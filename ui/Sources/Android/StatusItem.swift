import AppKit
import Observation
import SwiftUI

/// SwiftUI's scene actions (open the main window / Settings), captured once at launch by a tiny helper
/// window, so AppKit code (the status item, notifications, Shortcuts) can use them later.
@MainActor
enum SceneActions {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    static func showMainWindow(_ section: Pane? = nil) {
        if let section { AppModel.shared.section = section }
        // Just launched (by a widget's link, say): the scene's actions aren't captured yet; the model opens it.
        if let openWindow { AppModel.shared.mainWindowOpens += 1; openWindow(id: "main") } else { AppModel.shared.wantsMainWindow = true }
        NSApp.activate()
    }

    /// Settings live in the main window.
    static func showSettings() { showMainWindow(.settings) }
}

/// Invisible helper scene content: captures the actions, then closes itself.
struct SceneActionCatcher: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                SceneActions.openWindow = openWindow
                SceneActions.openSettings = openSettings
                DispatchQueue.main.async { dismissWindow(id: "scene-actions") }
                StatusItemController.shared.sceneActionsReady()
            }
    }
}

/// Closes whichever menu bar popover the view lives in.
struct ClosePanelKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}
extension EnvironmentValues {
    var closePanel: @MainActor () -> Void {
        get { self[ClosePanelKey.self] }
        set { self[ClosePanelKey.self] = newValue }
    }
}

