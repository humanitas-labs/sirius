import AppKit
import Combine
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The first-run onboarding, the design frames' four pages (1 Welcome,
// 2 Agents, 3 Permissions, 4 Done) over the night sky (NightSky). It began
// as Parrot's (parrot Sources/ParrotApp/UI/OnboardingWindow.swift) and
// replaces the earlier SetupWindow.
//
// Opens at launch while Onboarding.showsWindow says so: no agent registered,
// or never been through. "Settings…" opens it at the agents step.
// The last page finishes with the guided first turn (frames A to E):
// holding fn there dims the rows under "Listening…" (B); the
// transcript replaces the subtitle and goes to the agent in a throwaway
// session with the first-turn instruction (C, AgentHost.sendFirstTurn);
// the reply lands as the agent's ordinary toast, or 30 s pass, and the
// page teaches the composer's shortcut (D). The composer opening, by its
// shortcut, ends it: the window dissolves behind it into normal use (E).
// Skip and Esc go straight to E; ⌘W closes it at once. Each
// counts as done; quitting with it open does not. The
// agents are written, and started, as the user leaves the agents step.
// The speech model downloads at launch, out of sight (DictationService);
// the onboarding never shows it.
@MainActor
final class OnboardingWindow {
    // The window's fixed size, the design frames'.
    static let size = NSSize(width: 760, height: 540)
    // The frames' corner, the composer's too. Kept over the system's
    // smaller one.
    static let radius: CGFloat = 32
    // The system's hairline for a dark window, drawn at that corner: the
    // composer's #171719 rim vanished against the sky.
    static let hairline = NSColor(white: 1, alpha: 0.16)

    private let registry: AgentRegistry
    private let detector: AgentDetector
    private let dictation: DictationService
    private let shortcuts: ShortcutsModel
    private let defaults: UserDefaults
    private let onSave: () -> Void
    // Selects an agent in the composer, so D's composer opens on the agent
    // that answered.
    private let selectAgent: (String) -> Void
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var keys: OnboardingKeys?
    // The guided first turn: the agent whose reply ends C, and the timer
    // that ends it without one.
    private var firstTurnAgent: String?
    private var firstTurnTimer: Timer?
    private var finishing = false

    // How long C waits for the reply, and B for the transcript after the
    // release, before moving on.
    static let replyTimeout: TimeInterval = 30
    static let transcriptTimeout: TimeInterval = 20
    // E: the window dissolves.
    static let dissolve: TimeInterval = 0.6
    private lazy var delegate = Delegate(owner: self)

    init(registry: AgentRegistry, dictation: DictationService, shortcuts: ShortcutsModel,
         detector: AgentDetector = AgentDetector(),
         defaults: UserDefaults = .standard, onSave: @escaping () -> Void,
         selectAgent: @escaping (String) -> Void = { _ in }) {
        self.registry = registry
        self.dictation = dictation
        self.shortcuts = shortcuts
        self.detector = detector
        self.defaults = defaults
        self.onSave = onSave
        self.selectAgent = selectAgent
    }

    var completed: Bool { defaults.bool(forKey: Onboarding.completedKey) }

    // At launch: opens at the first step when Onboarding.showsWindow says
    // so, and returns whether it did.
    @discardableResult
    func showIfNeeded() -> Bool {
        let hasAgents = !registry.loadAll().agents.isEmpty
        guard Onboarding.showsWindow(hasAgents: hasAgents, completed: completed) else { return false }
        SiriusLog.onboarding.info("showing the onboarding")
        // Once the run loop is up, so activation brings the window forward.
        DispatchQueue.main.async { self.show(at: .welcome) }
        return true
    }

