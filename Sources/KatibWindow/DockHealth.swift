import AppKit
import KatibCore

/// Detects and heals the "stuck Dock" state seen on macOS 27.0 (26A428),
/// 2026-10-06: the Dock is set to auto-hide and has no window on screen, yet
/// the system reserves its space. `visibleFrame` shrinks AND the window server
/// clamps windows above the Dock line, so no app can fill to the bottom.
/// `snapFrame` alone cannot beat the clamp. Restarting the Dock clears it.
///
/// Safety: heals only when all three hold (auto-hide on, Dock space reserved,
/// no Dock window on screen), so a Dock you revealed on purpose is never
/// touched. At most one restart per 5 minutes; if a restart does not clear
/// it, Katib logs and stops trying instead of looping.
@MainActor
enum DockHealth {
    private static var lastHeal: Date?
    private static let minInterval: TimeInterval = 300

    static func isStuck(_ screen: NSScreen) -> Bool {
        guard NSScreen.dockAutohides() else { return false }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let inset: CGFloat
        switch NSScreen.dockEdge() {
        case .minX: inset = visible.minX - frame.minX
        case .maxX: inset = frame.maxX - visible.maxX
        default: inset = visible.minY - frame.minY
        }
        // An auto-hidden Dock reserves a few points at most.
        guard inset > 20 else { return false }
        return !dockHasWindowOnScreen()
    }

    /// Restart the Dock if it is stuck. Returns true when a restart was issued,
    /// so the caller can redo its snap once the Dock is back (~1 s).
    @discardableResult
    static func healIfStuck(_ screen: NSScreen) -> Bool {
        guard isStuck(screen) else { return false }
        if let last = lastHeal, Date().timeIntervalSince(last) < minInterval {
            Logger.shared.log("DockHealth: Dock still stuck after a restart \(Int(Date().timeIntervalSince(last)))s ago; not retrying")
            return false
        }
        lastHeal = Date()
        Logger.shared.log("DockHealth: Dock auto-hides but reserves space with no window on screen; restarting Dock")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        do { try p.run() } catch {
            Logger.shared.log("DockHealth: killall Dock failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private static func dockHasWindowOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return true   // cannot tell: assume visible, never restart blind
        }
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
    }
}
