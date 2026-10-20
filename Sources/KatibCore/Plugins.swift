import Foundation

/// A plugin is a folder holding a `plugin.json`. It adds to Katib without a
/// rebuild, in two ways:
///
/// - **search**: a command the ⌘Space palette runs with the query as its last
///   argument. It prints `{"items": [{"title", "subtitle", "url", "snippet"}]}`
///   and the hits appear under the plugin's own header.
/// - **dictionary**: a corrections file (same shape as `corrections.json`)
///   merged under the user's own corrections, optionally re-synced from a URL.
///
/// Plugins load from two folders, later wins on the same `id`:
///   1. `Katib.app/Contents/Resources/Plugins/` (an edition's bundled plugins)
///   2. `~/Library/Application Support/Katib/Plugins/` (the user's own)
///
/// Example `plugin.json`:
///
///     {
///       "id": "notes",
///       "name": "Notes",
///       "search": { "command": ["bin/search"], "minQueryLength": 3, "color": "purple" },
///       "dictionary": { "file": "dictionary.json", "syncURL": "https://example.com/dictionary.json" }
///     }
public struct PluginManifest: Decodable, Sendable, Equatable {
    public struct Search: Decodable, Sendable, Equatable {
        /// argv. A relative first element resolves against the plugin folder;
        /// `~/` expands to the home folder. Runs without a shell.
        public let command: [String]
        public let minQueryLength: Int?
        /// Seconds before a query is abandoned.
        public let timeout: Double?
        public let limit: Int?
        /// SF Symbol for the rows.
        public let symbol: String?
        /// Header dot: purple, pink, teal, orange, red, yellow, indigo, mint, cyan, brown.
        public let color: String?
    }

    public struct Dictionary: Decodable, Sendable, Equatable {
        /// Relative to the plugin folder.
        public let file: String
        public let syncURL: URL?
    }

    public let id: String
    public let name: String
    public let search: Search?
    public let dictionary: Dictionary?
}

public struct Plugin: Sendable, Identifiable, Equatable {
    public let manifest: PluginManifest
    public let folder: URL

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    /// The search argv with its executable resolved, or nil without a search.
    public var searchCommand: [String]? {
        guard let cmd = manifest.search?.command, let first = cmd.first, !first.isEmpty else { return nil }
        return [Self.resolve(first, in: folder)] + cmd.dropFirst()
    }

    public var dictionaryFile: URL? {
        manifest.dictionary.map { folder.appendingPathComponent($0.file) }
    }

    nonisolated static func resolve(_ path: String, in folder: URL) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return folder.appendingPathComponent(path).path
    }
}

@MainActor
public final class PluginRegistry: ObservableObject {
    public static let shared = PluginRegistry()

    @Published public private(set) var plugins: [Plugin] = []

    public static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Katib/Plugins", isDirectory: true)
    }

    public static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true)
    }

    public var searchPlugins: [Plugin] { plugins.filter { $0.searchCommand != nil } }

    private init() {
        try? FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        reload()
    }

    /// Re-reads both folders. Posts `.katibPluginsChanged` when the set
    /// changed, or always with `force` (a plugin's files changed in place,
    /// which the manifests alone cannot show).
    public func reload(force: Bool = false) {
        let loaded = Self.load(from: [Self.bundledFolder, Self.userFolder].compactMap { $0 })
        guard force || loaded != plugins else { return }
        plugins = loaded
        Logger.shared.log("Plugins: \(loaded.map { "\($0.id) (\($0.folder.path))" }.joined(separator: ", "))")
        NotificationCenter.default.post(name: .katibPluginsChanged, object: nil)
    }

    /// Every valid plugin in `folders`, sorted by name. A later folder's
    /// plugin replaces an earlier one with the same id. A broken manifest is
    /// logged and skipped, never fatal.
    nonisolated public static func load(from folders: [URL]) -> [Plugin] {
        var byID: [String: Plugin] = [:]
        let fm = FileManager.default
        for root in folders {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = folder.appendingPathComponent("plugin.json")
                guard let data = try? Data(contentsOf: file) else { continue }
                guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                    Logger.shared.log("Plugins: skipped \(file.path): not a valid plugin.json")
                    continue
                }
                // The id names cache folders and palette rows: keep it plain.
                guard manifest.id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
                    Logger.shared.log("Plugins: skipped \(file.path): id must be lowercase letters, digits and -")
                    continue
                }
                byID[manifest.id] = Plugin(manifest: manifest, folder: folder)
            }
        }
        return byID.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}
