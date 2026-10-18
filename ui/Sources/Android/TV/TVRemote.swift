import AVFoundation
import Foundation
import Observation
import Speech

/// A TV's remote (R39): the Android TV Remote protocol straight to the TV, so it works with nothing of ours running
/// there. One per TV; connected while a remote is on screen (a view calls `activate()`/`deactivate()`), reconnecting
/// every few seconds when the connection drops.
@MainActor @Observable
final class TVRemote {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case notReachable          // off, or not on this network
        case needsPairing
        case pairing(PairingStep)
        case failed(String)
    }

    enum PairingStep: Equatable { case starting, enterCode(wrong: Bool), checking }

    /// Android key codes the remote sends.
    enum Key: Int64 {
        case power = 26, home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, ok = 23
        case playPause = 85, volumeUp = 24, volumeDown = 25, mute = 164, search = 84, enter = 66, delete = 67
    }

    let deviceID: String
    private(set) var status: Status = .idle
    private(set) var volume: Int?
    private(set) var volumeMax: Int?
    private(set) var muted = false
    private(set) var powerOn: Bool?
    /// The app in front on the TV (its package), as the TV reports it.
    private(set) var appPackage: String?
    /// Holding the voice button: this Mac is listening.
    private(set) var listening = false
    /// What it heard so far (shown while holding, and briefly after it's sent).
    private(set) var heard = ""
    /// Why voice can't be used (permissions), shown under the keys.
    private(set) var voiceProblem: String?

    @ObservationIgnored private(set) var users = 0
    @ObservationIgnored private var channel: ATVChannel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pairing: ATVChannel?
    @ObservationIgnored private var imeCounter: Int64 = 0
    @ObservationIgnored private var fieldCounter: Int64 = 0
    @ObservationIgnored private var speech = SpeechInput()
    @ObservationIgnored private var wantsVoice = false

    private static var remotes: [String: TVRemote] = [:]
    static func of(_ device: Device) -> TVRemote {
        if let r = remotes[device.id] { return r }
        let r = TVRemote(deviceID: device.id)
        remotes[device.id] = r
        return r
    }

    private init(deviceID: String) { self.deviceID = deviceID }

    private var device: Device? { AppModel.shared.devices.first { $0.id == deviceID } }
    var name: String { device?.name ?? "TV" }

    var isPaired: Bool {
        get { UserDefaults.standard.bool(forKey: "tvremote.paired.\(deviceID)") }
        set { UserDefaults.standard.set(newValue, forKey: "tvremote.paired.\(deviceID)") }
    }
    private var host: String? {
        get { UserDefaults.standard.string(forKey: "tvremote.host.\(deviceID)") }
        set { UserDefaults.standard.set(newValue, forKey: "tvremote.host.\(deviceID)") }
    }

    var isConnected: Bool { status == .connected }

    // MARK: Lifetime: connected while on screen

    func activate() {
        users += 1
        if users == 1 { startLoop() }
    }

    func deactivate() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        loop?.cancel(); loop = nil
        channel?.close(); channel = nil
        endVoice()
        if case .pairing = status { cancelPairing() }
        status = .idle
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .pairing = self.status { try? await Task.sleep(for: .seconds(1)); continue }
                if !self.isPaired { self.status = .needsPairing; try? await Task.sleep(for: .seconds(1)); continue }
                await self.connectOnce()
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(self.status == .notReachable ? 4 : 2))
            }
        }
    }

    /// The TV's address: Janus/KDE announces the TV with its device id; the remote service itself is often nameless.
    private func findHost() async -> String? {
        if let host { return host }
        if let found = await AdbServiceFinder.find(type: "_kdeconnect._udp.", timeout: 1.5).first(where: { $0.name == deviceID })?.host {
            host = found
            return found
        }
        let remotes = await AdbServiceFinder.find(type: "_androidtvremote2._tcp.", timeout: 1.5)
        let words = name.lowercased().split(separator: " ").filter { $0.count > 2 }
        let pick = remotes.first { r in words.contains { r.name.lowercased().contains($0) } } ?? (remotes.count == 1 ? remotes.first : nil)
        if let pick { host = pick.host }
        return pick?.host
    }

    private func connectOnce() async {
        if status != .connected { status = .connecting }
        guard let host = await findHost() else { status = .notReachable; return }
        let identity: SecIdentity
        do { identity = try ATVIdentity.load().identity } catch { status = .failed("Couldn't make this Mac's remote certificate."); return }
        let channel = ATVChannel(host: host, port: ATV.remotePort, identity: identity)
        do {
            try await channel.open()
            if Task.isCancelled { channel.close(); return }
        } catch let e as ATVError {
            if Task.isCancelled { return }
            debugLog("tv remote: couldn't connect (\(e))")
            switch e {
            case .notPaired: isPaired = false; status = .needsPairing
            case .unreachable: self.host = nil; status = .notReachable
            default: status = .notReachable
            }
            return
        } catch { status = .notReachable; return }
        self.channel = channel
        var configured = false
        do {
            for try await message in channel.messages {
                if Task.isCancelled { break }
                handle(message, on: channel, configured: &configured)
            }
            if Task.isCancelled { return }   // let go (deactivate): nothing to report
            debugLog("tv remote: the TV closed the connection (\(configured ? "after" : "before") configuring)")
            // Closed right after the handshake: the TV doesn't know this certificate.
            if !configured { isPaired = false; status = .needsPairing } else { status = .connecting }
        } catch {
            if Task.isCancelled { return }
            debugLog("tv remote: connection ended (\(error), \(configured ? "after" : "before") configuring)")
            if !configured, (error as? ATVError) == .notPaired || (error as? ATVError) == .closed { isPaired = false; status = .needsPairing }
            else { status = .connecting }
        }
        if self.channel === channel { self.channel = nil }
        listening = false
    }

    private func handle(_ m: PB.R, on channel: ATVChannel, configured: inout Bool) {
        if m.has(1) {   // configure: who we are, and what we support
            let info = PB.W().str(1, "Mac").str(2, "Apple").int(3, 1).str(4, "1").str(5, "io.github.vivere-181.janus").str(6, "1.0.0")
            channel.send(PB.W().msg(1, PB.W().int(1, Self.features).msg(2, info)))
        } else if m.has(2) {
            channel.send(PB.W().msg(2, PB.W().int(1, Self.features)))
            configured = true
            status = .connected
        } else if let ping = m.msg(8) {
            channel.send(PB.W().msg(9, PB.W().int(1, ping.int(1) ?? 0)))
        } else if let edit = m.msg(21) {
            imeCounter = edit.int(1) ?? imeCounter
            fieldCounter = edit.int(2) ?? fieldCounter
        } else if let ime = m.msg(20) {
            if let package = ime.msg(1)?.string(12), !package.isEmpty { appPackage = package }
        } else if let v = m.msg(50) {
            volumeMax = Int(v.int(6) ?? 0)
            volume = Int(v.int(7) ?? 0)
            muted = (v.int(8) ?? 0) != 0
        } else if let p = m.msg(40) {
            powerOn = (p.int(1) ?? 0) != 0
        }
    }

    /// androidtvremote2's 622: ping, key, IME, power, volume, app link.
    private static let features: Int64 = 622

    // MARK: Sending

    func press(_ key: Key) { send(PB.W().msg(10, PB.W().int(1, key.rawValue).int(2, 3))) }

    /// Volume by `steps` presses (a TV takes no absolute level from a remote), spaced so it keeps up.
    func stepVolume(_ steps: Int) {
        guard steps != 0 else { return }
        let key: Key = steps > 0 ? .volumeUp : .volumeDown
        Task {
            for _ in 0..<min(abs(steps), 100) { press(key); try? await Task.sleep(for: .milliseconds(35)) }
        }
    }

    /// Replaces what's in the TV's focused text field.
    func type(_ text: String) {
        let position = Int64(max(0, text.count - 1))
        let field = PB.W().int(1, position).int(2, position).str(3, text)
        send(PB.W().msg(21, PB.W().int(1, imeCounter).int(2, fieldCounter).msg(3, PB.W().int(1, 1).msg(2, field))))
    }

    /// Opens a link in the TV app that handles it (https://www.youtube.com, janus://launch?package=…).
    func open(_ link: String) { send(PB.W().msg(90, PB.W().str(1, link))) }

    func openApp(_ package: String) {
        // YouTube and Netflix open by their own links (works without Janus on the TV); the rest through Janus there.
        switch package {
        case "com.google.android.youtube.tv": open("https://www.youtube.com")
        case "com.netflix.ninja": open("https://www.netflix.com/browse")
        default: open("janus://launch?package=\(package)")
        }
    }

    func showInputs() { open("janus://inputs") }

    private func send(_ message: PB.W) { channel?.send(message) }

    // MARK: Pairing

    func startPairing() {
        status = .pairing(.starting)
        Task {
            guard let host = await findHost() else { status = .notReachable; return }
            do {
                let identity = try ATVIdentity.load().identity
                let channel = ATVChannel(host: host, port: ATV.pairingPort, identity: identity)
                try await channel.open()
                pairing = channel
                var replies = channel.messages.makeAsyncIterator()
                func message() -> PB.W { PB.W().int(1, 2).int(2, 200) }
                func expect(_ field: Int) async throws {
                    guard let reply = try await replies.next() else { throw ATVError.closed }
                    guard reply.int(2) == 200, reply.has(field) else { throw ATVError.protocolError("status \(reply.int(2) ?? 0)") }
                }
                let name = Host.current().localizedName ?? "Mac"
                channel.send(message().msg(10, PB.W().str(1, "Janus for Mac").str(2, name)))
                try await expect(11)
                let hex6 = PB.W().int(1, 3).int(2, 6)   // hexadecimal, six symbols
                channel.send(message().msg(20, PB.W().msg(1, hex6).int(3, 1)))   // we're the input side
                try await expect(20)
                channel.send(message().msg(30, PB.W().msg(1, hex6).int(2, 1)))
                try await expect(31)
                pairingReplies = replies
                status = .pairing(.enterCode(wrong: false))
                debugLog("tv pairing: the TV shows a code")
            } catch {
                debugLog("tv pairing: couldn't start (\(error))")
                pairing?.close(); pairing = nil
                status = .failed("Couldn't start pairing with \(name). Make sure the TV is on.")
            }
        }
    }

    @ObservationIgnored private var pairingReplies: AsyncThrowingStream<PB.R, Error>.Iterator?

    /// The code on the TV. Its first two digits check the rest, so a mistyped code is caught here.
    func submitCode(_ code: String) {
        guard case .pairing(.enterCode) = status else { return }   // once per code
        let clean = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard clean.count == 6, clean.allSatisfy(\.isHexDigit), let channel = pairing,
              let server = channel.peerCertificate.flatMap(SecCertificateCopyKey).flatMap(ATVIdentity.rsaParts),
              let client = (try? ATVIdentity.load().publicKey).flatMap(ATVIdentity.rsaParts) else {
            debugLog("tv pairing: code not usable (pairing \(pairing != nil), TV certificate \(pairing?.peerCertificate != nil))")
            status = .pairing(.enterCode(wrong: true)); return
        }
        let digits = Array(clean)
        let check = UInt8(String(digits[0...1]), radix: 16)!
        let nonce = Data([UInt8(String(digits[2...3]), radix: 16)!, UInt8(String(digits[4...5]), radix: 16)!])
        let candidates = [(client, server), (server, client)].map { a, b in
            SHA256.hash(a.modulus + a.exponent + b.modulus + b.exponent + nonce)
        }
        guard let secret = candidates.first(where: { $0.first == check }) else {
            debugLog("tv pairing: the code's check digits don't match (mistyped?)")
            status = .pairing(.enterCode(wrong: true)); return
        }
        debugLog("tv pairing: code checks out, sending the secret")
        status = .pairing(.checking)
        channel.send(PB.W().int(1, 2).int(2, 200).msg(40, PB.W().bytes(1, secret)))
        Task {
            var replies = pairingReplies
            let reply = try? await replies?.next()
            pairingReplies = nil
            channel.close(); pairing = nil
            debugLog("tv pairing: TV answered \(reply.map { "status \($0.int(2) ?? 0), ack \($0.has(41))" } ?? "nothing")")
            if let reply, reply.int(2) == 200, reply.has(41) {
                isPaired = true
                status = .connecting
            } else {
                status = .pairing(.enterCode(wrong: true))
                startPairing()   // a fresh code on the TV
            }
        }
    }

    func cancelPairing() {
        pairing?.close(); pairing = nil
        pairingReplies = nil
        status = isPaired ? .connecting : .needsPairing
    }

    // MARK: Voice (hold to talk)

    /// The TV's own voice path doesn't work on every TV (the TCL won't give its assistant the remote's audio), so this
    /// Mac recognises the speech and hands the text to Janus on the TV (`janus://search?q=`), which gives it to the
    /// TV's assistant as if spoken.
    func beginVoice() {
        guard isConnected, !wantsVoice else { return }
        wantsVoice = true
        heard = ""
        voiceProblem = nil
        Task {
            if let problem = await SpeechInput.permission() { wantsVoice = false; voiceProblem = problem; return }
            guard wantsVoice else { return }   // already let go
            listening = true
            do {
                try speech.start { [weak self] text in Task { @MainActor in self?.heard = text } }
            } catch {
                listening = false; wantsVoice = false
                voiceProblem = "Couldn't start listening."
            }
        }
    }

    func endVoice() {
        wantsVoice = false
        guard listening else { return }
        listening = false
        speech.stop { [weak self] final in
            Task { @MainActor in
                guard let self else { return }
                let text = (final ?? self.heard).trimmingCharacters(in: .whitespacesAndNewlines)
                self.heard = text
                if !text.isEmpty, let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) {
                    self.open("janus://search?q=\(q)")
                }
                try? await Task.sleep(for: .seconds(3))
                if !self.listening, self.heard == text { self.heard = "" }
            }
        }
    }
}

