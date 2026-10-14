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
public actor AgentHost {
    // What the factory gets to build one agent's adapter.
    public struct AdapterContext: Sendable {
        public var registration: AgentRegistration
        // The agent's SIRIUS_SOCKET.
        public var socketPath: String
        // Holds sirius and sirius-mcp.
        public var helpersDirectory: URL
        // The agent's instructions.md with what it includes (Instructions).
        public var instructions: String?
        // workers.md, for Codex's worker agents.
        public var workerInstructions: String? = nil
        // The throwaway session of the user's first turn (sendFirstTurn):
        // `instructions` already carry the first-turn instruction, and
        // Claude's process goes without the agent's session name.
        public var firstTurn = false
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
        var state: AgentSummary.State
    }

    // Sorted by id, as the registry returns them.
    private var order: [String] = []
    private var hosted: [String: Hosted] = [:]
    private var started = false
    private var stopped = false

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

    // The registry, after seeding the instructions of any agent without them.
    private func scanRegistry() -> RegistryScan {
        let scan = registry.loadAll()
        guard registry.seedInstructions(for: scan.agents, templates: templatesDirectory, report: report) else {
            return scan
        }
        return registry.loadAll()
    }

    // ClaudeAdapter for claude-code, CodexAdapter for codex.
    public static func makeDefaultAdapter(_ context: AdapterContext) -> any Adapter {
        switch context.registration.harness {
        case .claudeCode:
            ClaudeAdapter(registration: context.registration, socketPath: context.socketPath,
                          helpersDirectory: context.helpersDirectory, systemPrompt: context.instructions,
                          named: !context.firstTurn)
        case .codex:
            CodexAdapter(registration: context.registration, socketPath: context.socketPath,
                         helpersDirectory: context.helpersDirectory, instructions: context.instructions,
                         workerInstructions: context.workerInstructions)
        }
    }

    // MARK: Lifecycle

    // Loads the registry, sets up every valid agent, then starts them all
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
        for entry in scan.agents {
            setUp(entry)
        }
        await warm(order)
    }

    // After setup has written the registry: starts the host if it has
    // not started, else sets up agents that are new and restarts those whose
    // registration changed, each warm. A changed root also starts a new
    // session, since the old one belongs to the old folder. Agents that are
    // unchanged keep running; a removed folder leaves its agent as it is.
    public func reload() async {
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
                server.remove(agent: id)
                commands.unregister(agent: id)
                hosted[id] = nil
                order.removeAll { $0 == id }
                if current.entry.registration.root != entry.registration.root {
                    try? current.storage.writeState(AgentState())
                }
            }
            setUp(entry)
            if hosted[id] != nil { changed.append(id) }
        }
        order.sort()
        await warm(changed)
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
                guard hosted[id]?.state == .starting else { continue }
                if let failure {
                    report("Sirius: \(id) did not start: \(failure)")
                    if let message {
                        problem(id, message)
                    } else if let name = hosted[id]?.entry.registration.name {
                        alert(name, Self.alertText(didNotStart: failure))
                    }
                    hosted[id]?.state = .failed(failure)
                } else {
                    hosted[id]?.state = .running
                }
            }
        }
    }

    // Stops every agent, marking a running turn interrupted (queued messages
    // stay in the log for the next start), and closes their sockets. The
    // "dev" socket and the server stay.
    public func stopAll() async {
        stopped = true
        let all = order.compactMap { id in hosted[id].map { (id, $0.queue) } }
        await withTaskGroup(of: Void.self) { group in
            for (_, queue) in all {
                group.addTask { await queue.stop() }
            }
        }
        for (id, _) in all {
            server.remove(agent: id)
            commands.unregister(agent: id)
            hosted[id]?.state = .stopped
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
                // TODO(andrew): a toast that offers to resend the cut-off turn
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
                                       onFailure: { alert(name, Self.alertText(failed: $0)) },
                                       onUserError: {
                                           report("Sirius: \(id): \($0)")
                                           problem(id, $0)
                                       })
            hosted[id] = Hosted(entry: entry, storage: storage, queue: queue, state: .starting)
            order.append(id)
        } catch {
            report("Sirius: \(id) skipped: \(error)")
        }
    }

    // What the user is told, bounded: the reasons can carry a stderr tail.
    // TODO(andrew): wording.
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
    public func agents() -> [AgentSummary] {
        order.compactMap { id in
            guard let hosted = hosted[id] else { return nil }
            let registration = hosted.entry.registration
            return AgentSummary(agent: id, name: registration.name, harness: registration.harness,
                                root: registration.root, state: hosted.state, fast: registration.fast == true)
        }
    }

    // Copies each attachment into the agent's attachments/<message>/, logs
    // the Message and queues it for the agent's next turn. Returns the
    // message id once queued, not when the turn runs.
    public func send(text: String, attachments: [URL], to agent: String) async throws -> String {
        guard let hosted = hosted[agent] else { throw AgentHostError.unknownAgent(agent) }
        let id = MessageID.make()
        var copied: [Message.Attachment] = []
        for source in attachments {
            copied.append(try hosted.storage.addAttachment(copying: source, to: id,
                                                           mimeType: Self.mimeType(of: source)))
        }
        try await hosted.queue.send(Message(id: id, agent: agent, text: text, attachments: copied))
        return id
    }

    // MARK: The first turn

    // What the user's first message through Sirius gets beside the agent's
    // own instructions (the spec's guided first turn).
    public static let firstTurnInstruction = "This is the user's first message through Sirius, a voice interface. Reply in 2–3 short spoken-style sentences, no lists or markdown, saying what you can help with from here."

    // The agent's instructions with the first-turn instruction after them.
    public static func firstTurnInstructions(_ instructions: String?) -> String {
        guard let instructions, !instructions.isEmpty else { return firstTurnInstruction }
        return instructions + "\n\n" + firstTurnInstruction
    }

    // The onboarding's guided first turn. Neither harness can scope an
    // instruction to one turn (Claude's --append-system-prompt is fixed when
    // its process starts; Codex's developer instructions stay in the
    // thread), so the turn runs in a throwaway session: a fresh adapter on
    // the agent's socket, in its folder, with firstTurnInstructions, started
    // with no session to resume, given `text` exactly as the user said it,
    // and stopped once the turn ends. The reply reaches the user as the
    // agent's ordinary toast. The agent's regular session is left alone and
    // never resumes this one; the turn is not in the agent's log. Returns
    // the message id at once; the turn runs on.
    public func sendFirstTurn(text: String, to agent: String) throws -> String {
        guard let hosted = hosted[agent] else { throw AgentHostError.unknownAgent(agent) }
        let socketPath = try server.socketPath(for: agent)
        let context = AdapterContext(
            registration: hosted.entry.registration, socketPath: socketPath, helpersDirectory: helpersDirectory,
            instructions: Self.firstTurnInstructions(hosted.entry.instructions),
            workerInstructions: hosted.entry.workerInstructions, firstTurn: true)
        let adapter = makeAdapter(context)
        let message = Message(id: MessageID.make(), agent: agent, text: text)
        let report = report
        Task {
            do {
                _ = try await adapter.start(session: nil)
                let end = try await adapter.deliver(message)
                if case .failed(let reason) = end.outcome {
                    report("Sirius: \(agent): the first turn failed: \(reason)")
                }
            } catch {
                report("Sirius: \(agent): the first turn did not run: \(error)")
            }
            await adapter.stop()
        }
        return message.id
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

    // Whether the agent process is up. Whether a turn is running is not
    // tracked here.
    public enum State: Equatable, Sendable {
        // Warm start in flight.
        case starting
        // Started; messages go straight to it.
        case running
        // The warm start failed; the next message tries again.
        case failed(String)
        case stopped
    }

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
