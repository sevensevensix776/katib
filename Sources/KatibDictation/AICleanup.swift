import Foundation
import KatibCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs the corrected transcription through Apple's on-device language model
/// (macOS 26 Foundation Models) for a final polish pass. Tightens punctuation,
/// removes stutters + restarts, drops filler words. Meaning + tone unchanged.
///
/// ## Why structured output
///
/// Our earlier implementation used `session.respond(to:)` with a free-form
/// system prompt. The 3B instruct model regularly responded with prose ABOUT
/// cleanup — "The transcription was processed to remove redundant restarts…"
/// — instead of the cleaned text itself. And output length consistently
/// inflated 1.5–3x rather than shrinking (the expected cleanup direction).
///
/// Foundation Models ships `@Generable` for exactly this class of problem:
/// the model is constrained to produce a Swift struct you define. With a
/// single-field `PolishedTranscript` schema, the model physically cannot
/// return commentary — only the string that fills the slot. Paired with
/// strict ratio + word-overlap guards, the meta-response failure mode is
/// eliminated.
///
/// Sessions are still created fresh per call to avoid context accumulation
/// (earlier cache caused `exceededContextWindowSize` after a day's use).
@MainActor
public final class AICleanup {
    public static let shared = AICleanup()

    private init() {}

    #if canImport(FoundationModels)
    /// Output schema. Single field so the model has nowhere to go except
    /// the cleaned text — no room for preambles, descriptions, or refusals.
    @available(macOS 26, *)
    @Generable
    struct PolishedTranscript {
        @Guide(description: """
            The cleaned transcript. REQUIREMENTS:
            - Keep every CONTENT word (nouns, verbs, names, facts). Don't summarize, paraphrase, or reword meaning.
            - Aggressively remove:
              * Filler words: um, uh, like, you know, I mean, actually, basically, kind of, sort of, I think (when vacuous)
              * Immediate duplicates: "in this in this specific" → "in this specific", "why why did" → "why did"
              * Restarted phrases: "I was going to — I wanted to say" → "I wanted to say"
              * Trailing self-corrections: "there was still alive, I mean, there was still a lag" → "there was still a lag"
            - Fix obvious word-boundary mistranscriptions where context makes the intended word unambiguous
              (e.g. "there was still alive" → "it was still alive" if context is clearly about persistence).
            - Add or fix punctuation and capitalization.
            - Output will be SHORTER than input. That's expected.
            - Do not describe what you did. Do not add commentary. Return only the cleaned text.
            """)
        let text: String
    }
    #endif

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Run the cleanup pass.
    /// - Parameters:
    ///   - text: The already-corrected transcription.
    ///   - bundleID: The active app's bundle ID at recording-start; used to
    ///     pick a matching per-app profile. Nil = base prompt only.
    public func polish(_ text: String, bundleID: String? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return text }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return text }
            do {
                let session = sessionForProfile(bundleID: bundleID)
                let response = try await session.respond(
                    to: "Clean up this transcript:\n\n\(trimmed)",
                    generating: PolishedTranscript.self
                )
                let polished = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if AppSettings.shared.debugTranscripts {
                    Logger.shared.logContent("DEBUG AI-raw", polished)
                }
                if let rejection = Self.rejectionReason(polished: polished, original: trimmed) {
                    Logger.shared.log("AI polish: rejected (\(rejection)), falling back to pre-polish text")
                    return text
                }
                Logger.shared.log("AI polish: \(Logger.summarize(trimmed)) -> \(Logger.summarize(polished))")
                return polished
            } catch {
                Logger.shared.log("AI polish error: \(error.localizedDescription)")
                return text
            }
        }
        #endif

        return text
    }

    // MARK: - Session construction

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func sessionForProfile(bundleID: String?) -> LanguageModelSession {
        let basePrompt = AppSettings.shared.aiCleanupPrompt
        let tail = profileTail(for: bundleID)
        let composed = tail.isEmpty ? basePrompt : "\(basePrompt)\n\n\(tail)"
        return LanguageModelSession(instructions: composed)
    }
    #endif

    // MARK: - Rejection

    /// Two-part guard against bad polish results:
    /// 1. Length ratio — cleanup should SHORTEN (or stay roughly equal).
    ///    Anything >1.25x the original means the model rewrote rather than
    ///    cleaned. That's always wrong for our use case.
    /// 2. Word overlap — at least 70% of the input's content words should
    ///    appear in the output. Lower than that = paraphrased, not cleaned.
    nonisolated static func rejectionReason(polished: String, original: String) -> String? {
        if polished.isEmpty { return "empty" }

        let ratio = Double(polished.count) / Double(max(original.count, 1))
        if ratio > 1.25 {
            return "inflation \(String(format: "%.2f", ratio))x (\(polished.count) vs \(original.count))"
        }

        let overlap = wordOverlap(polished: polished, original: original)
        if overlap < 0.70 {
            return "overlap \(Int(overlap * 100))% — paraphrased instead of cleaned"
        }

        return nil
    }

    /// Fraction of original content-word tokens that also appear in polished.
    /// Fillers ("um", "uh", "like", etc.) are stripped from BOTH sides before
    /// comparison so the filter doesn't punish correct filler removal —
    /// what we're detecting is paraphrasing, where content words change.
    nonisolated static func wordOverlap(polished: String, original: String) -> Double {
        let originalWords = contentWords(original)
        guard !originalWords.isEmpty else { return 1.0 }
        let polishedWords = Set(contentWords(polished))
        let kept = originalWords.filter { polishedWords.contains($0) }.count
        return Double(kept) / Double(originalWords.count)
    }

    /// Common English fillers + tiny stopwords. Cleanup is allowed to drop
    /// these, so they get stripped before we measure overlap.
    nonisolated private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "hmm", "like", "literally",
        "actually", "basically", "really", "you", "know", "mean",
        "so", "well", "right", "okay", "ok", "yeah", "kinda", "sorta"
    ]

    nonisolated private static func contentWords(_ text: String) -> [String] {
        // Strip apostrophes first so "what's" ↔ "whats" collide. Then split
        // on any other non-alphanumeric boundary.
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "") // curly apostrophe
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !fillers.contains($0) }
    }

    /// Look up the extra instruction line for the active bundle ID. Uses
    /// case-insensitive regex matching — first match wins.
    private func profileTail(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "" }
        for (pattern, tail) in AppSettings.shared.aiCleanupAppProfiles {
            if bundleID.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return tail
            }
        }
        return ""
    }
}

// .katibCleanupPromptChanged is declared in KatibCore's AppSettings.swift so
// both Core (which posts it on @Published didSet) and Dictation (which
// observes here) share the same symbol without circular imports.
