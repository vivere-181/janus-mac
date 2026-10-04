// "Janus" in the macOS Share menu. Runs sandboxed inside the share sheet: copies what's shared into
// ~/Library/Caches/Android/Outgoing (its one writable place outside the sandbox) and asks the app to
// send it via janus://share. Built by tools/build-ui.sh (not part of the Swift package).
import AppKit
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private let outgoing: URL = {
        // Inside the sandbox, the home directory points at the container; the real one comes from the user record.
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        return home.appendingPathComponent("Library/Caches/Android/Outgoing", isDirectory: true)
    }()
    private let status = NSTextField(labelWithString: "")

    override func loadView() {
        let phone = (try? String(contentsOf: outgoing.appendingPathComponent(".phone-name"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Sending to \(phone?.isEmpty == false ? phone! : "your phone")")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Preparing…"
        let text = NSStackView(views: [title, status]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let row = NSStackView(views: [icon, text]); row.spacing = 12; row.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 24)
        view = row
        preferredContentSize = NSSize(width: 300, height: 76)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await send() }
    }

    private func send() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let batch = outgoing.appendingPathComponent("Shared \(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        var files: [URL] = []
        var texts: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await fileURL(provider) {
                    let dest = unique(batch.appendingPathComponent(url.lastPathComponent))
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { files.append(dest) }   // APFS clone: instant
                } else if let url = await webURL(provider) {
                    texts.append(url.absoluteString)
                } else if let (data, ext) = await image(provider) {
                    let dest = unique(batch.appendingPathComponent("Image.\(ext)"))
                    if (try? data.write(to: dest)) != nil { files.append(dest) }
                } else if let text = await plainText(provider) {
                    texts.append(text)
                }
            }
            if texts.isEmpty, files.isEmpty, let t = item.attributedContentText?.string, !t.isEmpty { texts.append(t) }
        }
        var c = URLComponents(); c.scheme = "janus"; c.host = "share"
        c.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) } + texts.map { URLQueryItem(name: "text", value: $0) }
        guard !(c.queryItems ?? []).isEmpty, let url = c.url else {
            status.stringValue = "Nothing here can be sent"
            try? await Task.sleep(for: .seconds(1.2))
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        NSWorkspace.shared.open(url)
        let n = files.count + texts.count
        status.stringValue = files.isEmpty ? (n == 1 ? "Link or text sent" : "\(n) items sent")
                                          : (n == 1 ? files.first!.lastPathComponent : "\(n) items")
        try? await Task.sleep(for: .milliseconds(700))
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func unique(_ url: URL) -> URL {
        var u = url, i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(i)")
                .appendingPathExtension(url.pathExtension); i += 1
        }
        return u
    }

    private func load(_ p: NSItemProvider, _ type: UTType) async -> NSSecureCoding? {
        guard p.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in cont.resume(returning: item) }
        }
    }

    private func fileURL(_ p: NSItemProvider) async -> URL? {
        let item = await load(p, .fileURL)
        if let u = item as? URL, u.isFileURL { return u }
        if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil).flatMap { $0.isFileURL ? $0 : nil } }
        return nil
    }

    private func webURL(_ p: NSItemProvider) async -> URL? {
        let item = await load(p, .url)
        let u = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        return u.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
    }

    private func image(_ p: NSItemProvider) async -> (Data, String)? {
        guard p.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let type = p.registeredContentTypes.first { $0.conforms(to: .image) } ?? .png
        let data: Data? = await withCheckedContinuation { cont in
            p.loadDataRepresentation(for: type) { d, _ in cont.resume(returning: d) }
        }
        return data.map { ($0, type.preferredFilenameExtension ?? "png") }
    }

    private func plainText(_ p: NSItemProvider) async -> String? {
        let item = await load(p, .plainText)
        return (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
}
