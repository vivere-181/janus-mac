import AppKit
import SwiftUI

/// The TV's remote (R39), in the spirit of Apple's Siri Remote: what's on the TV and Power at the top, a round
/// clickpad (click the centre for OK, the edges for arrows, or swipe on the trackpad), the keys, volume at the TV's
/// own level, and the TV's apps. While it's in front, the Mac's keyboard works the TV too (arrows, Return, Esc…).
struct TVRemoteView: View {
    enum Layout { case compact, wide, panel }

    let device: Device
    var layout: Layout = .compact
    @State private var typing = false
    @FocusState private var focused: Bool
    @Environment(\.closePanel) private var closePanel

    private var remote: TVRemote { TVRemote.of(device) }

    var body: some View {
        Group {
            switch layout {
            case .compact: compact
            case .wide: wide
            case .panel: panel
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { handle($0) }
        .onAppear {
            remote.activate()
            focused = true
        }
        .onDisappear { remote.deactivate() }
        .onChange(of: remote.status) { _, status in
            guard status == .connected else { return }
            // The apps come from Janus on the TV; wake it if it isn't connected (TCL TVs stop it in the background).
            if !device.isReachable { remote.open("janus://hello") }
            if TVApps.shared.apps(for: device.id).isEmpty || !device.isReachable {
                Task { try? await Task.sleep(for: .seconds(device.isReachable ? 0 : 4)); TVApps.shared.request(device) }
            }
        }
    }

    // MARK: Layouts

    private var compact: some View {
        VStack(spacing: 18) {
            NowOnTV(device: device, remote: remote)
            if remote.isConnected {
                controls
                AppStrip(device: device, remote: remote)
            } else {
                RemoteStateView(remote: remote)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 320)
        .animation(.snappy(duration: 0.25), value: remote.status)
    }

    private var wide: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Metrics.gap) {
                VStack(spacing: 18) {
                    NowOnTV(device: device, remote: remote)
                    if remote.isConnected { controls } else { RemoteStateView(remote: remote).frame(minHeight: 380) }
                }
                .padding(Metrics.padding)
                .frame(width: 340)
                .cardBackground()
                VStack(spacing: Metrics.gap) {
                    Card(title: "Apps", symbol: "square.grid.2x2") {
                        AppGrid(device: device, remote: remote)
                    }
                    Card(title: "Keyboard", symbol: "keyboard") {
                        ShortcutList()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Remote")
    }

    /// In the menu bar panel: a smaller clickpad with the main keys beside it, and the volume.
    private var panel: some View {
        Group {
            if remote.isConnected {
                VStack(spacing: 14) {
                    Clickpad(remote: remote, size: 156)
                        .frame(width: 156, height: 156)
                    HStack(spacing: 18) {
                        RemoteKey(symbol: "chevron.backward", help: "Back (Esc)", size: 40) { remote.press(.back) }
                        RemoteKey(symbol: "house", help: "Home (H)", size: 40) { remote.press(.home) }
                        RemoteKey(symbol: "playpause.fill", help: "Play/Pause (Space)", size: 40) { remote.press(.playPause) }
                        VoiceKey(remote: remote, size: 40)
                    }
                    VoiceLine(remote: remote)
                    VolumeRow(remote: remote)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    if remote.status == .needsPairing {
                        Image(systemName: "av.remote").foregroundStyle(.secondary)
                        Text("Pair to use this Mac as a remote.").foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Pair…") { closePanel(); TVRemoteWindow.shared.show(device) }.controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(remote.status == .notReachable ? "\(device.name) isn't reachable" : "Connecting to the remote…")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                .font(.callout)
            }
        }
        .animation(.snappy(duration: 0.2), value: remote.status)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            Clickpad(remote: remote)
                .frame(width: 216, height: 216)
            KeyGrid(remote: remote, typing: $typing)
            VoiceLine(remote: remote)
            if typing {
                TypeField(remote: remote) { typing = false; focused = true }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            VolumeRow(remote: remote)
        }
        .animation(.snappy(duration: 0.2), value: typing)
    }

    // MARK: The Mac's keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard remote.isConnected, !typing else { return .ignored }
        let key: TVRemote.Key?
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .return: key = .ok
        case .escape, .delete: key = .back
        case .space: key = .playPause
        default:
            switch press.characters.lowercased() {
            case "h": key = .home
            case "+", "=": key = .volumeUp
            case "-": key = .volumeDown
            case "m": key = .mute
            case "i": remote.showInputs(); return .handled
            case "k": typing = true; return .handled
            default: key = nil
            }
        }
        guard let key else { return .ignored }
        remote.press(key)
        return .handled
    }
}

// MARK: Header

/// What's on the TV (its banner and name, live) and Power.
private struct NowOnTV: View {
    let device: Device
    let remote: TVRemote

    var body: some View {
        let apps = TVApps.shared
        let package = remote.isConnected ? remote.appPackage : nil
        HStack(spacing: 12) {
            Group {
                if let package, let banner = apps.banner(for: package, deviceID: device.id) {
                    Image(nsImage: banner).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Image(systemName: "tv").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(package.map { apps.label(for: $0, deviceID: device.id) } ?? device.name)
                    .font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { remote.press(.power) } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(remote.isConnected ? Color.red : Color.secondary)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!remote.isConnected)
            .help(remote.powerOn == false ? "Turn the TV on" : "Turn the TV off")
        }
        .animation(.snappy, value: remote.appPackage)
    }

    private var subtitle: String {
        switch remote.status {
        case .connected: remote.appPackage == nil ? "Remote ready" : device.name
        case .connecting, .idle: "Connecting…"
        case .notReachable: "TV not reachable"
        case .needsPairing, .pairing: "Not paired"
        case .failed: "Remote unavailable"
        }
    }
}

// MARK: Clickpad

/// A round clickpad: the centre is OK, the ring's edges are the arrows. Swipes on the trackpad (or dragging, or the
/// scroll wheel) step the arrows, one step per stretch.
private struct Clickpad: View {
    let remote: TVRemote
    var size: CGFloat = 216
    @State private var pressed: ClickpadSurface.Zone?

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            Circle().strokeBorder(.separator, lineWidth: 1)
            Circle().fill(pressed == .ok ? AnyShapeStyle(Color.janus.opacity(0.35)) : AnyShapeStyle(.quinary))
                .frame(width: size * 0.39, height: size * 0.39)
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            ForEach([ClickpadSurface.Zone.up, .down, .left, .right], id: \.self) { zone in
                Image(systemName: zone.symbol)
                    .font(.system(size: max(11, size * 0.07), weight: .bold))
                    .foregroundStyle(pressed == zone ? Color.primary : Color.secondary)
                    .offset(zone.offset(radius: size * 0.36))
            }
            ClickpadSurface(pressed: $pressed) { remote.press($0.key) }
        }
        .help("Click the centre for OK and the edges to move; swipe on the trackpad to move")
    }
}

/// The clickpad's mouse and trackpad handling (SwiftUI has no scroll-wheel events).
private struct ClickpadSurface: NSViewRepresentable {
    enum Zone: Hashable {
        case ok, up, down, left, right
        var key: TVRemote.Key {
            switch self { case .ok: .ok; case .up: .up; case .down: .down; case .left: .left; case .right: .right }
        }
        var symbol: String {
            switch self { case .ok: "circle"; case .up: "chevron.up"; case .down: "chevron.down"; case .left: "chevron.left"; case .right: "chevron.right" }
        }
        func offset(radius r: CGFloat) -> CGSize {
            switch self { case .ok: .zero; case .up: CGSize(width: 0, height: -r); case .down: CGSize(width: 0, height: r)
            case .left: CGSize(width: -r, height: 0); case .right: CGSize(width: r, height: 0) }
        }
    }

    @Binding var pressed: Zone?
    let send: (Zone) -> Void

    func makeNSView(context: Context) -> Surface {
        let v = Surface()
        v.pressedChanged = { pressed = $0 }
        v.send = send
        return v
    }

    func updateNSView(_ v: Surface, context: Context) {
        v.pressedChanged = { pressed = $0 }
        v.send = send
    }

    final class Surface: NSView {
        var pressedChanged: ((Zone?) -> Void)?
        var send: ((Zone) -> Void)?
        private var dragOrigin: NSPoint?
        private var dragged = false
        private var scroll = CGPoint.zero
        private let step: CGFloat = 46

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func zone(at p: NSPoint) -> Zone? {
            let c = NSPoint(x: bounds.midX, y: bounds.midY), r = min(bounds.width, bounds.height) / 2
            let dx = p.x - c.x, dy = p.y - c.y, d = hypot(dx, dy)
            guard d <= r else { return nil }
            if d < r * 0.4 { return .ok }
            if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
            return (isFlipped ? dy < 0 : dy > 0) ? .up : .down
        }

        override func mouseDown(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            dragOrigin = p
            dragged = false
            pressedChanged?(zone(at: p))
        }

        override func mouseDragged(with e: NSEvent) {
            guard let origin = dragOrigin else { return }
            let p = convert(e.locationInWindow, from: nil)
            let dx = p.x - origin.x, dy = (isFlipped ? origin.y - p.y : p.y - origin.y)
            guard max(abs(dx), abs(dy)) > step else { return }
            dragged = true
            pressedChanged?(nil)
            let z: Zone = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
            send?(z)
            dragOrigin = p
        }

        override func mouseUp(with e: NSEvent) {
            defer { dragOrigin = nil; pressedChanged?(nil) }
            guard !dragged, let z = zone(at: convert(e.locationInWindow, from: nil)) else { return }
            send?(z)
        }

        /// Trackpad swipes step with the fingers (natural scrolling or not); a mouse wheel steps a notch at a time.
        override func scrollWheel(with e: NSEvent) {
            guard e.momentumPhase.isEmpty else { return }   // only while the fingers are down
            if !e.hasPreciseScrollingDeltas {
                if e.scrollingDeltaY != 0 { send?(e.scrollingDeltaY > 0 ? .up : .down) }
                else if e.scrollingDeltaX != 0 { send?(e.scrollingDeltaX > 0 ? .left : .right) }
                return
            }
            if e.phase == .began { scroll = .zero }
            // Where the fingers went (right and down positive), whatever the scrolling direction setting.
            let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
            scroll.x += e.scrollingDeltaX * sign
            scroll.y += e.scrollingDeltaY * sign
            while abs(scroll.x) >= step || abs(scroll.y) >= step {
                if abs(scroll.x) >= abs(scroll.y) {
                    send?(scroll.x > 0 ? .right : .left); scroll.x -= scroll.x > 0 ? step : -step; scroll.y = 0
                } else {
                    send?(scroll.y > 0 ? .down : .up); scroll.y -= scroll.y > 0 ? step : -step; scroll.x = 0
                }
            }
        }
    }
}

// MARK: Keys

private struct KeyGrid: View {
    let remote: TVRemote
    @Binding var typing: Bool

    var body: some View {
        Grid(horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow {
                RemoteKey(symbol: "chevron.backward", help: "Back (Esc)") { remote.press(.back) }
                RemoteKey(symbol: "house", help: "Home (H)") { remote.press(.home) }
                RemoteKey(symbol: "playpause.fill", help: "Play/Pause (Space)") { remote.press(.playPause) }
            }
            GridRow {
                VoiceKey(remote: remote)
                RemoteKey(symbol: "rectangle.portrait.and.arrow.forward", help: "Inputs (I)") { remote.showInputs() }
                RemoteKey(symbol: "keyboard", help: "Type on the TV (K)", active: typing) { typing.toggle() }
            }
        }
    }
}

private struct RemoteKey: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 54
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.31, weight: .semibold))
                .foregroundStyle(active ? Color.janusOn : Color.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AnyShapeStyle(Color.janus.gradient) : AnyShapeStyle(.quaternary)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}

/// Hold to talk to the TV's assistant.
private struct VoiceKey: View {
    let remote: TVRemote
    var size: CGFloat = 54
    @State private var holding = false

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: size * 0.31, weight: .semibold))
            .foregroundStyle(remote.listening ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(remote.listening ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(.quaternary)))
            .scaleEffect(holding ? 0.92 : 1)
            .symbolEffect(.pulse, isActive: remote.listening)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; remote.beginVoice() } }
                .onEnded { _ in holding = false; remote.endVoice() })
            .animation(.snappy(duration: 0.15), value: holding)
            .help("Hold and speak, then let go: the TV's assistant does it")
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Typing into the TV's focused text field: each change replaces what's there; Return submits.
private struct TypeField: View {
    let remote: TVRemote
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type on the TV", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: text) { _, value in remote.type(value) }
                .onSubmit { remote.press(.enter) }
                .onExitCommand { done() }
            Button("Done", action: done).controlSize(.small)
        }
        .onAppear { focused = true }
    }
}

