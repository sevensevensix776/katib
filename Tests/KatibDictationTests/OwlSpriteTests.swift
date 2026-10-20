import XCTest
import AppKit
import SwiftUI
@testable import KatibDictation

/// The owl is hand-typed pixel art. The failure that matters is a ragged row
/// or a layer pushed off the 24x24 grid: it draws wrong with no error.
final class OwlSpriteTests: XCTestCase {

    private let moods: [OwlMood] = [
        .listening(speaking: true), .listening(speaking: false), .thinking, .done, .failed
    ]

    func testEveryPoseStaysOnTheGridWithKnownColors() {
        for mood in moods {
            for tick in 0..<200 {
                for layer in OwlScript.pose(for: mood, tick: tick).layers {
                    let width = layer.rows.first?.count ?? 0
                    for (y, row) in layer.rows.enumerated() {
                        XCTAssertEqual(row.count, width, "\(mood) tick \(tick): ragged row \(y)")
                        for (x, ch) in row.enumerated() where ch != "." {
                            XCTAssertNotNil(OwlPalette.colors[ch], "unknown pixel '\(ch)'")
                            let px = x + layer.dx, py = y + layer.dy
                            XCTAssertTrue((0..<OwlArt.size).contains(px) && (0..<OwlArt.size).contains(py),
                                          "\(mood) tick \(tick): pixel off grid at \(px),\(py)")
                        }
                    }
                }
            }
        }
        for eyes in [OwlEyes.open, .down, .closed, .up, .happy, .dizzy] {
            XCTAssertTrue(OwlArt.body(eyes: eyes).allSatisfy { $0.count == OwlArt.size })
        }
    }

    /// `KATIB_OWL_PREVIEW=/some/dir swift test --filter OwlSpriteTests` writes a
    /// contact sheet (one row per mood, 12 ticks) so the art can be eyeballed.
    func testWritePreviewSheetWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["KATIB_OWL_PREVIEW"] else { return }
        let scale = 8, ticks = 12, cell = OwlArt.size * scale
        let width = cell * ticks, height = cell * moods.count
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.14, green: 0.12, blue: 0.11, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (m, mood) in moods.enumerated() {
            for t in 0..<ticks {
                for layer in OwlScript.pose(for: mood, tick: t).layers {
                    for (y, row) in layer.rows.enumerated() {
                        for (x, ch) in row.enumerated() {
                            guard let color = OwlPalette.colors[ch] else { continue }
                            NSColor(color).setFill()
                            let px = t * cell + (x + layer.dx) * scale
                            let py = height - (m * cell + (y + layer.dy + 1) * scale)
                            NSRect(x: px, y: py, width: scale, height: scale).fill()
                        }
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("owl-sheet.png"))
    }

    /// Same env var: renders the real HUD in each non-recording state.
    @MainActor
    func testWriteHUDPreviewWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["KATIB_OWL_PREVIEW"] else { return }
        let states: [(String, IndicatorState)] = [
            ("thinking", .finalizing),
            ("done", .success("No, no, I want to focus on what the correct data source is.")),
            ("failed", .error("Microphone is in use by another app."))
        ]
        for (name, state) in states {
            let model = LiveIndicatorViewModel()
            model.state = state
            let renderer = ImageRenderer(content: LiveIndicatorView(viewModel: model).padding(20).background(Color.gray))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("hud-\(name).png"))
        }
    }
}
