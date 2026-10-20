import Foundation

/// Checks GitHub raw for a `latest.json` describing the current shipped version.
/// Throttled to 6h. Exposes `available` as @Published so the popover can bind.
/// `isNewer` is internal-scope so the test target can exercise it directly
/// without reflection tricks.
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    @Published public var available: Bool = false
    @Published public var latestVersion: String?
    @Published public var latestURL: URL?
    @Published public var latestNotes: String?

    /// Where to fetch `latest.json` from, first match wins: the UserDefaults
    /// key `updateManifestURL` (repoint one Mac without a rebuild), the
    /// edition's `KatibUpdateManifestURL`, then the public repo.
    private let manifestURL: URL = {
        let defaultURL = URL(string: "https://raw.githubusercontent.com/sevensevensix776/katib/master/latest.json")!
        if let override = UserDefaults.standard.string(forKey: "updateManifestURL"), let url = URL(string: override) {
            return url
        }
        return Edition.updateManifestURL ?? defaultURL
    }()
    private let throttleInterval: TimeInterval = 6 * 3600
    private var lastCheck: Date?

    private init() {}

    public func check(force: Bool = false) {
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < throttleInterval {
            return
        }
        lastCheck = Date()
        Task { [weak self] in
            guard let self else { return }
            await self.fetch()
        }
    }

    private func fetch() async {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // GitHub raw on a private repo returns an HTML 404 page rather
            // than a parseable JSON error. Short-circuit on status so we
            // don't shove "Unexpected character ':' around line 1 column 4"
            // into the logs on every launch.
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                Logger.shared.log("Update check: manifest returned HTTP \(http.statusCode) — skipping")
                return
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            if Self.isNewer(manifest.version, than: current) {
                self.latestVersion = manifest.version
                self.latestURL = URL(string: manifest.url)
                self.latestNotes = manifest.notes
                self.available = true
                Logger.shared.log("Update available: \(manifest.version) (running \(current))")
            } else {
                self.available = false
            }
        } catch {
            // Network / DNS / offline — one line, not a stack trace.
            Logger.shared.log("Update check: \(error.localizedDescription)")
        }
    }

    /// Semver-ish comparison: "1.4.0" > "1.3.1" > "1.3.0". Internal so tests
    /// can import and exercise it without duplicating logic.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private struct Manifest: Decodable {
        let version: String
        let url: String
        let notes: String?
    }
}
