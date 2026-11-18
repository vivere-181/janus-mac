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
        // The icon's middle, and the menu bar's bottom edge (the icon's slot is taller than the icon).
        let barBottom = StatusItemController.shared.button?.window?.frame.minY ?? icon.minY
        p.anchor = NSRect(x: icon.minX, y: barBottom, width: icon.width, height: max(icon.maxY - barBottom, 1))
        if !p.isVisible {
            p.fit()
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        }
        keyboard(p)
    }

    /// The cards' window has the keyboard only while a reply is typed.
    private func keyboard(_ w: NSWindow) {
        if typing, !w.isKeyWindow {
            w.makeKey()
        } else if !typing, w.isKeyWindow {
            // Ordering out hands the keyboard back to the window you were in; back in front at once, unchanged.
            w.orderOut(nil)
            w.orderFrontRegardless()
        }
    }

    /// The cards' size changed (one came or went, a stack expanded, a reply field opened): refit the panel on the
    /// next turn of the run loop, outside the layout pass that noticed.
    func cardsResized() {
        DispatchQueue.main.async { [weak self] in self?.panel?.fit() }
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
    /// The menu bar icon's horizontal extent, from the menu bar's bottom edge up (screen coordinates).
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
        host.sizingOptions = [.intrinsicContentSize]
        host.onResize = { [weak self] in self?.fit() }
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let container = NSView()
        container.addSubview(effect)
        container.addSubview(host)
        contentView = container
    }

    private let host = CardHostingView(rootView: AnyView(PopupStack().tint(.janus)))
    /// The popover material, shaped like a popover: the body with an arrow pointing at the icon.
    private let effect = NSVisualEffectView()
    private var shape: (size: NSSize, arrowX: CGFloat, radius: CGFloat)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Sized to the cards and placed under the icon (top edge fixed). Called after the cards change, never from
    /// inside a layout pass: resizing the window from layout (what NSHostingController's window sizing does, with
    /// the panel then moving itself) fed back into layout until the stack ran out.
    func fit() {
        let content = host.fittingSize
        guard content.width > 0, content.height > 0 else { return }
        let size = NSSize(width: content.width, height: content.height + CardShape.arrowHeight)
        let target = placed(size)
        if target != frame { setFrame(target, display: isVisible) }
        if host.frame.size != content { host.frame = NSRect(origin: .zero, size: content) }
        effect.frame = NSRect(origin: .zero, size: size)
        let next = (size: size, arrowX: anchor.midX - target.minX, radius: CGFloat(PopupStack.isStacked ? 26 : 18))
        if shape.map({ $0.size != next.size || $0.arrowX != next.arrowX || $0.radius != next.radius }) ?? true {
            shape = next
            effect.maskImage = CardShape.mask(size: next.size, arrowX: next.arrowX, radius: next.radius)
            invalidateShadow()
        }
    }

    private func placed(_ size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, bounds.minX + 8), bounds.maxX - 8 - size.width)
        // The arrow's tip just under the menu bar, like a popover's.
        return NSRect(x: x.rounded(), y: (anchor.minY - 2 - size.height).rounded(), width: size.width, height: size.height)
    }
}

/// The card panel's outline: a rounded body with a popover arrow on top, its tip at `arrowX` (kept clear of the
/// corners when the panel has to shift to stay on screen).
private enum CardShape {
    static let arrowWidth: CGFloat = 22
    static let arrowHeight: CGFloat = 9

    static func mask(size: NSSize, arrowX: CGFloat, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let top = size.height - arrowHeight
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size.width, height: top), xRadius: radius, yRadius: radius).fill()
            let half = arrowWidth / 2
            let x = min(max(arrowX, radius + half), size.width - radius - half)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x - half, y: top - 1))
            arrow.curve(to: NSPoint(x: x, y: size.height),
                        controlPoint1: NSPoint(x: x - half * 0.45, y: top), controlPoint2: NSPoint(x: x - 2.2, y: size.height))
            arrow.curve(to: NSPoint(x: x + half, y: top - 1),
                        controlPoint1: NSPoint(x: x + 2.2, y: size.height), controlPoint2: NSPoint(x: x + half * 0.45, y: top))
            arrow.close()
            arrow.fill()
            return true
        }
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

    fileprivate enum Card: Hashable {
        case call, mac, calendar(String), receive, banner(String)
    }

    /// What's active, in order.
    fileprivate static var cards: [Card] {
        let mac = MacPopup.shared.content
        let banners = BannerCenter.shared.banners
        var cards: [Card] = []
        if CallPopup.shared.call != nil { cards.append(.call) }
        if mac?.stays == true { cards.append(.mac) }
        cards += banners.filter(\.important).map { .banner($0.id) }
        cards += CalendarPopup.shared.cards.map { .calendar($0.alertKey) }
        cards += banners.filter { !$0.important }.map { .banner($0.id) }
        if ReceivePopup.shared.isActive { cards.append(.receive) }
        if let mac, !mac.stays { cards.append(.mac) }
        return cards
    }

    /// Several cards: separate platters on a larger panel.
    static var isStacked: Bool { cards.count > 1 }

    var body: some View {
        let banners = BannerCenter.shared.banners
        let cards = Self.cards
        let notifications = banners.filter { !$0.important }

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
        // The panel draws the popover material and arrow behind this; corners concentric with the platters'.
        .clipShape(RoundedRectangle(cornerRadius: stacked ? 26 : 18, style: .continuous))
        // The panel follows the cards' natural size (the hosting view doesn't report it as a subview).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in PopupHost.shared.cardsResized() }
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
