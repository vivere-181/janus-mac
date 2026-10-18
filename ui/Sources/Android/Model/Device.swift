import JanusLink
import AppKit
import KDEConnectKit
import Observation

struct MediaState: Equatable {
    var players: [String] = []
    var player = ""
    var title = ""
    var artist = ""
    var album = ""
    var artURL: URL?
    var isPlaying = false
    var length = 0            // ms
    var position = 0          // ms, as of positionDate
    var positionDate = Date()
    var volume = 0            // 0...100
    var canSeek = false

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }

    func currentPosition(at now: Date = .now) -> Int {
        guard isPlaying else { return position }
        return min(length > 0 ? length : .max, position + Int(now.timeIntervalSince(positionDate) * 1000))
    }
}

struct PhoneNotification: Identifiable, Equatable {
    let id: String            // publicId (D-Bus object name)
    var internalId = ""
    var appName = ""
    var title = ""
    var text = ""
    var ticker = ""
    var iconPath: String?
    var dismissable = true
    var replyId = ""
    var actions: [String] = []
    var silent = false
    var postedAt = Date()

    /// Pings from our phone app arrive as notifications whose id starts with this prefix.
    static let pingPrefix = "ge.connect.ping:"
    var isPing: Bool { internalId.hasPrefix(Self.pingPrefix) }
    /// The phone reports its Do Not Disturb state as a notification with this id prefix (text "on"/"off").
    static let dndPrefix = "ge.connect.dnd:"
    var isDND: Bool { internalId.hasPrefix(Self.dndPrefix) }
    /// Announces an incoming transfer's total size: text "totalBytes|numberOfFiles".
    static let transferPrefix = "ge.connect.transfer:"
    var isTransferInfo: Bool { internalId.hasPrefix(Self.transferPrefix) }
    /// Our phone app reports Find Phone ringing: text "on"/"off".
    static let ringPrefix = "ge.connect.ring:"
    var isRingInfo: Bool { internalId.hasPrefix(Self.ringPrefix) }
    /// Phone status: text "ringer=normal|vibrate|silent;dnd=on|off;flashlight=on|off".
    static let statusPrefix = "ge.connect.status:"
    var isStatusInfo: Bool { internalId.hasPrefix(Self.statusPrefix) }
    /// Mirroring replies from our phone app: "ready", "failed:<reason>", "stop".
    static let mirrorPrefix = "ge.connect.mirror:"
    var isMirrorInfo: Bool { internalId.hasPrefix(Self.mirrorPrefix) }
    /// Call state from our phone app (JSON: state ringing|talking, number, name, start, now).
    static let callStatePrefix = "ge.connect.callstate:"
    var isCallState: Bool { internalId.hasPrefix(Self.callStatePrefix) }
    /// The phone's calendar: a complete JSON snapshot (re-posted on changes).
    static let calendarPrefix = "ge.connect.calendar"
    var isCalendar: Bool { internalId.hasPrefix(Self.calendarPrefix) }
    /// A live activity (JSON body); updated in place, ended by removal.
    static let livePrefix = "ge.connect.live:"
    var isLive: Bool { internalId.hasPrefix(Self.livePrefix) }
    /// Result of a call command: "decline:ok", "decline:failed:<reason>", "mute:ok".
    static let callResultPrefix = "ge.connect.callresult:"
    var isCallResult: Bool { internalId.hasPrefix(Self.callResultPrefix) }
    /// Sent right before a new screenshot is shared: text = the screenshot's file name.
    static let screenshotPrefix = "ge.connect.screenshot:"
    var isScreenshotInfo: Bool { internalId.hasPrefix(Self.screenshotPrefix) }
    /// What the phone is (R28): maker, model, screen shape, region (JSON).
    static let profilePrefix = "ge.connect.device"
    var isProfile: Bool { internalId.hasPrefix(Self.profilePrefix) }
    /// A TV's apps (R39, CONTRACT → ge.connect.tvapps): {"apps":[{package,label,banner}]}, re-sent when they change.
    static let tvAppsPrefix = "ge.connect.tvapps:"
    var isTVApps: Bool { internalId.hasPrefix(Self.tvAppsPrefix) }
    /// Notes sync (R29): hello / push / ack (JSON).
    static let notesPrefix = "ge.connect.notes:"
    var isNotes: Bool { internalId.hasPrefix(Self.notesPrefix) }
    /// Janus Cloud keys, exchanged over the LAN (R36, shared/CLOUD.md §3): hello / forget (JSON).
    static let cloudPrefix = "ge.connect.cloud:"
    var isCloud: Bool { internalId.hasPrefix(Self.cloudPrefix) }
    /// Every `ge.connect.` notification is a companion message: never shown or listed, and unknown
    /// kinds are ignored (see shared/CONTRACT.md).
    var isControl: Bool { internalId.hasPrefix("ge.connect.") }

    /// The text a one-time code is looked for in.
    var codeText: String { NotificationText.plain([title, text].joined(separator: " ")) }
}

struct ReceivedItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let date = Date()
}

@MainActor @Observable
final class Device: Identifiable {
    let id: String
    @ObservationIgnored let bus: any EngineBus
    var path: String { EnginePaths.daemonPath + "/devices/" + id }

    // Identity & pairing
    /// What the app shows: the user's nickname if set, otherwise the name the phone announces.
    var name = ""
    /// The name the phone itself announces.
    var announcedName = ""
    var hasNickname: Bool { DeviceNicknames.get(id) != nil }
    /// Bumped when the owner changes how the device is drawn (or the phone reports what it is).
    var lookVersion = 0
    /// What the phone is (maker, model, screen); nil until it or mirroring tells.
    var profile: DeviceProfile?
    /// Runs our phone app: it reported status or a profile. Only then are `ge.connect.*` commands sent (other phones
    /// would show them as pings).
    var runsCompanion: Bool { profile?.fromPhone == true || UserDefaults.standard.bool(forKey: "reportsStatus.\(id)") }
    /// Whether our phone app understands a command (an older app without a capability list: assume it does).
    func supports(_ cap: String) -> Bool {
        guard runsCompanion else { return false }
        return profile?.caps.map { $0.contains(cap) } ?? true
    }
    var type = "phone"
    var isReachable = false
    var isPaired = false
    var isPairRequested = false
    var isPairRequestedByPeer = false
    var verificationKey = ""
    var addresses: [String] = []
    var providers: [String] = []
    var loadedPlugins: Set<String> = []
    var supportedPlugins: [String] = []
    var enabledPlugins: Set<String> = []

