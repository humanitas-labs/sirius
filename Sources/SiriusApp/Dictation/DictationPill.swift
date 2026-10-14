import AppKit
import SiriusCore
import ParrotCore
import SwiftUI

// The dictation pill: a borderless, click-through capsule near the bottom of
// the active screen, showing the level while recording and shrinking back
// into the sparkle while transcribing. Copied from Parrot's RecordingOverlay
// (parrot Sources/ParrotApp/UI/RecordingOverlay.swift) and owned by Sirius
// from here on: the pill is not shared, and Parrot's tweaks no longer reach
// it. Its look, position and motion are still Parrot's.
// What Sirius adds: the pill opens on the logo of the agent the hold is
// going to (or its mark, for a paste or no agent), then morphs into the
// level bars, and on release shrinks back into the sparkle until the
// transcript is delivered: the agent shows only while fn is held; and a
// download or warm-up state, a short label
// over a progress bar.
// On finish the pill just closes: no transcript is shown. Parrot's one-line error message went with ParrotCore's
// UserFacingError; a failure here turns the sparkle red as the pill goes.
// It follows ParrotCore's DictationController as a DictationObserver; the
// lifecycle methods below also run alone, for the Debug preview. The level
// bars are DictationWaves, shared with the composer, which shows them in
// place of the pill while it is open.
@MainActor
final class DictationPill: DictationObserver {
    enum State: Equatable {
        // The mark, as the pill opens.
        case mark
        case recording
        // The launch cue's sparkle alone, breathing, while the capture
        // transcribes: the bars' pill shrinks back into it, the launch
        // cue's grow played in reverse, in place of Parrot's bars settling
        // into dots.
        case transcribing
        // A model download or warm-up, 0...1, with its label.
        case progress(Double, String)
        // The launch cue: the sparkle in white while Sirius wakes, the
        // border's ring playing once, then the pill grows to say
        // "Listening." (LaunchCuePresenter).
        case launch
    }

    // Wide enough for the progress label; the panel is transparent and
    // click-through, so the unused width is invisible, and casts no shadow.
    private static let panelSize = NSSize(width: 640, height: 64)
    // The pill's height: its content, 20, and 9 above and below, Parrot's
    // 38. It was 44, then 40, and is back at its original 38.
    static let height: CGFloat = 38

    // How long the pill takes to grow or shrink, and to morph from one state
    // to the next; on hide, the window is ordered out once it has. Parrot's
    // 0.3 s, stretched by the Debug slow motion.
    nonisolated static let baseScaleDuration: TimeInterval = 0.3
    static var scaleDuration: TimeInterval { baseScaleDuration * SpatialMotion.timeScale }
    // How long the mark holds before it morphs into the bars: one open, so it
    // reads as the pill arriving rather than a step to wait through.
    static var markHold: TimeInterval { 0.3 * SpatialMotion.timeScale }
    // The least time the pill stays on the sparkle after the release before
    // it closes: the shrink, then the open's mark hold, so a transcript that
    // comes back at once still lets the shrink land and the sparkle read as
    // the pill settling rather than a glitch.
    static var transcribingHold: TimeInterval { scaleDuration + markHold }
    // How long a late ⌃ takes to cross the opening logo back to the mark.
    nonisolated static let baseLogoSwap: TimeInterval = 0.15
    static var logoSwap: TimeInterval { baseLogoSwap * SpatialMotion.timeScale }

    private let mark: NSImage?
    private var window: NSPanel?
    private let model = PillModel()
    // Bumped by every show, so the mark's hold only morphs its own opening.
    private var generation = 0
    // When the pill began shrinking into the sparkle (systemUptime), for
    // transcribingHold.
    private var transcribingSince: TimeInterval?
    // Whether a hold is recording now, and how many released holds are
    // still transcribing. ParrotCore lets a press start while an earlier
    // hold still transcribes, and that hold's end then reaches the pill
    // during the new one: it is not this pill's to close.
    private var recording = false
    private var transcriptions = 0
    // Keeps the pill off every screen, for the snapshots
    // (DictationSnapshots).
    var parksOffscreen = false
    // The pill's view, to render for the snapshots.
    var snapshotView: NSView? { window?.contentView }
    // What the pill shows, for the tests (DictationPillTests): whether its
    // window is ordered in, whether it stands at full scale or fading in,
    // its state, whether it is red, and the logo it opens on.
    var isOrderedIn: Bool { window?.isVisible == true }
    var isShown: Bool { model.visible }
    var shownState: State { model.state }
    var isRed: Bool { model.failedAt != nil }
    var shownOpenLogo: NSImage? { model.opensOnLogo ? model.openLogo : nil }
    var windowAlpha: CGFloat { window?.alphaValue ?? 0 }
    // Recomputes the window shadow while the pill grows, morphs or shrinks.
    private var shadowTimer: Timer?
    // The launch cue's colour in the border: the toast's arrival ring
    // (SplashRing), at the capsule's shape, over the pill.
    private let ring = SplashRing(radius: DictationPill.height / 2, cornerCurve: .circular)

