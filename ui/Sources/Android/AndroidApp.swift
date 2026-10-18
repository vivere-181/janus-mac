import AppKit
import SwiftUI

@main
struct AndroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // The menu bar icon and panel are AppKit (StatusItemController): a real popover animates.
        // This invisible helper only captures SwiftUI's open-window/settings actions at launch.
        Window("Janus Helper", id: "scene-actions") {
            SceneActionCatcher()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Window("Janus", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) }; UpdateWindow.shared.show() }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Janus") { WelcomeWindow.shared.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SceneActions.showMainWindow(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }


    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            if openOnLaunch { model?.wantsMainWindow = true }
            if let model, oldValue == nil, UserDefaults.standard.bool(forKey: "debugSnapshots") {
                DebugSnapshot.install(model: model)
            }
        }
    }
    private var openOnLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel.shared
        StatusItemController.shared.install()
        MacState.install()
        QuickNoteHotKey.shared.register()
        AppIcon.install()
        NoteAttachments.shared.cleanUp()
        NotesWidgets.start()
        CloudService.shared.start()
        ClipboardHistory.shared.start()
        Updater.shared.start()
        // Open the window when the user launches the app, but stay in the menu bar when started at login.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        // Nor when launched to open something (a widget's note opens in its own window, a phone action just runs).
        let defaultLaunch = notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
        openOnLaunch = !atLogin && defaultLaunch && !UserDefaults.standard.bool(forKey: "startHidden")
        if openOnLaunch { model?.wantsMainWindow = true }
        // First launch with nothing paired: the welcome (R41). Decided once the engine has listed the devices.
        if !UserDefaults.standard.bool(forKey: "welcome.done") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                WelcomeWindow.shared.showIfNeeded()
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// janus://action/… (Mac actions from the phone), janus://notes/… (the Notes widgets) and tel: links (click to
    /// call). Through the delegate rather than an Apple event handler of our own: replacing AppKit's left an app
    /// launched by a link stuck before it finished launching.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLRouter.handle)
    }

    /// Finder / right-click "Services" entry (NSMessage = sendToPhone in Info.plist).
    @objc func sendToPhone(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let device = model?.selectedDevice, device.isReachable else {
            error.pointee = "No phone is connected." as NSString
            return
        }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            device.share(urls)
        } else if let text = pboard.string(forType: .string) {
            device.shareText(text)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.wantsMainWindow = true
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Shows a Dock icon only while the main window is open, like modern menu bar utilities.
enum DockPresence {
    @MainActor static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    @MainActor static func update() {
        if UserDefaults.standard.bool(forKey: "noDockToggle") { return }
        // The main window or a note's own window: the app is in the Dock and the app switcher while one is open.
        let visible = NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue == "main" || $0.identifier?.rawValue.hasPrefix("note:") == true) }
        AppModel.shared.uiVisibilityChanged()
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            AppIcon.apply()   // the Dock tile takes the chosen icon
            if visible { NSApp.activate() }
        }
    }
}
