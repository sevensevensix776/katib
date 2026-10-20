import Foundation
import AppKit
import KatibCore

/// Window-action hotkey registry backed by the shared `HotkeyTapRouter`.
///
/// This used to own its own `CGEventTap`. Now it's a thin wrapper that
/// converts `(keyCode, modifiers)` pairs into router `Consumer`
/// registrations. Same behaviour, one tap instead of one-per-feature.
///
/// Still lives in KatibWindow because the action type + normalization
/// rules (which keys are fn-remapped on laptops) are window-specific.
/// The router itself is action-agnostic.
@MainActor
public final class FnHotkeyTap {
    public static let shared = FnHotkeyTap()

    /// Custom bit we set on `WindowBinding.modifiers` when the user records
    /// fn as part of the combo. Lives well above Carbon's modifier range
    /// so stored values remain valid Carbon bitmasks (minus our fn bit).
    public nonisolated static let fnFlag: UInt32 = 0x0001_0000

    /// Keycodes macOS hardware-remaps when fn is held (fn+Left→Home etc.).
    /// On Apple laptops these keys don't fire WITHOUT fn, so the fn bit is
    /// redundant information and we strip it from both the registered
    /// binding and the runtime event so bindings recorded either way match.
    nonisolated private static let fnRemappedKeycodes: Set<UInt32> = [
        115, 116, 117, 119, 121  // Home, PageUp, ForwardDelete, End, PageDown
    ]

    private var tokensByAction: [WindowAction: HotkeyTapRouter.Token] = [:]

    private init() {}

    public func register(_ action: WindowAction, keyCode: UInt32, modifiers: UInt32) {
        // Remove any prior registration for this action first.
        unregister(action)
        let flagMask = Self.normalizedFlagMask(forKeyCode: keyCode, modifiers: modifiers)
        // For fn-remapped keycodes we also need to normalize the event's
        // flags at match time. Consumers match on the mask we store, so we
        // strip fn from both sides and let the router do bit-exact compare.
        let token = HotkeyTapRouter.shared.registerConsumer(
            keyCode: keyCode,
            flagMask: flagMask
        ) {
            Logger.shared.log("FnHotkeyTap: fired for \(action.rawValue)")
            WindowManager.shared.perform(action)
        }
        tokensByAction[action] = token

        // For fn-remapped keys, also register the variant WITHOUT the fn
        // bit so a dedicated Home/End key on a desktop keyboard triggers
        // the same action. Laptop (fn held) and desktop (no fn) both work.
        if Self.fnRemappedKeycodes.contains(keyCode) {
            // flagMask already has fn stripped by normalizedFlagMask, so the
            // single registration is enough — the tap's event-flag
            // normalization will match both cases.
        }
    }

    public func unregister(_ action: WindowAction) {
        if let token = tokensByAction.removeValue(forKey: action) {
            HotkeyTapRouter.shared.remove(token)
        }
    }

    public func unregisterAll() {
        for token in tokensByAction.values {
            HotkeyTapRouter.shared.remove(token)
        }
        tokensByAction.removeAll()
    }

    public nonisolated static func containsFn(_ modifiers: UInt32) -> Bool {
        modifiers & fnFlag != 0
    }

    /// Convert the composite modifier format (Carbon bits + our fn bit) to
    /// a CGEventFlags mask. fn bits on fn-remapped keycodes are stripped.
    nonisolated static func cgFlagMask(fromComposite modifiers: UInt32) -> UInt64 {
        let shiftKey: UInt32 = 0x0200
        let controlKey: UInt32 = 0x1000
        let optionKey: UInt32 = 0x0800
        let cmdKey: UInt32 = 0x0100
        var flags: UInt64 = 0
        if modifiers & shiftKey != 0 { flags |= CGEventFlags.maskShift.rawValue }
        if modifiers & controlKey != 0 { flags |= CGEventFlags.maskControl.rawValue }
        if modifiers & optionKey != 0 { flags |= CGEventFlags.maskAlternate.rawValue }
        if modifiers & cmdKey != 0 { flags |= CGEventFlags.maskCommand.rawValue }
        if modifiers & fnFlag != 0 { flags |= CGEventFlags.maskSecondaryFn.rawValue }
        return flags
    }

    nonisolated static func normalizedFlagMask(forKeyCode keyCode: UInt32, modifiers: UInt32) -> UInt64 {
        var mask = cgFlagMask(fromComposite: modifiers)
        if fnRemappedKeycodes.contains(keyCode) {
            mask &= ~CGEventFlags.maskSecondaryFn.rawValue
        }
        return mask
    }
}