    init(mark: NSImage?) {
        self.mark = mark
        model.mark = mark
        // Build the panel now, not on the first press, so the first pill
        // appears as quickly as every later one.
        ensureWindow()
    }

    // A paste hold (⌃fn): a text-cursor glyph leads the bars, so the press
    // reads as typing rather than talking to an agent.
    // TODO(copy): the paste cue is a first pass.
    var pastes: Bool {
        get { model.pastes }
        set {
            model.pastes = newValue
            // ⌃ joining late turns the hold into a paste: an opening logo
            // crosses back to the sparkle.
            if newValue, model.opensOnLogo {
                withAnimation(.easeInOut(duration: Self.logoSwap)) { model.opensOnLogo = false }
            }
        }
    }

    // MARK: Lifecycle, as Parrot's DictationObserver

    // The pill opens on the logo of the agent the hold is going to, read
    // as it is pressed; a paste or no agent opens on the mark as before.
    func dictationStarted() {
        recording = true
        model.waves.start()
        let logo = destination?()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.openLogo = logo
            model.opensOnLogo = logo != nil
        }
        guard mark != nil || logo != nil else {
            show(.recording)
            return
        }
        show(.mark)
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.markHold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown, self.model.state == .mark else { return }
                self.show(.recording)
            }
        }
    }

    // The bars are left as they stood, not settled into the waves' dots,
    // as they shrink and fade out around the incoming sparkle.
    func dictationTranscribing() {
        recording = false
        transcriptions += 1
        transcribingSince = ProcessInfo.processInfo.systemUptime
        model.failedAt = nil
        show(.transcribing)
    }

    // The logo of the agent the hold is going to, read as it is pressed so
    // the pill opens on it. Nil opens on the mark: a paste, or
    // no agent known. From the release on, the pill is the sparkle's.
    var destination: (@MainActor () -> NSImage?)?

    func dictationFinished() {
        transcriptionEnded(failed: false)
    }

    func dictationFailed() {
        transcriptionEnded(failed: true)
    }

    // A transcription is done. The pill leaves only on the last one, and
    // never while a newer hold records: that pill is the newer hold's.
    private func transcriptionEnded(failed: Bool) {
        transcriptions = max(0, transcriptions - 1)
        guard !recording, transcriptions == 0 else { return }
        if failed { fail() } else { close() }
    }

    // A failed transcription leaves from its own exit, not the scale out:
    // once the shrink has landed the sparkle turns red with a soft red glow
    // and the pill gives the wrong-password shake, holds errorHold so it
    // registers, then fades out. Under Reduce Motion, the
    // red alone. A failure before the release closes the pill as before.
    nonisolated static let baseErrorHold: TimeInterval = 0.8
    static var errorHold: TimeInterval { baseErrorHold * SpatialMotion.timeScale }
    // The shake: a few points each way, three times over, dying away.
    nonisolated static let baseShakeDuration: TimeInterval = 0.4
    static let shakeAmplitude: CGFloat = 3
    static let shakeCount: Double = 3
    private var shakeTimer: Timer?

    private func fail() {
        guard model.state == .transcribing, model.visible, let since = transcribingSince else {
            hide()
            return
        }
        let wait = max(0, Self.scaleDuration - (ProcessInfo.processInfo.systemUptime - since))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.model.failedAt = ProcessInfo.processInfo.systemUptime
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.shake() }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorHold) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == shown else { return }
                        // Out by the window's fade, at full scale.
                        self.model.fades = true
                        self.hide()
                    }
                }
            }
        }
    }

    private func shake() {
        shakeTimer?.invalidate()
        let start = ProcessInfo.processInfo.systemUptime
        let duration = Self.baseShakeDuration * SpatialMotion.timeScale
        let model = self.model
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let p = min((ProcessInfo.processInfo.systemUptime - start) / duration, 1)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    model.shake = Self.shakeAmplitude * CGFloat(sin(2 * .pi * Self.shakeCount * p) * (1 - p))
                }
                if p >= 1 {
                    timer.invalidate()
                    if self?.shakeTimer === timer { self?.shakeTimer = nil }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shakeTimer = timer
        followShadow(for: duration)
    }

    // Closes the pill, from the sparkle no sooner than transcribingHold
    // after the release; a new press in the meantime keeps it.
    private func close() {
        guard model.state == .transcribing, model.visible, let since = transcribingSince else {
            hide()
            return
        }
        let wait = Self.transcribingHold - (ProcessInfo.processInfo.systemUptime - since)
        guard wait > 0 else {
            hide()
            return
        }
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.hide()
            }
        }
    }

    // DictationObserver's, carrying what the pill does not show: the counts
    // and timings, and why nothing was delivered.
    func dictationFinished(_ result: DictationResult) {
        dictationFinished()
    }

    // A discarded press (a short tap, a chord) is not a failure, nor is
    // this hold's capture failing as it starts or stops: the pill just
    // closes. A release with no audio closes as an empty transcript does,
    // without the red. Anything else is a
    // transcription or a delivery failing.
    func dictationFailed(_ error: Error) {
        switch error {
        case DictationError.cancelled, is CaptureError:
            recording = false
            hide()
        case DictationError.noAudio:
            dictationFinished()
        default:
            dictationFailed()
        }
    }

    // MARK: Feeds

    // A new audio level (0…~1), from AudioCapture.onLevel while recording.
    // Safe to call from any thread, as capture calls it from its own.
    nonisolated func level(_ value: Float) {
        Task { @MainActor in
            self.model.waves.pushLevel(value)
        }
    }

    // A model download or warm-up: `fraction` in 0...1 with a short label;
    // nil hides the pill if it is showing progress.
    // TODO(copy): the label copy ("Downloading speech model" in the Debug
    // preview), and whether warm-up gets its own phase.
    func progress(_ fraction: Double?, label: String) {
        guard let fraction else {
            if case .progress = model.state { hide() }
            return
        }
        show(.progress(min(max(fraction, 0), 1), label))
    }

    // MARK: Launch

    // How long the sparkle takes to come in from its blur: OnboardingIntro's
    // reveal curve, shorter, as the pill springs in around it.
    // TODO(copy): the launch cue is a first pass.
    nonisolated static let baseRevealDuration: TimeInterval = 0.7
    static var revealDuration: TimeInterval { baseRevealDuration * SpatialMotion.timeScale }
    // How long a faded open or close takes, under Reduce Motion.
    static let fadeDuration: TimeInterval = 0.3
    // When the pill grows to say "Listening.", after the open, once the
    // sparkle has landed. The grow is the pill's own
    // resize (PillView.curve); the word comes in from a blur half-way into
    // it, as the onboarding's lockup does, when the curve has opened nearly
    // all the room, so the word never stands past the capsule. The sparkle
    // holds alone until then (0.6 s before, which was a touch short).
    nonisolated static let baseGrowDelay: TimeInterval = 1.1
    static var growDelay: TimeInterval { baseGrowDelay * SpatialMotion.timeScale }
    static var wordDelay: TimeInterval { scaleDuration / 2 }
    static var wordDuration: TimeInterval { 0.6 * SpatialMotion.timeScale }

    // Whether the pill is showing the launch cue.
    var showsLaunch: Bool { model.state == .launch && model.visible }

    // Opens the pill on the sparkle and plays the ring once, then grows it
    // to say "Listening.". Under Reduce Motion: a plain fade in, the sparkle
    // and the word together at the full width, and no ring (SplashRing
    // plays none) and no grow.
    func showLaunch(reduceMotion: Bool) {
        ensureWindow()
        guard let window else { return }
        let shown = generation + 1
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.fades = reduceMotion
            model.launchReveal = reduceMotion ? 1 : 0
            model.launchGrow = reduceMotion ? 1 : 0
            model.launchWord = reduceMotion ? 1 : 0
        }
        if reduceMotion {
            window.alphaValue = 0
            show(.launch)
            fadeWindow(to: 1)
            return
        }
        window.alphaValue = 1
        show(.launch)
        placeRing(grow: 0)
        ring.view.alphaValue = 1
        ring.splash()
        // With the grow, which starts on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Self.revealDuration)) {
                    self.model.launchReveal = 1
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.growDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown, self.showsLaunch else { return }
                self.sayListening(shown: shown)
            }
        }
    }

    // The pill widens on its resize curve to make room for "Listening." to
    // the right of the sparkle, the ring's border widening with it, and the
    // word comes in.
    private func sayListening(shown: Int) {
        withAnimation(PillView.curve) { model.launchGrow = 1 }
        ring.resize(to: NSSize(width: PillView.pillWidth(.launch, launchGrow: 1), height: Self.height),
                    duration: Self.scaleDuration, timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        followShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wordDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown, self.showsLaunch else { return }
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Self.wordDuration)) {
                    self.model.launchWord = 1
                }
            }
        }
    }

    // Sirius is ready, or the cue has run its time: the pill leaves, if it
    // is still on the launch cue.
    func endLaunch() {
        guard showsLaunch else { return }
        hide()
    }

    // A press during the launch cue: if it did not open the pill on
    // something else (the composer took the hold, or the microphone is not
    // granted), the pill leaves at once.
    func launchInterrupted() {
        guard showsLaunch else { return }
        SiriusLog.launch.info("launch cue: interrupted by a press")
        hide()
    }

    // The ring over the launch cue's capsule, centred in the panel: its
    // view at the width that says "Listening.", the ring itself at the
    // capsule's width `grow` of the way there.
    private func placeRing(grow: Double) {
        guard let bounds = window?.contentView?.bounds else { return }
        let width = PillView.pillWidth(.launch, launchGrow: 1)
        ring.setFrame(NSRect(x: (bounds.width - width) / 2, y: (bounds.height - Self.height) / 2,
                             width: width, height: Self.height))
        ring.resize(to: NSSize(width: PillView.pillWidth(.launch, launchGrow: grow), height: Self.height))
    }

    private func fadeRing() {
        guard ring.view.alphaValue > 0 else { return }
        let ring = self.ring
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.scaleDuration * 0.6
            ring.view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if ring.view.alphaValue == 0 { ring.stop() } }
        }
    }

    private func fadeWindow(to alpha: CGFloat) {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            window.animator().alphaValue = alpha
        }
    }

    // The launch cue held still for the snapshots (LaunchSnapshots): the
    // sparkle `reveal` of the way in, the pill `grow` of the way to its
    // width for "Listening." and the word `word` of the way in, and the
    // ring `ring` seconds into its splash, or none. Off every screen;
    // returns the view to render.
    func poseLaunch<R: RandomNumberGenerator>(reveal: Double, grow: Double, word: Double, ring seconds: Double?,
                                              using random: inout R) -> NSView? {
        ensureWindow()
        guard let window else { return nil }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.state = .launch
            model.visible = true
            model.fades = false
            model.launchReveal = reveal
            model.launchGrow = grow
            model.launchWord = word
        }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.alphaValue = 1
        window.orderFrontRegardless()
        placeRing(grow: grow)
        if let seconds {
            ring.view.alphaValue = 1
            ring.pose(at: seconds, using: &random)
        } else {
            ring.view.alphaValue = 0
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView
    }

    // MARK: Window

    private func show(_ state: State) {
        generation += 1
        let shown = generation
        ensureWindow()
        guard let window else { return }
        // A new hold takes over from a failure's exit at once: no red, no
        // shake.
        if state != .transcribing, model.failedAt != nil || model.shake != 0 {
            shakeTimer?.invalidate()
            shakeTimer = nil
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                model.failedAt = nil
                model.shake = 0
            }
        }
        if state != .launch {
            // Anything else takes over from the launch cue at once: its ring
            // is drawn for the sparkle's capsule, and a faded open
            // (Reduce Motion) comes the rest of the way in.
            fadeRing()
            if !window.isVisible {
                window.alphaValue = 1
            } else if window.alphaValue < 1 {
                fadeWindow(to: 1)
            }
        }
        if !window.isVisible || !model.visible {
            // Change the content without animation while the pill is at scale
            // 0, then grow it on the next runloop tick, so SwiftUI lays out
            // the new content first and only the grow animates.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                model.state = state
                if state != .launch { model.fades = false }
            }
            if !window.isVisible {
                positionAtBottomCenter(window)
                window.orderFrontRegardless()
            }
            postFrame(window)
            // Only if nothing has hidden or shown the pill since: a hide in
            // the same turn would otherwise be undone, leaving the pill
            // stuck on screen.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == shown else { return }
                    self.model.visible = true
                }
            }
        } else {
            model.state = state
        }
        followShadow()
    }

    private func hide() {
        generation += 1
        model.visible = false
        fadeRing()
        // A faded open (the launch cue under Reduce Motion) fades out too.
        if model.fades { fadeWindow(to: 0) }
        // Let the SwiftUI scale animation play out before ordering the window
        // out, or it just pops away. Skip it if the pill was shown again in
        // the meantime.
        followShadow()
        // By generation, not by model.visible: a show whose grow has not
        // started yet must keep its window.
        let hidden = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scaleDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hidden else { return }
                self.window?.orderOut(nil)
                // A faded exit (a failure's) leaves the content at full
                // scale behind the window's alpha; back at scale 0, so the
                // next open's first frame cannot show the old red sparkle.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { self.model.fades = false }
            }
        }
        NotificationCenter.default.post(name: .dictationPillFrame, object: nil)
    }

    // The toast stands above the pill as it does above the open composer
    // (ToastPanel.avoid). Its own name, so the pill and
    // the composer, both up during a model download, do not clear each
    // other. The pill's band across the panel: only its top and screen
    // matter to the toast, and its width changes as it morphs.
    private func postFrame(_ window: NSPanel) {
        let frame = window.frame
        let band = NSRect(x: frame.minX, y: frame.midY - Self.height / 2, width: frame.width, height: Self.height)
        NotificationCenter.default.post(name: .dictationPillFrame, object: NSValue(rect: band))
    }

    // The window shadow is the composer's (applyComposerWindowShadow), drawn
    // by the window server from the window's content when it is shown, so it
    // would keep the pill's old shape as SwiftUI grows, morphs or shrinks it.
    // Recompute it every frame for the length of the animation, and once
    // after: it then follows the capsule at 46 and 77 and every width
    // between, and is gone with the pill at scale 0.
    private func followShadow(for duration: TimeInterval? = nil) {
        shadowTimer?.invalidate()
        guard let window else { return }
        // A tick past the animation, for the open's grow, which starts on
        // the next runloop turn.
        let end = Date().addingTimeInterval((duration ?? Self.scaleDuration) + 0.1)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] timer in
            MainActor.assumeIsolated {
                window?.invalidateShadow()
                if Date() >= end {
                    timer.invalidate()
                    if self?.shadowTimer === timer { self?.shadowTimer = nil }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // The composer's shadow and its light-line tweak, so the pill's rim
        // and shadow match the composer's. It
        // replaced a SwiftUI shadow of its own; followShadow keeps it on the
        // capsule as it changes.
        applyComposerWindowShadow(to: panel)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: PillView(model: model))
        // Keep the panel its fixed size and let SwiftUI centre the pill in
        // it, so a wider state grows both ways instead of off to the right.
        host.sizingOptions = []
        let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.wantsLayer = true
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        // The launch cue's ring, over the pill; framed as it plays.
        ring.view.alphaValue = 0
        root.addSubview(ring.view)
        panel.contentView = root

        window = panel
    }

    // Parrot's place: 32 pt above the bottom of the visible frame, on the
    // screen the user is working on (NSScreen.active, as the toast and
    // composer; Parrot uses NSScreen.main).
    private func positionAtBottomCenter(_ window: NSPanel) {
        if parksOffscreen {
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            return
        }
        guard let screen = NSScreen.active ?? NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        // The panel extends below the pill by half its extra height.
        let y = visible.minY + 32 - (frame.height - Self.height) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// Observable state for the SwiftUI pill. The bars' levels are in `waves`,
// the same model the composer's waves use (DictationWaves).
@MainActor
final class PillModel: ObservableObject {
    // What the pill shows, kept as it closes so the close shrinks the content
    // it had rather than swapping to something else.
    @Published var state: DictationPill.State = .recording
    @Published var visible = false
    // A paste hold's cue (DictationPill.pastes).
    @Published var pastes = false
    // The launch cue's sparkle, 0 to 1 of the way in from its blur.
    @Published var launchReveal: Double = 1
    // The launch cue's pill, 0 to 1 of the way from the sparkle's width to
    // the width that says "Listening.", and the word 0 to 1 of the way in.
    @Published var launchGrow: Double = 0
    @Published var launchWord: Double = 0
    // The pill opens and closes by the window's fade, at full scale: the
    // launch cue under Reduce Motion.
    @Published var fades = false
    // When the sparkle turned red for a failure (systemUptime), and the
    // pill's shake, in points across.
    @Published var failedAt: TimeInterval?
    @Published var shake: CGFloat = 0
    // The logo the pill opens on, and whether it shows it rather than the
    // mark (DictationPill.dictationStarted).
    @Published var openLogo: NSImage?
    @Published var opensOnLogo = false
    var mark: NSImage?
    let waves = DictationWavesModel(phase: .recording)
}

private let pillBlue = DictationWaves.tint
private let pillText = Color(red: 235/255, green: 238/255, blue: 242/255)

struct PillView: View {
    @ObservedObject var model: PillModel

    // The mark's size and the bars' height: Parrot's 20.
    static let contentHeight: CGFloat = 20
    // The opening logo's size: the sparkle glyph's, which fills its 20 pt
    // frame about as fully as a logo fills its square.
    static let logoSize: CGFloat = 16

    // Parrot's grow curve, used for the open, the close and every morph,
    // and the launch cue's grow to "Listening.".
    static var curve: Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: DictationPill.scaleDuration)
    }
    private var curve: Animation { Self.curve }

    // Parrot's 13 either side of the content, and its 9 above and below,
    // which follow from the pill's height (15 and 11, then 15 and 9, were
    // tried and reverted). The pill is 46 on the mark,
    // 77 on the bars.
    static let horizontalPadding: CGFloat = 13

    // Everything sits on the panel's centre, in a stack the panel's size, so
    // nothing moves as the pill changes width. The capsule's width and
    // scale are the surface's to draw (PillSurface); the content keeps its
    // own size and is only scaled for the open and close. Laid out by
    // content, as before, the stack shrank or grew about the centre while
    // the mark's last position was kept relative to its corner, so the
    // outgoing mark stood about 16 pt left of centre beside the incoming
    // bars, and the surface jumped to its new left edge and grew rightwards.
    var body: some View {
        ZStack {
            // The composer's surface: its blur, colour and border, at the
            // capsule's radius (installComposerSurface). It replaced Parrot's #101212
            // and its rim of 14% white. The shadow is the window's, as the
            // composer's (DictationPill.followShadow).
            PillSurface(width: Self.pillWidth(model.state, pastes: model.pastes, launchGrow: model.launchGrow),
                        scale: scale)
            ZStack {
                Color.clear
                states
            }
            .scaleEffect(scale)
        }
        .offset(x: model.shake)
        .animation(curve, value: model.state)
        .animation(curve, value: model.visible)
        .animation(curve, value: model.pastes)
    }

    // The pill's scale: 0 when shut, unless it fades (PillModel.fades).
    private var scale: CGFloat { model.visible || model.fades ? 1 : 0 }

    // The paste cue's glyph and its gap to the bars.
    // TODO(copy): the paste cue is a first pass.
    static let cueSize: CGFloat = 11
    static let cueSpacing: CGFloat = 6

    // The capsule's width for a state: its content and the padding. The
    // launch cue's grows from the sparkle's to the sparkle and "Listening."
    // by `launchGrow`, 0 to 1.
    static func pillWidth(_ state: DictationPill.State, pastes: Bool = false, launchGrow: Double = 0) -> CGFloat {
        contentWidth(state, pastes: pastes, launchGrow: launchGrow) + 2 * horizontalPadding
    }

    private static func contentWidth(_ state: DictationPill.State, pastes: Bool, launchGrow: Double) -> CGFloat {
        switch state {
        case .mark, .transcribing: contentHeight
        case .launch: contentHeight + CGFloat(launchGrow) * LaunchWord.room
        case .recording: DictationWaves.size.width + (pastes ? cueSize + cueSpacing : 0)
        case .progress(_, let label): ProgressRow.width(label: label)
        }
    }

    // The mark and the bars trade places by shrinking and fading about the
    // centre while the capsule eases to the new width: the pill's own grow,
    // in small. They overlap on the pill's centre through the morph; the
    // mark does not move as the bars come in and the pill widens from 46
    // to 77.
    private var morph: AnyTransition {
        .scale(scale: 0.4).combined(with: .opacity)
    }

    @ViewBuilder
    private var states: some View {
        switch model.state {
        case .mark:
            // The mark and the opening logo in one stack, so a late ⌃
            // crosses one to the other by opacity alone.
            ZStack {
                MarkView(image: model.mark)
                    .frame(width: Self.contentHeight, height: Self.contentHeight)
                    .opacity(model.opensOnLogo ? 0 : 1)
                MarkView(image: model.openLogo)
                    .frame(width: Self.logoSize, height: Self.logoSize)
                    .opacity(model.opensOnLogo ? 1 : 0)
            }
            .frame(width: Self.contentHeight, height: Self.contentHeight)
                .transition(morph)
        case .recording:
            HStack(spacing: Self.cueSpacing) {
                if model.pastes {
                    // TODO(copy): the paste cue is a first pass.
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: Self.cueSize, weight: .medium))
                        .foregroundColor(pillText.opacity(0.75))
                        .frame(width: Self.cueSize, height: Self.contentHeight)
                        .transition(.opacity)
                }
                DictationWaves(model: model.waves)
                    .frame(width: DictationWaves.size.width, height: Self.contentHeight)
            }
            .transition(morph)
        case .transcribing:
            // The bars shrink and fade out about the centre as the sparkle
            // comes in and the capsule eases back to the mark's 46.
            TranscribingSparkle(failedAt: model.failedAt)
                .frame(width: Self.contentHeight, height: Self.contentHeight)
                .transition(morph)
        case .progress(let fraction, let label):
            ProgressRow(fraction: fraction, label: label)
                .frame(width: ProgressRow.width(label: label), height: Self.contentHeight)
                .transition(morph)
        case .launch:
            // The sparkle, and the room for the word opening to its right,
            // so the pair stays centred and the sparkle moves left as the
            // pill grows. The word hangs from the room's leading edge.
            HStack(spacing: 0) {
                LaunchSparkle(reveal: model.launchReveal)
                    .frame(width: Self.contentHeight, height: Self.contentHeight)
                Color.clear
                    .frame(width: CGFloat(model.launchGrow) * LaunchWord.room, height: Self.contentHeight)
                    .overlay(alignment: .leading) {
                        LaunchWord(reveal: model.launchWord)
                            .padding(.leading, LaunchWord.gap)
                    }
            }
            .transition(morph)
        }
    }
}

