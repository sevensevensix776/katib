import AppIntents
import AppKit
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot

/// Expose Katib actions to Spotlight, Shortcuts, and Siri via the App Intents
/// framework. macOS 26 pushes this hard — free integration for 15 min of code.
///
/// Shortcuts users can now chain "Re-paste last transcription" with anything
/// else (send Slack message, append to Notion, etc.). Spotlight shows these
/// as top-of-results actions when the user searches "paste last" etc.

struct RePasteLastTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste last transcription again"
    static let description = IntentDescription(
        "Re-pastes the most recent dictation into the currently focused text field."
    )
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Hop to AppDelegate — it owns lastTranscription + outputManager.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.performRePasteLastViaIntent()
        }
        return .result()
    }
}

struct OpenKatibCorrectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Katib corrections editor"
    static let description = IntentDescription(
        "Opens the Katib window where you can edit casing fixes, rewrites, and phrase corrections."
    )
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.performOpenCorrectionsViaIntent()
        }
        return .result()
    }
}

struct CaptureScreenRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture screen region with Katib"
    static let description = IntentDescription(
        "Drag to select a region, then annotate and copy or save. Screen Recording permission required on first use."
    )
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        ScreenshotManager.shared.startCapture()
        return .result()
    }
}

struct KatibShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RePasteLastTranscriptionIntent(),
            phrases: [
                "Paste last \(.applicationName) dictation",
                "Re-paste in \(.applicationName)"
            ],
            shortTitle: "Paste Again",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: OpenKatibCorrectionsIntent(),
            phrases: [
                "Open \(.applicationName) corrections",
                "Edit \(.applicationName) dictionary"
            ],
            shortTitle: "Corrections",
            systemImageName: "character.book.closed"
        )
        AppShortcut(
            intent: CaptureScreenRegionIntent(),
            phrases: [
                "Capture region with \(.applicationName)",
                "\(.applicationName) screenshot"
            ],
            shortTitle: "Capture",
            systemImageName: "camera.viewfinder"
        )
    }
}
