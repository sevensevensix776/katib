import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import KatibCore

/// Ties together: permission check → capture overlay → ScreenCaptureKit pull
/// → crop → annotation window → clipboard / disk. All public callers go
/// through `startCapture()`.
///
/// Permission policy: we DO NOT probe Screen Recording at launch. First time
/// `startCapture()` runs, if TCC hasn't been granted, we show a friendly
/// alert with a deep-link to the Privacy pane and bail. The user grants it,
/// re-triggers capture, and we proceed.
@MainActor
public final class ScreenshotManager {
    public static let shared = ScreenshotManager()

    private var annotationController: AnnotationWindowController?
    private var captureInProgress = false

    /// Called whenever a capture is finalized — gives the host app a
    /// chance to persist the image somewhere besides the pasteboard
    /// (e.g. clipboard history). Module-boundary-respecting: this lives
    /// in KatibScreenshot, KatibClipboard depends only on KatibCore, so
    /// AppDelegate (which imports both) wires this hook.
    public var onCaptured: ((Data, Int, Int) -> Void)?

    private init() {}

    // MARK: - Public entry

    /// Region select → annotation editor → user decides copy/save. The
    /// full-featured path.
    public func startCapture() {
        beginCapture(skipEditor: false)
    }

    /// Region select → straight to clipboard (and disk if auto-save is on).
    /// Bypasses the annotation editor. Bound to ⇧⌘3 by default.
    public func startQuickCapture() {
        beginCapture(skipEditor: true)
    }

    private func beginCapture(skipEditor: Bool) {
        guard !captureInProgress else { return }
        captureInProgress = true

        if !CGPreflightScreenCaptureAccess() {
            captureInProgress = false
            presentScreenRecordingPermissionAlert()
            return
        }

        Task { @MainActor in
            do {
                // Snapshot every attached display BEFORE showing the overlay.
                // The overlay paints these bitmaps as its background and
                // crops from them at mouseUp, so what the user sees at
                // hotkey-press time — open menus, dropdowns, hover states —
                // is preserved instead of being dismissed when the overlay
                // steals focus.
                let frozen = try await captureAllDisplays()
                CaptureOverlayWindow.present(frozenDisplays: frozen) { [weak self] selection in
                    guard let self else { return }
                    guard let selection else {
                        self.captureInProgress = false
                        Logger.shared.log("Screenshot capture cancelled")
                        return
                    }
                    self.handleSelection(selection, skipEditor: skipEditor)
                }
            } catch {
                self.captureInProgress = false
                Logger.shared.log("Screenshot capture failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Couldn't capture the screen"
                alert.informativeText = "\(error.localizedDescription)\n\nTry again, or check System Settings → Privacy & Security → Screen Recording."
                alert.runModal()
            }
        }
    }

    public func annotationWindowClosed() {
        annotationController = nil
        captureInProgress = false
    }

    // MARK: - Capture

    private func handleSelection(_ selection: CaptureOverlayWindow.Selection, skipEditor: Bool) {
        do {
            let image = try cropFromFrozen(selection: selection)
            if skipEditor {
                // Quick mode: always copy, honor auto-save setting for disk.
                finalize(image: image, copy: true, save: AppSettings.shared.screenshotAutoSave)
                captureInProgress = false
            } else {
                openAnnotationEditor(with: image)
            }
        } catch {
            captureInProgress = false
            Logger.shared.log("Screenshot crop failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't produce the screenshot"
            alert.informativeText = "\(error.localizedDescription)\n\nTry again."
            alert.runModal()
        }
    }

    /// Snapshot every attached display via ScreenCaptureKit. Each frame's
    /// points-to-pixels scale is measured against the returned image, which
    /// handles "More Space" and other scaled display modes where
    /// backingScaleFactor can misreport the real ratio.
    private func captureAllDisplays() async throws -> [CaptureOverlayWindow.FrozenDisplay] {
        let tStart = CFAbsoluteTimeGetCurrent()

        // excludingDesktopWindows: true matches OBS + Apple's sample. The
        // display filter captures the wallpaper as part of the display's
        // visual state regardless; leaving desktop windows in the list could
        // make onScreenWindowsOnly misclassify background apps and silently
        // drop windows — that's the root of the "only captures one window"
        // symptom we hit previously.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let screens = NSScreen.screens
        var result: [CaptureOverlayWindow.FrozenDisplay] = []
        result.reserveCapacity(screens.count)

        for screen in screens {
            let wantedID = displayID(for: screen)
            guard let scDisplay = content.displays.first(where: { Int($0.displayID) == wantedID }) else {
                let ids = content.displays.map { Int($0.displayID) }
                Logger.shared.log("Screenshot: no SCDisplay matches NSScreen id=\(wantedID) (available: \(ids))")
                throw NSError(domain: "Katib", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't find the display to capture (id \(wantedID))."
                ])
            }

            // Apple's SCDisplay.width is documented as pixels but reads as
            // points on Retina — OBS sidesteps the ambiguity by reading the
            // current CGDisplayMode directly. Mismatched dimensions with
            // scalesToFit=false cause letterboxing / upper-left crops.
            let cgDisplayID = CGDirectDisplayID(scDisplay.displayID)
            let (pixelWidth, pixelHeight): (Int, Int) = {
                if let mode = CGDisplayCopyDisplayMode(cgDisplayID) {
                    return (mode.pixelWidth, mode.pixelHeight)
                }
                return (Int(scDisplay.width), Int(scDisplay.height))
            }()

            let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = pixelWidth
            config.height = pixelHeight
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = false
            config.preservesAspectRatio = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
                config.colorSpaceName = srgb.name ?? CGColorSpace.sRGB
            }
            config.queueDepth = 5

            let fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Measure the real points-to-pixels scale from the image itself
            // rather than trusting backingScaleFactor — on scaled display
            // modes the latter can be off by ~10-20% and silently produce
            // crops that miss the selected region.
            let logicalSize = screen.frame.size
            let measuredScale = logicalSize.width > 0
                ? CGFloat(fullImage.width) / logicalSize.width
                : screen.backingScaleFactor
            let scale = measuredScale > 0 ? measuredScale : screen.backingScaleFactor
            if abs(measuredScale - screen.backingScaleFactor) > 0.05 {
                Logger.shared.log("""
                    Screenshot scale mismatch: measured=\(measuredScale) \
                    backing=\(screen.backingScaleFactor) — using measured. \
                    image=\(fullImage.width)×\(fullImage.height) logical=\(logicalSize)
                    """)
            }

            result.append(CaptureOverlayWindow.FrozenDisplay(
                screen: screen,
                image: fullImage,
                scale: scale
            ))
        }

        let ms = Int(((CFAbsoluteTimeGetCurrent() - tStart) * 1000).rounded())
        Logger.shared.log("Screenshot pre-capture: \(result.count) display(s) frozen in \(ms)ms")
        return result
    }

