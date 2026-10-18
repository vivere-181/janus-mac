import Foundation
import JanusLink
import KDEConnectKit

/// One device, as KDE's daemon presented it: `/modules/kdeconnect/devices/<id>` with its properties, pairing and
/// plugins (each at `/<id>/<plugin>`). Lives on the engine's queue.
final class NativeDevice {
    let id: String
    unowned let engine: NativeEngine
    var name: String
    var type: String
    var certificateDER: Data?
    private(set) var link: Link?
    private(set) var pairing: Pairing?
    private var peerIncoming: [String] = []
    private var peerOutgoing: [String] = []
    private(set) var plugins: [String: NativePlugin] = [:]   // loaded, by id ("kdeconnect_battery")

    var isReachable: Bool { link != nil }
    var isPaired: Bool { engine.trust.isTrusted(id) }
    var path: String { NativeEngine.daemonPath + "/devices/" + id }

    init(trusted d: TrustStore.Device, engine: NativeEngine) {
        id = d.id; name = d.name; type = d.type; certificateDER = d.certificateDER
        self.engine = engine
    }

    init(id: String, engine: NativeEngine) {
        self.id = id; name = id; type = "phone"
        self.engine = engine
    }

    // MARK: Link

    private var pendingDetach: DispatchWorkItem?

    func attach(_ link: Link) {
        pendingDetach?.cancel(); pendingDetach = nil
        let replacing = self.link != nil
        self.link = link
        name = link.peer.name
        type = link.peer.type
        certificateDER = link.peer.certificateDER
        peerIncoming = link.peer.incomingCapabilities
        peerOutgoing = link.peer.outgoingCapabilities
        let pairing = Pairing(link: link, me: engine.me, trust: engine.trust)
        pairing.onChange = { [weak self] state, reason in self?.engine.queue.async { self?.pairingChanged(state, reason) } }
        pairing.acceptCode = { [weak engine] code in engine?.consumePairingCode(code) ?? false }
        self.pairing = pairing
        link.onPacket = { [weak self, weak link] p in self?.engine.queue.async { if let link, self?.link === link { self?.received(p) } } }
        // A device that closes and reconnects at once (some do, after their own network hiccup) doesn't flap: it
        // counts as gone only if no new link arrives within 2 seconds.
        link.onClose = { [weak self, weak link] _ in
            self?.engine.queue.async {
                guard let self, let link, self.link === link else { return }
                let detach = DispatchWorkItem { [weak self] in if self?.link === link { self?.detach() } }
                self.pendingDetach = detach
                self.engine.queue.asyncAfter(deadline: .now() + 2, execute: detach)
            }
        }
        link.start()
        if isPaired, link.trusted { engine.trust.add(.init(id: id, name: name, type: type, protocolVersion: link.peer.protocolVersion, certificateDER: link.peer.certificateDER)) }
        reloadPlugins()
        if !replacing { emit(nil, "", "reachableChanged", [.bool(true)]) }
        emit(nil, "", "nameChanged", [.string(name)])
        engine.log?("\(name) connected\(link.trusted ? "" : " (not paired)")")
    }

    private func detach() {
        link = nil
        pairing = nil
        unloadPlugins()
        emit(nil, "", "reachableChanged", [.bool(false)])
        engine.log?("\(name) disconnected")
        engine.detached(self)
    }

    private func received(_ p: Packet) {
        if p.type == PacketType.pair { pairing?.received(p); return }
        guard isPaired, link?.trusted == true else {
            // An unpaired device only gets to pair; anything else means it thinks we're paired: tell it we're not.
            link?.send(Packet(PacketType.pair, ["pair": false]))
            return
        }
        for plugin in plugins.values where Swift.type(of: plugin).incoming.contains(p.type) { plugin.received(p) }
    }

    func send(_ p: Packet) {
        guard let link, link.trusted else { return }
        link.send(p)
    }

