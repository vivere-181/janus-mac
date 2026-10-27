import AppKit
import SwiftUI
import UserNotifications

/// One occurrence of a calendar event on a phone (see shared/CONTRACT.md → `ge.connect.calendar`).
struct CalendarEvent: Codable, Identifiable, Equatable {
    let id: String              // "<device id>/<phone's occurrence id>"
    var calendar: String        // the calendar's key (account + name, the same on every phone)
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var join: URL?
    var color: String?

    func isOngoing(at now: Date) -> Bool { start <= now && end > now }

    /// "3:30 – 4:00 PM" or "All day".
    var timeRange: String {
        if allDay { return "All day" }
        // Times only, also for an event that ends after midnight ("23:00 – 00:30").
        guard Calendar.current.isDate(start, inSameDayAs: end) else {
            return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return (start..<end).formatted(.interval.hour().minute())
    }

    /// Changes when the event moves, so a moved event is reminded of again (and a stale reminder is withdrawn).
    var alertKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }
}

struct PhoneCalendarInfo: Codable, Identifiable, Equatable {
    let id: String              // key: account + name
    var name: String
    var account: String
    var color: String?
}

/// The phones' calendars, as last sent by our phone app (one snapshot per phone, merged). Cached on disk so the
/// agenda keeps working while a phone is away; drives the menu bar countdown, the panel's Up Next, the Calendar
/// pane and the reminders.
@MainActor @Observable
final class CalendarStore {
    static let shared = CalendarStore()

    fileprivate struct Snapshot: Codable {
        var deviceName: String
        var events: [CalendarEvent]
        var calendars: [PhoneCalendarInfo]
        var updated: Date
        var to: Date?
        var off = false
    }
    private var snapshots: [String: Snapshot] = [:] {
        didSet { merge() }
    }
    /// Merged across phones (the same event synced to two phones appears once).
    private(set) var events: [CalendarEvent] = []
    private(set) var calendars: [PhoneCalendarInfo] = []

