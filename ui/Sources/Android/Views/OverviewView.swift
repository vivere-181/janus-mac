import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.gap) {
                hero
                if let call = device.activeCall {
                    Card(title: "Call", symbol: "phone.fill") { ActiveCallRow(device: device, call: call) }
                }
                if !device.visibleLive.isEmpty {
                    Card(title: "Live", symbol: "dot.radiowaves.left.and.right") {
                        VStack(spacing: 14) {
                            ForEach(device.visibleLive) { LiveActivityRow(activity: $0, compact: false) }
                        }
                    }
                }
                if device.has("mprisremote"), device.media.hasTrack {
                    Card(title: "Now Playing", symbol: "play.circle") {
                        MiniPlayer(device: device, artSize: 52)
                    }
                    .onTapGesture(count: 2) { model.section = .media }
                }
                if !device.isTV { phoneCards }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    /// Transfers, notifications and messages: a phone's (a TV has none, R38).
    @ViewBuilder private var phoneCards: some View {
                RecentTransfersStrip { model.section = .files }
                    .padding(.horizontal, 4)
                HStack(alignment: .top, spacing: Metrics.gap) {
                    if device.has("notifications") {
                        Card(title: "Recent Notifications", symbol: "bell") {
                            // On the phone first, then the last 24 hours.
                            let recent = Array((device.notifications.sorted { $0.postedAt > $1.postedAt }
                                + NotificationHistory.shared.earlier(for: device).map(\.asNotification)).prefix(3))
                            if recent.isEmpty {
                                Text("No notifications").foregroundStyle(.secondary)
                            } else {
                                ForEach(recent) { n in
                                    NotificationRow(device: device, notification: n, compact: true)
                                }
                                Button("Show All") { model.section = .notifications }.buttonStyle(.link)
                            }
                        }
                    }
                    if device.has("sms") {
                        Card(title: "Recent Messages", symbol: "message") {
                            let recent = device.sortedConversations.prefix(3)
                            if recent.isEmpty {
                                Text("Loading conversations…").foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(recent)) { m in
                                    ConversationRow(device: device, message: m, compact: true)
                                }
                                Button("Open Messages") { model.section = .messages }.buttonStyle(.link)
                            }
                        }
                    }
                }
    }

    /// Two equal columns: the phone on the left, what you can do with it on the right. The pills inside
    /// the phone card wrap to fit, so this works down to the window's minimum width.
    private var hero: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            DeviceHeroCard(device: device, dropTargeted: $dropTargeted)
                .frame(maxWidth: .infinity)
            if device.isTV {
                ScreenShareCard(device: device)
                    .frame(maxWidth: .infinity)
            } else if device.isReachable {
                ControlCenterCard(device: device)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The phone: its drawing on a soft glow in the phone's own color, name, model and colour, a row of
/// status pills (battery, connection, signal, address) and the quick actions. Drop files on it to send.
struct DeviceHeroCard: View {
    let device: Device
    @Binding var dropTargeted: Bool
    @State private var textHeight: CGFloat = 150

    var body: some View {
        let look = DeviceLook.of(device)
        let _ = device.lookVersion
        // Wide: a big phone as tall as the text beside it. Narrow: a small phone next to the name and
        // the stats full width underneath, so nothing is ever cut off.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                art(look, height: textHeight)
                VStack(alignment: .leading, spacing: 14) {
                    header(look)
                    stats
                }
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = min(190, max(90, $0)) }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    art(look, height: 64)
                    header(look)
                }
                stats
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A faint wash of the phone's colour across the card.
            LinearGradient(colors: [glow(look).opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .cardBackground(highlight: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !device.isTV else { return false }   // a TV doesn't take files
            device.share(urls.filter(\.isFileURL)); return true
        } isTargeted: { dropTargeted = $0 && !device.isTV }
        .help(device.isTV ? "" : "Drop files here to send them to \(device.name)")
    }

    private func art(_ look: DeviceLook, height: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [glow(look).opacity(0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: height * 0.6))
                .frame(width: height * 1.2, height: height * 1.2)
                .blur(radius: height > 100 ? 10 : 5)
            DeviceArt(device: device, height: height, dimmed: !device.isReachable)
        }
        .frame(width: height * look.aspect, height: height)
    }

    private func header(_ look: DeviceLook) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(subtitle(look))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// "Galaxy S25 · Navy", "Pixel 9 Pro · Android 16": the real model (and the colour when it's an official one).
    private func subtitle(_ look: DeviceLook) -> String {
        if device.isTV { return "Android TV" }
        guard device.type == "phone" else { return device.type.capitalized }
        let model = device.modelName ?? "Android phone"
        if look.shape != .front { return "\(model) · \(look.finish.title)" }
        if let release = device.profile?.release { return "\(model) · Android \(release)" }
        return model
    }

    private func glow(_ look: DeviceLook) -> Color { look.glow }

    private struct Stat: Identifiable {
        let label: String, symbol: String, value: String
        var tint: Color? = nil
        var bars: Int? = nil
        var id: String { label }
    }

    /// Only what's known: the phone reports Wi-Fi name, carrier, storage and version (R24) when it can.
    private var statItems: [Stat] {
        guard device.isReachable else {
            return [Stat(label: "Status", symbol: "exclamationmark.circle", value: device.statusText)]
        }
        let st = device.status
        var items: [Stat] = []
        if device.has("battery"), let c = device.batteryCharge {
            items.append(Stat(label: "Battery", symbol: BatteryView(charge: c, charging: device.isCharging).symbol,
                              value: device.isCharging ? "\(c)% · Charging" : "\(c)%", tint: device.isCharging ? .green : nil))
        }
        if let free = st?.storageFree, let total = st?.storageTotal, total > 0 {
            // Whole gigabytes read better here than "27,58 GB of 106,8 GB".
            let f = "\(Int((Double(free) / 1e9).rounded())) GB", t = "\(Int((Double(total) / 1e9).rounded())) GB"
            items.append(Stat(label: "Storage", symbol: "internaldrive", value: "\(f) of \(t) free"))
        }
        let wifi = device.transport.hasPrefix("Wi-Fi")
        let latency = device.latencyMs.map { " · \(Int($0)) ms" } ?? ""
        items.append(Stat(label: wifi ? "Wi-Fi" : "Connection", symbol: wifi ? "wifi" : "dot.radiowaves.left.and.right",
                          value: (st?.ssid ?? (wifi ? "Connected" : device.transport)) + latency))
        let type = st?.cellular ?? (["", "unknown"].contains(device.networkType.lowercased()) ? nil : device.networkType)
        let cell = [st?.carrier, type].compactMap { $0 }.joined(separator: " · ")
        if !cell.isEmpty || (device.has("connectivity_report") && device.networkStrength >= 0) {
            items.append(Stat(label: "Cellular", symbol: "antenna.radiowaves.left.and.right",
                              value: cell.isEmpty ? "Signal" : cell,
                              bars: device.networkStrength >= 0 ? device.networkStrength : nil))
        }
        if let os = st?.os { items.append(Stat(label: "Software", symbol: "gearshape.2", value: os)) }
        return items
    }

    static func duration(_ since: Date) -> String {
        let m = max(0, Int(Date().timeIntervalSince(since) / 60))
        return m < 1 ? "Just now" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    /// One row per stat, label left and value right, like an About page.
    private var stats: some View {
        TimelineView(.everyMinute) { _ in
            VStack(spacing: 7) {
                ForEach(statItems) { stat($0) }
            }
        }
    }

    private func stat(_ s: Stat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.symbol)
                .font(.callout)
                .foregroundStyle(s.tint ?? .secondary)
                .frame(width: 18)
            Text(s.label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 16)
            if let bars = s.bars { SignalView(strength: bars, type: "").foregroundStyle(.secondary) }
            Text(s.value).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }
}

