import Foundation
import AppKit
import KatibCore

/// Fullscreen overlay that paints a frozen snapshot of each display and lets
/// the user drag a rectangle to pick the capture region. Dims the screen,
/// restores full brightness inside the selection, shows a live size HUD,
/// escapes on Esc. Completion hands back the selection and the frozen frame
/// it was drawn against — the caller crops from that bitmap, so we never
/// need a second ScreenCaptureKit round-trip after mouseUp.
@MainActor
final class CaptureOverlayWindow {

    /// One display captured at hotkey-press time. The image is the raw full
    /// display bitmap in native pixels; scale is the points-to-pixels ratio
    /// measured against the image itself (see `ScreenshotManager.captureDisplay`).
    struct FrozenDisplay {
        let screen: NSScreen
        let image: CGImage
        let scale: CGFloat
    }

    struct Selection {
        /// Frozen frame the selection was drawn against. Crop target.
        let frozen: FrozenDisplay
        /// Display-space rect in points, origin top-left of the display.
        let rectInPoints: CGRect

        var display: NSScreen { frozen.screen }
    }

    /// Present an overlay spanning every frozen display, resolve when the
    /// user either completes a drag or cancels with Esc.
    static func present(frozenDisplays: [FrozenDisplay], onPick: @escaping (Selection?) -> Void) {
        // One overlay window per display so the drag snaps to the one under
        // the cursor. Shared coordinator carries the pick callback.
        let coordinator = OverlayCoordinator(onPick: onPick)

        for frozen in frozenDisplays {
            let window = OverlayWindow(frozen: frozen, coordinator: coordinator)
            coordinator.windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class OverlayCoordinator {
    var windows: [OverlayWindow] = []
    let onPick: (CaptureOverlayWindow.Selection?) -> Void

    init(onPick: @escaping (CaptureOverlayWindow.Selection?) -> Void) {
        self.onPick = onPick
    }

    func finish(with selection: CaptureOverlayWindow.Selection?) {
        onPick(selection)
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

final class OverlayWindow: NSWindow {
    private let coordinator: OverlayCoordinator
    private let overlayView: OverlaySelectionView

    init(frozen: CaptureOverlayWindow.FrozenDisplay, coordinator: OverlayCoordinator) {
        self.coordinator = coordinator
        self.overlayView = OverlaySelectionView(frozen: frozen, coordinator: coordinator)
        // Use the 4-arg super init. The 5-arg (…screen:) variant delegates
        // internally to the 4-arg version, but because we declare our own
        // designated init here Swift synthesizes a trapping override of the
        // 4-arg init that the Obj-C runtime happily dispatches to — SIGTRAP
        // on every capture. Initialize with the frame up front, then
        // explicitly setFrame on the intended screen afterwards.
        super.init(
            contentRect: frozen.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.setFrame(frozen.screen.frame, display: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = false
        self.contentView = overlayView
        self.acceptsMouseMovedEvents = true
        // Pre-capture means the overlay can't appear in its own frame, but
        // keep sharingType=.none as belt-and-suspenders if the capture path
        // is ever re-run mid-session.
        self.sharingType = .none
    }

    required init?(coder: NSCoder) { fatalError("OverlayWindow doesn't support NSCoding") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            coordinator.finish(with: nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Custom NSView that paints the frozen display bitmap, handles the mouse
/// drag, and renders the dim overlay with a full-brightness hole at the
/// live selection rectangle.
final class OverlaySelectionView: NSView {
    private let frozen: CaptureOverlayWindow.FrozenDisplay
    private let coordinator: OverlayCoordinator
    private let frozenNSImage: NSImage

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(frozen: CaptureOverlayWindow.FrozenDisplay, coordinator: OverlayCoordinator) {
        self.frozen = frozen
        self.coordinator = coordinator
        self.frozenNSImage = NSImage(cgImage: frozen.image, size: frozen.screen.frame.size)
        super.init(frame: frozen.screen.frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let current = dragCurrent else {
            coordinator.finish(with: nil)
            return
        }

        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        dragStart = nil
        dragCurrent = nil

        if rect.width < 4 || rect.height < 4 {
            coordinator.finish(with: nil)
            return
        }

        // Convert bottom-left view coords → top-left display-points coords.
        let displayHeight = frozen.screen.frame.height
        let displaySpace = CGRect(
            x: rect.origin.x,
            y: displayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        coordinator.finish(with: CaptureOverlayWindow.Selection(
            frozen: frozen,
            rectInPoints: displaySpace
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Base layer: the frozen display bitmap at full brightness.
        frozenNSImage.draw(in: bounds)

        // Dim the whole thing — matches the old overlay's contrast.
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let start = dragStart, let current = dragCurrent else { return }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        // Restore full brightness inside the selection by redrawing the
        // frozen image within a clip region. Unlike the old transparent
        // punch-through, this shows the captured state — dropdowns, menus,
        // and hover effects that were on screen at hotkey time stay visible.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        frozenNSImage.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        // Selection border.
        AppColors.bronzeNSColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()

        // Size HUD.
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let labelSize = attr.size()
        let labelRect = CGRect(
            x: rect.minX,
            y: rect.maxY + 6,
            width: labelSize.width + 12,
            height: labelSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        attr.draw(at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 3))
    }
}
