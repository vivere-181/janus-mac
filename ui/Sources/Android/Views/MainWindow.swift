import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    /// SwiftUI keeps a closed window (and every view in it) alive, still updating for changes nobody can see. The
    /// section's view is released when it closes and built again as it reopens (the sidebar stays).
    @State private var open = true

    var body: some View {
        panes
        .onAppear { DispatchQueue.main.async { DockPresence.update() } }
        .onDisappear { DispatchQueue.main.async { DockPresence.update() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == "main" {
                open = false
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
        }
        // Back before it's drawn: becoming key happens while the window is ordered in.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if !open, (note.object as? NSWindow)?.identifier?.rawValue == "main" { open = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if !open, let w = note.object as? NSWindow, w.identifier?.rawValue == "main", w.isVisible { open = true }
        }
    }

    private var panes: some View {
        @Bindable var model = model
        return NavigationSplitView {
            // The minimum must fit the sidebar's toolbar (Settings, Reconnect, sidebar toggle). SwiftUI rebuilds the
            // toolbar each time the window reopens, and AppKit's first layout of it needs ~228 pt; narrower, Reconnect
            // goes into the » overflow and stays there until the sidebar is resized.
            Sidebar()
                .navigationSplitViewColumnWidth(min: 232, ideal: 240, max: 280)
        } detail: {
            Group {
                if !open {
                    Color.clear
                } else if model.section == .settings {
                    SettingsPane()
                } else if model.section == .testing {
                    TestingPane()
                } else if let device = model.selectedDevice, device.isPaired, model.section == .connection {
                    ConnectionView(device: device)
                } else if model.section == .notes, model.selectedDevice?.isPaired == true {
                    // Notes live on this Mac; they sync when the phone is back.
                    NotesPane()
                } else if let device = model.selectedDevice, device.isPaired, model.section == .calendar {
                    // Works from the cached copy while the phone is away.
                    CalendarPane()
                } else if let device = model.selectedDevice, device.isPaired, model.section == .notifications, !device.isReachable {
                    // The last 24 hours, while the phone is away.
                    NotificationsView(device: device)
                } else if let device = model.selectedDevice, device.isPaired, device.isReachable {
                    switch model.section ?? .overview {
                    case .connection: ConnectionView(device: device)
                    case .settings: SettingsPane()
                    case .testing: TestingPane()
                    case .overview: OverviewView(device: device)
                    case .calendar: CalendarPane()
                    case .notes: NotesPane()
                    case .messages: MessagesView(device: device)
                    case .notifications: NotificationsView(device: device)
                    case .media: MediaView(device: device)
                    case .files: TransfersView(device: device)
                    case .clipboard: ClipboardView(device: device)
                    case .remote: RemoteInputView(device: device)
                    }
                } else {
                    NoDeviceView()
                }
            }
            .frame(minWidth: 560, minHeight: 460)
        }
        .overlay(alignment: .top) { PairingBanner() }
        .tint(.janus)   // Janus navy for selections, buttons and controls (R32)
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet().environment(model) }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("developer.tools") private var developerTools = false
    @State private var renaming: Device?
    @State private var removing: Device?

    var body: some View {
        // Plain buttons instead of List(selection:): they take clicks reliably on first try,
        // including when the window isn't focused yet.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let device = model.selectedDevice, device.isPaired {
                    // Which phone is shown, and the switcher (also rename, remove, add): the sidebar's first row.
                    deviceMenu(device)
                        .padding(.bottom, 8)
                    // Connection lives in the status box at the bottom of the sidebar.
                    ForEach(Array(Pane.allCases.filter { ![.connection, .settings, .testing].contains($0) }.enumerated()), id: \.element) { index, pane in
                        SidebarRow(pane: pane,
                                   selected: (model.section ?? .overview) == pane,
                                   badge: badge(for: pane, device: device),
                                   dimmed: !device.isReachable && ![.connection, .calendar, .notes, .notifications].contains(pane)) {
                            model.section = pane
                        }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                }
                // Testing tools, for development only (Settings → Developer).
                if developerTools {
                    Text("Developer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
                    SidebarRow(pane: .testing, selected: model.section == .testing, badge: 0, dimmed: false) {
                        model.section = .testing
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $renaming) { d in RenameDeviceSheet(device: d) }
        .removeDeviceConfirmation($removing)
        .toolbar {
            // App-wide actions above the sidebar; the window's toolbar keeps each section's own actions.
            if model.selectedDevice?.isPaired == true {
                ToolbarItemGroup {
                    Button { model.section = .settings } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Settings")
                    ReconnectButton(compact: true, inToolbar: true).help("Reconnect")
                }
            }
        }
        .background {
            // ⌘0 opens Connection details (⌘1… are the sidebar rows).
            Button("") { model.section = .connection }.keyboardShortcut("0", modifiers: .command).hidden()
        }
    }

    /// The phone header is the one place for devices: switch, rename, remove, add.
    private func deviceMenu(_ device: Device) -> some View {
        Menu {
            if model.pairedDevices.count > 1 {
                Section("Devices") {
                    ForEach(model.pairedDevices) { d in
                        Button { model.selectedDeviceID = d.id } label: {
                            if d.id == device.id { Label(d.name, systemImage: "checkmark") }
                            else { Text(d.isReachable ? d.name : "\(d.name) · not connected") }
                        }
                    }
                }
            }
            Section(device.name) {
                Button("Connection Details") { model.section = .connection }
                Button("Rename…") { renaming = device }
                Button("Remove…", role: .destructive) { removing = device }
            }
            Divider()
            Button("Add Device…") { model.showAddDevice = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "smartphone").font(.body).foregroundStyle(.secondary).frame(width: 22)
                Text(device.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch, add, rename or remove devices")
    }

    private func badge(for section: Pane, device: Device) -> Int {
        switch section {
        case .notifications: device.notifications.count
        case .messages: device.unreadCount
        default: 0
        }
    }
}

private struct SidebarRow: View {
    let pane: Pane
    let selected: Bool
    let badge: Int
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .font(.body)
                    .foregroundStyle(Color(pane.tint))
                    .saturation(dimmed ? 0.3 : 1)
                    .frame(width: 22)
                Text(pane.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(dimmed ? .tertiary : .primary)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.11) : hovering ? Color.primary.opacity(0.05) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Floating banner for incoming pairing requests.
private struct PairingBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let device = model.pairingRequests.first {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("\(device.name) wants to pair").font(.headline)
                    Text("Verification key: \(device.verificationKey)").font(.caption).foregroundStyle(.secondary).monospaced()
                }
                Spacer()
                Button("Decline") { device.rejectPairing() }
                Button("Pair") { device.acceptPairing() }.buttonStyle(.borderedProminent)
            }
            .padding(14)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct NoDeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            switch model.state {
            case .connecting:
                ProgressView("Starting…")
            case .failed(let error):
                ContentUnavailableView {
                    Label("Can't start the connection", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                }
            case .connected:
                ContentUnavailableView {
                    Label(model.pairedDevices.isEmpty ? "Pair your phone" : "Phone not connected", systemImage: "iphone.gen3.radiowaves.left.and.right")
                } description: {
                    Text("Open the companion app on your Android phone and keep both devices on the same Wi-Fi network.")
                } actions: {
                    HStack {
                        Button("Add Device…") { model.showAddDevice = true }
                        ReconnectButton(prominent: !model.pairedDevices.isEmpty)
                    }
                    if let note = model.reconnectNote, !model.isReconnecting {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 280)
                if !model.discoverableDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available devices").font(.headline)
                        ForEach(model.discoverableDevices) { d in
                            HStack {
                                Image(systemName: d.symbol).frame(width: 24)
                                Text(d.name)
                                Spacer()
                                if d.isPairRequested {
                                    ProgressView().controlSize(.small)
                                    Button("Cancel") { d.rejectPairing() }
                                } else {
                                    Button("Pair") { d.requestPairing() }
                                }
                            }
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
