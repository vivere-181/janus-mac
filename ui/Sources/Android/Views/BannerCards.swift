import AppKit
import SwiftUI
import UserNotifications

/// A card in the shared popup (PopupHost) for what would otherwise be a macOS notification: phone notifications,
/// verification codes, pings, missed calls, pairing requests, links, low battery. One style for everything.
struct Banner: Identifiable {
    enum Icon {
        case symbol(String, Color)
        case image(String)          // a file (e.g. the phone app's icon)
    }

    let id: String
    /// A newer banner of the same thread (same chat, same kind) replaces the older one and counts it.
    var thread: String
    var icon: Icon
    /// Small line above the title (the phone app's name).
    var appName: String?
    var title: String
    var body: String?
    /// Shown large and monospaced (verification codes).
    var code: String?
    var count = 1
    /// Seconds on screen (paused while the pointer is on it or a reply is being typed); nil = until acted on.
    var lifetime: TimeInterval?
    /// Shown above the others (needs an answer).
    var important = false
    var sound: String?
    var actions: [BannerAction] = []
    var reply: ((String) -> Void)?
    /// A click on the card itself.
    var onOpen: (() -> Void)?
    var postedAt = Date()
}

struct BannerAction: Identifiable {
    let id = UUID()
    var title: String
    var primary = false
    var destructive = false
    var handler: () -> Void
}

/// The app's sounds (macOS system sounds), kept to three: every one-off notification (phone notifications, codes,
/// missed calls, links, files, battery, pairing, pings, reminders) sounds the same; an incoming call and Find My Mac
/// have their own. One switch turns them all off (Settings → Notifications); during a call only the call sounds.
@MainActor
enum Sounds {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notify.sounds") as? Bool ?? true }

    /// Any one-off notification.
    nonisolated static let alert = "Tink"
    /// An incoming call.
    nonisolated static let ring = "Glass"

    /// The same sounds for macOS notifications (used when cards are off or can't show).
    static var notification: UNNotificationSound? { enabled ? UNNotificationSound(named: .init(alert + ".aiff")) : nil }
    static var ringNotification: UNNotificationSound? { enabled ? UNNotificationSound(named: .init(ring + ".aiff")) : nil }

    static func play(_ name: String, duringCall: Bool = false) {
        guard enabled, duringCall || CallPopup.shared.call == nil else { return }
        NSSound(named: name)?.play()
        if UserDefaults.standard.bool(forKey: "debugSnapshots") { debugLog("sound \(name)") }
    }
}

@MainActor @Observable
final class BannerCenter {
    static let shared = BannerCenter()
    /// The owner can keep macOS notifications instead (they follow Focus, which this app can't read).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notify.popups") as? Bool ?? true }
    static let maxShown = 4

    /// Important first, then newest first.
    private(set) var banners: [Banner] = []
    var hovering = false
    var replyingTo: String?
    /// Folded notifications ("+N more") are shown in full.
    var expanded = false
    @ObservationIgnored private var expiries: [String: Date] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastPointer = NSPoint.zero
    @ObservationIgnored private var pointerMoved = Date.distantPast

    /// Shows a banner; false when it can't be shown (Mac locked, or macOS notifications preferred).
    func show(_ banner: Banner) -> Bool {
        guard Self.enabled, PopupHost.shared.canShow else { return false }
        var b = banner
        if let i = banners.firstIndex(where: { $0.thread == b.thread }) {
            b.count = banners[i].count + 1
            expiries[banners[i].id] = nil
            banners.remove(at: i)
        }
        banners.insert(b, at: 0)
        banners.sort { ($0.important ? 0 : 1, -$0.postedAt.timeIntervalSince1970) < ($1.important ? 0 : 1, -$1.postedAt.timeIntervalSince1970) }
        while banners.count > Self.maxShown, let last = banners.lastIndex(where: { !$0.important }) {
            expiries[banners[last].id] = nil
            banners.remove(at: last)
        }
        if let life = b.lifetime { expiries[b.id] = Date().addingTimeInterval(life) }
        if ticker == nil { lastPointer = NSEvent.mouseLocation }   // where the pointer already was doesn't count as moving
        // Quiet during a call; the call card has the attention.
        if let sound = b.sound { Sounds.play(sound) }
        PopupHost.shared.refresh()
        tick()
        return true
    }

