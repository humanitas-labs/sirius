import SiriusProtocol

// What every harness implements, shaped after ACP's lifecycle:
// open a session, prompt it one turn at a time,
// steer and compact where the harness can, close it, and a stream of the
// updates the queue needs. The per-agent queue calls prompt one turn at a
// time, stores the session it reports in state.json, and branches on the
// capabilities open returned, never on the harness. An adapter never shows
// anything to the user and never reads the agent's answer.
public protocol Adapter: AnyObject, Sendable {
    // Start the harness warm in its root, resuming `request.resume` when
    // given, with SIRIUS_SOCKET in its environment, and say what it can do.
    // ACP's initialize plus session/new, session/load or session/resume.
    // Returns as soon as the harness is ready: with the session when it has
    // named one by then (Codex names its thread at creation), so the queue
    // can persist it before the first turn can fail; nil when it only names
    // it at turn end. Opening again replaces the running session.
    func open(_ request: SessionRequest) async throws -> SessionInfo
    // One Message as a new turn; returns when the turn ends. ACP's
    // session/prompt. Returning .failed means the agent reported the turn
    // failed and is still up for the next one. Throwing means the transport
    // or the process is gone: the queue opens the agent again before the
    // next prompt.
    func prompt(_ message: Message) async throws -> TurnEnd
    // Add a Message to the turn prompt() is running, the way typing while an
    // agent works reaches it at its next step. Called only when open
    // declared `steer`. .joined when the harness took it into that turn,
    // whose end is then this message's end too; .notJoined when there is no
    // turn to join, and the queue sends it as a turn of its own.
    func steer(_ message: Message) async -> SteerResult
    // Shrink the agent's context to a short log of pointers, between turns
    // (architecture.md §5.1). Called only when open declared `compact`.
    // Returns when done; nil when the harness can't now (a turn of its own
    // is running). Throwing means the process is gone, as for prompt.
    func compact() async throws -> Consolidation?
    // How old and how large the record the harness keeps of this session is
    // (Claude's transcript file); nil when it keeps none or cannot say. The
    // queue reads it to decide when a session is due to be rotated.
    func sessionRecord() async -> SessionRecord?
    // Continue in a fresh session, between turns: the agent writes a handoff
    // brief, the session is closed, a new one is opened and reads the brief.
    // Called only when open declared `rotate`. Returns the new session when
    // done; nil when the harness can't now (a turn of its own is running);
    // .failed, with the old session still open, when the brief or the new
    // session did not come about. Throwing means the process is gone, as
    // for prompt.
    func rotate() async throws -> Rotation?
    // End the session and the process. Safe to call when it is not running.
    // A pending prompt does not outlive it: it throws CancellationError
    // before close returns. ACP's session/cancel plus session/close.
    func close() async
    // What the queue needs to hear between calls, for the adapter's whole
    // life, across opens: context usage and turns the agent started by
    // itself. ACP's session/update, filtered. One consumer.
    var updates: AsyncStream<SessionUpdate> { get }
}

// Harnesses that keep no record and cannot rotate say so by default.
public extension Adapter {
    func sessionRecord() async -> SessionRecord? { nil }
    func rotate() async throws -> Rotation? { nil }
}

// What open asks for. Launch configuration (root, model, instructions,
// MCP) stays with the adapter, from the registration it was built with:
// Claude and Codex fix it when their process starts.
public struct SessionRequest: Equatable, Sendable {
    // The session to resume, from state.json.
    public var resume: String?

    public init(resume: String? = nil) {
        self.resume = resume
    }
}

// What open reports: the session as far as the harness has named it, the
// model and effort, and what this harness can do.
public struct SessionInfo: Equatable, Sendable {
    // See open.
    public var session: String?
    // The model id the harness reports, else the one requested; nil when
    // the harness has not said yet and none was requested (Claude names it
    // with the first turn).
    public var model: String?
    public var effort: String?
    public var capabilities: AgentCapabilities

    public init(session: String? = nil, model: String? = nil, effort: String? = nil,
                capabilities: AgentCapabilities = AgentCapabilities()) {
        self.session = session
        self.model = model
        self.effort = effort
        self.capabilities = capabilities
    }
}

// What a harness can do beyond open, prompt and close. Everything is off
// unless the adapter declares it.
public struct AgentCapabilities: Equatable, Sendable {
    // Joins a running turn, and says whether it did (steer).
    public var steer: Bool
    // Compacts its context when Sirius asks (compact).
    public var compact: Bool
    // Starts turns by itself and reports their ends (.agentTurnEnded).
    public var agentTurns: Bool
    // Reports its context size (.usage).
    public var usage: Bool
    // Continues in a fresh session when Sirius asks (rotate).
    public var rotate: Bool

