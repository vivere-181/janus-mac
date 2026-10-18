import Foundation
import Network

/// Files that come with a packet (KDE Connect protocol 8): the sender listens on the first free port from 1739 and
/// names it in `payloadTransferInfo.port`; the receiver connects. The sender is the TLS server, the receiver the TLS
/// client (the usual roles here), with the same certificates as the link, each checked against the device's.
public enum Payload {
    public static let ports: ClosedRange<UInt16> = 1739...1764

    /// Progress: bytes done of total.
    public typealias Progress = @Sendable (Int64, Int64) -> Void

    /// Sends `packet` over `link` with the contents of `file` following on its own connection.
    public static func send(_ packet: Packet, file: URL, over link: Link, me: LocalIdentity,
                            progress: Progress? = nil) async throws {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let queue = DispatchQueue(label: "janus.payload.send")
        let peer = TLSBridge.PeerBox()
        let tls = TLSBridge.options(identity: me.identity, role: .server, peer: peer, queue: queue)
        var listener: NWListener?
        var port: UInt16 = 0
        for p in ports {
            if let l = await Listeners.start(NWParameters(tls: tls, tcp: .init()), port: p, queue: queue) { listener = l; port = p; break }
        }
        guard let listener else { throw LinkError.protocolError("no free payload port") }
        defer { listener.cancel() }

        let incoming = AsyncStream<NWConnection> { cont in listener.newConnectionHandler = { cont.yield($0) } }
        var packet = packet
        packet.payloadSize = size
        packet.payloadTransferInfo = ["port": Int(port)]
        link.send(packet)

        // The device has 10 s to come for it.
        let connection: NWConnection = try await withThrowingTaskGroup(of: NWConnection.self) { group in
            group.addTask {
                for await c in incoming { return c }
                throw LinkError.closed
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw LinkError.timeout }
            let c = try await group.next()!
            group.cancelAll()
            return c
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        try await TLSBridge.waitReady(connection)
        guard peer.certificate == link.peer.certificateDER else { throw LinkError.notTrusted }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < size {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.send(content: chunk, completion: .contentProcessed { e in
                    if let e { cont.resume(throwing: e) } else { cont.resume() }
                })
            }
            sent += Int64(chunk.count)
            progress?(sent, size)
        }
        // Closing at once can cut off what's still in flight (the receiver then discards the file as short), and
        // Network.framework's end-of-stream doesn't reach a TLS reader as EOF. So: give the receiver up to 3 s to
        // close first (Janus for Android does as soon as it has payloadSize bytes); then close, which a reader that
        // waits for EOF (older peers) takes as the end. Tested: 8/8 complete either way.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in cont.resume() })
        }
        await waitForClose(connection, timeout: .seconds(3))
    }

    /// Reads (and drops) whatever comes until the other side closes, or the timeout passes.
    private static func waitForClose(_ c: NWConnection, timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let done: Bool = await withCheckedContinuation { cont in
                        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, isComplete, error in
                            cont.resume(returning: isComplete || error != nil)
                        }
                    }
                    if done { return }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Receives the file that comes with `packet` from `link` into `destination` (created or replaced).
    public static func receive(_ packet: Packet, from link: Link, me: LocalIdentity, to destination: URL,
                               progress: Progress? = nil) async throws {
        guard let size = packet.payloadSize, let portNumber = (packet.payloadTransferInfo?["port"] as? NSNumber)?.uint16Value,
              let port = NWEndpoint.Port(rawValue: portNumber) else { throw LinkError.protocolError("no payload") }
        let queue = DispatchQueue(label: "janus.payload.receive")
        let peer = TLSBridge.PeerBox()
        let tls = TLSBridge.options(identity: me.identity, role: .client, peer: peer, queue: queue)
        let c = NWConnection(host: NWEndpoint.Host(link.peer.address), port: port, using: NWParameters(tls: tls, tcp: .init()))
        c.start(queue: queue)
        defer { c.cancel() }
        try await TLSBridge.waitReady(c)
        guard peer.certificate == link.peer.certificateDER else { throw LinkError.notTrusted }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var received: Int64 = 0
        while received < size {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                c.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, done, error in
                    if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if done { cont.resume(returning: Data()) }
                    else { cont.resume(throwing: error ?? LinkError.closed) }
                }
            }
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
            received += Int64(chunk.count)
            progress?(received, size)
        }
        guard received == size else { throw LinkError.protocolError("payload cut short (\(received) of \(size))") }
    }
}

/// Starting a listener on a given port, waiting until it's ready (nil if the port is taken).
enum Listeners {
    static func start(_ params: NWParameters, port: UInt16, queue: DispatchQueue) async -> NWListener? {
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { return nil }
        let ok: Bool = await withCheckedContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: once.run { cont.resume(returning: true) }
                case .failed, .cancelled: once.run { cont.resume(returning: false) }
                default: break
                }
            }
            l.newConnectionHandler = { $0.cancel() }
            l.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { once.run { cont.resume(returning: false) } }
        }
        if !ok { l.cancel() }
        return ok ? l : nil
    }
}
