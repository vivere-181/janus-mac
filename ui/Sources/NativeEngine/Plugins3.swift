import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import JanusLink
import KDEConnectKit

// Native plugins, phase 3 (R40): the rest of what the app uses, with KDE's objects, properties and signals.

/// Numbers in packets come as numbers or strings depending on the sender.
private func num(_ v: Any?) -> Int64? {
    if let n = v as? NSNumber { return n.int64Value }
    if let s = v as? String { return Int64(s) }
    return nil
}

/// A per-plugin INI file in KDE's per-device folder (`<device>/<plugin>/config`).
private func pluginConfig(_ device: String, _ plugin: String) -> URL {
    LocalIdentity.folder.appendingPathComponent(device, isDirectory: true)
        .appendingPathComponent(plugin, isDirectory: true).appendingPathComponent("config")
}

// MARK: Clipboard

/// The clipboard both ways. Automatic sending follows the per-device `autoShare` setting the app writes; passwords
/// (pasteboards marked concealed/transient by password managers) are never sent; what came from the phone isn't
/// sent back.
final class ClipboardPlugin: NativePlugin {
    override class var id: String { "kdeconnect_clipboard" }
    override class var subpath: String? { "clipboard" }
    override class var interface: String { "clipboard" }
    override class var incoming: [String] { ["kdeconnect.clipboard", "kdeconnect.clipboard.connect", "kdeconnect.clipboard.file"] }
    override class var outgoing: [String] { ["kdeconnect.clipboard", "kdeconnect.clipboard.connect", "kdeconnect.clipboard.file"] }

    private var autoShare: Bool {
        let text = (try? String(contentsOf: pluginConfig(device.id, Self.id), encoding: .utf8)) ?? ""
        return !text.contains("autoShare=false")
    }

    override func connected() {
        emit("autoShareDisabledChanged", [.bool(!autoShare)])
        ClipboardWatch.shared.add(self)
        // What's on the Mac's clipboard, with when it was copied (the phone takes it only if it's newer than its own).
        if autoShare, let (text, time) = ClipboardWatch.shared.current() {
            send(Packet("kdeconnect.clipboard.connect", ["content": text, "timestamp": Int64(time.timeIntervalSince1970 * 1000)]))
        }
    }

    override func unloaded() { ClipboardWatch.shared.remove(self) }

    /// The Mac's clipboard changed (from the watcher, on the engine's queue).
    func localChanged(_ text: String) {
        guard autoShare else { return }
        send(Packet("kdeconnect.clipboard", ["content": text]))
    }

    override func received(_ p: Packet) {
        guard let text = p.string("content"), !text.isEmpty else { return }
        if p.type == "kdeconnect.clipboard.connect", let ts = p.int64("timestamp"),
           let (_, mine) = ClipboardWatch.shared.current(), Double(ts) / 1000 <= mine.timeIntervalSince1970 { return }
        ClipboardWatch.shared.set(text)
    }

    override func properties(sub: String) -> [String: DBusValue] { ["isAutoShareDisabled": .bool(!autoShare)] }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "sendClipboard" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        if let (text, _) = ClipboardWatch.shared.current() { send(Packet("kdeconnect.clipboard", ["content": text])) }
        return []
    }
}

/// Watches the Mac's pasteboard (its change count, twice a second) for every clipboard plugin.
final class ClipboardWatch: @unchecked Sendable {
    static let shared = ClipboardWatch()
    private var plugins: [ObjectIdentifier: ClipboardPlugin] = [:]
    private let lock = NSLock()
    private var timer: Timer?
    private var lastCount = -1
    private var lastText: String?
    private var lastTime = Date.distantPast
    private var fromPhone: String?

    func add(_ p: ClipboardPlugin) {
        lock.lock(); plugins[ObjectIdentifier(p)] = p; lock.unlock()
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            self.lastCount = NSPasteboard.general.changeCount
            self.lastText = NSPasteboard.general.string(forType: .string)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.poll() }
        }
    }

    func remove(_ p: ClipboardPlugin) { lock.lock(); plugins[ObjectIdentifier(p)] = nil; lock.unlock() }

    func current() -> (String, Date)? {
        lock.lock(); defer { lock.unlock() }
        return lastText.map { ($0, lastTime) }
    }

    func set(_ text: String) {
        DispatchQueue.main.async {
            self.lock.lock(); self.fromPhone = text; self.lock.unlock()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types ?? []
        // Password managers mark what they copy (nspasteboard.org); never send those.
        let secret = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard !secret, let text = pb.string(forType: .string), !text.isEmpty else { return }
        lock.lock()
        let echo = text == fromPhone
        fromPhone = nil
        lastText = text
        lastTime = Date()
        let targets = Array(plugins.values)
        lock.unlock()
        guard !echo else { return }
        for p in targets { p.engine.queue.async { p.localChanged(text) } }
    }
}

