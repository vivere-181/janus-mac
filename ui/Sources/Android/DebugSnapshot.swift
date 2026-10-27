import AppKit
import SwiftUI
import WidgetFeed
import UserNotifications

/// Developer hook: renders the app's own windows to PNGs in build.noindex/snapshots (next to the built app) so the
/// UI can be reviewed without screen-recording permission. Triggered by a distributed notification:
///   "local.android-ui.snapshot" with object = pane name, "panel", or "settings".
@MainActor
enum DebugSnapshot {
    /// Next to the built app (build.noindex/snapshots); an installed copy uses ~/Library/Caches/Janus/snapshots.
    static let dir: URL = {
        let besideApp = Bundle.main.bundleURL.deletingLastPathComponent()
        let d = besideApp.lastPathComponent == "build.noindex" ? besideApp.appendingPathComponent("snapshots")
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Janus/snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func install(model: AppModel) {
        DistributedNotificationCenter.default().addObserver(forName: .init("local.android-ui.snapshot"), object: nil, queue: .main) { note in
            let what = note.object as? String ?? "overview"
            MainActor.assumeIsolated { take(what, model: model) }
        }
    }

    static func take(_ what: String, model: AppModel) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dark = what.hasSuffix("-dark"), light = what.hasSuffix("-light")
        let name = dark ? String(what.dropLast(5)) : light ? String(what.dropLast(6)) : what
        NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : light ? NSAppearance(named: .aqua) : nil
        if name == "reconnect" { model.reconnect(); return }
        if name == "wifiadbtest" {
            Task {
                var log = ""
                let connect = await AdbServiceFinder.find(type: AdbServiceFinder.connect, timeout: 3)
                log += "connect services: \(connect)\n"
                let pairing = await AdbServiceFinder.find(type: AdbServiceFinder.pairing, timeout: 2)
                log += "pairing services: \(pairing)\n"
                log += "start-server: \(await ADB.wifi.run(["start-server"], timeout: 15).output)\n"
                if let s = connect.first {
                    let relay = MirrorRelay(host: s.host, port: s.port)
                    do {
                        let local = try await relay.start()
                        log += "relay 127.0.0.1:\(local) → \(s.host):\(s.port)\n"
                        log += "connect: \(await ADB.wifi.run(["connect", "127.0.0.1:\(local)"], timeout: 12).output)\n"
                        log += "devices: \(await ADB.wifi.devices())\n"
                        log += "relay outbound: \(relay.lastOutboundState)\n"
                    } catch { log += "relay failed: \(error)\n" }
                    relay.stop()
                }
                try? log.write(to: dir.appendingPathComponent("wifiadb.txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        if name == "restart" { Task { await model.restartEngine() }; return }
        if name == "probe" { probe(model: model); return }
        if name == "notifytest" {
            UNUserNotificationCenter.current().getNotificationSettings { st in
                let auth = st.authorizationStatus.rawValue, alert = st.alertSetting.rawValue
                let c = UNMutableNotificationContent(); c.title = "Android"; c.body = "Notifications are working."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: c, trigger: nil)) { err in
                    try? "authorization=\(auth) (2=authorized) alert=\(alert) postError=\(String(describing: err))".write(to: DebugSnapshot.dir.appendingPathComponent("notify.txt"), atomically: true, encoding: .utf8)
                }
            }
            return
        }
        if name == "addsheet" { render(AddDeviceSheet().environment(model), size: nil, file: what); return }
        if name == "renamesheet", let d = model.selectedDevice { render(RenameDeviceSheet(device: d).environment(model), size: nil, file: what); return }
        if name.hasPrefix("nick:"), let d = model.selectedDevice { d.rename(String(name.dropFirst(5))); return }
        if name.hasPrefix("addr:") { _ = model.addAddress(String(name.dropFirst(5))); return }
        if name == "addrclear" { model.setCustomAddresses([]); return }
        if name == "nickreset", let d = model.selectedDevice { d.rename(nil); return }
        if name == "seedtransfers" {
            let d = model.selectedDevice
            let id = d?.id ?? "", dn = d?.name ?? "Phone"
            let img = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ge-connect-test.png")
            TransferStore.shared.injectSamples([
                Transfer(direction: .received, kind: .file, deviceID: id, deviceName: dn, url: URL(fileURLWithPath: "/tmp/Holiday video.mp4"),
                         name: "Holiday video.mp4", size: nil, bytesDone: 38_400_000, speed: 6_100_000),
                Transfer(direction: .sent, kind: .file, deviceID: id, deviceName: dn, url: URL(fileURLWithPath: "/tmp/Presentation.pdf"),
                         name: "Presentation.pdf", size: 12_000_000, bytesDone: 4_300_000, speed: 4_100_000),
                Transfer(direction: .received, kind: .file, deviceID: id, deviceName: dn, url: img, name: "ge-connect-test.png",
                         size: 7053, bytesDone: 7053, state: .done, date: Date().addingTimeInterval(-300)),
                Transfer(direction: .sent, kind: .link, deviceID: id, deviceName: dn, url: URL(string: "https://www.apple.com/macos"),
                         name: "www.apple.com", state: .done, date: Date().addingTimeInterval(-3600)),
                Transfer(direction: .sent, kind: .text, deviceID: id, deviceName: dn, text: "Pick up milk and the package from the post office",
                         name: "Pick up milk…", state: .done, date: Date().addingTimeInterval(-7200)),
                Transfer(direction: .sent, kind: .file, deviceID: id, deviceName: dn, url: URL(fileURLWithPath: "/tmp/Big archive.zip"),
                         name: "Big archive.zip", size: 900_000_000, bytesDone: 120_000_000, state: .failed, date: Date().addingTimeInterval(-86400)),
            ])
            return
        }
        if name == "pickfiles", let d = model.selectedDevice { FilePicker.chooseAndSend(to: d); return }
        if name == "closepanels" { NSApp.windows.compactMap { $0 as? NSOpenPanel }.forEach { $0.cancel(nil) }; return }
        if name.hasPrefix("compose:") {
            model.section = .messages
            model.composePrefill = String(name.dropFirst(8))
            model.showCompose = true
            return
        }
        if name == "composeprobe" { composeProbe(); return }
        if name == "popuptest" {
            for t in TransferStore.shared.items.filter({ $0.direction == .received && $0.kind == .file }).prefix(3) {
                ReceivePopup.shared.show(t.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let anchor = ReceivePopup.statusItemFrame()
                let panel = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
                var log = "status item: \(anchor.map { NSStringFromRect($0) } ?? "not found")\n"
                log += "popup: \(panel.map { NSStringFromRect($0.frame) } ?? "none") visible=\(panel?.isVisible ?? false)\n"
                try? log.write(to: dir.appendingPathComponent("popup.txt"), atomically: true, encoding: .utf8)
                if let v = panel?.contentView { write(v, file: "popup") }
            }
            return
        }
        if name == "ringon" { model.selectedDevice?.setRinging(true); return }
        if name == "ringoff" { model.selectedDevice?.setRinging(false); return }
        if name == "mediaplay", let d = model.selectedDevice { d.media.isPlaying = true; d.media.positionDate = .now; return }
        if name == "openpanel" { StatusItemController.shared.showPanel(); return }
        if name == "closepanel" { StatusItemController.shared.closePanel(); return }
        // widgetfeedtest: a note with every kind of line and inline formatting, as the widgets get it (JSON).
        if name == "widgetfeedtest" {
            let text = "Formatting test\nIntro with **bold**, *italic*, ~~gone~~, `code` and a [link](https://example.com).\n\n# Big heading\n## Medium heading\n### Small heading\n- bullet with **bold**\n\t- nested snake_case_name\n1. first\n- [ ] task *soon*\n- [x] done task\n\n> a quote\n\n\n\nLast line after three empty lines\n\n"
            let note = WidgetFeed.Note(id: "test", rev: "1", title: "Formatting test", pinned: true, modified: .now, lines: NotesWidgets.lines(of: text))
            if let data = WidgetFeed.encode(.init(notes: [note])) { try? data.write(to: dir.appendingPathComponent("widgetfeedtest.json")) }
            return
        }
        // notewindowshot: the first note window as on screen; notewindowframe:x,y,w,h moves and sizes it.
        if name == "notewindowshot", let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("note:") == true && $0.isVisible }) {
            debugCapture(w, "notewindow"); return
        }
        if name.hasPrefix("notewindowframe:"), let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("note:") == true && $0.isVisible }) {
            let v = name.dropFirst(16).split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { w.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
            return
        }
        if name == "notewindowclose" { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("note:") == true && $0.isVisible }?.performClose(nil); return }
        // menubaricon:<pt> sets the menu bar icon's height (to compare sizes).
        if name.hasPrefix("menubaricon:"), let h = Double(name.dropFirst(12)) {
            StatusItemController.shared.button?.image = MenuBarLabel.icon(height: h); return
        }
        // tablecaret: insert a table, type in a cell, Tab, type: where the caret is drawn each time (logged), and a picture.
        if name == "tablecaret" {
            let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false   // Swift owns it (closing would release it a second time)
            let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.documentView = tv; w.contentView = scroll
            w.orderFrontRegardless(); w.makeFirstResponder(tv)
            tv.string = "Table test"; tv.restyle(); tv.setSelectedRange(NSRange(location: 10, length: 0))
            func step(_ what: String) { tv.layoutManager?.ensureLayout(for: tv.textContainer!); debugLog("tablecaret \(what): \(tv.debugCaret())") }
            tv.insertTable(nil); step("new table")
            tv.insertText("ტესტი", replacementRange: tv.selectedRange()); step("typed Georgian")
            tv.insertTab(nil); step("Tab")
            tv.insertText("abc", replacementRange: tv.selectedRange()); step("typed abc")
            tv.insertTab(nil); step("Tab to next row")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { debugCapture(w, "tablecaret"); w.close() }
            return
        }
        // codeflow: a conversation's notification as the phone sends it (posted, then updated per message): which
        // codes get announced (no alerts shown).
        if name == "codeflow", let d = model.selectedDevice {
            let cc = CodeCenter.shared
            cc.quiet = true; cc.announced = []
            var n = PhoneNotification(id: "sim-\(Int.random(in: 1000...9999))")
            n.appName = "Messages"; n.title = "Shop"; n.postedAt = .now
            func step(_ what: String, _ text: String, isNew: Bool) {
                let before = n.codeText
                n.text = text
                let had = d.checkForCode(n, isNew: isNew, before: isNew ? nil : before)
                debugLog("codeflow \(what): has code \(had), announced so far \(cc.announced)")
            }
            let a = Int.random(in: 100000...199999), b = a + 111111, c = a + 222222
            step("1 first SMS", "Your verification code is \(a)", isNew: true)
            step("2 second SMS (update)", "Your verification code is \(a)\nYour verification code is \(b)", isNew: false)
            step("3 plain message (update)", "Your verification code is \(a)\nYour verification code is \(b)\nThanks for registering!", isNew: false)
            step("4 third SMS, latest only (update)", "Your verification code is \(c)", isNew: false)
            step("5 same text re-sent (update)", "Your verification code is \(c)", isNew: false)
            var old = PhoneNotification(id: "sim-old-\(a)")
            old.appName = "Messages"; old.title = "Bank"; old.text = "Your code is \(a + 333333)"; old.postedAt = .now.addingTimeInterval(-1800)
            debugLog("codeflow 6 old notification re-sent after reconnect: has code \(d.checkForCode(old, isNew: true, before: nil)), announced \(cc.announced)")
            debugLog("codeflow expected: [\(a), \(b), \(c)]")
            cc.quiet = false
            return
        }
        // appcall: an app's ongoing-call live activity (as the phone sends WhatsApp's) and a timer: which are kept.
        if name == "appcall", let d = model.selectedDevice {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            d.upsertLive(id: "sim.wacall", json: #"{"v":1,"app":"WhatsApp","title":"Ongoing voice call","text":"Nino","when":\#(now - 65_000),"chrono":"up","cat":"call","now":\#(now)}"#, iconPath: nil, via: "test")
            d.upsertLive(id: "sim.timer2", json: #"{"v":1,"app":"Clock","title":"Tea","text":"Timer","when":\#(now + 180_000),"chrono":"down","cat":"stopwatch","now":\#(now)}"#, iconPath: nil, via: "test")
            debugLog("appcall: live now \(d.live.map { "\($0.id) [\($0.category ?? "-")]" }), shown \(d.visibleLive.map(\.id))")
            d.live.removeAll { $0.id == "sim.timer2" || $0.id == "sim.wacall" }
            return
        }
        // Janus Cloud testing: cloudsetup:<url>|<invite>, cloudpeer:<kde id>|<name>|<sign b64>|<box b64> (as if the
        // phone said hello over the LAN), cloudsend:<kde id>|<file path>, cloudstatus, cloudoff.
        if name.hasPrefix("cloudsetup:") {
            let parts = name.dropFirst(11).split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let url = URL(string: parts[0]) {
                Task { do { try await CloudService.shared.setUp(relay: url, invite: parts[1]); debugLog("cloud: set up, id \(CloudService.shared.deviceID)") } catch { debugLog("cloud: setup failed: \(error.localizedDescription)") } }
            }
            return
        }
        if name.hasPrefix("cloudpeer:") {
            let p = name.dropFirst(10).split(separator: "|").map(String.init)
            if p.count == 4 { Task { do { try await CloudService.shared.testAddPeer(kdeID: p[0], name: p[1], sign: p[2], box: p[3]); debugLog("cloud: peer \(p[1]) added") } catch { debugLog("cloud: peer failed: \(error.localizedDescription)") } } }
            return
        }
        if name.hasPrefix("cloudsend:") {
            let p = name.dropFirst(10).split(separator: "|", maxSplits: 1).map(String.init)
            if p.count == 2, let d = model.devices.first(where: { $0.id == p[0] }) {
                if d.isReachable { CloudTransfers.shared.send([URL(fileURLWithPath: p[1])], to: d) } else { d.share([URL(fileURLWithPath: p[1])]) }
                debugLog("cloud: sending \(p[1]) to \(d.name) (reachable \(d.isReachable))")
            }
            return
        }
        if name == "cloudstatus" {
            let c = CloudService.shared
            debugLog("cloud: status \(c.status), id \(c.deviceID), peers \(c.peers.map { "\($0.name) \($0.cloudID.prefix(8)) ready \($0.ready)" })")
            for t in TransferStore.shared.items.prefix(4) where t.viaCloud == true {
                debugLog("cloud transfer: \(t.direction) \(t.name) \(t.state) \(t.bytesDone)/\(t.size ?? -1) \(t.note ?? "") \(t.url?.path ?? "")")
            }
            return
        }
        if name == "cloudsettingsshot" {
            let host = NSHostingController(rootView: Form { CloudSettingsSection() }.formStyle(.grouped).environment(model).frame(width: 620, height: 300))
            let w = NSWindow(contentViewController: host)
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 620, height: 300)); w.center(); w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { debugCapture(w, "cloudsettings"); w.close() }
            return
        }
        // away:<kde id>: show that phone as not on this network (in the app only, until it next reports in), selected.
        if name.hasPrefix("away:"), let d = model.devices.first(where: { $0.id == String(name.dropFirst(5)) }) {
            d.isReachable = false
            model.selectedDeviceID = d.id
            return
        }
        // ring:<kde id>, sharetext:<kde id>|<text>: Find My Phone and text sharing (through the cloud when away).
        if name.hasPrefix("ring:"), let d = model.devices.first(where: { $0.id == String(name.dropFirst(5)) }) { d.ring(); return }
        if name.hasPrefix("sharetext:") {
            let p = name.dropFirst(10).split(separator: "|", maxSplits: 1).map(String.init)
            if p.count == 2, let d = model.devices.first(where: { $0.id == p[0] }) { d.shareText(p[1]) }
            return
        }
        if name.hasPrefix("cloudpeerremove:") {
            let kde = String(name.dropFirst(16))
            Task { await CloudService.shared.testRemovePeer(kdeID: kde); debugLog("cloud: test peer removed") }
            return
        }
        if name == "devicestate", let d = model.selectedDevice {
            debugLog("device \(d.name): reachable \(d.isReachable), battery \(d.batteryCharge.map(String.init) ?? "-") charging \(d.isCharging), ringer \(d.status?.ringer ?? "-"), cloud \(CloudService.shared.canReach(d))")
            return
        }
        if name == "statusitem", let b = StatusItemController.shared.button,
           let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) {
            // The menu bar item as drawn, and what it says (title, tooltip, VoiceOver).
            b.cacheDisplay(in: b.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("statusitem.png"))
            try? "title=\(b.title)\ntooltip=\(b.toolTip ?? "")\nax=\(b.accessibilityLabel() ?? "")\nsize=\(b.bounds.size)"
                .write(to: dir.appendingPathComponent("statusitem.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "panelstate" {
            let sc = StatusItemController.shared
            debugLog("panel: shown \(sc.isPanelShown), button window \(sc.button?.window.map { "\($0.frame) visible \($0.isVisible)" } ?? "none"), popup shown \(PopupHost.shared.isShown) cards \(PopupHost.shared.hasCards), locked \(MacState.isLocked)")
            return
        }
        if name == "cloudwake" { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared); return }
        if name == "cloudoff" { Task { await CloudService.shared.turnOff(); debugLog("cloud: off") }; return }
        if name == "windows" {
            let lines = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") \(type(of: $0)) visible=\($0.isVisible) occluded=\(!$0.occlusionState.contains(.visible)) content=\($0.contentViewController.map { String(describing: type(of: $0)).prefix(60) } ?? "nil") frame=\($0.frame)" }
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8); return
        }
        if name == "closemain" { NSApp.windows.first { $0.identifier?.rawValue == "main" }?.close(); return }
        if name == "wantmain" { model.wantsMainWindow = true; return }
        if name == "mediastop", let d = model.selectedDevice { d.media.isPlaying = false; return }
        // fakemedia: a playing song with album art (the app's icon), to check the scrubber and art without the phone.
        if name == "fakemedia", let d = model.selectedDevice {
            var m = MediaState()
            m.players = ["Spotify"]; m.player = "Spotify"; m.title = "Test Song"; m.artist = "Test Artist"; m.album = "Album"
            m.artURL = Bundle.main.url(forResource: "Janus", withExtension: "icns")
            m.length = 215_000; m.position = 61_400; m.positionDate = .now; m.isPlaying = true; m.canSeek = true; m.volume = 50
            d.media = m; return
        }
        if name == "nomedia", let d = model.selectedDevice { d.media = MediaState(); return }
        if name == "alignstop" {
            model.selectedDevice?.media.isPlaying = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
                StatusItemController.shared.sampleContentAlignment { samples in
                    try? samples.joined(separator: "\n").write(to: dir.appendingPathComponent("align-stop.txt"), atomically: true, encoding: .utf8)
                }
            }
            return
        }
        if name == "alignprobe" {
            StatusItemController.shared.sampleContentAlignment { samples in
                try? samples.joined(separator: "\n").write(to: dir.appendingPathComponent("align.txt"), atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { model.selectedDevice?.media.isPlaying = true }
            return
        }
        if name.hasPrefix("macaction:") { MacActions.perform(String(name.dropFirst(10))); return }
        if name == "fakestatus", let d = model.selectedDevice { d.status = .init(ringer: "vibrate", flashlight: false); d.phoneDND = false; return }
        if name.hasPrefix("cmd:") { model.selectedDevice?.command(String(name.dropFirst(4))); return }
        if name == "status" {
            let d = model.selectedDevice
            try? "status=\(String(describing: d?.status)) dnd=\(String(describing: d?.phoneDND))"
                .write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "fakecall", let d = model.selectedDevice {
            Notifier.shared.call(event: "callReceived", number: "+12025550143", contactName: "", device: d); return
        }
        if name.hasPrefix("sized:") {
            // sized:<width>x<height>:<pane>: the main window at a given size (e.g. the owner's window).
            let parts = name.split(separator: ":").map(String.init)
            let dims = parts[1].split(separator: "x").compactMap { Double($0) }
            if dims.count == 2, let pane = Pane(rawValue: parts[2]) {
                model.section = pane
                render(MainWindow().environment(model), size: NSSize(width: dims[0], height: dims[1]), file: "sized", titled: true)
            }
            return
        }
        if name == "mirror", let d = model.selectedDevice { MirrorController.shared.start(d); return }
        if name == "mirrorhome" { MirrorController.shared.home(); return }
        if name.hasPrefix("mirrortap:") {
            let v = name.dropFirst(10).split(separator: ",").compactMap { Int($0) }
            if v.count == 2, let s = MirrorController.shared.session { s.touch(.down, x: v[0], y: v[1]); s.touch(.up, x: v[0], y: v[1]) }
            return
        }
        if name.hasPrefix("mirrorsound:") { MirrorController.shared.soundOnMac = name.hasSuffix("on"); return }
        if name.hasPrefix("mirrorscreen:") { MirrorController.shared.phoneScreenOff = name.hasSuffix("off"); return }
        if name.hasPrefix("mirrorquality:"), let q = MirrorController.Quality(rawValue: String(name.dropFirst(14))) { MirrorController.shared.quality = q; return }
        if name.hasPrefix("mirrorcopy:") { let pb = NSPasteboard.general; pb.clearContents(); pb.setString(String(name.dropFirst(11)), forType: .string); return }
        if name == "mirrorwindow", let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "mirror" }) {
            // The composited window (corners, shadow, title bar); an app may capture its own windows.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(w.windowNumber), 8)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mirrorwindow.png"))
            }
            return
        }
        if name.hasPrefix("mirrorswipe:"), let s = MirrorController.shared.session {
            // x1,y1,x2,y2 in phone pixels, as one finger drag over ~250 ms.
            let n = name.dropFirst(12).split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { return }
            s.touch(.down, x: Int(n[0]), y: Int(n[1]))
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25 * i)) {
                    let t = Double(i) / 10
                    s.touch(i == 10 ? .up : .move, x: Int(n[0] + (n[2] - n[0]) * t), y: Int(n[1] + (n[3] - n[1]) * t))
                }
            }
            return
        }
        if name == "mirrorwake" { MirrorController.shared.wake(); return }
        if name == "mirrorstop" { MirrorController.shared.stop(); return }
        if name == "mirrorframe", let sample = MirrorController.shared.view.lastSample {
            DebugFrame.save(sample, to: dir.appendingPathComponent("mirrorframe.png")); return
        }
        if name == "mirrorstate" {
            let c = MirrorController.shared
            try? "state=\(c.state) size=\(c.videoSize) device=\(c.session?.deviceName ?? "-") frames=\(c.view.frameCount) failed=\(c.view.rendererFailed) audio=\(c.audioDebug) asleep=\(c.phoneAsleep) quality=\(c.quality) screenOff=\(c.phoneScreenOff) clip=\(NSPasteboard.general.string(forType: .string)?.prefix(40) ?? "-") window=\(NSApp.windows.first(where: { $0.identifier?.rawValue == "mirror" }).map { "\($0.frame) content=\($0.contentLayoutRect.size)" } ?? "-")".write(to: dir.appendingPathComponent("mirror.txt"), atomically: true, encoding: .utf8); return
        }
        if name == "mirrorshot" {
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "mirror" }), let v = w.contentView { write(v.superview ?? v, file: "mirror") }
            return
        }
        if name.hasPrefix("fakeunpair:"), let d = model.devices.first(where: { $0.id == String(name.dropFirst(11)) }) {
            d.isPaired = false; model.reconcilePairing(); return
        }
        if name == "selection" {
            try? "selected=\(model.selectedDevice?.name ?? "-") paired=\(model.selectedDevice?.isPaired ?? false) devices=\(model.devices.map { "\($0.name):\($0.isPaired)" })".write(to: dir.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8); return
        }
        if name.hasPrefix("select:") { model.selectedDeviceID = String(name.dropFirst(7)); return }
        if name == "fakestats", let d = model.selectedDevice {
            var s = d.status ?? .init()
            s.ssid = "Home-5G"; s.carrier = "Magti"; s.cellular = "LTE"
            s.storageFree = 212_000_000_000; s.storageTotal = 256_000_000_000; s.os = "Android 16 · One UI 8.0"
            if s.ringer == nil { s.ringer = "vibrate" }
            if s.flashlight == nil { s.flashlight = false }
            if d.phoneDND == nil { d.phoneDND = false }
            d.status = s
            return
        }
        if name.hasPrefix("clipsync:"), let d = model.selectedDevice { d.setClipboardAutoSync(name.hasSuffix("on")); return }
        // profile:<json> applies a device profile (R28) to the selected device, as if the phone sent it.
        if name.hasPrefix("profile:"), let d = model.selectedDevice {
            DeviceProfiles.apply(json: String(name.dropFirst(8)), from: d); return
        }
        if name == "profileclear", let d = model.selectedDevice {
            DeviceProfiles.forget(d.id); d.profile = nil; d.lookVersion += 1; return
        }
        // recvtest:<n>: n files arrive from the selected phone as one announced batch (sounds are logged).
        if name.hasPrefix("recvtest:"), let d = model.selectedDevice, let n = Int(name.dropFirst(9)) {
            let urls = (0..<n).map { URL(fileURLWithPath: NSTemporaryDirectory() + "recvtest-\($0).txt") }
            urls.forEach { try? "test".write(to: $0, atomically: true, encoding: .utf8) }
            if n > 1 { TransferStore.shared.expectIncoming(totalBytes: Int64(4 * n), files: n, device: d) }
            for (i, url) in urls.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { TransferStore.shared.received(url, device: d) }
            }
            return
        }
        // notifadd / notifgone: a phone notification arrives / leaves the phone (history testing).
        if name == "notifadd", let d = model.selectedDevice {
            var n = PhoneNotification(id: "debug.1")
            n.internalId = "0|com.whatsapp|debug|1"; n.appName = "WhatsApp"; n.title = "Alex"; n.text = "See you at 8!"
            n.postedAt = Date().addingTimeInterval(-300)
            n.postedAt = NotificationHistory.shared.record(n, device: d)
            d.notifications.removeAll { $0.id == n.id }
            d.notifications.insert(n, at: 0)
            return
        }
        if name == "notifgone", let d = model.selectedDevice, let n = d.notifications.first(where: { $0.id == "debug.1" }) {
            NotificationHistory.shared.ended(n, device: d)
            d.notifications.removeAll { $0.id == n.id }
            return
        }
        // notestest: a scripted sync session with a pretend phone (results in debug.log).
        if name == "notestest", let real = model.devices.first {
            let peer = Device(id: "notes-test-peer", bus: real.bus)
            peer.name = "Pretend Phone"
            peer.profile = DeviceProfile(caps: ["notes"], fromPhone: true)
            UserDefaults.standard.set("mine", forKey: "trust.notes-test-peer")
            let store = NotesStore.shared
            func dump(_ step: String) {
                debugLog(step + ": " + store.notes.map { "[\($0.title)|\($0.deleted == nil ? "live" : "deleted")|\($0.rev.prefix(4))]" }.joined(separator: " "))
            }
            func push(_ notes: [[String: Any]]) {
                let data = try! JSONSerialization.data(withJSONObject: ["v": 1, "op": "push", "notes": notes])
                store.receive(String(decoding: data, as: UTF8.self), from: peer)
            }
            let ms = { (d: Date) in Note.ms(d) }
            let a = store.create(text: "Groceries\n- [ ] milk\n- [x] bread")
            dump("1 created A on Mac")
            push([["id": "B", "rev": "b1", "text": "From phone\nhello", "pinned": false, "created": ms(.now), "modified": ms(.now)]])
            dump("2 phone sent new B")
            push([["id": a.id, "rev": "a-phone-1", "base": a.rev, "text": "Groceries\n- [x] milk\n- [x] bread", "pinned": true,
                   "created": ms(a.created), "modified": ms(.now) + 5]])
            dump("3 phone edited A (on top of Mac's)")
            store.setText(a.id, "Groceries (Mac edit)\n- [x] milk")
            push([["id": a.id, "rev": "a-phone-2", "base": "a-phone-1", "text": "Groceries (phone edit)", "pinned": true,
                   "created": ms(a.created), "modified": ms(.now) + 60_000]])
            dump("4 both edited A -> conflict (phone later)")
            push([["id": "B", "rev": "b2", "base": "b1", "text": "From phone\nhello", "pinned": false, "created": ms(.now),
                   "modified": ms(.now), "deleted": ms(.now)]])
            dump("5 phone deleted B")
            push([["id": "B", "rev": "b2", "base": "b1", "text": "From phone\nhello", "pinned": false, "created": ms(.now),
                   "modified": ms(.now), "deleted": ms(.now)]])
            dump("6 same push again (no change expected)")
            debugLog("uuid3 conflict id check: " + Note.uuid3("conflict:abc:def"))
            UserDefaults.standard.removeObject(forKey: "trust.notes-test-peer")
            return
        }
        // noteeditor: the note editor with a checklist, in a window (checkbox rendering).
        if name == "noteeditor" {
            let text = "Weekend trip\nPack the **night before**, it's *much* calmer. ~~Taxi~~ Train at `08:15`, see [timetable](https://example.com).\n## Packing\n- [ ] Passport\n- [x] Charger\n\t- [ ] Spare cable\n### Plan\n1. Train to the coast\n2. Check in\n\t1. Leave bags\n- Swim\n\t- Sunscreen\n> Don't forget the camera.\n```\nWi-Fi: Hotel-Guest\nPassword: sea2026\n```\n| Day | Plan | Cost |\n| --- | --- | --- |\n| Saturday | **Beach** and dinner | 120 € |\n| Sunday | Botanical garden | 30 € |\nCall mum when there."
            let host = NSHostingController(rootView: NoteEditor(text: .constant(text), noteID: "preview").frame(width: 560, height: 720))
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 560, height: 720)); w.center(); w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { debugCapture(w, "noteeditor"); w.close() }
            return
        }
        // noterenderfile:<path>: text from a file, as the Mac shows it (debug.log gets the visible text length).
        if name.hasPrefix("noterenderfile:"), let text = try? String(contentsOfFile: String(name.dropFirst(15).split(separator: "@").first ?? ""), encoding: .utf8) {
            let caretAt = name.split(separator: "@").dropFirst().first.flatMap { Int($0) }
            let host = NSHostingController(rootView: NoteEditor(text: .constant(text), noteID: "file").frame(width: 560, height: 320))
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 560, height: 320)); w.center(); w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let tv = w.contentView?.firstDescendant(of: NoteTextView.self), let st = tv.textStorage {
                    var clear = 0
                    st.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: st.length)) { v, r, _ in if (v as? NSColor) == .clear { clear += r.length } }
                    debugLog("render \((name as NSString).lastPathComponent): length \(st.length), clear chars \(clear), used rect \(tv.layoutManager!.usedRect(for: tv.textContainer!))")
                    tv.debugLayout().forEach { debugLog("  " + $0) }
                }
                debugCapture(w, "noterenderfile")
                if let tv = w.contentView?.firstDescendant(of: NoteTextView.self) {
                    tv.setSelectedRange(NSRange(location: caretAt ?? 0, length: 0)); tv.restyle(); tv.display()
                    debugLog("after caret move: selection \(tv.selectedRange()), length \((tv.string as NSString).length)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { debugCapture(w, "noterenderfile-caret0"); w.close() }
            }
            return
        }
        // noterender:<title>: a synced note as the Mac shows it.
        if name.hasPrefix("noterender:"), let note = NotesStore.shared.live.first(where: { $0.title == String(name.dropFirst(11)) }) {
            let host = NSHostingController(rootView: NoteEditor(text: .constant(note.text), noteID: "render").frame(width: 560, height: 640))
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 560, height: 640)); w.center(); w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { debugCapture(w, "noterender"); w.close() }
            return
        }
        // notesperf: typing speed in a long note (600 lines of mixed formatting), per keystroke.
        if name == "notesperf" {
            let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.documentView = tv; w.contentView = scroll
            var lines = ["Long note"]
            for i in 0..<100 { lines += ["## Section \(i)", "Some **bold** and *italic* text with a [link](https://example.com) and `code`.",
                                         "- [ ] task \(i)", "\t- nested bullet", "1. numbered", "> quote line"] }
            tv.string = lines.joined(separator: "\n"); tv.restyle()
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length / 2, length: 0))
            let start = Date()
            for _ in 0..<200 { tv.insertText("a", replacementRange: tv.selectedRange()) }
            let typing = Date().timeIntervalSince(start) / 200 * 1000
            let s2 = Date()
            for _ in 0..<50 { tv.moveDown(nil) }
            let moving = Date().timeIntervalSince(s2) / 50 * 1000
            let s3 = Date(); tv.restyle(); let full = Date().timeIntervalSince(s3) * 1000
            debugLog(String(format: "notesperf: %.2f ms per keystroke, %.2f ms per line move, %.1f ms full restyle (%d lines)", typing, moving, full, lines.count))
            return
        }
        // tableedits: Tab, Return, | and row/column commands in a table (logged).
        if name == "tableedits" {
            let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            func show(_ step: String) { debugLog(step + ": " + tv.string.replacingOccurrences(of: "\n", with: "⏎")) }
            tv.string = "Plan"; tv.restyle(); tv.setSelectedRange(NSRange(location: 4, length: 0))
            tv.insertTable(nil); show("insert table")
            tv.insertText("Day", replacementRange: tv.selectedRange()); tv.insertTab(nil); tv.insertText("Cost", replacementRange: tv.selectedRange())
            tv.insertTab(nil); tv.insertText("Sat", replacementRange: tv.selectedRange()); tv.insertTab(nil); tv.insertText("12|3", replacementRange: tv.selectedRange())
            show("typed cells with Tab (and a |)")
            tv.insertTab(nil); show("Tab past last cell adds a row")
            tv.insertBacktab(nil); show("Shift-Tab back (caret \(tv.selectedRange().location))")
            tv.tableAddColumnAfter(nil); show("add column after")
            tv.tableDeleteColumn(nil); show("delete column")
            tv.tableDeleteRow(nil); show("delete row")
            tv.tableDelete(nil); show("delete table")
            return
        }
        // notesattachtest: a note made on the Mac with a picture, for the phone to fetch.
        if name == "notesattachtest" {
            Task { @MainActor in
                let png = FileManager.default.temporaryDirectory.appendingPathComponent("Mac test picture.png")
                let img = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { r in
                    NSGradient(colors: [.systemPink, .systemOrange])!.draw(in: r, angle: 0)
                    ("From the Mac" as NSString).draw(at: NSPoint(x: 40, y: 120), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white])
                    return true }
                try? NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
                guard let line = await NoteAttachments.shared.add(png) else { return }
                NotesStore.shared.create(text: "Mac attachment test\nA picture added on the Mac:\n" + line)
                debugLog("notesattachtest: created note with \(line.suffix(80))")
            }
            return
        }
        // noteattach: a note with a picture, a PDF, another file and one still on its way (rendering test).
        if name == "noteattach" {
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory
                let png = dir.appendingPathComponent("Beach.png"), pdf = dir.appendingPathComponent("Boarding pass.pdf"), zip = dir.appendingPathComponent("Photos.zip")
                let img = NSImage(size: NSSize(width: 800, height: 450), flipped: false) { r in
                    NSGradient(colors: [.systemTeal, .systemBlue])!.draw(in: r, angle: 90)
                    NSColor.systemYellow.setFill(); NSBezierPath(ovalIn: NSRect(x: 560, y: 260, width: 120, height: 120)).fill()
                    return true }
                try? NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
                let pdfData = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 595, height: 842)
                let ctx = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &box, nil)!
                ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.systemIndigo.cgColor); ctx.fill(CGRect(x: 40, y: 700, width: 515, height: 100)); ctx.endPDFPage(); ctx.closePDF()
                pdfData.write(to: pdf, atomically: true)
                try? Data(repeating: 7, count: 240_000).write(to: zip)
                var lines: [String] = []
                for u in [png, pdf, zip] { if let l = await NoteAttachments.shared.add(u) { lines.append(l) } }
                lines.append("![Scan from phone.jpg](attachments/" + String(repeating: "ab", count: 32) + ".jpg)")
                let text = "Trip files\nThe view from the hotel:\n" + lines.joined(separator: "\n") + "\nThat's all."
                let host = NSHostingController(rootView: NoteEditor(text: .constant(text), noteID: "attach").frame(width: 560, height: 900))
                let w = NSWindow(contentViewController: host)
                w.setContentSize(NSSize(width: 560, height: 900)); w.center(); w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { debugCapture(w, "noteattach"); w.close() }
            }
            return
        }
        // noteedits: the editor's list behaviour, logged (Return, Return on empty item, Backspace, Checklist toggle).
        if name == "noteedits" {
            let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            func show(_ step: String) { debugLog(step + ": " + tv.string.replacingOccurrences(of: "\n", with: "⏎")) }
            tv.string = "List\n- [ ] milk"; tv.restyle(); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertNewline(nil); show("Return after item")
            tv.insertText("eggs", replacementRange: tv.selectedRange()); tv.insertNewline(nil); show("type eggs, Return")
            tv.insertNewline(nil); show("Return on empty item")
            tv.insertText("note", replacementRange: tv.selectedRange()); show("type note")
            tv.setSelectedRange(NSRange(location: 4 + 1 + 6, length: 0)); tv.deleteBackward(nil); show("Backspace at start of milk")
            tv.setSelectedRange(NSRange(location: 6, length: 0)); tv.toggleChecklist(nil); show("Checklist on milk line")
            tv.setSelectedRange(NSRange(location: 7, length: 0)); show("caret moved to \(tv.selectedRange().location) (hidden prefix skipped)")

            tv.string = "Steps\n1. One"; tv.restyle(); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertNewline(nil); show("Return after 1.")
            tv.insertText("Two", replacementRange: tv.selectedRange()); tv.insertTab(nil); show("Tab indents (renumbered)")
            tv.insertBacktab(nil); show("Shift-Tab outdents (renumbered)")
            tv.insertNewline(nil); tv.insertTab(nil); tv.insertNewline(nil); show("Return on empty nested item outdents")
            tv.insertNewline(nil); show("Return on empty item ends list")
            tv.string = "Title\nsome words here"; tv.restyle(); tv.setSelectedRange(NSRange(location: 11, length: 5))
            tv.formatBold(nil); show("⌘B on 'words'")
            tv.formatBold(nil); show("⌘B again unwraps")
            tv.setSelectedRange(NSRange(location: 8, length: 0)); tv.formatHeading(nil); show("⇧⌘H on line 2")
            tv.formatBulleted(nil); show("⇧⌘7 on line 2")
            tv.formatBulleted(nil); show("⇧⌘7 again: back to text")
            tv.formatMonospaced(nil); show("⇧⌘M wraps in a code block")
            tv.setSelectedRange(NSRange(location: 11, length: 0)); tv.formatMonospaced(nil); show("⇧⌘M inside removes it")
            for l in ["# Hello **there**", "- [x] Done ~~it~~", "\t1. [link](https://x.y) `code`", "![Scan 1.pdf](attachments/ab12.pdf)", "| a | b \\| c |", "plain \\*star\\*"] {
                debugLog("plain(\(l)) = \(Markdown.plain(l))")
            }
            return
        }
        // notesmac: edit and add a note on the Mac, then log whether the phones acknowledge them (Mac → phone test).
        if name == "notesmac" {
            let store = NotesStore.shared
            var ids: [String] = []
            if let shop = store.live.first(where: { $0.title == "Shopping" }) {
                store.setText(shop.id, shop.text.replacingOccurrences(of: "- [ ] Bread", with: "- [x] Bread"))
                ids.append(shop.id)
            }
            let new = store.create(text: "From the Mac\nWritten on the Mac to test sync.\n- [ ] Seen on the phone")
            store.setText(new.id, new.text + "\n- [ ] Ticked on the phone")
            ids.append(new.id)
            debugLog("notesmac: peers " + store.peers().map(\.name).joined(separator: ", "))
            for delay in [3.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for id in ids {
                        let n = store.note(id)!
                        let peers = store.peers().map { "\($0.name): \(store.ackedRev(id, peer: $0.id) == n.rev ? "acked" : "not yet")" }
                        debugLog("after \(Int(delay))s \(n.title) rev \(n.rev.prefix(6)) → " + peers.joined(separator: ", "))
                    }
                }
            }
            return
        }
        // notesconflict: the Mac's half of the conflict test; notesdump: every note with its rev.
        if name == "notesconflict", let n = NotesStore.shared.live.first(where: { $0.title.hasPrefix("From the Mac") }) {
            var lines = n.text.components(separatedBy: "\n"); lines[0] = "From the Mac (Mac edit)"
            NotesStore.shared.setText(n.id, lines.joined(separator: "\n"))
            debugLog("notesconflict: edited \(n.id.prefix(8)) on the Mac")
            return
        }
        if name.hasPrefix("notesoffline:") {
            NotesStore.shared.paused = name.hasSuffix("on")
            debugLog("notes sync " + (NotesStore.shared.paused ? "paused (offline)" : "resumed (reconnect hello sent)"))
            return
        }
        if name == "notesdump" {
            for n in NotesStore.shared.notes {
                debugLog("note \(n.id) rev \(n.rev.prefix(8)) \(n.deleted == nil ? "live" : "deleted") \(n.title)")
            }
            return
        }
        if name == "quicknote" {
            QuickNote.show(focus: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let p = NSApp.windows.first(where: { $0 is QuickNotePanel && $0.isVisible }) { debugCapture(p, "quicknote") }
            }
            return
        }
        if name.hasPrefix("notesdelete:") {
            NotesStore.shared.delete(String(name.dropFirst(12)))
            debugLog("deleted \(name.dropFirst(12))")
            return
        }
        if name == "quicknoteclose" { QuickNote.close(); return }
        if name.hasPrefix("appicon:") {
            if let st = AppIcon.Style(rawValue: String(name.dropFirst(8))) { AppIcon.style = st }
            debugLog("app icon: style \(AppIcon.style.rawValue), system \(UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light"), showing \(AppIcon.showing), set \(NSApp.applicationIconImage != nil)")
            return
        }
        if name == "quicknotestate" {
            let p = NSApp.windows.first { $0 is QuickNotePanel }
            debugLog("quick note panel: \(p?.isVisible == true ? "open at \(p!.frame)" : "closed")")
            for w in NSApp.windows where w.contentView.map({ String(describing: type(of: $0)) }) == "CornerView" {
                debugLog("corner window \(w.frame) visible \(w.isVisible) onScreen \(w.isOnActiveSpace) level \(w.level.rawValue)")
            }
            for s in NSScreen.screens { debugLog("screen \(s.frame)") }
            return
        }
        if name == "arts" {
            render(HStack(spacing: 30) {
                // Pixel 9 Pro (1280×2856, punch-hole), a generic phone, an S22 Ultra and an S25.
                let pixel = DeviceProfile.Screen(w: 1280, h: 2856, radius: 140, cutouts: [[590, 40, 690, 140]])
                let looks = [
                    DeviceLook(shape: .front, finish: Finish.generic[1], screen: pixel,
                               accent: ["#C5D6F8", "#4E6DAE", "#1A1C22"].compactMap { Color(hex: $0) }),
                    DeviceLook(shape: .front, finish: Finish.generic[0]),
                    DeviceLook(shape: .s22Ultra, finish: Finish.s22Ultra[0]),
                    DeviceLook(shape: .s25, finish: Finish.s25[0]),
                ]
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                    Group {
                        if look.shape == .front { PhoneFront(look: look) } else { PhoneBack(look: look) }
                    }
                    .frame(width: 220 * look.aspect, height: 220)
                }
            }.padding(30), size: nil, file: "arts")
            return
        }
        if name.hasPrefix("trust:") {
            let parts = name.split(separator: ":").map(String.init)
            if parts.count == 3, let d = model.devices.first(where: { $0.id == parts[1] }), let l = DeviceTrust.Level(rawValue: parts[2]) {
                DeviceTrust.set(l, for: d)
            }
            return
        }
        if name == "fakeanswer", let d = model.selectedDevice {
            let start = Int((Date().timeIntervalSince1970 - 65) * 1000), now = Int(Date().timeIntervalSince1970 * 1000)
            d.applyCallState(id: "cs1", json: "{\"state\":\"talking\",\"number\":\"+12025550143\",\"name\":\"\",\"start\":\(start),\"now\":\(now)}")
            return
        }
        if name == "callcompose" { CallPopup.shared.composing = true; return }
        if name == "callshot" {
            if let w = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
               let v = w.contentView?.superview ?? w.contentView { write(v, file: "callpopup") }
            return
        }
        if name == "fakelive", let d = model.selectedDevice {
            let ms = Int((Date().addingTimeInterval(8 * 60 + 12).timeIntervalSince1970) * 1000)
            d.live = [
                LiveActivity(id: "l1", json: #"{"v":1,"app":"Wolt","title":"Arriving in 8 min","text":"Sam is on the way with your order","short":"8 min","progress":0.62,"cat":"transport"}"#, iconPath: nil)!,
                LiveActivity(id: "l2", json: "{\"v\":1,\"app\":\"Clock\",\"title\":\"Pasta\",\"text\":\"Timer\",\"when\":\(ms),\"chrono\":\"down\",\"cat\":\"stopwatch\"}", iconPath: nil)!,
            ]
            StatusItemController.shared.updateLiveLabel()
            return
        }
        if name == "iconshot", let b = StatusItemController.shared.button { try? "title=[\(b.title)] tip=\(b.toolTip ?? "")".write(to: dir.appendingPathComponent("statusicon.txt"), atomically: true, encoding: .utf8); return }
        if name == "nolive", let d = model.selectedDevice { d.live = []; return }
        if name == "pendingalerts" {
            UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                let lines = reqs.map { r -> String in
                    let fire = (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate().map { $0.formatted(date: .omitted, time: .shortened) } ?? "?"
                    return "\(r.identifier.prefix(12))… at \(fire) cat=\(r.content.categoryIdentifier) body=\(r.content.body.split(separator: "·").first ?? "")"
                }
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("alerts.txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        if name.hasPrefix("calevent:"), let device = model.selectedDevice {
            // calevent:<minutes from now>[:<length>] = one test event; calevent:none = no events.
            let parts = name.split(separator: ":").dropFirst().map(String.init)
            let ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
            var events: [[String: Any]] = []
            if let m = parts.first.flatMap(Double.init) {
                let len = parts.dropFirst().first.flatMap(Double.init) ?? 30
                let start = Date().addingTimeInterval(m * 60)
                events = [["id": "t1", "cal": "1", "title": "Edge test", "start": ms(start), "end": ms(start.addingTimeInterval(len * 60)), "allDay": false, "join": "https://meet.google.com/abc-defg-hij"]]
            }
            let snapshot: [String: Any] = ["v": 1, "now": ms(.now), "to": ms(.now.addingTimeInterval(7 * 86_400)),
                                           "calendars": [["id": "1", "name": "Work", "account": "test", "color": "#4285F4"]], "events": events]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) { CalendarStore.shared.apply(json: String(decoding: data, as: UTF8.self), from: device) }
            return
        }
        if name == "mergetest", let a = model.selectedDevice {
            let b = Device(id: "test-second-phone", bus: a.bus); b.name = "Test Phone"
            // The same meeting on two phones appears once; each phone's own events all appear.
            let t = Int(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000
            let cal = #"[{"id":"1","name":"Work","account":"me@work"}]"#
            CalendarStore.shared.apply(json: #"{"v":1,"calendars":\#(cal),"events":[{"id":"s","cal":"1","title":"Standup","start":\#(t),"end":\#(t + 900_000),"allDay":false}]}"#, from: a)
            CalendarStore.shared.apply(json: #"{"v":1,"calendars":[{"id":"7","name":"Work","account":"me@work"}],"events":[{"id":"q","cal":"7","title":"Standup","start":\#(t),"end":\#(t + 900_000),"allDay":false},{"id":"r","cal":"7","title":"Only on the other phone","start":\#(t + 3_600_000),"end":\#(t + 7_200_000),"allDay":false}]}"#, from: b)
            let c = CalendarStore.shared
            try? "sources=\(c.sourceNames) events=\(c.events.map(\.title)) calendars=\(c.calendars.count)".write(to: dir.appendingPathComponent("merge.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "caloff", let device = model.selectedDevice {
            CalendarStore.shared.apply(json: #"{"v":1,"calendars":[],"events":[],"off":true}"#, from: device); return
        }
        if name == "eventdetail", let e = CalendarStore.shared.events.first(where: { $0.join != nil }) ?? CalendarStore.shared.events.first {
            render(EventDetail(event: e).environment(model), size: nil, file: "eventdetail"); return
        }
        if name == "deliveredalerts" {
            UNUserNotificationCenter.current().getDeliveredNotifications { list in
                let lines = ["all delivered: \(list.count) [\(list.map { String($0.request.identifier.prefix(14)) }.joined(separator: ", "))]"] + list.filter { $0.request.identifier.hasPrefix("calendar.") }
                    .map { "\($0.request.identifier.split(separator: "@").first ?? "") | \($0.request.content.title) | \($0.request.content.body)" }
                try? (lines.isEmpty ? "none" : lines.joined(separator: "\n")).write(to: dir.appendingPathComponent("delivered.txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        if name == "calstate" {
            let c = CalendarStore.shared
            let lines = ["sources=\(c.sourceNames) off=\(c.isOffOnPhone) events=\(c.events.count) visible=\(c.visible.count) calendars=\(c.calendars.map(\.name))"]
                + c.events.map { "\($0.title) \($0.start.formatted(date: .abbreviated, time: .shortened)) → \($0.end.formatted(date: .omitted, time: .shortened)) allDay=\($0.allDay)" }
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("calstate.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "fakecalendar2", let other = model.devices.first(where: { $0.id != model.selectedDeviceID }) {
            // The same events from a second phone (merging), plus one of its own.
            let now = Date(), ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
            let snapshot: [String: Any] = ["v": 1, "now": ms(now), "calendars": [["id": "9", "name": "Work", "account": "work@example.com", "color": "#4285F4"]],
                "events": [["id": "x", "cal": "9", "title": "Only on the other phone", "start": ms(now.addingTimeInterval(2 * 3600)), "end": ms(now.addingTimeInterval(3 * 3600)), "allDay": false]]]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) { CalendarStore.shared.apply(json: String(decoding: data, as: UTF8.self), from: other) }
            return
        }
        if name == "clearcalendar" { CalendarStore.shared.clear(); return }
        if name.hasPrefix("fakecalendar"), let device = model.selectedDevice {
            // fakecalendar[:<minutes until "Standup">]: a sample snapshot around now.
            let lead = Double(name.split(separator: ":").dropFirst().first.flatMap { Double($0) } ?? 12)
            let now = Date(), ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
            let day = Calendar.current.startOfDay(for: now)
            let events: [[String: Any]] = [
                ["id": "a", "cal": "1", "title": "Design review", "start": ms(now.addingTimeInterval(-20 * 60)), "end": ms(now.addingTimeInterval(10 * 60)), "allDay": false, "join": "https://meet.google.com/abc-defg-hij"],
                ["id": "b", "cal": "1", "title": "Standup", "start": ms(now.addingTimeInterval(lead * 60)), "end": ms(now.addingTimeInterval((lead + 15) * 60)), "allDay": false, "join": "https://us02web.zoom.us/j/123456789"],
                ["id": "c", "cal": "2", "title": "Dentist", "start": ms(now.addingTimeInterval(3 * 3600)), "end": ms(now.addingTimeInterval(4 * 3600)), "allDay": false, "location": "Vake clinic"],
                ["id": "d", "cal": "2", "title": "Tamar's birthday", "start": ms(day), "end": ms(day.addingTimeInterval(86_400)), "allDay": true],
                ["id": "e", "cal": "1", "title": "Quarterly planning with the whole product team", "start": ms(day.addingTimeInterval(86_400 + 10 * 3600)), "end": ms(day.addingTimeInterval(86_400 + 11 * 3600)), "allDay": false],
                ["id": "f", "cal": "2", "title": "Lunch with Alex", "start": ms(now.addingTimeInterval(-5 * 60)), "end": ms(now.addingTimeInterval(55 * 60)), "allDay": false],
                ["id": "g", "cal": "1", "title": "Call Jordan", "start": ms(now.addingTimeInterval(2 * 3600)), "end": ms(now.addingTimeInterval(2 * 3600)), "allDay": false],
                ["id": "h", "cal": "2", "title": "Night flight to Berlin", "start": ms(day.addingTimeInterval(86_400 + 22 * 3600)), "end": ms(day.addingTimeInterval(2 * 86_400 + 2 * 3600)), "allDay": false],
                ["id": "i", "cal": "2", "title": "Conference", "start": ms(day.addingTimeInterval(86_400)), "end": ms(day.addingTimeInterval(4 * 86_400)), "allDay": true],
                ["id": "j", "cal": "1", "title": "Review", "start": ms(day.addingTimeInterval(86_400 + 10 * 3600 + 1800)), "end": ms(day.addingTimeInterval(86_400 + 12 * 3600)), "allDay": false],
            ]
            let snapshot: [String: Any] = ["v": 1, "now": ms(now), "to": ms(day.addingTimeInterval(7 * 86_400)), "calendars": [
                ["id": "1", "name": "Work", "account": "work@example.com", "color": "#4285F4"],
                ["id": "2", "name": "Personal", "account": "personal@example.com", "color": "#33B679"]], "events": events]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) { CalendarStore.shared.apply(json: String(decoding: data, as: UTF8.self), from: device) }
            return
        }
        if name == "fakenotifs", let d = model.selectedDevice {
            var a = PhoneNotification(id: "f1"); a.appName = "WhatsApp"; a.title = "Alex"; a.text = "Are we still on for dinner tonight?"; a.replyId = "r1"; a.actions = ["Mark as read"]; a.postedAt = .now.addingTimeInterval(-60)
            var b = PhoneNotification(id: "f2"); b.appName = "WhatsApp"; b.title = "Family"; b.text = "Mom: Don't forget to call grandma"; b.postedAt = .now.addingTimeInterval(-600)
            var c = PhoneNotification(id: "f3"); c.appName = "Gmail"; c.title = "Your order has shipped"; c.text = "Your package is on its way and will arrive Tuesday."; c.actions = ["Archive", "Reply"]; c.postedAt = .now.addingTimeInterval(-300)
            d.notifications = [a, b, c]
            return
        }
        if name == "dropcheck" {
            let w = StatusItemController.shared.button?.window
            try? "window=\(w != nil) view=\(w?.contentView?.registeredDraggedTypes.count ?? -1) delegate=\(w?.delegate === StatusItemController.shared)"
                .write(to: dir.appendingPathComponent("drop.txt"), atomically: true, encoding: .utf8); return
        }
        if name == "bannerdebug" {
            let ok = BannerCenter.shared.show(Banner(id: "dbg", thread: "dbg", icon: .symbol("ladybug", .gray), title: "Debug", lifetime: 5))
            try? "enabled=\(BannerCenter.enabled) canShow=\(PopupHost.shared.canShow) button=\(StatusItemController.shared.button != nil) visible=\(StatusItemController.shared.button?.window?.isVisible ?? false) shown=\(ok) count=\(BannerCenter.shared.banners.count) selected=\(model.selectedDevice?.name ?? "nil") phoneOn=\(Notifier.isOn(.phone))".write(to: dir.appendingPathComponent("bannerdebug.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name.hasPrefix("banner:"), let d = model.selectedDevice {
            // banner:<kind> fires a real notification of that kind through Notifier.
            switch name.dropFirst(7) {
            case "msg":
                var n = PhoneNotification(id: "fb\(Int.random(in: 1...999999))"); n.appName = "WhatsApp"; n.title = "Alex"
                n.text = ["Are we still on for dinner tonight?", "I'll be 10 minutes late", "Should I book the table?"].randomElement()!
                n.replyId = "r1"; n.actions = ["Mark as read"]
                Notifier.shared.phoneNotification(n, device: d)
            case "mail":
                var n = PhoneNotification(id: "fm\(Int.random(in: 1...999999))"); n.appName = "Gmail"; n.title = "Your order has shipped"
                n.text = "Your package is on its way and will arrive Tuesday."; n.actions = ["Archive", "Reply"]
                Notifier.shared.phoneNotification(n, device: d)
            case "code": Notifier.shared.verificationCode("482913", from: "Example Bank", device: d, copied: false)
            case "ping": Notifier.shared.ping(from: d, message: "")
            case "missed": Notifier.shared.call(event: "missedCall", number: "+12025550143", contactName: "", device: d)
            case "link": Notifier.shared.received(URL(string: "https://www.apple.com/macbook-pro/")!, device: d)
            case "battery": Notifier.shared.batteryLow(14, device: d)
            case "clear": BannerCenter.shared.banners.map(\.id).forEach { BannerCenter.shared.dismiss($0) }
            default: break
            }
            return
        }
        // TV remote (R39): open it (and capture the window), keys, pairing, state.
        if name.hasPrefix("tvremote:"), let d = AppModel.shared.devices.first(where: { $0.id == String(name.dropFirst(9)) }) {
            TVRemoteWindow.shared.show(d)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if let w = TVRemoteWindow.shared.window { debugCapture(w, "tvremote") } }
            return
        }
        if name == "tvremoteshot" { if let w = TVRemoteWindow.shared.window { debugCapture(w, "tvremote") }; return }
        if name == "tvremoteclose" { TVRemoteWindow.shared.window?.close(); return }
        if name.hasPrefix("tv"), let d = AppModel.shared.devices.first(where: \.isTV) {
            let r = TVRemote.of(d)
            let arg = name.split(separator: ":").dropFirst().joined(separator: ":")
            switch name.split(separator: ":").first {
            case "tvkey": if let code = Int64(arg), let k = TVRemote.Key(rawValue: code) { r.press(k) }
            case "tvopen": r.open(arg)
            case "tvtype": r.type(arg)
            case "tvpair": r.startPairing()
            case "tvcode": r.submitCode(arg)
            case "tvapps": TVApps.shared.request(d)
            default: break
            }
            debugLog("tv: \(r.status) users \(r.users) main \(NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }) volume \(r.volume.map(String.init) ?? "-")/\(r.volumeMax.map(String.init) ?? "-") muted \(r.muted) power \(r.powerOn.map { "\($0)" } ?? "-") app \(r.appPackage ?? "-") apps \(TVApps.shared.apps(for: d.id).count)")
            return
        }
        // sendfile:<device id>:<path>: send through the app's normal path, then log the transfer every second.
        if name.hasPrefix("sendfile:") {
            let parts = name.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let d = AppModel.shared.devices.first(where: { $0.id == parts[1] }) else { return }
            d.share([URL(fileURLWithPath: parts[2])])
            for i in 1...15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) {
                    if let t = TransferStore.shared.items.first(where: { $0.direction == .sent }) {
                        debugLog("transfer \(t.name): \(t.state) \(t.bytesDone)/\(t.size ?? -1) at \(Int(t.speed / 1024)) KB/s")
                    }
                }
            }
            return
        }
        if name.hasPrefix("welcome") {   // welcome or welcome:<page 0-4>: show it (and capture)
            WelcomeWindow.shared.window?.close()
            let page = Int(name.split(separator: ":").dropFirst().first ?? "") ?? 0
            WelcomeWindow.shared.show(page: WelcomeView.Page(rawValue: page) ?? .hello)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if let w = WelcomeWindow.shared.window { debugCapture(w, "welcome") } }
            return
        }
        if name == "updatecheck" {
            Task {
                await Updater.shared.check(userInitiated: true)
                debugLog("update: \(Updater.shared.state)")
                try? await Task.sleep(for: .seconds(1))
                if let w = NSApp.windows.first(where: { $0.title == "Software Update" }) { debugCapture(w, "update") }
            }
            return
        }
        if name == "updateinstall", case .available(let r) = Updater.shared.state {
            Task {
                await Updater.shared.install(r)
                debugLog("update: \(Updater.shared.state)")   // only reached when it failed
                if let w = NSApp.windows.first(where: { $0.title == "Software Update" }) { debugCapture(w, "update") }
            }
            return
        }
        if name == "panelshot" {
            // The real panel window, as composited on screen (glass included).
            StatusItemController.shared.showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let w = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible && $0.frame.height > 120 }) else {
                    debugLog("panelshot: no panel among \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) \(Int($0.frame.height))" })")
                    return
                }
                if light {
                    w.appearance = NSAppearance(named: .aqua)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { debugCapture(w, "panelshot"); w.appearance = nil; StatusItemController.shared.closePanel() }
                    return
                }
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
                   let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(w.windowNumber), 8)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("panelshot.png"))
                }
                StatusItemController.shared.closePanel()
            }
            return
        }
        if name.hasPrefix("mainshot:"), let pane = Pane(rawValue: String(name.dropFirst(9))) {
            // The real main window at the owner's size (1000×614), as composited on screen.
            SceneActions.showMainWindow(pane)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
                w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: 1000, height: 614)), display: true)
                w.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { debugCapture(w, "mainshot") }
            }
            return
        }
        if name == "sidebarsample" {
            // Apple's stock sidebar, for reference.
            let view = NavigationSplitView {
                List(selection: .constant("Calendar")) {
                    ForEach(["Overview", "Calendar", "Messages", "Notifications"], id: \.self) { t in
                        Label(t, systemImage: ["Overview": "iphone.gen3", "Calendar": "calendar", "Messages": "message.fill", "Notifications": "bell.badge.fill"][t]!).tag(t)
                    }
                }
                .navigationSplitViewColumnWidth(220)
            } detail: { Text("Detail").frame(maxWidth: .infinity, maxHeight: .infinity) }
                .toolbar { ToolbarItem { Button { } label: { Image(systemName: "gearshape") } }; ToolbarItem { Button { } label: { Image(systemName: "arrow.clockwise") } } }
                .navigationTitle("Calendar").navigationSubtitle("Subtitle")
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.setContentSize(NSSize(width: 700, height: 360)); w.title = "Sample"; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { debugCapture(w, "sidebarsample"); w.close() }
            return
        }
        if name == "clickicon" {
            StatusItemController.shared.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                try? "panel=\(StatusItemController.shared.isPanelShown)".write(to: dir.appendingPathComponent("click.txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        if name == "expandstack" { BannerCenter.shared.expanded = true; return }
        if name == "mirrorpreview", let d = model.selectedDevice {
            MirrorController.shared.previewWindow(d)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "mirror" }) { debugCapture(w, "mirrorpreview"); w.close() }
            }
            return
        }
        if name == "circletest" {
            // Which glass circle is a true circle? A thin red circle is drawn over each.
            func ref() -> some View { Circle().stroke(Color.red, lineWidth: 1).frame(width: 120, height: 120).allowsHitTesting(false) }
            let view = HStack(spacing: 30) {
                VStack { Image(systemName: "bell").font(.system(size: 44)).frame(width: 120, height: 120).glassEffect(.regular.interactive(), in: Circle()).overlay(ref()); Text("glassEffect") }
                VStack { Image(systemName: "bell").font(.system(size: 44)).frame(width: 120, height: 120).glassEffect(.regular.interactive(), in: Circle()).clipShape(Circle()).overlay(ref()); Text("+ clip") }
                VStack { Button {} label: { Image(systemName: "bell").font(.system(size: 22)).frame(width: 46, height: 46) }.buttonStyle(.glass).buttonBorderShape(.circle).overlay(ref()); Text(".glass circle") }
                VStack { Image(systemName: "bell").font(.system(size: 22)).frame(width: 60, height: 60).background(Circle().fill(.gray.opacity(0.4))).overlay(ref()); Text("plain Circle") }
            }.padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 36))   // on a glass surface, like the panel
            .padding(30)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Circles"; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { debugCapture(w, "circletest"); w.close() }
            return
        }
        if name == "stackstate" {
            let cards = [CallPopup.shared.call != nil ? "call" : nil, MacPopup.shared.content.map { "mac(\($0.title))" },
                         ReceivePopup.shared.isActive ? "file" : nil].compactMap { $0 } + CalendarPopup.shared.cards.map { "calendar(\($0.title))" }
                + BannerCenter.shared.banners.map { "banner(\($0.title)\($0.count > 1 ? " ×\($0.count)" : ""))" }
            try? "shown=\(PopupHost.shared.isShown) panel=\(StatusItemController.shared.isPanelShown) cards=\(cards)".write(to: dir.appendingPathComponent("stack.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "stackshot", let w = PopupHost.shared.window, light {
            w.appearance = NSAppearance(named: .aqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { debugCapture(w, "stack"); w.appearance = nil }
            return
        }
        if name == "stackshot", let w = PopupHost.shared.window {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(w.windowNumber), 8)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("stack.png"))
            }
            return
        }
        if name == "endcall" { CallPopup.shared.close(); return }
        if name == "dismisscal", let e = CalendarPopup.shared.cards.first { CalendarPopup.shared.dismiss(e); return }
        if name == "macmsg" { MacPopup.shared.show(.init(symbol: "safari.fill", tint: .blue, title: "Link sent", subtitle: "Opening on your phone")); return }
        if name == "popupstate" {
            try? MacPopup.shared.debugState.write(to: dir.appendingPathComponent("popupstate.txt"), atomically: true, encoding: .utf8); return
        }
        if name == "macstate" {
            try? MacState.text.write(to: dir.appendingPathComponent("macstate.txt"), atomically: true, encoding: .utf8); return
        }
        if name == "popupshot" {
            if let w = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible && $0.frame.height < 200 }),
               let v = w.contentView?.superview ?? w.contentView { write(v, file: "macpopup") }
            return
        }
        if name == "wake" { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared); return }
        if name == "events" {
            try? model.events.reversed().map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.kind)] \($0.text)" }.joined(separator: "\n")
                .write(to: dir.appendingPathComponent("events.txt"), atomically: true, encoding: .utf8)
            return
        }
        if name == "time" {
            timeSwitches(model: model)
            return
        }
        if name == "sidebar" {
            render(Sidebar().environment(model).frame(width: 240, height: 520), size: nil, file: what)
            return
        }
        if name == "panel" {
            render(MenuBarPanel().environment(model), size: nil, file: what)
            return
        }
        if name.hasPrefix("tall:"), let pane = Pane(rawValue: String(name.dropFirst(5))) {
            model.section = pane
            render(MainWindow().environment(model), size: NSSize(width: 1040, height: UserDefaults.standard.double(forKey: "debug.tallHeight") > 0 ? UserDefaults.standard.double(forKey: "debug.tallHeight") : 1150), file: "tall", titled: true)
            return
        }
        if let pane = Pane(rawValue: name) { model.section = pane }
        render(MainWindow().environment(model), size: NSSize(width: 1040, height: 700), file: what, titled: true)
    }

    /// Switches the real window through every pane, forcing layout + display synchronously, and logs the cost.
    static func timeSwitches(model: AppModel) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
              let root = window.contentView else { return }
        var log = ""
        let order: [Pane] = [.overview, .messages, .notifications, .media, .files, .remote, .messages, .overview]
        for pane in order {
            let t0 = CACurrentMediaTime()
            model.section = pane
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            CATransaction.flush()
            log += String(format: "%-14@ %7.1f ms\n", pane.rawValue as NSString, (CACurrentMediaTime() - t0) * 1000)
        }
        try? log.write(to: dir.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
    }

    /// Reports what view receives clicks along the sidebar, then synthesizes a click on each row.
    static func probe(model: AppModel) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
              let frame = window.contentView?.superview else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        var log = "canBecomeKey=\(window.canBecomeKey) keyWindow=\(String(describing: NSApp.keyWindow?.identifier?.rawValue)) style=\(window.styleMask.rawValue)\n"
        // Direct selection through the sidebar's NSOutlineView (bypasses mouse/activation).
        func find(_ v: NSView) -> NSOutlineView? {
            if let o = v as? NSOutlineView { return o }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        if let outline = find(frame) {
            log += "outline rows=\(outline.numberOfRows) selected=\(outline.selectedRow) allowsEmpty=\(outline.allowsEmptySelection) enabled=\(outline.isEnabled)\n"
            for row in 0..<outline.numberOfRows {
                let before = model.section?.rawValue ?? "nil"
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                log += "select row \(row): \(before) -> \(model.section?.rawValue ?? "nil") (outline.selectedRow=\(outline.selectedRow))\n"
            }
            // Real mouse path into the table: queue the mouse-up, then deliver mouse-down to the outline view.
            outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            for row in 3..<outline.numberOfRows {
                let r = outline.rect(ofRow: row)
                let inWindow = outline.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
                let before = model.section?.rawValue ?? "nil"
                func ev(_ t: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let up = ev(.leftMouseUp), let down = ev(.leftMouseDown) {
                    NSApp.postEvent(up, atStart: false)
                    outline.mouseDown(with: down)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                log += "mouse row \(row): \(before) -> \(model.section?.rawValue ?? "nil")\n"
            }
        } else { log += "no outline view found\n" }
        log += "window key=\(window.isKeyWindow) main=\(window.isMainWindow) ignoresMouse=\(window.ignoresMouseEvents) policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive)\n"
        log += "windows: " + NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")[\(type(of: $0)) lvl=\($0.level.rawValue) vis=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))]" }.joined(separator: ", ") + "\n"
        let h = frame.bounds.height
        for y in stride(from: 40.0, through: min(h - 10, 520), by: 30) {
            let pt = NSPoint(x: 110, y: h - y)          // x inside sidebar, y from top
            var chain: [String] = []
            var v = frame.hitTest(pt)
            while let cur = v, chain.count < 6 { chain.append(String(describing: type(of: cur))); v = cur.superview }
            log += String(format: "y=%3.0f ", y) + chain.joined(separator: " < ") + "\n"
        }
        // Synthesized clicks down the sidebar; record the selected pane after each.
        for y in stride(from: 100.0, through: 480, by: 20) {
            let before = model.section?.rawValue ?? "nil"
            let loc = NSPoint(x: 110, y: h - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            log += String(format: "click y=%3.0f: %@ -> %@\n", y, before, model.section?.rawValue ?? "nil")
        }
        try? log.write(to: dir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
    }

    /// Clicks down the New Message sheet (real mouse events) and records how many recipients get picked.
    static func composeProbe() {
        guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
              let sheet = main.attachedSheet, let root = sheet.contentView else {
            try? "no sheet".write(to: dir.appendingPathComponent("compose.txt"), atomically: true, encoding: .utf8); return
        }
        var log = "sheet \(Int(root.bounds.width))x\(Int(root.bounds.height)) key=\(sheet.isKeyWindow)\n"
        log += "query length: \(ComposeModel.current?.query.count ?? -1), recipients: \(ComposeModel.current?.recipients.count ?? -1)\n"
        write(root, file: "compose-before")
        let h = root.bounds.height
        for y in stride(from: 100.0, through: 300, by: 14) {
            let before = ComposeModel.current?.recipients.count ?? -1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 140, y: h - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    sheet.sendEvent(e)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            log += String(format: "click y=%3.0f: recipients %d -> %d\n", y, before, ComposeModel.current?.recipients.count ?? -1)
        }
        write(root, file: "compose-after")
        try? log.write(to: dir.appendingPathComponent("compose.txt"), atomically: true, encoding: .utf8)
    }

    private static func render<V: View>(_ content: V, size: NSSize?, file: String, titled: Bool = false) {
        let host = NSHostingView(rootView: content)
        let fitting = size ?? host.fittingSize
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: fitting),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            write(window.contentView?.superview ?? host, file: file)
            window.orderOut(nil)
        }
    }

    private static func write(_ view: NSView, file: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file + ".png"))
    }
}

import VideoToolbox
/// Decodes one frame with VideoToolbox and saves it as PNG (checks the decode path without screen capture).
enum DebugFrame {
    static func save(_ sample: CMSampleBuffer, to url: URL) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        guard let session else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else {
                try? "decode status \(status)".write(to: url.appendingPathExtension("txt"), atomically: true, encoding: .utf8); return
            }
            let ci = CIImage(cvPixelBuffer: image)
            let rep = NSBitmapImageRep(ciImage: ci)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

}

/// A window as composited on screen (glass included); an app may capture its own windows.
@MainActor func debugCapture(_ w: NSWindow, _ file: String) {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
          let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(w.windowNumber), 8)?.takeRetainedValue() else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: DebugSnapshot.dir.appendingPathComponent(file + ".png"))
}

/// Appends a line to snapshots/debug.log (testing aid).
@MainActor func debugLog(_ line: String) {
    let url = DebugSnapshot.dir.appendingPathComponent("debug.log")
    let text = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
    else { try? text.write(to: url, atomically: true, encoding: .utf8) }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for v in subviews { if let t = v as? T { return t }; if let t = v.firstDescendant(of: type) { return t } }
        return nil
    }
}
