import Foundation
import SiriusCore
import SiriusProtocol
import UniformTypeIdentifiers

// Runs the registered agents (architecture.md §3–§5). On start it loads the
// registry and, for each agent: opens its log (which marks a cut-off turn
// interrupted and re-queues messages that never reached the agent), files
// its commands in that log, binds its socket, builds the
// adapter for its harness and a turn queue, then starts the agent warm.
//
// The composer's seam is agents() and send(text:attachments:to:). The app
// calls stopAll() on quit so no agent outlives Sirius.
//
// It also keeps working memory in check (WorkingMemory): it seeds WMEM.md
// and gc.md beside the registry folder, and when WMEM.md is over the limit,
// at start and whenever the file changes, it sends a cleanup turn from
// Sirius itself to one agent whose instructions include it: the first by
// id, so one agent does it however many share the file.
public actor AgentHost {
    // What the factory gets to build one agent's adapter.
    public struct AdapterContext: Sendable {
        public var registration: AgentRegistration
        // The agent's SIRIUS_SOCKET.
        public var socketPath: String
        // Holds sirius, sirius-mcp and wmem.
        public var helpersDirectory: URL
        // The agent's instructions.md with what it includes (Instructions).
        public var instructions: String?
        // workers.md, for Codex's worker agents.
        public var workerInstructions: String? = nil
    }

    public typealias AdapterFactory = @Sendable (AdapterContext) -> any Adapter

    // The id the app's own "dev" socket uses; a registration with it is skipped.
    public static let reservedAgents: Set<String> = ["dev"]

    private let registry: AgentRegistry
    private let server: SocketServer
    private let commands: LoggingCommandQueue
    private let storageDirectory: URL
    private let helpersDirectory: URL
    private let templatesDirectory: URL
    private let makeAdapter: AdapterFactory
    private let report: @Sendable (String) -> Void
    private let alert: @Sendable (_ title: String, _ body: String) -> Void
    // A toast from Sirius itself, under the agent's mark.
    private let notice: @Sendable (_ agent: String, _ text: String) -> Void
    // A toast that stays until clicked, under the agent's mark: a failure
    // the user can act on (UserFacingError), e.g. a Claude Code too old to run.
    private let problem: @Sendable (_ agent: String, _ text: String) -> Void

    private struct Hosted {
        var entry: RegisteredAgent
        var storage: AgentStorage
        var queue: AgentTurnQueue
    }

    // Sorted by id, as the registry returns them.
    private var order: [String] = []
    private var hosted: [String: Hosted] = [:]
    private var started = false
    private var stopped = false
    // The reload in flight; the next waits for it, so two never interleave.
    private var reloading: Task<Void, Never>?
    // Agents moved to a new root whose old session could not be cleared.
    // Not started until it is.
    private var uncleared: Set<String> = []
    private var memoryTrigger = WorkingMemoryTrigger()
    private var memoryWatcher: FileWatcher?

    // `commands` must be the queue `server` was created with, so commands
    // arriving on the agents' sockets are logged.
    public init(registry: AgentRegistry = AgentRegistry(directory: AgentHost.registryDirectory()),
                server: SocketServer,
                commands: LoggingCommandQueue,
                storageDirectory: URL = AgentStorage.defaultBaseDirectory,
                helpersDirectory: URL = AgentHost.helpersDirectory(),
                templatesDirectory: URL = AgentHost.templatesDirectory(),
                makeAdapter: @escaping AdapterFactory = { AgentHost.makeDefaultAdapter($0) },
                report: @escaping @Sendable (String) -> Void = { SiriusLog.agents.info($0) },
                alert: @escaping @Sendable (_ title: String, _ body: String) -> Void = { _, _ in },
                notice: @escaping @Sendable (_ agent: String, _ text: String) -> Void = { _, _ in },
                problem: @escaping @Sendable (_ agent: String, _ text: String) -> Void = { _, _ in }) {
        self.registry = registry
        self.server = server
        self.commands = commands
        self.storageDirectory = storageDirectory
        self.helpersDirectory = helpersDirectory
        self.templatesDirectory = templatesDirectory
        self.makeAdapter = makeAdapter
        self.report = report
        self.alert = alert
        self.notice = notice
        self.problem = problem
    }

    // MARK: Locations

    // ~/.agents/registry, or $SIRIUS_REGISTRY_DIR when set (testing).
    public static func registryDirectory(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL {
        if let path = environment["SIRIUS_REGISTRY_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AgentRegistry.defaultDirectory
    }

    // Sirius.app/Contents/Helpers when running from the bundle; otherwise
    // the directory holding the running binary, where `swift build` puts
    // sirius and sirius-mcp beside it.
    public static func helpersDirectory(bundle: Bundle = .main) -> URL {
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        }
        let executable = bundle.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return executable.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    // The instructions template and a folder per harness:
    // Sirius.app/Contents/Resources/agent (scripts/build-app.sh copies
    // packaging/agent there).
    public static func templatesDirectory(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Resources/agent", isDirectory: true)
    }

    // ~/.agents, the registry folder's parent, which other tools share.
    var agentsDirectory: URL { registry.directory.deletingLastPathComponent() }

    // ~/.agents/sirius: WMEM.md, gc.md and the shared rules (toasts.md)
    // live here.
    var siriusDirectory: URL { SiriusFolder.directory(agents: agentsDirectory) }

    // The registry, after seeding the instructions of any agent without them,
    // and, once there is an agent, working memory and the shared rules the
    // instructions include. The registry is read again when anything was
    // written, so the instructions carry it.
    private func scanRegistry() -> RegistryScan {
        let scan = registry.loadAll()
        var wrote = false
        if !scan.agents.isEmpty {
            // Before the seeding, so a file that was directly in ~/.agents
            // is moved, not seeded again beside it.
            do {
                if try SiriusFolder.migrate(agents: agentsDirectory, agentFolders: scan.agents.map(\.directory)) {
                    wrote = true
                }
            } catch {
                report("Sirius: couldn't move its files into \(siriusDirectory.path): \(error)")
            }
            do {
                if try WorkingMemory.seed(into: siriusDirectory, templates: templatesDirectory) { wrote = true }
            } catch {
                report("Sirius: couldn't write working memory's templates: \(error)")
            }
            do {
                if try Instructions.refreshShared(into: siriusDirectory, templates: templatesDirectory) {
                    wrote = true
                }
            } catch {
                report("Sirius: couldn't write the shared instructions: \(error)")
            }
        }
        if registry.seedInstructions(for: scan.agents, templates: templatesDirectory, report: report) {
            wrote = true
        }
        // The manual: its copy at the fixed path, and one mention of it for
        // an agent whose instructions predate it. After the seeding, so a new
        // agent's instructions already carry the section.
        if !scan.agents.isEmpty {
            do {
                try Instructions.refreshManual(
                    into: storageDirectory.appendingPathComponent(Instructions.manual, isDirectory: true),
                    templates: templatesDirectory)
            } catch {
                report("Sirius: couldn't write the manual: \(error)")
            }
        }
        for agent in scan.agents {
            let marker = storageDirectory.appendingPathComponent(agent.registration.agent, isDirectory: true)
                .appendingPathComponent("manual-offered")
            do {
                if try Instructions.offerManual(folder: agent.directory, templates: templatesDirectory, marker: marker) {
                    wrote = true
                }
            } catch {
                report("Sirius: \(agent.registration.agent): couldn't add the manual to its instructions: \(error)")
            }
        }
        return wrote ? registry.loadAll() : scan
    }

    // ClaudeAdapter for claude-code, CodexAdapter for codex, MuseAdapter for
    // muse-code, ACPAdapter for cursor and antigravity. Muse has no worker
    // instructions: its subagents get the developer prompt of the host.
    public static func makeDefaultAdapter(_ context: AdapterContext) -> any Adapter {
        switch context.registration.harness {
        case .claudeCode:
            ClaudeAdapter(registration: context.registration, socketPath: context.socketPath,
                          helpersDirectory: context.helpersDirectory, systemPrompt: context.instructions)
        case .codex:
            CodexAdapter(registration: context.registration, socketPath: context.socketPath,
                         helpersDirectory: context.helpersDirectory, instructions: context.instructions,
                         workerInstructions: context.workerInstructions)
        case .museCode:
            MuseAdapter(registration: context.registration, socketPath: context.socketPath,
                        helpersDirectory: context.helpersDirectory, instructions: context.instructions)
        case .cursor:
            ACPAdapter(registration: context.registration, profile: .cursor, socketPath: context.socketPath,
                       helpersDirectory: context.helpersDirectory, instructions: context.instructions)
        case .antigravity:
            ACPAdapter(registration: context.registration, profile: .antigravity, socketPath: context.socketPath,
                       helpersDirectory: context.helpersDirectory, instructions: context.instructions)
        }
    }

    // MARK: Lifecycle

    // Loads the registry, sets up every valid agent that is on, then starts them all
    // warm in parallel and returns when every warm start has finished. Sends
    // are accepted as soon as an agent is set up, while it warms. Registry
    // and setup failures are reported and skipped, never fatal. Runs once.
    public func start() async {
        guard !started, !stopped else { return }
        started = true
        let scan = scanRegistry()
        for failure in scan.failures {
            report("Sirius: registry folder \(failure.folder) skipped: \(failure.error)")
        }
        for entry in scan.agents where entry.registration.isEnabled {
            setUp(entry)
        }
        await warm(order)
        watchWorkingMemory()
        await checkWorkingMemory()
    }

    // After setup has written the registry: starts the host if it has
    // not started, else sets up agents that are new and restarts those whose
    // registration changed, each warm. A changed root also starts a new
    // session, since the old one belongs to the old folder. An agent turned
    // off is stopped and taken out; one turned on starts warm. Agents that
    // are unchanged keep running; a removed folder leaves its agent as it is.
    // One at a time: a reload asked for while another runs waits its turn.
    public func reload() async {
        let earlier = reloading
        let task = Task {
            await earlier?.value
            await reloadOnce()
        }
        reloading = task
        await task.value
    }

    private func reloadOnce() async {
        guard !stopped else { return }
        guard started else { return await start() }
        let scan = scanRegistry()
        for failure in scan.failures {
            report("Sirius: registry folder \(failure.folder) skipped: \(failure.error)")
        }
        var changed: [String] = []
        for entry in scan.agents {
            let id = entry.registration.agent
            if let current = hosted[id] {
                guard current.entry != entry else { continue }
                await current.queue.stop()
                // stopAll() ran meanwhile: nothing is started after it.
                guard !stopped else { return }
                server.remove(agent: id)
                commands.unregister(agent: id)
                hosted[id] = nil
                order.removeAll { $0 == id }
                if current.entry.registration.root != entry.registration.root { uncleared.insert(id) }
            }
            if uncleared.contains(id) {
                // The stored session belongs to the old root.
                do {
                    try AgentStorage(agent: id, baseDirectory: storageDirectory).writeState(AgentState())
                    uncleared.remove(id)
                } catch {
                    report("Sirius: \(id) not started: its session from the old folder could not be cleared: \(error.localizedDescription)")
                    continue
                }
            }
            guard entry.registration.isEnabled else { continue }
            setUp(entry)
            if hosted[id] != nil { changed.append(id) }
        }
        order.sort()
        await warm(changed)
        await checkWorkingMemory()
    }

    // Starts the given agents warm in parallel; returns when all have finished.
    private func warm(_ ids: [String]) async {
        let queues = ids.compactMap { id in hosted[id].map { (id, $0.queue) } }
        // The failure, and what to tell the user of it when it says (UserFacingError).
        await withTaskGroup(of: (String, String?, String?).self) { group in
            for (id, queue) in queues {
                group.addTask {
                    do {
                        try await queue.warm()
                        return (id, nil, nil)
                    } catch {
                        return (id, "\(error)", (error as? UserFacingError)?.userMessage)
                    }
                }
            }
            for await (id, failure, message) in group {
                // Not for an agent stopped or replaced while it started.
                guard !stopped, let queue = queues.first(where: { $0.0 == id })?.1,
                      hosted[id]?.queue === queue else { continue }
                if let failure {
                    report("Sirius: \(id) did not start: \(failure)")
                    if let message {
                        problem(id, message)
                    } else if let name = hosted[id]?.entry.registration.name {
                        alert(name, Self.alertText(didNotStart: failure))
                    }
                }
            }
        }
    }

    // Stops every agent, marking a running turn interrupted (queued messages
    // stay in the log for the next start), and closes their sockets. The
    // "dev" socket and the server stay.
    public func stopAll() async {
        stopped = true
        memoryWatcher?.stop()
        memoryWatcher = nil
        let all = order.compactMap { id in hosted[id].map { (id, $0.queue) } }
        await withTaskGroup(of: Void.self) { group in
            for (_, queue) in all {
                group.addTask { await queue.stop() }
            }
        }
        for (id, _) in all {
            server.remove(agent: id)
            commands.unregister(agent: id)
        }
    }

    private func setUp(_ entry: RegisteredAgent) {
        let registration = entry.registration
        let id = registration.agent
        if Self.reservedAgents.contains(id) {
            report("Sirius: registry agent \"\(id)\" skipped: the id is reserved for the dev socket")
            return
        }
        do {
            let storage = try AgentStorage(agent: id, baseDirectory: storageDirectory)
            let log = try storage.openLog()
            if !log.recovered.isEmpty {
                report("Sirius: \(id): marked \(log.recovered.count) unfinished message(s) interrupted")
                // TODO(copy): a toast that offers to resend the cut-off turn
                // (#1, fix 2). It needs an action on the toast, which the toast
                // panel does not have yet; until then the turn stays interrupted.
            }
            if !log.requeued.isEmpty {
                report("Sirius: \(id): re-queued \(log.requeued.count) message(s) that never reached the agent")
                notice(id, Self.noticeText(resent: log.requeued.count))
            }
            commands.register(log, for: id)
            let socketPath: String
            do {
                socketPath = try server.add(agent: id)
            } catch {
                commands.unregister(agent: id)
                throw error
            }
            let context = AdapterContext(
                registration: registration, socketPath: socketPath, helpersDirectory: helpersDirectory,
                instructions: entry.instructions, workerInstructions: entry.workerInstructions)
            let alert = alert, name = registration.name, problem = problem, report = report
            let queue = AgentTurnQueue(adapter: makeAdapter(context), log: log, storage: storage,
                                       consolidation: ConsolidationPolicy(registration: registration),
                                       onFailure: { alert(name, Self.alertText(failed: $0)) },
                                       onUserError: {
                                           report("Sirius: \(id): \($0)")
                                           problem(id, $0)
                                       },
                                       report: { report("Sirius: \($0)") })
            commands.register(queue, for: id)
            hosted[id] = Hosted(entry: entry, storage: storage, queue: queue)
            order.append(id)
        } catch {
            report("Sirius: \(id) skipped: \(error)")
        }
    }

    // MARK: Working memory

    private func watchWorkingMemory() {
        guard memoryWatcher == nil else { return }
        let watcher = FileWatcher(file: siriusDirectory.appendingPathComponent(WorkingMemory.file)) { [weak self] in
            Task { await self?.checkWorkingMemory() }
        }
        watcher.start()
        memoryWatcher = watcher
    }

    // Sends the cleanup turn when WMEM.md is over the limit of the agent
    // that keeps it (WorkingMemoryTrigger says whether this crossing has had
    // one). Returns that agent when it sent.
    @discardableResult
    func checkWorkingMemory() async -> String? {
        guard !stopped else { return nil }
        let memory = siriusDirectory.appendingPathComponent(WorkingMemory.file)
        let text = (try? String(contentsOf: memory, encoding: .utf8)) ?? ""
        guard let id = order.first(where: { id in
            hosted[id].map { WorkingMemory.isIncluded(memory, agentFolder: $0.entry.directory) } ?? false
        }), let agent = hosted[id] else { return nil }
        let tokens = WorkingMemory.tokens(text)
        let limit = WorkingMemory.limit(agentFolder: agent.entry.directory)
        guard memoryTrigger.shouldAsk(tokens: tokens, limit: limit, cleaned: WorkingMemory.cleaned(text)) else {
            return nil
        }
        guard let cleanup = WorkingMemory.cleanupText(agentFolder: agent.entry.directory, agents: siriusDirectory,
                                                      templates: templatesDirectory) else {
            report("Sirius: \(id): working memory is over its limit, but there is no \(WorkingMemory.cleanup) to send")
            return nil
        }
        let message = Message(id: MessageID.make(), agent: id,
                              text: WorkingMemory.prompt(memory: memory, tokens: tokens, limit: limit,
                                                         cleanup: cleanup),
                              fromSirius: true)
        do {
            try await agent.queue.send(message)
            report("Sirius: \(id): working memory at ~\(tokens) tokens, over \(limit); asked it to clean up")
            return id
        } catch {
            report("Sirius: \(id): couldn't ask it to clean up working memory: \(error)")
            return nil
        }
    }

    // What the user is told, bounded: the reasons can carry a stderr tail.
    // TODO(copy): wording.
    static func alertText(didNotStart reason: String) -> String {
        "Didn't start: " + bounded(reason)
    }

    static func alertText(failed reason: String) -> String {
        "Couldn't finish: " + bounded(reason)
    }

    // The wording is issue #1's.
    static func noticeText(resent count: Int) -> String {
        count == 1 ? "Resent 1 message" : "Resent \(count) messages"
    }

    private static func bounded(_ reason: String) -> String {
        reason.count > 300 ? String(reason.prefix(300)) + "…" : reason
    }

    // MARK: The composer's seam

    // Every agent set up at start, sorted by id. Stopped ones stay listed.
    // Each one's state is asked of its queue, which alone knows it.
    public func agents() async -> [AgentSummary] {
        var summaries: [AgentSummary] = []
        for id in order {
            guard let hosted = hosted[id] else { continue }
            let registration = hosted.entry.registration
            summaries.append(AgentSummary(agent: id, name: registration.name, harness: registration.harness,
                                          root: registration.root, state: await hosted.queue.runState,
                                          fast: registration.isFast))
        }
        return summaries
    }

    // Copies each attachment into the agent's attachments/<message>/, logs
    // the Message and queues it for the agent's next turn. Returns the
    // message id once queued, not when the turn runs.
    // `context` is what the app in front had open and selected, when the
    // user sent it along (Message.Context).
    public func send(text: String, attachments: [URL], context: Message.Context? = nil,
                     to agent: String) async throws -> String {
        guard let hosted = hosted[agent] else { throw AgentHostError.unknownAgent(agent) }
        let id = MessageID.make()
        let copied = try hosted.storage.addAttachments(copying: attachments, to: id, mimeType: Self.mimeType(of:))
        do {
            try await hosted.queue.send(Message(id: id, agent: agent, text: text, attachments: copied,
                                                context: context))
        } catch {
            // Never logged, so nothing points at its attachments.
            hosted.storage.removeAttachments(of: id)
            throw error
        }
        return id
    }

    // The file's UTType's MIME type; application/octet-stream when it has none.
    static func mimeType(of url: URL) -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.preferredMIMEType ?? "application/octet-stream"
    }
}

// One registered agent as the composer shows it (AgentHost.agents()).
public struct AgentSummary: Equatable, Sendable {
    public var agent: String
    // The registration's display name.
    public var name: String
    public var harness: AgentRegistration.Harness
    public var root: String
    public var state: State
    // The registration's fast mode, shown as a bolt left of the logo.
    public var fast: Bool

    public typealias State = AgentTurnQueue.RunState

    public init(agent: String, name: String, harness: AgentRegistration.Harness, root: String, state: State,
                fast: Bool = false) {
        self.fast = fast
        self.agent = agent
        self.name = name
        self.harness = harness
        self.root = root
        self.state = state
    }
}

public enum AgentHostError: Error, Equatable, Sendable {
    case unknownAgent(String)
}
