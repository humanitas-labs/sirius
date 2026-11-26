import Foundation
import SiriusProtocol

// The last display an agent sent, for `last` (proto.ts): what the user can
// ask to see again, on demand, exactly as it was accepted — a toast, an
// alert where the display set one, under the agent's own mark. notify and
// speak are not displays: a notification stays in Notification Center and
// speech was heard; only a toast is gone when it leaves.
//
// It is kept in memory only, so it reaches as far back as the app's
// current opening. At setup each agent's log seeds it (the log's own
// recovery read finds the last display there, at no extra IO), and every
// display the queue accepts records it live. A display the queue refused
// (QUEUE_FULL) is not the user's to ask for again.
public struct LastResponse: Equatable, Sendable {
    public var agent: String
    // A toast; the alert flag as the display set it.
    public var alert: Bool
    public var text: String
    // The log cut the text at CommandSummary.maxTextChars.
    public var truncated: Bool
    public var at: Date

    public init(agent: String, alert: Bool, text: String, truncated: Bool = false, at: Date) {
        self.agent = agent
        self.alert = alert
        self.text = text
        self.truncated = truncated
        self.at = at
    }

    // From what a log's recovery read found, `agent` the log's own.
    public init(agent: String, display: LoggedDisplay) {
        self.init(agent: agent, alert: display.summary.alert ?? false, text: display.summary.text ?? "",
                  truncated: display.summary.truncated ?? false, at: display.at)
    }
}

// What an agent's log carries of its last display: the command summary and
// when it was accepted. Found in the log's recovery read, which runs at
// every open anyway; nil when the log holds no display.
public struct LoggedDisplay: Equatable, Sendable {
    public var summary: CommandSummary
    public var at: Date

    public init(summary: CommandSummary, at: Date) {
        self.summary = summary
        self.at = at
    }
}

// One LastResponse per agent, seeded from the logs, recorded from the
// queue, read by `last` and the menu item.
public final class LastResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var byAgent: [String: LastResponse] = [:]

    public init() {}

    public func record(_ response: LastResponse) {
        lock.withLock { byAgent[response.agent] = response }
    }

    // What `last` shows again: the agent's latest accepted display.
    public func latest(agent: String) -> LastResponse? {
        lock.withLock { byAgent[agent] }
    }

    // The newest across agents, for the menu's Last response.
    public func newest() -> LastResponse? {
        lock.withLock { byAgent.values.max { $0.at < $1.at } }
    }

    public func remove(agent: String) {
        lock.withLock { byAgent[agent] = nil }
    }
}
