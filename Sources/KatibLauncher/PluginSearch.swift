import AppKit
import Foundation
import KatibCore

/// Runs every search plugin for the Command Palette (see `PluginManifest`).
/// Each plugin's command gets the query as its last argument and prints
///
///     {"items": [{"id": "…", "title": "…", "subtitle": "…", "url": "…", "snippet": "…"}]}
///
/// Only `title` is required. `url` is opened on Return: a web or file URL,
/// or an absolute path. In `snippet`, `[brackets]` mark the matched words.
///
/// Design matches FileSearchProvider: debounced, bounded, and a newer query
/// discards an older one's results. Commands run off the main thread with a
/// timeout, get argv only (no shell), and a plugin whose executable is
/// missing shows nothing at all, never an error row.
@MainActor
public final class PluginSearch: ObservableObject {
    public struct Result: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let url: URL?
        public let snippet: String?
    }

    /// Hits per plugin id. A plugin with no hits has no key.
    @Published public private(set) var results: [String: [Result]] = [:]
    /// Plugins with a query in flight, so the palette can say "searching…".
    @Published public private(set) var searching: Set<String> = []
    /// Why a plugin's last query failed (rather than matched nothing), shown
    /// in its header so a slow or broken plugin never looks like "no results".
    @Published public private(set) var failures: [String: String] = [:]

    public let plugins: [Plugin]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = 0
    private let debounce: Duration

    public init(plugins: [Plugin], debounce: Duration = .milliseconds(250)) {
        self.plugins = plugins.filter { $0.searchCommand != nil }
        self.debounce = debounce
    }

    public func search(_ text: String) {
        cancelTasks()
        generation += 1
        let gen = generation
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        results = [:]
        failures = [:]
        searching = []
        for plugin in plugins {
            guard let argv = plugin.searchCommand,
                  trimmed.count >= (plugin.manifest.search?.minQueryLength ?? 3),
                  FileManager.default.isExecutableFile(atPath: argv[0]) else { continue }
            let id = plugin.id
            let limit = plugin.manifest.search?.limit ?? 6
            let timeout = plugin.manifest.search?.timeout ?? 6
            searching.insert(id)
            tasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.debounce ?? .milliseconds(250))
                guard !Task.isCancelled else { return }
                let started = Date()
                let outcome = await Self.run(argv + [trimmed], timeout: timeout)
                guard let self, gen == self.generation else { return }   // a newer query won
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch outcome {
                case .ok(let data):
                    if let parsed = Self.parse(data, limit: limit) {
                        Logger.shared.log("PluginSearch[\(id)]: \(parsed.count) hits in \(ms)ms")
                        if !parsed.isEmpty { self.results[id] = parsed }
                    } else {
                        Logger.shared.log("PluginSearch[\(id)]: unreadable output after \(ms)ms: \(data.prefix(200).count) bytes")
                        self.failures[id] = "returned output Katib could not read"
                    }
                case .failed(let why):
                    Logger.shared.log("PluginSearch[\(id)]: failed after \(ms)ms: \(why)")
                    self.failures[id] = why
                }
                self.searching.remove(id)
            }
        }
    }

    public func cancel() {
        cancelTasks()
        generation += 1
        searching = []
        failures = [:]
        if !results.isEmpty { results = [:] }
    }

    private func cancelTasks() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    public static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Parsing (pure, tested)

    /// Turns a plugin's output into rows; nil when it is not `{"items": [...]}`,
    /// so a broken plugin says so instead of looking like "no matches".
    nonisolated static func parse(_ data: Data, limit: Int) -> [Result]? {
        struct Item: Decodable {
            let id: String?
            let title: String?
            let subtitle: String?
            let url: String?
            let snippet: String?
        }
        struct Answer: Decodable { let items: [Item] }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        var out: [Result] = []
        for (i, item) in answer.items.enumerated() {
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            out.append(Result(
                id: item.id ?? item.url ?? "\(i):\(title)",
                title: title,
                subtitle: item.subtitle,
                url: item.url.flatMap(Self.url),
                snippet: item.snippet.flatMap(cleanSnippet)
            ))
            if out.count == limit { break }
        }
        return out
    }

    nonisolated static func url(_ s: String) -> URL? {
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        guard let u = URL(string: s), u.scheme != nil else { return nil }
        return u
    }

    /// One readable line: whitespace collapsed and a window of about 140
    /// characters around the first `[match]`. Nil when nothing is left.
    nonisolated static func cleanSnippet(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let width = 140
        if let open = s.firstIndex(of: "["), s.distance(from: s.startIndex, to: open) > 50 {
            let start = s.index(open, offsetBy: -40)
            s = "…" + s[start...].trimmingCharacters(in: .whitespaces)
        }
        if s.count > width { s = String(s.prefix(width)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }

    // MARK: - Process

    enum Outcome: Sendable {
        case ok(Data)
        case failed(String)   // shown to the user, so plain words
    }

    /// Runs one plugin command, giving up after `timeout` seconds. On timeout
    /// the process gets SIGTERM, then SIGKILL a second later, and Katib stops
    /// waiting either way: a child that keeps stdout open cannot hold it.
    nonisolated static func run(_ argv: [String], timeout: Double) async -> Outcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: argv[0])
                p.arguments = Array(argv.dropFirst())
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                let buffer = OutputBuffer()
                let done = DispatchSemaphore(value: 0)
                out.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil } else { buffer.append(chunk) }
                }
                p.terminationHandler = { _ in done.signal() }
                do { try p.run() } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: .failed("could not start the plugin"))
                    return
                }
                if done.wait(timeout: .now() + timeout) == .timedOut {
                    p.terminate()
                    if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
                    out.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: .failed("took longer than \(Int(timeout)) s"))
                    return
                }
                // Exited: drain what is left (bounded: the writer is gone
                // unless it handed stdout to a child, which gets 0.5 s).
                let drained = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    out.fileHandleForReading.readabilityHandler = nil
                    buffer.append(out.fileHandleForReading.readDataToEndOfFile())
                    drained.signal()
                }
                _ = drained.wait(timeout: .now() + 0.5)
                if p.terminationStatus != 0 {
                    cont.resume(returning: .failed("search failed (exit \(p.terminationStatus))"))
                } else {
                    cont.resume(returning: .ok(buffer.data))
                }
            }
        }
    }
}

/// Collects a plugin's stdout from the pipe's reader thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
