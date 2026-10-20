import Foundation
import AppKit
import KatibCore

/// JSON-backed CRUD over snippets. Mirrors `ClipboardManager`'s persistence
/// pattern: single file under `~/Library/Application Support/VoiceTools/`.
/// Observable so SwiftUI settings panes + the picker panel react to edits.
@MainActor
public final class SnippetStore: ObservableObject {
    public static let shared = SnippetStore()

    @Published public private(set) var snippets: [Snippet] = []

    private let storeURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("VoiceTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storeURL = folder.appendingPathComponent("snippets.json")
        loadFromDisk()
    }

    public func add(_ snippet: Snippet) {
        snippets.append(snippet)
        persist()
    }

    public func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        persist()
    }

    public func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    public func clear() {
        snippets = []
        persist()
    }

    /// Record usage — bumps `useCount` and `lastUsedAt` so the picker can sort
    /// by frecency and the expander can surface popular items.
    public func recordUsage(of id: UUID) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[idx].useCount += 1
        snippets[idx].lastUsedAt = Date()
        persist()
    }

    /// Items for the picker — newest-first, filtered by text match against
    /// name / trigger / content preview.
    public func visible(matching query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filter: (Snippet) -> Bool = { snippet in
            guard !q.isEmpty else { return true }
            return snippet.name.lowercased().contains(q)
                || snippet.trigger.lowercased().contains(q)
                || snippet.content.lowercased().contains(q)
        }
        return snippets
            .filter(filter)
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    /// Find a snippet whose trigger matches `candidate` exactly. Used by the
    /// text expander. Returns nil if no match or the trigger is empty.
    public func match(trigger: String) -> Snippet? {
        guard !trigger.isEmpty else { return nil }
        return snippets.first { !$0.trigger.isEmpty && $0.trigger == trigger }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return
        }
        snippets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
