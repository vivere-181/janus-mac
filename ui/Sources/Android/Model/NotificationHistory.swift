import Foundation

/// The phone's notifications as they came in, kept on this Mac for 24 hours after they were last on the phone, so
/// the Notifications section still has them after the phone disconnects, reconnects or clears them. Ongoing ones
/// (music, navigation, "USB debugging connected"…) are status, not events, and aren't kept. Only the owner's phones.
@MainActor @Observable
final class NotificationHistory {
    static let shared = NotificationHistory()
    static let keep: TimeInterval = 24 * 3600

    struct Entry: Codable, Identifiable, Equatable {
        var id: String { deviceID + "/" + key }
        let deviceID: String
        /// The phone's own key for the notification (stable across reconnects).
        let key: String
        var appName: String
        var title: String
        var text: String
        /// Our copy of the app's icon (the engine's copies don't last).
        var iconFile: String?
        var postedAt: Date
        /// The last time it was on the phone.
        var lastSeen: Date
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("NotificationIcons"), withIntermediateDirectories: true)
        return d
    }()
    private static var file: URL { dir.appendingPathComponent("notification-history.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        prune()
    }

    static func key(_ n: PhoneNotification) -> String { n.internalId.isEmpty ? n.id : n.internalId }

    /// A notification on the phone (new, changed or re-sent after a reconnect). Returns when it was first posted,
    /// so a re-sent one keeps its original time.
    @discardableResult
    func record(_ n: PhoneNotification, device: Device) -> Date {
        let key = Self.key(n)
        guard DeviceTrust.isMine(device), n.dismissable, !n.isControl,
              !(n.title.isEmpty && n.text.isEmpty) else { return n.postedAt }
        let now = Date()
        if let i = entries.firstIndex(where: { $0.deviceID == device.id && $0.key == key }) {
            // The same notification seen again (a reconnect re-sends what's on the phone): nothing to change or save
            // unless its 24 hours would otherwise run out noticeably earlier.
            let e = entries[i]
            if e.appName == n.appName, e.title == n.title, e.text == n.text, now.timeIntervalSince(e.lastSeen) < 600 {
                return e.postedAt
            }
            entries[i].appName = n.appName; entries[i].title = n.title; entries[i].text = n.text
            entries[i].lastSeen = now
            if let icon = copyIcon(n.iconPath) { entries[i].iconFile = icon }
            save()
            return entries[i].postedAt
        }
        entries.insert(Entry(deviceID: device.id, key: key, appName: n.appName, title: n.title, text: n.text,
                             iconFile: copyIcon(n.iconPath), postedAt: n.postedAt, lastSeen: now), at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        save()
        return n.postedAt
    }

    /// It left the phone (cleared there, or the phone disconnected): its 24 hours start now.
    func ended(_ n: PhoneNotification, device: Device) {
        guard let i = entries.firstIndex(where: { $0.deviceID == device.id && $0.key == Self.key(n) }) else { return }
        entries[i].lastSeen = Date()
        save()
    }

    /// What's no longer on the phone, newest first.
    func earlier(for device: Device) -> [Entry] {
        let onPhone = Set(device.notifications.map(Self.key))
        let cutoff = Date().addingTimeInterval(-Self.keep)
        return entries.filter { $0.deviceID == device.id && !onPhone.contains($0.key) && $0.lastSeen > cutoff }
            .sorted { $0.postedAt > $1.postedAt }
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0.id == e.id }
        save()
    }

    /// Dismissed on this Mac: gone for good, not "earlier".
    func remove(_ n: PhoneNotification, device: Device) {
        entries.removeAll { $0.deviceID == device.id && $0.key == Self.key(n) }
        save()
    }

    func clear(device: Device, app: String? = nil) {
        entries.removeAll { $0.deviceID == device.id && (app == nil || ($0.appName.isEmpty ? "Other" : $0.appName) == app) }
        save()
    }

    /// Unpaired or someone else's phones lose their history.
    func keepOnly(deviceIDs: Set<String>) {
        let before = entries.count
        entries.removeAll { !deviceIDs.contains($0.deviceID) }
        if entries.count != before { save() }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        if entries.contains(where: { $0.lastSeen < cutoff }) { entries.removeAll { $0.lastSeen < cutoff } }
    }

    /// Icons nothing refers to are removed once per launch (not on every save).
    @ObservationIgnored private var iconsCleaned = false

    /// Icons are small; one copy per distinct file, named after its path.
    private func copyIcon(_ path: String?) -> String? {
        guard let path = path?.replacingOccurrences(of: "file://", with: ""), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        if path.hasPrefix(Self.dir.path) { return path }
        let name = String(path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 36)
        let dest = Self.dir.appendingPathComponent("NotificationIcons/\(name).png").path
        if !FileManager.default.fileExists(atPath: dest) { try? FileManager.default.copyItem(atPath: path, toPath: dest) }
        return dest
    }

    private func save() {
        prune()
        saveTask?.cancel()
        let cleanIcons = !iconsCleaned
        iconsCleaned = true
        saveTask = Task { [entries] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let url = Self.file
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
                guard cleanIcons else { return }
                let used = Set(entries.compactMap(\.iconFile))
                let iconDir = url.deletingLastPathComponent().appendingPathComponent("NotificationIcons")
                for f in (try? FileManager.default.contentsOfDirectory(atPath: iconDir.path)) ?? []
                where !used.contains(iconDir.appendingPathComponent(f).path) {
                    try? FileManager.default.removeItem(at: iconDir.appendingPathComponent(f))
                }
            }.value
        }
    }
}
