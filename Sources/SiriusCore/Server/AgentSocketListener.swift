import Darwin
import Dispatch

// One agent's listening socket and its open connections. Confined to the
// server's io queue like AgentSocketConnection.
final class AgentSocketListener: @unchecked Sendable {
    let agent: String
    let path: String
    private let fd: Int32
    private let io: DispatchQueue
    private let settings: SocketServerSettings
    private let commands: any CommandQueue
    private var source: DispatchSourceRead?
    private var connections: [ObjectIdentifier: AgentSocketConnection] = [:]

    init(agent: String, path: String, fd: Int32, io: DispatchQueue, settings: SocketServerSettings,
         commands: any CommandQueue) {
        self.agent = agent
        self.path = path
        self.fd = fd
        self.io = io
        self.settings = settings
        self.commands = commands
    }

    var connectionCount: Int { connections.count }

    func start() {
        dispatchPrecondition(condition: .onQueue(io))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [unowned self] in acceptPending() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    // Stops accepting, closes every open connection and the listening fd.
    // The caller unlinks the path.
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(io))
        source?.cancel()
        source = nil
        for connection in Array(connections.values) { connection.finish() }
        connections.removeAll()
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // EAGAIN: nothing left. Anything else: try again on the next event.
                return
            }
            guard (try? UnixDomainSocket.configure(client)) != nil,
                  connections.count < settings.maxConnections,
                  settings.peerCheck.allows(client) else {
                // Over the cap, another user, or unusable: closed with no response.
                Darwin.close(client)
                continue
            }
            let connection = AgentSocketConnection(
                fd: client, agent: agent, io: io, settings: settings, commands: commands,
                onFinish: { [weak self] connection in
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                })
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }
}
