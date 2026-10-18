import AppKit
import SwiftUI

/// The menu bar icon. Also opens the main window on request, since it's the one view that is always alive.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// 13 pt tall: the height of the system's own menu bar symbols (Spotlight, Control Center), so it sits among them.
    static let icon = icon(height: 13)

    static func icon(height: CGFloat) -> NSImage {
        let bundled = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")
        if let url = bundled, let img = NSImage(contentsOf: url) {
            // The Janus arch at its own proportions.
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            img.size = NSSize(width: (height * aspect).rounded(), height: height)
            img.isTemplate = true
            return img
        }
        let img = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "Janus")!
        img.isTemplate = true
        return img
    }

    var body: some View {
        Image(nsImage: Self.icon)
            .opacity(model.connectedDevices.isEmpty ? 0.5 : 1)
            .onChange(of: model.wantsMainWindow, initial: true) { _, wants in
                guard wants else { return }
                model.wantsMainWindow = false
                model.mainWindowOpens += 1
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuBarPanel: View {
    static let inset: CGFloat = 14
    @Environment(AppModel.self) private var model
    @State private var headerDrop = false
    @Environment(\.closePanel) private var closePanel

    var body: some View {
        VStack(spacing: 0) {
            if let device = model.selectedDevice, device.isPaired {
                // The phone (name doubles as the device switcher), then one row of controls.
                // One spacing value around and between the header and the buttons.
                VStack(spacing: Self.inset) {
                    PanelHeader(device: device)
                    if device.isReachable, !device.isTV { PanelControls(device: device) }
                }
                .padding(Self.inset)
                .background(headerDrop ? Color.janus.opacity(0.15) : .clear)
                .dropDestination(for: URL.self) { urls, _ in
                    guard !device.isTV else { return false }   // a TV doesn't take files
                    device.share(urls.filter(\.isFileURL)); return true
                } isTargeted: { headerDrop = $0 && !device.isTV }
                if device.isTV {
                    // The TV's remote, right here (R39); it talks to the TV directly.
                    TVRemoteView(device: device, layout: .panel)
                        .padding(.horizontal, Self.inset).padding(.bottom, Self.inset)
                    if device.isReachable, device.media.hasTrack {
                        PanelSection(title: "Now Playing") { NowPlayingRow(device: device) { open(.media) } }
                    }
                    Divider().padding(.horizontal, 12)
                    VStack(spacing: 0) {
                        MenuRow(symbol: "rectangle.on.rectangle", title: "Screen Mirroring…") {
                            closePanel(); AirPlayMirroring.openDisplaySettings()
                        }
                        MenuRow(symbol: "av.remote", title: "Full Remote") {
                            closePanel(); TVRemoteWindow.shared.show(device)
                        }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 4)
                } else if device.isReachable {
                    sections(device)
                } else {
                    VStack(spacing: 8) {
                        if CloudService.shared.peer(forDevice: device.id) != nil {
                            // Not on this network, but reachable through the owner's relay: files still go.
                            Label("Not on this network · files go through Janus Cloud", systemImage: "icloud")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button { closePanel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { FilePicker.chooseAndSend(to: device) } } label: {
                                    Label("Send Files…", systemImage: "paperplane")
                                }
                                .buttonStyle(.borderedProminent)
                                if device.supports("cloud2") {
                                    // Find My Phone works from anywhere (shared/CLOUD.md §13).
                                    Button { device.ring() } label: { Label("Ring", systemImage: "speaker.wave.2") }
                                        .help("Ring \(device.name) through Janus Cloud")
                                }
                            }
                        } else {
                            Text("Your phone isn't connected right now.").font(.callout).foregroundStyle(.secondary)
                        }
                        ReconnectButton(prominent: CloudService.shared.peer(forDevice: device.id) == nil)
                        if let note = model.reconnectNote, !model.isReconnecting {
                            Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                    CalendarPanelSection()
                }
            } else {
                EmptyPanelState()
                    .padding(20)
            }

            Divider().padding(.horizontal, 12)
            HStack(spacing: 0) {
                MenuRow(symbol: "macwindow", title: "Open Janus") { open(.overview) }
                Menu {
                    if let d = model.selectedDevice, d.isPaired, DeviceTrust.isMine(d), d.supportedPlugins.contains("kdeconnect_clipboard") {
                        // Copying on either device copies on the other; this turns that off for this phone.
                        Toggle("Sync Clipboard with \(d.name)", isOn: Binding(
                            get: { d.enabledPlugins.contains("kdeconnect_clipboard") && !d.clipboardAutoShareDisabled },
                            set: { d.setClipboardAutoSync($0) }))
                        Divider()
                    }
                    Divider()
                    Button("Connection…") { open(.connection) }
                    Button("Settings…") { closePanel(); SceneActions.showSettings() }
                    Button("Reconnect") { model.reconnect() }
                    Divider()
                    Button("Quit Janus") { NSApp.terminate(nil) }
                } label: {
                    MoreButtonLabel()
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More")
            }
            .padding(5)
        }
        .frame(width: 280)
    }

    /// Named sections that appear only when they have something to show.
    @ViewBuilder private func sections(_ device: Device) -> some View {
        if let call = device.activeCall {
            PanelSection(title: "Call") {
                ActiveCallRow(device: device, call: call)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
        }
        if !device.visibleLive.isEmpty {
            PanelSection(title: "Live") {
                VStack(spacing: 10) {
                    ForEach(device.visibleLive) { LiveActivityRow(activity: $0) }
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
        }
        CalendarPanelSection()
        if device.media.hasTrack {
            PanelSection(title: "Now Playing") {
                NowPlayingRow(device: device) { open(.media) }
            }
        }
        let transfers = Array(TransferStore.shared.items.prefix(7))
        if !transfers.isEmpty, !device.isTV {
            PanelSection(title: "Recent Transfers",
                         detail: transfers[0].date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                         action: ("See All", { open(.files) })) {
                RecentTiles(items: transfers)
                    .padding(.horizontal, 9).padding(.bottom, 4)
            }
        }
        let clips = Array(ClipboardHistory.shared.items.prefix(3))
        if !clips.isEmpty, !device.isTV {
            PanelSection(title: "Clipboard", action: ("See All", { open(.clipboard) })) {
                VStack(spacing: 2) {
                    ForEach(clips) { item in
                        Button { ClipboardHistory.shared.copy(item) } label: {
                            ClipboardItemRow(item: item, compact: true)
                                .padding(.horizontal, 14).padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy again (also on the phone)")
                    }
                }
                .padding(.bottom, 4)
            }
        }
        if !device.isTV, device.unreadCount > 0 || !device.notifications.isEmpty {
            PanelSection(title: "Phone") {
                if device.unreadCount > 0 {
                    let n = device.unreadCount
                    MenuRow(symbol: "message", title: n == 1 ? "1 unread message" : "\(n) unread messages") { open(.messages) }
                }
                if !device.notifications.isEmpty {
                    let n = device.notifications.count
                    MenuRow(symbol: "bell", title: n == 1 ? "1 notification" : "\(n) notifications") { open(.notifications) }
                }
            }
        }
    }

    /// Rows that appear only when they have something to say.
    private func contextRows(_ device: Device) -> [ContextRow] {
        var rows: [ContextRow] = []
        if device.media.hasTrack {
            rows.append(ContextRow(id: "media", view: AnyView(NowPlayingRow(device: device) { open(.media) })))
        }
        if let summary = TransferSummary.latest(), Date().timeIntervalSince(summary.date) < 15 * 60 || summary.inProgress {
            rows.append(ContextRow(id: "transfer", view: AnyView(
                MenuRow(leading: AnyView(summary.thumbnail), title: summary.title, detail: summary.detail) { open(.files) })))
        }
        if device.unreadCount > 0 {
            let n = device.unreadCount
            rows.append(ContextRow(id: "sms", view: AnyView(
                MenuRow(symbol: "message", title: n == 1 ? "1 unread message" : "\(n) unread messages") { open(.messages) })))
        }
        if !device.notifications.isEmpty {
            let n = device.notifications.count
            rows.append(ContextRow(id: "notif", view: AnyView(
                MenuRow(symbol: "bell", title: n == 1 ? "1 notification" : "\(n) notifications") { open(.notifications) })))
        }
        return rows
    }

    private func open(_ section: Pane) {
        closePanel()
        SceneActions.showMainWindow(section)
    }
}

private struct ContextRow: Identifiable {
    let id: String
    let view: AnyView
}

/// A macOS-menu-style row: icon, title, optional detail, hover highlight.
struct MenuRow: View {
    var symbol: String? = nil
    var leading: AnyView? = nil
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @State private var hovering = false

    init(symbol: String, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.action = action
    }
    init(leading: AnyView, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.leading = leading; self.title = title; self.detail = detail; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let leading { leading } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.body)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Now playing: one view that morphs between a compact row (paused/stopped) and a rich player
/// (playing). Nothing swaps or slides; the artwork grows and the extra controls fade in below,
/// growing downward together with the popover.
private struct NowPlayingRow: View {
    let device: Device
    let openMedia: () -> Void
    /// Expands at once when playback starts; collapses only after 2 s of real stop, so the brief
    /// "not playing" the phone reports while seeking doesn't make the panel move.
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var hovering = false
    @State private var scrubbing: Double?
    /// Natural height of the scrubber + controls, so the reveal can animate a real height value.
    @State private var extraHeight: CGFloat = 70

    private var m: MediaState { device.media }
    private static let morph = Animation.smooth(duration: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            HStack(spacing: expanded ? 10 : 9) {
                AlbumArt(url: m.artURL, size: expanded ? 44 : 22)
                VStack(alignment: .leading, spacing: expanded ? 1 : 0) {
                    Text(m.title).font(.body.weight(expanded ? .semibold : .regular)).lineLimit(1)
                    let sub = expanded ? [m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " — ") : m.artist
                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if !expanded {
                    // Inline controls only in the compact row (they fade; the title then gets the full width).
                    HStack(spacing: 12) {
                        Button { device.mediaAction("PlayPause") } label: {
                            Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                        }
                        Button { device.mediaAction("Next") } label: { Image(systemName: "forward.fill") }
                    }
                    .font(.body)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openMedia)

            // Always laid out; revealed by animating its height from 0 to its natural height, frame by
            // frame, so the popover grows together with the content (inserting it would report the
            // final size at once and the content would shift inside an already-grown panel).
            VStack(spacing: 8) {
                if m.length > 0 { scrubber }
                HStack(spacing: 0) {
                    control("backward.end.fill", help: "Previous") { device.mediaAction("Previous") }
                    control("gobackward.10", help: "Back 10 seconds", disabled: !m.canSeek) { skip(-10_000) }
                    control(m.isPlaying ? "pause.fill" : "play.fill", help: "Play/Pause", size: 20) { device.mediaAction("PlayPause") }
                    control("goforward.10", help: "Forward 10 seconds", disabled: !m.canSeek) { skip(10_000) }
                    control("forward.end.fill", help: "Next") { device.mediaAction("Next") }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { extraHeight = $0 }
            .frame(height: expanded ? extraHeight : 0, alignment: .top)
            .clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
        }
        .padding(.horizontal, expanded ? 10 : 9)
        .padding(.vertical, expanded ? 10 : 5)
        .background(Color.primary.opacity(expanded ? 0.06 : (hovering ? 0.09 : 0)),
                    in: RoundedRectangle(cornerRadius: expanded ? 10 : 7, style: .continuous))
        .padding(.horizontal, expanded ? 4 : 0).padding(.vertical, expanded ? 3 : 0)
        .onHover { hovering = $0 }
        .onAppear { expanded = m.isPlaying }
        .onChange(of: m.isPlaying) { _, playing in
            collapseTask?.cancel()
            if playing {
                withAnimation(Self.morph) { expanded = true }
            } else {
                collapseTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, !device.media.isPlaying else { return }
                    withAnimation(Self.morph) { expanded = false }
                }
            }
        }
    }

    private var scrubber: some View {
        TimelineView(PlaybackTicks(m, running: expanded && scrubbing == nil)) { ctx in
            let pos = scrubbing ?? Double(device.media.currentPosition(at: ctx.date))
            VStack(spacing: 1) {
                Slider(value: Binding(get: { pos }, set: { scrubbing = $0 }), in: 0...Double(max(m.length, 1))) { editing in
                    if !editing, let s = scrubbing { device.seek(to: Int(s)); scrubbing = nil }
                }
                .controlSize(.mini)
                .disabled(!m.canSeek)
                HStack {
                    Text(formatTime(ms: Int(pos)))
                    Spacer()
                    Text("-" + formatTime(ms: max(0, m.length - Int(pos))))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func skip(_ ms: Int) {
        let target = min(max(0, m.currentPosition() + ms), max(0, m.length - 500))
        device.seek(to: target)
    }

    private func control(_ symbol: String, help: String, size: CGFloat = 14, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.primary)
        .disabled(disabled)
        .help(help)
    }
}

/// "Received 3 items · 2 min ago" for the latest transfer batch.
@MainActor
struct TransferSummary {
    let title: String
    let detail: String
    let date: Date
    let inProgress: Bool
    let first: Transfer

    var thumbnail: some View {
        Color.clear.frame(width: 22, height: 22)
            .overlay { PreviewImage(transfer: first, compact: true) }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    static func latest() -> TransferSummary? {
        let items = TransferStore.shared.items
        guard let first = items.first else { return nil }
        // Items of the same batch, or same direction within 30 s of each other.
        let batch = items.prefix { t in
            t.direction == first.direction
                && (t.batchID != nil ? t.batchID == first.batchID : abs(t.date.timeIntervalSince(first.date)) < 30)
        }
        let n = batch.count
        let inProgress = batch.contains { $0.state == .inProgress }
        let verb = first.direction == .received ? (inProgress ? "Receiving" : "Received") : (inProgress ? "Sending" : "Sent")
        let what = n == 1 ? first.name : "\(n) items"
        let detail: String
        if inProgress, let p = TransferStore.shared.progress(for: first) {
            detail = "\(Int(p * 100))%"
        } else if batch.contains(where: { $0.state == .failed }) {
            detail = "Didn't finish"
        } else {
            detail = first.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
        return TransferSummary(title: "\(verb) \(what)", detail: detail, date: first.date, inProgress: inProgress, first: first)
    }
}

struct DeviceHeader: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            DeviceArt(device: device, height: 34, dimmed: !device.isReachable)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.body.weight(.semibold))
                HStack(spacing: 5) {
                    Circle().fill(device.isReachable ? .green : .secondary).frame(width: 6, height: 6)
                    Text(device.statusText)
                    if device.phoneDND == true {
                        Image(systemName: "moon.fill").foregroundStyle(.indigo).help("Do Not Disturb is on")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if device.isReachable, device.has("battery") {
                BatteryView(charge: device.batteryCharge, charging: device.isCharging).font(.caption)
            }
        }
    }
}

struct QuickActions: View {
    let device: Device
    var compact = false
    var alignment: Alignment = .center
    @State private var pickingFiles = false
    @State private var confirmation: String?
    @Environment(\.closePanel) private var dismiss

    var body: some View { fullRow }


    @ViewBuilder private var fullRow: some View {
        let d: CGFloat = compact ? 32 : 42
        HStack(alignment: .top, spacing: compact ? 22 : 26) {
            ActionButton(title: "Ping", symbol: "hand.wave.fill", tint: .blue, disabled: !device.has("ping"), diameter: d) {
                device.ping(); flash("Ping sent")
            }
            if device.has("clipboard"), device.clipboardAutoShareDisabled {
                ActionButton(title: "Clipboard", symbol: "doc.on.clipboard.fill", tint: .teal, diameter: d) {
                    device.sendClipboard(); flash("Clipboard sent")
                }
            }
            ActionButton(title: device.isRinging ? "Stop Ringing" : "Find Phone",
                         symbol: device.isRinging ? "speaker.slash.fill" : "speaker.wave.3.fill",
                         tint: .orange, disabled: !device.has("findmyphone"), diameter: d) {
                let wasRinging = device.isRinging
                device.toggleRing(); flash(wasRinging ? "Stopped ringing" : "Ringing \(device.name)")
            }
            ActionButton(title: "Send Files", symbol: "paperplane.fill", tint: .purple, disabled: !device.has("share"), diameter: d) {
                if compact {
                    // In the menu bar, a sheet-style chooser dies with the panel when focus moves to it,
                    // so close the panel and open a standalone chooser instead.
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { FilePicker.chooseAndSend(to: device) }
                } else {
                    pickingFiles = true
                }
            }
            if DeviceTrust.isMine(device), device.supports("mirror") {
                let mirroring = MirrorController.shared.isActive && MirrorController.shared.deviceID == device.id
                ActionButton(title: mirroring ? "Stop Mirroring" : "Mirror", symbol: "rectangle.on.rectangle",
                             tint: .green, diameter: d) {
                    MirrorController.shared.toggle(device)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .overlay(alignment: .bottom) {
            if let confirmation {
                Text(confirmation)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .offset(y: compact ? 10 : 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                device.share(urls)
                flash(urls.count == 1 ? "Sending \(urls[0].lastPathComponent)" : "Sending \(urls.count) files")
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { confirmation = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.snappy) { if confirmation == text { confirmation = nil } }
        }
    }
}

struct MiniPlayer: View {
    let device: Device
    var artSize: CGFloat = 42

    var body: some View {
        HStack(spacing: 10) {
            AlbumArt(url: device.media.artURL, size: artSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.media.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(device.media.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 14) {
                Button { device.mediaAction("Previous") } label: { Image(systemName: "backward.fill") }
                Button { device.mediaAction("PlayPause") } label: {
                    Image(systemName: device.media.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { device.mediaAction("Next") } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)
        }
    }
}

struct EmptyPanelState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            switch model.state {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(.secondary)
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .connected:
                Image(systemName: "iphone.gen3.slash").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(model.pairedDevices.isEmpty ? "No paired phone" : "Phone not connected").font(.headline)
                Text("Open Janus on your phone and make sure both devices are on the same Wi-Fi.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Add Device…") { model.showAddDevice = true; model.wantsMainWindow = true }
                    ReconnectButton(prominent: !model.pairedDevices.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A standalone file chooser (its own window), usable from the menu bar.
@MainActor
enum FilePicker {
    static func chooseAndSend(to device: Device) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Send to \(device.name)"
        panel.message = "Choose files to send to \(device.name)"
        panel.prompt = "Send"
        panel.level = .floating
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            device.share(panel.urls)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

/// The ⋯ button: a full round target with a hover highlight (not just the dots).
private struct MoreButtonLabel: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 28)
            // A nearly invisible fill still counts for clicks, so the whole shape is clickable.
            .background(Color.primary.opacity(hovering ? 0.1 : 0.001), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A panel section: divider, small heading (with optional detail and action), content.
private struct PanelSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    var action: (String, () -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.horizontal, 12)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let detail { Text("· " + detail).font(.subheadline).foregroundStyle(.tertiary) }
                Spacer()
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.janus)
                }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 5).padding(.bottom, 5)
        }
    }
}

/// Up to 7 small tiles that exactly fill the panel width.
private struct RecentTiles: View {
    let items: [Transfer]
    @State private var preview: URL?

    var body: some View {
        // 7 × 32 pt + 6 × 4 pt = 248 pt: fits the 280 pt panel with the section's 14 pt margins.
        HStack(spacing: 4) {
            ForEach(items) { t in TransferTile(transfer: t, preview: $preview, size: 32) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .quickLookPreview($preview, in: items.compactMap { $0.kind == .file ? $0.url : nil })
    }
}

/// The phone, its name (a menu to switch phones when there are several) and a one-line status.
private struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @State private var textHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 11) {
            // As tall as the name and status beside it.
            DeviceArt(device: device, height: textHeight, dimmed: !device.isReachable)
            VStack(alignment: .leading, spacing: 2) {
                if model.pairedDevices.count > 1 {
                    Menu {
                        ForEach(model.pairedDevices) { d in
                            Button { model.selectedDeviceID = d.id } label: {
                                if d.id == device.id { Label(d.name, systemImage: "checkmark") }
                                else { Text(d.isReachable ? d.name : "\(d.name) · not connected") }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            name
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Switch phone")
                } else {
                    name
                }
                status
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            Spacer(minLength: 8)
            if device.isTV {
                TVPowerButton(device: device)
            } else if device.isReachable, let ringer = device.status?.ringer {
                RingerSwitch(device: device, mode: ringer)
            }
        }
    }

    private var name: some View {
        Text(device.name).font(.headline).lineLimit(1)
    }

    private var status: some View {
        HStack(spacing: 4) {
            Circle().fill(device.isReachable ? .green : .secondary).frame(width: 6, height: 6)
            if device.isReachable {
                if device.has("battery"), let c = device.batteryCharge {
                    Image(systemName: BatteryView(charge: c, charging: device.isCharging).symbol)
                        .foregroundStyle(device.isCharging ? .green : .secondary)
                    Text("\(c)%").monospacedDigit()
                } else {
                    Text("Connected")
                }
            } else if CloudService.shared.canReach(device) {
                // Away, but linked through Janus Cloud: its battery comes with the status the phone sends there.
                Image(systemName: "icloud.fill").foregroundStyle(Color.janus)
                Text("via Cloud")
                if device.supports("cloud2"), let c = device.batteryCharge {
                    Text("·")
                    Image(systemName: BatteryView(charge: c, charging: device.isCharging).symbol)
                        .foregroundStyle(device.isCharging ? .green : .secondary)
                    Text("\(c)%").monospacedDigit()
                }
            } else {
                Text(device.statusText)
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// One row of equal, labelled round buttons, like Control Center: find, clipboard, send, sound mode,
/// Do Not Disturb and flashlight (each only when the phone supports it).
private struct PanelControls: View {
    let device: Device
    @State private var copied = false
    @Environment(\.closePanel) private var closePanel

    var body: some View {
        if device.isTV { tvControls } else { phoneControls }
    }

    /// A TV (R38): its own controls only: the remote (pointer and keyboard) and what's playing.
    private var tvControls: some View {
        HStack(alignment: .top, spacing: 0) {
            PanelControlButton(symbol: "rectangle.on.rectangle", title: "Mirror") {
                closePanel()
                AirPlayMirroring.openDisplaySettings()
            }
            .help("Mirror or extend this Mac to the TV with AirPlay (Displays → +)")
            PanelControlButton(symbol: "av.remote", title: "Remote") {
                closePanel()
                TVRemoteWindow.shared.show(device)
            }
            .help("Open the remote for \(device.name)")
            if device.has("mprisremote") {
                PanelControlButton(symbol: "play.rectangle", title: "Playing") { open(.media) }
            }
        }
    }

    private func open(_ pane: Pane) {
        closePanel()
        SceneActions.showMainWindow(pane)
    }

    private var phoneControls: some View {
        HStack(alignment: .top, spacing: 0) {
            if device.has("findmyphone") {
                PanelControlButton(symbol: device.isRinging ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   title: device.isRinging ? "Stop" : "Find", active: device.isRinging, tint: .orange,
                                   pulse: device.isRinging) { device.toggleRing() }
                    .help(device.isRinging ? "Stop ringing" : "Ring the phone")
            }
            // Only when automatic sync is off: then copying doesn't reach the phone by itself.
            if device.has("clipboard"), device.clipboardAutoShareDisabled {
                PanelControlButton(symbol: copied ? "checkmark" : "doc.on.clipboard", title: "Clipboard") {
                    device.sendClipboard()
                    withAnimation(.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation(.snappy) { copied = false } }
                }
                .help("Send this Mac's clipboard to the phone")
            }
            if device.has("share") {
                PanelControlButton(symbol: "paperplane", title: "Send") {
                    closePanel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { FilePicker.chooseAndSend(to: device) }
                }
                .help("Send files…")
            }
            if DeviceTrust.isMine(device), device.supports("mirror") {
                let mirroring = MirrorController.shared.isActive && MirrorController.shared.deviceID == device.id
                PanelControlButton(symbol: "rectangle.on.rectangle", title: "Mirror", active: mirroring, tint: .janus) {
                    closePanel()
                    MirrorController.shared.toggle(device)
                }
                .help(mirroring ? "Stop mirroring" : "Show and control the phone on this Mac")
            }
            if let dnd = device.phoneDND {
                PanelControlButton(symbol: "moon.fill", title: "DND", active: dnd, tint: .indigo) {
                    device.setPhoneDND(!dnd, reason: "Menu bar")
                }
                .help(dnd ? "Turn off Do Not Disturb" : "Turn on Do Not Disturb")
            }
            if let light = device.status?.flashlight {
                PanelControlButton(symbol: light ? "flashlight.on.fill" : "flashlight.off.fill", title: "Light",
                                   active: light, tint: .yellow) { device.setFlashlight(!light) }
                    .help(light ? "Turn off the flashlight" : "Turn on the flashlight")
            }
        }
        .animation(.snappy(duration: 0.2), value: device.status)
        .animation(.snappy(duration: 0.2), value: device.phoneDND)
    }

    static func ringerSymbol(_ mode: String) -> String {
        switch mode { case "vibrate": "iphone.gen3.radiowaves.left.and.right"; case "silent": "bell.slash.fill"; default: "bell.fill" }
    }
    static func ringerTitle(_ mode: String) -> String {
        switch mode { case "vibrate": "Vibrate"; case "silent": "Silent"; default: "Ring" }
    }
}

/// Ring / Vibrate / Silent as a small capsule with a sliding highlight, in the header's top-right corner.
private struct RingerSwitch: View {
    let device: Device
    let mode: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(["normal", "vibrate", "silent"], id: \.self) { m in
                let selected = m == mode
                Button { device.setRinger(m) } label: {
                    Image(systemName: PanelControls.ringerSymbol(m))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? Color.janusOn : Color.secondary)
                        .frame(width: 24, height: 22)
                        .background {
                            if selected { Capsule().fill(Color.janus.gradient).matchedGeometryEffect(id: "sel", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(PanelControls.ringerTitle(m))
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy(duration: 0.25), value: mode)
    }
}

private struct PanelControlButton: View {
    let symbol: String
    let title: String
    var active = false
    var tint: Color = .janus
    var pulse = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? (tint == .janus ? Color.janusOn : Color.white) : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: pulse)
                    .frame(width: 34, height: 34)
                    // Control Center style: a flat circle, filled with its color while on. (Not glass: its edge
                    // lighting makes small circles read as rounded squares.)
                    .background(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.16 : 0.1)),
                                in: Circle())
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A TV's Power in the panel header (where a phone has its ringer).
private struct TVPowerButton: View {
    let device: Device

    var body: some View {
        let remote = TVRemote.of(device)
        Button { remote.press(.power) } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(remote.isConnected ? Color.red : Color.secondary)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!remote.isConnected)
        .help(remote.powerOn == false ? "Turn the TV on" : "Turn the TV off")
    }
}
