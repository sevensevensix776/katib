import AppKit
import Foundation

/// Every System Settings pane Katib links to, in one table. Callers use
/// `SettingsPane.x.open()` instead of hand-writing `x-apple.systempreferences:`
/// strings (there were 17 copies of the legacy pre-Ventura form).
///
/// IDs are the pane extension bundle IDs that ship in
/// `/System/Library/ExtensionKit/Extensions/*.appex` on macOS 26/27. The
/// `Privacy_*` anchors select the sub-pane inside Privacy & Security.
/// Verified 2026-10-06 on macOS 27.0 (26A428): each URL opened the pane whose
/// window title is `title` (the legacy `com.apple.preference.security?…` form
/// still works too). macOS 27 renamed Accessibility to "Device Control and
/// Data Access" and folds Apple Intelligence into the Siri pane.
public enum SettingsPane: String, CaseIterable, Sendable {
    case accessibility
    case inputMonitoring
    case microphone
    case speechRecognition
    case screenRecording
    case siri
    case keyboard
    case loginItems
    case notifications

    public var title: String {
        switch self {
        case .accessibility: return "Device Control and Data Access"
        case .inputMonitoring: return "Input Monitoring"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen & System Audio Recording"
        case .siri: return "Siri"
        case .keyboard: return "Keyboard"
        case .loginItems: return "Login Items"
        case .notifications: return "Notifications"
        }
    }

    public var url: URL {
        let base = "x-apple.systempreferences:"
        let privacy = "com.apple.settings.PrivacySecurity.extension"
        let path: String
        switch self {
        case .accessibility: path = "\(privacy)?Privacy_Accessibility"
        case .inputMonitoring: path = "\(privacy)?Privacy_ListenEvent"
        case .microphone: path = "\(privacy)?Privacy_Microphone"
        case .speechRecognition: path = "\(privacy)?Privacy_SpeechRecognition"
        case .screenRecording: path = "\(privacy)?Privacy_ScreenCapture"
        case .siri: path = "com.apple.Siri-Settings.extension"
        case .keyboard: path = "com.apple.Keyboard-Settings.extension"
        case .loginItems: path = "com.apple.LoginItems-Settings.extension"
        case .notifications: path = "com.apple.Notifications-Settings.extension"
        }
        // Every path above is a fixed ASCII literal, so this cannot fail.
        return URL(string: base + path)!
    }

    @MainActor
    public func open() {
        NSWorkspace.shared.open(url)
    }
}
