import AppKit
import KDEConnectKit

/// Actions the phone can trigger on this Mac. The engine's run-command feature executes
/// `open -g "janus://action/<id>"`, and this app does the actual work.
@MainActor
enum MacActions {
    struct Action { let id: String; let name: String }

    /// Published to the phone in this order. (Display Off was dropped: Lock covers it.)
    static let all: [Action] = [
        Action(id: "lock", name: "Lock Mac"),
        Action(id: "sleep", name: "Sleep Mac"),
        Action(id: "mute", name: "Mute Mac"),
        Action(id: "screenshot", name: "Screenshot to Phone"),
        Action(id: "findmac", name: "Find My Mac"),
    ]

    static var enabled: Bool { UserDefaults.standard.object(forKey: "macActions.enabled") as? Bool ?? true }

    /// Connected phones known to run our app (they understand `ge.connect.` commands).
    static var ourPhones: [Device] {
        AppModel.shared.connectedDevices.filter { UserDefaults.standard.bool(forKey: "reportsStatus.\($0.id)") && DeviceTrust.isMine($0) }
    }

    /// The phone that asked: each phone's command list carries its own device id. Older lists without it
    /// fall back to the first phone running our app.
    private static var requester: Device?

    /// Tells the phone that asked how an action went: `ge.connect.macaction:<id>:ok` or `…:failed:<reason>`.
    private static func reply(_ id: String, _ error: String? = nil) {
        let targets = requester.map { d in ourPhones.filter { $0.id == d.id } } ?? ourPhones
        for d in targets { d.command("macaction:\(id):" + (error.map { "failed:" + $0 } ?? "ok")) }
    }

    static func perform(_ id: String, deviceID: String? = nil) {
        let devices = AppModel.shared.connectedDevices
        requester = devices.first { $0.id == deviceID } ?? ourPhones.first ?? devices.first
        AppModel.shared.log(.info, "\(requester?.name ?? "Phone") asked this Mac to: \(all.first { $0.id == id }?.name ?? id)")
        let phone = requester
        let from = phone.map { "From \($0.name)" }
        switch id {
        case "lock":
            reply(id)
            lockScreen()
        case "displaysleep":   // older phone builds may still show it
            reply(id)
            run("/usr/bin/pmset", ["displaysleepnow"])
        case "sleep":
            // Answer first: the connection drops the moment the Mac sleeps.
            reply(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run("/usr/bin/pmset", ["sleepnow"]) }
        case "mute":
            if let muted = AudioOutput.toggleMute() {
                reply(id)
                MacPopup.shared.show(.init(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                           tint: muted ? .gray : .blue,
                                           title: muted ? "Mac muted" : "Mac unmuted", subtitle: from))
            } else {
                reply(id, "\(AudioOutput.deviceName ?? "This speaker") has no volume control")
                MacPopup.shared.show(.init(symbol: "speaker.slash.fill", tint: .gray,
                                           title: "Can't mute this speaker",
                                           subtitle: "\(AudioOutput.deviceName ?? "The current output") has no volume control."))
            }
            MacState.changed()
        case "screenshot": screenshotToPhone(phone)
        case "findmac":
            reply(id)
            FindMac.toggle(from: phone)
        default:
            reply(id, "Unknown action")
        }
    }

