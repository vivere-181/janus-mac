import AppIntents
import SwiftUI
import WidgetFeed
import WidgetKit

/// Janus's widgets: Notes (the list) and Note (one note). The app keeps their data current (WidgetFeed) and asks
/// for a redraw when it changes; nothing here polls.
@main
struct JanusWidgets: WidgetBundle {
    var body: some Widget {
        NotesWidget()
        NoteWidget()
    }
}

private func nextMidnight(after date: Date) -> Date {
    Calendar.current.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
}

// MARK: Notes

struct NotesEntry: TimelineEntry {
    let date: Date
    let notes: [WidgetFeed.Note]
    var total: Int? = nil
    let size: CGSize
}

struct NotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry { NotesEntry(date: .now, notes: Samples.notes, size: context.displaySize) }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        let snapshot = WidgetFeed.read()
        let notes = snapshot?.notes ?? []
        completion(context.isPreview && notes.isEmpty ? placeholder(in: context)
                   : NotesEntry(date: .now, notes: notes, total: snapshot?.total, size: context.displaySize))
    }

    /// One entry; the app reloads it when the notes change. Midnight only turns "14:05" into "Yesterday".
    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        let now = Date.now
        let snapshot = WidgetFeed.read()
        let entry = NotesEntry(date: now, notes: snapshot?.notes ?? [], total: snapshot?.total, size: context.displaySize)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight(after: now))))
    }
}

struct NotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFeed.listKind, provider: NotesProvider()) { entry in
            NotesWidgetView(entry: entry)
        }
        .configurationDisplayName("Notes")
        .description("Your notes, pinned first. Tick checklist items right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct NotesWidgetView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        NotesListView(notes: entry.notes, total: entry.total, family: family, size: entry.size, now: entry.date)
            .containerBackground(for: .widget) { WidgetBackground() }
    }
}

// MARK: Note

struct NoteEntry: TimelineEntry {
    let date: Date
    let state: SingleNoteView.State
    let size: CGSize
}

struct NoteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NoteEntry { NoteEntry(date: .now, state: .note(Samples.notes[0]), size: context.displaySize) }

    func snapshot(for configuration: SelectNoteIntent, in context: Context) async -> NoteEntry {
        let entry = self.entry(for: configuration, context)
        if context.isPreview, case .noNotes = entry.state { return placeholder(in: context) }
        return entry
    }

    func timeline(for configuration: SelectNoteIntent, in context: Context) async -> Timeline<NoteEntry> {
        let entry = self.entry(for: configuration, context)
        return Timeline(entries: [entry], policy: .after(nextMidnight(after: entry.date)))
    }

    private func entry(for configuration: SelectNoteIntent, _ context: Context) -> NoteEntry {
        let notes = WidgetFeed.read()?.notes ?? []
        let state: SingleNoteView.State
        if let chosen = configuration.note {
            state = notes.first { $0.id == chosen.id }.map { .note($0) } ?? .missing
        } else {
            state = notes.first.map { .note($0) } ?? .noNotes
        }
        return NoteEntry(date: .now, state: state, size: context.displaySize)
    }
}

struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetFeed.noteKind, intent: SelectNoteIntent.self, provider: NoteProvider()) { entry in
            NoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Note")
        .description("One note and its checklist. Choose the note with Edit Widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NoteWidgetView: View {
    let entry: NoteEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        SingleNoteView(state: entry.state, family: family, size: entry.size, now: entry.date)
            .containerBackground(for: .widget) { WidgetBackground() }
    }
}
