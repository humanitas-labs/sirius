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
    func send(text: String, attachments: [URL], context: Message.Context?, to agent: String) async throws
}

extension ComposerTarget {
    func send(text: String, attachments: [URL], to agent: String) async throws {
        try await send(text: text, attachments: attachments, context: nil, to: agent)
    }
}

// ⌘⇧J opens the composer; sending closes it, and the
// agent answers with a toast. The current agent is remembered across launches.
// The shortcut can be rebound from the onboarding sheet (rebind),
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
    // What the app in front had open and selected when the composer
    // opened. The send reads that app again and sends the fresh answer,
    // or this copy when the reread fails (AmbientSendRead). The composer
    // says what it holds in one line (ContextLine).
    private var ambient = AmbientAttachment()
    // The icon of the app the opening read, and its favicon when its
    // bundle has one, for that line.
    private var contextIcon: NSImage?
    private var contextAppName: String?
    // The sensitive-app warning is showing: the next send goes.
    private var confirming = false
    private var contextFavicon: Data?
    // The watch on the app the opening read, and the one-read-at-a-time
    // rule for the reads its notices cause (startWatch).
    private var watch: Task<Void, Never>?
    private var rereads = AmbientRereads()
    // The monitor of the user's input to the app behind, while the line
    // shows context Sirius read itself (startInputWatch).
    private var inputWatch: Any?
    private var inputSettle: Task<Void, Never>?
    // Opens a watch on a provider. Replaced in tests.
    var watchContext: @Sendable (AmbientProvider) -> AsyncStream<AmbientWatchEvent> = { provider in
        AmbientClient(provider: provider).watch()
    }
    // The app the opening read, which the send reads again: the app behind
    // the composer, never Sirius. Nil when context is off, the user removed
    // it, or no app was behind.
    private var contextSource: (pid: Int32, bundleID: String)?
    // Reads the app in front: its process and bundle id in, its context or
    // nil out. Replaced in tests.
    var readContext: (_ pid: Int32, _ bundleID: String) async -> AmbientSnapshot? = { pid, bundleID in
        await FrontAppContext.read(pid: pid, bundleID: bundleID)
    }
    // Sent text still showing as the panel closes; cleared once it has gone,
    // or at once if the composer reopens first.
    private var sent = false
    // The app that was active before the composer opened, to return to.
    private var previous: NSRunningApplication?

    // The user's choice is stored only when they switch; a list from the
    // host that lacks it never replaces it. Each load used to put the first
    // listed agent in place of a choice the list lacked, and store it, so
    // Codex's sends went to Claude (2026.10.11).
    private static let lastAgentKey = SettingsKeys.lastAgent
    private var selection: AgentSelection
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

    init(target: ComposerTarget, defaults: UserDefaults = .standard) {
        self.target = target
        self.defaults = defaults
        selection = AgentSelection(chosen: defaults.string(forKey: Self.lastAgentKey))
        shortcut = Shortcuts.compose(in: defaults)
        panel.onSend = { [weak self] in self?.send() }
        panel.onNextAgent = { [weak self] in self?.nextAgent() }
        // Esc backs out of the warning first, then closes.
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.confirming { self.endWarning() } else { self.close() }
        }
        panel.onCancelWarning = { [weak self] in self?.endWarning() }
        panel.onAttach = { [weak self] urls in self?.attach(urls) }
        panel.onReturn = { [weak self] in self?.contextChanged() }
        panel.onRemoveContext = { [weak self] in
            guard let self else { return }
            self.endWarning()
            self.ambient.clear()
            self.contextSource = nil
            self.stopWatch()
            self.panel.setContext(nil)
            SiriusLog.composer.info("context removed")
        }
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
        sendWhenRead = false
        clearSent()
        let front = NSWorkspace.shared.frontmostApplication
        if front != .current { previous = front }
        refreshAgent()
        panel.present()
        loadContext(from: front)
        ComposerSignposts.event("focused")
        // Whether typing reaches it: a panel on screen but not key leaves
        // the keys with the app behind.
        if panel.isKeyWindow {
            SiriusLog.composer.info("composer opened")
        } else {
            SiriusLog.composer.error("composer opened but is not key; typing goes to \(front?.bundleIdentifier ?? "the app behind")")
        }
        Task { await loadAgents() }
    }

    // Asks the app that was in front what is open and selected, once per
    // opening and after the panel is up, so it never delays typing. Only
    // that app is asked, here and again at send (rereadContext). The answer
    // is dropped if the composer has closed, sent or been reopened since.
    private func loadContext(from front: NSRunningApplication?) {
        let ticket = ambient.begin()
        endWarning()
        contextSource = nil
        stopWatch()
        panel.setContext(nil)
        guard SettingsKeys.ambientContextEnabled(in: defaults), let front, front != .current,
              let bundleID = front.bundleIdentifier
        else { return ambient.clear() }
        let pid = front.processIdentifier
        contextSource = (pid, bundleID)
        contextIcon = front.icon
        contextAppName = front.localizedName
        contextFavicon = front.bundleURL.flatMap { AmbientFavicon.data(inBundle: $0, bundleID: bundleID) }
        // An app Sirius reads itself is known before it is read, so the
        // line names it at once and the read fills in the rest.
        let named = Self.readsItself(bundleID, defaults: defaults)
        if let named {
            panel.setContext(ContextLine.Model(subject: named, selection: nil, app: named, icon: contextIcon,
                                               favicon: contextFavicon, preview: nil))
        }
        let read = readContext
        Task { [weak self] in
            let answer = await read(pid, bundleID)
            guard let self else { return }
            let current = self.ambient.ticket == ticket
            guard self.ambient.accept(answer, ticket: ticket), let answer else {
                // Nothing to send after all: the name comes off the line.
                if current, named != nil { self.panel.setContext(nil) }
                if current, self.sendWhenRead { self.sendWhenRead = false; self.send() }
                return
            }
            self.showContext(answer)
            if self.sendWhenRead { self.sendWhenRead = false; self.send() }
            self.startWatch(on: answer.provider)
            // Ids and counts only: what was selected is never logged.
            let via = answer.provider.isNative ? " via accessibility" : answer.helper.map { " via helper \($0)" } ?? ""
            SiriusLog.composer.info("context from \(bundleID)\(via): \(answer.count) items")
        }
    }

    // The name of an app Sirius reads through Accessibility, when it is
    // switched on and Sirius may read it.
    static func readsItself(_ bundleID: String, defaults: UserDefaults) -> String? {
        guard let app = NativeApps.app(bundleID), NativeApps.isOn(app, in: defaults),
              ContextProviders.isOn(bundleID, in: defaults), AccessibilityReader.isTrusted else { return nil }
        return app.name
    }

    // While the composer is open the user can click into the app behind
    // it and select something else, which the send will read
    // (rereadContext). The line follows, so it says what will go, and it
    // learns of a change in two ways, never by asking on a timer:
    //  - the app says so. A provider that offers a watch (protocol 0.2.2,
    //    RFC-0006) is asked to say when its context changes, for as long
    //    as the composer shows it. It says only "changed"; the app is then
    //    read again, as at any other time.
    //  - the composer gets the keys back, which is the user returning
    //    from the app.
    //  - for an app Sirius reads itself (AccessibilityReader), which has
    //    no watch to offer: the user let go of the mouse button or a key
    //    in that app. A selection there changes no other way, so the app
    //    is read again a moment after each release (startInputWatch).
    // One watch, on the provider the opening read. It ends when the
    // composer closes, sends, or has its context removed. If it is lost
    // after it was held, it is opened once more and then left; the line
    // keeps what it last read and nothing is shown to the user.
    private func startWatch(on provider: AmbientProvider) {
        stopWatch()
        // A tree Sirius read itself has no endpoint to watch; the user's
        // own input to the app says when to read it again.
        if provider.isNative { return startInputWatch(pid: provider.descriptor.pid) }
        guard AmbientClient.offersWatch(provider.descriptor.protocol) else { return }
        let open = watchContext
        let app = provider.descriptor.app.id
        watch = Task { [weak self] in
            for attempt in 1...2 {
                var held = false
                for await event in open(provider) {
                    switch event {
                    case .acknowledged:
                        held = true
                        SiriusLog.composer.info("watching context from \(app)")
                    case .changed:
                        self?.contextChanged()
                    }
                }
                if Task.isCancelled { return }
                SiriusLog.composer.info("watch on \(app) ended (attempt \(attempt), held: \(held))")
                // One that was never held is not offered; do not ask again.
                guard held else { return }
            }
        }
    }

    // How long after a release the app is read: long enough for it to
    // have settled its selection.
    static let inputSettleDelay: Duration = .milliseconds(90)

    // Reads the app again after each mouse-up or key-up that went to it.
    // A global monitor sees only other apps' events, so typing in the
    // composer never counts, and nothing runs while the user does nothing.
    // Releases close together make one read (the settle task is replaced),
    // and reads are one at a time (AmbientRereads).
    private func startInputWatch(pid: Int32) {
        inputWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.inputSettle?.cancel()
                self.inputSettle = Task { [weak self] in
                    try? await Task.sleep(for: Self.inputSettleDelay)
                    guard !Task.isCancelled else { return }
                    self?.contextChanged()
                }
            }
        }
        if inputWatch != nil { SiriusLog.composer.info("following input to pid \(pid) for context") }
    }

    private func stopWatch() {
        watch?.cancel()
        watch = nil
        if let inputWatch { NSEvent.removeMonitor(inputWatch) }
        inputWatch = nil
        inputSettle?.cancel()
        inputSettle = nil
        rereads.reset()
    }

    // A reason to read the app again: its notice, or the composer coming
    // back to the keys. One read at a time (AmbientRereads).
    private func contextChanged() {
        if rereads.notice() { rereadForLine() }
    }

    // Nothing is read while a send is out, or once the context is removed;
    // an answer for an opening that has since ended is dropped (replace).
    private func rereadForLine() {
        guard !sending, !sent, let source = contextSource, SettingsKeys.ambientContextEnabled(in: defaults)
        else { return rereads.reset() }
        let ticket = ambient.ticket
        let read = readContext
        Task { [weak self] in
            let answer = await read(source.pid, source.bundleID)
            guard let self else { return }
            // A read that fails keeps the line as it was.
            if let answer, self.ambient.replace(answer, ticket: ticket) { self.showContext(answer) }
            if self.rereads.finished() { self.rereadForLine() }
        }
    }

    private func showContext(_ answer: AmbientSnapshot) {
        let summary = answer.summary
        let preview = answer.tree.selected.first?.text
        panel.setContext(ContextLine.Model(
            subject: summary.subject, selection: summary.selection, app: answer.appName, icon: contextIcon,
            favicon: contextFavicon,
            preview: preview
        ))
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
        endWarning()
        let previous = previous
        self.previous = nil
        stopWatch()
        // A read still on its way is no longer wanted; what is held stays
        // for the send that is closing the panel.
        if !sent {
            ambient.clear()
            contextSource = nil
        }
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
    // A spoken message that would carry context from an app marked
    // sensitive has no composer to warn in, so it is given one: the
    // composer opens on that agent with the words in it, and once the app
    // has been read the send is made, which shows the warning. Return
    // sends, Esc cancels and leaves the words. False when the composer is
    // already up with something of the user's in it.
    func confirmSpoken(_ text: String, to agent: String) -> Bool {
        guard !panel.isVisible else { return false }
        open()
        selection.choose(agent)
        refreshAgent()
        panel.insert(text)
        sendWhenRead = true
        return true
    }
    private var sendWhenRead = false

    func insertDictation(_ text: String) {
        clearSent()
        panel.insert(text)
    }

    private func endWarning() {
        guard confirming else { return }
        confirming = false
        panel.setWarning(app: nil)
    }

    private func clearSent() {
        guard sent else { return }
        sent = false
        panel.textView.string = ""
        attachments = []
        panel.setAttachments([])
        ambient.clear()
        contextSource = nil
        panel.setContext(nil)
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

    // The agent selector: ⌘/, Shift-Tab and a click on the logo step to
    // the next agent in place, and so does `/` during a dictating hold
    // (DictationService), composer open or not. No list or popover: people
    // have two to four agents. Returns the agent now selected; nil, with a
    // beep, when none is listed.
    @discardableResult
    func nextAgent() -> String? {
        guard let chosen = selection.next() else {
            NSSound.beep()
            return nil
        }
        defaults.set(chosen, forKey: Self.lastAgentKey)
        refreshAgent()
        return chosen
    }

    // Reads the agents again, as each open does: at each dictating press,
    // so a switch during the hold steps through the agents there are now.
    func reloadAgents() {
        Task { await loadAgents() }
    }

    private func send() {
        let text = panel.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty || !attachments.isEmpty else { return }
        // The selected agent or none: never another. A host without it
        // throws, which beeps below and keeps the text.
        guard let agent = current else { return NSSound.beep() }
        // Context from an app marked sensitive is warned about first: this
        // send only shows the warning, and the next one goes (D8).
        if let source = contextSource, ambient.snapshot != nil {
            if !confirming, ContextWarnings.shouldWarn(source.bundleID, declared: ambient.snapshot?.tree.sensitive == true,
                                                       in: defaults) {
                confirming = true
                let name = agents.first { $0.id == agent }?.name ?? agent
                panel.setWarning(app: contextAppName ?? ambient.snapshot?.appName, agent: name, icon: contextIcon)
                SiriusLog.composer.info("warned before sending context from \(source.bundleID)")
                return
            }
            if confirming, panel.dontWarnAgain {
                ContextWarnings.dismiss(source.bundleID, in: defaults)
                SiriusLog.composer.info("warnings off for \(source.bundleID)")
            }
        }
        endWarning()
        sending = true
        stopWatch()
        let files = attachments
        let held = ambient.snapshot
        // An opening read that has not answered yet is not waited for and
        // will not be accepted after this; the reread below replaces it.
        if held == nil { ambient.clear() }
        let reread = rereadContext()
        Task {
            defer { sending = false }
            let context = await sendContext(held: held, reread: reread)?.messageContext
            do {
                try await target.send(text: text, attachments: files, context: context, to: agent)
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

    // The read a send makes of the app the opening read: that app, not
    // Sirius, which is in front while the composer has the keys. Nil when
    // there is nothing to read again.
    private func rereadContext() -> (@Sendable () async -> AmbientSnapshot?)? {
        guard let source = contextSource, SettingsKeys.ambientContextEnabled(in: defaults) else { return nil }
        let read = readContext
        return { await read(source.pid, source.bundleID) }
    }

    // The context a send carries: the reread's answer, or the copy from the
    // opening when the reread fails or is slow (issue 0010).
    private func sendContext(
        held: AmbientSnapshot?, reread: (@Sendable () async -> AmbientSnapshot?)?
    ) async -> AmbientSnapshot? {
        guard let reread else { return held }
        let started = ContinuousClock.now
        let fresh = await AmbientSendRead.resolve(held: nil, read: reread)
        let elapsed = ContinuousClock.now - started
        // Ids and counts only: what was selected is never logged.
        if let fresh {
            SiriusLog.composer.info("context reread at send: \(fresh.count) items in \(elapsed)")
            return fresh
        }
        SiriusLog.composer.info("context reread at send gave nothing after \(elapsed); sending the copy from the opening")
        return held
    }
}