    /// Locks immediately (same as Control-Command-Q), via the system login framework.
    private static func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])   // locks too when "require password immediately" is on
        }
    }

    private static func screenshotToPhone(_ phone: Device?) {
        guard let device = phone else { reply("screenshot", "No phone connected"); return }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Outgoing/Mac Screenshot \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Needs Screen Recording permission for Android (macOS asks the first time).
        run("/usr/sbin/screencapture", ["-x", "-t", "png", url.path]) { ok in
            if ok, FileManager.default.fileExists(atPath: url.path) {
                device.share([url])
                reply("screenshot")
                Sounds.play(Sounds.alert)
                MacPopup.shared.show(.init(symbol: "camera.viewfinder", tint: .green,
                                           title: "Screenshot sent", subtitle: "To \(device.name)"))
            } else {
                reply("screenshot", "Allow Screen Recording for Janus on the Mac")
                MacPopup.shared.show(.init(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                           title: "Couldn't take a screenshot",
                                           subtitle: "Allow Screen Recording for Janus in System Settings.",
                                           button: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                })
            }
        }
    }

    private static func run(_ path: String, _ args: [String], completion: (@MainActor (Bool) -> Void)? = nil) {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil
            p.waitUntilExit()
            let success = ok && p.terminationStatus == 0
            await MainActor.run { completion?(success) }
        }
    }

    // MARK: Publishing to the phone (engine run-command config)

    /// Writes our actions into the engine's run-command list for every paired phone (keeping any
    /// commands the owner added), then reloads the plugin so the phone sees the new list.
    static func publish() {
        for device in AppModel.shared.pairedDevices where device.supportedPlugins.contains("kdeconnect_runcommand") {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/kdeconnect/\(device.id)/kdeconnect_runcommand", isDirectory: true)
            let file = dir.appendingPathComponent("config")
            var commands = readCommands(file)
            commands = commands.filter { !$0.key.hasPrefix("ge-") }
            if enabled, DeviceTrust.isMine(device) {
                for a in all {
                    commands["ge-" + a.id] = ["name": a.name,
                                              "command": "open -g \"janus://action/\(a.id)?device=\(device.id)\""]
                }
            }
            guard let json = try? JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: json, encoding: .utf8) else { continue }
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // Quoted: QSettings would otherwise split the value at the JSON's commas.
            let ini = "[General]\ncommands=\"@ByteArray(\(escapeForQSettings(text)))\"\n"
            guard current != ini else { continue }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? ini.write(to: file, atomically: true, encoding: .utf8)
            // Reload the plugin so it re-reads its config and re-sends the list to the phone.
            Task {
                try? await device.call(nil, "", "setPluginEnabled", [.string("kdeconnect_runcommand"), .bool(false)])
                try? await Task.sleep(for: .milliseconds(300))
                try? await device.call(nil, "", "setPluginEnabled", [.string("kdeconnect_runcommand"), .bool(true)])
            }
        }
    }

    /// Existing `commands` JSON from the engine's QSettings-style file.
    private static func readCommands(_ file: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("commands=") }) else { return [:] }
        var value = String(line.dropFirst("commands=".count))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        if value.hasPrefix("@ByteArray("), value.hasSuffix(")") { value = String(value.dropFirst(11).dropLast()) }
        value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: [String: String]] ?? [:]
    }

    /// QSettings INI escaping for a @ByteArray value.
    private static func escapeForQSettings(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Links handled by the app: `janus://action/<id>` (from the phone) and `tel:` (click to call).
@MainActor
enum URLRouter {
    static func handle(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "janus", "androidconnect":   // (androidconnect: commands published before the rename)
            if url.host() == "action" {
                let device = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "device" }?.value
                MacActions.perform(url.lastPathComponent, deviceID: device)
            }
            if url.host() == "share" { shareFromExtension(url) }
        case "tel", "telprompt", "callto":
            let number = (url.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "")
                .removingPercentEncoding ?? ""
            let model = AppModel.shared
            // Calls are placed by our phone app (the dialer opens prefilled), so only phones running it can.
            let canCall = { (d: Device) in d.isReachable && d.has("telephony") && d.supports("dial") }
            guard let device = model.selectedDevice.flatMap({ canCall($0) ? $0 : nil }) ?? model.connectedDevices.first(where: canCall) else {
                AppModel.shared.log(.warning, "Can't call \(number): no connected phone runs the companion app")
                MacPopup.shared.show(.init(symbol: "phone.down", tint: .gray, title: "Can't call from this Mac",
                                           subtitle: model.connectedDevices.isEmpty ? "Your phone isn't connected."
                                               : "Calling needs the companion app on the phone."))
                return
            }
            device.dial(number)
            Notifier.shared.calling(number, device: device)
        default: break
        }
    }

    /// From the Share menu extension: files it copied into Outgoing, and links or text.
    private static func shareFromExtension(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let outgoing = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Outgoing").standardizedFileURL.path
        // Only files the extension put in our own folder; nothing else is read from a URL.
        let files = q.filter { $0.name == "file" }.compactMap(\.value).map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.path.hasPrefix(outgoing + "/") && FileManager.default.fileExists(atPath: $0.path) }
        let texts = q.filter { $0.name == "text" }.compactMap(\.value).filter { !$0.isEmpty }
        let model = AppModel.shared
        guard let device = (model.selectedDevice?.isReachable == true ? model.selectedDevice : nil)
                ?? model.connectedDevices.first(where: DeviceTrust.isMine) ?? model.connectedDevices.first else {
            MacPopup.shared.show(.init(symbol: "iphone.slash", tint: .gray, title: "Phone not connected",
                                       subtitle: "Nothing was sent. Try again when your phone is connected."))
            return
        }
        if !files.isEmpty { device.share(files) }
        texts.forEach(device.shareText)
        let n = files.count + texts.count
        guard n > 0 else { return }
        let what = n == 1 ? (files.first?.lastPathComponent ?? (texts[0].hasPrefix("http") ? "Link" : "Text")) : "\(n) items"
        MacPopup.shared.show(.init(symbol: "paperplane.fill", tint: .blue, title: "Sending \(what)", subtitle: "To \(device.name)"))
    }

    /// The share extension shows "Sending to <phone>"; it can only read our Outgoing folder.
    private static var publishedName: String?
    static func publishPhoneName(_ name: String?) {
        guard name != publishedName else { return }
        publishedName = name
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Android/Outgoing")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (name ?? "").write(to: dir.appendingPathComponent(".phone-name"), atomically: true, encoding: .utf8)
    }

    static var isDefaultForPhoneLinks: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "tel:123")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefaultForPhoneLinks() async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "tel")
    }
}

/// What happens to a screenshot that arrives from the phone.
@MainActor
enum ScreenshotHandler {
    static var copyToClipboard: Bool { UserDefaults.standard.object(forKey: "screenshots.copy") as? Bool ?? true }
    static var saveToDesktop: Bool { UserDefaults.standard.bool(forKey: "screenshots.desktop") }

    static func handle(_ url: URL) -> (note: String, url: URL?) {
        var fileURL = url
        var moved: URL?
        if saveToDesktop {
            let dest = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { fileURL = dest; moved = dest }
        }
        if copyToClipboard, let image = NSImage(contentsOf: fileURL) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image, fileURL as NSURL])
        }
        let parts = ["Screenshot", copyToClipboard ? "copied to clipboard" : nil, moved != nil ? "saved to Desktop" : nil]
        return (parts.compactMap { $0 }.joined(separator: " · "), moved)
    }
}
