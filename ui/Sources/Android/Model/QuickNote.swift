import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Quick Note: a small floating note, opened with a keyboard shortcut from anywhere (like macOS's Quick Note).
/// It's a normal note, synced like every note.
@MainActor
enum QuickNote {
    private static var panel: NSPanel?
    private static let size = NSSize(width: 340, height: 300)
    private static var lastID: String? {
        get { UserDefaults.standard.string(forKey: "notes.quickNoteID") }
        set { UserDefaults.standard.set(newValue, forKey: "notes.quickNoteID") }
    }

    /// Opens the quick note, or puts it away if it's open (the shortcut does both).
    static func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    /// Opens `noteID`, or the last quick note, or (`new`) a new one. `focus: false` only for testing aids.
    static func show(noteID: String? = nil, new: Bool = false, focus: Bool = true) {
        let store = NotesStore.shared
        // Starting another: the current one, if nothing was written, isn't kept.
        if new { store.discardIfEmpty(lastID) }
        // Resume the last quick note, like macOS; a new one when it's gone or asked for.
        let note = store.note(noteID).flatMap { $0.deleted == nil ? $0 : nil }
            ?? (!new ? store.note(lastID).flatMap { $0.deleted == nil ? $0 : nil } : nil) ?? store.create()
        lastID = note.id
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingController(rootView: QuickNoteView(noteID: note.id))
        host.sizingOptions = []   // the panel keeps its size (and the owner's resizing)
        p.contentViewController = host
        if !p.isVisible { p.setContentSize(Self.size) }
        position(p)
        p.orderFrontRegardless()
        if focus { p.makeKey() }
    }

    static func close() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil   // the editor and its text go; made again the next time it opens
        // A quick note left empty isn't kept.
        if let n = NotesStore.shared.note(lastID), n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NotesStore.shared.discardIfEmpty(n.id)
            lastID = nil
        }
    }

    private static func makePanel() -> NSPanel {
        let p = QuickNotePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 260, height: 180)
        p.delegate = QuickNotePanel.closer
        // Only the close button, like macOS's Quick Note.
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }

    /// Where the owner last dragged it (if that's still on a screen); at first, top right under the menu bar.
    private static func position(_ p: NSPanel) {
        placing = true
        defer { placing = false }
        let saved = UserDefaults.standard.string(forKey: "notes.quickNoteFrame").map(NSRectFromString)
        if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            p.setFrame(saved, display: false)
            return
        }
        guard let screen = NSScreen.screens.first else { return }   // the one with the menu bar
        let f = screen.visibleFrame, size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 8))
    }

    /// True while the app itself places the panel (only the owner's moves are remembered).
    fileprivate static var placing = false
    fileprivate static func remember(_ p: NSWindow) {
        guard !placing, p.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: "notes.quickNoteFrame")
    }
}

/// A floating panel that takes typing without bringing the whole app forward; Esc closes it.
final class QuickNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { QuickNote.close() }

    static let closer = Closer()
    final class Closer: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { QuickNote.close() }
            return false
        }
        func windowDidMove(_ n: Notification) { MainActor.assumeIsolated { (n.object as? NSWindow).map(QuickNote.remember) } }
        func windowDidEndLiveResize(_ n: Notification) { MainActor.assumeIsolated { (n.object as? NSWindow).map(QuickNote.remember) } }
    }
}

struct QuickNoteView: View {
    let noteID: String
    private var store: NotesStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                NoteFormatMenu().labelStyle(.iconOnly).fixedSize()
                Button { NSApp.sendAction(#selector(NoteTextView.attachFile(_:)), to: nil, from: nil) } label: {
                    Image(systemName: "paperclip")
                }
                .help("Attach a file or photo")
                Button { NSApp.sendAction(#selector(NoteTextView.toggleChecklist(_:)), to: nil, from: nil) } label: {
                    Image(systemName: "checklist")
                }
                .help("Checklist (⇧⌘L)")
                Button { QuickNote.show(new: true) } label: { Image(systemName: "square.and.pencil") }
                    .help("New Quick Note")
                Button {
                    QuickNote.close()
                    AppModel.shared.section = .notes
                    AppModel.shared.wantsMainWindow = true
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Show in Notes")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)   // the title bar's line, level with the close button
            NoteEditor(text: Binding(get: { store.note(noteID)?.text ?? "" }, set: { store.setText(noteID, $0) }), noteID: noteID)
        }
        .frame(minWidth: 260, minHeight: 180)
        .ignoresSafeArea(edges: .top)
        .background(.regularMaterial)
        .tint(.janus)
    }
}

/// The Quick Note shortcut, registered with macOS's global hotkey service: no permission needed, and nothing runs until
/// the keys are pressed.
@MainActor
final class QuickNoteHotKey {
    static let shared = QuickNoteHotKey()

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
        var modifiers: UInt32
        var display: String
    }

    /// Default ⌃⌥N (free in macOS and common apps); the owner can record another or turn it off.
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥N")

    static var current: Shortcut? {
        get {
            if UserDefaults.standard.bool(forKey: "notes.shortcutOff") { return nil }
            guard let data = UserDefaults.standard.data(forKey: "notes.shortcut") else { return standard }
            return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? standard
        }
        set {
            UserDefaults.standard.set(newValue == nil, forKey: "notes.shortcutOff")
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "notes.shortcut") }
            shared.register()
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        unregister()
        guard let s = Self.current else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { QuickNote.toggle() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x414E_514E), id: 1)   // "ANQN"
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { AppModel.shared.log(.warning, "Couldn't use \(s.display) for Quick Note: another app has it") }
        if UserDefaults.standard.bool(forKey: "debugSnapshots") { debugLog("Quick Note shortcut \(s.display): \(status == noErr ? "registered" : "failed \(status)")") }
    }

    /// While recording a new shortcut (so the current one can be pressed and recorded).
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// A key press as a shortcut: needs ⌘, ⌃ or ⌥ (Shift alone would block typing).
    static func shortcut(from e: NSEvent) -> Shortcut? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .control, .option]).isEmpty else { return nil }
        var mods: UInt32 = 0, text = ""
        if f.contains(.control) { mods |= UInt32(controlKey); text += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); text += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); text += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); text += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        return Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods, display: text + key)
    }
}
