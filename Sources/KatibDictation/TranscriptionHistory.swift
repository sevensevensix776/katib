import Foundation
import KatibCore

/// Per-transcription metadata for stats + UI. Privacy: never persists raw or
/// corrected text — storing them plaintext under ~/Library/Application Support
/// would leak every utterance to anyone with disk access, Time Machine, or MDM.
public final class TranscriptionHistory: @unchecked Sendable {
    public static let shared = TranscriptionHistory()

    private let historyURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("VoiceTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        historyURL = folder.appendingPathComponent("history.jsonl")
    }

    struct Entry: Codable {
        let timestamp: String
        let engine: String
        let app: String
        let durationSeconds: Double
        let wordCount: Int
        let charCount: Int
    }

    public func save(raw: String, corrected: String, duration: Double, app: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entry = Entry(
            timestamp: formatter.string(from: Date()),
            engine: "katib",
            app: app,
            durationSeconds: duration,
            wordCount: corrected.split(separator: " ").count,
            charCount: corrected.count
        )

        do {
            let data = try JSONEncoder().encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"

            if FileManager.default.fileExists(atPath: historyURL.path) {
                if let handle = try? FileHandle(forWritingTo: historyURL) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    try? handle.close()
                }
            } else {
                try line.data(using: .utf8)?.write(to: historyURL)
            }
        } catch {
            Logger.shared.log("History save error: \(error)")
        }
    }

    /// One day of dictation, as the popover's ledger shows it.
    public struct DayStats: Equatable, Sendable {
        public var count = 0
        public var words = 0
        /// Seconds the dictation key was held, summed.
        public var spokenSeconds: Double = 0
        public init(count: Int = 0, words: Int = 0, spokenSeconds: Double = 0) {
            self.count = count; self.words = words; self.spokenSeconds = spokenSeconds
        }
    }

    /// Entries logged on the person's local calendar day.
    public func todayStats() -> DayStats {
        guard FileManager.default.fileExists(atPath: historyURL.path),
              let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return DayStats()
        }
        return Self.stats(in: content, on: Date())
    }

    /// Pure core of `todayStats`, so the day rollover can be tested.
    ///
    /// Timestamps are stored in UTC. "Today" is the local calendar day, not
    /// the UTC date: comparing the UTC date prefix rolled the day over at
    /// 4 pm Pacific (2026-11-20, found while mocking the daily total).
    static func stats(in content: String, on day: Date, calendar: Calendar = .current) -> DayStats {
        // A local day touches at most two UTC dates. Skip lines that carry
        // neither before paying for a JSON decode.
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return DayStats() }
        let utcDay = ISO8601DateFormatter()
        utcDay.formatOptions = [.withFullDate]
        let prefixes = Set([
            utcDay.string(from: interval.start),
            utcDay.string(from: interval.end.addingTimeInterval(-1))
        ])

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var stats = DayStats()
        for line in content.split(separator: "\n") {
            guard prefixes.contains(where: { line.contains($0) }),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  let when = fractional.date(from: entry.timestamp) ?? plain.date(from: entry.timestamp),
                  interval.contains(when) else { continue }
            stats.count += 1
            stats.words += entry.wordCount
            stats.spokenSeconds += entry.durationSeconds
        }
        return stats
    }

    /// One-time migration — wipe the legacy plaintext-bearing file if present.
    public static func purgeLegacyHistoryIfNeeded() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("VoiceTools/history.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        if content.contains("\"rawText\"") || content.contains("\"correctedText\"") {
            try? FileManager.default.removeItem(at: url)
            Logger.shared.log("Purged legacy history.jsonl (contained plaintext transcriptions)")
        }
    }
}
