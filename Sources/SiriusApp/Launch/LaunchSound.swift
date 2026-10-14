import AVFoundation
import SiriusCore

// The launch cue's sound: Hero's two pickups as a fill,
// landing on Glass as "Listening." comes in. The timing and levels are
// LaunchCue.Sound's. Both sounds are macOS's own, read from
// /System/Library/Sounds when the cue begins and never bundled; if either is
// missing, nothing plays.
//
// One AVAudioEngine, made for the cue and torn down once Glass has rung
// out, so Sirius holds no audio device while idle. Two player nodes, Hero's
// segment (its first 0.175 s, faded out at the cut) on one and Glass on the
// other, scheduled in the players' own sample time (Glass at +0.18 s) and
// started together at one host time: the offset is sample-accurate, where
// two NSSound calls on a timer would drift. Output only, to the default
// device: the engine's inputNode is never touched, so it asks for no
// microphone, and the dictation's engine is a separate one. A muted output
// mutes it, as it does every sound.
// TODO(andrew): the launch cue is a first pass.
@MainActor
final class LaunchSound {
    private static let directory = "/System/Library/Sounds"
    private static var missingLogged = false

    private let hero: AVAudioPCMBuffer
    private let glass: AVAudioPCMBuffer
    private var engine: AVAudioEngine?
    // When Glass lands, by the host clock, once scheduled.
    private var glassHostTime: UInt64?

    // Nil, after logging once, when either sound cannot be read.
    init?() {
        guard let hero = Self.read("Hero", seconds: LaunchCue.Sound.heroCut),
              let glass = Self.read("Glass", seconds: nil) else {
            if !Self.missingLogged {
                Self.missingLogged = true
                SiriusLog.launch.error("launch sound: Hero or Glass is missing from \(Self.directory); playing none")
            }
            return nil
        }
        Self.fadeOut(hero, seconds: LaunchCue.Sound.heroFade)
        self.hero = hero
        self.glass = glass
    }

    // How long the sound runs, from its start to Glass's end.
    var duration: TimeInterval {
        LaunchCue.Sound.glassOffset + Double(glass.frameLength) / glass.format.sampleRate
    }

    // Plays the sound `delay` seconds from now, then tears the engine down.
    func play(after delay: TimeInterval) {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let (heroPlayer, glassPlayer) = attach(to: engine)
        engine.mainMixerNode.outputVolume = LaunchCue.Sound.volume
        do {
            try engine.start()
        } catch {
            SiriusLog.launch.error("launch sound: the engine did not start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        let start = mach_absolute_time() + Self.hostTicks(delay)
        let when = AVAudioTime(hostTime: start)
        heroPlayer.play(at: when)
        glassPlayer.play(at: when)
        glassHostTime = start + Self.hostTicks(LaunchCue.Sound.glassOffset)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    // A press took the pill over: stops the sound at once if Glass has not
    // landed yet; once it has, it rings out.
    func interrupt() {
        guard engine != nil, let glassHostTime, mach_absolute_time() < glassHostTime else { return }
        SiriusLog.launch.info("launch sound: stopped by a press")
        stop()
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        glassHostTime = nil
    }

    // The two players on `engine`, each with its segment scheduled in its
    // own sample time: Hero at 0, Glass at glassOffset.
    private func attach(to engine: AVAudioEngine) -> (AVAudioPlayerNode, AVAudioPlayerNode) {
        let heroPlayer = AVAudioPlayerNode()
        let glassPlayer = AVAudioPlayerNode()
        engine.attach(heroPlayer)
        engine.attach(glassPlayer)
        engine.connect(heroPlayer, to: engine.mainMixerNode, format: hero.format)
        engine.connect(glassPlayer, to: engine.mainMixerNode, format: glass.format)
        heroPlayer.volume = LaunchCue.Sound.heroGain
        glassPlayer.volume = LaunchCue.Sound.glassGain
        heroPlayer.scheduleBuffer(hero, at: AVAudioTime(sampleTime: 0, atRate: hero.format.sampleRate))
        let rate = glass.format.sampleRate
        glassPlayer.scheduleBuffer(glass, at: AVAudioTime(sampleTime: AVAudioFramePosition(
            (LaunchCue.Sound.glassOffset * rate).rounded()), atRate: rate))
        return (heroPlayer, glassPlayer)
    }

    // The first `seconds` of a system sound, or all of it.
    private static func read(_ name: String, seconds: TimeInterval?) -> AVAudioPCMBuffer? {
        let url = URL(fileURLWithPath: "\(directory)/\(name).aiff")
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        var frames = AVAudioFrameCount(file.length)
        if let seconds {
            frames = min(frames, AVAudioFrameCount((seconds * file.processingFormat.sampleRate).rounded()))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil,
              buffer.frameLength > 0 else { return nil }
        return buffer
    }

    // A linear fade to silence over the buffer's last `seconds`.
    private static func fadeOut(_ buffer: AVAudioPCMBuffer, seconds: TimeInterval) {
        guard let channels = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        let fade = min(length, Int((seconds * buffer.format.sampleRate).rounded()))
        guard fade > 0 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for index in 0..<fade {
                samples[length - fade + index] *= Float(fade - 1 - index) / Float(fade)
            }
        }
    }

    private static func hostTicks(_ seconds: TimeInterval) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    // MARK: Offline render

    // Debug: `Sirius --launch-sound-render <path>` renders the sound through
    // the same players and schedule, offline in the engine's manual
    // rendering mode, to a 48 kHz stereo WAV and exits, before the socket
    // server starts. The mix at its own level, without the output's 0.5,
    // to compare with the approved reference render.
    static let renderFlag = "--launch-sound-render"

    static func renderIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: renderFlag), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1])
        do {
            guard let sound = LaunchSound() else { exit(1) }
            try sound.render(to: url)
            print(url.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Sirius: launch sound render: \(error)\n".utf8))
            exit(1)
        }
    }

    private func render(to url: URL) throws {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let (heroPlayer, glassPlayer) = attach(to: engine)
        try engine.start()
        heroPlayer.play()
        glassPlayer.play()
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
        var remaining = AVAudioFramePosition((duration * 48_000).rounded())
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        engine.stop()
    }
}
