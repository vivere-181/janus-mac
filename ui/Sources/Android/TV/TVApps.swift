import AppKit
import Observation

/// A TV's apps (R39, CONTRACT → ge.connect.tvapps), as Janus on the TV last sent them: name, package and its TV
/// banner. Kept per TV, so the remote shows them at once next time.
@MainActor @Observable
final class TVApps {
    static let shared = TVApps()

    struct App: Identifiable, Equatable {
        let package: String
        let label: String
        let banner: NSImage?
        var id: String { package }
    }

    private var lists: [String: [App]] = [:]
    @ObservationIgnored private var loaded: Set<String> = []

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/TVRemote", isDirectory: true)
    }
    private static func file(_ id: String) -> URL { folder.appendingPathComponent("apps-\(id).json") }

    func apps(for deviceID: String) -> [App] {
        if !loaded.contains(deviceID) {
            loaded.insert(deviceID)
            if let text = try? String(contentsOf: Self.file(deviceID), encoding: .utf8) { lists[deviceID] = Self.parse(text) }
        }
        return lists[deviceID] ?? []
    }

    func receive(_ json: String, from device: Device) {
        let apps = Self.parse(json)
        guard !apps.isEmpty || json.contains("\"apps\"") else { return }
        loaded.insert(device.id)
        lists[device.id] = apps
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? json.write(to: Self.file(device.id), atomically: true, encoding: .utf8)
    }

    /// Asks the TV to send its list again (it does when its apps change, and when it connects).
    func request(_ device: Device) {
        guard device.isReachable else { return }
        device.ping("ge.connect.tvapps.request")
    }

    /// What to call the app in front: the TV's own label, else a known name, else the package's last part.
    func label(for package: String, deviceID: String) -> String {
        if let app = apps(for: deviceID).first(where: { $0.package == package }) { return app.label }
        if let known = Self.known[package] { return known }
        if package.contains("launcher") || package.contains("tvlauncher") { return "Home" }
        let last = package.split(separator: ".").last.map(String.init) ?? package
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    func banner(for package: String, deviceID: String) -> NSImage? {
        apps(for: deviceID).first { $0.package == package }?.banner
    }

    private static let known = [
        "com.google.android.youtube.tv": "YouTube", "com.netflix.ninja": "Netflix",
        "com.google.android.apps.tv.launcherx": "Home", "com.google.android.tvlauncher": "Home",
        "com.amazon.amazonvideo.livingroom": "Prime Video", "com.disney.disneyplus": "Disney+",
        "com.spotify.tv.android": "Spotify", "io.github.vivere_181.janus": "Janus",
    ]

    private static func parse(_ json: String) -> [App] {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = o["apps"] as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let package = a["package"] as? String else { return nil }
            let banner = (a["banner"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            return App(package: package, label: (a["label"] as? String) ?? package, banner: banner)
        }
    }
}
