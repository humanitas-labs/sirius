import Foundation
import SiriusCore
import SiriusProtocol

// Claude Code, warm headless (architecture.md §5.1). One long-lived
// `claude -p` per agent with stream-json in and out, in the agent's root.
// Each Message is one user turn on stdin; the `result` event ends it.
// Permissions are auto mode plus `Bash(sirius:*)`: the
// agent does its normal work with the user's own setup, a headless agent has
// no one to prompt, and auto's classifier decides instead of a person. It can
// always reach the user (docs/research/claude.md, item 3).
//
// Claude also starts turns by itself: when a background agent it launched
// finishes, the CLI runs a turn with no line from us (checked 2026.10.10,
// CLI 2.1.296). Each line we send carries a uuid that Claude echoes back
// (--replay-user-messages) and lists in the result of the turn that took it
// in (user_message_uuids); that result ends our turn. Any other result is
// the agent's own turn, reported through onAgentTurn, or the empty one that
// trails it, ignored. A CLI that does not list them falls back to the echo:
// the result after it ends our turn.
//
// A line written while a turn runs (steer) joins it at its next tool
// boundary, as typing does in Claude Code; a turn with no tool call left
// takes it as the next turn instead. deliver
// returns once every line it and its steers wrote has a result.
public actor ClaudeAdapter: Adapter {
    // Every stdout line as Claude wrote it, for the log and for tests. Called
    // on the reader's task, in order.
    public typealias Observer = @Sendable (Data) -> Void

    private let registration: AgentRegistration
    private let socketPath: String
    private let helpersDirectory: URL
    private let systemPrompt: String?
    // Whether the process goes by the agent's session name (--name). Off
    // for the throwaway first turn (AgentHost.sendFirstTurn), so it never
    // shows as a second session under the agent's name.
    private let named: Bool
    private let observer: Observer?
    private let environment: [String: String]

    private var running: Running?
    private var generation = 0
    private var pending: CheckedContinuation<TurnEnd, Error>?
    // The uuids of the lines the pending turn wrote, its own and steered
    // ones, until a result takes each in; whether Claude has echoed one;
    // and the failure of any result that took some of them.
    private var outstanding: Set<String> = []
    private var echoed = false
    private var turnFailure: String?
    private var agentTurnHandler: (@Sendable (TurnEnd) -> Void)?
    // The session the stream last named.
    private var session: String?
    // Why the last process ended, for a deliver that finds it gone.
    private var lastExit: String?
    // The first line of its stderr when it ended before writing a line on
    // stdout: claude refused to start, e.g. "error: unknown option
    // '--system-prompt-snapshot'" from a CLI older than a flag.
    private var launchFailure: String?
    // Processes on their way out, by generation. stop waits for all of them,
    // so no process outlives it.
    private var exiting: [Int: Task<Int32?, Never>] = [:]
    // The model the stream last named.
    private var model: String?
    // The session this process was started to resume, until a turn succeeds.
    private var resumed: String?
    // The arguments of the process last started.
    public private(set) var launchArguments: [String] = []

    private struct Running {
        let process: ClaudeProcess
        let stdin: FileHandle
        let generation: Int
        let stderr: ClaudeStderrTail
        // Whether Claude has written a line on stdout.
        var spoke = false
        // An error result Claude reported with no turn pending, e.g. a bad
        // --resume id.
        var unsolicitedFailure: String?
    }

    // helpersDirectory holds `sirius` and `sirius-mcp`
    // (Sirius.app/Contents/Helpers); it goes first on the agent's PATH.
    // systemPrompt is appended to Claude's own.
    public init(registration: AgentRegistration, socketPath: String, helpersDirectory: URL,
                systemPrompt: String? = nil, named: Bool = true,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                observer: Observer? = nil) {
        self.registration = registration
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
        self.systemPrompt = systemPrompt
        self.named = named
        self.environment = environment
        self.observer = observer
    }

    // The name the session goes by for other Claude sessions: ListAgents
    // rows, SendMessage addresses and the `from` of cross-session messages.
    // Without --name Claude derives one from the cwd, e.g. "humanitas-67"
    // (CLI 2.1.296). The one place to change the format.
    public static func sessionName(agent: String) -> String {
        "sirius-\(agent)"
    }

    // The flags, in order. --allowedTools takes several values, so it goes
    // last: anything after it would be read as a tool name. --name goes
    // before --resume, which must stay next to --replay-user-messages
    // (ClaudeOrphans).
    //
    // An older CLI exits at once on a flag it doesn't know, so the optional
    // ones its help doesn't list are left out (ClaudeCapabilities); start()
    // refuses a CLI that lacks a required one.
    public static func arguments(session: String?, systemPrompt: String?, name: String? = nil,
                                 model: String? = nil, effort: String? = nil, fast: Bool = false,
                                 capabilities: ClaudeCapabilities = .unknown) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "auto"]
        if let model { args += ["--model", model] }
        if let effort, capabilities.supports("--effort") { args += ["--effort", effort] }
        // Fast mode has no flag, only the fastMode setting, layered over the
        // user's own. Claude still needs the account to allow it: without
        // extra usage the stream reports fast_mode_state "off" (CLI 2.1.296).
        if fast, capabilities.supports("--settings") { args += ["--settings", #"{"fastMode":true}"#] }
        if let name, capabilities.supports("--name") { args += ["--name", name] }
        if let session { args += ["--resume", session] }
        args += ["--replay-user-messages"]
        if let systemPrompt {
            args += ["--append-system-prompt", systemPrompt]
            // Snapshot off: Claude otherwise keeps the prompt a session started
            // with on every resume, so an edited instructions.md never reached a resumed
            // agent (CLI 2.1.296). 2.1.212 has no such flag.
            if capabilities.supports("--system-prompt-snapshot") { args += ["--system-prompt-snapshot", "off"] }
        }
        args += ["--allowedTools", "Bash(sirius:*)"]
        return args
    }

    // MARK: - Adapter

    // Claude names the session only once a turn runs (system/init comes with
    // the first turn, not at process start), so this returns nil unless the
    // stream has already named one. Likewise the model, unless one was
    // registered.
    public func start(session resume: String?) async throws -> AgentStart {
        await stop()
        // A claude a dead Sirius left on this session must not write it beside
        // the new one (#2).
        if let resume { await ClaudeOrphans.end(session: resume) }
        guard let executable = ClaudeLocator.locate(executable: registration.executable, environment: environment)
        else { throw ClaudeAdapterError.executableNotFound(registration.executable) }
        let capabilities = await ClaudeProbe.shared.capabilities(executable: executable, environment: environment)
        let missing = capabilities.missingRequired
        guard missing.isEmpty else { throw ClaudeAdapterError.tooOld(version: capabilities.version, missing: missing) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let arguments = Self.arguments(session: resume, systemPrompt: systemPrompt,
                                       name: named ? Self.sessionName(agent: registration.agent) : nil,
                                       model: registration.model, effort: registration.effort,
                                       fast: registration.fast == true, capabilities: capabilities)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: registration.root, isDirectory: true)
        var env = environment
        env["PATH"] = helpersDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env[SiriusEnvironment.socket] = socketPath
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A write after Claude exits fails with EPIPE instead of killing Sirius.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let tail = ClaudeStderrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                tail.finish()
            } else {
                tail.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ClaudeAdapterError.launchFailed("\(executable): \(error.localizedDescription)")
        }
        generation += 1
        let gen = generation
        running = Running(process: ClaudeProcess(process), stdin: stdin.fileHandleForWriting,
                          generation: gen, stderr: tail)
        launchArguments = arguments
        resumed = resume
        session = nil
        model = nil
        lastExit = nil
        launchFailure = nil

        // Not FileHandle.bytes: its read(2) blocks a thread of the shared
        // cooperative pool for as long as Claude stays quiet, which for a warm
        // agent is most of its life, and a few idle agents starve every other
        // task in the app. The readability handler reads on a dispatch queue.
        let chunks = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        let observer = observer
        Task.detached { [weak self] in
            var line = Data()
            for await chunk in chunks {
                var rest = chunk[...]
                while let newline = rest.firstIndex(of: 0x0A) {
                    line.append(rest[..<newline])
                    rest = rest[rest.index(after: newline)...]
                    if !line.isEmpty {
                        let data = line
                        observer?(data)
                        await self?.received(data, generation: gen)
                    }
                    line = Data()
                }
                line.append(rest)
            }
            await self?.streamEnded(generation: gen)
        }
        return AgentStart(session: session, model: registration.model, effort: registration.effort)
    }

    // A session Claude can no longer find (deleted, or from another machine)
    // would fail every restart, so the turn starts a new session instead, as
    // the Codex adapter does; the queue persists the new id.
    public func deliver(_ message: Message) async throws -> TurnEnd {
        // Claude reports it as an error result, which a turn already waiting
        // receives as its end, then exits.
        do {
            let end = try await deliverOnce(message)
            if resumed != nil, case .failed(let reason) = end.outcome,
               reason.contains(ClaudeAdapterError.missingSession) {
                return try await deliverInNewSession(message)
            }
            resumed = nil
            return end
        } catch let error as ClaudeAdapterError where resumed != nil && error.isMissingSession {
            return try await deliverInNewSession(message)
        }
    }

    private func deliverInNewSession(_ message: Message) async throws -> TurnEnd {
        _ = try await start(session: nil)
        return try await deliverOnce(message)
    }

    private func deliverOnce(_ message: Message) async throws -> TurnEnd {
        try Task.checkCancellation()
        guard let current = running else {
            if let launchFailure { throw ClaudeAdapterError.quitAtLaunch(launchFailure, lastExit ?? "") }
            throw ClaudeAdapterError.notRunning(lastExit)
        }
        guard pending == nil else { throw ClaudeAdapterError.turnInProgress }
        let uuid = UUID().uuidString.lowercased()
        let line = try ClaudeStream.userMessage(message, uuid: uuid)
        let gen = current.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                outstanding = [uuid]
                echoed = false
                turnFailure = nil
                do {
                    try current.stdin.write(contentsOf: line)
                } catch {
                    // Claude has most likely exited, e.g. refused to start:
                    // the end of its stream says why, with its stderr.
                    let reason = "could not write the turn: \(error.localizedDescription)"
                    Task { await self.writeFailed(uuid: uuid, reason) }
                }
            }
        } onCancel: {
            Task { await self.cancelTurn(generation: gen) }
        }
    }

    // Writes the message now, while deliver waits; see the header.
    public func steer(_ message: Message) async -> Bool {
        guard pending != nil, let current = running else { return false }
        let uuid = UUID().uuidString.lowercased()
        guard let line = try? ClaudeStream.userMessage(message, uuid: uuid),
              (try? current.stdin.write(contentsOf: line)) != nil else { return false }
        outstanding.insert(uuid)
        return true
    }

    public func onAgentTurn(_ handler: @escaping @Sendable (TurnEnd) -> Void) async {
        agentTurnHandler = handler
    }

    public func stop() async {
        let midTurn = pending != nil
        outstanding = []
        if let continuation = pending {
            pending = nil
            continuation.resume(throwing: CancellationError())
        }
        if let current = running {
            running = nil
            lastExit = "stopped"
            launchFailure = nil
            try? current.stdin.close()
            // Idle, closing stdin is enough and lets Claude finish writing the
            // session; mid-turn, it would run the turn out first.
            _ = shutDown(current, grace: midTurn ? 0 : 2)
        }
        for task in exiting.values { _ = await task.value }
    }

    private func shutDown(_ current: Running, grace: Double) -> Task<Int32?, Never> {
        if let task = exiting[current.generation] { return task }
        let process = current.process
        let gen = current.generation
        let task = Task { [weak self] in
            let status = await process.terminate(grace: grace)
            await self?.exited(generation: gen)
            return status
        }
        exiting[gen] = task
        return task
    }

    private func exited(generation gen: Int) {
        exiting[gen] = nil
    }

    // MARK: - Stream

    private func received(_ line: Data, generation gen: Int) {
        guard running?.generation == gen else { return }
        running?.spoke = true
        guard let event = ClaudeStream.parse(line) else { return }
        switch event {
        case .initialized(let named, let reported):
            if let named { session = named }
            if let reported { model = reported }
        case .replayed(let uuid):
            if outstanding.contains(uuid) { echoed = true }
        case .result(let named, let failure, let turns, let messages):
            if let named { session = named }
            let end = TurnEnd(session: session, outcome: failure.map { .failed($0) } ?? .completed, model: model)
            if pending != nil, let messages, !outstanding.isDisjoint(with: messages) {
                outstanding.subtract(messages)
                if let failure { turnFailure = failure }
                if outstanding.isEmpty {
                    finishTurn(TurnEnd(session: session, outcome: turnFailure.map { .failed($0) } ?? .completed,
                                       model: model))
                }
                return
            }
            if pending != nil, messages == nil, echoed {
                finishTurn(end)
                return
            }
            // An error before Claude took in our line, naming none, is about
            // that line or the start (a bad --resume id, an unknown model):
            // our turn's end. Once it has echoed one, a result naming none
            // is the agent's own turn.
            if pending != nil, failure != nil, messages == nil || (messages?.isEmpty == true && !echoed) {
                finishTurn(end)
                return
            }
            // Not ours: the agent's own turn, or the empty result after one.
            if failure == nil, turns == 0 { return }
            if let failure, pending == nil { running?.unsolicitedFailure = failure }
            agentTurnHandler?(end)
        case .other:
            break
        }
    }

    private func streamEnded(generation gen: Int) async {
        guard let current = running, current.generation == gen else { return }
        running = nil
        // A stop while this waits finds the process in `exiting` and waits too.
        let status = await shutDown(current, grace: 1).value
        // stdout can close before the last of stderr is read.
        await current.stderr.drained(within: 0.5)
        var reason = "claude exited"
        if let status { reason += " with status \(status)" }
        if let failure = current.unsolicitedFailure { reason += ": \(failure)" }
        let stderr = current.stderr.text
        if !stderr.isEmpty { reason += " (stderr: \(stderr))" }
        lastExit = reason
        if !current.spoke, let first = stderr.split(separator: "\n").first {
            launchFailure = first.trimmingCharacters(in: .whitespaces)
        }
        if let continuation = pending {
            pending = nil
            outstanding = []
            continuation.resume(throwing: launchFailure.map { ClaudeAdapterError.quitAtLaunch($0, reason) }
                                ?? ClaudeAdapterError.exited(reason))
        }
    }

    // A turn whose line could not be written, if the stream's end has not
    // ended it within a few seconds.
    private func writeFailed(uuid: String, _ reason: String) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let continuation = pending, outstanding.contains(uuid) else { return }
        pending = nil
        outstanding = []
        continuation.resume(throwing: ClaudeAdapterError.exited(reason))
    }

    private func finishTurn(_ end: TurnEnd) {
        guard let continuation = pending else { return }
        pending = nil
        outstanding = []
        continuation.resume(returning: end)
    }

    // The task running deliver was cancelled. The turn cannot be taken back
    // from Claude, and its result would end the next turn, so the process goes.
    private func cancelTurn(generation gen: Int) async {
        guard running?.generation == gen, pending != nil else { return }
        await stop()
    }
}

