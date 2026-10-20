import Foundation
import KatibClipboard
import KatibDictation
import KatibWindow

/// Voice-command registrations — phrases matched against the dictation
/// transcript that trigger actions instead of pasting text. Extracted
/// from AppDelegate so the regex+outcome table lives in one focused file.
extension AppDelegate {
    func setupVoiceCommands() {
        VoiceCommandMatcher.shared.register([
            // Text insertion — replace transcription with a specific string.
            VoiceCommand(
                displayName: "New paragraph",
                patterns: ["^(new|insert) paragraph$", "^paragraph break$"],
                outcome: .insertText("\n\n")
            ),
            VoiceCommand(
                displayName: "New line",
                patterns: ["^(new|insert) line$", "^line break$"],
                outcome: .insertText("\n")
            ),

            // Window snapping.
            VoiceCommand(
                displayName: "Split left",
                patterns: ["^(split|half|snap) left$", "^left half$"],
                outcome: .execute { _ = WindowManager.shared.perform(.leftHalf) }
            ),
            VoiceCommand(
                displayName: "Split right",
                patterns: ["^(split|half|snap) right$", "^right half$"],
                outcome: .execute { _ = WindowManager.shared.perform(.rightHalf) }
            ),
            VoiceCommand(
                displayName: "Maximize",
                patterns: ["^maximize$", "^(make )?full(screen)?$", "^fill screen$"],
                outcome: .execute { _ = WindowManager.shared.perform(.maximize) }
            ),
            VoiceCommand(
                displayName: "Center window",
                patterns: ["^center (window|this)?$", "^center it$"],
                outcome: .execute { _ = WindowManager.shared.perform(.center) }
            ),
            VoiceCommand(
                displayName: "Next display",
                patterns: ["^(move to )?next (display|monitor|screen)$"],
                outcome: .execute { _ = WindowManager.shared.perform(.nextDisplay) }
            ),

            // Katib self-commands.
            VoiceCommand(
                displayName: "Paste last",
                patterns: ["^paste (last|previous|again)$", "^repeat (last|paste)$"],
                outcome: .execute { [weak self] in self?.rePasteLast() }
            ),
            VoiceCommand(
                displayName: "Cancel",
                patterns: ["^(cancel|never mind|nevermind|scratch that|forget it)$"],
                outcome: .execute { /* no-op — just skips paste */ }
            ),
            VoiceCommand(
                displayName: "Open settings",
                patterns: ["^open (katib )?(settings|preferences)$"],
                outcome: .execute { [weak self] in self?.openSettingsWindow() }
            ),
            VoiceCommand(
                displayName: "Open corrections",
                patterns: ["^(open|edit) (katib )?corrections$", "^open dictionary$"],
                outcome: .execute { [weak self] in self?.openCorrectionsWindow() }
            ),
            VoiceCommand(
                displayName: "Show clipboard",
                patterns: ["^show clipboard( history)?$", "^clipboard$"],
                outcome: .execute { [weak self] in
                    guard let self else { return }
                    ClipboardPanelController.shared.toggle(clipboard: self.clipboard)
                }
            ),
            VoiceCommand(
                displayName: "Capture screen",
                patterns: ["^(capture|take) (a )?(screenshot|screen)$", "^screenshot$"],
                outcome: .execute { [weak self] in self?.screenshotManager.startCapture() }
            )
        ])
    }
}
