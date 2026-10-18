import Foundation
import SwiftUI

/// What a phone is: maker, model, screen shape, region. Sent by our phone app (`ge.connect.device`, R28); until then
/// filled in from mirroring (scrcpy reports the model and the screen size). Cached per device, so it's there while
/// the phone is away.
struct DeviceProfile: Codable, Equatable {
    var maker: String?
    var brand: String?
    var model: String?
    var device: String?
    var market: String?
    var sdk: Int?
    var release: String?
    var skin: String?
    var colorCode: String?
    struct Screen: Codable, Hashable {
        var w: Double
        var h: Double
        var dpi: Double?
        var xdpi: Double?
        var ydpi: Double?
        /// Corner radius of the display, px.
        var radius: Double?
        /// Camera cutouts as [left, top, right, bottom], px, natural portrait.
        var cutouts: [[Double]]?
    }
    var screen: Screen?
    /// Material You colours (#RRGGBB): the phone's wallpaper palette.
    var accent: [String]?
    var country: String?
    var tz: String?
    var locale: String?
    var app: String?
    /// The `ge.connect.*` commands the phone app understands.
    var caps: [String]?
    /// True once our phone app sent it (not just guessed from mirroring).
    var fromPhone: Bool?

    enum Vendor { case samsung, google, other }

    var vendor: Vendor {
        let m = [maker, brand].compactMap { $0?.lowercased() }
        if m.contains(where: { $0.contains("samsung") }) || model?.uppercased().hasPrefix("SM-") == true
            || skin?.localizedCaseInsensitiveContains("One UI") == true { return .samsung }
        if m.contains(where: { $0 == "google" }) || model?.hasPrefix("Pixel") == true { return .google }
        return .other
    }

    /// "Galaxy S25", "Pixel 9 Pro", or the model as the phone reports it.
    var displayName: String? {
        if let market, !market.isEmpty { return market }
        guard let model, !model.isEmpty else { return nil }
        if let known = KnownModels.name(model) { return known }
        // "Pixel 9" is already a name; a bare code ("CPH2581") reads better with its maker.
        if let maker, !maker.isEmpty, !model.localizedCaseInsensitiveContains(maker),
           model.first(where: \.isLetter).map({ $0.isUppercase }) == true, model.contains(where: \.isNumber),
           !model.contains(" ") {
            return "\(maker.prefix(1).uppercased() + maker.dropFirst()) \(model)"
        }
        return model
    }

    var timeZone: TimeZone? { tz.flatMap(TimeZone.init(identifier:)) }

    /// Fills what `other` knows and this doesn't (a phone's own report wins over guesses).
    func merged(over other: DeviceProfile) -> DeviceProfile {
        var p = self
        p.maker = maker ?? other.maker; p.brand = brand ?? other.brand; p.model = model ?? other.model
        p.device = device ?? other.device; p.market = market ?? other.market; p.sdk = sdk ?? other.sdk
        p.release = release ?? other.release; p.skin = skin ?? other.skin; p.colorCode = colorCode ?? other.colorCode
        p.screen = screen ?? other.screen; p.accent = accent ?? other.accent; p.country = country ?? other.country
        p.tz = tz ?? other.tz; p.locale = locale ?? other.locale; p.app = app ?? other.app; p.caps = caps ?? other.caps
        p.fromPhone = (fromPhone ?? false) || (other.fromPhone ?? false)
        return p
    }
}

