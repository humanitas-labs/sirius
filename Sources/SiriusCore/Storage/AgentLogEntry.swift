import Foundation
import SiriusProtocol

// One line of log.jsonl, the record. Flat JSON: the
// format version "v", the time "at", the "event" name and its fields.
//
//   {"at":"2026-10-09T14:03:11.204Z","event":"message","message":"m_7f3k2a9q","text":"why?","attachments":[],"v":1}
//   {"at":"…","event":"agent_started","ms":2140,"model":"gpt-6-astra","effort":"medium","resumed":true,"session":"abc","v":1}
//   {"at":"…","event":"turn_started","message":"m_7f3k2a9q","v":1}
//   {"at":"…","event":"turn_joined","message":"m_9q2c","turn":"m_7f3k2a9q","v":1}
//   {"at":"…","event":"command","message":"m_7f3k2a9q","method":"display","params":{"kind":"toast","text":"Done"},"request":7,"v":1}
//   {"at":"…","event":"turn_ended","message":"m_7f3k2a9q","model":"claude-fable-5-1","outcome":"completed","session":"abc","v":1}
//   {"at":"…","event":"turn_ended","message":"m_7f3k2a9q","outcome":"failed","reason":"exited 1","v":1}
//   {"at":"…","event":"agent_turn","model":"claude-fable-5-1","outcome":"completed","session":"abc","v":1}
//   {"at":"…","event":"interrupted","message":"m_7f3k2a9q","reason":"app restarted mid-turn","v":1}
//   {"at":"…","event":"requeued","message":"m_7f3k2a9q","v":1}
//
// The record carries its own version rather than the wire's, since it
// outlives the command set.
public struct AgentLogEntry: Equatable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var at: Date
    public var event: Event

    public init(at: Date, event: Event, version: Int = AgentLogEntry.formatVersion) {
        self.version = version
        self.at = at
        self.event = event
    }

    public enum Event: Equatable, Sendable {
        // The user sent a Message. The agent is implied by the file.
        case message(id: String, text: String, attachments: [Message.Attachment])
        // The agent process is up. resumed: it carries on `session`; else a
        // new one. model and effort as far as the harness has said (see
        // AgentStart); milliseconds from launch to ready.
        case agentStarted(session: String?, resumed: Bool, model: String?, effort: String?, milliseconds: Int)
        case turnStarted(message: String)
        // Sent while `turn`'s turn ran and taken into it (Adapter.steer). It
        // ends with its own turn_ended or interrupted line, like a turn.
        case turnJoined(message: String, turn: String)
        // session is the resume id after the turn; nil when the turn failed
        // before the agent reported one. model is the one that ran it.
        case turnEnded(message: String, session: String?, outcome: TurnOutcome, model: String? = nil)
        // A turn the agent started by itself (a background task finished).
        // It answers no message.
        case agentTurn(session: String?, outcome: TurnOutcome, model: String?)
        // A request from the agent, filed against its current message or the
        // most recent one; nil only when no turn has ever started.
        case command(message: String?, request: RequestId, method: SiriusProtocol.Method, params: CommandSummary)
        // Never ran to completion and will never be rerun automatically.
        case interrupted(message: String, reason: String)
        // Queued and never started when the app restarted, so it never
        // reached the agent: queued again on open. It stays pending; a later
        // turn_started or interrupted line finishes it as usual (#1).
        case requeued(message: String)

        public var name: String {
            switch self {
            case .message: "message"
            case .agentStarted: "agent_started"
            case .turnStarted: "turn_started"
            case .turnJoined: "turn_joined"
            case .turnEnded: "turn_ended"
            case .agentTurn: "agent_turn"
            case .command: "command"
            case .interrupted: "interrupted"
            case .requeued: "requeued"
            }
        }

        public var message: String? {
            switch self {
            case .message(let id, _, _): id
            case .turnStarted(let message), .turnEnded(let message, _, _, _), .interrupted(let message, _),
                 .requeued(let message), .turnJoined(let message, _): message
            case .agentStarted, .agentTurn: nil
            case .command(let message, _, _, _): message
            }
        }
    }

    public enum TurnOutcome: Equatable, Sendable {
        case completed
        case failed(reason: String)

        public init(_ outcome: TurnEnd.Outcome) {
            switch outcome {
            case .completed: self = .completed
            case .failed(let reason): self = .failed(reason: reason)
            }
        }
    }
}

