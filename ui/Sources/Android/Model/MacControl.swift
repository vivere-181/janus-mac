import AppKit
import IOKit.ps
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: Audio output (mute / volume of the current output device)

@MainActor
enum AudioOutput {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static var muteAddress: AudioObjectPropertyAddress { address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) }
    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    }

    static var device: AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func isSettable(_ addr: AudioObjectPropertyAddress) -> Bool {
        guard let d = device else { return false }
        var a = addr
        guard AudioObjectHasProperty(d, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(d, &a, &settable) == noErr && settable.boolValue
    }

    private static func read<T>(_ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        guard let d = device else { return nil }
        var a = addr
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    private static func write<T>(_ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        guard let d = device, isSettable(addr) else { return false }
        var a = addr
        var v = value
        return AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static var deviceName: String? {
        guard let d = device else { return nil }
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    static var canMute: Bool { isSettable(muteAddress) }
    static var canSetVolume: Bool { isSettable(volumeAddress) }
    static var hardwareMuted: Bool? { read(muteAddress, UInt32(0)).map { $0 != 0 } }
    static var volume: Float32? { read(volumeAddress, Float32(0)) }
    @discardableResult static func setHardwareMuted(_ on: Bool) -> Bool { write(muteAddress, UInt32(on ? 1 : 0)) }
    @discardableResult static func setVolume(_ v: Float32) -> Bool { write(volumeAddress, max(0, min(1, v))) }

    /// Muted as the owner sees it: the mute switch, or volume 0 on speakers without one. nil = can't tell.
    static var isMuted: Bool? {
        if canMute { return hardwareMuted }
        if canSetVolume { return (volume ?? 1) < 0.001 }
        return nil
    }

    /// Volume to restore after "muting" a device that has no mute switch.
    private static var volumeBeforeMute: Float32 {
        get { UserDefaults.standard.object(forKey: "macActions.volumeBeforeMute") as? Float32 ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: "macActions.volumeBeforeMute") }
    }

    /// Returns the new state, or nil when this output can't be muted (e.g. some HDMI displays).
    static func toggleMute() -> Bool? {
        if canMute {
            let on = !(hardwareMuted ?? false)
            return setHardwareMuted(on) ? on : nil
        }
        if canSetVolume {
            if (volume ?? 0) > 0.001 {
                volumeBeforeMute = volume ?? 0.5
                return setVolume(0) ? true : nil
            }
            return setVolume(volumeBeforeMute) ? false : nil
        }
        return nil
    }

    // Change observation: the default device, and mute/volume on whichever device is current.
    private static var observedDevice: AudioObjectID?
    private static var onChange: (() -> Void)?
    private static let deviceListener: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { AudioOutput.reobserve(); AudioOutput.onChange?() }
    }
    private static let valueListener: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { AudioOutput.onChange?() }
    }

    static func observe(_ handler: @escaping () -> Void) {
        guard onChange == nil else { return }
        onChange = handler
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, deviceListener)
        reobserve()
    }

    private static func reobserve() {
        if let old = observedDevice {
            var m = muteAddress, v = volumeAddress
            AudioObjectRemovePropertyListenerBlock(old, &m, .main, valueListener)
            AudioObjectRemovePropertyListenerBlock(old, &v, .main, valueListener)
        }
        observedDevice = device
        if let d = observedDevice {
            var m = muteAddress, v = volumeAddress
            if AudioObjectHasProperty(d, &m) { AudioObjectAddPropertyListenerBlock(d, &m, .main, valueListener) }
            if AudioObjectHasProperty(d, &v) { AudioObjectAddPropertyListenerBlock(d, &v, .main, valueListener) }
        }
    }
}

// MARK: Mac state reported to the phone

/// Tells our phone app what the Mac is doing, so its Control card can show it:
/// `ge.connect.macstate:muted=on|off|na;finding=on|off;locked=on|off` (see shared/CONTRACT.md).
@MainActor
enum MacState {
    private(set) static var isLocked = false
    private static var lastSent: [String: String] = [:]
    private static var pending: Task<Void, Never>?

    static func install() {
        isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { isLocked = true; changed() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { isLocked = false; changed(); PopupHost.shared.refresh() }
        }
        AudioOutput.observe { changed() }
        MacIdentity.load()
    }

    static var text: String {
        let muted = AudioOutput.isMuted.map { $0 ? "on" : "off" } ?? "na"
        var t = "muted=\(muted);finding=\(FindMac.isActive ? "on" : "off");locked=\(isLocked ? "on" : "off")"
        // What this Mac is (R28), so the phone picks its icon and picture without guessing from the name.
        t += ";model=\(MacIdentity.model);kind=\(MacIdentity.isLaptop ? "laptop" : "desktop")"
        if let market = MacIdentity.market { t += ";market=\(market)" }
        return t
    }