    // Opens the window at `step`, or brings it forward and moves there.
    func show(at step: OnboardingStep) {
        if let window, let model {
            model.step = step
            bringForward(window)
            return
        }
        let model = makeModel(step: step)
        self.model = model
        let window = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = Self.surface(around: OnboardingView(model: model))
        window.title = "Welcome to Sirius" // TODO(copy): copy
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        model.window = window
        self.window = window
        keys = OnboardingKeys(window: window, model: model)

        model.grants.start()
        for agent in model.agents { agent.detect() }
        bringForward(window)
        // The opening sequence, once per window, when it opens at the
        // welcome; at another, the welcome is shown at its end.
        if step == .welcome {
            model.intro.play(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            model.intro.finish()
        }
    }

    // The window's content: the composer's surface (installComposerSurface)
    // with the night sky over its glass and the page on that. The window
    // keeps the composer's light appearance for its shadow's rim
    // (applyComposerWindowShadow); the page is dark, so the checkboxes,
    // spinner and focus rings draw for the dark surface.
    //
    // The sky is opaque, as the reference's is, so the blur no longer shows
    // through; the surface still gives the rounded corner, its 1 pt rim
    // (a layer border, drawn above the sky, in the system's hairline rather
    // than the composer's) and the shape the shadow follows. The sky has its own hosting view, so the page's changes never
    // draw it again.
    static func surface(around page: OnboardingView) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        installComposerSurface(in: container, radius: radius)
        container.layer?.borderColor = hairline.cgColor
        let sky = NSHostingView(rootView: NightSky())
        sky.sizingOptions = []
        sky.frame = container.bounds
        sky.autoresizingMask = [.width, .height]
        container.addSubview(sky)
        let hosting = NSHostingView(rootView: page)
        // Keep the window its fixed size whatever the page asks for.
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(hosting)
        return container
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation can be refused; the window still
        // comes forward, as Parrot's does.
        window.orderFrontRegardless()
        // The shadow is taken from the content's alpha; once the rounded
        // surface has drawn, so it follows the 32 pt corner.
        window.displayIfNeeded()
        window.invalidateShadow()
        DispatchQueue.main.async { window.invalidateShadow() }
    }

    private func makeModel(step: OnboardingStep) -> OnboardingModel {
        let existing = registry.loadAll().agents
        let agents = AgentRegistration.Harness.allCases.map { harness in
            AgentChoice(harness: harness,
                        current: existing.first { $0.registration.harness == harness }?.registration,
                        detector: detector)
        }
        let model = OnboardingModel(step: step, agents: agents, shortcuts: shortcuts)
        model.saveAgents = { [weak self] in self?.saveAgents(agents) ?? false }
        model.finish = { [weak self] in self?.finish() }
        return model
    }

    // MARK: The guided first turn

    // Whether the next dictated message is the first turn: on the last page,
    // before an answer is awaited.
    var takesFirstTurn: Bool {
        guard window != nil, !finishing, let model, model.step == .done else { return false }
        return model.firstTurn.takesMessage
    }

    // A dictating hold: B as it starts; back to A if no transcript follows
    // the release (an empty one, or a failure).
    func dictationHold(began: Bool) {
        guard takesFirstTurn, let model else { return }
        firstTurnTimer?.invalidate()
        firstTurnTimer = nil
        if began {
            model.firstTurn = .listening
            return
        }
        firstTurnTimer = Timer.scheduledTimer(withTimeInterval: Self.transcriptTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, model.firstTurn == .listening else { return }
                model.firstTurn = .ready
            }
        }
    }

    // C: the transcript is going to `agent` (its id), shown as `name`.
    func firstTurnSending(text: String, agent: String, name: String) {
        guard takesFirstTurn, let model else { return }
        SiriusLog.onboarding.info("onboarding: the first turn goes to \(agent)")
        model.firstTurn = .answering(transcript: text, agent: name)
        firstTurnAgent = agent
        firstTurnTimer?.invalidate()
        firstTurnTimer = Timer.scheduledTimer(withTimeInterval: Self.replyTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                SiriusLog.onboarding.info("onboarding: no reply to the first turn within \(Int(Self.replyTimeout)) s")
                self?.replied()
            }
        }
    }

    // A toast from `agent`: the first turn's reply, if it is the one awaited.
    func toastArrived(from agent: String) {
        guard window != nil, firstTurnAgent == agent else { return }
        replied()
    }

    // D: the reply has landed, or its wait ran out. The composer is set on
    // the agent that answered, and the page asks for its shortcut.
    private func replied() {
        firstTurnTimer?.invalidate()
        firstTurnTimer = nil
        guard window != nil, !finishing, let model else { return }
        let next = model.firstTurn.replied
        guard next != model.firstTurn else { return }
        if let firstTurnAgent { selectAgent(firstTurnAgent) }
        SiriusLog.onboarding.info("onboarding: the first turn moves on to the composer")
        model.firstTurn = next
    }

    // The composer has opened, by its shortcut or otherwise: on the last
    // page, D's end or a step ahead of it, the window dissolves behind it.
    func composerOpened() {
        guard window != nil, model?.step == .done else { return }
        finish()
    }

    // E: done, and the window dissolves over 0.6 s.
    private func finish() {
        guard let window, !finishing else { return }
        finishing = true
        // A recording still running would keep the compose shortcut set aside.
        shortcuts.cancelRecording()
        firstTurnTimer?.invalidate()
        firstTurnTimer = nil
        defaults.set(true, forKey: Onboarding.completedKey)
        SiriusLog.onboarding.info("onboarding done")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dissolve
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.close() }
        })
    }

    // Writes each chosen agent; one left off keeps whatever is registered.
    // Then the host reloads, starting the agents warm. False, with an alert,
    // when one could not be written.
    private func saveAgents(_ agents: [AgentChoice]) -> Bool {
        var failures: [String] = []
        for agent in agents {
            guard let registration = agent.registration else { continue }
            do {
                try registry.write(registration)
            } catch {
                failures.append("\(registration.name): \(error)")
                continue
            }
            // Its harness's default mark, unless the folder has its own; a
            // failure here leaves the agent registered, with the default
            // still shown from the bundle.
            do {
                try registry.seedIcon(agent: registration.agent, harness: registration.harness,
                                      marks: AgentMarks.directory)
            } catch {
                SiriusLog.onboarding.error("\(registration.agent): couldn't copy its mark: \(error)")
            }
        }
        guard failures.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the agents" // TODO(copy): copy
            alert.informativeText = failures.joined(separator: "\n")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
        onSave()
        return true
    }

    // Closing by hand counts as done, as Parrot's; Skip has already said so.
    fileprivate func closedByUser() {
        if !completed { defaults.set(true, forKey: Onboarding.completedKey) }
    }

    fileprivate func closed() {
        shortcuts.cancelRecording()
        model?.grants.stop()
        model?.intro.stop()
        firstTurnTimer?.invalidate()
        firstTurnTimer = nil
        firstTurnAgent = nil
        finishing = false
        keys = nil
        model = nil
        window = nil
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        private weak var owner: OnboardingWindow?

        init(owner: OnboardingWindow) { self.owner = owner }

        // Asked only for a close by hand (OnboardingPanel.performClose), not
        // for `close()` from Skip or for quitting.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { owner?.closedByUser() }
            return true
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { owner?.closed() }
        }
    }
}

