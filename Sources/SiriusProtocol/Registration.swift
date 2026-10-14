import Foundation

// ~/.agents/registry/<agent>/agent.json. Who the agent is; Sirius's own
// state for it is AgentState.
public struct AgentRegistration: Equatable, Sendable, Codable {
    // Folder and socket name. Fixed after setup.
    public var agent: String
    // Shown in the UI.
    public var name: String
    // Selects the adapter.
    public var harness: Harness
    // Absolute path, found at setup.
    public var executable: String
    // Folder the agent works in. Changing it starts a new session.
    public var root: String
    // Default voice for speak. Absent: the app's default.
    public var voice: String?
    // The harness's official model id, e.g. "claude-opus-5-5" or
    // "gpt-6-astra". Absent: the user's own default for that harness. Passed
    // through as written; the harness rejects one it does not know.
    public var model: String?
    // Reasoning effort, in the harness's words (Claude: low…max; Codex: what
    // the model offers). Absent: the user's own default.
    public var effort: String?
    // Sirius's fast mode for this agent; each adapter
    // maps it to its harness's own: Codex's priority tier ("Fast"), Claude
    // Code's fastMode setting. Absent or false: the user's own default.
    public var fast: Bool?

    public enum Harness: String, CaseIterable, Sendable, Codable {
        case claudeCode = "claude-code"
        case codex
    }

    public init(agent: String, name: String, harness: Harness, executable: String, root: String,
                voice: String? = nil, model: String? = nil, effort: String? = nil, fast: Bool? = nil) {
        self.agent = agent
        self.name = name
        self.harness = harness
        self.executable = executable
        self.root = root
        self.voice = voice
        self.model = model
        self.effort = effort
        self.fast = fast
    }

    // [a-z0-9-]{1,32}
    public static func isValidId(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count)
            && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}

// ~/Library/Application Support/Sirius/agents/<agent>/state.json. Written
// only by the app.
public struct AgentState: Equatable, Sendable, Codable {
    // Resume id: Claude session, Codex thread. Absent until the first turn.
    public var session: String?

    public init(session: String? = nil) {
        self.session = session
    }
}

// The environment the adapter gives every agent process.
public enum SiriusEnvironment {
    public static let socket = "SIRIUS_SOCKET"
    public static let timeout = "SIRIUS_TIMEOUT"
    public static let defaultTimeoutSeconds = 10
}
