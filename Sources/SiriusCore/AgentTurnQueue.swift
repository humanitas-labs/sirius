import Foundation
import SiriusProtocol

// One agent's messages, delivered one turn at a time in the order sent
// (architecture.md §3). A message sent while a turn runs, with none waiting
// ahead of it, joins that turn when the adapter declared steer (Adapter.steer);
// it is filed as joining it at once and ends with the turn. It starts the agent on warm() or the first message,
// whichever comes first, resuming the session in state.json, persists every
// session the adapter reports, and restarts the agent before the next turn
// when the last one lost it. Every step is filed in the agent's log.
//
// Messages the log re-queued on open (never delivered before a restart) go
// first, in log order, ahead of anything sent after; warm() or the first
// send starts their delivery (#1).
//
// With a ConsolidationPolicy, every turn's end (its own or the agent's)
// starts an idle timer that a send cancels. When it runs out with nothing
// running or queued and the context at the threshold, the queue consolidates
// the agent as a step of its own: a message sent meanwhile waits behind it
// rather than joining it, and goes once it is done. A session whose record
// has grown old or large is rotated into a fresh one at that moment instead
// (ConsolidationPolicy). Neither starts while the user is composing: a
// message on its way would wait behind it (2026.11.25: a 59 s dictation
// landed one second after a 35 s consolidation began).
public actor AgentTurnQueue {
    private let adapter: any Adapter
    private let log: AgentLog
    private let storage: AgentStorage
    // Told when the agent fails to start or a turn fails, with the reason,
    // so the user hears of it; a stop is not a failure.
    private let onFailure: @Sendable (String) -> Void
    // Told instead, with what to say, when the failure is a UserFacingError.
    private let onUserError: @Sendable (String) -> Void
    private let consolidation: ConsolidationPolicy?
    // Whether the user is dictating or has the composer open.
    private let composing: @Sendable () async -> Bool
    // A rotation did not come about; not tried again until the next launch,
    // so a harness that cannot do it is not asked every idle period.
    private var rotationFailed = false
    // For what went wrong that nobody is told of: a log line or the state
    // that could not be written.
    private let report: @Sendable (String) -> Void

    private var pending: [Message] = []
    // The message whose turn is running, and those that joined it.
    private var current: String?
    private var joined: [String] = []
    private var pump: Task<Void, Never>?
    private var started = false
    private var observing = false
    private var stopped = false
    // The adapter open in flight, shared by warm() and the first turn so
    // the agent is never started twice at once.
    private var startup: Task<Result<SessionInfo, any Error>, Never>?
    // Why the agent is down: the last start's failure, or the failure that
    // ended it mid-turn. Nil once a start works.
    private var down: String?
    // What the open adapter declared it can do; nothing until it opens.
    private var capabilities = AgentCapabilities()
    // The agent's context in tokens, from its last .usage update. The
    // adapter says when it no longer knows (.usage(nil)), e.g. after it
    // opens a session again, so open doesn't reset it here.
    private var contextTokens: Int?
    // Runs out after the policy's idle time; a send or the next turn's end
    // replaces or cancels it.
    private var idleTimer: Task<Void, Never>?

    public init(adapter: any Adapter, log: AgentLog, storage: AgentStorage,
                consolidation: ConsolidationPolicy? = nil,
                composing: @escaping @Sendable () async -> Bool = { false },
                onFailure: @escaping @Sendable (String) -> Void = { _ in },
                onUserError: @escaping @Sendable (String) -> Void = { _ in },
                report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.report = report
        self.consolidation = consolidation
        self.composing = composing
        self.adapter = adapter
        self.log = log
        self.storage = storage
        self.onFailure = onFailure
        self.onUserError = onUserError
        self.pending = log.requeued.map { Self.deliverable($0.message(agent: storage.agent)) }
    }

    // Whether the agent process is up. Whether a turn is running is not
    // tracked here.
    public enum RunState: Equatable, Sendable {
        // Not started yet, or a start in flight.
        case starting
        // Started; messages go straight to it.
        case running
        // Down, with why; the next message starts it again.
        case failed(String)
        case stopped
    }

    public var runState: RunState {
        if stopped { return .stopped }
        if started { return .running }
        if let down { return .failed(down) }
        return .starting
    }

    // A line for the log. The turn goes on when it cannot be written, and
    // the failure is reported rather than dropped.
    private func filed(_ write: () async throws -> Void) async {
        do {
            try await write()
        } catch {
            report("\(storage.agent): a log line was not written: \(error)")
        }
    }

    // Logs the message and queues it. Returns at once; the turn runs later.
    public func send(_ message: Message) async throws {
        guard !stopped else { throw AgentTurnQueueError.stopped }
        idleTimer?.cancel()
        try await log.messageReceived(message)
        if let turn = current, pending.isEmpty, started, capabilities.steer {
            if await adapter.steer(message) == .joined {
                await filed { try await log.turnJoined(message: message.id, turn: turn) }
                if current == turn {
                    joined.append(message.id)
                } else {
                    // The turn ended while the steer was on its way; the
                    // harness took the message in before it did.
                    let session = try? storage.readState().session
                    await filed { try await log.turnEnded(message: message.id, session: session,
                                                          outcome: .completed) }
                }
                return
            }
            if stopped { throw AgentTurnQueueError.stopped }
        }
        pending.append(message)
        drainIfNeeded()
    }

    // Starts the agent before any message, resuming the stored session, so
    // the first turn skips the start (architecture.md §5.1). No-op once it is
    // running or stopped. On failure the agent stays down and the first
    // message tries the start again.
    // Delivery of re-queued messages starts here either way; a failed start
    // is retried by their first turn.
    public func warm() async throws {
        guard !stopped, !started else { return }
        let result = await ensureStarted()
        drainIfNeeded()
        if case .failure(let error) = result { throw error }
    }

    // Stops the agent. A running turn is marked interrupted and never rerun.
    // Queued messages never reached the agent: they stay pending in the log,
    // which re-queues them on the next start (#1).
    public func stop() async {
        stopped = true
        pending.removeAll()
        idleTimer?.cancel()
        pump?.cancel()
        await adapter.close()
        await pump?.value
        // A start still in flight finishes first, then is stopped too.
        if let startup {
            _ = await startup.value
            await adapter.close()
        }
    }

    static let stopReason = "agent stopped"

    private func drainIfNeeded() {
        if pump == nil, !stopped, !pending.isEmpty {
            pump = Task { await self.drain() }
        }
    }

    private func drain() async {
        while !stopped, !pending.isEmpty {
            await run(pending.removeFirst())
        }
        pump = nil
        armIdleTimer()
    }

    // MARK: Consolidation

    private func armIdleTimer(after wait: Duration? = nil) {
        idleTimer?.cancel()
        guard let policy = consolidation, !stopped else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: wait ?? policy.idle)
            guard !Task.isCancelled else { return }
            await self?.consolidateIfIdle(policy)
        }
    }

    private func consolidateIfIdle(_ policy: ConsolidationPolicy) async {
        guard isIdle else { return }
        let rotates = capabilities.rotate && !rotationFailed
        let compacts = capabilities.compact && (contextTokens ?? 0) >= policy.threshold
        guard rotates || compacts else { return }
        if await composing() {
            // Still idle as far as turns go: look again shortly.
            if isIdle { armIdleTimer(after: policy.composingRetry) }
            return
        }
        var rotate = false
        if rotates, let record = await adapter.sessionRecord() { rotate = policy.rotates(record) }
        // A message may have come during the awaits above.
        guard isIdle, rotate || compacts else { return }
        pump = Task {
            if rotate { await self.rotate() } else { await self.consolidate() }
            await self.drain()
        }
    }

    private func rotate() async {
        do {
            guard let done = try await adapter.rotate() else { return }
            if case .completed = done.outcome, let session = done.to {
                persist(session)
            } else {
                rotationFailed = true
            }
            await filed { try await log.rotated(done) }
        } catch is CancellationError {
        } catch {
            // The agent is gone: restart it, in the session state.json still
            // names, before the next turn.
            started = false
            rotationFailed = true
            await adapter.close()
            let failed = Rotation(from: nil, to: nil, milliseconds: 0, outcome: .failed("\(error)"))
            await filed { try await log.rotated(failed) }
        }
    }

    private var isIdle: Bool {
        started && !stopped && pump == nil && pending.isEmpty && current == nil
    }

    private func consolidate() async {
        do {
            guard let done = try await adapter.compact() else { return }
            await filed { try await log.consolidated(done) }
        } catch is CancellationError {
        } catch {
            // The agent is gone, as after a failed turn: restart it before
            // the next one. Nobody asked for this step, so nobody is told.
            started = false
            await adapter.close()
            let failed = Consolidation(before: nil, after: nil, milliseconds: 0, outcome: .failed("\(error)"))
            await filed { try await log.consolidated(failed) }
        }
    }

    private func run(_ message: Message) async {
        if case .failure(let error) = await ensureStarted() {
            // A stop during the start: the message never reached the agent and
            // stays pending in the log for the next start.
            if stopped { return }
            let reason = "agent did not start: \(error)"
            await filed { try await log.turnStarted(message: message.id) }
            await filed { try await log.turnEnded(message: message.id, session: nil, outcome: .failed(reason: reason)) }
            if !stopped { fail(reason, error) }
            return
        }
        await filed { try await log.turnStarted(message: message.id) }
        current = message.id
        joined = []
        do {
            let end = try await adapter.prompt(message)
            if let session = end.session { persist(session) }
            for id in finished(message) { await filed { try await log.turnEnded(message: id, end) } }
            if case .failed(let reason) = end.outcome { onFailure(reason) }
        } catch is CancellationError {
            for id in finished(message) { await filed { try await log.interrupted(message: id, reason: Self.stopReason) } }
        } catch {
            // The agent is gone: restart it before the next turn.
            started = false
            down = "\(error)"
            let ids = finished(message)
            await adapter.close()
            for id in ids {
                await filed { try await log.turnEnded(message: id, session: nil, outcome: .failed(reason: "\(error)")) }
            }
            if !stopped { fail("\(error)", error) }
        }
    }

    private func fail(_ reason: String, _ error: any Error) {
        if let message = (error as? UserFacingError)?.userMessage {
            onUserError(message)
        } else {
            onFailure(reason)
        }
    }

    // The running turn's messages, its own and those that joined it, taken
    // before any await so a steer landing while they are filed sees the
    // turn as over.
    private func finished(_ message: Message) -> [String] {
        let ids = [message.id] + joined
        current = nil
        joined = []
        return ids
    }

    // Starts the adapter unless it is running; joins a start already in
    // flight rather than starting a second one.
    private func ensureStarted() async -> Result<Void, any Error> {
        if started { return .success(()) }
        if let startup {
            let result = await startup.value
            if stopped { return .failure(AgentTurnQueueError.stopped) }
            return result.map { _ in () }
        }
        let adapter = adapter
        if !observing {
            observing = true
            let updates = adapter.updates
            Task { [weak self] in
                for await update in updates { await self?.received(update) }
            }
        }
        let session = try? storage.readState().session
        let launched = ContinuousClock.now
        let task = Task { () -> Result<SessionInfo, any Error> in
            do { return .success(try await adapter.open(SessionRequest(resume: session))) } catch { return .failure(error) }
        }
        startup = task
        let result = await task.value
        startup = nil
        switch result {
        case .success(let start):
            if let named = start.session { persist(named) }
            let elapsed = ContinuousClock.now - launched
            let milliseconds = Int(elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000)
            // Resumed unless the adapter fell back to a new session.
            let resumed = session != nil && (start.session == nil || start.session == session)
            await filed {
                try await log.agentStarted(session: start.session ?? session, resumed: resumed,
                                           model: start.model, effort: start.effort, milliseconds: milliseconds)
            }
            if stopped {
                // stop() ran while the agent was starting; it must not outlive it.
                await adapter.close()
                return .failure(AgentTurnQueueError.stopped)
            }
            capabilities = start.capabilities
            started = true
            down = nil
            return .success(())
        case .failure(let error):
            down = "\(error)"
            return .failure(error)
        }
    }

    private func received(_ update: SessionUpdate) async {
        switch update {
        case .usage(let tokens): contextTokens = tokens
        case .agentTurnEnded(let end): await agentTurnEnded(end)
        }
    }

    // A turn the agent started by itself: filed, its session kept, a
    // failure reported like any other.
    private func agentTurnEnded(_ end: TurnEnd) async {
        if let session = end.session { persist(session) }
        await filed { try await log.agentTurn(end) }
        if case .failed(let reason) = end.outcome, !stopped { onFailure(reason) }
        if pump == nil { armIdleTimer() }
    }

    private func persist(_ session: String) {
        var state = (try? storage.readState()) ?? AgentState()
        guard state.session != session else { return }
        state.session = session
        do {
            try storage.writeState(state)
        } catch {
            report("\(storage.agent): state.json was not written: \(error.localizedDescription)")
        }
    }
}

extension AgentTurnQueue {
    // A re-queued message whose attachment files are gone (deleted while
    // Sirius was down) goes with its text and the attachments still there;
    // a note names each missing file so the agent knows it was sent (#1).
    static func deliverable(_ message: Message, fileExists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> Message {
        let missing = message.attachments.filter { !fileExists($0.path) }
        guard !missing.isEmpty else { return message }
        var kept = message
        kept.attachments.removeAll { !fileExists($0.path) }
        kept.text += "\n\n" + missing.map { missingAttachmentNote($0.path) }.joined(separator: "\n")
        return kept
    }

    // TODO(copy): wording.
    static func missingAttachmentNote(_ path: String) -> String {
        "[Sirius: attachment missing: \(path)]"
    }
}

public enum AgentTurnQueueError: Error, Equatable, Sendable {
    case stopped
}
