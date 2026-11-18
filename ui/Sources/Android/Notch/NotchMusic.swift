import AppKit
import CoreImage
import SwiftUI

/// The music the notch shows: Spotify, this Mac's when it's playing, otherwise the phone's.
struct NotchTrack: Equatable {
    enum Source: Equatable { case mac(bundleID: String), phone(deviceID: String) }

    var source: Source
    var title: String
    var artist: String
    var isPlaying: Bool
    /// The Mac's artwork arrives as an image; the phone's as a file.
    var artwork: NSImage?
    var artURL: URL?
    /// Seconds; nil when unknown or live.
    var duration: TimeInterval?
    /// Seconds played as of `elapsedAt`.
    var elapsed: TimeInterval = 0
    var elapsedAt = Date()
    var canSeek = false

    /// Where the playhead is now.
    func position(at now: Date) -> TimeInterval {
        let p = isPlaying ? elapsed + now.timeIntervalSince(elapsedAt) : elapsed
        return min(max(0, p), duration ?? .infinity)
    }

    /// Where it's playing: "Spotify", or the phone's name…
    @MainActor var place: String {
        switch source {
        case .mac(let id): MacNowPlaying.appName(id)
        case .phone(let id): AppModel.shared.devices.first { $0.id == id }?.name ?? "Phone"
        }
    }

    static let spotify = "com.spotify.client"

    /// Playing now (closed notch), or also paused (the open view, after it was paused from there).
    @MainActor static func current(includingPaused: Bool = false) -> NotchTrack? {
        guard NotchController.musicEnabled else { return nil }
        if let test = NotchController.shared.debugTrack { return test }
        if NotchController.shared.debugSilent { return nil }
        let mac = MacNowPlaying.shared.track.flatMap { $0.bundleID == Self.spotify ? $0 : nil }.map {
            NotchTrack(source: .mac(bundleID: $0.bundleID), title: $0.title, artist: $0.artist, isPlaying: $0.isPlaying,
                       artwork: MacNowPlaying.shared.artwork, duration: $0.duration, elapsed: $0.elapsed, elapsedAt: $0.elapsedAt,
                       canSeek: $0.duration != nil)
        }
        let phone = AppModel.shared.phone.flatMap { d -> NotchTrack? in
            guard d.media.hasTrack, d.media.player.localizedCaseInsensitiveContains("spotify") else { return nil }
            let m = d.media
            return NotchTrack(source: .phone(deviceID: d.id), title: m.title, artist: m.artist, isPlaying: m.isPlaying,
                              artURL: m.artURL, duration: m.length > 0 ? Double(m.length) / 1000 : nil,
                              elapsed: Double(m.position) / 1000, elapsedAt: m.positionDate, canSeek: m.canSeek && m.length > 0)
        }
        if let mac, mac.isPlaying { return mac }
        if let phone, phone.isPlaying { return phone }
        guard includingPaused else { return nil }
        return mac ?? phone
    }

    @MainActor func control(_ command: MacNowPlaying.Command) {
        switch source {
        case .mac:
            MacNowPlaying.shared.send(command)
        case .phone(let id):
            guard let d = AppModel.shared.devices.first(where: { $0.id == id }) else { return }
            d.mediaAction(command == .togglePlayPause ? "PlayPause" : command == .next ? "Next" : "Previous")
        }
    }

    @MainActor func seek(to seconds: TimeInterval) {
        switch source {
        case .mac: MacNowPlaying.shared.seek(to: seconds)
        case .phone(let id): AppModel.shared.devices.first { $0.id == id }?.seek(to: Int(seconds * 1000))
        }
    }

    /// The app playing it (Spotify, Firefox…); nil for the phone.
    @MainActor var appIcon: NSImage? {
        guard case .mac(let id) = source else { return nil }
        if let icon = Self.icons[id] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.icons[id] = icon   // the same image each time (the bars' tint is cached by image)
        return icon
    }
    @MainActor private static var icons: [String: NSImage] = [:]

