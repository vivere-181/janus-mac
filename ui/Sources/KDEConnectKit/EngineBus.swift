import Foundation

/// The connection engine as the app sees it: method calls, properties and signals on KDE Connect's object model
/// (`/modules/kdeconnect`, `/modules/kdeconnect/devices/<id>[/<plugin>]`), answered in-process by Janus's own engine
/// (R40). The shape is the one KDE's daemon had on D-Bus, which the app was built against.
public protocol EngineBus: AnyObject, Sendable {
    typealias SignalHandler = @Sendable (DBusMessage) -> Void

    var isConnected: Bool { get }
    var onClose: (@Sendable () -> Void)? { get set }
    func call(destination: String, path: String, interface: String, member: String, _ args: [DBusValue]) async throws -> [DBusValue]
    /// Fire-and-forget call (no reply expected).
    func send(destination: String, path: String, interface: String, member: String, _ args: [DBusValue])
    @discardableResult func addSignalHandler(_ handler: @escaping SignalHandler) -> UUID
    func shutdown()
}

public extension EngineBus {
    func call(destination: String, path: String, interface: String, member: String) async throws -> [DBusValue] {
        try await call(destination: destination, path: path, interface: interface, member: member, [])
    }

    func send(destination: String, path: String, interface: String, member: String) {
        send(destination: destination, path: path, interface: interface, member: member, [])
    }

    func addMatch(_ rule: String) async throws {
        _ = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                           interface: "org.freedesktop.DBus", member: "AddMatch", [.string(rule)])
    }

    func nameHasOwner(_ name: String) async -> Bool {
        let r = try? await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                interface: "org.freedesktop.DBus", member: "NameHasOwner", [.string(name)])
        return r?.first?.bool ?? false
    }

    func getProperty(destination: String, path: String, interface: String, name: String) async throws -> DBusValue {
        let r = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                               member: "Get", [.string(interface), .string(name)])
        return r.first?.unwrapped ?? .structure([])
    }

    func getAllProperties(destination: String, path: String, interface: String) async throws -> [String: DBusValue] {
        let r = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                               member: "GetAll", [.string(interface)])
        return (r.first?.dictionary ?? [:]).mapValues(\.unwrapped)
    }

    func setProperty(destination: String, path: String, interface: String, name: String, value: DBusValue) async throws {
        _ = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                           member: "Set", [.string(interface), .string(name), .variant(value)])
    }
}

/// The engine's well-known names.
public enum EnginePaths {
    public static let service = "org.kde.kdeconnect"
    public static let daemonPath = "/modules/kdeconnect"
}

public struct DBusError: Error, LocalizedError, Sendable {
    public let name: String
    public let message: String
    public init(name: String, message: String) { self.name = name; self.message = message }
    public var errorDescription: String? { message.isEmpty ? name : message }
}
