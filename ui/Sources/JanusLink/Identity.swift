import CryptoKit
import Foundation
import Security

/// This Mac on the network: its device id, name and type, and the TLS identity it pairs with. Kept in Janus's own
/// folder; made on first use, or taken over from the previous engine's folder so existing pairings carry over.
public struct LocalIdentity: @unchecked Sendable {
    public let deviceID: String
    public var name: String
    public var type: String
    public let identity: SecIdentity
    public let certificateDER: Data
    /// The certificate's public key (SubjectPublicKeyInfo DER), for pairing verification codes.
    public let publicKeyInfo: Data
    public var incomingCapabilities: [String]
    public var outgoingCapabilities: [String]

    public static let protocolVersion = 8

    /// `~/Library/Application Support/Android/Engine` (the app's support folder keeps its first name).
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Engine", isDirectory: true)
    }

    /// Where KDE Connect's engine kept the same files, before Janus had its own engine.
    static var legacyFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/kdeconnect", isDirectory: true)
    }

    /// Makes sure there's an identity: copied from the previous engine's folder the first time (pairings, per-device
    /// settings), otherwise a new one (a P-256 key and a self-signed certificate named after a new device id).
    public static func prepare() throws {
        let fm = FileManager.default
        let cert = folder.appendingPathComponent("certificate.pem")
        guard !fm.fileExists(atPath: cert.path) else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: legacyFolder.appendingPathComponent("certificate.pem").path) {
            for item in try fm.contentsOfDirectory(atPath: legacyFolder.path) where !fm.fileExists(atPath: folder.appendingPathComponent(item).path) {
                try fm.copyItem(at: legacyFolder.appendingPathComponent(item), to: folder.appendingPathComponent(item))
            }
            return
        }
        let key = P256.Signing.PrivateKey()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let der = try Certificates.selfSigned(commonName: id, key: key)
        fm.createFile(atPath: folder.appendingPathComponent("privateKey.pem").path, contents: Data(key.pemRepresentation.utf8),
                      attributes: [.posixPermissions: 0o600])
        try PEM.encode(der, label: "CERTIFICATE").write(to: cert, atomically: true, encoding: .utf8)
        let name = Host.current().localizedName ?? "Mac"
        try "[General]\nname=\(name)\n".write(to: folder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    public static func load(type: String = "laptop", incoming: [String], outgoing: [String],
                            folder: URL = LocalIdentity.folder) throws -> LocalIdentity {
        if folder == LocalIdentity.folder { try prepare() }
        let certPEM = try String(contentsOf: folder.appendingPathComponent("certificate.pem"), encoding: .utf8)
        let keyPEM = try String(contentsOf: folder.appendingPathComponent("privateKey.pem"), encoding: .utf8)
        guard let der = PEM.der(certPEM), let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw LinkError.identity("can't read certificate.pem")
        }
        let key = try PEM.privateKey(keyPEM)
        // SecIdentityCreate pairs a certificate with a key without a keychain (public in Security, not in the headers).
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "SecIdentityCreate"),
              let identity = unsafeBitCast(sym, to: Create.self)(nil, cert, key)?.takeRetainedValue() else {
            throw LinkError.identity("can't make the TLS identity")
        }
        let id = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""
        guard id.range(of: "^[A-Za-z0-9_]{32,38}$", options: .regularExpression) != nil else { throw LinkError.identity("bad device id \(id)") }
        let config = (try? String(contentsOf: folder.appendingPathComponent("config"), encoding: .utf8)) ?? ""
        let name = INI.sections(config)["General"]?["name"] ?? Host.current().localizedName ?? "Mac"
        return LocalIdentity(deviceID: id, name: name, type: type, identity: identity, certificateDER: der,
                             publicKeyInfo: Certificates.publicKeyInfo(der) ?? Data(),
                             incomingCapabilities: incoming, outgoingCapabilities: outgoing)
    }

    /// The identity packet: broadcast, sent before TLS, and again inside it.
    public func identityPacket(tcpPort: Int? = nil, target: (id: String, version: Int)? = nil) -> Packet {
        var p = Packet(PacketType.identity, [
            "deviceId": deviceID, "deviceName": name, "deviceType": type,
            "protocolVersion": Self.protocolVersion,
            "incomingCapabilities": incomingCapabilities, "outgoingCapabilities": outgoingCapabilities,
        ])
        if let tcpPort { p["tcpPort"] = tcpPort }
        if let target { p["targetDeviceId"] = target.id; p["targetProtocolVersion"] = target.version }
        return p
    }
}

/// The devices this Mac is paired with: their certificates (pinned) and what they were last called.
/// Kept in the previous engine's `trusted_devices` file, so both engines see the same pairings during the switch.
public final class TrustStore: @unchecked Sendable {
    public struct Device: Sendable {
        public let id: String
        public var name: String
        public var type: String
        public var protocolVersion: Int
        public var certificateDER: Data

        public init(id: String, name: String, type: String, protocolVersion: Int, certificateDER: Data) {
            self.id = id; self.name = name; self.type = type; self.protocolVersion = protocolVersion; self.certificateDER = certificateDER
        }
    }

    private let file: URL
    private let lock = NSLock()

    public init(file: URL = LocalIdentity.folder.appendingPathComponent("trusted_devices")) { self.file = file }

    public func all() -> [Device] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    public func device(_ id: String) -> Device? { all().first { $0.id == id } }

    public func isTrusted(_ id: String) -> Bool { device(id) != nil }