// The pill's ground: the composer's surface as a capsule of the given width
// at the pill's height, centred in the panel and scaled about its centre
// for the open and close. The view itself stays the panel's size, and the
// width and scale reach it every frame of an animation (Animatable, on this
// wrapper: SwiftUI does not interpolate a representable's own properties),
// so the capsule grows about the centre. SwiftUI animated a platform view's
// size but set its origin at once, so a capsule laid out by SwiftUI grew
// from its new left edge.
private struct PillSurface: View, Animatable {
    var width: CGFloat
    var scale: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, scale) }
        set {
            width = newValue.first
            scale = newValue.second
        }
    }

    var body: some View {
        PillSurfaceHost(size: NSSize(width: width * scale, height: DictationPill.height * scale))
    }
}

private struct PillSurfaceHost: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> PillSurfaceView {
        PillSurfaceView()
    }

    func updateNSView(_ view: PillSurfaceView, context: Context) {
        view.capsuleSize = size
    }
}

private final class PillSurfaceView: NSView {
    private let capsule = NSView()

    var capsuleSize: NSSize = .zero {
        didSet { layoutCapsule() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        installComposerSurface(in: capsule, radius: DictationPill.height / 2)
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutCapsule()
    }

    // The blur and fill are sized here, not by their autoresizing masks:
    // AppKit does not resize subviews out of a zero size, and the capsule is
    // zero at every open. Left to autoresizing, they stayed 0 by 0 while the
    // capsule grew to the mark's 46, so the mark state showed only the
    // layer's dark border over the desktop, until the morph to the bars
    // resized them from a non-zero width.
    private func layoutCapsule() {
        let size = capsuleSize
        capsule.isHidden = size.width < 0.5 || size.height < 0.5
        capsule.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        capsule.layer?.cornerRadius = size.height / 2
        for view in capsule.subviews {
            view.frame = capsule.bounds
        }
    }
}

extension Notification.Name {
    // The dictation pill's frame as it shows, or nil as it closes, so the
    // toast can stand above it (ToastPanel.avoid). Apart from composerFrame
    // so each clears only its own.
    static let dictationPillFrame = Notification.Name("SiriusDictationPillFrame")
}

// The Sirius mark as the pill opens: a template image (an SF Symbol) in the
// bars' blue, anything else in its own colours.
private struct MarkView: View {
    let image: NSImage?

