import Foundation
import KatibCore

/// Intercepts transcriptions that are actually commands. Runs BEFORE the
/// correction engine — if the raw text matches a command pattern, we skip
/// cleanup + paste entirely and invoke the action instead.
///
/// Katib becomes a dictation + command hybrid without a separate modal UI:
/// say "split left" → window snaps; say "new paragraph" → `\n\n` is inserted
/// in the place of the transcription; say "paste last" → last dictation is
/// re-pasted. Everything else falls through to normal transcription → paste.
///
/// Inspired by the local-whisper OSS project, which exposes this via a
/// Hammerspoon Lua hook — we build it in-language with a typed registry.
public enum VoiceCommandOutcome: Sendable {
    /// Run this closure (on MainActor) and skip the paste entirely.
    case execute(@MainActor @Sendable () -> Void)
    /// Replace the transcription with this literal string (still pastes).
    /// Useful for "new paragraph" → `"\n\n"`.
    case insertText(String)
}

public struct VoiceCommand: Sendable {
    /// Regex patterns that trigger the command. Any match wins. Case- and
    /// punctuation-insensitive — the matcher strips trailing .!?," before
    /// comparing and always folds to lowercase.
    public let patterns: [String]
    public let outcome: VoiceCommandOutcome
    public let displayName: String

    public init(displayName: String, patterns: [String], outcome: VoiceCommandOutcome) {
        self.displayName = displayName
        self.patterns = patterns
        self.outcome = outcome
    }
}

@MainActor
public final class VoiceCommandMatcher {
    public static let shared = VoiceCommandMatcher()

    /// Ordered command list — first match wins. Feature modules register
    /// their commands on app launch; the dictation pipeline runs `match(on:)`
    /// before the correction engine.
    private var commands: [VoiceCommand] = []

    private init() {}

    public func register(_ command: VoiceCommand) {
        commands.append(command)
    }

    public func register(_ many: [VoiceCommand]) {
        commands.append(contentsOf: many)
    }

    public func clear() {
        commands.removeAll()
    }

    /// Try to match the raw transcription against registered commands.
    /// Returns `nil` if no command fires — caller proceeds with normal
    /// cleanup + paste.
    public func match(on text: String) -> VoiceCommandOutcome? {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return nil }

        for command in commands {
            for pattern in command.patterns {
                if normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    Logger.shared.log("Voice command matched: \(command.displayName)")
                    return command.outcome
                }
            }
        }
        return nil
    }

    /// Lowercase + strip trailing sentence punctuation + trim whitespace.
    /// Speech recognizers often append ".!?" — we match without it.
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var result = trimmed
        while let last = result.last, ".!?,;:".contains(last) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
