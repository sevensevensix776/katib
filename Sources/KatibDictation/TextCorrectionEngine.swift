import Foundation
import NaturalLanguage
import KatibCore

/// Post-processing for transcribed text: corrections, casing, punctuation.
///
/// Three correction types:
/// - **replacements**: casual speech → formal (gonna → going to)
/// - **dictionary**: casing fixes (api → API, typescript → TypeScript)
/// - **phonetic**: speech-to-text misrecognitions (ack me → Acme, hub spot → HubSpot)
///
/// Corrections are loaded from bundled defaults on first launch, then merged with the
/// user's editable file at `~/Library/Application Support/VoiceTools/corrections.json`.
/// Edits made via the Corrections Editor UI are saved to that file.
@MainActor
public final class TextCorrectionEngine: ObservableObject {
    public static let shared = TextCorrectionEngine()

    @Published public private(set) var corrections: CorrectionSet

    /// The plugin layer on its own, so recognition terms can rank plugin
    /// jargon (a team's names and terms) above bundled defaults and
    /// auto-learned identifiers.
    private var pluginSet = CorrectionSet()
    /// Everything below the user layer; saves write only the difference.
    private var baseSet = CorrectionSet()

    private let tagger: NLTagger
    private let userCorrectionsURL: URL
    private let posTagger: NLTagger
    private let sentenceTokenizer: NLTokenizer

