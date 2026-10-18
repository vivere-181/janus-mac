import CryptoKit
import Foundation

/// Janus Cloud's cryptography, exactly as shared/CLOUD.md §2, §5 and §6 specify (the phone does the same bytes).
enum CloudCrypto {
    /// This device's keys: Ed25519 to sign in to the relay, X25519 to encrypt for the paired devices.
    struct Identity {
        let sign: Curve25519.Signing.PrivateKey
        let box: Curve25519.KeyAgreement.PrivateKey

        static func new() -> Identity { Identity(sign: .init(), box: .init()) }

        var id: String { CloudCrypto.deviceID(sign: sign.publicKey.rawRepresentation) }
        var signPublic: String { sign.publicKey.rawRepresentation.base64EncodedString() }
        var boxPublic: String { box.publicKey.rawRepresentation.base64EncodedString() }
    }

    /// First 16 bytes of SHA-256 of the Ed25519 public key, lowercase hex.
    static func deviceID(sign publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The relay sign-in signature: Ed25519 over "janus-auth v1|<id>|<unix seconds>".
    static func signIn(_ me: Identity, at ts: Int64) throws -> String {
        try me.sign.signature(for: Data("janus-auth v1|\(me.id)|\(ts)".utf8)).base64EncodedString()
    }

    /// The key two devices share: HKDF-SHA256 over their X25519 secret, salt "janus-cloud v1",
    /// info "<smaller id>|<larger id>".
    static func pairKey(_ me: Identity, peerBox: Data, peerID: String) throws -> SymmetricKey {
        let secret = try me.box.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peerBox))
        let ids = [me.id, peerID].sorted()
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("janus-cloud v1".utf8),
                                              sharedInfo: Data("\(ids[0])|\(ids[1])".utf8), outputByteCount: 32)
    }

    static func envelopeAAD(from: String, to: String) -> Data { Data("janus-env v1|\(from)|\(to)".utf8) }

    /// base64(nonce ‖ ciphertext ‖ tag), ChaCha20-Poly1305 with a random nonce.
    static func seal(_ plaintext: Data, key: SymmetricKey, from: String, to: String) throws -> String {
        try ChaChaPoly.seal(plaintext, using: key, authenticating: envelopeAAD(from: from, to: to)).combined.base64EncodedString()
    }

    static func open(_ box: String, key: SymmetricKey, from: String, to: String) throws -> Data {
        guard let data = Data(base64Encoded: box) else { throw CryptoKitError.incorrectParameterSize }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key, authenticating: envelopeAAD(from: from, to: to))
    }

    // MARK: File chunks

    static let chunkSize = 4 << 20

    static func chunkCount(size: Int64) -> Int { max(1, Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))) }

    /// What the relay stores for a file: its size plus a 16-byte tag per chunk.
    static func encryptedSize(size: Int64) -> Int64 { size + 16 * Int64(chunkCount(size: size)) }

    /// 4 zero bytes and the chunk's index as 8 bytes, big-endian: unique per chunk under the file's own key.
    static func chunkNonce(_ index: Int) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func chunkAAD(blob: String, index: Int, count: Int) -> Data { Data("janus-chunk v1|\(blob)|\(index)|\(count)".utf8) }

    /// ciphertext ‖ tag (the nonce follows from the index).
    static func sealChunk(_ plaintext: Data, key: SymmetricKey, blob: String, index: Int, count: Int) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: chunkNonce(index), authenticating: chunkAAD(blob: blob, index: index, count: count))
        return box.ciphertext + box.tag
    }

    static func openChunk(_ data: Data, key: SymmetricKey, blob: String, index: Int, count: Int) throws -> Data {
        guard data.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: chunkNonce(index), ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: chunkAAD(blob: blob, index: index, count: count))
    }
}
