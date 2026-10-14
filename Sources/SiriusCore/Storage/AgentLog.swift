import Foundation
import SiriusProtocol

public enum AgentLogError: Error, Equatable, Sendable {
    case duplicateMessage(String)
    case unknownMessage(String)
    // One turn at a time per agent.
    case turnAlreadyRunning(current: String)
    // The message is not the one whose turn is running.
    case turnNotRunning(String)
    // Ended or interrupted already; a message never runs twice.
    case messageFinished(String)
    case cannotOpen(path: String, errno: Int32)
}

// The lines read back from a log. Lines that do not decode (a crash
// mid-write, or a newer format) are skipped and counted, never fatal.
public struct AgentLogContents: Equatable, Sendable {
    public var entries: [AgentLogEntry]
    // 1-based line numbers.
    public var skippedLines: [Int]
}

// The single writer of one agent's log.jsonl. Every append is one write(2)
// of a whole line on an O_APPEND descriptor, so a crash leaves at most one
// partial last line.
//
// Opening the log is the restart recovery. A message whose turn started and
// never ended is marked interrupted and never rerun: it reached the agent,
// and rerunning it unprompted could repeat side effects. A message with no
// turn_started never reached the agent (the queue logs turn_started before
// delivery), so it is re-queued instead, in log order and ahead of anything
// sent after the restart, and a "requeued" line records it (#1; before, it
// was marked interrupted and silently dropped). It stays pending, so a
// second restart before its turn re-queues it again rather than dropping it.
public actor AgentLog {
    public let url: URL
    // Messages whose turn was cut off, marked interrupted when this log was
    // opened: the turn's own message, then any that joined it.
    public nonisolated let recovered: [String]
    // Messages that never reached the agent, re-queued when this log was
    // opened, in log order. The turn queue delivers them first.
    public nonisolated let requeued: [RequeuedMessage]

    private let handle: FileHandle
    private let now: @Sendable () -> Date
    private var state: AgentLogState

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentLogError.cannotOpen(path: url.path, errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        // Terminate a partial last line so the next entry starts clean; the
        // fragment stays in the file and is skipped on read.
        if let last = existing.last, last != 0x0A {
            try handle.write(contentsOf: Data([0x0A]))
        }

        var state = AgentLogState()
        var bodies: [String: RequeuedMessage] = [:]
        for entry in Self.decode(existing).entries {
            state.apply(entry.event)
            if case .message(let id, let text, let attachments) = entry.event, bodies[id] == nil {
                bodies[id] = RequeuedMessage(id: id, text: text, attachments: attachments)
            }
        }

        var recovered: [String] = []
        for message in [state.current].compactMap({ $0 }) + state.joined {
            let entry = AgentLogEntry(at: now(), event: .interrupted(message: message, reason: Self.restartReason))
            try Self.append(entry, to: handle)
            state.apply(entry.event)
            recovered.append(message)
        }
        var requeued: [RequeuedMessage] = []
        for message in state.pending {
            guard let body = bodies[message] else { continue }
            let entry = AgentLogEntry(at: now(), event: .requeued(message: message))
            try Self.append(entry, to: handle)
            state.apply(entry.event)
            requeued.append(body)
        }

        self.url = url
        self.handle = handle
        self.now = now
        self.state = state
        self.recovered = recovered
        self.requeued = requeued
    }

    static let restartReason = "app restarted before the turn finished"

    // MARK: Reading

    // The message whose turn is running.
    public var currentMessage: String? { state.current }
    // The message of the most recent turn, running or not. Commands are
    // filed against it when no turn is running (late output).
    public var mostRecentMessage: String? { state.lastStarted }
    // Received, not yet started, in arrival order.
    public var pendingMessages: [String] { state.pending }

    public static func read(_ url: URL) throws -> AgentLogContents {
        decode(try Data(contentsOf: url))
    }

    static func decode(_ data: Data) -> AgentLogContents {
        let decoder = JSONDecoder()
        var entries: [AgentLogEntry] = []
        var skipped: [Int] = []
        for (index, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty { continue }
            if let entry = try? decoder.decode(AgentLogEntry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                skipped.append(index + 1)
            }
        }
        return AgentLogContents(entries: entries, skippedLines: skipped)
    }

    // MARK: Writing

    public func messageReceived(_ message: Message) throws {
        guard state.status[message.id] == nil else { throw AgentLogError.duplicateMessage(message.id) }
        try write(.message(id: message.id, text: message.text, attachments: message.attachments))
    }

    public func turnStarted(message: String) throws {
        if let current = state.current { throw AgentLogError.turnAlreadyRunning(current: current) }
        switch state.status[message] {
        case nil: throw AgentLogError.unknownMessage(message)
        case .finished, .running: throw AgentLogError.messageFinished(message)
        case .pending: try write(.turnStarted(message: message))
        }
    }

    // The message joined `turn`'s running turn (Adapter.steer). Also when
    // that turn has just ended, since the harness took it in before then.
    public func turnJoined(message: String, turn: String) throws {
        switch state.status[message] {
        case nil: throw AgentLogError.unknownMessage(message)
        case .finished, .running: throw AgentLogError.messageFinished(message)
        case .pending: try write(.turnJoined(message: message, turn: turn))
        }
    }

    public func agentStarted(session: String?, resumed: Bool, model: String?, effort: String?,
                             milliseconds: Int) throws {
        try write(.agentStarted(session: session, resumed: resumed, model: model, effort: effort,
                                milliseconds: milliseconds))
    }

    public func turnEnded(message: String, session: String?, outcome: AgentLogEntry.TurnOutcome,
                          model: String? = nil) throws {
        guard state.current == message || state.joined.contains(message) else {
            throw AgentLogError.turnNotRunning(message)
        }
        try write(.turnEnded(message: message, session: session, outcome: outcome, model: model))
    }

    public func agentTurn(_ end: TurnEnd) throws {
        try write(.agentTurn(session: end.session, outcome: AgentLogEntry.TurnOutcome(end.outcome), model: end.model))
    }

    public func turnEnded(message: String, _ end: TurnEnd) throws {
        try turnEnded(message: message, session: end.session, outcome: AgentLogEntry.TurnOutcome(end.outcome),
                      model: end.model)
    }

    // Files the command against the current message, else the most recent
    // one, and returns which. Uses the command's receive time.
    @discardableResult
    public func commandReceived(_ command: Command) throws -> String? {
        let message = state.current ?? state.lastStarted
        try write(.command(message: message, request: command.id, method: command.call.method,
                           params: CommandSummary(command.call)),
                  at: command.received)
        return message
    }

    // Marks a running or queued message interrupted, e.g. the user stopped
    // the agent. It is never rerun.
    public func interrupted(message: String, reason: String) throws {
        switch state.status[message] {
        case nil: throw AgentLogError.unknownMessage(message)
        case .finished: throw AgentLogError.messageFinished(message)
        case .pending, .running: try write(.interrupted(message: message, reason: reason))
        }
    }

    private func write(_ event: AgentLogEntry.Event, at date: Date? = nil) throws {
        let entry = AgentLogEntry(at: date ?? now(), event: event)
        try Self.append(entry, to: handle)
        state.apply(event)
    }

    private static func append(_ entry: AgentLogEntry, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }
}