/// Everything you can do with the phone, laid out like Control Center: quick actions, then the
/// phone's sound mode, Do Not Disturb and flashlight as modules.
struct ControlCenterCard: View {
    let device: Device


    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            QuickActions(device: device, alignment: .center)
            if device.status?.ringer != nil || device.status?.flashlight != nil || device.phoneDND != nil {
                Spacer(minLength: Metrics.gap)
                Divider()
                Spacer(minLength: Metrics.gap)
                VStack(spacing: 10) {
                    if let ringer = device.status?.ringer { soundMode(ringer) }
                    tiles
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
        .animation(.snappy(duration: 0.22), value: device.status)
        .animation(.snappy(duration: 0.22), value: device.phoneDND)
    }

    /// Do Not Disturb and Flashlight tiles: side by side when their titles fit, stacked otherwise.
    private var tiles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tileViews }
            VStack(spacing: 10) { tileViews }
        }
    }

    @ViewBuilder private var tileViews: some View {
        if let dnd = device.phoneDND {
            ModuleTile(title: "Do Not Disturb", subtitle: dnd ? "On" : "Off",
                       symbol: "moon.fill", on: dnd, tint: .indigo) {
                device.setPhoneDND(!dnd, reason: "Overview")
            }
        }
        if let light = device.status?.flashlight {
            ModuleTile(title: "Flashlight", subtitle: light ? "On" : "Off",
                       symbol: light ? "flashlight.on.fill" : "flashlight.off.fill", on: light, tint: .yellow) {
                device.setFlashlight(!light)
            }
        }
    }


    /// Ring / Vibrate / Silent as one capsule with a sliding selection.
    @Namespace private var soundNS
    private func soundMode(_ current: String) -> some View {
        HStack(spacing: 2) {
            ForEach([("normal", "Ring", "bell.fill"), ("vibrate", "Vibrate", "iphone.gen3.radiowaves.left.and.right"),
                     ("silent", "Silent", "bell.slash.fill")], id: \.0) { mode, title, symbol in
                let selected = current == mode
                Button { device.setRinger(mode) } label: {
                    Label(title, systemImage: symbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.janusOn : Color.primary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background {
                            if selected {
                                Capsule().fill(Color.janus.gradient).matchedGeometryEffect(id: "sel", in: soundNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
    }
}

/// A Control Center module: round icon (filled with its color when on), title and state.
struct ModuleTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let on: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    /// Concentric with the card where it can be, never squarer than a Control Center module.
    static let shape = ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Self.shape)
        .onHover { hovering = $0 }
        .help(on ? "Turn off \(title)" : "Turn on \(title)")
    }
}
