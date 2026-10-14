import Foundation
import SiriusCore
import SiriusProtocol

// Codex through `codex app-server` (architecture.md §5.2).
// One warm app-server per agent, one thread, one turn per Message. The agent
// reaches the user through sirius-mcp, configured as the MCP server "sirius"
// with its tools approved, because Codex's sandbox without network access
// refuses socket connects from the agent's shell.
//
// start: spawn app-server in the root, initialize, then thread/start (or
//        thread/resume) with sandbox workspace-write and approvalPolicy
//        never; returns the thread id at once. The sandbox has network
//        access, set at launch (CodexLaunch.arguments): if Claude gets
//        network access, Codex does too.
// deliver: turn/start with the rendered text, plus each image attachment as
//        a localImage item; the turn ends on turn/completed.
// stop: close stdin, then terminate the process.
public actor CodexAdapter: Adapter {
    public nonisolated let registration: AgentRegistration
    public nonisolated let socketPath: String
    // Holds sirius and sirius-mcp: Sirius.app/Contents/Helpers.
    public nonisolated let helpersDirectory: URL
    // Given as developer instructions on every thread/start and thread/resume.
    public nonisolated let instructions: String?
    // Given to the worker agents it starts (CodexLaunch.arguments).
    public nonisolated let workerInstructions: String?

    private var server: CodexAppServer?
    private var thread: String?
    // The turn deliver() is waiting on, which steer() joins.
    private var activeTurn: String?
    // What thread/start or thread/resume reported.
    private var model: String?
    private var observer: (@Sendable (String) -> Void)?

    public init(registration: AgentRegistration, socketPath: String, helpersDirectory: URL,
                instructions: String? = nil, workerInstructions: String? = nil) {
        self.registration = registration
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
        self.instructions = instructions
        self.workerInstructions = workerInstructions
    }

    // Every JSON-RPC line, ">> " sent or "<< " received. Takes effect at the
    // next start. Tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        self.observer = observer
    }

    // The running app-server's pid, for tests.
    var processIdentifier: Int32? { server?.processIdentifier }

    public func start(session: String?) async throws -> AgentStart {
        await stop()
        let environment = ProcessInfo.processInfo.environment
        guard let executable = CodexLaunch.findExecutable(registered: registration.executable,
                                                          environment: environment) else {
            throw CodexAdapterError.codexNotFound(registration.executable)
        }
        let capabilities = await CodexProbe.shared.capabilities(executable: executable, environment: environment)
        guard !capabilities.isTooOld else { throw CodexAdapterError.tooOld(version: capabilities.version) }
        var childEnvironment = environment
        childEnvironment[SiriusEnvironment.socket] = socketPath
        let mcpHelper = helpersDirectory.appendingPathComponent("sirius-mcp").path
        let server = CodexAppServer(
            executable: URL(fileURLWithPath: executable),
            arguments: CodexLaunch.arguments(mcpHelper: mcpHelper, socketPath: socketPath,
                                             fast: registration.fast == true, workers: workerInstructions,
                                             capabilities: capabilities),
            environment: childEnvironment,
            directory: URL(fileURLWithPath: registration.root, isDirectory: true))
        if let observer { server.observe(observer) }
        try server.launch()
        self.server = server

        do {
            _ = try await server.request("initialize", .object([
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(Self.clientVersion)]),
            ]))
            try server.notify("initialized")
            let opened = try await openThread(on: server, resuming: session)
            thread = opened.id
            model = opened.model ?? registration.model
            return AgentStart(session: opened.id, model: model, effort: opened.effort ?? registration.effort)
        } catch {
            // Codex quit or refused as it started, e.g. at initialize on a
            // -c key it cannot read: say why, in its own first words.
            var why: String?
            switch error {
            case CodexAppServerError.rpc(_, let message): why = message
            case is CodexAppServerError: why = await server.firstStderrLine()
            default: break
            }
            await server.terminate()
            if self.server === server { self.server = nil }
            guard error is CodexAppServerError else { throw error }
            throw CodexAdapterError.startFailed(why ?? "\(error)", "\(error)")
        }
    }

    public func deliver(_ message: Message) async throws -> TurnEnd {
        guard let server, let thread else { throw CodexAdapterError.notStarted }
        let params = Self.turnParams(thread: thread, message: message, effort: registration.effort)
        let started = try await server.request("turn/start", .object(params))
        guard let turnId = started["turn"]?["id"]?.string else {
            throw CodexAdapterError.unexpectedResponse("turn/start returned no turn id")
        }
        activeTurn = turnId
        defer { if activeTurn == turnId { activeTurn = nil } }
        let turn = try await server.turnCompleted(turnId)
        switch turn["status"]?.string {
        case "completed":
            return TurnEnd(session: thread, outcome: .completed, model: model)
        case let status:
            let reason = turn["error"]?["message"]?.string ?? "turn \(status ?? "ended without a status")"
            return TurnEnd(session: thread, outcome: .failed(reason), model: model)
        }
    }

    // turn/steer (checked on 0.159.1): the message joins the
    // running turn as a userMessage the model reads at its next step, after
    // a running command finishes; one turn/completed still ends it. Codex
    // refuses with -32600 when no turn is active or another one is, as when
    // the turn has just ended: the queue then delivers it as its own turn.
    public func steer(_ message: Message) async -> Bool {
        guard let server, let thread, let activeTurn else { return false }
        do {
            _ = try await server.request("turn/steer", .object([
                "threadId": .string(thread),
                "expectedTurnId": .string(activeTurn),
                "input": .array(Self.input(for: message)),
            ]))
            return true
        } catch {
            return false
        }
    }

    public func stop() async {
        guard let server else { return }
        self.server = nil
        thread = nil
        model = nil
        await server.terminate()
    }

    // MARK: - Internals

    static let clientVersion = "0.1"

    private struct OpenedThread {
        var id: String
        var model: String?
        var effort: String?
    }

    // thread/start's params, and thread/resume's beside the thread id.
    static func threadParams(registration: AgentRegistration, instructions: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "cwd": .string(registration.root),
            "sandbox": .string("workspace-write"),
            "approvalPolicy": .string("never"),
        ]
        if let model = registration.model { params["model"] = .string(model) }
        if let instructions { params["developerInstructions"] = .string(instructions) }
        return params
    }

    // turn/start's params. Codex takes effort per turn, not per thread.
    static func turnParams(thread: String, message: Message, effort: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(thread),
            "input": .array(input(for: message)),
        ]
        if let effort { params["effort"] = .string(effort) }
        return params
    }

    private func openThread(on server: CodexAppServer, resuming session: String?) async throws -> OpenedThread {
        let params = Self.threadParams(registration: registration, instructions: instructions)
        if let session {
            var resume = params
            resume["threadId"] = .string(session)
            do {
                return try opened(try await server.request("thread/resume", .object(resume)))
            } catch CodexAppServerError.rpc {
                // The thread is gone (deleted, or a different CODEX_HOME):
                // a stored session must not block the agent for good, so
                // start a new one. The queue persists the new id.
            }
        }
        return try opened(try await server.request("thread/start", .object(params)))
    }

    private func opened(_ result: JSONValue) throws -> OpenedThread {
        guard let id = result["thread"]?["id"]?.string else {
            throw CodexAdapterError.unexpectedResponse("no thread id")
        }
        return OpenedThread(id: id, model: result["model"]?.string, effort: result["reasoningEffort"]?.string)
    }

    // The rendered wrapper, then each image beside it as a native image the
    // model can see. The wrapper still names its path (DECIDED 2026.10.09).
    static func input(for message: Message) -> [JSONValue] {
        var items: [JSONValue] = [.object([
            "type": .string("text"),
            "text": .string(MessageRenderer.render(message)),
            "text_elements": .array([]),
        ])]
        for attachment in message.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            items.append(.object(["type": .string("localImage"), "path": .string(attachment.path)]))
        }
        return items
    }
}

