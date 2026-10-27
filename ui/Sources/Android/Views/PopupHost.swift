import AppKit
import SwiftUI

/// The one popup under the menu bar icon. Calls, calendar reminders, received files and Mac messages each keep
/// their own state; this shows whichever are active as a stack of cards in a single panel (most important
/// first), so they never cover or replace each other.
/// - Held (not shown) while the menu bar panel is open (it shows the same things) and while the Mac is locked;
///   shown again when the panel closes or the Mac unlocks, if anything is still active.
/// - Order: call, Mac messages that need an answer, calendar reminders, received files, other Mac messages.
/// - Like a notification, it never takes the keyboard from what you're working on (an NSPopover does, the moment
///   it appears): only while you type a reply, and it hands the keyboard back when you're done.
@MainActor
final class PopupHost {
    static let shared = PopupHost()

    private var panel: CardPanel?

    var isShown: Bool { panel?.isVisible == true }
    /// The popup's window (diagnostics).
    var window: NSWindow? { panel }

    var hasCards: Bool {
        CallPopup.shared.call != nil || MacPopup.shared.content != nil
            || !CalendarPopup.shared.cards.isEmpty || ReceivePopup.shared.isActive || !BannerCenter.shared.banners.isEmpty
    }

    /// A reply is being written in one of the cards: the only time they take the keyboard.
    private var typing: Bool { BannerCenter.shared.replyingTo != nil || CallPopup.shared.composing }

    /// Whether a popup can appear at all (a notification is used otherwise).
    var canShow: Bool { !MacState.isLocked && ReceivePopup.statusItemFrame() != nil }

    /// Shows, resizes or closes the popup to match what's active, and gives or returns the keyboard.
    func refresh() {
        guard hasCards, !StatusItemController.shared.isPanelShown, !MacState.isLocked else {
            close(animated: true)
            return
        }
        guard let icon = ReceivePopup.statusItemFrame() else { return }
        let p = panel ?? CardPanel()
        panel = p
        p.anchor = icon
        if !p.isVisible {
            p.fit()
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        }
        if typing, !p.isKeyWindow {
            p.makeKey()
        } else if !typing, p.isKeyWindow {
            // Ordering out hands the keyboard back to the window you were in; back in front at once, unchanged.
            p.orderOut(nil)
            p.orderFrontRegardless()
        }
    }

    /// The menu bar panel is opening: out of its way at once, without animation (the cards are kept).
    func stepAside() { close(animated: false) }

    /// Closed and released: a hidden one keeps its views (and their timers) alive.
    private func close(animated: Bool) {
        guard let p = panel else { return }
        panel = nil
        guard animated, p.isVisible else { p.orderOut(nil); p.contentView = nil; return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 0 }
        Task {
            try? await Task.sleep(for: .seconds(0.2))
            p.orderOut(nil)
            p.contentView = nil
        }
    }
}

/// The cards' window: under the menu bar icon (centred on it, kept on screen), above other windows on every Space.
/// Non-activating, and key only when asked (a reply) or when a field in it is clicked.
private final class CardPanel: NSPanel {
    /// The menu bar icon's frame, in screen coordinates.
    var anchor: NSRect = .zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let host = CardHostingView(rootView: AnyView(PopupStack().tint(.janus)))
        host.sizingOptions = [.intrinsicContentSize]
        host.onResize = { [weak self] in self?.fit() }
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Sized to the cards and placed under the icon (top edge fixed). Called after the cards change, never from
    /// inside a layout pass: resizing the window from layout (what NSHostingController's window sizing does, with
    /// the panel then moving itself) fed back into layout until the stack ran out.
    func fit() {
        guard let host = contentView else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let target = placed(size)
        if target != frame { setFrame(target, display: isVisible) }
    }

    private func placed(_ size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, bounds.minX + 8), bounds.maxX - 8 - size.width)
        return NSRect(x: x.rounded(), y: (anchor.minY - 6 - size.height).rounded(), width: size.width, height: size.height)
    }
}

