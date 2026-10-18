import Foundation
import WidgetFeed
import WidgetKit

/// Feeds the Notes widgets (WidgetFeed): a snapshot of the notes each time they're saved, and the checklist items
/// ticked in a widget applied here, so they sync like any edit. Nothing runs in between: the inbox is watched by
/// the kernel, and widgets are redrawn only when what they show changed.
@MainActor
enum NotesWidgets {
    /// Enough for the largest widget; the rest of a long note isn't shown anyway.
    private static let maxNotes = 24, maxLines = 30
    private static var last: Data?
    private static var watcher: DispatchSourceFileSystemObject?

    static func start() {
        publish(NotesStore.shared.live)
        watchInbox()
        applyCommands()
    }

    /// The notes as the widgets show them. Redraws the widgets only when that changed.
    static func publish(_ notes: [Note]) {
        let snapshot = WidgetFeed.Snapshot(notes: notes.prefix(maxNotes).map { n in
            WidgetFeed.Note(id: n.id, rev: n.rev, title: n.title, pinned: n.pinned, modified: n.modified,
                            lines: Array(lines(of: n.text).prefix(maxLines)))
        }, total: notes.count)
        guard let data = WidgetFeed.encode(snapshot), data != last else { return }
        last = data
        Task.detached(priority: .utility) {
            WidgetFeed.write(data)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The lines after the title as the note shows them: blank lines (its spacing), headings with their level, and
    /// the inline formatting of each line.
    static func lines(of text: String) -> [WidgetFeed.Line] {
        let ns = text as NSString
        var out: [WidgetFeed.Line] = []
        var blanks = 0
        for (index, l) in Markdown.lines(ns).enumerated() where !l.isTitle {
            let raw = ns.substring(with: l.range)
            let shown = String(Markdown.plain(raw).prefix(200))
            let content = ns.substring(with: NSRange(location: l.content, length: max(0, l.range.upperBound - l.content)))
            let rich = inlineMarkdown(content)
            var line: WidgetFeed.Line
            switch l.kind {
            case .fence, .tableRule: continue
            case .blank:
                // Spacing between parts, not before the first line; a run of empty lines counts as two at most.
                blanks += 1
                guard !out.isEmpty, blanks <= 2 else { continue }
                out.append(.init(index: index, kind: .blank, level: 0, text: ""))
                continue
            case .body: line = .init(index: index, kind: .body, level: 0, text: shown, rich: rich)
            case .heading(let h): line = .init(index: index, kind: .heading, level: 0, text: shown, rich: rich, heading: h)
            case .bullet: line = .init(index: index, kind: .bullet, level: l.tabs, text: shown, rich: rich)
            case .numbered(let n): line = .init(index: index, kind: .number, level: l.tabs, text: shown, number: n, rich: rich)
            case .check(let c): line = .init(index: index, kind: .check, level: l.tabs, text: shown, checked: c, rich: rich)
            case .quote: line = .init(index: index, kind: .quote, level: 0, text: shown, rich: rich)
            case .code: line = .init(index: index, kind: .code, level: 0, text: String(raw.prefix(200)))
            case .attachment(_, let label): line = .init(index: index, kind: .attachment, level: 0, text: label)
            case .tableRow: line = .init(index: index, kind: .table, level: 0, text: shown)
            }
            blanks = 0
            out.append(line)
        }
        while out.last?.kind == .blank { out.removeLast() }
        return out
    }

    /// A line's inline Markdown (R30: **bold**, *italic*, ~~strike~~, `code`, [links](…), \escapes), in the form the
    /// widget's Markdown reader takes it the same way: "_" is literal in notes, so it's escaped. Nil when plain.
    static func inlineMarkdown(_ s: String) -> String? {
        let text = String(s.trimmingCharacters(in: .whitespaces).prefix(300))
        guard text.contains(where: { "*~`[\\".contains($0) }) else { return nil }
        var out = ""
        var escaped = false
        for c in text {
            if c == "_" && !escaped { out += "\\_" } else { out.append(c) }
            escaped = c == "\\" && !escaped
        }
        return out
    }

    private static func watchInbox() {
        try? FileManager.default.createDirectory(at: WidgetFeed.inbox, withIntermediateDirectories: true)
        let fd = open(WidgetFeed.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { applyCommands() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private static func applyCommands() {
        let commands = WidgetFeed.takeCommands()
        guard !commands.isEmpty else { return }
        for c in commands { NotesStore.shared.setChecked(c.note, line: c.line, text: c.text, checked: c.checked) }
        // Straight away (the store saves a second later): the widget already shows the tick.
        publish(NotesStore.shared.live)
    }
}

extension NotesStore {
    /// Ticks or unticks a checklist item: the one on `line`, or (the note changed since) the item with that text.
    func setChecked(_ id: String, line: Int, text: String, checked: Bool) {
        guard let note = note(id), note.deleted == nil else { return }
        let ns = note.text as NSString
        let lines = Markdown.lines(ns)
        func matches(_ l: MDLine) -> Bool {
            guard case .check = l.kind else { return false }
            return Markdown.plain(ns.substring(with: l.range)) == text
        }
        guard let item = (lines.indices.contains(line) && matches(lines[line]) ? lines[line] : nil) ?? lines.first(where: matches),
              case .check(let now) = item.kind, now != checked, let marker = item.marker else { return }
        let old = ns.substring(with: marker)
        let new = checked ? old.replacingOccurrences(of: "[ ]", with: "[x]")
            : old.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        setText(id, ns.replacingCharacters(in: marker, with: new))
    }
}
