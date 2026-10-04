import AppKit
import SwiftUI

/// The Calendar pane: the phone's events in a few day columns (as many as fit), like Calendar's day/week view.
struct CalendarPane: View {
    @Environment(AppModel.self) private var model
    @State private var anchor = Calendar.current.startOfDay(for: .now)
    let store = CalendarStore.shared

    private static let gutter: CGFloat = 52
    private static let minColumn: CGFloat = 190

    /// Day columns that fit the width (kept for the toolbar's ‹ › steps).
    @State private var columns = 3

    var body: some View {
        GeometryReader { geo in
            let count = max(1, min(7, Int((geo.size.width - Self.gutter) / Self.minColumn)))
            Group {
                if store.hasCalendar {
                    TimelineView(.everyMinute) { context in
                        CalendarGrid(days: days(count), now: context.date, gutter: Self.gutter)
                            .padding(.top, 8)
                    }
                } else {
                    ContentUnavailableView {
                        Label(store.isOffOnPhone ? "Calendar access is off" : "No calendar yet", systemImage: "calendar")
                    } description: {
                        Text(store.footer)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { columns = count }
            .onChange(of: count) { _, c in columns = c }
        }
        // Like Calendar: the month is the window's title, the source its subtitle, the controls in the toolbar.
        .navigationTitle(anchor.formatted(.dateTime.month(.wide).year()))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { refresh() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Get the latest events from your phone")
                    .disabled(model.connectedDevices.isEmpty)
            }
            ToolbarItem {
                // One joined control, like Calendar's ‹ Today ›.
                ControlGroup {
                    Button { step(-columns) } label: { Label("Earlier", systemImage: "chevron.left") }
                        .help("Earlier")
                    Button("Today") { anchor = Calendar.current.startOfDay(for: .now) }
                        .disabled(Calendar.current.isDateInToday(anchor))
                    Button { step(columns) } label: { Label("Later", systemImage: "chevron.right") }
                        .help("Later")
                }
                .controlGroupStyle(.navigation)
            }
        }
    }

    private var subtitle: String {
        guard store.hasCalendar, let updated = store.updated else { return "" }
        return "From \(store.sourceNames.formatted(.list(type: .and))) · updated \(updated.formatted(.relative(presentation: .named)))"
    }

    private func days(_ count: Int) -> [Date] {
        (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: anchor) }
    }

    private func step(_ days: Int) {
        anchor = Calendar.current.date(byAdding: .day, value: days, to: anchor) ?? anchor
    }

    private func refresh() {
        for d in model.connectedDevices where DeviceTrust.isMine(d) && d.supports("calendar") { d.command("calendar:refresh") }
    }
}

/// Day headers, an all-day row and a scrolling hour grid.
private struct CalendarGrid: View {
    let days: [Date]
    let now: Date
    let gutter: CGFloat
    let store = CalendarStore.shared

    static let hourHeight: CGFloat = 48

    var body: some View {
        let perDay = days.map { store.events(on: $0) }
        let allDay = perDay.map { $0.filter(\.allDay) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    DayHeader(day: day, synced: store.coveredUntil.map { day < $0 } ?? true)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            if allDay.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.caption).foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).padding(.top, 4)
                    ForEach(Array(allDay.enumerated()), id: \.offset) { _, events in
                        VStack(spacing: 2) {
                            ForEach(events.prefix(3)) { AllDayChip(event: $0) }
                            if events.count > 3 {
                                Text("\(events.count - 3) more").font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        HourLines(gutter: gutter)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter)
                            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                                DayColumn(day: day, events: perDay[i].filter { !$0.allDay }, now: now)
                                    .frame(maxWidth: .infinity)
                                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 0.5) }
                            }
                        }
                        if let today = days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: now) }) {
                            NowLine(now: now, gutter: gutter, column: today, columns: days.count)
                        }
                    }
                    .frame(height: Self.hourHeight * 24)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: days.first) { _, _ in scroll(proxy) }
            }
        }
    }

    /// Opens at the current hour (a little before), or the first event of the days shown.
    private func scroll(_ proxy: ScrollViewProxy) {
        let first = days.flatMap { store.events(on: $0) }.filter { !$0.allDay }.map { Calendar.current.component(.hour, from: $0.start) }.min()
        let hour = days.contains { Calendar.current.isDate($0, inSameDayAs: now) } ? Calendar.current.component(.hour, from: now) : (first ?? 8)
        proxy.scrollTo("hour\(max(0, hour - 1))", anchor: .top)
    }
}

private struct DayHeader: View {
    let day: Date
    let synced: Bool

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .foregroundStyle(today ? Color.red : .secondary)
                Text(day.formatted(.dateTime.day()))
                    .foregroundStyle(today ? .white : .primary)
                    .frame(minWidth: 24, minHeight: 24)
                    .background { if today { Circle().fill(Color.red) } }
            }
            .font(.headline)
            if !synced {
                Text("Not synced yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Hour labels in the gutter and a line per hour across the days.
private struct HourLines: View {
    let gutter: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hour == 0 ? "" : Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                        .formatted(.dateTime.hour()))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .padding(.trailing, 8)
                        .offset(y: -6)
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
                .frame(height: CalendarGrid.hourHeight, alignment: .top)
                .id("hour\(hour)")
            }
        }
    }
}

