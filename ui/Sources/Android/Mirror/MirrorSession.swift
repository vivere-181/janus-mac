import AVFoundation
import CoreMedia
import Foundation

/// One mirroring session with the scrcpy server (v4.1, Apache-2.0) on the phone: pushes and starts the
/// server over adb, then reads the video stream and sends input on the control socket.
/// Protocol (scrcpy 4.1): sockets are accepted in the order video, audio, control; the first carries a
/// dummy byte and a 64-byte device name; the video socket starts with a 4-byte codec id, then 12-byte
/// headers: session packets (MSB set: flags, width, height) or media packets (pts|flags u64, size u32).
final class MirrorSession: @unchecked Sendable {
    static let serverVersion = "4.1"
    static let remoteJar = "/data/local/tmp/ge-mirror-server.jar"

    struct Options {
        var maxSize = 1920
        var bitRate = 12_000_000
        var maxFps = 60
        var audio = false
        var screenOff = false
        /// The phone's screen timeout while mirroring (ms); the phone restores its own afterwards, even if the
        /// Mac disconnects abruptly (scrcpy's clean-up process).
        var screenOffTimeout: Int?
    }

    let adb: ADB
    let serial: String
    let options: Options

    // Callbacks run on background threads; the owner hops to the main actor.
    var onVideoSize: (@Sendable (CGSize) -> Void)?
    var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onAudio: (@Sendable (Data) -> Void)?
    var onClipboard: (@Sendable (String) -> Void)?
    var onEnd: (@Sendable (Error?) -> Void)?

    private var server: Process?
    private var videoFD: Int32 = -1
    private var audioFD: Int32 = -1
    private var controlFD: Int32 = -1
    private let localPort = Int.random(in: 27200...27999)
    private let scid = UInt32.random(in: 1..<0x7fff_ffff)
    private let writeQueue = DispatchQueue(label: "mirror.control")
    private var stopped = false
    private(set) var deviceName = ""
    private(set) var videoSize = CGSize.zero
    private var clipboardSequence: Int64 = 1

    init(adb: ADB, serial: String, options: Options = Options()) {
        self.adb = adb
        self.serial = serial
        self.options = options
    }

    // MARK: Start / stop

    func start() async throws {
        guard let jar = Self.serverJar else { throw MirrorError.pushFailed("server file missing") }
        let push = await adb.run(["-s", serial, "push", jar.path, Self.remoteJar], timeout: 30)
        guard push.ok else { throw MirrorError.pushFailed(push.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let socketName = "scrcpy_" + String(format: "%08x", scid)
        let fwd = await adb.run(["-s", serial, "forward", "tcp:\(localPort)", "localabstract:\(socketName)"])
        guard fwd.ok else { throw MirrorError.forwardFailed(fwd.output) }

        var args = ["-s", serial, "shell", "CLASSPATH=\(Self.remoteJar)", "app_process", "/",
                    "com.genymobile.scrcpy.Server", Self.serverVersion,
                    "scid=" + String(format: "%08x", scid), "log_level=info",
                    "tunnel_forward=true", "send_dummy_byte=true", "send_device_meta=true",
                    "video=true", "video_codec=h264", "max_size=\(options.maxSize)",
                    "video_bit_rate=\(options.bitRate)", "max_fps=\(options.maxFps)",
                    "control=true", "clipboard_autosync=true", "stay_awake=true", "cleanup=true"]
        args += options.audio ? ["audio=true", "audio_codec=raw"] : ["audio=false"]
        if let t = options.screenOffTimeout { args.append("screen_off_timeout=\(t)") }
        server = try adb.spawn(args) { line in
            if ProcessInfo.processInfo.environment["MIRROR_DEBUG"] != nil { FileHandle.standardError.write(Data(line.utf8)) }
        }

        // The server needs a moment to start listening; adb accepts the connection earlier and closes it
        // if nothing listens yet, so retry until the dummy byte arrives.
        videoFD = try await connectFirstSocket()
        if options.audio { audioFD = try connectSocket() }
        controlFD = try connectSocket()

        var name = [UInt8](repeating: 0, count: 64)
        try readFully(videoFD, &name, 64)
        deviceName = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)

        var codec = [UInt8](repeating: 0, count: 4)
        try readFully(videoFD, &codec, 4)
        guard codec != [0, 0, 0, 0], codec != [0, 0, 0, 1] else { throw MirrorError.protocolError("the phone refused video") }

        if options.screenOff { setDisplayPower(false) }
        Thread.detachNewThread { [self] in videoLoop() }
        if options.audio { Thread.detachNewThread { [self] in audioLoop() } }
        Thread.detachNewThread { [self] in deviceMessageLoop() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for fd in [videoFD, audioFD, controlFD] where fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        videoFD = -1; audioFD = -1; controlFD = -1
        server?.terminate()
        server = nil
        let adb = adb, serial = serial, port = localPort
        Task.detached { _ = await adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5) }
    }

    private func finish(_ error: Error?) {
        guard !stopped else { return }
        stop()
        onEnd?(error)
    }

    /// The server file bundled with the app (tools/build-ui.sh puts it in Resources).
    static var serverJar: URL? { Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) }