    public init(steer: Bool = false, compact: Bool = false, agentTurns: Bool = false, usage: Bool = false,
                rotate: Bool = false) {
        self.steer = steer
        self.compact = compact
        self.agentTurns = agentTurns
        self.usage = usage
        self.rotate = rotate
    }
}

public enum SteerResult: Equatable, Sendable {
    case joined
    case notJoined
}

public enum SessionUpdate: Equatable, Sendable {
    // The agent's context in tokens as of its last model call; nil when the
    // harness no longer knows (just opened, or just compacted).
    case usage(contextTokens: Int?)
    // A turn the agent started by itself ended, e.g. when a background task
    // it launched finished.
    case agentTurnEnded(TurnEnd)
}

// For adapters: the stream they return as `updates`, and its sink. Keeps
// the newest updates when nobody reads them (the first-turn adapter).
public func makeUpdateStream() -> (AsyncStream<SessionUpdate>, AsyncStream<SessionUpdate>.Continuation) {
    let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
    return (stream, continuation)
}

// What a consolidation did: the context in tokens before and after, as far
// as the harness said, and how long it took.
public struct Consolidation: Equatable, Sendable {
    public var before: Int?
    public var after: Int?
    public var milliseconds: Int
    public var outcome: TurnEnd.Outcome

    public init(before: Int?, after: Int?, milliseconds: Int, outcome: TurnEnd.Outcome = .completed) {
        self.before = before
        self.after = after
        self.milliseconds = milliseconds
        self.outcome = outcome
    }
}

// The harness's own record of a session: how long ago it began and its size
// on disk.
public struct SessionRecord: Equatable, Sendable {
    public var age: Duration
    public var bytes: Int

    public init(age: Duration, bytes: Int) {
        self.age = age
        self.bytes = bytes
    }
}

// What a rotation did: the session left and the one that took over, and how
// long it took. On .failed the agent is still in `from`.
public struct Rotation: Equatable, Sendable {
    public var from: String?
    public var to: String?
    public var milliseconds: Int
    public var outcome: TurnEnd.Outcome

    public init(from: String?, to: String?, milliseconds: Int, outcome: TurnEnd.Outcome = .completed) {
        self.from = from
        self.to = to
        self.milliseconds = milliseconds
        self.outcome = outcome
    }
}

// When the queue consolidates an agent: after `idle` with no turn, once its
// context is at least `threshold` tokens. At the same moment a session whose
// record is older than `rotateAge` or larger than `rotateBytes` is rotated
// instead (.plan/session-rotation.md): one session resumed for weeks grew a
// 700 MB transcript that the harness's own cleanup never removes. Neither
// step starts while the user is composing; it is tried again after
// `composingRetry`.
public struct ConsolidationPolicy: Equatable, Sendable {
    public static let defaultIdleMinutes = 15
    public static let defaultThreshold = 100_000
    public static let defaultRotateAge: Duration = .seconds(7 * 24 * 60 * 60)
    public static let defaultRotateBytes = 200_000_000

    public var idle: Duration
    public var threshold: Int
    // Nil turns that trigger off.
    public var rotateAge: Duration?
    public var rotateBytes: Int?
    public var composingRetry: Duration

    public init(idle: Duration, threshold: Int, rotateAge: Duration? = ConsolidationPolicy.defaultRotateAge,
                rotateBytes: Int? = ConsolidationPolicy.defaultRotateBytes,
                composingRetry: Duration = .seconds(60)) {
        self.idle = idle
        self.threshold = threshold
        self.rotateAge = rotateAge
        self.rotateBytes = rotateBytes
        self.composingRetry = composingRetry
    }

    public func rotates(_ record: SessionRecord) -> Bool {
        if let rotateAge, record.age >= rotateAge { return true }
        if let rotateBytes, record.bytes >= rotateBytes { return true }
        return false
    }

    // The registration's consolidate_after_idle and consolidate_threshold,
    // or the defaults; nil when it turns consolidation off (0 minutes).
    public init?(registration: AgentRegistration) {
        let minutes = registration.consolidateAfterIdle ?? Self.defaultIdleMinutes
        guard minutes > 0 else { return nil }
        self.init(idle: .seconds(minutes * 60),
                  threshold: max(0, registration.consolidateThreshold ?? Self.defaultThreshold))
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
