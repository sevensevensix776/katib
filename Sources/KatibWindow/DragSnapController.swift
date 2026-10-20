import Foundation
import AppKit
import ApplicationServices
import KatibCore

// Force casts after AX typeID guards are idiomatic; see WindowManager for the
// same pattern.
// swiftlint:disable force_cast

/// Drag-to-snap orchestrator.
///
/// Behavior mirrors BetterSnapTool / Rectangle / Magnet:
/// 1. User mouseDown on a window's title bar → we enter `pendingDrag`
/// 2. Once the cursor moves past `cursorActivationThreshold` AND the
///    window's AX position has actually moved, we unsnap (if the window
///    was previously snapped via Katib) and enter `tracking`. The window-
///    movement check is what distinguishes a real window drag from an
///    in-window drag like reordering Chrome tabs.
/// 3. As the user drags near a screen edge or corner, a bronze preview
///    overlay appears showing the target frame
/// 4. On mouseUp inside a snap zone → the window snaps via WindowManager
/// 5. On mouseUp elsewhere → the preview disappears, normal drag behavior
///    continues (macOS handles the actual window move)
/// 6. On mouseUp without ever leaving `pendingDrag` → it was a click;
///    no unsnap, no preview, no side effects
///
/// Uses a global CGEvent tap in `.listenOnly` mode — the tap observes mouse
/// events without consuming them, so native window dragging keeps working.
///
/// Title-bar detection is simple: the click's Y coordinate must be within
/// 30pt of the focused window's top. False positives (clicks on Chrome's
/// tab strip, Safari's bookmark bar, etc.) are why steps 1–2 separate
/// click-down from drag-activation. Pre-2.0 Katib unsnapped on mouseDown,
/// which made every Chrome tab click shrink the window.
@MainActor
public final class DragSnapController {
    public static let shared = DragSnapController()

    public var isEnabled: Bool = false {
        didSet { isEnabled ? start() : stop() }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let previewWindow = SnapPreviewWindow()

    /// Threshold distances (in points) for detecting edge + corner zones.
    private let edgeThreshold: CGFloat = 8
    private let cornerThreshold: CGFloat = 40
    private let titleBarDepth: CGFloat = 30
    private let activation = DragActivation(
        cursorActivationThreshold: 5,
        windowMoveThreshold: 1
    )

    private enum State {
        case idle
        /// Mouse is down on what looks like a title bar; awaiting real
        /// drag motion before unsnapping or showing a preview. Stores the
        /// initial cursor + window origin so we can measure deltas.
        case pendingDrag(
            windowElement: AXUIElement,
            screen: NSScreen,
            downCursor: CGPoint,
            downWindowOrigin: CGPoint
        )
        /// Drag activated; we've unsnapped (if applicable) and are now
        /// tracking the cursor for snap-zone hits.
        case tracking(windowElement: AXUIElement, screen: NSScreen)
        /// Cursor entered a snap zone during drag; preview is showing.
        case snapping(action: WindowAction, windowElement: AXUIElement, screen: NSScreen)
    }

    private var state: State = .idle
    /// Last-seen snap action — when the user drops, we commit this.
    nonisolated(unsafe) private var lastSnapAction: WindowAction?

    private init() {}

    // MARK: - Lifecycle

    private func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<DragSnapController>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.shared.log("DragSnapController: failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.shared.log("Drag-to-snap listener started")
    }

    private func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        Task { @MainActor in
            self.state = .idle
            self.previewWindow.hide()
        }
        Logger.shared.log("Drag-to-snap listener stopped")
    }