/// The cards' SwiftUI view. When what they need changes, the panel refits on the next turn of the run loop.
private final class CardHostingView: NSHostingView<AnyView> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

/// The cards, stacked with hairlines between them. With more than one, all take the same width.
/// The cards. One card fills the popup; several are separate platters with gaps (like a Notification Center
/// group), and beyond two notifications the older ones fold into a "+N more" stack that expands on click.
struct PopupStack: View {
    static let width: CGFloat = 300
    static let platter = RoundedRectangle(cornerRadius: 18, style: .continuous)

    private enum Card: Hashable {
        case call, mac, calendar(String), receive, banner(String)
    }

    var body: some View {
        let mac = MacPopup.shared.content
        let banners = BannerCenter.shared.banners
        var cards: [Card] = []
        if CallPopup.shared.call != nil { cards.append(.call) }
        if mac?.stays == true { cards.append(.mac) }
        cards += banners.filter(\.important).map { .banner($0.id) }
        cards += CalendarPopup.shared.cards.map { .calendar($0.alertKey) }
        let notifications = banners.filter { !$0.important }
        cards += notifications.map { .banner($0.id) }
        if ReceivePopup.shared.isActive { cards.append(.receive) }
        if let mac, !mac.stays { cards.append(.mac) }

        let folded = !BannerCenter.shared.expanded && notifications.count > 2 ? Array(notifications.dropFirst(2)) : []
        let foldedIDs = Set(folded.map { Card.banner($0.id) })
        let shown = cards.filter { !foldedIDs.contains($0) }
        let stacked = cards.count > 1
        return VStack(spacing: stacked ? 8 : 0) {
            ForEach(shown, id: \.self) { card in
                view(for: card, banners: banners)
                    .background { if stacked { Self.platter.fill(Color.primary.opacity(0.06)) } }
            }
            if !folded.isEmpty {
                FoldedNotifications(banners: folded)
            } else if BannerCenter.shared.expanded, notifications.count > 2 {
                Button("Show Less") { BannerCenter.shared.expanded = false }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
        .padding(stacked ? 8 : 0)
        .environment(\.popupStacked, stacked)
        // Like a notification banner, the popup never becomes the active window, yet its buttons should look live.
        .environment(\.controlActiveState, .key)
        .frame(width: stacked ? Self.width + 16 : nil)
        // The panel itself is transparent: the cards sit on the popover material, its corners concentric with the
        // platters'. Not glass: the cards' buttons are glass, and glass on glass made SwiftUI recurse until it crashed.
        .background(PopoverMaterial())
        .clipShape(RoundedRectangle(cornerRadius: stacked ? 26 : 18, style: .continuous))
        .animation(.snappy(duration: 0.25), value: shown)
        .animation(.snappy(duration: 0.25), value: folded.count)
    }

    @ViewBuilder private func view(for card: Card, banners: [Banner]) -> some View {
        switch card {
        case .call: CallPopupView(popup: CallPopup.shared)
        case .mac: MacPopupView(popup: MacPopup.shared)
        case .receive: ReceivePopupView(popup: ReceivePopup.shared)
        case .banner(let id):
            if let b = banners.first(where: { $0.id == id }) { BannerCard(banner: b) }
        case .calendar(let key):
            if let event = CalendarPopup.shared.cards.first(where: { $0.alertKey == key }) {
                CalendarReminderCard(event: event)
            }
        }
    }
}

/// Older notifications, folded: a platter with two edges peeking out below it, like Notification Center's stacks.
private struct FoldedNotifications: View {
    let banners: [Banner]
    private let edge = UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)

    var body: some View {
        let apps = Array(NSOrderedSet(array: banners.map { $0.appName ?? $0.title }).compactMap { $0 as? String }.prefix(3))
        Button { withAnimation(.snappy) { BannerCenter.shared.expanded = true } } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(banners.count == 1 ? "1 more notification" : "\(banners.count) more notifications")
                        .font(.callout.weight(.semibold))
                    Text(apps.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: PopupStack.width, alignment: .leading)
            .background(PopupStack.platter.fill(Color.primary.opacity(0.06)))
            // The stack's edges: two strips under the platter, each a little narrower (they never overlap it,
            // since the platters are translucent).
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    edge.fill(Color.primary.opacity(0.045)).frame(height: 5).padding(.horizontal, 8)
                    edge.fill(Color.primary.opacity(0.03)).frame(height: 5).padding(.horizontal, 16)
                }
                .offset(y: 10)
            }
            .padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show all notifications")
    }
}

