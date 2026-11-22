import Foundation
import SiriusCore
import SiriusProtocol

// Any agent that speaks the Agent Client Protocol, version 1, over stdio
// (agentclientprotocol.com): Cursor's `agent acp`, Antigravity's `agy acp`
// and OpenCode's `opencode acp` today. What differs between them is an
// ACPProfile; nothing here names a harness. One warm process per agent,
// one session, one turn per Message. The agent reaches the user through
// sirius-mcp, given to the session as the MCP server "sirius".
//
// open:   spawn the server in the root, initialize, authenticate with the
//         profile's method when the server offers it, then session/resume
//         or session/load (whichever it advertises) or session/new; set the
//         registered model and effort through the session's config options.
// prompt: session/prompt; its response ends the turn, with a stop reason.
// close:  terminate the process. The session is the agent's to keep.
//
// Instructions go as the session's systemPrompt (append) when the server
// advertises that; otherwise in front of the first prompt after each open,
// so an edited instructions.md reaches a resumed session too.
//
// Sirius runs agents with nobody at the terminal, so every
// session/request_permission is answered with the request's own allow
// option, as the Muse adapter grants Muse's. Sirius serves no fs/* or
// terminal/* methods and says so in initialize.
//
// Declares nothing beyond open, prompt and close: ACP v1 has no way to join
// a running turn and none to compact on request. usage_update, where a
// server sends it, still goes out on `updates`.
public actor ACPAdapter: Adapter {
    public nonisolated let registration: AgentRegistration
    public nonisolated let socketPath: String
    // Holds sirius and sirius-mcp: Sirius.app/Contents/Helpers.
    public nonisolated let helpersDirectory: URL
    public nonisolated let instructions: String?
    public nonisolated let updates: AsyncStream<SessionUpdate>
    nonisolated let profile: ACPProfile
    private let updateSink: AsyncStream<SessionUpdate>.Continuation
    private let environment: [String: String]
    // How long authenticate may take. Cursor's, signed out, never answers
    // (checked on 2026.08.11), and open must not wait on it for good.
    private let authenticateTimeout: Duration

    private var connection: JSONRPCStdio?
    private var session: String?
    private var model: String?
    // Whether the server takes image blocks in a prompt.
    private var takesImages = false
    // Instructions the session was not given as its system prompt: they go
    // in front of the next prompt.
    private var instructionsDue = false
    private var observer: (@Sendable (String) -> Void)?

    static let capabilities = AgentCapabilities()
    static let protocolVersion: Int64 = 1
    static let clientVersion = "0.1"

    init(registration: AgentRegistration, profile: ACPProfile, socketPath: String, helpersDirectory: URL,
         instructions: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         authenticateTimeout: Duration = .seconds(15)) {
        self.registration = registration
        self.profile = profile
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
        self.instructions = instructions.flatMap { $0.isEmpty ? nil : $0 }
        self.environment = environment
        self.authenticateTimeout = authenticateTimeout
        (updates, updateSink) = makeUpdateStream()
    }

    // Every JSON-RPC line, ">> " sent or "<< " received. Takes effect at the
    // next open. Tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        self.observer = observer
    }

    var processIdentifier: Int32? { connection?.processIdentifier }

    // MARK: - Adapter

    public func open(_ request: SessionRequest) async throws -> SessionInfo {
        await close()
        guard let executable = profile.findExecutable(registered: registration.executable, environment: environment)
        else { throw ACPAdapterError.notFound(product: profile.product, command: profile.command) }
        let connection = JSONRPCStdio(
            name: "\(profile.command) acp", executable: URL(fileURLWithPath: executable),
            arguments: profile.arguments(registration),
            environment: profile.environment(environment, socketPath: socketPath, helpers: helpersDirectory),
            directory: URL(fileURLWithPath: registration.root, isDirectory: true))
        let followed = FollowedSession()
        var handlers = JSONRPCStdio.Handlers()
        let updates = updateSink
        handlers.notification = { method, params in
            guard method == "session/update", params["sessionId"]?.string == followed.id,
                  let update = params["update"], update["sessionUpdate"]?.string == "usage_update",
                  let used = update["used"]?.safeInteger else { return }
            updates.yield(.usage(contextTokens: Int(used)))
        }
        let profile = profile
        handlers.serverRequest = { method, params in Self.answer(method, params, profile: profile) }
        connection.setHandlers(handlers)
        if let observer { connection.observe(observer) }
        do {
            try connection.launch()
        } catch {
            throw ACPAdapterError.startFailed(product: profile.product, "\(executable): \(error.localizedDescription)", "")
        }
        self.connection = connection

        do {
            let initialized = try await connection.request("initialize", .object([
                "protocolVersion": .number(Double(Self.protocolVersion)),
                // Agents use their own files and shells: no fs/*, no terminal/*.
                "clientCapabilities": .object([
                    "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                    "terminal": .bool(false),
                ]),
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(Self.clientVersion)]),
            ]))
            let version = initialized["protocolVersion"]?.safeInteger
            guard version == Self.protocolVersion else {
                throw ACPAdapterError.unsupportedProtocol(product: profile.product, version)
            }
            let agent = initialized["agentCapabilities"] ?? .null
            takesImages = agent["promptCapabilities"]?["image"] == .bool(true)
            let offered = (initialized["authMethods"]?.array ?? []).compactMap { $0["id"]?.string }
            if let method = profile.authMethod, offered.contains(method) {
                try await authenticate(on: connection, method: method)
            }

            let opened = try await openSession(on: connection, capabilities: agent, resuming: request.resume,
                                               followed: followed)
            session = opened.id
            followed.id = opened.id
            instructionsDue = instructions != nil && !opened.promptApplied
            model = try await configure(connection, session: opened.id, options: opened.options)
            return SessionInfo(session: opened.id, model: model, effort: registration.effort,
                               capabilities: Self.capabilities)
        } catch {
            var failure = error
            if let rpc = error as? JSONRPCStdioError {
                switch rpc {
                case .rpc(_, Self.authenticationRequired, _):
                    failure = ACPAdapterError.signInRequired(product: profile.product, command: profile.signIn)
                case .rpc(_, _, let message):
                    failure = ACPAdapterError.startFailed(product: profile.product, message, "\(rpc)")
                case .closed, .exited:
                    let line = await connection.firstStderrLine()
                    failure = ACPAdapterError.startFailed(product: profile.product, line ?? "\(rpc)", "\(rpc)")
                }
            }
            await connection.terminate()
            if self.connection === connection { self.connection = nil }
            session = nil
            throw failure
        }
    }

    public func prompt(_ message: Message) async throws -> TurnEnd {
        guard let connection, let session else { throw ACPAdapterError.notStarted(product: profile.product) }
        let prefixed = instructionsDue
        let blocks = Self.prompt(for: message, instructions: prefixed ? instructions : nil, images: takesImages)
        do {
            let result = try await connection.request("session/prompt", .object([
                "sessionId": .string(session), "prompt": .array(blocks),
            ]))
            if prefixed { instructionsDue = false }
            return TurnEnd(session: session, outcome: Self.outcome(stopReason: result["stopReason"]?.string),
                           model: model)
        } catch JSONRPCStdioError.rpc(_, let code, let text) {
            // The agent refused the turn and is still up for the next one.
            let reason = code == Self.authenticationRequired
                ? "\(profile.product) is signed out. Run `\(profile.signIn)` in a terminal, then try again."
                : text
            return TurnEnd(session: session, outcome: .failed(reason), model: model)
        }
    }

    // Not declared; see the header.
    public func steer(_ message: Message) async -> SteerResult { .notJoined }

    // Not declared; see the header.
    public func compact() async throws -> Consolidation? { nil }

    // Kills the process: neither CLI is asked first, since Cursor's server
    // stays up after its stdin closes (checked on 2026.08.11).
    public func close() async {
        guard let connection else { return }
        self.connection = nil
        session = nil
        model = nil
        instructionsDue = false
        await connection.terminate()
    }

    // MARK: - Session

    static let authenticationRequired: Int64 = -32000

    private struct OpenedSession {
        var id: String
        var options: [JSONValue]
        // Whether the instructions went as the session's system prompt.
        var promptApplied: Bool
    }

    // The session whose updates count: session/load replays the history of
    // the one being loaded before it answers.
    private final class FollowedSession: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var id: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    // authenticate, given up on after authenticateTimeout as signed out.
    // The request itself cannot be taken back; closing the connection,
    // which open does on any failure, ends it.
    private func authenticate(on connection: JSONRPCStdio, method: String) async throws {
        let signedOut = ACPAdapterError.signInRequired(product: profile.product, command: profile.signIn)
        let timeout = authenticateTimeout
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                do {
                    _ = try await connection.request("authenticate", .object(["methodId": .string(method)]))
                    once.run { continuation.resume() }
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.run { continuation.resume(throwing: signedOut) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }

    private func openSession(on connection: JSONRPCStdio, capabilities: JSONValue, resuming resume: String?,
                             followed: FollowedSession) async throws -> OpenedSession {
        let sessions = capabilities["sessionCapabilities"] ?? .null
        var params: [String: JSONValue] = [
            "cwd": .string(registration.root),
            "mcpServers": .array([Self.mcpServer(helper: helpersDirectory.appendingPathComponent("sirius-mcp").path,
                                                 socketPath: socketPath)]),
        ]
        var promptApplied = false
        if let instructions, sessions["systemPrompt"]?.object != nil {
            params["systemPrompt"] = .object([
                "mode": .string("append"),
                "content": .array([.object(["type": .string("text"), "text": .string(instructions)])]),
            ])
            promptApplied = true
        }
        // resume opens the session without its history; load replays it
        // first, which the notification handler drops.
        let reopen = sessions["resume"]?.object != nil ? "session/resume"
            : capabilities["loadSession"] == .bool(true) ? "session/load" : nil
        if let resume, let reopen {
            var reopening = params
            reopening["sessionId"] = .string(resume)
            do {
                let result = try await connection.request(reopen, .object(reopening))
                return OpenedSession(id: resume, options: result["configOptions"]?.array ?? [],
                                     promptApplied: promptApplied)
            } catch JSONRPCStdioError.rpc(_, let code, _) where code != Self.authenticationRequired {
                // The session is gone: a stored id must not block the agent
                // for good, so start a new one. The queue persists it.
            }
        }
        let result = try await connection.request("session/new", .object(params))
        guard let id = result["sessionId"]?.string else {
            throw ACPAdapterError.startFailed(product: profile.product, "session/new returned no sessionId", "")
        }
        return OpenedSession(id: id, options: result["configOptions"]?.array ?? [], promptApplied: promptApplied)
    }

    // Sets the registered model and effort through the session's config
    // options and returns the model the session says it runs on, else the
    // registered one.
    // A registered model the session does not offer is refused here, with
    // what it does offer. An effort it does not offer is left alone: the
    // levels differ by model.
    private func configure(_ connection: JSONRPCStdio, session: String, options: [JSONValue]) async throws -> String? {
        var options = options
        func set(_ choice: ACPConfig.Choice) async throws {
            let result = try await connection.request("session/set_config_option", .object([
                "sessionId": .string(session), "configId": .string(choice.option), "value": .string(choice.value),
            ]))
            if let updated = result["configOptions"]?.array { options = updated }
        }
        if let wanted = registration.model, let offered = ACPConfig.option(in: options, category: "model") {
            guard let choice = ACPConfig.choice(in: offered, wanted: wanted) else {
                throw ACPAdapterError.modelUnavailable(product: profile.product, wanted,
                                                       available: ACPConfig.values(of: offered))
            }
            try await set(choice)
        }
        if let wanted = registration.effort, let offered = ACPConfig.option(in: options, category: "thought_level"),
           let choice = ACPConfig.choice(in: offered, wanted: wanted) {
            try? await set(choice)
        }
        return ACPConfig.option(in: options, category: "model")?["currentValue"]?.string ?? registration.model
    }

    // MARK: - Wire shapes

    // sirius-mcp as a stdio MCP server of the session: ACP's env is a list
    // of name and value, not an object.
    static func mcpServer(helper: String, socketPath: String) -> JSONValue {
        .object([
            "name": .string("sirius"),
            "command": .string(helper),
            "args": .array([]),
            "env": .array([.object(["name": .string(SiriusEnvironment.socket), "value": .string(socketPath)])]),
        ])
    }

    static let instructionsHeader = "[sirius · standing instructions for this session, from the app, not the user]"
    static let instructionsFooter = "[sirius · end of instructions; the user's message follows]"

    // The rendered wrapper, with the instructions in front when they are
    // due, then each image beside it as a native block when the server
    // takes them. The wrapper still names every attachment by path.
    static func prompt(for message: Message, instructions: String?, images: Bool) -> [JSONValue] {
        var text = MessageRenderer.render(message)
        if let instructions {
            text = [instructionsHeader, "", instructions, "", instructionsFooter, "", text].joined(separator: "\n")
        }
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        guard images else { return blocks }
        for attachment in message.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            guard let data = FileManager.default.contents(atPath: attachment.path), !data.isEmpty else { continue }
            blocks.append(.object([
                "type": .string("image"),
                "mimeType": .string(attachment.mimeType.lowercased()),
                "data": .string(data.base64EncodedString()),
            ]))
        }
        return blocks
    }

    // ACP's five stop reasons. Only end_turn is a completed turn.
    static func outcome(stopReason: String?) -> TurnEnd.Outcome {
        switch stopReason {
        case "end_turn": return .completed
        case "max_tokens": return .failed("the turn ran out of output tokens")
        case "max_turn_requests": return .failed("the turn reached the agent's limit of model requests")
        case "refusal": return .failed("the model refused the request")
        case "cancelled": return .failed("the turn was cancelled")
        case let other: return .failed("the turn ended without a stop reason Sirius knows (\(other ?? "none"))")
        }
    }

    // A request from the agent: a permission, one of the profile's own
    // methods, or something Sirius does not serve.
    static func answer(_ method: String, _ params: JSONValue, profile: ACPProfile) -> JSONRPCStdio.Reply {
        if method == "session/request_permission" { return .result(permission(params)) }
        if let reply = profile.answer(method, params) { return reply }
        return .error(code: -32601, message: "Sirius does not handle \(method)")
    }

    // The request's one-time allow option, else its standing one; an option
    // list that offers neither is answered as cancelled, never as a guess.
    static func permission(_ params: JSONValue) -> JSONValue {
        let options = params["options"]?.array ?? []
        func option(_ kind: String) -> String? {
            options.first { $0["kind"]?.string == kind }?["optionId"]?.string
        }
        guard let chosen = option("allow_once") ?? option("allow_always") else {
            return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(chosen)])])
    }
}

