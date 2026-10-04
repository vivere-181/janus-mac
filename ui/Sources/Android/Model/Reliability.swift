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
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            // Keep the file small: trim to the last ~2000 lines when it passes 256 KB.
            if let size = try? FileManager.default.attributesOfItem(atPath: Self.logURL.path)[.size] as? Int, size > 256_000,
               let text = try? String(contentsOf: Self.logURL, encoding: .utf8) {
                try? text.split(separator: "\n").suffix(2000).joined(separator: "\n").appending("\n")
                    .write(to: Self.logURL, atomically: true, encoding: .utf8)
            }
        } else {
            try? line.write(to: Self.logURL, atomically: true, encoding: .utf8)
        }
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

        // Every 30 s: make sure the engine is alive, and keep announcing while the phone is missing.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.watchdogTick()
            }
        }
    }

    private func watchdogTick() async {
        switch state {
        case .connected:
            if !KDEConnectEngine.isDaemonRunning {
                log(.warning, "The connection engine isn't running; starting it")
                await restartEngine()
            } else if !pairedDevices.isEmpty, connectedDevices.isEmpty {
                refreshNetwork()
            }
        case .failed, .connecting:
            await connect()
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
                self.log(.warning, "Phone still not found after \(reason); will keep checking every 30 s")
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
