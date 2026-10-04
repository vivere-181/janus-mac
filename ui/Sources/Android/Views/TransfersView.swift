import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Blip-style transfers: big preview cards, live progress, drop anywhere to send.
struct TransfersView: View {
    let device: Device
    @State private var store = TransferStore.shared
    @State private var filter = Filter.all
    @State private var targeted = false
    @State private var picking = false
    @State private var text = ""
    @State private var preview: URL?

    enum Filter: String, CaseIterable { case all = "All", received = "Received", sent = "Sent" }

    private var shown: [Transfer] {
        store.items.filter {
            switch filter {
            case .all: true
            case .received: $0.direction == .received
            case .sent: $0.direction == .sent
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sendBar
                if shown.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "arrow.up.arrow.down.circle",
                                           description: Text("Files, links and text you send or receive show up here."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                        ForEach(shown) { t in
                            TransferCard(transfer: t, preview: $preview)
                        }
                    }
                    .animation(.snappy, value: shown.map(\.id))
                }
            }
            .padding(24)
        }
        .navigationTitle("Transfers")
        // Like other macOS 27 apps: the view's controls live in the toolbar, the content below.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItem {
                Button { picking = true } label: { Label("Send Files…", systemImage: "paperplane") }
                    .help("Send files to \(device.name)")
            }
            ToolbarItem {
                Button { store.clear(filter == .all ? nil : filter == .sent ? .sent : .received) } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help(filter == .all ? "Clear all transfers" : "Clear \(filter.rawValue.lowercased()) transfers")
                .disabled(shown.isEmpty)
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.janus, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                    .background(Color.janus.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        Label("Send to \(device.name)", systemImage: "arrow.up.circle.fill")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in device.share(urls.filter(\.isFileURL)); return true } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { device.share(urls) }
        }
        .quickLookPreview($preview, in: store.items.compactMap { $0.kind == .file ? $0.url : nil })
    }

    private var sendBar: some View {
        HStack(spacing: 12) {
            TextField("Paste a link or type text to send", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(sendText)
            Button("Send", action: sendText).controlSize(.large).disabled(text.isEmpty)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Tip: drop files anywhere in this window to send them to \(device.name).")
                .font(.caption).foregroundStyle(.secondary)
                .offset(y: 20)
        }
        .padding(.bottom, 14)
    }

    private func sendText() {
        device.shareText(text)
        text = ""
    }
}

// MARK: Card