// A message read back from the log for delivery after a restart. The agent
// is implied by the log, as on the message line itself.
public struct RequeuedMessage: Equatable, Sendable {
    public var id: String
    public var text: String
    public var attachments: [Message.Attachment]

    public init(id: String, text: String, attachments: [Message.Attachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }

    public func message(agent: String) -> Message {
        Message(id: id, agent: agent, text: text, attachments: attachments)
    }
}

// The lifecycle of each message, rebuilt from the log on open and kept
// current on every append.
struct AgentLogState: Sendable {
    enum Status: Equatable, Sendable { case pending, running, finished }

    var status: [String: Status] = [:]
    // Arrival order, for pending and recovery.
    var order: [String] = []
    var current: String?
    // Running because they joined a turn, current's or one just ended.
    var joined: [String] = []
    var lastStarted: String?

    var pending: [String] { order.filter { status[$0] == .pending } }

    mutating func apply(_ event: AgentLogEntry.Event) {
        switch event {
        case .message(let id, _, _):
            if status[id] == nil {
                status[id] = .pending
                order.append(id)
            }
        case .turnStarted(let message):
            status[message] = .running
            current = message
            lastStarted = message
        case .turnJoined(let message, _):
            status[message] = .running
            joined.append(message)
        case .turnEnded(let message, _, _, _), .interrupted(let message, _):
            status[message] = .finished
            if current == message { current = nil }
            joined.removeAll { $0 == message }
        case .requeued, .command, .agentStarted, .agentTurn:
            // A re-queued message stays pending until its turn starts.
            break
        }
    }
}
