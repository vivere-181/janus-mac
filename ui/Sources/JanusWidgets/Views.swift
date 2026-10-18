import AppIntents
import SwiftUI
import WidgetFeed
import WidgetKit

/// Janus navy (R32) and the widgets' measures.
enum Look {
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xA8 / 255, green: 0xC8 / 255, blue: 0xFC / 255) : Color(red: 0x1B / 255, green: 0x46 / 255, blue: 0x84 / 255)
    }
    /// The navy of the app icon, for the small tile next to the header (the same in light and dark, like an icon).
    static let tile = LinearGradient(colors: [Color(red: 0x34 / 255, green: 0x6C / 255, blue: 0xC0 / 255), Color(red: 0x1B / 255, green: 0x46 / 255, blue: 0x84 / 255)],
                                     startPoint: .top, endPoint: .bottom)

    /// A whisper of navy at the top, fading into the page: depth without a colour block.
    static func background(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.23), Color(red: 0.10, green: 0.11, blue: 0.13)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.99), .white], startPoint: .top, endPoint: .center)
    }
    /// A note's card: a soft fill and a hairline, so notes read as things you can click.
    static func card(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.07) : Color(red: 0.11, green: 0.27, blue: 0.52).opacity(0.055) }
    static func cardEdge(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.08) : Color(red: 0.11, green: 0.27, blue: 0.52).opacity(0.09) }

    static let titleFont = Font.system(size: 12.5, weight: .semibold)
    static let lineFont = Font.system(size: 11.5)
    static let lineHeight: CGFloat = 15
    /// Heights the layout plans with.
    static let titleHeight: CGFloat = 17, cardPadding: CGFloat = 7, cardGap: CGFloat = 6, header: CGFloat = 34, margins: CGFloat = 32
    /// The hairline under a note's title, with the space around it.
    static let rule: CGFloat = 7

    /// Headings keep the editor's proportions to body text (# 22, ## 18, ### 15.5 against 14) when one note is shown;
    /// in the list's previews they're only a little larger than the text around them.
    static func headingSize(_ level: Int?, _ size: CGFloat, prominent: Bool) -> CGFloat {
        let scale: [CGFloat] = prominent ? [1.45, 1.25, 1.1] : [1.15, 1.07, 1.0]
        return size * scale[min(max((level ?? 3) - 1, 0), 2)]
    }

    /// What a line takes up: an empty line is a gap of `blank`.
    static func height(_ l: WidgetFeed.Line, size: CGFloat, blank: CGFloat, prominent: Bool) -> CGFloat {
        switch l.kind {
        case .blank: blank
        case .heading: headingSize(l.heading, size, prominent: prominent) + (prominent ? 6 : 3.5)
        default: size + 3.5
        }
    }

    /// The lines that fit in `height`, at most `limit` of them with text, never ending on a gap.
    static func fit(_ lines: [WidgetFeed.Line], height: CGFloat, limit: Int, size: CGFloat, blank: CGFloat,
                    prominent: Bool) -> (lines: [WidgetFeed.Line], used: CGFloat) {
        var out: [WidgetFeed.Line] = [], used: CGFloat = 0, count = 0
        for l in lines {
            if l.kind != .blank, count >= limit { break }
            let h = Self.height(l, size: size, blank: blank, prominent: prominent)
            if used + h > height { break }
            out.append(l); used += h
            if l.kind != .blank { count += 1 }
        }
        while let last = out.last, last.kind == .blank { out.removeLast(); used -= blank }
        return (out, used)
    }

    /// "14:05", "Yesterday", "Tuesday", "3/10/26", like Notes.
    static func time(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        if now.timeIntervalSince(d) < 6 * 86400 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(date: .numeric, time: .omitted)
    }
}

enum Links {
    static let notes = URL(string: "janus://notes")!
    static let new = URL(string: "janus://notes/new")!
    static func open(_ id: String) -> URL {
        var c = URLComponents(string: "janus://notes/open")!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url!
    }
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Look.background(scheme) }
}

/// The small navy tile with the notes glyph, like a folder's icon in Notes.
struct NotesTile: View {
    var side: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(Look.tile)
            .overlay {
                Image(systemName: "note.text").font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .shadow(color: Color(red: 0.11, green: 0.27, blue: 0.52).opacity(0.25), radius: 1.5, y: 1)
            .widgetAccentable()
    }
}

/// A round ✎ button in Janus navy.
struct ComposeButton: View {
    let accent: Color
    var side: CGFloat = 24
    var body: some View {
        Link(destination: Links.new) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: side, height: side)
                .background(accent.opacity(0.14), in: Circle())
                .widgetAccentable()
        }
        .accessibilityLabel("New Note")
    }
}

// MARK: Notes (the list)

/// Pinned notes first, then the latest, each on its own card with its first lines; checklist items tick right
/// there (like the phone's widget).
struct NotesListView: View {
    let notes: [WidgetFeed.Note]
    var total: Int? = nil
    let family: WidgetFamily
    /// The widget's size on screen (what fits is worked out from it).
    let size: CGSize
    let now: Date
    @Environment(\.colorScheme) private var scheme

