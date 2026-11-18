import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the notch shows beside the camera while closed: the menu bar's text (a call, a live activity, a meeting…).
struct NotchLabel: Equatable {
    var text: String
    var icon: String?
    var green = false
    /// A call or a meeting starting now: shown over the music.
    var urgent = false
    /// Something running (a timer, a ride, a transfer): shares the notch with the music (artwork left, this right).
    var live = false
}

/// Janus in the MacBook's notch, on the built-in display only. Three states:
/// - idle: an island the size of the camera housing, invisible against it;
/// - closed with something live (music, a call, a timer, a meeting): the island grown sideways, beside the camera;
/// - open: resting the pointer on the notch opens it (Spotify while it plays, files, the notes you chose); dragging
///   files onto it opens it too, to send them to the phone.
/// Notifications stay in the menu bar.
///
/// The window is a fixed, transparent panel over the top middle of the display; only the island in it is drawn, and
/// clicks on the rest go through to what's below. It never takes the keyboard.
@MainActor @Observable
final class NotchController {
    static let shared = NotchController()

    enum Mode { case closed, open }

    /// Closed-state text beside the camera, set by the menu bar item (which works it out).
    var label: NotchLabel?
    private(set) var mode: Mode = .closed
    /// Something is being dragged over the island.
    private(set) var dropTargeted = false
    /// Opened while Spotify played: pausing it from here keeps the player until the notch closes.
    private(set) var keepsPausedTrack = false
    /// A menu from the notch is open: it stays open meanwhile.
    @ObservationIgnored private var menuOpen = false
    /// The camera housing, in points.
    private(set) var notchSize = CGSize(width: 185, height: 32)
    /// The island's current size (reported by the view), for noticing when the pointer has left it.
    @ObservationIgnored var islandSize: CGSize = .zero

    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var exitWatch: Timer?
    @ObservationIgnored private var screensTask: Task<Void, Never>?

    /// Room for the largest state (open) and its shadow.
    static let windowSize = CGSize(width: 700, height: 460)
    static let openWidth: CGFloat = 480

    static var enabled: Bool { UserDefaults.standard.object(forKey: "notch.enabled") as? Bool ?? true }
    static var musicEnabled: Bool { UserDefaults.standard.object(forKey: "notch.music") as? Bool ?? true }

