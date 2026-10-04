import AppKit
import SwiftUI

/// A note's Markdown, edited like Apple Notes (R30): syntax hidden, shown faintly only on the caret's line (like
/// Obsidian's live preview); checkboxes, bullets, quote bars and monospaced blocks drawn in place.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    let noteID: String
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The editor going away (note closed, window closed): what was typed is handed over first.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.flush() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        let text = NoteTextView(frame: tv.frame, textContainer: tv.textContainer)
        text.autoresizingMask = tv.autoresizingMask
        text.minSize = tv.minSize; text.maxSize = tv.maxSize
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.textContainerInset = NSSize(width: 28, height: 14)
        text.insertionPointColor = Janus.primary
        text.selectedTextAttributes = [.backgroundColor: Janus.primaryContainer]
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        // A file that arrived from the phone replaces its placeholder.
        let arrived = NoteAttachments.shared.version
        if arrived != context.coordinator.attachmentsVersion { context.coordinator.attachmentsVersion = arrived; tv.restyle() }
        tv.isEditable = editable
        let switched = context.coordinator.noteID != noteID
        // Text typed here but not yet handed to the store belongs to the note it was typed in.
        if switched { context.coordinator.flush() }
        // Only a change from elsewhere (another device, a command) replaces the text; what's being typed wins.
        let external = context.coordinator.pending == nil && text != context.coordinator.lastPushed
        if switched || external {
            context.coordinator.lastPushed = text
            let caret = tv.selectedRange()
            tv.string = text
            if switched {
                context.coordinator.noteID = noteID
                tv.undoManager?.removeAllActions()
                if editable { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
                tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            } else {
                tv.setSelectedRange(NSRange(location: min(caret.location, (text as NSString).length), length: 0))
            }
            tv.restyle()
            // A just-loaded note is laid out again once the view has its size (a table at the very end otherwise
            // drew no text on first display).
            DispatchQueue.main.async {
                tv.restyle()
                if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
                tv.needsDisplay = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        weak var textView: NoteTextView?
        var noteID: String?
        var attachmentsVersion = 0
        /// The text last handed to the store, and an edit waiting to be (with the binding of the note it belongs to).
        var lastPushed: String?
        var pending: (task: Task<Void, Never>, binding: Binding<String>)?
        init(_ parent: NoteEditor) { self.parent = parent }

        /// Typing reaches the store (and from there the list, the disk and the phone) once it pauses for 0.3 s.
        func textDidChange(_ notification: Notification) {
            pending?.task.cancel()
            let binding = parent.$text
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
            pending = (task, pending?.binding ?? binding)
        }

        func flush() {
            guard let p = pending, let tv = textView else { pending = nil; return }
            p.task.cancel()
            pending = nil
            let text = tv.string
            lastPushed = text
            if p.binding.wrappedValue != text { p.binding.wrappedValue = text }
        }

        func textDidEndEditing(_ notification: Notification) { flush() }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.caretMoved()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

// MARK: Markdown lines

/// One line of a note, as R30 reads it.
struct MDLine {
    enum Kind: Equatable { case body, heading(Int), bullet, numbered(Int), check(Bool), quote, code, fence, blank, attachment(String, String), tableRow, tableRule }
    var range: NSRange          // without the line break
    var kind: Kind
    var tabs: Int
    /// The block marker after the tabs ("- ", "12. ", "- [ ] ", "> ", "## "), if any.
    var marker: NSRange?
    var isTitle = false
    var content: Int { marker.map { $0.upperBound } ?? range.location + tabs }
    var isList: Bool {
        switch kind { case .bullet, .numbered, .check: true; default: false }
    }
}

enum Markdown {
    /// Patterns are compiled once (they ran on every line of every keystroke before).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    static func re(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = cache[pattern] { return r }
        let r = try! NSRegularExpression(pattern: pattern)
        cache[pattern] = r
        return r
    }
    /// The first match of a pattern in a string, as a String range.
    static func match(_ pattern: String, _ s: String) -> Range<String.Index>? {
        re(pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).flatMap { Range($0.range, in: s) }
    }
    static func replacing(_ pattern: String, in s: String, with template: String) -> String {
        re(pattern).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func lines(_ s: NSString) -> [MDLine] {
        var out: [MDLine] = []
        var inCode = false
        var titleFound = false
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            let line = s.substring(with: r) as NSString
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                out.append(MDLine(range: r, kind: .fence, tabs: 0))
                return
            }
            if inCode { out.append(MDLine(range: r, kind: .code, tabs: 0)); return }
            var tabs = 0
            while tabs < line.length, line.character(at: tabs) == 9 { tabs += 1 }
            let rest = line.substring(from: tabs)
            var l = MDLine(range: r, kind: .body, tabs: tabs)
            func marker(_ n: Int) -> NSRange { NSRange(location: r.location + tabs, length: n) }
            // Only lines starting with a marker character can be anything but body text (most lines skip the patterns).
            let first = rest.first
            if trimmed.isEmpty {
                l.kind = .blank
            } else if first == "!", tabs == 0, let m = match(#"^!\[((?:\\.|[^\]])*)\]\(attachments/([0-9a-f]{64}\.[a-z0-9]{1,8})\)$"#, rest) {
                let whole = String(rest[m])
                let name = String(whole[match(#"[0-9a-f]{64}\.[a-z0-9]{1,8}"#, whole)!])
                let label = replacing(#"^!\[|\]\(attachments/.*$"#, in: whole, with: "")
                l.kind = .attachment(name, Markdown.unescape(label))
            } else if first == "-" || first == "*" || first == "+" {
                if let m = match(#"^[-*+] \[( |x|X)\] "#, rest) {
                    let n = rest.distance(from: rest.startIndex, to: m.upperBound)
                    l.kind = .check(rest[m].contains("x") || rest[m].contains("X")); l.marker = marker(n)
                } else if let m = match(#"^[-*+] "#, rest) {
                    l.kind = .bullet; l.marker = marker(rest.distance(from: rest.startIndex, to: m.upperBound))
                }
            } else if first?.isNumber == true, let m = match(#"^\d{1,9}[.)] "#, rest) {
                l.kind = .numbered(Int(rest[m].prefix { $0.isNumber }) ?? 1)
                l.marker = marker(rest.distance(from: rest.startIndex, to: m.upperBound))
            } else if first == ">", let m = match(#"^> ?"#, rest) {
                l.kind = .quote; l.marker = marker(rest.distance(from: rest.startIndex, to: m.upperBound))
            } else if first == "#", let m = match(#"^#{1,6} "#, rest) {
                let n = rest.distance(from: rest.startIndex, to: m.upperBound)
                l.kind = .heading(min(n - 1, 3)); l.marker = marker(n)
            }
            if tabs == 0, trimmed.hasPrefix("|") {
                l.kind = match(#"^\|(\s*:?-{3,}:?\s*\|)+\s*$"#, trimmed) != nil ? .tableRule : .tableRow
                l.marker = nil
            }
            if !titleFound, l.kind != .blank {
                titleFound = true
                l.isTitle = true
            }
            out.append(l)
        }
        // Only real tables (first row, then a rule line); other "|" lines are text.
        var i = 0
        while i < out.count {
            guard out[i].kind == .tableRow || out[i].kind == .tableRule else { i += 1; continue }
            var j = i
            while j + 1 < out.count, out[j + 1].kind == .tableRow || out[j + 1].kind == .tableRule { j += 1 }
            if !(j > i && out[i].kind == .tableRow && out[i + 1].kind == .tableRule) {
                for k in i...j { out[k].kind = .body }
            }
            i = j + 1
        }
        return out
    }

    /// The cells of a table row: ranges between unescaped pipes (absolute), from the row's line range.
    static func cells(_ s: NSString, _ row: NSRange) -> [NSRange] {
        var pipes: [Int] = []
        var k = row.location
        while k < row.upperBound {
            let c = s.character(at: k)
            if c == 92 { k += 2; continue }        // a backslash escapes the next character
            if c == 124 { pipes.append(k) }
            k += 1
        }
        guard pipes.count >= 2 else { return [] }
        return zip(pipes, pipes.dropFirst()).map { NSRange(location: $0 + 1, length: $1 - $0 - 1) }
    }

    /// A line as plain text for titles, previews and search (R30: markers stripped, escapes resolved).
    static func plain(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("```") { return "" }
        if s.hasPrefix("!["), let r = match(#"^!\[((?:\\.|[^\]])*)\]\(attachments/[^)]+\)$"#, s) {
            let name = replacing(#"^!\[|\]\(.*$"#, in: String(s[r]), with: "")
            return "📎 " + unescape(name)
        }
        if let f = s.first, "-*+>#".contains(f) || f.isNumber {
            for p in [#"^[-*+] \[[ xX]\] "#, #"^[-*+] "#, #"^\d{1,9}[.)] "#, #"^> ?"#, #"^#{1,6} "#] {
                if let r = match(p, s) { s.removeSubrange(r); break }
            }
        }
        if s.hasPrefix("|") {   // a table row: its cells
            let cells = replacing(#"(?<!\\)\|"#, in: s, with: "\u{1F}").split(separator: "\u{1F}")
            return cells.map { unescape($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty && !$0.allSatisfy { "-: ".contains($0) } }.joined(separator: " · ")
        }
        if s.contains("](") { s = replacing(#"\[([^\]]*)\]\((?:<[^>]*>|[^)]*)\)"#, in: s, with: "$1") }
        for m in ["**", "~~", "`"] where s.contains(m) { s = s.replacingOccurrences(of: m, with: "") }
        if s.contains("*") { s = replacing(#"(?<![\\\w])\*(?=\S)(.+?)(?<=\S)\*"#, in: s, with: "$1") }
        return unescape(s)
    }

    static func unescape(_ s: String) -> String {
        s.contains("\\") ? replacing(#"\\([\\`*_{}\[\]()#+\-.!|>~])"#, in: s, with: "$1") : s
    }
}

// MARK: Text view

final class NoteTextView: NSTextView {
    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    static let headingFont = NSFont.systemFont(ofSize: 18, weight: .bold)
    static let subheadingFont = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    static let indentStep: CGFloat = 22

    private(set) var parsed: [MDLine] = []

    /// The edit about to happen: where, and whether it can change other lines' styling (code fences, tables, the
    /// title line) and so needs a full restyle.
    private var pendingEdit: (range: NSRange, structural: Bool)?

    override func shouldChangeText(in range: NSRange, replacementString text: String?) -> Bool {
        guard super.shouldChangeText(in: range, replacementString: text) else { return false }
        let s = string as NSString
        let removed = range.length > 0 && range.upperBound <= s.length ? s.substring(with: range) : ""
        let touched = removed + (text ?? "")
        let titleEnd = parsed.first(where: \.isTitle)?.range.upperBound ?? 0
        let structural = pendingEdit != nil || touched.contains("`") || touched.contains("|") || range.location <= titleEnd
        pendingEdit = (NSRange(location: range.location, length: (text.map { ($0 as NSString).length } ?? 0)), structural)
        return true
    }

    /// Every change (typing, commands, undo) restyles what it touched, so the parsed lines always match the text.
    override func didChangeText() {
        if let edit = pendingEdit, !edit.structural {
            let fresh = Markdown.lines(string as NSString)
            let lo = max(0, edit.range.location - 1), hi = edit.range.upperBound + 1
            var targets = Set(fresh.indices.filter { fresh[$0].range.upperBound >= lo && fresh[$0].range.location <= hi })
            if revealedLine >= 0 { targets.insert(min(revealedLine, fresh.count - 1)) }
            restyle(lines: targets)
        } else {
            restyle()
        }
        pendingEdit = nil
        super.didChangeText()
    }
    private var revealedLine = -1

    /// The line containing (or ending at) a location: a binary search over the parsed lines.
    private func lineIndex(at location: Int) -> Int? {
        var lo = 0, hi = parsed.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = parsed[mid].range
            if location < r.location { hi = mid - 1 }
            else if location > r.upperBound { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// The caret's line shows its syntax: when it moves to another line, those two lines restyle (and the fences of a
    /// code block it enters or leaves).
    func caretMoved() {
        let i = lineIndex(at: selectedRange().location) ?? -1
        guard i != revealedLine else { return }
        var targets: Set<Int> = [i, revealedLine]
        for line in [i, revealedLine] where line >= 0 && line < parsed.count && [.code, .fence].contains(parsed[line].kind) {
            targets.formUnion(codeBlock(around: line))
        }
        restyle(lines: targets)
    }

    // MARK: Styling

    /// Restyles everything (a note loaded, the width changed, or an edit that changes structure: code fences, tables,
    /// the title). Typing otherwise restyles only the lines it touched (`restyle(lines:)`).
    func restyle() {
        guard let storage = textStorage else { return }
        styledWidth = contentWidth
        let s = string as NSString
        parsed = Markdown.lines(s)
        let caretLine = lineIndex(at: selectedRange().location) ?? -1
        revealedLine = caretLine
        let caretBlock = caretCodeBlock(caretLine)
        storage.beginEditing()
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: all)
        for (i, l) in parsed.enumerated() {
            styleLine(i, l, reveal: i == caretLine, caretBlock: caretBlock, storage: storage, s: s)
        }
        layoutTables(in: storage, s: s)
        storage.endEditing()
        finishStyling(caretLine: caretLine)
    }

    /// Restyles only the given lines (by index in a fresh parse). Lines in a table restyle the whole note (columns
    /// depend on every row).
    func restyle(lines targets: Set<Int>) {
        guard let storage = textStorage else { return }
        let s = string as NSString
        parsed = Markdown.lines(s)
        let valid = targets.filter { $0 >= 0 && $0 < parsed.count }
        if valid.contains(where: { [.tableRow, .tableRule].contains(parsed[$0].kind) }) { restyle(); return }
        let caretLine = lineIndex(at: selectedRange().location) ?? -1
        revealedLine = caretLine
        let caretBlock = caretCodeBlock(caretLine)
        storage.beginEditing()
        for i in valid.sorted() {
            let l = parsed[i]
            let lineWithBreak = NSRange(location: l.range.location, length: min(l.range.length + 1, s.length - l.range.location))
            storage.setAttributes(baseAttributes, range: lineWithBreak)
            styleLine(i, l, reveal: i == caretLine, caretBlock: caretBlock, storage: storage, s: s)
        }
        storage.endEditing()
        finishStyling(caretLine: caretLine)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(0, 0)]
    }

    /// The code block the caret is in shows its fences.
    private func caretCodeBlock(_ caretLine: Int) -> ClosedRange<Int>? {
        guard caretLine >= 0, caretLine < parsed.count, [.code, .fence].contains(parsed[caretLine].kind) else { return nil }
        return codeBlock(around: caretLine)
    }

    /// One line's styling (on top of the base attributes).
    private func styleLine(_ i: Int, _ l: MDLine, reveal: Bool, caretBlock: ClosedRange<Int>?, storage: NSTextStorage, s: NSString) {
        let lineWithBreak = NSRange(location: l.range.location, length: min(l.range.length + 1, s.length - l.range.location))
        switch l.kind {
        case .fence:
            if caretBlock?.contains(i) == true {
                storage.addAttributes([.font: Self.codeFont, .foregroundColor: NSColor.tertiaryLabelColor], range: l.range)
            } else {
                hide(lineWithBreak, in: storage)   // collapses the line
            }
            return
        case .code:
            storage.addAttribute(.font, value: Self.codeFont, range: lineWithBreak)
            storage.addAttribute(.paragraphStyle, value: paragraph(10, 10), range: lineWithBreak)
            return
        default: break
        }
        // Indentation: each tab is one step (tab stops every 22 pt); wrapped lines align with the text.
        let markerWidth: CGFloat = l.marker.map { width(s.substring(with: $0), Self.bodyFont) } ?? 0
        let indent = CGFloat(l.tabs) * Self.indentStep
        if l.tabs > 0 || l.isList || l.kind == .quote {
            // The tabs themselves move the first line in; wrapped lines are indented to match.
            storage.addAttribute(.paragraphStyle, value: paragraph(0, indent + markerWidth + (l.kind == .quote ? 8 : 0)), range: lineWithBreak)
        }
        switch l.kind {
        case .heading(let level):
            let font = l.isTitle || level == 1 ? Self.titleFont : level == 2 ? Self.headingFont : Self.subheadingFont
            storage.addAttribute(.font, value: font, range: l.range)
            if let m = l.marker { reveal ? faint(m, in: storage) : hide(m, in: storage) }
        case .check(let checked):
            if let m = l.marker {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: m)   // the box is drawn here
                if checked {
                    let rest = NSRange(location: m.upperBound, length: l.range.upperBound - m.upperBound)
                    storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                           .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
                    // "x" is wider than " ": narrow it so ticked and unticked items line up.
                    storage.addAttribute(.kern, value: width(" ", Self.bodyFont) - width("x", Self.bodyFont),
                                         range: NSRange(location: m.location + 3, length: 1))
                }
            }
        case .bullet:
            if let m = l.marker { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: m.location, length: 1)) }
        case .numbered:
            if let m = l.marker { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m) }
        case .quote:
            if let m = l.marker { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: m) }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                 range: NSRange(location: l.content, length: l.range.upperBound - l.content))
        case .body where l.isTitle:
            storage.addAttribute(.font, value: Self.titleFont, range: l.range)
        case .tableRule:
            hide(lineWithBreak, in: storage)   // collapses the line, with no spacing of its own
            let flat = NSMutableParagraphStyle(); flat.maximumLineHeight = 0.01; flat.paragraphSpacing = 0
            storage.addAttribute(.paragraphStyle, value: flat, range: lineWithBreak)
            return
        case .tableRow:
            return   // laid out per table below
        case .attachment(let name, _):
            // The line's text is hidden; the file is drawn in its place, as tall as the line is made.
            hide(lineWithBreak, in: storage)
            let h = AttachmentArt.height(name, width: contentWidth)
            let p = NSMutableParagraphStyle(); p.minimumLineHeight = h; p.maximumLineHeight = h; p.paragraphSpacing = 8
            storage.addAttribute(.paragraphStyle, value: p, range: lineWithBreak)
            return
        default: break
        }
        styleInline(l, reveal: reveal, in: storage, s: s)
        }

    /// New text takes the style of where it's typed.
    private func finishStyling(caretLine: Int) {
        var typing: [NSAttributedString.Key: Any] = baseAttributes
        if caretLine >= 0, caretLine < parsed.count {
            let l = parsed[caretLine]
            if l.isTitle || l.kind == .heading(1) { typing[.font] = Self.titleFont }
            else if l.kind == .heading(2) { typing[.font] = Self.headingFont }
            else if l.kind == .heading(3) { typing[.font] = Self.subheadingFont }
            else if l.kind == .code { typing[.font] = Self.codeFont }
        }
        typingAttributes = typing
        needsDisplay = true
    }

    /// Bold, italic, strikethrough, inline code, links and escapes within a line.
    private func styleInline(_ l: MDLine, reveal: Bool, in storage: NSTextStorage, s: NSString) {
        let start = l.content
        let range = NSRange(location: start, length: l.range.upperBound - start)
        guard range.length > 0 else { return }
        let text = s.substring(with: range)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + start, length: r.length) }
        func markers(_ m: NSTextCheckingResult, inner: Int) -> [NSRange] {
            let whole = m.range, body = m.range(at: inner)
            return [NSRange(location: whole.location, length: body.location - whole.location),
                    NSRange(location: body.upperBound, length: whole.upperBound - body.upperBound)].map(abs)
        }
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            let re = Markdown.re(pattern)
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { m, _, _ in if let m { body(m) } }
        }
        var codeSpans: [NSRange] = []
        each(#"(?<!\\)`([^`]+)`"#) { m in
            storage.addAttributes([.font: Self.codeFont, .backgroundColor: NSColor.quaternaryLabelColor], range: abs(m.range(at: 1)))
            markers(m, inner: 1).forEach { reveal ? faint($0, in: storage) : hide($0, in: storage) }
            codeSpans.append(abs(m.range))
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeSpans.contains { NSIntersectionRange($0, abs(r)).length > 0 } }
        each(#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { m in
            guard outsideCode(m.range) else { return }
            addTrait(.boldFontMask, abs(m.range(at: 1)), storage)
            markers(m, inner: 1).forEach { reveal ? faint($0, in: storage) : hide($0, in: storage) }
        }
        each(#"(?<![\\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)|(?<![\\\w])_(?=\S)(.+?)(?<=\S)_(?!\w)"#) { m in
            guard outsideCode(m.range) else { return }
            let inner = m.range(at: 1).location != NSNotFound ? 1 : 2
            addTrait(.italicFontMask, abs(m.range(at: inner)), storage)
            markers(m, inner: inner).forEach { reveal ? faint($0, in: storage) : hide($0, in: storage) }
        }
        each(#"(?<!\\)~~(?=\S)(.+?)(?<=\S)~~"#) { m in
            guard outsideCode(m.range) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: abs(m.range(at: 1)))
            markers(m, inner: 1).forEach { reveal ? faint($0, in: storage) : hide($0, in: storage) }
        }
        each(#"(?<![\\!])\[((?:\\.|[^\]])+)\]\((<[^>]+>|[^)\s]+)\)"#) { m in
            guard outsideCode(m.range) else { return }
            let target = (text as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if let url = URL(string: target) ?? URL(string: target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
                storage.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: abs(m.range(at: 1)))
            }
            markers(m, inner: 1).forEach { reveal ? faint($0, in: storage) : hide($0, in: storage) }
        }
        each(#"(?<![(<\w])https?://[^\s<>()]+[^\s<>().,;:!?'"]"#) { m in
            guard outsideCode(m.range), let url = URL(string: (text as NSString).substring(with: m.range)) else { return }
            storage.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: abs(m.range))
        }
        each(#"\\([\\`*_{}\[\]()#+\-.!|>~])"#) { m in
            guard outsideCode(m.range) else { return }
            let slash = abs(NSRange(location: m.range.location, length: 1))
            reveal ? faint(slash, in: storage) : hide(slash, in: storage)
        }
    }

    // MARK: Tables

    struct TableLayout { var rows: [MDLine]; var edges: [CGFloat] }   // edges: column borders, from the text's left
    private(set) var tables: [TableLayout] = []

    /// Each table's columns as wide as their widest cell: pipes hidden, and the space before each pipe stretched
    /// (kerning) so cells line up; the grid is drawn behind.
    private func layoutTables(in storage: NSTextStorage, s: NSString) {
        tables = []
        var i = 0
        while i < parsed.count {
            guard parsed[i].kind == .tableRow else { i += 1; continue }
            var rows: [MDLine] = []
            var j = i
            while j < parsed.count, parsed[j].kind == .tableRow || parsed[j].kind == .tableRule {
                if parsed[j].kind == .tableRow { rows.append(parsed[j]) }
                j += 1
            }
            i = j
            let pad: CGFloat = 10, pipe = width("|", Self.bodyFont)
            let cellsPerRow = rows.map { Markdown.cells(s, $0.range) }
            let columns = cellsPerRow.map(\.count).max() ?? 0
            guard columns > 0 else { continue }
            // Pass 1: style each cell (spaces take no room, inline markup hidden) and measure it as shown.
            var textRanges: [[NSRange]] = []
            var widths = [CGFloat](repeating: 44, count: columns)
            for (row, cells) in zip(rows, cellsPerRow) {
                let line = NSRange(location: row.range.location, length: min(row.range.length + 1, s.length - row.range.location))
                let p = NSMutableParagraphStyle(); p.paragraphSpacingBefore = 5; p.paragraphSpacing = 5
                p.tabStops = []; p.defaultTabInterval = 0.01   // a stray tab in a cell takes no room
                storage.addAttribute(.paragraphStyle, value: p, range: line)
                var rowTexts: [NSRange] = []
                for (c, r) in cells.enumerated() {
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: r.location - 1, length: 1))
                    let cell = s.substring(with: r) as NSString
                    let lead = Markdown.re(#"^\s*"#).firstMatch(in: cell as String, range: NSRange(location: 0, length: cell.length))?.range.length ?? 0
                    let trail = lead == r.length ? 0 : Markdown.re(#"\s*$"#).firstMatch(in: cell as String, range: NSRange(location: 0, length: cell.length))?.range.length ?? 0
                    if lead > 0 { hide(NSRange(location: r.location, length: lead), in: storage) }
                    if trail > 0 { hide(NSRange(location: r.upperBound - trail, length: trail), in: storage) }
                    let textRange = NSRange(location: r.location + lead, length: max(0, r.length - lead - trail))
                    styleInline(MDLine(range: textRange, kind: .body, tabs: 0), reveal: false, in: storage, s: s)
                    widths[c] = max(widths[c], min(260, shownWidth(textRange, storage) + 2 * pad))
                    rowTexts.append(textRange)
                }
                if let last = cells.last {
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: last.upperBound, length: 1))
                }
                textRanges.append(rowTexts)
            }
            var edges: [CGFloat] = [0]
            for w in widths { edges.append(edges.last! + pipe + w) }
            // Pass 2: the pipe before each cell carries its left padding; the end of its text is stretched so the
            // next pipe lands on the column's right edge.
            for (cells, texts) in zip(cellsPerRow, textRanges) {
                for (c, r) in cells.enumerated() {
                    let pipeBefore = NSRange(location: r.location - 1, length: 1)
                    storage.addAttribute(.kern, value: pad, range: pipeBefore)
                    let text = texts[c]
                    let room = max(0, (edges[c + 1] - edges[c]) - pipe - pad - shownWidth(text, storage))
                    let stretchAt = text.length > 0 ? NSRange(location: text.upperBound - 1, length: 1) : pipeBefore
                    let existing = (storage.attribute(.kern, at: stretchAt.location, effectiveRange: nil) as? CGFloat) ?? 0
                    storage.addAttribute(.kern, value: existing + room, range: stretchAt)
                }
            }
            tables.append(TableLayout(rows: rows, edges: edges))
        }
    }

    /// Width of text as it's currently styled (hidden markers take none).
    private func shownWidth(_ r: NSRange, _ storage: NSTextStorage) -> CGFloat {
        guard r.length > 0 else { return 0 }
        let a = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
        a.removeAttribute(.kern, range: NSRange(location: 0, length: a.length))
        return ceil(a.size().width)
    }

    private func table(at location: Int) -> (table: TableLayout, row: Int, cell: Int, cells: [NSRange])? {
        let s = string as NSString
        for t in tables {
            for (ri, row) in t.rows.enumerated() where NSLocationInRange(location, row.range) || row.range.upperBound == location {
                let cells = Markdown.cells(s, row.range)
                guard !cells.isEmpty else { return nil }
                let ci = cells.firstIndex { location >= $0.location && location <= $0.upperBound } ?? (location <= cells[0].location ? 0 : cells.count - 1)
                return (t, ri, ci, cells)
            }
        }
        return nil
    }

    /// The caret into a cell: at the end of its text (after the one space that follows the pipe).
    private func caret(in cell: NSRange) -> NSRange {
        let s = string as NSString
        var k = cell.location
        if k < cell.upperBound, s.character(at: k) == 32 { k += 1 }
        let text = s.substring(with: NSRange(location: k, length: cell.upperBound - k)).trimmingCharacters(in: .whitespaces)
        return NSRange(location: k + (text as NSString).length, length: 0)
    }

    /// The table as cells (text, trimmed) and its range in the note.
    private func tableModel(_ t: TableLayout) -> (cells: [[String]], range: NSRange) {
        let s = string as NSString
        let rows = t.rows.map { r in Markdown.cells(s, r.range).map { s.substring(with: $0).trimmingCharacters(in: .whitespaces) } }
        let start = t.rows.first!.range.location, end = t.rows.last!.range.upperBound
        return (rows, NSRange(location: start, length: end - start))
    }

    static func render(_ cells: [[String]]) -> String {
        let cols = max(1, cells.map(\.count).max() ?? 1)
        func line(_ row: [String]) -> String {
            "| " + (0..<cols).map { $0 < row.count ? row[$0] : "" }.joined(separator: " | ") + " |"
        }
        var out = [line(cells.first ?? [])]
        out.append("|" + String(repeating: " --- |", count: cols))
        out += cells.dropFirst().map(line)
        return out.joined(separator: "\n")
    }

    /// Rewrites the table and puts the caret in cell (row, col).
    private func rewrite(_ t: TableLayout, _ cells: [[String]], caretAt: (Int, Int)?) {
        let model = tableModel(t)
        // A removed table takes its line break with it.
        var range = model.range
        if cells.isEmpty, range.upperBound < (string as NSString).length { range.length += 1 }
        replace(range, with: cells.isEmpty ? "" : Self.render(cells))
        guard let (r, c) = caretAt, !cells.isEmpty else { return }
        let s = string as NSString
        var lineStart = model.range.location
        for _ in 0..<(r == 0 ? 0 : r + 1) { lineStart = NSMaxRange(s.lineRange(for: NSRange(location: lineStart, length: 0))) }
        let row = s.lineRange(for: NSRange(location: lineStart, length: 0))
        let rowNoBreak = NSRange(location: row.location, length: row.length - (s.substring(with: row).hasSuffix("\n") ? 1 : 0))
        let cs = Markdown.cells(s, rowNoBreak)
        if c < cs.count { setSelectedRange(caret(in: cs[c])) }
    }

    @objc func insertTable(_ sender: Any?) {
        guard isEditable else { return }
        let s = string as NSString
        var loc = selectedRange().location
        if let l = currentLine(), l.range.length > 0 { loc = l.range.upperBound }
        var text = Self.render([["", ""], ["", ""]])
        if loc > 0, s.character(at: loc - 1) != 10 { text = "\n" + text }
        if loc >= s.length { text += "\n" }
        insertText(text, replacementRange: NSRange(location: loc, length: 0))
        if let t = table(at: loc + (text.hasPrefix("\n") ? 1 : 0)) { setSelectedRange(caret(in: t.cells[0])) }
    }

    @objc func tableAddRowBelow(_ sender: Any?) { editTable { c, r, _ in c.insert(Array(repeating: "", count: c[0].count), at: r + 1); return (r + 1, 0) } }
    @objc func tableAddRowAbove(_ sender: Any?) { editTable { c, r, _ in c.insert(Array(repeating: "", count: c[0].count), at: r); return (r, 0) } }
    @objc func tableAddColumnAfter(_ sender: Any?) { editTable { c, r, col in for i in c.indices { c[i].insert("", at: min(col + 1, c[i].count)) }; return (r, col + 1) } }
    @objc func tableAddColumnBefore(_ sender: Any?) { editTable { c, r, col in for i in c.indices { c[i].insert("", at: min(col, c[i].count)) }; return (r, col) } }
    @objc func tableDeleteRow(_ sender: Any?) { editTable { c, r, col in c.remove(at: r); return c.isEmpty ? nil : (min(r, c.count - 1), col) } }
    @objc func tableDeleteColumn(_ sender: Any?) {
        editTable { c, r, col in
            for i in c.indices where col < c[i].count { c[i].remove(at: col) }
            if c.allSatisfy(\.isEmpty) { c = [] }
            return c.isEmpty ? nil : (r, max(0, col - 1))
        }
    }
    @objc func tableDelete(_ sender: Any?) { editTable { c, _, _ in c = []; return nil } }

    private func editTable(_ change: (inout [[String]], Int, Int) -> (Int, Int)?) {
        guard isEditable, let at = table(at: selectedRange().location) else { return }
        var cells = tableModel(at.table).cells
        let target = change(&cells, at.row, at.cell)
        rewrite(at.table, cells, caretAt: target)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard isEditable, table(at: i) != nil else { return menu }
        setSelectedRange(NSRange(location: i, length: 0))
        let groups: [[(String, Selector)]] = [
            [("Add Row Above", #selector(tableAddRowAbove)), ("Add Row Below", #selector(tableAddRowBelow)),
             ("Add Column Before", #selector(tableAddColumnBefore)), ("Add Column After", #selector(tableAddColumnAfter))],
            [("Delete Row", #selector(tableDeleteRow)), ("Delete Column", #selector(tableDeleteColumn)), ("Delete Table", #selector(tableDelete))]]
        var index = 0
        for group in groups {
            for (title, action) in group {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: index); index += 1
            }
            menu.insertItem(.separator(), at: index); index += 1
        }
        return menu
    }

    private func addTrait(_ trait: NSFontTraitMask, _ r: NSRange, _ storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = (v as? NSFont) ?? Self.bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
        }
    }

    private func hide(_ r: NSRange, in storage: NSTextStorage) {
        guard r.length > 0 else { return }
        storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: r)
    }

    private func faint(_ r: NSRange, in storage: NSTextStorage) {
        guard r.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
    }

    private func paragraph(_ first: CGFloat, _ head: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2; p.paragraphSpacing = 4
        p.tabStops = []; p.defaultTabInterval = Self.indentStep
        p.firstLineHeadIndent = first; p.headIndent = head
        return p
    }

    private func width(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

    private func codeBlock(around i: Int) -> ClosedRange<Int> {
        var a = i, b = i
        if parsed[i].kind == .fence {
            // Opening or closing fence: count fences before it.
            let before = parsed[..<i].filter { $0.kind == .fence }.count
            if before % 2 == 0 { while b + 1 < parsed.count, parsed[b + 1].kind != .fence { b += 1 }; if b + 1 < parsed.count { b += 1 } }
            else { while a - 1 >= 0, parsed[a - 1].kind != .fence { a -= 1 }; if a - 1 >= 0 { a -= 1 } }
            return a...b
        }
        while a - 1 >= 0, parsed[a - 1].kind == .code { a -= 1 }
        while b + 1 < parsed.count, parsed[b + 1].kind == .code { b += 1 }
        return max(0, a - 1)...min(parsed.count - 1, b + 1)
    }

    // MARK: Drawing (boxes, bullets, quote bars, code blocks)

    private func rect(_ r: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, r.length > 0 else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// The whole line as laid out (its full height, including what an attachment reserves), across the text width.
    private func lineRect(_ l: MDLine) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let len = (string as NSString).length
        guard len > 0, l.range.location < len || l.range.location == len else { return nil }
        let first = lm.glyphIndexForCharacter(at: min(l.range.location, max(0, len - 1)))
        let last = lm.glyphIndexForCharacter(at: min(max(l.range.location, l.range.upperBound - 1), max(0, len - 1)))
        var rect = lm.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
        if last != first { rect = rect.union(lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)) }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = textContainerOrigin.x; rect.size.width = tc.size.width
        return rect
    }

    private func boxRect(_ l: MDLine) -> NSRect? {
        guard let m = l.marker, let r = rect(NSRange(location: m.location, length: min(5, m.length))) else { return nil }
        let d = min(r.height * 0.85, 17)
        return NSRect(x: r.minX + 1, y: r.midY - d / 2, width: d, height: d)
    }

    override func drawBackground(in dirty: NSRect) {
        super.drawBackground(in: dirty)
        // Only the lines in the area being drawn (a caret blink redraws a few points, not the whole note).
        let visible = lineIndices(in: dirty)
        guard !visible.isEmpty else { return }
        // Monospaced blocks: one rounded background per block.
        var i = visible.lowerBound
        while i < visible.upperBound {
            if parsed[i].kind == .code || (parsed[i].kind == .fence && (i + 1 < parsed.count && parsed[i + 1].kind == .code)) {
                let block = codeBlock(around: parsed[i].kind == .fence ? min(i + 1, parsed.count - 1) : i)
                let rects = block.compactMap { j in parsed[j].kind == .code ? lineRect(parsed[j]) : nil }
                if var u = rects.first {
                    rects.dropFirst().forEach { u = u.union($0) }
                    let bg = NSBezierPath(roundedRect: u.insetBy(dx: 0, dy: -5), xRadius: 7, yRadius: 7)
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill(); bg.fill()
                    NSColor.separatorColor.setStroke(); bg.lineWidth = 0.5; bg.stroke()
                }
                i = block.upperBound + 1
                continue
            }
            i += 1
        }
        // Table grids.
        let x0 = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        let visibleChars = NSRange(location: parsed[visible.lowerBound].range.location,
                                   length: parsed[visible.upperBound - 1].range.upperBound - parsed[visible.lowerBound].range.location)
        for t in tables where t.rows.contains(where: { NSIntersectionRange($0.range, visibleChars).length > 0 || NSLocationInRange($0.range.location, visibleChars) }) {
            let rects = t.rows.compactMap(lineRect)
            // A table that ends the note has no spacing after its last row: give it the same room.
            let endsNote = (t.rows.last?.range.upperBound ?? 0) >= (string as NSString).length
            guard let top = rects.first?.minY, let last = rects.last?.maxY, let right = t.edges.last,
                  case let bottom = last + (endsNote ? 5 : 0),
                  dirty.intersects(NSRect(x: x0, y: top, width: right, height: bottom - top)) else { continue }
            let grid = NSBezierPath()
            for r in rects.dropFirst() { grid.move(to: NSPoint(x: x0, y: r.minY)); grid.line(to: NSPoint(x: x0 + right, y: r.minY)) }
            for e in t.edges.dropFirst().dropLast() { grid.move(to: NSPoint(x: x0 + e, y: top)); grid.line(to: NSPoint(x: x0 + e, y: bottom)) }
            NSColor.separatorColor.setStroke(); grid.lineWidth = 1; grid.stroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: x0, y: top, width: right, height: bottom - top), xRadius: 6, yRadius: 6)
            frame.lineWidth = 1; frame.stroke()
        }
        for l in parsed[visible] {
            switch l.kind {
            case .attachment(let name, let label):
                guard let line = lineRect(l), line.intersects(dirty) else { continue }
                let h = AttachmentArt.height(name, width: contentWidth)
                let frame = NSRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5), y: line.minY,
                                   width: contentWidth, height: h)
                let selected = NSIntersectionRange(selectedRange(), l.range).length > 0
                AttachmentArt.draw(name, label: label, in: frame, selected: selected)
            case .check(let checked):
                guard let box = boxRect(l), box.intersects(dirty) else { continue }
                if checked {
                    Janus.primary.setFill()
                    NSBezierPath(ovalIn: box).fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: box.minX + box.width * 0.28, y: box.midY))
                    tick.line(to: NSPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.68))
                    tick.line(to: NSPoint(x: box.minX + box.width * 0.73, y: box.minY + box.height * 0.32))
                    tick.lineWidth = max(1.4, box.width * 0.11); tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                    Janus.onPrimary.setStroke(); tick.stroke()
                } else {
                    let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.3
                    NSColor.tertiaryLabelColor.setStroke(); ring.stroke()
                }
            case .bullet:
                guard let m = l.marker, let r = rect(NSRange(location: m.location, length: 1)), r.intersects(dirty) else { continue }
                let d: CGFloat = l.tabs % 2 == 0 ? 5 : 4.5
                let dot = NSRect(x: r.midX - d / 2, y: r.midY - d / 2 + 0.5, width: d, height: d)
                NSColor.labelColor.setFill()
                l.tabs % 2 == 0 ? NSBezierPath(ovalIn: dot).fill() : NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6)).stroke()
            case .quote:
                guard let m = l.marker, let r = rect(NSRange(location: m.location, length: max(1, m.length))) ,
                      let line = lineRect(l), line.intersects(dirty) else { continue }
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 1, y: line.minY + 1, width: 3, height: line.height - 2), xRadius: 1.5, yRadius: 1.5).fill()
            default: continue
            }
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let l = parsed.first(where: { if case .attachment = $0.kind { return lineRect($0)?.contains(p) ?? false }; return false }),
           case .attachment(let name, _) = l.kind {
            // Click selects it (Delete removes it); double-click opens it.
            if event.clickCount >= 2, NoteAttachments.has(name) { NSWorkspace.shared.open(NoteAttachments.url(name)); return }
            window?.makeFirstResponder(self)
            setSelectedRange(l.range)
            needsDisplay = true
            return
        }
        if isEditable, let l = parsed.first(where: { if case .check = $0.kind { return boxRect($0)?.insetBy(dx: -4, dy: -4).contains(p) ?? false }; return false }),
           let m = l.marker, case .check(let checked) = l.kind {
            replace(NSRange(location: m.location + 3, length: 1), with: checked ? " " : "x")
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for l in parsed[lineIndices(in: visibleRect)] { if case .check = l.kind, let r = boxRect(l) { addCursorRect(r, cursor: .arrow) } }
    }

    /// The parsed lines inside a rectangle of the view (with one line of margin), from the layout already done.
    private func lineIndices(in rect: NSRect) -> Range<Int> {
        guard let lm = layoutManager, let tc = textContainer, !parsed.isEmpty else { return 0..<0 }
        let r = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: r, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(at: chars.location) ?? 0
        let last = lineIndex(at: min(chars.upperBound, (string as NSString).length)) ?? (parsed.count - 1)
        return max(0, first - 1)..<min(parsed.count, max(first, last) + 2)
    }

    /// Attachments are as wide as the note: measure again when the width changes.
    private var styledWidth: CGFloat = 0
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // While the window is being resized the attachments keep their size; they're measured again at the end.
        if !inLiveResize { remeasureAttachmentsIfNeeded() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        remeasureAttachmentsIfNeeded()
    }

    private func remeasureAttachmentsIfNeeded() {
        if abs(contentWidth - styledWidth) > 0.5, parsed.contains(where: { if case .attachment = $0.kind { return true }; return false }) {
            restyle()
        }
    }

    var contentWidth: CGFloat {
        max(120, (textContainer?.size.width ?? 400) - 2 * (textContainer?.lineFragmentPadding ?? 5))
    }

    // MARK: Attachments in

    /// Files become attachment lines at the caret, each on its own line.
    func attach(_ urls: [URL]) {
        guard isEditable, !urls.isEmpty else { return }
        Task { @MainActor in
            var lines: [String] = []
            for u in urls { if let line = await NoteAttachments.shared.add(u) { lines.append(line) } }
            insertBlock(lines)
        }
    }

    func attach(image: NSImage) {
        Task { @MainActor in if let line = await NoteAttachments.shared.add(image: image) { insertBlock([line]) } }
    }

    private func insertBlock(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let s = string as NSString
        // At the end of the caret's line, so nothing is split; each attachment on its own line.
        var loc = selectedRange().location
        if let l = currentLine(), l.range.length > 0 { loc = l.range.upperBound }
        var text = lines.joined(separator: "\n")
        if loc > 0, s.character(at: loc - 1) != 10 { text = "\n" + text }
        if loc >= s.length { text += "\n" }   // room to keep writing below
        insertText(text, replacementRange: NSRange(location: loc, length: 0))
    }

    @objc func attachFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] r in
            if r == .OK { self?.attach(panel.urls) }
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, isEditable else { return super.performDragOperation(sender) }
        let p = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: p), length: 0))
        attach(urls)
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { attach(urls); return }
        if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) { attach(image: image); return }
        super.paste(sender)
    }

    /// Typing on an attachment's line starts a new line instead of changing the attachment.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let r = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        // A "|" typed in a table cell is text, not a new column.
        if let str = string as? String, str.contains("|"), table(at: r.location) != nil {
            super.insertText(str.replacingOccurrences(of: "|", with: "\\|"), replacementRange: replacementRange)
            return
        }
        if let l = parsed.first(where: { NSLocationInRange(r.location, $0.range) || ($0.range.upperBound == r.location && r.length == 0) }),
           case .attachment = l.kind, r.length < l.range.length, (string as? String).map({ !$0.hasPrefix("\n") }) ?? true {
            setSelectedRange(NSRange(location: l.range.upperBound, length: 0))
            super.insertText("\n", replacementRange: NSRange(location: l.range.upperBound, length: 0))
            super.insertText(string, replacementRange: selectedRange())
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Editing behaviour

    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func currentLine() -> MDLine? { lineIndex(at: selectedRange().location).map { parsed[$0] } }

    /// Return continues a list or quote (numbers count up); on an empty item it outdents, then ends the list.
    override func insertNewline(_ sender: Any?) {
        // In a table: the same column in the next row (a new row at the end); a cell is one line.
        if let t = table(at: selectedRange().location) {
            if t.row + 1 < t.table.rows.count {
                let cells = Markdown.cells(string as NSString, t.table.rows[t.row + 1].range)
                if t.cell < cells.count { setSelectedRange(self.caret(in: cells[t.cell])) }
            } else {
                let col = t.cell
                editTable { c, r, _ in c.insert(Array(repeating: "", count: c[0].count), at: r + 1); return (r + 1, col) }
            }
            return
        }
        let caret = selectedRange()
        if caret.length == 0, let l = currentLine(), let m = l.marker, l.isList || l.kind == .quote {
            if l.range.upperBound == m.upperBound {   // empty item
                if l.tabs > 0 { replace(NSRange(location: l.range.location, length: 1), with: ""); renumberCurrent() }
                else { replace(NSRange(location: l.range.location, length: l.range.length), with: "") }
                return
            }
            let tabs = String(repeating: "\t", count: l.tabs)
            let next: String = switch l.kind {
            case .numbered(let n): "\(n + 1). "
            case .check: "- [ ] "
            case .quote: "> "
            default: "- "
            }
            insertText("\n" + tabs + next, replacementRange: caret)
            if case .numbered = l.kind { renumber(around: lineIndex(at: selectedRange().location) ?? 0) }
            return
        }
        super.insertNewline(sender)
    }

    /// Tab / Shift-Tab indent and outdent list items (and quotes).
    override func insertTab(_ sender: Any?) {
        if let t = table(at: selectedRange().location) {
            // Next cell; past the last cell, a new row.
            if t.cell + 1 < t.cells.count { setSelectedRange(caret(in: t.cells[t.cell + 1])); return }
            if t.row + 1 < t.table.rows.count, let next = Markdown.cells(string as NSString, t.table.rows[t.row + 1].range).first {
                setSelectedRange(caret(in: next)); return
            }
            tableAddRowBelow(nil)
            return
        }
        if let l = currentLine(), l.isList || l.kind == .quote {
            let caret = selectedRange()
            replace(NSRange(location: l.range.location, length: 0), with: "\t", select: NSRange(location: caret.location + 1, length: caret.length))
            renumberCurrent()
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let t = table(at: selectedRange().location) {
            if t.cell > 0 { setSelectedRange(caret(in: t.cells[t.cell - 1])); return }
            if t.row > 0, let prev = Markdown.cells(string as NSString, t.table.rows[t.row - 1].range).last { setSelectedRange(caret(in: prev)) }
            return
        }
        if let l = currentLine(), l.tabs > 0 {
            let caret = selectedRange()
            replace(NSRange(location: l.range.location, length: 1), with: "", select: NSRange(location: max(l.range.location, caret.location - 1), length: caret.length))
            renumberCurrent()
            return
        }
        super.insertBacktab(sender)
    }

    /// Backspace right after a list, quote or heading marker removes the marker.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, let l = currentLine(), let m = l.marker, caret.location == m.upperBound {
            replace(m, with: "")
            return
        }
        super.deleteBackward(sender)
    }

    // The caret never sits inside a drawn marker (box, bullet, quote bar).
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if !stillSelecting, ranges.count == 1, let r = ranges.first?.rangeValue, r.length == 0,
           let l = parsed.first(where: { NSLocationInRange(r.location, $0.range) }), let m = l.marker,
           l.isList || l.kind == .quote, r.location >= m.location, r.location < m.upperBound {
            if case .numbered = l.kind {} else { ranges = [NSValue(range: NSRange(location: m.upperBound, length: 0))] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    private func renumberCurrent() {
        if let i = lineIndex(at: selectedRange().location) { renumber(around: i) }
    }

    /// Numbers in the run of numbered items around line `i` count 1, 2, 3… per level (R30).
    private func renumber(around i: Int) {
        parsed = Markdown.lines(string as NSString)
        guard i < parsed.count else { return }
        var a = i, b = i
        func inRun(_ j: Int) -> Bool { parsed[j].isList }
        while a - 1 >= 0, inRun(a - 1) { a -= 1 }
        while b + 1 < parsed.count, inRun(b + 1) { b += 1 }
        var counters: [Int: Int] = [:]
        var edits: [(NSRange, String)] = []
        for j in a...b {
            let l = parsed[j]
            counters = counters.filter { $0.key <= l.tabs }
            guard case .numbered(let n) = l.kind, let m = l.marker else { counters[l.tabs] = nil; continue }
            let want = (counters[l.tabs] ?? 0) + 1
            counters[l.tabs] = want
            if n != want { edits.append((m, "\(want). ")) }
        }
        guard !edits.isEmpty else { return }
        let caret = selectedRange()
        var shift = 0
        for (r, t) in edits.reversed() {
            replace(r, with: t)
            if r.location < caret.location { shift += (t as NSString).length - r.length }
        }
        setSelectedRange(NSRange(location: caret.location + shift, length: caret.length))
    }

    // MARK: Formatting commands (Aa menu and Apple Notes' shortcuts)

    enum Block { case title, heading, subheading, body, monospaced, bulleted, numbered, checklist, quote }

    @objc func formatTitle(_ s: Any?) { setBlock(.title) }
    @objc func formatHeading(_ s: Any?) { setBlock(.heading) }
    @objc func formatSubheading(_ s: Any?) { setBlock(.subheading) }
    @objc func formatBody(_ s: Any?) { setBlock(.body) }
    @objc func formatMonospaced(_ s: Any?) { toggleCodeBlock() }
    @objc func formatBulleted(_ s: Any?) { setBlock(.bulleted) }
    @objc func formatNumbered(_ s: Any?) { setBlock(.numbered) }
    @objc func toggleChecklist(_ s: Any?) { setBlock(.checklist) }
    @objc func formatQuote(_ s: Any?) { setBlock(.quote) }
    @objc func formatBold(_ s: Any?) { toggleInline("**") }
    @objc func formatItalic(_ s: Any?) { toggleInline("*") }
    @objc func formatStrikethrough(_ s: Any?) { toggleInline("~~") }
    @objc func formatCode(_ s: Any?) { toggleInline("`") }
    @objc func formatLink(_ s: Any?) { insertLink() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return super.performKeyEquivalent(with: e) }
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector? = switch (f, key, e.keyCode) {
        case ([.command], "b", _): #selector(formatBold)
        case ([.command], "i", _): #selector(formatItalic)
        case ([.command], "k", _): #selector(formatLink)
        case ([.command], "'", _): #selector(formatQuote)
        case ([.command, .shift], "x", _): #selector(formatStrikethrough)
        case ([.command, .shift], "t", _): #selector(formatTitle)
        case ([.command, .shift], "h", _): #selector(formatHeading)
        case ([.command, .shift], "j", _): #selector(formatSubheading)
        case ([.command, .shift], "b", _): #selector(formatBody)
        case ([.command, .shift], "m", _): #selector(formatMonospaced)
        case ([.command, .shift], "l", _): #selector(toggleChecklist)
        case ([.command, .shift], _, 26): #selector(formatBulleted)   // ⇧⌘7
        case ([.command, .shift], _, 25): #selector(formatNumbered)   // ⇧⌘9
        default: nil
        }
        if let action { perform(action, with: nil); return true }
        return super.performKeyEquivalent(with: e)
    }

    /// Turns the selected lines into a block style; a list style they all have already turns them back into text.
    private func setBlock(_ block: Block) {
        guard isEditable else { return }
        parsed = Markdown.lines(string as NSString)
        let sel = selectedRange()
        var affected = parsed.filter { NSIntersectionRange($0.range, sel).length > 0 || NSLocationInRange(sel.location, $0.range) || $0.range.upperBound == sel.location }
            .filter { $0.kind != .code && $0.kind != .fence }
        if affected.isEmpty {
            let prefix: String = switch block {
            case .title: "# "
            case .heading: "## "
            case .subheading: "### "
            case .bulleted: "- "
            case .numbered: "1. "
            case .checklist: "- [ ] "
            case .quote: "> "
            default: ""
            }
            insertText(prefix, replacementRange: sel)
            return
        }
        func matches(_ l: MDLine) -> Bool {
            switch (block, l.kind) {
            case (.bulleted, .bullet), (.numbered, .numbered), (.checklist, .check), (.quote, .quote): true
            case (.heading, .heading(2)), (.subheading, .heading(3)): true
            case (.title, .heading(1)): true
            default: false
            }
        }
        let toggleOff = affected.allSatisfy(matches) && block != .title
        let first = affected.first!.range.location, last = affected.last!.range.upperBound
        var number = 0
        var newLines: [String] = []
        let s = string as NSString
        for l in affected {
            let content = s.substring(with: NSRange(location: l.content, length: l.range.upperBound - l.content))
            let keepTabs = [.bulleted, .numbered, .checklist, .quote].contains(block) && !toggleOff
            let tabs = keepTabs ? String(repeating: "\t", count: l.tabs) : ""
            var prefix = ""
            if !toggleOff {
                switch block {
                case .title: prefix = "# "
                case .heading: prefix = "## "
                case .subheading: prefix = "### "
                case .bulleted: prefix = "- "
                case .numbered: number += 1; prefix = "\(number). "
                case .checklist:
                    if case .check(let c) = l.kind { prefix = c ? "- [x] " : "- [ ] " } else { prefix = "- [ ] " }
                case .quote: prefix = "> "
                case .body, .monospaced: prefix = ""
                }
            }
            newLines.append(tabs + prefix + content)
        }
        let joined = newLines.joined(separator: "\n")
        replace(NSRange(location: first, length: last - first), with: joined,
                select: sel.length == 0 ? nil : NSRange(location: first, length: (joined as NSString).length))
        if sel.length == 0 {
            // Keep the caret at the same place within its line's text.
            let offsetFromEnd = last - sel.location
            setSelectedRange(NSRange(location: max(first, first + (joined as NSString).length - offsetFromEnd), length: 0))
        }
        if block == .numbered { renumberCurrent() }
    }

    /// Monospaced: fences around the selected lines, or removes the fences of the block the caret is in.
    private func toggleCodeBlock() {
        guard isEditable else { return }
        parsed = Markdown.lines(string as NSString)
        let sel = selectedRange()
        if let i = lineIndex(at: sel.location), [.code, .fence].contains(parsed[i].kind) {
            let block = codeBlock(around: i)
            let fences = block.filter { parsed[$0].kind == .fence }.map { parsed[$0] }
            for f in fences.reversed() {
                let len = (string as NSString).length
                // The fence line and its line break (the one before it, when it's the last line).
                let r = f.range.upperBound < len ? NSRange(location: f.range.location, length: f.range.length + 1)
                    : NSRange(location: max(0, f.range.location - 1), length: f.range.length + (f.range.location > 0 ? 1 : 0))
                replace(r, with: "")
            }
            return
        }
        let lines = parsed.filter { NSIntersectionRange($0.range, sel).length > 0 || NSLocationInRange(sel.location, $0.range) || $0.range.upperBound == sel.location }
        guard let a = lines.first?.range.location, let b = lines.last?.range.upperBound else {
            insertText("```\n\n```", replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 4, length: 0))
            return
        }
        let inner = (string as NSString).substring(with: NSRange(location: a, length: b - a))
        replace(NSRange(location: a, length: b - a), with: "```\n" + inner + "\n```",
                select: NSRange(location: a + 4 + (inner as NSString).length, length: 0))
    }

    private func toggleInline(_ m: String) {
        guard isEditable else { return }
        let s = string as NSString, sel = selectedRange(), n = (m as NSString).length
        if sel.length == 0 {
            replace(sel, with: m + m, select: NSRange(location: sel.location + n, length: 0))
            return
        }
        let text = s.substring(with: sel)
        // Already wrapped (markers just outside, or inside the selection): unwrap.
        if sel.location >= n, sel.upperBound + n <= s.length,
           s.substring(with: NSRange(location: sel.location - n, length: n)) == m,
           s.substring(with: NSRange(location: sel.upperBound, length: n)) == m {
            replace(NSRange(location: sel.location - n, length: sel.length + 2 * n), with: text,
                    select: NSRange(location: sel.location - n, length: sel.length))
            return
        }
        if text.hasPrefix(m), text.hasSuffix(m), (text as NSString).length > 2 * n {
            let inner = (text as NSString).substring(with: NSRange(location: n, length: (text as NSString).length - 2 * n))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }
        replace(sel, with: m + text + m, select: NSRange(location: sel.location + n, length: sel.length))
    }

    /// ⌘K: the selection becomes a link (to the URL on the clipboard, if there is one).
    private func insertLink() {
        guard isEditable else { return }
        let sel = selectedRange()
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = clip.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil } ?? "https://"
        let label = (string as NSString).substring(with: sel)
        let target = url.contains(" ") || url.contains("(") || url.contains(")") ? "<\(url)>" : url
        let text = "[\(label)](\(target))"
        let urlStart = sel.location + 1 + (label as NSString).length + 2
        replace(sel, with: text, select: label.isEmpty ? NSRange(location: sel.location + 1, length: 0)
                                                      : NSRange(location: urlStart, length: (target as NSString).length))
    }
}

