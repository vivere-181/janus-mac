import Foundation

/// A call or signal in the engine's object model (the shape KDE Connect's daemon used on D-Bus, kept in memory).
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
}
