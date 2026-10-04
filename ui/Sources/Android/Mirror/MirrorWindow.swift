import AppKit
import AVFoundation
import SwiftUI

struct MirrorVideoRepresentable: NSViewRepresentable {
    let view: MirrorVideoView
    func makeNSView(context: Context) -> MirrorVideoView { view }
    func updateNSView(_ nsView: MirrorVideoView, context: Context) {}
}

/// Shows the decoded video and turns mouse, trackpad and keyboard input into phone input.
final class MirrorVideoView: NSView {
    weak var session: MirrorSession?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var touching = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Frames shown so far and the latest key frame (for diagnostics).
    private(set) var frameCount = 0
    private(set) var lastSample: CMSampleBuffer?
    var rendererFailed: Bool { displayLayer.sampleBufferRenderer.status == .failed }

    nonisolated func enqueue(_ sample: CMSampleBuffer) {
        DispatchQueue.main.async { [self] in
            frameCount += 1
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == false { lastSample = sample }
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        lastSample = nil   // the last key frame isn't kept after mirroring
    }

    /// Where the video is drawn inside the view (aspect fit).
    private var videoRect: CGRect {
        guard let s = session, s.videoSize.width > 0 else { return bounds }
        return AVMakeRect(aspectRatio: s.videoSize, insideRect: bounds)
    }

    /// A point in the view → phone pixels, or nil outside the picture.
    private func phonePoint(_ event: NSEvent) -> (Int, Int)? {
        guard let s = session else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.width > 0, r.contains(p) || touching else { return nil }
        let x = (p.x - r.minX) / r.width * s.videoSize.width
        let y = (r.maxY - p.y) / r.height * s.videoSize.height
        return (Int(max(0, min(s.videoSize.width - 1, x))), Int(max(0, min(s.videoSize.height - 1, y))))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (x, y) = phonePoint(event) else { return }
        touching = true
        session?.touch(.down, x: x, y: y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let (x, y) = phonePoint(event) else { return }
        session?.touch(.move, x: x, y: y)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        let point = phonePoint(event)
        touching = false
        if let (x, y) = point { session?.touch(.up, x: x, y: y) }
    }

    /// Right click = Back, like a mouse on Android.
    override func rightMouseDown(with event: NSEvent) { session?.press(4) }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = phonePoint(event) else { return }
        // Trackpads report pixels; mice report lines. Android expects wheel ticks.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 / 12 : 1.0
        session?.scroll(x: x, y: y, dx: -event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale)
    }

    override func keyDown(with event: NSEvent) {
        guard let s = session else { return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": if let t = NSPasteboard.general.string(forType: .string) { s.setClipboard(t, paste: true) }
            case "c": s.press(278)    // KEYCODE_COPY
            case "x": s.press(277)    // KEYCODE_CUT
            case "a": s.key(.down, 29, meta: 0x1000); s.key(.up, 29, meta: 0x1000)   // Ctrl+A
            default: super.keyDown(with: event)
            }
            return
        }
        let special: [UInt16: Int32] = [51: 67, 117: 112, 36: 66, 76: 66, 48: 61, 53: 4,
                                        123: 21, 124: 22, 125: 20, 126: 19, 115: 122, 119: 123, 116: 92, 121: 93]
        if let code = special[event.keyCode] {
            s.key(.down, code)
            s.key(.up, code)
            return
        }
        guard let chars = event.characters, !chars.isEmpty else { return }
        if chars.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) {
            s.text(chars)
        } else {
            // Non-Latin scripts (e.g. Georgian) can't be typed key by key; paste them instead.
            s.setClipboard(chars, paste: true)
        }
    }
}
