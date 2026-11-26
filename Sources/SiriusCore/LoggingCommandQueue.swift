import Foundation
import SiriusProtocol

// Files every command the socket server accepts in its agent's log, then
// hands it to the inner queue (the presenters) unchanged (architecture.md
// §4, step 5). The command is logged against the agent's current message,
// else its most recent one. Agents without a log here (the "dev" socket)
// pass straight through. A log write that fails is reported, never a reason
// to drop the command.
public final class LoggingCommandQueue: CommandQueue, @unchecked Sendable {
    private let inner: any CommandQueue
    private let report: @Sendable (String) -> Void
    // The agents' last displays, for `last`: seeded here from each log as
    // it is registered (the log's own recovery read found it) and recorded
    // by the inner queue as it accepts displays.
    private let responses: LastResponses?
    private let lock = NSLock()
    // Guarded by lock.
    private var logs: [String: AgentLog] = [:]

    private var turnQueues: [String: AgentTurnQueue] = [:]

    public init(inner: any CommandQueue, report: @escaping @Sendable (String) -> Void = { SiriusLog.agents.error($0) },
                responses: LastResponses? = nil) {
        self.inner = inner
        self.report = report
        self.responses = responses
    }

    // Commands arriving on `agent`'s socket are filed in `log` from now on.
    public func register(_ log: AgentLog, for agent: String) {
        lock.withLock { logs[agent] = log }
        if let found = log.lastDisplay {
            responses?.record(LastResponse(agent: agent, display: found))
        } else {
            responses?.remove(agent: agent)
        }
    }

    public func register(_ queue: AgentTurnQueue, for agent: String) {
        lock.withLock { turnQueues[agent] = queue }
    }

    public func unregister(agent: String) {
        lock.withLock {
            logs[agent] = nil
            turnQueues[agent] = nil
        }
        responses?.remove(agent: agent)
    }

    public func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
        if case .agentMessage(let peer) = command.call {
            guard case .string(let id) = command.id, UUID(uuidString: id) != nil else {
                return .failure(RPCError(.invalidParams, "Peer messages require a UUID request id"))
            }
            guard let queue = lock.withLock({ turnQueues[command.agent] }) else {
                return .failure(RPCError(.notReady, "Agent is unavailable"))
            }
            do {
                try await queue.send(Message(id: id.lowercased(), agent: command.agent, text: peer.text,
                                             peerSender: peer.sender))
                return .success(.delivered)
            } catch {
                return .failure(RPCError(.internalError, "Could not queue peer message: \(error)"))
            }
        }
        if let log = lock.withLock({ logs[command.agent] }) {
            do {
                try await log.commandReceived(command)
            } catch {
                report("Sirius: could not log \(command.call.method.rawValue) from \(command.agent): \(error)")
            }
        }
        return await inner.accept(command)
    }
}
