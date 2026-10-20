import XCTest
import AppKit
@testable import KatibDictation

/// With several monitors the HUD must land on the screen under the cursor,
/// not NSScreen.main (the screen with the key window).
@MainActor
final class HUDPlacementTests: XCTestCase {
    func testHUDLandsOnTheScreenUnderTheCursor() throws {
        for screen in NSScreen.screens {
            let cursor = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            let origin = try XCTUnwrap(LiveIndicatorWindowController.restingOrigin(cursor: cursor))
            XCTAssertTrue(screen.frame.contains(origin), "cursor on \(screen.localizedName), HUD at \(origin)")
        }
    }
}
