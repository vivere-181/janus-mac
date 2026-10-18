import Foundation
import Network
import Security

/// TLS in either role over a connection that's already open.
///
/// KDE Connect inverts the usual roles: whoever *accepted* the TCP connection is the TLS client, whoever *opened* it is
/// the TLS server, and the TLS starts only after a plain-text identity line. Network.framework fixes the TLS role by
/// direction and can't start TLS on an open connection, so the TLS runs over loopback instead: the raw connection to
/// the device just carries bytes to and from a local endpoint where Network.framework does the TLS in the right role.
/// (Modern TLS from the system, no deprecated SecureTransport, no third-party crypto.)
enum TLSBridge {
    enum Role { case client, server }

    /// The device's certificate, as seen during the handshake.
    final class PeerBox: @unchecked Sendable { var certificate: Data? }

    static func options(identity: SecIdentity, role: Role, peer: PeerBox, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        if role == .server { sec_protocol_options_set_peer_authentication_required(sec, true) }
        // Self-signed on both sides: trust is decided by pairing (the link compares this certificate with the pinned one).
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            peer.certificate = chain?.first.map { SecCertificateCopyData($0) as Data }
            complete(peer.certificate != nil)
        }, queue)
        return tls
    }

    /// Starts TLS over `raw` (already connected, plain). Returns the connection to read and write in the clear, and
    /// the device's certificate.
    static func secure(_ raw: NWConnection, role: Role, identity: SecIdentity, queue: DispatchQueue) async throws -> (NWConnection, Data) {
        let peer = PeerBox()
        let loopback = NWEndpoint.Host("127.0.0.1")
        let tlsOptions = options(identity: identity, role: role, peer: peer, queue: queue)
        let listenerParams: NWParameters
        switch role {
        case .client: listenerParams = .tcp                                       // we dial TLS into a plain local socket
        case .server: listenerParams = NWParameters(tls: tlsOptions, tcp: .init()) // the device's bytes dial into our TLS listener
        }
        listenerParams.requiredLocalEndpoint = .hostPort(host: loopback, port: .any)
        let listener = try NWListener(using: listenerParams)
        defer { listener.cancel() }

        let accepted = AsyncStream<NWConnection> { cont in
            listener.newConnectionHandler = { cont.yield($0) }
            listener.stateUpdateHandler = { if case .failed = $0 { cont.finish() } }
        }
        listener.start(queue: queue)
        let port = try await waitForPort(listener)

        var acceptedIterator = accepted.makeAsyncIterator()
        switch role {
        case .client:
            // Our TLS client → local plain socket ⇄ raw ⇄ device (TLS server).
            let tls = NWConnection(host: loopback, port: port, using: NWParameters(tls: tlsOptions, tcp: .init()))
            tls.start(queue: queue)
            guard let local = await acceptedIterator.next() else { throw LinkError.closed }
            local.start(queue: queue)
            Pump.splice(raw, local, queue: queue)
            try await waitReady(tls)
            guard let cert = peer.certificate else { throw LinkError.notTrusted }
            return (tls, cert)
        case .server:
            // Device (TLS client) ⇄ raw ⇄ local plain socket → our TLS listener.
            let local = NWConnection(host: loopback, port: port, using: .tcp)
            local.start(queue: queue)
            Pump.splice(raw, local, queue: queue)
            guard let tls = await acceptedIterator.next() else { throw LinkError.closed }
            tls.start(queue: queue)
            try await waitReady(tls)
            guard let cert = peer.certificate else { throw LinkError.notTrusted }
            return (tls, cert)
        }
    }

    private static func waitForPort(_ listener: NWListener) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let p = listener.port, p.rawValue != 0 { return p }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LinkError.timeout
    }

    static func waitReady(_ c: NWConnection, timeout: Duration = .seconds(10)) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e), .waiting(let e): once.run { c.cancel(); cont.resume(throwing: LinkError.protocolError("\(e)")) }
                case .cancelled: once.run { cont.resume(throwing: LinkError.closed) }
                default: break
                }
            }
            let ms = Int(timeout.components.seconds * 1000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
                once.run { c.cancel(); cont.resume(throwing: LinkError.timeout) }
            }
        }
    }
}

/// Runs a closure once, from whichever callback gets there first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}

/// Copies bytes both ways between two connections until either closes.
enum Pump {
    static func splice(_ a: NWConnection, _ b: NWConnection, queue: DispatchQueue) {
        copy(from: a, to: b)
        copy(from: b, to: a)
    }

    private static func copy(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
            if let data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { e in
                    if e != nil { src.cancel(); dst.cancel(); return }
                    if done || error != nil { dst.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent); return }
                    copy(from: src, to: dst)
                })
            } else if done || error != nil {
                dst.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in dst.cancel() })
                src.cancel()
            } else {
                copy(from: src, to: dst)
            }
        }
    }
}
