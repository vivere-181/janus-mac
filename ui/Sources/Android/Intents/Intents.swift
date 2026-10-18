import AppIntents
import Foundation

// MARK: Device picker

struct PhoneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Phone"
    static let defaultQuery = PhoneQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "smartphone"))
    }
}

struct PhoneQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [PhoneEntity] {
        AppModel.shared.pairedDevices.filter { identifiers.contains($0.id) }.map { PhoneEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func suggestedEntities() async throws -> [PhoneEntity] {
        AppModel.shared.pairedDevices.map { PhoneEntity(id: $0.id, name: $0.name) }
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected, missingFeature(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Your phone isn't connected. Open Janus on the phone and try again."
        case .missingFeature(let f): "\(f) isn't turned on for this phone."
        }
    }
}

/// The requested phone (or the connected one), waiting up to 10 s if the app was just launched.
@MainActor
func connectedPhone(_ entity: PhoneEntity?) async throws -> Device {
    for _ in 0..<40 {
        let model = AppModel.shared
        if let e = entity, let d = model.devices.first(where: { $0.id == e.id }), d.isReachable { return d }
        if entity == nil, let d = model.selectedDevice, d.isReachable { return d }
        if entity == nil, let d = model.connectedDevices.first { return d }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw IntentFailure.notConnected
}

// MARK: Actions

struct RingPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Ring Phone"
    static let description = IntentDescription("Makes your phone ring loudly so you can find it.")
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        let d = try await connectedPhone(phone)
        guard d.has("findmyphone") else { throw IntentFailure.missingFeature("Find my phone") }
        d.ring()
        return .result()
    }
}

struct PingPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Ping Phone"
    static let description = IntentDescription("Shows a ping notification on your phone, with an optional message.")
    @Parameter(title: "Message") var message: String?
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        let d = try await connectedPhone(phone)
        d.ping(message?.isEmpty == false ? message : nil)
        return .result()
    }
}

struct SendFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Files to Phone"
    static let description = IntentDescription("Sends files to your phone. They're saved in the phone's downloads.")
    @Parameter(title: "Files", supportedContentTypes: [.item]) var files: [IntentFile]
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        let d = try await connectedPhone(phone)
        // Copies stay in Caches until the next launch, since the transfer runs after this returns.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Android/Outgoing/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for f in files {
            let dest = dir.appendingPathComponent(f.filename.isEmpty ? "file" : f.filename)
            if let src = f.fileURL, FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            } else {
                try f.data.write(to: dest)
            }
            urls.append(dest)
        }
        d.share(urls)
        return .result()
    }
}

struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text or Link to Phone"
    static let description = IntentDescription("Links open on the phone; other text goes to the phone's clipboard.")
    @Parameter(title: "Text or Link") var text: String
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedPhone(phone).shareText(text)
        return .result()
    }
}

struct SendClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Clipboard to Phone"
    static let description = IntentDescription("Sends this Mac's clipboard text to your phone.")
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedPhone(phone).sendClipboard()
        return .result()
    }
}

struct SendSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text Message"
    static let description = IntentDescription("Sends an SMS from your phone.")
    @Parameter(title: "To", description: "Phone number") var recipient: String
    @Parameter(title: "Message") var message: String
    @Parameter(title: "Phone") var phone: PhoneEntity?
    static var parameterSummary: some ParameterSummary {
        Summary("Text \(\.$message) to \(\.$recipient)") { \.$phone }
    }
    @MainActor func perform() async throws -> some IntentResult {
        let d = try await connectedPhone(phone)
        guard d.has("sms") else { throw IntentFailure.missingFeature("Messages") }
        d.sendMessage(message, to: [recipient])
        return .result()
    }
}

enum MediaCommand: String, AppEnum {
    case playPause = "PlayPause", next = "Next", previous = "Previous", pause = "Pause", play = "Play"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Media Command"
    static let caseDisplayRepresentations: [MediaCommand: DisplayRepresentation] = [
        .playPause: "Play/Pause", .next: "Next Track", .previous: "Previous Track", .pause: "Pause", .play: "Play",
    ]
}

struct PhoneMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Phone Media"
    static let description = IntentDescription("Plays, pauses or skips what's playing on your phone.")
    @Parameter(title: "Command", default: .playPause) var command: MediaCommand
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedPhone(phone).mediaAction(command.rawValue)
        return .result()
    }
}

struct GetBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Phone Battery Level"
    static let description = IntentDescription("Returns the phone's battery percentage.")
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let d = try await connectedPhone(phone)
        guard let level = d.batteryCharge else { throw IntentFailure.missingFeature("Battery") }
        return .result(value: level, dialog: "\(d.name) is at \(level)%\(d.isCharging ? " and charging" : "").")
    }
}

struct IsConnectedIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Phone Connected"
    static let description = IntentDescription("Returns whether the phone is connected to this Mac.")
    @Parameter(title: "Phone") var phone: PhoneEntity?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let connected = (try? await connectedPhone(phone)) != nil
        return .result(value: connected)
    }
}

struct LatestCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Verification Code"
    static let description = IntentDescription("Returns the most recent verification code from the last 10 minutes and copies it.")
    @Parameter(title: "Copy to Clipboard", default: true) var copy: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let latest = CodeCenter.shared.latest, Date().timeIntervalSince(latest.date) < 600 else {
            return .result(value: "", dialog: "No verification code in the last 10 minutes.")
        }
        if copy { CodeCenter.shared.copy(latest.code, autoClear: true) }
        return .result(value: latest.code, dialog: "\(latest.code) from \(latest.from)\(copy ? " (copied)" : "")")
    }
}

struct SetPhoneDNDIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Phone Do Not Disturb"
    static let description = IntentDescription("Turns Do Not Disturb on or off on your phone.")
    @Parameter(title: "Do Not Disturb", default: true) var on: Bool
    @Parameter(title: "Phone") var phone: PhoneEntity?
    static var parameterSummary: some ParameterSummary {
        Summary("Turn phone Do Not Disturb \(\.$on)") { \.$phone }
    }
    @MainActor func perform() async throws -> some IntentResult {
        let d = try await connectedPhone(phone)
        guard d.supports("dnd") else { throw IntentFailure.missingFeature("Do Not Disturb sync (Janus on the phone)") }
        d.setPhoneDND(on, reason: "Shortcut")
        return .result()
    }
}

// MARK: Siri & Spotlight phrases

struct AndroidShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RingPhoneIntent(), phrases: ["Ring my phone with \(.applicationName)", "Find my phone with \(.applicationName)"],
                    shortTitle: "Ring Phone", systemImageName: "speaker.wave.3.fill")
        AppShortcut(intent: SendClipboardIntent(), phrases: ["Send clipboard to my phone with \(.applicationName)"],
                    shortTitle: "Send Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: GetBatteryIntent(), phrases: ["Check my phone battery with \(.applicationName)", "Phone battery in \(.applicationName)"],
                    shortTitle: "Phone Battery", systemImageName: "battery.75percent")
        AppShortcut(intent: LatestCodeIntent(), phrases: ["Copy verification code with \(.applicationName)", "Get my code from \(.applicationName)"],
                    shortTitle: "Latest Code", systemImageName: "key.fill")
        AppShortcut(intent: PhoneMediaIntent(), phrases: ["Pause my phone with \(.applicationName)", "Play my phone with \(.applicationName)"],
                    shortTitle: "Play/Pause Phone", systemImageName: "playpause.fill")
        AppShortcut(intent: PingPhoneIntent(), phrases: ["Ping my phone with \(.applicationName)"],
                    shortTitle: "Ping Phone", systemImageName: "hand.wave.fill")
    }
}
