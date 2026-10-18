import AppKit
import SwiftUI

/// A note in a window of its own (from the Notes widgets), like Notes' "Open Note in New Window". Each note's window
/// comes back where it was left and at the size it was left; a note opened for the first time takes the size of the
/// last one, a little offset so it doesn't hide it.
@MainActor
enum NoteWindows {
    private static var windows: [String: NSWindow] = [:]
    private static let framesKey = "notes.windowFrames", lastKey = "notes.windowFrame"
    private static let defaultSize = NSSize(width: 480, height: 560)

    static var isAnyVisible: Bool { windows.values.contains { $0.isVisible } }

    /// Brings the note's window forward, opening it if needed.
    static func show(_ id: String) {
        guard let note = NotesStore.shared.note(id), note.deleted == nil else {
            SceneActions.showMainWindow(.notes)
            return
        }
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: NoteWindowView(noteID: id))
        host.sizingOptions = []                    // the window keeps the size it's given (and the owner's resizing)
        host.sceneBridgingOptions = [.title, .toolbars]
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.identifier = NSUserInterfaceItemIdentifier("note:" + id)
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 320, height: 240)
        w.delegate = Tracker.shared
        place(w, id)
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DockPresence.update()
    }

    static func close(_ id: String) { windows[id]?.performClose(nil) }

    // MARK: Size and place

    private static var frames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: framesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: framesKey) }
    }

    private static func onScreen(_ r: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersection(r).width >= 120 && $0.visibleFrame.intersection(r).height >= 80 }
    }

    /// Placing it ourselves isn't a move by the owner.
    private static var placing = false

    private static func place(_ w: NSWindow, _ id: String) {
        placing = true
        defer { placing = false }
        if let saved = frames[id].map(NSRectFromString), onScreen(saved) {
            w.setFrame(saved, display: false)
        } else if let last = UserDefaults.standard.string(forKey: lastKey).map(NSRectFromString), onScreen(last) {
            w.setFrame(last.offsetBy(dx: 24, dy: -24), display: false)
            if !onScreen(w.frame) { w.setFrame(last, display: false) }
        } else {
            w.setContentSize(defaultSize)
            w.center()
        }
    }

    fileprivate static func remember(_ w: NSWindow) {
        guard !placing, w.isVisible, let id = noteID(of: w) else { return }
        let frame = NSStringFromRect(w.frame)
        var all = frames
        all[id] = frame
        // Only notes that still exist keep a place.
        if all.count > 100 { all = all.filter { NotesStore.shared.note($0.key)?.deleted == nil } }
        frames = all
        UserDefaults.standard.set(frame, forKey: lastKey)
    }

    fileprivate static func closed(_ w: NSWindow) {
        guard let id = noteID(of: w) else { return }
        windows[id] = nil
        w.contentViewController = nil   // the editor and its text go with the window
        NotesStore.shared.discardIfEmpty(id)
        DispatchQueue.main.async { DockPresence.update() }
    }

    private static func noteID(of w: NSWindow) -> String? {
        guard let s = w.identifier?.rawValue, s.hasPrefix("note:") else { return nil }
        return String(s.dropFirst(5))
    }

    private final class Tracker: NSObject, NSWindowDelegate {
        static let shared = Tracker()
        func windowDidMove(_ n: Notification) { MainActor.assumeIsolated { (n.object as? NSWindow).map(NoteWindows.remember) } }
        func windowDidEndLiveResize(_ n: Notification) { MainActor.assumeIsolated { (n.object as? NSWindow).map(NoteWindows.remember) } }
        // Zoom, tiling, a size set by the system: kept too (a drag is kept once it ends).
        func windowDidResize(_ n: Notification) {
            MainActor.assumeIsolated { if let w = n.object as? NSWindow, !w.inLiveResize { NoteWindows.remember(w) } }
        }
        func windowWillClose(_ n: Notification) { MainActor.assumeIsolated { (n.object as? NSWindow).map(NoteWindows.closed) } }
    }
}

/// One note, with the editor's tools in the title bar (like a note opened in its own window in Notes).
struct NoteWindowView: View {
    let noteID: String
    private var store: NotesStore { .shared }

    var body: some View {
        Group {
            if let n = store.note(noteID), n.deleted == nil {
                NoteEditor(text: Binding(get: { store.note(noteID)?.text ?? "" }, set: { store.setText(noteID, $0) }), noteID: noteID)
                    .padding(.top, 6)
                .navigationTitle(n.title.isEmpty ? "New Note" : n.title)
                .toolbar { toolbar(n) }
            } else {
                ContentUnavailableView("Note Deleted", systemImage: "trash",
                                       description: Text("It's in Recently Deleted in Notes."))
                    .navigationTitle("Note")
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .tint(.janus)
    }

    @ToolbarContentBuilder private func toolbar(_ n: Note) -> some ToolbarContent {
        ToolbarItemGroup {
            NoteFormatMenu()
            Button { NSApp.sendAction(#selector(NoteTextView.insertTable(_:)), to: nil, from: nil) } label: {
                Label("Table", systemImage: "tablecells")
            }
            .help("Insert a table")
            Button { NSApp.sendAction(#selector(NoteTextView.attachFile(_:)), to: nil, from: nil) } label: {
                Label("Attach File", systemImage: "paperclip")
            }
            .help("Attach a file or photo (or drag one into the note)")
            Button { NSApp.sendAction(#selector(NoteTextView.toggleChecklist(_:)), to: nil, from: nil) } label: {
                Label("Checklist", systemImage: "checklist")
            }
            .help("Checklist (⇧⌘L)")
        }
        ToolbarItem {
            Menu {
                Button { store.togglePin(n.id) } label: { Label(n.pinned ? "Unpin" : "Pin", systemImage: n.pinned ? "pin.slash" : "pin") }
                Button {
                    AppModel.shared.noteToOpen = n.id
                    SceneActions.showMainWindow(.notes)
                } label: { Label("Show in Notes", systemImage: "sidebar.left") }
                Divider()
                Button(role: .destructive) {
                    store.delete(n.id)
                    NoteWindows.close(n.id)
                } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: { Label("More", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
                .help("Pin, show in Notes, delete")
        }
    }
}
