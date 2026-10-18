import AppKit
import Darwin
import KDEConnectKit
import Observation

/// One file, link or text sent to or received from a phone (Blip-style feed).
struct Transfer: Identifiable, Codable, Equatable {
    enum Direction: String, Codable { case sent, received }
    enum Kind: String, Codable { case file, link, text }
    enum State: String, Codable { case inProgress, done, failed }

    var id = UUID()
    var direction: Direction
    var kind: Kind
    var deviceID: String
    var deviceName: String
    var url: URL?              // file URL or web link
    var text: String?          // for text shares
    var name: String
    var size: Int64?           // total bytes, when known
    var bytesDone: Int64 = 0
    var speed: Double = 0      // bytes per second
    var state: State = .inProgress
    var date = Date()
    /// Incoming batches announced by our phone app: shared id and total size of all files in it.
    var batchID: UUID?
    var batchTotal: Int64?
    /// Extra line shown in the receive popup, e.g. "Screenshot · copied to clipboard".
    var note: String?
    /// Went through Janus Cloud (the devices weren't on the same network).
    var viaCloud: Bool?
    /// Sent to the cloud, not yet taken by the phone (it's away; kept up to 72 hours).
    var awaitingPickup: Bool?

    var progress: Double? {
        guard let size, size > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(size))
    }
}

/// The feed: persisted (last 100) and fed live by `TransferMonitor`.
@MainActor @Observable
final class TransferStore {
    static let shared = TransferStore()
    private(set) var items: [Transfer] = []
    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transfers.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Transfer].self, from: data) {
            // Anything still "in progress" from a previous run didn't finish while we watched.
            items = saved.map { var t = $0; if t.state == .inProgress { t.state = .failed }; return t }
        }
        TransferMonitor.shared.start()
    }

    var active: [Transfer] { items.filter { $0.state == .inProgress } }

    // MARK: Screenshots from the phone

    @ObservationIgnored private var pendingScreenshots: [(name: String, at: Date)] = []

    func expectScreenshot(named name: String, from device: Device) {
        pendingScreenshots.removeAll { Date().timeIntervalSince($0.at) > 120 }
        pendingScreenshots.append((name.trimmingCharacters(in: .whitespacesAndNewlines), Date()))
    }

    /// "Screenshot_1.png" also matches "Screenshot_1 (1).png" (the engine renames duplicates).
    private func takeScreenshotMatch(_ fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        guard let i = pendingScreenshots.firstIndex(where: { ($0.name as NSString).deletingPathExtension == base }) else { return false }
        pendingScreenshots.remove(at: i)
        return true
    }

    // MARK: Incoming batches (phone announces total size first)

    struct Batch { let id: UUID; var total: Int64; var files: Int; var announced: Date; let deviceID: String }
    @ObservationIgnored private(set) var pendingBatch: Batch?

    func expectIncoming(totalBytes: Int64, files: Int, device: Device) {
        TransferMonitor.shared.activate()
        // More files joining a running send: the latest announcement updates the same batch.
        if var b = pendingBatch, b.deviceID == device.id,
           Date().timeIntervalSince(b.announced) < 30 || items.contains(where: { $0.batchID == b.id && $0.state == .inProgress }) {
            b.total = totalBytes; b.files = files; b.announced = Date()
            pendingBatch = b
            for i in items.indices where items[i].batchID == b.id { items[i].batchTotal = totalBytes }
        } else {
            pendingBatch = Batch(id: UUID(), total: totalBytes, files: files, announced: Date(), deviceID: device.id)
        }
    }

    /// Attaches a newly detected incoming file to the announced batch, if it belongs to one.
    func attachToBatch(_ t: inout Transfer) {
        guard let b = pendingBatch, Date().timeIntervalSince(b.announced) < 120,
              items.filter({ $0.batchID == b.id }).count < b.files else { return }
        t.batchID = b.id
        t.batchTotal = b.total
        if b.files == 1 { t.size = b.total }
    }

    /// Progress for a card: per file when its size is known, else the whole announced batch.
    func progress(for t: Transfer) -> Double? {
        if let p = t.progress { return p }
        guard let id = t.batchID, let total = t.batchTotal, total > 0 else { return nil }
        let done = items.filter { $0.batchID == id }.reduce(Int64(0)) { $0 + ($1.state == .done ? ($1.size ?? $1.bytesDone) : $1.bytesDone) }
        return min(1, Double(done) / Double(total))
    }

    func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[i].state
        change(&items[i])
        if before != items[i].state || items[i].state != .inProgress { save() }
        if before == .inProgress, items[i].state != .inProgress { finished(items[i]) }
    }

    @ObservationIgnored private var lastReceiveSound = Date.distantPast

    /// One sound when received files are in (done or failed): once per batch, after the last file.
    private func finished(_ t: Transfer) {
        guard t.direction == .received, t.kind == .file else { return }
        if let b = t.batchID {
            let batch = items.filter { $0.batchID == b }
            if batch.contains(where: { $0.state == .inProgress }) { return }
            // The phone announced more files than have started yet.
            if let pending = pendingBatch, pending.id == b, batch.count < pending.files,
               Date().timeIntervalSince(pending.announced) < 120 { return }
        }
        // Files without an announcement arrive back to back: one sound for the lot.
        guard Date().timeIntervalSince(lastReceiveSound) > 3 else { return }
        lastReceiveSound = Date()
        Sounds.play(Sounds.alert)
    }

    func add(_ t: Transfer) {
        items.insert(t, at: 0)
        if items.count > 100 { items.removeLast(items.count - 100) }
        save()
        if t.state != .inProgress { finished(t) }
    }

    /// Developer hook: show sample items without touching the saved history.
    func injectSamples(_ samples: [Transfer]) { items = samples + items }

    func remove(_ t: Transfer) { items.removeAll { $0.id == t.id }; save() }
    func clear(_ direction: Transfer.Direction?) {
        items.removeAll { $0.state != .inProgress && (direction == nil || $0.direction == direction) }
        save()
    }

    private func save() {
        let snapshot = items
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Events

    func beginSend(_ urls: [URL], device: Device) {
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            var t = Transfer(direction: .sent, kind: .file, deviceID: device.id, deviceName: device.name,
                             url: url, name: url.lastPathComponent, size: size)
            if !device.isReachable { t.state = .failed }
            add(t)
        }
        TransferMonitor.shared.expectSends()
    }

    func sentText(_ text: String, isLink: Bool, device: Device) {
        add(Transfer(direction: .sent, kind: isLink ? .link : .text, deviceID: device.id, deviceName: device.name,
                     url: isLink ? URL(string: text) : nil, text: isLink ? nil : text,
                     name: isLink ? (URL(string: text)?.host() ?? text) : String(text.prefix(80)),
                     state: device.isReachable ? .done : .failed))
    }

    /// The engine finished receiving a file (or a link) from the phone.
    func received(_ url: URL, device: Device) {
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            let id: UUID
            if let t = items.first(where: { $0.direction == .received && $0.url?.standardizedFileURL.path == path && $0.state == .inProgress }) {
                update(t.id) { $0.state = .done; $0.size = size ?? $0.size; $0.bytesDone = size ?? $0.bytesDone; $0.speed = 0 }
                id = t.id
            } else {
                let t = Transfer(direction: .received, kind: .file, deviceID: device.id, deviceName: device.name,
                                 url: url, name: url.lastPathComponent, size: size, bytesDone: size ?? 0, state: .done)
                add(t)
                id = t.id
            }
            if takeScreenshotMatch(url.lastPathComponent) {
                let result = ScreenshotHandler.handle(url)
                update(id) { $0.note = result.note; if let moved = result.url { $0.url = moved; $0.name = moved.lastPathComponent } }
            }
            ReceivePopup.shared.show(id)
        } else {
            add(Transfer(direction: .received, kind: .link, deviceID: device.id, deviceName: device.name,
                         url: url, name: url.host() ?? url.absoluteString, state: .done))
        }
    }
}