/// One day's timed events; overlapping events share the width side by side.
private struct DayColumn: View {
    let day: Date
    let events: [CalendarEvent]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let start = Calendar.current.startOfDay(for: day)
            ForEach(Self.layout(events)) { slot in
                let e = slot.event
                let from = max(e.start, start).timeIntervalSince(start) / 3600
                let to = min(e.end, start.addingTimeInterval(86_400)).timeIntervalSince(start) / 3600
                let width = geo.size.width / CGFloat(slot.columns)
                EventBlock(event: e, now: now, height: max(20, CGFloat(to - from) * CalendarGrid.hourHeight - 2))
                    .frame(width: width - 4)
                    .offset(x: CGFloat(slot.column) * width + 2, y: CGFloat(from) * CalendarGrid.hourHeight + 1)
            }
        }
    }

    struct Slot: Identifiable {
        let event: CalendarEvent
        var column: Int
        var columns: Int
        var id: String { event.id }
    }

    /// Groups events that overlap (directly or through others) and gives each a column within its group.
    static func layout(_ events: [CalendarEvent]) -> [Slot] {
        var slots: [Slot] = []
        var group: [Int] = []          // indices into slots of the current overlapping group
        var columnEnds: [Date] = []    // when each column of the group becomes free
        var groupEnd = Date.distantPast
        func closeGroup() {
            for i in group { slots[i].columns = columnEnds.count }
            group = []; columnEnds = []
        }
        for e in events.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
            // Zero-length events still take a sliver of time on screen.
            let end = max(e.end, e.start.addingTimeInterval(20 * 60))
            if e.start >= groupEnd { closeGroup() }
            let column = columnEnds.firstIndex { $0 <= e.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(end) } else { columnEnds[column] = end }
            slots.append(Slot(event: e, column: column, columns: 1))
            group.append(slots.count - 1)
            groupEnd = max(groupEnd, end)
        }
        closeGroup()
        return slots
    }
}

/// Text in an event's own color, kept readable on its tinted background: darker in light mode, lighter in dark.
private func eventText(_ color: Color, _ scheme: ColorScheme) -> Color {
    scheme == .dark ? color.mix(with: .white, by: 0.3) : color.mix(with: .black, by: 0.45)
}

private struct EventBlock: View {
    let event: CalendarEvent
    let now: Date
    let height: CGFloat
    @State private var showing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = Color(hex: event.color) ?? .janus
        let text = eventText(color, scheme)
        let past = event.end <= now
        Button { showing = true } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title).font(.callout.weight(.semibold))
                            .foregroundStyle(text)
                            .lineLimit(height > 52 ? 2 : 1)
                        if event.join != nil { Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(text.opacity(0.8)) }
                    }
                    if height > 36 {
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline).foregroundStyle(text.opacity(0.8))
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, height > 26 ? 3 : 1)
                Spacer(minLength: 0)
            }
            .frame(height: height, alignment: .top)
            .background(color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(past ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .trailing) { EventDetail(event: event) }
        .help("\(event.title) · \(event.timeRange)")
    }
}

private struct AllDayChip: View {
    let event: CalendarEvent
    @State private var showing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = Color(hex: event.color) ?? .janus
        Button { showing = true } label: {
            Text(event.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(eventText(color, scheme))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.28), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) { EventDetail(event: event) }
    }
}

/// The red current-time line across today's column, with the time in the gutter.
private struct NowLine: View {
    let now: Date
    let gutter: CGFloat
    let column: Int
    let columns: Int

    var body: some View {
        GeometryReader { geo in
            let y = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 3600 * CalendarGrid.hourHeight
            let width = (geo.size.width - gutter) / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    .frame(width: gutter - 6, alignment: .trailing)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .offset(y: y - 7)
                Circle().fill(.red).frame(width: 7, height: 7)
                    .offset(x: gutter + CGFloat(column) * width - 3.5, y: y - 3.5)
                Rectangle().fill(.red).frame(width: width, height: 1.5)
                    .offset(x: gutter + CGFloat(column) * width, y: y - 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

/// An event's details (popover): time, calendar, place, Join.
struct EventDetail: View {
    let event: CalendarEvent
    let store = CalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Label {
                Text(when).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "clock") }
            if let cal = store.calendars.first(where: { $0.id == event.calendar }) {
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(cal.name.isEmpty ? "Calendar" : cal.name)
                        if !cal.account.isEmpty, cal.account != cal.name { Text(cal.account).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Circle().fill(Color(hex: event.color) ?? .janus).frame(width: 9, height: 9) }
            }
            if let location = event.location {
                Label { Text(location).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } icon: { Image(systemName: "mappin.and.ellipse") }
            }
            if let join = event.join {
                HStack {
                    Button("Join") { NSWorkspace.shared.open(join) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(join.absoluteString, forType: .string)
                    }
                    Spacer()
                    Text(join.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var when: String {
        let day = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if event.allDay {
            let last = event.end.addingTimeInterval(-1)
            return Calendar.current.isDate(event.start, inSameDayAs: last)
                ? "\(day) · All day"
                : "\(day) – \(last.formatted(.dateTime.weekday(.wide).day().month(.wide))) · All day"
        }
        return "\(day) · \(event.timeRange)"
    }
}
