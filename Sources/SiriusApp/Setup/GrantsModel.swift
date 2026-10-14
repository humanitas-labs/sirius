import AppKit
import SiriusCore

// Dictation's grants, Accessibility and Microphone, for the onboarding's
// permissions step: each with its own Allow button, so no system prompt
// appears before its button is pressed and the two never stack
// (Grants.allowSteps). Follows the grants live while the window is open:
// Accessibility has no change notification, so this polls, as Parrot's
// onboarding does. Moved from SetupWindow's DictationSection.
@MainActor
final class GrantsModel: ObservableObject {
    // How often the grants are re-read while the window is open.
    private static let pollInterval: TimeInterval = 1
    // The Accessibility prompt reports nothing when dismissed; the buttons
    // wait for Sirius to become active again, the grant, or this long.
    private static let promptTimeout: TimeInterval = 20

    @Published private(set) var state = Permissions.current
    @Published private(set) var prompting: Grant?
    // While Parrot.app runs, the step asks the user to quit it: Sirius owns
    // fn, so both would answer a press.
    @Published private(set) var parrotRunning = false

    // Set by simulate(_:): the state is the given one, never the system's.
    private var simulated = false
    private var promptExpiry: Timer?
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var parrot: ParrotPresence?

    var context: GrantContext {
        GrantContext(canRequestMicrophone: Permissions.canRequestMicrophone,
                     accessibilityPrompted: Permissions.accessibilityPrompted,
                     prompting: prompting)
    }

    func isGranted(_ grant: Grant) -> Bool { Grants.isGranted(grant, in: state) }

    // What its button does now: nothing (off), prompt, or open the pane.
    func steps(_ grant: Grant) -> [GrantStep] {
        Grants.allowSteps(for: grant, in: state, context: context)
    }

    // Follows the grants while the window is open.
    func start() {
        refresh()
        if parrot == nil {
            let parrot = ParrotPresence()
            parrot.onChange = { [weak self] running in self?.parrotRunning = running }
            parrotRunning = parrot.isRunning
            self.parrot = parrot
        }
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Back from the Accessibility prompt, or from System Settings.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.prompting == .accessibility { self.answered() }
                self.refresh()
            }
        }
    }

    // Once the window closes.
    func stop() {
        poll?.invalidate()
        poll = nil
        promptExpiry?.invalidate()
        promptExpiry = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        parrot?.stop()
        parrot = nil
    }

    func allow(_ grant: Grant) {
        let steps = steps(grant)
        if Grants.prompts(steps) {
            prompting = grant
            promptExpiry = Timer.scheduledTimer(withTimeInterval: Self.promptTimeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.answered() }
            }
        }
        for step in steps {
            Permissions.perform(step, answered: { [weak self] in self?.answered() })
        }
    }

    // The prompt is gone: both buttons are live again.
    private func answered() {
        prompting = nil
        promptExpiry?.invalidate()
        promptExpiry = nil
        refresh()
    }

    // A debug path (OnboardingSnapshots): shows `state` as the grants and
    // stops reading the system's. Nothing is asked of the system.
    func simulate(_ state: GrantState) {
        simulated = true
        self.state = state
    }

    private func refresh() {
        guard !simulated else { return }
        let now = Permissions.current
        if now != state { state = now }
        if let prompting, Grants.isGranted(prompting, in: now) { answered() }
    }
}