/// Model codes whose marketing name the phone doesn't report (Samsung reports only "SM-S931B").
enum KnownModels {
    private static let samsung: [String: String] = [
        "SM-S931": "Galaxy S25", "SM-S936": "Galaxy S25+", "SM-S937": "Galaxy S25 Edge", "SM-S938": "Galaxy S25 Ultra",
        "SM-S731": "Galaxy S25 FE",
        "SM-S921": "Galaxy S24", "SM-S926": "Galaxy S24+", "SM-S928": "Galaxy S24 Ultra", "SM-S721": "Galaxy S24 FE",
        "SM-S911": "Galaxy S23", "SM-S916": "Galaxy S23+", "SM-S918": "Galaxy S23 Ultra", "SM-S711": "Galaxy S23 FE",
        "SM-S901": "Galaxy S22", "SM-S906": "Galaxy S22+", "SM-S908": "Galaxy S22 Ultra",
        "SM-F966": "Galaxy Z Fold7", "SM-F766": "Galaxy Z Flip7", "SM-F956": "Galaxy Z Fold6", "SM-F741": "Galaxy Z Flip6",
        "SM-F946": "Galaxy Z Fold5", "SM-F731": "Galaxy Z Flip5",
        "SM-A566": "Galaxy A56", "SM-A366": "Galaxy A36", "SM-A266": "Galaxy A26",
        "SM-A556": "Galaxy A55", "SM-A356": "Galaxy A35", "SM-A546": "Galaxy A54", "SM-A346": "Galaxy A34",
    ]

    /// "SM-S931B" / "SM-S931U1" → "Galaxy S25".
    static func name(_ model: String) -> String? {
        let m = model.uppercased()
        guard m.hasPrefix("SM-"), m.count >= 7 else { return nil }
        return samsung[String(m.prefix(7))]
    }

    /// The model code family ("SM-S931"), for choosing a drawing.
    static func family(_ model: String?) -> String? {
        guard let m = model?.uppercased(), m.hasPrefix("SM-"), m.count >= 7 else { return nil }
        return String(m.prefix(7))
    }
}

@MainActor
enum DeviceProfiles {
    private static let key = "deviceProfiles"
    private static var cache: [String: DeviceProfile] = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) else { return [:] }
        return all
    }()

    static func get(_ id: String) -> DeviceProfile? { cache[id] }

    /// The phone's own report (R28). Replaces what it covers; earlier guesses fill the rest.
    static func apply(json: String, from device: Device) {
        guard let data = json.data(using: .utf8), var p = try? JSONDecoder().decode(DeviceProfile.self, from: data) else {
            AppModel.shared.log(.warning, "Couldn't read the device profile from \(device.name)")
            return
        }
        p.fromPhone = true
        store(p.merged(over: cache[device.id] ?? DeviceProfile()), for: device)
        device.profile = cache[device.id]
        // Sent after each connect: the moment to sync notes.
        NotesStore.shared.connected(device)
        CloudService.shared.connected(device)
    }

    /// What mirroring learned (scrcpy's model name and the screen in px). Never overrides the phone's own report.
    static func learnFromMirror(model: String, screen: CGSize, device: Device) {
        var guess = DeviceProfile()
        if !model.isEmpty { guess.model = model }
        if screen.width > 0, screen.height > 0 {
            guess.screen = .init(w: min(screen.width, screen.height), h: max(screen.width, screen.height))
        }
        let current = cache[device.id] ?? DeviceProfile()
        var next = current.merged(over: guess)
        // Mirroring knows the real size; a guessed screen (no px from the phone) takes it.
        if current.fromPhone != true, let s = guess.screen { next.screen = s }
        store(next, for: device)
    }

    /// The `os=` status key ("Android 16 · One UI 8.5") tells the skin before a profile arrives.
    static func learnFromStatus(os: String, device: Device) {
        let parts = os.components(separatedBy: " · ")
        var guess = DeviceProfile()
        if let a = parts.first, a.hasPrefix("Android ") { guess.release = String(a.dropFirst(8)) }
        if parts.count > 1 { guess.skin = parts[1] }
        store((cache[device.id] ?? DeviceProfile()).merged(over: guess), for: device)
    }

    static func forget(_ id: String) {
        guard cache.removeValue(forKey: id) != nil else { return }
        save()
    }

    private static func store(_ p: DeviceProfile, for device: Device) {
        guard cache[device.id] != p else { return }
        cache[device.id] = p
        save()
        device.profile = p
        device.lookVersion += 1
    }

    private static func save() {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}
