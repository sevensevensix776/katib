import Foundation
import AppKit

#if DEBUG

/// Diagnostic listener on HotkeyTapRouter. When on, every keyDown with
/// modifier keys held gets logged as `[KEYDEBUG] keyCode=X flags=Y (⌃⌥⌘...)`.
/// Lets us distinguish "Carbon didn't deliver the event" from "Carbon
/// delivered something we didn't expect" when hotkeys don't fire.
///
/// DEBUG-only — stripped from release builds entirely. Previously owned
/// its own CGEventTap; now piggybacks on HotkeyTapRouter's shared one.
@MainActor
public final class KeystrokeDebugTap {
    public static let shared = KeystrokeDebugTap()

    private var listenerToken: HotkeyTapRouter.Token?

    public var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled {
                install()
            } else {
                uninstall()
            }
        }
    }

    private init() {}

    private func install() {
        guard listenerToken == nil else { return }
        listenerToken = HotkeyTapRouter.shared.registerListener { keyCode, flags in
            // Only log when at least one modifier is held — skip ambient typing.
            guard flags != 0 else { return }
            Logger.shared.log("[KEYDEBUG] keyCode=\(keyCode) flags=\(flags) (\(Self.describe(flags: flags)))")
        }
        Logger.shared.log("KeystrokeDebugTap: listening via router")
    }

    private func uninstall() {
        if let token = listenerToken {
            HotkeyTapRouter.shared.remove(token)
            listenerToken = nil
            Logger.shared.log("KeystrokeDebugTap: stopped listening")
        }
    }

    nonisolated private static func describe(flags: UInt64) -> String {
        var parts: [String] = []
        if flags & CGEventFlags.maskSecondaryFn.rawValue != 0 { parts.append("fn") }
        if flags & CGEventFlags.maskControl.rawValue != 0 { parts.append("⌃") }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if flags & CGEventFlags.maskShift.rawValue != 0 { parts.append("⇧") }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { parts.append("⌘") }
        return parts.joined()
    }
}

#else

/// Release-mode stub. Preserves the call-site shape so AppDelegate's
/// wiring doesn't need `#if DEBUG` guards.
@MainActor
public final class KeystrokeDebugTap {
    public static let shared = KeystrokeDebugTap()
    public var isEnabled: Bool = false
    private init() {}
}

#endif
