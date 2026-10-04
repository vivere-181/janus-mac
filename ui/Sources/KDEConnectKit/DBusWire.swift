import Foundation

enum DBusWireError: Error { case truncated, badSignature(String), badHeader }

/// Little-endian D-Bus marshaller. Offsets are relative to the start of the message,
/// which is where D-Bus alignment is measured from.
struct DBusEncoder {
    var data = Data()

    mutating func pad(_ n: Int) {
        let rem = data.count % n
        if rem != 0 { data.append(contentsOf: [UInt8](repeating: 0, count: n - rem)) }
    }

    mutating func raw<T: FixedWidthInteger>(_ v: T) {
        pad(MemoryLayout<T>.size)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func encode(_ v: DBusValue) {
        switch v {
        case .byte(let x): data.append(x)
        case .bool(let x): raw(UInt32(x ? 1 : 0))
        case .int16(let x): raw(x)
        case .uint16(let x): raw(x)
        case .int32(let x): raw(x)
        case .uint32(let x), .unixFD(let x): raw(x)
        case .int64(let x): raw(x)
        case .uint64(let x): raw(x)
        case .double(let x): raw(x.bitPattern)
        case .string(let s), .objectPath(let s):
            let bytes = Array(s.utf8)
            raw(UInt32(bytes.count)); data.append(contentsOf: bytes); data.append(0)
        case .signature(let s):
            let bytes = Array(s.utf8)
            data.append(UInt8(bytes.count)); data.append(contentsOf: bytes); data.append(0)
        case .array(let element, let items):
            encodeArray(elementAlignment: Self.alignment(of: element)) { enc in items.forEach { enc.encode($0) } }
        case .dict(_, _, let kv):
            encodeArray(elementAlignment: 8) { enc in
                for (k, v) in kv { enc.pad(8); enc.encode(k); enc.encode(v) }
            }
        case .structure(let vs):
            pad(8); vs.forEach { encode($0) }
        case .variant(let inner):
            encode(.signature(inner.signature)); encode(inner)
        }
    }

    private mutating func encodeArray(elementAlignment: Int, _ body: (inout DBusEncoder) -> Void) {
        raw(UInt32(0))
        let lengthAt = data.count - 4
        pad(elementAlignment)
        let start = data.count
        body(&self)
        let len = UInt32(data.count - start).littleEndian
        withUnsafeBytes(of: len) { data.replaceSubrange(lengthAt..<lengthAt + 4, with: $0) }
    }

    static func alignment(of sig: String) -> Int {
        switch sig.first {
        case "y", "g", "v": 1
        case "n", "q": 2
        case "x", "t", "d", "(", "{": 8
        default: 4
        }
    }
}

struct DBusDecoder {
    let data: Data
    var pos: Int
    let bigEndian: Bool

    init(data: Data, pos: Int = 0, bigEndian: Bool = false) {
        self.data = data; self.pos = pos; self.bigEndian = bigEndian
    }

    mutating func align(_ n: Int) { let rem = pos % n; if rem != 0 { pos += n - rem } }

    mutating func raw<T: FixedWidthInteger>(_: T.Type) throws -> T {
        align(MemoryLayout<T>.size)
        let size = MemoryLayout<T>.size
        guard pos + size <= data.count else { throw DBusWireError.truncated }
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: data.startIndex + pos ..< data.startIndex + pos + size)
        }
        pos += size
        return bigEndian ? T(bigEndian: v) : T(littleEndian: v)
    }

    mutating func byte() throws -> UInt8 {
        guard pos < data.count else { throw DBusWireError.truncated }
        defer { pos += 1 }
        return data[data.startIndex + pos]
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard pos + n <= data.count else { throw DBusWireError.truncated }
        defer { pos += n }
        return data.subdata(in: data.startIndex + pos ..< data.startIndex + pos + n)
    }

    mutating func decode(signature: String) throws -> [DBusValue] {
        var out: [DBusValue] = []
        for t in try Self.splitTypes(signature) { out.append(try decodeOne(t)) }
        return out
    }

    mutating func decodeOne(_ t: String) throws -> DBusValue {
        guard let c = t.first else { throw DBusWireError.badSignature(t) }
        switch c {
        case "y": return .byte(try byte())
        case "b": return .bool(try raw(UInt32.self) != 0)
        case "n": return .int16(try raw(Int16.self))
        case "q": return .uint16(try raw(UInt16.self))
        case "i": return .int32(try raw(Int32.self))
        case "u": return .uint32(try raw(UInt32.self))
        case "h": return .unixFD(try raw(UInt32.self))
        case "x": return .int64(try raw(Int64.self))
        case "t": return .uint64(try raw(UInt64.self))
        case "d": return .double(Double(bitPattern: try raw(UInt64.self)))
        case "s", "o":
            let n = Int(try raw(UInt32.self))
            let s = String(decoding: try bytes(n), as: UTF8.self); pos += 1
            return c == "s" ? .string(s) : .objectPath(s)
        case "g":
            let n = Int(try byte())
            let s = String(decoding: try bytes(n), as: UTF8.self); pos += 1
            return .signature(s)
        case "v":
            guard case .signature(let sig) = try decodeOne("g") else { throw DBusWireError.badSignature(t) }
            return .variant(try decodeOne(sig))
        case "(":
            align(8)
            let inner = String(t.dropFirst().dropLast())
            return .structure(try decode(signature: inner))
        case "a":
            let elem = String(t.dropFirst())
            let len = Int(try raw(UInt32.self))
            align(DBusEncoder.alignment(of: elem))
            let end = pos + len
            if elem.first == "{" {
                let kv = try Self.splitTypes(String(elem.dropFirst().dropLast()))
                guard kv.count == 2 else { throw DBusWireError.badSignature(t) }
                var pairs: [(DBusValue, DBusValue)] = []
                while pos < end {
                    align(8)
                    pairs.append((try decodeOne(kv[0]), try decodeOne(kv[1])))
                }
                return .dict(key: kv[0], value: kv[1], pairs)
            }
            if elem == "y" { // fast path for byte arrays
                let d = try bytes(len)
                return .array(element: "y", d.map { .byte($0) })
            }
            var items: [DBusValue] = []
            while pos < end { items.append(try decodeOne(elem)) }
            return .array(element: elem, items)
        default:
            throw DBusWireError.badSignature(t)
        }
    }

    /// Splits a signature into its complete top-level types.
    static func splitTypes(_ sig: String) throws -> [String] {
        let chars = Array(sig)
        var out: [String] = []
        var i = 0
        func one() throws -> String {
            guard i < chars.count else { throw DBusWireError.badSignature(sig) }
            let c = chars[i]; i += 1
            switch c {
            case "a": return "a" + (try one())
            case "(", "{":
                let close: Character = c == "(" ? ")" : "}"
                var s = String(c)
                while i < chars.count, chars[i] != close { s += try one() }
                guard i < chars.count else { throw DBusWireError.badSignature(sig) }
                i += 1
                return s + String(close)
            default: return String(c)
            }
        }
        while i < chars.count { out.append(try one()) }
        return out
    }
}