/// The Aa menu: block styles, lists and text styles, with Apple Notes' shortcuts (handled by the editor).
struct NoteFormatMenu: View {
    var body: some View {
        Menu {
            Section {
                item("Title", #selector(NoteTextView.formatTitle(_:)), "t", [.command, .shift])
                item("Heading", #selector(NoteTextView.formatHeading(_:)), "h", [.command, .shift])
                item("Subheading", #selector(NoteTextView.formatSubheading(_:)), "j", [.command, .shift])
                item("Body", #selector(NoteTextView.formatBody(_:)), "b", [.command, .shift])
                item("Monospaced", #selector(NoteTextView.formatMonospaced(_:)), "m", [.command, .shift])
            }
            Section {
                item("Bulleted List", #selector(NoteTextView.formatBulleted(_:)), "7", [.command, .shift])
                item("Numbered List", #selector(NoteTextView.formatNumbered(_:)), "9", [.command, .shift])
                item("Checklist", #selector(NoteTextView.toggleChecklist(_:)), "l", [.command, .shift])
                item("Block Quote", #selector(NoteTextView.formatQuote(_:)), "'", [.command])
            }
            Section {
                item("Bold", #selector(NoteTextView.formatBold(_:)), "b", [.command])
                item("Italic", #selector(NoteTextView.formatItalic(_:)), "i", [.command])
                item("Strikethrough", #selector(NoteTextView.formatStrikethrough(_:)), "x", [.command, .shift])
                Button("Code") { send(#selector(NoteTextView.formatCode(_:))) }
                item("Link…", #selector(NoteTextView.formatLink(_:)), "k", [.command])
            }
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .menuIndicator(.hidden)
        .help("Format")
    }

    private func item(_ title: String, _ action: Selector, _ key: KeyEquivalent, _ mods: EventModifiers) -> some View {
        Button(title) { send(action) }.keyboardShortcut(key, modifiers: mods)
    }

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
}


/// How attachments look in a note: images and PDFs at the note's width, other files as a tile.
@MainActor
enum AttachmentArt {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
    /// Previews of attachments: about 48 MB at most, emptied by macOS under memory pressure.
    private static let thumbs: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 48 << 20; return c }()

    static func kind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return imageTypes.contains(ext) ? "image" : ext == "pdf" ? "pdf" : "file"
    }

    /// A downscaled picture (images; a PDF's first page), cached.
    static func thumbnail(_ name: String) -> NSImage? {
        if let t = thumbs.object(forKey: name as NSString) { return t }
        let url = NoteAttachments.url(name)
        guard NoteAttachments.has(name) else { return nil }
        var image: NSImage?
        switch kind(name) {
        case "image":
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        case "pdf":
            if let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
                let box = page.getBoxRect(.cropBox)
                let scale = min(2, 1400 / max(box.width, 1))
                let size = NSSize(width: box.width * scale, height: box.height * scale)
                image = NSImage(size: size, flipped: false) { r in
                    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                    ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -box.minX, y: -box.minY)
                    ctx.drawPDFPage(page)
                    return true
                }
            }
        default: break
        }
        if let image { thumbs.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }

    static func height(_ name: String, width: CGFloat) -> CGFloat {
        guard kind(name) != "file", let t = thumbnail(name), t.size.width > 0 else { return 56 }
        let w = min(width, t.size.width / 2)   // pictures aren't blown up past their own size
        return min(440, max(40, w * t.size.height / t.size.width))
    }

    static func draw(_ name: String, label: String, in frame: NSRect, selected: Bool) {
        let have = NoteAttachments.has(name)
        if have, kind(name) != "file", let t = thumbnail(name) {
            let w = min(frame.width, t.size.width / 2, frame.height * t.size.width / t.size.height)
            let r = NSRect(x: frame.minX, y: frame.minY, width: w, height: frame.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).addClip()
            t.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            if selected { outline(r) }
            return
        }
        // A tile: icon, name, size (or a placeholder while the file is on its way).
        let tile = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, 340), height: 56)
        let path = NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
        let icon: NSImage = have ? NSWorkspace.shared.icon(forFile: NoteAttachments.url(name).path)
            : (NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) ?? NSImage())
        icon.draw(in: NSRect(x: tile.minX + 10, y: tile.minY + 10, width: 36, height: 36), from: .zero, operation: .sourceOver,
                  fraction: have ? 1 : 0.5, respectFlipped: true, hints: nil)
        let title = NSAttributedString(string: label.isEmpty ? name : label,
                                       attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        let size = (try? NoteAttachments.url(name).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let detail = NSAttributedString(string: have ? (size ?? "") : "Waiting for it to arrive from your phone…",
                                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let textX = tile.minX + 56, textW = tile.width - 66
        title.draw(with: NSRect(x: textX, y: tile.minY + 10, width: textW, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        detail.draw(with: NSRect(x: textX, y: tile.minY + 30, width: textW, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if selected { outline(tile) }
    }

    private static func outline(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
        p.lineWidth = 3; Janus.primary.setStroke(); p.stroke()
    }
}
