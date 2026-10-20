import XCTest
import AppKit
@testable import KatibScreenshot

/// Retina screenshots are 2x pixels per point. The export used to compute
/// the blur region in points against the pixel image: it blurred the wrong
/// area, and a box near the bottom edge faded to transparent mud.
@MainActor
final class BlurExportTests: XCTestCase {

    /// 200x200 pt image at 2x. Left half solid red; right half black/white
    /// vertical stripes 2 px wide. A real blur turns stripes mid-grey; raw
    /// stripes (see-through edge) stay black or white; red means the export
    /// sampled the wrong place.
    private func retinaRedAndStripes() -> NSImage {
        let px = 400
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: px / 2, height: px).fill()
        for x in stride(from: px / 2, to: px, by: 2) {
            ((x / 2).isMultiple(of: 2) ? NSColor.black : NSColor.white).setFill()
            NSRect(x: x, y: 0, width: 2, height: px).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: rep.cgImage!, size: NSSize(width: 200, height: 200))
    }

    func testBlurInTheBottomRightCornerBlursWhatIsUnderTheBox() throws {
        let state = AnnotationState(image: retinaRedAndStripes())
        // Box hugging the bottom-right corner, entirely over the stripes.
        state.committed = [AnnotationStroke(tool: .blur, start: CGPoint(x: 120, y: 140),
                                            end: CGPoint(x: 200, y: 200), color: .red, thickness: 4, text: "")]
        let out = AnnotationExporter.flatten(state: state)
        let rep = try XCTUnwrap(out.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let sx = CGFloat(rep.pixelsWide) / 200, sy = CGFloat(rep.pixelsHigh) / 200
        // Centre of the box and its bottom-right corner (rep rows are y-down).
        for (x, y) in [(160.0, 170.0), (198.0, 198.0)] {
            let c = try XCTUnwrap(rep.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(abs(c.redComponent - c.blueComponent), 0.15, "at \(x),\(y): wrong region (red) \(c)")
            // Raw stripes are 0 or 1. CI blurs in linear light, so the mix lands
            // nearer 0.75 than 0.5; anything strictly between means blurred.
            XCTAssertEqual(c.greenComponent, 0.5, accuracy: 0.45, "at \(x),\(y): not blurred \(c)")
        }
    }
}