// MARK: Now playing (the phone's media)

final class MprisRemotePlugin: NativePlugin {
    override class var id: String { "kdeconnect_mprisremote" }
    override class var subpath: String? { "mprisremote" }
    override class var interface: String { "mprisremote" }
    override class var incoming: [String] { ["kdeconnect.mpris"] }
    override class var outgoing: [String] { ["kdeconnect.mpris.request"] }

    private var players: [String] = []
    private var player = ""
    private var title = "", artist = "", album = ""
    private var isPlaying = false, canSeek = false
    private var position: Int64 = 0, length: Int64 = 0
    private var volume: Int64 = 0
    private var artURL = "", localArt = ""
    private var supportsArtPayload = false

    override func connected() { send(Packet("kdeconnect.mpris.request", ["requestPlayerList": true])) }

    override func received(_ p: Packet) {
        if let list = p.body["playerList"] as? [String] {
            players = list
            supportsArtPayload = p.bool("supportAlbumArtPayload") ?? false
            if !players.contains(player) { player = players.first ?? ""; requestNowPlaying() }
            engine.log?("media: \(players.count) player(s) on \(device.name)")
            changed(); return
        }
        guard let who = p.string("player"), who == player else { return }
        if p.bool("transferringAlbumArt") == true, p.payloadSize != nil, let url = p.string("albumArtUrl") {
            let file = NotificationsPlugin.iconFolder.appendingPathComponent("art-" + String(url.hashValue & 0x7FFF_FFFF))
            Task {
                try? await device.receivePayload(p, to: file)
                engine.queue.async { if url == self.artURL { self.localArt = file.absoluteString; self.changed() } }
            }
            return
        }
        if let v = p.string("title") { title = v }
        if let v = p.string("artist") { artist = v }
        if let v = p.string("album") { album = v }
        if let v = p.bool("isPlaying") { isPlaying = v }
        if let v = p.bool("canSeek") { canSeek = v }
        if let v = num(p.body["pos"]) { position = v }
        if let v = num(p.body["length"]) { length = v }
        if let v = num(p.body["volume"]) { volume = v }
        if let url = p.string("albumArtUrl"), url != artURL {
            artURL = url
            localArt = ""
            if supportsArtPayload, !url.isEmpty { send(Packet("kdeconnect.mpris.request", ["player": player, "albumArtUrl": url])) }
        }
        changed()
    }

    private func requestNowPlaying() {
        guard !player.isEmpty else { return }
        send(Packet("kdeconnect.mpris.request", ["player": player, "requestNowPlaying": true, "requestVolume": true]))
    }

    private func changed() { emit("propertiesChanged", []) }

    override func properties(sub: String) -> [String: DBusValue] {
        ["playerList": .strings(players), "player": .string(player), "title": .string(title), "artist": .string(artist),
         "album": .string(album), "localAlbumArtUrl": .string(localArt), "isPlaying": .bool(isPlaying),
         "length": .int32(Int32(clamping: length)), "position": .int32(Int32(clamping: position)),
         "volume": .int32(Int32(clamping: volume)), "canSeek": .bool(canSeek)]
    }

    override func setProperty(_ name: String, _ value: DBusValue) throws {
        switch name {
        case "player":
            player = value.string ?? player
            title = ""; artist = ""; album = ""; artURL = ""; localArt = ""
            requestNowPlaying(); changed()
        case "volume":
            volume = Int64(value.int ?? 0)
            send(Packet("kdeconnect.mpris.request", ["player": player, "setVolume": volume]))
        case "position":
            position = Int64(value.int ?? 0)
            send(Packet("kdeconnect.mpris.request", ["player": player, "SetPosition": position]))
        default: try super.setProperty(name, value)
        }
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "sendAction" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        send(Packet("kdeconnect.mpris.request", ["player": player, "action": args.first?.string ?? ""]))
        if args.first?.string == "PlayPause" { isPlaying.toggle() }
        return []
    }
}

