import Foundation
import AppKit
import SwiftUI
import Combine
import KatibCore

/// Floating NSPanel for the clipboard picker. Opens at the cursor, search-
/// first, non-activating so the frontmost app stays the "paste target". Enter
/// copies the selected clip to the pasteboard; the user's next ⌘V lands it in
/// the app they were already in.
///
/// Why a panel instead of the menu bar popover:
/// - The popover anchors to the status item icon; always opens at the top of
///   the screen regardless of where the user is working.
/// - NSPanel with `.nonactivatingPanel` style keeps the frontmost app as the
///   active text-input target, which is what we want when the user's plan is
///   "pick a clip → Cmd+V into the field I'm already typing in."
@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate {
    public static let shared = ClipboardPanelController()

    private var panel: NSPanel?
    /// Reference to the NSSearchField inside the SwiftUI hierarchy.
    /// Captured by `SearchFieldRepresentable` via the `onCreate` callback
    /// the moment the AppKit view exists, so we can call
    /// `panel.makeFirstResponder(field)` deterministically — no tree
    /// walk, no race against SwiftUI's render pipeline.
    private weak var capturedSearchField: NSSearchField?
    /// Local NSEvent monitor that tracks the Option key state while the
    /// picker is open. Drives footer hints (paste vs paste-plain) and
    /// other modifier-aware affordances. Torn down with the panel.
    private var modifierMonitor: Any?
    /// Global mouse-down monitor that hides the panel when the user
    /// clicks outside its bounds. Replaces the `windowDidResignKey`
    /// auto-hide so taking a screenshot with the picker open doesn't
    /// dismiss the picker before the capture fires.
    private var outsideClickMonitor: Any?

    override public init() { super.init() }

    public func toggle(clipboard: ClipboardManager) {
        if let panel, panel.isVisible {
            hide()
            return
        }
        show(clipboard: clipboard)
    }

    public func show(clipboard: ClipboardManager) {
        capturedSearchField = nil
        let viewModel = ClipboardPickerViewModel(clipboard: clipboard) { [weak self] in
            self?.hide()
        }
        installModifierMonitor(viewModel: viewModel)
        let rootView = ClipboardPickerView(viewModel: viewModel) { [weak self] field in
            // Captures the NSSearchField as soon as SwiftUI's
            // NSViewRepresentable creates it — guarantees we have a
            // reference by the time `focusSearchField` runs.
            self?.capturedSearchField = field
            // If the panel is already key, focus immediately. The first-
            // launch path tends to capture before makeKeyAndOrderFront,
            // so this is the second-open case.
            if let panel = self?.panel, panel.isKeyWindow {
                panel.makeFirstResponder(field)
            }
        }
        // NSHostingView directly. Pre-2026-05-03 this was
        // NSHostingController(rootView:) followed by `hosting.view`,
        // but that pattern releases the controller at end of show()
        // (it's a local var) while SwiftUI's bridge keeps weak refs to
        // controller-bound state. Subsequent body re-renders crash with
        // EXC_BAD_ACCESS in swift_task_isMainExecutorImpl. Same fix
        // applied to CommandPaletteController.show().
        let hostingView = NSHostingView(rootView: rootView)

        // Size as a fraction of the active screen so the panel feels
        // proportional on different displays. ~85% width × ~70% height,
        // capped so a 6K monitor doesn't get a 5000-pt panel. Floors so
        // small displays still get a usable two-pane layout.
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame
                      ?? NSScreen.main?.frame
                      ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let size = Self.calculatePanelSize(screenSize: screen.size)
        let panelWidth = size.width
        let panelHeight = size.height

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            // Dropped `.utilityWindow` — utility panels often coerce to a
            // smaller default size and cap at a fraction of the screen
            // regardless of the contentRect. Plain `.titled` +
            // `.fullSizeContentView` keeps the borderless look (we hide
            // the title bar) without the size coercion.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Hide the close/min/zoom buttons — `.titled` style mask shows
        // them by default. We don't need any of them; the panel is
        // closed via Esc / outside-click / item selection. Visible
        // window chrome was leaking into screenshots and looked off.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // Belt-and-suspenders: set the content size explicitly after init.
        // `contentRect:` in the initializer is sometimes a hint rather than
        // a hard target — `setContentSize` nails it for the SwiftUI host.
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
        // false (was true) — `becomesKeyOnlyIfNeeded = true` made the panel
        // only become key when a subview demanded focus, which SwiftUI's
        // FocusState doesn't reliably trigger. With false, the panel
        // becomes key on `makeKeyAndOrderFront` and SwiftUI's
        // `@FocusState` assignment in `.onAppear` actually focuses the
        // search field. The `nonactivatingPanel` style mask still keeps
        // the previous app active so paste targets the right window.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        // Set frame on the hosting view + content size on the panel.
        // We never set `panel.contentViewController`, so the 1×1
        // collapse-via-preferredContentSize pitfall doesn't apply
        // even with NSHostingView.
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = hostingView
        // Re-pin the size now that the content view is in place.
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))

        positionCenter(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor(panel: panel)
        // Log the actual final frame so "the panel is too small" claims
        // are diagnosable without guessing what the OS did.
        Logger.shared.log(
            "Clipboard panel: requested=\(Int(panelWidth))×\(Int(panelHeight)) " +
            "actual=\(Int(panel.frame.width))×\(Int(panel.frame.height)) " +
            "screen=\(Int(screen.width))×\(Int(screen.height))"
        )
        // Try focus immediately. If SearchFieldRepresentable's
        // makeNSView already ran during NSHostingController init, we have
        // the field reference; otherwise the onCreate callback above
        // will focus once the field appears.
        focusCapturedSearchField()
        // Belt: a few delayed retries for the SwiftUI lazy-creation case.
        // Retries no-op once the field is focused.
        for delay in [0.02, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusCapturedSearchField()
            }
        }
        self.panel = panel
    }

    private func focusCapturedSearchField() {
        guard let panel, panel.isKeyWindow,
              let field = capturedSearchField,
              panel.firstResponder !== field else { return }
        panel.makeFirstResponder(field)
    }

    public func hide() {
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func installOutsideClickMonitor(panel: NSPanel) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        // Global monitor — fires for clicks in OTHER apps' windows, which
        // is exactly the "user clicked away" gesture. Local clicks
        // inside our panel don't reach this monitor (NSPanel handles
        // them itself).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func installModifierMonitor(viewModel: ClipboardPickerViewModel) {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak viewModel] event in
            let held = event.modifierFlags.contains(.option)
            Task { @MainActor in viewModel?.optionHeld = held }
            return event
        }
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Don't auto-hide. The picker survives focus changes — Esc, an
        // item selection, or a click outside the panel all close it
        // explicitly. Auto-hiding on resignKey meant pressing ⇧⌘3 to
        // screenshot WHILE the picker was open dismissed the picker
        // before the capture overlay grabbed pixels — so the screenshot
        // never included the picker. Match Alfred's behavior (open until
        // explicitly dismissed).
    }

    // MARK: - Positioning

    /// Pure: Alfred-scale picker dimensions for a given screen. 92%
    /// width × 80% height, with floors that guarantee a usable two-pane
    /// layout on small displays and caps that avoid an absurd panel on
    /// 6K monitors. Public + static so tests can lock the math down.
    public static func calculatePanelSize(screenSize: CGSize) -> CGSize {
        // Tuned slightly down from 92×80 — Asif's call after seeing it big.
        // Still big enough that the two-pane layout has room to breathe;
        // less aggressive than "take the whole screen."
        let widthFraction: CGFloat  = 0.80
        let heightFraction: CGFloat = 0.65
        let minWidth: CGFloat       = 1100
        let maxWidth: CGFloat       = 1900
        let minHeight: CGFloat      = 600
        let maxHeight: CGFloat      = 1000
        let w = min(max(screenSize.width  * widthFraction,  minWidth),  maxWidth)
        let h = min(max(screenSize.height * heightFraction, minHeight), maxHeight)
        return CGSize(width: w, height: h)
    }

    /// Center the panel on the screen containing the cursor — Alfred /
    /// Spotlight / Raycast convention. Sits slightly above vertical center
    /// (40% down from the top) so the search field lands in the user's
    /// natural line of sight instead of being bottom-heavy.
    private func positionCenter(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero
        let panelSize = panel.frame.size

        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.minY + (screenFrame.height * 0.6) - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View model

@MainActor
final class ClipboardPickerViewModel: ObservableObject {
    /// Live search text — bound directly to the NSSearchField. Updates
    /// per keystroke.
    @Published var search: String = "" {
        didSet { scheduleDebouncedSearch() }
    }
    /// Debounced mirror of `search` — updates 80ms after the user stops
    /// typing. `filtered` keys off this so the 8k-item filter doesn't
    /// re-run per keystroke during a fast type.
    @Published private(set) var debouncedSearch: String = "" {
        didSet { refilter() }
    }
    private var debounceTask: Task<Void, Never>?
    /// True while the Option key is held. Drives footer hint swaps so the
    /// user discovers paste-as-plain without reading docs.
    @Published var optionHeld: Bool = false
    /// Filter to image clips only — toggled by the picker's image-filter
    /// button. Orthogonal to text search.
    @Published var imagesOnly: Bool = false {
        didSet { refilter() }
    }
    let clipboard: ClipboardManager
    let dismiss: () -> Void

    /// The filtered list, computed once per change. It was a computed
    /// property that the view read ~11 times per render (isEmpty, ForEach,
    /// selection, scroll, footer), so every keystroke ran several full
    /// scans of the history.
    @Published private(set) var filtered: [ClipboardItem] = []
    private var itemsSub: AnyCancellable?

    init(clipboard: ClipboardManager, dismiss: @escaping () -> Void) {
        self.clipboard = clipboard
        self.dismiss = dismiss
        refilter()
        // Pins, deletes and new copies change the history while the panel is open.
        itemsSub = clipboard.$items
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refilter() }
    }

    func refilter() {
        filtered = clipboard.visibleItems(matching: debouncedSearch, imagesOnly: imagesOnly)
    }

    private func scheduleDebouncedSearch() {
        debounceTask?.cancel()
        let current = search
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.debouncedSearch = current }
        }
    }

    func choose(_ item: ClipboardItem, plain: Bool) {
        if plain { clipboard.copyPlainToPasteboard(item) } else { clipboard.copyToPasteboard(item) }
        dismiss()
        // Auto-paste into the previously-focused app — matches Alfred,
        // Maccy, Raycast. Without this, "choose" only copies and the user
        // still has to press ⌘V manually. Small delay so NSPanel's
        // orderOut + the async dismiss settle before the paste event
        // reaches the prior app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            Self.simulateCommandV()
        }
    }

    /// Post a synthetic ⌘V via CGEvent. Requires Accessibility (which
    /// Katib already has for global hotkeys). Keystroke goes to whichever
    /// app is frontmost after the picker dismisses — the app the user
    /// was in before opening the picker.
    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func pin(_ item: ClipboardItem) {
        clipboard.togglePin(item)
    }

    func remove(_ item: ClipboardItem) {
        clipboard.remove(item)
    }
}

