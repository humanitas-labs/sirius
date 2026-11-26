// Whether the user is in the middle of saying something to an agent: a
// dictation hold, or the composer open. The agent host asks before it
// consolidates or rotates an idle agent, so a message on its way does not
// wait behind that step (AgentTurnQueue). Made before the composer and the
// dictation service exist, and told how to ask once they do.
@MainActor
final class ComposingProbe: Sendable {
    var isComposing: () -> Bool = { false }

    nonisolated init() {}
}
