import AppKit
import SwiftUI

/// Live permission state for the Manage Permissions sheet. Reads the OS, never
/// remembers: re-checks when Katib becomes active and on a timer while a view
/// that owns this model is on screen.
@MainActor
public final class PermissionsModel: ObservableObject {
    public enum RowState: Equatable {
        case granted
        case missing
        /// The person asked for Screen Recording and macOS still says no.
        /// macOS applies that grant only to a new process.
        case needsRelaunch
    }

    @Published public private(set) var granted: [KatibPermission.ID: Bool] = [:]
    @Published public private(set) var screenRecordingRequested = false

    public init() { refresh() }

    public func refresh() {
        var next: [KatibPermission.ID: Bool] = [:]
        for id in KatibPermission.ID.allCases { next[id] = KatibPermission.isGranted(id) }
        if next != granted { granted = next }
    }

    public func state(_ id: KatibPermission.ID) -> RowState {
        if granted[id] == true { return .granted }
        if id == .screenRecording && screenRecordingRequested { return .needsRelaunch }
        return .missing
    }

    public func grant(_ id: KatibPermission.ID) {
        if id == .screenRecording { screenRecordingRequested = true }
        KatibPermission.grant(id)
        refresh()
    }

    /// True while a list-type permission still needs its icon dragged in.
    public var showsDragCallout: Bool {
        KatibPermission.all.contains { $0.needsDrag && state($0.id) != .granted }
    }
}

/// Callout + PERMISSION / STATUS table. The welcome step embeds this; the
/// sheet wraps it with the title and the app icon. 776 Ledger look: Theme776.
public struct PermissionsPanel: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PermissionsModel
    let appIcon: NSImage

    public init(model: PermissionsModel, appIcon: NSImage? = nil) {
        self.model = model
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
    }

    private var p: Palette776 { .for(scheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsDragCallout { callout.padding(.bottom, 18) }
            Rule776(heavy: true)
            HStack {
                Label776("Permission")
                Spacer()
                Label776("Status")
            }
            .padding(.vertical, 9)
            let rows = KatibPermission.all
            ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                Rule776()
                PermissionRow(row: row, state: model.state(row.id)) { model.grant(row.id) }
            }
            Rule776()
            HStack {
                Mark776(width: 26)
                Spacer()
                Label776("\(grantedCount) of \(rows.count) granted", size: 9.5, color: p.muted)
            }
            .padding(.top, 14)
        }
        // Back from System Settings: flip to Granted at once. The timer
        // covers a toggle flipped while Katib stays in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
        .onAppear { model.refresh() }
    }

    private var grantedCount: Int {
        KatibPermission.all.filter { model.state($0.id) == .granted }.count
    }

    private var callout: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(p.purple).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                Label776("Drag", color: p.purpleText)
                Text("Drag the icon above into the list in System Settings. Turn Katib on if it is already there.")
                    .font(Type776.font(12.5)).foregroundColor(p.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRow: View {
    @Environment(\.colorScheme) private var scheme
    let row: KatibPermission
    let state: PermissionsModel.RowState
    let grant: () -> Void

    private var p: Palette776 { .for(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                // One Text so a long name ("Screen & System Audio Recording")
                // wraps instead of truncating; "Optional" trails it.
                (Text(row.name).font(Type776.font(15, .medium)).foregroundColor(p.ink)
                    + Text(row.required ? "" : "   OPTIONAL").font(Type776.font(9.5, .medium)).tracking(1.9).foregroundColor(p.muted))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            Text(row.why)
                .font(Type776.font(12)).foregroundColor(p.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 90)
            if state == .needsRelaunch {
                Text("Turned it on already? Katib needs a restart to see it.")
                    .font(Type776.font(11.5)).foregroundColor(p.purpleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            HStack(spacing: 6) {
                Circle().fill(p.purple).frame(width: 6, height: 6)
                Label776("Granted", color: p.ink)
            }
        case .missing:
            Button("Grant…", action: grant).buttonStyle(Button776Style())
        case .needsRelaunch:
            VStack(alignment: .trailing, spacing: 6) {
                Button("Relaunch to finish") { AppRelaunch.relaunch() }
                    .buttonStyle(Button776Style(filled: true))
                Button("Grant…", action: grant).buttonStyle(Button776Style())
            }
        }
    }
}

/// The "Manage Permissions" sheet: title, app icon to drag, callout, table.
public struct ManagePermissionsView: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var model = PermissionsModel()
    let appIcon: NSImage
    let onClose: (() -> Void)?

    public init(appIcon: NSImage? = nil, onClose: (() -> Void)? = nil) {
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
        self.onClose = onClose
    }

    private var p: Palette776 { .for(scheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Headline776("Manage permissions", size: 30)
                Spacer()
                // Drag this onto the System Settings list: a file provider for
                // the app bundle, so the drop adds Katib itself.
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 46, height: 46)
                    .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                    .help("Drag into the list in System Settings")
            }
            Text("Katib needs four things from macOS. Everything stays on your Mac.")
                .font(Type776.font(13)).foregroundColor(p.muted)
                .padding(.top, 6).padding(.bottom, 18)
            PermissionsPanel(model: model, appIcon: appIcon)
        }
        .padding(26)
        .padding(.top, onClose == nil ? 10 : 0)
        .frame(width: 460)
        .background(p.box)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                // Sheet only: the menu-bar window uses its own close button
                // (fd59a51), and passes no onClose.
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(p.muted.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .padding(12)
            }
        }
    }
}
