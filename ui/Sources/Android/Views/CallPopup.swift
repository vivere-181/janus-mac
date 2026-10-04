import AppKit
import SwiftUI

/// Incoming call, shown from the menu bar icon with the actions as real buttons (a notification
/// hides them behind "Options"). Closes when the call is missed, after an action, or after a minute.
/// A card in the shared popup (PopupHost), always on top of the others.
@MainActor @Observable
final class CallPopup {
    static let shared = CallPopup()

    struct Call: Equatable {
        let deviceID: String
        let number: String
        let name: String
        let photo: Data?
        let deviceName: String
    }

    private(set) var call: Call?
    var composing = false
    var muted = false
    /// Set once the call is answered on the phone: the popup becomes a live call card.
    private(set) var started: Date?
    var ending = false
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    /// Returns false when it can't be shown (e.g. the Mac is locked), so a notification is used instead.
    func show(number: String, contactName: String, device: Device) -> Bool {
        guard PopupHost.shared.canShow else { return false }
        let contact = device.contact(for: number)
        call = Call(deviceID: device.id, number: number,
                    name: contact?.name ?? (contactName.isEmpty || contactName == number ? "" : contactName),
                    photo: contact?.photo, deviceName: device.name)
        composing = false
        muted = false
        started = nil
        ending = false
        guard present() else { return false }
        Sounds.play(Sounds.ring, duringCall: true)
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled, self?.composing == false, self?.started == nil { self?.close() }
        }
        return true
    }

    /// The call was answered on the phone: show (or turn the ringing popup into) a live call card.
    func answered(number: String, name: String, start: Date, device: Device) {
        let contact = device.contact(for: number)
        if call?.deviceID != device.id || call?.number != number {
            call = Call(deviceID: device.id, number: number,
                        name: contact?.name ?? (name == number ? "" : name),
                        photo: contact?.photo, deviceName: device.name)
        }
        started = start
        composing = false
        ending = false
        closeTask?.cancel()
        _ = present()
    }

    /// The answered call ended (on the phone or via Hang Up here).
    func activeEnded(deviceID: String) {
        guard call?.deviceID == deviceID, started != nil else { return }
        close()
    }

    func hangUp() {
        ending = true
        device?.hangUp()
    }

    /// A call is urgent: the panel makes way for it. Other cards (a file, a reminder) stay below it.
    @discardableResult
    private func present() -> Bool {
        guard PopupHost.shared.canShow else { return false }
        StatusItemController.shared.closePanel()
        PopupHost.shared.refresh()
        return true
    }

    /// The call ended without an answer from here (missed); keep it open while a reply is being typed.
    func callEnded(number: String) {
        guard call?.number == number, !composing else { return }
        close()
    }

    func close() {
        closeTask?.cancel()
        call = nil
        started = nil
        composing = false
        ending = false
        PopupHost.shared.refresh()
    }

    private var device: Device? { AppModel.shared.devices.first { $0.id == call?.deviceID } }

    /// The phone's answer to a call command. A failed decline gets explained (the phone mutes instead).
    func result(_ text: String, device: Device) {
        let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        AppModel.shared.log(parts[1] == "ok" ? .info : .warning, "\(device.name): call \(parts[0]) \(parts[1])"
                            + (parts.count > 2 ? " (\(parts[2]))" : ""))
        switch (parts[0], parts[1]) {
        case ("mute", "ok"):
            muted = true
        case ("hangup", "failed"):
            ending = false
            MacPopup.shared.show(.init(symbol: "phone.down.fill", tint: .orange, title: "Couldn't hang up",
                                       subtitle: parts.count > 2 ? parts[2] : "End the call on \(device.name).",
                                       button: "OK") {})
        case ("decline", "failed"):
            MacPopup.shared.show(.init(symbol: "phone.down.fill", tint: .orange,
                                       title: "Couldn't decline the call",
                                       subtitle: parts.count > 2 ? parts[2] : "Check the call permission on \(device.name).",
                                       button: "OK") {})
        default: break
        }
    }

    func decline() {
        device?.declineCall()
        close()
    }

    func mute() {
        device?.muteRinger()
        muted = true
    }

    func reply(_ text: String) {
        guard let device, let number = call?.number, !text.isEmpty else { return }
        device.sendMessage(text, to: [number])
        device.declineCall()
        close()
    }
}

