import AppKit
import SwiftUI

/// "A new version of Janus is available": the version, what's new, Install and Relaunch.
struct UpdateView: View {
    let close: () -> Void

    var body: some View {
        let updater = Updater.shared
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(updater.state)).font(.title2.weight(.semibold))
                    Text(subtitle(updater.state)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .available(let r) = updater.state, !r.notes.isEmpty {
                ScrollView {
                    Text(Self.notes(r.notes))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 180)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if case .downloading(let p) = updater.state {
                ProgressView(value: p) { Text("Downloading…").font(.callout) }
            }
            if updater.state == .installing {
                ProgressView { Text("Installing… Janus will reopen in a moment.").font(.callout) }.progressViewStyle(.linear)
            }
            HStack {
                if case .available(let r) = updater.state, let page = r.page {
                    Button("Release Page") { NSWorkspace.shared.open(page) }.buttonStyle(.link)
                }
                Spacer()
                switch updater.state {
                case .available(let r):
                    Button("Later") { close() }.keyboardShortcut(.cancelAction)
                    Button("Install and Relaunch") { Task { await updater.install(r) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .downloading, .installing, .checking:
                    EmptyView()
                default:
                    Button("OK") { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    /// Release notes as written on GitHub: list items as bullets, headings bold, inline Markdown kept.
    static func notes(_ markdown: String) -> AttributedString {
        let lines = markdown.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return "•  " + t.dropFirst(2) }
            if t.hasPrefix("#") { return "**" + t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**" }
            return String(line)
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func title(_ s: Updater.State) -> String {
        switch s {
        case .available, .downloading, .installing: "A new version of Janus is available"
        case .checking: "Checking for updates…"
        case .upToDate: "Janus is up to date"
        case .failed: "Couldn't update"
        case .idle: "Software Update"
        }
    }

    private func subtitle(_ s: Updater.State) -> String {
        switch s {
        case .available(let r): "Janus \(r.version) is ready to install. You have \(Updater.current)."
        case .downloading, .installing: "Your settings, pairings and permissions stay as they are."
        case .upToDate: "You have the latest version, \(Updater.current)."
        case .failed(let m): m
        default: ""
        }
    }
}

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    static let shared = UpdateWindow()
    private var window: NSWindow?

    /// Shows the update window; `activate` brings Janus forward (when the owner asked), otherwise it waits quietly.
    func show(activate: Bool = true) {
        if let window {
            window.orderFront(nil)
            if activate { window.makeKey(); NSApp.activate() }
            return
        }
        let host = NSHostingController(rootView: UpdateView { [weak self] in self?.window?.close() }.tint(.janus))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Software Update"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        if activate { w.makeKeyAndOrderFront(nil); NSApp.activate() } else { w.orderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

/// Settings → General: the version, the last check, Check Now, and automatic checks.
struct SoftwareUpdateSection: View {
    @State private var automatic = Updater.shared.automatic

    var body: some View {
        let updater = Updater.shared
        Section("Software Update") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Janus \(Updater.current)")
                    Text(status(updater)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .available = updater.state {
                    Button("Update…") { UpdateWindow.shared.show() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.state == .checking)
                }
            }
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { _, v in updater.automatic = v }
        }
    }

    private func status(_ u: Updater) -> String {
        switch u.state {
        case .checking: return "Checking…"
        case .available(let r): return "Version \(r.version) is available"
        case .failed(let m): return m
        default:
            guard let d = u.lastCheck else { return "Not checked yet" }
            return "Checked " + d.formatted(.relative(presentation: .named))
        }
    }
}