// What the log keeps of a command: the method's scalar params and its text,
// bounded, and the types of its other blocks. Image, audio and embedded
// resource bytes are left out: a single image may be 6 MB of base64, and the
// log's jobs (recovery and debugging) need what was shown, not the pixels.
public struct CommandSummary: Equatable, Sendable, Codable {
    // The text kept per command. Equal to the longest text any built method
    // accepts (speak), so today nothing is cut; dialog and aside may be.
    public static let maxTextChars = Limits.maxSpeakChars

    public var kind: DisplayKind?
    // Text blocks joined with "\n", or speak's text.
    public var text: String?
    // Set when text was cut at maxTextChars.
    public var truncated: Bool?
    // Block types other than text, in order, e.g. ["image", "resource_link"].
    public var blocks: [ContentBlock.BlockType]?
    // resource_link URIs, which the access check decides on.
    public var uris: [String]?
    public var title: String?
    public var alert: Bool?
    public var session: String?
    public var voice: String?

    public init(kind: DisplayKind? = nil, text: String? = nil, truncated: Bool? = nil,
                blocks: [ContentBlock.BlockType]? = nil, uris: [String]? = nil, title: String? = nil,
                alert: Bool? = nil, session: String? = nil, voice: String? = nil) {
        self.kind = kind
        self.text = text
        self.truncated = truncated
        self.blocks = blocks
        self.uris = uris
        self.title = title
        self.alert = alert
        self.session = session
        self.voice = voice
    }

    public init(_ call: Call) {
        self.init()
        switch call {
        case .display(let params):
            kind = params.kind
            alert = params.alert
            session = params.session
            summarize(params.content)
        case .notify(let params):
            title = params.title
            summarize(params.content)
        case .speak(let params):
            voice = params.voice
            setText(params.text)
        }
    }

    private mutating func summarize(_ content: [ContentBlock]) {
        let others = content.map(\.type).filter { $0 != .text }
        if !others.isEmpty { blocks = others }
        let links = content.compactMap { if case .resourceLink(let link) = $0 { link.uri } else { nil } }
        if !links.isEmpty { uris = links }
        if content.contains(where: { $0.type == .text }) { setText(ContentBlock.joinedText(content)) }
    }

    private mutating func setText(_ value: String) {
        if value.codePoints > Self.maxTextChars {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: value.unicodeScalars.prefix(Self.maxTextChars))
            text = String(scalars)
            truncated = true
        } else {
            text = value
        }
    }
}

