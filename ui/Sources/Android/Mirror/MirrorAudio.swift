import AVFoundation

/// Plays the phone's sound while mirroring. scrcpy's raw codec sends 48 kHz stereo 16-bit PCM. Wi-Fi
/// delivers it in bursts, so playback starts once a small cushion is queued (and again after running
/// dry). After a stall, the late burst is trimmed: a queue that stays long is shortened a packet at a
/// time, and one that grows too long drops packets outright, so the sound keeps up with the video.
final class MirrorAudioPlayer: @unchecked Sendable {
    private static let sampleRate = 48_000.0
    /// Sound queued before playback (re)starts.
    private static let cushion = Int(sampleRate * 0.04)
    /// More than this queued for over a second is trimmed.
    private static let highQueued = Int(sampleRate * 0.1)
    /// More than this queued drops new packets at once.
    private static let maxQueued = Int(sampleRate * 0.2)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    /// Starts and pauses the player, in order (never from its own completion callbacks).
    private let control = DispatchQueue(label: "mirror.audio")
    private let lock = NSLock()
    private var queuedFrames = 0
    private var playing = false
    private var running = false
    private var highSince: CFAbsoluteTime?
    /// Diagnostics: packets played and dropped, times the queue ran dry, loudest sample.
    private(set) var played = 0
    private(set) var dropped = 0
    private(set) var underruns = 0
    private(set) var peak: Int16 = 0

    func start() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        running = (try? engine.start()) != nil
    }

    func stop() {
        guard running else { return }
        running = false
        control.sync {
            player.stop()
            engine.stop()
        }
    }

    /// One packet of interleaved little-endian Int16 stereo samples.
    func play(_ data: Data) {
        guard running else { return }
        let frames = data.count / 4
        guard frames > 0 else { return }
        lock.lock()
        let backlog = queuedFrames
        lock.unlock()
        if backlog > Self.maxQueued { dropped += 1; return }
        if backlog > Self.highQueued {
            let now = CFAbsoluteTimeGetCurrent()
            if let since = highSince {
                if now - since > 1 { highSince = now; dropped += 1; return }
            } else {
                highSince = now
            }
        } else {
            highSince = nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0], right = channels[1]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let l = Int16(littleEndian: samples[2 * i])
                peak = max(peak, l == .min ? .max : abs(l))
                left[i] = Float(l) / 32768
                right[i] = Float(Int16(littleEndian: samples[2 * i + 1])) / 32768
            }
        }
        played += 1

        lock.lock()
        queuedFrames += frames
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in self?.consumed(frames) }
        lock.lock()
        if !playing, queuedFrames >= Self.cushion {
            playing = true
            control.async { [self] in if running { player.play() } }
        }
        lock.unlock()
    }

    private func consumed(_ frames: Int) {
        lock.lock()
        queuedFrames -= frames
        if queuedFrames <= 0, playing {
            playing = false
            underruns += 1
            control.async { [self] in if running { player.pause() } }
        }
        lock.unlock()
    }
}
