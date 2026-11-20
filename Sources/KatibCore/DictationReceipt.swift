import Foundation

/// Time-saved arithmetic and the receipt line, kept free of UI and storage so
/// tests can pin the numbers.
///
/// Time saved = words / typing speed - time spoken, never below zero.
/// `spokenSeconds` is the time the dictation key was held (hotkey down to
/// hotkey up, AppDelegate.recordingStartTime), not the processing pipeline.
public enum TimeSaved {
    public static let defaultWPM = 40
    public static let wpmRange = 10...200

    public static func typingSeconds(words: Int, wpm: Int) -> Double {
        guard words > 0, wpm > 0 else { return 0 }
        return Double(words) / Double(wpm) * 60
    }

    public static func savedSeconds(words: Int, spokenSeconds: Double, wpm: Int) -> Double {
        max(0, typingSeconds(words: words, wpm: wpm) - max(0, spokenSeconds))
    }

    /// `m:ss`, or `h:mm:ss` from one hour. Rounds to the nearest second.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One dictation, as the receipt shows it: `Slack ..... 21 w  0:08  +0:23`.
public struct DictationReceipt: Equatable, Sendable {
    public let app: String
    public let words: Int
    public let spokenSeconds: Double
    public let savedSeconds: Double

    public init(app: String, words: Int, spokenSeconds: Double, wpm: Int) {
        self.app = app
        self.words = words
        self.spokenSeconds = spokenSeconds
        self.savedSeconds = TimeSaved.savedSeconds(words: words, spokenSeconds: spokenSeconds, wpm: wpm)
    }

    /// Everything right of the dotted leader, minus the saved figure.
    public var detail: String { "\(words) w  \(TimeSaved.clock(spokenSeconds))" }
    public var saved: String { "+\(TimeSaved.clock(savedSeconds))" }
    /// Plain-text form, for logs, tests and accessibility.
    public var plain: String { "\(app) ..... \(detail)  \(saved)" }
}

/// The four ledger lines under today's word count in the popover.
public struct LedgerFigures: Equatable, Sendable {
    public let dictations: Int
    public let words: Int
    public let spokenSeconds: Double
    public let typingSeconds: Double
    public let savedSeconds: Double

    public init(dictations: Int, words: Int, spokenSeconds: Double, wpm: Int) {
        self.dictations = dictations
        self.words = words
        self.spokenSeconds = spokenSeconds
        self.typingSeconds = TimeSaved.typingSeconds(words: words, wpm: wpm)
        self.savedSeconds = TimeSaved.savedSeconds(words: words, spokenSeconds: spokenSeconds, wpm: wpm)
    }

    /// 1286 -> "1,286". Fixed locale so the tests and the popover agree.
    public static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public var wordsText: String { Self.grouped(words) }
    public var spokenText: String { TimeSaved.clock(spokenSeconds) }
    public var typingText: String { TimeSaved.clock(typingSeconds) }
    public var savedText: String { TimeSaved.clock(savedSeconds) }
}
