import Foundation

/// Dictation hotkey callback wiring — glues HotkeyManager key-down /
/// key-up / double-tap / abort events to the AppDelegate's recording
/// lifecycle methods. All four fire on the main actor.
extension AppDelegate {
    func setupHotkeyCallbacks() {
        hotkeyManager.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }

        hotkeyManager.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndPaste()
            }
        }

        hotkeyManager.onDoubleTap = { [weak self] in
            Task { @MainActor in
                self?.doubleTapRePaste()
            }
        }

        hotkeyManager.onAbort = { [weak self] in
            Task { @MainActor in
                self?.abortRecording()
            }
        }
    }
}
