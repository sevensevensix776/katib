import Foundation

/// Tracks how often and how recently each palette command has been invoked.
/// Alfred / Raycast call this pattern "frecency" — a blended frequency +
/// recency score — and it's the single thing that makes their palettes
/// feel smart instead of mechanical.
///
/// Persisted to UserDefaults as a single JSON blob. Per-command data is
/// small (count + last-used timestamp). At 100 commands with 500 uses each,
/// the blob is ~5 KB.
@MainActor
public final class FrecencyStore {
    public static let shared = FrecencyStore()

    private let defaultsKey = "katib.palette.frecency"
    private var data: [String: Entry] = [:]
    /// The `UserDefaults` instance this store reads/writes to. Swapped to
    /// an in-memory suite by `_useIsolatedTestStore()` so tests can call
    /// `clear()` / `touch()` without mutating the user's real defaults.
    private var store: UserDefaults = .standard

    public struct Entry: Codable {
        public var count: Int
        public var lastUsedAt: Date
    }

    private init() {
        load()
    }

    /// Record an invocation.
    public func touch(_ id: String) {
        var entry = data[id] ?? Entry(count: 0, lastUsedAt: Date(timeIntervalSince1970: 0))
        entry.count += 1
        entry.lastUsedAt = Date()
        data[id] = entry
        persist()
    }

    /// Boost score for a given command. Added to fuzzy score in the registry.
    ///
    /// Blend:
    ///   uses        → 5 * log(1 + count)       (logarithmic — 10 uses ≈ 5 * 2.4 = 12)
    ///   recency     → 100 * 2^(-Δt / 7 days)   (half-life every 7 days)
    ///
    /// A command used 10 times today gets +12 + 100 = +112; used 10 times a
    /// month ago gets +12 + ~6 = +18. Raw fuzzy score on a perfect prefix
    /// match for "split" on "Split Left" is ~160, so fresh use can push a
    /// weak fuzzy match up without drowning out strong ones.
    public func score(for id: String, now: Date = Date()) -> Int {
        guard let entry = data[id] else { return 0 }
        let days = now.timeIntervalSince(entry.lastUsedAt) / 86_400
        let halfLife = pow(2.0, -days / 7.0)
        let uses = log(1.0 + Double(entry.count))
        return Int(5.0 * uses + 100.0 * halfLife)
    }

    public func clear() {
        data = [:]
        persist()
    }

    /// TEST-ONLY: redirect persistence to an isolated in-memory defaults
    /// suite. Without this, `swift test` invocations running the
    /// `FrecencyStoreTests.setUp()` call to `clear()` wrote to the user's
    /// real `UserDefaults.standard`, silently erasing their real palette
    /// frecency data on every build. Same lesson as ClipboardManager.
    // swiftlint:disable:next identifier_name
    public func _useIsolatedTestStore() {
        store = UserDefaults(suiteName: "KatibTests-\(UUID().uuidString)") ?? .standard
        data = [:]
    }

    // MARK: - Persistence

    private func load() {
        guard let raw = store.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) else {
            return
        }
        data = decoded
    }

    private func persist() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        store.set(raw, forKey: defaultsKey)
    }
}
