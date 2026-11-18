import AppKit
import Foundation
import Observation

/// Spotify on this Mac, for the notch. Spotify announces every play, pause, seek and track change itself (the
/// distributed notification `com.spotify.client.PlaybackStateChanged`), so nothing is polled and nothing runs while
/// it's quiet. The artwork, the state when Janus starts and the controls go through Spotify's scripting (macOS asks
/// once whether Janus may control Spotify).
///
/// macOS's own "now playing" isn't used: it names a single app, and a video in a browser can take it over from
/// Spotify at a track change (the notch then lost the music, and its buttons went to the browser).
@MainActor @Observable
final class MacNowPlaying {
    static let shared = MacNowPlaying()
    static let spotify = "com.spotify.client"

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var bundleID: String
        var isPlaying: Bool
        /// Seconds; nil when unknown.
        var duration: TimeInterval?
        /// Seconds played as of `elapsedAt`.
        var elapsed: TimeInterval
        var elapsedAt: Date
        /// "spotify:track:…", for knowing when the artwork changes.
        var id: String
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?

    enum Command { case togglePlayPause, next, previous }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkFor: String?
    /// Scripting runs off the main thread (the first call waits for the permission prompt).
    @ObservationIgnored private let scripting = DispatchQueue(label: "Janus.spotify", qos: .userInitiated)

    func start() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { MacNowPlaying.shared.received(info) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == MacNowPlaying.spotify
            MainActor.assumeIsolated { if quit { MacNowPlaying.shared.clear() } }
        })
        // Already playing when Janus starts: ask once (later changes are announced).
        if Self.isRunning { refresh() }
    }

    func stop() {
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
        clear()
    }

    func send(_ command: Command) {
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        run("tell application id \"\(Self.spotify)\" to \(verb)") { _ in }
    }

    /// Jumps to a point in the track (seconds).
    func seek(to seconds: TimeInterval) {
        run("tell application id \"\(Self.spotify)\" to set player position to \(max(0, seconds))") { _ in }
        if var t = track { t.elapsed = seconds; t.elapsedAt = .now; track = t }
    }

    // MARK: Spotify's announcements

    private func received(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String, !title.isEmpty else { clear(); return }
        let ms = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        update(Track(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                     bundleID: Self.spotify, isPlaying: state == "Playing", duration: ms > 0 ? ms / 1000 : nil,
                     elapsed: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0, elapsedAt: .now,
                     id: info["Track ID"] as? String ?? title))
    }

    private func update(_ next: Track) {
        if next != track { track = next }
        if next.id != artworkFor { loadArtwork(for: next.id) }
    }

    private func clear() {
        track = nil
        artwork = nil
        artworkFor = nil
    }

    // MARK: Scripting

    private static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: spotify).isEmpty }

    /// The whole state in one call (when Janus starts).
    private func refresh() {
        let script = """
        tell application id "\(Self.spotify)"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {player state as string, name of t, artist of t, album of t, duration of t, player position, id of t}
        end tell
        """
        run(script) { [weak self] reply in
            guard let self, let reply, reply.numberOfItems >= 7 else { return }
            let item = { (i: Int) in reply.atIndex(i) }
            let ms = Double(item(5)?.int32Value ?? 0)
            self.update(Track(title: item(2)?.stringValue ?? "", artist: item(3)?.stringValue ?? "",
                              album: item(4)?.stringValue ?? "", bundleID: Self.spotify,
                              isPlaying: item(1)?.stringValue == "playing", duration: ms > 0 ? ms / 1000 : nil,
                              elapsed: item(6)?.doubleValue ?? 0, elapsedAt: .now, id: item(7)?.stringValue ?? ""))
        }
    }

    /// The cover, from Spotify's image server (the link comes from Spotify itself).
    private func loadArtwork(for id: String) {
        artworkFor = id
        run("tell application id \"\(Self.spotify)\" to return artwork url of current track") { [weak self] reply in
            guard let self, let link = reply?.stringValue, let url = URL(string: link), url.scheme == "https" else { return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                      self.artworkFor == id else { return }
                self.artwork = image
            }
        }
    }

    /// Runs an AppleScript for Spotify (only while it's running: a script would otherwise open it).
    private func run(_ source: String, then: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        guard Self.isRunning else { return }
        scripting.async {
            var error: NSDictionary?
            let reply = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let ok = error == nil
            Task { @MainActor in then(ok ? reply : nil) }
        }
    }

    /// "Spotify".
    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "This Mac" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
