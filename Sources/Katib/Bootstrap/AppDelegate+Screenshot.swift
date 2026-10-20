import AppKit
import Combine
import KatibCore
import KatibScreenshot

/// Screenshot hotkey wiring — both quick (straight-to-clipboard) and
/// annotate (opens editor) bindings. Settings changes re-install the
/// hotkeys without a relaunch.
extension AppDelegate {
    func setupScreenshotHotkey() {
        ScreenshotHotkeyManager.shared.onQuickCapture = {
            ScreenshotManager.shared.startQuickCapture()
        }
        ScreenshotHotkeyManager.shared.onAnnotateCapture = {
            ScreenshotManager.shared.startCapture()
        }

        let installQuick: () -> Void = { [weak self] in
            guard let self else { return }
            _ = ScreenshotHotkeyManager.shared.installQuick(
                keyCode: self.settings.screenshotQuickHotkeyKeyCode,
                modifiers: self.settings.screenshotQuickHotkeyModifiers
            )
        }
        let installAnnotate: () -> Void = { [weak self] in
            guard let self else { return }
            _ = ScreenshotHotkeyManager.shared.installAnnotate(
                keyCode: self.settings.screenshotAnnotateHotkeyKeyCode,
                modifiers: self.settings.screenshotAnnotateHotkeyModifiers
            )
        }
        installQuick()
        installAnnotate()

        settings.$screenshotQuickHotkeyKeyCode
            .combineLatest(settings.$screenshotQuickHotkeyModifiers)
            .dropFirst()
            .sink { _ in installQuick() }
            .store(in: &cancellables)

        settings.$screenshotAnnotateHotkeyKeyCode
            .combineLatest(settings.$screenshotAnnotateHotkeyModifiers)
            .dropFirst()
            .sink { _ in installAnnotate() }
            .store(in: &cancellables)
    }
}