    public func add(_ d: Device) {
        lock.lock(); defer { lock.unlock() }
        var list = read().filter { $0.id != d.id }
        list.append(d)
        write(list)
    }

    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { $0.id != id })
    }

    private func read() -> [Device] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return INI.sections(text).compactMap { id, values in
            guard let pem = values["certificate"], let der = PEM.der(pem.replacingOccurrences(of: "\\n", with: "\n")) else { return nil }
            return Device(id: id, name: values["name"] ?? id, type: values["type"] ?? "phone",
                          protocolVersion: Int(values["protocolVersion"] ?? "") ?? 8, certificateDER: der)
        }.sorted { $0.id < $1.id }
    }

    private func write(_ list: [Device]) {
        var out = ""
        for d in list {
            let pem = PEM.encode(d.certificateDER, label: "CERTIFICATE").replacingOccurrences(of: "\n", with: "\\n")
            out += "[\(d.id)]\ncertificate=\(pem)\nname=\(d.name)\nprotocolVersion=\(d.protocolVersion)\ntype=\(d.type)\n\n"
        }
        try? out.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// QSettings-style INI, as much as the engine's files use.
enum INI {
    static func sections(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { current = String(line.dropFirst().dropLast()); result[current!] = [:]; continue }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            result[section]?[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }
}

enum PEM {
    static func der(_ pem: String) -> Data? {
        Data(base64Encoded: pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined())
    }

    static func encode(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j])); i = j
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    /// The engine's key: EC P-256 ("EC PRIVATE KEY" or PKCS#8) or, on older installs, RSA.
    static func privateKey(_ pem: String) throws -> SecKey {
        if let ec = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            guard let key = SecKeyCreateWithData(ec.x963Representation as CFData,
                                                 [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)
            else { throw LinkError.identity("bad EC key") }
            return key
        }
        guard var der = der(pem) else { throw LinkError.identity("bad key file") }
        if pem.contains("BEGIN PRIVATE KEY") { der = Certificates.pkcs8Inner(der) ?? der }   // PKCS#8 → PKCS#1
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)
        else { throw LinkError.identity("unsupported key") }
        return key
    }
}

/// Just enough X.509/DER reading for the protocol.
public enum Certificates {
    /// A certificate's SubjectPublicKeyInfo (what Java's `publicKey.encoded` returns), used for verification codes.
    public static func publicKeyInfo(_ certificate: Data) -> Data? {
        var r = DERReader(certificate)
        guard let cert = r.read(0x30) else { return nil }
        var c = DERReader(cert.content)
        guard let tbs = c.read(0x30) else { return nil }
        var t = DERReader(tbs.content)
        if t.peek == 0xA0 { _ = t.read(0xA0) }            // version
        for tag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] { guard t.read(tag) != nil else { return nil } }   // serial, alg, issuer, validity, subject
        return t.read(0x30)?.whole
    }

    /// A self-signed X.509 v3 certificate for a P-256 key (ECDSA with SHA-256): subject CN=<device id>, as the
    /// protocol expects; valid from a year ago for ten years.
    static func selfSigned(commonName: String, key: P256.Signing.PrivateKey) throws -> Data {
        func tlv(_ tag: UInt8, _ c: Data) -> Data {
            var out = Data([tag]); let n = c.count
            if n < 0x80 { out.append(UInt8(n)) } else {
                var b: [UInt8] = []; var v = n
                while v > 0 { b.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
                out.append(0x80 | UInt8(b.count)); out.append(contentsOf: b)
            }
            return out + c
        }
        func seq(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
        func oid(_ b: [UInt8]) -> Data { tlv(0x06, Data(b)) }
        func time(_ d: Date) -> Data {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(f.string(from: d).utf8))
        }
        let ecdsaSHA256 = seq(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = seq(tlv(0x31, seq(oid([0x55, 0x04, 0x03]), tlv(0x0C, Data(commonName.utf8)))),
                       tlv(0x31, seq(oid([0x55, 0x04, 0x0A]), tlv(0x0C, Data("Janus".utf8)))))
        let spki = seq(seq(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]), oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])),
                       tlv(0x03, Data([0]) + key.publicKey.x963Representation))
        let now = Date()
        let tbs = seq(tlv(0xA0, tlv(0x02, Data([2]))), tlv(0x02, Data([1])), ecdsaSHA256, name,
                      seq(time(now.addingTimeInterval(-365 * 86_400)), time(now.addingTimeInterval(10 * 365 * 86_400))), name, spki)
        let signature = try key.signature(for: tbs).derRepresentation
        return seq(tbs, ecdsaSHA256, tlv(0x03, Data([0]) + signature))
    }

    /// The private key inside a PKCS#8 wrapper.
    static func pkcs8Inner(_ der: Data) -> Data? {
        var r = DERReader(der)
        guard let seq = r.read(0x30) else { return nil }
        var s = DERReader(seq.content)
        guard s.read(0x02) != nil, s.read(0x30) != nil, let octets = s.read(0x04) else { return nil }
        return octets.content
    }

    /// SHA-256 of a certificate, as hex (for logs and comparisons).
    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}

struct DERReader {
    struct Element { let tag: UInt8; let content: Data; let whole: Data }
    private let b: [UInt8]
    private var i = 0
    init(_ d: Data) { b = [UInt8](d) }
    var peek: UInt8? { i < b.count ? b[i] : nil }

    mutating func read(_ tag: UInt8) -> Element? {
        let start = i
        guard i + 2 <= b.count, b[i] == tag else { return nil }
        i += 1
        var length = Int(b[i]); i += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n <= 4, i + n <= b.count else { return nil }
            length = 0
            for _ in 0..<n { length = length << 8 | Int(b[i]); i += 1 }
        }
        guard i + length <= b.count else { return nil }
        defer { i += length }
        return Element(tag: tag, content: Data(b[i..<(i + length)]), whole: Data(b[start..<(i + length)]))
    }
}