// MARK: Mac actions (commands the phone can run on the Mac)

/// The command list is the one the app keeps in KDE's run-command config (`commands="@ByteArray(<json>)"`); a request
/// with a key runs that command.
final class RunCommandPlugin: NativePlugin {
    override class var id: String { "kdeconnect_runcommand" }
    override class var incoming: [String] { ["kdeconnect.runcommand.request"] }
    override class var outgoing: [String] { ["kdeconnect.runcommand"] }

    private var commands: [String: [String: String]] {
        guard let text = try? String(contentsOf: pluginConfig(device.id, Self.id), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("commands=") }) else { return [:] }
        var value = String(line.dropFirst("commands=".count))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        if value.hasPrefix("@ByteArray("), value.hasSuffix(")") { value = String(value.dropFirst(11).dropLast()) }
        value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: [String: String]] ?? [:]
    }

    override func connected() { sendList() }

    private func sendList() {
        let json = (try? JSONSerialization.data(withJSONObject: commands, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        send(Packet("kdeconnect.runcommand", ["commandList": json, "canAddCommand": false]))
        engine.log?("mac actions: \(commands.count) sent to \(device.name)")
    }

    override func received(_ p: Packet) {
        if p.bool("requestCommandList") == true { sendList() }
        if let key = p.string("key"), let command = commands[key]?["command"] {
            engine.log?("mac action \(key) from \(device.name)")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", command]
            try? task.run()
        }
    }
}

// MARK: SMS

/// Conversations, on the device's own path (`org.kde.kdeconnect.device.conversations`), as KDE's sms plugin did.
final class SmsPlugin: NativePlugin {
    override class var id: String { "kdeconnect_sms" }
    override class var interface: String { "conversations" }
    override class var incoming: [String] { ["kdeconnect.sms.messages", "kdeconnect.sms.attachment_file"] }
    override class var outgoing: [String] { ["kdeconnect.sms.request", "kdeconnect.sms.request_conversation", "kdeconnect.sms.request_conversations", "kdeconnect.sms.request_attachment"] }
    override class var deviceLevelMembers: Set<String> {
        ["activeConversations", "requestAllConversationThreads", "requestConversation", "replyToConversation", "sendWithoutConversation"]
    }

    private struct Message {
        var event: Int32, body: String, addresses: [String], date: Int64, type: Int32, read: Int32
        var thread: Int64, uid: Int32, subID: Int64
        var attachments: [(Int64, String, String, String)]

        var value: DBusValue {
            .structure([.int32(event), .string(body), .array(element: "(s)", addresses.map { .structure([.string($0)]) }),
                        .int64(date), .int32(type), .int32(read), .int64(thread), .int32(uid), .int64(subID),
                        .array(element: "(xsss)", attachments.map { .structure([.int64($0.0), .string($0.1), .string($0.2), .string($0.3)]) })])
        }
    }

    private var threads: [Int64: [Int32: Message]] = [:]
    private var awaiting: Set<Int64> = []

    override func received(_ p: Packet) {
        guard p.type == "kdeconnect.sms.messages" else { return }
        var touched: Set<Int64> = []
        for m in p.body["messages"] as? [[String: Any]] ?? [] {
            guard let thread = num(m["thread_id"]), let uid = num(m["_id"]) else { continue }
            let addresses = (m["addresses"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
            let atts = (m["attachments"] as? [[String: Any]] ?? []).map {
                (num($0["part_id"]) ?? 0, $0["mime_type"] as? String ?? "", $0["encoded_thumbnail"] as? String ?? "", $0["unique_identifier"] as? String ?? "")
            }
            let read: Int32 = (m["read"] as? Bool).map { $0 ? 1 : 0 } ?? Int32(num(m["read"]) ?? 1)
            let msg = Message(event: Int32(num(m["event"]) ?? 1), body: m["body"] as? String ?? "", addresses: addresses,
                              date: num(m["date"]) ?? 0, type: Int32(num(m["type"]) ?? 1), read: read, thread: thread,
                              uid: Int32(truncatingIfNeeded: uid), subID: num(m["sub_id"]) ?? -1, attachments: atts)
            let isNewThread = threads[thread] == nil
            threads[thread, default: [:]][msg.uid] = msg
            emit(isNewThread ? "conversationCreated" : "conversationUpdated", [.variant(msg.value)], sub: nil)
            touched.insert(thread)
        }
        if (p.body["messages"] as? [Any])?.count ?? 0 > 1 { engine.log?("sms: \((p.body["messages"] as? [Any])?.count ?? 0) messages loaded") }
        for t in touched where awaiting.contains(t) {
            awaiting.remove(t)
            emit("conversationLoaded", [.int64(t), .uint64(UInt64(threads[t]?.count ?? 0))], sub: nil)
        }
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        switch member {
        case "activeConversations":
            let latest = threads.values.compactMap { $0.values.max { $0.date < $1.date } }
            return [.array(element: "v", latest.map { .variant($0.value) })]
        case "requestAllConversationThreads":
            send(Packet("kdeconnect.sms.request_conversations"))
        case "requestConversation":
            guard let thread = args.first?.int else { break }
            let start = args.dropFirst().first?.int ?? 0, end = args.dropFirst(2).first?.int ?? 50
            var p = Packet("kdeconnect.sms.request_conversation", ["threadID": Int64(thread), "numberToRequest": max(1, end - start)])
            if start > 0, let oldest = threads[Int64(thread)]?.values.map(\.date).min() { p["rangeStartTimestamp"] = oldest }
            awaiting.insert(Int64(thread))
            send(p)
        case "replyToConversation":
            guard let thread = args.first?.int, let latest = threads[Int64(thread)]?.values.max(by: { $0.date < $1.date }) else { break }
            sendSMS(to: latest.addresses, text: args.dropFirst().first?.string ?? "", subID: latest.subID)
        case "sendWithoutConversation":
            let addresses = args.first?.array?.compactMap { $0.unwrapped.array?.first?.string ?? $0.string } ?? []
            sendSMS(to: addresses, text: args.dropFirst().first?.string ?? "", subID: -1)
        default:
            return try super.call(sub: sub, interface: interface, member: member, args)
        }
        return []
    }

    private func sendSMS(to addresses: [String], text: String, subID: Int64) {
        var p = Packet("kdeconnect.sms.request", ["version": 2, "addresses": addresses.map { ["address": $0] }, "messageBody": text])
        if subID >= 0 { p["subID"] = subID }
        send(p)
    }
}

// MARK: Contacts

/// The phone's contacts as vCards in `~/Library/Application Support/Android/Contacts/<device>/<uid>.vcf`,
/// where the app (and KDE's engine before) keeps them; only new or changed ones are fetched.
final class ContactsPlugin: NativePlugin {
    override class var id: String { "kdeconnect_contacts" }
    override class var subpath: String? { "contacts" }
    override class var interface: String { "contacts" }
    override class var incoming: [String] { ["kdeconnect.contacts.response_uids_timestamps", "kdeconnect.contacts.response_vcards"] }
    override class var outgoing: [String] { ["kdeconnect.contacts.request_all_uids_timestamps", "kdeconnect.contacts.request_vcards_by_uid"] }

    private var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Contacts/\(device.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The phone's timestamps from its last list, written into each vCard fetched after it.
    private var timestamps: [String: Int64] = [:]

    private func storedTimestamp(_ uid: String) -> Int64? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("\(uid).vcf"), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("X-KDECONNECT-TIMESTAMP:") }) else { return nil }
        return Int64(line.dropFirst("X-KDECONNECT-TIMESTAMP:".count))
    }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "synchronizeRemoteWithLocal" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        send(Packet("kdeconnect.contacts.request_all_uids_timestamps"))
        return []
    }

    override func received(_ p: Packet) {
        let uids = p.strings("uids")
        if p.type == "kdeconnect.contacts.response_uids_timestamps" {
            // Forget contacts the phone no longer has; fetch the new and changed ones.
            let keep = Set(uids.map { "\($0).vcf" })
            for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".vcf") && !keep.contains(f) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
            }
            for uid in uids { timestamps[uid] = num(p.body[uid]) }
            let wanted = uids.filter { storedTimestamp($0) != num(p.body[$0]) }
            engine.log?("contacts: \(uids.count) on the phone, \(wanted.count) to fetch")
            if wanted.isEmpty { emit("localCacheSynchronized", [.strings(uids)]) }
            else { send(Packet("kdeconnect.contacts.request_vcards_by_uid", ["uids": wanted])) }
        } else {
            for uid in uids {
                guard var vcard = p.string(uid) else { continue }
                let marks = "X-KDECONNECT-ID-DEV-\(device.id):\(uid)\nX-KDECONNECT-TIMESTAMP:\(timestamps[uid] ?? 0)\n"
                if let r = vcard.range(of: "END:VCARD", options: .backwards) { vcard.insert(contentsOf: marks, at: r.lowerBound) }
                try? vcard.write(to: folder.appendingPathComponent("\(uid).vcf"), atomically: true, encoding: .utf8)
            }
            engine.log?("contacts: \(uids.count) vCard(s) saved")
            emit("localCacheSynchronized", [.strings(uids)])
        }
    }
}

