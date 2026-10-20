import Foundation

/// File logger with millisecond timestamps.
///
/// Privacy: callers must never pass full transcription text — use `summarize(_:)`
/// for any user-content-bearing string so dictated passwords/DMs/etc don't end up
/// on disk or in Sentry breadcrumbs.
public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.katib.logger")
    private let maxBytes = 5 * 1024 * 1024 // 5 MB

    private init() {
        // Under XCTest, redirect to a per-process temp file so test runs
        // don't pollute the production log with fixture output (corrections
        // saves, voice-command matches, transient HotkeyTapRouter
        // start/stops). Next investigation in ~/Library/Logs/Katib/ stays
        // free of test noise.
        //
        // Detection: `XCTestConfigurationFilePath` only appears under
        // xcodebuild — `swift test` doesn't set it. NSClassFromString is
        // the one signal that works in both, plus IDE test runs and
        // future swift-testing, since the XCTest framework is always
        // loaded into the test process.
        let isTesting = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName == "xctest"

        let logsDir: URL
        if isTesting {
            logsDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("KatibTestLogs", isDirectory: true)
        } else {
            logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs/Katib", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logName = isTesting ? "katib-test-\(ProcessInfo.processInfo.processIdentifier).log" : "katib.log"
        logFileURL = logsDir.appendingPathComponent(logName)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        rotateIfNeeded()
        if !isTesting {
            log("=== Katib Started ===")
        }
    }

    public func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self else { return }
            if let data = logLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: self.logFileURL)
                }
            }
        }
    }

    /// Summarize a user-content string for safe logging: `"12 words, 89 chars"`.
    /// Never logs the content itself.
    public static func summarize(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(words) words, \(text.count) chars"
    }

    /// Write full text content — only called from stages gated on
    /// `AppSettings.debugTranscripts`. Quotes + truncates at 500 chars so a
    /// runaway transcript can't fill the log. Local-only — the log file is
    /// never uploaded anywhere.
    public func logContent(_ label: String, _ text: String) {
        let max = 500
        let sanitized = text.replacingOccurrences(of: "\n", with: "\\n")
        let shown = sanitized.count > max ? String(sanitized.prefix(max)) + "…[truncated]" : sanitized
        log("\(label): \"\(shown)\"")
    }

    private func rotateIfNeeded() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }

        let rotated = logFileURL.deletingLastPathComponent().appendingPathComponent("katib.log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logFileURL, to: rotated)
    }
}
