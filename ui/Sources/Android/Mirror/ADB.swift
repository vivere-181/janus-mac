import Foundation

/// Runs Android's `adb` for mirroring. Wi-Fi uses the app's own adb server on port 5038: it's started by
/// this app, so it inherits the app's Local Network permission, and it never disturbs another adb server
/// (e.g. one used for development on the default port 5037).
struct ADB: Sendable {
    /// Port of the adb server this instance talks to.
    let port: Int

    static let wifi = ADB(port: 5038)
    static let usb = ADB(port: 5037)

    /// The app's own server handles Wireless debugging only: no USB (phones on a cable stay with the default
    /// server, which the USB path uses) and no adb discovery (the app finds phones with Bonjour itself).
    /// adb passes this environment to the server it starts.
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if port != Self.usb.port {
            env["ADB_USB"] = "0"
            env["ADB_MDNS"] = "0"
        }
        return env
    }

    /// The adb inside the app; otherwise one installed on this Mac (Android SDK, Homebrew, MacPorts, or the PATH).
    static let executable: URL? = {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb").path]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] { if let sdk = env[key] { candidates.append(sdk + "/platform-tools/adb") } }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/opt/local/bin/adb",
                       home + "/Library/Android/sdk/platform-tools/adb", home + "/Android/sdk/platform-tools/adb"]
        candidates += (env["PATH"] ?? "").split(separator: ":").map { $0 + "/adb" }
        if let found = candidates.first(where: fm.isExecutableFile(atPath:)) { return URL(fileURLWithPath: found) }
        // Apps don't get the Terminal's PATH; ask a login shell once.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v adb"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Runs `adb -P <port> <args>` and waits (with a timeout) for it to finish.
    func run(_ args: [String], timeout: TimeInterval = 20) async -> Result {
        guard let exe = Self.executable else { return Result(status: -1, output: "adb not found") }
        let port = self.port, env = environment
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["-P", String(port)] + args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
            let deadline = DispatchTime.now() + timeout
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: deadline) == .timedOut { p.terminate() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Starts a long-running adb command (the mirroring server); the caller terminates it.
    func spawn(_ args: [String], output: @escaping @Sendable (String) -> Void) throws -> Process {
        guard let exe = Self.executable else { throw MirrorError.adbMissing }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-P", String(port)] + args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { output(String(decoding: d, as: UTF8.self)) }
        }
        try p.run()
        return p
    }

    /// Serials of devices in the "device" state (USB serials, or ip:port for Wi-Fi).
    func devices(includingOffline: Bool = false) async -> [String] {
        let r = await run(["devices"], timeout: 8)
        return r.output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && (includingOffline || parts[1] == "device") ? String(parts[0]) : nil
        }
    }

    /// The phone's Wi-Fi IPv4 address, used to match an adb device to a paired phone.
    func wifiAddress(serial: String) async -> String? {
        // The address of the interface the default route uses (named wlan0, wlan1, swlan0… depending on the phone).
        let route = await run(["-s", serial, "shell", "ip", "-4", "route", "get", "1.1.1.1"], timeout: 8)
        if let range = route.output.range(of: #"src (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) {
            return String(route.output[range].dropFirst(4))
        }
        let r = await run(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"], timeout: 8)
        guard let range = r.output.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else { return nil }
        return String(r.output[range].dropFirst(5))
    }
}

enum MirrorError: LocalizedError {
    case adbMissing, noDevice, pushFailed(String), forwardFailed(String), connectFailed, protocolError(String)

    var errorDescription: String? {
        switch self {
        case .adbMissing: "Mirroring needs Android's platform tools, which this copy of the app doesn't include. Download \"SDK Platform-Tools for Mac\" from developer.android.com and put the platform-tools folder in ~/Library/Android/sdk, or install them with Homebrew (brew install --cask android-platform-tools)."
        case .noDevice: "The phone isn't reachable for mirroring."
        case .pushFailed(let s): "Couldn't start mirroring on the phone (\(s))."
        case .forwardFailed(let s): "Couldn't open the mirroring connection (\(s))."
        case .connectFailed: "The phone didn't start the mirroring stream."
        case .protocolError(let s): "Mirroring stopped: \(s)"
        }
    }
}