public enum ClaudeAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)
    // deliver with no process: never started, stopped, or exited (the reason).
    case notRunning(String?)
    // The process or its pipe went away mid-turn.
    case exited(String)
    // deliver while a turn is running; the queue never does this.
    case turnInProgress
    // The CLI lacks a flag Sirius needs (ClaudeCapabilities.required).
    case tooOld(version: String?, missing: [String])
    // Claude exited before writing anything: the first line of its stderr,
    // then the whole reason.
    case quitAtLaunch(String, String)

    // Claude's words for a --resume id it has no conversation for.
    static let missingSession = "No conversation found"

    var isMissingSession: Bool {
        "\(self)".contains(Self.missingSession)
    }

    public var description: String {
        switch self {
        case .executableNotFound(let path):
            return "claude not found (registration: \(path.isEmpty ? "none" : path), PATH, ~/.claude/local, ~/.local/bin, /opt/homebrew/bin)"
        case .launchFailed(let reason): return "claude did not launch: \(reason)"
        case .notRunning(let reason): return "claude is not running" + (reason.map { ": \($0)" } ?? "")
        case .exited(let reason): return reason
        case .turnInProgress: return "a turn is already running"
        case .tooOld(let version, let missing):
            return "claude \(version ?? "(version unknown)") is too old for Sirius: it has no \(missing.joined(separator: ", "))"
        case .quitAtLaunch(let line, let reason):
            return "claude quit as it started: \(line)" + (reason.isEmpty ? "" : " (\(reason))")
        }
    }
}

