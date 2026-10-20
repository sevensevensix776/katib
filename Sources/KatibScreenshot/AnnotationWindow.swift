import SwiftUI
import AppKit
import KatibCore

/// Hosts the annotation editor in its own NSWindow. Owner keeps a reference
/// so the window doesn't dealloc mid-edit; released explicitly on dismiss.
@MainActor
final class AnnotationWindowController: NSWindowController {
    private let state: AnnotationState
    private let onCopy: (NSImage) -> Void
    private let onSave: (NSImage) -> Void
    private let onCancel: () -> Void
    /// Local scroll-wheel monitor — lets ⌘+scroll zoom the annotation
    /// editor without disturbing unmodified scroll (which still pans the
    /// ScrollView). Retained for teardown in `deinit`. `nonisolated(unsafe)`
    /// because Swift 6's nonisolated deinit can't access MainActor state
    /// otherwise — writes only happen from MainActor init, the deinit's
    /// only read is to unregister the monitor.
    private nonisolated(unsafe) var scrollMonitor: Any?
    /// Local keyDown monitor for Delete/Backspace/Esc on the selection.
    /// NSEvent-level because SwiftUI `.keyboardShortcut(.delete)` only
    /// maps to Forward-Delete, and Backspace is the more common "remove"
    /// key on macOS. We intercept only when something is selected; other
    /// keys pass through so text fields / command palette still work.
    private nonisolated(unsafe) var keyMonitor: Any?

    init(image: NSImage,
         onCopy: @escaping (NSImage) -> Void,
         onSave: @escaping (NSImage) -> Void,
         onCancel: @escaping () -> Void) {
        self.state = AnnotationState(image: image)
        self.onCopy = onCopy
        self.onSave = onSave
        self.onCancel = onCancel

        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentViewController: hosting)
        super.init(window: window)

        let rootView = AnnotationEditorView(
            state: state,
            onCopy: { [weak self] in self?.performCopy() },
            onSave: { [weak self] in self?.performSave() },
            onCancel: { [weak self] in self?.performCancel() }
        )
        hosting.rootView = AnyView(rootView)

        window.title = "Annotate"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let minSize = CGSize(
            width: min(max(640, image.size.width * 0.6), 1400),
            height: min(max(480, image.size.height * 0.6 + 120), 1000)
        )
        window.setContentSize(minSize)
        window.center()
        window.delegate = self

        installScrollZoomMonitor()
        installSelectionKeyMonitor()
    }

    private func installSelectionKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow else {
                return event
            }
            // Don't steal keys from a focused text field (the text-tool
            // input). Responder chain's first responder is the text field
            // when it's editing; AppKit reports `window.firstResponder`.
            if window.firstResponder is NSText || window.firstResponder is NSTextView {
                return event
            }
            let selectedID = self.state.selectedStrokeID

            switch event.keyCode {
            case 51, 117: // Backspace, Forward Delete
                guard selectedID != nil else { return event }
                Task { @MainActor in self.state.deleteSelected() }
                return nil
            case 53: // Esc
                guard selectedID != nil else { return event }
                Task { @MainActor in self.state.selectedStrokeID = nil }
                return nil
            case 36, 76: // Return, Keypad Enter → copy+close (only when no text field focused; the early-return above handles that)
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods.isEmpty else { return event } // ⌘⏎ still routes to the SwiftUI Copy shortcut
                Task { @MainActor in self.performCopy() }
                return nil
            default:
                return event
            }
        }
    }

    private func installScrollZoomMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.modifierFlags.contains(.command) else {
                return event
            }
            // Normalize trackpad (pixel) vs wheel (tick) deltas. Trackpad
            // scrollingDeltaY is pixels per event (small floats), wheel
            // is discrete ticks. 0.01 factor lands somewhere usable for
            // both on a typical MBP — slow enough to be controllable.
            let delta = event.scrollingDeltaY
            let factor = 1.0 + (delta * 0.01)
            let proposed = self.state.zoom * factor
            Task { @MainActor in
                self.state.zoom = min(
                    AnnotationState.maxZoom,
                    max(AnnotationState.minZoom, proposed)
                )
            }
            // Consume — upstream ScrollView doesn't also scroll.
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    private func performCopy() {
        let flat = AnnotationExporter.flatten(state: state)
        onCopy(flat)
        close()
    }

    private func performSave() {
        let flat = AnnotationExporter.flatten(state: state)
        onSave(flat)
        close()
    }

    private func performCancel() {
        onCancel()
        close()
    }

    // Belt-and-suspenders: if this controller is released without
    // `windowWillClose` firing (e.g. app terminates while the editor is
    // open, or the window is destroyed from outside the delegate path),
    // still clear ScreenshotManager's `captureInProgress` flag. Without
    // this, the user has to relaunch Katib before another screenshot can
    // start — a silent stuck state we've shipped once already.
    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        Task { @MainActor in
            ScreenshotManager.shared.annotationWindowClosed()
        }
    }
}

extension AnnotationWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Let ScreenshotManager know it can drop its reference.
            ScreenshotManager.shared.annotationWindowClosed()
        }
    }
}

/// The SwiftUI root of the annotation window: toolbar + canvas + footer.
@MainActor
private struct AnnotationEditorView: View {
    @ObservedObject var state: AnnotationState
    let onCopy: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(state: state)
            Divider()
            AnnotationCanvas(state: state)
            Divider()
            footer
        }
        .tint(AppColors.bronze)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(state.committed.count) annotation\(state.committed.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            // Zoom cluster. Hidden keyboard shortcuts are bound to invisible
            // buttons so ⌘+ / ⌘- / ⌘0 fire even when a toolbar text field
            // has focus — SwiftUI routes .command shortcuts past text fields.
            Button("") { state.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("") { state.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("") { state.zoomIn() }
                .keyboardShortcut("+", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0)
            Button("") { state.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

            HStack(spacing: 2) {
                Button {
                    state.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(state.zoom <= AnnotationState.minZoom + 0.001)
                .help("Zoom out (⌘−)")

                Button {
                    state.zoomReset()
                } label: {
                    Text("\(Int((state.zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 44)
                }
                .buttonStyle(.plain)
                .help("Reset zoom (⌘0)")

                Button {
                    state.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(state.zoom >= AnnotationState.maxZoom - 0.001)
                .help("Zoom in (⌘=)")
            }
            .foregroundColor(.secondary)

            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave() }
                .keyboardShortcut("s", modifiers: .command)
            // Plain Return → Copy (via keyMonitor in the window controller,
            // gated on first-responder so typing a text annotation still
            // commits instead of closing the editor). ⌘⏎ is the explicit
            // shortcut below; plain Return is the natural "default button"
            // behavior users expect.
            // ⌘Z = undo. State machine already tracks a 50-entry undo
            // stack; this just wires the keyboard shortcut. Redo (⇧⌘Z)
            // deferred — Excalidraw's ring is separate and we'd need
            // pushRedo on every undo call.
            Button("") { state.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Copy") { onCopy() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
