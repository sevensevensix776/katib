import AppKit
import Foundation
import KatibCore

/// Live file-search provider for the Command Palette. Wraps `NSMetadataQuery`
/// (Apple's Spotlight index) so the palette can offer Alfred-style file
/// results alongside Katib actions and app-launcher rows.
///
/// Design:
/// - **Debounced**. Each keystroke restarts a 150ms timer; only the final
///   query hits Spotlight. Cheap enough that this could be tighter, but
///   150ms matches typical typing latency without feeling laggy.
/// - **Bounded**. `kQueryResultLimit` capped — palette has finite real
///   estate and Spotlight matches can run into the thousands for short
///   queries like "doc".
/// - **Excludes apps**. AppLauncherIndex already provides those; doubling
///   them would make the palette noisy and split frecency state.
/// - **Cancels prior queries** when a new one comes in. NSMetadataQuery
///   keeps streaming updates if you don't `stop()`, which would race
///   against the debounce.
@MainActor
public final class FileSearchProvider: ObservableObject {
    public struct Result: Sendable, Identifiable, Equatable {
        public let id: String          // canonical file path — stable id
        public let displayName: String
        public let url: URL
        public let kind: String?       // localized type ("PNG image", "Folder", etc.)
    }

    @Published public private(set) var results: [Result] = []

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let limit: Int
    private let minQueryLength: Int
    private let debounce: Duration

    public init(limit: Int = 10, minQueryLength: Int = 2, debounce: Duration = .milliseconds(150)) {
        self.limit = limit
        self.minQueryLength = minQueryLength
        self.debounce = debounce
    }

    deinit {
        // Best-effort: nonisolated deinit can't safely touch MainActor state.
        // The query stops itself when its observer is torn down by the
        // notification center on dealloc.
    }

    /// Begin a new search. Cheap to call on every keystroke — debounced
    /// + idempotent.
    public func search(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        guard trimmed.count >= minQueryLength else {
            // Reset to empty when the user clears or under-types. Avoid
            // a redundant @Published write if we're already empty.
            cancelActiveQuery()
            if !results.isEmpty { results = [] }
            return
        }

        let captured = trimmed
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.runQuery(captured)
        }
    }

    /// Synchronously cancel any in-flight query and clear results. Useful
    /// when the palette dismisses — no point having Spotlight churn for
    /// a panel that's not on screen.
    public func cancel() {
        debounceTask?.cancel()
        cancelActiveQuery()
        if !results.isEmpty { results = [] }
    }

    // MARK: - Predicate

    /// Construct the Spotlight predicate. Extracted so tests can verify
    /// the shape without firing a real Spotlight query.
    ///
    /// `LIKE[cd]` = case-insensitive + diacritic-insensitive wildcard match
    /// against the user-visible display name. We also exclude `.app`
    /// bundles — AppLauncherIndex already covers those, and doubling
    /// them up would split frecency between two ids for the same launch
    /// target.
    nonisolated public static func predicate(for query: String) -> NSPredicate {
        let wildcard = "*\(query)*"
        return NSPredicate(
            format: "(kMDItemDisplayName LIKE[cd] %@) AND (kMDItemContentTypeTree != %@)",
            wildcard, "com.apple.application-bundle"
        )
    }

    // MARK: - Execution

    private func runQuery(_ text: String) {
        cancelActiveQuery()

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = Self.predicate(for: text)
        q.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
        ]
        // We only want the initial gather; subsequent live updates would
        // mutate results behind the user's back.
        q.notificationBatchingInterval = 0.1

        // Don't capture `q` in the notification closure — pulling it
        // across the task hop trips Swift 6's Sendable check (NSMetadataQuery
        // is not Sendable). Reach for it via `self.query` from the
        // MainActor task body instead, where we know it's the same
        // instance because runQuery sets `query = q` immediately below.
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let active = self.query else { return }
                self.collectResults(from: active)
            }
        }
        q.start()
        query = q
        Logger.shared.log("FileSearch: started for '\(text)'")
    }

    private func collectResults(from q: NSMetadataQuery) {
        q.disableUpdates()
        defer { cancelActiveQuery() }

        let count = min(q.resultCount, limit)
        var collected: [Result] = []
        collected.reserveCapacity(count)

        for i in 0..<count {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }

            let displayName = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? URL(fileURLWithPath: path).lastPathComponent
            let kind = item.value(forAttribute: NSMetadataItemKindKey) as? String

            collected.append(Result(
                id: path,
                displayName: displayName,
                url: URL(fileURLWithPath: path),
                kind: kind
            ))
        }
        Logger.shared.log("FileSearch: \(collected.count) of \(q.resultCount) match shown")
        results = collected
    }

    private func cancelActiveQuery() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        query?.stop()
        query = nil
    }
}
