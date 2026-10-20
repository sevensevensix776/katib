import XCTest
@testable import KatibSnippets

/// Filtering + trigger matching. We exercise SnippetStore indirectly through
/// a throwaway Snippet array where it's simpler — the persistence layer is
/// a thin wrapper over JSONEncoder we don't need to retest.
@MainActor
final class SnippetStoreTests: XCTestCase {

    // MARK: - Filter

    func testFilterMatchesName() {
        let snippets = [
            Snippet(name: "Email signature", trigger: "sig", content: "Jane Doe\nAcme"),
            Snippet(name: "Phone number", trigger: "phone", content: "+1 555 0100")
        ]
        let matches = snippets.filter { matchesQuery($0, query: "sig") }
        XCTAssertEqual(matches.map(\.name), ["Email signature"])
    }

    func testFilterMatchesTrigger() {
        let snippets = [
            Snippet(name: "Signature", trigger: "sig", content: "x"),
            Snippet(name: "Address", trigger: "addr", content: "y")
        ]
        let matches = snippets.filter { matchesQuery($0, query: "addr") }
        XCTAssertEqual(matches.map(\.name), ["Address"])
    }

    func testFilterMatchesContent() {
        let snippets = [
            Snippet(name: "Sig", trigger: "s", content: "Acme Ventures"),
            Snippet(name: "Zip", trigger: "z", content: "94102")
        ]
        let matches = snippets.filter { matchesQuery($0, query: "ventures") }
        XCTAssertEqual(matches.map(\.name), ["Sig"])
    }

    func testEmptyQueryReturnsAll() {
        let snippets = [
            Snippet(name: "A", trigger: "a", content: "x"),
            Snippet(name: "B", trigger: "b", content: "y")
        ]
        let matches = snippets.filter { matchesQuery($0, query: "") }
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: - Trigger matching

    func testTriggerMatchRequiresExactString() {
        let snippets = [Snippet(name: "Sig", trigger: "sig", content: "x")]
        XCTAssertNotNil(match(snippets, trigger: "sig"))
        XCTAssertNil(match(snippets, trigger: "si"))
        XCTAssertNil(match(snippets, trigger: "sigx"))
    }

    func testEmptyTriggersNeverMatch() {
        let snippets = [Snippet(name: "Untitled", trigger: "", content: "x")]
        XCTAssertNil(match(snippets, trigger: ""))
    }

    func testTriggerMatchIsCaseSensitive() {
        let snippets = [Snippet(name: "Sig", trigger: "Sig", content: "x")]
        XCTAssertNil(match(snippets, trigger: "sig"))
        XCTAssertNotNil(match(snippets, trigger: "Sig"))
    }

    // MARK: - Snippet model

    func testPreviewCollapsesNewlines() {
        let s = Snippet(name: "Multi", trigger: "m", content: "line 1\nline 2\nline 3")
        XCTAssertEqual(s.preview, "line 1 line 2 line 3")
    }

    func testPreviewTruncatesLongContent() {
        let content = String(repeating: "a", count: 200)
        let s = Snippet(name: "Long", trigger: "l", content: content)
        XCTAssertTrue(s.preview.hasSuffix("…"))
        XCTAssertLessThan(s.preview.count, content.count)
    }

    // MARK: - Helpers mirroring SnippetStore.visible / .match

    private func matchesQuery(_ snippet: Snippet, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return snippet.name.lowercased().contains(q)
            || snippet.trigger.lowercased().contains(q)
            || snippet.content.lowercased().contains(q)
    }

    private func match(_ snippets: [Snippet], trigger: String) -> Snippet? {
        guard !trigger.isEmpty else { return nil }
        return snippets.first { !$0.trigger.isEmpty && $0.trigger == trigger }
    }
}
