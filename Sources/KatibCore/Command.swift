import Foundation
import SwiftUI

/// A typeable Katib action surfaced in the Command Palette, right-click menu,
/// Spotlight (via App Intents), and future voice-trigger mode.
///
/// Every feature module registers its commands at launch. The palette fuzzy-
/// searches the title + keywords and invokes `perform()` on Enter.
///
/// Kept in KatibCore so every feature module (Dictation, Clipboard, Screenshot,
/// future Window) can declare commands without importing the palette itself.
public struct KatibCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Free-text tokens the palette matches against. Don't repeat words already
    /// in `title` — add synonyms and phrases a voice user might say.
    public let keywords: [String]
    /// SF Symbol name rendered in the left gutter.
    public let symbol: String
    /// Optional file URL whose Finder/NSWorkspace icon overrides `symbol` in
    /// the palette row. Used for app-launcher commands so each app shows its
    /// real icon instead of a generic glyph. URL is Sendable; the actual
    /// NSImage resolution happens on MainActor at render time.
    public let iconFileURL: URL?
    /// Optional third line: why a search hit matched. Text inside [brackets]
    /// is drawn bold (the matched words). Used by plugin search rows.
    public let detail: String?
    /// Optional hint ("⌘,", "⌥⌘V", "voice: split left"). Rendered on the right.
    public let shortcutHint: String?
    /// Higher = appears earlier among ties. Defaults to 0.
    public let rank: Int
    /// Which feature owns this command. Used for the "Only in Dictation" etc.
    /// filter in the palette's right sidebar.
    public let section: Section
    /// Invoked on Enter / click. Always hops to MainActor.
    public let perform: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        symbol: String = "command",
        iconFileURL: URL? = nil,
        detail: String? = nil,
        shortcutHint: String? = nil,
        rank: Int = 0,
        section: Section = .general,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.symbol = symbol
        self.iconFileURL = iconFileURL
        self.detail = detail
        self.shortcutHint = shortcutHint
        self.rank = rank
        self.section = section
        self.perform = perform
    }

    public enum Section: String, CaseIterable, Sendable {
        case general
        case dictation
        case clipboard
        case screenshot
        case window
        case settings
        case app
        case plugin
        case file

        public var displayName: String {
            switch self {
            case .general: return "General"
            case .dictation: return "Dictation"
            case .clipboard: return "Clipboard"
            case .screenshot: return "Screenshot"
            case .window: return "Window"
            case .settings: return "Settings"
            case .app: return "App"
            case .plugin: return "Plugin"
            case .file: return "File"
            }
        }
    }

    /// Relevance score for a query. 0 = no match. Higher = better.
    ///
    /// Score = fuzzy(query, title) + fuzzy(query, keywords) + rank + frecency
    ///
    /// Fuzzy is the objc.io-style DP matcher with gap penalty + separator
    /// bonus + consecutive-run bonus. Keyword matches get a slight weight
    /// tax so title hits still outrank them. Frecency is pulled from
    /// FrecencyStore (use-count + recency).
    @MainActor
    public func score(against query: String) -> Int {
        let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return rank + 1 + FrecencyStore.shared.score(for: id) }

        let titleScore = FuzzyMatch.score(query: normalized, candidate: title)
        let keywordScore: Int = keywords
            .map { FuzzyMatch.score(query: normalized, candidate: $0) }
            .max() ?? 0
        let subtitleScore = subtitle.map { FuzzyMatch.score(query: normalized, candidate: $0) } ?? 0

        // Tax keyword + subtitle matches so they don't outrank a direct title hit.
        let raw = titleScore + (keywordScore * 70 / 100) + (subtitleScore * 40 / 100)
        guard raw > 0 else { return 0 }

        return raw + rank + FrecencyStore.shared.score(for: id)
    }
}
