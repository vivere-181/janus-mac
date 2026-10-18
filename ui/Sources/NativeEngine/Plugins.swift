import AppKit
import Foundation
import IOKit.ps
import JanusLink
import KDEConnectKit

// The first native plugins (R40 phase 2). Each one shows the app the same object, properties, methods and signals as
// KDE's plugin of that name, so the app works unchanged.

// MARK: Ping

final class PingPlugin: NativePlugin {
    override class var id: String { "kdeconnect_ping" }
    override class var subpath: String? { "ping" }
    override class var interface: String { "ping" }
    override class var incoming: [String] { ["kdeconnect.ping"] }
    override class var outgoing: [String] { ["kdeconnect.ping"] }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "sendPing" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        var p = Packet("kdeconnect.ping")
        if let m = args.first?.string { p["message"] = m }
        send(p)
        return []
    }

    // A ping from the phone: the app shows its own (companion messages carry everything it needs).
    override func received(_ p: Packet) { engine.log?("ping from \(device.name)\(p.string("message").map { ": \($0)" } ?? "")") }
}

// MARK: Battery

/// The phone's battery (in), and this Mac's own (out), read straight from macOS.
final class BatteryPlugin: NativePlugin {
    override class var id: String { "kdeconnect_battery" }
    override class var subpath: String? { "battery" }
    override class var interface: String { "battery" }
    override class var incoming: [String] { ["kdeconnect.battery"] }
    override class var outgoing: [String] { ["kdeconnect.battery"] }

    private var charge: Int32 = -1
    private var charging = false
    private var lastSent: (Int, Bool)?

    override func connected() {
        lastSent = nil
        sendMine()
        MacBatteryWatch.shared.add(self)
    }

    override func unloaded() { MacBatteryWatch.shared.remove(self) }

    override func received(_ p: Packet) {
        charge = Int32(p.int("currentCharge") ?? -1)
        charging = p.bool("isCharging") ?? false
        emit("refreshed", [.bool(charging), .int32(charge)])
    }

    override func properties(sub: String) -> [String: DBusValue] {
        ["charge": .int32(charge), "isCharging": .bool(charging)]
    }

    func sendMine() {
        guard let b = MacBatteryWatch.reading() else { return }
        guard lastSent.map({ $0 != (b.level, b.charging) }) ?? true else { return }
        lastSent = (b.level, b.charging)
        send(Packet("kdeconnect.battery", ["currentCharge": b.level, "isCharging": b.charging, "thresholdEvent": b.level <= 15 && !b.charging ? 1 : 0]))
    }
}

/// macOS's power-source notifications, for every battery plugin.
final class MacBatteryWatch: @unchecked Sendable {
    static let shared = MacBatteryWatch()
    private var plugins: [ObjectIdentifier: BatteryPlugin] = [:]
    private var source: CFRunLoopSource?

    static func reading() -> (level: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for s in list {
            guard let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (min(100, now * 100 / max), d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    func add(_ p: BatteryPlugin) {
        plugins[ObjectIdentifier(p)] = p
        guard source == nil else { return }
        DispatchQueue.main.async {
            self.source = IOPSNotificationCreateRunLoopSource({ _ in
                MacBatteryWatch.shared.changed()
            }, nil)?.takeRetainedValue()
            if let s = self.source { CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode) }
        }
    }

    func remove(_ p: BatteryPlugin) { plugins[ObjectIdentifier(p)] = nil }

    private func changed() {
        for p in plugins.values { p.engine.queue.async { p.sendMine() } }
    }
}

// MARK: Connectivity

final class ConnectivityPlugin: NativePlugin {
    override class var id: String { "kdeconnect_connectivity_report" }
    override class var subpath: String? { "connectivity_report" }
    override class var interface: String { "connectivity_report" }
    override class var incoming: [String] { ["kdeconnect.connectivity_report"] }

    private var networkType = ""
    private var strength: Int32 = -1

    override func received(_ p: Packet) {
        // One entry per SIM; the first is shown, as KDE did.
        let strengths = p.body["signalStrengths"] as? [String: [String: Any]] ?? [:]
        let first = strengths.keys.sorted().first.flatMap { strengths[$0] }
        networkType = first?["networkType"] as? String ?? ""
        strength = Int32((first?["signalStrength"] as? NSNumber)?.intValue ?? -1)
        emit("refreshed", [.string(networkType), .int32(strength)])
    }

    override func properties(sub: String) -> [String: DBusValue] {
        ["cellularNetworkType": .string(networkType), "cellularNetworkStrength": .int32(strength)]
    }
}

// MARK: Find my phone

final class FindMyPhonePlugin: NativePlugin {
    override class var id: String { "kdeconnect_findmyphone" }
    override class var subpath: String? { "findmyphone" }
    override class var interface: String { "findmyphone" }
    override class var outgoing: [String] { ["kdeconnect.findmyphone.request"] }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "ring" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        send(Packet("kdeconnect.findmyphone.request"))
        return []
    }
}

// MARK: Telephony

final class TelephonyPlugin: NativePlugin {
    override class var id: String { "kdeconnect_telephony" }
    override class var subpath: String? { "telephony" }
    override class var interface: String { "telephony" }
    override class var incoming: [String] { ["kdeconnect.telephony"] }
    override class var outgoing: [String] { ["kdeconnect.telephony.request_mute"] }