    var body: some View {
        if let image {
            if image.isTemplate {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(pillBlue)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

// The download or warm-up: the label, a thin bar in the bars' blue and the
// percentage, on one line.
private struct ProgressRow: View {
    let fraction: Double
    let label: String
    private static let trackWidth: CGFloat = 64
    static let spacing: CGFloat = 9
    private static let percentWidth: CGFloat = 32
    static let fontSize: CGFloat = 12

    // The row's width, for the capsule's (PillView.pillWidth): the label's
    // as AppKit sets it in the same font, the bar and the percentage.
    static func width(label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let text = (label as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return text + spacing + trackWidth + spacing + percentWidth
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(label)
                .font(.system(size: Self.fontSize, weight: .medium))
                .foregroundColor(pillText)
                .lineLimit(1)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(pillBlue)
                    .frame(width: max(3, Self.trackWidth * fraction))
            }
            .frame(width: Self.trackWidth, height: 3)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: Self.fontSize, weight: .medium).monospacedDigit())
                .foregroundColor(pillText.opacity(0.7))
                .frame(width: Self.percentWidth, alignment: .trailing)
        }
    }
}

// The launch cue's sparkle: the menu bar's glyph in white, coming in from a
// blur with a little scale and opacity, as the onboarding's lockup does
// (OnboardingPages' lockup, OnboardingIntro's reveal).
// TODO(copy): the launch cue is a first pass.
private struct LaunchSparkle: View {
    let reveal: Double
    var color: Color = .white

