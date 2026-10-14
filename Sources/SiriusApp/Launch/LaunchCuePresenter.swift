import AppKit
import SiriusCore

// The launch moment: as Sirius starts, the dictation
// pill opens on the sparkle, its border's ring plays once, the pill grows
// to say "Listening." (DictationPill.sayListening), and the pill
// leaves once Sirius is ready (LaunchCue: the agents started warm and a
// model already on disk loaded; the socket server is up before this
// shows), after 3.7 s at the least and 6 s at the most. Not while the
// onboarding opens at launch, which has its own opening. A press of the
// hold key takes the pill over at once (DictationPill.launchInterrupted).
// The cue's sound (LaunchSound) lands Glass with the word, under Reduce
// Motion too, which is about motion, not sound; a press stops it if Glass
// has not landed.
// Never takes focus: the pill is a non-activating, click-through panel.
// TODO(copy): the launch cue is a first pass.
@MainActor
final class LaunchCuePresenter {
    private var dictation: DictationService?
    private var agentsReady: Bool
    private var modelReady = true
    private var shownAt: Date?
    private var ended = false
    private var sound: LaunchSound?

    // `waitsForAgents`: some agent is registered and starting. Made before
    // the agents start, so it hears them finish.
    init(waitsForAgents: Bool) {
        agentsReady = !waitsForAgents
    }

    // Dictation, once its model has begun loading (prepareModel).
    func attach(_ dictation: DictationService) {
        self.dictation = dictation
        modelReady = !dictation.loadsFromDisk
        dictation.onModelSettled = { [weak self] in self?.modelSettled() }
        dictation.onPress = { [weak self] in self?.sound?.interrupt() }
    }

    // The registered agents have all finished starting, started or not.
    func agentsStarted() {
        agentsReady = true
        check()
    }

    private func modelSettled() {
        modelReady = true
        check()
    }

    // Shows the cue, unless the onboarding opened at launch.
    func begin(onboardingShown: Bool) {
        guard !onboardingShown else {
            ended = true
            SiriusLog.launch.info("launch cue: skipped, the onboarding is open")
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        SiriusLog.launch.info("launch cue: showing (agents \(agentsReady ? "ready" : "starting"), "
            + "model \(modelReady ? "ready" : "loading")\(reduceMotion ? ", Reduce Motion" : ""))")
        shownAt = Date()
        dictation?.showLaunch(reduceMotion: reduceMotion)
        // Glass lands with the word, which the Debug slow motion delays.
        // Under Reduce Motion the word is in from the start; the sound keeps
        // its time.
        sound = LaunchSound()
        sound?.play(after: LaunchCue.Sound.start + LaunchCue.wordAppears * (SpatialMotion.timeScale - 1))
        for delay in [LaunchCue.minimum, LaunchCue.maximum] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    private func check() {
        guard !ended, let shownAt else { return }
        let elapsed = Date().timeIntervalSince(shownAt)
        let ready = agentsReady && modelReady
        guard LaunchCue.leaves(elapsed: elapsed, ready: ready) else { return }
        ended = true
        SiriusLog.launch.info("launch cue: \(ready ? "ready" : "timed out") after \(String(format: "%.1f", elapsed))s")
        dictation?.endLaunch()
    }
}
