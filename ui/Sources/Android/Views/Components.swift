import AppKit
import SwiftUI

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}

/// App-icon style rounded square with a white SF Symbol, as in System Settings' sidebar.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

struct BatteryView: View {
    let charge: Int?
    let charging: Bool

    var symbol: String {
        guard let c = charge else { return "battery.0percent" }
        if charging { return "battery.100percent.bolt" }
        switch c {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var color: Color {
        guard let c = charge else { return .secondary }
        if charging { return .green }
        return c <= 15 ? .red : c <= 30 ? .orange : .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color).symbolRenderingMode(.hierarchical)
            Text(charge.map { "\($0)%" } ?? "—").monospacedDigit()
        }
    }
}

struct SignalView: View {
    let strength: Int
    let type: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cellularbars", variableValue: strength < 0 ? 0 : Double(strength) / 4)
            if !type.isEmpty && type != "Unknown" { Text(type) }
        }
    }
}

/// Large circular action button used in quick-action grids.
struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .janus
    var disabled = false
    var diameter: CGFloat = 42
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: diameter < 40 ? 4 : 6) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.4, weight: .medium))
                    .frame(width: diameter, height: diameter)
                    .foregroundStyle(disabled ? Color.secondary : tint)
                    .background(tint.opacity(disabled ? 0.06 : hovering ? 0.22 : 0.14), in: Circle())
                Text(title)
                    .font(diameter < 40 ? .caption2 : .caption)
                    .foregroundStyle(disabled ? .secondary : .primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Grouped card surface consistent with macOS 26 materials.
/// One set of measurements for every card, so edges, gaps and corners line up across the window.
/// Shared layout values. Corners inside a card are concentric with it: cards declare their shape
/// (`containerShape`), and what's inside uses `ConcentricRectangle()` instead of a radius of its own.
enum Metrics {
    /// Between cards and sections.
    static let gap: CGFloat = 16
    /// Inside a card, on all four sides.
    static let padding: CGFloat = 20
    static let radius: CGFloat = 18
    /// Tiles inside a card (concentric with the card's corner); prefer `ConcentricRectangle()` in new code.
    static let innerRadius: CGFloat = 12
}

extension View {
    /// The standard card surface: secondary background, hairline border (accent while highlighted).
    func cardBackground(highlight: Bool = false) -> some View {
        containerShape(.rect(cornerRadius: Metrics.radius))
            .background(Color.janusCard, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(highlight ? Color.janus : Color.janusOutline.opacity(0.7),
                              lineWidth: highlight ? 2 : 1))
    }
}

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

struct AlbumArt: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat { size * 0.12 }

    var body: some View {
        Group {
            if let url, let image = ImageCache.file(url.path, points: size) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: .black.opacity(size > 100 ? 0.25 : 0.1), radius: size > 100 ? 16 : 3, y: size > 100 ? 8 : 1)
    }
}

/// Circular avatar: contact photo or colored initials.
struct Avatar: View {
    let name: String
    var photo: Data?
    var size: CGFloat = 36

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .mint, .brown]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    var body: some View {
        Group {
            if let image = ImageCache.data(photo, points: size) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

func formatTime(ms: Int) -> String {
    let s = max(0, ms / 1000)
    return String(format: "%d:%02d", s / 60, s % 60)
}

extension Date {
    /// "14:05", "Yesterday", "Mon", or "12/03/24" like Messages.
    var conversationStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

/// Redraws a playback time once per second, on the second the position actually changes, and not at all while
/// paused or hidden (a paused song's time doesn't move).
struct PlaybackTicks: TimelineSchedule {
    let start: Date
    let running: Bool

    init(_ media: MediaState, running: Bool) {
        self.running = running && media.isPlaying
        let ms = media.currentPosition()
        start = Date().addingTimeInterval(Double(1000 - ms % 1000) / 1000)
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let first = start, running = running && mode != .lowFrequency
        return AnyIterator {
            guard let current = next else { return nil }
            if !running { next = nil; return current }
            next = current == startDate ? max(first, startDate.addingTimeInterval(0.001)) : current.addingTimeInterval(1)
            return current
        }
    }
}
