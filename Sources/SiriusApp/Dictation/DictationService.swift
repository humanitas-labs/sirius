import AppKit
import ApplicationServices
import ParrotCore
import SiriusCore

// Hold fn anywhere, speak, release (dictation.md). Owns the fn tap
// (HoldMonitor), ParrotCore's capture and loop, the model and the pill;
// SiriusDelivery decides where each transcript goes. Hold ⌃ with it (⌃fn,
// HoldKey.pasteModifier) and the transcript is pasted at the cursor rather
// than sent to an agent; the pill shows a text-cursor
// glyph for those holds. The key held can be fn, right ⌥, right ⌘ or ⌃,
// chosen on the onboarding's last page and stored in UserDefaults
// (Shortcuts.holdKey); "fn" below means whichever it is.
//
// It never shows a system prompt: the grants are asked for only from
// setup's Allow buttons, as in Parrot's onboarding. Without
// Accessibility the tap waits, re-checking every 2 s, and starts once the
// grant appears. Without the microphone a press opens nothing and records
// nothing. Sirius owns fn whether or not Parrot.app runs: Parrot is being
// retired, and setup asks the user to quit it so one
// press never gives two results. The first press with no model on disk
// downloads whisper-base.en, with progress in the pill, and records
// nothing; the next press dictates. In practice
// the model is already coming: Sirius starts the download at launch, out of
// sight, as Parrot starts its own (prepareModel), and a press before it is
// in shows "Preparing speech…" with its progress in the pill. A model
// already on disk is loaded at launch too, so the first press is fast.
//
// With the composer open, a hold shows no pill: the composer's own waves
// come alive in place and go back to rest on release.
// Which one a hold drives is chosen as fn goes down and kept for that hold
// and its transcription, even if the composer closes meanwhile. The
// download and its preparing step still show in the pill, composer open or
// not: the composer has no place for a label and a percentage.
@MainActor
final class DictationService {
    enum Status: Equatable {
        // A grant is missing; the pill never opens.
        case off(Missing)
        // First press: the model is coming.
        case downloading(Double)
        case ready
    }

    enum Missing: Equatable { case accessibility, microphone }

    private(set) var status: Status = .off(.accessibility) {
        didSet {
            guard status != oldValue else { return }
            // Each new fraction is not worth a line.
            if case .downloading = status, case .downloading = oldValue {} else {
                SiriusLog.dictation.info("dictation: \(status)")
            }
            onStatus?(status)
        }
    }
    var onStatus: ((Status) -> Void)?
    // A dictating hold: true as it starts recording, false as it is
    // released or cancelled. For the onboarding's guided first turn.
    var onHold: ((Bool) -> Void)?

    // The pill's one line for the download and the load after it (CoreML
    // compiles the model once downloaded), from the spec.
    static let preparingLabel = "Preparing speech…"
    // How often the tap waits on the Accessibility grant is re-checked, as
    // Parrot's Daemon does. AXIsProcessTrusted never prompts.
    static let grantPoll: TimeInterval = 2

