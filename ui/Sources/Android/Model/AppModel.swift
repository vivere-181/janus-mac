import AppKit
import KDEConnectKit
import NativeEngine
import Network
import Observation

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case overview, calendar, notes, messages, notifications, media, files, clipboard, remote, connection, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .notes: "Notes"
        case .messages: "Messages"
        case .notifications: "Notifications"
        case .media: "Now Playing"
        case .files: "Transfers"
        case .clipboard: "Clipboard"
        case .remote: "Remote Input"
        case .connection: "Connection"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "smartphone"
        case .calendar: "calendar"
        case .notes: "note.text"
        case .messages: "message.fill"
        case .notifications: "bell.badge.fill"
        case .media: "play.circle.fill"
        case .files: "arrow.up.arrow.down.circle.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .remote: "cursorarrow.rays"
        case .connection: "antenna.radiowaves.left.and.right"
        case .settings: "gearshape.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .overview: .systemGreen
        case .calendar: .systemRed
        case .notes: .systemYellow
        case .messages: .systemBlue
        case .notifications: .systemRed
        case .media: .systemPink
        case .files: .systemOrange
        case .clipboard: .systemIndigo
        case .remote: .systemPurple
        case .connection: .systemTeal
        case .settings: .systemGray
        }
    }
}

@MainActor @Observable
final class AppModel {
    /// One instance for the whole app, shared by the UI and Shortcuts actions.
    static let shared = AppModel()

    enum State: Equatable { case connecting, connected, failed(String) }

    private(set) var state: State = .connecting
    private(set) var devices: [Device] = []
    private(set) var announcedName = ""
    /// Connection types from the engine, reported as "DisplayName|InternalName|enabled".
    private(set) var linkProviders: [(name: String, title: String, enabled: Bool)] = []
    var selectedDeviceID: String?
    var section: Pane? = .overview
    /// Set to ask the always-alive menu bar label to open the main window.
    var wantsMainWindow = false
    /// Counts each time the main window is asked to show: it builds its content again even when macOS doesn't make
    /// it key (opened from the background, it isn't activated).
    var mainWindowOpens = 0
    /// A note to show in the Notes section (from a widget): selected there, ready to type.
    var noteToOpen: String?
    /// Presents the "Add Device" sheet in the main window.
    var showAddDevice = false
    /// Presents the New Message sheet (with an optional prefilled "To" query).
    var showCompose = false
    var composePrefill = ""
    /// Addresses the engine connects to directly (for networks where discovery doesn't work).
    private(set) var customAddresses: [String] = []

    /// User-initiated reconnect in progress, and the outcome of the last one.
    private(set) var isReconnecting = false
    private(set) var reconnectNote: String?
    private(set) var engineStartedAt: Date?
    private(set) var busAddress = ""
    private(set) var macAddresses: [String] = []

    /// Recent connection history (newest first), also written to ~/Library/Logs/Android/connection.log.
    var events: [ConnectionEvent] = []

    @ObservationIgnored private var bus: (any EngineBus)?
    @ObservationIgnored private var reconnecting = false
    @ObservationIgnored var nudgeTask: Task<Void, Never>?
    @ObservationIgnored var pathMonitor: NWPathMonitor?
    @ObservationIgnored var lastPathSignature = ""
    @ObservationIgnored var lastReachable: [String: Bool] = [:]
    /// Devices paired at the last refresh (to notice unpairing).
    @ObservationIgnored private var lastPaired: Set<String> = []
    @ObservationIgnored var notifiedPairing: Set<String> = []

    init() {
        LegacySettings.migrate()
        log(.info, "Janus started")
        Self.cleanOutgoingCache()
        Notifier.shared.setup(model: self)
        Task { await connect() }
        startReliabilityMonitors()
        // The main window hidden behind others or on another Space counts as not visible.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { n in
            guard (n.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
            MainActor.assumeIsolated { AppModel.shared.uiVisibilityChanged() }
        }
    }

    // MARK: Work that only matters on screen

    /// The panel or the main window is showing (latency, live progress and the like are only worth refreshing then).
    static var uiVisible: Bool { StatusItemController.shared.isPanelShown || DockPresence.mainWindowVisible }

    @ObservationIgnored private var latencyTask: Task<Void, Never>?

    /// Called when the panel or main window shows or hides. While hidden nothing here runs at all.
    func uiVisibilityChanged() {
        guard Self.uiVisible else { return }   // the loops end themselves once hidden
        StatusItemController.shared.missedCalls = 0   // seen
        startLatencyLoop()
        for d in connectedDevices { d.watchLive() }
    }

