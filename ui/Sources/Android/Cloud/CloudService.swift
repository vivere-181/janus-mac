import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import os

/// Janus Cloud on the Mac (shared/CLOUD.md): this Mac's keys, the relay connection, and the paired phones it can
/// reach through the relay when they aren't on the same network. Keys are exchanged only over the LAN pairing.
@MainActor @Observable
final class CloudService {
    static let shared = CloudService()

    enum Status: Equatable {
        case off                       // not set up
        case connecting
        case online
        case offline(String)           // can't reach the relay right now (retrying)
        case needsReconnect(String)    // the relay doesn't know this Mac any more: enrol again
    }

    struct Peer: Codable, Equatable {
        var kdeID: String              // the paired device (KDE Connect id)
        var cloudID: String
        var name: String
        var sign: String
        var box: String
        var ready = false              // registered with the relay and told so
    }

    private(set) var status: Status = .off
    /// Round trips to the relay in ms (Settings shows them, measured only while it's on screen): this Mac's, and
    /// each phone's as the relay last timed it (cloud id → ms; absent = not connected to the relay).
    private(set) var latency: Int?
    private(set) var peerLatency: [String: Int] = [:]
    private(set) var peers: [Peer] = []
    private(set) var relay: URL?
    var isSetUp: Bool { relay != nil }

    @ObservationIgnored private var identity: CloudCrypto.Identity?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketTask: Task<Void, Never>?
    @ObservationIgnored private var seen: [String: Date] = [:]
    @ObservationIgnored private var keys: [String: SymmetricKey] = [:]