    func sendWithPayload(_ p: Packet, file: URL, progress: Payload.Progress? = nil) async throws {
        guard let link, link.trusted else { throw LinkError.closed }
        try await Payload.send(p, file: file, over: link, me: engine.me, progress: progress)
    }

    func receivePayload(_ p: Packet, to destination: URL, progress: Payload.Progress? = nil) async throws {
        guard let link, link.trusted else { throw LinkError.closed }
        try await Payload.receive(p, from: link, me: engine.me, to: destination, progress: progress)
    }

    // MARK: Pairing

    private func pairingChanged(_ state: Pairing.State, _ reason: String?) {
        if let reason, state == .notPaired { emit(nil, "", "pairingFailed", [.string(reason)]) }
        emit(nil, "", "pairStateChanged", [.int32(Self.kdeState(state))])
        engine.emit(NativeEngine.daemonPath, NativeEngine.daemonInterface, "pairingRequestsChanged", [])
        reloadPlugins()
        if state == .paired {
            engine.log?("paired with \(name)\(pairing?.pairedByCode == true ? " (QR code)" : "")")
            if pairing?.pairedByCode == true {
                engine.emit(NativeEngine.daemonPath, NativeEngine.daemonInterface, "janusPairedByCode", [.string(id)])
            }
        }
    }

    /// KDE's PairState: NotPaired 0, Requested 1, RequestedByPeer 2, Paired 3.
    private static func kdeState(_ s: Pairing.State) -> Int32 {
        switch s { case .notPaired: 0; case .requested: 1; case .requestedByPeer: 2; case .paired: 3 }
    }

    // MARK: Plugins

    /// The plugins both sides can use: one of a plugin's packet types goes the other way.
    var supportedPlugins: [String] {
        guard isReachable else { return [] }
        return PluginRegistry.all.filter { p in
            !Set(p.incoming).isDisjoint(with: peerOutgoing) || !Set(p.outgoing).isDisjoint(with: peerIncoming)
        }.map { $0.id }
    }

    func isPluginEnabled(_ plugin: String) -> Bool {
        PluginSettings.enabled(device: id, plugin: plugin) ?? PluginRegistry.byID[plugin]?.enabledByDefault ?? true
    }

    func setPluginEnabled(_ plugin: String, _ on: Bool) {
        PluginSettings.set(device: id, plugin: plugin, enabled: on)
        reloadPlugins()
    }

    private func reloadPlugins() {
        let wanted = Set(isPaired && link?.trusted == true ? supportedPlugins.filter(isPluginEnabled) : [])
        let current = Set(plugins.keys)
        guard wanted != current else { return }
        for gone in current.subtracting(wanted) { plugins[gone]?.unloaded(); plugins[gone] = nil }
        for new in wanted.subtracting(current) {
            guard let t = PluginRegistry.byID[new] else { continue }
            let plugin = t.make(self)
            plugins[new] = plugin
            plugin.connected()
        }
        emit(nil, "", "pluginsChanged", [])
    }

    private func unloadPlugins() {
        plugins.values.forEach { $0.unloaded() }
        plugins = [:]
    }

    // MARK: Calls

    func emit(_ sub: String?, _ iface: String, _ member: String, _ body: [DBusValue]) {
        engine.emit(sub.map { path + "/" + $0 } ?? path, NativeEngine.deviceInterface + (iface.isEmpty ? "" : "." + iface), member, body)
    }

