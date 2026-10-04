import Foundation
import Network

/// Relays a loopback port to the phone's Wireless debugging port. The app (which has macOS's Local
/// Network permission) makes the Wi-Fi connection; adb only talks to 127.0.0.1, which needs no
/// permission (adb's background server isn't covered by the app's permission). adb's TLS runs end to
/// end through the relay, so pairing and encryption are unchanged.
final class MirrorRelay: @unchecked Sendable {
    let host: String
    let port: Int
    private(set) var localPort: Int = 0
    /// The phone-side connection's latest state (diagnostics).
    private(set) var lastOutboundState = "none"
    private var listener: NWListener?
    private var links: [(NWConnection, NWConnection)] = []
    private let queue = DispatchQueue(label: "mirror.relay")

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Starts listening on a free loopback port; returns it.
    func start() async throws -> Int {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let p = Int(listener.port?.rawValue ?? 0)
                    self?.localPort = p
                    cont.resume(returning: p)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            links.forEach { $0.0.cancel(); $0.1.cancel() }
            links = []
        }
    }

    private func accept(_ inbound: NWConnection) {
        let outbound = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
        links.append((inbound, outbound))
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
        outbound.stateUpdateHandler = { [weak self] state in
            self?.lastOutboundState += " → \(state)"
            if case .failed = state { inbound.cancel() }
        }
    }

    private func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { _ in })
            }
            if done || error != nil {
                b.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in b.cancel() })
                a.cancel()
                return
            }
            self?.pump(from: a, to: b)
        }
    }
}