struct TransferCard: View {
    let transfer: Transfer
    @Binding var preview: URL?
    var compact = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ZStack(alignment: .bottomLeading) {
                // A fixed frame the preview fills, so wide or tall images never change the card's size.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 88 : 150)
                    .overlay { PreviewImage(transfer: transfer) }
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous).strokeBorder(.separator.opacity(0.4)))
                    .overlay {
                        if transfer.state == .inProgress {
                            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous).fill(.black.opacity(0.18))
                        }
                    }
                DeviceBadge(transfer: transfer, size: compact ? 26 : 36)
                    .offset(x: compact ? 6 : 10, y: compact ? 10 : 14)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .padding(.bottom, compact ? 6 : 8)

            if !compact {
                Text(transfer.name).font(.headline).lineLimit(1).truncationMode(.middle)
                status
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hovering = h } }
        .onTapGesture(count: 2) { open() }
        .onTapGesture { primary() }
        .contextMenu { menu }
        .help(compact ? "\(transfer.name) · \(subtitle)" : "")
        .draggable(transfer.url ?? URL(fileURLWithPath: "/"))
    }

    @ViewBuilder private var status: some View {
        switch transfer.state {
        case .inProgress:
            VStack(alignment: .leading, spacing: 5) {
                WavyProgress(progress: TransferStore.shared.progress(for: transfer))
                    .frame(height: 10)
                Text(progressText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Didn't finish", systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        case .done:
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var subtitle: String {
        let who = (transfer.direction == .received ? "From " : "To ") + transfer.deviceName
        var parts = [who]
        if let size = transfer.size, transfer.kind == .file { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        parts.append(transfer.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    /// "42% · 4.1 MB/s" (the owner prefers percent and speed over byte counts).
    private var progressText: String {
        var parts: [String] = []
        if let p = TransferStore.shared.progress(for: transfer) {
            parts.append("\(Int((p * 100).rounded(.down)))%")
        } else {
            parts.append(transfer.direction == .received ? "Receiving" : "Sending")
        }
        if transfer.speed > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.speed), countStyle: .file))/s") }
        return parts.joined(separator: " · ")
    }

    private func primary() {
        switch transfer.kind {
        case .file: if transfer.state == .done, let url = transfer.url { preview = url }
        case .link: if let url = transfer.url { NSWorkspace.shared.open(url) }
        case .text: copyText()
        }
    }

    private func open() {
        if let url = transfer.url { NSWorkspace.shared.open(url) }
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transfer.text ?? transfer.url?.absoluteString ?? transfer.name, forType: .string)
    }

    @ViewBuilder private var menu: some View {
        if transfer.kind == .file, let url = transfer.url {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Quick Look") { preview = url }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            ShareLink(item: url) { Text("Share…") }
            if transfer.state == .failed, transfer.direction == .sent,
               let device = AppModel.shared.devices.first(where: { $0.id == transfer.deviceID }) {
                Button("Send Again") { device.share([url]) }
            }
        } else if transfer.kind == .link, let url = transfer.url {
            Button("Open Link") { NSWorkspace.shared.open(url) }
            Button("Copy Link") { copyText() }
        } else {
            Button("Copy Text") { copyText() }
        }
        Divider()
        Button("Remove from List", role: .destructive) { TransferStore.shared.remove(transfer) }
    }
}

/// The round badge overlapping the preview: the other device, an arrow for direction, and a check
/// that pops in when the transfer completes.
private struct DeviceBadge: View {
    let transfer: Transfer
    let size: CGFloat

    private var badgeColor: Color {
        guard let d = AppModel.shared.devices.first(where: { $0.id == transfer.deviceID }) else { return .gray }
        return DeviceLook.of(d).glow
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(badgeColor.gradient)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "smartphone")
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            Group {
                switch transfer.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
                case .inProgress:
                    Image(systemName: transfer.direction == .received ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(.white, .orange)
                        .symbolEffect(.pulse, isActive: true)
                }
            }
            .font(.system(size: size * 0.45))
            .background(Circle().fill(.background).padding(1))
            .offset(x: size * 0.18, y: size * 0.12)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: transfer.state)
        }
    }
}

/// Thumbnail for files (Quick Look), or a styled tile for links and text.
struct PreviewImage: View {
    let transfer: Transfer
    /// Small tiles: icons only (no host/quote text).
    var compact = false
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            switch transfer.kind {
            case .file:
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else if let url = transfer.url {
                    Rectangle().fill(.quaternary)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                        .frame(width: compact ? 24 : 56, height: compact ? 24 : 56)
                }
            case .link:
                LinearGradient(colors: [.blue.opacity(0.75), .indigo.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if compact {
                    Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                } else {
                VStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 28, weight: .semibold))
                    Text(transfer.url?.host() ?? "Link").font(.caption.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(8)
                }
            case .text:
                LinearGradient(colors: [.orange.opacity(0.7), .pink.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if compact {
                    Image(systemName: "text.quote").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text("“\(transfer.text ?? transfer.name)”")
                        .font(.callout.weight(.medium)).foregroundStyle(.white)
                        .lineLimit(4).padding(12)
                }
            }
        }
        .task(id: transfer.state) { await loadThumbnail() }
    }

    /// Made at the size it's shown (a 32 pt tile doesn't need a 1000 px picture) and kept in a small shared cache, so
    /// reopening the panel doesn't make them again.
    private func loadThumbnail() async {
        guard transfer.kind == .file, transfer.state == .done, let url = transfer.url else { return }
        let size = compact ? CGSize(width: 64, height: 64) : CGSize(width: 280, height: 180)
        let key = "\(url.path)|\(Int(size.width))" as NSString
        if let cached = Self.cache.object(forKey: key) { thumbnail = cached; return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            let image = rep.nsImage
            Self.cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4 * 4))
            thumbnail = image
        }
    }

    /// About 16 MB of thumbnails at most; macOS empties it under memory pressure.
    private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 16 << 20; return c }()
}

