import Foundation
import AppKit
import KatibCore

/// Registers a global hotkey (default ⌥⌘V) that pops the clipboard picker
/// panel without moving keyboard focus away from the user's current app.
///
/// Backed by the shared `HotkeyTapRouter` CGEventTap. We used to use Carbon
/// `RegisterEventHotKey` but Carbon silently refuses events with the fn bit
/// set and can't override OS-reserved combos (⇧⌘3 etc.) — CGEventTap sits
/// above the system shortcut layer and handles both.
///
/// Keycode/modifiers are driven by `AppSettings.clipboardHotkeyCode` and
/// `AppSettings.clipboardHotkeyModifiers` so the user can rebind without a
/// rebuild. Modifier bits use the Carbon format (shiftKey=0x200 etc.) for
/// storage compatibility with older builds; converted to CGEventFlags at
/// registration time via `HotkeyTapRouter.cgFlagMask(carbonModifiers:)`.
@MainActor
public final class ClipboardHotkeyManager {
    public static let shared = ClipboardHotkeyManager()

    /// Fired on hotkey hit. Set by AppDelegate.
    public var onHotkey: (() -> Void)?

    private var token: HotkeyTapRouter.Token?

    private init() {}

    /// Register the current-setting hotkey. Safe to call repeatedly —
    /// unregisters any prior registration first. Returns `false` only if the
    /// tap itself couldn't be created (Accessibility denied); unlike Carbon,
    /// CGEventTap doesn't know if another app already owns the combo, so we
    /// always succeed here when permissions are in order.
    @discardableResult
    public func install(keyCode: UInt32, modifiers: UInt32) -> Bool {
        uninstall()
        let flagMask = HotkeyTapRouter.cgFlagMask(carbonModifiers: modifiers)
        token = HotkeyTapRouter.shared.registerConsumer(
            keyCode: keyCode,
            flagMask: flagMask
        ) { [weak self] in
            self?.onHotkey?()
        }
        Logger.shared.log("Clipboard hotkey installed (keyCode=\(keyCode), modifiers=\(modifiers))")
        return true
    }

    public func uninstall() {
        if let token {
            HotkeyTapRouter.shared.remove(token)
            self.token = nil
        }
    }
}
