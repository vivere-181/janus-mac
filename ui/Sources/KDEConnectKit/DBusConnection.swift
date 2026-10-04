import Foundation
import Darwin

public struct DBusError: Error, LocalizedError, Sendable {
    public let name: String
    public let message: String
    public init(name: String, message: String) { self.name = name; self.message = message }
    public var errorDescription: String? { message.isEmpty ? name : message }
}

/// Minimal D-Bus client over a unix socket: method calls, properties and signals.
public final class DBusConnection: @unchecked Sendable {
    public typealias SignalHandler = @Sendable (DBusMessage) -> Void

    private let fd: Int32
    private let lock = NSLock()
    private var nextSerial: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<DBusMessage, Error>] = [:]
    private var signalHandlers: [UUID: SignalHandler] = [:]
    private var closed = false
    public private(set) var uniqueName = ""
    public var onClose: (@Sendable () -> Void)?

    /// Connects to an address like `unix:path=/tmp/dbus-XXXX,guid=...`.
    public init(address: String) throws {
        guard let path = address.split(separator: ";").lazy.compactMap({ entry -> String? in
            guard entry.hasPrefix("unix:") else { return nil }
            return entry.dropFirst(5).split(separator: ",").first { $0.hasPrefix("path=") }.map { String($0.dropFirst(5)) }
        }).first else { throw DBusError(name: "BadAddress", message: "Unsupported D-Bus address \(address)") }

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DBusError(name: "Socket", message: String(cString: strerror(errno))) }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw DBusError(name: "BadAddress", message: "Socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes); buf[pathBytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            let err = String(cString: strerror(errno)); close(fd)
            throw DBusError(name: "Connect", message: "Cannot connect to \(path): \(err)")
        }
        try authenticate()
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { shutdown() }

    public func shutdown() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let waiting = pending; pending = [:]
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        waiting.values.forEach { $0.resume(throwing: DBusError(name: "Disconnected", message: "Connection closed")) }
        onClose?()
    }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    // MARK: Auth

    private func authenticate() throws {
        let uidHex = String(getuid()).utf8.map { String(format: "%02x", $0) }.joined()
        try writeAll(Data([0]) + Data("AUTH EXTERNAL \(uidHex)\r\n".utf8))
        let reply = try readLine()
        guard reply.hasPrefix("OK") else { throw DBusError(name: "Auth", message: "Authentication rejected: \(reply)") }
        try writeAll(Data("BEGIN\r\n".utf8))
    }

    private func readLine() throws -> String {
        var line = Data()
        var c: UInt8 = 0
        while true {
            let n = read(fd, &c, 1)
            guard n == 1 else { throw DBusError(name: "Auth", message: "Connection closed during auth") }
            if c == UInt8(ascii: "\n") { break }
            line.append(c)
        }
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw DBusError(name: "Write", message: String(cString: strerror(errno))) }
                off += n
            }
        }
    }

    // MARK: Reading

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            buffer.append(contentsOf: chunk[0..<n])
            while let total = DBusMessage.totalLength(of: buffer), buffer.count >= total {
                let msgData = buffer.prefix(total)
                buffer = Data(buffer.dropFirst(total))
                if let msg = try? DBusMessage.decode(Data(msgData)) { dispatch(msg) }
            }
        }
        shutdown()
    }

    private func dispatch(_ msg: DBusMessage) {
        switch msg.kind {
        case .methodReturn, .error:
            guard let rs = msg.replySerial else { return }
            lock.lock(); let cont = pending.removeValue(forKey: rs); lock.unlock()
            if msg.kind == .error {
                cont?.resume(throwing: DBusError(name: msg.errorName ?? "Error", message: msg.body.first?.string ?? ""))
            } else {
                cont?.resume(returning: msg)
            }
        case .signal:
            lock.lock(); let handlers = Array(signalHandlers.values); lock.unlock()
            handlers.forEach { $0(msg) }
        case .methodCall:
            // We export nothing; reply with an error so callers don't hang (e.g. Peer.Ping).
            var err = DBusMessage(kind: .error)
            err.errorName = "org.freedesktop.DBus.Error.UnknownMethod"
            err.replySerial = msg.serial
            err.destination = msg.sender
            err.flags = 1
            err.body = [.string("No such method")]
            send(err)
        }
    }

    // MARK: Sending

    @discardableResult
    private func send(_ message: DBusMessage) -> UInt32 {
        lock.lock()
        var m = message
        m.serial = nextSerial; nextSerial &+= 1
        let data = m.encoded()
        let ok = !closed
        lock.unlock()
        if ok { try? writeAll(data) }
        return m.serial
    }

    public func call(destination: String, path: String, interface: String, member: String,
                     _ args: [DBusValue] = []) async throws -> [DBusValue] {
        var m = DBusMessage(kind: .methodCall)
        m.destination = destination; m.path = path; m.interface = interface; m.member = member; m.body = args
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DBusMessage, Error>) in
            lock.lock()
            guard !closed else {
                lock.unlock(); cont.resume(throwing: DBusError(name: "Disconnected", message: "Connection closed")); return
            }
            m.serial = nextSerial; nextSerial &+= 1
            pending[m.serial] = cont
            let data = m.encoded()
            lock.unlock()
            do { try writeAll(data) } catch {
                lock.lock(); let c = pending.removeValue(forKey: m.serial); lock.unlock()
                c?.resume(throwing: error)
            }
        }.body
    }

    /// Fire-and-forget call (no reply expected).
    public func send(destination: String, path: String, interface: String, member: String, _ args: [DBusValue] = []) {
        var m = DBusMessage(kind: .methodCall)
        m.destination = destination; m.path = path; m.interface = interface; m.member = member; m.body = args
        m.flags = 1 // NO_REPLY_EXPECTED
        send(m)
    }

    public func hello() async throws {
        let r = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                               interface: "org.freedesktop.DBus", member: "Hello")
        uniqueName = r.first?.string ?? ""
    }

    @discardableResult
    public func addSignalHandler(_ handler: @escaping SignalHandler) -> UUID {
        let id = UUID()
        lock.lock(); signalHandlers[id] = handler; lock.unlock()
        return id
    }

    public func addMatch(_ rule: String) async throws {
        _ = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                           interface: "org.freedesktop.DBus", member: "AddMatch", [.string(rule)])
    }

    public func nameHasOwner(_ name: String) async -> Bool {
        let r = try? await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                interface: "org.freedesktop.DBus", member: "NameHasOwner", [.string(name)])
        return r?.first?.bool ?? false
    }

    // MARK: Properties

    public func getProperty(destination: String, path: String, interface: String, name: String) async throws -> DBusValue {
        let r = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                               member: "Get", [.string(interface), .string(name)])
        return r.first?.unwrapped ?? .structure([])
    }

    public func getAllProperties(destination: String, path: String, interface: String) async throws -> [String: DBusValue] {
        let r = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                               member: "GetAll", [.string(interface)])
        return (r.first?.dictionary ?? [:]).mapValues(\.unwrapped)
    }

    public func setProperty(destination: String, path: String, interface: String, name: String, value: DBusValue) async throws {
        _ = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Properties",
                           member: "Set", [.string(interface), .string(name), .variant(value)])
    }

    public func introspect(destination: String, path: String) async throws -> String {
        let r = try await call(destination: destination, path: path, interface: "org.freedesktop.DBus.Introspectable",
                               member: "Introspect")
        return r.first?.string ?? ""
    }
}
