// The unit the user sends from the composer to one agent. How it is rendered
// for the agent (the <sirius> wrapper, MessageRenderer in SiriusCore) is
// the adapter layer's job.
public struct Message: Equatable, Sendable, Codable {
    // TODO(andrew): the id format; "m_" plus a short random id for now.
    public var id: String
    public var agent: String
    // The user's words, verbatim.
    public var text: String
    public var attachments: [Attachment]

    public struct Attachment: Equatable, Sendable, Codable {
        // Absolute path under the agent's attachments/<message>/ folder.
        public var path: String
        public var mimeType: String

        public init(path: String, mimeType: String) {
            self.path = path
            self.mimeType = mimeType
        }
    }

    public init(id: String, agent: String, text: String, attachments: [Attachment] = []) {
        self.id = id
        self.agent = agent
        self.text = text
        self.attachments = attachments
    }
}
