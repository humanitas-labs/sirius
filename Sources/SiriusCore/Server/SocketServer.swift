import Darwin
import Dispatch
import Foundation
import SiriusProtocol

// The app's side of the transport (proto.ts, Transport): one Unix socket
// per agent under $TMPDIR/sirius/, one request per connection, each valid
// request handed to the CommandQueue and answered with what it returns.
//
// Creating a SocketServer takes the instance lock; a second instance gets
// SocketServerError.alreadyRunning and should exit. All IO runs on one
// private serial queue; the public methods may be called from any thread
// but block briefly on it.
public final class SocketServer: @unchecked Sendable {
    public let directory: String
    private let commands: any CommandQueue
    private let settings: SocketServerSettings
    private let io = DispatchQueue(label: "sirius.socket-server")
    // Confined to io.
    private var lock: InstanceLock?
    private var listeners: [String: AgentSocketListener] = [:]

    // $TMPDIR/sirius/ from confstr.
    public convenience init(commands: any CommandQueue) throws {
        try self.init(commands: commands, directory: SocketDirectory.defaultPath())
    }

    public convenience init(commands: any CommandQueue, directory: String) throws {
        try self.init(commands: commands, directory: directory, settings: SocketServerSettings())
    }

    init(commands: any CommandQueue, directory: String, settings: SocketServerSettings) throws {
        try SocketDirectory.prepare(directory)
        let lock = try InstanceLock(path: (directory as NSString).appendingPathComponent(SocketDirectory.lockName))
        // We hold the lock, so every socket node here is a dead instance's.
        SocketDirectory.sweepStaleSockets(in: directory)
        self.directory = directory
        self.commands = commands
        self.settings = settings
        self.lock = lock
    }

    deinit {
        // Nothing else references self now; hand the teardown to io so it
        // stays ordered after any work already queued there.
        let listeners = Array(listeners.values)
        let lock = lock
        io.async {
            for listener in listeners {
                listener.shutdown()
                unlink(listener.path)
            }
            lock?.release()
        }
    }

    // <dir>/<agent>.sock, after the id and 104-byte checks. The registry can
    // call this before it accepts an agent.
    public func socketPath(for agent: String) throws -> String {
        try SocketDirectory.socketPath(directory: directory, agent: agent)
    }

    // Binds and starts listening on the agent's socket. Returns its path,
    // the agent's SIRIUS_SOCKET.
    @discardableResult
    public func add(agent: String) throws -> String {
        dispatchPrecondition(condition: .notOnQueue(io))
        let path = try socketPath(for: agent)
        return try io.sync {
            guard lock != nil else { throw SocketServerError.closed }
            guard listeners[agent] == nil else { throw SocketServerError.agentExists(agent) }
            try SocketDirectory.removeStaleSocket(at: path)
            let fd = try UnixDomainSocket.listen(path: path)
            let listener = AgentSocketListener(agent: agent, path: path, fd: fd, io: io, settings: settings,
                                               commands: commands)
            listeners[agent] = listener
            listener.start()
            return path
        }
    }

    // Unlinks the agent's socket and closes it and its open connections,
    // answered or not. No-op for an unknown agent.
    public func remove(agent: String) {
        dispatchPrecondition(condition: .notOnQueue(io))
        io.sync {
            guard let listener = listeners.removeValue(forKey: agent) else { return }
            unlink(listener.path)
            listener.shutdown()
        }
    }

    public var agents: [String] {
        io.sync { listeners.keys.sorted() }
    }

    // Closes every socket and connection, unlinks the sockets, then releases
    // the lock. The lock goes last so a new instance never binds a socket an
    // old one is still about to unlink. sirius.lock itself stays.
    public func close() {
        dispatchPrecondition(condition: .notOnQueue(io))
        io.sync {
            for listener in listeners.values {
                unlink(listener.path)
                listener.shutdown()
            }
            listeners.removeAll()
            lock?.release()
            lock = nil
        }
    }

    func connectionCount(agent: String) -> Int {
        io.sync { listeners[agent]?.connectionCount ?? 0 }
    }
}

// The transport limits, injectable so tests need not wait out the real ones.
struct SocketServerSettings: Sendable {
    var maxRequestBytes = Limits.maxRequestBytes
    var readDeadline = TimeInterval(Limits.readDeadlineSeconds)
    // Not in LIMITS: how long a response may take to drain to a helper that
    // stopped reading. Same value as the read deadline.
    var writeDeadline = TimeInterval(Limits.readDeadlineSeconds)
    var maxConnections = Limits.maxConnectionsPerAgent
    var peerCheck = PeerCheck()
}