public enum CodexAdapterError: Error, Equatable, CustomStringConvertible {
    // Neither the registered executable, PATH nor ChatGPT.app has codex.
    case codexNotFound(String)
    case notStarted
    case unexpectedResponse(String)
    // Older than CodexCapabilities.floor.
    case tooOld(version: String?)
    // app-server quit, or answered with an error, before the thread was
    // open: the first line of its stderr or the error's message, then the
    // whole reason.
    case startFailed(String, String)

    public var description: String {
        switch self {
        case .codexNotFound(let registered):
            return "codex not found (registered: \(registered.isEmpty ? "none" : registered); PATH; ChatGPT.app)"
        case .notStarted: return "codex is not started"
        case .unexpectedResponse(let detail): return "codex app-server: \(detail)"
        case .tooOld(let version):
            return "codex \(version ?? "(version unknown)") is too old for Sirius: it needs \(CodexCapabilities.floor) or later"
        case .startFailed(let line, let reason):
            return "codex quit as it started: \(line)" + (reason == line ? "" : " (\(reason))")
        }
    }
}

extension CodexAdapterError: UserFacingError {
    // TODO(andrew): copy. Generic on how to update: Codex comes from npm,
    // Homebrew, its standalone installer or ChatGPT.app, and `codex update`
    // is not in every release.
    public var userMessage: String? {
        switch self {
        case .tooOld(let version):
            return "Codex is too old for Sirius" + (version.map { " (\($0))" } ?? "") + ". Update Codex, then try again."
        case .startFailed(let line, _):
            return "Codex quit as it started: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        default:
            return nil
        }
    }
}
