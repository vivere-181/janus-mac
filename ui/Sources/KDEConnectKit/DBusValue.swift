import Foundation

/// A D-Bus value with enough type information to be marshalled back onto the wire.
public indirect enum DBusValue: CustomStringConvertible, Sendable {
    case byte(UInt8)
    case bool(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case unixFD(UInt32)
    /// Array of values that all have signature `element`.
    case array(element: String, [DBusValue])
    /// Dictionary (`a{kv}`), keeping wire order.
    case dict(key: String, value: String, [(DBusValue, DBusValue)])
    case structure([DBusValue])
    case variant(DBusValue)

    public var signature: String {
        switch self {
        case .byte: "y"
        case .bool: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case .array(let e, _): "a" + e
        case .dict(let k, let v, _): "a{" + k + v + "}"
        case .structure(let vs): "(" + vs.map(\.signature).joined() + ")"
        case .variant: "v"
        }
    }

    public var description: String {
        switch self {
        case .byte(let v): "\(v)"
        case .bool(let v): "\(v)"
        case .int16(let v): "\(v)"
        case .uint16(let v): "\(v)"
        case .int32(let v): "\(v)"
        case .uint32(let v): "\(v)"
        case .int64(let v): "\(v)"
        case .uint64(let v): "\(v)"
        case .double(let v): "\(v)"
        case .string(let v): "\"\(v)\""
        case .objectPath(let v): "o\"\(v)\""
        case .signature(let v): "g\"\(v)\""
        case .unixFD(let v): "fd\(v)"
        case .array(let e, let vs):
            e == "y" ? "bytes[\(vs.count)]" : "[" + vs.map(\.description).joined(separator: ", ") + "]"
        case .dict(_, _, let kv): "{" + kv.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "}"
        case .structure(let vs): "(" + vs.map(\.description).joined(separator: ", ") + ")"
        case .variant(let v): "<\(v)>"
        }
    }

    // MARK: Convenience accessors (variants are unwrapped transparently)

    public var unwrapped: DBusValue {
        if case .variant(let v) = self { return v.unwrapped }
        return self
    }

    public var string: String? {
        switch unwrapped {
        case .string(let s), .objectPath(let s), .signature(let s): s
        default: nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = unwrapped { return b }
        return nil
    }

    public var int: Int? {
        switch unwrapped {
        case .byte(let v): Int(v)
        case .int16(let v): Int(v)
        case .uint16(let v): Int(v)
        case .int32(let v): Int(v)
        case .uint32(let v): Int(v)
        case .int64(let v): Int(v)
        case .uint64(let v): Int(truncatingIfNeeded: v)
        case .double(let v): Int(v)
        default: nil
        }
    }

    public var double: Double? {
        if case .double(let d) = unwrapped { return d }
        return int.map(Double.init)
    }

    public var array: [DBusValue]? {
        switch unwrapped {
        case .array(_, let vs), .structure(let vs): vs
        default: nil
        }
    }

    public var strings: [String]? { array?.compactMap(\.string) }

    public var bytes: Data? {
        guard case .array("y", let vs) = unwrapped else { return nil }
        return Data(vs.compactMap { if case .byte(let b) = $0 { return b } else { return nil } })
    }

    /// `a{s?}` as a Swift dictionary keyed by string.
    public var dictionary: [String: DBusValue]? {
        guard case .dict(_, _, let kv) = unwrapped else { return nil }
        var out: [String: DBusValue] = [:]
        for (k, v) in kv { if let key = k.string { out[key] = v } }
        return out
    }

    public subscript(key: String) -> DBusValue? { dictionary?[key] }
}

extension DBusValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public extension DBusValue {
    static func strings(_ values: [String]) -> DBusValue { .array(element: "s", values.map { .string($0) }) }
}
