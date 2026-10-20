import SwiftUI
import AppKit
import KatibCore
import KatibSnippets

/// Snippets pane: CRUD over saved snippets + text-expander controls. New
/// snippets start as "picker-only" (no trigger) — user fills in a trigger
/// when they want auto-expansion.
@MainActor
struct SnippetsSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = SnippetStore.shared
    @State private var selectedSnippetID: UUID?
    @State private var editor: Snippet?
    @State private var isCreating = false

    var body: some View {
        Form {
            Section("Text expansion") {
                Toggle("Auto-expand triggers as I type", isOn: $settings.snippetExpansionEnabled)
                HStack {
                    Text("Trigger prefix")
                    Spacer()
                    TextField("", text: $settings.snippetPrefixCharacter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.center)
                }
                Text("""
                    Type the prefix + trigger to expand (e.g. `\(settings.snippetPrefixCharacter)sig`). \
                    The trigger characters appear briefly in the target app before being replaced — same \
                    visual as TextExpander / aText. Never reads secure input fields.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("\(store.snippets.count) snippets")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        editor = Snippet(name: "", trigger: "", content: "")
                        isCreating = true
                    } label: {
                        Label("New snippet", systemImage: "plus")
                    }
                }

                if store.snippets.isEmpty {
                    emptyState
                } else {
                    snippetList
                }
            }
        }
        .formStyle(.grouped)
        .tint(AppColors.bronze)
        .sheet(item: $editor) { snippet in
            SnippetEditorSheet(
                snippet: snippet,
                isNew: isCreating,
                onSave: { edited in
                    if isCreating { store.add(edited) } else { store.update(edited) }
                    editor = nil
                    isCreating = false
                },
                onCancel: {
                    editor = nil
                    isCreating = false
                },
                onDelete: isCreating ? nil : {
                    store.remove(snippet)
                    editor = nil
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text("No snippets yet").font(.callout)
            Text("Click New snippet to create one. Pop the picker with ⌃⌘Space.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var snippetList: some View {
        ForEach(store.snippets) { snippet in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                            .font(.callout).bold()
                        if !snippet.trigger.isEmpty {
                            Text("\(settings.snippetPrefixCharacter)\(snippet.trigger)")
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(AppColors.bronze.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(snippet.preview).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Edit") {
                    editor = snippet
                    isCreating = false
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Modal editor for creating / updating a snippet.
@MainActor
private struct SnippetEditorSheet: View {
    @State var snippet: Snippet
    let isNew: Bool
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New snippet" : "Edit snippet").font(.headline)

            TextField("Name (e.g. Email signature)", text: $snippet.name)
                .textFieldStyle(.roundedBorder)

            TextField("Trigger (e.g. sig) — leave empty for picker-only",
                      text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("Content")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $snippet.content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary, lineWidth: 1)
                )

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.isEmpty || snippet.content.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
