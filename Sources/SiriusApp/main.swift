import AppKit
import ParrotCore
import SiriusAdapters
import SiriusCore

// The app's own socket, for the CLI and the live tests. Not a registered
// agent: nothing runs behind it, and AgentHost skips a registration with this id.
let devAgent = "dev"

// Top-level code runs on the main thread but is not main-actor isolated in
// Swift 5 mode. app.run() never returns, so the locals here live as long as
// the app.
// Prints the agent argv for scripts/compat-test.sh and exits.
AgentArgsPreview.runIfRequested()

MainActor.assumeIsolated {
    // A menu-bar app: no Dock icon, no main window (LSUIElement in Info.plist).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Renders the onboarding's pages and exits, before anything else starts.
    OnboardingSnapshots.runIfRequested()
    ComposerSnapshots.runIfRequested()
    LaunchSnapshots.runIfRequested()
    DictationSnapshots.runIfRequested()
    ToastSnapshots.runIfRequested()
    LaunchSound.renderIfRequested()

    // Diagnostics to the unified log and ~/Library/Logs/Sirius/sirius.log,
    // which a tester can send; stderr is /dev/null under launchd.
    SiriusLog.mirror(to: .standard())
    let info = Bundle.main.infoDictionary
    SiriusLog.app.info("launched: \(info?["CFBundleShortVersionString"] as? String ?? "?") "
        + "(\(info?["CFBundleVersion"] as? String ?? "?")), pid \(ProcessInfo.processInfo.processIdentifier)")
    // The end-to-end update test's check, in a test build with a local feed
    // only; before the socket server, so it runs beside an installed Sirius.
    Updater.runLocalCheckIfRequested()

    // Each agent's logo, from its registry folder, for the toast.
    let toasts = ToastPresenter(mark: { agent in AgentMarks.mark(agent: agent) })
    // "dev" has no default voice; the registry will pass each agent's.
    let speech = SpeechPresenter(agentVoice: { _ in nil })
    let notifications = NotificationPresenter()
    let queue = AppCommandQueue(toasts: toasts, notifications: notifications, speech: speech)
    // Files each registered agent's commands in its log before the presenters see them.
    let commands = LoggingCommandQueue(inner: queue)

    // One instance per user: the server takes $TMPDIR/sirius/sirius.lock, and
    // a second app exits before showing anything.
    let server: SocketServer
    do {
        server = try SocketServer(commands: commands)
        let socket = try server.add(agent: devAgent)
        SiriusLog.app.info("\(devAgent) listening on \(socket)")
    } catch SocketServerError.alreadyRunning {
        SiriusLog.app.info("already running; this copy exits")
        exit(0)
    } catch {
        SiriusLog.app.error("could not start the socket server: \(error)")
        exit(1)
    }
    // The registered agents (~/.agents/registry, or $SIRIUS_REGISTRY_DIR),
    // each started warm in its root.
    // An agent that fails to start or to finish a turn says so in Notification Center.
    // Sirius's own notices about an agent (e.g. "Resent 3 messages" after a
    // restart, #1) are toasts under its mark. A failure the user can act on
    // (e.g. "Claude Code is too old for Sirius") is a toast that stays until clicked.
    let host = AgentHost(server: server, commands: commands, alert: { title, body in
        Task { @MainActor in _ = await notifications.post(title: title, body: body) }
    }, notice: { agent, text in
        Task { @MainActor in _ = toasts.enqueue(agent: agent, text: text, alert: false) }
    }, problem: { agent, text in
        Task { @MainActor in _ = toasts.enqueue(agent: agent, text: text, alert: true) }
    })
    // With an agent registered, the agents start now; otherwise once the
    // onboarding's agents step saves one (below).
    let registry = AgentRegistry(directory: AgentHost.registryDirectory())
    let agentsRegistered = !registry.loadAll().agents.isEmpty
    // The launch cue (LaunchCuePresenter) waits on the agents' warm start.
    let launchCue = LaunchCuePresenter(waitsForAgents: agentsRegistered)
    if agentsRegistered {
        Task.detached {
            await host.start()
            await MainActor.run { launchCue.agentsStarted() }
        }
    }

    // On an orderly quit: stop every agent (they must not outlive Sirius),
    // then unlink the sockets and release the lock. The main thread waits,
    // bounded, since nothing after willTerminate runs the run loop again.
    let termination = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await host.stopAll()
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            SiriusLog.agents.error("agents did not stop within 10 s")
        }
        server.close()
    }

    // AppKit posts willTerminate only for its own quit, not a raw SIGTERM
    // (dev-install.sh's pkill, launchd, kill), whose default action ends the
    // process at once and leaves the agents running (#2). Turn it into an
    // orderly quit so the observer above stops them.
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { MainActor.assumeIsolated { app.terminate(nil) } }
    sigterm.resume()

    DevDemo.runIfRequested(queue: queue)

    // ⌘⇧J opens the composer.
    let composerTarget = HostComposerTarget(host: host)
    let composer = ComposerController(target: composerTarget)
    DevDemo.openComposer = { composer.open() }
    // A shortcut that cannot be had says so and stays until clicked; the
    // menu's Compose still opens the composer.
    composer.onShortcutUnavailable = { combo in
        DispatchQueue.main.async {
            _ = toasts.enqueue(agent: "sirius", text: Shortcuts.takenMessage(KeyComboText.string(combo)), alert: true)
        }
    }
    composer.registerShortcut()
    DevDemo.closeComposer = { composer.close() }

    // Hold fn anywhere to dictate (dictation.md): a command for an agent, or
    // into the composer while it is open. Hold ⌃fn to paste at the cursor
    // instead.
    // Asks for no grant; setup does. Owns fn even while Parrot.app runs.
    let dictationAgents = DictationAgents(target: composerTarget)
    composer.onAgents = { dictationAgents.set($0) }
    let delivery = SiriusDelivery(composer: composer, target: composerTarget, agents: { dictationAgents.addresses })
    let dictation = DictationService(
        delivery: delivery,
        model: DictationModel(),
        agents: dictationAgents,
        composer: composer
    )
    dictation.start()
    // whisper-base.en, downloaded and loaded now, out of sight, as Parrot
    // does at launch; a press before it is in shows "Preparing speech…".
    dictation.prepareModel()
    launchCue.attach(dictation)

    // The onboarding opens by itself on first launch:
    // no agent registered, or never been through. Saving its agents step
    // starts them, or reloads them. "Settings…" opens it again.
    let onboarding = OnboardingWindow(registry: registry, dictation: dictation,
                                      shortcuts: .live(composer: composer, dictation: dictation),
                                      onSave: { Task.detached { await host.reload() } },
                                      selectAgent: { composer.select(agent: $0) })
    // Its last page's guided first turn: the hold, the message (sent in a
    // throwaway session with the first-turn instruction), the reply's
    // toast, then the composer opening, which it dissolves behind.
    dictation.onHold = { onboarding.dictationHold(began: $0) }
    delivery.firstTurn = { text, agent in
        guard onboarding.takesFirstTurn else { return false }
        let name = dictationAgents.agents.first { $0.id == agent }?.name ?? agent
        onboarding.firstTurnSending(text: text, agent: agent, name: name)
        try await composerTarget.sendFirstTurn(text: text, to: agent)
        return true
    }
    toasts.onToast = { onboarding.toastArrived(from: $0) }
    composer.onOpen = { onboarding.composerOpened() }
    let onboardingShown = onboarding.showIfNeeded()
    // The pill on the sparkle while Sirius wakes, once the run loop is up;
    // not over the onboarding's own opening.
    DispatchQueue.main.async { launchCue.begin(onboardingShown: onboardingShown) }
    // A debug path for checking the window's system frame in the real app:
    // `Sirius --show-setup` opens it at the agents step, as "Settings…".
    if CommandLine.arguments.contains("--show-setup") {
        DispatchQueue.main.async {
            onboarding.show(at: .agents)
            for window in app.windows where window.isVisible {
                let layer = window.contentView?.layer
                SiriusLog.app.info(String(format: "--show-setup: %@ styleMask=%lu opaque=%d shadow=%d radius=%.0f border=%.1f %@",
                                          window.className, window.styleMask.rawValue, window.isOpaque, window.hasShadow,
                                          layer?.cornerRadius ?? 0, layer?.borderWidth ?? 0,
                                          layer?.borderColor.map { "\($0)" } ?? "none"))
            }
        }
    }

    // NSApplication holds its delegate weakly; the local keeps it alive.
    let delegate = AppDelegate(queue: queue, openOnboarding: { step in onboarding.show(at: step) },
                               openComposer: { composer.open() }, composeShortcut: { composer.shortcut })
    app.delegate = delegate
    app.run()
    withExtendedLifetime((termination, sigterm, composer, dictation, onboarding, launchCue)) {}
}
