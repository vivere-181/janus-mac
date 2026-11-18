import AppKit
import SwiftUI

/// The notch window's content: the island at the top middle; the rest is transparent.
struct NotchRootView: View {
    var body: some View {
        NotchIsland(notch: NotchController.shared)
            .frame(width: NotchController.windowSize.width, height: NotchController.windowSize.height, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

/// The black island: the camera housing, grown to fit what it shows.
private struct NotchIsland: View {
    let notch: NotchController

    var body: some View {
        let mode = notch.mode
        // Idle, it's exactly the housing (no shoulders); grown, it flares into the menu bar like the real notch.
        let grown = notch.label != nil || NotchTrack.current() != nil
        let top: CGFloat = mode == .closed && !grown ? 0 : (mode == .closed ? 6 : 14)
        let bottom: CGFloat = mode == .closed ? 10 : 24
        let shape = NotchShape(top: top, bottom: bottom)
        content
            .padding(.horizontal, top)
            .background { shape.fill(.black) }
            .clipShape(shape)
            .shadow(color: .black.opacity(mode == .closed ? 0 : 0.4), radius: 10, y: 4)
            .contentShape(shape)
            .onHover { notch.hover($0) }
            .onDrop(of: [.fileURL, .url, .plainText],
                    isTargeted: Binding(get: { notch.dropTargeted }, set: { notch.setDropTargeted($0) })) { notch.drop($0) }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { notch.islandSize = $0 }
            // Music or a live activity starting or ending: the island stretches out of (or back into) the camera
            // housing while what it shows fades in with a blur, like the Dynamic Island. Only a change of what's shown
            // (or of its width) animates, not every tick of a timer.
            .animation(.spring(response: 0.5, dampingFraction: 0.78), value: ClosedIsland.layout(notch))
    }

    @ViewBuilder private var content: some View {
        switch notch.mode {
        case .closed:
            ClosedIsland(notch: notch)
        case .open:
            NotchDashboard(notch: notch)
                .frame(width: NotchController.openWidth)
                .transition(.opacity)
        }
    }
}

/// Closed: the housing alone, or with an icon left of the camera and the text right of it (equal sides, so the
/// camera stays in the middle).
private struct ClosedIsland: View {
    let notch: NotchController
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    /// Appearing and disappearing: a blur and a little scale from the camera outwards.
    private static let appear = AnyTransition(.blurReplace).combined(with: .scale(scale: 0.6))

    /// What the closed island shows, as far as its shape goes (its kind and widths).
    static func layout(_ notch: NotchController) -> String {
        let label = notch.label
        if label?.urgent != true, NotchTrack.current() != nil {
            return label?.live == true ? "music+\(Int(wing(for: label!.text)))" : "music"
        }
        if let label { return "label:\(Int(wing(for: label.text)))" }
        return "idle"
    }

    var body: some View {
        let size = notch.notchSize
        if notch.label?.urgent != true, let track = NotchTrack.current() {
            // Music: the artwork left of the camera, the bars (or a running timer) right of it; equal sides, so the
            // camera stays in the middle.
            let live = notch.label.flatMap { $0.live ? $0 : nil }
            let side = live.map { Self.wing(for: $0.text) + 24 } ?? 26   // the text and its icon
            HStack(spacing: 0) {
                TrackArtwork(track: track, size: 22, corner: 6)
                    .id(track.title + track.artist)   // a new song's cover crossfades in
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: track.title + track.artist)
                    .frame(width: side, alignment: .leading)
                Color.clear.frame(width: size.width)
                if let label = live {
                    // A timer or a ride alongside the music: it takes the right side.
                    HStack(spacing: 4) {
                        if let icon = label.icon { Image(systemName: icon) }
                        Text(label.text).font(Font(Self.font)).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(label.green ? Color.green : .white)
                    .frame(width: side, alignment: .trailing)
                } else {
                    MusicBars(playing: track.isPlaying, color: ArtworkTint.color(for: track))
                        .frame(width: 26, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: size.height)
            .transition(Self.appear)
            .help("\(track.title) — \(track.artist) · \(track.place)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playing \(track.title) by \(track.artist) on \(track.place)")
        } else if let label = notch.label {
            let wing = Self.wing(for: label.text)
            let color: Color = label.green ? .green : .white
            HStack(spacing: 0) {
                Group { if let icon = label.icon { Image(systemName: icon) } }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: wing, alignment: .leading)
                Color.clear.frame(width: size.width)
                Text(label.text)
                    .font(Font(Self.font))
                    .lineLimit(1)
                    .frame(width: wing, alignment: .trailing)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: size.height)
            .transition(Self.appear)
        } else {
            Color.clear.frame(width: size.width, height: size.height)
                .transition(.identity)
        }
    }

    /// As wide as the text, within limits (the menu bar's menus and icons are beside the notch).
    fileprivate static func wing(for text: String) -> CGFloat {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return min(130, max(24, ceil(width)))
    }
}

// MARK: Open

/// Open, like the Dynamic Island expanded: no boxes, and one thing leads. Spotify (while it plays) is the main act;
/// below it files and the chosen notes, each in its own colour.
private struct NotchDashboard: View {
    let notch: NotchController

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.notchSize.height)   // the camera
            VStack(spacing: 14) {
                if let track = NotchTrack.current(includingPaused: notch.keepsPausedTrack) {
                    NowPlaying(track: track)
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                }
                HStack(alignment: .top, spacing: 0) {
                    FilesSection(notch: notch)
                    Hairline()
                    NotesSection(notch: notch)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .fixedSize(horizontal: false, vertical: true)   // as tall as its content, not the window
    }
}

/// What's playing: artwork with the app's badge, the bars, a scrubber and the controls.
private struct NowPlaying: View {
    let track: NotchTrack

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                TrackArtwork(track: track, size: 56, corner: 12)
                    .overlay(alignment: .bottomTrailing) {
                        if track.artwork != nil || track.artURL != nil { SourceBadge(track: track).offset(x: 5, y: 5) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MusicBars(playing: track.isPlaying, color: ArtworkTint.color(for: track))
            }
            if let duration = track.duration {
                Scrubber(track: track, duration: duration)
            }
            HStack(spacing: 36) {
                Glyph(symbol: "backward.fill", size: 17, help: "Previous") { track.control(.previous) }
                Glyph(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 24, help: track.isPlaying ? "Pause" : "Play") {
                    track.control(.togglePlayPause)
                }
                Glyph(symbol: "forward.fill", size: 17, help: "Next") { track.control(.next) }
            }
        }
        .help("Playing on \(track.place)")
    }
}

/// The playing app's icon (Spotify, Safari…), or the phone's glyph.
private struct SourceBadge: View {
    let track: NotchTrack

    var body: some View {
        if let icon = track.appIcon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.5), radius: 2)
        } else {
            Image(systemName: "iphone")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(white: 0.2)))
                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
        }
    }
}

