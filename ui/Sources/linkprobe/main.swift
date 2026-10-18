import Foundation
import JanusLink

// Native engine probe (R40 phase 1): announces this Mac with its real identity, accepts/makes connections,
// and pings trusted devices. Run only while the old engine is stopped (they share UDP/TCP 1716 and the identity).
//   linkprobe [seconds] [ping message]
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let message = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Hello from Janus's native engine"
func log(_ s: String) { print("\(Date().formatted(date: .omitted, time: .standard))  \(s)"); fflush(stdout) }

// `linkprobe capture <folder>`: with a throwaway identity from <folder>, connect to this Mac's running engine and
// print what it announces (its capabilities come only inside TLS).
if CommandLine.arguments.dropFirst().first == "capture", CommandLine.arguments.count > 2 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    let me = try! LocalIdentity.load(type: "phone", incoming: [], outgoing: [], folder: folder)
    let trust = TrustStore(file: folder.appendingPathComponent("trusted_devices"))
    let provider = LinkProvider(identity: me, trust: trust)
    provider.onLink = { link in
        let caps: [String: Any] = ["in": link.peer.incomingCapabilities.sorted(), "out": link.peer.outgoingCapabilities.sorted(), "type": link.peer.type]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: caps, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        link.close(); exit(0)
    }
    let target = Packet(PacketType.identity, ["deviceId": CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "", "protocolVersion": 8, "deviceName": "engine"])
    provider.connect(host: "127.0.0.1", port: 1716, deviceIdentity: target)
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) { print("no answer"); exit(1) }
    dispatchMain()
}

do {
    // Announce everything the previous engine did, so the phone doesn't drop anything meanwhile.
    let me = try LocalIdentity.load(incoming: Capabilities.incoming, outgoing: Capabilities.outgoing)
    let sendFile = ProcessInfo.processInfo.environment["SEND_FILE"].map { URL(fileURLWithPath: $0) }
    let trust = TrustStore()
    log("I am \(me.name) (\(me.deviceID)), \(trust.all().count) paired devices: \(trust.all().map(\.name).joined(separator: ", "))")
    let provider = LinkProvider(identity: me, trust: trust)
    var links: [Link] = []
    provider.log = log
    provider.onLink = { link in
        links.append(link)
        let p = link.peer
        log("LINK \(p.name) [\(p.type), protocol \(p.protocolVersion)] at \(p.address) trusted=\(link.trusted) cert \(Certificates.fingerprint(p.certificateDER).prefix(16))… capabilities in \(p.incomingCapabilities.count) out \(p.outgoingCapabilities.count)")
        link.onPacket = { packet in log("  ← \(p.name): \(packet.type) \(packet.body.keys.sorted())") }
        link.onClose = { error in log("  ✕ \(p.name) closed \(error.map { "\($0)" } ?? "")") }
        link.start()
        if link.trusted, let file = sendFile, p.type == "phone" {
            Task {
                do {
                    let start = Date()
                    try await Payload.send(Packet("kdeconnect.share.request", ["filename": file.lastPathComponent]), file: file, over: link, me: me) { done, total in
                        if done == total { log("  → \(file.lastPathComponent): \(total) bytes sent") }
                    }
                    log("  ✓ file sent to \(p.name) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
                } catch { log("  ✗ file to \(p.name) failed: \(error)") }
            }
        } else if link.trusted, sendFile == nil {
            link.send(Packet("kdeconnect.ping", ["message": message])) { e in log("  → ping to \(p.name) \(e == nil ? "sent" : "failed: \(e!)")") }
        }
    }
    try provider.start()
    log("TCP port \(provider.tcpPort); announced")
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        log("done: \(links.count) link(s)")
        links.forEach { $0.close() }
        provider.stop()
        exit(0)
    }
    dispatchMain()
} catch {
    log("failed: \(error)")
    exit(1)
}
