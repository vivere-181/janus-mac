import Foundation
import JanusLink
import Network
import Security

/// Google's Android TV Remote protocol (v2), the one the Google TV phone app uses (R39): pairing on port 6467 (the TV
/// shows a six-character code), then the remote on 6466. Both are TLS with our own client certificate; messages are
/// varint-length-prefixed protobufs (layouts as in androidtvremote2's pairingmessage.proto and remotemessage.proto).
enum ATV {
    static let pairingPort: UInt16 = 6467
    static let remotePort: UInt16 = 6466
}

// MARK: Protobuf, as much as the protocol needs

enum PB {
    /// A message being written.
    struct W {
        private(set) var data = Data()

        static func varint(_ value: UInt64) -> Data {
            var v = value, out = Data()
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            out.append(UInt8(v))
            return out
        }

        func int(_ field: Int, _ value: Int64) -> W {
            var w = self
            w.data += Self.varint(UInt64(field << 3)) + Self.varint(UInt64(bitPattern: value))
            return w
        }

        func bytes(_ field: Int, _ value: Data) -> W {
            var w = self
            w.data += Self.varint(UInt64(field << 3 | 2)) + Self.varint(UInt64(value.count)) + value
            return w
        }

        func str(_ field: Int, _ value: String) -> W { bytes(field, Data(value.utf8)) }
        func msg(_ field: Int, _ value: W) -> W { bytes(field, value.data) }

        /// Length-prefixed, as sent.
        var framed: Data { Self.varint(UInt64(data.count)) + data }
    }

    /// A received message: varints as Int64, length-delimited fields as Data (first of each field).
    struct R {
        private var fields: [Int: Any] = [:]

        init(_ bytes: Data) {
            let b = [UInt8](bytes)
            var i = 0
            func varint() -> UInt64? {
                var result: UInt64 = 0, shift: UInt64 = 0
                while i < b.count {
                    let byte = b[i]; i += 1
                    result |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return result }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }
            while i < b.count, let key = varint() {
                let field = Int(key >> 3)
                switch key & 7 {
                case 0:
                    guard let v = varint() else { return }
                    if fields[field] == nil { fields[field] = Int64(bitPattern: v) }
                case 2:
                    guard let n = varint(), i + Int(n) <= b.count else { return }
                    if fields[field] == nil { fields[field] = Data(b[i..<(i + Int(n))]) }
                    i += Int(n)
                case 1: i += 8
                case 5: i += 4
                default: return
                }
            }
        }

        func has(_ field: Int) -> Bool { fields[field] != nil }
        func int(_ field: Int) -> Int64? { fields[field] as? Int64 }
        func data(_ field: Int) -> Data? { fields[field] as? Data }
        func msg(_ field: Int) -> R? { data(field).map(R.init) }
        func string(_ field: Int) -> String? { data(field).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Takes one length-prefixed message off the front of `buffer`, if it's all there.
    static func takeMessage(from buffer: inout Data) -> Data? {
        var length: UInt64 = 0, shift: UInt64 = 0, i = buffer.startIndex
        while true {
            guard i < buffer.endIndex else { return nil }
            let byte = buffer[i]; i += 1
            length |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 35 { buffer.removeAll(); return nil }
        }
        guard buffer.endIndex - i >= Int(length) else { return nil }
        let message = Data(buffer[i..<(i + Int(length))])
        buffer.removeSubrange(buffer.startIndex..<(i + Int(length)))
        return message
    }
}

// MARK: Our certificate

/// This Mac's certificate for TVs: RSA 2048, self-signed, made once and kept (pairing ties it to each TV; the pairing
/// secret is made from both sides' RSA keys). Kept in Application Support, readable only by this user; nothing goes
/// into the keychain.
enum ATVIdentity {
    private static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/TVRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }

    private static let lock = NSLock()
    private static var cached: (identity: SecIdentity, publicKey: SecKey)?

    static func load() throws -> (identity: SecIdentity, publicKey: SecKey) {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let keyFile = folder.appendingPathComponent("key.der"), certFile = folder.appendingPathComponent("cert.der")
        let key: SecKey, cert: Data
        if let k = try? Data(contentsOf: keyFile), let c = try? Data(contentsOf: certFile),
           let made = SecKeyCreateWithData(k as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil),
           // The first certificates were named like the phone's, and a TV keeps one pairing per name: replace those.
           SecCertificateCreateWithData(nil, c as CFData).flatMap { SecCertificateCopySubjectSummary($0) as String? } == commonName {
            key = made; cert = c
        } else {
            var error: Unmanaged<CFError>?
            guard let made = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
                  let raw = SecKeyCopyExternalRepresentation(made, &error) as Data? else { throw ATVError.identity }
            key = made
            cert = try makeCertificate(key: made)
            FileManager.default.createFile(atPath: keyFile.path, contents: raw, attributes: [.posixPermissions: 0o600])
            try cert.write(to: certFile, options: .atomic)
            // A new certificate: no TV knows it yet.
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("tvremote.paired.") { defaults.removeObject(forKey: key) }
        }
        guard let certificate = SecCertificateCreateWithData(nil, cert as CFData), let publicKey = SecKeyCopyPublicKey(key) else { throw ATVError.identity }
        // SecIdentityCreate pairs a certificate with a key without a keychain (public in Security, not in the headers).
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "SecIdentityCreate"),
              let identity = unsafeBitCast(sym, to: Create.self)(nil, certificate, key)?.takeRetainedValue() else { throw ATVError.identity }
        cached = (identity, publicKey)
        return cached!
    }

