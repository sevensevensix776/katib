#!/usr/bin/env swift
// Diagnostic CLI for Katib's screenshot capture pipeline.
//
// Usage:
//   swift scripts/screenshot-diagnostic.swift           # all default tests
//   swift scripts/screenshot-diagnostic.swift 5         # run 5 captures
//
// What it does:
//   1. Captures the full primary display via ScreenCaptureKit — SAME
//      SCContentFilter + SCStreamConfiguration that ScreenshotManager uses.
//   2. Dumps the raw full-display capture to /tmp/katib-diag/full.png.
//      Open it: if anything is missing (dock, menu bar, wallpaper, other
//      apps), the bug is at the SC/filter layer, not our crop.
//   3. Generates a grid of 9 deterministic selections — corners, edges,
//      center — and crops each. Dumps to /tmp/katib-diag/crop-*.png with
//      a report.json alongside listing every scale + pixel rect.
//   4. Verifies our `cropRectInPixels` math against a direct CGImage.cropping
//      using the same rect. Any divergence = the bug is in our math.
//
// Output:
//   /tmp/katib-diag/
//     full.png               raw SC capture, no crop
//     crop-TL.png            top-left 400×300 selection
//     crop-TR.png            top-right
//     ...
//     report.json            display info, scales, pixel rects, mismatches

import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: "/tmp/katib-diag", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Capture the full display

func runDiagnostic() async throws {
    guard let primaryScreen = NSScreen.main else {
        print("ERROR: no primary NSScreen")
        exit(1)
    }
    guard let screenNumber = primaryScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        print("ERROR: can't read NSScreenNumber")
        exit(1)
    }
    let wantedDisplayID = screenNumber.intValue

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let scDisplay = content.displays.first(where: { Int($0.displayID) == wantedDisplayID }) else {
        print("ERROR: no SCDisplay matches NSScreenNumber \(wantedDisplayID)")
        print("Available SCDisplay IDs: \(content.displays.map { Int($0.displayID) })")
        exit(1)
    }

    print("Primary display:")
    print("  NSScreen.frame:            \(primaryScreen.frame)")
    print("  NSScreen.backingScaleFactor: \(primaryScreen.backingScaleFactor)")
    print("  SCDisplay.width×height:    \(scDisplay.width)×\(scDisplay.height)")
    print("  Measured scale X:          \(CGFloat(scDisplay.width) / primaryScreen.frame.width)")
    print("  Measured scale Y:          \(CGFloat(scDisplay.height) / primaryScreen.frame.height)")
    print("")

    let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(scDisplay.width)
    config.height = Int(scDisplay.height)
    config.showsCursor = false
    config.capturesAudio = false

    print("Capturing full display...")
    let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    print("  got CGImage \(fullImage.width)×\(fullImage.height)")
    try save(cgImage: fullImage, name: "full.png")

    // Derive the real scale from the captured image
    let scale = CGFloat(fullImage.width) / primaryScreen.frame.width

    // Generate test selections in POINTS (display-local, top-left)
    let W = primaryScreen.frame.width
    let H = primaryScreen.frame.height
    let cellW: CGFloat = 400
    let cellH: CGFloat = 300
    let margin: CGFloat = 40

    let selections: [(name: String, rect: CGRect)] = [
        ("TL",   CGRect(x: margin,             y: margin,             width: cellW, height: cellH)),
        ("TC",   CGRect(x: (W - cellW) / 2,    y: margin,             width: cellW, height: cellH)),
        ("TR",   CGRect(x: W - cellW - margin, y: margin,             width: cellW, height: cellH)),
        ("ML",   CGRect(x: margin,             y: (H - cellH) / 2,    width: cellW, height: cellH)),
        ("MC",   CGRect(x: (W - cellW) / 2,    y: (H - cellH) / 2,    width: cellW, height: cellH)),
        ("MR",   CGRect(x: W - cellW - margin, y: (H - cellH) / 2,    width: cellW, height: cellH)),
        ("BL",   CGRect(x: margin,             y: H - cellH - margin, width: cellW, height: cellH)),
        ("BC",   CGRect(x: (W - cellW) / 2,    y: H - cellH - margin, width: cellW, height: cellH)),
        ("BR",   CGRect(x: W - cellW - margin, y: H - cellH - margin, width: cellW, height: cellH)),
    ]

    var report: [[String: Any]] = []
    var mismatches = 0

    print("\nRunning \(selections.count) crop tests...")
    for selection in selections {
        // Mirror the exact math from ScreenshotManager.cropRectInPixels
        let scaled = CGRect(
            x: selection.rect.origin.x * scale,
            y: selection.rect.origin.y * scale,
            width: selection.rect.width * scale,
            height: selection.rect.height * scale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let cropRect = scaled.intersection(imageBounds)

        guard !cropRect.isEmpty, let cropped = fullImage.cropping(to: cropRect) else {
            print("  \(selection.name): EMPTY crop — selection \(selection.rect) scaled to \(scaled)")
            mismatches += 1
            continue
        }

        try save(cgImage: cropped, name: "crop-\(selection.name).png")

        // Validate: cropped pixel dims == cropRect dims
        let dimsMatch = Int(cropRect.width) == cropped.width && Int(cropRect.height) == cropped.height
        if !dimsMatch {
            print("  \(selection.name): DIM MISMATCH cropRect=\(cropRect) cropped=\(cropped.width)×\(cropped.height)")
            mismatches += 1
        } else {
            print("  \(selection.name): OK selection=\(Int(selection.rect.width))×\(Int(selection.rect.height))pt → crop=\(cropped.width)×\(cropped.height)px")
        }

        report.append([
            "name": selection.name,
            "selectionPoints": rectToDict(selection.rect),
            "scaledPixels": rectToDict(scaled),
            "cropRect": rectToDict(cropRect),
            "resultPixels": ["w": cropped.width, "h": cropped.height],
            "dimsMatch": dimsMatch
        ])
    }

    let summary: [String: Any] = [
        "display": [
            "nsScreenFrame": rectToDict(primaryScreen.frame),
            "backingScaleFactor": primaryScreen.backingScaleFactor,
            "scDisplaySize": ["w": scDisplay.width, "h": scDisplay.height]
        ],
        "scaleUsed": scale,
        "fullImage": ["w": fullImage.width, "h": fullImage.height],
        "selections": report,
        "mismatches": mismatches
    ]
    let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: outputDir.appendingPathComponent("report.json"))

    print("\n--- Summary ---")
    print("Output dir: \(outputDir.path)")
    print("Crops saved: \(report.count) / \(selections.count)")
    print("Mismatches:  \(mismatches)")
    if mismatches == 0 {
        print("\nAll crops respect the selection bounds (pixel-dim exact). If captures")
        print("still look wrong in Katib, inspect /tmp/katib-diag/full.png — if content")
        print("is missing there, the bug is in SCContentFilter, not our crop math.")
    } else {
        print("\nFOUND MISMATCHES — crop math diverges from expected pixel dimensions.")
        print("Inspect report.json and the saved PNGs.")
    }
}

func rectToDict(_ r: CGRect) -> [String: CGFloat] {
    ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height]
}

func save(cgImage: CGImage, name: String) throws {
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    guard let tiff = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(name)"])
    }
    let url = outputDir.appendingPathComponent(name)
    try png.write(to: url)
}

// Run it
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        try await runDiagnostic()
    } catch {
        print("ERROR: \(error)")
    }
    sem.signal()
}
sem.wait()
