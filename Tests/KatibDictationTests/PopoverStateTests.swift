import XCTest
@testable import KatibDictation
import KatibCore

@MainActor
final class PopoverStateTests: XCTestCase {

    override func setUp() async throws {
        // Shared singleton — reset between tests.
        PopoverState.shared.clearRecent()
    }

    func testPushRecentSetsLastTranscription() {
        let state = PopoverState.shared
        state.pushRecent("hello")
        XCTAssertEqual(state.lastTranscription, "hello")
    }

    func testPushRecentOrderIsNewestFirst() {
        let state = PopoverState.shared
        state.pushRecent("first")
        state.pushRecent("second")
        state.pushRecent("third")
        XCTAssertEqual(state.recent, ["third", "second", "first"])
    }

    func testPushRecentDedupesByMovingToTop() {
        let state = PopoverState.shared
        state.pushRecent("apple")
        state.pushRecent("banana")
        state.pushRecent("apple")  // duplicate of first entry
        XCTAssertEqual(state.recent, ["apple", "banana"])
        XCTAssertEqual(state.lastTranscription, "apple")
    }

    func testPushRecentCapsAtFive() {
        let state = PopoverState.shared
        for i in 1...10 {
            state.pushRecent("entry \(i)")
        }
        XCTAssertEqual(state.recent.count, 5)
        XCTAssertEqual(state.recent.first, "entry 10")
        XCTAssertEqual(state.recent.last, "entry 6")
    }

    func testClearRecentWipesEverything() {
        let state = PopoverState.shared
        state.pushRecent("x")
        state.pushRecent("y")
        state.clearRecent()
        XCTAssertTrue(state.recent.isEmpty)
        XCTAssertNil(state.lastTranscription)
    }
}
