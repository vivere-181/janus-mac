import CryptoKit
import Foundation
import JanusLink
import KDEConnectKit

/// Janus's own connection engine (R40): the KDE Connect protocol (JanusLink) inside the app, answering the same calls
/// and sending the same signals as KDE's daemon did over D-Bus, so the app works unchanged on either engine.
///
/// All state lives on one serial queue. Calls come in through `EngineBus`; signals go out to the app's handler.
public final class NativeEngine: EngineBus, @unchecked Sendable {
    public static let service = "org.kde.kdeconnect"
    static let daemonPath = "/modules/kdeconnect"
    static let daemonInterface = "org.kde.kdeconnect.daemon"
    static let deviceInterface = "org.kde.kdeconnect.device"

    let queue = DispatchQueue(label: "janus.engine", qos: .userInitiated)
    private var handlers: [UUID: EngineBus.SignalHandler] = [:]
    private let handlerLock = NSLock()
    public var onClose: (@Sendable () -> Void)?
    public private(set) var isConnected = false

    let me: LocalIdentity
    let trust = TrustStore()
    private(set) var provider: LinkProvider!
    var devices: [String: NativeDevice] = [:]
    /// What happened, for the app's debug log.
    public var log: ((String) -> Void)?

    private init(identity: LocalIdentity) {
        me = identity
    }

    /// Starts the engine with this Mac's existing identity (KDE's certificate and key, so pairings carry over).
    public static func start(log: ((String) -> Void)? = nil) throws -> NativeEngine {
        let identity = try LocalIdentity.load(type: "laptop", incoming: Capabilities.incoming, outgoing: Capabilities.outgoing)
        let engine = NativeEngine(identity: identity)
        engine.log = log
        try engine.queue.sync {
            for d in engine.trust.all() { engine.devices[d.id] = NativeDevice(trusted: d, engine: engine) }
            let provider = LinkProvider(identity: identity, trust: engine.trust)
            provider.log = { [weak engine] in engine?.log?($0) }
            provider.onLink = { [weak engine] link in engine?.queue.async { engine?.attach(link) } }
            try provider.start()
            engine.provider = provider
            engine.isConnected = true
        }
        log?("native engine started as \(identity.name) (\(identity.deviceID)), TCP \(engine.provider.tcpPort)")
        return engine
    }

    public func shutdown() {
        queue.sync {
            guard isConnected else { return }
            isConnected = false
            devices.values.forEach { $0.link?.close() }
            provider?.stop()
        }
        onClose?()
    }

    // MARK: Links

    private func attach(_ link: Link) {
        let id = link.peer.deviceID
        let device = devices[id] ?? {
            let d = NativeDevice(id: id, engine: self)
            devices[id] = d
            emit(Self.daemonPath, Self.daemonInterface, "deviceAdded", [.string(id)])
            return d
        }()
        device.attach(link)
        emit(Self.daemonPath, Self.daemonInterface, "deviceVisibilityChanged", [.string(id), .bool(true)])
        emit(Self.daemonPath, Self.daemonInterface, "deviceListChanged", [])
    }

    /// A device's link ended (called by the device on the engine's queue).
    func detached(_ device: NativeDevice) {
        emit(Self.daemonPath, Self.daemonInterface, "deviceVisibilityChanged", [.string(device.id), .bool(false)])
        if !device.isPaired {
            devices[device.id] = nil
            emit(Self.daemonPath, Self.daemonInterface, "deviceRemoved", [.string(device.id)])
        }
        emit(Self.daemonPath, Self.daemonInterface, "deviceListChanged", [])
    }

    // MARK: Signals

    @discardableResult
    public func addSignalHandler(_ handler: @escaping EngineBus.SignalHandler) -> UUID {
        let id = UUID()
        handlerLock.lock(); handlers[id] = handler; handlerLock.unlock()
        return id
    }

    func emit(_ path: String, _ interface: String, _ member: String, _ body: [DBusValue]) {
        var m = DBusMessage(kind: .signal)
        m.path = path; m.interface = interface; m.member = member; m.body = body; m.sender = Self.service
        handlerLock.lock(); let hs = Array(handlers.values); handlerLock.unlock()
        hs.forEach { $0(m) }
    }

    // MARK: Calls

    public func call(destination: String, path: String, interface: String, member: String, _ args: [DBusValue]) async throws -> [DBusValue] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.handle(path: path, interface: interface, member: member, args)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public func send(destination: String, path: String, interface: String, member: String, _ args: [DBusValue]) {
        queue.async { _ = try? self.handle(path: path, interface: interface, member: member, args) }
    }

    private func handle(path: String, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        switch interface {
        case "org.freedesktop.DBus":
            switch member {
            case "NameHasOwner": return [.bool(args.first?.string == Self.service && isConnected)]
            case "Hello": return [.string(":native")]
            default: return []   // AddMatch: every signal goes to every handler anyway
            }
        case "org.freedesktop.DBus.Properties":
            let target = args.first?.string ?? ""
            let props = try properties(path: path, interface: target)
            switch member {
            case "GetAll": return [.dict(key: "s", value: "v", props.map { (.string($0.key), .variant($0.value)) })]
            case "Get":
                guard let name = args.dropFirst().first?.string, let v = props[name] else { throw Self.unknown("property") }
                return [.variant(v)]
            case "Set":
                guard let name = args.dropFirst().first?.string, let v = args.dropFirst(2).first?.unwrapped else { throw Self.unknown("property") }
                try setProperty(path: path, interface: target, name: name, value: v)
                return []
            default: throw Self.unknown(member)
            }
        default:
            if path == Self.daemonPath { return try daemon(member, args) }
            let (device, sub) = try route(path)
            return try device.call(sub: sub, interface: interface, member: member, args)
        }
    }