/// Our menu bar icon and its panel: a real popover (arrow, smooth open/close and resize animations).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    static let shared = StatusItemController()

    private(set) var item: NSStatusItem?
    private var popover: NSPopover?
    private var pendingMainWindow = false

    var button: NSStatusBarButton? { item?.button }
    var isPanelShown: Bool { popover?.isShown == true }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        shownLabel = ""   // a new item shows nothing yet
        item.button?.image = MenuBarLabel.icon
        // (The expanded-interface API is in the macOS 27 SDK: Xcode 27 / Swift 6.4. Older Xcodes build without it.)
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), Self.usesExpandedInterface {
            // macOS 27: the panel is the item's "expanded interface", so it behaves like Apple's menu bar items
            // (opens while sliding across the menu bar with a menu open, keyboard navigation).
            item.expandedInterfaceDelegate = self
        } else {
            item.button?.target = self
            item.button?.action = #selector(togglePanel(_:))
        }
        #else
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        #endif
        item.button?.setAccessibilityLabel("Janus")
        self.item = item
        // Drop files, links or text on the icon to send them to the phone. The status bar window
        // forwards drag events to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL, .URL, .string])
        item.button?.window?.delegate = self
        observeModel()
    }

    static var usesExpandedInterface: Bool { UserDefaults.standard.object(forKey: "statusItem.expanded") as? Bool ?? false }

    @objc private func togglePanel(_ sender: Any?) {
        if isPanelShown { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button else { return }
        // A card on screen (reminder, call, file) is a popover on the same button: AppKit won't open a second one
        // there, and closing it in the same moment reads as a click outside, which closes the panel again. So the
        // card steps aside first (its cards stay, and come back when the panel closes), and the panel opens a beat later.
        if PopupHost.shared.isShown {
            PopupHost.shared.stepAside()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.showPanel() }
            return
        }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        NSApp.activate()
        popover.animates = true   // native open animation
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        PopupHost.shared.refresh()   // the popup steps aside while the panel is open (its cards stay)
        popover.contentViewController?.view.window?.makeKey()
        AppModel.shared.uiVisibilityChanged()   // latency, live progress: refreshed while it's open
        if ClipboardHistory.enabled { ClipboardHistory.shared.check() }   // what was just copied shows at once
    }

    /// Developer probe: during the next ~0.8 s, record where the SwiftUI content's top edge is relative
    /// to the popover's top edge on screen (should stay constant).
    func sampleContentAlignment(completion: @escaping ([String]) -> Void) {
        guard let window = popover?.contentViewController?.view.window,
              let root = popover?.contentViewController?.view else { completion(["no popover"]); return }
        func hostingView(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).contains("HostingView") { return v }
            for s in v.subviews { if let f = hostingView(s) { return f } }
            return nil
        }
        let content = hostingView(root) ?? root
        var samples: [String] = []
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
            MainActor.assumeIsolated {
                let r = window.convertToScreen(content.convert(content.bounds, to: nil))
                samples.append(String(format: "gap=%.0f h=%.0f", window.frame.maxY - r.maxY, window.frame.height))
                n += 1
                if n >= 96 { t.invalidate(); completion(samples) }
            }
        }
    }

    // MARK: Size animation
    // SwiftUI reports only the final size of an animated layout, so the popover's edge is animated here
    // with the same curve as the content's `.smooth(duration: 0.32)` (a critically damped spring,
    // response 0.32 s): x(t) = 1 − (1 + ωt)·e^(−ωt), ω = 2π / 0.32. Edge and content move together.

    private var sizeTimer: Timer?

    private func animatePopover(to target: NSSize) {
        guard let p = popover else { return }
        sizeTimer?.invalidate()
        guard p.isShown else { p.contentSize = target; return }
        let start = p.contentSize
        guard start != target else { return }
        let t0 = CACurrentMediaTime()
        let omega = 2 * Double.pi / 0.32
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak p] t in
            MainActor.assumeIsolated {
                guard let p else { t.invalidate(); return }
                let x = CACurrentMediaTime() - t0
                let progress = x >= 0.6 ? 1 : 1 - (1 + omega * x) * exp(-omega * x)
                p.contentSize = NSSize(width: target.width,
                                       height: (start.height + (target.height - start.height) * progress).rounded())
                if progress >= 1 { t.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sizeTimer = timer
    }

    func closePanel() {
        popover?.animates = true   // native close animation
        popover?.performClose(nil)
    }

    /// Once open, the popover follows SwiftUI's own (animated) size frame by frame; its separate resize
    /// animation would otherwise run out of step with the content.
    func popoverDidShow(_ notification: Notification) { popover?.animates = false }
    func popoverWillClose(_ notification: Notification) { popover?.animates = true }

    /// Release the panel once closed: a hidden popover keeps its views alive, and their timers and
    /// animations would keep using CPU. It's rebuilt (quickly) on the next open.
    func popoverDidClose(_ notification: Notification) {
        AppModel.shared.uiVisibilityChanged()
        sizeTimer?.invalidate()
        popover?.contentViewController = nil
        popover = nil
        // Closed by a click elsewhere or an action inside: end the menu bar's tracking of it too.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { item?.expandedInterfaceSession?.cancel() }
        #endif
        PopupHost.shared.refresh()   // cards still active come back
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient          // closes when you click elsewhere, like other menu bar extras
        p.animates = true
        p.delegate = self
        let root = MenuBarPanel()
            .tint(.janus)
            .environment(AppModel.shared)
            .environment(\.closePanel, { [weak self] in self?.closePanel() })
        if UserDefaults.standard.bool(forKey: "debug.plainHost") {   // developer A/B: the old hosting
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
        } else {
            let host = TopPinnedHostingController(rootView: root)
            host.onSizeChange = { [weak self] size in self?.animatePopover(to: size) }
            p.contentViewController = host
        }
        return p
    }

    // MARK: Drop on the icon

    private var dropTarget: Device? {
        let model = AppModel.shared
        if let d = model.selectedDevice, d.isReachable { return d }
        return model.connectedDevices.first(where: DeviceTrust.isMine) ?? model.connectedDevices.first
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropTarget != nil else { return [] }
        button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropTarget == nil ? [] : .copy }

    func draggingExited(_ sender: NSDraggingInfo?) { button?.highlight(false) }

    func draggingEnded(_ sender: NSDraggingInfo) { button?.highlight(false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        guard let device = dropTarget else { return false }
        let pb = sender.draggingPasteboard
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            device.share(files)
            let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            MacPopup.shared.show(.init(symbol: "paperplane.fill", tint: .blue, title: "Sending \(what)", subtitle: "To \(device.name)"))
            return true
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme?.hasPrefix("http") == true {
            device.shareText(url.absoluteString)
            MacPopup.shared.show(.init(symbol: "safari.fill", tint: .blue, title: "Link sent", subtitle: "Opening on \(device.name)"))
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            device.shareText(text)
            MacPopup.shared.show(.init(symbol: "text.quote", tint: .blue, title: "Text sent", subtitle: "To \(device.name)"))
            return true
        }
        return false
    }

    // MARK: Model observation (icon dimming, opening the main window on request)

    private func observeModel() {
        withObservationTracking {
            let model = AppModel.shared
            let connected = !model.connectedDevices.isEmpty
            item?.button?.alphaValue = connected ? 1 : 0.5
            if model.wantsMainWindow { pendingMainWindow = true }
            _ = model.connectedDevices.map(\.live)
            _ = model.connectedDevices.map(\.activeCall)
        } onChange: {
            Task { @MainActor in self.observeModel() }
        }
        if pendingMainWindow { openMainWindowIfReady() }
        updateLiveLabel()
    }

    // MARK: Live activity next to the icon

    private var liveTimer: Timer?
    static var showsLiveLabel: Bool { UserDefaults.standard.object(forKey: "live.menuBar") as? Bool ?? true }

    /// "8 min", "12:04" or "62%" next to the icon while something is live on the phone.
    /// The label currently shown (to skip redrawing an unchanged one).
    private var shownLabel = ""

    func updateLiveLabel() {
        guard let item, let button = item.button else { return }
        let activity = Self.showsLiveLabel ? AppModel.shared.connectedDevices.lazy.compactMap(\.headlineActivity).first : nil
        let call = Self.showsLiveLabel ? AppModel.shared.connectedDevices.lazy.compactMap(\.activeCall).first : nil
        let calendar = CalendarStore.shared
        let now = Date()
        // An event starting right now briefly beats a live activity; otherwise the calendar comes last.
        let imminent = call == nil ? calendar.imminent(at: now) : nil
        let liveText = activity?.label(at: now)
        let meeting = call != nil ? nil : imminent ?? (liveText == nil ? calendar.headline(at: now) : nil)
        // The tooltip names whatever the text had to leave out.
        let alsoMeeting = liveText != nil && imminent == nil ? calendar.headline(at: now)?.text : nil
        let alsoLive = imminent != nil ? liveText.map { t in [activity?.title, t].compactMap { $0 }.joined(separator: " ") } : nil
        // What the item should show; the menu bar is only touched when it changes (a tick usually changes nothing).
        let label: (text: String, tooltip: String?, green: Bool)?
        if let call {
            label = (" " + CallTimer.format(Date().timeIntervalSince(call.start)), "On call with \(call.name.isEmpty ? call.number : call.name)", true)
        } else if let meeting, imminent != nil || liveText == nil {
            label = (" " + meeting.text, (["\(meeting.event.title) · \(meeting.event.timeRange)"] + [alsoLive].compactMap { $0 }).joined(separator: "\n"), false)
        } else if let text = liveText {
            label = (" " + text, ([[activity?.app, activity?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")]
                                  + [alsoMeeting].compactMap { $0 }).joined(separator: "\n"), false)
        } else {
            label = nil
        }
        let key = label.map { "\($0.green)|\($0.text)|\($0.tooltip ?? "")" } ?? ""
        if key != shownLabel {
            shownLabel = key
            if let label {
                item.length = NSStatusItem.variableLength
                button.imagePosition = .imageLeading
                var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)]
                if label.green { attrs[.foregroundColor] = NSColor.systemGreen }
                button.attributedTitle = NSAttributedString(string: label.text, attributes: attrs)
                button.toolTip = label.tooltip
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
                button.toolTip = nil
                item.length = NSStatusItem.squareLength
            }
        }
        // A running clock ticks every second; a calendar countdown (whole minutes) every 30 s; nothing else ticks.
        let interval: TimeInterval? = call != nil || activity?.needsTicking(at: .now) == true ? 1
            : calendar.showInMenuBar && calendar.needsTicking(at: .now) ? 30 : nil
        if interval != liveTimer?.timeInterval {
            liveTimer?.invalidate()
            liveTimer = nil
            if let interval {
                let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { self.updateLiveLabel() } }
                t.tolerance = interval == 1 ? 0.05 : 5   // lets macOS batch the wake-ups
                RunLoop.main.add(t, forMode: .common)
                liveTimer = t
            }
        }
    }

    func sceneActionsReady() { openMainWindowIfReady() }

    private func openMainWindowIfReady() {
        guard pendingMainWindow, SceneActions.openWindow != nil else { return }
        pendingMainWindow = false
        AppModel.shared.wantsMainWindow = false
        closePanel()
        SceneActions.showMainWindow()
    }
}