// MARK: Typing and pointing on the phone

final class RemoteKeyboardPlugin: NativePlugin {
    override class var id: String { "kdeconnect_remotekeyboard" }
    override class var subpath: String? { "remotekeyboard" }
    override class var interface: String { "remotekeyboard" }
    override class var incoming: [String] { ["kdeconnect.mousepad.echo", "kdeconnect.mousepad.keyboardstate"] }
    override class var outgoing: [String] { ["kdeconnect.mousepad.request"] }

    private var remoteState = false

    override func received(_ p: Packet) {
        if p.type == "kdeconnect.mousepad.keyboardstate" {
            remoteState = p.bool("state") ?? false
            emit("remoteStateChanged", [.bool(remoteState)])
        }
    }

    override func properties(sub: String) -> [String: DBusValue] { ["remoteState": .bool(remoteState)] }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        guard member == "sendKeyPress" else { return try super.call(sub: sub, interface: interface, member: member, args) }
        var p = Packet("kdeconnect.mousepad.request")
        if let key = args.first?.string, !key.isEmpty { p["key"] = key }
        if let special = args.dropFirst().first?.int, special != 0 { p["specialKey"] = special }
        p["shift"] = args.dropFirst(2).first?.bool ?? false
        p["ctrl"] = args.dropFirst(3).first?.bool ?? false
        p["alt"] = args.dropFirst(4).first?.bool ?? false
        p["sendAck"] = args.dropFirst(5).first?.bool ?? false
        send(p)
        return []
    }
}

