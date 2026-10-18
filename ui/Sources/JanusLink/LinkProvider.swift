import Darwin
import Foundation
import Network
import dnssd

/// Finds devices on the local network and connects to them (KDE Connect protocol 8, as Janus for Android does):
/// - UDP 1716: identity broadcasts (ours out, theirs in); a device that hears ours connects to our TCP port.
/// - TCP 1716–1764: when we hear a device's broadcast we connect to its `tcpPort`; when it hears ours, it connects
///   to us. Then the identity in the clear, then TLS with inverted roles (see TLSBridge), then the identity again.
/// - mDNS `_kdeconnect._udp` (instance = our device id, TXT id/name/type/protocol): phones browse for it and answer
///   with a unicast identity, which is how they find us when broadcasts don't get through.
public final class LinkProvider: @unchecked Sendable {
    public static let udpPort: UInt16 = 1716
    public static let tcpPorts: ClosedRange<UInt16> = 1716...1764

    private let me: LocalIdentity
    private let trust: TrustStore
    private let queue = DispatchQueue(label: "janus.link", qos: .userInitiated)
    private var udp: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var listener: NWListener?
    private(set) public var tcpPort: UInt16 = 0
    private var dnsService: DNSServiceRef?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private var found: [String: NWEndpoint] = [:]   // devices announcing themselves over mDNS, by device id
    private var lastSeen: [String: Date] = [:]   // rate limit per device id / address
    private var live: [String: Link] = [:]        // one link per device
    private let lock = NSLock()

    /// A new connection, encrypted and identified (trusted or not), on the provider's queue.
    public var onLink: ((Link) -> Void)?
    /// What happened, for logs.
    public var log: ((String) -> Void)?

    public init(identity: LocalIdentity, trust: TrustStore) {
        self.me = identity
        self.trust = trust
    }

