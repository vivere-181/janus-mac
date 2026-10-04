import SwiftUI

struct NotificationsView: View {
    let device: Device

    var body: some View {
        let earlier = NotificationHistory.shared.earlier(for: device).map(\.asNotification)
        Group {
            if device.notifications.isEmpty && earlier.isEmpty {
                ContentUnavailableView {
                    Label("No Notifications", systemImage: "bell.slash")
                } description: {
                    Text("Notifications from \(device.name) appear here and stay for 24 hours. If nothing shows up, allow notification access for the companion app on the phone.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                        if !device.notifications.isEmpty, !earlier.isEmpty {
                            header("On \(device.name)", detail: nil)
                        }
                        ForEach(Self.grouped(device.notifications), id: \.app) { group in
                            NotificationGroup(device: device, app: group.app, items: group.items, earlier: false)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if !earlier.isEmpty {
                            header("Earlier", detail: "No longer on the phone · kept for 24 hours") {
                                NotificationHistory.shared.clear(device: device)
                            }
                            .padding(.top, device.notifications.isEmpty ? 0 : 10)
                            ForEach(Self.grouped(earlier), id: \.app) { group in
                                NotificationGroup(device: device, app: group.app, items: group.items, earlier: true)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: device.notifications.map(\.id) + earlier.map(\.id))
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationSubtitle(subtitle(earlier: earlier.count))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    device.notifications.filter(\.dismissable).forEach(device.dismiss)
                    NotificationHistory.shared.clear(device: device)
                } label: {
                    Label("Clear All", systemImage: "xmark.circle")
                }
                .help("Clear notifications here and dismiss them on the phone")
                .disabled(!device.notifications.contains(where: \.dismissable) && earlier.isEmpty)
            }
        }
    }

    private func subtitle(earlier: Int) -> String {
        let now = device.notifications.count
        switch (now, earlier) {
        case (0, 0): return ""
        case (_, 0): return "\(now) on the phone"
        case (0, _): return "\(earlier) earlier"
        default: return "\(now) on the phone · \(earlier) earlier"
        }
    }

    private func header(_ title: String, detail: String?, clear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            if let clear { Button("Clear", action: clear).buttonStyle(.link) }
        }
        .padding(.horizontal, 4)
    }

    /// Notifications grouped by app, newest group first (like Notification Center).
    static func grouped(_ list: [PhoneNotification]) -> [(app: String, items: [PhoneNotification])] {
        var order: [String] = []
        var byApp: [String: [PhoneNotification]] = [:]
        for n in list.sorted(by: { $0.postedAt > $1.postedAt }) {
            let app = n.appName.isEmpty ? "Other" : n.appName
            if byApp[app] == nil { order.append(app) }
            byApp[app, default: []].append(n)
        }
        return order.map { ($0, byApp[$0]!) }
    }
}

extension NotificationHistory.Entry {
    /// Shown like a phone notification, without actions (the phone no longer has it).
    var asNotification: PhoneNotification {
        var n = PhoneNotification(id: id)
        n.appName = appName; n.title = title; n.text = text; n.iconPath = iconFile
        n.dismissable = false; n.postedAt = postedAt
        return n
    }
}

/// One app's notifications in a card: header with the app, count and actions, then the rows. Earlier ones (no longer
/// on the phone) clear from this Mac only.
private struct NotificationGroup: View {
    let device: Device
    let app: String
    let items: [PhoneNotification]
    let earlier: Bool
    @State private var muted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(app).font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                if muted {
                    Label("Muted on this Mac", systemImage: "bell.slash.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(muted ? "Unmute \(app) on This Mac" : "Mute \(app) on This Mac") {
                        Notifier.setMuted(app, !muted)
                        muted.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if earlier {
                    Button("Clear") { NotificationHistory.shared.clear(device: device, app: app) }
                        .buttonStyle(.link).font(.callout)
                } else if items.contains(where: \.dismissable) {
                    Button("Clear") { items.filter(\.dismissable).forEach(device.dismiss) }
                        .buttonStyle(.link).font(.callout)
                }
            }
            .padding(.bottom, 10)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, n in
                if index > 0 { Divider().padding(.vertical, 10) }
                NotificationRow(device: device, notification: n, showsApp: false, remove: earlier ? {
                    if let e = NotificationHistory.shared.entries.first(where: { $0.id == n.id }) { NotificationHistory.shared.remove(e) }
                } : nil)
            }
        }
        .padding(Metrics.padding)
        .cardBackground()
        .onAppear { muted = Notifier.mutedApps.contains(app) }
    }
}

struct NotificationRow: View {
    let device: Device
    let notification: PhoneNotification
    var compact = false
    var showsApp = true
    /// For earlier notifications: removes it from this Mac (instead of dismissing it on the phone).
    var remove: (() -> Void)? = nil
    @State private var replying = false
    @State private var reply = ""
    @State private var hovering = false

    var body: some View {
        let n = notification
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: compact ? 24 : 34, height: compact ? 24 : 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    if showsApp {
                        Text(n.appName.isEmpty ? "Notification" : n.appName)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    } else if !n.title.isEmpty {
                        Text(NotificationText.plain(n.title)).font(.callout.weight(.semibold)).lineLimit(2)
                    }
                    Spacer()
                    if !compact {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(Self.age(n.postedAt)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if showsApp, !n.title.isEmpty { Text(NotificationText.plain(n.title)).font(compact ? .callout.weight(.medium) : .headline).lineLimit(compact ? 1 : 2) }
                if !n.text.isEmpty {
                    Text(NotificationText.attributed(n.text)).font(compact ? .caption : .callout).foregroundStyle(compact || !showsApp ? .secondary : .primary)
                        .lineLimit(compact ? 1 : 6).textSelection(.enabled)
                }
                if !compact && (!n.actions.isEmpty || !n.replyId.isEmpty) {
                    HStack {
                        if !n.replyId.isEmpty {
                            Button { withAnimation(.snappy) { replying.toggle() } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        }
                        ForEach(n.actions, id: \.self) { a in
                            Button(a) { device.trigger(a, on: n) }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                if replying {
                    HStack {
                        TextField("Reply to \(n.title)", text: $reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendReply)
                        Button("Send", action: sendReply).disabled(reply.isEmpty)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !compact && (n.dismissable || remove != nil) && hovering {
                Button { if let remove { remove() } else { device.dismiss(n) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
                .help(remove != nil ? "Remove" : "Dismiss on phone")
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let p = notification.iconPath, let img = NSImage(contentsOfFile: p.replacingOccurrences(of: "file://", with: "")) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            IconTile(symbol: "app.badge.fill", color: .gray, size: compact ? 24 : 34)
        }
    }

    /// "now", "5m", "2h", "Yesterday"… like Notification Center.
    static func age(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(s / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        device.reply(to: notification, reply)
        reply = ""
        withAnimation(.snappy) { replying = false }
    }
}