final class RemoteControlPlugin: NativePlugin {
    override class var id: String { "kdeconnect_remotecontrol" }
    override class var subpath: String? { "remotecontrol" }
    override class var interface: String { "remotecontrol" }
    override class var outgoing: [String] { ["kdeconnect.mousepad.request"] }

    override func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        switch member {
        case "moveCursor":
            let xy = args.first?.array ?? []
            send(Packet("kdeconnect.mousepad.request", ["dx": xy.first?.int ?? 0, "dy": xy.dropFirst().first?.int ?? 0]))
        case "sendCommand":
            var p = Packet("kdeconnect.mousepad.request")
            for (k, v) in args.first?.dictionary ?? [:] { p[k] = v.bool ?? v.int ?? v.string ?? true }
            send(p)
        default: return try super.call(sub: sub, interface: interface, member: member, args)
        }
        return []
    }
}

// MARK: The phone as the Mac's mouse and keyboard

/// Pointer, clicks, scrolling and typing from the phone, as macOS input events (needs Accessibility permission).
final class MousepadPlugin: NativePlugin {
    override class var id: String { "kdeconnect_mousepad" }
    override class var incoming: [String] { ["kdeconnect.mousepad.request"] }
    override class var outgoing: [String] { ["kdeconnect.mousepad.keyboardstate"] }

    override func connected() { send(Packet("kdeconnect.mousepad.keyboardstate", ["state": true])) }

    override func received(_ p: Packet) {
        DispatchQueue.main.async { MainActor.assumeIsolated { MacInput.apply(p) } }
    }
}

enum MacInput {
    private static var holding = false
    private static var askedPermission = false

    /// macOS key codes for KDE Connect's special keys.
    private static let specialKeys: [Int: CGKeyCode] = [
        1: 51, 2: 48, 4: 123, 5: 126, 6: 124, 7: 125, 8: 116, 9: 121, 10: 115, 11: 119, 12: 36, 13: 117, 14: 53,
        21: 122, 22: 120, 23: 99, 24: 118, 25: 96, 26: 97, 27: 98, 28: 100, 29: 101, 30: 109, 31: 103, 32: 111,
    ]

