import AppKit
import SwiftUI

/// Testing aid (temporary): fires each kind of notification and a few features on demand (main window → Testing).
/// Phone notifications come from a pretend "Test Phone" that exists only in this app, so their buttons (Reply, Pair,
/// Decline…) go nowhere. Live activities and calendar events are shown alongside the real ones and are removed with
/// "Clear Simulated".
@MainActor
enum Simulator {
    private static var fake: Device?

    /// The pretend phone (needs any real device for the engine connection it never uses for real).
    private static var phone: Device? {
        if let fake { return fake }
        guard let real = AppModel.shared.devices.first else { return nil }
        let d = Device(id: "simulated-test-phone", bus: real.bus)
        d.name = "Test Phone"
        d.verificationKey = "A1 B2 C3 D4"
        fake = d
        return d
    }

    static var available: Bool { !AppModel.shared.devices.isEmpty }

    enum Item: String, CaseIterable, Identifiable {
        case message = "Message (with Reply)"
        case burst = "3 Messages from One Chat"
        case email = "Email (with Actions)"
        case code = "Verification Code"
        case ping = "Ping"
        case missedCall = "Missed Call"
        case incomingCall = "Incoming Call"
        case answeredCall = "Answered Call"
        case pairing = "Pairing Request"
        case link = "Link Received"
        case battery = "Low Battery"
        case files = "Files Received"
        case reminder = "Calendar Reminder (with Join)"
        case meetingSoon = "Meeting in 3 Minutes (menu bar)"
        case delivery = "Live: Delivery Order"
        case timer = "Live: Timer"
        case macMessage = "Mac Message (Link sent)"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .message: "Message"
            case .burst: "3 Messages from One Chat"
            case .email: "Email"
            case .code: "Verification Code"
            case .ping: "Ping"
            case .missedCall: "Missed Call"
            case .incomingCall: "Incoming Call"
            case .answeredCall: "Call in Progress"
            case .pairing: "Pairing Request"
            case .link: "Link Received"
            case .battery: "Low Battery"
            case .files: "Files Received"
            case .reminder: "Calendar Reminder"
            case .meetingSoon: "Meeting Soon"
            case .delivery: "Delivery Order"
            case .timer: "Timer"
            case .macMessage: "Mac Message"
            }
        }

        /// What it shows, in one line.
        var detail: String {
            switch self {
            case .message: "A WhatsApp message with Reply"
            case .burst: "Three messages in a row group into one card with a count"
            case .email: "A Gmail notification with its own Archive and Reply buttons"
            case .code: "A bank code, shown large and ready to copy"
            case .ping: "The phone says hi"
            case .missedCall: "With Call Back"
            case .incomingCall: "The ringing card with Decline and Silence"
            case .answeredCall: "The call timer in the menu bar, with Hang Up"
            case .pairing: "A phone asks to pair, with its verification key"
            case .link: "A link from the phone, with Open and Copy"
            case .battery: "The phone is down to 14%"
            case .files: "Your last received files, as the card that drops down (with its sound)"
            case .reminder: "A meeting in 5 minutes, with Join"
            case .meetingSoon: "A meeting in 3 minutes: the countdown in the menu bar"
            case .delivery: "A live activity: the courier arrives in 14 minutes"
            case .timer: "A live activity: an 8-minute timer"
            case .macMessage: "The small confirmation card, like \"Link sent\""
            }
        }

        var symbol: String {
            switch self {
            case .message, .burst: "message.fill"
            case .email: "envelope.fill"
            case .code: "key.fill"
            case .ping: "hand.wave.fill"
            case .missedCall: "phone.arrow.down.left.fill"
            case .incomingCall: "phone.fill"
            case .answeredCall: "phone.connection.fill"
            case .pairing: "link.badge.plus"
            case .link: "link"
            case .battery: "battery.25percent"
            case .files: "arrow.down.doc.fill"
            case .reminder: "calendar.badge.clock"
            case .meetingSoon: "clock.fill"
            case .delivery: "bag.fill"
            case .timer: "timer"
            case .macMessage: "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .message, .burst, .ping: .green
            case .email, .link, .pairing, .macMessage: .blue
            case .code: .indigo
            case .missedCall: .red
            case .incomingCall, .answeredCall: .green
            case .battery: .orange
            case .files: .blue
            case .reminder, .meetingSoon: .red
            case .delivery: .orange
            case .timer: .orange
            }
        }

        var section: String {
            switch self {
            case .message, .burst, .email, .code, .ping, .link, .battery: "Notifications"
            case .missedCall, .incomingCall, .answeredCall: "Calls"
            case .pairing, .files, .macMessage: "Other Cards"
            case .reminder, .meetingSoon: "Calendar"
            case .delivery, .timer: "Live Activities"
            }
        }
    }

    static func run(_ item: Item) {
        guard let d = phone else { return }
        let ms = { (date: Date) in Int(date.timeIntervalSince1970 * 1000) }
        switch item {
        case .message:
            let n = message("Alex", "Are we still on for dinner tonight?", reply: true); inspect(n); Notifier.shared.phoneNotification(n, device: d)
        case .burst:
            for (i, text) in ["Running 10 minutes late", "Should I book the table?", "Booked for 8 🙂"].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                    let n = message("Family", text, reply: true); inspect(n); Notifier.shared.phoneNotification(n, device: d)
                }
            }
        case .email:
            var n = message("Your order has shipped", "Your package is on its way and will arrive Tuesday.", reply: false)
            n.appName = "Gmail"; n.actions = ["Archive", "Reply"]
            inspect(n); Notifier.shared.phoneNotification(n, device: d)
        case .code:
            Notifier.shared.verificationCode("482913", from: "Example Bank", device: d, copied: false)
        case .ping:
            Notifier.shared.ping(from: d, message: "")
        case .missedCall:
            Notifier.shared.call(event: "missedCall", number: "+1 202 555 0143", contactName: "Jordan", device: d)
        case .incomingCall:
            Notifier.shared.call(event: "callReceived", number: "+1 202 555 0143", contactName: "Jordan", device: d)
        case .answeredCall:
            d.applyCallState(id: "sim.call", json: #"{"state":"talking","number":"+1 202 555 0143","name":"Jordan","start":\#(ms(Date().addingTimeInterval(-42))),"now":\#(ms(.now))}"#)
        case .pairing:
            Notifier.shared.pairingRequest(d)
        case .link:
            Notifier.shared.received(URL(string: "https://www.apple.com/macbook-pro/")!, device: d)
        case .battery:
            Notifier.shared.batteryLow(14, device: d)
        case .files:
            let received = TransferStore.shared.items.filter { $0.direction == .received && $0.kind == .file }.prefix(3)
            if received.isEmpty {
                MacPopup.shared.show(.init(symbol: "tray", tint: .gray, title: "No received files yet",
                                           subtitle: "This card shows files you've received before; send one from the phone first."))
            } else {
                received.forEach { ReceivePopup.shared.show($0.id) }
                Sounds.play(Sounds.alert)
            }
        case .reminder:
            _ = CalendarPopup.shared.remind(event("Design review", inMinutes: 5, join: "https://meet.google.com/abc-defg-hij"))
        case .meetingSoon:
            CalendarStore.shared.simulate(event("Standup", inMinutes: 3, join: "https://us02web.zoom.us/j/123456789"))
        case .delivery:
            live(on: AppModel.shared.selectedDevice, id: "sim.delivery",
                 #"{"v":1,"app":"Glovo","title":"Your courier is on the way","text":"Sam is picking up your order","when":\#(ms(Date().addingTimeInterval(14 * 60))),"chrono":"down","cat":"transport","now":\#(ms(.now))}"#)
        case .timer:
            live(on: AppModel.shared.selectedDevice, id: "sim.timer",
                 #"{"v":1,"app":"Clock","title":"Pasta","text":"Timer","when":\#(ms(Date().addingTimeInterval(8 * 60 + 12))),"chrono":"down","cat":"stopwatch","now":\#(ms(.now))}"#)
        case .macMessage:
            MacPopup.shared.show(.init(symbol: "safari.fill", tint: .blue, title: "Link sent", subtitle: "Opening on Test Phone"))
        }
    }

    /// Removes everything simulated (cards, live activities, the pretend call and meeting).
    static func clear() {
        BannerCenter.shared.banners.map(\.id).forEach { BannerCenter.shared.dismiss($0) }
        CalendarPopup.shared.cards.forEach { CalendarPopup.shared.dismiss($0) }
        if CallPopup.shared.call?.deviceID == fake?.id { CallPopup.shared.close() }
        fake?.activeCall = nil
        for d in AppModel.shared.devices { d.live.removeAll { $0.id.hasPrefix("sim.") } }
        CalendarStore.shared.simulate(nil)
        StatusItemController.shared.updateLiveLabel()
    }

    private static func message(_ title: String, _ text: String, reply: Bool) -> PhoneNotification {
        var n = PhoneNotification(id: "sim.\(UUID().uuidString)")
        n.appName = "WhatsApp"; n.title = title; n.text = text
        if reply { n.replyId = "sim"; n.actions = ["Mark as read"] }
        return n
    }

    /// What a simulated phone notification carries, in the Inspector (like real ones).
    private static func inspect(_ n: PhoneNotification) {
        Inspector.shared.record("Notification", source: "Test Phone (simulated)", title: "\(n.appName): \(n.title)",
                                fields: [("appName", n.appName), ("title", n.title), ("text", n.text),
                                         ("replyId", n.replyId.isEmpty ? "(none: no Reply)" : n.replyId),
                                         ("actions", n.actions.isEmpty ? "[]" : n.actions.joined(separator: " · ")),
                                         ("silent", n.silent ? "true" : "false"), ("iconPath", n.iconPath ?? "(none)")])
    }

    private static func event(_ title: String, inMinutes m: Double, join: String?) -> CalendarEvent {
        let start = Date().addingTimeInterval(m * 60)
        return CalendarEvent(id: "sim/\(title)", calendar: "", title: title, start: start, end: start.addingTimeInterval(30 * 60),
                             allDay: false, location: nil, join: join.flatMap(URL.init(string:)), color: "#4285F4")
    }

    /// Live activities show for a connected phone only (like real ones).
    private static func live(on _: Device?, id: String, _ json: String) {
        guard let device = AppModel.shared.connectedDevices.first(where: { DeviceTrust.isMine($0) }) else {
            MacPopup.shared.show(.init(symbol: "iphone.slash", tint: .gray, title: "No phone connected",
                                       subtitle: "Live activities appear for a connected phone. Connect one, then try again."))
            return
        }
        guard let a = LiveActivity(id: id, json: json, iconPath: nil) else { return }
        Inspector.shared.record("Live", source: "Simulated on \(device.name)", title: id,
                                fields: [("text (JSON)", Inspector.prettyJSON(json) ?? json)])
        device.live.removeAll { $0.id == id }
        device.live.append(a)
        StatusItemController.shared.updateLiveLabel()
    }
}
