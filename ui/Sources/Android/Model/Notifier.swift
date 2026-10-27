import AppKit
import UserNotifications

/// All Mac notifications come from here (the engine's own pop-ups are switched off), so they carry
/// this app's name, icon and actions.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    enum Kind: String, CaseIterable {
        case phone = "notify.phone", codes = "codes.enabled", ping = "notify.ping", calls = "notify.calls", files = "notify.files", battery = "notify.battery", pairing = "notify.pairing"
        var title: String {
            switch self {
            case .phone: "Phone notifications"
            case .ping: "Pings from your phone"
            case .codes: "Verification codes (with Copy button)"
            case .calls: "Incoming and missed calls"
            case .files: "Files and links received"
            case .battery: "Phone battery low"
            case .pairing: "Pairing requests"
            }
        }
    }

    static func isOn(_ kind: Kind) -> Bool { UserDefaults.standard.object(forKey: kind.rawValue) as? Bool ?? true }

    /// Apps whose phone notifications don't appear on this Mac (they're still listed in the app).
    static var mutedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notify.mutedApps") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "notify.mutedApps") }
    }
    static var phoneSounds: Bool { UserDefaults.standard.object(forKey: "notify.phone.sound") as? Bool ?? true }

    static func setMuted(_ app: String, _ muted: Bool) {
        var apps = mutedApps
        if muted { apps.insert(app) } else { apps.remove(app) }
        mutedApps = apps
    }

    private var baseCategories: Set<UNNotificationCategory> = []
    /// One category per combination of phone actions (macOS needs the buttons declared up front).
    private var actionCategories: [String: UNNotificationCategory] = [:]
    private let replyAction = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
    private let dismissAction = UNNotificationAction(identifier: "dismissOnPhone", title: "Dismiss on Phone")

    func setup(model: AppModel) {
        self.model = model
        center.delegate = self
        let reply = replyAction
        let dismiss = dismissAction
        baseCategories = Set([
            UNNotificationCategory(identifier: "phone.reply", actions: [reply, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: "phone", actions: [dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: "pairing", actions: [
                UNNotificationAction(identifier: "accept", title: "Pair", options: [.foreground]),
                UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "call", actions: [
                UNNotificationAction(identifier: "declineCall", title: "Decline", options: [.destructive]),
                UNNotificationAction(identifier: "muteCall", title: "Mute Ringer"),
                UNTextInputNotificationAction(identifier: "replyCall", title: "Reply with Message…", options: [],
                                              textInputButtonTitle: "Send", textInputPlaceholder: "Can't talk right now."),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "otp", actions: [
                UNNotificationAction(identifier: "copyCode", title: "Copy Code"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "calendar", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "calendar.join", actions: [
                UNNotificationAction(identifier: "joinMeeting", title: "Join", options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "file", actions: [
                UNNotificationAction(identifier: "reveal", title: "Show in Finder", options: [.foreground]),
            ], intentIdentifiers: []),
        ])
        center.setNotificationCategories(baseCategories)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Posting

    func phoneNotification(_ n: PhoneNotification, device: Device) {
        guard Self.isOn(.phone), !Self.mutedApps.contains(n.appName) else { return }
        let icon = n.iconPath.map { URL(string: $0)?.isFileURL == true ? URL(string: $0)!.path : $0 }
        let banner = Banner(
            id: identifier(device, n.id), thread: "\(device.id).\(n.appName).\(n.title)",
            icon: icon.map { .image($0) } ?? .symbol("app.badge.fill", .gray),
            appName: n.appName.isEmpty ? device.name : n.appName,
            title: n.title.isEmpty ? (n.appName.isEmpty ? device.name : n.appName) : n.title,
            body: n.text.isEmpty ? n.ticker : n.text,
            lifetime: 7, sound: !n.silent && Self.phoneSounds ? Sounds.alert : nil,
            actions: n.actions.prefix(n.replyId.isEmpty ? 3 : 2).map { a in BannerAction(title: a) { device.trigger(a, on: n) } },
            reply: n.replyId.isEmpty ? nil : { text in device.reply(to: n, text) },
            onOpen: { [weak model = self.model] in model?.section = .notifications; model?.wantsMainWindow = true })
        if BannerCenter.shared.show(banner) { return }
        let c = UNMutableNotificationContent()
        c.title = n.title.isEmpty ? (n.appName.isEmpty ? device.name : n.appName) : n.title
        if !n.appName.isEmpty && !n.title.isEmpty { c.subtitle = n.appName }
        c.body = NotificationText.plain(n.text.isEmpty ? n.ticker : n.text)
        c.threadIdentifier = "\(device.id).\(n.appName)"
        c.categoryIdentifier = category(for: n)
        c.userInfo = ["device": device.id, "notification": n.id, "app": n.appName]
        if !n.silent, Self.phoneSounds { c.sound = Sounds.notification }
        if let p = n.iconPath.map({ URL(string: $0)?.isFileURL == true ? URL(string: $0)! : URL(fileURLWithPath: $0) }),
           let att = try? UNNotificationAttachment(identifier: "icon", url: copyForAttachment(p)) {
            c.attachments = [att]
        }
        post(id: identifier(device, n.id), c)
    }

    /// Reply (if the app supports it), the app's own buttons ("Mark as read", "Like"…), then
    /// muting the app on this Mac and dismissing it on the phone.
    private func category(for n: PhoneNotification) -> String {
        let phoneActions = Array(n.actions.prefix(3))
        let key = "phone.\(n.replyId.isEmpty ? "" : "r").\(phoneActions.joined(separator: "|")).\(n.appName)"
        if actionCategories[key] == nil {
            var actions: [UNNotificationAction] = n.replyId.isEmpty ? [] : [replyAction]
            actions += phoneActions.map { UNNotificationAction(identifier: "act:" + $0, title: $0) }
            if !n.appName.isEmpty {
                actions.append(UNNotificationAction(identifier: "muteApp", title: "Mute \(n.appName) on This Mac"))
            }
            actions.append(dismissAction)
            actionCategories[key] = UNNotificationCategory(identifier: key, actions: actions, intentIdentifiers: [])
            center.setNotificationCategories(baseCategories.union(actionCategories.values))
        }
        return key
    }

    func verificationCode(_ code: String, from sender: String, device: Device, copied: Bool) {
        if BannerCenter.shared.show(Banner(
            id: "otp.\(code)", thread: "otp", icon: .symbol("key.fill", .green), title: "Verification code",
            body: copied ? "From \(sender) · Copied to the clipboard" : "From \(sender)", code: code, lifetime: 30, sound: Sounds.alert,
            actions: [BannerAction(title: copied ? "Copy Again" : "Copy Code", primary: true) { CodeCenter.shared.copy(code, autoClear: true) }])) { return }
        let c = UNMutableNotificationContent()
        c.title = "Verification code \(code)"
        c.body = copied ? "From \(sender) · Copied to clipboard" : "From \(sender)"
        c.categoryIdentifier = "otp"
        c.userInfo = ["code": code]
        c.sound = Sounds.notification
        c.interruptionLevel = .timeSensitive
        // One per sender: a newer code replaces the older one, so the one in Notification Center is the one to use.
        post(id: "otp.\(device.id).\(sender)", c)
    }

    func ping(from device: Device, message: String) {
        guard Self.isOn(.ping) else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if BannerCenter.shared.show(Banner(
            id: "ping.\(UUID().uuidString)", thread: "ping.\(device.id)", icon: .symbol("bell.fill", .blue),
            appName: device.name, title: text.isEmpty ? "Ping!" : text, lifetime: 8, sound: Sounds.alert)) { return }
        let c = UNMutableNotificationContent()
        c.title = device.name
        c.body = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ping!" : message
        c.sound = Sounds.notification
        post(id: "ping.\(device.id).\(UUID().uuidString)", c)
    }

    func removePhoneNotification(_ id: String, device: Device) {
        BannerCenter.shared.dismiss(identifier(device, id))
        center.removeDeliveredNotifications(withIdentifiers: [identifier(device, id)])
    }

    /// The engine reports an incoming call as "callReceived" (it renames the phone's "ringing") and a
    /// missed one as "missedCall". An answered call sends nothing, so the incoming-call notification
    /// removes itself after a minute.
    func call(event: String, number: String, contactName: String, device: Device) {
        let ringing = event == "callReceived" || event == "ringing"
        // The menu bar's unread dot, until the panel or the window is opened (already open: seen).
        if event == "missedCall", DeviceTrust.isMine(device), !AppModel.uiVisible { StatusItemController.shared.missedCalls += 1 }
        guard Self.isOn(.calls), ringing || event == "missedCall" else { return }
        let ringingID = "call.\(device.id).\(number).ringing"
        let c = UNMutableNotificationContent()
        let who = contactName.isEmpty || contactName == number ? (number.isEmpty ? "Unknown caller" : number) : contactName
        c.title = ringing ? "Incoming call" : "Missed call"
        c.body = "\(who) · \(device.name)"
        c.sound = ringing ? Sounds.ringNotification : Sounds.notification
        c.userInfo = ["device": device.id, "number": number]
        if ringing, CallPopup.shared.show(number: number, contactName: contactName, device: device) {
            return   // the popup has the buttons; a notification would duplicate it
        }
        if !ringing { CallPopup.shared.callEnded(number: number) }
        if ringing {
            c.categoryIdentifier = "call"
            c.interruptionLevel = .timeSensitive
            post(id: ringingID, c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.center.removeDeliveredNotifications(withIdentifiers: [ringingID])
            }
        } else {
            center.removeDeliveredNotifications(withIdentifiers: [ringingID])
            let missed = Banner(
                id: "call.\(device.id).\(number).missedCall", thread: "missed.\(device.id).\(number)",
                icon: .symbol("phone.arrow.down.left.fill", .red), appName: device.name, title: "Missed call", body: who,
                lifetime: 30, sound: Sounds.alert,
                actions: number.isEmpty || !device.supports("dial") ? [] : [BannerAction(title: "Call Back", primary: true) { [weak self] in
                    device.dial(number)
                    self?.calling(number, device: device)
                }])
            if BannerCenter.shared.show(missed) { return }
            post(id: "call.\(device.id).\(number).missedCall", c)
        }
    }

    func calling(_ number: String, device: Device) {
        if BannerCenter.shared.show(Banner(
            id: "calling.\(number)", thread: "calling", icon: .symbol("phone.fill", .green),
            title: "Call \(device.contact(for: number)?.name ?? number) on your phone",
            body: "Tap Call on \(device.name) to start the call.", lifetime: 8)) { return }
        let c = UNMutableNotificationContent()
        c.title = "Call \(device.contact(for: number)?.name ?? number) on your phone"
        c.body = "Tap Call on \(device.name) to start the call."
        post(id: "calling.\(number)", c)
    }

    func pairingRequest(_ device: Device) {
        guard Self.isOn(.pairing) else { return }
        if BannerCenter.shared.show(Banner(
            id: "pair.\(device.id)", thread: "pair.\(device.id)", icon: .symbol("iphone.gen3.radiowaves.left.and.right", .blue),
            title: "\(device.name) wants to pair",
            body: "Check that this key matches the one on your phone: \(device.verificationKey)", important: true, sound: Sounds.alert,
            actions: [BannerAction(title: "Decline") { device.rejectPairing() },
                      BannerAction(title: "Pair", primary: true) { device.acceptPairing() }])) { return }
        let c = UNMutableNotificationContent()
        c.title = "\(device.name) wants to pair"
        c.body = "Verification key: \(device.verificationKey)"
        c.categoryIdentifier = "pairing"
        c.userInfo = ["device": device.id]
        c.sound = Sounds.notification
        post(id: "pair.\(device.id)", c)
    }

    func received(_ url: URL, device: Device) {
        guard Self.isOn(.files) else { return }
        if url.isFileURL, ReceivePopup.enabled { return }   // the menu bar popup shows it instead
        if !url.isFileURL, BannerCenter.shared.show(Banner(
            id: "link.\(UUID().uuidString)", thread: "link.\(url.absoluteString)", icon: .symbol("link", .blue),
            appName: device.name, title: "Link received", body: url.absoluteString, lifetime: 15, sound: Sounds.alert,
            actions: [BannerAction(title: "Copy") {
                          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) },
                      BannerAction(title: "Open", primary: true) { NSWorkspace.shared.open(url) }])) { return }
        let c = UNMutableNotificationContent()
        c.title = url.isFileURL ? "Received \(url.lastPathComponent)" : "Link received"
        c.body = url.isFileURL ? "From \(device.name) · saved to \(url.deletingLastPathComponent().lastPathComponent)" : url.absoluteString
        c.categoryIdentifier = "file"
        if !url.isFileURL { c.sound = Sounds.notification }   // files chime when they're all in (TransferStore)
        c.userInfo = ["url": url.absoluteString]
        post(id: "file.\(UUID().uuidString)", c)
    }

    /// Text shared from the phone (through Janus Cloud): copied, and shown with Copy again.
    func receivedText(_ text: String, device: Device) {
        guard Self.isOn(.files) else { return }
        if BannerCenter.shared.show(Banner(
            id: "text.\(UUID().uuidString)", thread: "text.\(device.id)", icon: .symbol("text.quote", .blue),
            appName: device.name, title: "Text received · copied", body: String(text.prefix(300)), lifetime: 15, sound: Sounds.alert,
            actions: [BannerAction(title: "Copy", primary: true) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }])) { return }
        let c = UNMutableNotificationContent()
        c.title = "Text from \(device.name) · copied"
        c.body = String(text.prefix(300))
        c.sound = Sounds.notification
        post(id: "text.\(UUID().uuidString)", c)
    }

    func batteryLow(_ charge: Int, device: Device) {
        guard Self.isOn(.battery) else { return }
        if BannerCenter.shared.show(Banner(
            id: "battery.\(device.id)", thread: "battery.\(device.id)", icon: .symbol("battery.25percent", .orange),
            title: "\(device.name) battery low", body: "\(charge)% remaining", lifetime: 12, sound: Sounds.alert)) { return }
        let c = UNMutableNotificationContent()
        c.title = "\(device.name) battery low"
        c.body = "\(charge)% remaining"
        c.sound = Sounds.notification
        post(id: "battery.\(device.id)", c)
    }

    private func post(id: String, _ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func identifier(_ device: Device, _ id: String) -> String { "phone.\(device.id).\(id)" }

    /// Attachments are moved into the notification store, so hand over a copy.
    /// The engine stores pictures without an extension; name the copy by its real type (JPEG photos,
    /// PNG icons) so the attachment is recognized.
    private func copyForAttachment(_ url: URL) -> URL {
        var ext = url.pathExtension
        if ext.isEmpty, let h = try? FileHandle(forReadingFrom: url) {
            let head = [UInt8](h.readData(ofLength: 4))
            try? h.close()
            if head.starts(with: [0xFF, 0xD8]) { ext = "jpg" }
            else if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { ext = "webp" }
            else if head.starts(with: [0x47, 0x49, 0x46]) { ext = "gif" }
            else { ext = "png" }
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try? FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: Responses

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let deviceID = info["device"] as? String
        let notifID = info["notification"] as? String
        let appName = info["app"] as? String
        let urlString = info["url"] as? String
        let code = info["code"] as? String
        let number = info["number"] as? String
        let join = info["join"] as? String
        let isCalendar = response.notification.request.content.categoryIdentifier.hasPrefix("calendar")
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { completionHandler() }
            guard let model = self.model else { return }
            let device = model.devices.first { $0.id == deviceID }
            switch action {
            case "reply":
                if let device, let n = device.notifications.first(where: { $0.id == notifID }), let text, !text.isEmpty {
                    device.reply(to: n, text)
                }
            case let a where a.hasPrefix("act:"):
                if let device, let n = device.notifications.first(where: { $0.id == notifID }) {
                    device.trigger(String(a.dropFirst(4)), on: n)
                }
            case "muteApp":
                if let app = appName, !app.isEmpty {
                    Self.setMuted(app, true)
                    model.log(.info, "Muted \(app) notifications on this Mac")
                }
            case "dismissOnPhone":
                if let device, let n = device.notifications.first(where: { $0.id == notifID }) { device.dismiss(n) }
            case "copyCode", UNNotificationDefaultActionIdentifier where code != nil:
                if let code { CodeCenter.shared.copy(code, autoClear: true) }
            case "declineCall": device?.declineCall()
            case "muteCall": device?.muteRinger()
            case "replyCall":
                if let device, let number, let text, !text.isEmpty {
                    device.sendMessage(text, to: [number])
                    device.declineCall()
                }
            case "joinMeeting":
                if let join, let url = URL(string: join) { NSWorkspace.shared.open(url) }
            case UNNotificationDefaultActionIdentifier where isCalendar:
                StatusItemController.shared.showPanel()
            case "accept": device?.acceptPairing()
            case "decline": device?.rejectPairing()
            case "reveal":
                if let s = urlString, let url = URL(string: s) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case UNNotificationDefaultActionIdentifier:
                if let s = urlString, let url = URL(string: s), !url.isFileURL { NSWorkspace.shared.open(url); return }
                if let s = urlString, let url = URL(string: s) { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
                model.section = notifID != nil ? .notifications : .overview
                model.wantsMainWindow = true
            default: break
            }
        }
    }
}
