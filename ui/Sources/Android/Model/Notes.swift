import AppKit
import CryptoKit
import Foundation

/// A note: plain text, first line is the title; checklist items are lines starting "- [ ] " / "- [x] ".
struct Note: Codable, Identifiable, Equatable {
    var id: String
    /// New on every change (edit, pin, delete, restore); how the two sides tell versions apart.
    var rev: String
    var text: String
    var pinned: Bool
    var created: Date
    var modified: Date
    /// When it was deleted (Recently Deleted for 30 days); nil = live.
    var deleted: Date?

    /// The first non-empty line, without its Markdown (R30).
    var title: String { NoteSummary.of(self).title }

    /// The text after the title, on one line, without Markdown (only as much as a list row shows).
    var preview: String { NoteSummary.of(self).preview }

    static func stripChecklist(_ line: String) -> String {
        for p in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(p) { return String(line.dropFirst(p.count)) }
        return line
    }

    /// Times travel in whole milliseconds; keeping them that way here makes both sides compare the same values.
    static var now: Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// Java's UUID.nameUUIDFromBytes (MD5, version 3), so the phone makes the same id.
    static func uuid3(_ name: String) -> String {
        var b = Array(Insecure.MD5.hash(data: Data(name.utf8)))
        b[6] = (b[6] & 0x0f) | 0x30
        b[8] = (b[8] & 0x3f) | 0x80
        let h = b.map { String(format: "%02x", $0) }.joined()
        let parts = [h.prefix(8), h.dropFirst(8).prefix(4), h.dropFirst(12).prefix(4), h.dropFirst(16).prefix(4), h.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    // Wire format: times in epoch ms (shared/REQUESTS.md R29).
    enum CodingKeys: String, CodingKey { case id, rev, text, pinned, created, modified, deleted }
    init(id: String = UUID().uuidString, rev: String = UUID().uuidString, text: String, pinned: Bool = false,
         created: Date = Note.now, modified: Date = Note.now, deleted: Date? = nil) {
        self.id = id; self.rev = rev; self.text = text; self.pinned = pinned
        self.created = created; self.modified = modified; self.deleted = deleted
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func date(_ k: CodingKeys) throws -> Date? {
            try c.decodeIfPresent(Double.self, forKey: k).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        id = try c.decode(String.self, forKey: .id)
        rev = try c.decode(String.self, forKey: .rev)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        created = try date(.created) ?? .now
        modified = try date(.modified) ?? created
        deleted = try date(.deleted)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        let ms = Note.ms
        try c.encode(id, forKey: .id); try c.encode(rev, forKey: .rev); try c.encode(text, forKey: .text)
        try c.encode(pinned, forKey: .pinned); try c.encode(ms(created), forKey: .created); try c.encode(ms(modified), forKey: .modified)
        if let deleted { try c.encode(ms(deleted), forKey: .deleted) }
    }
}

/// The owner's notes on this Mac, synced with every phone running our app that supports notes (R29). Each side
/// remembers which version each peer has (`acked`); whatever differs is sent. Concurrent edits keep both versions.
@MainActor @Observable
final class NotesStore {
    static let shared = NotesStore()
    static let trashDays: TimeInterval = 30 * 24 * 3600

    private(set) var notes: [Note] = []
    /// Per phone: note id → the rev that phone is known to have.
    @ObservationIgnored private var acked: [String: [String: String]] = [:]
    /// Phones we're syncing with right now, and when we last heard from them.
    private(set) var lastSync: [String: Date] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// Testing aid: acts as if no phone were connected (nothing sent or taken) until switched back on.
    @ObservationIgnored var paused = false {
        didSet { if !paused, oldValue { for d in peers() { connected(d) } } }
    }

    private struct Saved: Codable { var notes: [Note]; var acked: [String: [String: String]] }
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            notes = saved.notes; acked = saved.acked
        }
        purge()
    }

    var live: [Note] {
        notes.filter { $0.deleted == nil }.sorted { ($0.pinned ? 0 : 1, -$0.modified.timeIntervalSince1970) < ($1.pinned ? 0 : 1, -$1.modified.timeIntervalSince1970) }
    }
    var trash: [Note] { notes.filter { $0.deleted != nil }.sorted { $0.deleted! > $1.deleted! } }

    func note(_ id: String?) -> Note? { notes.first { $0.id == id } }

    /// Testing aid: which rev a phone has acknowledged.
    func ackedRev(_ id: String, peer: String) -> String? { acked[peer]?[id] }

    // MARK: Editing (every change gets a new rev and is pushed)

    @discardableResult
    func create(text: String = "") -> Note {
        let n = Note(id: UUID().uuidString.lowercased(), text: text)
        notes.append(n)
        changed()
        return n
    }

    func setText(_ id: String, _ text: String) {
        edit(id) { $0.text = text }
    }

    func togglePin(_ id: String) { edit(id) { $0.pinned.toggle() } }
    func delete(_ id: String) { edit(id) { $0.deleted = Note.now; $0.pinned = false } }
    func restore(_ id: String) { edit(id) { $0.deleted = nil } }

    /// Gone for good here (the phones keep their copy in Recently Deleted until their own 30 days pass).
    func deleteNow(_ id: String) {
        notes.removeAll { $0.id == id }
        for k in acked.keys { acked[k]?[id] = nil }
        save()
    }

    private func edit(_ id: String, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var n = notes[i]
        change(&n)
        guard n != notes[i] else { return }
        n.rev = UUID().uuidString.lowercased()
        n.modified = Note.now
        notes[i] = n
        changed()
    }

    private func changed() {
        save()
        // Pushed once typing pauses.
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            for d in self.peers() { self.push(to: d) }
        }
    }

