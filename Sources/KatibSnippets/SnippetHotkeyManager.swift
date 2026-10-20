import Foundation
import AppKit
import KatibCore

/// Global hotkey for the snippets picker (default ⌃⌘Space). Thin wrapper
/// around the shared `HotkeyTapRouter` CGEventTap. Same shape as the other
/// migrated managers.
@MainActor
public final class SnippetHotkeyManager {
    public static let shared = SnippetHotkeyManager()

    public var onHotkey: (() -> Void)?

    private var token: HotkeyTapRouter.Token?

    private init() {}

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
        Logger.shared.log("Snippet hotkey installed (keyCode=\(keyCode), modifiers=\(modifiers))")
        return true
    }

    public func uninstall() {
        if let token {
            HotkeyTapRouter.shared.remove(token)
            self.token = nil
        }
    }
}
