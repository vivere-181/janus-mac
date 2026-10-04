import Foundation

/// Finds a phone's Wireless debugging services on the local network with Bonjour (macOS's own
/// discovery; adb's built-in discovery is unreliable here): `_adb-tls-pairing._tcp` while the
/// "Pair with code" screen is open, `_adb-tls-connect._tcp` while Wireless debugging is on.
@MainActor
final class AdbServiceFinder: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Service: Sendable, Equatable { let name: String; let host: String; let port: Int }

    static let pairing = "_adb-tls-pairing._tcp."
    static let connect = "_adb-tls-connect._tcp."

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var found: [Service] = []
    private var onUpdate: (([Service]) -> Void)?

    /// Browses for `type` and reports every resolved service until `stop()`.
    func start(type: String, onUpdate: @escaping ([Service]) -> Void) {
        self.onUpdate = onUpdate
        browser.delegate = self
        browser.searchForServices(ofType: type, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        pending.forEach { $0.stop() }
        pending = []
        onUpdate = nil
    }

    /// One-shot: the services of `type` seen within `timeout` seconds.
    static func find(type: String, timeout: TimeInterval = 3) async -> [Service] {
        let finder = AdbServiceFinder()
        var latest: [Service] = []
        finder.start(type: type) { latest = $0 }
        try? await Task.sleep(for: .seconds(timeout))
        finder.stop()
        return latest
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            pending.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            found.removeAll { $0.name == service.name }
            onUpdate?(found)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard let host = Self.ipv4(sender.addresses ?? []) else { return }
            found.removeAll { $0.name == sender.name }
            found.append(Service(name: sender.name, host: host, port: sender.port))
            onUpdate?(found)
        }
    }

    private static func ipv4(_ addresses: [Data]) -> String? {
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            if let ip { return ip }
        }
        return nil
    }
}

/// Pairing and connecting over Wireless debugging, with the app's own adb server.
enum MirrorLink {
    static func isPaired(_ device: Device) -> Bool { UserDefaults.standard.bool(forKey: "mirror.paired.\(device.id)") }
    static func setPaired(_ device: Device, _ paired: Bool) { UserDefaults.standard.set(paired, forKey: "mirror.paired.\(device.id)") }

    /// `adb pair` with the code shown on the phone (through a relay, see MirrorRelay).
    /// Returns an error message, or nil on success.
    static func pair(_ service: AdbServiceFinder.Service, code: String) async -> String? {
        _ = await ADB.wifi.run(["start-server"], timeout: 15)
        let relay = MirrorRelay(host: service.host, port: service.port)
        guard let local = try? await relay.start() else { return "Couldn't reach the phone on the network." }
        defer { relay.stop() }
        let r = await ADB.wifi.run(["pair", "127.0.0.1:\(local)", code], timeout: 20)
        if r.output.localizedCaseInsensitiveContains("Successfully paired") { return nil }
        let reason = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.localizedCaseInsensitiveContains("wrong password") || reason.localizedCaseInsensitiveContains("protocol fault")
            ? "That code didn't work. Check the code on the phone and try again."
            : (reason.isEmpty ? "Pairing failed." : reason)
    }

    /// Connects the app's adb server to the phone's Wireless debugging port (through a relay that
    /// must stay up while connected). Returns the adb serial and the relay.
    static func connect(host: String) async -> (serial: String, relay: MirrorRelay)? {
        _ = await ADB.wifi.run(["start-server"], timeout: 15)
        // Relays from earlier sessions are gone; forget their adb entries.
        for stale in await ADB.wifi.devices(includingOffline: true) where stale.hasPrefix("127.0.0.1:") {
            _ = await ADB.wifi.run(["disconnect", stale], timeout: 5)
        }
        for _ in 0..<3 {
            guard let service = await AdbServiceFinder.find(type: AdbServiceFinder.connect, timeout: 2.5)
                    .first(where: { $0.host == host }) else { continue }
            let relay = MirrorRelay(host: service.host, port: service.port)
            guard let local = try? await relay.start() else { continue }
            let serial = "127.0.0.1:\(local)"
            _ = await ADB.wifi.run(["connect", serial], timeout: 12)
            if await ADB.wifi.devices().contains(serial) { return (serial, relay) }
            relay.stop()
        }
        return nil
    }

    /// The phone app's package (Janus for Android).
    static let phonePackage = "io.github.vivere_181.janus"

    /// Lets the phone app switch Wireless debugging on and off by itself. After pairing, and again at each session
    /// (a reinstalled phone app has lost it; granting twice is harmless).
    static func grantPhonePermission(serial: String, adb: ADB = .wifi) async {
        _ = await adb.run(["-s", serial, "shell", "pm", "grant", phonePackage, "android.permission.WRITE_SECURE_SETTINGS"], timeout: 8)
    }
}
