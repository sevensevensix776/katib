import XCTest
@testable import KatibWindow
import CoreGraphics

/// Pure tests for the drag-activation gate. The corresponding bug:
/// pre-2.0 Katib unsnapped on every mouseDown in the title-bar zone,
/// so clicking a Chrome tab shrank the window. The fix requires both
/// cursor movement AND window AX-origin movement before unsnapping.
final class DragActivationTests: XCTestCase {

    private let activation = DragActivation(
        cursorActivationThreshold: 5,
        windowMoveThreshold: 1
    )

    // MARK: - The bug we're guarding against

    func testPureClickDoesNotActivate() {
        // User clicks a Chrome tab and releases — no cursor movement, no
        // window movement. Must not unsnap.
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 0, windowDelta: 0))
    }

    func testTinyClickJitterDoesNotActivate() {
        // Real "clicks" almost always have 1-3pt of jitter from finger
        // pressure on the trackpad. Must stay below activation.
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 2, windowDelta: 0))
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 4.99, windowDelta: 0))
    }

    func testTabReorderDoesNotActivate() {
        // User drags a Chrome tab horizontally to reorder it. Cursor
        // moves a lot; the WINDOW doesn't. Must not unsnap.
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 200, windowDelta: 0))
    }

    func testInWindowResizeDoesNotActivate() {
        // User drags a Slack channel-list divider. Cursor moves; window
        // origin doesn't. Must not unsnap.
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 50, windowDelta: 0))
    }

    // MARK: - Real drags must activate

    func testRealWindowDragActivates() {
        XCTAssertTrue(activation.shouldActivate(cursorDelta: 8, windowDelta: 8))
        XCTAssertTrue(activation.shouldActivate(cursorDelta: 5, windowDelta: 1))
        XCTAssertTrue(activation.shouldActivate(cursorDelta: 100, windowDelta: 100))
    }

    func testCursorAtThresholdRequiresWindowMovement() {
        // Cursor exactly at threshold counts; window must also have
        // moved past its (smaller) threshold.
        XCTAssertTrue(activation.shouldActivate(cursorDelta: 5, windowDelta: 1))
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 5, windowDelta: 0.5))
    }

    // MARK: - Symmetry: window-only motion isn't a user drag either

    func testWindowMovedButCursorDidNotIsNotActivation() {
        // Defensive: if some other process moved the window between
        // mouseDown and mouseDragged but the user didn't actually move
        // the cursor, that's not a drag.
        XCTAssertFalse(activation.shouldActivate(cursorDelta: 0, windowDelta: 50))
    }
}
