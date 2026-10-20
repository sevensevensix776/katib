import Foundation
import AppKit
import KatibCore

/// Global hotkeys for region-capture screenshots. Backed by the shared
/// `HotkeyTapRouter` CGEventTap.
///
/// Two bindings, one manager:
/// - **quick**: capture → auto-copy to clipboard, skipping the annotation
///   editor (default ⇧⌘3).
/// - **annotate**: capture → open the annotation editor (default ⇧⌘4).
///
/// Both combos are Apple-reserved at the system shortcut layer. That's fine —
/// CGEventTap sits ABOVE the system shortcut router, so our registration
/// consumes the event before Apple's screenshot service ever sees it.
/// Carbon couldn't do this (`RegisterEventHotKey` runs below the system
/// shortcut layer, so Apple always won).
@MainActor
public final class ScreenshotHotkeyManager {
    public static let shared = ScreenshotHotkeyManager()

    /// Fired on quick-capture hotkey. Set by AppDelegate.
    public var onQuickCapture: (() -> Void)?
    /// Fired on annotate-capture hotkey. Set by AppDelegate.
    public var onAnnotateCapture: (() -> Void)?

    private var quickToken: HotkeyTapRouter.Token?
    private var annotateToken: HotkeyTapRouter.Token?

    private init() {}

    @discardableResult
    public func installQuick(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let quickToken { HotkeyTapRouter.shared.remove(quickToken) }
        let flagMask = HotkeyTapRouter.cgFlagMask(carbonModifiers: modifiers)
        quickToken = HotkeyTapRouter.shared.registerConsumer(
            keyCode: keyCode,
            flagMask: flagMask
        ) { [weak self] in
            self?.onQuickCapture?()
        }
        Logger.shared.log("Screenshot quick hotkey installed (keyCode=\(keyCode), modifiers=\(modifiers))")
        return true
    }

    @discardableResult
    public func installAnnotate(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let annotateToken { HotkeyTapRouter.shared.remove(annotateToken) }
        let flagMask = HotkeyTapRouter.cgFlagMask(carbonModifiers: modifiers)
        annotateToken = HotkeyTapRouter.shared.registerConsumer(
            keyCode: keyCode,
            flagMask: flagMask
        ) { [weak self] in
            self?.onAnnotateCapture?()
        }
        Logger.shared.log("Screenshot annotate hotkey installed (keyCode=\(keyCode), modifiers=\(modifiers))")
        return true
    }

    public func uninstall() {
        if let quickToken { HotkeyTapRouter.shared.remove(quickToken) }
        if let annotateToken { HotkeyTapRouter.shared.remove(annotateToken) }
        quickToken = nil
        annotateToken = nil
    }
}
