import AppKit
import Combine
import KatibClipboard

/// Clipboard picker hotkey wiring — installs the user-configurable combo
/// (defaults to ⇧⌃⌘V) and toggles the Alfred-style panel. Reinstalls when
/// the user changes the binding in Settings.
extension AppDelegate {
    func setupClipboardHotkey() {
        let installer: () -> Void = { [weak self] in
            guard let self else { return }
            ClipboardHotkeyManager.shared.onHotkey = { [weak self] in
                guard let self else { return }
                ClipboardPanelController.shared.toggle(clipboard: self.clipboard)
            }
            _ = ClipboardHotkeyManager.shared.install(
                keyCode: self.settings.clipboardHotkeyKeyCode,
                modifiers: self.settings.clipboardHotkeyModifiers
            )
        }
        installer()

        settings.$clipboardHotkeyKeyCode
            .combineLatest(settings.$clipboardHotkeyModifiers)
            .dropFirst()
            .sink { _ in installer() }
            .store(in: &cancellables)
    }
}
