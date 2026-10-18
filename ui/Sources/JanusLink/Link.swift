import Foundation
import Network

/// A device on the other end of an encrypted connection: who it says it is (its identity packet, sent inside TLS) and
/// its certificate. `trusted` when that certificate is the one pinned at pairing; an untrusted link can only pair.
public final class Link: @unchecked Sendable {
    public struct Peer: Sendable {
        public let deviceID: String
        public let name: String
        public let type: String
        public let protocolVersion: Int
        public let incomingCapabilities: [String]
        public let outgoingCapabilities: [String]
        public let certificateDER: Data
        public let address: String
    }

    public let peer: Peer
    /// The device's certificate is the pinned one (set when pairing completes on this link).
    public internal(set) var trusted: Bool
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = LineBuffer()
    private let closed = Once()

    /// Packets from the device, on the link's queue.
    public var onPacket: ((Packet) -> Void)?
    /// Called once when the connection ends.
    public var onClose: ((Error?) -> Void)?
    /// The provider's own bookkeeping (live links), before `onClose`.
    var onEnded: (() -> Void)?

    init(peer: Peer, trusted: Bool, connection: NWConnection, queue: DispatchQueue) {
        self.peer = peer
        self.trusted = trusted
        self.connection = connection
        self.queue = queue
    }

    /// Starts delivering packets (after `onPacket` / `onClose` are set).
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e): self?.finish(e)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for line in try self.buffer.append(data) {
                        if let packet = Packet(line: line) { self.onPacket?(packet) }
                    }
                } catch { self.close(); return }
            }
            if done || error != nil { self.finish(error); self.connection.cancel() } else { self.receive() }
        }
    }

    public func send(_ packet: Packet, completion: ((Error?) -> Void)? = nil) {
        connection.send(content: packet.serialized(), completion: .contentProcessed { completion?($0) })
    }

    public func close() { connection.cancel() }

    private func finish(_ error: Error?) {
        closed.run { onEnded?(); onClose?(error) }
    }

    // MARK: Handshake (protocol 8)

    /// After TLS: both sides send their identity again, now that it can't be tampered with; the one received in the
    /// clear only got us this far.
    static func establish(tls: NWConnection, certificate: Data, plainIdentity: Packet, me: LocalIdentity,
                          trust: TrustStore, address: String, queue: DispatchQueue) async throws -> Link {
        tls.send(content: me.identityPacket().serialized(), completion: .idempotent)
        let line = try await readLine(tls, limit: 512 * 1024, timeout: .seconds(10))
        guard let secure = Packet(line: line), secure.type == PacketType.identity,
              let id = secure.string("deviceId"), id == plainIdentity.string("deviceId"),
              secure.int("protocolVersion") == plainIdentity.int("protocolVersion") else {
            tls.cancel(); throw LinkError.protocolError("identity changed during the handshake")
        }
        let pinned = trust.device(id)?.certificateDER
        if let pinned, pinned != certificate { tls.cancel(); throw LinkError.notTrusted }
        let peer = Peer(deviceID: id, name: secure.string("deviceName") ?? id, type: secure.string("deviceType") ?? "phone",
                        protocolVersion: secure.int("protocolVersion") ?? 8,
                        incomingCapabilities: secure.strings("incomingCapabilities"),
                        outgoingCapabilities: secure.strings("outgoingCapabilities"),
                        certificateDER: certificate, address: address)
        return Link(peer: peer, trusted: pinned != nil, connection: tls, queue: queue)
    }

    /// One line from a connection, read without reading past it (what follows may be TLS, or the next packet).
    static func readLine(_ c: NWConnection, limit: Int, timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var line = Data()
                while true {
                    let byte: Data = try await withCheckedThrowingContinuation { cont in
                        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, done, error in
                            if let data, !data.isEmpty { cont.resume(returning: data) }
                            else { cont.resume(throwing: error ?? LinkError.closed) }
                            _ = done
                        }
                    }
                    if byte.first == 0x0A { return line }
                    line.append(byte)
                    if line.count > limit { throw LinkError.protocolError("identity too long") }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LinkError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