/// SHA-256 without CryptoKit's types leaking into the call site.
import CryptoKit
private enum SHA256 {
    static func hash(_ data: Data) -> Data { Data(CryptoKit.SHA256.hash(data: data)) }
}

/// Speech to text with macOS's recogniser, from the microphone, while the voice button is held.
final class SpeechInput: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished: ((String?) -> Void)?

    /// The recogniser for the Mac's language, or English when that one isn't available.
    private static var recognizer: SFSpeechRecognizer? {
        if let r = SFSpeechRecognizer(locale: Locale.current), r.isAvailable { return r }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// nil when allowed; otherwise what to tell the owner.
    static func permission() async -> String? {
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        case .notDetermined: mic = await AVCaptureDevice.requestAccess(for: .audio)
        default: mic = false
        }
        guard mic else { return "Allow Janus in System Settings → Privacy & Security → Microphone." }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard speech == .authorized else { return "Allow Janus in System Settings → Privacy & Security → Speech Recognition." }
        return nil
    }

    func start(onText: @escaping (String) -> Void) throws {
        guard let recognizer = Self.recognizer else { throw ATVError.protocolError("no recogniser") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        latest = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                onText(self.latest)
            }
            if result?.isFinal == true || error != nil { self.deliver(self.latest) }
        }
        try engine.start()
        self.engine = engine
        self.request = request
    }

    /// Stops listening; hands back the final text (waits briefly for the recogniser to finish).
    func stop(final: @escaping (String?) -> Void) {
        finished = final
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver(self?.latest) }
    }

    private func deliver(_ text: String?) {
        guard let f = finished else { return }
        finished = nil
        task?.cancel(); task = nil; request = nil
        f(text?.isEmpty == false ? text : nil)
    }
}
