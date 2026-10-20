import XCTest
@testable import KatibWindow

/// `WindowManager.isSnapAction` decides whether an action marks the window
/// as "snapped" for later drag-to-unsnap. Resize-only and navigation-only
/// actions don't count.
@MainActor
final class IsSnapActionTests: XCTestCase {

    func testHalfAndQuarterActionsAreSnaps() {
        let snaps: [WindowAction] = [
            .maximize, .almostMaximize,
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter
        ]
        for action in snaps {
            XCTAssertTrue(
                WindowManager.isSnapAction(action),
                "Expected \(action) to count as a snap"
            )
        }
    }

    func testResizeAndNavigationActionsAreNotSnaps() {
        let nonSnaps: [WindowAction] = [
            .larger, .smaller, .restore, .center, .nextDisplay, .previousDisplay
        ]
        for action in nonSnaps {
            XCTAssertFalse(
                WindowManager.isSnapAction(action),
                "Expected \(action) NOT to count as a snap"
            )
        }
    }
}