    /// The built-in display, when it has a notch.
    static var notchedScreen: NSScreen? {
        NSScreen.screens.first { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) != 0 else { return false }
            return s.safeAreaInsets.top > 0 && s.auxiliaryTopLeftArea != nil && s.auxiliaryTopRightArea != nil
        }
    }

    static var hasNotch: Bool { notchedScreen != nil }

    var isActive: Bool { panel?.isVisible == true }

    /// The panel (for test snapshots).
    var window: NSPanel? { panel }

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.screensChanged() }
        }
        update()
    }

    /// Displays come and go in bursts (lid, dock, resolution): settle first.
    private func screensChanged() {
        screensTask?.cancel()
        screensTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// Shows, moves or removes the notch window to match the displays and the setting.
    func update() {
        guard Self.enabled, let screen = Self.notchedScreen,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            panel?.orderOut(nil)
            panel = nil
            mode = .closed
            MacNowPlaying.shared.stop()
            StatusItemController.shared.updateLiveLabel()   // what the notch showed goes back to the menu bar
            return
        }
        notchSize = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        let size = Self.windowSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let p = panel ?? NotchPanel()
        if p.frame != frame {
            // Moving a visible window between displays stretches it on the way: out, move, back in.
            p.orderOut(nil)
            p.setFrame(frame, display: false)
        }
        panel = p
        if !p.isVisible { p.orderFrontRegardless() }
        // This Mac's music (the phone's comes with the phone): read only while the notch can show it.
        if Self.musicEnabled { MacNowPlaying.shared.start() } else { MacNowPlaying.shared.stop() }
        StatusItemController.shared.updateLiveLabel()   // the menu bar leaves what's running to the notch
    }

    // MARK: Opening on hover

    static let opening = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let closing = Animation.spring(response: 0.45, dampingFraction: 1)

    /// The pointer entered or left the island. Resting on it for a moment opens Janus; leaving closes it.
    func hover(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        if inside {
            guard mode == .closed else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.hovering, self.mode == .closed else { return }
                self.open()
            }
        } else if mode == .open, !dropTargeted, !menuOpen {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, !self.hovering, !self.dropTargeted, !self.menuOpen else { return }
                self.close()
            }
        }
    }

    /// Testing: hold the open view and a sample label, whatever the pointer and the menu bar do.
    @ObservationIgnored var debugHold = false
    /// Testing: a track to show as playing (without playing anything).
    var debugTrack: NotchTrack?
    /// Testing: as if nothing played (to watch music appear and go without touching Spotify).
    var debugSilent = false

    /// Testing: open as if the pointer rested on it.
    func debugOpen() { debugHold = true; hovering = true; open() }

    private func open() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        keepsPausedTrack = NotchTrack.current() != nil
        withAnimation(Self.opening) { mode = .open }
        watchExit()
    }

    /// Closes the open view (an action in it opened a window, or the pointer left).
    func close() {
        stopExitWatch()
        guard mode == .open else { return }
        withAnimation(Self.closing) { mode = .closed }
        keepsPausedTrack = false
    }

    /// AppKit can miss the pointer leaving when it moves fast (up to a display above, say): while open, check where
    /// it is a few times a second.
    private func watchExit() {
        stopExitWatch()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = NotchController.shared
                guard c.mode == .open, !c.dropTargeted, !c.menuOpen, !c.debugHold, let frame = c.islandFrame else { return }
                if !frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { c.hovering = false; c.close() }
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        exitWatch = t
    }

    private func stopExitWatch() { exitWatch?.invalidate(); exitWatch = nil }

    /// Shows a menu from the notch (it stays open meanwhile), then closes if the pointer has gone.
    func popUp(_ menu: NSMenu, from view: NSView?, at point: NSPoint) {
        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: view)
        menuOpen = false
        if let frame = islandFrame, !frame.contains(NSEvent.mouseLocation) { hovering = false; close() }
    }

    /// The island on screen: centred at the top of the window.
    private var islandFrame: NSRect? {
        guard let p = panel, islandSize.width > 0 else { return nil }
        return NSRect(x: p.frame.midX - islandSize.width / 2, y: p.frame.maxY - islandSize.height,
                      width: islandSize.width, height: islandSize.height)
    }

    // MARK: Dropping files, links and text

    func setDropTargeted(_ on: Bool) {
        guard dropTargeted != on else { return }
        dropTargeted = on
        if on {
            hoverTask?.cancel()
            if mode == .closed { open() }
        } else if mode == .open, !hovering {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, !self.hovering, !self.dropTargeted else { return }
                self.close()
            }
        }
    }

    /// Sends what was dropped to the phone (files, else a link, else text), like dropping it on the menu bar icon.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let device = AppModel.shared.phone, !providers.isEmpty else { return false }
        Task {
            var files: [URL] = [], link: URL?, text: String?
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await Self.load(URL.self, from: p) {
                    if url.isFileURL { files.append(url) } else if link == nil { link = url }
                } else if text == nil, let s = await Self.load(String.self, from: p) {
                    text = s
                }
            }
            _ = StatusItemController.send(files: files, link: link, text: text, to: device)
        }
        return true
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from p: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: type) { value, _ in c.resume(returning: value) }
        }
    }

    // MARK: Notes

    /// The notes chosen for the notch, in the order they were chosen.
    var noteIDs: [String] {
        get { access(keyPath: \.noteIDs); return UserDefaults.standard.stringArray(forKey: "notch.notes") ?? [] }
        set { withMutation(keyPath: \.noteIDs) { UserDefaults.standard.set(newValue, forKey: "notch.notes") } }
    }

    func toggleNote(_ id: String) {
        if noteIDs.contains(id) { noteIDs.removeAll { $0 == id } } else { noteIDs.append(id) }
    }
}

/// The notch window: transparent, above the menu bar's status items (below its menus), on every Space and over
/// full-screen apps, never the active window or the key one (it has nothing to type in).
private final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: NotchController.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: NotchRootView().tint(.janus))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
