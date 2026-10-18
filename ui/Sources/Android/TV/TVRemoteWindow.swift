import AppKit
import SwiftUI

/// The TV remote as a small floating window (R39), like a remote kept on the desk: it stays above other windows,
/// and closing it lets the connection to the TV go.
@MainActor
final class TVRemoteWindow: NSObject, NSWindowDelegate {
    static let shared = TVRemoteWindow()
    private(set) var window: NSWindow?
    private var deviceID: String?

    func show(_ device: Device) {
        if let window, deviceID == device.id {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        window?.close()
        let host = NSHostingController(rootView: TVRemoteView(device: device, layout: .compact)
            .frame(minHeight: 600)
            .environment(AppModel.shared)
            .tint(.janus))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "\(device.name) Remote"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.delegate = self
        if !w.setFrameUsingName("TVRemote") { w.center() }
        w.setFrameAutosaveName("TVRemote")
        window = w
        deviceID = device.id
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        deviceID = nil
    }
}
