import Foundation

/// How the ⌘Space palette groups its rows under headers. Pure, so the order
/// rules are tested without a window.
public enum PaletteSource: Hashable, Sendable {
    case commands, settings, apps, files
    /// A search plugin's hits, under its own name and color.
    case plugin(id: String, name: String, color: String?)

    public var title: String {
        switch self {
        case .commands: return "Commands"
        case .settings: return "Settings"
        case .apps: return "Apps"
        case .files: return "Files"
        case .plugin(_, let name, _): return name
        }
    }

    public init(_ section: KatibCommand.Section) {
        switch section {
        case .app: self = .apps
        case .settings: self = .settings
        case .file: self = .files
        // Plugin hits never come from the registry; they are grouped by
        // `PaletteGrouping.group(plugins:)` with their plugin's identity.
        default: self = .commands
        }
    }
}

public struct PaletteGroup: Sendable {
    public let source: PaletteSource
    public let items: [KatibCommand]

    public init(source: PaletteSource, items: [KatibCommand]) {
        self.source = source
        self.items = items
    }
}

public enum PaletteGrouping {
    /// Registry hits arrive ranked by relevance, so their groups keep the order
    /// in which each source first appears: typing "chrome" puts Apps first,
    /// "split" puts Commands first. Plugins and Files come after, because they
    /// arrive later (a subprocess, a Spotlight query) and must not reshuffle
    /// rows the user is already arrowing through. Plugins keep the order given.
    public static func group(registry: [KatibCommand], plugins: [PaletteGroup], files: [KatibCommand]) -> [PaletteGroup] {
        var order: [PaletteSource] = []
        var buckets: [PaletteSource: [KatibCommand]] = [:]
        for cmd in registry {
            let source = PaletteSource(cmd.section)
            if buckets[source] == nil { order.append(source) }
            buckets[source, default: []].append(cmd)
        }
        var groups = order.map { PaletteGroup(source: $0, items: buckets[$0] ?? []) }
        groups += plugins.filter { !$0.items.isEmpty }
        if !files.isEmpty { groups.append(PaletteGroup(source: .files, items: files)) }
        return groups
    }
}