// MARK: Volume

/// The TV's volume at its own level (it follows the TV); dragging steps it there, as a TV only takes up/down.
private struct VolumeRow: View {
    let remote: TVRemote
    @State private var dragging: Double?

    var body: some View {
        let max = Double(Swift.max(1, remote.volumeMax ?? 100))
        HStack(spacing: 10) {
            Button { remote.press(.mute) } label: {
                Image(systemName: remote.muted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 20)
                    .foregroundStyle(remote.muted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(remote.muted ? "Unmute (M)" : "Mute (M)")
            Slider(value: Binding(get: { dragging ?? Double(remote.volume ?? 0) }, set: { dragging = $0 }), in: 0...max) { editing in
                if !editing, let target = dragging {
                    remote.stepVolume(Int(target.rounded()) - (remote.volume ?? 0))
                    dragging = nil
                }
            }
            .disabled(remote.volume == nil)
            Text(remote.volume.map(String.init) ?? "–")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: Apps

private struct AppTile: View {
    let label: String
    let banner: NSImage?
    var tint: Color = .gray
    var width: CGFloat = 112
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let banner {
                        Image(nsImage: banner).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Text(label).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(tint.gradient)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.6 : 0.08), lineWidth: hovering ? 2 : 1))
                .scaleEffect(hovering ? 1.04 : 1)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: width)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help("Open \(label) on the TV")
    }
}

/// YouTube and Netflix first (they open even without Janus on the TV), then the TV's other apps.
private func orderedApps(_ apps: [TVApps.App]) -> [(package: String, label: String, banner: NSImage?, tint: Color)] {
    let favourites: [(String, String, Color)] = [("com.google.android.youtube.tv", "YouTube", Color(red: 1, green: 0, blue: 0.2)),
                                                 ("com.netflix.ninja", "Netflix", Color(white: 0.08))]
    var out = favourites.map { f in
        let app = apps.first { $0.package == f.0 }
        return (package: f.0, label: app?.label ?? f.1, banner: app?.banner, tint: f.2)
    }
    out += apps.filter { a in !favourites.contains { $0.0 == a.package } }.map { (package: $0.package, label: $0.label, banner: $0.banner, tint: Color.gray) }
    return out
}

private struct AppStrip: View {
    let device: Device
    let remote: TVRemote

