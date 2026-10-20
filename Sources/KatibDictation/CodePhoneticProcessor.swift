import Foundation

/// Turns phonetic separator words into their punctuation forms when
/// sandwiched between identifier-like tokens. Designed for dictation into
/// code editors + terminals where users say things like "acme dash api"
/// and expect `acme-api`.
///
/// **Positional, not blanket.** A standalone "dash" or "slash" surrounded
/// by common English stopwords stays as a word — so "I need to dash to the
/// store" doesn't get mangled. The rule fires only when both the
/// preceding AND following tokens are non-stopword alphanumerics.
///
/// **Iterative.** Runs passes until the text stops changing, so chained
/// expressions like "acme dash api dash service" collapse all the way
/// to `acme-api-service`.
///
/// **Caller decides when this runs.** This file is pure logic — the
/// dictation pipeline gates it on bundle-ID match against
/// `AppSettings.codeModeAppPattern`.
public enum CodePhoneticProcessor {

    /// Ordered so multi-token triggers are tried before their single-token
    /// counterparts — "dash dash" must beat "dash" to form `--`.
    public static let defaultRules: [(trigger: String, replacement: String)] = [
        ("dash dash", "--"),
        ("slash slash", "//"),
        ("dash", "-"),
        ("slash", "/"),
        ("backslash", "\\"),
        ("dot", "."),
        ("underscore", "_"),
        ("colon", ":"),
        ("semicolon", ";")
    ]

    /// Short English words that should never be glued to an adjacent token
    /// by a code-mode trigger. Everything here is lowercase and compared
    /// case-insensitive.
    public static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "to", "from", "of", "in",
        "on", "at", "by", "for", "with", "about", "i", "you", "he", "she",
        "we", "they", "it", "is", "was", "are", "were", "be", "been", "have",
        "has", "had", "do", "does", "did", "my", "your", "our", "their",
        "this", "that", "these", "those", "so", "no", "not", "nor", "than",
        "then", "out", "up", "over", "under", "as", "me", "us", "him", "her"
    ]

    public static func process(
        _ input: String,
        rules: [(trigger: String, replacement: String)] = defaultRules,
        stopwords: Set<String> = stopwords
    ) -> String {
        var text = input
        // Bound iterations so a pathological input can't loop forever.
        // In practice one pass per trigger word in the input is plenty.
        for _ in 0..<10 {
            let before = text
            for (trigger, replacement) in rules {
                text = collapse(trigger: trigger, replacement: replacement, in: text, stopwords: stopwords)
            }
            if text == before { break }
        }
        return text
    }

    private static func collapse(
        trigger: String,
        replacement: String,
        in text: String,
        stopwords: Set<String>
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        let pattern = "(\\w+)\\s+\(escaped)\\s+(\\w+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        var result = text as NSString
        let fullRange = NSRange(location: 0, length: result.length)
        let matches = regex.matches(in: text, range: fullRange)
        // Right-to-left so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            let leftRange = match.range(at: 1)
            let rightRange = match.range(at: 2)
            let left = result.substring(with: leftRange).lowercased()
            let right = result.substring(with: rightRange).lowercased()
            if stopwords.contains(left) || stopwords.contains(right) { continue }
            let joined = "\(result.substring(with: leftRange))\(replacement)\(result.substring(with: rightRange))"
            result = result.replacingCharacters(in: match.range, with: joined) as NSString
        }
        return result as String
    }
}
