import AppIntents
import WidgetFeed
import WidgetKit

/// Ticks or unticks a checklist item from a widget. Runs in the widget extension: the app applies it and syncs it.
struct SetChecklistItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick Checklist Item"
    static var isDiscoverable = false

    @Parameter(title: "Note") var note: String
    @Parameter(title: "Line") var line: Int
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Checked") var checked: Bool

    init() {}
    init(note: String, line: Int, text: String, checked: Bool) {
        self.note = note; self.line = line; self.text = text; self.checked = checked
    }

    func perform() async throws -> some IntentResult {
        try WidgetFeed.post(.init(note: note, line: line, text: text, checked: checked))
        return .result()
    }
}

/// A note, as Edit Widget lists them.
struct NoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static var defaultQuery = NoteQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ note: WidgetFeed.Note) { id = note.id; title = note.title.isEmpty ? "New Note" : note.title }
}

struct NoteQuery: EntityStringQuery {
    private var notes: [WidgetFeed.Note] { WidgetFeed.read()?.notes ?? [] }
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        notes.filter { identifiers.contains($0.id) }.map(NoteEntity.init)
    }
    func entities(matching string: String) async throws -> [NoteEntity] {
        notes.filter { $0.title.localizedCaseInsensitiveContains(string) }.map(NoteEntity.init)
    }
    func suggestedEntities() async throws -> [NoteEntity] { notes.map(NoteEntity.init) }
}

/// Which note a Note widget shows; none chosen shows the first (pinned, else the latest).
struct SelectNoteIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Note"
    static var description = IntentDescription("The note this widget shows.")

    @Parameter(title: "Note") var note: NoteEntity?
}