    // MARK: - Event handler (runs off main thread)

    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tap = self.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passRetained(event)
        }

        let location = event.location

        switch type {
        case .leftMouseDown:
            Task { @MainActor in self.onMouseDown(at: location) }
        case .leftMouseDragged:
            Task { @MainActor in self.onMouseDragged(to: location) }
        case .leftMouseUp:
            // Capture current snap target synchronously so mouseUp can commit
            // before any further events arrive.
            let target = lastSnapAction
            Task { @MainActor in self.onMouseUp(at: location, lastSnap: target) }
        default:
            break
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - State transitions (main-thread only)

    private func onMouseDown(at cursor: CGPoint) {
        guard isEnabled else { return }

        // Check if the click landed in the title bar area of a window.
        guard let window = windowUnder(cursor: cursor),
              isLikelyTitleBar(click: cursor, onWindow: window) else {
            state = .idle
            return
        }

        // Per-app opt-out: some apps (Xcode, Photoshop) don't play well with
        // forced AX resize. Keyboard shortcuts still work for them — the user
        // is explicit there. Drag-to-snap steps out of the way.
        if let bundleID = bundleID(of: window),
           AppSettings.shared.windowSnapExcludedBundleIDs.contains(bundleID) {
            state = .idle
            return
        }

        let screen = screenContaining(point: cursor) ?? NSScreen.main
        guard let screen else { state = .idle; return }

        // Capture the window's current origin so we can detect actual
        // window movement during the drag. Don't unsnap yet — that
        // happens in onMouseDragged once we've confirmed this is a real
        // drag and not a click on (e.g.) a Chrome tab.
        let downOrigin = WindowManager.shared.publicFrame(of: window)?.origin ?? .zero
        state = .pendingDrag(
            windowElement: window,
            screen: screen,
            downCursor: cursor,
            downWindowOrigin: downOrigin
        )
        lastSnapAction = nil
    }

    private func bundleID(of window: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func onMouseDragged(to cursor: CGPoint) {
        switch state {
        case .idle:
            return
        case .pendingDrag(let window, let screen, let downCursor, let downOrigin):
            // Has the cursor moved enough AND the window actually started
            // moving? If both, this is a real drag — unsnap and promote
            // to tracking. If just the cursor moved (e.g. user dragging
            // a Chrome tab while the window stays put), stay pending.
            let cursorDelta = hypot(cursor.x - downCursor.x, cursor.y - downCursor.y)
            guard cursorDelta >= activation.cursorActivationThreshold else { return }

            let currentOrigin = WindowManager.shared.publicFrame(of: window)?.origin ?? downOrigin
            let windowDelta = hypot(currentOrigin.x - downOrigin.x, currentOrigin.y - downOrigin.y)
            guard activation.shouldActivate(cursorDelta: cursorDelta, windowDelta: windowDelta) else {
                return
            }

            WindowManager.shared.unsnapIfNeeded(element: window, cursor: cursor)
            state = .tracking(windowElement: window, screen: screen)
            applySnapZone(for: cursor, on: screen, window: window)
        case .tracking(let element, let screen),
             .snapping(_, let element, let screen):
            applySnapZone(for: cursor, on: screen, window: element)
        }
    }

    private func onMouseUp(at cursor: CGPoint, lastSnap: WindowAction?) {
        defer {
            state = .idle
            lastSnapAction = nil
            previewWindow.hide()
        }
        guard case .snapping(let action, let element, _) = state else { return }
        _ = action
        // Slight delay so the preview has a moment to fade — cosmetic.
        // Snap happens immediately; the preview just lingers briefly.
        setWindowFrame(element, toActionFor: action, cursor: cursor, lastSnap: lastSnap)
    }

    /// Inspect cursor location, figure out which zone it's in (if any), and
    /// either show the preview for that zone or hide it.
    private func applySnapZone(for cursor: CGPoint, on screen: NSScreen, window: AXUIElement) {
        guard let action = snapZone(for: cursor, screen: screen) else {
            if case .snapping = state {
                state = .tracking(windowElement: window, screen: screen)
                previewWindow.hide()
            }
            lastSnapAction = nil
            return
        }

        let visibleFrame = axVisibleFrame(of: screen)
        guard let target = action.targetFrame(
            visibleFrame: visibleFrame,
            currentFrame: WindowManager.shared.publicFrame(of: window) ?? visibleFrame
        ) else { return }

        previewWindow.show(frame: target, on: screen)
        state = .snapping(action: action, windowElement: window, screen: screen)
        lastSnapAction = action
    }

    private func setWindowFrame(_ element: AXUIElement, toActionFor action: WindowAction, cursor: CGPoint, lastSnap: WindowAction?) {
        // Give AX a moment — macOS may still be processing the end-of-drag.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            _ = WindowManager.shared.perform(action, on: element)
        }
    }

    // MARK: - Zone detection

    /// Describes which edges of a screen border another display — those edges
    /// should skip snap detection when the user has enabled that preference,
    /// so dragging from screen A to screen B doesn't accidentally half-snap
    /// at the border.
    struct BorderingEdges: OptionSet {
        let rawValue: Int
        static let left   = Self(rawValue: 1 << 0)
        static let right  = Self(rawValue: 1 << 1)
        static let top    = Self(rawValue: 1 << 2)
        static let bottom = Self(rawValue: 1 << 3)
    }

    /// Detect which edges of `screen` neighbor another NSScreen. A pair of
    /// screens "border" if they share an edge and their perpendicular ranges
    /// overlap by at least a meaningful amount (we use 1pt).
    static func borderingEdges(of screen: NSScreen, among all: [NSScreen]) -> BorderingEdges {
        var result: BorderingEdges = []
        let f = screen.frame
        for other in all where other != screen {
            let o = other.frame
            // Right of self touches left of other.
            if abs(f.maxX - o.minX) < 1 && verticalOverlap(f, o) > 0 {
                result.insert(.right)
            }
            if abs(f.minX - o.maxX) < 1 && verticalOverlap(f, o) > 0 {
                result.insert(.left)
            }
            if abs(f.maxY - o.minY) < 1 && horizontalOverlap(f, o) > 0 {
                result.insert(.top)
            }
            if abs(f.minY - o.maxY) < 1 && horizontalOverlap(f, o) > 0 {
                result.insert(.bottom)
            }
        }
        return result
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    private func snapZone(for cursor: CGPoint, screen: NSScreen) -> WindowAction? {
        let frame = screen.frame

        // If the user wants cross-display drags to stay clean, skip snap
        // detection on edges that border another display.
        let skip: BorderingEdges = AppSettings.shared.windowMultiDisplayBorder
            ? Self.borderingEdges(of: screen, among: NSScreen.screens)
            : []

        let nearTop = !skip.contains(.top) && cursor.y >= frame.maxY - edgeThreshold
        let nearBottom = !skip.contains(.bottom) && cursor.y <= frame.minY + edgeThreshold
        let nearLeft = !skip.contains(.left) && cursor.x <= frame.minX + edgeThreshold
        let nearRight = !skip.contains(.right) && cursor.x >= frame.maxX - edgeThreshold

        // Corner zones — both edges close enough. Corners ALSO skipped if
        // either constituent edge borders another screen, since the cursor is
        // headed across the boundary.
        let inTopLeft = !skip.contains(.top) && !skip.contains(.left)
            && cursor.x <= frame.minX + cornerThreshold
            && cursor.y >= frame.maxY - cornerThreshold
        let inTopRight = !skip.contains(.top) && !skip.contains(.right)
            && cursor.x >= frame.maxX - cornerThreshold
            && cursor.y >= frame.maxY - cornerThreshold
        let inBottomLeft = !skip.contains(.bottom) && !skip.contains(.left)
            && cursor.x <= frame.minX + cornerThreshold
            && cursor.y <= frame.minY + cornerThreshold
        let inBottomRight = !skip.contains(.bottom) && !skip.contains(.right)
            && cursor.x >= frame.maxX - cornerThreshold
            && cursor.y <= frame.minY + cornerThreshold

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

    // MARK: - AX helpers

    private func windowUnder(cursor: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            system,
            Float(cursor.x),
            Float(cgEventYtoAXY(cursor.y)),
            &element
        )
        guard status == .success, let element else { return nil }
        hit = element

        // Walk up the parent chain until we find an AXWindow.
        var current: AXUIElement? = hit
        while let node = current {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWindow" { return node }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent)
            guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func isLikelyTitleBar(click: CGPoint, onWindow window: AXUIElement) -> Bool {
        // Get window's screen-space position via AX.
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionRef else { return false }
        var position = CGPoint.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        // Position is AX-space (top-left origin). Click is in CGEvent space
        // (also top-left origin). Direct compare.
        let axClickY = cgEventYtoAXY(click.y)
        return abs(axClickY - position.y) < titleBarDepth
    }

    // MARK: - Coordinate helpers

    /// CGEvent locations use the system's top-left origin — same as AX for
    /// the primary display — but multi-display setups have the screens laid
    /// out in NSScreen space (bottom-left) and we need the AX equivalent.
    /// For the primary display it's a pass-through.
    nonisolated private func cgEventYtoAXY(_ y: CGFloat) -> CGFloat {
        y
    }

    private func axVisibleFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.snapFrame
        let axY = primaryHeight - vf.maxY
        return CGRect(x: vf.origin.x, y: axY, width: vf.width, height: vf.height)
    }

    private func screenContaining(point: CGPoint) -> NSScreen? {
        // CGEvent.location uses primary-display-top-left coords; flip to
        // NSScreen space.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        return NSScreen.screens.first(where: { $0.frame.contains(nsPoint) })
    }
}

// MARK: - WindowManager bridge

extension WindowManager {
    /// Perform an action on a specific AXUIElement (rather than the focused
    /// window). Used by DragSnapController to snap the window the user was
    /// dragging, which might not match `focusedWindowElement()` by the time
    /// mouseUp fires.
    @MainActor
    public func perform(_ action: WindowAction, on element: AXUIElement) -> Bool {
        let current = publicFrame(of: element) ?? .zero
        guard let screen = NSScreen.main else { return false }
        if DockHealth.healIfStuck(screen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                _ = self?.perform(action, on: element)
            }
            return true
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.snapFrame
        let visible = CGRect(
            x: vf.origin.x,
            y: primaryHeight - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        guard let target = action.targetFrame(visibleFrame: visible, currentFrame: current) else {
            return false
        }
        rememberFrame(current, for: element)
        setFrame(target, on: element)
        if WindowManager.isSnapAction(action) {
            markSnapped(element, preSnap: current)
        } else {
            clearSnapMark(for: element)
        }
        return true
    }

    /// Publicly-readable AX frame for a window. Used by DragSnapController.
    @MainActor
    public func publicFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let positionRef {
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        }
        if let sizeRef {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

}
