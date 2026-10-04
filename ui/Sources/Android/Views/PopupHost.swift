import AppKit
import SwiftUI

/// The one popup under the menu bar icon. Calls, calendar reminders, received files and Mac messages each keep
/// their own state; this shows whichever are active as a stack of cards in a single popover (most important
/// first), so they never cover or replace each other.
/// - Held (not shown) while the menu bar panel is open (it shows the same things) and while the Mac is locked;
///   shown again when the panel closes or the Mac unlocks, if anything is still active.
/// - Order: call, Mac messages that need an answer, calendar reminders, received files, other Mac messages.
@MainActor
final class PopupHost: NSObject, NSPopoverDelegate {
    static let shared = PopupHost()

    private var popover: NSPopover?
    private var anchorWindow: NSWindow?

    var isShown: Bool { popover?.isShown == true }
    /// The popup's window (diagnostics).
    var window: NSWindow? { popover?.contentViewController?.view.window }

    var hasCards: Bool {
        CallPopup.shared.call != nil || MacPopup.shared.content != nil
            || !CalendarPopup.shared.cards.isEmpty || ReceivePopup.shared.isActive || !BannerCenter.shared.banners.isEmpty
    }

    /// Whether a popup can appear at all (a notification is used otherwise).
    var canShow: Bool { !MacState.isLocked && anchor() != nil }

    /// Shows, resizes or closes the popup to match what's active.
    func refresh() {
        guard hasCards, !StatusItemController.shared.isPanelShown, !MacState.isLocked else {
            if isShown { popover?.performClose(nil) }
            return
        }
        guard let anchor = anchor() else { return }
        let p = popover ?? {
            let p = NSPopover()
            p.behavior = .applicationDefined      // stays until its cards are done or dismissed
            p.animates = true
            p.delegate = self
            let host = NSHostingController(rootView: PopupStack().tint(.janus))
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            return p
        }()
        popover = p
        if !p.isShown { p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
    }

    /// Release the popover once closed: a hidden one keeps its views (and their timers) alive.
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    /// Our menu bar button, or (when the menu bar hides it) an invisible 2×1 pt window where it would be.
    private func anchor() -> NSView? {
        if let b = StatusItemController.shared.button, b.window?.isVisible == true { return b }
        guard let icon = ReceivePopup.statusItemFrame() else { return nil }
        let w = anchorWindow ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            return w
        }()
        anchorWindow = w
        w.setFrame(NSRect(x: icon.midX - 1, y: icon.minY - 1, width: 2, height: 1), display: false)
        w.orderFrontRegardless()
        return w.contentView
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
