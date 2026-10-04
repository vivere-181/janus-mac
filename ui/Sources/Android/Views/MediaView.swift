import SwiftUI

struct MediaView: View {
    let device: Device
    @State private var scrubbing: Double?
    @State private var volume: Double?

    var body: some View {
        let m = device.media
        Group {
            if !m.hasTrack {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note",
                                       description: Text("Start music or a video on \(device.name) to control it here."))
            } else {
                VStack(spacing: 22) {
                    Spacer(minLength: 0)
                    AlbumArt(url: m.artURL, size: 260)
                    VStack(spacing: 4) {
                        Text(m.title).font(.title2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                        Text([m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                    progress
                    HStack(spacing: 44) {
                        Button { device.mediaAction("Previous") } label: { Image(systemName: "backward.fill") }
                        Button { device.mediaAction("PlayPause") } label: {
                            Image(systemName: m.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 58))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        Button { device.mediaAction("Next") } label: { Image(systemName: "forward.fill") }
                    }
                    .font(.system(size: 26))
                    .buttonStyle(.plain)
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { volume ?? Double(m.volume) }, set: { volume = $0 }), in: 0...100) { editing in
                            if !editing, let v = volume { device.setVolume(Int(v)); volume = nil }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if let wash = ColorWash.image(for: m.artURL) {
                        Image(nsImage: wash).resizable().interpolation(.high)
                            .opacity(0.45).ignoresSafeArea()
                    }
                }
                .clipped()
            }
        }
        .navigationTitle("Now Playing")
        .toolbar {
            if m.players.count > 1 {
                ToolbarItem {
                    Picker("Player", selection: Binding(get: { m.player }, set: { device.selectPlayer($0) })) {
                        ForEach(m.players, id: \.self) { Text($0) }
                    }
                }
            } else if !m.player.isEmpty {
                ToolbarItem { Text(m.player).foregroundStyle(.secondary) }
            }
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let m = device.media
            let pos = scrubbing ?? Double(m.currentPosition(at: ctx.date))
            VStack(spacing: 2) {
                Slider(value: Binding(get: { pos }, set: { scrubbing = $0 }), in: 0...Double(max(m.length, 1))) { editing in
                    if !editing, let s = scrubbing { device.seek(to: Int(s)); scrubbing = nil }
                }
                .disabled(!m.canSeek || m.length <= 0)
                .controlSize(.small)
                HStack {
                    Text(formatTime(ms: Int(pos)))
                    Spacer()
                    Text("-" + formatTime(ms: max(0, m.length - Int(pos))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
        }
    }
}

/// A soft color field made by shrinking the album art to a few pixels and letting it scale back up smoothly.
enum ColorWash {
    @MainActor private static var cache: [URL: NSImage] = [:]

    @MainActor static func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let hit = cache[url] { return hit }
        guard let src = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        guard let small = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: small, size: NSSize(width: 6, height: 6))
        cache = [url: img]
        return img
    }
}