/// Elapsed – bar – remaining. Drag (or click) to seek when the player allows it; it thickens under the pointer.
private struct Scrubber: View {
    let track: NotchTrack
    let duration: TimeInterval
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = dragging.map { $0 * duration } ?? track.position(at: context.date)
            let active = hovering || dragging != nil
            HStack(spacing: 10) {
                Text(Self.time(position)).frame(width: 42, alignment: .trailing)
                GeometryReader { g in
                    let height: CGFloat = active ? 8 : 5
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(height, g.size.width * CGFloat(position / max(duration, 1))))
                    }
                    .frame(height: height)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragging = min(1, max(0, $0.location.x / max(g.size.width, 1))) }
                        .onEnded { _ in
                            if let d = dragging { track.seek(to: d * duration) }
                            dragging = nil
                        })
                    .allowsHitTesting(track.canSeek)
                }
                .frame(height: 14)
                Text("-" + Self.time(max(0, duration - position))).frame(width: 42, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onHover { hovering = $0 && track.canSeek }
        .animation(.easeOut(duration: 0.15), value: hovering || dragging != nil)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Self.time(track.position(at: .now))) of \(Self.time(duration))")
    }

    static func time(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A bare glyph button: a soft circle under the pointer, a little squeeze when pressed.
private struct Glyph: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(Squeeze())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct Squeeze: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.horizontal, 14)
    }
}

/// A small section: its name in its own colour (and an optional button), then its content.
private struct NotchSection<Accessory: View, Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 18)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A row that lights up under the pointer (a list item, not a box).
private struct Row<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Squeeze())
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A small glyph button in a section's header.
private struct HeaderButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 18)
                .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Squeeze())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Files: a well to drop on (or click, to choose), and the latest files sent or received.
private struct FilesSection: View {
    let notch: NotchController

    var body: some View {
        let phone = AppModel.shared.phone
        let recent = Array(TransferStore.shared.items.lazy.filter { $0.kind == .file }.prefix(2))
        NotchSection(title: "Files", color: .janus) {
            EmptyView()
        } content: {
            DropWell(phone: phone, targeted: notch.dropTargeted) {
                guard let phone else { return }
                notch.close()
                FilePicker.chooseAndSend(to: phone)
            }
            ForEach(recent) { TransferRow(transfer: $0) }
        }
    }
}

