import Foundation
import SiriusProtocol

// The socket client both helpers share. One call per connection: connect,
// write one frame, read one response line, close. It never retries, since a
// retry after a lost receipt would show or speak the same thing twice. It
// never prints or exits; the helper maps the Outcome to its own output.
public struct SiriusClient: Sendable {
    public var socketPath: String
    // Covers connect, write and read together.
    public var timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = TimeInterval(SiriusEnvironment.defaultTimeoutSeconds)) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    // Reads SIRIUS_SOCKET and SIRIUS_TIMEOUT.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SiriusClient {
        guard let path = environment[SiriusEnvironment.socket], !path.isEmpty else {
            throw ConfigurationError.socketNotSet
        }
        var timeout = TimeInterval(SiriusEnvironment.defaultTimeoutSeconds)
        if let raw = environment[SiriusEnvironment.timeout] {
            guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
                  seconds.isFinite, seconds > 0 else {
                throw ConfigurationError.invalidTimeout(raw)
            }
            timeout = seconds
        }
        return SiriusClient(socketPath: path, timeout: timeout)
    }

    // A fresh string id. One call per connection, so it only has to be
    // unique enough to tell requests apart in the app's log.
    public static func newRequestId() -> RequestId {
        .string(UUID().uuidString.lowercased())
    }

    // Sends method and params under a new id. Params may be typed
    // (DisplayParams) or raw JSON passed through untouched (JSONValue).
    public func call<Params: Encodable & Sendable>(_ method: SiriusProtocol.Method, params: Params) -> Outcome {
        call(Request(id: Self.newRequestId(), method: method, params: params))
    }

    public func call<Params: Encodable & Sendable>(_ request: Request<Params>) -> Outcome {
        let frame: Data
        do {
            frame = try encodeFrame(request)
        } catch {
            // Nothing was sent. Only a non-finite number in the params can
            // get here, which the app would have rejected anyway.
            return .error(RPCError(.invalidParams, "Could not encode the request: \(error)"))
        }
        return exchange(frame: frame, id: request.id)
    }

    // The transport alone, for a frame that is already encoded.
    public func exchange(frame: Data, id: RequestId) -> Outcome {
        let line: Data
        do {
            line = try UnixSocket.exchange(path: socketPath, frame: frame, timeout: timeout)
        } catch let failure as TransportFailure {
            return failure.outcome
        } catch {
            return .unknown(.connectionLost)
        }
        // Reply.parse checks the envelope; the id must also be
        // this request's, so a null id fails here: this client always sends
        // a valid one.
        guard let reply = try? Reply.parse(line), reply.id == id else {
            return .unknown(.malformedResponse)
        }
        switch reply.outcome {
        case .result(let value): return .result(value)
        case .error(let error): return .error(error)
        }
    }
}

// The environment is missing or wrong; nothing was sent.
public enum ConfigurationError: Error, Equatable, Sendable {
    case socketNotSet
    case invalidTimeout(String)

    // A missing socket means the helper was not started by Sirius, so
    // Sirius cannot be reached: 3, like not running. Nothing was sent and
    // the command line was fine, so 2 would wrongly tell the agent to fix
    // its arguments. A bad timeout is a malformed invocation: 2.
    public var exitCode: Int32 {
        switch self {
        case .socketNotSet: ExitStatus.notRunning
        case .invalidTimeout: ExitStatus.usage
        }
    }

    public var message: String {
        switch self {
        case .socketNotSet:
            "Sirius isn't running (\(SiriusEnvironment.socket) is not set; run from an agent Sirius started)"
        case .invalidTimeout(let raw):
            "\(SiriusEnvironment.timeout) must be a positive number of seconds, not \"\(raw)\""
        }
    }
}

// The helpers' exit codes, from proto.ts's CLI mapping.
public enum ExitStatus {
    public static let result: Int32 = 0
    public static let errorResponse: Int32 = 1
    public static let usage: Int32 = 2
    public static let notRunning: Int32 = 3
    public static let outcomeUnknown: Int32 = 4
}
