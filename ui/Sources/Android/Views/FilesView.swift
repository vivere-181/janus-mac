import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    let device: Device
    @State private var targeted = false
    @State private var picking = false
    @State private var text = ""
    @State private var sentNote: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                dropZone
                Card(title: "Send Text or Link", symbol: "link") {
                    HStack {
                        TextField("Paste a link or type some text", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendText)
                        Button("Send", action: sendText).disabled(text.isEmpty)
                    }
                    Text("Links open in the phone's browser; text is copied to the phone's clipboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Received From \(device.name)", symbol: "tray.and.arrow.down") {
                    if device.received.isEmpty {
                        Text("Files shared from the phone are saved to your Downloads folder and listed here.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Downloads") {
                            NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                        }
                    } else {
                        ForEach(device.received) { item in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading) {
                                    Text(item.url.lastPathComponent).lineLimit(1)
                                    Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.url.isFileURL {
                                    Button("Open") { NSWorkspace.shared.open(item.url) }
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    .help("Show in Finder")
                                } else {
                                    Button("Open Link") { NSWorkspace.shared.open(item.url) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Send & Receive")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { send(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.up.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(targeted ? Color.janus : .secondary)
                .symbolEffect(.bounce, value: targeted)
            Text(sentNote ?? "Drop files here to send them to \(device.name)")
                .font(.title3.weight(.medium))
                .contentTransition(.opacity)
            Button("Choose Files…") { picking = true }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .background(targeted ? Color.janus.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(targeted ? Color.janus : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .animation(.snappy, value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            send(urls); return true
        } isTargeted: { targeted = $0 }
    }

    private func send(_ urls: [URL]) {
        device.share(urls)
        withAnimation { sentNote = urls.count == 1 ? "Sending \(urls[0].lastPathComponent)…" : "Sending \(urls.count) files…" }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { sentNote = nil }
        }
    }

    private func sendText() {
        device.shareText(text)
        text = ""
    }
}
