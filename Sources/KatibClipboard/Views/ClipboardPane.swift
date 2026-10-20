import SwiftUI
import AppKit
import KatibCore

/// Clipboard tab content for the menu bar popover. Alfred-inspired:
/// search at the top, pinned items float above the rest, click to copy back,
/// ⌘P toggles pin, Option-click pastes plain.
@MainActor
public struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardManager

    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    public init(clipboard: ClipboardManager) {
        self.clipboard = clipboard
    }

    private var visible: [ClipboardItem] {
        clipboard.visibleItems(matching: searchText)
    }

    public var body: some View {
        if clipboard.items.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                searchField
                headerRow
                list
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search clipboard…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { pasteTopMatch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var headerRow: some View {
        HStack {
            Text("\(visible.count) of \(clipboard.items.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                clipboard.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Clear clipboard history")
            .accessibilityLabel("Clear clipboard history")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { item in
                    row(item)
                }
                if visible.isEmpty {
                    Text("No matches for \"\(searchText)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 14)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text("No clips yet")
                .font(.callout)
            Text("Anything you copy while Katib is running shows up here. Passwords and transient clips are skipped automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func row(_ item: ClipboardItem) -> some View {
        Button {
            copyAndClose(item, plainText: false)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                glyph(for: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.capturedAt, style: .relative)
                        if let app = item.sourceApp {
                            Text("·").foregroundColor(.secondary.opacity(0.6))
                            Text(app)
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    clipboard.togglePin(item)
                } label: {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary.opacity(0.7))
                .help(item.pinned ? "Unpin" : "Pin to top")
                Button {
                    clipboard.remove(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary.opacity(0.7))
                .accessibilityLabel("Remove from clipboard history")
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Button("Copy (plain text)") { copyAndClose(item, plainText: true) }
            Divider()
            Button("Remove", role: .destructive) { clipboard.remove(item) }
        }
        .help("Click to put back on your clipboard — then ⌘V into any app. Option-click for plain text.")
    }

    private func copyAndClose(_ item: ClipboardItem, plainText: Bool) {
        if plainText || NSEvent.modifierFlags.contains(.option) {
            clipboard.copyPlainToPasteboard(item)
        } else {
            clipboard.copyToPasteboard(item)
        }
    }

    @ViewBuilder
    private func glyph(for item: ClipboardItem) -> some View {
        if let image = item.image, let nsImage = NSImage(data: image.thumbnail) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: item.pinned ? "pin.fill" : "doc.on.clipboard")
                .font(.caption2)
                .foregroundColor(item.pinned ? AppColors.bronze : .secondary)
                .padding(.top, 2)
                .frame(width: 24)
        }
    }

    private func pasteTopMatch() {
        guard let first = visible.first else { return }
        copyAndClose(first, plainText: false)
    }
}
