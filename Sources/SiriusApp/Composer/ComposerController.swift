import AppKit
import Carbon.HIToolbox
import SiriusCore
import SiriusProtocol

// An agent the composer can send to.
struct ComposerAgent: Equatable, Sendable {
    let id: String
    let name: String
    let harness: AgentRegistration.Harness
    var fast = false
}

// Where the composer sends: the agent host once the app runs the registry.
@MainActor
protocol ComposerTarget: AnyObject {
    func composerAgents() async -> [ComposerAgent]
    func send(text: String, attachments: [URL], to agent: String) async throws
}

// ⌘⇧J opens the composer; sending closes it, and the
// agent answers with a toast. The current agent is remembered across launches.
// The shortcut can be rebound from the onboarding's last page (rebind),
// and is stored in UserDefaults (Shortcuts.composeKey).
@MainActor
final class ComposerController {
    private let target: ComposerTarget
    private let panel = ComposerPanel()
    private var hotKey: HotKey?
    private let defaults: UserDefaults
    // The shortcut registered, or to be registered once the recording ends.
    private(set) var shortcut: KeyCombo
    private var agents: [ComposerAgent] = []
    private var attachments: [URL] = []
    private var sending = false
    // Sent text still showing as the panel closes; cleared once it has gone,
    // or at once if the composer reopens first.
    private var sent = false
    // The app that was active before the composer opened, to return to.
    private var previous: NSRunningApplication?

    // The user's choice is stored only when they switch; a list from the
    // host that lacks it never replaces it. Each load used to put the first
    // listed agent in place of a choice the list lacked, and store it, so
    // Codex's sends went to Claude (2026.10.11).
    private static let lastAgentKey = "composer.lastAgent"
    private var selection = AgentSelection(chosen: UserDefaults.standard.string(forKey: lastAgentKey))
    private var current: String? { selection.current }

    // The agents as each open read them, for dictation's addresses
    // (SiriusDelivery), so a newly registered agent is addressable once the
    // composer has shown it.
    var onAgents: (([ComposerAgent]) -> Void)?

    // On screen and not closing: fn then dictates into it (dictation.md).
    var isOpen: Bool { panel.isOpen }

    // Open and taking the keyboard: a paste hold (⌃fn) then types into it
    // rather than into the app behind.
    var isFocused: Bool { panel.isOpen && panel.isKeyWindow }

    // The agent selected in the composer, remembered across launches, which
    // dictation with no agent's name goes to. The
    // first listed agent only while the user has never chosen one.
    var currentAgent: String? { current }

    // The waves at the composer's bottom centre, which a hold of fn with the
    // composer open drives in place of the pill (DictationService).
    var dictationWaves: DictationWavesModel { panel.waves }
    // Told once the composer has opened, by its shortcut or otherwise: the
    // onboarding's last page dissolves behind it.
    var onOpen: (() -> Void)?

    init(target: ComposerTarget, defaults: UserDefaults = .standard) {
        self.target = target
        self.defaults = defaults
        shortcut = Shortcuts.compose(in: defaults)
        panel.onSend = { [weak self] in self?.send() }
        panel.onNextAgent = { [weak self] in self?.nextAgent() }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onAttach = { [weak self] urls in self?.attach(urls) }
        panel.onRemoveAttachment = { [weak self] url in
            guard let self else { return }
            self.attachments.removeAll { $0 == url }
            self.panel.setAttachments(self.attachments)
        }
        DispatchQueue.main.async { [panel] in panel.prewarm() }
        // The agents ready before the first open, so it shows the right one.
        Task { await loadAgents() }
        hotKey = HotKey { [weak self] in self?.toggle() }
        if hotKey == nil { SiriusLog.hotkey.error("compose hotkey: the Carbon handler could not be installed") }
    }

    // Told when the shortcut could not be registered, at launch or when it
    // comes back after a recording: the composer is then reachable only
    // from the menu, and the user needs to know (a sticky toast).
    var onShortcutUnavailable: ((KeyCombo) -> Void)?

    // Whether the shortcut is registered now.
    var shortcutRegistered: Bool { hotKey?.registered == true }

    // Registers the shortcut, once the caller has set onShortcutUnavailable.
    // A failure used to go to stderr only, /dev/null under launchd.
    func registerShortcut() {
        let status = hotKey?.register(shortcut) ?? OSStatus(eventInternalErr)
        reportRegistration(status, of: shortcut)
    }

    private func reportRegistration(_ status: OSStatus, of combo: KeyCombo) {
        if status == noErr {
            SiriusLog.hotkey.info("compose hotkey registered \(KeyComboText.string(combo))")
        } else {
            SiriusLog.hotkey.error("compose hotkey \(KeyComboText.string(combo)) not registered (\(status)); "
                + "another app may own it")
            onShortcutUnavailable?(combo)
        }
    }

    // MARK: Rebinding

    enum Rebind: Equatable {
        case bound
        // Without ⌘, ⌃ or ⌥, and not an F-key.
        case needsModifier
        // One of macOS's own shortcuts (CopySymbolicHotKeys).
        case takenByMacOS
        // Another app's hot key (eventHotKeyExistsErr), or Carbon refused it.
        case takenByApp
    }

