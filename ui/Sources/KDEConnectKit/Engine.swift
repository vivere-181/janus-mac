import AppKit
import Darwin
import Foundation

/// Locates and starts KDE Connect's engine: a private dbus-daemon (address published in a file in this user's
/// temporary folder) plus kdeconnectd. Everything is per user, so several people can use it on one Mac.
public enum KDEConnectEngine {
    public static let service = "org.kde.kdeconnect"
    public static let daemonPath = "/modules/kdeconnect"
    public static let addressFile = NSTemporaryDirectory() + "android-connect-bus-address"

    /// Process names: current ("Janus Engine" / "Janus Bus") and the earlier ones (before the renames).
    static let daemonNames = ["Janus Engine", "Android Engine", "kdeconnectd"]
    static let busNames = ["Janus Bus", "Android Bus", "dbus-daemon"]

    /// The engine bundle embedded inside our app (or the pre-rename location).
    public static var engineBundle: URL? {
        let roots = [Bundle.main.bundleURL, URL(fileURLWithPath: "/Applications/Janus.app"), URL(fileURLWithPath: "/Applications/Android.app")]
        let candidates = roots.flatMap { root in
            ["Janus Engine.app", "Android Engine.app", "KDE Connect.app"].map { root.appendingPathComponent("Contents/Library/Engine/\($0)") }
        }
        return candidates.first { executable(in: $0, names: daemonNames) != nil }
    }

    static func executable(in bundle: URL, names: [String]) -> URL? {
        names.map { bundle.appendingPathComponent("Contents/MacOS/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func currentAddress() -> String? {
        (try? String(contentsOfFile: addressFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static var isDaemonRunning: Bool { pidOfDaemon() != nil }

    /// Connects to the engine's bus, starting the bus and/or kdeconnectd first if needed.
    public static func connect(launchIfNeeded: Bool = true) async throws -> DBusConnection {
        if let bus = await tryConnect() { return bus }
        guard launchIfNeeded else {
            throw DBusError(name: "NotRunning", message: "The connection engine is not running.")
        }
        guard let engine = engineBundle else {
            throw DBusError(name: "EngineMissing", message: "Part of the app is missing (its connection engine). Reinstall Janus.")
        }

        // 1. Bus: reuse the published one if it's alive, otherwise start a fresh dbus-daemon.
        var address = currentAddress()
        if await !busAlive(address) {
            address = try await startBus(engine: engine)
        }
        // 2. Engine: start kdeconnectd on that bus (restart it if it's running on a dead bus).
        if isDaemonRunning {
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                if let bus = await tryConnect() { return bus }
            }
            stopDaemon()
            try await Task.sleep(for: .milliseconds(500))
        }
        try await launchEngine(engine, env: ["DBUS_SESSION_BUS_ADDRESS": address ?? ""])
        for _ in 0..<60 {                      // up to ~15 s
            try await Task.sleep(for: .milliseconds(250))
            if let bus = await tryConnect() { return bus }
        }
        throw DBusError(name: "Timeout", message: "The connection engine did not start.")
    }

    private static func tryConnect() async -> DBusConnection? {
        guard let address = currentAddress(), let bus = try? DBusConnection(address: address) else { return nil }
        do {
            try await bus.hello()
            if await bus.nameHasOwner(service) { return bus }
        } catch {}
        bus.shutdown()
        return nil
    }

    private static func busAlive(_ address: String?) async -> Bool {
        guard let address, let bus = try? DBusConnection(address: address) else { return false }
        defer { bus.shutdown() }
        return (try? await bus.hello()) != nil
    }

    /// Starts KDE Connect's private dbus-daemon and publishes its address.
    private static func startBus(engine: URL) async throws -> String {
        let p = Process()
        guard let busExe = executable(in: engine, names: busNames) else {
            throw DBusError(name: "Bus", message: "The connection engine's message bus is missing.")
        }
        p.executableURL = busExe
        p.arguments = ["--print-address", "--nofork",
                       "--config-file", engine.appendingPathComponent("Contents/Resources/dbus-1/session.conf").path,
                       "--address", "unix:tmpdir=/tmp"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let address: String = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var data = Data()
                let h = out.fileHandleForReading
                while !data.contains(UInt8(ascii: "\n")) {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                if line.hasPrefix("unix:") { cont.resume(returning: line) }
                else { cont.resume(throwing: DBusError(name: "Bus", message: "Could not start the connection engine's message bus.")) }
            }
        }
        try (address + "\n").write(toFile: addressFile, atomically: true, encoding: .utf8)
        // KDE's own tools (kdeconnect-cli, -sms, -handler) locate the bus via launchd's environment.
        if let path = address.dropFirst(5).split(separator: ",").first(where: { $0.hasPrefix("path=") })?.dropFirst(5) {
            let lc = Process()
            lc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            lc.arguments = ["setenv", "DBUS_LAUNCHD_SESSION_BUS_SOCKET", String(path)]
            try? lc.run(); lc.waitUntilExit()
        }
        return address
    }

    /// Opens the engine bundle through LaunchServices (its executable is kdeconnectd), so it runs as its own
    /// app with KDE Connect's identity and permissions (Bluetooth, notifications), not as our child process.
    private static func launchEngine(_ engine: URL, env: [String: String]) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.environment = env
        _ = try await NSWorkspace.shared.openApplication(at: engine, configuration: config)
    }

    public static func stopEngine() { stopDaemon() }

    /// Process ID of the running engine, if any. Remembered and re-checked with the kernel (no processes launched):
    /// this is asked every second while a transfer runs.
    public static func daemonPID() -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedPID, isDaemon(p) { return p }
        cachedPID = pids(named: daemonNames).first
        return cachedPID
    }

    /// When the running engine was started (nil if not running).
    public static func daemonStartDate() -> Date? {
        guard let pid = daemonPID(), let info = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    private static func pidOfDaemon() -> String? { daemonPID().map { String($0) } }

    private static func stopDaemon() {
        lock.lock(); cachedPID = nil; lock.unlock()
        for pid in pids(named: daemonNames) { kill(pid, SIGTERM) }
    }

    // MARK: Processes, from the kernel

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPID: pid_t?

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// One of the engine's names, run by this user (other users' engines aren't ours).
    private static func isDaemon(_ pid: pid_t) -> Bool {
        guard let name = processName(pid), daemonNames.contains(name), let info = bsdInfo(pid) else { return false }
        return info.pbi_uid == getuid()
    }

    private static func pids(named names: [String]) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        return all.prefix(Int(max(0, got))).filter { $0 > 0 && names.contains(processName($0) ?? "") && (bsdInfo($0)?.pbi_uid == getuid()) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
