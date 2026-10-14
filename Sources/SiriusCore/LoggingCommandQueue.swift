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
    private let lock = NSLock()
    // Guarded by lock.
    private var logs: [String: AgentLog] = [:]

    public init(inner: any CommandQueue, report: @escaping @Sendable (String) -> Void = { SiriusLog.agents.error($0) }) {
        self.inner = inner
        self.report = report
    }

    // Commands arriving on `agent`'s socket are filed in `log` from now on.
    public func register(_ log: AgentLog, for agent: String) {
        lock.withLock { logs[agent] = log }
    }

    public func unregister(agent: String) {
        lock.withLock { _ = logs.removeValue(forKey: agent) }
    }

    public func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
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