    /// Unique to this Mac (a TV keeps one pairing per certificate name): "Janus remote <this Mac's KDE id>".
    static let commonName: String = {
        let pem = (try? String(contentsOf: LocalIdentity.folder.appendingPathComponent("certificate.pem"), encoding: .utf8)) ?? ""
        let der = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())
        let id = der.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return "Janus remote " + (id ?? Host.current().localizedName ?? UUID().uuidString)
    }()

    /// A minimal X.509 v3 certificate, signed with the key itself (SHA-256 with RSA).
    private static func makeCertificate(key: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(key), let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw ATVError.identity }
        let sha256RSA = DER.seq(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), DER.null)
        let rsa = DER.seq(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), DER.null)
        let name = DER.seq(DER.set(DER.seq(DER.oid([0x55, 0x04, 0x03]), DER.utf8(commonName))),
                           DER.set(DER.seq(DER.oid([0x55, 0x04, 0x0A]), DER.utf8("Janus"))))
        let now = Date()
        var serial = Data(count: 8)
        _ = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        serial[0] &= 0x7F
        let tbs = DER.seq(
            DER.tlv(0xA0, DER.int(Data([2]))),                       // v3
            DER.int(serial),
            sha256RSA,
            name,
            DER.seq(DER.utc(now.addingTimeInterval(-86_400)), DER.utc(now.addingTimeInterval(20 * 365 * 86_400))),
            name,
            DER.seq(rsa, DER.bitString(pkcs1))
        )
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else { throw ATVError.identity }
        return DER.seq(tbs, sha256RSA, DER.bitString(signature))
    }

    /// An RSA key's modulus and exponent, unsigned big-endian without leading zeros (for the pairing secret).
    static func rsaParts(_ key: SecKey) -> (modulus: Data, exponent: Data)? {
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        var reader = DER.Reader(pkcs1)
        guard let seq = reader.next(tag: 0x30) else { return nil }
        var inner = DER.Reader(seq)
        guard let n = inner.next(tag: 0x02), let e = inner.next(tag: 0x02) else { return nil }
        func trim(_ d: Data) -> Data { Data(d.drop { $0 == 0 }) }
        return (trim(n), trim(e))
    }
}

/// Just enough DER to write a certificate and read an RSA public key.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 { out.append(UInt8(n)) } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
        }
        return out + content
    }
    static func seq(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: Data...) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func int(_ value: Data) -> Data { tlv(0x02, (value.first ?? 0) & 0x80 != 0 ? Data([0]) + value : value) }
    static func oid(_ encoded: [UInt8]) -> Data { tlv(0x06, Data(encoded)) }
    static let null = Data([0x05, 0x00])
    static func utf8(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    static func bitString(_ d: Data) -> Data { tlv(0x03, Data([0]) + d) }
    static func utc(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }

    struct Reader {
        private let b: [UInt8]
        private var i = 0
        init(_ data: Data) { b = [UInt8](data) }
        mutating func next(tag: UInt8) -> Data? {
            guard i + 2 <= b.count, b[i] == tag else { return nil }
            i += 1
            var length = Int(b[i]); i += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, i + count <= b.count else { return nil }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(b[i]); i += 1 }
            }
            guard i + length <= b.count else { return nil }
            defer { i += length }
            return Data(b[i..<(i + length)])
        }
    }
}

enum ATVError: Error, Equatable {
    case identity          // couldn't make or read our certificate
    case refused           // nothing listening
    case unreachable
    case notPaired         // TLS refused or closed right away: the TV doesn't know our certificate
    case protocolError(String)
    case closed
}

// MARK: A TLS connection carrying framed messages

final class ATVChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atv.channel", qos: .userInitiated)
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<PB.R, Error>.Continuation?
    private let peerBox = PeerBox()
    let messages: AsyncThrowingStream<PB.R, Error>

    final class PeerBox: @unchecked Sendable { var certificate: SecCertificate? }

    /// The TV's certificate (its key goes into the pairing secret).
    var peerCertificate: SecCertificate? { queue.sync { peerBox.certificate } }

    init(host: String, port: UInt16, identity: SecIdentity) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        // The TV's certificate is self-signed; pairing is what makes it trusted.
        let box = peerBox
        let verifyQueue = queue
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            box.certificate = chain?.first
            complete(true)
        }, verifyQueue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: tcp))
        var c: AsyncThrowingStream<PB.R, Error>.Continuation?
        messages = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .waiting(let e) where !resumed && Self.map(e) != .refused:
                    break   // e.g. the network still settling: the timeout below decides
                case .waiting(let e), .failed(let e):
                    let error = Self.map(e)
                    if !resumed { resumed = true; self?.connection.cancel(); cont.resume(throwing: error) } else { self?.finish(error) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: ATVError.closed) } else { self?.finish(nil) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard !resumed else { return }
                resumed = true
                self?.connection.cancel()
                cont.resume(throwing: ATVError.unreachable)
            }
        }
        receive()
    }

    private static func map(_ e: NWError) -> ATVError {
        switch e {
        case .posix(let code) where code == .ECONNREFUSED: return .refused
        case .posix(let code) where [.ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN].contains(code): return .unreachable
        case .tls: return .notPaired
        default: return .protocolError(e.localizedDescription)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let message = PB.takeMessage(from: &self.buffer) { self.continuation?.yield(PB.R(message)) }
            if let error { self.finish(Self.map(error)) } else if done { self.finish(ATVError.closed) } else { self.receive() }
        }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.finish(throwing: error) } else { c.finish() }
        connection.cancel()
    }

    func send(_ message: PB.W) {
        connection.send(content: message.framed, completion: .contentProcessed { _ in })
    }

    func close() {
        queue.async { self.finish(nil) }
    }
}
