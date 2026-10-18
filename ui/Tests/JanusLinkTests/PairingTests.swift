import CryptoKit
import Foundation
import Security
import Testing
@testable import JanusLink

/// Known answers from Janus for Android's own tests (PairingHandlerTest), so both apps show the same code.
struct PairingTests {
    let certA = Data(base64Encoded: "MIIBkzCCATmgAwIBAgIBATAKBggqhkjOPQQDBDBTMS0wKwYDVQQDDCRlZTA2MWE3NV9lNDAzXzRlY2NfOTI2MV81ZmZlMjcyMmY2OTgxFDASBgNVBAsMC0tERSBDb25uZWN0MQwwCgYDVQQKDANLREUwHhcNMjMwOTE1MjIwMDAwWhcNMzQwOTE1MjIwMDAwWjBTMS0wKwYDVQQDDCRlZTA2MWE3NV9lNDAzXzRlY2NfOTI2MV81ZmZlMjcyMmY2OTgxFDASBgNVBAsMC0tERSBDb25uZWN0MQwwCgYDVQQKDANLREUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASqOIKTm5j6x8DKgYSkItLmjCgIXP0gkOW6bmVvloDGsYnvqYLMFGe7YW8g8lT/qPBTEfDOM4UpQ8X6jidE+XrnMAoGCCqGSM49BAMEA0gAMEUCIEpk6VNpbt3tfbWDf0TmoJftRq3wAs3Dke7d5vMZlivyAiEA/ZXtSRqPjs/2RN9SynKhSUA9/z0PNq6LYoAaC6TdomM=")!
    let certB = Data(base64Encoded: "MIIBkzCCATmgAwIBAgIBATAKBggqhkjOPQQDBDBTMS0wKwYDVQQDDCQxNTdiYmMyOF82ZjJiXzRiMTZfYmQwMl8xMzM0NWMwMjU0M2MxFDASBgNVBAsMC0tERSBDb25uZWN0MQwwCgYDVQQKDANLREUwHhcNMjQwMTE3MjMwMDAwWhcNMzUwMTE3MjMwMDAwWjBTMS0wKwYDVQQDDCQxNTdiYmMyOF82ZjJiXzRiMTZfYmQwMl8xMzM0NWMwMjU0M2MxFDASBgNVBAsMC0tERSBDb25uZWN0MQwwCgYDVQQKDANLREUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ5W53rrDJps9v/sszQf0eLtvoGiRbfsY+snO6IJJfi1pFeHDQj2nAE+aTyUYelrcx1eIuqxFHnJTFt/HqXwuAvMAoGCCqGSM49BAMEA0gAMEUCIBIk3zKPz/M0c82nvCGFDXGGmfdojHsx3G5DbYNNKqFVAiEAzhBGe960/4NDiaVcOplBaeg5xNJKs3Kq+22J6JOii4Y=")!

    @Test func verificationKeyMatchesAndroid() throws {
        let a = try #require(Certificates.publicKeyInfo(certA))
        let b = try #require(Certificates.publicKeyInfo(certB))
        #expect(Pairing.verificationKey(a, b, timestamp: 1737228658) == "54DC916E")
        #expect(Pairing.verificationKey(b, a, timestamp: 1737228658) == "54DC916E")
        #expect(Pairing.verificationKey(a, b, timestamp: 2737228658) == "8C07153A")
    }

    @Test func packetRoundTrip() throws {
        var p = Packet("kdeconnect.share.request", ["filename": "a/b.txt", "n": 3])
        p.payloadSize = 42
        p.payloadTransferInfo = ["port": 1739]
        let data = p.serialized()
        #expect(data.last == 0x0A)
        #expect(!String(decoding: data, as: UTF8.self).contains("\\/"))   // slashes unescaped, like KDE
        let back = try #require(Packet(line: data.dropLast()))
        #expect(back.type == p.type && back.string("filename") == "a/b.txt" && back.int("n") == 3 && back.payloadSize == 42)
    }

    @Test func lineBufferSplitsPackets() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Data("{\"a\":1}\n{\"b".utf8)).count == 1)
        #expect(try buffer.append(Data("\":2}\n".utf8)).count == 1)
    }
}

/// A new Mac's identity (no previous engine): a valid self-signed certificate named after the device id.
struct IdentityTests {
    @Test func selfSignedCertificateIsValid() throws {
        let key = P256.Signing.PrivateKey()
        let id = "0123456789abcdef0123456789abcdef"
        let der = try Certificates.selfSigned(commonName: id, key: key)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == id)
        let pub = try #require(SecCertificateCopyKey(cert))
        #expect(SecKeyCopyExternalRepresentation(pub, nil) as Data? == key.publicKey.x963Representation)
        #expect(Certificates.publicKeyInfo(der) != nil)
        try PEM.encode(der, label: "CERTIFICATE").write(toFile: NSTemporaryDirectory() + "janus-test-cert.pem", atomically: true, encoding: .utf8)
    }
}