    override func received(_ p: Packet) {
        guard p.bool("isCancel") != true, let event = p.string("event") else { return }
        emit("callReceived", [.string(event), .string(p.string("phoneNumber") ?? ""), .string(p.string("contactName") ?? "")])
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "sendMutePacket" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        send(Packet("kdeconnect.telephony.request_mute"))
        return []
    }
}

// MARK: Notifications

/// The phone's notifications (and Janus's companion messages, which travel as notifications): each one an object at
/// `notifications/<publicId>`, posted / updated / removed by signal. Icons arrive as payloads and are kept by their
/// hash in the same cache folder KDE's engine used (live activities look them up there).
final class NotificationsPlugin: NativePlugin {
    override class var id: String { "kdeconnect_notifications" }
    override class var subpath: String? { "notifications" }
    override class var interface: String { "notifications" }
    override class var incoming: [String] { ["kdeconnect.notification"] }
    override class var outgoing: [String] { ["kdeconnect.notification.request", "kdeconnect.notification.reply", "kdeconnect.notification.action"] }

    struct Note {
        var internalId: String
        var props: [String: DBusValue]
    }

    private var notes: [String: Note] = [:]   // by public id

    /// Where icons are kept (`$TMPDIR/kdeconnect_<user>/<payloadHash>`, as before).
    static var iconFolder: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kdeconnect_\(NSUserName())", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func publicID(_ internalId: String) -> String {
        String(internalId.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "_" })
    }

    override func connected() { send(Packet("kdeconnect.notification.request", ["request": true])) }

    override func unloaded() {
        notes = [:]
        emit("allNotificationsRemoved", [])
    }

    override func received(_ p: Packet) {
        guard let internalId = p.string("id") else { return }
        let pid = Self.publicID(internalId)
        if p.bool("isCancel") == true {
            if notes.removeValue(forKey: pid) != nil { emit("notificationRemoved", [.string(pid)]) }
            return
        }
        var props: [String: DBusValue] = [
            "internalId": .string(internalId),
            "appName": .string(p.string("appName") ?? ""),
            "title": .string(p.string("title") ?? ""),
            "text": .string(p.string("text") ?? ""),
            "ticker": .string(p.string("ticker") ?? ""),
            "dismissable": .bool(p.bool("isClearable") ?? false),
            "replyId": .string(p.string("requestReplyId") ?? ""),
            "actions": .strings(p.strings("actions")),
            "silent": .bool(p.bool("silent") ?? false),
            "iconPath": .string(""),
            "hasIcon": .bool(false),
        ]
        let post = { [weak self] in
            guard let self else { return }
            let existed = self.notes[pid] != nil
            self.notes[pid] = Note(internalId: internalId, props: props)
            self.emit(existed ? "notificationUpdated" : "notificationPosted", [.string(pid)])
        }
        // An icon: kept by its hash (sent once, then only the hash); post when it's here.
        if let hash = p.string("payloadHash"), !hash.isEmpty {
            let file = Self.iconFolder.appendingPathComponent(hash)
            props["hasIcon"] = .bool(true)
            props["iconPath"] = .string(file.path)
            if FileManager.default.fileExists(atPath: file.path) || p.payloadSize == nil { post(); return }
            Task {
                try? await device.receivePayload(p, to: file)
                engine.queue.async { post() }
            }
            return
        }
        post()
    }

    override func properties(sub: String) -> [String: DBusValue] {
        let parts = sub.split(separator: "/")
        if parts.count == 2 { return notes[String(parts[1])]?.props ?? [:] }
        return [:]
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        let parts = (sub ?? "").split(separator: "/")
        if parts.count == 2, member == "dismiss", let n = notes[String(parts[1])] {
            send(Packet("kdeconnect.notification.request", ["cancel": n.internalId]))
            notes[String(parts[1])] = nil
            emit("notificationRemoved", [.string(String(parts[1]))])
            return []
        }
        switch member {
        case "activeNotifications":
            return [.strings(Array(notes.keys))]
        case "sendReply":
            send(Packet("kdeconnect.notification.reply", ["requestReplyId": args.first?.string ?? "", "message": args.dropFirst().first?.string ?? ""]))
            return []
        case "sendAction":
            let key = args.first?.string ?? ""
            send(Packet("kdeconnect.notification.action", ["key": notes[key]?.internalId ?? key, "action": args.dropFirst().first?.string ?? ""]))
            return []
        default:
            return try super.call(sub: sub, interface: interface, member: member, args)
        }
    }
}