    private var columnCount: Int { family == .systemMedium || family == .systemExtraLarge ? 2 : 1 }
    private var linesPerNote: Int { family == .systemLarge || family == .systemExtraLarge ? 4 : 2 }

    private struct Shown: Identifiable { let note: WidgetFeed.Note; let lines: [WidgetFeed.Line]; var id: String { note.id } }

    /// Cards top to bottom, column after column, as many as fit.
    private var columns: [[Shown]] {
        let height = size.height - Look.margins - Look.header
        let card = Look.cardPadding * 2 + Look.titleHeight
        var out: [[Shown]] = [[]]
        var left = height
        for n in notes {
            var gap = out[out.count - 1].isEmpty ? 0 : Look.cardGap
            if left < gap + card {
                guard out.count < columnCount else { break }
                out.append([]); left = height; gap = 0
            }
            // In a list, an empty line is a small gap: enough to keep the note's parts apart.
            let fit = Look.fit(n.lines, height: left - gap - card - Look.rule, limit: linesPerNote, size: 11.5, blank: 6, prominent: false)
            out[out.count - 1].append(Shown(note: n, lines: fit.lines))
            left -= gap + card + fit.used + (fit.lines.isEmpty ? 0 : Look.rule)
        }
        return out
    }

    var body: some View {
        let accent = Look.accent(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Link(destination: Links.notes) {
                    HStack(spacing: 7) {
                        NotesTile()
                        Text("Notes").font(.system(size: 14, weight: .bold))
                        if let count = total ?? (notes.isEmpty ? nil : notes.count) {
                            Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
                ComposeButton(accent: accent)
            }
            .frame(height: 24)
            if notes.isEmpty {
                EmptyNotes(accent: accent, compact: family == .systemSmall)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: Look.cardGap) {
                            ForEach(column) { NoteCard(note: $0.note, lines: $0.lines, now: now, accent: accent) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// No notes yet: what to do about it.
struct EmptyNotes: View {
    let accent: Color
    var compact = false
    var body: some View {
        Link(destination: Links.new) {
            VStack(spacing: compact ? 4 : 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: compact ? 15 : 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                    .background(accent.opacity(0.12), in: Circle())
                    .widgetAccentable()
                Text("No Notes").font(Look.titleFont)
                if !compact {
                    Text("Your notes, synced with your phone, show up here.").font(Look.lineFont).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A note on its card: pin, title and time, then the lines shown under it.
struct NoteCard: View {
    let note: WidgetFeed.Note
    let lines: [WidgetFeed.Line]
    let now: Date
    let accent: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: Links.open(note.id)) {
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(accent)
                            .rotationEffect(.degrees(40)).widgetAccentable()
                    }
                    Text(note.title.isEmpty ? "New Note" : note.title).font(Look.titleFont).foregroundStyle(accent).lineLimit(1)
                        .widgetAccentable()
                    Spacer(minLength: 4)
                    Text(Look.time(note.modified, now: now)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(height: Look.titleHeight)
                .contentShape(Rectangle())
            }
            if !lines.isEmpty {
                TitleRule(accent: accent).frame(height: Look.rule)
                ForEach(lines, id: \.index) { NoteLine(note: note, line: $0, accent: accent, blank: 6) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, Look.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            if mode == .fullColor {
                shape.fill(Look.card(scheme)).overlay(shape.strokeBorder(Look.cardEdge(scheme), lineWidth: 0.5))
            } else {
                shape.fill(.primary.opacity(0.08))   // tinted or clear desktop widgets: a plain plate
            }
        }
    }
}

/// The hairline between a note's title and its text.
struct TitleRule: View {
    let accent: Color
    var body: some View {
        Rectangle().fill(accent.opacity(0.2)).frame(height: 0.75).widgetAccentable()
    }
}

/// One line as the note shows it (its heading size, bold, italic, strikethrough, code, links); a checklist item
/// ticks right here.
struct NoteLine: View {
    let note: WidgetFeed.Note
    let line: WidgetFeed.Line
    let accent: Color
    var size: CGFloat = 11.5
    /// The height of an empty line.
    var blank: CGFloat = 15
    /// Body text in full colour (one note shown) or quieter (a preview in the list).
    var prominent = false

    /// The text with its inline formatting; code on a light chip, like in the editor.
    private var text: Text {
        guard let rich = line.rich,
              var a = try? AttributedString(markdown: rich, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return Text(line.text) }
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].backgroundColor = Color.secondary.opacity(0.16)
        }
        return Text(a)
    }

    private var textColor: Color {
        switch line.kind {
        case .heading: .primary
        case .quote, .attachment: .secondary
        default: prominent ? .primary : .secondary
        }
    }

    var body: some View {
        if line.kind == .blank {
            Color.clear.frame(height: blank)
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if line.kind == .check {
                Button(intent: SetChecklistItemIntent(note: note.id, line: line.index, text: line.text, checked: !line.checked)) {
                    HStack(spacing: 5) {
                        Group {
                            if line.checked {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).widgetAccentable()
                            } else {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: size + 1))
                        .contentTransition(.symbolEffect(.replace))
                        .invalidatableContent()   // shown as pending until the tick lands
                        text
                            .strikethrough(line.checked, color: .secondary)
                            .foregroundStyle(line.checked ? Color.secondary : (prominent ? Color.primary : Color.primary.opacity(0.85)))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Link(destination: Links.open(note.id)) {
                    HStack(spacing: 4) {
                        switch line.kind {
                        case .bullet: Text("•").foregroundStyle(accent.opacity(0.8))
                        case .number: Text("\(line.number).").foregroundStyle(.secondary).monospacedDigit()
                        case .quote: RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.6)).frame(width: 2, height: size + 2)
                        case .attachment: Image(systemName: "paperclip").foregroundStyle(accent)
                        default: EmptyView()
                        }
                        text
                            .font(font)
                            .foregroundStyle(textColor)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.system(size: size))
        .lineLimit(1)
        .padding(.leading, CGFloat(min(line.level, 4)) * 12)
        .frame(height: Look.height(line, size: size, blank: blank, prominent: prominent), alignment: line.kind == .heading ? .bottom : .center)
        .tint(accent)   // links in Janus navy
    }

    private var font: Font {
        switch line.kind {
        case .heading: .system(size: Look.headingSize(line.heading, size, prominent: prominent), weight: (line.heading ?? 3) <= 2 ? .bold : .semibold)
        case .code: .system(size: size - 0.5, design: .monospaced)
        default: .system(size: size)
        }
    }
}

// MARK: Note (one note)

struct SingleNoteView: View {
    enum State { case note(WidgetFeed.Note), noNotes, missing }
    let state: State
    let family: WidgetFamily
    let size: CGSize
    let now: Date
    @Environment(\.colorScheme) private var scheme

    /// The lines the widget has room for under the title (empty lines keep their full height, as in the note).
    private func shown(_ note: WidgetFeed.Note) -> [WidgetFeed.Line] {
        Look.fit(note.lines, height: size.height - Look.margins - 36, limit: .max, size: 12, blank: 15.5, prominent: true).lines
    }

    var body: some View {
        let accent = Look.accent(scheme)
        switch state {
        case .note(let note):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.title.isEmpty ? "New Note" : note.title)
                        // As large as a "#" heading, like the title in the editor; in navy, the note's header.
                        .font(.system(size: Look.headingSize(1, family == .systemSmall ? 10.5 : 12, prominent: true), weight: .bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                            .rotationEffect(.degrees(40))
                    }
                }
                .widgetAccentable()
                TitleRule(accent: accent).padding(.top, 6).padding(.bottom, 6)
                if note.lines.isEmpty {
                    Text("No additional text").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                ForEach(shown(note), id: \.index) { NoteLine(note: note, line: $0, accent: accent, size: 12, blank: 15.5, prominent: true) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Links.open(note.id))
        case .noNotes, .missing:
            VStack(spacing: 6) {
                Image(systemName: missing ? "questionmark.text.page" : "square.and.pencil")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.12), in: Circle())
                    .widgetAccentable()
                Text(missing ? "Note Not Found" : "No Notes").font(Look.titleFont)
                Text(missing ? "It was deleted. Choose another with Edit Widget." : "Click to write one.")
                    .font(Look.lineFont).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(missing ? Links.notes : Links.new)
        }
    }

    private var missing: Bool { if case .missing = state { true } else { false } }
}

// MARK: Samples (the widget gallery's preview before any notes exist)

enum Samples {
    static let notes: [WidgetFeed.Note] = [
        .init(id: "sample-1", rev: "", title: "Groceries", pinned: true, modified: .now, lines: [
            .init(index: 1, kind: .check, level: 0, text: "Milk", checked: true),
            .init(index: 2, kind: .check, level: 0, text: "Eggs"),
            .init(index: 3, kind: .check, level: 0, text: "Coffee beans"),
            .init(index: 4, kind: .check, level: 0, text: "Bread"),
        ]),
        .init(id: "sample-2", rev: "", title: "Trip ideas", pinned: false, modified: .now.addingTimeInterval(-3600 * 26), lines: [
            .init(index: 1, kind: .bullet, level: 0, text: "Weekend in the mountains"),
            .init(index: 2, kind: .bullet, level: 0, text: "Book the guesthouse"),
        ]),
        .init(id: "sample-3", rev: "", title: "Meeting notes", pinned: false, modified: .now.addingTimeInterval(-3600 * 72), lines: [
            .init(index: 1, kind: .body, level: 0, text: "Ship the widget this week", rich: "Ship the widget **this week**"),
        ]),
    ]
}
