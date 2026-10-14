import Foundation
import SiriusAdapters

// The composer's view of the agent host: the registered agents, and a send
// that queues the message for its agent.
@MainActor
final class HostComposerTarget: ComposerTarget {
    private let host: AgentHost

    init(host: AgentHost) {
        self.host = host
    }

    func composerAgents() async -> [ComposerAgent] {
        await host.agents().map { ComposerAgent(id: $0.agent, name: $0.name, harness: $0.harness, fast: $0.fast) }
    }

    func send(text: String, attachments: [URL], to agent: String) async throws {
        _ = try await host.send(text: text, attachments: attachments, to: agent)
    }

    // The onboarding's guided first turn, in a throwaway session
    // (AgentHost.sendFirstTurn).
    func sendFirstTurn(text: String, to agent: String) async throws {
        _ = try await host.sendFirstTurn(text: text, to: agent)
    }
}