    // MARK: Sockets

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MirrorError.connectFailed }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(localPort).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { close(fd); throw MirrorError.connectFailed }
        return fd
    }

    private func connectFirstSocket() async throws -> Int32 {
        for _ in 0..<100 {
            if stopped { throw MirrorError.connectFailed }
            if let fd = try? connectSocket() {
                var b: UInt8 = 0
                if read(fd, &b, 1) == 1 { return fd }
                close(fd)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MirrorError.connectFailed
    }

    private func readFully(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) throws {
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { throw MirrorError.protocolError("the connection closed") }
            got += n
        }
    }

    // MARK: Video

    private func videoLoop() {
        var header = [UInt8](repeating: 0, count: 12)
        let decoder = H264Packetizer()
        do {
            while !stopped {
                try readFully(videoFD, &header, 12)
                if header[0] & 0x80 != 0 {
                    // Session packet: a new (or rotated) video size.
                    let w = be32(header, 4), h = be32(header, 8)
                    videoSize = CGSize(width: Int(w), height: Int(h))
                    onVideoSize?(videoSize)
                    continue
                }
                let flags = be64(header, 0)
                let size = Int(be32(header, 8))
                guard size > 0, size < 32 << 20 else { throw MirrorError.protocolError("bad packet") }
                var payload = [UInt8](repeating: 0, count: size)
                try readFully(videoFD, &payload, size)
                let isConfig = flags & (1 << 62) != 0
                if isConfig {
                    decoder.configure(annexB: payload)
                } else if let sample = decoder.sample(annexB: payload, keyFrame: flags & (1 << 61) != 0) {
                    onSample?(sample)
                }
            }
        } catch {
            finish(stopped ? nil : error)
        }
    }

    private func audioLoop() {
        var codec = [UInt8](repeating: 0, count: 4)
        var header = [UInt8](repeating: 0, count: 12)
        do {
            try readFully(audioFD, &codec, 4)
            // 0 = the phone disabled audio (e.g. unsupported): keep mirroring video only.
            guard codec != [0, 0, 0, 0], codec != [0, 0, 0, 1] else { return }
            while !stopped {
                try readFully(audioFD, &header, 12)
                if header[0] & 0x80 != 0 { continue }
                let size = Int(be32(header, 8))
                guard size >= 0, size < 4 << 20 else { throw MirrorError.protocolError("bad audio packet") }
                var payload = [UInt8](repeating: 0, count: size)
                try readFully(audioFD, &payload, size)
                if be64(header, 0) & (1 << 62) == 0 { onAudio?(Data(payload)) }
            }
        } catch {
            // Audio ending alone doesn't end the session.
        }
    }

    /// Clipboard changes on the phone (type 0), clipboard acks (1), UHID output (2).
    private func deviceMessageLoop() {
        var type: [UInt8] = [0]
        do {
            while !stopped {
                try readFully(controlFD, &type, 1)
                switch type[0] {
                case 0:
                    var len = [UInt8](repeating: 0, count: 4)
                    try readFully(controlFD, &len, 4)
                    var text = [UInt8](repeating: 0, count: Int(be32(len, 0)))
                    try readFully(controlFD, &text, text.count)
                    onClipboard?(String(decoding: text, as: UTF8.self))
                case 1:
                    var seq = [UInt8](repeating: 0, count: 8)
                    try readFully(controlFD, &seq, 8)
                case 2:
                    var head = [UInt8](repeating: 0, count: 4)
                    try readFully(controlFD, &head, 4)
                    var data = [UInt8](repeating: 0, count: Int(head[2]) << 8 | Int(head[3]))
                    try readFully(controlFD, &data, data.count)
                default:
                    throw MirrorError.protocolError("unknown device message")
                }
            }
        } catch {
            finish(stopped ? nil : error)
        }
    }

    private func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    private func be64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(be32(b, o)) << 32 | UInt64(be32(b, o + 4)) }

    // MARK: Control (Mac → phone)

    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }
    enum KeyAction: UInt8 { case down = 0, up = 1 }

    private func send(_ bytes: [UInt8]) {
        writeQueue.async { [self] in
            guard controlFD >= 0 else { return }
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { write(controlFD, $0.baseAddress! + sent, bytes.count - sent) }
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// A finger touch at a point in video coordinates (pointer id -2 = one generic finger).
    func touch(_ action: TouchAction, x: Int, y: Int) {
        var b: [UInt8] = [2, action.rawValue]
        b += beBytes(UInt64(bitPattern: -2))
        b += position(x: x, y: y)
        b += beBytes(UInt16(action == .up ? 0 : 0xffff))   // pressure
        b += beBytes(UInt32(0)) + beBytes(UInt32(0))        // action button, buttons
        send(b)
    }

    /// Scroll in "wheel ticks" (−16…16) at a point.
    func scroll(x: Int, y: Int, dx: Double, dy: Double) {
        func fixed(_ v: Double) -> UInt16 {
            let n = max(-1, min(1, v / 16))
            return UInt16(bitPattern: Int16(n >= 1 ? 0x7fff : (n * 32768).rounded()))
        }
        var b: [UInt8] = [3]
        b += position(x: x, y: y)
        b += beBytes(fixed(dx)) + beBytes(fixed(dy))
        b += beBytes(UInt32(0))
        send(b)
    }

    func key(_ action: KeyAction, _ keycode: Int32, meta: Int32 = 0) {
        var b: [UInt8] = [0, action.rawValue]
        b += beBytes(UInt32(bitPattern: keycode)) + beBytes(UInt32(0)) + beBytes(UInt32(bitPattern: meta))
        send(b)
    }

    func press(_ keycode: Int32) {
        key(.down, keycode)
        key(.up, keycode)
    }

    /// Types text (ASCII-friendly; other scripts go through the clipboard, see `paste`).
    func text(_ s: String) {
        let data = Array(s.utf8.prefix(300))
        send([1] + beBytes(UInt32(data.count)) + data)
    }

    /// Puts text on the phone's clipboard, and pastes it into the focused field when `paste` is set.
    func setClipboard(_ s: String, paste: Bool) {
        let data = Array(s.utf8.prefix(250_000))
        clipboardSequence += 1
        send([9] + beBytes(UInt64(clipboardSequence)) + [paste ? 1 : 0] + beBytes(UInt32(data.count)) + data)
    }

    /// Turns the phone's screen on or off while it keeps mirroring.
    func setDisplayPower(_ on: Bool) { send([10, on ? 1 : 0]) }

    private func position(x: Int, y: Int) -> [UInt8] {
        beBytes(UInt32(bitPattern: Int32(x))) + beBytes(UInt32(bitPattern: Int32(y)))
            + beBytes(UInt16(videoSize.width)) + beBytes(UInt16(videoSize.height))
    }

    private func beBytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }
}

