import Darwin
import SiriusProtocol

// What one call came to. The split that matters to the caller is whether
// the request might have been accepted: notRunning means certainly not,
// unknown means it might have been, and must not be sent again.
public enum Outcome: Equatable, Sendable {
    // The app accepted the request; the receipt as JSON.
    case result(JSONValue)
    // The app answered with an error.
    case error(RPCError)
    // The connection failed before a byte was written: nothing could have
    // been accepted.
    case notRunning(NotRunning)
    // Connected and wrote, or began to, with no valid response: the request
    // may have been accepted. Callers must say so, never report a rejection.
    case unknown(Unknown)

    // True when the request may have been accepted without a receipt.
    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public enum NotRunning: Equatable, Sendable {
        // No socket file at the path.
        case noSocket
        // A socket file with no listener.
        case refused
        // connect failed for another reason, with its errno.
        case unreachable(errno: Int32)
        // The deadline passed before connect completed.
        case connectTimedOut
        // Longer than sockaddr_un holds (103 bytes plus NUL).
        case pathTooLong
    }

    public enum Unknown: Equatable, Sendable {
        case timedOut
        // EOF or a socket error before a full response line.
        case connectionLost
        // A line arrived that is not a well-formed response to this
        // request: bad JSON, wrong or missing version tags or id, or not
        // exactly one of result and error.
        case malformedResponse
    }

    public var exitCode: Int32 {
        switch self {
        case .result: ExitStatus.result
        case .error: ExitStatus.errorResponse
        case .notRunning: ExitStatus.notRunning
        case .unknown: ExitStatus.outcomeUnknown
        }
    }

    // One line for stderr, without the program name; nil on a result.
    public var message: String? {
        switch self {
        case .result:
            return nil
        case .error(let error):
            return "\(error.message) (\(error.code.rawValue))"
        case .notRunning(let reason):
            switch reason {
            case .noSocket, .refused: return "Sirius isn't running"
            case .unreachable(let code): return "can't reach Sirius (\(String(cString: strerror(code))))"
            case .connectTimedOut: return "can't reach Sirius (timed out connecting); nothing was sent"
            case .pathTooLong: return "can't reach Sirius (\(SiriusEnvironment.socket) is longer than 103 bytes)"
            }
        case .unknown(let reason):
            let why = switch reason {
            case .timedOut: "timed out"
            case .connectionLost: "connection lost"
            case .malformedResponse: "malformed response"
            }
            return "outcome unknown (\(why)); not retried"
        }
    }
}
