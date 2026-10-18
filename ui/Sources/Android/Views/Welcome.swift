import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI
import UserNotifications

/// Where the "get the Android app" code points (R41).
enum JanusLinks {
    static let androidApp = URL(string: "https://github.com/vivere-181/janus-android/releases/latest")!
}

// MARK: QR codes

/// A QR code, drawn crisp at any size (black on white, with its quiet zone).
struct QRCode: View {
    let text: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = Self.image(text) {
                Image(nsImage: image).interpolation(.none).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityLabel("QR code")
    }

    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage, let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
    }
}

/// This Mac's pairing code (R41): scanned with Janus on the phone, it pairs at once, as the owner's device. A fresh
/// code every few minutes while it's shown; the engine forgets it when it goes away.
struct PairingCode: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 200
    @State private var link: String?
    @State private var unavailable = false

    var body: some View {
        VStack(spacing: 14) {
            if let link {
                QRCode(text: link, size: size)
            } else if unavailable {
                Label("QR pairing needs Janus's own connection engine.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).frame(width: size + 28, height: size + 28)
            } else {
                ProgressView().frame(width: size + 28, height: size + 28)
            }
        }
        .task {
            // A new code every 9 minutes (each is good for 10) while this is on screen.
            while !Task.isCancelled {
                if let l = await model.pairingLink() { link = l; unavailable = false } else { unavailable = true }
                try? await Task.sleep(for: .seconds(540))
            }
        }
        .onDisappear { model.endPairingOffer() }
    }
}

// MARK: Welcome

/// First launch (R41): what Janus does, get the Android app, pair by scanning a code, a few permissions, done.
struct WelcomeView: View {
    enum Page: Int, CaseIterable { case hello, getApp, pair, permissions, done }

    @Environment(AppModel.self) private var model
    @State private var page: Page
    @State private var pairedID: String?
    let close: () -> Void

    init(start: Page = .hello, close: @escaping () -> Void) {
        _page = State(initialValue: start)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .hello: hello
                case .getApp: getApp
                case .pair: pair
                case .permissions: PermissionsPage()
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48).padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(page)
            footer
        }
        .frame(width: 640, height: 560)
        .animation(.smooth(duration: 0.35), value: page)
        .onChange(of: model.pairedByCode) { _, id in
            guard let id, page == .pair || page == .getApp else { return }
            pairedID = id
            Task { try? await Task.sleep(for: .seconds(1.6)); if page == .pair || page == .getApp { page = .permissions } }
        }
    }

    // MARK: Pages

    private var hello: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("Welcome to Janus").font(.largeTitle.weight(.bold))
                Text("Your Android phone and your Mac, working together.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("bell.badge.fill", .red, "Notifications and calls", "See them on your Mac, reply, and answer.")
                feature("message.fill", .green, "Messages and calendar", "Text from your Mac; your phone's events at a glance.")
                feature("doc.on.doc.fill", .blue, "Files, links and clipboard", "Send anything either way; copy here, paste there.")
                feature("rectangle.on.rectangle", .purple, "Notes, mirroring and more", "Synced notes, your phone's screen, your TV's remote.")
            }
            .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private var getApp: some View {
        VStack(spacing: 18) {
            header("Get Janus on your phone", "Scan this code with your Android phone's camera to download Janus.")
            QRCode(text: JanusLinks.androidApp.absoluteString, size: 190)
            Text("Your phone will ask to allow installing apps from your browser. That's expected: Janus isn't in the Play Store.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private var pair: some View {
        VStack(spacing: 18) {
            if let id = pairedID, let d = model.devices.first(where: { $0.id == id }) {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: pairedID)
                Text("Paired with \(d.name)").font(.title.weight(.semibold))
                Spacer()
            } else {
                header("Pair your phone", "Open Janus on your phone and scan this code.")
                PairingCode(size: 190)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your phone…").foregroundStyle(.secondary)
                }
                Button("Pair over Wi-Fi instead…") { close(); model.showAddDevice = true; SceneActions.showMainWindow(.overview) }
                    .buttonStyle(.link)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Color.janus)
            Text("You're all set").font(.largeTitle.weight(.bold))
            Text("Janus lives in the menu bar: click its icon for your phone at a glance, or open the window for everything.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Spacer()
        }
    }

    private func header(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title.weight(.bold))
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if page != .hello && page != .done {
                Button("Back") { page = Page(rawValue: page.rawValue - 1) ?? .hello }
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { p in
                    Circle().fill(p == page ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(primaryTitle) {
                if page == .done { close() } else { page = Page(rawValue: page.rawValue + 1) ?? .done }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var primaryTitle: String {
        switch page {
        case .hello: "Get Started"
        case .getApp: "I Have Janus"
        case .pair: pairedID == nil ? "Skip for Now" : "Continue"
        case .permissions: "Continue"
        case .done: "Open Janus"
        }
    }
}

/// The permissions Janus uses, each with why; the optional ones say what they're for. Everything else is asked when
/// a feature first needs it.
private struct PermissionsPage: View {
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("A few permissions").font(.title.weight(.bold))
                Text("Turn on what you'd like. You can change these anytime.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                row("bell.badge.fill", .red, "Notifications", "Your phone's notifications, calls and messages on this Mac.") {
                    if notifications == .authorized || notifications == .provisional { allowed } else {
                        Button(notifications == .denied ? "Open Settings" : "Allow") { allowNotifications() }
                    }
                }
                Divider().padding(.leading, 58)
                row("power", .green, "Open at login", "Stay connected to your phone after you restart.") {
                    Toggle("", isOn: Binding(get: { loginItem }, set: setLogin)).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 58)
                row("cursorarrow.motionlines", .indigo, "Phone as mouse and keyboard", "Optional: control this Mac from your phone's touchpad.") {
                    if accessibility { allowed } else {
                        Button("Allow") {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Janus also asks to find devices on your local network the first time it looks for your phone.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .task { await refresh() }
        .onReceive(timer) { _ in Task { await refresh() } }
    }

    private var allowed: some View {
        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        loginItem = SMAppService.mainApp.status == .enabled
        accessibility = AXIsProcessTrusted()
    }

    private func allowNotifications() {
        if notifications == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    private func setLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

/// The welcome window: shown once, on first launch with nothing paired yet.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()
    private(set) var window: NSWindow?

    /// First launch: not seen before and no paired devices (people who already use Janus never see it).
    func showIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "welcome.done") else { return }
        if !AppModel.shared.pairedDevices.isEmpty { d.set(true, forKey: "welcome.done"); return }
        show()
    }

    func show(page: WelcomeView.Page = .hello) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let host = NSHostingController(rootView: WelcomeView(start: page) { [weak self] in self?.window?.close() }
            .environment(AppModel.shared).tint(.janus))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to Janus"
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "welcome.done")
        window = nil
    }
}
