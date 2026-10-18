import CryptoKit
import Foundation

/// Pairing on a link (KDE Connect protocol 8): `kdeconnect.pair` {pair: true, timestamp} to ask, {pair: true} to
/// accept, {pair: false} to refuse, cancel or unpair. Both sides show the same verification code, made from both
/// certificates' public keys and the request's timestamp; pairing pins the device's certificate.
public final class Pairing: @unchecked Sendable {
    public enum State: Equatable { case notPaired, requested, requestedByPeer, paired }

    public private(set) var state: State
    /// The request's time (seconds), part of the verification code.
    public private(set) var timestamp: Int64 = 0
    private let link: Link
    private let me: LocalIdentity
    private let trust: TrustStore
    private var timer: DispatchWorkItem?
    private let lock = NSLock()

    /// State changes, with a reason when pairing failed ("timed out", "refused"…).
    public var onChange: ((State, String?) -> Void)?
    /// QR pairing (R41): whether a request's `janusPairCode` is the one this Mac is showing (single use).
    public var acceptCode: ((String) -> Bool)?
    /// Paired by scanning this Mac's code: the owner was at both devices, so it's their own.
    public private(set) var pairedByCode = false

    /// Clocks may differ this much (seconds) before a request is refused.
    static let allowedClockDifference: Int64 = 1800

    public init(link: Link, me: LocalIdentity, trust: TrustStore) {
        self.link = link
        self.me = me
        self.trust = trust
        state = link.trusted ? .paired : .notPaired
    }

    /// The code both devices show while pairing ("A1B2C3D4"), nil before a request.
    public var verificationKey: String? {
        guard state == .requested || state == .requestedByPeer || timestamp != 0,
              let theirs = Certificates.publicKeyInfo(link.peer.certificateDER) else { return nil }
        return Self.verificationKey(me.publicKeyInfo, theirs, timestamp: timestamp)
    }

    public static func verificationKey(_ a: Data, _ b: Data, timestamp: Int64) -> String {
        // The larger key (unsigned, byte by byte) first, as KDE Connect does.
        let concat = a.lexicographicallyPrecedes(b) ? b + a : a + b
        let hash = SHA256.hash(data: concat + Data(String(timestamp).utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(8).uppercased()
    }

    // MARK: Our side

    public func request() {
        switch state {
        case .paired, .requested: return
        case .requestedByPeer: accept(); return
        case .notPaired: break
        }
        timestamp = Int64(Date().timeIntervalSince1970)
        set(.requested)
        arm(seconds: 30, reason: "timed out")
        link.send(Packet(PacketType.pair, ["pair": true, "timestamp": timestamp])) { [weak self] e in
            if e != nil { self?.fail("not reachable") }
        }
    }

    public func accept() {
        guard state == .requestedByPeer else { return }
        disarm()
        link.send(Packet(PacketType.pair, ["pair": true])) { [weak self] e in
            if e != nil { self?.fail("not reachable") } else { self?.paired() }
        }
    }

    /// Refuses their request, or cancels ours.
    public func cancel() {
        guard state == .requested || state == .requestedByPeer else { return }
        disarm()
        link.send(Packet(PacketType.pair, ["pair": false]))
        set(.notPaired)
    }

    public func unpair() {
        disarm()
        link.send(Packet(PacketType.pair, ["pair": false]))
        trust.remove(link.peer.deviceID)
        link.trusted = false
        set(.notPaired)
    }

    // MARK: Their side

    /// A `kdeconnect.pair` packet from the device.
    public func received(_ p: Packet) {
        if p.bool("pair") == true {
            switch state {
            case .requested:
                disarm(); paired()
            case .requestedByPeer:
                return   // a second request before the first timed out
            case .paired, .notPaired:
                if state == .paired {
                    // Pair requests and accepts look the same: a request while paired means they forgot us.
                    trust.remove(link.peer.deviceID); link.trusted = false
                }
                guard let ts = p.int64("timestamp") else { set(.notPaired, "no timestamp"); return }
                let now = Int64(Date().timeIntervalSince1970)
                guard abs(ts - now) <= Self.allowedClockDifference else { set(.notPaired, "the clocks don't match"); return }
                timestamp = ts
                // Scanned from this Mac's screen: accept at once (the code and the certificate fingerprint in it stand
                // in for comparing verification codes).
                if let code = p.string("janusPairCode"), acceptCode?(code) == true {
                    pairedByCode = true
                    link.send(Packet(PacketType.pair, ["pair": true])) { [weak self] e in
                        if e != nil { self?.fail("not reachable") } else { self?.paired() }
                    }
                    return
                }
                set(.requestedByPeer)
                arm(seconds: 25, reason: "timed out")
            }
        } else {
            disarm()
            switch state {
            case .requested, .requestedByPeer: set(.notPaired, "cancelled by the other device")
            case .paired:
                trust.remove(link.peer.deviceID); link.trusted = false
                set(.notPaired, "unpaired by the other device")
            case .notPaired: break
            }
        }
    }

    // MARK: Helpers

    private func paired() {
        let p = link.peer
        trust.add(.init(id: p.deviceID, name: p.name, type: p.type, protocolVersion: p.protocolVersion, certificateDER: p.certificateDER))
        link.trusted = true
        set(.paired)
    }

    private func fail(_ reason: String) { disarm(); set(.notPaired, reason) }

    private func set(_ s: State, _ reason: String? = nil) {
        lock.lock(); state = s; lock.unlock()
        onChange?(s, reason)
    }

    private func arm(seconds: Double, reason: String) {
        disarm()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .requested || self.state == .requestedByPeer else { return }
            self.set(.notPaired, reason)
        }
        timer = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func disarm() { timer?.cancel(); timer = nil }
}
