import AppKit
import SwiftUI

/// Notes, synced with the phone (R29): the list on the left, the note on the right. Works while the phone is away;
/// changes go out when it's back.
struct NotesPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var search = ""
    @State private var showingTrash = false
    private var store: NotesStore { .shared }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(showingTrash ? "Recently Deleted" : "Notes")
        .navigationSubtitle(syncStatus)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar { toolbar }
        .onChange(of: selection) { old, _ in discardIfEmpty(old) }
        .onAppear { if selection == nil { selection = (showingTrash ? store.trash : store.live).first?.id } }
    }

    // MARK: List

    private var shown: [Note] {
        let list = showingTrash ? store.trash : store.live
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            let notes = shown
            List(selection: $selection) {
                if showingTrash {
                    Section { ForEach(notes) { row($0) } } footer: {
                        if !notes.isEmpty { Text("Deleted notes stay here for 30 days.").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    let pinned = notes.filter(\.pinned), rest = notes.filter { !$0.pinned }
                    if !pinned.isEmpty { Section("Pinned") { ForEach(pinned) { row($0) } } }
                    if !rest.isEmpty { Section(pinned.isEmpty ? "" : "Notes") { ForEach(rest) { row($0) } } }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView(search.isEmpty ? (showingTrash ? "Nothing Deleted" : "No Notes") : "No Results",
                                           systemImage: showingTrash ? "trash" : "note.text",
                                           description: Text(search.isEmpty && !showingTrash ? "Click \(Image(systemName: "square.and.pencil")) to write one. It shows up on your phone too." : ""))
                }
            }
            Divider()
            Button {
                showingTrash.toggle()
                selection = (showingTrash ? store.trash : store.live).first?.id
            } label: {
                HStack {
                    Label(showingTrash ? "Notes" : "Recently Deleted", systemImage: showingTrash ? "chevron.left" : "trash")
                    Spacer()
                    if !showingTrash, !store.trash.isEmpty { Text("\(store.trash.count)").foregroundStyle(.secondary).monospacedDigit() }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ n: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.date(n.deleted ?? n.modified)).foregroundStyle(.secondary)
                Text(n.preview.isEmpty ? "No additional text" : n.preview).foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.callout)
        }
        .padding(.vertical, 3)
        .tag(n.id)
        .contextMenu {
            if n.deleted == nil {
                Button(n.pinned ? "Unpin" : "Pin") { store.togglePin(n.id) }
                Button("Delete", role: .destructive) { delete(n.id) }
            } else {
                Button("Restore") { restore(n.id) }
                Button("Delete Now", role: .destructive) { store.deleteNow(n.id) }
            }
        }
    }

    /// "14:05" today, "Yesterday", then the date.
    static func date(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.day().month(.abbreviated).year(Calendar.current.isDate(d, equalTo: .now, toGranularity: .year) ? .omitted : .defaultDigits))
    }

    // MARK: Note

    @ViewBuilder private var detail: some View {
        if let n = store.note(selection), (n.deleted != nil) == showingTrash {
            VStack(spacing: 0) {
                Text((n.deleted ?? n.modified).formatted(date: .long, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 10)
                NoteEditor(text: Binding(get: { store.note(n.id)?.text ?? "" }, set: { store.setText(n.id, $0) }),
                           noteID: n.id, editable: n.deleted == nil)
                if n.deleted != nil {
                    HStack {
                        Text("Restore this note to edit it.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Now", role: .destructive) { store.deleteNow(n.id); selection = store.trash.first?.id }
                        Button("Restore") { restore(n.id) }.keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    .background(.bar)
                }
            }
        } else {
            ContentUnavailableView(showingTrash ? "No Note Selected" : "No Note Selected", systemImage: "note.text")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Note (⌘N)")
            NoteFormatMenu()
                .disabled(showingTrash || selection == nil)
            Button { NSApp.sendAction(#selector(NoteTextView.insertTable(_:)), to: nil, from: nil) } label: {
                Label("Table", systemImage: "tablecells")
            }
            .help("Insert a table (right-click a table to add or remove rows and columns)")
            .disabled(showingTrash || selection == nil)
            Button { NSApp.sendAction(#selector(NoteTextView.attachFile(_:)), to: nil, from: nil) } label: {
                Label("Attach File", systemImage: "paperclip")
            }
            .help("Attach a file or photo (or drag one into the note)")
            .disabled(showingTrash || selection == nil)
            Button { NSApp.sendAction(#selector(NoteTextView.toggleChecklist(_:)), to: nil, from: nil) } label: {
                Label("Checklist", systemImage: "checklist")
            }
            .help("Checklist (⇧⌘L)")
            .disabled(showingTrash || selection == nil)
            if let n = store.note(selection), n.deleted == nil {
                Button { store.togglePin(n.id) } label: { Label(n.pinned ? "Unpin" : "Pin", systemImage: n.pinned ? "pin.slash" : "pin") }
                    .help(n.pinned ? "Unpin" : "Pin")
                Button { delete(n.id) } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Delete (⌘⌫)")
            }
        }
    }

    // MARK: Actions

    private func newNote() {
        showingTrash = false
        search = ""
        let n = store.create()
        selection = n.id
    }

    private func delete(_ id: String) {
        let next = store.live.drop { $0.id != id }.dropFirst().first?.id ?? store.live.last { $0.id != id }?.id
        store.delete(id)
        selection = next
    }

    private func restore(_ id: String) {
        store.restore(id)
        showingTrash = false
        selection = id
    }

    /// A new note left without writing anything isn't kept.
    private func discardIfEmpty(_ id: String?) {
        guard let n = store.note(id), n.deleted == nil, n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.deleteNow(n.id)
    }

    private var syncStatus: String {
        let peers = store.peers()
        if !peers.isEmpty { return "Synced with " + peers.map(\.name).formatted(.list(type: .and)) }
        if let away = model.pairedDevices.first(where: NotesStore.syncs) { return "Syncs when \(away.name) connects" }
        // The phone's app doesn't have notes yet.
        return "On this Mac only"
    }
}