// The onboarding's window: borderless, as the composer, so the surface is
// all there is. A borderless window is neither key nor closable by itself:
// it takes keys, for the steps' keys (OnboardingKeys) and the folder pills,
// and closes by hand from Esc or ⌘W, asking its
// delegate first as the system close button would.
private final class OnboardingPanel: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        applyComposerWindowShadow(to: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    // The system's performClose beeps without a close button.
    override func performClose(_ sender: Any?) {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

    // ⌘W, which an accessory app's missing File menu would otherwise not
    // send.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// The steps' keys, wherever the focus is in the window: Return and → move
// on (nothing on the last step, which the first turn or Skip finishes), and
// Space too on the welcome, where nothing else takes it,
// ← goes back, to the welcome from the agents, and Esc closes it by hand,
// on every step. Return, → and ← wait for the welcome's opening sequence
// (OnboardingModel.takesInput); before it they do nothing, and without a
// beep. A local monitor rather than the page's
// shortcuts, so a focused control or a hidden button never takes them
// first; a sheet or the folder panel is another window and keeps its own.
@MainActor
final class OnboardingKeys {
    enum Key: Equatable {
        case next, back, close
        // Space: on, from the welcome only; elsewhere it presses the
        // focused control.
        case space
    }

    // Set once, on the main thread; removed as it goes.
    private nonisolated(unsafe) var monitor: Any?

    init(window: NSWindow, model: OnboardingModel) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            guard event.window === window, let key = Self.key(for: event) else { return event }
            // A shortcut being recorded takes every key, Esc included.
            if MainActor.assumeIsolated({ model?.shortcuts.isRecording == true }) { return event }
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                switch key {
                case .next: model?.next()
                case .back: model?.back()
                case .close: model?.close()
                case .space:
                    guard model?.step == .welcome else { return false }
                    model?.next()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // Return, Enter, →, ← and Esc, with no modifier but the arrows' own.
    nonisolated static func key(for event: NSEvent) -> Key? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return nil }
        return key(code: event.keyCode)
    }

    nonisolated static func key(code: UInt16) -> Key? {
        switch code {
        case 36, 76: .next // Return, Enter
        case 124: .next // →
        case 123: .back // ←
        case 53: .close // Esc
        case 49: .space
        default: nil
        }
    }
}

// The step shown, the agents, the grants, and the page's actions.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep
    // The last page's guided first turn.
    @Published var firstTurn: FirstTurn = .ready
    let agents: [AgentChoice]
    let shortcuts: ShortcutsModel
    let grants = GrantsModel()
    let intro = OnboardingIntro()
    weak var window: NSWindow?

    var saveAgents: () -> Bool = { true }
    // Skip, Esc and the end of the first turn: done, and the window
    // dissolves.
    var finish: () -> Void = {}

    private var forwarding: [AnyCancellable] = []

    init(step: OnboardingStep, agents: [AgentChoice], shortcuts: ShortcutsModel) {
        self.step = step
        self.agents = agents
        self.shortcuts = shortcuts
        // The page re-renders as any agent, grant or shortcut changes.
        let children = agents.map(\.objectWillChange) + [grants.objectWillChange, shortcuts.objectWillChange]
        forwarding = children.map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
        // The welcome moves on by itself, as → would; never from a later
        // page.
        intro.advance = { [weak self] in
            guard let self, self.step == .welcome else { return }
            self.next()
        }
    }

    // A click on the welcome, anywhere but a control: on, as →.
    func clickedBackground() {
        guard step == .welcome else { return }
        next()
    }

    var agentsChosen: Int { agents.filter { $0.registration != nil }.count }

    var canContinue: Bool { Onboarding.canContinue(from: step, agentsChosen: agentsChosen) }

    // Whether the page takes the user's moves between steps: not while the
    // welcome's opening sequence is still coming in (OnboardingIntro's
    // settle), nor once the first turn has begun.
    var takesInput: Bool { (step != .welcome || intro.settle > 0) && firstTurn == .ready }

    // Return and →: the next step. The last has none; the first turn or
    // Skip finishes it.
    func next() {
        guard takesInput, canContinue, let next = step.next else { return }
        if step == .agents, !saveAgents() { return }
        // Leaving the welcome ends its sequence.
        intro.finish()
        step = next
    }

    // Back and ←.
    func back() {
        guard takesInput, let previous = step.previous else { return }
        step = previous
    }

    // A step's dot: back straight there, or forward a step at a time as
    // Continue goes, stopping where Continue is held.
    func go(to target: OnboardingStep) {
        guard takesInput else { return }
        if target.rawValue < step.rawValue {
            step = target
            return
        }
        while step.rawValue < target.rawValue {
            let from = step
            next()
            if step == from { return }
        }
    }

    // Esc: straight to the end, as Skip.
    func close() {
        finish()
    }
}