/// Turns the H.264 Annex-B stream from Android's encoder into CMSampleBuffers (AVCC) that the Mac's
/// hardware decoder shows via AVSampleBufferDisplayLayer.
final class H264Packetizer {
    private var format: CMVideoFormatDescription?

    /// Splits Annex-B data (00 00 01 / 00 00 00 01 start codes) into NAL units.
    static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0, start = -1
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, b[end - 1] == 0 { end -= 1 }
                    units.append(b[start..<end])
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < b.count { units.append(b[start...]) }
        return units
    }

    func configure(annexB: [UInt8]) {
        let units = Self.nalUnits(annexB)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1f == 7 }),
              let pps = units.first(where: { ($0.first ?? 0) & 0x1f == 8 }) else { return }
        let spsData = Array(sps), ppsData = Array(pps)
        spsData.withUnsafeBufferPointer { s in
            ppsData.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [spsData.count, ppsData.count]
                var desc: CMFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                format = desc
            }
        }
    }

    func sample(annexB: [UInt8], keyFrame: Bool) -> CMSampleBuffer? {
        guard let format else { return nil }
        // Annex-B → AVCC: each NAL unit prefixed with its 4-byte big-endian length. Parameter sets repeated
        // in key frames are dropped (the format description already has them).
        var avcc: [UInt8] = []
        avcc.reserveCapacity(annexB.count + 16)
        for unit in Self.nalUnits(annexB) {
            let type = (unit.first ?? 0) & 0x1f
            if type == 7 || type == 8 { configure(annexB: annexB); continue }
            let n = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: n) { avcc += $0 }
            avcc += unit
        }
        guard !avcc.isEmpty else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // Show frames as soon as they arrive: lowest latency, no clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            first[kCMSampleAttachmentKey_NotSync] = !keyFrame
        }
        return sample
    }
}
