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

/// Callout + permission rows. The welcome step embeds this; the sheet wraps
/// it with the app icon and title.
public struct PermissionsPanel: View {
    @ObservedObject var model: PermissionsModel
    let appIcon: NSImage

    public init(model: PermissionsModel, appIcon: NSImage? = nil) {
        self.model = model
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
    }

    public var body: some View {
        VStack(spacing: 14) {
            if model.showsDragCallout { callout }
            VStack(spacing: 0) {
                let rows = KatibPermission.all
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    PermissionRow(row: row, state: model.state(row.id)) { model.grant(row.id) }
                    if index < rows.count - 1 { Divider().padding(.leading, 62) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
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

    private var callout: some View {
        // Bold lead like Rex's "Drag the icon above into the list…".
        (Text("Drag the icon above into the list in System Settings.").bold()
            + Text(" Turn Katib on if it is already there."))
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionRow: View {
    let row: KatibPermission
    let state: PermissionsModel.RowState
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                // One Text so a long name ("Screen & System Audio Recording")
                // wraps instead of truncating; "Optional" trails it.
                (Text(row.name).font(.system(size: 13, weight: .semibold))
                    + Text(row.required ? "" : "  Optional").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.why)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .needsRelaunch {
                    Text("Turned it on already? Katib needs a restart to see it.")
                        .font(.system(size: 11)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .semibold))
                Text("Granted").font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Color(nsColor: .systemGreen))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: .systemGreen).opacity(0.14), in: Capsule())
        case .missing:
            Button("Grant…", action: grant).buttonStyle(ChipButtonStyle())
        case .needsRelaunch:
            VStack(alignment: .trailing, spacing: 6) {
                Button("Relaunch to finish") { AppRelaunch.relaunch() }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                Button("Grant…", action: grant).buttonStyle(ChipButtonStyle())
            }
        }
    }
}

private struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(prominent ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.09))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The "Manage Permissions" sheet: app icon, title, callout, rows.
public struct ManagePermissionsView: View {
    @StateObject private var model = PermissionsModel()
    let appIcon: NSImage
    let onClose: (() -> Void)?

    public init(appIcon: NSImage? = nil, onClose: (() -> Void)? = nil) {
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Drag this onto the System Settings list: a file provider for the
            // app bundle, so the drop adds Katib itself.
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 76, height: 76)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag into the list in System Settings")
                .padding(.top, 24)
            Text("Manage Permissions")
                .font(.system(size: 22, weight: .bold))
            PermissionsPanel(model: model, appIcon: appIcon)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .padding(12)
            }
        }
    }
}