    var body: some View {
        let apps = orderedApps(TVApps.shared.apps(for: device.id))
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(apps, id: \.package) { app in
                    AppTile(label: app.label, banner: app.banner, tint: app.tint, width: 104) { remote.openApp(app.package) }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(width: 280)
    }
}

private struct AppGrid: View {
    let device: Device
    let remote: TVRemote

    var body: some View {
        let apps = orderedApps(TVApps.shared.apps(for: device.id))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 14) {
            ForEach(apps, id: \.package) { app in
                AppTile(label: app.label, banner: app.banner, tint: app.tint, width: 120) { remote.openApp(app.package) }
            }
        }
        if apps.count <= 2 {
            Text(device.isReachable ? "Loading the TV's apps…" : "The TV's other apps show here when Janus on the TV is connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutList: View {
    private let rows: [(String, String)] = [("← ↑ → ↓", "Move"), ("Return", "OK"), ("Esc", "Back"), ("H", "Home"),
                                            ("Space", "Play/Pause"), ("+  −", "Volume"), ("M", "Mute"), ("I", "Inputs"), ("K", "Type")]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key).font(.callout.monospaced()).foregroundStyle(.primary)
                    Text(action).foregroundStyle(.secondary)
                }
            }
        }
        Text("While the remote is in front.").font(.caption).foregroundStyle(.tertiary)
    }
}

