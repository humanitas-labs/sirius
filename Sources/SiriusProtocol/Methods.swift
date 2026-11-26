public enum DisplayKind: String, CaseIterable, Sendable, Codable {
    case toast, dialog

    // The block types each kind accepts; nil while the kind is not built.
    public var accepts: Set<ContentBlock.BlockType>? {
        switch self {
        case .toast: [.text]
        case .dialog: nil
        }
    }

    // "aside" was a kind from 2026.11.09 to 2026.11.17. An agent that still
    // asks for one is told what to do instead: an instruction file written
    // before then may still name it.
    public static let removedAside = "aside"
    public static let asideRemoved = "display aside was removed; answer with a toast, or write a file and say where it is" // TODO(copy): copy
}

public let notifyAccepts: Set<ContentBlock.BlockType> = [.text]

public struct DisplayParams: Equatable, Sendable, Encodable {
    public var kind: DisplayKind
    // Normalized: always blocks on the app side.
    public var content: [ContentBlock]
    // toast only. Stays until dismissed.
    public var alert: Bool?
    // toast only. Takes the place of the agent's own toast, on screen or
    // waiting, instead of queueing behind it.
    public var replace: Bool?

    public init(kind: DisplayKind, content: [ContentBlock], alert: Bool? = nil, replace: Bool? = nil) {
        self.kind = kind
        self.content = content
        self.alert = alert
        self.replace = replace
    }
}

public struct NotifyParams: Equatable, Sendable, Encodable {
    public var content: [ContentBlock]
    public var title: String?

    public init(content: [ContentBlock], title: String? = nil) {
        self.content = content
        self.title = title
    }
}

public struct SpeakParams: Equatable, Sendable, Encodable {
    public var text: String
    public var voice: String?

    public init(text: String, voice: String? = nil) {
        self.text = text
        self.voice = voice
    }
}

// last: nothing is asked for. The socket the request arrives on names the
// agent, and the app knows that agent's last display.
public struct LastParams: Equatable, Sendable, Encodable {
    public init() {}
}

public struct PeerMessageParams: Equatable, Sendable, Codable {
    public let sender: String
    public let text: String
}

// A validated request's method and params.
public enum Call: Equatable, Sendable {
    case display(DisplayParams)
    case notify(NotifyParams)
    case speak(SpeakParams)
    case last(LastParams)
    case agentMessage(PeerMessageParams)

    public var method: Method {
        switch self {
        case .display: .display
        case .notify: .notify
        case .speak: .speak
        case .last: .last
        case .agentMessage: .agentMessage
        }
    }
}

// What a result carries, per method.
public enum MethodResult: Equatable, Sendable, Encodable {
    // display and notify: accepted into the queue, or handed to Notification Center.
    case delivered
    // speak: queued, with the voice selected and whether it fell back.
    case queued(voice: String, fallback: Bool)

    enum CodingKeys: String, CodingKey { case delivered, queued, voice, fallback }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delivered:
            try container.encode(true, forKey: .delivered)
        case .queued(let voice, let fallback):
            try container.encode(true, forKey: .queued)
            try container.encode(voice, forKey: .voice)
            if fallback { try container.encode(true, forKey: .fallback) }
        }
    }
}
