import Darwin

// Why the socket server could not start, or could not add an agent's socket.
public enum SocketServerError: Error, Equatable, Sendable, CustomStringConvertible {
    // confstr(_CS_DARWIN_USER_TEMP_DIR) gave nothing.
    case temporaryDirectoryUnavailable
    // The socket directory exists but is not a directory owned by the user at 0700.
    case directoryUnsafe(path: String, reason: String)
    // Another instance holds sirius.lock. The app exits on this.
    case alreadyRunning(lockPath: String)
    case invalidAgentId(String)
    // The socket path does not fit sockaddr_un (104 bytes including the NUL).
    case pathTooLong(path: String, bytes: Int)
    case agentExists(String)
    // Something other than a socket sits where the agent's socket goes.
    case pathOccupied(String)
    // close() was called.
    case closed
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case .temporaryDirectoryUnavailable:
            return "The per-user temporary directory is unavailable"
        case .directoryUnsafe(let path, let reason):
            return "Refusing socket directory \(path): \(reason)"
        case .alreadyRunning(let lockPath):
            return "Sirius is already running (\(lockPath) is locked)"
        case .invalidAgentId(let id):
            return "Invalid agent id \"\(id)\": must match [a-z0-9-]{1,32}"
        case .pathTooLong(let path, let bytes):
            return "Socket path \(path) is \(bytes) bytes with its NUL; the limit is under 104"
        case .agentExists(let agent):
            return "Agent \(agent) already has a socket"
        case .pathOccupied(let path):
            return "\(path) exists and is not a socket"
        case .closed:
            return "The socket server is closed"
        case .system(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }

    static func posix(_ call: String) -> SocketServerError {
        .system(call: call, errno: errno)
    }
}
