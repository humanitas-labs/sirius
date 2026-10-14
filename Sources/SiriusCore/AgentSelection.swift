import Foundation

// The composer's agent: the one the user chose, kept
// apart from the agents the host last listed. A list that momentarily lacks
// the chosen agent (read before the host started, a registry reload) never
// replaces the choice; only the user's own switch does. With no choice yet,
// the first listed agent stands in, unstored. Pure, so it is tested.
public struct AgentSelection: Equatable, Sendable {
    // The user's choice, as stored; nil until they switch.
    public private(set) var chosen: String?
    // The agent ids as the host last listed them.
    public var listed: [String]

    public init(chosen: String?, listed: [String] = []) {
        self.chosen = chosen
        self.listed = listed
    }

    // Where the composer and dictation send: the choice, even when the
    // list lacks it (the host refuses a send to an unregistered agent, and
    // the send fails loudly), else the first listed agent.
    public var current: String? { chosen ?? listed.first }

    // Whether the last list has the current agent.
    public var isListed: Bool { current.map(listed.contains) ?? false }

    // A switch straight to `agent`, which becomes the choice; false when
    // it already was.
    @discardableResult
    public mutating func choose(_ agent: String) -> Bool {
        guard chosen != agent else { return false }
        chosen = agent
        return true
    }

    // The user's switch to the next listed agent, which becomes the choice
    // and is returned for storing; nil when nothing is listed. From a
    // choice the list lacks, it goes to the first.
    public mutating func next() -> String? {
        guard !listed.isEmpty else { return nil }
        let index = current.flatMap { listed.firstIndex(of: $0) } ?? -1
        chosen = listed[(index + 1) % listed.count]
        return chosen
    }
}
