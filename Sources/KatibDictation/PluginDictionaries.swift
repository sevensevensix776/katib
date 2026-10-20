import Foundation
import KatibCore

/// The plugin layer of the correction engine: every plugin's dictionary,
/// merged in plugin order (by name). For each plugin the synced copy wins
/// over the file in its folder, so a plugin is never empty offline or before
/// its first sync. Merged UNDER learned terms and user corrections.
///
/// A plugin whose dictionary names a `syncURL` re-fetches it on launch
/// (throttled 6h per plugin) into
/// `~/Library/Application Support/Katib/PluginCache/<id>/dictionary.json`.
@MainActor
public final class PluginDictionaries {
    public static let shared = PluginDictionaries()

    private let throttleInterval: TimeInterval = 6 * 3600
    private let cacheRoot: URL
    private let registry: PluginRegistry

    private init() {
        registry = .shared
        cacheRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Katib/PluginCache", isDirectory: true)
    }

    /// All plugin dictionaries merged into one set.
    public func mergedSet() -> CorrectionSet {
        Self.merged(registry.plugins, cacheRoot: cacheRoot)
    }

    nonisolated static func merged(_ plugins: [Plugin], cacheRoot: URL) -> CorrectionSet {
        var out = CorrectionSet()
        for plugin in plugins {
            guard let set = load(plugin, cacheRoot: cacheRoot) else { continue }
            for (k, v) in set.replacements { out.replacements[k] = v }
            for (k, v) in set.dictionary { out.dictionary[k] = v }
            for (k, v) in set.phonetic { out.phonetic[k] = v }
        }
        return out
    }

    nonisolated static func load(_ plugin: Plugin, cacheRoot: URL) -> CorrectionSet? {
        guard let bundled = plugin.dictionaryFile else { return nil }
        var candidates = [bundled]
        // The synced copy counts only while it came from this plugin's
        // current syncURL: a replacement plugin with the same id, or one that
        // dropped its syncURL, must not inherit an old download.
        if let source = plugin.manifest.dictionary?.syncURL {
            let dir = cacheRoot.appendingPathComponent(plugin.id)
            let recorded = try? String(contentsOf: dir.appendingPathComponent("source"), encoding: .utf8)
            if recorded == source.absoluteString {
                candidates.insert(dir.appendingPathComponent("dictionary.json"), at: 0)
            }
        }
        for url in candidates {
            if let data = try? Data(contentsOf: url), let set = validated(data) { return set }
        }
        return nil
    }

    /// A dictionary file decodes only when it is a JSON object whose known
    /// buckets (replacements, dictionary, phonetic) are string-to-string maps
    /// and at least one is present. `CorrectionSet`'s own decoder accepts
    /// anything (an error body becomes an empty set), which would let a bad
    /// download replace a good cache with nothing.
    nonisolated static func validated(_ data: Data) -> CorrectionSet? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let buckets = ["replacements", "dictionary", "phonetic"]
        guard buckets.contains(where: { object[$0] != nil }),
              buckets.allSatisfy({ object[$0] == nil || object[$0] is [String: String] }) else { return nil }
        return try? JSONDecoder().decode(CorrectionSet.self, from: data)
    }

    public func sync(force: Bool = false) {
        for plugin in registry.plugins {
            guard let url = plugin.manifest.dictionary?.syncURL else { continue }
            let key = "pluginDictionaryLastSync.\(plugin.id)"
            let last = UserDefaults.standard.object(forKey: key) as? Date
            if !force, let last, Date().timeIntervalSince(last) < throttleInterval { continue }
            let target = cacheRoot.appendingPathComponent(plugin.id).appendingPathComponent("dictionary.json")
            Task { await Self.fetch(url, to: target, plugin: plugin.id, lastSyncKey: key) }
        }
    }

    private static func fetch(_ url: URL, to target: URL, plugin: String, lastSyncKey: String) async {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // A 404 body is HTML; check the status before decoding.
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                Logger.shared.log("Plugin \(plugin): dictionary sync returned HTTP \(http.statusCode), keeping the copy on disk")
                return
            }
            guard validated(data) != nil else {
                Logger.shared.log("Plugin \(plugin): dictionary sync returned no valid dictionary, keeping the copy on disk")
                return
            }
            let dir = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            try url.absoluteString.write(to: dir.appendingPathComponent("source"), atomically: true, encoding: .utf8)
            UserDefaults.standard.set(Date(), forKey: lastSyncKey)
            Logger.shared.log("Plugin \(plugin): dictionary synced (\(data.count) bytes)")
            NotificationCenter.default.post(name: .katibPluginsChanged, object: nil)
        } catch {
            Logger.shared.log("Plugin \(plugin): dictionary sync failed: \(error.localizedDescription), keeping the copy on disk")
        }
    }
}
