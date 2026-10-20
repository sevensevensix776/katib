import SwiftUI
import AppKit
import Carbon.HIToolbox
import KatibCore
import KatibWindow

/// Settings pane for window management. Moom-structured: separate sections
/// for Actions (per-row key recorder), Drag-to-snap behavior, Multi-display,
/// and Preset switching. Each action row shows current binding + an inline
/// recorder that captures a new combo on click.
@MainActor
struct WindowSettingsPane: View {
    @ObservedObject var settings: AppSettings

    @State private var recordingAction: WindowAction?
    @State private var showingPresetConfirm = false
    @State private var presetToApply: WindowPreset = .rectangle

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Rectangle defaults") {
                        presetToApply = .rectangle
                        showingPresetConfirm = true
                    }
                    Button("Clear all") {
                        presetToApply = .empty
                        showingPresetConfirm = true
                    }
                    Spacer()
                }
                Text("Hotkeys use Carbon's global registration — they're intercepted before reaching the frontmost app, so they work everywhere including full-screen apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(WindowAction.Group.allCases, id: \.rawValue) { group in
                Section(group.displayName) {
                    ForEach(actionsInGroup(group), id: \.rawValue) { action in
                        WindowBindingRow(
                            action: action,
                            binding: binding(for: action),
                            isRecording: recordingAction == action,
                            onStartRecord: { recordingAction = action },
                            onCancelRecord: { recordingAction = nil },
                            onCapture: { keyCode, modifiers in
                                setBinding(for: action, keyCode: keyCode, modifiers: modifiers)
                                recordingAction = nil
                            },
                            onClear: {
                                clearBinding(for: action)
                            }
                        )
                    }
                }
            }

            Section("Drag to snap") {
                Toggle("Enable drag-to-snap at screen edges", isOn: $settings.windowDragSnapEnabled)
                Text("""
                    Drag a window's title bar toward a screen edge or corner — a bronze preview shows the target \
                    shape, release to snap. Uses a passive CGEvent tap so native window dragging keeps working.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Multi-display") {
                Toggle("Ignore edges bordering another display", isOn: $settings.windowMultiDisplayBorder)
                Text("When enabled, dragging toward a screen edge that neighbors another display won't trigger a snap — gives you room to move windows across screens without accidental halving.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Gap between windows")
                    Spacer()
                    Stepper(value: $settings.windowGap, in: 0...40) {
                        Text("\(settings.windowGap) px")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    .fixedSize()
                }
            }

            Section("Per-app exclusions") {
                Text("Drag-to-snap is disabled for these apps (keyboard shortcuts still work). Good for apps that don't like being resized — Xcode, Photoshop, Final Cut.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.windowSnapExcludedBundleIDs.isEmpty {
                    Text("No excluded apps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(settings.windowSnapExcludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(appName(for: bundleID))
                            Spacer()
                            Text(bundleID)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button {
                                settings.windowSnapExcludedBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Add app…") { addExcludedApp() }
                }
            }
        }
        .formStyle(.grouped)
        .tint(AppColors.bronze)
        .confirmationDialog("Apply \(presetToApply.displayName)?",
                            isPresented: $showingPresetConfirm,
                            titleVisibility: .visible) {
            Button("Apply", role: .destructive) { applyPreset(presetToApply) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current window bindings will be replaced.")
        }
    }

    // MARK: - Data helpers

    private func actionsInGroup(_ group: WindowAction.Group) -> [WindowAction] {
        WindowAction.allCases.filter { $0.group == group }
    }

    private func binding(for action: WindowAction) -> WindowBinding {
        guard let pair = settings.windowBindings[action.rawValue], pair.count == 2 else {
            return WindowBinding()
        }
        return WindowBinding(keyCode: pair[0], modifiers: pair[1])
    }

    private func setBinding(for action: WindowAction, keyCode: UInt32, modifiers: UInt32) {
        var current = settings.windowBindings
        current[action.rawValue] = [keyCode, modifiers]
        settings.windowBindings = current
    }

    private func clearBinding(for action: WindowAction) {
        var current = settings.windowBindings
        current.removeValue(forKey: action.rawValue)
        settings.windowBindings = current
    }

    private func applyPreset(_ preset: WindowPreset) {
        var next: [String: [UInt32]] = [:]
        for (action, binding) in preset.bindings() {
            next[action.rawValue] = [binding.keyCode, binding.modifiers]
        }
        settings.windowBindings = next
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.message = "Pick an application to exclude from drag-to-snap"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        if !settings.windowSnapExcludedBundleIDs.contains(bundleID) {
            settings.windowSnapExcludedBundleIDs.append(bundleID)
        }
    }
}

/// One action row: symbol + name + current binding + inline recorder + clear.
@MainActor
struct WindowBindingRow: View {
    let action: WindowAction
    let binding: WindowBinding
    let isRecording: Bool
    let onStartRecord: () -> Void
    let onCancelRecord: () -> Void
    let onCapture: (UInt32, UInt32) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 20)
                .foregroundColor(.secondary)
            Text(action.displayName)
            Spacer()

            if isRecording {
                HotkeyRecorderField(onCapture: onCapture, onCancel: onCancelRecord)
                    .frame(width: 170, height: 24)
            } else {
                Button {
                    onStartRecord()
                } label: {
                    Text(binding.isBound ? binding.displayString : "Record shortcut…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(binding.isBound ? .primary : .secondary)
                        .frame(minWidth: 130, alignment: .center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(binding.isBound ? .secondary : .secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!binding.isBound)
            .help(binding.isBound ? "Clear shortcut" : "No shortcut set")
        }
    }
}

/// NSEvent-driven keyboard capture. Put it in focus and press a chord — the
/// next non-modifier-only key event is captured, modifiers + keyCode are
/// reported back via onCapture.
struct HotkeyRecorderField: NSViewRepresentable {
    let onCapture: (UInt32, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
            installMonitor()
        }

        override func removeFromSuperview() {
            teardownMonitor()
            super.removeFromSuperview()
        }

        private func installMonitor() {
            teardownMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event: event)
                return nil // consume
            }
        }

        private func teardownMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(event: NSEvent) {
            // Esc cancels the capture.
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            let combined = combinedModifiers(from: event)
            // Require at least one modifier to avoid capturing plain keys.
            guard combined != 0 else { return }
            onCapture?(UInt32(event.keyCode), combined)
        }

        /// Carbon modifier bits plus a custom fn bit. macOS Carbon's
        /// RegisterEventHotKey doesn't accept fn as a modifier, so when the
        /// user holds it we set a high bit (FnHotkeyTap.fnFlag = 0x00010000)
        /// and route those bindings through our CGEventTap instead of Carbon
        /// at install time.
        ///
        /// Arrow keys always carry `.function` in NSEvent.modifierFlags as
        /// cluster noise — but only "true" fn-held presses remap the key
        /// code (Left→Home, Right→End, etc.). We only flag fn when the key
        /// code actually differs, which means arrow noise is ignored but a
        /// deliberate fn+Left (captured as Home) is honoured.
        private func combinedModifiers(from event: NSEvent) -> UInt32 {
            var result: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.control) { result |= UInt32(controlKey) }
            if flags.contains(.option) { result |= UInt32(optionKey) }
            if flags.contains(.shift) { result |= UInt32(shiftKey) }
            if flags.contains(.command) { result |= UInt32(cmdKey) }
            if flags.contains(.function) && Self.isFnRemappedKey(keyCode: event.keyCode) {
                result |= FnHotkeyTap.fnFlag
            }
            return result
        }

        /// Key codes that macOS hardware-remaps when fn is held
        /// (Home/End/PageUp/PageDown/Forward-delete). Seeing any of these
        /// with `.function` set is a strong signal the user really pressed
        /// fn — as opposed to an arrow key that always carries the bit.
        private static func isFnRemappedKey(keyCode: UInt16) -> Bool {
            // 115=Home  116=PageUp  117=ForwardDelete  119=End  121=PageDown
            [115, 116, 117, 119, 121].contains(keyCode)
        }

        override func draw(_ dirtyRect: NSRect) {
            // Subtle bronze border to indicate we're recording.
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            AppColors.bronzeNSColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()

            NSColor.labelColor.setFill()
            let str = NSAttributedString(
                string: "Press a shortcut…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            let textSize = str.size()
            str.draw(at: CGPoint(x: (bounds.width - textSize.width) / 2,
                                 y: (bounds.height - textSize.height) / 2))
        }
    }
}
