import XCTest
import AppKit
@testable import KatibWindow

final class SnapFrameTests: XCTestCase {
    // The 14" MacBook Pro numbers from 2026-10-06: macOS reported 86 pt of
    // Dock space at the bottom while the Dock auto-hid.
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 86, width: 1512, height: 863)

    func testAutoHiddenBottomDockGivesBackTheBottom() {
        let r = NSScreen.snapFrame(frame: frame, visible: visible, dockAutohides: true, dockEdge: .minY)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1512, height: 949))   // menu bar (33 pt) kept
    }

    func testPinnedDockKeepsVisibleFrame() {
        XCTAssertEqual(NSScreen.snapFrame(frame: frame, visible: visible, dockAutohides: false, dockEdge: .minY), visible)
    }

    func testAutoHiddenSideDocks() {
        let left = CGRect(x: 70, y: 0, width: 1442, height: 949)
        XCTAssertEqual(NSScreen.snapFrame(frame: frame, visible: left, dockAutohides: true, dockEdge: .minX),
                       CGRect(x: 0, y: 0, width: 1512, height: 949))
        let right = CGRect(x: 0, y: 0, width: 1442, height: 949)
        XCTAssertEqual(NSScreen.snapFrame(frame: frame, visible: right, dockAutohides: true, dockEdge: .maxX),
                       CGRect(x: 0, y: 0, width: 1512, height: 949))
    }
}
