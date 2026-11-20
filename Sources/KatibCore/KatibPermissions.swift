import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

/// Every system permission Katib uses, in one table (the Rex "Manage
/// Permissions" pattern, cerebro-prds agent-docs/MACOS_PERMISSIONS_ONBOARDING.md).
/// The sheet, the welcome step and the tests all read this table, so a new
/// permission shows up everywhere once it has a row.
///
/// Notifications: Katib posts none (no UserNotifications use in Sources), so
/// it has no row. `KatibPermissionsCoverageTests` fails if that changes.
public struct KatibPermission: Identifiable, Equatable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case microphone, speechRecognition, accessibility, screenRecording
    }

    /// How "Grant…" works. macOS lets some prompts appear in place; the
    /// list-type panes (Accessibility, Screen Recording) only take a switch
    /// flipped in System Settings.
    public enum GrantMode: Sendable {
        case askInPlace
        case openPane
    }

    public let id: ID
    /// SF Symbol shown in the row.
    public let symbol: String
    /// The name System Settings shows for the pane.
    public let name: String
    /// One plain line on what Katib does with it.
    public let why: String
    public let required: Bool
    public let pane: SettingsPane
    public let grantMode: GrantMode
    /// True for panes where the person adds the app by dragging its icon in.
    public let needsDrag: Bool
    /// Names of the OS calls Katib makes for this permission. The coverage
    /// test greps Sources for each marker and fails when a marker used in
    /// code belongs to no row.
    public let apiMarkers: [String]

    /// Accessibility is "Device Control and Data Access" from macOS 27.
    public static func accessibilityName(osMajorVersion: Int) -> String {
        osMajorVersion >= 27 ? SettingsPane.accessibility.title : "Accessibility"
    }

    /// OS API names that need a row if any Sources file uses them. A marker
    /// with no row (UNUserNotificationCenter today) fails the coverage test.
    public static let watchedMarkers: [String] = [
        "AXIsProcessTrusted",
        "CGPreflightScreenCaptureAccess",
        "CGRequestScreenCaptureAccess",
        "AVCaptureDevice",
        "AVAudioApplication",
        "SFSpeechRecognizer",
        "UNUserNotificationCenter"
    ]

    public static let all: [KatibPermission] = [
        KatibPermission(
            id: .microphone,
            symbol: "mic.fill",
            name: "Microphone",
            why: "Lets Katib hear you while you hold the dictation key.",
            required: true,
            pane: .microphone,
            grantMode: .askInPlace,
            needsDrag: false,
            apiMarkers: ["AVCaptureDevice", "AVAudioApplication"]
        ),
        KatibPermission(
            id: .speechRecognition,
            symbol: "waveform",
            name: "Speech Recognition",
            why: "Lets Katib turn your voice into text on your Mac. Nothing leaves it.",
            required: true,
            pane: .speechRecognition,
            grantMode: .askInPlace,
            needsDrag: false,
            apiMarkers: ["SFSpeechRecognizer"]
        ),
        KatibPermission(
            id: .accessibility,
            symbol: "keyboard",
            name: accessibilityName(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            why: "Lets Katib see the dictation key and type your dictation into the app you are using.",
            required: true,
            pane: .accessibility,
            grantMode: .openPane,
            needsDrag: true,
            apiMarkers: ["AXIsProcessTrusted"]
        ),
        KatibPermission(
            id: .screenRecording,
            symbol: "rectangle.dashed.badge.record",
            name: SettingsPane.screenRecording.title,
            why: "Lets Katib capture the screen for ⇧⌘3 and ⇧⌘4 screenshots.",
            required: false,
            pane: .screenRecording,
            grantMode: .openPane,
            needsDrag: false,
            apiMarkers: ["CGPreflightScreenCaptureAccess", "CGRequestScreenCaptureAccess"]
        )
    ]

    public static func row(_ id: ID) -> KatibPermission {
        // `all` holds one row per ID (the coverage test checks it).
        all.first { $0.id == id } ?? all[0]
    }

    // MARK: - Check

    /// Reads the live state from the OS. Cheap enough to call every second.
    public static func isGranted(_ id: ID) -> Bool {
        switch id {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Grant

    /// Ask in place where macOS allows it, otherwise open the exact pane.
    @MainActor
    public static func grant(_ id: ID) {
        switch id {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                // TCC calls back off the main queue; `@Sendable` keeps Swift 6
                // from inferring @MainActor and trapping (see MenuBarView).
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in }
            } else {
                SettingsPane.microphone.open()
            }
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { @Sendable _ in }
            } else {
                SettingsPane.speechRecognition.open()
            }
        case .accessibility:
            // Literal key: kAXTrustedCheckOptionPrompt is a non-Sendable
            // global CFString under Swift 6. The string is ABI.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if !AXIsProcessTrusted() { SettingsPane.accessibility.open() }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() { SettingsPane.screenRecording.open() }
        }
    }
}

/// Quit and open Katib again. A Screen Recording grant applies only to a new
/// process. `open` waits for this one to exit (the single-instance lock) via
/// the short sleep.
public enum AppRelaunch {
    @MainActor
    public static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