/// A progress bar whose filled part is a gently moving wave; indeterminate when the total is unknown.
struct WavyProgress: View {
    let progress: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in   // a gentle wave doesn't need the display's full rate
            let phase = ctx.date.timeIntervalSinceReferenceDate * 4
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let fillWidth = progress.map { w * $0 } ?? w
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Wave(phase: phase, amplitude: h * 0.3)
                        .stroke(Color.janus, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: max(8, fillWidth))
                        .mask {
                            if progress == nil {
                                // Indeterminate: a highlight sweeping across.
                                let x = (sin(phase / 2) + 1) / 2 * w
                                LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: w * 0.5).offset(x: x - w * 0.25)
                            } else {
                                Rectangle()
                            }
                        }
                }
                .frame(height: h)
            }
        }
    }
}

private struct Wave: Shape {
    var phase: Double
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        let step: CGFloat = 2
        var x: CGFloat = 0
        p.move(to: CGPoint(x: 0, y: mid + sin(phase) * amplitude))
        while x <= rect.width {
            x += step
            p.addLine(to: CGPoint(x: x, y: mid + sin(Double(x) / 7 + phase) * amplitude))
        }
        return p
    }
}

/// Small square cards for Overview and the menu bar.
struct RecentTransfersStrip: View {
    var limit = 12
    /// Menu bar version: small square tiles, no names.
    var mini = false
    var onSeeAll: (() -> Void)?
    @State private var store = TransferStore.shared
    @State private var preview: URL?

    var body: some View {
        if !store.items.isEmpty, mini {
            HStack(spacing: 6) {
                ForEach(store.items.prefix(limit)) { t in TransferTile(transfer: t, preview: $preview) }
                Spacer(minLength: 0)
                if let onSeeAll {
                    Button(action: onSeeAll) { Image(systemName: "chevron.right.circle.fill").font(.title3).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("See all transfers")
                }
            }
            .quickLookPreview($preview, in: store.items.compactMap { $0.kind == .file ? $0.url : nil })
        } else if !store.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Transfers").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    if let onSeeAll { Button("See All", action: onSeeAll).buttonStyle(.link) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.items.prefix(limit)) { t in
                            VStack(alignment: .leading, spacing: 4) {
                                TransferCard(transfer: t, preview: $preview, compact: true)
                                    .frame(width: 100)
                                if t.state == .inProgress {
                                    WavyProgress(progress: store.progress(for: t)).frame(width: 100, height: 8)
                                } else {
                                    Text(t.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 100, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 6)
                }
            }
            .quickLookPreview($preview, in: store.items.compactMap { $0.kind == .file ? $0.url : nil })
        }
    }
}

/// 40 pt square tile for the menu bar: preview plus a small status dot.
/// Square thumbnail tile with a direction/status badge; a progress ring while transferring.
struct TransferTile: View {
    let transfer: Transfer
    @Binding var preview: URL?
    var size: CGFloat = 40

    var body: some View {
        let corner = size * 0.24
        Color.clear
            .frame(width: size, height: size)
            .overlay { PreviewImage(transfer: transfer, compact: size < 48) }
            .overlay {
                if transfer.state == .inProgress {
                    ZStack {
                        Color.black.opacity(0.35)
                        Circle().stroke(.white.opacity(0.3), lineWidth: 2.5).frame(width: size * 0.5, height: size * 0.5)
                        if let p = TransferStore.shared.progress(for: transfer) {
                            Circle().trim(from: 0, to: p).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90)).frame(width: size * 0.5, height: size * 0.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .overlay(alignment: .bottomTrailing) {
                if transfer.state != .inProgress {
                    Group {
                        if transfer.state == .failed {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
                        } else {
                            Image(systemName: transfer.direction == .received ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .foregroundStyle(.white, transfer.direction == .received ? Color.blue : Color.green)
                        }
                    }
                    .font(.system(size: max(10, size * 0.32)))
                    .background(Circle().fill(.background).padding(1))
                    .offset(x: 3, y: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                switch transfer.kind {
                case .file: if transfer.state == .done, let u = transfer.url { preview = u }
                case .link: if let u = transfer.url { NSWorkspace.shared.open(u) }
                case .text:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transfer.text ?? transfer.name, forType: .string)
                }
            }
            .help("\(transfer.name) · \(transfer.direction == .received ? "from" : "to") \(transfer.deviceName)")
    }
}