public struct DBusMessage: Sendable {
    public enum Kind: UInt8, Sendable { case methodCall = 1, methodReturn, error, signal }

    public var kind: Kind
    public var flags: UInt8 = 0
    public var serial: UInt32 = 0
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var body: [DBusValue] = []

    public init(kind: Kind) { self.kind = kind }

    func encoded() -> Data {
        let sig = body.map(\.signature).joined()
        var fields: [(UInt8, DBusValue)] = []
        if let path { fields.append((1, .objectPath(path))) }
        if let interface { fields.append((2, .string(interface))) }
        if let member { fields.append((3, .string(member))) }
        if let errorName { fields.append((4, .string(errorName))) }
        if let replySerial { fields.append((5, .uint32(replySerial))) }
        if let destination { fields.append((6, .string(destination))) }
        if !sig.isEmpty { fields.append((8, .signature(sig))) }

        var bodyEnc = DBusEncoder()
        body.forEach { bodyEnc.encode($0) }

        var enc = DBusEncoder()
        enc.data.append(contentsOf: [UInt8(ascii: "l"), kind.rawValue, flags, 1])
        enc.raw(UInt32(bodyEnc.data.count))
        enc.raw(serial)
        enc.encode(.array(element: "(yv)", fields.map { .structure([.byte($0.0), .variant($0.1)]) }))
        enc.pad(8)
        enc.data.append(bodyEnc.data)
        return enc.data
    }

    /// Returns the total message length once at least 16 bytes of it are available.
    static func totalLength(of header: Data) -> Int? {
        guard header.count >= 16 else { return nil }
        let big = header[header.startIndex] == UInt8(ascii: "B")
        var d = DBusDecoder(data: header, pos: 4, bigEndian: big)
        guard let bodyLen = try? d.raw(UInt32.self), (try? d.raw(UInt32.self)) != nil,
              let fieldsLen = try? d.raw(UInt32.self) else { return nil }
        let headerEnd = 16 + Int(fieldsLen)
        let padded = (headerEnd + 7) & ~7
        return padded + Int(bodyLen)
    }

    static func decode(_ data: Data) throws -> DBusMessage {
        guard data.count >= 16, let kind = Kind(rawValue: data[data.startIndex + 1]) else { throw DBusWireError.badHeader }
        let big = data[data.startIndex] == UInt8(ascii: "B")
        var d = DBusDecoder(data: data, pos: 4, bigEndian: big)
        var m = DBusMessage(kind: kind)
        m.flags = data[data.startIndex + 2]
        let bodyLen = Int(try d.raw(UInt32.self))
        m.serial = try d.raw(UInt32.self)
        var sig = ""
        if case .array(_, let fields) = try d.decodeOne("a(yv)") {
            for f in fields {
                guard case .structure(let parts) = f, parts.count == 2, case .byte(let code) = parts[0] else { continue }
                let v = parts[1].unwrapped
                switch code {
                case 1: m.path = v.string
                case 2: m.interface = v.string
                case 3: m.member = v.string
                case 4: m.errorName = v.string
                case 5: m.replySerial = v.int.map(UInt32.init)
                case 6: m.destination = v.string
                case 7: m.sender = v.string
                case 8: sig = v.string ?? ""
                default: break
                }
            }
        }
        d.align(8)
        guard d.pos + bodyLen <= data.count else { throw DBusWireError.truncated }
        if !sig.isEmpty { m.body = try d.decode(signature: sig) }
        return m
    }
}