    /// Round-trip latency, every 10 s and only while on screen: each ping wakes the phone's Wi-Fi.
    private func startLatencyLoop() {
        guard latencyTask == nil else { return }
        latencyTask = Task { [weak self] in
            while let self, Self.uiVisible, !Task.isCancelled {
                for d in self.connectedDevices {
                    if let ip = d.addresses.first(where: { !$0.contains(":") }) ?? d.addresses.first {
                        d.recordLatency(await Latency.ping(ip))
                    }
                }
                let addresses = Latency.localIPv4Addresses()
                if addresses != self.macAddresses { self.macAddresses = addresses }
                try? await Task.sleep(for: .seconds(10), tolerance: .seconds(2))
            }
            self?.latencyTask = nil
        }
    }

    var selectedDevice: Device? {
        // Phones first: a TV is only shown when picked (or when it's the only device).
        devices.first { $0.id == selectedDeviceID } ?? pairedDevices.first { !$0.isTV } ?? pairedDevices.first
    }
    var pairedDevices: [Device] { devices.filter(\.isPaired) }
    var connectedDevices: [Device] { devices.filter { $0.isPaired && $0.isReachable } }
    var discoverableDevices: [Device] { devices.filter { !$0.isPaired && $0.isReachable } }
    var pairingRequests: [Device] { devices.filter(\.isPairRequestedByPeer) }

    // MARK: Connection

    func connect() async {
        state = .connecting
        do {
            // Janus's own engine (R40), inside the app.
            let bus = try NativeEngine.start(log: { line in Task { @MainActor in debugLog("engine: " + line) } })
            self.bus = bus
            bus.onClose = { [weak self] in Task { @MainActor in self?.connectionLost() } }
            bus.addSignalHandler { [weak self] msg in Task { @MainActor in self?.handle(msg) } }
            state = .connected
            log(.info, "Connected to the connection engine")
            busAddress = "native"
            engineStartedAt = .now
            await refreshDevices()
            announcedName = (try? await daemonCall("announcedName").first?.string) ?? ""
            syncMacName()
            await refreshLinkProviders()
            await refreshCustomAddresses()
        } catch {
            state = .failed(error.localizedDescription)
            log(.warning, "Couldn't reach the connection engine: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    private func connectionLost() {
        guard state == .connected else { return }
        log(.warning, "Lost the connection engine; restarting")
        bus = nil
        devices = []
        lastReachable = [:]
        lastPaired = []
        state = .connecting
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            reconnecting = false
            if state != .connected { await connect() }
        }
    }

    /// Escalating reconnect: ask the engine to rediscover; if the phone doesn't come back,
    /// restart the engine itself; finally report what happened.
    func reconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectNote = nil
        Task {
            defer { isReconnecting = false }
            if state == .connected {
                refreshNetwork()
                if await waitForPhone(seconds: 8) { reconnectNote = "Reconnected"; return }
            }
            reconnectNote = "Restarting the connection engine…"
            await restartEngine()
            if await waitForPhone(seconds: 20) {
                reconnectNote = "Reconnected"
            } else {
                reconnectNote = "Phone not found. Open Janus on your phone and check it's on the same Wi-Fi."
            }
        }
    }

