import AppKit
import SwiftUI

/// Starts and stops mirroring and owns the mirror window (which also hosts the one-time setup).
@MainActor @Observable
final class MirrorController {
    static let shared = MirrorController()

    enum State: Equatable {
        case idle
        /// One-time pairing: waiting for the phone's "Pair with code" screen, then for the code.
        case setup(found: AdbServiceFinder.Service?, busy: Bool, error: String?)
        case connecting(String)
        case mirroring
        case failed(String)
    }

    enum Quality: String, CaseIterable, Identifiable {
        case smooth, balanced, sharp
        var id: String { rawValue }
        var title: String {
            switch self { case .smooth: "Smoothest"; case .balanced: "Balanced"; case .sharp: "Sharpest" }
        }
        func apply(to o: inout MirrorSession.Options) {
            switch self {
            case .smooth: o.maxSize = 1280; o.bitRate = 6_000_000
            case .balanced: o.maxSize = 1920; o.bitRate = 12_000_000
            case .sharp: o.maxSize = 0; o.bitRate = 20_000_000
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var deviceID: String?
    /// A typical 20:9 phone until the phone's profile or the stream tells its real shape.
    private(set) var videoSize = CGSize(width: 1080, height: 2400)

    // Preferences (changing sound or quality restarts the stream; the screen toggle applies at once).
    var soundOnMac = UserDefaults.standard.object(forKey: "mirror.sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOnMac, forKey: "mirror.sound"); restartSession() }
    }
    /// Like iPhone Mirroring: the phone's own screen stays dark while it's used from the Mac (default on).
    var phoneScreenOff = UserDefaults.standard.object(forKey: "mirror.keepScreenOff") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(phoneScreenOff, forKey: "mirror.keepScreenOff")
            if state == .mirroring, !phoneAsleep { session?.setDisplayPower(!phoneScreenOff) }
        }
    }
    /// The phone went to sleep (its power button, or a timeout): the window offers to wake it.
    private(set) var phoneAsleep = false
    var quality = Quality(rawValue: UserDefaults.standard.string(forKey: "mirror.quality") ?? "") ?? .balanced {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "mirror.quality"); restartSession() }
    }

    @ObservationIgnored private(set) var session: MirrorSession?
    @ObservationIgnored private var link: (adb: ADB, serial: String)?
    @ObservationIgnored private var reconnects: [Date] = []
    @ObservationIgnored private var powerWatch: Task<Void, Never>?
    @ObservationIgnored private var audio: MirrorAudioPlayer?
    var audioDebug: String { audio.map { "played=\($0.played) dropped=\($0.dropped) underruns=\($0.underruns) peak=\($0.peak)" } ?? "off" }
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var pasteboardCount = 0
    @ObservationIgnored private var phoneClipboard: String?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var finder: AdbServiceFinder?
    @ObservationIgnored private var relay: MirrorRelay?
    @ObservationIgnored private var prepareReply: CheckedContinuation<String?, Never>?
    @ObservationIgnored let view = MirrorVideoView()

    var isActive: Bool {
        switch state { case .idle, .failed: false; default: true }
    }

    var device: Device? { AppModel.shared.devices.first { $0.id == deviceID } }

    func toggle(_ device: Device) {
        if isActive, deviceID == device.id { stop() } else { start(device) }
    }

    func start(_ device: Device) {
        stop()
        reconnects = []
        deviceID = device.id
        // Open at the phone's own shape (until the stream says otherwise).
        if let screen = device.profile?.screen { videoSize = CGSize(width: screen.w, height: screen.h) }
        showWindow(title: device.name)
        connect(device)
    }

    // MARK: Setup (pairing)

    private func beginSetup() {
        state = .setup(found: nil, busy: false, error: nil)
        let f = AdbServiceFinder()
        finder = f
        f.start(type: AdbServiceFinder.pairing) { [weak self] services in
            guard let self, case .setup(_, let busy, let error) = self.state, let device = self.device else { return }
            // This phone's pairing service, matched by its Wi-Fi address.
            let match = services.first { device.addresses.contains($0.host) } ?? (services.count == 1 ? services[0] : nil)
            self.state = .setup(found: match, busy: busy, error: error)
        }
    }

    func pair(code: String) {
        guard case .setup(let found?, _, _) = state, let device else { return }
        state = .setup(found: found, busy: true, error: nil)
        Task {
            if let error = await MirrorLink.pair(found, code: code) {
                state = .setup(found: found, busy: false, error: error)
                return
            }
            finder?.stop(); finder = nil
            state = .connecting("Paired. Connecting…")
            guard let (serial, relay) = await MirrorLink.connect(host: found.host) else {
                state = .failed("Paired, but the phone didn't accept the connection. Try again.")
                return
            }
            self.relay = relay
            await MirrorLink.grantPhonePermission(serial: serial)
            MirrorLink.setPaired(device, true)
            device.command("mirror:paired")
            AppModel.shared.log(.success, "Paired \(device.name) for mirroring")
            await startSession(device, adb: .wifi, serial: serial)
        }
    }

    // MARK: Connecting

    /// `resuming`: the stream dropped and this reconnects it (the phone still shows "Mirroring"; a failure ends it).
    private func connect(_ device: Device, resuming: Bool = false) {
        state = .connecting(resuming ? "Reconnecting…" : "Connecting to \(device.name)…")
        Task {
            @MainActor func fail(_ message: String) {
                state = .failed(message)
                if resuming { device.command("mirror:stopped"); device.command("mirror:done") }
            }
            guard ADB.executable != nil else { fail(MirrorError.adbMissing.localizedDescription); return }
            // A phone plugged in by USB needs nothing else (and is the fastest link), unless the owner
            // wants Wi-Fi only (e.g. when the cable is only for charging).
            let usb = UserDefaults.standard.bool(forKey: "mirror.wifiOnly") ? [] : await ADB.usb.devices()
            for serial in usb where !serial.contains(":") {
                if let ip = await ADB.usb.wifiAddress(serial: serial), device.addresses.contains(ip) {
                    await startSession(device, adb: .usb, serial: serial, resuming: resuming)
                    return
                }
            }
            // Over Wi-Fi the Mac must be paired first (one time).
            guard MirrorLink.isPaired(device) else { beginSetup(); return }
            guard let host = device.addresses.first(where: { !$0.contains(":") }) else {
                fail("\(device.name) isn't on Wi-Fi."); return
            }
            // Ask the phone to switch Wireless debugging on (it answers "ready" or "failed:<reason>"). After a drop,
            // adb on the phone is gone while the setting still says on, so it has to be switched off and on again.
            var reply = await askPhone(device, resuming ? "mirror:restart" : "mirror:prepare")
            if resuming, reply == nil {
                // A phone app without "restart": "done" switches it off (when the phone switched it on), "prepare" on.
                device.command("mirror:done")
                try? await Task.sleep(for: .seconds(1))
                reply = await askPhone(device, "mirror:prepare")
                device.command("mirror:started")   // "done" took the phone's Mirroring notification away
            }
            if let reply, reply.hasPrefix("failed:") {
                fail(String(reply.dropFirst(7)))
                return
            }
            if !resuming { state = .connecting("Connecting to \(device.name)…") }
            guard let (serial, relay) = await MirrorLink.connect(host: host) else {
                fail("Couldn't reach \(device.name). Make sure Wireless debugging is on, then try again.")
                return
            }
            self.relay = relay
            await startSession(device, adb: .wifi, serial: serial, resuming: resuming)
        }
    }

    /// Sends `command` ("mirror:prepare" or "mirror:restart") and waits for the phone's answer (nil: none in 6 s).
    private func askPhone(_ device: Device, _ command: String) async -> String? {
        device.command(command)
        return await withCheckedContinuation { cont in
            prepareReply = cont
            Task {
                try? await Task.sleep(for: .seconds(6))
                // No answer (e.g. an older phone app): try to connect anyway.
                if let c = prepareReply { prepareReply = nil; c.resume(returning: nil) }
            }
        }
    }

    /// Companion messages from the phone: "ready", "failed:<reason>" (to prepare) or "stop" (its notification).
    func phoneMessage(_ text: String, from device: Device) {
        guard device.id == deviceID else { return }
        if text == "stop" { stop(); return }
        if let c = prepareReply { prepareReply = nil; c.resume(returning: text) }
    }

    /// `restart`: new preferences on the same connection. `resuming`: after the connection dropped.
    private func startSession(_ device: Device, adb: ADB, serial: String, restart: Bool = false, resuming: Bool = false) async {
        link = (adb, serial)
        if !restart { Task { await MirrorLink.grantPhonePermission(serial: serial, adb: adb) } }
        state = .connecting(restart ? "Updating…" : resuming ? "Reconnecting…" : "Starting…")
        var options = MirrorSession.Options()
        options.audio = soundOnMac
        options.screenOff = phoneScreenOff
        // Awake while mirroring (a phone idle on the desk would otherwise sleep after its usual timeout).
        options.screenOffTimeout = 30 * 60 * 1000
        quality.apply(to: &options)
        let s = MirrorSession(adb: adb, serial: serial, options: options)
        s.onVideoSize = { size in
            Task { @MainActor in
                self.resize(to: size)
                // What the phone is, for phones that don't send a profile (scrcpy reports the model).
                if let d = self.device { DeviceProfiles.learnFromMirror(model: s.deviceName, screen: size, device: d) }
            }
        }
        s.onSample = { [view] sample in view.enqueue(sample) }
        s.onClipboard = { text in Task { @MainActor in self.receivedPhoneClipboard(text) } }
        s.onEnd = { error in Task { @MainActor in if self.session === s { self.ended(error) } } }
        if soundOnMac {
            let player = MirrorAudioPlayer()
            player.start()
            audio = player
            s.onAudio = { data in player.play(data) }
        }
        session = s
        view.session = s
        do {
            try await s.start()
            guard session === s else { return }
            state = .mirroring
            phoneAsleep = false
            watchMacClipboard()
            watchPower(adb: adb, serial: serial)
            if resuming {
                AppModel.shared.log(.info, "Mirroring reconnected")
            } else if !restart {
                device.command("mirror:started")
                AppModel.shared.log(.info, "Mirroring \(device.name)\(adb.port == ADB.usb.port ? " over USB" : "")")
            }
        } catch {
            if session === s { ended(error) }
        }
    }

    /// Starts the stream again with the current preferences, on the same connection.
    private func restartSession() {
        guard state == .mirroring, let link, let device else { return }
        endSession()
        Task { await startSession(device, adb: link.adb, serial: link.serial, restart: true) }
    }

    private func endSession() {
        powerWatch?.cancel()
        powerWatch = nil
        phoneAsleep = false
        session?.stop()
        session = nil
        view.session = nil
        audio?.stop()
        audio = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    // MARK: Phone asleep

    /// Notices the phone going to sleep (power button, or its timeout) and waking up (e.g. picked up).
    private func watchPower(adb: ADB, serial: String) {
        powerWatch?.cancel()
        powerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let r = await adb.run(["-s", serial, "shell", "dumpsys power | grep -m1 mWakefulness="], timeout: 5)
                guard !Task.isCancelled, let self, self.state == .mirroring, r.output.contains("mWakefulness=") else { continue }
                let asleep = !r.output.contains("Awake")
                if asleep != self.phoneAsleep { self.phoneAsleep = asleep }
            }
        }
    }

    /// Wakes the phone from the Mac; its screen stays dark if Keep Phone Screen Off is on.
    func wake() {
        guard let session else { return }
        session.press(224)   // KEYCODE_WAKEUP
        phoneAsleep = false
        guard phoneScreenOff else { return }
        Task {
            // The screen comes on with the wake-up; turn it off again once it has.
            for delay in [0.4, 1.2] {
                try? await Task.sleep(for: .seconds(delay))
                self.session?.setDisplayPower(false)
            }
        }
    }

    // MARK: Clipboard

    /// Copies on the phone land on the Mac right away while mirroring.
    private func receivedPhoneClipboard(_ text: String) {
        phoneClipboard = text
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) != text else { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pasteboardCount = pb.changeCount
    }

    /// Copies on the Mac go to the phone (unless clipboard sync is off for it; ⌘V in the window still pastes).
    private func watchMacClipboard() {
        pasteboardCount = NSPasteboard.general.changeCount
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pb = NSPasteboard.general
                guard pb.changeCount != self.pasteboardCount else { return }
                self.pasteboardCount = pb.changeCount
                guard self.device?.clipboardAutoShareDisabled != true,
                      let text = pb.string(forType: .string), text != self.phoneClipboard else { return }
                self.phoneClipboard = text
                self.session?.setClipboard(text, paste: false)
            }
        }
    }

    // MARK: Stop

    func stop() {
        finder?.stop(); finder = nil
        if let c = prepareReply { prepareReply = nil; c.resume(returning: nil) }
        let wasMirroring = session != nil
        endSession()
        if let link, link.adb.port == ADB.wifi.port {
            Task.detached { _ = await ADB.wifi.run(["disconnect", link.serial], timeout: 5) }
        }
        relay?.stop()
        relay = nil
        link = nil
        view.flush()
        if wasMirroring, let device {
            device.command("mirror:stopped")
            device.command("mirror:done")
            AppModel.shared.log(.info, "Mirroring stopped")
        }
        state = .idle
        let w = window
        window = nil
        w?.close()
    }

    private func ended(_ error: Error?) {
        let wasMirroring = session != nil
        endSession()
        // The stream dropped (e.g. some phones restart adb when they lock or unlock): reconnect by itself,
        // a few times a minute at most, keeping the last picture up meanwhile.
        if error != nil, wasMirroring, let device, device.isPaired, device.isReachable {
            reconnects = reconnects.filter { $0.timeIntervalSinceNow > -60 }
            if reconnects.count < 3 {
                reconnects.append(.now)
                AppModel.shared.log(.info, "Mirroring connection lost; reconnecting")
                if let link, link.adb.port == ADB.wifi.port {
                    Task.detached { _ = await ADB.wifi.run(["disconnect", link.serial], timeout: 5) }
                }
                relay?.stop()
                relay = nil
                link = nil
                state = .connecting("Reconnecting…")
                Task {
                    // adb on the phone needs a moment to come back.
                    try? await Task.sleep(for: .seconds(2))
                    guard state == .connecting("Reconnecting…"), deviceID == device.id else { return }
                    connect(device, resuming: true)
                }
                return
            }
        }
        if wasMirroring, let device { device.command("mirror:stopped"); device.command("mirror:done") }
        if let error {
            state = .failed(error.localizedDescription)
            AppModel.shared.log(.warning, "Mirroring: \(error.localizedDescription)")
        } else {
            stop()
        }
    }

    /// Testing aid: the window in its "couldn't connect" state, without touching a phone.
    func previewWindow(_ device: Device) {
        deviceID = device.id
        showWindow(title: device.name)
        state = .failed("Couldn't reach \(device.name). Make sure Wireless debugging is on, then try again.")
    }

    // MARK: Window

    private func showWindow(title: String) {
        if let window { window.title = title; window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let host = NSHostingController(rootView: MirrorWindowContent(controller: self).tint(.janus))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.identifier = NSUserInterfaceItemIdentifier("mirror")
        let options = NSTitlebarAccessoryViewController()
        options.layoutAttribute = .trailing
        let menu = NSHostingView(rootView: MirrorOptionsMenu(controller: self))
        menu.frame.size = menu.fittingSize
        options.view = menu
        w.addTitlebarAccessoryViewController(options)
        window = w
        resize(to: videoSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window === w else { return }
                self.window = nil
                self.stop()
            }
        }
    }

    /// Keeps the window at the phone's aspect ratio (plus the title bar). A new window is about 80% of the
    /// screen tall; afterwards the phone keeps its on-screen size, and when it turns, the window turns with it
    /// around the same center.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let rotated = (size.width > size.height) != (videoSize.width > videoSize.height)
        videoSize = size
        guard let window, let content = window.contentView else { return }
        // The title bar sits above the phone's screen.
        let bar = window.frame.height - window.contentLayoutRect.height
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        // The content view spans the whole window (full-size content under the transparent title bar).
        let current = content.frame.size
        let longSide = current.height > 200
            ? max(current.width, current.height - bar)
            : screen.height * 0.8 - bar
        var width = size.width >= size.height ? longSide : longSide * size.width / size.height
        var height = width * size.height / size.width
        let fit = min(1, screen.width * 0.9 / width, (screen.height * 0.9 - bar) / height)
        width *= fit
        height *= fit

        let target = NSSize(width: width.rounded(), height: (height + bar).rounded())
        window.contentAspectRatio = target
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        frame = window.constrainFrameRect(frame, to: window.screen)
        window.setFrame(frame, display: true, animate: rotated)
    }

    func home() { session?.press(3) }   // KEYCODE_HOME
}

