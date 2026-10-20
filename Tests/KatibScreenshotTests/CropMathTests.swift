import XCTest
@testable import KatibScreenshot

/// Locks down the pure crop math that converts a user selection (in logical
/// points, display-local y-DOWN) into the pixel-space crop rect applied to
/// the captured CGImage.
///
/// Every "capture didn't respect the bounds" bug we've shipped has lived
/// either in this math or in the scale computation that feeds it. Tests are
/// mass-produced: exact selections at native + Retina scales, selections
/// that straddle each image edge, microscopic selections, and selections
/// that entirely miss the image. No SC involvement, runs in microseconds.
final class CropMathTests: XCTestCase {

    private func imageBounds(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: w, height: h)
    }

    // MARK: - Exact, aligned selections

    func testNonRetinaFullScreenSelectionReturnsEntireImage() {
        let selection = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1920, 1080)
        )
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testRetinaSelectionMultipliesByScaleFactor() {
        // 400×200 points at 2x Retina = 800×400 pixels. This is the happy
        // path — if it regresses, every capture is broken.
        let selection = CGRect(x: 100, y: 50, width: 400, height: 200)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 2.0,
            imageBounds: imageBounds(2880, 1800)
        )
        XCTAssertEqual(crop, CGRect(x: 200, y: 100, width: 800, height: 400))
    }

    func testScaledDisplayModeRatioProducesCorrectPixels() {
        // "More Space" mode on 16" MBP: logical 1920, panel 3456. Ratio 1.8.
        // This is the mode where backingScaleFactor (2.0) historically gave
        // crops that overshot by ~11% — hence measuring the real ratio.
        let selection = CGRect(x: 100, y: 100, width: 500, height: 300)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.8,
            imageBounds: imageBounds(3456, 2160)
        )
        XCTAssertEqual(crop.origin.x, 180)
        XCTAssertEqual(crop.origin.y, 180)
        XCTAssertEqual(crop.width, 900)
        XCTAssertEqual(crop.height, 540)
    }

    // MARK: - Edge-straddling selections

    func testSelectionOffLeftEdgeClipsToImageLeft() {
        // User dragged from off-screen into the image (can happen on the
        // arrow tool now that we don't clamp; the overlay itself shouldn't
        // allow this but safety net in the crop prevents crashes).
        let selection = CGRect(x: -50, y: 100, width: 200, height: 100)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertEqual(crop.origin.x, 0)
        XCTAssertEqual(crop.origin.y, 100)
        XCTAssertEqual(crop.width, 150) // 200 - 50 that was off-image
    }

    func testSelectionOffRightEdgeClipsToImageRight() {
        let selection = CGRect(x: 900, y: 100, width: 200, height: 100)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertEqual(crop, CGRect(x: 900, y: 100, width: 100, height: 100))
    }

    func testSelectionOffTopEdgeClipsToImageTop() {
        let selection = CGRect(x: 100, y: -30, width: 200, height: 100)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 200, height: 70))
    }

    func testSelectionOffBottomEdgeClipsToImageBottom() {
        let selection = CGRect(x: 100, y: 750, width: 200, height: 100)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertEqual(crop, CGRect(x: 100, y: 750, width: 200, height: 50))
    }

    func testSelectionEntirelyOutsideImageReturnsEmpty() {
        let selection = CGRect(x: 2000, y: 100, width: 200, height: 100)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertTrue(crop.isEmpty)
    }

    // MARK: - Rounding / integral behaviour

    func testFractionalSelectionRoundsOutward() {
        // .integral: origin floored, size ceiled — never loses pixels, may
        // gain one or two. User selects 400.5×200.5 starting at 100.5,50.5.
        let selection = CGRect(x: 100.5, y: 50.5, width: 400.4, height: 200.6)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 1.0,
            imageBounds: imageBounds(1000, 800)
        )
        XCTAssertEqual(crop.origin.x, 100)
        XCTAssertEqual(crop.origin.y, 50)
        XCTAssertTrue(crop.maxX >= 500.9) // original maxX
        XCTAssertTrue(crop.maxY >= 251.1)
    }

    func testTinyOnePixelSelectionSurvivesIntegralRounding() {
        // 1×1 point selection at 2x scale should yield a 2×2 pixel crop.
        let selection = CGRect(x: 500, y: 400, width: 1, height: 1)
        let crop = ScreenshotManager.cropRectInPixels(
            selectionInPoints: selection, scale: 2.0,
            imageBounds: imageBounds(2000, 1600)
        )
        XCTAssertFalse(crop.isEmpty)
        XCTAssertEqual(crop, CGRect(x: 1000, y: 800, width: 2, height: 2))
    }

    // MARK: - Stress / fuzz

    func testHundredRandomSelectionsNeverExceedImageBounds() {
        // Property: under any selection + scale, the crop rect must lie
        // entirely within imageBounds. If this fires, "capture exceeded the
        // bounds" is a code bug, not a display-mode quirk.
        let bounds = imageBounds(2880, 1800)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let x = CGFloat(Int.random(in: -200...1500, using: &rng))
            let y = CGFloat(Int.random(in: -200...1000, using: &rng))
            let w = CGFloat(Int.random(in: 1...2000, using: &rng))
            let h = CGFloat(Int.random(in: 1...1500, using: &rng))
            let scale = [1.0, 1.5, 1.8, 2.0].randomElement(using: &rng)!
            let selection = CGRect(x: x, y: y, width: w, height: h)
            let crop = ScreenshotManager.cropRectInPixels(
                selectionInPoints: selection, scale: scale, imageBounds: bounds
            )
            if !crop.isEmpty {
                XCTAssertGreaterThanOrEqual(crop.minX, bounds.minX, "selection=\(selection) scale=\(scale)")
                XCTAssertGreaterThanOrEqual(crop.minY, bounds.minY, "selection=\(selection) scale=\(scale)")
                XCTAssertLessThanOrEqual(crop.maxX, bounds.maxX, "selection=\(selection) scale=\(scale)")
                XCTAssertLessThanOrEqual(crop.maxY, bounds.maxY, "selection=\(selection) scale=\(scale)")
            }
        }
    }
}
