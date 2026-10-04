import AppKit
import KDEConnectKit
import Network
import ServiceManagement

struct ConnectionEvent: Identifiable, Equatable {
    enum Kind { case info, success, warning }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

/// Keeps the phone connected across restarts, sleep/wake, Wi-Fi changes and engine crashes.
extension AppModel {
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connection.log")
    }()

    func log(_ kind: ConnectionEvent.Kind, _ text: String) {
        let event = ConnectionEvent(kind: kind, text: text)
        events.insert(event, at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        let line = "\(ISO8601DateFormatter.string(from: event.date, timeZone: .current, formatOptions: [.withInternetDateTime])) [\(kind)] \(text)\n"
        LogFile.append(line, to: Self.logURL)
    }

    func startReliabilityMonitors() {
        ensureLoginItem()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log(.info, "Mac going to sleep") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log(.info, "Mac woke up; looking for the phone")
                self?.nudge(reason: "wake")
            }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge(reason: "unlock") }
        }

        // Wi-Fi joins, IP changes, switching networks: re-announce as soon as the network is usable.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied
                ? path.availableInterfaces.map(\.name).sorted().joined(separator: ",") + "|" + Latency.localIPv4Addresses().joined(separator: ",")
                : "offline"
            Task { @MainActor in
                guard let self, signature != self.lastPathSignature else { return }
                let first = self.lastPathSignature.isEmpty
                self.lastPathSignature = signature
                guard !first else { return }
                if signature == "offline" {
                    self.log(.warning, "Mac lost its network connection")
                } else {
                    self.log(.info, "Network changed (\(Latency.localIPv4Addresses().joined(separator: ", ")))")
                    self.nudge(reason: "network")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "android.path-monitor"))
        pathMonitor = monitor

        // A safety net (the engine's exit, the network, wake and unlock are all events already): makes sure the engine
        // is alive and re-announces while a phone is missing, backing off so an absent phone costs next to nothing.
        Task { [weak self] in
            var delay = 30.0
            while true {
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 5))
                guard let self else { return }
                delay = await self.watchdogTick(previous: delay)
            }
        }
    }

    /// One check; returns how long to wait before the next: 5 min when every paired phone is connected, while one is
    /// missing 30 s → 1 → 2 → 5 min, 30 s while the engine connection itself is down.
    private static var missingChecksStorage = 0
    private var missingChecks: Int {
        get { Self.missingChecksStorage }
        set { Self.missingChecksStorage = newValue }
    }

    private func watchdogTick(previous: Double) async -> Double {
        switch state {
        case .connected:
            if !KDEConnectEngine.isDaemonRunning {
                log(.warning, "The connection engine isn't running; starting it")
                await restartEngine()
                return 30
            }
            guard !pairedDevices.isEmpty, connectedDevices.count < pairedDevices.count else { missingChecks = 0; return 300 }
            refreshNetwork()
            missingChecks += 1
            return [30.0, 60, 120, 300][min(missingChecks - 1, 3)]
        case .failed, .connecting:
            await connect()
            return 30
        }
    }

    /// Re-announces this Mac at increasing intervals until every paired phone is back (about 2 minutes).
    func nudge(reason: String) {
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            let delays: [Double] = [1, 3, 6, 10, 15, 25, 40, 60]
            var waited = 0.0
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay - waited))
                waited = delay
                guard let self, !Task.isCancelled else { return }
                if self.state != .connected { await self.connect() }
                if !self.pairedDevices.isEmpty, self.connectedDevices.count == self.pairedDevices.count { return }
                self.refreshNetwork()
            }
            guard let self, !Task.isCancelled else { return }
            if self.connectedDevices.isEmpty, !self.pairedDevices.isEmpty {
                self.log(.warning, "Phone still not found after \(reason); will keep checking, less often over time")
            }
        }
    }

    /// Files handed over by Shortcuts are staged here; drop anything older than a day.
    static func cleanOutgoingCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Android/Outgoing")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > 86_400 { try? FileManager.default.removeItem(at: item) }
        }
    }

    // MARK: Login item

    var loginItemStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// Opens at login by default (the user can turn it off in Settings). Runs once per install.
    private func ensureLoginItem() {
        let key = "loginItemConfigured.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
            log(.info, "Set to open at login")
        } catch {
            log(.warning, "Couldn't turn on Open at Login automatically (\(error.localizedDescription)). Turn it on in Settings.")
        }
    }
}


/// The event log on disk, written off the main thread through one open file; trimmed to the last ~2000 lines when it
/// passes 256 KB (checked every 100 lines).
enum LogFile {
    private static let queue = DispatchQueue(label: "janus.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written = 0

    static func append(_ line: String, to url: URL) {
        queue.async {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data(line.utf8))
            written += 1
            guard written % 100 == 0,
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            try? handle?.close(); handle = nil
            try? text.split(separator: "\n").suffix(2000).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