// MARK: - View

@MainActor
struct ClipboardPickerView: View {
    @ObservedObject var viewModel: ClipboardPickerViewModel
    @ObservedObject private var clipboard: ClipboardManager
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex: Int = 0
    /// Fired by SearchFieldRepresentable the moment the underlying
    /// NSSearchField is created. Lets the controller capture the
    /// reference for direct `makeFirstResponder` calls.
    let onSearchFieldCreated: (NSSearchField) -> Void

    init(viewModel: ClipboardPickerViewModel,
         onSearchFieldCreated: @escaping (NSSearchField) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.onSearchFieldCreated = onSearchFieldCreated
        _clipboard = ObservedObject(initialValue: viewModel.clipboard)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                // ~45% of the panel goes to the list, the remainder to the
                // preview. Alfred uses roughly this split — list narrow
                // enough that you scan titles, preview wide enough that an
                // image or webpage shows clearly.
                list
                    .frame(minWidth: 360, idealWidth: 480, maxWidth: 720)
                Divider()
                previewPane
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .tint(AppColors.bronze)
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.search) { _, _ in selectedIndex = 0 }
        .background(globalShortcuts)
    }

    /// All keyboard shortcuts as invisible buttons. Includes ⌘1-⌘9 for
    /// the top nine clips (Alfred convention) so the user can paste a
    /// specific clip without arrowing through the list.
    @ViewBuilder
    private var globalShortcuts: some View {
        Group {
            Button("") { pasteSelected(plain: false) }
                .keyboardShortcut(.return, modifiers: [])
                .hidden()
            Button("") { pasteSelected(plain: true) }
                .keyboardShortcut(.return, modifiers: .option)
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
            // ⌘1..⌘9 — paste the Nth clip without selecting it first.
            ForEach(0..<9) { idx in
                Button("") {
                    guard viewModel.filtered.indices.contains(idx) else { return }
                    viewModel.choose(viewModel.filtered[idx], plain: false)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .hidden()
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            // NSSearchField has its own magnifying-glass icon built in.
            // Don't render a second SwiftUI one alongside it.
            SearchFieldRepresentable(text: $viewModel.search, onCreate: onSearchFieldCreated)
                .frame(height: 30)
            // Images-only filter — toggle to show only image clips.
            // Same row as search so it's discoverable.
            Button {
                viewModel.imagesOnly.toggle()
            } label: {
                Image(systemName: viewModel.imagesOnly ? "photo.fill" : "photo")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.imagesOnly ? AppColors.bronze : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.imagesOnly ? "Showing images only — click for all" : "Show images only")
            if !viewModel.search.isEmpty {
                Button {
                    viewModel.search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var list: some View {
        if viewModel.filtered.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filtered.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                                .id(item.id)
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
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text(viewModel.search.isEmpty ? "No clips yet" : "No matches")
                .font(.callout)
            Text(viewModel.search.isEmpty
                 ? "Copy something and it'll show up here."
                 : "No clips match \"\(viewModel.search)\".")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
    }

    private func row(_ item: ClipboardItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return HStack(alignment: .center, spacing: 12) {
            leadingGlyph(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Alfred-style ⌘N hint for the first 9 items only.
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppColors.bronze.opacity(0.25) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            viewModel.choose(item, plain: NSEvent.modifierFlags.contains(.option))
        }
        .contextMenu {
            Button(item.pinned ? "Unpin" : "Pin") { viewModel.pin(item) }
            Button("Paste as plain text") { viewModel.choose(item, plain: true) }
            Divider()
            Button("Remove", role: .destructive) { viewModel.remove(item) }
        }
    }

    /// Right-pane preview of the currently-selected clip. Mirrors Alfred:
    /// images render full-size scaled-to-fit; text renders monospaced
    /// scrollable. Bottom strip shows clip metadata.
    @ViewBuilder
    private var previewPane: some View {
        if let item = currentSelection {
            VStack(spacing: 0) {
                Group {
                    if let image = item.image,
                       let nsImage = Self.previewImage(filename: image.filename,
                                                      url: clipboard.imageURL(for: image),
                                                      thumbnailFallback: image.thumbnail) {
                        ScrollView {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .padding(16)
                        }
                    } else {
                        ScrollView {
                            Text(item.text)
                                .font(.system(.body, design: .default))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                previewMetadata(item)
            }
        } else {
            Color.clear
        }
    }

    private var currentSelection: ClipboardItem? {
        viewModel.filtered.indices.contains(selectedIndex)
            ? viewModel.filtered[selectedIndex]
            : nil
    }

    private func previewMetadata(_ item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            Text("Copied")
                .font(.caption).foregroundColor(.secondary)
            Text(item.capturedAt, style: .date)
                .font(.caption).foregroundColor(.secondary)
            Text(item.capturedAt, style: .time)
                .font(.caption).foregroundColor(.secondary)
            if let app = item.sourceApp {
                Text("·").foregroundColor(.secondary.opacity(0.5))
                Text(app).font(.caption).foregroundColor(.secondary)
            }
            if let img = item.image {
                Text("·").foregroundColor(.secondary.opacity(0.5))
                Text("\(img.width)×\(img.height)").font(.caption).foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary.opacity(0.5))
                Text(byteString(img.bytes)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var footer: some View {
        // Modifier-reactive hints (Maccy `FooterView` pattern). The visible
        // labels swap as the user holds ⌥, so they discover plain-paste
        // without needing to read docs.
        HStack(spacing: 12) {
            FooterHint(key: "↩︎", label: viewModel.optionHeld ? "paste plain" : "paste")
            Divider().frame(height: 10)
            FooterHint(key: "⌘N", label: "paste Nth (1–9)")
            Divider().frame(height: 10)
            FooterHint(key: "↑↓", label: "navigate")
            Spacer()
            FooterHint(key: "⎋", label: "close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func pasteSelected(plain: Bool) {
        guard viewModel.filtered.indices.contains(selectedIndex) else { return }
        viewModel.choose(viewModel.filtered[selectedIndex], plain: plain)
    }

    @ViewBuilder
    private func leadingGlyph(for item: ClipboardItem) -> some View {
        if let image = item.image, let nsImage = NSImage(data: image.thumbnail) {
            // Image clips: thumbnail itself is the most useful preview.
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
        } else if let appIcon = Self.icon(forBundleID: item.sourceBundleID) {
            // Maccy convention: source-app icon is the strongest "what is
            // this clip" signal. Pin overlay if pinned.
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(AppColors.bronze)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.pinned ? "pin.fill" : "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundColor(item.pinned ? AppColors.bronze : .secondary)
                .frame(width: 22, height: 22)
        }
    }

    /// Thread-safe cache for app icons by bundle ID. `NSCache` is
    /// documented thread-safe + auto-evicts under memory pressure — we
    /// just lack a Sendable conformance, so `nonisolated(unsafe)` is
    /// honest about the SDK gap rather than a real risk. Static so it
    /// survives picker open/close cycles.
    nonisolated(unsafe) private static let iconCache: NSCache<NSString, NSImage> = NSCache()

    nonisolated private static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    /// Cached preview NSImages keyed by filename so arrow-keying through
    /// image clips doesn't re-decode the PNG from disk each step. NSCache
    /// auto-evicts under memory pressure (preview images are large).
    nonisolated(unsafe) private static let previewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32 // ~32 large PNGs in RAM, enough for fluid scroll
        return cache
    }()

    nonisolated private static func previewImage(
        filename: String,
        url: URL,
        thumbnailFallback: Data
    ) -> NSImage? {
        let key = filename as NSString
        if let cached = previewCache.object(forKey: key) { return cached }
        let img = NSImage(contentsOf: url) ?? NSImage(data: thumbnailFallback)
        if let img { previewCache.setObject(img, forKey: key) }
        return img
    }
}

/// AppKit-backed search field — the SwiftUI TextField + @FocusState combo
/// kept losing the focus race against a non-activating NSPanel. Wrapping
/// NSSearchField here lets the panel call `makeFirstResponder(field)`
/// directly with no SwiftUI scheduler hop in the way.
private struct SearchFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    /// Called once with the NSSearchField the moment makeNSView creates
    /// it. The controller stashes this reference so it can call
    /// makeFirstResponder(field) directly without walking the view tree.
    var onCreate: (NSSearchField) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)
        field.delegate = context.coordinator
        field.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        field.placeholderString = "Search clipboard…"
        // Use the standard search-field look (rounded bezel, light bg,
        // built-in magnifying glass icon on the left). The previous
        // borderless config was causing the search icon and placeholder
        // text to overlap and render weird. Standard look matches
        // Maccy/Alfred and lets NSSearchField place its own icon
        // correctly inside the bezel.
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        DispatchQueue.main.async { onCreate(field) }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Single-line footer hint with a key glyph and a label. Two flavors of
/// type face so the keys read distinct from the verbs.
@MainActor
private struct FooterHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
