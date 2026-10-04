import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings as a page of the main window (no separate window): General and Devices, switched from the toolbar.
struct SettingsPane: View {
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        // Full width (so the toolbar's scroll edge spans the window), content centred at a readable width.
        GeometryReader { geo in
            Group {
                if tab == "devices" { DeviceSettings() } else { GeneralSettings() }
            }
            .contentMargins(.horizontal, max(0, (geo.size.width - 680) / 2), for: .scrollContent)
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Settings", selection: $tab) {
                    Text("General").tag("general")
                    Text("Devices").tag("devices")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("startHidden") private var startHidden = false
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Name shown on your phone", text: $name)
                    .onSubmit { model.setAnnouncedName(name) }
                    .onAppear { name = model.announcedName }
                    .onChange(of: model.announcedName) { _, n in name = n }
                if model.announcedName != AppModel.protocolSafeName(AppModel.computerName) {
                    Button("Use Computer Name (“\(AppModel.protocolSafeName(AppModel.computerName))”)") {
                        model.setAnnouncedName(AppModel.computerName)
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Start in the menu bar only", isOn: $startHidden)
                if AppIcon.darkAvailable {
                    Picker("App icon", selection: Binding(get: { AppIcon.style }, set: { AppIcon.style = $0 })) {
                        ForEach(AppIcon.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .help("The icon in the Dock and the app switcher while Janus is open")
                }
            }
            PhoneAndCallsSection()
            CalendarSettingsSection()
            NotesSettingsSection()
            DeveloperSettingsSection()
            Section("Notifications on This Mac") {
                if notificationsDenied {
                    Label("Notifications are turned off for Janus in System Settings, so none of these will appear.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(Notifier.Kind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: kind.rawValue) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: kind.rawValue) }))
                }
                Toggle("Play sounds (received files, links, codes, calls, reminders…)", isOn: Binding(
                    get: { Sounds.enabled },
                    set: { UserDefaults.standard.set($0, forKey: "notify.sounds") }))
                Toggle("Play a sound when the phone's notification makes one", isOn: Binding(
                    get: { Notifier.phoneSounds },
                    set: { UserDefaults.standard.set($0, forKey: "notify.phone.sound") }))
                    .disabled(!Sounds.enabled)
                MutedAppsRow()
                Toggle("Show notifications as cards below the menu bar icon", isOn: Binding(
                    get: { BannerCenter.enabled },
                    set: { UserDefaults.standard.set($0, forKey: "notify.popups") }))
                    .help("Off: macOS notifications instead, which follow Focus and stay in Notification Center")
                Toggle("Show received files in a popup below the menu bar icon", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "popup.receive") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "popup.receive") }))
                Toggle("Keep a history of what you copy (Clipboard in the sidebar)", isOn: Binding(
                    get: { ClipboardHistory.enabled },
                    set: { UserDefaults.standard.set($0, forKey: "clipboard.history"); if !$0 { ClipboardHistory.shared.clear() } }))
                Toggle("Show live activities next to the menu bar icon", isOn: Binding(
                    get: { StatusItemController.showsLiveLabel },
                    set: { UserDefaults.standard.set($0, forKey: "live.menuBar"); StatusItemController.shared.updateLiveLabel() }))
                Toggle("Copy verification codes automatically", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "codes.autoCopy") },
                    set: { UserDefaults.standard.set($0, forKey: "codes.autoCopy") }))
                Text("Codes are cleared from the clipboard after 2 minutes if you haven't copied anything else.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link)
            }
            Section {
                ForEach(model.linkProviders, id: \.name) { p in
                    Toggle(p.title, isOn: Binding(get: { p.enabled }, set: { model.setLinkProvider(p.name, enabled: $0) }))
                }
                Button("Refresh Connections") { model.refreshNetwork() }
            } header: {
                Text("Connections")
            } footer: {
                Text("Your phone connects over Wi-Fi (LAN) or Bluetooth.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

}

private struct DeviceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var renaming: Device?
    @State private var removing: Device?
    @State private var newAddress = ""

    var body: some View {
        let devices = model.pairedDevices + model.discoverableDevices
        if devices.isEmpty {
            ContentUnavailableView {
                Label("No Devices", systemImage: "iphone.gen3.slash")
            } actions: {
                Button("Add Device…") { addDevice() }
            }
        } else {
            let device = devices.first { $0.id == selection } ?? devices[0]
            Form {
                Section {
                    Picker("Device", selection: Binding(get: { device.id }, set: { selection = $0 })) {
                        ForEach(devices) { Text($0.name).tag($0.id) }
                    }
                    LabeledContent("Name") {
                        HStack {
                            Text(device.name)
                            if device.hasNickname { Text("(\(device.announcedName))").foregroundStyle(.secondary) }
                            Button("Rename…") { renaming = device }
                        }
                    }
                    if let model = device.modelName { LabeledContent("Model", value: model) }
                    if device.type == "phone" {
                        let look = DeviceLook.of(device)
                        Picker("Color", selection: Binding(get: { look.finish }, set: { DeviceLook.set($0, for: device) })) {
                            ForEach(look.finishes) { Text($0.title).tag($0) }
                        }
                    }
                    if device.isPaired {
                        Picker("Whose device", selection: Binding(
                            get: { DeviceTrust.level(device) ?? .other },
                            set: { DeviceTrust.set($0, for: device) })) {
                            Text("My device").tag(DeviceTrust.Level.mine)
                            Text("Someone else's").tag(DeviceTrust.Level.other)
                        }
                        if !DeviceTrust.isMine(device) {
                            Text("Only files and links. Clipboard, notifications, calls, messages, media, remote control and Mac controls are off, and files you receive ask Keep or Delete.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Status", value: device.statusText)
                    LabeledContent("Verification key") { Text(device.verificationKey).monospaced().textSelection(.enabled) }
                    HStack {
                        if device.isPaired {
                            Button("Remove Device…", role: .destructive) { removing = device }
                        } else if device.isReachable {
                            Button("Pair") { device.requestPairing() }
                        }
                        Spacer()
                        Button("Add Device…") { addDevice() }
                    }
                }
                Section {
                    ForEach(model.customAddresses, id: \.self) { addr in
                        HStack {
                            Text(addr).monospaced()
                            Spacer()
                            Button { model.setCustomAddresses(model.customAddresses.filter { $0 != addr }) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop connecting to this address")
                        }
                    }
                    HStack {
                        TextField("IP address, e.g. \(AppModel.exampleAddress)", text: $newAddress)
                            .onSubmit { if model.addAddress(newAddress) { newAddress = "" } }
                        Button("Add") { if model.addAddress(newAddress) { newAddress = "" } }
                            .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Direct Addresses")
                } footer: {
                    Text("For networks where devices can't find each other automatically. This Mac connects to these addresses directly.")
                        .foregroundStyle(.secondary)
                }
                if device.isPaired {
                    Section("Features") {
                        ForEach(device.supportedPlugins.sorted { pluginTitle($0) < pluginTitle($1) }, id: \.self) { plugin in
                            Toggle(isOn: Binding(get: { device.enabledPlugins.contains(plugin) }, set: { device.setPlugin(plugin, enabled: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(pluginTitle(plugin))
                                    if let d = pluginDetail(plugin) { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $renaming) { d in RenameDeviceSheet(device: d) }
            .removeDeviceConfirmation($removing)
        }
    }

    private func addDevice() {
        model.showAddDevice = true
        model.wantsMainWindow = true
    }

    private func pluginTitle(_ id: String) -> String {
        [
            "kdeconnect_battery": "Battery", "kdeconnect_clipboard": "Clipboard sync",
            "kdeconnect_connectivity_report": "Cellular signal", "kdeconnect_contacts": "Contacts",
            "kdeconnect_findmyphone": "Find my phone", "kdeconnect_mousepad": "Phone as touchpad",
            "kdeconnect_mprisremote": "Media control", "kdeconnect_notifications": "Notifications",
            "kdeconnect_ping": "Ping", "kdeconnect_presenter": "Presentation remote",
            "kdeconnect_remotecommands": "Run commands on phone", "kdeconnect_remotecontrol": "Remote input",
            "kdeconnect_remotekeyboard": "Remote keyboard", "kdeconnect_remotesystemvolume": "Phone volume",
            "kdeconnect_runcommand": "Run commands on Mac", "kdeconnect_screensaver_inhibit": "Keep Mac awake",
            "kdeconnect_share": "Share files and links", "kdeconnect_sms": "Messages",
            "kdeconnect_systemvolume": "Mac volume from phone", "kdeconnect_telephony": "Call alerts",
            "kdeconnect_virtualmonitor": "Virtual display",
        ][id] ?? id.replacingOccurrences(of: "kdeconnect_", with: "").capitalized
    }

    private func pluginDetail(_ id: String) -> String? {
        [
            "kdeconnect_mousepad": "Lets the phone move this Mac's pointer.",
            "kdeconnect_remotecontrol": "Control the phone's pointer from this Mac.",
            "kdeconnect_screensaver_inhibit": "Prevents sleep while the phone is connected.",
            "kdeconnect_telephony": "Shows incoming calls on this Mac.",
            "kdeconnect_systemvolume": "Lets the phone change this Mac's volume.",
        ][id]
    }
}

/// Apps muted from a notification's "Mute … on This Mac" button or the Notifications page.
private struct MutedAppsRow: View {
    @State private var apps: [String] = []

    var body: some View {
        Group {
            if !apps.isEmpty {
                LabeledContent("Muted apps") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(apps, id: \.self) { app in
                            HStack(spacing: 6) {
                                Text(app)
                                Button("Unmute") {
                                    Notifier.setMuted(app, false)
                                    apps = Notifier.mutedApps.sorted()
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { apps = Notifier.mutedApps.sorted() }
    }
}

private struct PhoneAndCallsSection: View {
    @State private var isDefaultForTel = URLRouter.isDefaultForPhoneLinks
    @State private var telError: String?
    @AppStorage("macActions.enabled") private var macActions = true
    @AppStorage("screenshots.copy") private var copyScreenshots = true
    @AppStorage("screenshots.desktop") private var desktopScreenshots = false

    var body: some View {
        Section {
            LabeledContent("Phone number links") {
                if isDefaultForTel {
                    Label("Numbers open on your phone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Use Janus for Calls") {
                        Task {
                            do { try await URLRouter.makeDefaultForPhoneLinks() } catch { telError = error.localizedDescription }
                            isDefaultForTel = URLRouter.isDefaultForPhoneLinks
                        }
                    }
                }
            }
            if let telError { Text(telError).font(.caption).foregroundStyle(.red) }
            Toggle("Let the phone lock, sleep, mute and screenshot this Mac", isOn: $macActions)
                .onChange(of: macActions) { _, _ in MacActions.publish() }
            Toggle("Copy phone screenshots to the clipboard", isOn: $copyScreenshots)
            Toggle("Save phone screenshots to the Desktop", isOn: $desktopScreenshots)
        } header: {
            Text("Phone & Calls")
        } footer: {
            Text("Clicking a phone number in Safari, Contacts or Mail opens it on your phone, ready to call: just tap Call there. Screenshots reach this Mac once \"Send screenshots to computer\" is on in the phone app.")
                .foregroundStyle(.secondary)
        }
        .onAppear { isDefaultForTel = URLRouter.isDefaultForPhoneLinks }
    }
}

/// The Quick Note shortcut: shown, re-recorded or turned off.
private struct NotesSettingsSection: View {
    @State private var shortcut = QuickNoteHotKey.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Section("Notes") {
            LabeledContent("Quick Note shortcut") {
                HStack(spacing: 8) {
                    Button(recording ? "Type the shortcut…" : (shortcut?.display ?? "Record Shortcut")) {
                        recording ? stop() : start()
                    }
                    .monospaced(!recording && shortcut != nil)
                    if shortcut != nil, !recording {
                        Button("Turn Off") { QuickNoteHotKey.current = nil; shortcut = nil }
                    }
                }
            }
            Text("Opens a small note from anywhere: your last quick note, ready to type. Press it again or Esc to put it away. Quick notes sync to your phone like any note. You can also start one from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        QuickNoteHotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                       // Esc: keep the old one
            guard let s = QuickNoteHotKey.shortcut(from: e) else { NSSound.beep(); return nil }
            QuickNoteHotKey.current = s
            shortcut = s
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; QuickNoteHotKey.shared.register() }
    }
}

/// Tools for people working on Janus: simulated notifications and the raw data inspector.
private struct DeveloperSettingsSection: View {
    @AppStorage("developer.tools") private var tools = false

    var body: some View {
        Section("Developer") {
            Toggle("Show testing tools (Testing in the sidebar)", isOn: $tools)
        }
    }
}
