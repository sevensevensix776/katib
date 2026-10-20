import Foundation
import AppKit
import Carbon.HIToolbox
import SwiftUI
import KatibCore
import KatibLauncher

/// Floating Command Palette — the single entry point for any Katib action.
/// Global hotkey (default ⇧⌘K) pops a search field; user types a fragment of
/// an action name and hits Enter to invoke.
///
/// Architecture mirrors ClipboardPanelController — non-activating NSPanel,
/// positioned near the cursor, cosmetic NSWindowDelegate hides on blur.
@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    static let shared = CommandPaletteController()

    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4b544350 // "KTCP"

    override init() { super.init() }

    // MARK: - Hotkey

    /// One candidate hotkey + a human-readable label for logs. The label
    /// is what we show the user when we tell them which combo we ended
    /// up bound to ("Command palette: ⌘Space"). Carbon-format modifiers.
    struct HotkeyPreference {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    /// Try preferences in order, install the first one that's free.
    /// Returns the label of whichever bound, or nil if all conflicted.
    /// `RegisterEventHotKey` returns `eventHotKeyExistsErr` (-9878) when
    /// another Carbon-registered hotkey owns the combo — Spotlight,
    /// Alfred, Raycast, etc. all use Carbon for their primary trigger,
    /// so this catches the realistic conflict cases. CGEventTap-based
    /// bindings (rare for primary hotkeys) won't conflict here but will
    /// shadow our handler — the user just rebinds via fallback.
    @discardableResult
    func installHotkey(preferences: [HotkeyPreference]) -> String? {
        uninstallHotkey()

        for pref in preferences {
            let hotKeyID = EventHotKeyID(signature: signature, id: 1)
            let status = RegisterEventHotKey(
                pref.keyCode, pref.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &hotKeyRef
            )
            if status == noErr {
                if installEventHandler() {
                    Logger.shared.log("Command palette: bound to \(pref.label)")
                    return pref.label
                }
                // Handler install failed — clean up the registration we
                // just made and try the next preference.
                uninstallHotkey()
            } else {
                Logger.shared.log("Command palette: \(pref.label) unavailable (status \(status)), trying next…")
            }
        }
        Logger.shared.log("Command palette: no hotkey bound (all preferences conflicted)")
        return nil
    }

    /// Convenience for callers with a single-combo binding.
    func installHotkey(keyCode: UInt32, modifiers: UInt32, label: String = "command-palette") {
        installHotkey(preferences: [HotkeyPreference(keyCode: keyCode, modifiers: modifiers, label: label)])
    }

    private func installEventHandler() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let c = Unmanaged<CommandPaletteController>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in c.toggle() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Logger.shared.log("Command palette handler install failed (\(status))")
            return false
        }
        return true
    }

    func uninstallHotkey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    // MARK: - Panel lifecycle

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// `initialQuery` pre-fills the search field. Used by the
    /// `-paletteQuery <text>` launch argument so the palette can be opened
    /// and screenshotted without synthetic keystrokes.
    func show(initialQuery: String = "") {
        PluginRegistry.shared.reload()   // a plugin added since launch shows up now
        let view = CommandPaletteView(initialQuery: initialQuery, onDismiss: { [weak self] in self?.hide() })
        // NSHostingView directly — NOT NSHostingController(...).view.
        // The controller pattern releases the controller at end of
        // show() (it's a local var), but SwiftUI's bridge keeps weak
        // refs to controller-bound state. Subsequent body re-renders
        // dereference stale executor metadata and crash with
        // EXC_BAD_ACCESS in swift_task_isMainExecutorImpl. Hit on
        // 2026-05-03 (twice — same crash signature survived an entire
        // architecture rewrite of the data layer because the host
        // pattern was unchanged).
        // SnapPreviewWindow + LiveIndicatorWindowController already
        // use this pattern; matching them.
        let hostingView = NSHostingView(rootView: view)

        // Same sizing lesson as ClipboardPanelController: fraction of the
        // active screen so the palette feels proportional on different
        // displays. Raycast / VSCode / Alfred palettes all float around
        // this scale — bigger than Apple's Spotlight, smaller than the
        // clipboard's two-pane picker.
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame
                      ?? NSScreen.main?.frame
                      ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let size = Self.calculatePanelSize(screenSize: screen.size)
        let panelWidth = size.width
        let panelHeight = size.height

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            // No `.utilityWindow` — it coerces to a smaller default size.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Belt-and-suspenders: nail the content size before the SwiftUI
        // host queries preferredContentSize (which is 0 pre-layout).
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
        panel.delegate = self

        // Set frame on the hosting view + content size on the panel.
        // We previously created an NSHostingController and pulled its
        // `.view` here — that pattern crashed (see comment above where
        // hostingView is constructed). NSHostingView is the supported
        // direct-host primitive when you don't need controller
        // semantics; same 1×1-collapse-via-`contentViewController`
        // pitfall doesn't apply because we never set
        // `panel.contentViewController`.
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))

        positionCentered(panel)
        panel.makeKeyAndOrderFront(nil)
        Logger.shared.log(
            "Command palette: requested=\(Int(panelWidth))×\(Int(panelHeight)) " +
            "actual=\(Int(panel.frame.width))×\(Int(panel.frame.height)) " +
            "screen=\(Int(screen.width))×\(Int(screen.height))"
        )
        self.panel = panel
    }

    /// Pure: palette dimensions for a given screen. Between Spotlight and
    /// the clipboard two-pane picker — 55%×55% of screen with floors so
    /// small displays still show 8+ commands comfortably and caps so a
    /// 6K panel doesn't swallow the screen. Public + static so tests
    /// could lock the math down if we ever add a Katib-exec test target.
    public static func calculatePanelSize(screenSize: CGSize) -> CGSize {
        let widthFraction:  CGFloat = 0.55
        let heightFraction: CGFloat = 0.55
        let minWidth:  CGFloat = 720
        let maxWidth:  CGFloat = 1100
        let minHeight: CGFloat = 520
        let maxHeight: CGFloat = 780
        let w = min(max(screenSize.width  * widthFraction,  minWidth),  maxWidth)
        let h = min(max(screenSize.height * heightFraction, minHeight), maxHeight)
        return CGSize(width: w, height: h)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func positionCentered(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let frame = panel.frame
        let origin = NSPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.frame.midY - frame.height / 2 + 120  // sit slightly above center
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View

@MainActor
private struct CommandPaletteView: View {
    @ObservedObject private var registry = CommandRegistry.shared
    @StateObject private var fileSearch = FileSearchProvider()
    @StateObject private var pluginSearch = PluginSearch(plugins: PluginRegistry.shared.searchPlugins)
    @State private var query: String
    @State private var selection: Int = 0
    @FocusState private var searchFocused: Bool
    let onDismiss: () -> Void

    init(initialQuery: String = "", onDismiss: @escaping () -> Void) {
        _query = State(initialValue: initialQuery)
        self.onDismiss = onDismiss
    }

    /// Rows grouped under headers (see `PaletteGrouping`): registry sources in
    /// relevance order, then each search plugin, then Files, which arrive
    /// later. Each file and plugin hit becomes an ephemeral `KatibCommand` so
    /// the row renderer doesn't need to branch.
    private var groups: [PaletteGroup] {
        let registryHits = registry.search(query, limit: 80)
        let fileHits = fileSearch.results.map { result -> KatibCommand in
            let url = result.url
            return KatibCommand(
                id: "katib.file.\(result.id)",
                title: result.displayName,
                subtitle: result.kind ?? url.deletingLastPathComponent().path,
                keywords: ["file", "open"],
                symbol: "doc",
                iconFileURL: url,
                section: .file
            ) {
                NSWorkspace.shared.open(url)
            }
        }
        let pluginGroups = pluginSearch.plugins.map { plugin -> PaletteGroup in
            let hits = (pluginSearch.results[plugin.id] ?? []).map { hit -> KatibCommand in
                KatibCommand(
                    id: "katib.plugin.\(plugin.id).\(hit.id)",
                    title: hit.title,
                    subtitle: hit.subtitle,
                    keywords: [],
                    symbol: plugin.manifest.search?.symbol ?? "puzzlepiece.extension",
                    detail: hit.snippet,
                    section: .plugin
                ) {
                    if let url = hit.url { PluginSearch.open(url) }
                }
            }
            return PaletteGroup(source: Self.source(plugin), items: hits)
        }
        return PaletteGrouping.group(registry: registryHits, plugins: pluginGroups, files: fileHits)
    }

    /// Flat list in display order; keyboard selection indexes into it.
    private var results: [KatibCommand] { groups.flatMap(\.items) }

    static func source(_ plugin: Plugin) -> PaletteSource {
        .plugin(id: plugin.id, name: plugin.name, color: plugin.manifest.search?.color)
    }

    /// Plugins still searching with nothing to show yet, or failed: drawn as
    /// a bare header ("searching…" or the reason) so the wait is visible.
    private var pluginStatusHeaders: [(source: PaletteSource, note: String?)] {
        let shown = Set(groups.map(\.source))
        return pluginSearch.plugins.compactMap { plugin in
            let source = Self.source(plugin)
            guard !shown.contains(source) else { return nil }
            if let why = pluginSearch.failures[plugin.id] { return (source, why) }
            if pluginSearch.searching.contains(plugin.id) { return (source, nil) }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
            Divider()
            footer
        }
        .tint(AppColors.bronze)
        .onAppear {
            searchFocused = true
            if !query.isEmpty {   // opened with -paletteQuery
                fileSearch.search(query)
                pluginSearch.search(query)
            }
        }
        .onDisappear {
            fileSearch.cancel()
            pluginSearch.cancel()
        }
        // Plugins and Files land after the user may have arrowed down: keep
        // the same row selected, so Return never opens a row that slid in.
        .onChange(of: results.map(\.id)) { old, new in
            guard old.indices.contains(selection), let i = new.firstIndex(of: old[selection]) else { return }
            selection = i
        }
        .onChange(of: query) { _, newQuery in
            selection = 0
            fileSearch.search(newQuery)
            pluginSearch.search(newQuery)
        }
        .background(
            Group {
                Button("") { runSelected() }
                    .keyboardShortcut(.return, modifiers: [])
                    .hidden()
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                Button("") { selection = max(selection - 1, 0) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .hidden()
                Button("") { selection = min(selection + 1, max(results.count - 1, 0)) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .hidden()
            }
        )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .foregroundColor(AppColors.bronze)
                .font(.title3)
            TextField("Search actions, apps and files…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""; searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var list: some View {
        if results.isEmpty && pluginStatusHeaders.isEmpty {
            empty
        } else {
            let groups = self.groups
            let offsets = Self.rowOffsets(groups)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.source) { gi, group in
                            header(group.source, count: group.items.count)
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, cmd in
                                row(cmd, index: offsets[gi] + i, source: group.source).id(cmd.id)
                            }
                        }
                        ForEach(pluginStatusHeaders, id: \.source) { status in
                            header(status.source, count: nil, note: status.note)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selection) { _, newValue in
                    guard results.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.08)) {
                        proxy.scrollTo(results[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text("No matches")
                .font(.callout)
            if !query.isEmpty {
                Text("Try an action (\"split\", \"capture\"), an app or a file name")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }

    /// Section header: a colored dot, the source name and its count. A nil
    /// count means "still searching", or shows `note` when the source failed.
    private func header(_ source: PaletteSource, count: Int?, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Self.color(for: source)).frame(width: 6, height: 6)
            Text(source.title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            if let count {
                Text("\(count)").font(.caption2).foregroundColor(.secondary.opacity(0.7))
            } else if let note {
                Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundColor(.orange)
                Text(note).font(.caption2).foregroundColor(.orange)
            } else {
                ProgressView().controlSize(.mini)
                Text("searching…").font(.caption2).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }

    /// "[word]" → bold "word". Unbalanced brackets are left as typed.
    static func boldMatches(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]") {
            out += AttributedString(String(rest[..<open]))
            var match = AttributedString(String(rest[rest.index(after: open)..<close]))
            // An explicit font + color: `inlinePresentationIntent` bold was
            // ignored under the row's .caption font (checked by screenshot).
            match.font = .caption.weight(.bold)
            match.foregroundColor = .primary
            out += match
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return out
    }

    /// offsets[g] = flat index of group g's first row, so keyboard selection
    /// (an index into `results`) lines up with the grouped rows.
    static func rowOffsets(_ groups: [PaletteGroup]) -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for g in groups {
            offsets.append(running)
            running += g.items.count
        }
        return offsets
    }

    /// One color per source. System colors, so they adapt to dark mode.
    static func color(for source: PaletteSource) -> Color {
        switch source {
        case .commands: return AppColors.bronze
        case .settings: return .gray
        case .apps: return .blue
        case .files: return .green
        case .plugin(_, _, let color): return pluginColor(color)
        }
    }

    static func pluginColor(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "pink": return .pink
        case "teal": return .teal
        case "orange": return .orange
        case "red": return .red
        case "yellow": return .yellow
        case "indigo": return .indigo
        case "mint": return .mint
        case "cyan": return .cyan
        case "brown": return .brown
        default: return .purple
        }
    }

    private func row(_ cmd: KatibCommand, index: Int, source: PaletteSource) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon(for: cmd, selected: index == selection, source: source)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(.callout).lineLimit(1)
                if let sub = cmd.subtitle {
                    Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let detail = cmd.detail {
                    Text(Self.boldMatches(detail))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer()
            if let hint = cmd.shortcutHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            // Commands mix several kinds (Window, Dictation, …): keep their
            // kind as a quiet tag. Other groups are already named by the header.
            if source == .commands {
                Text(cmd.section.displayName.uppercased())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index == selection ? AppColors.bronze.opacity(0.2) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { run(cmd) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("↵", systemImage: "return").font(.caption2)
            Text("run").font(.caption2).foregroundColor(.secondary)
            Divider().frame(height: 10)
            Text("↑↓").font(.caption2)
            Text("navigate").font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text("\(registry.commands.count) commands")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func icon(for cmd: KatibCommand, selected: Bool, source: PaletteSource) -> some View {
        if let url = cmd.iconFileURL {
            // NSWorkspace caches icons internally, so this is cheap to call
            // per row. Falling back to the SF Symbol if the file vanished
            // between scan and render.
            let nsImage = NSWorkspace.shared.icon(forFile: url.path)
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: cmd.symbol)
                .foregroundColor(selected ? AppColors.bronze : Self.color(for: source).opacity(0.85))
        }
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ cmd: KatibCommand) {
        FrecencyStore.shared.touch(cmd.id)
        onDismiss()
        // Tiny hop so the panel dismisses before the action runs (avoids focus race).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cmd.perform()
        }
    }
}
