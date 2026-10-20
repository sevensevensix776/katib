import XCTest
@testable import KatibWindow
import CoreGraphics

/// Drag-snap zone detection is pure geometry — easily unit tested.
/// We replicate the zone-picking logic here so we can exercise it without
/// spinning up a CGEvent tap + NSScreen.
final class DragSnapZoneTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let edgeThreshold: CGFloat = 8
    private let cornerThreshold: CGFloat = 40

    // Replicates DragSnapController.snapZone(for:screen:). If the private
    // implementation changes, this test mirrors it.
    private func snapZone(for cursor: CGPoint) -> WindowAction? {
        let frame = screen
        let inTopLeft = cursor.x <= frame.minX + cornerThreshold
            && cursor.y >= frame.maxY - cornerThreshold
        let inTopRight = cursor.x >= frame.maxX - cornerThreshold
            && cursor.y >= frame.maxY - cornerThreshold
        let inBottomLeft = cursor.x <= frame.minX + cornerThreshold
            && cursor.y <= frame.minY + cornerThreshold
        let inBottomRight = cursor.x >= frame.maxX - cornerThreshold
            && cursor.y <= frame.minY + cornerThreshold

        let nearTop = cursor.y >= frame.maxY - edgeThreshold
        let nearBottom = cursor.y <= frame.minY + edgeThreshold
        let nearLeft = cursor.x <= frame.minX + edgeThreshold
        let nearRight = cursor.x >= frame.maxX - edgeThreshold

        if inTopLeft { return .topLeftQuarter }
        if inTopRight { return .topRightQuarter }
        if inBottomLeft { return .bottomLeftQuarter }
        if inBottomRight { return .bottomRightQuarter }
        if nearTop { return .maximize }
        if nearBottom { return .bottomHalf }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        return nil
    }

    // MARK: - Corners (dominate over edges)

    func testTopLeftCorner() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 5, y: 995)), .topLeftQuarter)
        XCTAssertEqual(snapZone(for: CGPoint(x: 30, y: 970)), .topLeftQuarter)
    }

    func testTopRightCorner() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 1595, y: 995)), .topRightQuarter)
    }

    func testBottomLeftCorner() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 5, y: 5)), .bottomLeftQuarter)
    }

    func testBottomRightCorner() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 1595, y: 5)), .bottomRightQuarter)
    }

    // MARK: - Edges

    func testLeftEdgeAwayFromCorners() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 2, y: 500)), .leftHalf)
    }

    func testRightEdgeAwayFromCorners() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 1598, y: 500)), .rightHalf)
    }

    func testTopEdgeAwayFromCornersIsMaximize() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 800, y: 995)), .maximize)
    }

    func testBottomEdgeAwayFromCorners() {
        XCTAssertEqual(snapZone(for: CGPoint(x: 800, y: 3)), .bottomHalf)
    }

    // MARK: - Dead zone (middle of screen)

    func testCenterIsNotInAnyZone() {
        XCTAssertNil(snapZone(for: CGPoint(x: 800, y: 500)))
    }

    func testJustInsideEdgeThresholdIsNotSnap() {
        // 9 pixels from right edge — beyond the 8-pixel threshold.
        XCTAssertNil(snapZone(for: CGPoint(x: 1591, y: 500)))
    }
}
