import AppKit
import Foundation
import Observation
import Security

/// In-app updates from GitHub Releases (no third-party updater). A release has a version tag (`v1.2.0`), notes, and
/// `Janus-<version>.zip` (the app, for updating; the `.dmg` is for first installs).
///
/// Safety: a downloaded Janus is installed only if it's signed by the same certificate as this one (its designated
/// requirement), so nothing else can pass for an update. Files the app downloads itself aren't quarantined, so the
/// update opens without Gatekeeper's "Open Anyway", and macOS keeps its permissions (same certificate).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let page: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "update.lastCheck") as? Date

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "update.automatic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.automatic") }
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// The releases feed (GitHub's API for the latest release); a different one can be set for testing.
    private static var feed: URL {
        UserDefaults.standard.string(forKey: "update.feedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/vivere-181/janus-mac/releases/latest")!
    }

    @ObservationIgnored private var timer: Timer?

    /// Checks once a day while the app runs (the first a minute after launch).
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Task { @MainActor in await Updater.shared.checkIfDue() } }
        Task { try? await Task.sleep(for: .seconds(60)); await checkIfDue() }
    }

    private func checkIfDue() async {
        guard automatic, Date().timeIntervalSince(lastCheck ?? .distantPast) > 86_400 else { return }
        await check(userInitiated: false)
    }

    /// Asks GitHub for the latest release. A newer one opens the update window (quietly, when not asked for).
    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.feed)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw UpdateError.message("No releases yet.") }
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = o["tag_name"] as? String else {
                throw UpdateError.message("The release information couldn't be read.")
            }
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "update.lastCheck")
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = o["assets"] as? [[String: Any]] ?? []
            guard Self.isNewer(version, than: Self.current),
                  let zip = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".zip") }).flatMap(URL.init(string:)) else {
                state = .upToDate
                return
            }
            let release = Release(version: version, notes: o["body"] as? String ?? "", zip: zip,
                                  page: (o["html_url"] as? String).flatMap(URL.init(string:)))
            state = .available(release)
            UpdateWindow.shared.show(activate: userInitiated)
        } catch {
            state = .failed((error as? UpdateError)?.text ?? "Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    func install(_ release: Release) async {
        state = .downloading(0)
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("JanusUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Janus.zip")
            try await download(release.zip, to: zip)
            state = .installing
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message("The download doesn't contain Janus.") }
            try Self.verify(app)
            try relaunch(into: app)
        } catch {
            state = .failed((error as? UpdateError)?.text ?? "The update couldn't be installed: \(error.localizedDescription)")
        }
    }

    private func download(_ url: URL, to file: URL) async throws {
        let progress = DownloadProgress { p in Task { @MainActor in if case .downloading = Updater.shared.state { Updater.shared.state = .downloading(p) } } }
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: progress)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw UpdateError.message("The download failed (\(http.statusCode)).") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
    }

    /// The new app must satisfy this app's own designated requirement: same identifier, same signing certificate.
    static func verify(_ app: URL) throws {
        var running: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else {
            throw UpdateError.message("The update's signature couldn't be checked.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess else {
            throw UpdateError.message("The update isn't signed like this copy of Janus, so it wasn't installed.")
        }
    }

    /// Hands over to a small helper that waits for Janus to quit, swaps the app in place, and opens the new one.
    private func relaunch(into newApp: URL) throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            throw UpdateError.message("Janus can't replace itself where it is. The new version is in the Finder window: drag it to Applications.")
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$OLD.previous" && mv "$OLD" "$OLD.previous" && mv "$NEW" "$OLD" && rm -rf "$OLD.previous" || { [ -d "$OLD.previous" ] && [ ! -d "$OLD" ] && mv "$OLD.previous" "$OLD"; }
        open "$OLD"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["OLD": target.path, "NEW": newApp.path, "PATH": "/usr/bin:/bin"]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw UpdateError.message("The download couldn't be unpacked.") }
        }.value
    }
}

enum UpdateError: Error {
    case message(String)
    var text: String { if case .message(let m) = self { return m }; return "" }
}

/// Download progress for the update window.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
