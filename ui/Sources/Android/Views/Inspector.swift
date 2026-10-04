import AppKit
import SwiftUI
import KDEConnectKit

/// Testing aid: the raw data behind what the phones send (notifications with every field, live activities,
/// calendar snapshots, calls), newest first. In memory only; cleared when the app quits.
@MainActor @Observable
final class Inspector {
    static let shared = Inspector()

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let kind: String
        let source: String
        let title: String
        let fields: [(String, String)]
    }

    private(set) var entries: [Entry] = []
    var selection: UUID?

    func record(_ kind: String, source: String, title: String, fields: [(String, String)]) {
        entries.insert(Entry(kind: kind, source: source, title: title, fields: fields), at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
    }

    /// A notification's properties as the engine has them (companion messages included; JSON bodies pretty-printed).
    func recordNotification(_ p: [String: DBusValue], id: String, device: Device) {
        let internalId = p["internalId"]?.string ?? ""
        let kind: String
        switch true {
        case internalId.hasPrefix("ge.connect.live"): kind = "Live"
        case internalId.hasPrefix("ge.connect.calendar"): kind = "Calendar"
        case internalId.hasPrefix("ge.connect.callstate"): kind = "Call"
        case internalId.hasPrefix("ge.connect."): kind = "Companion"
        default: kind = "Notification"
        }
        var fields = p.keys.sorted().map { key -> (String, String) in
            let v = p[key]!
            let text = v.string ?? v.strings.map { $0.isEmpty ? "[]" : $0.joined(separator: " · ") } ?? v.bool.map { $0 ? "true" : "false" } ?? v.description
            return (key, text)
        }
        // JSON bodies (live activities, calendar…) are shown formatted instead of on one line.
        if let text = p["text"]?.string, let pretty = Self.prettyJSON(text), let i = fields.firstIndex(where: { $0.0 == "text" }) {
            fields[i] = ("text (JSON)", pretty)
        }
        fields.insert(("engine id", id), at: 0)
        let app = p["appName"]?.string ?? ""
        let title = p["title"]?.string ?? ""
        record(kind, source: device.name, title: kind == "Notification" ? [app, title].filter { !$0.isEmpty }.joined(separator: ": ") : internalId, fields: fields)
    }

    static func prettyJSON(_ text: String) -> String? {
        guard text.first == "{" || text.first == "[",
              let data = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Window

    @ObservationIgnored private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: InspectorView().tint(.janus)))
        w.title = "Inspector"
        w.setContentSize(NSSize(width: 860, height: 540))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct InspectorView: View {
    @State private var filter = "All"
    @Bindable var inspector = Inspector.shared

    private var kinds: [String] { ["All"] + Array(Set(inspector.entries.map(\.kind))).sorted() }
    private var shown: [Inspector.Entry] { filter == "All" ? inspector.entries : inspector.entries.filter { $0.kind == filter } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) { ForEach(kinds, id: \.self) { Text($0) } }
                    .labelsHidden().padding(8)
                List(shown, selection: $inspector.selection) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.kind).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(e.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(e.title.isEmpty ? "(no title)" : e.title).lineLimit(2)
                        Text(e.source).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView("Nothing yet", systemImage: "tray",
                                               description: Text("Notifications, live activities, calls and calendar updates from your phones appear here as they arrive."))
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
            Group {
                if let e = inspector.entries.first(where: { $0.id == inspector.selection }) {
                    ScrollView {
                        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                            ForEach(Array(e.fields.enumerated()), id: \.offset) { _, f in
                                GridRow {
                                    Text(f.0).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(f.1).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .toolbar {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(e.fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n"), forType: .string)
                        }
                    }
                } else {
                    ContentUnavailableView("Select an item", systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