extension ClaudeAdapterError: UserFacingError {
    // TODO(andrew): copy.
    public var userMessage: String? {
        switch self {
        case .tooOld(let version, _):
            return "Claude Code is too old for Sirius" + (version.map { " (\($0))" } ?? "")
                + ". Run `claude update`, then try again."
        case .quitAtLaunch(let line, _):
            return "Claude Code quit as it started: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        default:
            return nil
        }
    }
}

// Process is not Sendable; the box is only touched from the adapter and the
// detached waits below.
final class ClaudeProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    // Waits `grace` seconds for a clean exit, then SIGTERM, then SIGKILL.
    // Returns the exit status, nil if it was killed by a signal. Runs detached
    // so a cancelled caller still waits.
    //
    // Process starts claude as the leader of its own process group (checked
    // 2026.10.10: its pgid is its pid), so the signals go to the group and
    // reach the tools claude was running, e.g. a hung xcodebuild, which would
    // otherwise outlive it (#2). Anything left in the group once claude has
    // exited gets a SIGTERM too.
    @discardableResult
    func terminate(grace: Double) async -> Int32? {
        await Task.detached { [self] in
            let pid = process.processIdentifier
            if await !waitForExit(seconds: grace) {
                ClaudeProcess.signal(pid, SIGTERM)
                if await !waitForExit(seconds: 3) {
                    ClaudeProcess.signal(pid, SIGKILL)
                    _ = await waitForExit(seconds: 3)
                }
            }
            guard !process.isRunning else { return nil }
            ClaudeProcess.signalGroup(pid, SIGTERM)
            return process.terminationReason == .exit ? process.terminationStatus : nil
        }.value
    }

    // The group when `pid` leads one, else the process alone.
    static func signal(_ pid: pid_t, _ signal: Int32) {
        guard pid > 0 else { return }
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
    }

    // What is left of the group `pid` led; nothing when it is empty (ESRCH).
    // The kernel never hands out a pid equal to a live group's id, and pids
    // are handed out in sequence, so an empty group's id is not reused in the
    // moment between claude's exit and this signal.
    static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        guard pid > 0 else { return }
        kill(-pid, signal)
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