    private let delivery: SiriusDelivery
    private let model: DictationModel
    private let agents: DictationAgents
    private let composer: ComposerController
    // The Sirius mark as the pill opens (the Debug preview's).
    private let pill = DictationPill(mark: NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sirius"))
    // The pill or the composer's waves, whichever this hold drives.
    private lazy var surface = DictationSurface(pill: pill, waves: composer.dictationWaves)
    private let log = DictationLog()
    // Parrot's dictionary, shared: ~/.config/parrot/dictionary (dictation.md §2).
    private let dictionary = DictionaryStore()
    private let monitor: HoldMonitor
    private let defaults: UserDefaults
    // The key held to dictate.
    private(set) var holdKey: HoldKey
    // Made as the tap first starts: it prepares the input ahead of the first
    // press once the microphone is granted.
    private var capture: AudioCapture?
    private var controller: DictationController?
    private var listening = false
    private var running = false

    // The model loading, from disk as the tap starts or downloading on a
    // first press; nil until then, and again after a failed load.
    private var loading: Task<WhisperKitTranscriber, Error>?
    private var downloading = false
    // The load has finished, loaded or not.
    private var loadSettled = false
    // Called as each load finishes, loaded or not: for the launch cue.
    var onModelSettled: (() -> Void)?
    // Called on each press of the hold key, fn or ⌃fn: the launch cue's
    // sound stops if Glass has not landed.
    var onPress: (() -> Void)?
    private var downloaded = 0.0
    // The pill follows the download: off for the one started at launch,
    // until a press asks for it.
    private var pillShowsDownload = false
    // This press reached the controller, so its release goes there too. A
    // press that did not (no microphone, the model downloading) has its
    // release dropped.
    private var forwarding = false
    // What this hold does with its transcript: set as it is pressed, made
    // .paste if the chord's modifier joins late, and handed to the delivery
    // at release.
    private var mode: DictationMode = .agent

    private var grantTimer: Timer?
    private var tapFailureLogged = false
    private var microphoneLogged = false

    init(delivery: SiriusDelivery, model: DictationModel, agents: DictationAgents,
         composer: ComposerController, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holdKey = Shortcuts.holdKey(in: defaults)
        monitor = HoldMonitor(key: holdKey)
        self.delivery = delivery
        self.model = model
        self.agents = agents
        self.composer = composer
        // The pill opens on the logo of the agent the hold is going to.
        pill.destination = { [weak self] in self?.targetLogo() }
    }

    // The agent this hold's transcript goes to unless it names another, as
    // DictationDestination will send it, and its logo; nil, for the
    // sparkle, on a paste, into the open composer, or with no agent.
    private func targetLogo() -> NSImage? {
        DictationDestination.agent(mode: mode, composerOpen: composer.isOpen,
                                   selected: composer.currentAgent, agents: agents.addresses)
            .flatMap(Self.logo)
    }

    // The agent's logo as the composer shows it (AgentMarks, from its file),
    // or nil where AgentMarks falls back to its symbol sparkle: the pill
    // keeps its own blue one.
    static func logo(_ agent: String) -> NSImage? {
        guard let mark = AgentMarks.mark(agent: agent), !mark.isTemplate else { return nil }
        return mark
    }

    // Starts the tap once Accessibility is granted. Asks for nothing.
    func start() {
        guard !running else { return }
        running = true
        // HotkeyMonitor reports on the main thread. Followed as Parrot's
        // Daemon follows it; Sirius has no menu-bar status line, so it is
        // logged.
        monitor.onHealthChange = { health in
            SiriusLog.dictation.info("dictation: fn tap \(health)\(health.statusText.map { " (\($0))" } ?? "")")
        }
        agents.refresh()
        update()
    }

    func stop() {
        running = false
        stopListening()
        grantTimer?.invalidate()
        grantTimer = nil
    }

    // MARK: The tap

    // Listens when it can; otherwise says why and waits.
    private func update() {
        guard running else { return }
        guard AXIsProcessTrusted() else {
            status = .off(.accessibility)
            waitForGrant()
            return
        }
        if !listening { startListening() }
        refreshStatus()
    }

    private func startListening() {
        do {
            try monitor.start { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } catch {
            // Granted but the tap would not start (a grant for an older
            // signature, say): keep trying on the grant poll, logged once.
            if !tapFailureLogged {
                tapFailureLogged = true
                SiriusLog.dictation.error("dictation: the fn tap did not start: \(error); retrying")
            }
            waitForGrant()
            return
        }
        listening = true
        tapFailureLogged = false
        grantTimer?.invalidate()
        grantTimer = nil
        SiriusLog.dictation.info("dictation: listening on \(holdKey.glyph), \(holdKey.pasteGlyph) to paste")
        if capture == nil { capture = makeCapture() }
        // Load the model now if it is on disk and the microphone is granted,
        // so the first press is fast. Never a download unasked: that waits
        // for a press.
        if loading == nil, model.isOnDisk, Permissions.microphone == .granted {
            load(downloading: false)
        }
    }

    private func stopListening() {
        guard listening else { return }
        if forwarding {
            forwarding = false
            controller?.handle(.cancelled)
        }
        monitor.stop()
        listening = false
        SiriusLog.dictation.info("dictation: fn tap stopped")
    }

    private func waitForGrant() {
        guard grantTimer == nil else { return }
        let timer = Timer(timeInterval: Self.grantPoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        grantTimer = timer
    }

    private func refreshStatus() {
        guard AXIsProcessTrusted() else { return status = .off(.accessibility) }
        guard Permissions.microphone == .granted else { return status = .off(.microphone) }
        status = downloading ? .downloading(downloaded) : .ready
    }

    // Holds `key` to dictate from now on, and stores it. The tap follows
    // at once (HoldMonitor.setKey); a hold in progress is cancelled. The
    // paste chord follows the key (HoldKey.pasteModifier).
    func setHoldKey(_ key: HoldKey) {
        guard key != holdKey else { return }
        holdKey = key
        Shortcuts.setHoldKey(key, in: defaults)
        monitor.setKey(key)
        SiriusLog.dictation.info("dictation: hold \(key.glyph) to talk, \(key.pasteGlyph) to paste")
    }

    // MARK: Presses

    private func handle(_ event: HoldMonitor.Event) {
        switch event {
        case .pressed(let mode):
            // The pill takes over from the launch cue: the paths below that
            // open it morph straight from the sparkle; the rest close it.
            defer { pill.launchInterrupted() }
            onPress?()
            forwarding = false
            self.mode = mode
            // Who is addressable, read again for this transcript.
            agents.refresh()
            // Never a request from a press: the prompt belongs to setup.
            guard Permissions.microphone == .granted else {
                if !microphoneLogged {
                    microphoneLogged = true
                    SiriusLog.dictation.error("dictation: fn pressed without the microphone grant; nothing recorded (allow it in setup)")
                }
                status = .off(.microphone)
                return
            }
            microphoneLogged = false
            if loading == nil {
                if model.isOnDisk {
                    load(downloading: false)
                } else {
                    // The first press brings the model and records nothing.
                    load(downloading: true)
                    return
                }
            }
            if downloading {
                pillShowsDownload = true
                pill.progress(downloaded, label: Self.preparingLabel)
                return
            }
            refreshStatus()
            forwarding = true
            surface.route = DictationSurface.route(mode: mode, composerOpen: composer.isOpen,
                                                   composerFocused: composer.isFocused)
            pill.pastes = mode == .paste
            SiriusLog.dictation.info("dictation: \(mode == .paste ? "paste" : "agent") hold")
            loop().handle(.pressed)
            onHold?(true)
        case .paste:
            // ⌃ joined within the chord window: the recording carries on,
            // and its transcript is pasted.
            guard forwarding else { return }
            mode = .paste
            pill.pastes = true
            SiriusLog.dictation.info("dictation: paste hold")
        case .released:
            guard forwarding else { return }
            forwarding = false
            delivery.mode = mode
            controller?.handle(.released)
            onHold?(false)
        case .cancelled:
            guard forwarding else { return }
            forwarding = false
            controller?.handle(.cancelled)
            onHold?(false)
        }
    }

    // MARK: The loop

    private func makeCapture() -> AudioCapture {
        let capture = AudioCapture()
        let surface = self.surface
        capture.onLevel = { level in surface.level(level) }
        return capture
    }

    // ParrotCore's controller, built on the first dictating press. Its
    // transcriber waits for the load running now, so recording starts at
    // once even while the model is still loading.
    private func loop() -> DictationController {
        if let controller { return controller }
        let capture = self.capture ?? makeCapture()
        self.capture = capture
        let transcriber: Transcriber = loading.map { PendingTranscriber(modelID: model.model.id, load: $0) }
            ?? WhisperKitTranscriber(model: model.model)
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            processors: [DictionaryProcessor(store: dictionary)],
            observers: [surface, log],
            delivery: delivery,
            context: { [weak self] in self?.context() ?? TranscriptionContext() }
        )
        self.controller = controller
        return controller
    }

    // The dictionary's context, read at each release, with the agents'
    // names added to the vocabulary (dictation.md: "the agent names ... go
    // into the transcription prompt as vocabulary"). "dictate" went with the
    // Dictate paste mode.
    // The example sentences are Parrot's, from its settings.json, as the
    // dictionary is Parrot's.
    private func context() -> TranscriptionContext {
        var context = DictionaryContext(
            store: dictionary,
            language: DictionaryContext.language(of: model.model, setting: nil),
            examples: DictionaryContext.savedExamples()
        ).context()
        for word in agents.names where !context.vocabulary.contains(word) {
            context.vocabulary.append(word)
        }
        return context
    }

    // At launch: downloads the model if it is not on disk and loads it,
    // through the same load a first press runs, so the first press
    // dictates at once. Silent: the pill stays shut until a press asks.
    // Does nothing while a load runs or once one has finished.
    func prepareModel() {
        guard loading == nil else { return }
        load(downloading: !model.isOnDisk, pill: false)
    }

    // Whether a load from disk is running: the launch cue waits for it, but
    // not for a download (LaunchCuePresenter).
    var loadsFromDisk: Bool { loading != nil && !downloading && !loadSettled }

    // The launch cue in the pill (LaunchCuePresenter).
    func showLaunch(reduceMotion: Bool) { pill.showLaunch(reduceMotion: reduceMotion) }
    func endLaunch() { pill.endLaunch() }

    // Loads the model, downloading it first when `downloading`, with the
    // download's progress in the pill when `pill`. A failed load is
    // forgotten, so the next press tries again.
    private func load(downloading: Bool, pill showsPill: Bool = true) {
        self.downloading = downloading
        downloaded = 0
        pillShowsDownload = downloading && showsPill
        if downloading {
            SiriusLog.dictation.info("dictation: downloading \(model.model.id) (\(model.model.sizeMB) MB)")
            if pillShowsDownload { pill.progress(0, label: Self.preparingLabel) }
            refreshStatus()
        }
        let model = self.model
        let task = Task { @MainActor [weak self] in
            try await model.transcriber { fraction in
                Task { @MainActor in self?.progressed(fraction) }
            }
        }
        loading = task
        loadSettled = false
        Task { @MainActor [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let transcriber = try await task.value
                guard let self, self.loading == task else { return }
                SiriusLog.dictation.info("dictation: \(model.model.id) loaded in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - started))s")
                self.controller?.replaceTranscriber(transcriber)
                self.finishLoad()
            } catch {
                SiriusLog.dictation.error("dictation: \(model.model.id) did not load: \(error)")
                guard let self, self.loading == task else { return }
                self.loading = nil
                // The controller's transcriber waited on this load; the next
                // press builds it again with the next one.
                self.controller = nil
                self.finishLoad()
            }
        }
    }

    private func progressed(_ fraction: Double) {
        guard downloading else { return }
        downloaded = min(max(fraction, 0), 1)
        status = .downloading(downloaded)
        if pillShowsDownload {
            pill.progress(downloaded, label: Self.preparingLabel)
        }
    }

    private func finishLoad() {
        loadSettled = true
        defer { onModelSettled?() }
        if downloading {
            downloading = false
            if pillShowsDownload { pill.progress(nil, label: "") }
            pillShowsDownload = false
        }
        refreshStatus()
    }
}

// The controller's transcriber while the model loads: waits for the load,
// then transcribes with it. Replaced by the loaded transcriber once it is in.
private struct PendingTranscriber: Transcriber {
    let modelID: String
    let load: Task<WhisperKitTranscriber, Error>

    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript {
        try await load.value.transcribe(audio, context: context)
    }
}

// Where a hold shows: the pill, or the composer's waves when the composer
// was open as fn went down. It passes the loop's callbacks and the levels to
// the one chosen; DictationService sets `route` at each dictating press.
// The waves go back to rest on any end: delivered, empty, cancelled or
// failed. A transcription still running when the next hold starts ends on
// that hold's surface, as the pill always did.
@MainActor
final class DictationSurface: DictationObserver {
    enum Route: Equatable { case pill, composer }

    static func route(composerOpen: Bool) -> Route {
        composerOpen ? .composer : .pill
    }

    // A paste hold shows in the composer only when the composer has focus,
    // as its transcript goes there only then (DictationDestination).
    static func route(mode: DictationMode, composerOpen: Bool, composerFocused: Bool) -> Route {
        route(composerOpen: mode == .paste ? composerFocused : composerOpen)
    }

    var route: Route = .pill
    private let pill: DictationPill
    private let waves: DictationWavesModel

    init(pill: DictationPill, waves: DictationWavesModel) {
        self.pill = pill
        self.waves = waves
    }

    func dictationStarted() {
        switch route {
        case .pill: pill.dictationStarted()
        case .composer: waves.start()
        }
    }

    func dictationTranscribing() {
        switch route {
        case .pill: pill.dictationTranscribing()
        case .composer: waves.transcribing()
        }
    }

    func dictationFinished(_ result: DictationResult) {
        switch route {
        case .pill: pill.dictationFinished(result)
        case .composer: waves.idle()
        }
    }

    func dictationFailed(_ error: Error) {
        switch route {
        case .pill: pill.dictationFailed(error)
        case .composer: waves.idle()
        }
    }

    // From AudioCapture.onLevel, on capture's thread.
    nonisolated func level(_ value: Float) {
        Task { @MainActor in
            switch self.route {
            case .pill: self.pill.level(value)
            case .composer: self.waves.pushLevel(value)
            }
        }
    }
}

// Each dictation's counts and timings in the log, never its text.
@MainActor
private final class DictationLog: DictationObserver {
    func dictationFinished(_ result: DictationResult) {
        SiriusLog.dictation.info(String(format: "dictation: %.2fs of audio, %d chars, transcribed in %.2fs, delivered %.2fs after release",
                                        result.captureDuration, result.charCount, result.transcriptionTime, result.releaseToText))
    }

    func dictationFailed(_ error: Error) {
        SiriusLog.dictation.error("dictation: nothing delivered: \(error)")
    }
}
