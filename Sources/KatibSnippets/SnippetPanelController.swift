import Foundation
import AppKit
import SwiftUI
import KatibCore

/// Floating picker for manual snippet paste. Same architecture as
/// `ClipboardPanelController`: non-activating NSPanel near the cursor,
/// search-first, Enter types the snippet into the frontmost app.
@MainActor
public final class SnippetPanelController: NSObject, NSWindowDelegate {
    public static let shared = SnippetPanelController()

    private var panel: NSPanel?

    override public init() { super.init() }

    public func toggle() {
        if let panel, panel.isVisible {
            hide()
            return
        }
        show()
    }

    public func show() {
        let viewModel = SnippetPickerViewModel(store: SnippetStore.shared) { [weak self] in
            self?.hide()
        }
        let rootView = SnippetPickerView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: rootView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = hosting
        panel.delegate = self

        positionNearCursor(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func positionNearCursor(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero
        let panelSize = panel.frame.size
        let margin: CGFloat = 16
        var origin = NSPoint(
            x: mouse.x - panelSize.width / 2,
            y: mouse.y - panelSize.height - margin
        )
        origin.x = max(screenFrame.minX + margin,
                       min(origin.x, screenFrame.maxX - panelSize.width - margin))
        origin.y = max(screenFrame.minY + margin,
                       min(origin.y, screenFrame.maxY - panelSize.height - margin))
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View model + view

@MainActor
final class SnippetPickerViewModel: ObservableObject {
    @Published var search: String = ""
    let store: SnippetStore
    let dismiss: () -> Void

    init(store: SnippetStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
    }

    var filtered: [Snippet] {
        store.visible(matching: search)
    }

    /// Copy to pasteboard + paste into the frontmost app via synthesized
    /// Cmd+V. We use pasteboard here (rather than keyboardSetUnicodeString)
    /// because the picker is manual — pasting via Cmd+V keeps the target
    /// app's undo stack clean and handles multi-paragraph content better.
    func choose(_ snippet: Snippet) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.content, forType: .string)
        store.recordUsage(of: snippet.id)
        dismiss()

        // Give the panel a frame to close, then synthesize Cmd+V.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            sendCommandV()
        }
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: UInt16 = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

@MainActor
struct SnippetPickerView: View {
    @ObservedObject var viewModel: SnippetPickerViewModel
    @ObservedObject private var store: SnippetStore
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex: Int = 0

    init(viewModel: SnippetPickerViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(initialValue: viewModel.store)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            list
            Divider()
            footer
        }
        .tint(AppColors.bronze)
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.search) { _, _ in selectedIndex = 0 }
        .background(
            Group {
                Button("") { chooseSelected() }
                    .keyboardShortcut(.return, modifiers: [])
                    .hidden()
                Button("") { viewModel.dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                Button("") { selectedIndex = max(selectedIndex - 1, 0) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .hidden()
                Button("") { selectedIndex = min(selectedIndex + 1, viewModel.filtered.count - 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .hidden()
            }
        )
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search snippets…", text: $viewModel.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if viewModel.filtered.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filtered.enumerated()), id: \.element.id) { index, snippet in
                            row(snippet, index: index).id(snippet.id)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, newValue in
                    guard viewModel.filtered.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(viewModel.filtered[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text(viewModel.search.isEmpty ? "No snippets yet" : "No matches")
                .font(.callout)
            Text(viewModel.search.isEmpty
                 ? "Add a snippet in Settings to paste from here."
                 : "No snippets match \"\(viewModel.search)\".")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
    }

    private func row(_ snippet: Snippet, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snippet.name).font(.callout).bold()
                    if !snippet.trigger.isEmpty {
                        Text(snippet.trigger)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AppColors.bronze.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(snippet.preview).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index == selectedIndex ? AppColors.bronze.opacity(0.2) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.choose(snippet) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Enter", systemImage: "return").font(.caption2)
            Text("to paste").font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text("⎋").font(.caption2)
            Text("close").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseSelected() {
        guard viewModel.filtered.indices.contains(selectedIndex) else { return }
        viewModel.choose(viewModel.filtered[selectedIndex])
    }
}
