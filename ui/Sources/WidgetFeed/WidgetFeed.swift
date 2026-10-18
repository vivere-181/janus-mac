import Foundation

/// What the Notes widgets show, and how they talk back. The app writes a snapshot of the notes (ready to draw, no
/// Markdown left) into a folder the sandboxed widget extension may use; a ticked checklist item comes back as a small
/// command file in that folder's Inbox, which the app applies like any edit (so it syncs to the phone).
public enum WidgetFeed {
    public enum Kind: String, Codable, Sendable { case body, heading, bullet, number, check, quote, code, attachment, table, blank }

    public struct Line: Codable, Hashable, Sendable {
        /// The line's number in the note's text (what a tick refers to).
        public var index: Int
        public var kind: Kind
        /// Indent (tabs before the marker).
        public var level: Int
        public var text: String
        public var checked: Bool
        public var number: Int
        /// The line's text with its inline formatting, as Markdown the widget can show (bold, italic, strikethrough,
        /// code, links); nil when there's none.
        public var rich: String?
        /// 1–3 for "#", "##", "###".
        public var heading: Int?
        public init(index: Int, kind: Kind, level: Int, text: String, checked: Bool = false, number: Int = 0,
                    rich: String? = nil, heading: Int? = nil) {
            self.index = index; self.kind = kind; self.level = level; self.text = text; self.checked = checked; self.number = number
            self.rich = rich; self.heading = heading
        }
    }

    public struct Note: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var rev: String
        public var title: String
        public var pinned: Bool
        public var modified: Date
        /// The lines after the title (code fences and table rules left out; blank lines kept, they're the note's spacing).
        public var lines: [Line]
        public init(id: String, rev: String, title: String, pinned: Bool, modified: Date, lines: [Line]) {
            self.id = id; self.rev = rev; self.title = title; self.pinned = pinned; self.modified = modified; self.lines = lines
        }
    }

    public struct Snapshot: Codable, Sendable {
        /// Pinned first, then most recently changed.
        public var notes: [Note]
        /// How many notes there are (the snapshot carries only as many as a widget can show).
        public var total: Int?
        public init(notes: [Note], total: Int? = nil) { self.notes = notes; self.total = total }
    }

    /// Sets a checklist item. `text` finds the item again if the note changed after the snapshot was taken.
    public struct Command: Codable, Sendable {
        public var note: String
        public var line: Int
        public var text: String
        public var checked: Bool
        public init(note: String, line: Int, text: String, checked: Bool) {
            self.note = note; self.line = line; self.text = text; self.checked = checked
        }
    }

    public static let listKind = "JanusNotes"
    public static let noteKind = "JanusNote"

    /// The real home folder (inside the sandbox, NSHomeDirectory() is the extension's container).
    public static var home: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
    /// ~/Library/Application Support/Android/Widget (the extension's entitlements name this folder).
    public static var folder: URL { home.appendingPathComponent("Library/Application Support/Android/Widget", isDirectory: true) }
    public static var snapshotFile: URL { folder.appendingPathComponent("notes.json") }
    public static var inbox: URL { folder.appendingPathComponent("Inbox", isDirectory: true) }

    public static func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public static func encode(_ s: Snapshot) -> Data? { try? encoder.encode(s) }

    public static func write(_ data: Data) {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? data.write(to: snapshotFile, options: .atomic)
    }

    /// From the widget: the command for the app, and the snapshot changed to match so the widget redraws ticked at once.
    public static func post(_ c: Command) throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let name = String(format: "%.0f-%@.json", Date().timeIntervalSince1970 * 1000, UUID().uuidString)
        try encoder.encode(c).write(to: inbox.appendingPathComponent(name), options: .atomic)
        if var s = read(), let n = s.notes.firstIndex(where: { $0.id == c.note }),
           let l = s.notes[n].lines.firstIndex(where: { $0.index == c.line && $0.kind == .check }) {
            s.notes[n].lines[l].checked = c.checked
            if let data = encode(s) { try? data.write(to: snapshotFile, options: .atomic) }
        }
    }

    /// For the app: the commands waiting, oldest first; each file is removed as it's read.
    public static func takeCommands() -> [Command] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Command.self, from: $0) }
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .millisecondsSince1970; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }
}
