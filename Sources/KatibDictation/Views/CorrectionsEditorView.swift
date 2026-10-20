import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KatibCore

@MainActor
public struct CorrectionsEditorView: View {
    @ObservedObject var engine: TextCorrectionEngine

    public init(engine: TextCorrectionEngine) {
        self.engine = engine
    }

    @State private var selectedType: CorrectionType = .dictionary
    @State private var searchText: String = ""
    @State private var editing: Entry?
    @State private var showingAddSheet = false
    @State private var importError: String?
    @State private var selection: Set<Entry.ID> = []
    @FocusState private var searchFocused: Bool

    struct Entry: Identifiable, Hashable {
        var from: String
        var to: String
        let type: CorrectionType
        let originalKey: String

        /// Stable across renders: keyed on the underlying correction + bucket, not a per-instance UUID.
        /// Otherwise the editing sheet's `@State editing` ghosts after a save.
        var id: String { "\(type):\(originalKey)" }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            list
        }
        .frame(minWidth: 560, minHeight: 480)
        .tint(AppColors.bronze)
        .background(
            Button("Focus search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { importError != nil },
                   set: { if !$0 { importError = nil } }
               ),
               presenting: importError) { _ in
            Button("OK", role: .cancel) { importError = nil }
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: $showingAddSheet) {
            EntryEditorSheet(
                mode: .add,
                initial: Entry(from: "", to: "", type: selectedType, originalKey: ""),
                onSave: { entry in
                    engine.upsertCorrection(from: entry.from, to: entry.to, type: entry.type)
                }
            )
        }
        .sheet(item: $editing) { entry in
            EntryEditorSheet(
                mode: .edit,
                initial: entry,
                onSave: { updated in
                    if updated.from != updated.originalKey {
                        engine.removeCorrection(key: updated.originalKey, type: updated.type)
                    }
                    engine.upsertCorrection(from: updated.from, to: updated.to, type: updated.type)
                }
            )
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Corrections")
                .font(.headline)
            Spacer()
            Menu {
                Button("Export to JSON…") { exportCorrections() }
                Button("Import (merge)…") { importCorrections(strategy: .merge) }
                Button("Import (replace)…") { importCorrections(strategy: .replace) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Import / export corrections")

            Button {
                showingAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityLabel("Add correction")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding()
    }

    private func exportCorrections() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "katib-corrections.json"
        panel.message = "Save your corrections to a JSON file you can share or back up."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try engine.exportData()
            try data.write(to: url)
        } catch {
            importError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importCorrections(strategy: TextCorrectionEngine.ImportStrategy) {
        if strategy == .replace {
            let confirm = NSAlert()
            confirm.messageText = "Replace all your corrections?"
            confirm.informativeText = """
            Your current \(engine.totalCount) corrections (casing, rewrites, phrases)
            will be wiped and replaced with whatever's in the file you pick.
            This can't be undone from inside Katib — export first if you want a backup.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Choose file…")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = strategy == .merge
            ? "Choose a corrections JSON to merge into your current set."
            : "Choose a corrections JSON — existing corrections will be replaced."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try engine.importData(data, strategy: strategy)
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    private var filterBar: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Picker("Type", selection: $selectedType) {
                Text("Casing \(bucketCount(.dictionary))").tag(CorrectionType.dictionary)
                Text("Rewrites \(bucketCount(.replacement))").tag(CorrectionType.replacement)
                Text("Phrases \(bucketCount(.phonetic))").tag(CorrectionType.phonetic)
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func bucketCount(_ type: CorrectionType) -> String {
        let count: Int
        switch type {
        case .dictionary: count = engine.corrections.dictionary.filter { !$0.key.hasPrefix("_comment") }.count
        case .replacement: count = engine.corrections.replacements.count
        case .phonetic: count = engine.corrections.phonetic.count
        }
        return count > 0 ? "(\(count))" : ""
    }

    @ViewBuilder
    private var list: some View {
        if filteredEntries.isEmpty {
            emptyState
        } else {
            Table(filteredEntries, selection: $selection) {
                TableColumn("Heard / Written") { entry in
                    Text(entry.from)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 120, ideal: 200)

                TableColumn("Katib pastes") { entry in
                    Text(entry.to)
                }
                .width(min: 120, ideal: 260)

                TableColumn("") { entry in
                    HStack(spacing: 4) {
                        Button {
                            editing = entry
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Edit \(entry.from)")
                        Button {
                            engine.removeCorrection(key: entry.originalKey, type: entry.type)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Delete \(entry.from)")
                    }
                }
                .width(60)
            }
            .contextMenu(forSelectionType: Entry.ID.self) { ids in
                Button("Delete") { deleteSelected(ids) }
            }
            .onDeleteCommand { deleteSelected(selection) }
        }
    }

    private func deleteSelected(_ ids: Set<Entry.ID>) {
        let keys = filteredEntries
            .filter { ids.contains($0.id) }
            .map { $0.originalKey }
        guard !keys.isEmpty else { return }
        engine.removeCorrections(keys, type: selectedType)
        selection.removeAll()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary)
            Text(emptyStateTitle)
                .font(.headline)
            Text(emptyStateDetail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showingAddSheet = true
            } label: {
                Label("Add your first", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateIcon: String {
        searchText.isEmpty ? "character.book.closed" : "magnifyingglass"
    }

    private var emptyStateTitle: String {
        searchText.isEmpty ? "No \(bucketLabel) yet" : "No matches"
    }

    private var emptyStateDetail: String {
        if !searchText.isEmpty {
            return "No \(bucketLabel) match \"\(searchText)\"."
        }
        switch selectedType {
        case .dictionary: return "Add words that should always paste with specific casing — e.g. api → API, github → GitHub."
        case .replacement: return "Rewrite casual speech into clean text — e.g. gonna → going to, wanna → want to."
        case .phonetic: return "Fix speech-to-text misrecognitions across multiple words — e.g. hub spot → HubSpot, seven seven six → 776."
        }
    }

    private var bucketLabel: String {
        switch selectedType {
        case .dictionary: return "casing fixes"
        case .replacement: return "rewrites"
        case .phonetic: return "phrases"
        }
    }

    private var searchPlaceholder: String {
        switch selectedType {
        case .dictionary: return "Search casing fixes…"
        case .replacement: return "Search rewrites…"
        case .phonetic: return "Search phrases…"
        }
    }

    private var allEntries: [Entry] {
        let dict: [String: String]
        switch selectedType {
        case .dictionary: dict = engine.corrections.dictionary
        case .replacement: dict = engine.corrections.replacements
        case .phonetic: dict = engine.corrections.phonetic
        }
        return dict
            .filter { !$0.key.hasPrefix("_comment") }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { Entry(from: $0.key, to: $0.value, type: selectedType, originalKey: $0.key) }
    }

    private var filteredEntries: [Entry] {
        guard !searchText.isEmpty else { return allEntries }
        let q = searchText.lowercased()
        return allEntries.filter {
            $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
        }
    }
}

private struct EntryEditorSheet: View {
    enum Mode { case add, edit }

    let mode: Mode
    @State var entry: CorrectionsEditorView.Entry
    let onSave: (CorrectionsEditorView.Entry) -> Void

    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, initial: CorrectionsEditorView.Entry, onSave: @escaping (CorrectionsEditorView.Entry) -> Void) {
        self.mode = mode
        _entry = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .add ? "Add correction" : "Edit correction")
                .font(.headline)

            Form {
                TextField("From", text: $entry.from, prompt: Text("what speech recognition hears"))
                TextField("To", text: $entry.to, prompt: Text("what Katib should paste"))
            }

            Text(typeHint)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == .add ? "Add" : "Save") {
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.from.trimmingCharacters(in: .whitespaces).isEmpty ||
                          entry.to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var typeHint: String {
        switch entry.type {
        case .dictionary: return "Casing — fix how a word is written. e.g. api → API."
        case .replacement: return "Rewrite — swap one word for another. e.g. gonna → going to."
        case .phonetic: return "Phrase — fix a multi-word misrecognition. e.g. hub spot → HubSpot."
        }
    }
}