// MARK: Not connected: pairing, finding the TV

private struct RemoteStateView: View {
    let remote: TVRemote
    @State private var code = ""

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            switch remote.status {
            case .needsPairing:
                header("Use this Mac as a remote", "Pair once: \(remote.name) shows a code to type here.")
                Button("Pair…") { code = ""; remote.startPairing() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .pairing(.starting):
                header("Pairing with \(remote.name)", "Waiting for the TV…")
                ProgressView().controlSize(.small)
            case .pairing(.enterCode(let wrong)):
                header("Enter the code", "Type the code shown on \(remote.name).")
                CodeEntry(code: $code) { remote.submitCode($0) }
                if wrong { Text("That code didn't work. Check the TV and try again.").font(.caption).foregroundStyle(.orange) }
                Text("Letters A–F and digits 0–9.").font(.caption).foregroundStyle(.tertiary)
                Button("Cancel") { remote.cancelPairing() }.controlSize(.small)
            case .pairing(.checking):
                header("Pairing with \(remote.name)", "Checking the code…")
                ProgressView().controlSize(.small)
            case .notReachable:
                header("\(remote.name) isn't reachable", "Turn the TV on, and check it's on this Wi-Fi.")
                ProgressView().controlSize(.small)
            case .failed(let message):
                header("Remote unavailable", message)
                Button("Try Again") { remote.cancelPairing() }
            default:
                header("Connecting to \(remote.name)…", "")
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func header(_ title: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "av.remote").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            if !text.isEmpty { Text(text).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// Six character slots, like a verification code: typing fills them (letters A–F and digits, uppercased); the
/// sixth sends the code once.
private struct CodeEntry: View {
    @Binding var code: String
    let submit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // The real field, invisible: it takes the typing (and pasting).
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, value in
                    let clean = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6))
                    if clean != value { code = clean; return }
                    if clean.count == 6 { submit(clean) }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .frame(width: 34, height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(focused && i == min(chars.count, 5) ? Color.janus : Color.clear, lineWidth: 2))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
        .help("Type the code shown on the TV")
    }
}

/// While holding the voice button: what this Mac hears; then what was sent (or why voice isn't available).
private struct VoiceLine: View {
    let remote: TVRemote

    var body: some View {
        Group {
            if let problem = remote.voiceProblem {
                Label(problem, systemImage: "mic.slash").foregroundStyle(.orange)
            } else if remote.listening {
                Text(remote.heard.isEmpty ? "Listening…" : "“\(remote.heard)”").foregroundStyle(.primary)
            } else if !remote.heard.isEmpty {
                Label("“\(remote.heard)”", systemImage: "checkmark").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .animation(.snappy(duration: 0.2), value: remote.heard)
    }
}