    func dismiss(_ id: String) {
        guard banners.contains(where: { $0.id == id }) else { return }
        banners.removeAll { $0.id == id }
        expiries[id] = nil
        if replyingTo == id { replyingTo = nil }
        if banners.filter({ !$0.important }).count <= 2 { expanded = false }
        PopupHost.shared.refresh()
    }

    /// Banners leave on their own after their lifetime; time stands still while one is replied to, or pointed at
    /// by a pointer that's being used (one that merely rests where a card happened to appear doesn't count).
    private func tick() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.expiries.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                let pointer = NSEvent.mouseLocation
                if pointer != self.lastPointer { self.lastPointer = pointer; self.pointerMoved = Date() }
                let reading = self.hovering && Date().timeIntervalSince(self.pointerMoved) < 8
                if reading || self.replyingTo != nil {
                    for (id, date) in self.expiries { self.expiries[id] = date.addingTimeInterval(1) }
                    continue
                }
                let now = Date()
                let gone = self.expiries.filter { $0.value <= now }.map(\.key)
                gone.forEach { self.dismiss($0) }
            }
            self?.ticker = nil
        }
    }
}

struct BannerCard: View {
    let banner: Banner
    @State private var hover = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var replying: Bool { BannerCenter.shared.replyingTo == banner.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    if let app = banner.appName, !app.isEmpty {
                        HStack {
                            Text(app).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            time
                            if banner.count > 1 {
                                Text("\(banner.count)").font(.caption2.weight(.bold)).foregroundStyle(Color.janusOn)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.janus, in: Capsule())
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(banner.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if banner.appName?.isEmpty ?? true { Spacer(minLength: 4); time }
                    }
                    if let body = banner.body, !body.isEmpty {
                        Text(NotificationText.attributed(body)).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let code = banner.code {
                Text(code).font(.system(.title, design: .monospaced).weight(.semibold)).tracking(3)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
            }
            if replying {
                HStack(spacing: 8) {
                    TextField("Reply", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(send)
                        .onAppear { fieldFocused = true }
                    PopupButton(title: "Send", role: .primary(.janus), action: send)
                        .frame(width: 70)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if banner.reply != nil || !banner.actions.isEmpty {
                HStack(spacing: 8) {
                    if banner.reply != nil {
                        PopupButton(title: "Reply", role: banner.actions.contains(where: \.primary) ? .secondary : .primary(.janus)) {
                            NSApp.activate()
                            BannerCenter.shared.replyingTo = banner.id
                        }
                    }
                    ForEach(banner.actions) { a in
                        PopupButton(title: a.title, role: a.destructive ? .destructive : a.primary ? .primary(.janus) : .secondary) {
                            a.handler()
                            BannerCenter.shared.dismiss(banner.id)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: PopupStack.width)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let open = banner.onOpen else { return }
            open()
            BannerCenter.shared.dismiss(banner.id)
        }
        .overlay(alignment: .topLeading) {
            // Close (like a notification's ×), shown while pointing at the card.
            if hover {
                Button { BannerCenter.shared.dismiss(banner.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.separator))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Close")
            }
        }
        .onHover { h in
            hover = h
            BannerCenter.shared.hovering = h
        }
    }

    /// "now", "4m", "1h": how long ago, like a notification's time.
    private var time: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let s = context.date.timeIntervalSince(banner.postedAt)
            Text(s < 60 ? "now" : s < 3600 ? "\(Int(s / 60))m" : "\(Int(s / 3600))h")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var icon: some View {
        switch banner.icon {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: Circle())
        case .image(let path):
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "app.badge.fill").font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        banner.reply?(text)
        BannerCenter.shared.dismiss(banner.id)
    }
}
