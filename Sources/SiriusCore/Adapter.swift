import SiriusProtocol

// The five jobs every adapter does (docs/architecture.md §5): start, resume,
// deliver, turn end, stop. The per-agent queue calls deliver one turn
// at a time and stores the returned session in state.json. An adapter never
// shows anything to the user and never reads the agent's answer.
public protocol Adapter: AnyObject, Sendable {
    // Start the agent warm in its root, resuming `session` when given, with
    // SIRIUS_SOCKET in its environment. Returns the session as soon as the
    // harness reports one (Codex names its thread at creation), so the queue
    // can persist it before the first turn can fail; nil when the harness
    // only reports it at turn end. Also the model and effort, as far as the
    // harness has said by then.
    func start(session: String?) async throws -> AgentStart
    // Deliver one Message as a new turn. Returns when the turn ends.
    // Returning .failed means the agent reported the turn failed and is still
    // up for the next one. Throwing means the transport or the process is
    // gone: the queue restarts the agent before the next delivery.
    func deliver(_ message: Message) async throws -> TurnEnd
    // Add a Message to the turn deliver() is running, the way typing while
    // an agent works reaches it at its next step. True when the
    // harness took it into that turn, whose end is then this message's end
    // too; false when there is no turn to join or the harness can't, and
    // the queue delivers it as a turn of its own.
    func steer(_ message: Message) async -> Bool
    // Stop the agent. Safe to call when it is not running. A pending deliver
    // does not outlive it: it throws CancellationError before stop returns.
    func stop() async
    // Turns the agent starts by itself, e.g. when a background task it
    // launched finishes: the handler gets each one's end. Set before start.
    func onAgentTurn(_ handler: @escaping @Sendable (TurnEnd) -> Void) async
}

extension Adapter {
    // Harnesses that never start a turn by themselves.
    public func onAgentTurn(_ handler: @escaping @Sendable (TurnEnd) -> Void) async {}
    // Harnesses that take one message per turn.
    public func steer(_ message: Message) async -> Bool { false }
}

public struct AgentStart: Equatable, Sendable {
    // See start(session:).
    public var session: String?
    // The model id the harness reports, else the one requested; nil when
    // the harness has not said yet and none was requested (Claude names it
    // with the first turn).
    public var model: String?
    public var effort: String?

    public init(session: String? = nil, model: String? = nil, effort: String? = nil) {
        self.session = session
        self.model = model
        self.effort = effort
    }
}

public struct TurnEnd: Equatable, Sendable {
    // The resume id after this turn. Absent when the turn failed before the
    // agent reported one.
    public var session: String?
    public var outcome: Outcome
    // The model id that ran the turn, as the harness reports it.
    public var model: String?

    public enum Outcome: Equatable, Sendable {
        case completed
        // The agent reported an error or its process exited mid-turn.
        case failed(String)
    }

    public init(session: String?, outcome: Outcome, model: String? = nil) {
        self.session = session
        self.outcome = outcome
        self.model = model
    }
}

// An adapter error the user can act on as it stands ("run claude update"):
// the queue and the host show `userMessage` as a toast under the agent's
// mark instead of the bare reason. Nil for errors with nothing to say.
public protocol UserFacingError: Error {
    var userMessage: String? { get }
}