/// Watches the engine's open files: files it reads are being sent, files it writes outside
/// ~/Library are being received. The file offset gives exact progress and speed.
@MainActor
final class TransferMonitor {
    static let shared = TransferMonitor()
    private var timer: Timer?
    private var lastOffsets: [String: (offset: Int64, time: TimeInterval)] = [:]
    private var seenSending: Set<String> = []
    private var sendQueuedAt: [UUID: Date] = [:]
    private var receivingSince: [String: Date] = [:]
    private var interval: TimeInterval = 0
    private var quietSince: Date?
    private var downloadsWatch: FSEventStreamRef?

    /// Asleep until a transfer can happen: a send from this Mac, the phone announcing files, or something being
    /// written to Downloads (macOS reports that; nothing is polled while idle). Then it samples the engine's open files
    /// (progress, speed) and goes back to sleep 10 s after the last transfer.
    func start() {
        guard downloadsWatch == nil else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { TransferMonitor.shared.activate() } }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [downloads] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        downloadsWatch = stream
    }

    /// Something may be transferring: sample every second (every 0.3 s while this Mac sends).
    func activate(fast: Bool = false) {
        quietSince = nil
        schedule(interval: fast ? 0.3 : max(interval == 0 ? 1.0 : interval, fast ? 0.3 : 0))
    }

    func expectSends() { activate(fast: true) }

    private func schedule(interval: TimeInterval) {
        guard interval != self.interval || timer == nil else { return }
        self.interval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2   // lets macOS group the wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sleep() {
        timer?.invalidate(); timer = nil; interval = 0; quietSince = nil
    }

    private func tick() {
        let store = TransferStore.shared
        // The engine's open files: it runs inside this app (R40).
        let pid = getpid()
        let now = ProcessInfo.processInfo.systemUptime
        let open = Self.openFiles(pid: pid)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var openPaths = Set<String>()

        for f in open {
            let path = URL(fileURLWithPath: f.path).standardizedFileURL.path
            openPaths.insert(path)
            let speed: Double = {
                guard let last = lastOffsets[path], now > last.time else { return 0 }
                return Double(f.offset - last.offset) / (now - last.time)
            }()
            lastOffsets[path] = (f.offset, now)

            if f.writing {
                guard !path.hasPrefix(home + "/Library"), !path.hasPrefix("/private"), !path.hasPrefix("/dev") else { continue }
                // Incoming file from the phone.
                if let t = store.items.first(where: { $0.direction == .received && $0.state == .inProgress && $0.url?.path == path }) {
                    store.update(t.id) { $0.bytesDone = max($0.bytesDone, f.offset); if speed > 0 { $0.speed = smooth($0.speed, speed) } }
                } else if receivingSince[path] == nil, !NoteAttachments.shared.isIncoming((path as NSString).lastPathComponent) {
                    receivingSince[path] = Date()
                    // The phone that just announced a transfer; else the only connected phone sharing files with us.
                    let model = AppModel.shared
                    let announced = store.pendingBatch.flatMap { b in model.devices.first { $0.id == b.deviceID } }
                    let device = announced ?? model.connectedDevices.first { $0.has("share") && DeviceTrust.isMine($0) }
                        ?? model.connectedDevices.first
                    var t = Transfer(direction: .received, kind: .file, deviceID: device?.id ?? "", deviceName: device?.name ?? "Phone",
                                     url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, bytesDone: f.offset)
                    store.attachToBatch(&t)
                    store.add(t)
                    ReceivePopup.shared.show(t.id)
                    expectSends()
                }
            } else if let t = store.items.first(where: { $0.direction == .sent && $0.state == .inProgress && $0.url?.standardizedFileURL.path == path }) {
                // Outgoing file being read by the engine.
                seenSending.insert(path)
                store.update(t.id) { $0.bytesDone = max($0.bytesDone, f.offset); if speed > 0 { $0.speed = smooth($0.speed, speed) } }
            }
        }

        // Sends: done once the engine has read the whole file and closed it.
        for t in store.active where t.direction == .sent {
            guard let path = t.url?.standardizedFileURL.path else { continue }
            let queued = sendQueuedAt[t.id] ?? { sendQueuedAt[t.id] = Date(); return Date() }()
            if openPaths.contains(path) { continue }
            if seenSending.contains(path) {
                // The engine finished with the file. Fast sends often complete between two samples, so
                // the last offset we saw says nothing; what matters is whether the phone stayed connected.
                let stillConnected = AppModel.shared.devices.first { $0.id == t.deviceID }?.isReachable ?? false
                store.update(t.id) {
                    $0.state = stillConnected ? .done : .failed
                    if stillConnected { $0.bytesDone = $0.size ?? $0.bytesDone }
                    $0.speed = 0
                }
                seenSending.remove(path); lastOffsets[path] = nil; sendQueuedAt[t.id] = nil
            } else if Date().timeIntervalSince(queued) > 8, (t.size ?? 0) < 4_000_000 {
                // Small files can be read and closed between two checks.
                store.update(t.id) { $0.state = .done; $0.bytesDone = $0.size ?? 0; $0.speed = 0 }
                sendQueuedAt[t.id] = nil
            } else if Date().timeIntervalSince(queued) > 120 {
                store.update(t.id) { $0.state = .failed; $0.speed = 0 }
                sendQueuedAt[t.id] = nil
            }
        }
        // Receives: the engine reports completion (shareReceived). If the file closes without it, it failed.
        for t in store.active where t.direction == .received {
            guard let path = t.url?.path, !openPaths.contains(path) else { continue }
            let since = receivingSince[path] ?? Date()
            if Date().timeIntervalSince(since) > 3, lastOffsets[path].map({ now - $0.time > 6 }) ?? true {
                let exists = FileManager.default.fileExists(atPath: path)
                store.update(t.id) { $0.state = exists ? .done : .failed; $0.speed = 0 }
                receivingSince[path] = nil; lastOffsets[path] = nil
            }
        }
        // Nothing moving (no transfer in progress, the engine writing nothing to Downloads or elsewhere): back to sleep
        // after 10 quiet seconds.
        let writing = open.contains { $0.writing && !$0.path.hasPrefix(home + "/Library") && !$0.path.hasPrefix("/private") && !$0.path.hasPrefix("/dev") }
        if store.active.isEmpty && !writing {
            if let q = quietSince { if Date().timeIntervalSince(q) > 10 { sleep() } } else { quietSince = Date() }
            if interval < 1, timer != nil { schedule(interval: 1.0) }
        } else {
            quietSince = nil
        }
    }

    private func smooth(_ old: Double, _ new: Double) -> Double { old == 0 ? new : old * 0.6 + new * 0.4 }

    /// Regular files a process has open, with the current offset (same user; no special permission).
    static func openFiles(pid: pid_t) -> [(path: String, offset: Int64, writing: Bool)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)) / MemoryLayout<proc_fdinfo>.stride
        var out: [(String, Int64, Bool)] = []
        for fd in fds.prefix(got) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = withUnsafePointer(to: info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !path.isEmpty, !path.contains(".app/Contents/") else { continue }
            out.append((path, info.pfi.fi_offset, (Int32(info.pfi.fi_openflags) & FWRITE) != 0))
        }
        return out
    }
}