extension AgentLogEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case v, at, event, message, text, attachments, session, outcome, reason, request, method, params
        case resumed, model, effort, ms, turn
    }

    struct UnknownEvent: Error {}

    // ISO 8601 UTC with milliseconds; the style is Sendable, a formatter is not.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .v)
        at = try Self.timestampStyle.parse(container.decode(String.self, forKey: .at))
        switch try container.decode(String.self, forKey: .event) {
        case "message":
            event = .message(id: try container.decode(String.self, forKey: .message),
                             text: try container.decode(String.self, forKey: .text),
                             attachments: try container.decodeIfPresent([Message.Attachment].self,
                                                                        forKey: .attachments) ?? [])
        case "agent_started":
            event = .agentStarted(session: try container.decodeIfPresent(String.self, forKey: .session),
                                  resumed: try container.decodeIfPresent(Bool.self, forKey: .resumed) ?? false,
                                  model: try container.decodeIfPresent(String.self, forKey: .model),
                                  effort: try container.decodeIfPresent(String.self, forKey: .effort),
                                  milliseconds: try container.decodeIfPresent(Int.self, forKey: .ms) ?? 0)
        case "turn_started":
            event = .turnStarted(message: try container.decode(String.self, forKey: .message))
        case "turn_joined":
            event = .turnJoined(message: try container.decode(String.self, forKey: .message),
                                turn: try container.decode(String.self, forKey: .turn))
        case "turn_ended":
            let outcome: TurnOutcome
            switch try container.decode(String.self, forKey: .outcome) {
            case "completed": outcome = .completed
            case "failed": outcome = .failed(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
            default: throw UnknownEvent()
            }
            event = .turnEnded(message: try container.decode(String.self, forKey: .message),
                               session: try container.decodeIfPresent(String.self, forKey: .session),
                               outcome: outcome,
                               model: try container.decodeIfPresent(String.self, forKey: .model))
        case "agent_turn":
            event = .agentTurn(session: try container.decodeIfPresent(String.self, forKey: .session),
                               outcome: try Self.decodeOutcome(container),
                               model: try container.decodeIfPresent(String.self, forKey: .model))
        case "command":
            event = .command(message: try container.decodeIfPresent(String.self, forKey: .message),
                             request: try container.decode(RequestId.self, forKey: .request),
                             method: try container.decode(SiriusProtocol.Method.self, forKey: .method),
                             params: try container.decode(CommandSummary.self, forKey: .params))
        case "interrupted":
            event = .interrupted(message: try container.decode(String.self, forKey: .message),
                                 reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "requeued":
            event = .requeued(message: try container.decode(String.self, forKey: .message))
        default:
            throw UnknownEvent()
        }
    }

    private static func decodeOutcome(_ container: KeyedDecodingContainer<CodingKeys>) throws -> TurnOutcome {
        switch try container.decode(String.self, forKey: .outcome) {
        case "completed": return .completed
        case "failed": return .failed(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        default: throw UnknownEvent()
        }
    }

    private static func encode(_ outcome: TurnOutcome, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch outcome {
        case .completed:
            try container.encode("completed", forKey: .outcome)
        case .failed(let reason):
            try container.encode("failed", forKey: .outcome)
            try container.encode(reason, forKey: .reason)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .v)
        try container.encode(at.formatted(Self.timestampStyle), forKey: .at)
        try container.encode(event.name, forKey: .event)
        switch event {
        case .message(let id, let text, let attachments):
            try container.encode(id, forKey: .message)
            try container.encode(text, forKey: .text)
            try container.encode(attachments, forKey: .attachments)
        case .agentStarted(let session, let resumed, let model, let effort, let milliseconds):
            try container.encodeIfPresent(session, forKey: .session)
            try container.encode(resumed, forKey: .resumed)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(effort, forKey: .effort)
            try container.encode(milliseconds, forKey: .ms)
        case .turnStarted(let message):
            try container.encode(message, forKey: .message)
        case .turnJoined(let message, let turn):
            try container.encode(message, forKey: .message)
            try container.encode(turn, forKey: .turn)
        case .turnEnded(let message, let session, let outcome, let model):
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(session, forKey: .session)
            try container.encodeIfPresent(model, forKey: .model)
            switch outcome {
            case .completed:
                try container.encode("completed", forKey: .outcome)
            case .failed(let reason):
                try container.encode("failed", forKey: .outcome)
                try container.encode(reason, forKey: .reason)
            }
        case .agentTurn(let session, let outcome, let model):
            try container.encodeIfPresent(session, forKey: .session)
            try container.encodeIfPresent(model, forKey: .model)
            try Self.encode(outcome, into: &container)
        case .command(let message, let request, let method, let params):
            try container.encodeIfPresent(message, forKey: .message)
            try container.encode(request, forKey: .request)
            try container.encode(method, forKey: .method)
            try container.encode(params, forKey: .params)
        case .interrupted(let message, let reason):
            try container.encode(message, forKey: .message)
            try container.encode(reason, forKey: .reason)
        case .requeued(let message):
            try container.encode(message, forKey: .message)
        }
    }
}
