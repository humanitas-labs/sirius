import Foundation
import SiriusClient
import SiriusProtocol

// MCP over stdio, the subset a tools-only server needs: initialize,
// notifications/initialized, ping, tools/list, tools/call. One JSON-RPC
// message per line in, at most one per line out.
struct MCPServer {
    static let name = "sirius"
    static let version = "0.1.0"

    // Newest first. A client asking for one of these gets it back; any other
    // gets the newest, and the client decides whether to go on (MCP
    // lifecycle, version negotiation).
    static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    var environment: [String: String]

    // The response line for one input line, or nil when none is due
    // (notifications, responses to requests we never send).
    func handle(_ line: String) -> String? {
        guard let message = try? JSONValue.parse(Data(line.utf8)) else {
            return encode(error: -32700, "Parse error", id: .null)
        }
        guard let object = message.object else {
            // Batches were removed from MCP in 2025-06-18; anything but an
            // object is an invalid request.
            return encode(error: -32600, "Invalid Request", id: .null)
        }
        let id = object["id"]
        guard let method = object["method"]?.string else {
            // A response from the client (we send no requests), or junk.
            if id != nil, object["result"] == nil, object["error"] == nil {
                return encode(error: -32600, "Invalid Request", id: validId(id) ?? .null)
            }
            return nil
        }
        // A notification: no response, whatever it is.
        guard let id else { return nil }
        guard let requestId = validId(id) else {
            return encode(error: -32600, "Invalid Request: id must be a string or an integer", id: .null)
        }
        let params = object["params"] ?? .object([:])
        switch method {
        case "initialize":
            return encode(result: initialize(params), id: requestId)
        case "ping":
            return encode(result: .object([:]), id: requestId)
        case "tools/list":
            return encode(result: .object(["tools": .array(Tool.all.map(\.listing))]), id: requestId)
        case "tools/call":
            guard let name = params["name"]?.string else {
                return encode(error: -32602, "Invalid params: tools/call needs a tool name", id: requestId)
            }
            guard let tool = Tool.named(name) else {
                return encode(error: -32602, "Unknown tool: \(name)", id: requestId)
            }
            return encode(result: call(tool, arguments: params["arguments"]), id: requestId)
        default:
            return encode(error: -32601, "Method not found: \(method)", id: requestId)
        }
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.string
        let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(Self.name),
                "title": .string("Sirius"),
                "version": .string(Self.version),
            ]),
        ])
    }

    // A tool call becomes one Sirius request. Every failure after the tool is
    // found is a tool result with isError, so the model reads it; only a
    // malformed MCP request is a JSON-RPC error.
    func call(_ tool: Tool, arguments: JSONValue?) -> JSONValue {
        let client: SiriusClient
        do {
            client = try SiriusClient.fromEnvironment(environment)
        } catch let error as ConfigurationError {
            return Self.toolResult(error.message + "; nothing was sent.", isError: true)
        } catch {
            return Self.toolResult("\(error); nothing was sent.", isError: true)
        }
        // Absent arguments go as {} so the app answers with its own
        // INVALID_PARAMS message, the same one the CLI would get.
        return Self.result(for: client.call(tool.method, params: arguments ?? .object([:])))
    }

    static func result(for outcome: Outcome) -> JSONValue {
        switch outcome {
        case .result(let receipt):
            return toolResult(compact(receipt), isError: false)
        case .error(let error):
            var detail: [String: JSONValue] = [
                "code": .number(Double(error.code.rawValue)),
                "message": .string(error.message),
            ]
            if let data = error.data, let encoded = try? JSONValue.parse(JSONEncoder().encode(data)) {
                detail["data"] = encoded
            }
            return toolResult(
                "Sirius rejected this request; it was not accepted. \(error.message)\n"
                    + compact(.object(["error": .object(detail)])),
                isError: true)
        case .notRunning:
            return toolResult("\(outcome.message ?? "Sirius isn't running"); nothing was sent.", isError: true)
        case .unknown:
            // Not a rejection: the app may have queued it, and a
            // retry would show or speak it twice.
            return toolResult(
                "The outcome is unknown: \(outcome.message ?? "no response"). Sirius may have accepted "
                    + "this and shown or spoken it. Do not retry it.",
                isError: true)
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    // MCP ids are strings or integers; null is not allowed on a request.
    private func validId(_ id: JSONValue?) -> JSONValue? {
        guard let id else { return nil }
        if id.string != nil || id.safeInteger != nil { return id }
        return nil
    }

    private func encode(result: JSONValue, id: JSONValue) -> String {
        Self.compact(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func encode(error code: Int, _ message: String, id: JSONValue) -> String {
        Self.compact(.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    static func compact(_ value: JSONValue) -> String {
        // encodeFrame cannot fail on values parsed from JSON or built here.
        let frame = (try? encodeFrame(value)) ?? Data("null\n".utf8)
        return String(decoding: frame.dropLast(), as: UTF8.self)
    }
}
