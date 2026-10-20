import XCTest
import KatibCore
@testable import KatibLauncher

final class PluginSearchTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParseNeedsATitleAndReadsEveryURLForm() throws {
        let r = try XCTUnwrap(PluginSearch.parse(json("""
        {"items":[
          {"title":"Web","url":"https://example.com/a","snippet":"a   [match]  here"},
          {"subtitle":"no title, skipped"},
          {"title":"File","url":"/tmp/notes.md"},
          {"title":"Bad url","url":"not a url"}
        ]}
        """), limit: 10))
        XCTAssertEqual(r.map(\.title), ["Web", "File", "Bad url"])
        XCTAssertEqual(r[0].url?.absoluteString, "https://example.com/a")
        XCTAssertEqual(r[0].snippet, "a [match] here")
        XCTAssertEqual(r[1].url, URL(fileURLWithPath: "/tmp/notes.md"))
        XCTAssertNil(r[2].url)
    }

    func testParseRespectsLimitAndRejectsGarbage() {
        let many = (0..<9).map { #"{"title":"t\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(PluginSearch.parse(json(#"{"items":[\#(many)]}"#), limit: 3)?.count, 3)
        XCTAssertEqual(PluginSearch.parse(json(#"{"items":[]}"#), limit: 3)?.count, 0)
        XCTAssertNil(PluginSearch.parse(json("not json"), limit: 3))
        XCTAssertNil(PluginSearch.parse(json(#"{"hits":[]}"#), limit: 3))
    }

    /// A plugin folder holding `bin/search` (a shell script) and a manifest.
    private func plugin(_ id: String, script: String?, timeout: Double = 6) throws -> Plugin {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katib-plugin-\(UUID().uuidString)/\(id)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        if let script {
            let exe = folder.appendingPathComponent("bin/search")
            try ("#!/bin/sh\n" + script).write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        try #"{"id":"\#(id)","name":"Test","search":{"command":["bin/search","--json"],"timeout":\#(timeout)}}"#
            .write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginRegistry.load(from: [folder.deletingLastPathComponent()]).first)
    }

    @MainActor
    private func settle(_ search: PluginSearch) async throws {
        for _ in 0..<100 where !search.searching.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The command gets its own args, then the query as the last argument.
    @MainActor
    func testRunsThePluginWithTheQueryLast() async throws {
        let p = try plugin("echo", script: #"printf '{"items":[{"title":"%s|%s"}]}' "$1" "$2""#)
        let search = PluginSearch(plugins: [p], debounce: .milliseconds(1))
        search.search("hello world")
        XCTAssertEqual(search.searching, ["echo"])
        try await settle(search)
        XCTAssertEqual(search.results["echo"]?.map(\.title), ["--json|hello world"])
        XCTAssertNil(search.failures["echo"])
    }

    /// A plugin whose executable is missing is not a feature on this Mac:
    /// no "searching…" header and no error row.
    @MainActor
    func testMissingExecutableShowsNothingAtAll() async throws {
        let search = PluginSearch(plugins: [try plugin("gone", script: nil)], debounce: .milliseconds(1))
        search.search("hello")
        XCTAssertTrue(search.searching.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertTrue(search.failures.isEmpty)
    }

    @MainActor
    func testAFailingPluginSaysWhyInsteadOfLookingEmpty() async throws {
        let search = PluginSearch(plugins: [try plugin("boom", script: "exit 3")], debounce: .milliseconds(1))
        search.search("hello")
        try await settle(search)
        XCTAssertEqual(search.failures["boom"], "search failed (exit 3)")
        XCTAssertNil(search.results["boom"])
    }

    /// Broken output must say so, not look like "no matches".
    @MainActor
    func testUnreadableOutputIsAFailureNotAnEmptyResult() async throws {
        let search = PluginSearch(plugins: [try plugin("junk", script: "echo hello")], debounce: .milliseconds(1))
        search.search("hello")
        try await settle(search)
        XCTAssertEqual(search.failures["junk"], "returned output Katib could not read")
    }

    /// A command that ignores SIGTERM and keeps stdout open is killed, and
    /// Katib stops waiting: the timeout bounds the search.
    func testTimeoutBoundsACommandThatIgnoresTerm() async throws {
        let p = try plugin("stuck", script: "trap '' TERM\nsleep 30 &\nwait\nsleep 30")
        let started = Date()
        let outcome = await PluginSearch.run(try XCTUnwrap(p.searchCommand) + ["q"], timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard case .failed(let why) = outcome else { return XCTFail("expected a timeout") }
        XCTAssertEqual(why, "took longer than 0 s")
    }
}
