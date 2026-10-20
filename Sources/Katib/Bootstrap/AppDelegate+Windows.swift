import Foundation
import KatibCore
import KatibWindow

/// Window-management wiring — seeds default bindings (Rectangle preset on
/// first launch), installs the FnHotkeyTap listeners per WindowAction, and
/// reacts to Settings edits without a relaunch. Drag-to-snap follows its
/// own enable toggle. Also registers every action as a palette command.
extension AppDelegate {
    func setupWindowManager() {
        var bindings = settings.windowBindings
        if bindings.isEmpty {
            for (action, binding) in WindowPreset.rectangle.bindings() {
                bindings[action.rawValue] = [binding.keyCode, binding.modifiers]
            }
            settings.windowBindings = bindings
        }

        for action in WindowAction.allCases {
            guard let pair = bindings[action.rawValue], pair.count == 2 else { continue }
            installWindowBinding(action, keyCode: pair[0], modifiers: pair[1])
        }

        // Register every action as a palette command.
        let commands: [KatibCommand] = WindowAction.allCases.map { action in
            let binding = bindings[action.rawValue].flatMap {
                $0.count == 2 ? WindowBinding(keyCode: $0[0], modifiers: $0[1]) : nil
            }
            return KatibCommand(
                id: "katib.window.\(action.rawValue)",
                title: action.displayName,
                subtitle: action.group.displayName,
                keywords: windowKeywords(for: action),
                symbol: action.symbol,
                shortcutHint: binding?.displayString,
                section: .window
            ) {
                _ = WindowManager.shared.perform(action)
            }
        }
        CommandRegistry.shared.register(commands)

        // Re-bind hotkeys when the user edits bindings in Settings.
        settings.$windowBindings
            .dropFirst()
            .sink { [weak self] newBindings in
                Task { @MainActor in
                    FnHotkeyTap.shared.unregisterAll()
                    for action in WindowAction.allCases {
                        if let pair = newBindings[action.rawValue], pair.count == 2 {
                            self?.installWindowBinding(action, keyCode: pair[0], modifiers: pair[1])
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Drag-to-snap follows its own enable toggle.
        DragSnapController.shared.isEnabled = settings.windowDragSnapEnabled
        settings.$windowDragSnapEnabled
            .dropFirst()
            .sink { enabled in
                Task { @MainActor in DragSnapController.shared.isEnabled = enabled }
            }
            .store(in: &cancellables)
    }

    /// Route every window binding through FnHotkeyTap (CGEventTap).
    ///
    /// Carbon's RegisterEventHotKey silently drops the event when any bit
    /// the registration didn't list is set on the CGEvent — notably fn,
    /// which macOS always sets on keycodes it hardware-remaps like Home
    /// (fn+Left) and End (fn+Right). So a binding of ⌃⌥⌘+Home registered
    /// via Carbon would simply never fire on a MacBook. Using the tap
    /// exclusively sidesteps the whole class of Carbon modifier quirks.
    ///
    /// Only window bindings go through the tap; the three static global
    /// hotkeys (clipboard, screenshot, snippets) stay on Carbon because
    /// they use keys that don't collide with fn-remapped codes.
    func installWindowBinding(_ action: WindowAction, keyCode: UInt32, modifiers: UInt32) {
        FnHotkeyTap.shared.register(action, keyCode: keyCode, modifiers: modifiers)
    }

    /// Voice-command phrasings a user might say / type to invoke each action.
    /// Surfaced via the command palette's keywords matcher.
    private func windowKeywords(for action: WindowAction) -> [String] {
        switch action {
        case .maximize: return ["full", "fullscreen", "max", "fill"]
        case .almostMaximize: return ["almost", "inset", "nearly full"]
        case .restore: return ["revert", "back", "undo"]
        case .center: return ["middle", "centered"]
        case .leftHalf: return ["split left", "half left", "left"]
        case .rightHalf: return ["split right", "half right", "right"]
        case .topHalf: return ["split top", "half top", "upper"]
        case .bottomHalf: return ["split bottom", "half bottom", "lower"]
        case .topLeftQuarter: return ["corner", "upper left"]
        case .topRightQuarter: return ["corner", "upper right"]
        case .bottomLeftQuarter: return ["corner", "lower left"]
        case .bottomRightQuarter: return ["corner", "lower right"]
        case .nextDisplay: return ["next monitor", "move right", "other screen"]
        case .previousDisplay: return ["previous monitor", "move left", "prior screen"]
        case .larger: return ["bigger", "grow", "expand"]
        case .smaller: return ["tinier", "shrink", "reduce"]
        }
    }
}
