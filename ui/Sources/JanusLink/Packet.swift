import Foundation

/// One message of the KDE Connect protocol (version 8): a line of JSON, `{"id", "type", "body"}`, plus
/// `payloadSize` and `payloadTransferInfo` when a file follows on its own connection.
public struct Packet: @unchecked Sendable {
    public var type: String
    public var body: [String: Any]
    public var payloadSize: Int64?
    public var payloadTransferInfo: [String: Any]?

    public init(_ type: String, _ body: [String: Any] = [:]) {
        self.type = type
        self.body = body
    }

    /// Newline-terminated JSON, as sent.
    public func serialized() -> Data {
        var o: [String: Any] = ["id": Int64(Date().timeIntervalSince1970 * 1000), "type": type, "body": body]
        if let payloadSize { o["payloadSize"] = payloadSize }
        if let payloadTransferInfo { o["payloadTransferInfo"] = payloadTransferInfo }
        var data = (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    public init?(line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        self.type = type
        body = o["body"] as? [String: Any] ?? [:]
        payloadSize = (o["payloadSize"] as? NSNumber)?.int64Value
        payloadTransferInfo = o["payloadTransferInfo"] as? [String: Any]
    }

    // Typed access to the body.
    public func string(_ key: String) -> String? { body[key] as? String }
    public func bool(_ key: String) -> Bool? { (body[key] as? NSNumber)?.boolValue }
    public func int(_ key: String) -> Int? { (body[key] as? NSNumber)?.intValue }
    public func int64(_ key: String) -> Int64? { (body[key] as? NSNumber)?.int64Value }
    public func strings(_ key: String) -> [String] { body[key] as? [String] ?? [] }
    public subscript(key: String) -> Any? {
        get { body[key] }
        set { body[key] = newValue }
    }
}

public enum PacketType {
    public static let identity = "kdeconnect.identity"
    public static let pair = "kdeconnect.pair"
}

/// Splits a byte stream into lines (packets), bounded so a broken peer can't make us buffer forever.
struct LineBuffer {
    private var data = Data()
    let limit: Int

    init(limit: Int = 32 << 20) { self.limit = limit }

    /// Appends bytes and returns the complete lines (without the newline). Throws if a line grows past the limit.
    mutating func append(_ bytes: Data) throws -> [Data] {
        data.append(bytes)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            data.removeSubrange(data.startIndex...nl)
        }
        if data.count > limit { throw LinkError.protocolError("line too long") }
        return lines
    }
}

public enum LinkError: Error, Equatable {
    case protocolError(String)
    case notTrusted
    case closed
    case timeout
    case identity(String)
}
