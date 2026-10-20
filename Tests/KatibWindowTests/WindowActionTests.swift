import XCTest
@testable import KatibWindow

final class WindowActionTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    // MARK: - Halves

    func testLeftHalfCoversLeftHalfOfScreen() {
        let target = WindowAction.leftHalf.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target, CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testRightHalfCoversRightHalfOfScreen() {
        let target = WindowAction.rightHalf.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target, CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testTopHalf() {
        let target = WindowAction.topHalf.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target, CGRect(x: 0, y: 0, width: 1600, height: 500))
    }

    func testBottomHalf() {
        let target = WindowAction.bottomHalf.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target, CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    // MARK: - Quarters

    func testQuartersCoverExactlyOneQuarter() {
        let quarters: [WindowAction] = [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        for action in quarters {
            let frame = action.targetFrame(visibleFrame: screen, currentFrame: window)!
            XCTAssertEqual(frame.width, 800, "\(action) width")
            XCTAssertEqual(frame.height, 500, "\(action) height")
        }
    }

    func testTopLeftQuarterIsTopLeft() {
        let target = WindowAction.topLeftQuarter.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target.minX, 0)
        XCTAssertEqual(target.minY, 0)
    }

    // MARK: - Maximize + center + restore

    func testMaximizeFillsVisibleFrame() {
        let target = WindowAction.maximize.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target, screen)
    }

    func testAlmostMaximizeInsets() {
        let target = WindowAction.almostMaximize.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target.origin, CGPoint(x: 40, y: 40))
        XCTAssertEqual(target.size, CGSize(width: 1520, height: 920))
    }

    func testCenterPreservesCurrentSize() {
        let target = WindowAction.center.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertEqual(target.size, window.size)
        XCTAssertEqual(target.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(target.midY, screen.midY, accuracy: 0.001)
    }

    // MARK: - Display actions have no target frame

    func testDisplayActionsReturnNil() {
        XCTAssertNil(WindowAction.nextDisplay.targetFrame(visibleFrame: screen, currentFrame: window))
        XCTAssertNil(WindowAction.previousDisplay.targetFrame(visibleFrame: screen, currentFrame: window))
    }

    // MARK: - Grow / shrink

    func testLargerExpandsOutward() {
        let target = WindowAction.larger.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertGreaterThan(target.width, window.width)
        XCTAssertGreaterThan(target.height, window.height)
    }

    func testSmallerShrinksInward() {
        let target = WindowAction.smaller.targetFrame(visibleFrame: screen, currentFrame: window)!
        XCTAssertLessThan(target.width, window.width)
        XCTAssertLessThan(target.height, window.height)
    }

    func testLargerClampedToVisibleFrame() {
        let oversized = CGRect(x: -100, y: -100, width: 2000, height: 2000)
        let target = WindowAction.larger.targetFrame(visibleFrame: screen, currentFrame: oversized)!
        XCTAssertEqual(target.width, screen.width, accuracy: 0.001)
        XCTAssertEqual(target.height, screen.height, accuracy: 0.001)
    }

    // MARK: - Groups + metadata

    func testGroupsCoverAllActions() {
        let grouped = Set(WindowAction.allCases.map(\.group))
        XCTAssertTrue(grouped.contains(.halves))
        XCTAssertTrue(grouped.contains(.quarters))
        XCTAssertTrue(grouped.contains(.resize))
        XCTAssertTrue(grouped.contains(.display))
    }

    func testEveryActionHasSymbol() {
        for action in WindowAction.allCases {
            XCTAssertFalse(action.symbol.isEmpty, "\(action) missing symbol")
        }
    }
}