// A session's config options (ACP session-config-options): a list of
// selects, each with a category and its values, flat or in groups.
enum ACPConfig {
    struct Choice: Equatable {
        var option: String
        var value: String
    }

    static func option(in options: [JSONValue], category: String) -> JSONValue? {
        options.first { $0["category"]?.string == category && $0["id"]?.string != nil }
    }

    // Each value with its display name, groups flattened.
    static func entries(of option: JSONValue) -> [(value: String, name: String?)] {
        (option["options"]?.array ?? []).flatMap { entry -> [(value: String, name: String?)] in
            if let grouped = entry["options"]?.array {
                return grouped.compactMap { item in item["value"]?.string.map { ($0, item["name"]?.string) } }
            }
            return entry["value"]?.string.map { [($0, entry["name"]?.string)] } ?? []
        }
    }

    static func values(of option: JSONValue) -> [String] { entries(of: option).map(\.value) }

    // The value that is `wanted`, by value, else by name without case, else
    // through the names Sirius's effort levels go by elsewhere ("xhigh" is
    // Antigravity's "Extra").
    static func choice(in option: JSONValue, wanted: String) -> Choice? {
        guard let id = option["id"]?.string else { return nil }
        let entries = entries(of: option)
        let lowered = wanted.lowercased()
        let names = [lowered] + (aliases[lowered] ?? [])
        let match = entries.first { $0.value == wanted }
            ?? entries.first { names.contains($0.value.lowercased()) }
            ?? entries.first { entry in entry.name.map { names.contains($0.lowercased()) } ?? false }
        return match.map { Choice(option: id, value: $0.value) }
    }

