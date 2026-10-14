import Foundation

// Where one finished transcript goes: into the open
// composer, at the cursor, or to an agent as a message. A paste hold (⌃fn,
// HoldKey.pasteModifier) goes to the cursor; a plain hold goes to an agent.
// The spoken "Dictate:" prefix stays gone.
// Pure, so the app's SiriusDelivery only carries it out.
public enum DictationDestination: Equatable, Sendable {
    // The composer is open: the whole transcript at its caret, prefixes and
    // all: with the composer open, fn dictates into it.
    case composer(String)
    // A paste hold: the whole transcript at the cursor of the frontmost app.
    case cursor(String)
    // A message for an agent: one named in the transcript, or the
    // composer's selected agent.
    case agent(String, String)
    // Nothing to deliver: an empty body ("Codex," alone), or no agent to
    // send to. Dropped silently.
    case nothing

    // `selected` is the composer's current agent, and a transcript with no
    // agent's name goes to it even when `agents` lacks it: that list can be
    // stale, and a send to another agent is worse than one that fails
    // loudly (2026.10.11). The first agent stands in only when nothing is
    // selected.
    //
    // A paste hold never reads agent names: the transcript is text to type.
    // It goes into the composer only when `composerFocused`, the composer
    // being the frontmost window; an open composer behind another app
    // leaves the paste to that app.
    public static func of(
        _ text: String,
        mode: DictationMode = .agent,
        composerOpen: Bool,
        composerFocused: Bool = false,
        selected: String?,
        agents: [DictationAddress]
    ) -> DictationDestination {
        if mode == .paste {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
            return composerFocused ? .composer(text) : .cursor(text)
        }
        if composerOpen {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .composer(text)
        }
        switch DictationRouter.route(text, agents: agents) {
        case .agent(let agent, let body):
            return body.isEmpty ? .nothing : .agent(agent, body)
        case .selected(let body):
            guard !body.isEmpty else { return .nothing }
            let agent = selected ?? agents.first?.agent
            return agent.map { .agent($0, body) } ?? .nothing
        }
    }

    // The agent a hold's transcript is going to before the text is in:
    // the composer's selected agent, else the first one, as `of` sends a
    // transcript that names none. Nil when it is not going to an agent: a
    // paste hold, or the open composer. For the pill, which opens on that
    // agent's logo.
    public static func agent(
        mode: DictationMode = .agent,
        composerOpen: Bool,
        selected: String?,
        agents: [DictationAddress]
    ) -> String? {
        guard mode == .agent, !composerOpen else { return nil }
        return selected ?? agents.first?.agent
    }
}