struct CallPopupView: View {
    @Bindable var popup: CallPopup
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    static let quickReplies = [
        "Can't talk now. I'll call you back.",
        "I'm in a meeting. I'll call you later.",
        "Please text me.",
    ]

    var body: some View {
        if let call = popup.call {
            VStack(spacing: 14) {
                header(call)
                if popup.started != nil { activeActions } else if popup.composing { replies } else { actions }
            }
            .padding(14)
            .frame(width: 300)
            .animation(.snappy(duration: 0.25), value: popup.composing)
        }
    }

    /// Same header as the other menu bar popups: round image left, title and a quiet subtitle.
    private func header(_ call: CallPopup.Call) -> some View {
        HStack(spacing: 12) {
            Avatar(name: call.name.isEmpty ? "#" : call.name, photo: call.photo, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.green.gradient, in: Circle())
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name.isEmpty ? call.number : call.name)
                    .font(.headline).lineLimit(1)
                if let start = popup.started {
                    // Ticks only while the card is open (the popover is released when it closes).
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("On call · \(CallTimer.format(ctx.date.timeIntervalSince(start))) · \(call.deviceName)")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                } else {
                    Text(call.name.isEmpty ? "Incoming call · \(call.deviceName)" : "\(call.number) · \(call.deviceName)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            PopupButton(title: "Message") {
                popup.composing = true
                fieldFocused = true
            }
            PopupButton(title: popup.muted ? "Muted" : "Mute") { popup.mute() }
                .disabled(popup.muted)
            PopupButton(title: "Decline", role: .destructive) { popup.decline() }
        }
    }

    private var activeActions: some View {
        HStack(spacing: 8) {
            PopupButton(title: "Hide") { popup.close() }
            PopupButton(title: popup.ending ? "Ending…" : "Hang Up", role: .destructive) { popup.hangUp() }
                .disabled(popup.ending)
        }
    }

    private var replies: some View {
        VStack(spacing: 6) {
            ForEach(Self.quickReplies, id: \.self) { text in
                ReplyRow(text: text) { popup.reply(text) }
            }
            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { popup.reply(draft) }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                Button { popup.reply(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Color.secondary : Color.janus)
                .disabled(draft.isEmpty)
            }
            .padding(.top, 2)
            PopupButton(title: "Cancel") { popup.composing = false }
                .padding(.top, 4)
        }
    }
}

/// A quick reply: one line, tinted on hover.
private struct ReplyRow: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.callout).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The capsule button every menu bar popup uses: quiet gray, colored for the main action, red to end
/// something. Drawn by hand because standard prominent buttons look disabled while the app is inactive.
/// A full-width action button in a card: a Liquid Glass capsule; the main action filled with its color (red for
/// destructive ones). Drawn directly rather than with a system button style, because the cards' popup never
/// becomes the active window, and system buttons and glass tints would show their inactive, greyed look.
struct PopupButton: View {
    enum Role { case secondary, primary(Color), destructive }

    let title: String
    var role: Role = .secondary
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(tint == nil ? .medium : .semibold))
                .foregroundStyle(tint == nil ? Color.primary : (tint == .janus ? Color.janusOn : Color.white))
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background { if let tint { Capsule().fill(tint.gradient) } }
        .glassEffect(tint == nil ? .regular.interactive() : .clear.interactive(), in: Capsule())
        .opacity(enabled ? 1 : 0.5)
    }

    private var tint: Color? {
        switch role {
        case .secondary: nil
        case .primary(let c): c
        case .destructive: .red
        }
    }
}

enum CallTimer {
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds)), h = s / 3600, m = s / 60 % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
    }
}

/// An answered call in the panel or Overview: who, how long, and Hang Up.
struct ActiveCallRow: View {
    let device: Device
    let call: Device.ActiveCall
    @State private var ending = false

    var body: some View {
        let contact = device.contact(for: call.number)
        let name = contact?.name ?? (call.name.isEmpty || call.name == call.number ? call.number : call.name)
        HStack(spacing: 10) {
            Avatar(name: name.isEmpty ? "#" : name, photo: contact?.photo, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Call" : name).font(.callout.weight(.semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(CallTimer.format(ctx.date.timeIntervalSince(call.start)))
                        .font(.caption).monospacedDigit().foregroundStyle(.green)
                }
            }
            Spacer(minLength: 4)
            PopupButton(title: ending ? "Ending…" : "Hang Up", role: .destructive) {
                ending = true
                device.hangUp()
            }
            .frame(width: 96)
            .disabled(ending)
        }
    }
}