    static let size: CGFloat = 15
    static let blurRadius: CGFloat = 6
    static let startScale: CGFloat = 0.85

    var body: some View {
        let r = CGFloat(reveal)
        Image(systemName: "sparkle")
            .font(.system(size: Self.size, weight: .medium))
            .foregroundColor(color)
            .scaleEffect(Self.startScale + (1 - Self.startScale) * r)
            .blur(radius: (1 - r) * Self.blurRadius)
            .opacity(reveal)
    }
}

// The launch cue's word, "Listening.", in the pill's
// text: the progress label's font, size and colour, at its gap from what it
// follows (ProgressRow). It comes in from a slight blur and rises a few
// points to its place, as the onboarding's lockup does (OnboardingPages'
// lockup); `reveal` 0 to 1.
// TODO(copy): the launch cue is a first pass.
private struct LaunchWord: View {
    let reveal: Double

    static let text = "Listening."
    static let gap = ProgressRow.spacing
    static let blurRadius: CGFloat = 4
    static let rise: CGFloat = 3

    // The word's width as AppKit sets it in the same font, and the room the
    // pill opens for it: the gap and the word.
    static let width: CGFloat = {
        let font = NSFont.systemFont(ofSize: ProgressRow.fontSize, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }()
    static var room: CGFloat { gap + width }

    var body: some View {
        let r = CGFloat(reveal)
        Text(Self.text)
            .font(.system(size: ProgressRow.fontSize, weight: .medium))
            .foregroundColor(pillText)
            .lineLimit(1)
            .fixedSize()
            .offset(y: (1 - r) * Self.rise)
            .blur(radius: (1 - r) * Self.blurRadius)
            .opacity(reveal)
    }
}

// The sparkle while the capture transcribes: the launch cue's, landed, in
// the bars' blue, and breathing between full and dim once the shrink has
// landed, so the pill reads as working without a spinner. A failure turns
// it red.
struct TranscribingSparkle: View {
    var failedAt: TimeInterval?

