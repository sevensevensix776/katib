import Foundation
import AppKit
import AVFoundation
import Speech
import KatibCore

/// Popover-owned reactive state. Exists so MenuBarView's hosting controller
/// can be built ONCE in setupMenuBar — the view observes this, gets fresh
/// data without the controller being torn down and rebuilt on every open.
///
/// AppDelegate owns a singleton, bumps it when a new dictation lands or when
/// the user toggles the popover open.
@MainActor
public final class PopoverState: ObservableObject {
    public static let shared = PopoverState()

    @Published public var lastTranscription: String?
    @Published public var microphoneGranted: Bool = true
    @Published public var speechGranted: Bool = true
    @Published public var screenRecordingGranted: Bool = true

    /// In-memory ring of the last N transcriptions (newest first). Not persisted
    /// so we don't have plaintext content on disk; survives only until the app
    /// restarts. Popover surfaces these as "Paste earlier…" entries.
    @Published public private(set) var recent: [String] = []
    private let recentCap = 5

    private init() {
        refreshPermissions()
    }

    public func pushRecent(_ text: String) {
        lastTranscription = text
        var next = recent.filter { $0 != text }
        next.insert(text, at: 0)
        if next.count > recentCap { next.removeLast(next.count - recentCap) }
        recent = next
    }

    public func clearRecent() {
        recent = []
        lastTranscription = nil
    }

    /// Snap current permission status into the published flags.
    public func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }
}