    // Plugin state
    var batteryCharge: Int?
    var isCharging = false
    var networkType = ""
    var networkStrength = -1
    var media = MediaState()
    var notifications: [PhoneNotification] = []
    var clipboardAutoShareDisabled = false
    var remoteKeyboardActive = false
    var received: [ReceivedItem] = []
    var lastError: String?

    /// Ringer mode, flashlight (reported by our phone app; nil until it reports).
    private var statusRequested = false
    struct Status: Equatable {
        var ringer: String?
        var flashlight: Bool?
        /// Extra stats (R24): Wi-Fi network name, carrier, cellular type, storage, Android version.
        var ssid: String?
        var carrier: String?
        var cellular: String?
        var storageFree: Int64?
        var storageTotal: Int64?
        var os: String?
    }
    var status: Status?
    /// Live activities from the phone (deliveries, rides, navigation, timers…).
    var live: [LiveActivity] = []
    /// A call answered on the phone, while it lasts.
    struct ActiveCall: Equatable { var number: String; var name: String; var start: Date }
    var activeCall: ActiveCall?
    @ObservationIgnored private var callStateID: String?
    @ObservationIgnored private var callEnding: Task<Void, Never>?
    @ObservationIgnored var liveIcons: [String: String] = [:]

    /// Commands to our phone app travel as pings whose message starts with `ge.connect.`
    /// (see shared/CONTRACT.md). Other phones would just show a ping, so only send them to phones that
    /// report status (i.e. run our app).
    func command(_ body: String) {
        guard runsCompanion else {
            AppModel.shared.log(.warning, "\(name) doesn't run Janus for Android; didn't send \(body.prefix { $0 != ":" })")
            return
        }
        // Away from this network: the ones that make sense remotely go through Janus Cloud (shared/CLOUD.md §13).
        if !isReachable, CloudService.goesThroughCloud(body), CloudService.shared.canReach(self) {
            CloudService.shared.sendCompanion(body, to: self)
            return
        }
        ping("ge.connect." + body)
    }

    func setRinger(_ mode: String) {
        var s = status ?? Status(); s.ringer = mode; status = s
        command("ringer:" + mode)
    }

    func setFlashlight(_ on: Bool) {
        var s = status ?? Status(); s.flashlight = on; status = s
        command("flashlight:" + (on ? "on" : "off"))
    }

    /// Places a call from the phone.
    func dial(_ number: String) {
        let clean = number.filter { $0.isNumber || "+*#".contains($0) }
        guard !clean.isEmpty else { return }
        command("dial:" + clean)
        AppModel.shared.log(.info, "Calling \(contact(for: clean)?.name ?? clean) from \(name)")
    }

    func declineCall() {
        command("call:decline")
        AppModel.shared.log(.info, "Asked \(name) to decline the call")
    }
    func muteRinger() {
        command("call:mute")
        AppModel.shared.log(.info, "Asked \(name) to silence the ringer")
    }