    // MARK: Sync

    /// Our phones that sync notes and are connected.
    func peers() -> [Device] {
        AppModel.shared.connectedDevices.filter { Self.syncs($0) }
    }

    static func syncs(_ d: Device) -> Bool {
        DeviceTrust.isMine(d) && d.profile?.caps?.contains("notes") == true
    }

    /// The phone connected (its profile arrived): say hello and send what it's missing.
    func connected(_ device: Device) {
        guard !paused, Self.syncs(device) else { return }
        // The profile can arrive a moment before this app has marked the phone connected: try again shortly.
        guard device.isReachable else {
            Task { [weak device] in
                try? await Task.sleep(for: .seconds(2))
                if let device, device.isReachable { self.connected(device) }
            }
            return
        }
        // Once per connection (the connect and the profile both ask for it).
        if let last = helloSent[device.id], Date().timeIntervalSince(last) < 10 { return }
        helloSent[device.id] = .now
        send(["v": 1, "op": "hello"], to: device)
        push(to: device)
        NoteAttachments.shared.requestMissing(from: device)
    }
    @ObservationIgnored private var helloSent: [String: Date] = [:]

    private func push(to device: Device) {
        guard !paused else { return }
        let have = acked[device.id] ?? [:]
        // A note nobody has written in yet isn't sent.
        let pending = notes.filter { have[$0.id] != $0.rev && !(have[$0.id] == nil && $0.deleted == nil && $0.text.isEmpty) }
        guard !pending.isEmpty else { return }
        // Batches of at most 50 notes and about 200 KB (a bigger note goes alone).
        var batch: [[String: Any]] = [], size = 0
        func flush() {
            if !batch.isEmpty { send(["v": 1, "op": "push", "notes": batch], to: device) }
            batch = []; size = 0
        }
        for n in pending {
            guard var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(n))) as? [String: Any] else { continue }
            if let base = have[n.id] { o["base"] = base }
            let bytes = (try? JSONSerialization.data(withJSONObject: o).count) ?? 0
            if batch.count == 50 || (size + bytes > 200_000 && !batch.isEmpty) { flush() }
            batch.append(o); size += bytes
        }
        flush()
    }

    func send(_ message: [String: Any], to device: Device) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        if UserDefaults.standard.bool(forKey: "debugSnapshots") {
            debugLog("notes → \(device.name): \(message["op"] ?? "?") \((message["files"] as? [String])?.map { String($0.prefix(8)) } ?? [])\(message["name"].map { " \(String(describing: $0).prefix(8))" } ?? "")")
        }
        device.command("notes:" + String(decoding: data, as: UTF8.self))
    }

    /// A message from a phone (`ge.connect.notes:<uuid>`).
    func receive(_ json: String, from device: Device) {
        guard !paused, Self.syncs(device), let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        lastSync[device.id] = .now
        if UserDefaults.standard.bool(forKey: "debugSnapshots") { debugLog("notes ← \(device.name): \(o["op"] ?? "?") \((o["files"] as? [String])?.map { String($0.prefix(8)) } ?? [])\((o["name"] as? String).map { " " + $0.prefix(8) } ?? "")") }
        switch o["op"] as? String {
        case "hello":
            push(to: device)
            NoteAttachments.shared.requestMissing(from: device)
        case "want":
            NoteAttachments.shared.wanted(o["files"] as? [String] ?? [], by: device)
        case "file":
            if let name = o["name"] as? String { NoteAttachments.shared.expect(name) }
        case "have":
            NoteAttachments.shared.had(o["files"] as? [String] ?? [], by: device)
        case "ack":
            for a in o["acks"] as? [[String: Any]] ?? [] {
                if let id = a["id"] as? String, let rev = a["rev"] as? String { acked[device.id, default: [:]][id] = rev }
            }
            save()
        case "push":
            var acks: [[String: String]] = []
            var changedHere = false
            for item in o["notes"] as? [[String: Any]] ?? [] {
                guard let d = try? JSONSerialization.data(withJSONObject: item),
                      let incoming = try? JSONDecoder().decode(Note.self, from: d) else { continue }
                if apply(incoming, base: item["base"] as? String) { changedHere = true }
                acked[device.id, default: [:]][incoming.id] = incoming.rev
                acks.append(["id": incoming.id, "rev": incoming.rev])
            }
            save()
            if !acks.isEmpty { send(["v": 1, "op": "ack", "acks": acks], to: device) }
            NoteAttachments.shared.requestMissing(from: device)
            // Conflicts and other phones: whatever anyone is missing now goes out.
            if changedHere { for d in peers() { push(to: d) } }
        default: break
        }
    }

    /// Takes a note from a phone. Returns true when something here changed (other peers may need it).
    private func apply(_ incoming: Note, base: String?) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == incoming.id }) else {
            notes.append(incoming)
            return true
        }
        let local = notes[i]
        if local.rev == incoming.rev { return false }
        if base == local.rev {
            notes[i] = incoming
            return true
        }
        // Both changed since they last agreed: the later edit keeps the id (same time: the larger rev), the other
        // becomes a copy. Both sides make the identical copy (id from the losing rev), so it isn't duplicated.
        let incomingWins = (Note.ms(incoming.modified), incoming.rev) > (Note.ms(local.modified), local.rev)
        let (winner, loser) = incomingWins ? (incoming, local) : (local, incoming)
        notes[i] = winner
        if loser.deleted == nil, loser.text != winner.text {
            let copy = Note(id: Note.uuid3("conflict:\(loser.id):\(loser.rev)"), rev: loser.rev, text: loser.text,
                            pinned: loser.pinned, created: loser.created, modified: loser.modified)
            if !notes.contains(where: { $0.id == copy.id }) { notes.append(copy) }
        }
        AppModel.shared.log(.info, "Notes: \"\(winner.title)\" was changed on both sides; kept both versions")
        return true
    }

    // MARK: Storage

    private func purge() {
        let cutoff = Date().addingTimeInterval(-Self.trashDays)
        let gone = notes.filter { ($0.deleted ?? .distantFuture) < cutoff }.map(\.id)
        guard !gone.isEmpty else { return }
        notes.removeAll { gone.contains($0.id) }
        for k in acked.keys { gone.forEach { acked[k]?[$0] = nil } }
        save()
    }

    /// Written once changes pause for a second (and when the app quits), not on every edit.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: Any?

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.writeNow()
        }
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotesStore.shared.writeNow(sync: true) }
            }
        }
    }

    func writeNow(sync: Bool = false) {
        saveTask?.cancel(); saveTask = nil
        let saved = Saved(notes: notes, acked: acked)
        let url = Self.file
        let write = { if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) } }
        if sync { write() } else { Task.detached(priority: .utility) { write() } }
    }
}


/// Titles and previews, worked out once per version of a note (list rows asked for them on every render).
enum NoteSummary {
    private final class Box { let title: String, preview: String; init(_ t: String, _ p: String) { title = t; preview = p } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 1000; return c }()

    static func of(_ note: Note) -> (title: String, preview: String) {
        let key = (note.id + "#" + note.rev) as NSString
        if let b = cache.object(forKey: key) { return (b.title, b.preview) }
        var lines = note.text.split(separator: "\n", omittingEmptySubsequences: true).lazy
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.makeIterator()
        let first = lines.next().map(String.init) ?? ""
        let t = Markdown.plain(first)
        var preview = ""
        while preview.count < 200, let line = lines.next() {   // a row shows one line; no need for the whole note
            let p = Markdown.plain(String(line))
            if !p.isEmpty { preview += preview.isEmpty ? p : " " + p }
        }
        let box = Box(t.isEmpty ? "New Note" : t, preview)
        cache.setObject(box, forKey: key)
        return (box.title, box.preview)
    }
}