    private func waitForPhone(seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if !connectedDevices.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
            if seconds > 0, state == .connected, connectedDevices.isEmpty { await refreshDevices() }
        }
        return !connectedDevices.isEmpty
    }

    /// Stops kdeconnectd and starts it again on the same message bus.
    func restartEngine() async {
        log(.info, "Restarting the connection engine")
        reconnecting = true                     // suppress the automatic reconnect while we do it
        let old = bus
        bus = nil
        devices = []
        lastReachable = [:]
        lastPaired = []
        state = .connecting
        old?.shutdown()
        try? await Task.sleep(for: .seconds(1))
        reconnecting = false
        await connect()
    }

    /// The device just paired by QR code (R41), for the pairing screens.
    var pairedByCode: String?

    /// The link for the pairing QR code (a fresh single-use code), nil when the engine can't do QR pairing.
    func pairingLink() async -> String? {
        return try? await daemonCall("janusPairingURI").first?.string
    }

    func endPairingOffer() { Task { _ = try? await daemonCall("janusEndPairingOffer") } }

    @discardableResult
    func daemonCall(_ member: String, _ args: [DBusValue] = []) async throws -> [DBusValue] {
        guard let bus else { throw DBusError(name: "Disconnected", message: "Not connected") }
        return try await bus.call(destination: EnginePaths.service, path: EnginePaths.daemonPath,
                                  interface: "org.kde.kdeconnect.daemon", member: member, args)
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    /// Device signals come in bursts (a phone connecting sends several): they share one refresh, 0.2 s later, and a
    /// refresh never runs twice at once (one more follows if something arrived meanwhile).
    func requestRefresh() {
        if refreshTask != nil { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                await self.refreshDevices()
            } while self.refreshAgain
            self.refreshTask = nil
        }
    }

    func refreshDevices() async {
        guard let bus, let ids = try? await daemonCall("devices", [false, false]).first?.strings else { return }
        var next: [Device] = []
        for id in ids {
            if let existing = devices.first(where: { $0.id == id }) {
                next.append(existing)
            } else {
                next.append(Device(id: id, bus: bus))
            }
        }
        devices = next
        for d in next { await d.refresh() }
        devices.sort { ($0.isPaired && $0.isReachable ? 0 : $0.isPaired ? 1 : 2, $0.name) < ($1.isPaired && $1.isReachable ? 0 : $1.isPaired ? 1 : 2, $1.name) }
        for d in devices where d.isPairRequestedByPeer && !notifiedPairing.contains(d.id) {
            notifiedPairing.insert(d.id)
            log(.info, "\(d.name) wants to pair")
            Notifier.shared.pairingRequest(d)
        }
        let stillAsking = Set(devices.filter(\.isPairRequestedByPeer).map(\.id))
        // Answered (here, on the phone) or cancelled: its card goes away.
        for id in notifiedPairing.subtracting(stillAsking) { BannerCenter.shared.dismiss("pair.\(id)") }
        notifiedPairing.formIntersection(stillAsking)
        for d in devices where d.isPaired {
            let was = lastReachable[d.id]
            if was != d.isReachable {
                if d.isReachable { log(.success, "\(d.name) connected via \(d.transport)") }
                else if was == true { log(.warning, "\(d.name) disconnected") }
                lastReachable[d.id] = d.isReachable
            }
        }
        reconcilePairing()
        URLRouter.publishPhoneName(selectedDevice?.name)
    }

    /// After a refresh: notices devices unpaired from either side and keeps a paired device selected.
    func reconcilePairing() {
        // Unpaired from either side: say so, and stop mirroring it.
        let paired = Set(devices.filter(\.isPaired).map(\.id))
        for d in devices where lastPaired.contains(d.id) && !paired.contains(d.id) {
            log(.warning, "\(d.name) is no longer paired")
            if MirrorController.shared.deviceID == d.id { MirrorController.shared.stop() }
        }
        lastPaired = paired
        if !devices.isEmpty {
            let mine = Set(devices.filter { $0.isPaired && DeviceTrust.isMine($0) }.map(\.id))
            CalendarStore.shared.keepOnly(deviceIDs: mine)
            NotificationHistory.shared.keepOnly(deviceIDs: mine)
        }
        DeviceTrust.migrate(devices)
        MacActions.publish()
        // The window and menu bar only work with a paired device selected (an unpaired one hides the device
        // switcher), so move on to another paired device whenever the selected one isn't paired any more.
        if selectedDevice?.isPaired != true {
            selectedDeviceID = (connectedDevices.first { !$0.isTV } ?? pairedDevices.first { !$0.isTV } ?? connectedDevices.first ?? pairedDevices.first)?.id
                ?? (selectedDevice == nil ? nil : selectedDeviceID)
        }
    }

    func refreshLinkProviders() async {
        let raw = (try? await daemonCall("linkProviders").first?.strings) ?? []
        linkProviders = raw.map { entry in
            let parts = entry.split(separator: "|").map(String.init)
            let display = parts.first ?? entry
            let title = display.localizedCaseInsensitiveContains("lan") ? "Wi-Fi / local network"
                : display.localizedCaseInsensitiveContains("bluetooth") ? "Bluetooth"
                : display.localizedCaseInsensitiveContains("loopback") ? "Loopback (testing)" : display
            return (name: parts.count > 1 ? parts[1] : display, title: title, enabled: parts.last == "enabled")
        }
    }

    func setLinkProvider(_ name: String, enabled: Bool) {
        Task {
            try? await daemonCall("setLinkProviderState", [.string(name), .bool(enabled)])
            await refreshLinkProviders()
        }
    }

    // MARK: Devices

    /// Unpairs a device and forgets its nickname. The phone must be paired again to reconnect.
    func removeDevice(_ device: Device) {
        log(.info, "Removed \(device.name)")
        device.unpair()
        DeviceNicknames.set(device.id, nil)
        if selectedDeviceID == device.id { selectedDeviceID = nil }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshDevices()
        }
    }

    func refreshCustomAddresses() async {
        guard let bus else { return }
        customAddresses = (try? await bus.getProperty(destination: EnginePaths.service, path: EnginePaths.daemonPath,
                                                      interface: "org.kde.kdeconnect.daemon", name: "customDevices"))?.strings ?? []
    }

    func setCustomAddresses(_ list: [String]) {
        guard let bus else { return }
        customAddresses = list
        Task {
            try? await bus.setProperty(destination: EnginePaths.service, path: EnginePaths.daemonPath,
                                       interface: "org.kde.kdeconnect.daemon", name: "customDevices", value: .strings(list))
            refreshNetwork()
            await refreshCustomAddresses()
        }
    }

    /// Adds a phone's IP address (or hostname) for direct connection, then looks for it.
    func addAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !address.contains(" ") else { return false }
        if !customAddresses.contains(address) { setCustomAddresses(customAddresses + [address]) }
        log(.info, "Looking for a device at \(address)")
        return true
    }

    /// Sets how this Mac appears on phones. A name typed by the owner sticks; otherwise the app
    /// follows the Mac's Computer Name (see `syncMacName`).
    /// The phone's own Do Not Disturb changed (not in response to us).
    func phoneDNDChanged(_ on: Bool, device: Device) {
        log(.info, "\(device.name) turned Do Not Disturb \(on ? "on" : "off")")
    }

    func setAnnouncedName(_ name: String, userChosen: Bool = true) {
        let clean = Self.protocolSafeName(name)
        guard !clean.isEmpty else { return }
        if userChosen {
            UserDefaults.standard.set(clean != Self.protocolSafeName(Self.computerName), forKey: "macNameCustomized")
        }
        announcedName = clean
        Task { try? await daemonCall("setAnnouncedName", [.string(clean)]) }
    }

    /// The Mac's Computer Name (System Settings → General → About → Name).
    static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Device names may not contain "',;:.!?()[]<> and are at most 32 characters (as the engine enforces);
    /// a straight apostrophe becomes the typographic one so "Alex's" survives.
    static func protocolSafeName(_ raw: String) -> String {
        let forbidden = Set("\"',;:.!?()[]<>")
        let cleaned = String(raw.replacingOccurrences(of: "'", with: "’").filter { !forbidden.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(32)).trimmingCharacters(in: .whitespaces)
    }

    /// Announce the Computer Name unless the owner picked a different name in Settings.
    private func syncMacName() {
        guard !UserDefaults.standard.bool(forKey: "macNameCustomized") else { return }
        let wanted = Self.protocolSafeName(Self.computerName)
        guard !wanted.isEmpty, wanted != announcedName else { return }
        log(.info, "This Mac now appears on phones as “\(wanted)”")
        setAnnouncedName(wanted, userChosen: false)
    }

    func refreshNetwork() {
        Task { try? await daemonCall("forceOnNetworkChange") }
    }

    // MARK: Signals

    private func handle(_ msg: DBusMessage) {
        guard let path = msg.path, let member = msg.member else { return }
        if path == EnginePaths.daemonPath {
            switch member {
            case "deviceAdded", "deviceRemoved", "deviceListChanged", "deviceVisibilityChanged", "pairingRequestsChanged":
                requestRefresh()
            case "announcedNameChanged":
                announcedName = msg.body.first?.string ?? announcedName
            case "linkProvidersChanged":
                Task { await refreshLinkProviders() }
            case "janusPairedByCode":
                // Paired by scanning this Mac's QR code (R41): the owner was at both devices, so it's theirs.
                if let id = msg.body.first?.string {
                    UserDefaults.standard.set(DeviceTrust.Level.mine.rawValue, forKey: "trust.\(id)")
                    pairedByCode = id
                }
                requestRefresh()
            default: break
            }
            return
        }
        let prefix = EnginePaths.daemonPath + "/devices/"
        guard path.hasPrefix(prefix) else { return }
        let rest = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let device = devices.first(where: { $0.id == rest[0] }) else {
            requestRefresh()
            return
        }
        device.handle(member: member, interface: msg.interface ?? "", subpath: rest.count > 1 ? rest[1] : nil, body: msg.body)
        if member == "pairStateChanged" || member == "reachableChanged" {
            requestRefresh()
        }
    }
}

extension AppModel {
    /// An address on this Mac's own network ("192.168.1.42"), for "e.g." hints.
    nonisolated static var exampleAddress: String {
        guard let mine = Latency.localIPv4Addresses().first else { return "192.168.1.42" }
        let parts = mine.split(separator: ".")
        return parts.count == 4 ? parts.prefix(3).joined(separator: ".") + ".42" : mine
    }
}


/// The app's bundle id changed with the move to GitHub (it was "local.android.connect"). macOS keeps settings per id,
/// so on the first launch under the new id the old settings are copied over once (pairings, notes and history live
/// in files and the engine's own config, which don't depend on the id).
enum LegacySettings {
    static let oldDomain = "local.android.connect"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !defaults.bool(forKey: "migrated.fromLegacyId"),
              let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "migrated.fromLegacyId")
    }
}
