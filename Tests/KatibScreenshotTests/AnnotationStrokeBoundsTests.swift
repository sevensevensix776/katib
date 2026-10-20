import XCTest
import SwiftUI
@testable import KatibScreenshot

/// Locks down `AnnotationStroke.visualBounds()` per tool. The exporter's
/// canvas-extension math depends on these returning a tight-but-correct
/// bounding rect for each shape — undersized = strokes get clipped at
/// save, oversized = needless white margin in the saved PNG.
final class AnnotationStrokeBoundsTests: XCTestCase {

    private func stroke(
        tool: AnnotationTool,
        start: CGPoint = CGPoint(x: 100, y: 100),
        end: CGPoint = CGPoint(x: 200, y: 200),
        thickness: CGFloat = 4,
        text: String = ""
    ) -> AnnotationStroke {
        AnnotationStroke(
            tool: tool,
            start: start,
            end: end,
            color: .red,
            thickness: thickness,
            text: text
        )
    }

    // MARK: - Arrow

    func testArrowBoundsExpandsBeyondRectForArrowhead() {
        // Arrow visualBounds insets by max(thickness*4, 18) on each side
        // to account for the arrowhead. At default thickness=4 the pad is
        // 18 (the floor wins over thickness*4=16).
        let s = stroke(tool: .arrow,
                       start: CGPoint(x: 100, y: 100),
                       end: CGPoint(x: 200, y: 200))
        let bounds = s.visualBounds()
        XCTAssertEqual(bounds.minX, 100 - 18)
        XCTAssertEqual(bounds.minY, 100 - 18)
        XCTAssertEqual(bounds.maxX, 200 + 18)
        XCTAssertEqual(bounds.maxY, 200 + 18)
    }

    func testArrowBoundsScalesWithThickness() {
        // At thickness=10, pad = max(40, 18) = 40.
        let s = stroke(tool: .arrow,
                       start: CGPoint(x: 100, y: 100),
                       end: CGPoint(x: 200, y: 200),
                       thickness: 10)
        let bounds = s.visualBounds()
        XCTAssertEqual(bounds.width, 100 + 80)
        XCTAssertEqual(bounds.height, 100 + 80)
    }

    // MARK: - Rectangle / Ellipse

    func testRectangleBoundsExpandsByHalfThickness() {
        // Rect visualBounds insets by -(thickness/2 + 2) so the stroke
        // line itself fits inside. At thickness=4, that's 4 each side.
        let s = stroke(tool: .rectangle, thickness: 4)
        let bounds = s.visualBounds()
        XCTAssertEqual(bounds.minX, 100 - 4)
        XCTAssertEqual(bounds.minY, 100 - 4)
        XCTAssertEqual(bounds.maxX, 200 + 4)
        XCTAssertEqual(bounds.maxY, 200 + 4)
    }

    func testEllipseBoundsMatchesRectangle() {
        let r = stroke(tool: .rectangle, thickness: 6).visualBounds()
        let e = stroke(tool: .ellipse, thickness: 6).visualBounds()
        XCTAssertEqual(r, e, "Rect/ellipse use identical bounding logic")
    }

    // MARK: - Highlight / Blur

    func testHighlightBoundsIsExactRect() {
        let s = stroke(tool: .highlight)
        XCTAssertEqual(s.visualBounds(), CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    func testBlurBoundsIsExactRect() {
        let s = stroke(tool: .blur)
        XCTAssertEqual(s.visualBounds(), CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    // MARK: - Number

    func testNumberBoundsCenteredOnStartWithToolSize() {
        // Numbered step circle is max(22, thickness*5) at default thickness=4.
        // 22 wins. Centered on `start`.
        let s = stroke(tool: .number, start: CGPoint(x: 500, y: 400))
        let bounds = s.visualBounds()
        XCTAssertEqual(bounds.origin.x, 500 - 11)
        XCTAssertEqual(bounds.origin.y, 400 - 11)
        XCTAssertEqual(bounds.width, 22)
        XCTAssertEqual(bounds.height, 22)
    }

    // MARK: - Text

    func testTextBoundsScalesWithCharacterCount() {
        // Empty text → 1 character of width still reserved (visualBounds
        // returns a sane minimum so empty strokes don't degenerate).
        let empty = stroke(tool: .text, text: "")
        let one = stroke(tool: .text, text: "a")
        let many = stroke(tool: .text, text: "the quick brown fox")

        XCTAssertGreaterThan(empty.visualBounds().width, 0)
        XCTAssertEqual(empty.visualBounds().width, one.visualBounds().width,
                       "Empty falls back to 1-char width for sane bounds")
        XCTAssertGreaterThan(many.visualBounds().width, one.visualBounds().width)
    }

    func testTextBoundsAnchorsAtStart() {
        let s = stroke(tool: .text, start: CGPoint(x: 250, y: 175), text: "hi")
        let bounds = s.visualBounds()
        XCTAssertEqual(bounds.origin.x, 250)
        XCTAssertEqual(bounds.origin.y, 175)
    }

    // MARK: - Select

    func testSelectToolReturnsZeroBounds() {
        // Select isn't a drawn stroke — visualBounds returns .zero so it
        // doesn't contribute to the export's expanded canvas math. This
        // test pins the contract; if someone later tries to use .select
        // as a real stroke type they'll get caught here.
        let s = stroke(tool: .select)
        XCTAssertEqual(s.visualBounds(), .zero)
    }
}