// MARK: Share

/// Files, links and text both ways. Received files go to Downloads (removed again if the transfer fails), then the
/// app hears `shareReceived`; links open on the Mac.
final class SharePlugin: NativePlugin {
    override class var id: String { "kdeconnect_share" }
    override class var subpath: String? { "share" }
    override class var interface: String { "share" }
    override class var incoming: [String] { ["kdeconnect.share.request"] }
    override class var outgoing: [String] { ["kdeconnect.share.request", "kdeconnect.share.request.update"] }

    override func received(_ p: Packet) {
        if let name = p.string("filename"), p.payloadSize != nil {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            // Written under its final name (the app follows progress by the file the engine has open, as before).
            let target = Self.unique(downloads.appendingPathComponent((name as NSString).lastPathComponent))
            let part = target
            Task {
                do {
                    try await device.receivePayload(p, to: part)
                    if let ms = p.int64("lastModified") {
                        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(ms) / 1000)], ofItemAtPath: target.path)
                    }
                    engine.queue.async { self.emit("shareReceived", [.string(target.absoluteString)]) }
                } catch {
                    try? FileManager.default.removeItem(at: part)
                    engine.log?("receiving \(name) from \(self.device.name) failed: \(error)")
                }
            }
        } else if let url = p.string("url"), let u = URL(string: url) {
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
            emit("shareReceived", [.string(url)])
        } else if let text = p.string("text") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Shared text \(Int(Date().timeIntervalSince1970)).txt")
            try? text.write(to: file, atomically: true, encoding: .utf8)
            emit("shareReceived", [.string(file.absoluteString)])
        }
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        switch member {
        case "shareUrl": share([args.first?.string ?? ""])
        case "shareUrls": share(args.first?.strings ?? [])
        case "shareText": send(Packet("kdeconnect.share.request", ["text": args.first?.string ?? ""]))
        default: return try super.call(sub: sub, interface: interface, member: member, args)
        }
        return []
    }

    private func share(_ urls: [String]) {
        let parsed = urls.compactMap(URL.init(string:))
        let files = parsed.filter(\.isFileURL)
        for link in parsed where !link.isFileURL { send(Packet("kdeconnect.share.request", ["url": link.absoluteString])) }
        guard !files.isEmpty else { return }
        let sizes = files.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0 }
        let total = sizes.reduce(0, +)
        if files.count > 1 {
            send(Packet("kdeconnect.share.request.update", ["numberOfFiles": files.count, "totalPayloadSize": total]))
        }
        Task {
            for file in files {
                var p = Packet("kdeconnect.share.request", ["filename": file.lastPathComponent, "numberOfFiles": files.count, "totalPayloadSize": total])
                if let d = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date { p["lastModified"] = Int64(d.timeIntervalSince1970 * 1000) }
                do { try await device.sendWithPayload(p, file: file) }
                catch { engine.log?("sending \(file.lastPathComponent) to \(device.name) failed: \(error)") }
            }
        }
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) || FileManager.default.fileExists(atPath: candidate.path + ".part") {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}
