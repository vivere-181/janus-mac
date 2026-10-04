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
        ClipboardHistory.shared.start()
        // Open the window when the user launches the app, but stay in the menu bar when started at login.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        openOnLaunch = !atLogin && !UserDefaults.standard.bool(forKey: "startHidden")
        if openOnLaunch { model?.wantsMainWindow = true }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        // janus://action/… (Mac actions from the phone) and tel: links (click to call).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
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

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s) else { return }
        URLRouter.handle(url)
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
        let visible = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            AppIcon.apply()   // the Dock tile takes the chosen icon
            if visible { NSApp.activate() }
        }
    }
}
