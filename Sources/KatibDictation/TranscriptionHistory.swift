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

    /// Count + total word count of entries logged today.
    public func todayStats() -> (count: Int, words: Int) {
        guard FileManager.default.fileExists(atPath: historyURL.path),
              let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return (0, 0)
        }

        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var count = 0
        var words = 0

        for line in content.split(separator: "\n") {
            guard line.contains(today) else { continue }
            if let data = line.data(using: .utf8),
               let entry = try? JSONDecoder().decode(Entry.self, from: data) {
                count += 1
                words += entry.wordCount
            }
        }

        return (count, words)
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