    /// Something changed: tell every phone running our app (debounced; unchanged states aren't resent).
    static func changed() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            for device in MacActions.ourPhones where lastSent[device.id] != text { send(to: device) }
        }
    }

    /// Full report, e.g. right after a phone connects.
    static func send(to device: Device) {
        lastSent[device.id] = text
        device.command("macstate:" + text)
    }

    static func forget(_ device: Device) { lastSent[device.id] = nil }
}

/// This Mac's model: identifier ("Mac16,8"), marketing name ("MacBook Pro") and whether it's a laptop.
@MainActor
enum MacIdentity {
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf).filter { $0 != ";" && $0 != "=" }
    }()

    /// A laptop has a built-in battery.
    static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { src in
            (IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String
                == kIOPSInternalBatteryType
        }
    }()

    /// From System Information (slow, so read once in the background at launch); nil until then.
    private(set) static var market: String?

    static func load() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPHardwareDataType", "-json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
                  let name = hw["machine_name"] as? String, !name.isEmpty else { return }
            await MainActor.run {
                market = name.filter { $0 != ";" && $0 != "=" }
                MacState.changed()
            }
        }
    }
}

// MARK: Find My Mac

/// Plays a sound until stopped (from the phone, the popup or after 2 minutes). Unmutes and turns the
/// volume up while sounding, then puts both back.
@MainActor
enum FindMac {
    private(set) static var isActive = false
    private static var timer: Timer?
    private static var stopTask: Task<Void, Never>?
    private static var savedMuted: Bool?
    private static var savedVolume: Float32?
    private static let sound = NSSound(named: "Submarine")

    static func toggle(from device: Device?) { isActive ? stop() : start(from: device) }

    static func start(from device: Device?) {
        guard !isActive else { return }
        isActive = true
        savedMuted = AudioOutput.canMute ? AudioOutput.hardwareMuted : nil
        savedVolume = AudioOutput.volume
        if savedMuted == true { AudioOutput.setHardwareMuted(false) }
        if let v = savedVolume, v < 0.75 { AudioOutput.setVolume(0.75) }
        func beep() { sound?.stop(); sound?.play() }
        beep()
        let t = Timer(timeInterval: 1.4, repeats: true) { _ in MainActor.assumeIsolated { beep() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        stopTask = Task {
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { stop() }
        }
        MacPopup.shared.show(.init(
            symbol: "speaker.wave.3.fill", tint: .orange,
            title: "Your phone is looking for this Mac",
            subtitle: device.map { "From \($0.name)" },
            button: "Found It", pulse: true, stays: true) { stop() })
        MacState.changed()
    }

    static func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        stopTask?.cancel(); stopTask = nil
        sound?.stop()
        if let v = savedVolume { AudioOutput.setVolume(v) }
        if savedMuted == true { AudioOutput.setHardwareMuted(true) }
        savedVolume = nil; savedMuted = nil
        MacPopup.shared.close(ifShowing: "Your phone is looking for this Mac")
        MacState.changed()
    }
}

// MARK: Popup from the menu bar icon

/// A small popover from our menu bar icon confirming what the phone just did on this Mac.
@MainActor @Observable
final class MacPopup {
    static let shared = MacPopup()

    struct Content {
        var symbol: String
        var tint: Color
        var title: String
        var subtitle: String?
        var button: String?
        var pulse = false
        var stays = false
        /// A second, quieter button to the left of the main one.
        var secondary: (String, @MainActor () -> Void)?
        var action: (@MainActor () -> Void)?
    }

    private(set) var content: Content?
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    func show(_ content: Content) {
        let important = content.stays
        // While the panel is open, only something the owner must act on (it makes way for it).
        if !important, StatusItemController.shared.isPanelShown { return }
        if important { StatusItemController.shared.closePanel() }
        self.content = content
        PopupHost.shared.refresh()
        closeTask?.cancel()
        if !content.stays {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(content.button == nil ? 2.2 : 6))
                if !Task.isCancelled { self?.close() }
            }
        }
    }

    var debugState: String { "content=\(content?.title ?? "nil") shown=\(PopupHost.shared.isShown)" }

    func close(ifShowing title: String? = nil) {
        if let title, content?.title != title { return }
        closeTask?.cancel()
        content = nil
        PopupHost.shared.refresh()
    }
}

struct MacPopupView: View {
    let popup: MacPopup

    var body: some View {
        if let c = popup.content {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: c.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating, isActive: c.pulse)
                        .frame(width: 40, height: 40)
                        .background(c.tint.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let s = c.subtitle {
                            Text(s).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let b = c.button {
                    HStack(spacing: 8) {
                        if let (title, secondary) = c.secondary {
                            PopupButton(title: title) {
                                secondary()
                                popup.close()
                            }
                        }
                        PopupButton(title: b, role: .primary(c.tint)) {
                            c.action?()
                            popup.close()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}
