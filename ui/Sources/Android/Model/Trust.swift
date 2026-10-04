import AppKit

/// "My device" vs "Someone else's" (mirrors the phone app's split). Someone else's device can only send
/// and receive files and links: everything personal is switched off in the engine for it (clipboard,
/// notifications, calls, messages, contacts, media, remote control, Mac actions…), and files it sends
/// wait for Keep / Delete. A device is treated as someone else's until the owner says otherwise.
@MainActor
enum DeviceTrust {
    enum Level: String { case mine, other }

    /// The only engine features someone else's device keeps.
    static let allowedForOthers: Set<String> = ["kdeconnect_share", "kdeconnect_ping"]

    static func level(_ d: Device) -> Level? {
        UserDefaults.standard.string(forKey: "trust.\(d.id)").flatMap(Level.init(rawValue:))
    }

    static func isMine(_ d: Device) -> Bool { level(d) == .mine }

    /// Devices paired before this existed are the owner's own.
    static func migrate(_ devices: [Device]) {
        guard !UserDefaults.standard.bool(forKey: "trust.migrated") else { return }
        let paired = devices.filter(\.isPaired)
        guard !paired.isEmpty else { return }
        for d in paired where level(d) == nil { UserDefaults.standard.set(Level.mine.rawValue, forKey: "trust.\(d.id)") }
        UserDefaults.standard.set(true, forKey: "trust.migrated")
    }

    static func set(_ level: Level, for d: Device) {
        UserDefaults.standard.set(level.rawValue, forKey: "trust.\(d.id)")
        AppModel.shared.log(.info, "\(d.name) is now \(level == .mine ? "your device" : "someone else's device")")
        Task {
            await apply(d)
            MacActions.publish()
        }
    }

    /// Switches the engine's features to match. Features switched off here are remembered, so making it
    /// "mine" again restores exactly those (and leaves the owner's own choices in Settings alone).
    static func apply(_ d: Device) async {
        guard d.isPaired else { return }
        let key = "trust.disabled.\(d.id)"
        var disabled = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if isMine(d) {
            for plugin in disabled { _ = try? await d.call(nil, "", "setPluginEnabled", [.string(plugin), .bool(true)]) }
            disabled = []
        } else {
            for plugin in d.enabledPlugins where !allowedForOthers.contains(plugin) {
                _ = try? await d.call(nil, "", "setPluginEnabled", [.string(plugin), .bool(false)])
                disabled.insert(plugin)
            }
        }
        UserDefaults.standard.set(disabled.sorted(), forKey: key)
    }

    /// Right after pairing: whose device is it?
    static func ask(_ d: Device) {
        MacPopup.shared.show(.init(
            symbol: "person.crop.circle.badge.questionmark", tint: .blue,
            title: "Is \(d.name) your device?",
            subtitle: "Your own devices get everything. Someone else's can only send and receive files and links.",
            button: "My Device", stays: true,
            secondary: ("Someone Else's", { set(.other, for: d) })) { set(.mine, for: d) })
    }

    /// A file from someone else's device: keep it, or move it to the Trash.
    static func confirmFile(_ url: URL, from d: Device) {
        MacPopup.shared.show(.init(
            symbol: "arrow.down.doc.fill", tint: .blue,
            title: "\(d.name) sent \(url.lastPathComponent)",
            subtitle: "It's in \(FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)). Keep it?",
            button: "Keep", stays: true,
            secondary: ("Delete", {
                NSWorkspace.shared.recycle([url])
                AppModel.shared.log(.info, "Deleted \(url.lastPathComponent) from \(d.name)")
            })) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
    }
}