// MARK: Top-pinned hosting

/// Hosts SwiftUI content pinned to the TOP of the popover. AppKit views grow from the bottom-left,
/// so during a resize a plain hosting controller shows its content shifted up (growing) or down
/// (shrinking) for a frame or two. Here the container is flipped and the content sits at y = 0,
/// so resizing only ever happens at the bottom edge, and the popover size follows the content's
/// (animated) size on every frame.
final class TopPinnedHostingController<Content: View>: NSViewController {
    /// Called with the content's size on every layout pass, including each animation frame.
    var onSizeChange: ((NSSize) -> Void)?
    private let sink = SizeSink()
    private let hosting: NSHostingView<AnyView>
    /// The hosting view is taller than the content; the popover's size decides how much shows.
    private static var canvasHeight: CGFloat { 900 }

    init(rootView: Content) {
        let sink = self.sink
        hosting = NSHostingView(rootView: AnyView(
            rootView
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { sink.report($0) }
                .frame(maxHeight: .infinity, alignment: .top)))
        super.init(nibName: nil, bundle: nil)
        sink.onChange = { [weak self] size in self?.apply(size) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = FlippedView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        hosting.sizingOptions = []
        container.addSubview(hosting)
        view = container
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.canvasHeight)
        preferredContentSize = NSSize(width: size.width, height: min(size.height, Self.canvasHeight))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hosting.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: Self.canvasHeight)   // glued to the top
    }

    private var lastSize: NSSize = .zero

    /// Only reports the size; the popover animates to it (setting preferredContentSize would make
    /// NSPopover jump there instantly).
    private func apply(_ size: CGSize) {
        let s = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard s.width > 0, s.height > 0, s != lastSize else { return }
        lastSize = s
        onSizeChange?(s)
    }
}

final class SizeSink {
    var onChange: ((CGSize) -> Void)?
    func report(_ size: CGSize) { DispatchQueue.main.async { self.onChange?(size) } }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


#if compiler(>=6.4)
@available(macOS 27.0, *)
extension StatusItemController: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        if !isPanelShown { showPanel() }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if isPanelShown { closePanel() }
    }
}
#endif
