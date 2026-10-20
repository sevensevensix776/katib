import XCTest
@testable import KatibCore

@MainActor
final class CommandRegistryTests: XCTestCase {

    override func setUp() async throws {
        // Registry is a singleton — wipe + re-seed each test so state doesn't leak.
        for id in CommandRegistry.shared.commands.map(\.id) {
            CommandRegistry.shared.unregister(id: id)
        }
        FrecencyStore.shared.clear()
    }

    private func makeCommand(id: String, title: String, keywords: [String] = [], subtitle: String? = nil, section: KatibCommand.Section = .general) -> KatibCommand {
        KatibCommand(
            id: id,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            section: section
        ) {}
    }

    // MARK: - Registration

    func testRegisterAdds() {
        CommandRegistry.shared.register(makeCommand(id: "a", title: "Alpha"))
        XCTAssertEqual(CommandRegistry.shared.commands.count, 1)
    }

    func testRegisterSameIdReplaces() {
        CommandRegistry.shared.register(makeCommand(id: "a", title: "Alpha"))
        CommandRegistry.shared.register(makeCommand(id: "a", title: "Alpha v2"))
        XCTAssertEqual(CommandRegistry.shared.commands.count, 1)
        XCTAssertEqual(CommandRegistry.shared.commands.first?.title, "Alpha v2")
    }

    func testUnregisterRemoves() {
        CommandRegistry.shared.register(makeCommand(id: "a", title: "Alpha"))
        CommandRegistry.shared.unregister(id: "a")
        XCTAssertTrue(CommandRegistry.shared.commands.isEmpty)
    }

    // MARK: - Empty-query ordering

    func testEmptyQueryGroupsBySection() {
        CommandRegistry.shared.register([
            makeCommand(id: "z", title: "Zebra", section: .window),
            makeCommand(id: "a", title: "Alpha", section: .general),
            makeCommand(id: "b", title: "Bravo", section: .dictation)
        ])
        let results = CommandRegistry.shared.search("")
        let sections = results.map(\.section)
        // .clipboard < .dictation < .general < .screenshot < .settings < .window by rawValue sort
        XCTAssertEqual(sections.first, .dictation) // dictation < general alphabetically
    }

    // MARK: - Fuzzy + frecency

    func testSearchReturnsFuzzyRankedResults() {
        CommandRegistry.shared.register([
            makeCommand(id: "max", title: "Maximize"),
            makeCommand(id: "dict", title: "Dictate"),
            makeCommand(id: "mirror", title: "Mirror window", keywords: ["max"])
        ])
        let results = CommandRegistry.shared.search("max")
        XCTAssertEqual(results.first?.id, "max", "Direct title match should win")
    }

    func testFrecencyBoostsRecentlyUsedCommand() {
        CommandRegistry.shared.register([
            makeCommand(id: "split.left", title: "Split left"),
            makeCommand(id: "split.right", title: "Split right")
        ])
        // Mark left as recently used many times.
        for _ in 0..<10 { FrecencyStore.shared.touch("split.left") }
        let results = CommandRegistry.shared.search("split")
        XCTAssertEqual(results.first?.id, "split.left",
                       "Frecent command should outrank an equivalent-fuzzy-match peer")
    }

    func testLimitTruncatesResults() {
        for idx in 0..<20 {
            CommandRegistry.shared.register(makeCommand(id: "\(idx)", title: "Item \(idx)"))
        }
        XCTAssertEqual(CommandRegistry.shared.search("", limit: 5).count, 5)
    }
}