    private func route(_ path: String) throws -> (NativeDevice, String?) {
        let prefix = Self.daemonPath + "/devices/"
        guard path.hasPrefix(prefix) else { throw Self.unknown("object \(path)") }
        let rest = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let device = devices[rest[0]] else { throw Self.unknown("device \(rest[0])") }
        return (device, rest.count > 1 ? rest[1] : nil)
    }

    private func properties(path: String, interface: String) throws -> [String: DBusValue] {
        if path == Self.daemonPath {
            return ["customDevices": .strings(customDevices)]
        }
        let (device, sub) = try route(path)
        return try device.properties(sub: sub, interface: interface)
    }

    private func setProperty(path: String, interface: String, name: String, value: DBusValue) throws {
        if path == Self.daemonPath, name == "customDevices" {
            customDevices = value.strings ?? []
            provider.broadcast(to: customDevices)
            return
        }
        let (device, sub) = try route(path)
        try device.setProperty(sub: sub, interface: interface, name: name, value: value)
    }

    /// Addresses the owner added by hand (devices on other subnets); announced to on every refresh.
    private var customDevices: [String] {
        get { UserDefaults.standard.stringArray(forKey: "engine.customDevices") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "engine.customDevices") }
    }

    private func daemon(_ member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        switch member {
        case "devices":
            let onlyReachable = args.first?.bool ?? false, onlyPaired = args.dropFirst().first?.bool ?? false
            return [.strings(devices.values.filter { (!onlyReachable || $0.isReachable) && (!onlyPaired || $0.isPaired) }.map(\.id).sorted())]
        case "announcedName":
            return [.string(me.name)]
        case "setAnnouncedName":
            // The name goes out with the next identity (each new connection); KDE's config keeps it for both engines.
            if let n = args.first?.string, !n.isEmpty { Self.saveName(n) }
            emit(Self.daemonPath, Self.daemonInterface, "announcedNameChanged", [.string(args.first?.string ?? me.name)])
            return []
        case "linkProviders":
            return [.strings(["Wi-Fi|LanLinkProvider|enabled"])]
        case "setLinkProviderState":
            return []
        case "forceOnNetworkChange":
            // The app asks often (its watchdog looks for devices that aren't back): call only those, directly. A
            // broadcast would make every connected device reconnect. Real network changes the provider sees itself.
            provider.callUnlinked()
            if !customDevices.isEmpty { provider.broadcast(to: customDevices) }
            return []
        case "janusPairingURI":
            return [.string(makePairingOffer())]
        case "janusEndPairingOffer":
            offer = nil
            return []
        case "pairingRequests":
            return [.strings(devices.values.filter { $0.pairing?.state == .requestedByPeer }.map(\.id))]
        default:
            throw Self.unknown(member)
        }
    }

    // MARK: QR pairing (R41)

    private var offer: (code: String, expires: Date)?

    /// A fresh single-use code (valid 10 minutes) and the link for the QR: this Mac's id, name, addresses, port and
    /// certificate fingerprint, so the phone connects straight here and knows it reached the right Mac.
    private func makePairingOffer() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        let code = Self.base64url(Data(bytes))
        offer = (code, Date().addingTimeInterval(600))
        var c = URLComponents()
        c.scheme = "janus"; c.host = "pair"
        c.queryItems = [
            .init(name: "v", value: "1"), .init(name: "id", value: me.deviceID), .init(name: "name", value: me.name),
            .init(name: "addr", value: Self.localIPv4().joined(separator: ",")), .init(name: "port", value: String(provider.tcpPort)),
            .init(name: "fp", value: Self.base64url(Data(SHA256.hash(data: me.certificateDER)))), .init(name: "code", value: code),
        ]
        return c.url?.absoluteString ?? ""
    }

    /// A pairing request's code: right, and still valid? Used up either way when right.
    func consumePairingCode(_ code: String) -> Bool {
        guard let o = offer, o.expires > Date(), o.code == code else { return false }
        offer = nil
        return true
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// This Mac's IPv4 addresses on its networks (Wi-Fi, Ethernet), loopback and link-local left out.
    static func localIPv4() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0,
                  i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if !ip.hasPrefix("169.254."), !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    static func saveName(_ name: String) {
        let file = LocalIdentity.folder.appendingPathComponent("config")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? "[General]\n"
        if let r = text.range(of: "(?m)^name=.*$", options: .regularExpression) { text.replaceSubrange(r, with: "name=\(name)") }
        else { text = text.replacingOccurrences(of: "[General]\n", with: "[General]\nname=\(name)\n") }
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    static func unknown(_ what: String) -> DBusError {
        DBusError(name: "org.freedesktop.DBus.Error.UnknownMethod", message: "Native engine: no \(what)")
    }
}
