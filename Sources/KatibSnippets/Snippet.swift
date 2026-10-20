import Foundation

/// A text snippet the user has saved. Triggered either manually from the
/// picker panel (`⌃⌘Space` by default) or automatically by typing `trigger`
/// when the expander is enabled.
///
/// Triggers are typically prefixed (`;sig`, `//email`) so they don't fire
/// mid-word. Prefix character is configurable in `AppSettings`.
public struct Snippet: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    /// Literal trigger string the user types (without the prefix). Matching
    /// is case-sensitive. Empty means "no auto-expansion — picker only".
    public var trigger: String
    /// Expansion content. Plain text for v1; rich text (RTF) is a future
    /// migration target — Alfred stores both.
    public var content: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        trigger: String,
        content: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.content = content
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    public var preview: String {
        let single = content.replacingOccurrences(of: "\n", with: " ")
        return single.count > 80 ? String(single.prefix(80)) + "…" : single
    }
}
