import Foundation
import JanusLink
import KDEConnectKit

/// A feature on a device (KDE Connect's plugin model): the packet types it takes and sends, and the object it shows
/// the app at `/devices/<id>/<subpath>` (properties, methods, signals) — the same as KDE's plugin of that name.
class NativePlugin {
    class var id: String { "" }
    /// Path under the device (nil: the device's own path, e.g. sms conversations).
    class var subpath: String? { nil }
    class var interface: String { "" }
    class var incoming: [String] { [] }
    class var outgoing: [String] { [] }
    class var enabledByDefault: Bool { true }
    /// Methods this plugin answers on the device's own path.
    class var deviceLevelMembers: Set<String> { [] }

    unowned let device: NativeDevice
    required init(device: NativeDevice) { self.device = device }

    /// The link is up and the plugin is loaded.
    func connected() {}
    func unloaded() {}
    func received(_ p: Packet) {}
    func properties(sub: String) -> [String: DBusValue] { [:] }
    func setProperty(_ name: String, _ value: DBusValue) throws { throw NativeEngine.unknown("property \(name)") }
    func call(sub: String?, interface: String, member: String, _ args: [DBusValue]) throws -> [DBusValue] {
        throw NativeEngine.unknown("\(Self.id).\(member)")
    }

    var engine: NativeEngine { device.engine }
    func send(_ p: Packet) { device.send(p) }
    func emit(_ member: String, _ body: [DBusValue], sub: String? = nil) {
        device.emit(sub ?? Self.subpath, Self.interface, member, body)
    }
}

/// Every plugin, with the packet types KDE's plugin of the same name declares (KDE Connect 26.04, matching what the
/// previous engine announced). A plugin without a native implementation yet still counts for "supported", so the
/// app's view of the device is the same; it just does nothing until it's implemented.
enum PluginRegistry {
    struct Entry {
        let id: String
        let incoming: [String]
        let outgoing: [String]
        let enabledByDefault: Bool
        let make: (NativeDevice) -> NativePlugin
    }

    static func entry(_ t: NativePlugin.Type) -> Entry {
        Entry(id: t.id, incoming: t.incoming, outgoing: t.outgoing, enabledByDefault: t.enabledByDefault) { t.init(device: $0) }
    }

    static func declared(_ id: String, in incoming: [String], out outgoing: [String], enabledByDefault: Bool = true) -> Entry {
        Entry(id: id, incoming: incoming, outgoing: outgoing, enabledByDefault: enabledByDefault) { Placeholder(device: $0) }
    }

    static let all: [Entry] = [
        entry(PingPlugin.self),
        entry(BatteryPlugin.self),
        entry(ConnectivityPlugin.self),
        entry(FindMyPhonePlugin.self),
        entry(TelephonyPlugin.self),
        entry(NotificationsPlugin.self),
        entry(SharePlugin.self),
        entry(ClipboardPlugin.self),
        entry(ContactsPlugin.self),
        entry(MousepadPlugin.self),
        entry(MprisRemotePlugin.self),
        declared("kdeconnect_presenter", in: ["kdeconnect.presenter"], out: []),
        declared("kdeconnect_remotecommands", in: ["kdeconnect.runcommand"], out: ["kdeconnect.runcommand.request"]),
        entry(RemoteControlPlugin.self),
        entry(RemoteKeyboardPlugin.self),
        declared("kdeconnect_remotesystemvolume", in: ["kdeconnect.systemvolume"], out: ["kdeconnect.systemvolume.request"]),
        entry(RunCommandPlugin.self),
        entry(SmsPlugin.self),
        entry(SystemVolumePlugin.self),
        declared("kdeconnect_virtualmonitor", in: ["kdeconnect.virtualmonitor", "kdeconnect.virtualmonitor.request"],
                 out: ["kdeconnect.virtualmonitor", "kdeconnect.virtualmonitor.request"]),
    ]

    static let byID: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// A plugin not implemented natively yet: loaded (so the app's view matches) but silent.
final class Placeholder: NativePlugin {}