// The first page's opening: the star, the wordmark and the
// tagline blur in and move up a little to their place (`reveal`), then the
// help button fades in (`settle`). About 1.6 s; then it holds and moves on
// to the agents by itself (`advance`, WelcomeTiming). It plays once per
// window, as it opens at the first page; opening at another shows the end,
// and never moves on. With Reduce Motion it is a plain fade: no blur, no
// move, and the same hold.
@MainActor
final class OnboardingIntro: ObservableObject {
    @Published var reveal: Double = 0
    @Published var settle: Double = 0

    // Before it starts, so the window is up and the first frame drawn.
    static let delay = WelcomeTiming.delay
    static let revealDuration = WelcomeTiming.reveal
    static let settleDuration = 0.4
    static let fadeDuration = WelcomeTiming.fade

    // Told once the lockup has held: the welcome moves on.
    var advance: () -> Void = {}

    // Ease out, sharpening fast and settling slowly.
    static let revealCurve = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: revealDuration)
    static let settleCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: settleDuration)

    private var task: Task<Void, Never>?

    func play(reduceMotion: Bool) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            func wait(_ seconds: Double) async -> Bool {
                try? await Task.sleep(for: .seconds(seconds))
                return !Task.isCancelled
            }
            guard await wait(Self.delay), let self else { return }
            if reduceMotion {
                withAnimation(.easeInOut(duration: Self.fadeDuration)) {
                    self.reveal = 1
                    self.settle = 1
                }
                guard await wait(Self.fadeDuration + WelcomeTiming.hold) else { return }
                self.advance()
                return
            }
            withAnimation(Self.revealCurve) { self.reveal = 1 }
            guard await wait(Self.revealDuration * 0.75) else { return }
            withAnimation(Self.settleCurve) { self.settle = 1 }
            guard await wait(Self.revealDuration * 0.25 + WelcomeTiming.hold) else { return }
            self.advance()
        }
    }

    // Straight to the end, as when the window opens at another page or
    // leaves the first before it is done.
    func finish() {
        stop()
        reveal = 1
        settle = 1
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

