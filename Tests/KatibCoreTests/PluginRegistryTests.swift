import XCTest
@testable import KatibCore

final class PluginRegistryTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("katib-plugins-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ manifest: String, folder: String, in root: URL) throws {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    }

    /// Bundled first, then the user's folder: the user's copy of an id wins.
    func testUserPluginReplacesABundledOneWithTheSameID() throws {
        let bundled = root(), user = root()
        try write(#"{"id":"team","name":"Team","dictionary":{"file":"d.json"}}"#, folder: "team", in: bundled)
        try write(#"{"id":"notes","name":"Notes","search":{"command":["bin/s"]}}"#, folder: "notes", in: bundled)
        try write(#"{"id":"team","name":"Team (mine)","dictionary":{"file":"d.json"}}"#, folder: "t2", in: user)
        let plugins = PluginRegistry.load(from: [bundled, user])
        XCTAssertEqual(plugins.map(\.name), ["Notes", "Team (mine)"])
        // Paths compare by suffix: the directory listing reports /private/var.
        XCTAssertEqual(plugins[0].searchCommand?.count, 1)
        XCTAssertTrue(plugins[0].searchCommand![0].hasSuffix(bundled.lastPathComponent + "/notes/bin/s"))
        XCTAssertNil(plugins[1].searchCommand)
        XCTAssertTrue(plugins[1].dictionaryFile!.path.hasSuffix(user.lastPathComponent + "/t2/d.json"))
    }

    func testBrokenManifestsAndUnsafeIDsAreSkipped() throws {
        let r = root()
        try write("{ not json", folder: "a", in: r)
        try write(#"{"id":"../x","name":"Escape"}"#, folder: "b", in: r)
        try write(#"{"id":"ok","name":"OK"}"#, folder: "c", in: r)
        XCTAssertEqual(PluginRegistry.load(from: [r, root().appendingPathComponent("missing")]).map(\.id), ["ok"])
    }

    func testCommandPathsResolve() {
        let folder = URL(fileURLWithPath: "/p/notes")
        XCTAssertEqual(Plugin.resolve("/usr/bin/true", in: folder), "/usr/bin/true")
        XCTAssertEqual(Plugin.resolve("bin/s", in: folder), "/p/notes/bin/s")
        XCTAssertTrue(Plugin.resolve("~/x", in: folder).hasSuffix("/x"))
        XCTAssertFalse(Plugin.resolve("~/x", in: folder).contains("~"))
    }
}
