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
    // Code's fastMode setting. Absent: the harness's default (isFast): on
    // for Codex, off for Claude.
    public var fast: Bool?
    // Consolidation (architecture.md §5.1): once the agent has been idle
    // consolidate_after_idle minutes with more than consolidate_threshold
    // tokens of context, Sirius shrinks its context to a short log of
    // pointers. Absent: 15 minutes and 100,000 tokens; 0 minutes: never.
    public var consolidateAfterIdle: Int?
    public var consolidateThreshold: Int?
    // Whether Sirius runs the agent. Off: it isn't started, isn't in the
    // composer's rotation and can't be sent to; its folder, session and
    // settings stay. Absent: on.
    public var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case agent, name, harness, executable, root, voice, model, effort, fast, enabled
        case consolidateAfterIdle = "consolidate_after_idle"
        case consolidateThreshold = "consolidate_threshold"
    }

    public enum Harness: String, CaseIterable, Sendable, Codable {
        // In the order Settings and onboarding list them.
        case claudeCode = "claude-code"
        case codex
        // Cursor's CLI and Google's Antigravity CLI, both over ACP.
        case cursor
        case antigravity
        case museCode = "muse-code"
    }

    public init(agent: String, name: String, harness: Harness, executable: String, root: String,
                voice: String? = nil, model: String? = nil, effort: String? = nil, fast: Bool? = nil,
                consolidateAfterIdle: Int? = nil, consolidateThreshold: Int? = nil, enabled: Bool? = nil) {
        self.enabled = enabled
        self.consolidateAfterIdle = consolidateAfterIdle
        self.consolidateThreshold = consolidateThreshold
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

    // Whether a harness runs fast when agent.json leaves `fast` out: Codex
    // does, since the composer shows the bolt;
    // Claude does not.
    public static func defaultFast(_ harness: Harness) -> Bool {
        harness == .codex
    }

    // The agent's fast mode: `fast` as written, else its harness's default.
    // Only an explicit false turns Codex's off.
    public var isFast: Bool { fast ?? Self.defaultFast(harness) }

    // Only an explicit false turns an agent off.
    public var isEnabled: Bool { enabled ?? true }

    // [a-z0-9-]{1,32}
    public static func isValidId(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count)
            && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}

// ~/Library/Application Support/Sirius/agents/<agent>/state.json. Written
// only by the app.
public struct AgentState: Equatable, Sendable, Codable {
    // Resume id: Claude session, Codex thread, Muse or ACP session. Absent until the first turn.
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

    // What a helper waits for its receipt: the base (SIRIUS_TIMEOUT, or
    // defaultTimeoutSeconds) plus a transfer allowance for the frame's size
    // (Limits.frameBytesPerSecond beyond Limits.freeFrameBytes).
    public static func receiptTimeout(base: TimeInterval, frameBytes: Int) -> TimeInterval {
        base + Double(max(0, frameBytes - Limits.freeFrameBytes)) / Double(Limits.frameBytesPerSecond)
    }
}
