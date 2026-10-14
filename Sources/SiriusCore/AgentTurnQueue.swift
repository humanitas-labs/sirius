import Foundation
import SiriusProtocol

// One agent's messages, delivered one turn at a time in the order sent
// (architecture.md §3). A message sent while a turn runs, with none waiting
// ahead of it, joins that turn when the adapter can steer (Adapter.steer);
// it is filed as joining it at once and ends with the turn. It starts the agent on warm() or the first message,
// whichever comes first, resuming the session in state.json, persists every
// session the adapter reports, and restarts the agent before the next turn
// when the last one lost it. Every step is filed in the agent's log.
//
// Messages the log re-queued on open (never delivered before a restart) go
// first, in log order, ahead of anything sent after; warm() or the first
// send starts their delivery (#1).
public actor AgentTurnQueue {
    private let adapter: any Adapter
    private let log: AgentLog
    private let storage: AgentStorage
    // Told when the agent fails to start or a turn fails, with the reason,
    // so the user hears of it; a stop is not a failure.
    private let onFailure: @Sendable (String) -> Void
    // Told instead, with what to say, when the failure is a UserFacingError.
    private let onUserError: @Sendable (String) -> Void

    private var pending: [Message] = []
    // The message whose turn is running, and those that joined it.
    private var current: String?
    private var joined: [String] = []
    private var pump: Task<Void, Never>?
    private var started = false
    private var observing = false
    private var stopped = false
    // The adapter start in flight, shared by warm() and the first turn so
    // the agent is never started twice at once.
    private var startup: Task<Result<AgentStart, any Error>, Never>?

    public init(adapter: any Adapter, log: AgentLog, storage: AgentStorage,
                onFailure: @escaping @Sendable (String) -> Void = { _ in },
                onUserError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.adapter = adapter
        self.log = log
        self.storage = storage
        self.onFailure = onFailure
        self.onUserError = onUserError
        self.pending = log.requeued.map { Self.deliverable($0.message(agent: storage.agent)) }
    }

    // Logs the message and queues it. Returns at once; the turn runs later.
    public func send(_ message: Message) async throws {
        guard !stopped else { throw AgentTurnQueueError.stopped }
        try await log.messageReceived(message)
        if let turn = current, pending.isEmpty, started {
            if await adapter.steer(message) {
                try? await log.turnJoined(message: message.id, turn: turn)
                if current == turn {
                    joined.append(message.id)
                } else {
                    // The turn ended while the steer was on its way; the
                    // harness took the message in before it did.
                    try? await log.turnEnded(message: message.id, session: try? storage.readState().session,
                                             outcome: .completed)
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
        pump?.cancel()
        await adapter.stop()
        await pump?.value
        // A start still in flight finishes first, then is stopped too.
        if let startup {
            _ = await startup.value
            await adapter.stop()
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
    }

    private func run(_ message: Message) async {
        if case .failure(let error) = await ensureStarted() {
            // A stop during the start: the message never reached the agent and
            // stays pending in the log for the next start.
            if stopped { return }
            let reason = "agent did not start: \(error)"
            try? await log.turnStarted(message: message.id)
            try? await log.turnEnded(message: message.id, session: nil, outcome: .failed(reason: reason))
            if !stopped { fail(reason, error) }
            return
        }
        try? await log.turnStarted(message: message.id)
        current = message.id
        joined = []
        do {
            let end = try await adapter.deliver(message)
            if let session = end.session { persist(session) }
            for id in finished(message) { try? await log.turnEnded(message: id, end) }
            if case .failed(let reason) = end.outcome { onFailure(reason) }
        } catch is CancellationError {
            for id in finished(message) { try? await log.interrupted(message: id, reason: Self.stopReason) }
        } catch {
            // The agent is gone: restart it before the next turn.
            started = false
            let ids = finished(message)
            await adapter.stop()
            for id in ids {
                try? await log.turnEnded(message: id, session: nil, outcome: .failed(reason: "\(error)"))
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
            await adapter.onAgentTurn { [weak self] end in
                Task { await self?.agentTurnEnded(end) }
            }
        }
        let session = try? storage.readState().session
        let launched = ContinuousClock.now
        let task = Task { () -> Result<AgentStart, any Error> in
            do { return .success(try await adapter.start(session: session)) } catch { return .failure(error) }
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
            try? await log.agentStarted(session: start.session ?? session, resumed: resumed,
                                        model: start.model, effort: start.effort, milliseconds: milliseconds)
            if stopped {
                // stop() ran while the agent was starting; it must not outlive it.
                await adapter.stop()
                return .failure(AgentTurnQueueError.stopped)
            }
            started = true
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    // A turn the agent started by itself: filed, its session kept, a
    // failure reported like any other.
    private func agentTurnEnded(_ end: TurnEnd) async {
        if let session = end.session { persist(session) }
        try? await log.agentTurn(end)
        if case .failed(let reason) = end.outcome, !stopped { onFailure(reason) }
    }

    private func persist(_ session: String) {
        guard (try? storage.readState().session) != session else { return }
        try? storage.writeState(AgentState(session: session))
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

    // TODO(andrew): wording.
    static func missingAttachmentNote(_ path: String) -> String {
        "[Sirius: attachment missing: \(path)]"
    }
}

public enum AgentTurnQueueError: Error, Equatable, Sendable {
    case stopped
}
