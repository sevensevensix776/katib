import SwiftUI
import AppKit
import KatibCore
import KatibWindow

/// Single discoverable surface for every Katib keybinding. Dropped the
/// nested `Form`/`Section` layout — it squeezed the hotkey chip into a
/// 70-px column on narrow panes. This uses a scroll + sticky section
/// headers pattern so every row gets the full width available.
@MainActor
struct ShortcutsSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var recording: RecordingTarget?

    private enum RecordingTarget: Hashable {
        case clipboard, screenshotQuick, screenshotAnnotate
        case windowAction(String)
    }

    /// Walks every Katib binding and returns the set of (keyCode,
    /// modifiers) pairs that are claimed by more than one action.
    private var conflicts: Set<Conflict> {
        var seen: [Conflict: Int] = [:]
        func count(_ pair: Conflict) {
            seen[pair, default: 0] += 1
        }
        count(Conflict(keyCode: settings.clipboardHotkeyKeyCode, modifiers: settings.clipboardHotkeyModifiers))
        count(Conflict(keyCode: settings.screenshotQuickHotkeyKeyCode, modifiers: settings.screenshotQuickHotkeyModifiers))
        count(Conflict(keyCode: settings.screenshotAnnotateHotkeyKeyCode, modifiers: settings.screenshotAnnotateHotkeyModifiers))
        for pair in settings.windowBindings.values where pair.count == 2 {
            count(Conflict(keyCode: pair[0], modifiers: pair[1]))
        }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    private struct Conflict: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro

                sectionBlock(title: "Dictation") {
                    HStack(spacing: 12) {
                        glyph("waveform")
                        Text("Hold to dictate").frame(maxWidth: .infinity, alignment: .leading)
                        Picker("", selection: $settings.hotkeySide) {
                            ForEach(AppSettings.HotkeySide.allCases) { side in
                                Text(side.displayName).tag(side)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .padding(.vertical, 4)
                }

                sectionBlock(title: "Pickers + capture") {
                    globalRow(
                        symbol: "doc.on.clipboard", name: "Clipboard picker",
                        keyCode: settings.clipboardHotkeyKeyCode,
                        modifiers: settings.clipboardHotkeyModifiers,
                        target: .clipboard,
                        onCapture: { code, mods in
                            settings.clipboardHotkeyKeyCode = code
                            settings.clipboardHotkeyModifiers = mods
                        }
                    )
                    rowDivider
                    globalRow(
                        symbol: "camera.viewfinder", name: "Screenshot (quick)",
                        keyCode: settings.screenshotQuickHotkeyKeyCode,
                        modifiers: settings.screenshotQuickHotkeyModifiers,
                        target: .screenshotQuick,
                        onCapture: { code, mods in
                            settings.screenshotQuickHotkeyKeyCode = code
                            settings.screenshotQuickHotkeyModifiers = mods
                        }
                    )
                    rowDivider
                    globalRow(
                        symbol: "pencil.tip.crop.circle", name: "Screenshot + annotate",
                        keyCode: settings.screenshotAnnotateHotkeyKeyCode,
                        modifiers: settings.screenshotAnnotateHotkeyModifiers,
                        target: .screenshotAnnotate,
                        onCapture: { code, mods in
                            settings.screenshotAnnotateHotkeyKeyCode = code
                            settings.screenshotAnnotateHotkeyModifiers = mods
                        }
                    )
                }

                // Quarters hidden — Asif doesn't use them and the rows were
                // cluttering the pane. The four actions still exist in
                // WindowAction so bindings persist if anyone else has them;
                // they just don't appear in this settings UI.
                ForEach(WindowAction.Group.allCases.filter { $0 != .quarters }, id: \.rawValue) { group in
                    let actions = actions(in: group)
                    if !actions.isEmpty {
                        sectionBlock(title: "Windows · \(group.displayName)") {
                            ForEach(Array(actions.enumerated()), id: \.element.rawValue) { idx, action in
                                windowRow(action)
                                if idx < actions.count - 1 { rowDivider }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard shortcuts").font(.title2).bold()
            Text("Every Katib binding in one place. Click a shortcut to rebind — the change takes effect immediately.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func sectionBlock<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold)
                .tracking(0.6).foregroundColor(.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .padding(12)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var rowDivider: some View {
        Divider().opacity(0.6).padding(.leading, 32)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundColor(AppColors.bronze)
            .frame(width: 22)
    }

    // MARK: - Row builders

    private func globalRow(
        symbol: String,
        name: String,
        keyCode: UInt32,
        modifiers: UInt32,
        target: RecordingTarget,
        onCapture: @escaping (UInt32, UInt32) -> Void
    ) -> some View {
        let conflicted = conflicts.contains(Conflict(keyCode: keyCode, modifiers: modifiers))
        return HStack(spacing: 12) {
            glyph(symbol)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            if conflicted {
                conflictBadge
            }
            hotkeyCell(
                display: WindowBinding(keyCode: keyCode, modifiers: modifiers).displayString,
                bound: true,
                isRecording: recording == target,
                onRecord: { recording = target },
                onCapture: { code, mods in
                    onCapture(code, mods)
                    recording = nil
                },
                onCancel: { recording = nil }
            )
        }
        .padding(.vertical, 6)
    }

    private var conflictBadge: some View {
        Label("Conflict", systemImage: "exclamationmark.triangle.fill")
            .labelStyle(.iconOnly)
            .foregroundColor(.orange)
            .font(.caption)
            .help("Another Katib shortcut uses the same combo — whichever fires first wins.")
    }

    private func windowRow(_ action: WindowAction) -> some View {
        let binding = windowBinding(for: action)
        let target: RecordingTarget = .windowAction(action.rawValue)
        let conflicted = binding.isBound && conflicts.contains(Conflict(keyCode: binding.keyCode, modifiers: binding.modifiers))
        return HStack(spacing: 12) {
            glyph(action.symbol)
            Text(action.displayName).frame(maxWidth: .infinity, alignment: .leading)
            if conflicted { conflictBadge }
            hotkeyCell(
                display: binding.isBound ? binding.displayString : "Not set",
                bound: binding.isBound,
                isRecording: recording == target,
                onRecord: { recording = target },
                onCapture: { code, mods in
                    setWindowBinding(for: action, keyCode: code, modifiers: mods)
                    recording = nil
                },
                onCancel: { recording = nil }
            )
            Button {
                clearWindowBinding(for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(binding.isBound ? .secondary : .secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!binding.isBound)
            .help(binding.isBound ? "Clear shortcut" : "No shortcut set")
        }
        .padding(.vertical, 6)
    }

    /// Fixed-width hotkey cell — prevents the chip from collapsing on narrow
    /// panes. Either shows the recorder (when active) or the current value.
    @ViewBuilder
    private func hotkeyCell(
        display: String,
        bound: Bool,
        isRecording: Bool,
        onRecord: @escaping () -> Void,
        onCapture: @escaping (UInt32, UInt32) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        if isRecording {
            HotkeyRecorderField(onCapture: onCapture, onCancel: onCancel)
                .frame(width: 170, height: 26)
        } else {
            Button(action: onRecord) {
                Text(display)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(bound ? .primary : .secondary)
                    .frame(minWidth: 140, alignment: .center)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Data helpers

    private func actions(in group: WindowAction.Group) -> [WindowAction] {
        WindowAction.allCases.filter { $0.group == group }
    }

    private func windowBinding(for action: WindowAction) -> WindowBinding {
        guard let pair = settings.windowBindings[action.rawValue], pair.count == 2 else {
            return WindowBinding()
        }
        return WindowBinding(keyCode: pair[0], modifiers: pair[1])
    }

    private func setWindowBinding(for action: WindowAction, keyCode: UInt32, modifiers: UInt32) {
        var current = settings.windowBindings
        current[action.rawValue] = [keyCode, modifiers]
        settings.windowBindings = current
    }

    private func clearWindowBinding(for action: WindowAction) {
        var current = settings.windowBindings
        current.removeValue(forKey: action.rawValue)
        settings.windowBindings = current
    }
}