    var showInMenuBar = UserDefaults.standard.object(forKey: "calendar.menuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "calendar.menuBar"); changed() }
    }
    /// Minutes before an event for the reminder; -1 = none.
    var alertMinutes = UserDefaults.standard.object(forKey: "calendar.alert") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(alertMinutes, forKey: "calendar.alert"); changed() }
    }
    /// Calendar keys (account + name) the owner turned off.
    var hiddenCalendars = Set(UserDefaults.standard.stringArray(forKey: "calendar.hiddenKeys") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenCalendars), forKey: "calendar.hiddenKeys"); changed() }
    }

    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("calendar.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL), let cached = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
            snapshots = cached
        }
        merge()
        for name in [NSWorkspace.didWakeNotification, NSNotification.Name.NSSystemClockDidChange] {
            let center = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarStore.shared.changed() }
            }
        }
    }

    var hasCalendar: Bool { snapshots.values.contains { !$0.off } }
    /// Every phone that sent a calendar says access is off.
    var isOffOnPhone: Bool { !snapshots.isEmpty && snapshots.values.allSatisfy(\.off) }
    var updated: Date? { snapshots.values.filter { !$0.off }.map(\.updated).max() }
    var sourceNames: [String] { snapshots.values.filter { !$0.off }.map(\.deviceName).sorted() }
    /// How far ahead the phones sent events (days after this aren't known).
    var coveredUntil: Date? { snapshots.values.compactMap(\.to).max() }

    // MARK: Snapshots from the phone

    /// A complete snapshot (JSON) from one of the owner's phones.
    /// The last snapshot text per phone: the same one again (a refresh, a reconnect) changes nothing.
    @ObservationIgnored private var lastSnapshot: [String: Int] = [:]

    func apply(json: String, from device: Device) {
        let fingerprint = json.hashValue
        if lastSnapshot[device.id] == fingerprint, snapshots[device.id] != nil { return }
        lastSnapshot[device.id] = fingerprint
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Event times are absolute: no clock correction by "now" (a snapshot re-read later, e.g. at startup,
        // would shift every event by its age).
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        if o["off"] as? Bool == true {
            snapshots[device.id] = Snapshot(deviceName: device.name, events: [], calendars: [], updated: .now, off: true)
            save()
            return
        }
        var keys: [String: String] = [:]
        let cals = (o["calendars"] as? [[String: Any]] ?? []).compactMap { c -> PhoneCalendarInfo? in
            guard let id = Self.string(c["id"]) else { return nil }
            let name = c["name"] as? String ?? "", account = c["account"] as? String ?? ""
            let key = account + "\n" + name
            keys[id] = key
            return PhoneCalendarInfo(id: key, name: name, account: account, color: c["color"] as? String)
        }
        let colors = Dictionary(cals.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        // All-day events come as the phone's local midnights; they belong on the same dates here, even when the
        // Mac is in another time zone.
        let phoneZone = device.profile?.timeZone
        func day(_ d: Date) -> Date {
            guard let phoneZone, phoneZone.secondsFromGMT(for: d) != TimeZone.current.secondsFromGMT(for: d) else { return d }
            var there = Calendar(identifier: .gregorian); there.timeZone = phoneZone
            return Calendar.current.date(from: there.dateComponents([.year, .month, .day], from: d)) ?? d
        }
        let list = (o["events"] as? [[String: Any]] ?? []).compactMap { e -> CalendarEvent? in
            guard let id = Self.string(e["id"]), var start = date(e["start"]), var end = date(e["end"]) else { return nil }
            if e["allDay"] as? Bool == true { start = day(start); end = day(end) }
            let cal = keys[Self.string(e["cal"]) ?? ""] ?? ""
            let join = (e["join"] as? String).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
            return CalendarEvent(id: device.id + "/" + id, calendar: cal,
                                 title: (e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No title)",
                                 start: start, end: max(end, start), allDay: e["allDay"] as? Bool ?? false,
                                 location: (e["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 join: join, color: (e["color"] as? String) ?? colors[cal] ?? nil)
        }
        snapshots[device.id] = Snapshot(deviceName: device.name, events: list, calendars: cals, updated: .now, to: date(o["to"]))
        save()
    }

    /// Drops the calendars of phones that aren't the owner's paired phones any more.
    func keepOnly(deviceIDs: Set<String>) {
        let gone = snapshots.keys.filter { !deviceIDs.contains($0) }
        guard !gone.isEmpty else { return }
        gone.forEach { snapshots[$0] = nil }
        save()
    }

    /// Forgets every calendar (and withdraws its reminders).
    func clear() {
        snapshots = [:]
        save()
    }

    private func save() {
        if snapshots.isEmpty { try? FileManager.default.removeItem(at: fileURL) }
        else if let data = try? JSONEncoder().encode(snapshots) { try? data.write(to: fileURL, options: .atomic) }
        changed()
    }

    /// Testing aid: one pretend event shown with the real ones (never saved).
    @ObservationIgnored private var simulatedEvent: CalendarEvent?
    func simulate(_ event: CalendarEvent?) {
        simulatedEvent = event
        merge()
        changed()
    }

    private func merge() {
        var seen = Set<String>()
        var merged: [CalendarEvent] = simulatedEvent.map { [$0] } ?? []
        for snap in snapshots.sorted(by: { $0.key < $1.key }).map(\.value) where !snap.off {
            for e in snap.events {
                // The same event on two phones: same calendar, title and times.
                let key = "\(e.calendar)|\(e.title)|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)"
                if seen.insert(key).inserted { merged.append(e) }
            }
        }
        events = merged.sorted { ($0.start, $0.allDay ? 0 : 1, $0.title) < ($1.start, $1.allDay ? 0 : 1, $1.title) }
        var calSeen = Set<String>()
        calendars = snapshots.values.filter { !$0.off }.flatMap(\.calendars).filter { calSeen.insert($0.id).inserted }
            .sorted { ($0.account, $0.name) < ($1.account, $1.name) }
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func changed() {
        CalendarPopup.shared.sync(with: visible)
        scheduleAlerts()
        StatusItemController.shared.updateLiveLabel()
    }

    // MARK: What to show

    var visible: [CalendarEvent] { events.filter { !hiddenCalendars.contains($0.calendar) } }

    /// Events that haven't ended, in order (ongoing first).
    func upcoming(at now: Date) -> [CalendarEvent] { visible.filter { $0.end > now } }

    /// Events on a day (all-day ones spanning it included).
    func events(on day: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return visible.filter { $0.start < end && ($0.end > start || ($0.start == $0.end && $0.start >= start)) }
    }

    /// How long before an event its countdown appears in the menu bar: the reminder time (10 min when
    /// reminders are off; an event starting "now" still shows 2 min before via `imminent`).
    var countdownLead: TimeInterval { Double(alertMinutes < 0 ? 10 : alertMinutes) * 60 }

    /// The text next to the menu bar icon: from the reminder time before a timed event, and while it runs.
    /// An event about to start (5 min) wins over one that is still running.
    func headline(at now: Date) -> (text: String, event: CalendarEvent)? {
        guard showInMenuBar else { return nil }
        let timed = visible.filter { !$0.allDay }
        let next = timed.first { $0.start > now && $0.start.timeIntervalSince(now) <= countdownLead }
        let current = timed.filter { $0.isOngoing(at: now) }.min { $0.end < $1.end }
        if let next, current == nil || next.start.timeIntervalSince(now) <= 300 {
            let left = next.start.timeIntervalSince(now)
            return (left < 60 ? "\(Self.short(next.title)) now" : "\(Self.short(next.title)) in \(Self.duration(left))", next)
        }
        if let current {
            return ("\(Self.short(current.title)) · \(Self.duration(current.end.timeIntervalSince(now))) left", current)
        }
        return nil
    }

    /// An event starting within 2 minutes (or started up to 2 minutes ago): shown in the menu bar even over a
    /// running live activity, since it's the moment to act.
    func imminent(at now: Date) -> (text: String, event: CalendarEvent)? {
        guard showInMenuBar else { return nil }
        guard let e = visible.filter({ !$0.allDay && abs($0.start.timeIntervalSince(now)) <= 120 })
                .min(by: { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }) else { return nil }
        let left = e.start.timeIntervalSince(now)
        return (left < 60 ? "\(Self.short(e.title)) now" : "\(Self.short(e.title)) in \(Self.duration(left))", e)
    }

    /// Whether the menu bar text will change within the next hour (so it needs a tick).
    func needsTicking(at now: Date) -> Bool {
        visible.contains { !$0.allDay && $0.end > now && $0.start.timeIntervalSince(now) <= max(countdownLead, 120) + 100 }
    }

    /// "12m", "1h 5m" (rounded up, so "in 1m" until it starts).
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func short(_ title: String) -> String {
        title.count <= 22 ? title : String(title.prefix(21)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Reminders

    private static let alertPrefix = "calendar."
    /// A reminder more than this late (e.g. the Mac slept through it) isn't shown any more.
    private static let lateness: TimeInterval = 120
    @ObservationIgnored private var alertTimer: Timer?
    /// Reminders already shown (by alertKey), so a restart or an update doesn't repeat them.
    @ObservationIgnored private var alerted = Set(UserDefaults.standard.stringArray(forKey: "calendar.alerted") ?? [])

    /// The app times reminders itself (it's always running) instead of scheduling them with macOS: a reminder
    /// due while the Mac slept is dropped rather than shown late, and moved or deleted events never leave one behind.
    func scheduleAlerts() {
        alertTimer?.invalidate()
        alertTimer = nil
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let lead = Double(max(alertMinutes, 0)) * 60
        let timed = alertMinutes < 0 ? [] : visible.filter { !$0.allDay }

        for e in timed where !alerted.contains(e.alertKey) {
            let due = e.start.addingTimeInterval(-lead)
            if due <= now, now.timeIntervalSince(due) < Self.lateness {
                // A card under the menu bar icon; a notification only when that can't show (Mac locked).
                if !CalendarPopup.shared.remind(e) { post(e, now: now) }
                AppModel.shared.log(.info, "Calendar reminder: \(Int((e.start.timeIntervalSince(now) / 60).rounded()) <= 0 ? "starting now" : "in \(Int((e.start.timeIntervalSince(now) / 60).rounded())) min")")
                alerted.insert(e.alertKey)
            }
        }
        // Keep the "already shown" list short: only events that could still matter.
        let live = Set(events.filter { $0.end > now.addingTimeInterval(-86_400) }.map(\.alertKey))
        alerted.formIntersection(live)
        UserDefaults.standard.set(Array(alerted), forKey: "calendar.alerted")

        // Withdraw reminders for events that moved, were deleted, hidden or have ended; and any reminders
        // an earlier version scheduled with macOS.
        let current = Set(timed.filter { $0.end > now }.map { Self.alertPrefix + $0.alertKey })
        center.getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix(Self.alertPrefix) && !current.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix(Self.alertPrefix) }
            if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old) }
        }

        guard let next = timed.map({ $0.start.addingTimeInterval(-lead) }).filter({ $0 > now }).min() else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { CalendarStore.shared.scheduleAlerts() } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
    }

    private func post(_ e: CalendarEvent, now: Date) {
        let c = UNMutableNotificationContent()
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded())
        c.title = e.title
        c.body = [minutes <= 0 ? "Starting now" : "In \(minutes) min", e.timeRange, e.location].compactMap { $0 }.joined(separator: " · ")
        c.sound = Sounds.notification
        c.categoryIdentifier = e.join == nil ? "calendar" : "calendar.join"
        if let join = e.join { c.userInfo = ["join": join.absoluteString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.alertPrefix + e.alertKey, content: c, trigger: nil)) { error in
            if let error { Task { @MainActor in AppModel.shared.log(.warning, "Couldn't show a calendar reminder: \(error.localizedDescription)") } }
        }
    }
}

extension Color {
    /// "#RRGGBB" from the phone.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: Views

/// "Up Next" in the menu bar panel: what's on now and next (today, then tomorrow), with Join for meetings.
struct CalendarPanelSection: View {
    let store = CalendarStore.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let upcoming = store.upcoming(at: now)
            // Today's timed events first; all-day ones only today; tomorrow's first few when today is done.
            let today = upcoming.filter { Calendar.current.isDateInToday($0.start) || $0.isOngoing(at: now) }
            let shown = today.isEmpty
                ? Array(upcoming.filter { Calendar.current.isDateInTomorrow($0.start) }.prefix(2))
                : Array(today.prefix(3))
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Divider().padding(.horizontal, 12)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(today.isEmpty ? "Tomorrow" : "Up Next").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        if today.count > shown.count {
                            Text("· \(today.count - shown.count) more today").font(.subheadline).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
                    VStack(spacing: 8) {
                        ForEach(shown) { CalendarEventRow(event: $0, now: now) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
        }
    }
}

struct CalendarEventRow: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: event.color) ?? .janus)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(event.isOngoing(at: now) && !event.allDay ? Color.janus : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let join = event.join, !event.allDay, event.start.timeIntervalSince(now) < 15 * 60 || event.isOngoing(at: now) {
                Button("Join") { NSWorkspace.shared.open(join) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(join.host ?? "Join the meeting")
            } else if let join = event.join, !event.allDay {
                Button { NSWorkspace.shared.open(join) } label: { Image(systemName: "video") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Join (\(join.host ?? "meeting link"))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detail: String {
        if event.allDay { return "All day" }
        if event.isOngoing(at: now) { return "Now · \(CalendarStore.duration(event.end.timeIntervalSince(now))) left" }
        let left = event.start.timeIntervalSince(now)
        let when = left <= 3600 ? "in \(CalendarStore.duration(left))" : event.timeRange
        return Calendar.current.isDateInTomorrow(event.start) && left > 3600 ? "Tomorrow · \(event.timeRange)" : when
    }
}

/// Settings → General → Calendar.
struct CalendarSettingsSection: View {
    @Bindable var store = CalendarStore.shared

    var body: some View {
        Section {
            Picker("Remind me (and show the countdown)", selection: $store.alertMinutes) {
                Text("Never").tag(-1)
                Text("When an event starts").tag(0)
                Text("1 minute before").tag(1)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
            }
            if !store.calendars.isEmpty {
                ForEach(store.calendars) { cal in
                    Toggle(isOn: Binding(
                        get: { !store.hiddenCalendars.contains(cal.id) },
                        set: { on in if on { store.hiddenCalendars.remove(cal.id) } else { store.hiddenCalendars.insert(cal.id) } })) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: cal.color) ?? .janus).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(cal.name.isEmpty ? "Calendar" : cal.name)
                                if !cal.account.isEmpty, cal.account != cal.name {
                                    Text(cal.account).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text(store.footer)
        }
    }
}

extension CalendarStore {
    /// Where the events come from and how fresh they are (Settings and the Calendar pane).
    var footer: String {
        if isOffOnPhone { return "The phone app isn't allowed to read your calendar. Allow it in the phone app's setup (Calendar on your Mac)." }
        guard let updated else {
            return "Your phone's calendar appears here once the phone app is allowed to read it (Calendar on your Mac, in the phone app's setup)."
        }
        let from = sourceNames.formatted(.list(type: .and))
        return "From \(from), updated \(updated.formatted(.relative(presentation: .named))). The countdown appears in the menu bar at the reminder time and while an event runs."
    }
}
