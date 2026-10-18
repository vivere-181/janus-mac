import Charts
import ServiceManagement
import SwiftUI
import UserNotifications

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @State private var encryption = ""
    @State private var showSecurity = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Link", symbol: "point.3.connected.trianglepath.dotted") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            row("Transport", device.isReachable ? device.transport : "—")
                            row("Phone address", device.addresses.isEmpty ? "—" : device.addresses.joined(separator: ", "), mono: true)
                            row("This Mac", model.macAddresses.isEmpty ? "—" : model.macAddresses.joined(separator: ", "), mono: true)
                            row("Mac's name on phone", model.announcedName.isEmpty ? "—" : model.announcedName)
                        }
                    }
                    Card(title: "Session", symbol: "clock") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                Text("Connected for").foregroundStyle(.secondary)
                                if let since = device.connectedSince {
                                    Text(since, style: .relative).monospacedDigit()
                                } else { Text("—") }
                            }
                            GridRow {
                                Text("Last seen").foregroundStyle(.secondary)
                                if device.isReachable { Text("Now") }
                                else if let seen = device.lastSeen { Text(seen.formatted(date: .omitted, time: .shortened)) }
                                else { Text("—") }
                            }
                            row("Drops this session", "\(device.disconnects)")
                            GridRow {
                                Text("Engine running for").foregroundStyle(.secondary)
                                if let start = model.engineStartedAt {
                                    Text(start, style: .relative).monospacedDigit()
                                } else { Text("—") }
                            }
                        }
                    }
                }
                latencyCard
                ReliabilityCard()
                Card(title: "Connection Types", symbol: "switch.2") {
                    ForEach(model.linkProviders, id: \.name) { p in
                        LabeledContent(p.title) {
                            Toggle(p.title, isOn: Binding(get: { p.enabled }, set: { model.setLinkProvider(p.name, enabled: $0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
                Card(title: "Security", symbol: "lock.shield") {
                    HStack {
                        Text("Verification key").foregroundStyle(.secondary)
                        Text(device.verificationKey).monospaced().textSelection(.enabled)
                        Spacer()
                        Button(showSecurity ? "Hide Details" : "Show Details") {
                            showSecurity.toggle()
                            if showSecurity && encryption.isEmpty { Task { encryption = await device.encryptionInfo() } }
                        }
                        .buttonStyle(.link)
                    }
                    if showSecurity {
                        Text(encryption.isEmpty ? "Loading…" : encryption)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    Text("The connection is encrypted with TLS. The same key is shown on your phone when pairing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Connection")
    }

    private var statusCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(statusColor.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: device.isReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: model.isReconnecting)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(device.isReachable ? "Connected to \(device.name)" : "\(device.name) is not connected")
                    .font(.title2.weight(.semibold))
                Text(model.isReconnecting ? (model.reconnectNote ?? "Reconnecting…")
                     : (model.reconnectNote ?? (device.isReachable ? device.statusText : "Click Reconnect, or open Janus on the phone.")))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ReconnectButton(prominent: !device.isReachable)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private var latencyCard: some View {
        Card(title: "Latency", symbol: "waveform.path.ecg") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let ms = device.latencyMs {
                    Text(String(format: "%.0f", ms)).font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("ms").foregroundStyle(.secondary)
                    Text(quality(ms)).font(.callout.weight(.medium)).foregroundStyle(qualityColor(ms)).padding(.leading, 8)
                } else {
                    Text(device.isReachable ? "Measuring…" : "—").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                if device.packetLoss > 0 {
                    Label("\(device.packetLoss) of last \(device.latencyHistory.count) pings lost", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            let points = Array(device.latencyHistory.enumerated()).filter { $0.element >= 0 }
            if points.count >= 2 {
                Chart(points, id: \.offset) { p in
                    AreaMark(x: .value("Sample", p.offset), y: .value("ms", p.element))
                        .foregroundStyle(.teal.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Sample", p.offset), y: .value("ms", p.element))
                        .foregroundStyle(.teal)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 90)
            }
            Text("Measured every 10 seconds. Phones in power-saving mode can respond slowly; that's normal.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color { device.isReachable ? .green : .orange }

    private func quality(_ ms: Double) -> String { ms < 60 ? "Excellent" : ms < 150 ? "Good" : ms < 400 ? "Fair" : "Slow" }
    private func qualityColor(_ ms: Double) -> Color { ms < 60 ? .green : ms < 150 ? .teal : ms < 400 ? .orange : .red }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(mono ? .body.monospaced() : .body).textSelection(.enabled)
        }
    }

}

private struct ReliabilityCard: View {
    @Environment(AppModel.self) private var model
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var notificationsDenied = false

    var body: some View {
        Card(title: "Staying Connected", symbol: "bolt.horizontal.circle") {
            HStack(spacing: 10) {
                Image(systemName: loginStatus == .enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(loginStatus == .enabled ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loginStatus == .enabled ? "Opens automatically at login" : "Not set to open at login")
                    if loginStatus != .enabled {
                        Text(loginStatus == .requiresApproval
                             ? "Allow “Janus” under Login Items in System Settings."
                             : "Without this, the phone won't reconnect after a restart until you open Janus.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if loginStatus == .requiresApproval {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                } else if loginStatus != .enabled {
                    Button("Turn On") {
                        try? SMAppService.mainApp.register()
                        loginStatus = SMAppService.mainApp.status
                    }
                }
            }
            if notificationsDenied {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications are off")
                        Text("You won't see phone notifications, calls or received files on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Turn On…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Automatically reconnects after sleep, after Wi-Fi changes, and every 30 seconds while the phone is missing. Restarts the connection engine if it ever stops.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Recent Activity").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Show Full Log") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL]) }
                    .buttonStyle(.link)
            }
            if model.events.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.events.prefix(8)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(e.kind == .success ? Color.green : e.kind == .warning ? .orange : .secondary)
                            .frame(width: 6, height: 6)
                        Text(e.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(e.text).font(.callout)
                    }
                }
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .task {
            let st = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = st.authorizationStatus == .denied
        }
    }
}

struct ReconnectButton: View {
    @Environment(AppModel.self) private var model
    var prominent = false
    var compact = false
    /// In a window toolbar: the toolbar styles it (Liquid Glass group).
    var inToolbar = false

    var body: some View {
        Button { model.reconnect() } label: {
            if compact {
                // The system's rotate effect stops reliably; a repeatForever animation can keep
                // redrawing after it's switched off.
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeating, isActive: model.isReconnecting)
            } else if model.isReconnecting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reconnecting…") }
            } else {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
        }
        .disabled(model.isReconnecting)
        .modifier(ProminentIf(prominent, plain: compact, toolbar: inToolbar))
        .help("Look for the phone again; restarts the connection engine if needed")
    }
}

private struct ProminentIf: ViewModifier {
    let on: Bool
    let plain: Bool
    var toolbar = false
    init(_ on: Bool, plain: Bool, toolbar: Bool = false) { self.on = on; self.plain = plain; self.toolbar = toolbar }
    func body(content: Content) -> some View {
        if toolbar { content }
        else if plain { content.buttonStyle(.borderless) }
        else if on { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

/// Status line at the bottom of the sidebar: live state, latency and a one-click reconnect.