/// The window's content: the phone's screen under the title bar, with setup and status on top of it.
/// Navigation uses the phone's own gestures (drag up from the bottom edge, in from a side) and right-click = Back.
struct MirrorWindowContent: View {
    let controller: MirrorController

    var body: some View {
        ZStack {
            MirrorVideoRepresentable(view: controller.view)
            switch controller.state {
            case .setup(let found, let busy, let error):
                MirrorSetupView(controller: controller, found: found, busy: busy, error: error)
            case .connecting(let message):
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(message).foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 24)
                    if let d = controller.device { Button("Try Again") { controller.start(d) } }
                }
            case .mirroring where controller.phoneAsleep:
                // Covers the (frozen) picture; a click anywhere wakes the phone.
                ZStack {
                    Color.black.opacity(0.72)
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("\(controller.device?.name ?? "Your phone") is asleep").font(.headline)
                        Button("Wake") { controller.wake() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { controller.wake() }
            default:
                EmptyView()
            }
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
    }
}

/// Sound, phone screen and quality, in the window's title bar.
struct MirrorOptionsMenu: View {
    @Bindable var controller: MirrorController

    var body: some View {
        Menu {
            Toggle("Play Sound on Mac", isOn: $controller.soundOnMac)
            Toggle("Keep Phone Screen Off", isOn: $controller.phoneScreenOff)
            Section("Quality") {
                Picker("Quality", selection: $controller.quality) {
                    ForEach(MirrorController.Quality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mirroring Options")
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }
}

/// One-time pairing, inside the mirror window.
struct MirrorSetupView: View {
    let controller: MirrorController
    let found: AdbServiceFinder.Service?
    let busy: Bool
    let error: String?
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set Up Mirroring", systemImage: "rectangle.on.rectangle").font(.title3.weight(.semibold))
            Text("One time only. On your phone:").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                step(1, developerOptionsStep)
                step(2, "Tap **Pair device with pairing code**")
                step(3, "Type the 6-digit code shown on the phone here")
            }
            .font(.callout)
            Divider()
            if let found {
                Label("Found your phone (\(found.host))", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                HStack(spacing: 8) {
                    TextField("Pairing code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.title3, design: .monospaced))
                        .focused($focused)
                        .onSubmit(submit)
                        .onAppear { focused = true }
                    Button(busy ? "Pairing…" : "Pair", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || code.filter(\.isNumber).count != 6)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for the pairing screen on your phone…").foregroundStyle(.secondary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(16)
    }

    private var vendor: DeviceProfile.Vendor? { controller.device?.profile?.vendor }

    /// Where Wireless debugging is on this phone's maker's Settings.
    private var developerOptionsStep: LocalizedStringKey {
        switch vendor {
        case .samsung: "Settings → Developer options → **Wireless debugging** (on)"
        case .google: "Settings → System → Developer options → **Wireless debugging** (on)"
        default: "Settings → Developer options (on some phones under System) → **Wireless debugging** (on)"
        }
    }

    private var hint: LocalizedStringKey {
        let unlock: String = switch vendor {
        case .samsung: "Settings → About phone → Software information"
        default: "Settings → About phone"
        }
        let base = "No Developer options? In \(unlock), tap **Build number** 7 times."
        // Samsung's Auto Blocker keeps Wireless debugging off.
        return vendor == .samsung
            ? LocalizedStringKey(base + " If Wireless debugging won't turn on, switch off **Auto Blocker** (Settings → Security and privacy).")
            : LocalizedStringKey(base)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                .background(Color.janus.opacity(0.25), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        controller.pair(code: digits)
    }
}
