import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import KatibCore

/// Flatten the annotation state down to an NSImage / PNG Data blob.
///
/// Why re-implement drawing here (instead of reusing the SwiftUI Canvas): the
/// canvas draws at on-screen scale and has previews for in-progress work.
/// Export must be pixel-perfect at the image's native size, and blur has to
/// actually filter the underlying pixels, not render a translucent overlay.
@MainActor
enum AnnotationExporter {

    static func flatten(state: AnnotationState) -> NSImage {
        let imageRect = CGRect(origin: .zero, size: state.imageSize)

        // Extend canvas if annotations spill outside the image — arrow/text
        // tools allow this (Droplr/CleanShot convention). Union every
        // stroke's visualBounds with the image rect; pad the extended area
        // so strokes don't sit flush against the canvas edge.
        var expanded = imageRect
        for stroke in state.committed {
            expanded = expanded.union(stroke.visualBounds())
        }
        let didExpand = expanded != imageRect
        if didExpand {
            expanded = expanded.insetBy(dx: -16, dy: -16)
        }
        expanded = expanded.integral

        let size = expanded.size
        // Where the original image sits inside the expanded canvas. Zero
        // when no expansion happened; positive when strokes extended top/
        // left (image shifts down/right in the new canvas).
        let shift = CGPoint(x: -expanded.origin.x, y: -expanded.origin.y)

        let result = NSImage(size: size)
        // y-DOWN context — matches stored stroke coords (captured from the
        // SwiftUI drag gesture, which is y-DOWN) and the Canvas preview.
        result.lockFocusFlipped(true)
        defer { result.unlockFocus() }

        // White margin where we extended past the image — looks clean when
        // pasted into light or dark recipients and matches CleanShot.
        // Inside the image area we let the image itself overwrite.
        if didExpand {
            NSColor.white.setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }

        // Base image at shifted origin within the expanded canvas.
        state.image.draw(in: CGRect(origin: shift, size: state.imageSize))

        // Translate the drawing context so every stroke (stored in image-
        // local coords) lands at the correct position inside the expanded
        // canvas without rewriting each tool's draw method. Blur samples
        // the source image directly and draws via cgContext — the
        // translation applies to that too.
        guard let cgCtx = NSGraphicsContext.current?.cgContext else { return result }
        cgCtx.saveGState()
        defer { cgCtx.restoreGState() }
        cgCtx.translateBy(x: shift.x, y: shift.y)

        // Blur + redact passes first so other annotations paint on top
        // of the obscured region (arrows pointing AT redacted text remain
        // visible). Order between blur and redact doesn't matter — they
        // don't overlap in practice — but redact runs second so a user
        // who blurred a region then placed redact over it gets the more
        // permanent obscuring on top.
        for stroke in state.committed where stroke.tool == .blur {
            drawBlur(stroke: stroke, base: state.image, imageSize: state.imageSize)
        }
        for stroke in state.committed where stroke.tool == .redact {
            drawRedact(stroke: stroke)
        }

        // Highlights beneath shapes
        for stroke in state.committed where stroke.tool == .highlight {
            drawHighlight(stroke: stroke)
        }

        // Shapes + text
        for stroke in state.committed {
            switch stroke.tool {
            case .select:
                break // Not a drawable stroke — the select tool manipulates
                // existing strokes, it never creates one.
            case .arrow:
                drawArrow(stroke: stroke)
            case .rectangle:
                drawRect(stroke: stroke)
            case .ellipse:
                drawEllipse(stroke: stroke)
            case .text:
                drawText(stroke: stroke)
            case .number:
                drawNumber(stroke: stroke)
            case .highlight, .blur, .redact:
                break // already handled in the pre-shapes passes above
            }
        }

        return result
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    // MARK: - Drawing primitives (image-space coordinates)

    private static func drawHighlight(stroke: AnnotationStroke) {
        NSColor(stroke.color).withAlphaComponent(0.35).setFill()
        stroke.rect.fill()
    }

    /// Solid fill over the region. Pixels underneath are permanently
    /// destroyed at export — no recovery path even with image-recovery
    /// AI, because the source pixels never make it into the output PNG.
    /// Color follows `stroke.color` so the user can pick black for the
    /// classic "censor bar" look or any other tint to match the docs
    /// they're shipping.
    private static func drawRedact(stroke: AnnotationStroke) {
        NSColor(stroke.color).setFill()
        stroke.rect.fill()
    }

    private static func drawRect(stroke: AnnotationStroke) {
        NSColor(stroke.color).setStroke()
        let path = NSBezierPath(roundedRect: stroke.rect, xRadius: 4, yRadius: 4)
        path.lineWidth = stroke.thickness
        path.stroke()
    }

    private static func drawEllipse(stroke: AnnotationStroke) {
        NSColor(stroke.color).setStroke()
        let path = NSBezierPath(ovalIn: stroke.rect)
        path.lineWidth = stroke.thickness
        path.stroke()
    }

    private static func drawArrow(stroke: AnnotationStroke) {
        NSColor(stroke.color).setStroke()
        let path = NSBezierPath()
        path.move(to: stroke.start)
        path.line(to: stroke.end)
        path.lineWidth = stroke.thickness
        path.lineCapStyle = .round
        path.stroke()

        let dx = stroke.end.x - stroke.start.x
        let dy = stroke.end.y - stroke.start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 2 else { return }
        let ux = dx / length, uy = dy / length
        let headLen = max(12, stroke.thickness * 3.5)
        let spread = max(6, stroke.thickness * 2)

        let left = CGPoint(
            x: stroke.end.x - headLen * ux + spread * -uy,
            y: stroke.end.y - headLen * uy + spread * ux
        )
        let right = CGPoint(
            x: stroke.end.x - headLen * ux - spread * -uy,
            y: stroke.end.y - headLen * uy - spread * ux
        )
        NSColor(stroke.color).setFill()
        let head = NSBezierPath()
        head.move(to: stroke.end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private static func drawText(stroke: AnnotationStroke) {
        // Match AnnotationCanvas.swift — floor 28pt, scale with thickness.
        // The canvas preview sets the expectation; the exporter must match
        // or the saved PNG will have different text sizes than the editor.
        let fontSize = max(28, stroke.thickness * 6)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor(stroke.color)
        ]
        let attr = NSAttributedString(string: stroke.text, attributes: attributes)
        attr.draw(at: stroke.start)
    }

    private static func drawNumber(stroke: AnnotationStroke) {
        let size = max(22, stroke.thickness * 5)
        let rect = CGRect(
            x: stroke.start.x - size / 2,
            y: stroke.start.y - size / 2,
            width: size, height: size
        )
        NSColor(stroke.color).setFill()
        NSBezierPath(ovalIn: rect).fill()

        let font = NSFont.systemFont(ofSize: size * 0.55, weight: .bold)
        let text = "\(stroke.stepIndex ?? 0)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        attr.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    }

    /// Blur strength in image points. One number shared by the export and the
    /// live preview so what you see is what you get. 24 pt makes body text
    /// unreadable; the old 18 px was ~9 pt on Retina and could be read through.
    static let blurRadiusPoints: CGFloat = 24

    /// Blur the source pixels inside the stroke rect with CIGaussianBlur. This
    /// runs off the original image, not the canvas render.
    ///
    /// Two traps, both fixed 2026-10-19:
    /// - Units. `stroke.rect` and `imageSize` are POINTS; the CGImage is
    ///   PIXELS (2x on Retina). Mixing them blurred the wrong part of the
    ///   image, drifting further off the lower the box sat.
    /// - Edges. Gaussian blur samples past the image edge, where CI sees
    ///   transparent pixels, so boxes near an edge faded to mud. Clamping
    ///   the source to its extent repeats the edge pixels instead.
    private static func drawBlur(stroke: AnnotationStroke, base: NSImage, imageSize: CGSize) {
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              imageSize.width > 0, imageSize.height > 0 else { return }
        let pxPerPt = CGFloat(cg.width) / imageSize.width
        let ci = CIImage(cgImage: cg)

        let filter = CIFilter.gaussianBlur()
        filter.inputImage = ci.clampedToExtent()
        filter.radius = Float(blurRadiusPoints * pxPerPt)
        guard let blurred = filter.outputImage else { return }

        // CI space is y-UP in pixels; stroke.rect is y-DOWN in points.
        let rect = stroke.rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !rect.isEmpty else { return }
        let region = CGRect(
            x: rect.minX * pxPerPt,
            y: CGFloat(cg.height) - rect.maxY * pxPerPt,
            width: rect.width * pxPerPt,
            height: rect.height * pxPerPt
        ).integral

        let ciContext = CIContext()
        guard let cropped = ciContext.createCGImage(blurred, from: region) else { return }

        // Draw via CGContext directly instead of NSImage.draw(in:) — NSImage
        // applies an extra orientation flip in a flipped AppKit context
        // which would vertically mirror the blurred pixels. CGContext.draw
        // is y-DOWN unconditionally; in our flipped (also y-DOWN) context
        // it lays the image down with top at rect.minY, matching every
        // other stroke. Catches the y-inversion regression flagged in review.
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
        cgContext.saveGState()
        cgContext.draw(cropped, in: rect)
        cgContext.restoreGState()
    }
}