    @MainActor static func apply(_ p: Packet) {
        guard AXIsProcessTrusted() else {
            if !askedPermission {
                askedPermission = true
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let location = CGEvent(source: nil)?.location ?? .zero
        var flags: CGEventFlags = []
        if p.bool("shift") == true { flags.insert(.maskShift) }
        if p.bool("ctrl") == true { flags.insert(.maskControl) }
        if p.bool("alt") == true { flags.insert(.maskAlternate) }
        if p.bool("super") == true { flags.insert(.maskCommand) }

        func click(_ down: CGEventType, _ up: CGEventType, _ button: CGMouseButton, count: Int = 1) {
            for n in 1...count {
                for t in [down, up] {
                    let e = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: location, mouseButton: button)
                    e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                    e?.post(tap: .cghidEventTap)
                }
            }
        }

        if p.bool("singleclick") == true { click(.leftMouseDown, .leftMouseUp, .left) }
        else if p.bool("doubleclick") == true { click(.leftMouseDown, .leftMouseUp, .left, count: 2) }
        else if p.bool("rightclick") == true { click(.rightMouseDown, .rightMouseUp, .right) }
        else if p.bool("middleclick") == true { click(.otherMouseDown, .otherMouseUp, .center) }
        else if p.bool("singlehold") == true {
            holding = true
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else if p.bool("singlerelease") == true {
            holding = false
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else if let dx = (p.body["dx"] as? NSNumber)?.doubleValue, let dy = (p.body["dy"] as? NSNumber)?.doubleValue {
            if p.bool("scroll") == true {
                CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)?.post(tap: .cghidEventTap)
            } else {
                let to = CGPoint(x: location.x + dx, y: location.y + dy)
                CGEvent(mouseEventSource: source, mouseType: holding ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        } else if let special = p.int("specialKey"), let code = specialKeys[special] {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
            }
        } else if let key = p.string("key"), !key.isEmpty {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                let units = Array(key.utf16)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: The phone controlling the Mac's volume

/// The Mac's sound outputs for the phone's volume controls: list them, set volume and mute, choose the default.
final class SystemVolumePlugin: NativePlugin {
    override class var id: String { "kdeconnect_systemvolume" }
    override class var incoming: [String] { ["kdeconnect.systemvolume.request"] }
    override class var outgoing: [String] { ["kdeconnect.systemvolume"] }

    override func received(_ p: Packet) {
        if p.bool("requestSinks") == true { sendSinks(); return }
        guard let name = p.string("name"), let dev = MacAudio.device(uid: name) else { return }
        if let v = p.int("volume") { MacAudio.setVolume(dev, Float(v) / 100) }
        if let m = p.bool("muted") { MacAudio.setMuted(dev, m) }
        if p.bool("enabled") == true { MacAudio.setDefault(dev) }
        sendSinks()
    }

    override func connected() { sendSinks() }

    private func sendSinks() {
        let list: [[String: Any]] = MacAudio.outputs().map { d in
            ["name": MacAudio.uid(d), "description": MacAudio.name(d), "muted": MacAudio.isMuted(d),
             "volume": Int((MacAudio.volume(d) * 100).rounded()), "maxVolume": 100, "enabled": d == MacAudio.defaultOutput()]
        }
        send(Packet("kdeconnect.systemvolume", ["sinkList": list]))
        engine.log?("volume: \(list.count) output(s) sent to \(device.name)")
    }
}

enum MacAudio {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func outputs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.filter { id in
            var s = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var n: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n)
            return n > 0
        }
    }

    static func defaultOutput() -> AudioDeviceID {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ id: AudioDeviceID) {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var v = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    static func uid(_ id: AudioDeviceID) -> String { string(id, kAudioDevicePropertyDeviceUID) }
    static func name(_ id: AudioDeviceID) -> String { string(id, kAudioObjectPropertyName) }
    static func device(uid: String) -> AudioDeviceID? { outputs().first { self.uid($0) == uid } }

    static func volume(_ id: AudioDeviceID) -> Float {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var v = max(0, min(1, value))
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v != 0
    }

    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}