/// The material an NSPopover draws behind its content.
private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension EnvironmentValues {
    /// True when a card shares the popup with others (cards then take the stack's full width).
    @Entry var popupStacked = false
}

// MARK: Calendar reminders

/// Reminder cards ("Standup in 5 min", with Join). One per event; a card goes away when dismissed, a few minutes
/// after its event started, or when the event moves, is deleted or hidden.
@MainActor @Observable
final class CalendarPopup {
    static let shared = CalendarPopup()

    private(set) var cards: [CalendarEvent] = []
    var hovering = false
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Shows a reminder card; false when it can't be shown (the Mac is locked), so a notification is used.
    func remind(_ event: CalendarEvent) -> Bool {
        guard BannerCenter.enabled, PopupHost.shared.canShow else { return false }
        cards.removeAll { $0.id == event.id }
        cards.append(event)
        cards.sort { $0.start < $1.start }
        if cards.count > 3 { cards.removeFirst(cards.count - 3) }
        // Quiet while a call card is up.
        Sounds.play(Sounds.alert)
        PopupHost.shared.refresh()
        scheduleExpiry()
        return true
    }

    func dismiss(_ event: CalendarEvent) {
        cards.removeAll { $0.alertKey == event.alertKey }
        PopupHost.shared.refresh()
    }

    /// The calendar changed: drop cards whose event moved, was deleted, hidden or has ended.
    func sync(with events: [CalendarEvent]) {
        let keys = Set(events.map(\.alertKey))
        let now = Date()
        let kept = cards.filter { keys.contains($0.alertKey) && $0.end > now }
        guard kept.count != cards.count else { return }
        cards = kept
        PopupHost.shared.refresh()
    }

    /// A card stays until 5 minutes after its event started (or it ended), and while the pointer is on it.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            while let self, !Task.isCancelled, !self.cards.isEmpty {
                try? await Task.sleep(for: .seconds(15))
                guard !self.hovering else { continue }
                let now = Date()
                let kept = self.cards.filter { min($0.start.addingTimeInterval(300), $0.end) > now }
                if kept.count != self.cards.count {
                    self.cards = kept
                    PopupHost.shared.refresh()
                }
            }
        }
    }
}

struct CalendarReminderCard: View {
    let event: CalendarEvent
    @Environment(\.popupStacked) private var stacked

    var body: some View {
        let color = Color(hex: event.color) ?? .janus
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: event.join == nil ? "calendar" : "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(when(context.date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let location = event.location {
                        Text(location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if let join = event.join {
                    PopupButton(title: "Dismiss") { CalendarPopup.shared.dismiss(event) }
                    PopupButton(title: "Join", role: .primary(.janus)) {
                        NSWorkspace.shared.open(join)
                        CalendarPopup.shared.dismiss(event)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    PopupButton(title: "OK", role: .primary(.janus)) { CalendarPopup.shared.dismiss(event) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: PopupStack.width)
        .onHover { CalendarPopup.shared.hovering = $0 }
    }

    /// "In 5 min · 12:15 – 12:30", "Now · 12:15 – 12:30", "Started 3 min ago".
    private func when(_ now: Date) -> String {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded())
        let lead = minutes > 0 ? "In \(minutes) min" : minutes == 0 ? "Now" : "Started \(-minutes) min ago"
        return "\(lead) · \(event.timeRange)"
    }
}
