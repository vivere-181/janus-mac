import AppKit
import SwiftUI

/// An ongoing "live" notification from the phone (delivery ETA, ride, navigation, timer…), sent by our
/// phone app as a `ge.connect.live:` companion notification with a JSON body (see shared/CONTRACT.md).
struct LiveActivity: Identifiable, Equatable {
    let id: String              // the engine's notification id: stays the same across updates
    var app: String
    var title: String
    var text: String
    var short: String?
    var progress: Double?
    var when: Date?
    var countsDown = false
    var category: String?
    var indeterminate = false
    var iconPath: String?
    var updatedAt = Date()

    /// `fresh`: just received, so "now" tells the phone's clock difference (not so for a packet read again later).
    init?(id: String, json: String, iconPath: String?, fresh: Bool = true) {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.id = id
        app = o["app"] as? String ?? ""
        title = o["title"] as? String ?? ""
        text = o["text"] as? String ?? ""
        short = (o["short"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        progress = (o["progress"] as? NSNumber)?.doubleValue.clamped(to: 0...1)
        if let ms = (o["when"] as? NSNumber)?.doubleValue, ms > 0 {
            // "now" is the phone's clock when it sent this; shift by the difference so a phone clock that's
            // a few seconds off doesn't make countdowns end early or late.
            let skew = ((o["now"] as? NSNumber)?.doubleValue).map { Date().timeIntervalSince1970 - $0 / 1000 } ?? 0
            when = Date(timeIntervalSince1970: ms / 1000 + (fresh && abs(skew) < 600 ? skew : 0))
        }
        indeterminate = (o["indeterminate"] as? Bool) ?? false
        countsDown = (o["chrono"] as? String) == "down"
        category = o["cat"] as? String
        // "icon" = the icon's payloadHash: the engine keeps received icons in $TMPDIR/kdeconnect_<user>/<hash>,
        // so the icon is found even when this packet didn't carry it (e.g. after this app restarted).
        if iconPath == nil, let hash = o["icon"] as? String, !hash.isEmpty, !hash.contains("/") {
            let cached = FileManager.default.temporaryDirectory
                .appendingPathComponent("kdeconnect_\(NSUserName())/\(hash)").path
            self.iconPath = FileManager.default.fileExists(atPath: cached) ? cached : nil
        } else {
            self.iconPath = iconPath
        }
    }

    /// Ticking time for chronometers/countdowns ("8:12", "1:04:30").
    func clock(at now: Date) -> String? {
        guard let when else { return nil }
        let seconds = Int(max(0, countsDown ? when.timeIntervalSince(now) : now.timeIntervalSince(when)))
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The compact text next to the menu bar icon.
    func label(at now: Date) -> String? {
        if let short { return short }
        if let clock = clock(at: now) { return clock }
        if let progress { return "\(Int((progress * 100).rounded()))%" }
        return nil
    }

    /// A running clock needs a tick; a countdown that reached 0 waits for the phone instead.
    func needsTicking(at now: Date) -> Bool {
        guard short == nil, let when else { return false }
        return !countsDown || when > now
    }

    var symbol: String {
        switch category {
        case "navigation": "arrow.triangle.turn.up.right.diamond.fill"
        case "transport": "car.fill"
        case "stopwatch", "alarm": "timer"
        case "workout": "figure.run"
        case "call": "phone.fill"
        case "progress": "arrow.down.circle.fill"
        default: "dot.radiowaves.left.and.right"
        }
    }

    var icon: NSImage? {
        iconPath.flatMap { NSImage(contentsOfFile: $0.replacingOccurrences(of: "file://", with: "")) }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

extension Device {
    /// Live activities to show: a call already has its own card and row.
    var visibleLive: [LiveActivity] { activeCall == nil ? live : live.filter { $0.category != "call" } }

    /// The activity shown next to the menu bar icon: navigation and rides first, then the most recent.
    var headlineActivity: LiveActivity? {
        let rank: [String: Int] = ["navigation": 0, "transport": 1, "call": 2, "stopwatch": 3, "alarm": 3, "workout": 4]
        return visibleLive.sorted {
            // Something running (a ticking clock) beats something paused or stopped.
            if ($0.when != nil) != ($1.when != nil) { return $0.when != nil }
            let a = rank[$0.category ?? ""] ?? 9, b = rank[$1.category ?? ""] ?? 9
            return a != b ? a < b : $0.updatedAt > $1.updatedAt
        }.first
    }
}

/// One live activity: app icon, title and detail, a live clock or short label, and progress.
struct LiveActivityRow: View {
    let activity: LiveActivity
    var compact = true

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(activity.title.isEmpty ? activity.app : activity.title)
                        .font(compact ? .callout.weight(.semibold) : .headline).lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                if !activity.text.isEmpty || !compact {
                    Text(activity.text.isEmpty ? activity.app : activity.text)
                        .font(compact ? .caption : .callout).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                }
                if let p = activity.progress, !activity.indeterminate {
                    ProgressView(value: p).progressViewStyle(.linear).tint(.janus)
                        .controlSize(.small)
                        .animation(.smooth, value: p)
                } else if activity.indeterminate {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let short = activity.short {
            Text(short).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.tint)
        } else if activity.when != nil {
            // Ticks once a second, only while this row is on screen.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(activity.clock(at: ctx.date) ?? "").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.tint)
            }
        } else if let p = activity.progress {
            Text("\(Int((p * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var iconView: some View {
        if let img = activity.icon {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
        } else {
            Image(systemName: activity.symbol)
                .font(.system(size: compact ? 12 : 15, weight: .semibold)).foregroundStyle(Color.janusOn)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.janus.gradient, in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
        }
    }
}
