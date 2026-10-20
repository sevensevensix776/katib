import Foundation
import Carbon.HIToolbox
import KatibCore

/// A single hotkey binding for a WindowAction. Persisted as two ints in
/// UserDefaults. `keyCode == 0` means unbound.
public struct WindowBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32 = 0, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isBound: Bool { keyCode > 0 }

    /// Keycodes macOS hardware-remaps from fn+arrow. On a laptop the user
    /// thinks of "fn+←" — showing "Home" in the UI is disorienting.
    private static let fnRemappedDisplay: [UInt32: (key: String, arrow: String)] = [
        115: ("Home", "←"),
        119: ("End", "→"),
        116: ("PageUp", "↑"),
        121: ("PageDown", "↓"),
        117: ("Delete", "⌦")
    ]

    /// Human-readable shortcut string. When the keycode is a fn-remapped
    /// one (Home/End/PgUp/PgDn/FwdDelete), we show the form the user
    /// actually presses: `fn ⌃⌥⌘ ←` instead of `⌃⌥⌘ Home`.
    public var displayString: String {
        guard isBound else { return "" }
        var parts: [String] = []
        let isFnRemapped = Self.fnRemappedDisplay[keyCode] != nil
        if isFnRemapped || modifiers & FnHotkeyTap.fnFlag != 0 { parts.append("fn") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        let keyLabel = Self.fnRemappedDisplay[keyCode]?.arrow ?? keyCodeName(UInt16(keyCode))
        parts.append(keyLabel)
        return parts.joined(separator: parts.first == "fn" ? " " : "")
    }
}

/// Named sets of bindings the user can apply in one click from Settings or
/// the first-run sheet. Values mirror what the app ships with defaults.
public enum WindowPreset: String, CaseIterable, Identifiable, Sendable {
    case rectangle
    case bettersnaptool
    case empty

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .rectangle: return "Rectangle defaults (⌃⌥ + arrows)"
        case .bettersnaptool: return "Match BetterSnapTool (⌃⌥⌘ + Home/End/PageUp)"
        case .empty: return "No bindings (I'll set my own)"
        }
    }

    public func bindings() -> [WindowAction: WindowBinding] {
        switch self {
        case .rectangle:
            let ctrlOpt = UInt32(controlKey | optionKey)
            let ctrlOptShift = ctrlOpt | UInt32(shiftKey)
            let ctrlOptCmd = ctrlOpt | UInt32(cmdKey)
            return [
                .leftHalf: .init(keyCode: 123, modifiers: ctrlOpt),    // ⌃⌥←
                .rightHalf: .init(keyCode: 124, modifiers: ctrlOpt),   // ⌃⌥→
                .topHalf: .init(keyCode: 126, modifiers: ctrlOpt),     // ⌃⌥↑
                .bottomHalf: .init(keyCode: 125, modifiers: ctrlOpt),  // ⌃⌥↓
                .maximize: .init(keyCode: 36, modifiers: ctrlOpt),     // ⌃⌥↩
                .center: .init(keyCode: 8, modifiers: ctrlOpt),        // ⌃⌥C
                .topLeftQuarter: .init(keyCode: 32, modifiers: ctrlOpt),     // ⌃⌥U
                .topRightQuarter: .init(keyCode: 34, modifiers: ctrlOpt),    // ⌃⌥I
                .bottomLeftQuarter: .init(keyCode: 38, modifiers: ctrlOpt),  // ⌃⌥J
                .bottomRightQuarter: .init(keyCode: 40, modifiers: ctrlOpt), // ⌃⌥K
                .nextDisplay: .init(keyCode: 124, modifiers: ctrlOptCmd),    // ⌃⌥⌘→
                .previousDisplay: .init(keyCode: 123, modifiers: ctrlOptCmd),// ⌃⌥⌘←
                .restore: .init(keyCode: 27, modifiers: ctrlOpt),            // ⌃⌥-
                .almostMaximize: .init(keyCode: 36, modifiers: ctrlOptShift)// ⌃⌥⇧↩
            ]
        case .bettersnaptool:
            let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)
            return [
                .leftHalf: .init(keyCode: 115, modifiers: ctrlOptCmd),   // Home
                .rightHalf: .init(keyCode: 119, modifiers: ctrlOptCmd),  // End
                .maximize: .init(keyCode: 116, modifiers: ctrlOptCmd)   // Page Up
            ]
        case .empty:
            return [:]
        }
    }
}

/// Produces a short label like "←" or "Home" for a Carbon key code.
/// A big switch, but it's a lookup table — not genuine complexity.
// swiftlint:disable:next cyclomatic_complexity function_body_length
public func keyCodeName(_ code: UInt16) -> String {
    switch Int(code) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_Return: return "↩"
    case kVK_Escape: return "⎋"
    case kVK_Space: return "Space"
    case kVK_Tab: return "⇥"
    case kVK_Delete: return "⌫"
    case kVK_Home: return "Home"
    case kVK_End: return "End"
    case kVK_PageUp: return "Page Up"
    case kVK_PageDown: return "Page Down"
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Slash: return "/"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return "?\(code)"
    }
}
