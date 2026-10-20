import XCTest
@testable import KatibCore

@MainActor
final class FrecencyStoreTests: XCTestCase {

    override func setUp() async throws {
        // Isolate to a temp UserDefaults suite. Without this, `clear()`
        // persists an empty dict to the user's real UserDefaults.standard
        // on every `swift test` run — wiping real palette frecency data.
        FrecencyStore.shared._useIsolatedTestStore()
    }

    func testEmptyStoreReturnsZero() {
        XCTAssertEqual(FrecencyStore.shared.score(for: "unused"), 0)
    }

    func testTouchIncrementsScore() {
        FrecencyStore.shared.touch("cmd.a")
        XCTAssertGreaterThan(FrecencyStore.shared.score(for: "cmd.a"), 0)
    }

    func testRecentlyUsedCommandOutranksOlderOne() async {
        FrecencyStore.shared.touch("cmd.recent")
        // Simulate an old entry by requesting a score at a point in the
        // future — equivalent to aging "cmd.recent" by that many days.
        let recentNow = FrecencyStore.shared.score(for: "cmd.recent", now: Date())
        let recentIn30Days = FrecencyStore.shared.score(
            for: "cmd.recent",
            now: Date().addingTimeInterval(30 * 86_400)
        )
        XCTAssertGreaterThan(recentNow, recentIn30Days)
    }

    func testHigherUseCountScoresHigher() {
        FrecencyStore.shared.touch("cmd.once")
        for _ in 0..<20 { FrecencyStore.shared.touch("cmd.many") }
        XCTAssertGreaterThan(
            FrecencyStore.shared.score(for: "cmd.many"),
            FrecencyStore.shared.score(for: "cmd.once")
        )
    }

    func testClearResetsStore() {
        FrecencyStore.shared.touch("cmd.a")
        FrecencyStore.shared.touch("cmd.b")
        FrecencyStore.shared.clear()
        XCTAssertEqual(FrecencyStore.shared.score(for: "cmd.a"), 0)
        XCTAssertEqual(FrecencyStore.shared.score(for: "cmd.b"), 0)
    }
}