    /// Crop the user's selection out of the pre-captured frozen frame. No
    /// ScreenCaptureKit round-trip — we already have the bitmap.
    private func cropFromFrozen(selection: CaptureOverlayWindow.Selection) throws -> NSImage {
        let frozen = selection.frozen
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let cropRect = Self.cropRectInPixels(
            selectionInPoints: selection.rectInPoints,
            scale: frozen.scale,
            imageBounds: imageBounds
        )

        Logger.shared.log("""
            Screenshot crop: selectionPoints=\(selection.rectInPoints) scale=\(frozen.scale) \
            fullImage=\(frozen.image.width)×\(frozen.image.height) cropRect=\(cropRect)
            """)

        guard !cropRect.isEmpty, let cropped = frozen.image.cropping(to: cropRect) else {
            Logger.shared.log("Screenshot crop empty — selection didn't overlap captured image")
            throw NSError(domain: "Katib", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Selected region didn't overlap the captured image (check katib.log for coords)."
            ])
        }

        // Derive points-size from the actual cropped pixel dimensions, not
        // the user's selection rect — after `.integral` rounding and edge
        // clipping the aspect can shift, and tagging NSImage with the
        // original selection size makes SwiftUI stretch the pixels.
        let pointsSize = CGSize(
            width: CGFloat(cropped.width) / frozen.scale,
            height: CGFloat(cropped.height) / frozen.scale
        )
        return NSImage(cgImage: cropped, size: pointsSize)
    }

    /// Pure: compute the pixel-space crop rect given a selection in points,
    /// a points-to-pixels scale, and the captured image's bounds (also in
    /// pixels). Rounds to integers via `.integral` and clips to image bounds
    /// so selections straddling the edge don't throw.
    ///
    /// Extracted static so unit tests can hammer it across scales, origins,
    /// sign conventions, and off-edge selections without spinning up
    /// ScreenCaptureKit. "Bounds not respected" bugs live here or in the
    /// scale computation — having both testable is the whole point.
    public nonisolated static func cropRectInPixels(
        selectionInPoints: CGRect,
        scale: CGFloat,
        imageBounds: CGRect
    ) -> CGRect {
        let scaled = CGRect(
            x: selectionInPoints.origin.x * scale,
            y: selectionInPoints.origin.y * scale,
            width: selectionInPoints.width * scale,
            height: selectionInPoints.height * scale
        ).integral
        return scaled.intersection(imageBounds)
    }

    private func displayID(for screen: NSScreen) -> Int {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return number.intValue
    }

    // MARK: - Editor + output

    private func openAnnotationEditor(with image: NSImage) {
        let autoCopy = AppSettings.shared.screenshotAutoCopy
        let autoSave = AppSettings.shared.screenshotAutoSave

        // Shortcut: if both auto-actions are off AND skip-editor is on,
        // this is user-level misconfiguration — open editor anyway so the
        // shot isn't lost.
        if AppSettings.shared.screenshotSkipEditor {
            finalize(image: image, copy: autoCopy || !autoSave, save: autoSave)
            captureInProgress = false
            return
        }

        let controller = AnnotationWindowController(
            image: image,
            onCopy: { [weak self] flat in
                self?.finalize(image: flat, copy: true, save: autoSave)
            },
            onSave: { [weak self] flat in
                self?.finalize(image: flat, copy: autoCopy, save: true)
            },
            onCancel: {
                Logger.shared.log("Screenshot edit cancelled")
            }
        )
        annotationController = controller
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finalize(image: NSImage, copy: Bool, save: Bool) {
        guard let data = AnnotationExporter.pngData(from: image) else {
            Logger.shared.log("Screenshot PNG encode failed")
            presentFinalizeFailureAlert(stage: "Encode", detail: "Couldn't turn the image into PNG data.")
            return
        }

        var copyOK = true
        if copy {
            let pb = NSPasteboard.general
            pb.clearContents()
            // `writeObjects` returns Bool — silently dropping a false return
            // meant "Copy" could visually succeed while the clipboard stayed
            // empty. Surface it.
            copyOK = pb.writeObjects([image])
            // Mark so ClipboardManager skips it (it's our own output)
            pb.setData(Data(), forType: KatibPasteboard.katibMarkerType)
            if copyOK {
                Logger.shared.log("Screenshot copied to clipboard (bytes=\(data.count))")
            } else {
                Logger.shared.log("Screenshot clipboard write REFUSED by NSPasteboard")
            }
        }

        // Also persist into clipboard history. Pasteboard polling skips
        // our own writes (katibMarkerType), so without this explicit call
        // screenshots only landed in the system pasteboard, not the
        // searchable history. Now they show up in the clipboard picker.
        let dims = image.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) }
            ?? (Int(image.size.width), Int(image.size.height))
        onCaptured?(data, dims.0, dims.1)

        var savedURL: URL?
        if save, let url = destinationURL() {
            do {
                try data.write(to: url, options: .atomic)
                savedURL = url
                Logger.shared.log("Screenshot saved to \(url.path)")
                if AppSettings.shared.screenshotRevealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                Logger.shared.log("Screenshot save failed: \(error)")
                presentFinalizeFailureAlert(stage: "Save", detail: error.localizedDescription)
            }
        }

        // If the user asked to copy AND it failed, they got no feedback
        // because no save happened either. Show them.
        if copy && !copyOK && savedURL == nil {
            presentFinalizeFailureAlert(
                stage: "Copy",
                detail: "macOS refused the clipboard write. Try again, or use Save instead."
            )
        }
    }

    private func presentFinalizeFailureAlert(stage: String, detail: String) {
        // Defer past this runloop tick so the overlay teardown and any
        // currently-executing pipeline step can finish unwinding. Running
        // a modal while SCKit or AppKit is mid-teardown has produced odd
        // interactions in the past (stuck overlays, focus-stealing loops).
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screenshot \(stage) failed"
            alert.informativeText = detail + "\n\nSee ~/Library/Logs/Katib/katib.log for details."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func destinationURL() -> URL? {
        let parent: URL
        switch AppSettings.shared.screenshotSaveLocation {
        case .desktop:
            parent = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        case .downloads:
            parent = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        case .pictures:
            parent = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        }

        // Optional subfolder — keeps Desktop/Downloads from turning into a
        // dumping ground. Created on first save if missing. Empty string
        // setting = save directly in the parent location.
        let subfolder = AppSettings.shared.screenshotSubfolderName
            .trimmingCharacters(in: .whitespaces)
        let targetFolder: URL
        if subfolder.isEmpty {
            targetFolder = parent
        } else {
            targetFolder = parent.appendingPathComponent(subfolder, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: targetFolder, withIntermediateDirectories: true
            )
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = formatter.string(from: Date())
        return targetFolder.appendingPathComponent("Katib-\(stamp).png")
    }

    // MARK: - Permission prompt

    private func presentScreenRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Katib needs Screen Recording permission"
        alert.informativeText = """
        macOS requires apps to be granted Screen Recording before they can capture any region of your screen.

        Click Open Settings, toggle Katib on in the list, then come back and try Capture again.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsPane.screenRecording.open()
            // Nudge the OS to remember we asked.
            CGRequestScreenCaptureAccess()
        }
    }
}