    public init() {
        tagger = NLTagger(tagSchemes: [.nameType])
        posTagger = NLTagger(tagSchemes: [.lexicalClass])
        sentenceTokenizer = NLTokenizer(unit: .sentence)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sharedFolder = appSupport.appendingPathComponent("VoiceTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        userCorrectionsURL = sharedFolder.appendingPathComponent("corrections.json")

        (pluginSet, baseSet, corrections) = Self.layers(folder: sharedFolder, userURL: userCorrectionsURL)

        let total = corrections.replacements.count + corrections.dictionary.count + corrections.phonetic.count
        Logger.shared.log("Corrections loaded: \(corrections.replacements.count) replacements, \(corrections.dictionary.count) dictionary, \(corrections.phonetic.count) phonetic (\(total) total)")

        if !FileManager.default.fileExists(atPath: userCorrectionsURL.path) {
            createUserCorrectionsTemplate()
        }

        // A plugin added, removed or re-synced: rebuild the layers.
        NotificationCenter.default.addObserver(
            forName: .katibPluginsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }

    /// Rebuild the merged corrections from disk layers. Called when the plugin
    /// set or a plugin dictionary changes.
    private func reloadFromDisk() {
        (pluginSet, baseSet, corrections) = Self.layers(folder: userCorrectionsURL.deletingLastPathComponent(),
                                                        userURL: userCorrectionsURL)
    }

    /// Layer order (each layer wins over the one before):
    ///   bundled defaults → plugin dictionaries → learned terms → user overrides
    /// Returns the plugin layer, everything below the user layer, and the
    /// merged result with the user's disabled entries left out.
    private static func layers(folder: URL, userURL: URL) -> (plugin: CorrectionSet, base: CorrectionSet, merged: CorrectionSet) {
        var merged = loadBundledDefaults()
        let plugin = PluginDictionaries.shared.mergedSet()
        merge(plugin, into: &merged, label: "plugin")
        mergeFileInto(&merged, url: folder.appendingPathComponent("learned-terms.json"), label: "learned")
        let base = merged
        mergeFileInto(&merged, url: userURL, label: "user")
        return (plugin, base, droppingDisabled(merged))
    }

    /// The user's file holds only their changes against `base`: added or
    /// changed entries, and `"key": ""` for a base entry they deleted. So a
    /// plugin or default entry is never copied into it, and removing a plugin
    /// removes its entries.
    nonisolated static func userLayer(merged: CorrectionSet, base: CorrectionSet) -> CorrectionSet {
        func diff(_ m: [String: String], _ b: [String: String]) -> [String: String] {
            var out = m.filter { b[$0.key] != $0.value }
            for key in b.keys where m[key] == nil { out[key] = "" }
            return out
        }
        var out = CorrectionSet()
        out.replacements = diff(merged.replacements, base.replacements)
        out.dictionary = diff(merged.dictionary, base.dictionary)
        out.phonetic = diff(merged.phonetic, base.phonetic)
        return out
    }

    /// Leaves out entries the user disabled (`"key": ""`).
    nonisolated static func droppingDisabled(_ set: CorrectionSet) -> CorrectionSet {
        var out = set
        out.replacements = set.replacements.filter { !$0.value.isEmpty }
        out.dictionary = set.dictionary.filter { !$0.value.isEmpty }
        out.phonetic = set.phonetic.filter { !$0.value.isEmpty }
        return out
    }

    /// Words to hand the recognizer as contextual strings: the merged
    /// corrections plus the plugin layer.
    public var recognitionTerms: [String] {
        Self.recognitionTerms(phonetic: corrections.phonetic.merging(pluginSet.phonetic) { a, _ in a },
                              ranked: [pluginSet.dictionary, corrections.dictionary])
    }

    /// Phonetic targets first (each is a word the recognizer already got wrong),
    /// then each dictionary tier in order (plugin jargon before the rest, where
    /// auto-learned code identifiers live). Short all-caps acronyms (API, PRs,
    /// EC2) are skipped: the recognizer spells letters fine and the slots are
    /// scarce. Capped because `setContext` takes the whole list and a long one
    /// dilutes it.
    static func recognitionTerms(phonetic: [String: String],
                                 ranked tiers: [[String: String]],
                                 limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let acronym = /(?=.*[A-Z])[A-Z0-9]{1,5}s?/   // needs a letter, so "776" stays
        let ordered = phonetic.values.sorted() + tiers.flatMap { $0.values.sorted() }
        for term in ordered {
            let t = term.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.wholeMatch(of: acronym) == nil, seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == limit { break }
        }
        return out
    }

    /// Test-only: build an engine with a fixed correction set and no disk IO.
    internal init(testingCorrections: CorrectionSet) {
        tagger = NLTagger(tagSchemes: [.nameType])
        posTagger = NLTagger(tagSchemes: [.lexicalClass])
        sentenceTokenizer = NLTokenizer(unit: .sentence)
        userCorrectionsURL = URL(fileURLWithPath: "/dev/null")
        corrections = testingCorrections
    }

    /// Add or update a correction. Persists immediately.
    public func upsertCorrection(from: String, to: String, type: CorrectionType) {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty, !trimmedTo.isEmpty else { return }

        switch type {
        case .replacement: corrections.replacements[trimmedFrom] = trimmedTo
        case .dictionary: corrections.dictionary[trimmedFrom] = trimmedTo
        case .phonetic: corrections.phonetic[trimmedFrom] = trimmedTo
        }
        saveUserCorrections()
        NotificationCenter.default.post(name: .katibCorrectionsChanged, object: nil)
    }

    /// Remove a correction. Persists immediately.
    public func removeCorrection(key: String, type: CorrectionType) {
        switch type {
        case .replacement: corrections.replacements.removeValue(forKey: key)
        case .dictionary: corrections.dictionary.removeValue(forKey: key)
        case .phonetic: corrections.phonetic.removeValue(forKey: key)
        }
        saveUserCorrections()
        NotificationCenter.default.post(name: .katibCorrectionsChanged, object: nil)
    }

    /// Remove several corrections in one save. Posts one change notification.
    public func removeCorrections(_ keys: [String], type: CorrectionType) {
        guard !keys.isEmpty else { return }
        for key in keys {
            switch type {
            case .replacement: corrections.replacements.removeValue(forKey: key)
            case .dictionary: corrections.dictionary.removeValue(forKey: key)
            case .phonetic: corrections.phonetic.removeValue(forKey: key)
            }
        }
        saveUserCorrections()
        NotificationCenter.default.post(name: .katibCorrectionsChanged, object: nil)
    }

    /// Total number of active corrections across all three buckets.
    public var totalCount: Int {
        corrections.replacements.count + corrections.dictionary.count + corrections.phonetic.count
    }

    // MARK: - Import / Export

    public enum ImportStrategy {
        /// Replace user corrections entirely with imported set.
        case replace
        /// Merge imported entries on top of existing user corrections.
        case merge
    }

    /// Serialize the current merged set to a Data blob. UI exposes as Export.
    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(corrections)
    }

    /// Load a CorrectionSet from a Data blob and apply per the strategy.
    @discardableResult
    public func importData(_ data: Data, strategy: ImportStrategy) throws -> Int {
        let imported = try JSONDecoder().decode(CorrectionSet.self, from: data)
        switch strategy {
        case .replace:
            corrections = imported
        case .merge:
            for (k, v) in imported.replacements { corrections.replacements[k] = v }
            for (k, v) in imported.dictionary { corrections.dictionary[k] = v }
            for (k, v) in imported.phonetic { corrections.phonetic[k] = v }
        }
        saveUserCorrections()
        NotificationCenter.default.post(name: .katibCorrectionsChanged, object: nil)
        let count = imported.replacements.count + imported.dictionary.count + imported.phonetic.count
        Logger.shared.log("Imported \(count) corrections (\(strategy))")
        return count
    }

    /// Apply all corrections to transcribed text
    public func correct(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Step 1: Phonetic corrections (multi-word → term)
        for (from, to) in corrections.phonetic {
            result = replacePhrase(in: result, from: from, to: to)
        }

        // Step 2: Remove filler words (um, uh, like, you know, I mean)
        result = removeFillers(result)

        // Step 3: Word replacements (gonna → going to)
        for (from, to) in corrections.replacements {
            result = replaceWord(in: result, from: from, to: to)
        }

        // Step 4: Dictionary corrections (api → API)
        for (from, to) in corrections.dictionary {
            guard !from.hasPrefix("_comment") else { continue }
            result = replaceWord(in: result, from: from, to: to)
        }

        // Step 5: Clean up run-on sentences (insert periods at natural breaks)
        result = breakRunOnSentences(result)

        // Step 6: Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        // Step 7: Capitalize standalone "i"
        result = applyRegex(result, pattern: "\\bi\\b", replacement: "I")

        // Step 8: Capitalize after sentence-ending punctuation
        result = capitalizeSentences(result)

        // Step 9: Clean up spacing (double spaces, space before punctuation)
        result = cleanSpacing(result)

        // Step 10: Ensure ending punctuation (period by default) — must run BEFORE
        // fixQuestionMarks because that function looks for sentences ending in ".".
        if let last = result.last, !".!?:;,)]}\"'".contains(last) {
            result += "."
        }

        // Step 11: Fix question marks (sentences starting with interrogative words)
        result = fixQuestionMarks(result)

        return result
    }

    // MARK: - Text Processing

    private func replaceWord(in text: String, from: String, to: String) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: from))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex

        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            result.append(contentsOf: text[cursor..<matchRange.lowerBound])
            let matched = String(text[matchRange])
            result.append(self.adjustCase(original: matched, replacement: to))
            cursor = matchRange.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    /// Replace a multi-word phrase (case-insensitive match)
    private func replacePhrase(in text: String, from: String, to: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: from),
            options: .caseInsensitive
        ) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: to)
    }

    private func adjustCase(original: String, replacement: String) -> String {
        // If replacement has explicit casing (API, TypeScript, CI/CD), preserve it
        let letters = replacement.filter { $0.isLetter }
        if letters.count > 1 {
            let hasUpper = letters.contains { $0.isUppercase }
            let hasLower = letters.contains { $0.isLowercase }
            if (hasUpper && hasLower) || letters.allSatisfy({ $0.isUppercase }) {
                return replacement
            }
        }

        // Match the original's casing
        if original.allSatisfy({ $0.isUppercase || !$0.isLetter }) {
            return replacement.uppercased()
        } else if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement.lowercased()
    }

    private func applyRegex(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
    }

    private func capitalizeSentences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?])\\s+([a-z])", options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            if let fullRange = Range(match.range, in: result),
               let letterRange = Range(match.range(at: 2), in: result) {
                let letter = String(result[letterRange]).uppercased()
                let prefix = String(result[fullRange]).prefix(while: { !$0.isLetter })
                result.replaceSubrange(fullRange, with: prefix + letter)
            }
        }
        return result
    }

    // MARK: - Filler Removal

    /// Remove filler words and discourse markers that add no meaning
    private func removeFillers(_ text: String) -> String {
        var result = text

        // Single-word fillers: um, uh, uh-huh — at sentence start or mid-sentence
        // Handles: "Um, I think" → "I think" and "I, um, think" → "I think"
        result = applyRegex(result, pattern: "(?i)\\b[Uu][mh]\\b[,.]?\\s*", replacement: "")
        result = applyRegex(result, pattern: "(?i),?\\s*\\b[Uu]h\\b,?\\s*", replacement: " ")

        // Multi-word fillers (surrounded by commas/spaces/sentence boundaries)
        let fillerPhrases = [
            "you know", "I mean", "sort of", "kind of like",
            "or whatever", "and stuff", "and things like that",
            "to be honest", "at the end of the day", "so basically"
        ]
        for filler in fillerPhrases {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            // Mid-sentence: ", you know, " → " "
            result = applyRegex(result, pattern: "(?i),?\\s*\\b\(escaped)\\b,?\\s+", replacement: " ")
            // Sentence start: "You know, I think" → "I think"
            result = applyRegex(result, pattern: "(?i)(?<=^|[.!?]\\s)\\b\(escaped)\\b,?\\s+", replacement: "")
        }

        // "honestly" at sentence start
        result = applyRegex(result, pattern: "(?i)(?<=^|[.!?]\\s)[Hh]onestly,?\\s+", replacement: "")

        return result
    }

    // MARK: - Smart Sentence Breaking (NLTagger-based)

    /// Break run-on sentences using POS tagging to find natural break points.
    /// When a clause exceeds ~25 words and we hit a conjunction or transition word,
    /// replace the comma with a period.
    private func breakRunOnSentences(_ text: String) -> String {
        // First: use NLTokenizer to find existing sentences and check their length
        sentenceTokenizer.string = text
        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }

        // Process each sentence — if too long, try to break it
        var result: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = trimmed.split(separator: " ").count

            if wordCount > 25 {
                result.append(breakLongSentence(trimmed))
            } else {
                result.append(trimmed)
            }
        }

        return result.joined(separator: " ")
    }

    /// Break a single long sentence at natural conjunction/transition points using POS tagging
    private func breakLongSentence(_ sentence: String) -> String {
        // Transition words that can start a new sentence
        let transitionWords: Set<String> = [
            "so", "but", "and", "also", "however", "because", "although",
            "then", "therefore", "meanwhile", "additionally", "furthermore",
            "how", "what", "where", "when", "why", "which"
        ]

        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 25 else { return sentence }

        var result = ""
        var wordsSinceBreak = 0

        for word in words {
            let cleanWord = word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)

            // Check if this is a good break point:
            // - At least 15 words since last break (don't create tiny sentences)
            // - Current word is a transition/conjunction word
            // - Previous word ended with a comma or no punctuation
            if wordsSinceBreak >= 15 && transitionWords.contains(cleanWord) {
                // Remove trailing comma from previous text if present
                if result.hasSuffix(", ") || result.hasSuffix(",") {
                    result = String(result.dropLast(result.hasSuffix(", ") ? 2 : 1))
                }
                result += ". "
                // Capitalize the transition word
                let capitalized = word.prefix(1).uppercased() + word.dropFirst()
                result += capitalized
                wordsSinceBreak = 1
            } else {
                if !result.isEmpty { result += " " }
                result += word
                wordsSinceBreak += 1
            }
        }

        return result
    }

    // MARK: - Question Detection

    /// Detect sentences that should end with "?" instead of "."
    private func fixQuestionMarks(_ text: String) -> String {
        let interrogatives: Set<String> = [
            "who", "what", "where", "when", "why", "how",
            "is", "are", "can", "do", "does", "should", "would", "could",
            "will", "did", "has", "have", "was", "were"
        ]

        sentenceTokenizer.string = text
        var sentences: [(String, Range<String.Index>)] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append((String(text[range]), range))
            return true
        }

        var result = text
        // Process from end to preserve ranges
        for (sentence, range) in sentences.reversed() {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix(".") else { continue }  // Only fix periods, not existing ?

            let firstWord = trimmed.split(separator: " ").first.map { String($0).lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters) } ?? ""
            if interrogatives.contains(firstWord) {
                let fixed = String(trimmed.dropLast()) + "?"
                let trimmedRange = Range(uncheckedBounds: (
                    lower: text[range].firstIndex(where: { !$0.isWhitespace }) ?? range.lowerBound,
                    upper: text[range].lastIndex(where: { !$0.isWhitespace }).map { text.index(after: $0) } ?? range.upperBound
                ))
                result.replaceSubrange(trimmedRange, with: fixed)
            }
        }

        return result
    }

    // MARK: - Spacing Cleanup

    private func cleanSpacing(_ text: String) -> String {
        var result = text

        // Double spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Space before punctuation
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ?", with: "?")

        // Double periods
        while result.contains("..") && !result.contains("...") {
            result = result.replacingOccurrences(of: "..", with: ".")
        }

        // Ensure space after sentence-ending punctuation
        if let regex = try? NSRegularExpression(pattern: "([.!?])([A-Z])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1 $2"
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Persistence

    static func loadBundledDefaults() -> CorrectionSet {
        // Bundle.main FIRST and short-circuit. Bundle.module's static
        // initializer fatalError's on the deployed .app because SPM's
        // generated accessor looks for `Katib.app/Katib_KatibDictation.bundle`
        // (the .app root) which codesign won't accept, so we ship the
        // raw JSON in Contents/Resources via build-app.sh and reach
        // for it through Bundle.main. The Bundle.module fallback exists
        // only for tests and the dev REPL, where Bundle.main has no
        // resources and Bundle.module's build-path string resolves.
        let url = Bundle.main.url(forResource: "default-corrections", withExtension: "json")
            ?? Bundle.module.url(forResource: "default-corrections", withExtension: "json")

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return CorrectionSet()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CorrectionSet.self, from: data)
        } catch {
            Logger.shared.log("Error loading bundled corrections: \(error)")
            return CorrectionSet()
        }
    }

    private static func merge(_ set: CorrectionSet, into target: inout CorrectionSet, label: String) {
        for (k, v) in set.replacements { target.replacements[k] = v }
        for (k, v) in set.dictionary { target.dictionary[k] = v }
        for (k, v) in set.phonetic { target.phonetic[k] = v }
        Logger.shared.log("Merged \(set.replacements.count + set.dictionary.count + set.phonetic.count) \(label) corrections")
    }

    private static func mergeFileInto(_ target: inout CorrectionSet, url: URL, label: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let set = try JSONDecoder().decode(CorrectionSet.self, from: data)
            var count = 0
            for (k, v) in set.replacements { target.replacements[k] = v; count += 1 }
            for (k, v) in set.dictionary { target.dictionary[k] = v; count += 1 }
            for (k, v) in set.phonetic { target.phonetic[k] = v; count += 1 }
            Logger.shared.log("Merged \(count) \(label) corrections from \(url.lastPathComponent)")
        } catch {
            Logger.shared.log("Error loading \(label) corrections: \(error)")
        }
    }

    private func saveUserCorrections() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Self.userLayer(merged: corrections, base: baseSet))
            // Atomic so a kill mid-write can't leave a half-flushed JSON
            // file that fails to decode on next launch.
            try data.write(to: userCorrectionsURL, options: .atomic)
            Logger.shared.log("Saved corrections to \(userCorrectionsURL.lastPathComponent)")
        } catch {
            Logger.shared.log("Error saving corrections: \(error)")
        }
    }

    private func createUserCorrectionsTemplate() {
        let template = CorrectionSet()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(template)
            try data.write(to: userCorrectionsURL, options: .atomic)
        } catch {
            // Not critical
        }
    }
}

// MARK: - Models

public struct CorrectionSet: Codable {
    public var replacements: [String: String]
    public var dictionary: [String: String]
    public var phonetic: [String: String]

    public init() {
        replacements = [:]
        dictionary = [:]
        phonetic = [:]
    }

    enum CodingKeys: String, CodingKey {
        case replacements, dictionary, phonetic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replacements = (try? container.decode([String: String].self, forKey: .replacements)) ?? [:]
        dictionary = (try? container.decode([String: String].self, forKey: .dictionary)) ?? [:]
        phonetic = (try? container.decode([String: String].self, forKey: .phonetic)) ?? [:]
    }
}

public enum CorrectionType {
    case replacement
    case dictionary
    case phonetic
}
