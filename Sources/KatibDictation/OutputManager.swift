import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KatibCore

/// Pastes text at the cursor via clipboard + Cmd+V. Saves + restores the user's clipboard.
///
/// Safeguards:
/// - Secure-text-field guard: never paste into a field flagged as AXSecureTextField.
/// - Focus-change check: paste only if the frontmost app matches the one that
///   was frontmost when recording started.
/// - Control-char strip: tabs + newlines stay, raw ESC / bell / etc are scrubbed.
@MainActor
public final class OutputManager {
    public static let shared = OutputManager()

    private let pasteboard = NSPasteboard.general

    private init() {}

    public enum PasteResult {
        case ok
        case refusedSecureField
        case refusedFocusChanged(from: String?, to: String?)
    }

    /// Paste text at the cursor, preserving the user's clipboard.
    /// - Parameter expectedApp: localized name of the app that was frontmost
    ///   when recording started. If current frontmost app differs, paste is refused.
    @discardableResult
    public func pasteText(_ text: String, expectedApp: String? = nil) -> PasteResult {
        let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName
        if let expected = expectedApp, expected != currentApp {
            Logger.shared.log("Paste refused: focus changed from \(expected) to \(currentApp ?? "?")")
            return .refusedFocusChanged(from: expected, to: currentApp)
        }

        if isFocusedFieldSecure() {
            Logger.shared.log("Paste refused: secure text field focused")
            return .refusedSecureField
        }

        let safe = strippedOfControlChars(text)

        let saved = savePasteboard()
        pasteboard.clearContents()
        pasteboard.setString(safe, forType: .string)
        // Marker so ClipboardManager's watcher doesn't capture our own paste.
        pasteboard.setData(Data(), forType: KatibPasteboard.katibMarkerType)

        // Defense-in-depth weak captures. OutputManager is a singleton
        // so a strong capture wouldn't leak in practice, but if the
        // singleton ever turns into a per-recording instance the
        // strong refs would extend lifetime past restorePasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulatePaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.restorePasteboard(saved)
            }
        }

        return .ok
    }

    /// Cmd+Z to active app — works for anything with a normal undo stack.
    public func undoLastPaste() {
        postModifierKey(kVK_ANSI_Z, flag: .maskCommand)
        Logger.shared.log("Sent Cmd+Z for undo")
    }

    // MARK: - Safety

    private func isFocusedFieldSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return false }
        // typeID-checked above, safe. swiftlint:disable:next force_cast
        let axElement = focusedElement as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        return (role as? String) == "AXSecureTextField"
    }

    private func strippedOfControlChars(_ text: String) -> String {
        text.unicodeScalars.filter { scalar in
            if scalar == "\t" || scalar == "\n" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }.map { String($0) }.joined()
    }

    // MARK: - Clipboard preservation

    private func savePasteboard() -> [(NSPasteboard.PasteboardType, Data)] {
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }
        return saved
    }

    private func restorePasteboard(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let newItem = NSPasteboardItem()
        for (type, data) in items {
            newItem.setData(data, forType: type)
        }
        pasteboard.writeObjects([newItem])
    }

    // MARK: - Keyboard simulation

    private func simulatePaste() {
        postModifierKey(kVK_ANSI_V, flag: .maskCommand)
    }

    private func postModifierKey(_ keyCode: Int, flag: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            Logger.shared.log("OutputManager: Failed to create key events for \(keyCode)")
            return
        }
        down.flags = flag
        up.flags = flag
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
