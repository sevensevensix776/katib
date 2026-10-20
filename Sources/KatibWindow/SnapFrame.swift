import AppKit

/// The area windows snap into: `visibleFrame`, minus the Dock inset when the
/// Dock auto-hides.
///
/// Why: on macOS 27.0 (26A428), 2026-10-06, `NSScreen.visibleFrame` reserved
/// 86 pt at the bottom for the Dock while the Dock was set to auto-hide and
/// had no window on screen. A fresh process saw it; a long-running one kept
/// its launch-time value. Half-screen snaps stopped 86 pt short of the bottom.
/// An auto-hidden Dock slides over windows, so it should not shrink the area.
extension NSScreen {
    var snapFrame: CGRect {
        Self.snapFrame(frame: frame, visible: visibleFrame,
                       dockAutohides: Self.dockAutohides(), dockEdge: Self.dockEdge())
    }

    /// Pure core, testable. The top inset (menu bar) always stays; only the
    /// Dock's edge is given back.
    static func snapFrame(frame: CGRect, visible: CGRect, dockAutohides: Bool, dockEdge: NSRectEdge) -> CGRect {
        guard dockAutohides else { return visible }
        var r = visible
        switch dockEdge {
        case .minY:
            r.size.height += r.minY - frame.minY
            r.origin.y = frame.minY
        case .minX:
            r.size.width += r.minX - frame.minX
            r.origin.x = frame.minX
        case .maxX:
            r.size.width = frame.maxX - r.minX
        default:
            break
        }
        return r
    }

    static func dockAutohides() -> Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }

    /// Dock `orientation`: "bottom" (default, key absent), "left" or "right".
    static func dockEdge() -> NSRectEdge {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "left": return .minX
        case "right": return .maxX
        default: return .minY
        }
    }
}
