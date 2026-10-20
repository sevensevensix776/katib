import XCTest
@testable import KatibWindow
import AppKit

/// `BorderingEdges` logic is pure geometry on CGRects. We stub NSScreen by
/// subclassing it (we can't construct real NSScreens in unit tests) and test
/// the edge-detection math through a test-only helper that takes raw frames.
final class BorderingEdgesTests: XCTestCase {

    // Mirror of DragSnapController.borderingEdges(of:among:) but operating on
    // raw CGRects so we can unit-test without real NSScreens. The screen code
    // uses this same geometry.
    private func borderingEdges(of screen: CGRect, among all: [CGRect]) -> DragSnapController.BorderingEdges {
        var result: DragSnapController.BorderingEdges = []
        for other in all where other != screen {
            if abs(screen.maxX - other.minX) < 1 && verticalOverlap(screen, other) > 0 {
                result.insert(.right)
            }
            if abs(screen.minX - other.maxX) < 1 && verticalOverlap(screen, other) > 0 {
                result.insert(.left)
            }
            if abs(screen.maxY - other.minY) < 1 && horizontalOverlap(screen, other) > 0 {
                result.insert(.top)
            }
            if abs(screen.minY - other.maxY) < 1 && horizontalOverlap(screen, other) > 0 {
                result.insert(.bottom)
            }
        }
        return result
    }

    private func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    // MARK: - Solo display

    func testSingleScreenHasNoBorderingEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(borderingEdges(of: screen, among: [screen]), [])
    }

    // MARK: - Horizontal arrangement

    func testScreenToTheRightMarksRightEdge() {
        // Primary on left, second display abutting its right edge.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(borderingEdges(of: primary, among: [primary, secondary]), [.right])
        XCTAssertEqual(borderingEdges(of: secondary, among: [primary, secondary]), [.left])
    }

    // MARK: - Vertical arrangement

    func testScreenAboveMarksTopEdge() {
        // NSScreen y grows upward — "above" means higher y.
        let bottom = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let top = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        XCTAssertEqual(borderingEdges(of: bottom, among: [bottom, top]), [.top])
        XCTAssertEqual(borderingEdges(of: top, among: [bottom, top]), [.bottom])
    }

    // MARK: - Perpendicular overlap required

    func testTouchingOnlyAtCornerDoesNotCount() {
        // Two screens that only share a single point — no perpendicular overlap,
        // so this shouldn't mark either edge as bordering.
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let diagonal = CGRect(x: 1000, y: 1000, width: 1000, height: 1000)
        XCTAssertEqual(borderingEdges(of: primary, among: [primary, diagonal]), [])
    }

    // MARK: - Non-touching screens

    func testScreensWithGapAreNotBordering() {
        // Users with non-contiguous display arrangements.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let faraway = CGRect(x: 3000, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(borderingEdges(of: primary, among: [primary, faraway]), [])
    }

    // MARK: - Three-display configurations

    func testPrimaryBetweenTwoScreensMarksBothEdges() {
        // Two external displays flanking the primary.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            borderingEdges(of: primary, among: [left, primary, right]),
            [.left, .right]
        )
    }

    func testScreenWithNeighborsOnTopAndRightMarksBothEdges() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let top = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            borderingEdges(of: primary, among: [primary, top, right]),
            [.top, .right]
        )
    }

    // MARK: - Partial overlap on perpendicular axis

    func testOffsetVerticalOverlapStillCounts() {
        // Adjacent displays where the secondary is shifted down — they still
        // share an edge along a non-zero portion of their vertical extent.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: -300, width: 1920, height: 1080)
        XCTAssertEqual(borderingEdges(of: primary, among: [primary, secondary]), [.right])
    }
}