    // One breath, out and back in.
    static var period: TimeInterval { 1.6 * SpatialMotion.timeScale }
    static let dimmest = 0.5
    // The failure's red: how long it takes to come in, and its glow.
    static var redIn: TimeInterval { 0.2 * SpatialMotion.timeScale }
    static let red = Color(nsColor: .systemRed)
    static let redGlow: CGFloat = 4

    @State private var start = ProcessInfo.processInfo.systemUptime

    var body: some View {
        TimelineView(.animation) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let breath = Self.level(now - start)
            // 0 to 1 of the way to red, which comes in to full, out of
            // the breath.
            let red = failedAt.map { min(max((now - $0) / Self.redIn, 0), 1) } ?? 0
            ZStack {
                // In the bars' blue, so the ending sparkle matches the waves.
                LaunchSparkle(reveal: 1, color: pillBlue)
                    .opacity(1 - red)
                LaunchSparkle(reveal: 1, color: Self.red)
                    .opacity(red)
                    .shadow(color: Self.red.opacity(0.6 * red), radius: Self.redGlow * CGFloat(red))
            }
            .opacity(breath + (1 - breath) * red)
        }
    }

    // The sparkle's opacity `t` seconds after the release: full through the
    // shrink, then a cosine down to dimmest and back each period.
    static func level(_ t: TimeInterval) -> Double {
        let breathing = max(0, t - DictationPill.scaleDuration)
        let depth = (1 - cos(2 * .pi * breathing / period)) / 2
        return 1 - (1 - dimmest) * depth
    }
}
