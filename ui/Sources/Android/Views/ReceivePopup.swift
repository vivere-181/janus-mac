import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Blip-style card that drops down from the menu bar icon when files arrive from the phone (in the shared
/// popup, PopupHost, below a call or a reminder).
@MainActor @Observable
final class ReceivePopup {
    static let shared = ReceivePopup()
    static var enabled: Bool { UserDefaults.standard.object(forKey: "popup.receive") as? Bool ?? true }

    /// Transfers shown in the current card (one batch).
    private(set) var transferIDs: [UUID] = []
    var hovering = false { didSet { if !hovering { scheduleClose() } } }

    @ObservationIgnored private var lastAdded = Date.distantPast
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    static let size = NSSize(width: 250, height: 252)

    var transfers: [Transfer] {
        let items = TransferStore.shared.items
        return transferIDs.compactMap { id in items.first { $0.id == id } }
    }

    var isActive: Bool { !transferIDs.isEmpty }

    /// Called when a received file shows up (in progress or already finished).
    func show(_ transferID: UUID) {
        guard Self.enabled else { return }
        // While the main panel is open it already shows the transfer.
        if StatusItemController.shared.isPanelShown, !isActive { return }
        let batchOpen = isActive && (Date().timeIntervalSince(lastAdded) < 6 || transfers.contains { $0.state == .inProgress })
        if !batchOpen { transferIDs = [] }
        if !transferIDs.contains(transferID) { transferIDs.append(transferID) }
        lastAdded = Date()
        PopupHost.shared.refresh()
        scheduleClose()
    }

    func transferChanged() {
        guard isActive else { return }
        scheduleClose()
    }

    func close() {
        closeTask?.cancel()
        transferIDs = []
        hovering = false
        PopupHost.shared.refresh()
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            while let self, !Task.isCancelled,
                  self.hovering || self.transfers.contains(where: { $0.state == .inProgress }) {
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.close()
        }
    }

    /// The button of our menu bar item (created by SwiftUI's MenuBarExtra).
    static func statusButton() -> NSView? {
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).contains("StatusBarButton") { return v }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") && w.isVisible {
            if let root = w.contentView, let b = find(root) ?? (w.frame.height < 60 ? root : nil) { return b }
        }
        return nil
    }

    static func statusItemFrame() -> NSRect? {
        (StatusItemController.shared.button ?? statusButton()).flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
    }
}

struct ReceivePopupView: View {
    let popup: ReceivePopup
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var checkShown = false
    @Environment(\.popupStacked) private var stacked

    private var transfers: [Transfer] { popup.transfers }
    private var inProgress: Bool { transfers.contains { $0.state == .inProgress } }
    private var failed: Bool { !inProgress && transfers.contains { $0.state == .failed } }
    private var urls: [URL] { transfers.compactMap { $0.state == .done ? $0.url : nil } }

    private var overallProgress: Double? {
        let ps = transfers.map { TransferStore.shared.progress(for: $0) ?? ($0.state == .done ? 1 : nil) }
        guard !ps.contains(where: { $0 == nil }), !ps.isEmpty else { return nil }
        return ps.compactMap { $0 }.reduce(0, +) / Double(ps.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                previewStack
                    .frame(maxWidth: .infinity)
                    .frame(height: 118)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if popup.hovering {
                    Button { popup.close() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .transition(.opacity)
                }
            }
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.janus.opacity(inProgress ? 0 : 0.9), in: Capsule())
                    .foregroundStyle(inProgress ? Color.primary : Color.janusOn)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button { copy() } label: {
                    Text("Copy").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(urls.isEmpty)
                HStack(spacing: 0) {
                    Button { open() } label: {
                        Text("Open").font(.subheadline.weight(.semibold)).foregroundStyle(Color.janusOn)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 16)
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls); popup.close() }
                        if urls.count > 1 { Button("Open All") { urls.forEach { NSWorkspace.shared.open($0) }; popup.close() } }
                        Divider()
                        Button("Show All Transfers") {
                            AppModel.shared.section = .files; AppModel.shared.wantsMainWindow = true; popup.close()
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.janusOn)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 10)
                }
                .background(Color.janus, in: Capsule())
                .opacity(urls.isEmpty ? 0.5 : 1)
                .disabled(urls.isEmpty)
            }
        }
        .padding(12)
        .frame(width: stacked ? PopupStack.width : ReceivePopup.size.width)
        .fixedSize(horizontal: false, vertical: true)   // height follows the content: equal padding on all sides
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { popup.hovering = h } }
        .task(id: transfers.map(\.state)) { await loadThumbnails() }
    }

    private var title: String {
        transfers.count == 1 ? transfers[0].name : "\(transfers.count) Items"
    }

    private var subtitle: String {
        let from = transfers.first?.deviceName ?? "your phone"
        if !inProgress, transfers.count == 1, let note = transfers[0].note { return note }
        if inProgress {
            var s = "Receiving from \(from)"
            if let p = overallProgress { s = "\(Int(p * 100))% · " + s }
            return s
        }
        return failed ? "Didn't finish · \(from)" : "Received from \(from)"
    }

    /// Up to three previews fanned out, with the status badge on top.
    private var previewStack: some View {
        ZStack {
            ForEach(Array(transfers.suffix(3).enumerated()), id: \.element.id) { i, t in
                let count = min(transfers.count, 3)
                let offset = CGFloat(i - (count - 1))
                preview(t)
                    .frame(width: 68, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .rotationEffect(.degrees(Double(offset) * 6))
                    .offset(x: offset * 8, y: offset * 3)
            }
            statusBadge
                .offset(y: 30)
        }
    }

    @ViewBuilder private func preview(_ t: Transfer) -> some View {
        if let img = thumbnails[t.id] {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let url = t.url {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        ZStack {
            Circle().fill(.white).frame(width: 36, height: 36).shadow(radius: 2)
            if inProgress {
                Circle().stroke(.quaternary, lineWidth: 4).frame(width: 28, height: 28)
                if let p = overallProgress {
                    Circle().trim(from: 0, to: p)
                        .stroke(Color.janus, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 28, height: 28)
                        .animation(.linear(duration: 0.3), value: p)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                ZStack {
                    Circle().fill(failed ? Color.red : Color.green).frame(width: 30, height: 30)
                    Image(systemName: failed ? "exclamationmark" : "checkmark")
                        .font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                }
                .scaleEffect(checkShown ? 1 : 0.3)
                .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { checkShown = true } }
                .onDisappear { checkShown = false }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: inProgress)
    }

    private func loadThumbnails() async {
        for t in transfers.suffix(3) where t.state == .done && thumbnails[t.id] == nil {
            guard let url = t.url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 184, height: 236), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumbnails[t.id] = rep.nsImage
            }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        popup.close()
    }

    private func open() {
        if urls.count == 1 { NSWorkspace.shared.open(urls[0]) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        popup.close()
    }
}

