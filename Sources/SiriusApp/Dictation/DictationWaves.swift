import SwiftUI

// The dictation waves: six level bars that follow the voice while recording
// and settle into dots while transcribing. Parrot's RecordingOverlay bars,
// moved out of DictationPill so the pill and the composer draw one
// implementation. The composer holds a set at its bottom centre, shown
// only while fn is held with it open and through the transcription after:
// idle bars were a distraction, so only fn brings them up. Neither shows
// them idle.
// The dots are the composer's alone: the pill shrinks back into the
// sparkle as it transcribes.
@MainActor
final class DictationWavesModel: ObservableObject {
    enum Phase: Equatable {
        // Flat and dim, nothing dictated. The composer hides its waves
        // in this phase (hidesAtRest).
        case idle
        case recording
        case transcribing
    }

    static let barCount = 6
    // Per-bar height multiplier: centre bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published private(set) var phase: Phase
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: barCount)
    // Whether the current recording has been louder than silence, so a
    // recording with nothing said gets no loading animation.
    @Published private(set) var heardVoice = false

    // RMS over one refresh interval above which the recording counts as
    // speech. Silent recordings measure about 0.001 over their whole length;
    // speech averages 0.007 to 0.018 and peaks well above (Parrot's figures).
    static let voiceThreshold: Float = 0.01

    // How often the bars move. Capture delivers a level per buffer, about
    // every 12 ms with Parrot's AUHAL input; the bars are tuned for about
    // 100 ms and look twitchy any faster.
    static let refreshInterval: TimeInterval = 0.1

    private var pendingPower: Float = 0
    private var pendingCount = 0
    private var lastRefresh: TimeInterval = 0

    init(phase: Phase = .idle) {
        self.phase = phase
    }

    // MARK: Phases

    // A recording began: the bars start flat and follow the level.
    func start() {
        resetLevels()
        phase = .recording
    }

    // The key was released: the bars settle while the capture transcribes.
    func transcribing() {
        phase = .transcribing
    }

    // Back to rest, flat and dim, ready for the next hold.
    func idle() {
        resetLevels()
        phase = .idle
    }

    // MARK: Levels

    // Collects levels and moves the bars once per refreshInterval, with the
    // RMS over that interval. Ignored at rest, so a level arriving after the
    // hold ended does not stir idle bars.
    func pushLevel(_ level: Float) {
        guard phase == .recording else { return }
        pendingPower += level * level
        pendingCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefresh >= Self.refreshInterval else { return }
        let rms = (pendingPower / Float(pendingCount)).squareRoot()
        pendingPower = 0
        pendingCount = 0
        lastRefresh = now
        if rms > Self.voiceThreshold, !heardVoice {
            heardVoice = true
        }
        showLevel(rms)
    }

    private func showLevel(_ level: Float) {
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    private func resetLevels() {
        pendingPower = 0
        pendingCount = 0
        heardVoice = false
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

struct DictationWaves: View {
    @ObservedObject var model: DictationWavesModel
    // Fades the bars out at idle and back in as a hold starts: the
    // composer's, which show only while dictating.
    var hidesAtRest = false

    // The bars' size, in the pill and in the composer.
    static let size = CGSize(width: 51, height: 20)
    // The bars' blue, the composer caret's (Palette.caret).
    static let tint = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)
    // At rest: the caret's blue dimmed, the composer's selection tone.
    static let idleTint = Color(nsColor: Palette.selection)

    // Height of a resting bar (idle, or after a silent recording), as a
    // fraction of the full height.
    private static let restHeight: CGFloat = 0.2
    // Size of the dots the middle bars settle into while transcribing.
    private static let dotSize: CGFloat = 3.5
    // How long the bars take to settle into dots, or to rest.
    private static var settleDuration: Double { 0.25 * SpatialMotion.timeScale }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3.75) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { i, level in
                    let bar = bar(i, level: level, height: geo.size.height)
                    Capsule()
                        .fill(model.phase == .idle ? Self.idleTint : Self.tint)
                        .frame(width: bar.width, height: bar.height)
                        .opacity(bar.opacity)
                        .animation(
                            model.phase == .recording ? .easeOut(duration: 0.09) : .easeInOut(duration: Self.settleDuration),
                            value: bar.height
                        )
                        .animation(.easeInOut(duration: Self.settleDuration), value: bar.opacity)
                        .animation(.easeInOut(duration: Self.settleDuration), value: model.phase == .idle)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(hidesAtRest && model.phase == .idle ? 0 : 1)
            .animation(.easeInOut(duration: Self.settleDuration), value: model.phase == .idle)
        }
    }

    // While recording, each bar follows the level. While transcribing, the
    // outer bars fade where they stand and the middle ones settle into dots;
    // after a silent recording, every bar just rests. At idle every bar
    // rests, dim.
    private func bar(_ i: Int, level: Float, height: CGFloat) -> (width: CGFloat, height: CGFloat, opacity: Double) {
        let rest = (2.5 as CGFloat, Self.restHeight * height, 1.0)
        let live = max(0.10, CGFloat(level)) * height
        switch model.phase {
        case .idle:
            return rest
        case .recording:
            return (2.5, live, 1)
        case .transcribing:
            guard model.heardVoice else { return rest }
            if i == 0 || i == model.levels.count - 1 {
                return (2.5, live, 0)
            }
            return (Self.dotSize, Self.dotSize, 1)
        }
    }
}
