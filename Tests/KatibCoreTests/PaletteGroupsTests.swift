import XCTest
@testable import KatibCore

@MainActor
final class PaletteGroupsTests: XCTestCase {
    private func cmd(_ id: String, _ section: KatibCommand.Section) -> KatibCommand {
        KatibCommand(id: id, title: id, symbol: "circle", section: section) {}
    }

    func testRegistrySourcesKeepRelevanceOrderThenPluginsThenFiles() {
        let notes = PaletteSource.plugin(id: "notes", name: "Notes", color: nil)
        let wiki = PaletteSource.plugin(id: "wiki", name: "Wiki", color: "teal")
        let groups = PaletteGrouping.group(
            registry: [cmd("chrome", .app), cmd("split", .window), cmd("safari", .app), cmd("mic", .settings)],
            plugins: [PaletteGroup(source: notes, items: [cmd("doc", .plugin)]),
                      PaletteGroup(source: wiki, items: []),
                      PaletteGroup(source: .plugin(id: "x", name: "X", color: nil), items: [cmd("page", .plugin)])],
            files: [cmd("f", .file)])
        XCTAssertEqual(groups.map(\.source), [.apps, .commands, .settings, notes,
                                              .plugin(id: "x", name: "X", color: nil), .files])
        XCTAssertEqual(groups[0].items.map(\.id), ["chrome", "safari"])
    }

    func testEmptySourcesAreLeftOut() {
        let groups = PaletteGrouping.group(registry: [cmd("paste", .dictation)], plugins: [], files: [])
        XCTAssertEqual(groups.map(\.source), [.commands])
    }

    func testEveryKindOfCommandMapsToCommands() {
        for s in [KatibCommand.Section.general, .dictation, .clipboard, .screenshot, .window] {
            XCTAssertEqual(PaletteSource(s), .commands, s.rawValue)
        }
    }
}
