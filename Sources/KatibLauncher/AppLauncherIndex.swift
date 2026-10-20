import AppKit
import Foundation
import KatibCore

/// Discovers `.app` bundles on disk and re-scans when the watched
/// directories change. Powers the Spotlight/Alfred-style app-launcher
/// rows in the Command Palette.
///
/// Scope is intentionally narrow: top-level `.app` bundles in the standard
/// install locations. Apple's Spotlight indexes deeper, but the long tail
/// is overwhelmingly noise (frameworks' embedded helpers, dev tools' XPC
/// services). Limiting to top-level apps matches Alfred's default and
/// keeps the registry under ~300 commands on a typical Mac.
@MainActor
public final class AppLauncherIndex {
    public static let shared = AppLauncherIndex()

    public struct Entry: Sendable, Equatable {
        /// CFBundleIdentifier when present, else the URL path. Stable
        /// across renames so frecency score persists.
        public let id: String
        /// CFBundleDisplayName ?? CFBundleName ?? filename minus `.app`.
        public let name: String
        public let url: URL

        public init(id: String, name: String, url: URL) {
            self.id = id
            self.name = name
            self.url = url
        }
    }

    /// Standard macOS app install locations. `~/Applications` exists for
    /// users who keep personal apps separate; harmless if absent — `scan`
    /// silently skips unreadable roots.
    ///
    /// `/System/Library/CoreServices` is where Apple keeps Finder, Apple
    /// Diagnostics, Installer, Screen Time, etc. — apps users absolutely
    /// expect to find in a launcher but that don't live in /Applications.
    /// It also holds dozens of system helpers (BluetoothUIServer,
    /// CoreLocationAgent…) we don't want polluting the palette; those
    /// are filtered out by `isUserFacing` because they declare
    /// `LSUIElement` or `LSBackgroundOnly`.
    public static let defaultRoots: [URL] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }()

    /// Roots where every `.app` we encounter must clear an LSUIElement /
    /// LSBackgroundOnly filter before being indexed. CoreServices is the
    /// canonical case: it holds Finder alongside ~70 background helpers.
    /// /Applications is intentionally NOT here — plenty of legitimate
    /// menu-bar apps (Bartender, Hammerspoon, Things, Katib itself) set
    /// LSUIElement = true and should still appear.
    /// `nonisolated` so the static `scan(roots:)` method (also nonisolated)
    /// can read it without a hop to the main actor.
    nonisolated private static let filteredRoots: Set<String> = [
        "/System/Library/CoreServices"
    ]

    private let roots: [URL]
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    public private(set) var entries: [Entry] = []

    /// Called on the main actor whenever `entries` changes.
    public var onChange: (([Entry]) -> Void)?

    public init(roots: [URL] = AppLauncherIndex.defaultRoots) {
        self.roots = roots
    }

    deinit {
        for w in watchers { w.cancel() }
    }

    public func start() {
        rescan()
        installWatchers()
    }

    /// Manual rescan — exposed so tests / debug menu items can force a refresh.
    public func refresh() {
        rescan()
    }

    /// Pure-ish: enumerates `.app` bundles in `roots` and reads their
    /// metadata. Synchronous; runs in ~50ms for a typical Mac. Static
    /// so tests can hit a fixture directory without a watcher.
    ///
    /// Robustness:
    /// - Roots that don't exist or can't be read are silently skipped.
    /// - `.app` bundles missing Info.plist still produce an Entry with
    ///   the filename as `name` and the path as `id`.
    /// - Duplicate bundle IDs across roots: first-seen wins. Roots are
    ///   ordered so /Applications takes priority over $HOME/Applications.
    public nonisolated static func scan(roots: [URL]) -> [Entry] {
        let fm = FileManager.default
        var seenIDs = Set<String>()
        var entries: [Entry] = []

        for root in roots {
            // Use the path-based listing, not the URL one. The URL-based
            // `contentsOfDirectory(at:includingPropertiesForKeys:options:)`
            // silently drops symlinks that resolve across volumes — which
            // means it skips `/Applications/Safari.app` on macOS 26+, where
            // Safari is a symlink into a cryptex
            // (`/System/Cryptexes/App/System/Applications/Safari.app`).
            // Empirically reproduced: the string version returns Safari,
            // the URL version returns 95 apps and quietly omits it. Both
            // skip hidden files; .skipsPackageDescendants doesn't apply
            // here because we don't recurse.
            let filenames: [String]
            do {
                filenames = try fm.contentsOfDirectory(atPath: root.path)
            } catch {
                // Missing dir / no read permission. Normal for ~/Applications.
                continue
            }

            let mustFilter = Self.filteredRoots.contains(root.path)
            for filename in filenames where filename.hasSuffix(".app") && !filename.hasPrefix(".") {
                let url = root.appendingPathComponent(filename)
                guard let entry = readEntry(at: url) else { continue }
                if mustFilter && !Self.isUserFacing(at: url) { continue }
                guard seenIDs.insert(entry.id).inserted else { continue }
                entries.append(entry)
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Read display-name + bundle-id from an `.app` bundle's Info.plist.
    /// Falls back gracefully when the plist is missing or unreadable —
    /// some hand-built or stub apps simply don't have one.
    /// True when the bundle is launchable + user-facing. Apple's helper
    /// pattern is `LSUIElement = true` (agent — no Dock icon) or
    /// `LSBackgroundOnly = true` (daemon — never shows UI). Either
    /// marker means "not a thing the user opens by name." Both plist
    /// values can be `1`, `true`, `YES`, or the string variants;
    /// NSDictionary already canonicalises them to NSNumber, so a simple
    /// `boolValue` works.
    public nonisolated static func isUserFacing(at appURL: URL) -> Bool {
        let plistURL = appURL
            .resolvingSymlinksInPath()
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return true   // missing plist → trust the .app extension (matches readEntry's behavior)
        }
        let ui = (info["LSUIElement"] as? NSNumber)?.boolValue ?? false
        let bg = (info["LSBackgroundOnly"] as? NSNumber)?.boolValue ?? false
        return !ui && !bg
    }

    public nonisolated static func readEntry(at appURL: URL) -> Entry? {
        // Cheap sanity check: must be a directory ending in `.app`. We
        // already filter `.app` extensions in `scan` but trust nothing —
        // someone could symlink a regular file into /Applications.
        //
        // Resolve symlinks before asking — `.isDirectoryKey` on a symlink
        // reports false even when the target is a directory. That alone
        // would skip /Applications/Safari.app on macOS 26+ (Safari is a
        // symlink into a cryptex volume).
        let resolved = appURL.resolvingSymlinksInPath()
        let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else { return nil }

        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: plistURL) as? [String: Any]

        let displayName = (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bundleName  = (info?["CFBundleName"]        as? String).flatMap { $0.isEmpty ? nil : $0 }
        let filename = appURL.deletingPathExtension().lastPathComponent
        let name = displayName ?? bundleName ?? filename

        let bundleID = (info?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return Entry(id: bundleID ?? appURL.path, name: name, url: appURL)
    }

    private func rescan() {
        let start = Date()
        let fresh = Self.scan(roots: roots)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        guard fresh != entries else {
            Logger.shared.log("AppLauncher: rescan unchanged (\(fresh.count) apps, \(elapsedMs)ms)")
            return
        }
        let delta = fresh.count - entries.count
        let sign = delta >= 0 ? "+" : ""
        Logger.shared.log("AppLauncher: rescan \(entries.count) → \(fresh.count) apps (\(sign)\(delta), \(elapsedMs)ms)")
        entries = fresh
        onChange?(fresh)
    }

    /// Watches each root via DispatchSource for write/rename events. We
    /// only get notified on direct children, which is exactly what we
    /// want — installing a new app drops a new `.app` bundle into one
    /// of these directories.
    private func installWatchers() {
        for root in roots {
            let fd = open(root.path, O_EVTONLY)
            guard fd >= 0 else {
                // Missing dirs (typically ~/Applications) are normal —
                // already handled gracefully by `scan`. Skip silently.
                continue
            }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            src.setEventHandler { [weak self] in self?.scheduleRescan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
        Logger.shared.log("AppLauncher: watching \(watchers.count) of \(roots.count) roots")
    }

    /// Coalesce bursts of FS events (an installer drops dozens of files
    /// during a single update) into one rescan a beat later.
    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }
}