    func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        if let sub {
            let top = String(sub.split(separator: "/").first ?? "")
            guard let plugin = plugins.values.first(where: { Swift.type(of: $0).subpath == top }) else { throw NativeEngine.unknown("plugin \(sub)") }
            return try plugin.call(sub: sub, interface: interface, member: member, args)
        }
        // Device-level methods; conversations (sms) also live here, on the device's own path.
        switch member {
        case "loadedPlugins": return [.strings(Array(plugins.keys).sorted())]
        case "isPluginEnabled": return [.bool(isPluginEnabled(args.first?.string ?? ""))]
        case "setPluginEnabled":
            setPluginEnabled(args.first?.string ?? "", args.dropFirst().first?.bool ?? true); return []
        case "encryptionInfo": return [.string(encryptionInfo)]
        case "requestPairing": pairing?.request(); return []
        case "acceptPairing": pairing?.accept(); return []
        case "cancelPairing": pairing?.cancel(); return []
        case "unpair":
            if let pairing { pairing.unpair() } else { engine.trust.remove(id) }
            reloadPlugins()
            emit(nil, "", "pairStateChanged", [.int32(0)])
            return []
        default:
            if let sms = plugins.values.first(where: { Swift.type(of: $0).deviceLevelMembers.contains(member) }) {
                return try sms.call(sub: nil, interface: interface, member: member, args)
            }
            throw NativeEngine.unknown(member)
        }
    }

    func properties(sub: String?, interface: String) throws -> [String: DBusValue] {
        if let sub {
            let top = String(sub.split(separator: "/").first ?? "")
            guard let plugin = plugins.values.first(where: { Swift.type(of: $0).subpath == top }) else { return [:] }
            return plugin.properties(sub: sub)
        }
        let state = pairing?.state ?? (isPaired ? .paired : .notPaired)
        return [
            "type": .string(type), "name": .string(name),
            "isReachable": .bool(isReachable), "isPaired": .bool(isPaired),
            "isPairRequested": .bool(state == .requested), "isPairRequestedByPeer": .bool(state == .requestedByPeer),
            "verificationKey": .string(pairing?.verificationKey ?? ""),
            "reachableAddresses": .strings(link.map { [$0.peer.address] } ?? []),
            "activeProviderNames": .strings(isReachable ? ["LanLinkProvider"] : []),
            "supportedPlugins": .strings(supportedPlugins),
            "statusIconName": .string(isReachable ? "phone-connected" : "phone-disconnected"),
        ]
    }

    func setProperty(sub: String?, interface: String, name: String, value: DBusValue) throws {
        guard let sub else { throw NativeEngine.unknown("property \(name)") }
        let top = String(sub.split(separator: "/").first ?? "")
        guard let plugin = plugins.values.first(where: { Swift.type(of: $0).subpath == top }) else { throw NativeEngine.unknown("plugin \(sub)") }
        try plugin.setProperty(name, value)
    }

    private var encryptionInfo: String {
        let mine = Certificates.fingerprint(engine.me.certificateDER)
        let theirs = certificateDER.map(Certificates.fingerprint) ?? "?"
        func pretty(_ s: String) -> String { stride(from: 0, to: s.count, by: 2).map { i in String(Array(s)[i..<min(i + 2, s.count)]) }.joined(separator: ":") }
        return "SHA256 fingerprint of your device certificate is:\n\(pretty(mine))\n\nSHA256 fingerprint of remote device certificate is:\n\(pretty(theirs))\n"
    }
}

/// Which plugins are switched on per device: KDE's `<device>/config`, [Plugins] `<plugin>Enabled=true|false`, so
/// both engines (and the app, which writes plugin configs there) agree.
enum PluginSettings {
    private static func file(_ device: String) -> URL {
        LocalIdentity.folder.appendingPathComponent(device, isDirectory: true).appendingPathComponent("config")
    }

    static func enabled(device: String, plugin: String) -> Bool? {
        guard let text = try? String(contentsOf: file(device), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("\(plugin)Enabled=") }) else { return nil }
        return line.hasSuffix("=true")
    }

    static func set(device: String, plugin: String, enabled: Bool) {
        let url = file(device)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "[Plugins]\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entry = "\(plugin)Enabled=\(enabled)"
        if let i = lines.firstIndex(where: { $0.hasPrefix("\(plugin)Enabled=") }) { lines[i] = entry }
        else if let i = lines.firstIndex(of: "[Plugins]") { lines.insert(entry, at: i + 1) }
        else { lines.append(contentsOf: ["[Plugins]", entry]) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