    static func == (a: NotchTrack, b: NotchTrack) -> Bool {
        a.source == b.source && a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying
            && a.artwork === b.artwork && a.artURL == b.artURL && a.duration == b.duration && a.elapsed == b.elapsed
    }
}

/// The track's artwork: the Mac's image, or the phone's file.
struct TrackArtwork: View {
    let track: NotchTrack
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let url = track.artURL {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// No artwork (a video in a browser, say): the app's own icon, else a note.
    @ViewBuilder private var placeholder: some View {
        if let icon = track.appIcon {
            Image(nsImage: icon).resizable().padding(size * 0.08)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.12))
        }
    }
}

/// Four bars that move while music plays and rest when it's paused. Like boring.notch and vorssaint-utils, they
/// follow the playing state, not the sound itself (that would need recording the Mac's audio). Core Animation runs
/// them in the window server, so they cost the app nothing per frame (SwiftUI would redraw the notch each frame).
struct MusicBars: NSViewRepresentable {
    let playing: Bool
    let color: Color

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ view: BarsView, context: Context) { view.update(playing: playing, color: NSColor(color)) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? { BarsView.size }
}

final class BarsView: NSView {
    static let size = CGSize(width: 4 * 3 + 3 * 2.5, height: 16)
    private var bars: [CALayer] = []
    private var playing: Bool?
    /// Heights each bar moves through (different rhythms, so they never line up).
    private static let heights: [[CGFloat]] = [[5, 14, 7, 12, 4, 10, 5], [9, 4, 16, 8, 13, 6, 9], [12, 6, 10, 15, 5, 9, 12], [4, 11, 6, 9, 13, 5, 4]]
    private static let durations: [CFTimeInterval] = [1.3, 1.1, 1.45, 1.2]

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() { bar.position = CGPoint(x: 1.5 + CGFloat(i) * 5.5, y: bounds.midY) }
        CATransaction.commit()
    }

    func update(playing: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            let rest: CGFloat = playing ? (still ? Self.heights[i][1] : Self.heights[i][0]) : 3
            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = bar.presentation()?.bounds.height ?? bar.bounds.height
            settle.duration = 0.25
            bar.bounds.size.height = rest
            bar.add(settle, forKey: "settle")
            guard playing, !still else { continue }
            let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
            bounce.values = Self.heights[i]
            bounce.duration = Self.durations[i]
            bounce.calculationMode = .cubic
            bounce.repeatCount = .infinity
            bounce.beginTime = CACurrentMediaTime() + 0.25
            bar.add(bounce, forKey: "bounce")
        }
    }
}

/// The artwork's average colour, brightened to read on black: the bars take it, like the artwork's own light.
@MainActor
enum ArtworkTint {
    private static var cache: (key: ObjectIdentifier, color: Color)?
    private static var phoneArt: (url: URL, image: NSImage?)?
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// The Mac's artwork, or the phone's (a file, read once per track).
    static func color(for track: NotchTrack) -> Color {
        if let image = track.artwork { return color(for: image) }
        guard let url = track.artURL, url.isFileURL else { return track.appIcon.map { color(for: $0) } ?? .white }
        if phoneArt?.url != url { phoneArt = (url, NSImage(contentsOf: url)) }
        return color(for: phoneArt?.image)
    }

    static func color(for image: NSImage?) -> Color {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let key = ObjectIdentifier(image)
        if let cache, cache.key == key { return cache.color }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let average = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        // Keep its hue; lift it so it never sinks into the black notch.
        let hsb = average.usingColorSpace(.deviceRGB) ?? average
        let color = Color(nsColor: NSColor(hue: hsb.hueComponent, saturation: min(hsb.saturationComponent, 0.75),
                                           brightness: max(hsb.brightnessComponent, 0.8), alpha: 1))
        cache = (key, color)
        return color
    }
}