private struct DropWell: View {
    let phone: Device?
    let targeted: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let lit = targeted || hovering
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: phone == nil ? "iphone.slash" : "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(phone == nil ? Color.secondary : Color.janus)
                    .symbolEffect(.bounce, value: targeted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(phone == nil ? "No phone connected" : targeted ? "Drop to send" : "Drop or choose files")
                        .font(.system(size: 12, weight: .semibold))
                    if let phone {
                        Text("to \(phone.name)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(shape.fill(targeted ? Color.janus.opacity(0.18) : .white.opacity(hovering ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(lit ? Color.janus.opacity(0.8) : .white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(shape)
        }
        .buttonStyle(Squeeze())
        .disabled(phone == nil)
        .onHover { hovering = $0 && phone != nil }
        .help(phone.map { "Choose files to send to \($0.name), or drop them here" } ?? "Open Janus on your phone, on the same Wi-Fi as this Mac")
        .animation(.easeOut(duration: 0.15), value: lit)
        .padding(.bottom, 2)
    }
}

/// A file sent or received: its icon, name and how it went. Opens a received file; shows a sent one in Finder.
private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        Row(help: transfer.direction == .received ? "Open \(transfer.name)" : "Show \(transfer.name) in Finder") {
            guard let url = transfer.url else { return }
            NotchController.shared.close()
            if transfer.direction == .received, transfer.state == .done { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            HStack(spacing: 7) {
                icon.frame(width: 18, height: 18)
                Text(transfer.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(status).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(transfer.state == .failed ? Color.red : .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let url = transfer.url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch transfer.state {
        case .inProgress: transfer.progress.map { "\(Int($0 * 100))%" } ?? (transfer.direction == .sent ? "Sending" : "Receiving")
        case .failed: "Failed"
        case .done: transfer.direction == .sent ? "Sent" : "Received"
        }
    }
}

/// The notes you chose for the notch (from its menu, or Notes → right-click → Show in Notch).
private struct NotesSection: View {
    let notch: NotchController

    var body: some View {
        let byID = Dictionary(NotesStore.shared.live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let notes = notch.noteIDs.compactMap { byID[$0] }.prefix(3)
        NotchSection(title: "Notes", color: .yellow) {
            ChooseNotesButton(notch: notch)
        } content: {
            if notes.isEmpty {
                Text("Choose the notes to keep here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(notes)) { note in
                        Row(help: "Open \(note.title.isEmpty ? "note" : note.title)") {
                            NotchController.shared.close()
                            NoteWindows.show(note.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title.isEmpty ? "New Note" : note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if !note.preview.isEmpty {
                                    Text(note.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(notes.count == 1 ? 4 : 2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The header's menu: every note, ticked when it's in the notch; and a new one.
private struct ChooseNotesButton: View {
    let notch: NotchController

    var body: some View {
        HeaderButton(symbol: "checklist", color: .yellow, help: "Choose Notes") {}
            .overlay {
                // AppKit's menu (it keeps the notch open while it's up, and sits under the button).
                MenuAnchor { view in
                    let menu = NSMenu()
                    let notes = NotesStore.shared.live
                    for note in notes.prefix(30) {
                        let item = NSMenuItem(title: note.title.isEmpty ? "New Note" : note.title, action: nil, keyEquivalent: "")
                        item.state = notch.noteIDs.contains(note.id) ? .on : .off
                        item.target = MenuTarget.shared
                        item.action = #selector(MenuTarget.run(_:))
                        item.representedObject = { notch.toggleNote(note.id) } as () -> Void
                        menu.addItem(item)
                    }
                    if notes.isEmpty { menu.addItem(NSMenuItem(title: "No Notes", action: nil, keyEquivalent: "")) }
                    menu.addItem(.separator())
                    let new = NSMenuItem(title: "New Note", action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
                    new.target = MenuTarget.shared
                    new.representedObject = { notch.close(); QuickNote.show(new: true) } as () -> Void
                    menu.addItem(new)
                    notch.popUp(menu, from: view, at: NSPoint(x: 0, y: view.bounds.height + 4))
                }
            }
    }
}

/// Runs a menu item's closure.
@MainActor
private final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func run(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }
}

/// A clear AppKit view over a button that shows a menu on click (positioned from the view itself).
private struct MenuAnchor: NSViewRepresentable {
    let show: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.show = show }

    final class AnchorView: NSView {
        var show: ((NSView) -> Void)?
        override func mouseDown(with event: NSEvent) { show?(self) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var isFlipped: Bool { true }
    }
}