    /// HTTP/2 to the relay; long-polls wait up to 25 s, so requests may take a while.
    @ObservationIgnored let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 3600
        c.httpMaximumConnectionsPerHost = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: Stored state (~/Library/Application Support/Android/Cloud, private to this user)

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }()
    private static var identityFile: URL { dir.appendingPathComponent("identity.json") }
    private static var stateFile: URL { dir.appendingPathComponent("state.json") }

    private struct Saved: Codable { var relay: URL?; var peers: [Peer] }
    private struct SavedIdentity: Codable { var sign: Data; var box: Data }

    private init() {
        if let data = try? Data(contentsOf: Self.stateFile), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            relay = s.relay; peers = s.peers
        }
        if let data = try? Data(contentsOf: Self.identityFile), let s = try? JSONDecoder().decode(SavedIdentity.self, from: data),
           let sign = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.sign),
           let box = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: s.box) {
            identity = .init(sign: sign, box: box)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(relay: relay, peers: peers)) { try? data.write(to: Self.stateFile, options: .atomic) }
    }

    /// The keys are made once and kept in a file only this user can read (like the engine's own private key).
    private func me() -> CloudCrypto.Identity {
        if let identity { return identity }
        let made = CloudCrypto.Identity.new()
        let saved = SavedIdentity(sign: made.sign.rawRepresentation, box: made.box.rawRepresentation)
        if let data = try? JSONEncoder().encode(saved) {
            FileManager.default.createFile(atPath: Self.identityFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        identity = made
        return made
    }

    var deviceID: String { me().id }

    // MARK: Setting up

    /// Settings → Cloud: enrol this Mac with the owner's invite (used once, not kept), then connect.
    func setUp(relay url: URL, invite: String) async throws {
        let me = me()
        self.relay = url
        let body: [String: Any] = ["invite": invite.trimmingCharacters(in: .whitespacesAndNewlines), "name": Host.current().localizedName ?? "Mac",
                                   "sign": me.signPublic, "box": me.boxPublic]
        let (_, res) = try await call("POST", "/v1/enroll", json: body, signedIn: false)
        guard res.statusCode == 200 else {
            self.relay = nil
            throw CloudError.message(res.statusCode == 403 ? "The invite isn't right." : "The relay answered \(res.statusCode).")
        }
        // A fresh start: phones are added again over the LAN.
        peers = peers.map { var p = $0; p.ready = false; return p }
        save()
        AppModel.shared.log(.success, "Janus Cloud set up on \(url.host() ?? url.absoluteString)")
        start()
        for d in AppModel.shared.connectedDevices { connected(d) }
    }

    /// Turns the cloud off here: the phones are told (over the LAN when they're connected) and removed from the relay.
    func turnOff() async {
        for p in peers {
            if let d = AppModel.shared.devices.first(where: { $0.id == p.kdeID }), d.isReachable { sendLAN(["op": "forget"], to: d) }
            _ = try? await call("DELETE", "/v1/devices/\(p.cloudID)")
        }
        _ = try? await call("DELETE", "/v1/devices/\(me().id)")
        stopSocket()
        peers = []; relay = nil; token = nil; keys = [:]
        status = .off
        save()
    }

    /// The app launched: connect if set up.
    func start() {
        guard relay != nil else { status = .off; return }
        watchForDeadConnections()
        startSocket()
    }

    @ObservationIgnored private var wakeObserver: Any?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: String?

    /// After sleep or a network change the socket is usually dead without having noticed (a receive can wait on it
    /// for hours): connect again at once instead.
    private func watchForDeadConnections() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudService.shared.reconnectNow("woke up") }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let key = path.status == .satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "none"
            Task { @MainActor in
                let svc = CloudService.shared
                defer { svc.lastPath = key }
                guard let previous = svc.lastPath, previous != key, key != "none" else { return }
                svc.reconnectNow("network changed")
            }
        }
        monitor.start(queue: DispatchQueue(label: "cloud.path", qos: .utility))
        pathMonitor = monitor
    }

    func reconnectNow(_ why: String) {
        guard relay != nil else { return }
        if case .needsReconnect = status { return }
        stopSocket()
        startSocket()
    }

    // MARK: Phones (key exchange over the LAN, §3)

    /// A TV is never reached through the cloud (R38); one linked before that rule is unlinked when it's next seen.
    func peer(forDevice kdeID: String) -> Peer? {
        guard AppModel.shared.devices.first(where: { $0.id == kdeID })?.isTV != true else { return nil }
        return peers.first { $0.kdeID == kdeID && $0.ready }
    }

    /// Whether a message to this phone can go through the cloud right now.
    func canReach(_ device: Device) -> Bool { status == .online && peer(forDevice: device.id) != nil }

    // MARK: Companion messages, text and actions (§13)

    /// Mac → phone commands that make sense remotely (the rest wait for the LAN).
    private static let cloudCommands: Set<String> = ["notes", "status", "ringer", "flashlight", "dnd", "macstate", "macaction", "calendar", "findmyphone"]
    /// Phone → Mac companion kinds accepted from the cloud.
    private static let cloudKinds = ["ge.connect.notes", "ge.connect.status", "ge.connect.ring", "ge.connect.dnd", "ge.connect.device",
                                     "ge.connect.ping", "ge.connect.calendar"]

    static func goesThroughCloud(_ command: String) -> Bool {
        cloudCommands.contains(String(command.prefix { $0 != ":" }))
    }

    func sendCompanion(_ command: String, to device: Device) {
        guard let p = peer(forDevice: device.id) else { return }
        Task { try? await send("c", ["cmd": command], to: p) }
    }

    func sendText(_ text: String, isLink: Bool, to device: Device) {
        guard let p = peer(forDevice: device.id) else { return }
        Task { try? await send("text", ["text": text, "link": isLink], to: p) }
    }

    /// The cloud came up: for each linked phone that isn't on the LAN, ask for its status and start notes sync.
    private func cameOnline() {
        for p in peers where p.ready {
            guard let d = AppModel.shared.devices.first(where: { $0.id == p.kdeID }), !d.isReachable else { continue }
            d.command("status")
            NotesStore.shared.connected(d)
        }
    }

    /// A paired phone connected over the LAN: offer it the cloud if it can do it and isn't set up yet.
    func connected(_ device: Device) {
        if device.isTV, let p = peers.first(where: { $0.kdeID == device.id }) {
            peers.removeAll { $0.kdeID == device.id }
            keys[p.cloudID] = nil
            save()
            Task { _ = try? await call("DELETE", "/v1/devices/\(p.cloudID)") }   // the TV drops its own keys
        }
        guard relay != nil, !device.isTV, device.supports("cloud"), DeviceTrust.isMine(device),
              peers.first(where: { $0.kdeID == device.id })?.ready != true else { return }
        let me = me()
        sendLAN(["op": "hello", "relay": relay!.absoluteString, "id": me.id, "name": Host.current().localizedName ?? "Mac",
                 "sign": me.signPublic, "box": me.boxPublic], to: device)
    }

    /// From the phone, over the LAN (`ge.connect.cloud:` companion notification).
    func receiveLAN(_ json: String, from device: Device) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        switch o["op"] as? String {
        case "hello":
            guard relay != nil, let sign = o["sign"] as? String, let box = o["box"] as? String,
                  let signRaw = Data(base64Encoded: sign), signRaw.count == 32, Data(base64Encoded: box)?.count == 32 else { return }
            let id = CloudCrypto.deviceID(sign: signRaw)
            guard (o["id"] as? String).map({ $0 == id }) ?? true else { return }   // the id must match the key
            var p = Peer(kdeID: device.id, cloudID: id, name: o["name"] as? String ?? device.name, sign: sign, box: box)
            peers.removeAll { $0.kdeID == device.id }
            peers.append(p)
            keys[id] = nil
            save()
            Task {
                do {
                    let (_, res) = try await call("POST", "/v1/devices", json: ["name": p.name, "sign": sign, "box": box])
                    guard res.statusCode == 200 else { throw CloudError.message("relay answered \(res.statusCode)") }
                    p.ready = true
                    if let i = peers.firstIndex(where: { $0.kdeID == device.id }) { peers[i] = p }
                    save()
                    sendLAN(["op": "ready", "relay": relay?.absoluteString ?? ""], to: device)
                    AppModel.shared.log(.success, "\(device.name) can now be reached through Janus Cloud")
                } catch {
                    AppModel.shared.log(.warning, "Couldn't add \(device.name) to Janus Cloud: \(error.localizedDescription)")
                }
            }
        case "forget":
            if let p = peers.first(where: { $0.kdeID == device.id }) {
                peers.removeAll { $0.kdeID == device.id }
                keys[p.cloudID] = nil
                save()
                Task { _ = try? await call("DELETE", "/v1/devices/\(p.cloudID)") }
            }
        default: break
        }
    }

    private func sendLAN(_ body: [String: Any], to device: Device) {
        guard let data = try? JSONSerialization.data(withJSONObject: body), let json = String(data: data, encoding: .utf8) else { return }
        device.command("cloud:" + json)
    }

    // MARK: Signing in and requests (§4, §9)

    enum CloudError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    private func signIn() async throws {
        let me = me()
        let ts = Int64(Date().timeIntervalSince1970)
        let (data, res) = try await call("POST", "/v1/auth", json: ["id": me.id, "ts": ts, "sig": try CloudCrypto.signIn(me, at: ts)], signedIn: false)
        if res.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["token"] as? String {
            token = t
            return
        }
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        switch code {
        case "unknown_device":
            status = .needsReconnect("The relay doesn't know this Mac any more. Set up Janus Cloud again.")
            stopSocket()
        case "clock":
            status = .offline("This Mac's clock is more than 5 minutes off.")
        default:
            status = .offline("Couldn't sign in (\(res.statusCode)).")
        }
        throw CloudError.message("sign-in refused: \(code ?? String(res.statusCode))")
    }

    /// One request to the relay. Signs in when needed (and once more on 401).
    func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, signedIn: Bool = true,
              headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let relay else { throw CloudError.message("Janus Cloud isn't set up.") }
        if signedIn, token == nil { try await signIn() }
        for attempt in 0..<2 {
            var req = URLRequest(url: relay.appending(path: path))
            req.httpMethod = method
            if let json {
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if let body {
                req.httpBody = body
            }
            if signedIn, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await session.data(for: req)
            guard let res = response as? HTTPURLResponse else { throw CloudError.message("no answer") }
            if res.statusCode == 401, signedIn, attempt == 0 { token = nil; try await signIn(); continue }
            return (data, res)
        }
        throw CloudError.message("not signed in")
    }

    // MARK: The live connection (§5, §9)

    private func stopSocket() {
        socketTask?.cancel(); socketTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    /// Connects and stays connected: reconnects with backoff (1, 2, 4… 60 s) after drops, deploys and sleep.
    private func startSocket() {
        guard socketTask == nil else { return }
        status = .connecting
        socketTask = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled {
                guard let self, self.relay != nil else { return }
                if case .needsReconnect = self.status { self.socketTask = nil; return }
                do {
                    try await self.runSocket()
                    delay = 1
                } catch {
                    if case .needsReconnect = self.status { self.socketTask = nil; return }
                    if case .offline = self.status {} else { self.status = .offline("Reconnecting…") }
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    private func runSocket() async throws {
        if token == nil { try await signIn() }
        guard let relay, let token, var comps = URLComponents(url: relay.appending(path: "/v1/ws"), resolvingAgainstBaseURL: false) else { return }
        comps.scheme = relay.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        socket = ws
        ws.resume()
        defer { if socket === ws { socket = nil } }
        // Connected once a ping comes back (the relay sends nothing until there's something for us). Receiving starts
        // at once: URLSession reads frames, the relay's own pings and our pong included, only while a receive waits.
        var online = false
        let confirm = Task { [weak self] in
            guard (try? await Self.ping(ws)) != nil, !Task.isCancelled, let self else { return }
            online = true
            self.status = .online
            self.cameOnline()
            // A light check every 2 minutes for a connection that died without a word (the relay's own pings keep
            // proxies and NAT open; this only notices a silent drop). No answer in 20 s: connect again.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120), tolerance: .seconds(30))
                if Task.isCancelled { return }
                let answered = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { (try? await Self.ping(ws)) != nil }
                    group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if !answered { ws.cancel(with: .abnormalClosure, reason: nil); return }
            }
        }
        defer { confirm.cancel() }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch {
                if !online { self.token = nil }   // a refused upgrade is usually an expired sign-in: sign in again
                throw error
            }
            guard case .string(let text) = message,
                  let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  o["type"] as? String == "message", let id = o["id"] as? String,
                  let from = o["from"] as? String, let box = o["box"] as? String else { continue }
            if handle(box: box, from: from) {
                try? await ws.send(.string(#"{"type":"ack","id":"\#(id)"}"#))
            }
        }
    }

    /// One measurement: a ping over the open connection (no new connection or handshake), and the relay's own
    /// figures for the phones.
    func measureLatency() async {
        guard let ws = socket, status == .online else { latency = nil; peerLatency = [:]; return }
        let start = Date()
        if (try? await Self.ping(ws)) != nil { latency = max(1, Int(Date().timeIntervalSince(start) * 1000)) }
        guard !peers.isEmpty, let (data, res) = try? await call("GET", "/v1/devices"), res.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var found: [String: Int] = [:]
        for d in list {
            if let id = d["id"] as? String, d["online"] as? Bool == true, let rtt = (d["rtt"] as? NSNumber)?.intValue { found[id] = rtt }
        }
        peerLatency = found
    }

    /// URLSession can call a ping's handler twice (when the connection drops with the ping pending), so only the
    /// first call resumes.
    private static func ping(_ ws: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            ws.sendPing { error in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                error.map { c.resume(throwing: $0) } ?? c.resume()
            }
        }
    }

    // MARK: Envelopes (§5)

    private func key(for peer: Peer) throws -> SymmetricKey {
        if let k = keys[peer.cloudID] { return k }
        guard let box = Data(base64Encoded: peer.box) else { throw CloudError.message("bad key") }
        let k = try CloudCrypto.pairKey(me(), peerBox: box, peerID: peer.cloudID)
        keys[peer.cloudID] = k
        return k
    }

    /// Seals and sends one envelope: `{"t": type, "id", "ts", …}`.
    func send(_ type: String, _ fields: [String: Any], to peer: Peer) async throws {
        var body = fields
        body["t"] = type
        body["id"] = UUID().uuidString.lowercased()
        body["ts"] = Int64(Date().timeIntervalSince1970 * 1000)
        let plaintext = try JSONSerialization.data(withJSONObject: body)
        let box = try CloudCrypto.seal(plaintext, key: key(for: peer), from: me().id, to: peer.cloudID)
        let (_, res) = try await call("POST", "/v1/messages", json: ["to": peer.cloudID, "box": box])
        guard res.statusCode == 200 else { throw CloudError.message("the relay answered \(res.statusCode)") }
    }

    /// Opens and handles an envelope. Returns whether it can be acknowledged (handled, or never readable).
    private func handle(box: String, from: String) -> Bool {
        guard let peer = peers.first(where: { $0.cloudID == from && $0.ready }),
              let plaintext = try? CloudCrypto.open(box, key: key(for: peer), from: from, to: me().id),
              let o = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let type = o["t"] as? String, let id = o["id"] as? String else {
            AppModel.shared.log(.warning, "Janus Cloud: a message that couldn't be opened was dropped")
            return true
        }
        // Each envelope once, and nothing older than 72 hours.
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 72 * 3600 }
        let ts = (o["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? now
        guard seen[id] == nil, now.timeIntervalSince(ts) < 72 * 3600 else { return true }
        seen[id] = now
        let device = AppModel.shared.devices.first { $0.id == peer.kdeID }
        switch type {
        case "c":
            // As if the phone's companion notification had arrived (only the kinds allowed remotely).
            guard let device, let cid = o["nid"] as? String, let text = o["text"] as? String,
                  Self.cloudKinds.contains(where: { cid.hasPrefix($0) }) else { break }
            var n = PhoneNotification(id: "cloud." + id)
            n.internalId = cid
            n.text = text
            device.companion(n, isNew: true, via: "cloud")
            // The phone sends its status when its cloud connection comes up (like a new LAN connection): the cue to
            // start notes sync with it (NotesStore says hello once per 10 s at most).
            if cid.hasPrefix(PhoneNotification.statusPrefix), !device.isReachable { NotesStore.shared.connected(device) }
        case "text":
            guard let device, let text = o["text"] as? String, !text.isEmpty else { break }
            if o["link"] as? Bool == true, let url = URL(string: text), url.scheme.map({ ["http", "https"].contains($0) }) == true {
                TransferStore.shared.received(url, device: device)
                Notifier.shared.received(url, device: device)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                var t = Transfer(direction: .received, kind: .text, deviceID: device.id, deviceName: device.name, text: text,
                                 name: String(text.prefix(80)), state: .done)
                t.viaCloud = true
                TransferStore.shared.add(t)
                Notifier.shared.receivedText(text, device: device)
            }
        case "action":
            if let device, let name = o["name"] as? String { MacActions.perform(name, deviceID: device.id) }
        case "file": CloudTransfers.shared.receive(offer: o, from: peer)
        case "file-done": if let blob = o["blob"] as? String { CloudTransfers.shared.delivered(blob: blob) }
        case "file-cancel": if let blob = o["blob"] as? String { CloudTransfers.shared.cancelled(blob: blob) }
        default: break
        }
        return true
    }

    // MARK: Testing aid

    /// Removes a test peer from the relay and here, without telling any phone (debug hook only).
    func testRemovePeer(kdeID: String) async {
        guard let p = peers.first(where: { $0.kdeID == kdeID }) else { return }
        _ = try? await call("DELETE", "/v1/devices/\(p.cloudID)")
        peers.removeAll { $0.kdeID == kdeID }
        keys[p.cloudID] = nil
        save()
    }

    /// As if a phone had said hello over the LAN (debug hook only).
    func testAddPeer(kdeID: String, name: String, sign: String, box: String) async throws {
        guard let signRaw = Data(base64Encoded: sign) else { return }
        let id = CloudCrypto.deviceID(sign: signRaw)
        let (_, res) = try await call("POST", "/v1/devices", json: ["name": name, "sign": sign, "box": box])
        guard res.statusCode == 200 else { throw CloudError.message("add: \(res.statusCode)") }
        peers.removeAll { $0.kdeID == kdeID }
        peers.append(Peer(kdeID: kdeID, cloudID: id, name: name, sign: sign, box: box, ready: true))
        keys[id] = nil
        save()
    }
}
