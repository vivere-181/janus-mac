import AppKit
import CryptoKit
import Foundation

/// Files in notes (R30): stored once per content hash as `<sha256>.<ext>`, referenced from the text as
/// `![name](attachments/<sha>.<ext>)`, and synced through the normal KDE share, one file at a time.
@MainActor @Observable
final class NoteAttachments {
    static let shared = NoteAttachments()
    static let maxSize: Int64 = 50 * 1024 * 1024
    static let namePattern = #"^[0-9a-f]{64}\.[a-z0-9]{1,8}$"#

    /// Bumped when a file arrives, so notes showing a placeholder redraw.
    private(set) var version = 0

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/NoteAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    // MARK: Adding

    /// Copies a file in and returns its line for the note (nil: too big or unreadable).
    func add(_ source: URL) async -> String? {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.maxSize, let sha = await Self.sha256(source) else {
            AppModel.shared.log(.warning, "Couldn't attach \(source.lastPathComponent): files can be up to 50 MB")
            return nil
        }
        let ext = source.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
        let name = sha + "." + (ext.isEmpty ? "bin" : ext)
        if !Self.has(name) { try? FileManager.default.copyItem(at: source, to: Self.url(name)) }
        let label = source.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
        return "![\(label)](attachments/\(name))"
    }

    /// An image from the clipboard (a screenshot, a copied picture) as a PNG attachment.
    func add(image: NSImage) async -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted Image \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png")
        try? png.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return await add(tmp)
    }

    nonisolated static func sha256(_ url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: What notes need

    /// Every attachment any note refers to (Recently Deleted included).
    static func referenced(in notes: [Note]) -> Set<String> {
        var out = Set<String>()
        let re = try! NSRegularExpression(pattern: #"\]\(attachments/([0-9a-f]{64}\.[a-z0-9]{1,8})\)"#)
        for n in notes {
            let ns = n.text as NSString
            re.enumerateMatches(in: n.text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m { out.insert(ns.substring(with: m.range(at: 1))) }
            }
        }
        return out
    }

    func missing() -> [String] {
        Self.referenced(in: NotesStore.shared.notes).filter { !Self.has($0) }.sorted()
    }

    // MARK: Sync (ops want / file / have on ge.connect.notes)

    /// Announced by a phone (`file`), so the share that follows comes here instead of Downloads.
    private var expected: [String: Date] = [:]
    /// Per phone: files it asked for, sent one at a time (the next after its `have`).
    private var queue: [String: [String]] = [:]
    private var sending: [String: (name: String, since: Date)] = [:]

    func expect(_ name: String) { expected[name] = .now }

    /// Is this incoming file (by name) one of ours? Asked while it's still arriving, to keep it out of Transfers.
    func isIncoming(_ fileName: String) -> Bool {
        let name = Self.normalized(fileName)
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else { return false }
        if let t = expected[name], Date().timeIntervalSince(t) < 600 { return true }
        return Self.referenced(in: NotesStore.shared.notes).contains(name)
    }

    /// A file the engine received: an attachment is checked and filed away (true), anything else goes on as usual.
    func take(_ url: URL, from device: Device) -> Bool {
        let name = Self.normalized(url.lastPathComponent)
        guard isIncoming(url.lastPathComponent) else { return false }
        expected[name] = nil
        Task {
            let sha = await Self.sha256(url)
            if UserDefaults.standard.bool(forKey: "debugSnapshots") { debugLog("attachment arrived \(name.prefix(8)): hash \(sha.map { name.hasPrefix($0 + ".") ? "ok" : "MISMATCH" } ?? "unreadable")") }
            if sha.map({ name.hasPrefix($0 + ".") }) == true {
                if !Self.has(name) { try? FileManager.default.moveItem(at: url, to: Self.url(name)) } else { try? FileManager.default.removeItem(at: url) }
                version += 1
                NotesStore.shared.send(["v": 1, "op": "have", "files": [name]], to: device)
            } else {
                // Damaged on the way: asked for again at the next hello.
                try? FileManager.default.removeItem(at: url)
                AppModel.shared.log(.warning, "Notes: a file from \(device.name) arrived damaged; it'll be fetched again")
            }
        }
        return true
    }

    /// "(1)" etc. that a download folder adds to a name that's already there.
    private static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)(?=\.[a-z0-9]{1,8}$)"#, with: "", options: .regularExpression).lowercased()
    }

    /// Ask the phone for what we're missing (after a push, and on hello).
    func requestMissing(from device: Device) {
        let names = missing()
        guard !names.isEmpty else { return }
        NotesStore.shared.send(["v": 1, "op": "want", "files": names], to: device)
    }

    func wanted(_ names: [String], by device: Device) {
        let mine = names.filter(Self.has)
        var q = queue[device.id] ?? []
        for n in mine where !q.contains(n) { q.append(n) }
        queue[device.id] = q
        sendNext(to: device)
    }

    func had(_ names: [String], by device: Device) {
        if let s = sending[device.id], names.contains(s.name) { sending[device.id] = nil }
        queue[device.id]?.removeAll { names.contains($0) }
        sendNext(to: device)
    }

    private func sendNext(to device: Device) {
        // One at a time; a send that got no answer in 5 minutes counts as lost (asked for again later).
        if let s = sending[device.id], Date().timeIntervalSince(s.since) < 300 { return }
        guard var q = queue[device.id], !q.isEmpty else { sending[device.id] = nil; return }
        let name = q.removeFirst()
        queue[device.id] = q
        let url = Self.url(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        sending[device.id] = (name, .now)
        NotesStore.shared.send(["v": 1, "op": "file", "name": name, "size": size], to: device)
        device.shareQuietly([url])
    }

    // MARK: Cleanup

    /// Files no note refers to any more (Recently Deleted included) go 30 days after they stopped being used.
    func cleanUp() {
        let used = Self.referenced(in: NotesStore.shared.notes)
        var since = (UserDefaults.standard.dictionary(forKey: "notes.unusedSince") as? [String: Date]) ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path)) ?? []
        for f in files {
            if used.contains(f) { since[f] = nil; continue }
            let first = since[f] ?? .now
            since[f] = first
            if Date().timeIntervalSince(first) > 30 * 24 * 3600 { try? FileManager.default.removeItem(at: Self.url(f)); since[f] = nil }
        }
        since = since.filter { files.contains($0.key) }
        UserDefaults.standard.set(since, forKey: "notes.unusedSince")
    }
}