    // While a new shortcut is recorded, the current one is set aside, so
    // pressing it is recorded rather than opening the composer.
    func suspendShortcut() {
        hotKey?.unregister()
        SiriusLog.hotkey.info("compose hotkey \(KeyComboText.string(shortcut)) set aside")
    }

    func resumeShortcut() {
        guard let hotKey, !hotKey.registered else { return }
        reportRegistration(hotKey.register(shortcut), of: shortcut)
    }

    // Binds `combo` if it can be had; otherwise the old shortcut stays.
    func rebind(_ combo: KeyCombo) -> Rebind {
        guard combo.isAcceptable else { return .needsModifier }
        guard let hotKey else { return .takenByApp }
        if combo != shortcut, HotKey.symbolicHotKeys().contains(where: combo.clashes(withSymbolic:)) {
            return .takenByMacOS
        }
        let status = hotKey.register(combo)
        guard status == noErr else {
            SiriusLog.hotkey.error("\(KeyComboText.string(combo)) is taken (\(status)); keeping \(KeyComboText.string(shortcut))")
            let restored = hotKey.register(shortcut)
            if restored != noErr { reportRegistration(restored, of: shortcut) }
            return .takenByApp
        }
        shortcut = combo
        Shortcuts.setCompose(combo, in: defaults)
        SiriusLog.hotkey.info("compose hotkey registered \(KeyComboText.string(combo)) (rebound)")
        return .bound
    }

    func toggle() {
        panel.isVisible ? close() : open()
    }

    // Focus first: the panel shows and takes keys in
    // the hotkey's own run-loop turn, with the agents as the last open read
    // them; the host is asked afterwards, and the agent line updates if
    // they changed. An await before present waited behind any work on the
    // AgentHost actor.
    func open() {
        ComposerSignposts.event("open")
        clearSent()
        let front = NSWorkspace.shared.frontmostApplication
        if front != .current { previous = front }
        refreshAgent()
        panel.present()
        ComposerSignposts.event("focused")
        // Whether typing reaches it: a panel on screen but not key leaves
        // the keys with the app behind.
        if panel.isKeyWindow {
            SiriusLog.composer.info("composer opened")
        } else {
            SiriusLog.composer.error("composer opened but is not key; typing goes to \(front?.bundleIdentifier ?? "the app behind")")
        }
        onOpen?()
        Task { await loadAgents() }
    }

    // Selects `agent`, as the user's own switch would, and keeps it.
    func select(agent: String) {
        guard selection.choose(agent) else { return }
        UserDefaults.standard.set(agent, forKey: Self.lastAgentKey)
        refreshAgent()
    }

    // The registered agents, from the host; the composer's own copy is what
    // the next open shows at once.
    private func loadAgents() async {
        let loaded = await target.composerAgents()
        ComposerSignposts.event("agents")
        onAgents?(loaded)
        let before = (agents, current)
        agents = loaded
        selection.listed = loaded.map(\.id)
        if !selection.isListed, let current {
            SiriusLog.composer.error("composer: the selected agent \(current) is not among the \(loaded.count) listed; kept")
        }
        if before.0 != agents || before.1 != current { refreshAgent() }
    }

    func close(then gone: @escaping () -> Void = {}) {
        let previous = previous
        self.previous = nil
        panel.dismiss {
            // Only if Sirius still has focus; the user may have clicked elsewhere.
            if NSApp.isActive { previous?.activate() }
            gone()
        }
    }

    // Dictation with the composer open goes in at the caret rather than
    // being sent, so attachments and edits can follow;
    // the composer stays open and Enter sends as usual. Text from a send
    // still closing is cleared first, as a reopen would.
    func insertDictation(_ text: String) {
        clearSent()
        panel.insert(text)
    }

    private func clearSent() {
        guard sent else { return }
        sent = false
        panel.textView.string = ""
        attachments = []
        panel.setAttachments([])
    }

    // An agent the list lacks still shows, by its id: sends go to it and
    // fail loudly rather than reach another agent.
    private func refreshAgent() {
        let agent = agents.first { $0.id == current }
        panel.setAgent(name: agent?.name ?? current ?? "No agent", mark: current.flatMap { AgentMarks.mark(agent: $0) },
                       fast: agent?.fast == true)
    }

    private func attach(_ urls: [URL]) {
        attachments += urls.filter { !attachments.contains($0) }
        panel.setAttachments(attachments)
    }

    // ⌘/, Shift-Tab and a click on the logo step to the next agent in
    // place. No list or popover: people have two to four agents.
    private func nextAgent() {
        guard let chosen = selection.next() else { return NSSound.beep() }
        UserDefaults.standard.set(chosen, forKey: Self.lastAgentKey)
        refreshAgent()
    }

    private func send() {
        let text = panel.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty || !attachments.isEmpty else { return }
        // The selected agent or none: never another. A host without it
        // throws, which beeps below and keeps the text.
        guard let agent = current else { return NSSound.beep() }
        sending = true
        let files = attachments
        Task {
            defer { sending = false }
            do {
                try await target.send(text: text, attachments: files, to: agent)
                // The text stays in the field while it closes, and clears once
                // it has gone, so the send reads as one motion.
                sent = true
                close { [weak self] in self?.clearSent() }
            } catch {
                // The text stays so nothing typed is lost.
                SiriusLog.composer.error("send to \(agent) failed: \(error)")
                NSSound.beep()
            }
        }
    }
}

