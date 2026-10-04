import AppKit
import SwiftUI

struct RemoteInputView: View {
    let device: Device
    @State private var typed = ""
    @State private var sensitivity = 1.5

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if device.has("remotecontrol") {
                    Card(title: "Touchpad", symbol: "rectangle.and.hand.point.up.left") {
                        Touchpad(device: device, sensitivity: sensitivity)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                        HStack {
                            Button { device.pointerCommand(["singleclick": .bool(true)]) } label: { Label("Click", systemImage: "hand.tap") }
                            Button { device.pointerCommand(["rightclick": .bool(true)]) } label: { Label("Right-Click", systemImage: "contextualmenu.and.cursorarrow") }
                            Button { device.pointerCommand(["middleclick": .bool(true)]) } label: { Label("Middle-Click", systemImage: "computermouse") }
                            Spacer()
                            Text("Speed").foregroundStyle(.secondary)
                            Slider(value: $sensitivity, in: 0.5...4).frame(width: 120)
                        }
                        .controlSize(.small)
                        Text("Move the pointer to control the phone's cursor. Click to tap, two-finger scroll to scroll, right-click for a long press. Requires remote input to be allowed in the companion app on your phone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if device.has("remotekeyboard") {
                    Card(title: "Keyboard", symbol: "keyboard") {
                        HStack(spacing: 6) {
                            Circle().fill(device.remoteKeyboardActive ? .green : .orange).frame(width: 8, height: 8)
                            Text(device.remoteKeyboardActive
                                 ? "The remote keyboard is active on the phone."
                                 : "Switch the phone's keyboard to the companion app's remote keyboard to type from your Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            TextField("Type here and press Return to send", text: $typed)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { device.sendText(typed); typed = "" }
                            Button("Send") { device.sendText(typed); typed = "" }.disabled(typed.isEmpty)
                        }
                        HStack(spacing: 6) {
                            KeyButton("esc", 14, device)
                            KeyButton("tab", 2, device)
                            KeyButton("⌫", 1, device)
                            KeyButton("⌦", 13, device)
                            KeyButton("return", 12, device)
                            Divider().frame(height: 18)
                            KeyButton("←", 4, device)
                            KeyButton("↑", 5, device)
                            KeyButton("↓", 7, device)
                            KeyButton("→", 6, device)
                            Divider().frame(height: 18)
                            KeyButton("home", 10, device)
                            KeyButton("end", 11, device)
                        }
                        .controlSize(.small)
                    }
                }
                if !device.has("remotecontrol") && !device.has("remotekeyboard") {
                    ContentUnavailableView("Remote Input Unavailable", systemImage: "cursorarrow.slash",
                                           description: Text("Enable “Remote input” and “Remote keyboard” for \(device.name) in Settings."))
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Remote Input")
    }
}

private struct KeyButton: View {
    let title: String
    let code: Int
    let device: Device
    init(_ title: String, _ code: Int, _ device: Device) { self.title = title; self.code = code; self.device = device }

    var body: some View {
        Button(title) { device.sendKey("", special: code) }
            .font(.system(.caption, design: .rounded).weight(.medium))
    }
}

/// Trackpad surface: relative pointer motion, clicks and two-finger scrolling forwarded to the phone.
private struct Touchpad: NSViewRepresentable {
    let device: Device
    let sensitivity: Double

    func makeNSView(context: Context) -> TouchpadView {
        let v = TouchpadView()
        v.device = device
        v.sensitivity = sensitivity
        return v
    }

    func updateNSView(_ v: TouchpadView, context: Context) {
        v.device = device
        v.sensitivity = sensitivity
    }

    final class TouchpadView: NSView {
        var device: Device?
        var sensitivity = 1.5
        private var pending = CGPoint.zero
        private var scrollPending = CGPoint.zero
        private var tracking: NSTrackingArea?
        private var flushScheduled = false
        private var dragging = false

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.quaternarySystemFill.setFill()
            bounds.fill()
            let hint = "Move here to control the phone" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.push() }
        override func mouseExited(with event: NSEvent) { NSCursor.pop() }
        override func mouseMoved(with event: NSEvent) { accumulate(event) }
        override func mouseDragged(with event: NSEvent) {
            if !dragging { dragging = true; device?.pointerCommand(["singlehold": .bool(true)]) }
            accumulate(event)
        }
        override func mouseUp(with event: NSEvent) {
            if dragging {
                dragging = false
                flush()
                device?.pointerCommand(["singlerelease": .bool(true)])
            } else {
                device?.pointerCommand([event.clickCount >= 2 ? "doubleclick" : "singleclick": .bool(true)])
            }
        }
        override func rightMouseUp(with event: NSEvent) { device?.pointerCommand(["rightclick": .bool(true)]) }
        override func otherMouseUp(with event: NSEvent) { device?.pointerCommand(["middleclick": .bool(true)]) }

        override func scrollWheel(with event: NSEvent) {
            scrollPending.x += event.scrollingDeltaX
            scrollPending.y += event.scrollingDeltaY
            schedule()
        }

        private func accumulate(_ e: NSEvent) {
            pending.x += e.deltaX * sensitivity
            pending.y += e.deltaY * sensitivity
            schedule()
        }

        private func schedule() {
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.flush() }
        }

        private func flush() {
            flushScheduled = false
            let dx = Int(pending.x.rounded()), dy = Int(pending.y.rounded())
            if dx != 0 || dy != 0 {
                device?.moveCursor(dx: dx, dy: dy)
                pending.x -= CGFloat(dx); pending.y -= CGFloat(dy)
            }
            let sx = Int(scrollPending.x.rounded()), sy = Int(scrollPending.y.rounded())
            if sx != 0 || sy != 0 {
                device?.pointerCommand(["scroll": .bool(true), "dx": .double(Double(sx)), "dy": .double(Double(sy))])
                scrollPending = .zero
            }
        }
    }
}