    public func start() throws {
        try startTCP()
        try startUDP()
        announceService()
        browse()
        watchNetwork()
        announce()
        // A device may still be noticing that the previous connection is gone: call the ones not back yet again.
        for delay in [3.0, 8, 20] { queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.callUnlinked() } }
    }

    /// Calls (directly, not by broadcast) each device we know of that isn't connected.
    public func callUnlinked() {
        lock.lock(); let devices = found; lock.unlock()
        for (id, endpoint) in devices where !hasLiveLink(id) { sendIdentity(to: endpoint) }
        let linkedAddresses = Set(liveAddresses())
        let addresses = KnownAddresses.shared.all().filter { !linkedAddresses.contains($0) }
        if !addresses.isEmpty { broadcast(to: addresses) }
    }

    private func liveAddresses() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return live.values.map(\.peer.address)
    }

    public func stop() {
        udpSource?.cancel(); udpSource = nil
        if udp >= 0 { close(udp); udp = -1 }
        listener?.cancel(); listener = nil
        if let s = dnsService { DNSServiceRefDeallocate(s); dnsService = nil }
        browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
    }

    /// A real network change (another Wi-Fi, waking up): links may be dead without knowing it yet, so everyone
    /// hears from us again (each device then reconnects, replacing its old link).
    private func watchNetwork() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let key = path.availableInterfaces.map(\.name).joined(separator: ",") + "|\(path.status)"
            defer { self.lastPath = key }
            guard let last = self.lastPath, last != key, path.status == .satisfied else { return }
            self.log?("network changed; announcing")
            self.queue.asyncAfter(deadline: .now() + 1) { self.announce() }
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    // MARK: TCP

    private func startTCP() throws {
        for port in Self.tcpPorts {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true   // the port a previous engine just let go of
            (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.enableKeepalive = true
            guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { continue }
            let ready = DispatchSemaphore(value: 0)
            var ok = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ok = true; ready.signal()
                case .failed: ready.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accepted(c) }
            l.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
            if ok { listener = l; tcpPort = port; log?("TCP listening on \(port)"); return }
            l.cancel()
        }
        throw LinkError.protocolError("no free TCP port in 1716–1764")
    }

    /// A device heard our broadcast and connected: its identity first, then we're the TLS client.
    private func accepted(_ c: NWConnection) {
        let address = Self.host(c.endpoint)
        c.start(queue: queue)
        Task {
            do {
                try await TLSBridge.waitReady(c)
                let line = try await Link.readLine(c, limit: 512 * 1024, timeout: .seconds(10))
                guard let identity = Packet(line: line), let id = validIdentity(identity) else { c.cancel(); return }
                if let target = identity.string("targetDeviceId"), target != me.deviceID { c.cancel(); return }
                if let v = identity.int("targetProtocolVersion"), v != LocalIdentity.protocolVersion { c.cancel(); return }
                log?("TCP from \(identity.string("deviceName") ?? id) at \(address)")
                let (tls, cert) = try await TLSBridge.secure(c, role: .client, identity: me.identity, queue: queue)
                let link = try await Link.establish(tls: tls, certificate: cert, plainIdentity: identity, me: me,
                                                    trust: trust, address: address, queue: queue)
                deliver(link)
            } catch {
                log?("incoming connection from \(address) failed: \(error)")
                c.cancel()
            }
        }
    }

    /// Connects to a device we know the address of (e.g. a remembered or typed-in address).
    public func connect(host: String, port: UInt16, deviceIdentity: Packet) {
        connect(to: host, port: port, identity: deviceIdentity)
    }

    /// We heard a device's broadcast: connect to it, send our identity, then we're the TLS server.
    private func connect(to address: String, port: UInt16, identity: Packet) {
        guard let id = identity.string("deviceId"), let p = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.enableKeepalive = true
        let c = NWConnection(host: NWEndpoint.Host(address), port: p, using: params)
        c.start(queue: queue)
        Task {
            do {
                try await TLSBridge.waitReady(c)
                let mine = me.identityPacket(target: (id, identity.int("protocolVersion") ?? LocalIdentity.protocolVersion))
                c.send(content: mine.serialized(), completion: .idempotent)
                let (tls, cert) = try await TLSBridge.secure(c, role: .server, identity: me.identity, queue: queue)
                let link = try await Link.establish(tls: tls, certificate: cert, plainIdentity: identity, me: me,
                                                    trust: trust, address: address, queue: queue)
                deliver(link)
            } catch {
                log?("connecting to \(identity.string("deviceName") ?? id) at \(address) failed: \(error)")
                c.cancel()
            }
        }
    }

    // MARK: UDP

    private func startUDP() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LinkError.protocolError("udp socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.udpPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); throw LinkError.protocolError("udp bind \(errno)") }
        udp = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readUDP() }
        source.resume()
        udpSource = source
        log?("UDP listening on \(Self.udpPort)")
    }

    private func readUDP() {
        var buffer = [UInt8](repeating: 0, count: 512 * 1024)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buffer, buffer.count, 0, $0, &len) }
        }
        guard n > 0 else { return }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        let address = String(cString: ip)
        let data = Data(buffer[0..<n]).split(separator: 0x0A).first.map { Data($0) } ?? Data()
        guard let identity = Packet(line: data), let id = validIdentity(identity) else { return }
        guard !rateLimited(id) else { return }
        // Already connected: a second connection would only replace the first (as the old engine did, skip it).
        guard !hasLiveLink(id) else { return }
        let port = UInt16(identity.int("tcpPort") ?? Int(Self.tcpPorts.lowerBound))
        guard Self.tcpPorts.contains(port) else { return }
        log?("UDP identity from \(identity.string("deviceName") ?? id) at \(address):\(port)")
        connect(to: address, port: port, identity: identity)
    }

    /// Tells the network we're here (and asks devices to connect). Only on start, network changes and a manual
    /// reconnect: a device answers every broadcast by connecting, even when it's already connected (the new
    /// connection then replaces the old on both sides).
    ///
    /// Phones with the screen off can ignore 255.255.255.255 (Wi-Fi power saving), so this also goes to each
    /// interface's own broadcast address and straight to every paired device's last address.
    public func announce() {
        broadcast(to: ["255.255.255.255"] + Self.subnetBroadcasts() + KnownAddresses.shared.all())
        lock.lock(); let devices = found; lock.unlock()
        for (id, endpoint) in devices where !hasLiveLink(id) { sendIdentity(to: endpoint) }
    }

    /// Phones announce `_kdeconnect._udp` (instance = device id): send each one our identity directly, which gets
    /// through when broadcasts don't (that's how the previous engine found phones with the screen off).
    private func browse() {
        let b = NWBrowser(for: .bonjour(type: "_kdeconnect._udp", domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let r):
                    guard case .service(let id, _, _, _) = r.endpoint, id != self.me.deviceID else { continue }
                    self.lock.lock(); self.found[id] = r.endpoint; self.lock.unlock()
                    if !self.hasLiveLink(id) { self.log?("mDNS: found \(id), calling it"); self.sendIdentity(to: r.endpoint) }
                case .removed(let r):
                    if case .service(let id, _, _, _) = r.endpoint { self.lock.lock(); self.found[id] = nil; self.lock.unlock() }
                default: break
                }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    /// Our identity as one UDP datagram to a device's announced service (it then connects to our TCP port).
    private func sendIdentity(to endpoint: NWEndpoint) {
        let data = me.identityPacket(tcpPort: Int(tcpPort)).serialized()
        let c = NWConnection(to: endpoint, using: .udp)
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { c.cancel() }
    }

    public func broadcast(to addresses: [String]) {
        guard udp >= 0 else { return }
        let data = me.identityPacket(tcpPort: Int(tcpPort)).serialized()
        for a in addresses {
            var to = sockaddr_in()
            to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = Self.udpPort.bigEndian
            inet_pton(AF_INET, a, &to.sin_addr)
            _ = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                } }
            }
        }
    }

    // MARK: mDNS

    private func announceService() {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        for (k, v) in [("id", me.deviceID), ("name", me.name), ("type", me.type), ("protocol", String(LocalIdentity.protocolVersion))] {
            let bytes = Array(v.utf8)
            TXTRecordSetValue(&txt, k, UInt8(min(bytes.count, 255)), bytes)
        }
        var ref: DNSServiceRef?
        let err = DNSServiceRegister(&ref, 0, 0, me.deviceID, "_kdeconnect._udp", nil, nil, Self.udpPort.bigEndian,
                                     TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
        TXTRecordDeallocate(&txt)
        if err == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, queue)
            dnsService = ref
            log?("mDNS: announced as \(me.deviceID)")
        } else {
            log?("mDNS: couldn't announce (\(err))")
        }
    }

    // MARK: Links

    /// The device's current link, if it's connected.
    public func link(for deviceID: String) -> Link? {
        lock.lock(); defer { lock.unlock() }
        return live[deviceID]
    }

    private func hasLiveLink(_ id: String) -> Bool { link(for: id) != nil }

    /// One link per device: a newer connection (the device reconnected, e.g. after a network change) replaces the
    /// older one, which is closed.
    private func deliver(_ link: Link) {
        let id = link.peer.deviceID
        lock.lock()
        let old = live[id]
        live[id] = link
        lock.unlock()
        link.onEnded = { [weak self, weak link] in
            guard let self, let link else { return }
            self.lock.lock()
            if self.live[id] === link { self.live[id] = nil }
            self.lock.unlock()
        }
        if link.trusted { KnownAddresses.shared.remember(link.peer.address, for: id) }
        // The new link takes over first, then the old one closes: the device never looks disconnected in between.
        queue.async {
            self.onLink?(link)
            if let old { self.log?("\(link.peer.name) reconnected; closing the older connection"); old.close() }
        }
    }

    // MARK: Helpers

    private func validIdentity(_ p: Packet) -> String? {
        guard p.type == PacketType.identity, let id = p.string("deviceId"), id != me.deviceID,
              id.range(of: "^[A-Za-z0-9_]{32,38}$", options: .regularExpression) != nil,
              !(p.string("deviceName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return id
    }

    private func rateLimited(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastSeen[key], Date().timeIntervalSince(last) < 1 { return true }
        lastSeen[key] = Date()
        return false
    }

    /// Each IPv4 interface's broadcast address (e.g. 192.168.1.255), loopback left out.
    static func subnetBroadcasts() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  i.ifa_flags & UInt32(IFF_BROADCAST) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  i.ifa_flags & UInt32(IFF_UP) != 0, let b = i.ifa_dstaddr else { continue }
            var sin = b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let s = String(cString: ip)
            if !result.contains(s) { result.append(s) }
        }
        return result
    }

    static func host(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let h, _) = endpoint {
            switch h {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "\(h)"
            }
        }
        return "\(endpoint)"
    }
}

/// Where each paired device was last connected from, to call it directly next time.
final class KnownAddresses: @unchecked Sendable {
    static let shared = KnownAddresses()
    private let lock = NSLock()
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Android/Engine/addresses.json")
    private var map: [String: String]

    private init() {
        map = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }

    func remember(_ address: String, for id: String) {
        guard !address.contains(":") else { return }   // IPv4 only (UDP identity goes over IPv4)
        lock.lock(); defer { lock.unlock() }
        guard map[id] != address else { return }
        map[id] = address
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(map).write(to: file, options: .atomic)
    }

    func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(map.values))
    }
}
