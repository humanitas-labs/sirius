public enum DisplayKind: String, CaseIterable, Sendable, Codable {
    case toast, dialog, aside

    // The block types each kind accepts; nil while the kind is not built.
    public var accepts: Set<ContentBlock.BlockType>? {
        switch self {
        case .toast: [.text]
        case .dialog, .aside: nil
        }
    }
}

public let notifyAccepts: Set<ContentBlock.BlockType> = [.text]

public struct DisplayParams: Equatable, Sendable, Encodable {
    public var kind: DisplayKind
    // Normalized: always blocks on the app side.
    public var content: [ContentBlock]
    // toast only. Stays until dismissed.
    public var alert: Bool?
    // aside only. Deferred.
    public var session: String?

    public init(kind: DisplayKind, content: [ContentBlock], alert: Bool? = nil, session: String? = nil) {
        self.kind = kind
        self.content = content
        self.alert = alert
        self.session = session
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

// A validated request's method and params.
public enum Call: Equatable, Sendable {
    case display(DisplayParams)
    case notify(NotifyParams)
    case speak(SpeakParams)

    public var method: Method {
        switch self {
        case .display: .display
        case .notify: .notify
        case .speak: .speak
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