    static let aliases = ["xhigh": ["extra", "extra high", "extra_high"]]
}

public enum ACPAdapterError: Error, Equatable, CustomStringConvertible {
    // Neither the registered executable, PATH nor ~/.local/bin has it.
    case notFound(product: String, command: String)
    case notStarted(product: String)
    // The server answered initialize with a protocol version other than 1.
    case unsupportedProtocol(product: String, Int64?)
    // The CLI has no credentials: the command that signs it in.
    case signInRequired(product: String, command: String)
    // The registered model isn't one the session offers.
    case modelUnavailable(product: String, String, available: [String])
    // The server quit, or answered with an error, before the session was
    // open: the first line of its stderr or the error's message, then the
    // whole reason.
    case startFailed(product: String, String, String)

    public var description: String {
        switch self {
        case .notFound(let product, let command):
            return "\(product): \(command) not found (registered executable; PATH; ~/.local/bin)"
        case .notStarted(let product): return "\(product) is not started"
        case .unsupportedProtocol(let product, let version):
            return "\(product) speaks ACP version \(version.map(String.init) ?? "(none)"); Sirius speaks 1"
        case .signInRequired(let product, let command):
            return "\(product) is signed out: run \(command)"
        case .modelUnavailable(let product, let model, let available):
            return "\(product): \(model) is not offered (available: \(available.joined(separator: ", ")))"
        case .startFailed(let product, let line, let reason):
            return "\(product) quit as it started: \(line)" + (reason.isEmpty || reason == line ? "" : " (\(reason))")
        }
    }
}

extension ACPAdapterError: UserFacingError {
    // TODO(copy): copy.
    public var userMessage: String? {
        switch self {
        case .notFound(let product, let command):
            return "\(product) isn't installed: `\(command)` was not found."
        case .unsupportedProtocol(let product, _):
            return "This \(product) speaks a protocol Sirius doesn't know yet. Update Sirius, then try again."
        case .signInRequired(let product, let command):
            return "\(product) is signed out. Run `\(command)` in a terminal, then try again."
        case .modelUnavailable(let product, let model, _):
            return "\(model) isn't offered by \(product). Pick another model for this agent."
        case .startFailed(let product, let line, _):
            return "\(product) quit as it started: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        case .notStarted:
            return nil
        }
    }
}