    private func applyStatus(_ text: String) {
        if !UserDefaults.standard.bool(forKey: "reportsStatus.\(id)") { UserDefaults.standard.set(true, forKey: "reportsStatus.\(id)") }
        MacState.changed()   // first report after connecting: send the Mac's own state back (only if new)
        var s = status ?? Status()
        for pair in text.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "ringer": s.ringer = kv[1]
            // Through Janus Cloud the status carries the battery (on the LAN it comes from the battery plugin).
            case "battery": if let c = Int(kv[1]), (0...100).contains(c) { batteryCharge = c }
            case "charging": isCharging = kv[1] == "1"
            case "flashlight": s.flashlight = kv[1] == "on"
            case "dnd": phoneDND = kv[1] == "on"
            case "wifi": s.ssid = kv[1].isEmpty ? nil : kv[1]
            case "carrier": s.carrier = kv[1].isEmpty ? nil : kv[1]
            case "net": s.cellular = kv[1].isEmpty ? nil : kv[1]
            case "os":
                s.os = kv[1].isEmpty ? nil : kv[1]
                if let os = s.os { DeviceProfiles.learnFromStatus(os: os, device: self) }
            case "storage":
                let parts = kv[1].split(separator: "/").compactMap { Int64($0) }
                if parts.count == 2 { s.storageFree = parts[0]; s.storageTotal = parts[1] }
            default: break
            }
        }
        status = s
    }

    /// True while we believe the phone is ringing (Find Phone); see `toggleRing`.
    var isRinging = false
    @ObservationIgnored private var ringTimeout: Task<Void, Never>?

    // Do Not Disturb (nil = unknown)
    var phoneDND: Bool?
    @ObservationIgnored var lastDNDCommand: (on: Bool, date: Date)?

    // Connection statistics
    var connectedSince: Date?
    var lastSeen: Date?
    var latencyMs: Double?
    var latencyHistory: [Double] = []      // last ~30 samples, 10 s apart
    var packetLoss = 0                     // failed pings in the history window
    var disconnects = 0

    // Messages
    var conversations: [Int64: SMSMessage] = [:]      // thread → latest message
    var threads: [Int64: [Int32: SMSMessage]] = [:]    // thread → uID → message
    var loadingThreads: Set<Int64> = []
    /// Contacts by `ContactBook.key` (several can share one).
    var contactsByNumber: [String: [(number: String, contact: PhoneContact)]] = [:]
    var contacts: [PhoneContact] = []

    init(id: String, bus: any EngineBus) {
        self.id = id
        self.bus = bus
        profile = DeviceProfiles.get(id)
        loadReadMarks()
    }

    func recordLatency(_ ms: Double?) {
        latencyMs = ms
        latencyHistory.append(ms ?? -1)
        if latencyHistory.count > 30 { latencyHistory.removeFirst(latencyHistory.count - 30) }
        packetLoss = latencyHistory.filter { $0 < 0 }.count
    }

    var transport: String {
        if providers.contains(where: { $0.localizedCaseInsensitiveContains("bluetooth") }) { return "Bluetooth" }
        if providers.contains(where: { $0.localizedCaseInsensitiveContains("lan") }) { return "Wi-Fi (local network)" }
        return providers.first ?? "—"
    }

    /// Sets (or with nil/empty, clears) the nickname shown on this Mac.
    func rename(_ nickname: String?) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DeviceNicknames.set(id, trimmed.isEmpty || trimmed == announcedName ? nil : trimmed)
        name = DeviceNicknames.get(id) ?? announcedName
    }

    func has(_ plugin: String) -> Bool { loadedPlugins.contains("kdeconnect_" + plugin) }

    /// An Android TV running Janus (R38): it only gets TV things here (media control, remote input, screen sharing),
    /// no files, clipboard, notes, Find, notifications or calendar.
    var isTV: Bool { type == "tv" }

    /// Whether this device has that section in the main window.
    func shows(_ pane: Pane) -> Bool {
        !isTV || [.overview, .media, .remote, .connection, .settings].contains(pane)
    }

    var statusText: String {
        if isPairRequestedByPeer { return "Wants to pair" }
        if isPairRequested { return "Waiting for phone…" }
        if !isPaired { return isReachable ? "Not paired" : "Unavailable" }
        guard isReachable else { return "Not connected" }
        let via = providers.contains { $0.localizedCaseInsensitiveContains("bluetooth") } ? "Bluetooth" : "Wi-Fi"
        return "Connected via \(via)"
    }

    var symbol: String {
        switch type {
        case "tablet": "ipad"
        case "tv": "tv"
        case "desktop": "desktopcomputer"
        case "laptop": "laptopcomputer"
        default: "smartphone"
        }
    }

    // MARK: D-Bus helpers

    @discardableResult
    func call(_ sub: String?, _ iface: String, _ member: String, _ args: [DBusValue] = []) async throws -> [DBusValue] {
        try await bus.call(destination: EnginePaths.service, path: sub.map { path + "/" + $0 } ?? path,
                           interface: "org.kde.kdeconnect.device" + (iface.isEmpty ? "" : "." + iface),
                           member: member, args)
    }

    /// Fire-and-forget action that surfaces failures in `lastError`.
    func perform(_ sub: String?, _ iface: String, _ member: String, _ args: [DBusValue] = []) {
        Task {
            do { try await call(sub, iface, member, args) } catch { lastError = error.localizedDescription }
        }
    }

    func props(_ sub: String?, _ iface: String) async -> [String: DBusValue] {
        (try? await bus.getAllProperties(destination: EnginePaths.service, path: sub.map { path + "/" + $0 } ?? path,
                                         interface: "org.kde.kdeconnect.device" + (iface.isEmpty ? "" : "." + iface))) ?? [:]
    }

    // MARK: Refresh

    func refresh() async {
        let p = await props(nil, "")
        let wasReachable = isReachable
        let wasPaired = isPaired
        type = p["type"]?.string ?? type
        announcedName = p["name"]?.string ?? announcedName
        name = DeviceNicknames.get(id) ?? announcedName
        isReachable = p["isReachable"]?.bool ?? false
        if isReachable && (!wasReachable || connectedSince == nil) {
            connectedSince = .now
            // Notes: hello on every connection (the saved profile says whether this phone syncs them).
            if !wasReachable { NotesStore.shared.connected(self) }
        }
        if !isReachable && wasReachable {
            lastSeen = .now; connectedSince = nil; latencyMs = nil; disconnects += 1
            phoneDND = nil          // the next report after reconnecting is the initial state again
            status = nil
            live = []
            // What was on the phone moves to Notifications → Earlier; the phone re-sends what's still there.
            notifications.forEach { NotificationHistory.shared.ended($0, device: self) }
            notifications = []
            activeCall = nil
            statusRequested = false
            MacState.forget(self)
        }
        // This app may have started after the phone connected and missed its on-connect report.
        // Only ask phones known to run our app (others would show the command as a ping).
        if isReachable, status == nil, !statusRequested, UserDefaults.standard.bool(forKey: "reportsStatus.\(id)"),
           DeviceTrust.isMine(self) {
            statusRequested = true
            command("status")
        }
        isPaired = p["isPaired"]?.bool ?? false
        isPairRequested = p["isPairRequested"]?.bool ?? false
        isPairRequestedByPeer = p["isPairRequestedByPeer"]?.bool ?? false
        verificationKey = p["verificationKey"]?.string ?? ""
        addresses = p["reachableAddresses"]?.strings ?? []
        providers = p["activeProviderNames"]?.strings ?? []
        supportedPlugins = p["supportedPlugins"]?.strings ?? []
        let loaded = Set((try? await call(nil, "", "loadedPlugins").first?.strings) ?? [])
        let newlyLoaded = loaded.subtracting(loadedPlugins)
        let pluginsChanged = loaded != loadedPlugins
        if pluginsChanged { loadedPlugins = loaded }
        // Which plugins are switched on: asked (one call per plugin) only when something about plugins changed.
        var enabled = enabledPlugins
        if pluginStateStale || pluginsChanged {
            enabled = []
            for plugin in supportedPlugins {
                if (try? await call(nil, "", "isPluginEnabled", [.string(plugin)]).first?.bool) == true { enabled.insert(plugin) }
            }
            pluginStateStale = false
            if enabled != enabledPlugins { enabledPlugins = enabled }
        }
        // My device / someone else's: ask once after pairing; keep someone else's device limited.
        if UserDefaults.standard.bool(forKey: "trust.migrated"), isPaired {
            if !wasPaired, DeviceTrust.level(self) == nil { DeviceTrust.ask(self) }
            if !DeviceTrust.isMine(self), !enabled.subtracting(DeviceTrust.allowedForOthers).isEmpty {
                await DeviceTrust.apply(self)
            }
        }
        guard isPaired && isReachable else { return }
        await refreshPlugins(firstLoad: !newlyLoaded.isEmpty)
    }

    /// Set when the engine says plugins changed (or at start): the next refresh asks which are enabled.
    @ObservationIgnored var pluginStateStale = true

    func refreshPlugins(firstLoad: Bool) async {
        if has("battery") {
            let b = await props("battery", "battery")
            batteryCharge = b["charge"]?.int.flatMap { $0 >= 0 ? $0 : nil }
            isCharging = b["isCharging"]?.bool ?? false
        }
        if has("connectivity_report") {
            let c = await props("connectivity_report", "connectivity_report")
            networkType = c["cellularNetworkType"]?.string ?? ""
            networkStrength = c["cellularNetworkStrength"]?.int ?? -1
        }
        if has("clipboard") {
            clipboardAutoShareDisabled = (await props("clipboard", "clipboard"))["isAutoShareDisabled"]?.bool ?? false
        }
        if has("remotekeyboard") {
            remoteKeyboardActive = (await props("remotekeyboard", "remotekeyboard"))["remoteState"]?.bool ?? false
        }
        if has("mprisremote") { await refreshMedia() }
        // Notifications come and go as signals; the full list is read when the phone (re)connects.
        if firstLoad, has("notifications") { await refreshNotifications() }
        if firstLoad {
            if has("contacts") {
                loadContacts()
                perform("contacts", "contacts", "synchronizeRemoteWithLocal")
            }
            if has("sms") { await refreshConversations() }
        }
    }

    // MARK: Signals

    func handle(member: String, interface: String, subpath: String?, body: [DBusValue]) {
        switch (subpath?.split(separator: "/").first.map(String.init), member) {
        case (nil, "nameChanged"):
            announcedName = body.first?.string ?? announcedName
            name = DeviceNicknames.get(id) ?? announcedName
        case (nil, "pluginsChanged"), (nil, "linksChanged"), (nil, "statusIconNameChanged"), (nil, "typeChanged"):
            if member == "pluginsChanged" { pluginStateStale = true }
            Task { await refresh() }
        case (nil, "pairingFailed"): lastError = "Pairing failed: " + (body.first?.string ?? "")
        case (nil, "conversationCreated"), (nil, "conversationUpdated"):
            if let m = body.first.flatMap(SMSMessage.init) { ingest(m) }
        case (nil, "conversationRemoved"):
            if let t = body.first?.int { conversations[Int64(t)] = nil; threads[Int64(t)] = nil }
        case (nil, "conversationLoaded"):
            if let t = body.first?.int { loadingThreads.remove(Int64(t)) }
        case ("battery", "refreshed"):
            let previous = batteryCharge
            isCharging = body.first?.bool ?? isCharging
            batteryCharge = body.dropFirst().first?.int.flatMap { $0 >= 0 ? $0 : nil }
            if let now = batteryCharge, now <= 15, !isCharging, (previous ?? 100) > 15 {
                Notifier.shared.batteryLow(now, device: self)
            }
        case ("connectivity_report", "refreshed"):
            networkType = body.first?.string ?? ""
            networkStrength = body.dropFirst().first?.int ?? -1
        case ("clipboard", "autoShareDisabledChanged"):
            clipboardAutoShareDisabled = body.first?.bool ?? false
        case ("remotekeyboard", "remoteStateChanged"):
            remoteKeyboardActive = body.first?.bool ?? false
        case ("mprisremote", _):
            Task { await refreshMedia() }
        case ("notifications", "notificationPosted"), ("notifications", "notificationUpdated"):
            if let nid = body.first?.string {
                debugLiveLog("signal \(member) \(nid)")
                let isNew = member == "notificationPosted" && !notifications.contains { $0.id == nid }
                let before = notifications.first { $0.id == nid }.map(\.codeText)
                Task {
                    await loadNotification(nid)
                    guard let n = notifications.first(where: { $0.id == nid }) else { return }
                    if n.isControl {
                        // Companion messages from our phone app (see shared/CONTRACT.md).
                        notifications.removeAll { $0.id == nid }
                        companion(n, isNew: isNew, via: member)
                    } else if isNew {
                        AppModel.shared.log(.info, "Notification from \(n.appName.isEmpty ? "an app" : n.appName) on \(name)")
                        let hadCode = checkForCode(n, isNew: true, before: nil)
                        // A code notification replaces the plain mirror of the same message.
                        if !hadCode, !n.silent { Notifier.shared.phoneNotification(n, device: self) }
                    } else {
                        checkForCode(n, isNew: false, before: before)   // changed in place
                    }
                }
            }
        case ("notifications", "notificationRemoved"):
            if let nid = body.first?.string {
                endLive(nid)
                if nid == callStateID { endCallState() }
                if let n = notifications.first(where: { $0.id == nid }) { NotificationHistory.shared.ended(n, device: self) }
                notifications.removeAll { $0.id == nid }
                Notifier.shared.removePhoneNotification(nid, device: self)
            }
        case ("telephony", "callReceived"):
            Notifier.shared.call(event: body.first?.string ?? "", number: body.dropFirst().first?.string ?? "",
                                 contactName: body.dropFirst(2).first?.string ?? "", device: self)
        case ("notifications", "allNotificationsRemoved"):
            notifications.forEach { NotificationHistory.shared.ended($0, device: self) }
            notifications = []
        case ("share", "shareReceived"):
            if let s = body.first?.string, let url = URL(string: s) {
                // A note's attachment (R30) goes to the notes, not Downloads, and isn't a transfer.
                if url.isFileURL, DeviceTrust.isMine(self), NoteAttachments.shared.take(url, from: self) { return }
                if url.isFileURL, !DeviceTrust.isMine(self) {
                    DeviceTrust.confirmFile(url, from: self)
                    return
                }
                received.insert(ReceivedItem(url: url), at: 0)
                TransferStore.shared.received(url, device: self)
                Notifier.shared.received(url, device: self)
            }
        case ("contacts", "localCacheSynchronized"):
            loadContacts()
        default: break
        }
    }

    // MARK: Pairing & plugins

    func requestPairing() { perform(nil, "", "requestPairing") }
    func acceptPairing() { perform(nil, "", "acceptPairing") }
    func rejectPairing() { perform(nil, "", "cancelPairing") }
    func unpair() { perform(nil, "", "unpair") }

    /// Automatic clipboard sharing from this Mac (the engine's clipboard "autoShare" setting). Off keeps
    /// the clipboard feature itself: phone copies still arrive and "Send Clipboard" works.
    func setClipboardAutoSync(_ on: Bool) {
        clipboardAutoShareDisabled = !on
        let dir = LocalIdentity.folder.appendingPathComponent("\(id)/kdeconnect_clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "[General]\nautoShare=\(on)\n".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppModel.shared.log(.info, "Automatic clipboard sync with \(name) \(on ? "on" : "off")")
        Task {
            // Reload the plugin so it reads the setting (and make sure it's on at all).
            _ = try? await call(nil, "", "setPluginEnabled", [.string("kdeconnect_clipboard"), .bool(false)])
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await call(nil, "", "setPluginEnabled", [.string("kdeconnect_clipboard"), .bool(true)])
            await refresh()
        }
    }

    func setPlugin(_ plugin: String, enabled: Bool) {
        if enabled { enabledPlugins.insert(plugin) } else { enabledPlugins.remove(plugin) }
        Task {
            try? await call(nil, "", "setPluginEnabled", [.string(plugin), .bool(enabled)])
            await refresh()
        }
    }

    func encryptionInfo() async -> String {
        (try? await call(nil, "", "encryptionInfo").first?.string) ?? ""
    }

    // MARK: Quick actions

    func ping(_ message: String? = nil) {
        perform("ping", "ping", "sendPing", message.map { [.string($0)] } ?? [])
    }
    func ring() {
        guard !isTV else { return }
        if !isReachable, CloudService.shared.canReach(self) { CloudService.shared.sendCompanion("findmyphone", to: self); return }
        perform("findmyphone", "findmyphone", "ring")
    }

    /// Find Phone as a toggle: a second request while ringing asks our phone app to stop (it also
    /// reports ringing on/off with a `ge.connect.ring:` marker). Falls back to "off" after 60 s.
    func toggleRing() {
        ring()
        setRinging(!isRinging)
    }

    /// `confirmed`: the phone itself reported the state, so no fallback timer is needed
    /// (the phone rings until it's stopped).
    func setRinging(_ on: Bool, confirmed: Bool = false) {
        isRinging = on
        ringTimeout?.cancel()
        guard on, !confirmed else { return }
        ringTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { self?.isRinging = false }
        }
    }
    func sendClipboard() { perform("clipboard", "clipboard", "sendClipboard") }
    /// A file for our phone app's own use (a note's attachment): no Transfers entry or card.
    func shareQuietly(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform("share", "share", "shareUrls", [.strings(urls.map(\.absoluteString))])
    }

    func share(_ urls: [URL]) {
        guard !urls.isEmpty, !isTV else { return }
        // Not on the same network: through Janus Cloud, if this phone is set up for it (or always, for testing).
        if !isReachable || UserDefaults.standard.bool(forKey: "cloud.force"), CloudService.shared.peer(forDevice: id) != nil {
            CloudTransfers.shared.send(urls, to: self)
            return
        }
        TransferStore.shared.beginSend(urls, device: self)
        perform("share", "share", "shareUrls", [.strings(urls.map(\.absoluteString))])
    }
    func shareText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isTV else { return }
        if !isReachable, CloudService.shared.canReach(self) {
            let isLink = URL(string: t).flatMap(\.scheme).map { ["http", "https"].contains($0) } ?? false
            TransferStore.shared.sentText(t, isLink: isLink, device: self)
            CloudService.shared.sendText(t, isLink: isLink, to: self)
            return
        }
        if let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            TransferStore.shared.sentText(t, isLink: true, device: self)
            perform("share", "share", "shareUrl", [.string(t)])
        } else {
            TransferStore.shared.sentText(t, isLink: false, device: self)
            perform("share", "share", "shareText", [.string(t)])
        }
    }

    // MARK: Media

    func refreshMedia() async {
        let p = await props("mprisremote", "mprisremote")
        guard !p.isEmpty else { return }
        var m = MediaState()
        m.players = p["playerList"]?.strings ?? []
        m.player = p["player"]?.string ?? ""
        m.title = p["title"]?.string ?? ""
        m.artist = p["artist"]?.string ?? ""
        m.album = p["album"]?.string ?? ""
        m.artURL = p["localAlbumArtUrl"]?.string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        m.isPlaying = p["isPlaying"]?.bool ?? false
        m.length = p["length"]?.int ?? 0
        m.position = p["position"]?.int ?? 0
        m.positionDate = .now
        m.volume = p["volume"]?.int ?? 0
        m.canSeek = p["canSeek"]?.bool ?? false
        // While seeking or switching tracks the phone can briefly report an empty track; keep what we had.
        if !m.hasTrack, media.hasTrack, !m.players.isEmpty {
            m.title = media.title; m.artist = media.artist; m.album = media.album
            m.artURL = m.artURL ?? media.artURL
        }
        if media != m { media = m }   // unchanged state doesn't redraw the views showing it
    }

    func mediaAction(_ action: String) {
        if action == "PlayPause" {   // optimistic toggle so the button responds instantly
            media.position = media.currentPosition(); media.positionDate = .now
            media.isPlaying.toggle()
        }
        perform("mprisremote", "mprisremote", "sendAction", [.string(action)])
    }

    func setVolume(_ v: Int) {
        media.volume = v
        Task { try? await setMediaProperty("volume", .int32(Int32(v))) }
    }

    func seek(to ms: Int) {
        media.position = ms; media.positionDate = .now
        Task { try? await setMediaProperty("position", .int32(Int32(ms))) }
    }

    func selectPlayer(_ player: String) {
        media.player = player
        Task {
            try? await setMediaProperty("player", .string(player))
            await refreshMedia()
        }
    }

    private func setMediaProperty(_ name: String, _ value: DBusValue) async throws {
        try await bus.setProperty(destination: EnginePaths.service, path: path + "/mprisremote",
                                  interface: "org.kde.kdeconnect.device.mprisremote", name: name, value: value)
    }

    // MARK: Calls

    func hangUp() {
        command("call:hangup")
        AppModel.shared.log(.info, "Asked \(name) to hang up")
    }

    func applyCallState(id: String, json: String) {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        callStateID = id
        callEnding?.cancel(); callEnding = nil
        let number = o["number"] as? String ?? ""
        let name = o["name"] as? String ?? ""
        guard (o["state"] as? String) == "talking", let ms = (o["start"] as? NSNumber)?.doubleValue else { return }
        let skew = ((o["now"] as? NSNumber)?.doubleValue).map { Date().timeIntervalSince1970 - $0 / 1000 } ?? 0
        let start = Date(timeIntervalSince1970: ms / 1000 + (abs(skew) < 600 ? skew : 0))
        activeCall = ActiveCall(number: number, name: name, start: start)
        CallPopup.shared.answered(number: number, name: name, start: start, device: self)
    }

    /// Ended after a short grace: ringing → talking arrives as a removal followed by a new post.
    private func endCallState() {
        callEnding?.cancel()
        callEnding = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let hadCall = self.activeCall
            self.activeCall = nil
            self.callStateID = nil
            if hadCall != nil { CallPopup.shared.activeEnded(deviceID: self.id) }
        }
    }

    // MARK: Live activities

    @ObservationIgnored private var liveEnding: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var livePoll: Task<Void, Never>?

    /// The phone re-sends a live activity whenever it changes (cancel + repost), which arrives as signals. As a safety
    /// net for an in-place update the engine wouldn't announce, the few live objects are re-read every 5 s, only while
    /// the panel or main window shows them; nothing runs while hidden.
    func watchLive() {
        guard livePoll == nil, !live.isEmpty, AppModel.uiVisible else { return }
        livePoll = Task { [weak self] in
            while let self, !self.live.isEmpty, AppModel.uiVisible, !Task.isCancelled {
                for id in self.live.map(\.id) where self.liveEnding[id] == nil {
                    let p = (try? await self.bus.getAllProperties(destination: EnginePaths.service,
                                                                   path: self.path + "/notifications/" + id,
                                                                   interface: "org.kde.kdeconnect.device.notifications.notification")) ?? [:]
                    guard let text = p["text"]?.string else { continue }   // gone: the removal signal handles it
                    if text != self.liveJSON[id] {
                        self.upsertLive(id: id, json: text, iconPath: p["iconPath"]?.string.flatMap { $0.isEmpty ? nil : $0 }, via: "poll")
                    }
                }
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            }
            self?.livePoll = nil
        }
    }
    @ObservationIgnored private var liveJSON: [String: String] = [:]

    /// Every packet is a complete snapshot: it replaces what we had (nothing is merged).
    func upsertLive(id: String, json: String, iconPath: String?, via: String) {
        debugLiveLog("\(via) \(id) \(json)")
        // A packet read again at startup ("refresh") is older than its "now": no clock correction for it.
        guard var a = LiveActivity(id: id, json: json, iconPath: iconPath, fresh: via != "refresh") else { return }
        // Calls are phone calls only: those have the call card, with a clock that ends with the call. An app's call
        // (WhatsApp, Telegram…) isn't one: its clock never learned the call had ended, and its buttons can't work here.
        if a.category == "call" {
            live.removeAll { $0.id == id }
            liveJSON[id] = nil
            return
        }
        liveJSON[id] = json
        defer { watchLive() }
        // The phone sends each app's icon once per connection; later packets only refer to it.
        if a.iconPath == nil { a.iconPath = live.first(where: { $0.id == id })?.iconPath ?? liveIcons[a.app] }
        if let p = a.iconPath { liveIcons[a.app] = p }
        if let i = live.firstIndex(where: { $0.id == id }) {
            live[i] = a
        } else if let j = live.firstIndex(where: { liveEnding[$0.id] != nil && $0.app == a.app && $0.title == a.title }) {
            // Samsung re-keys a timer (ends one id, posts the same under a new id): swap in place, no flicker.
            liveEnding.removeValue(forKey: live[j].id)?.cancel()
            live[j] = a
        } else {
            live.append(a)
        }
    }

    /// Ends after a short grace period, so a re-keyed activity can take its place without a flicker.
    func endLive(_ id: String) {
        guard live.contains(where: { $0.id == id }) else { return }
        debugLiveLog("end \(id)")
        liveEnding[id]?.cancel()
        liveEnding[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.live.removeAll { $0.id == id }
            self.liveEnding[id] = nil
            self.liveJSON[id] = nil
        }
    }

    private func debugLiveLog(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "debugSnapshots") else { return }
        let url = DebugSnapshot.dir.appendingPathComponent("live.log")
        let entry = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Notifications

    func refreshNotifications() async {
        let ids = (try? await call("notifications", "notifications", "activeNotifications").first?.strings) ?? []
        for n in notifications where !ids.contains(n.id) { NotificationHistory.shared.ended(n, device: self) }
        notifications.removeAll { !ids.contains($0.id) }
        for nid in ids { await loadNotification(nid) }
        if let dnd = notifications.last(where: \.isDND) { phoneDND = dnd.text.lowercased().contains("on") }
        // Live activities that started before this app did (e.g. after an update) are already there.
        for n in notifications where n.isLive { upsertLive(id: n.id, json: n.text, iconPath: n.iconPath, via: "refresh") }
        if DeviceTrust.isMine(self), let cal = notifications.last(where: \.isCalendar) { CalendarStore.shared.apply(json: cal.text, from: self) }
        if let p = notifications.last(where: \.isProfile) { DeviceProfiles.apply(json: p.text, from: self) }
        notifications.removeAll(where: \.isControl)
    }

    private func loadNotification(_ nid: String) async {
        let p = (try? await bus.getAllProperties(destination: EnginePaths.service, path: path + "/notifications/" + nid,
                                                  interface: "org.kde.kdeconnect.device.notifications.notification")) ?? [:]
        guard !p.isEmpty else { return }
        var n = notifications.first { $0.id == nid } ?? PhoneNotification(id: nid)
        n.internalId = p["internalId"]?.string ?? ""
        n.appName = p["appName"]?.string ?? ""
        n.title = p["title"]?.string ?? ""
        n.text = p["text"]?.string ?? ""
        n.ticker = p["ticker"]?.string ?? ""
        n.iconPath = p["iconPath"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        n.dismissable = p["dismissable"]?.bool ?? true
        n.replyId = p["replyId"]?.string ?? ""
        n.actions = p["actions"]?.strings ?? []
        n.silent = p["silent"]?.bool ?? false
        // Kept for 24 hours (Notifications → Earlier); one re-sent after a reconnect keeps its original time.
        if !n.isControl { n.postedAt = NotificationHistory.shared.record(n, device: self) }
        if let i = notifications.firstIndex(where: { $0.id == nid }) {
            notifications[i] = n
        } else {
            notifications.insert(n, at: 0)
        }
    }

    /// A companion message from our phone app (see shared/CONTRACT.md): over the LAN as a silent notification, or
    /// through Janus Cloud (`c` envelope, shared/CLOUD.md §13). `isNew`: not a re-send of one already handled.
    func companion(_ n: PhoneNotification, isNew: Bool, via member: String) {
        if n.isMirrorInfo {
            if isNew { MirrorController.shared.phoneMessage(n.text, from: self) }
            return
        }
        if n.isCallState {
            applyCallState(id: n.id, json: n.text)
            return
        }
        if n.isLive {
            upsertLive(id: n.id, json: n.text, iconPath: n.iconPath, via: member)
            return
        }
        if n.isCalendar {
            if DeviceTrust.isMine(self) { CalendarStore.shared.apply(json: n.text, from: self) }
            return
        }
        if n.isProfile {
            DeviceProfiles.apply(json: n.text, from: self)
            return
        }
        if n.isTVApps {
            if isNew { TVApps.shared.receive(n.text, from: self) }
            return
        }
        guard isNew else { return }
        if n.isNotes {
            NotesStore.shared.receive(n.text, from: self)
        } else if n.isCloud {
            CloudService.shared.receiveLAN(n.text, from: self)
        } else if n.isPing {
            Notifier.shared.ping(from: self, message: n.text)
        } else if n.isDND {
            phoneReportedDND(n.text.lowercased().contains("on"))
        } else if n.isStatusInfo {
            applyStatus(n.text)
        } else if n.isCallResult {
            CallPopup.shared.result(n.text, device: self)
        } else if n.isScreenshotInfo {
            TransferStore.shared.expectScreenshot(named: n.text, from: self)
        } else if n.isRingInfo {
            setRinging(n.text.lowercased().contains("on"), confirmed: true)
        } else if n.isTransferInfo {
            let parts = n.text.split(separator: "|")
            if let total = parts.first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) {
                let count = parts.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                TransferStore.shared.expectIncoming(totalBytes: total, files: count, device: self)
            }
        }
    }

    /// Looks for a one-time code in a notification. Returns whether it has one (it's shown as a code then, not mirrored).
    /// Also when a notification changes in place: messaging apps keep one notification per conversation and update it
    /// for each new message, so the second and later codes from the same sender only ever arrive as updates. A
    /// notification re-sent after a reconnect (posted more than 10 minutes ago) isn't announced again.
    @discardableResult
    func checkForCode(_ n: PhoneNotification, isNew: Bool, before: String?) -> Bool {
        let text = n.codeText
        guard isNew || text != before, let code = CodeDetector.code(in: text) else { return false }
        // Each notification's codes are announced once: a conversation that gets another (plain) message later
        // still shows the old code, which isn't new.
        if codesShown[n.id, default: []].contains(code) { return true }
        if codesShown.count > 100 { codesShown = [:] }
        codesShown[n.id, default: []].insert(code)
        if isNew, Date().timeIntervalSince(n.postedAt) >= 600 { return true }
        CodeCenter.shared.inspect(text, from: n.title.isEmpty ? n.appName : n.title, device: self)
        return true
    }
    /// Codes already announced, per phone notification.
    @ObservationIgnored private var codesShown: [String: Set<String>] = [:]

    func dismiss(_ n: PhoneNotification) {
        notifications.removeAll { $0.id == n.id }
        NotificationHistory.shared.remove(n, device: self)   // dismissed here: gone, not "earlier"
        Task {
            _ = try? await bus.call(destination: EnginePaths.service, path: path + "/notifications/" + n.id,
                                    interface: "org.kde.kdeconnect.device.notifications.notification", member: "dismiss")
        }
    }

    func reply(to n: PhoneNotification, _ text: String) {
        perform("notifications", "notifications", "sendReply", [.string(n.replyId), .string(text)])
    }

    func trigger(_ action: String, on n: PhoneNotification) {
        perform("notifications", "notifications", "sendAction", [.string(n.internalId), .string(action)])
    }

    // MARK: Do Not Disturb

    /// Asks our phone app to turn Do Not Disturb on/off (a ping carrying a `ge.connect.dnd:` command).
    func setPhoneDND(_ on: Bool, reason: String) {
        lastDNDCommand = (on, .now)
        phoneDND = on
        ping(PhoneNotification.dndPrefix + (on ? "on" : "off"))
        AppModel.shared.log(.info, "Phone Do Not Disturb \(on ? "on" : "off") (\(reason))")
    }

    private func phoneReportedDND(_ on: Bool) {
        // The first report after connecting just tells us the current state; it isn't a change.
        let initial = phoneDND == nil
        let changed = !initial && phoneDND != on
        phoneDND = on
        if initial { AppModel.shared.log(.info, "\(name): Do Not Disturb is \(on ? "on" : "off")") }
        // Our own command coming back isn't a change made on the phone.
        if let c = lastDNDCommand, c.on == on, Date().timeIntervalSince(c.date) < 15 { return }
        if changed { AppModel.shared.phoneDNDChanged(on, device: self) }
    }

    // MARK: Remote input

    func moveCursor(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        bus.send(destination: EnginePaths.service, path: path + "/remotecontrol",
                 interface: "org.kde.kdeconnect.device.remotecontrol", member: "moveCursor",
                 [.structure([.int32(Int32(dx)), .int32(Int32(dy))])])
    }

    /// Commands understood by the phone's mouse receiver: singleclick, doubleclick, rightclick,
    /// middleclick, singlehold, singlerelease, scroll (+dx/dy).
    func pointerCommand(_ fields: [String: DBusValue]) {
        let dict = DBusValue.dict(key: "s", value: "v", fields.map { (.string($0.key), .variant($0.value)) })
        bus.send(destination: EnginePaths.service, path: path + "/remotecontrol",
                 interface: "org.kde.kdeconnect.device.remotecontrol", member: "sendCommand", [dict])
    }

    func sendKey(_ key: String, special: Int = 0, shift: Bool = false, ctrl: Bool = false, alt: Bool = false) {
        bus.send(destination: EnginePaths.service, path: path + "/remotekeyboard",
                 interface: "org.kde.kdeconnect.device.remotekeyboard", member: "sendKeyPress",
                 [.string(key), .int32(Int32(special)), .bool(shift), .bool(ctrl), .bool(alt), .bool(false)])
    }

    func sendText(_ text: String) {
        for ch in text { sendKey(ch == "\n" ? "" : String(ch), special: ch == "\n" ? 12 : 0) }
    }

    // MARK: Messages

    func refreshConversations() async {
        let list = (try? await call(nil, "conversations", "activeConversations").first?.array) ?? []
        for v in list { if let m = SMSMessage(v) { ingest(m) } }
        perform(nil, "conversations", "requestAllConversationThreads")
    }

    func ingest(_ m: SMSMessage) {
        // Brand-new incoming SMS (not history being loaded): look for a verification code.
        if m.isIncoming, Date().timeIntervalSince(m.date) < 180,
           conversations[m.threadID]?.uID != m.uID, threads[m.threadID]?[m.uID] == nil {
            CodeCenter.shared.inspect(m.body, from: displayName(for: m.addresses), device: self)
        }
        if let current = conversations[m.threadID] {
            if m.date >= current.date { conversations[m.threadID] = m }
        } else {
            conversations[m.threadID] = m
        }
        if threads[m.threadID] != nil { threads[m.threadID]![m.uID] = m }
    }

    func loadThread(_ thread: Int64, more: Bool = false) {
        let have = threads[thread]?.count ?? 0
        if threads[thread] == nil { threads[thread] = [:] }
        if let latest = conversations[thread] { threads[thread]![latest.uID] = latest }
        guard more || have == 0 else { return }
        loadingThreads.insert(thread)
        perform(nil, "conversations", "requestConversation", [.int64(thread), .int32(Int32(have)), .int32(Int32(have + 60))])
    }

    func sendMessage(_ text: String, thread: Int64) {
        perform(nil, "conversations", "replyToConversation", [.int64(thread), .string(text), .array(element: "v", [])])
    }

    func sendMessage(_ text: String, to numbers: [String]) {
        let addrs = numbers.map { DBusValue.variant(.structure([.string($0)])) }
        perform(nil, "conversations", "sendWithoutConversation", [.array(element: "v", addrs), .string(text), .array(element: "v", [])])
    }

    func loadContacts() {
        let id = self.id
        Task.detached(priority: .utility) {
            let list = ContactBook.load(deviceID: id).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            await MainActor.run {
                self.contacts = list
                var map: [String: [(number: String, contact: PhoneContact)]] = [:]
                for c in list { for n in c.numbers { map[ContactBook.key(for: n), default: []].append((n, c)) } }
                self.contactsByNumber = map
            }
        }
    }

    func contact(for number: String) -> PhoneContact? {
        let candidates = contactsByNumber[ContactBook.key(for: number)] ?? []
        return candidates.first { ContactBook.sameNumber($0.number, number) }?.contact
    }

    func displayName(for addresses: [String]) -> String {
        let names = addresses.map { contact(for: $0)?.name ?? $0 }
        return names.isEmpty ? "Unknown" : ListFormatter.localizedString(byJoining: names)
    }

    var sortedConversations: [SMSMessage] {
        conversations.values.sorted { $0.date > $1.date }
    }

    var unreadCount: Int { conversations.values.filter(isUnread).count }

    // MARK: Read state
    // Android lets only the default SMS app change a message's read flag, so "read" is tracked here on
    // the Mac: a thread counts as read up to the newest message shown while it was open.

    /// thread → date of the newest message seen on this Mac.
    var readMarks: [Int64: Date] = [:]
    private var readMarksKey: String { "readMarks.\(id)" }

    func loadReadMarks() {
        let raw = UserDefaults.standard.dictionary(forKey: readMarksKey) as? [String: Double] ?? [:]
        readMarks = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int64(k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }

    func isUnread(_ m: SMSMessage) -> Bool {
        guard m.isIncoming, !m.isRead else { return false }
        return m.date > (readMarks[m.threadID] ?? .distantPast)
    }

    func markRead(_ thread: Int64) {
        guard let latest = conversations[thread]?.date else { return }
        if let mark = readMarks[thread], mark >= latest { return }
        readMarks[thread] = latest
        let raw = Dictionary(uniqueKeysWithValues: readMarks.map { (String($0.key), $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(raw, forKey: readMarksKey)
    }

    func markAllRead() { for t in conversations.keys { markRead(t) } }
}

/// Per-device nicknames, stored on this Mac only (the engine can't rename a remote device).
enum DeviceNicknames {
    private static let key = "deviceNicknames"
    static func get(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id]
    }
    static func set(_ id: String, _ name: String?) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[id] = name
        UserDefaults.standard.set(all, forKey: key)
    }
}
