import Foundation

public let jsonrpcVersion = "2.0"
public let siriusProtocolVersion = 1
public let mcpSchemaRevision = "2026-07-28"

public enum RequestId: Hashable, Sendable, Codable {
    case string(String)
    case number(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

public enum Method: String, CaseIterable, Sendable, Codable {
    case display, notify, speak
}

// Open, not an enum: a helper must read a code it does not know as a
// definite rejection, never as a malformed response.
public struct ErrorCode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let parseError = ErrorCode(rawValue: -32700)
    public static let invalidRequest = ErrorCode(rawValue: -32600)
    public static let methodNotFound = ErrorCode(rawValue: -32601)
    public static let invalidParams = ErrorCode(rawValue: -32602)
    public static let internalError = ErrorCode(rawValue: -32603)

    public static let unsupportedVersion = ErrorCode(rawValue: -32001)
    public static let unknownDisplayKind = ErrorCode(rawValue: -32002)
    public static let kindNotAvailable = ErrorCode(rawValue: -32003)
    public static let unsupportedContent = ErrorCode(rawValue: -32004)
    public static let tooLarge = ErrorCode(rawValue: -32005)
    public static let accessDenied = ErrorCode(rawValue: -32006)
    public static let queueFull = ErrorCode(rawValue: -32007)
    public static let notReady = ErrorCode(rawValue: -32008)
}

public struct ErrorData: Equatable, Sendable, Codable {
    public var method: Method?
    public var kind: String?
    public var type: String?
    public var limit: LimitName?
    public var value: Int?
    public var uri: String?
    public var supported: [Int]?

    public init(method: Method? = nil, kind: String? = nil, type: String? = nil, limit: LimitName? = nil,
                value: Int? = nil, uri: String? = nil, supported: [Int]? = nil) {
        self.method = method
        self.kind = kind
        self.type = type
        self.limit = limit
        self.value = value
        self.uri = uri
        self.supported = supported
    }

    enum CodingKeys: String, CodingKey { case method, kind, type, limit, value, uri, supported }

    // Lenient: a field this helper doesn't understand is dropped, so the
    // rejection itself still reads as a rejection.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try? container.decodeIfPresent(Method.self, forKey: .method)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        limit = try? container.decodeIfPresent(LimitName.self, forKey: .limit)
        value = try? container.decodeIfPresent(Int.self, forKey: .value)
        uri = try? container.decodeIfPresent(String.self, forKey: .uri)
        supported = try? container.decodeIfPresent([Int].self, forKey: .supported)
    }
}

public struct RPCError: Error, Equatable, Sendable, Codable {
    public var code: ErrorCode
    public var message: String
    public var data: ErrorData?

    public init(_ code: ErrorCode, _ message: String, data: ErrorData? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// A request as the helper sends it.
public struct Request<Params: Encodable & Sendable>: Encodable, Sendable {
    public var jsonrpc = jsonrpcVersion
    public var sirius = siriusProtocolVersion
    public var id: RequestId
    public var method: Method
    public var params: Params

    public init(id: RequestId, method: Method, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

// A response as the app sends it: a result or an error, never both.
public struct Response: Encodable, Sendable {
    public var jsonrpc = jsonrpcVersion
    public var sirius = siriusProtocolVersion
    public var id: RequestId?
    public var outcome: Outcome

    public enum Outcome: Sendable {
        case result(MethodResult)
        case error(RPCError)
    }

    public init(id: RequestId?, _ outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, sirius, id, result, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(sirius, forKey: .sirius)
        // null when the request's id was missing or invalid.
        try container.encode(id, forKey: .id)
        switch outcome {
        case .result(let result): try container.encode(result, forKey: .result)
        case .error(let error): try container.encode(error, forKey: .error)
        }
    }
}

// A response as the helper reads it. The result stays JSON: the helper
// prints or returns it, and reads only the fields it needs.
public struct Reply: Equatable, Sendable {
    public var id: RequestId?
    public var outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case result(JSONValue)
        case error(RPCError)
    }

    public struct Malformed: Error {}

    // Strict about the envelope: both version tags, an id (null only on an
    // error, answering a request whose id the app could not read), and
    // exactly one of result and error. After a request was sent anything
    // less must read as an unknown outcome, never as a definite answer.
    // Lenient inside the error: an unknown code or odd
    // data is still a rejection. Matching the id to the request is the
    // caller's check.
    public static func parse(_ data: Data) throws -> Reply {
        guard let object = (try? JSONValue.parse(data))?.object,
              object["jsonrpc"]?.string == jsonrpcVersion,
              object["sirius"]?.safeInteger == Int64(siriusProtocolVersion),
              let rawId = object["id"] else { throw Malformed() }
        let id: RequestId?
        if let string = rawId.string {
            id = .string(string)
        } else if let number = rawId.safeInteger {
            id = .number(number)
        } else if rawId == .null {
            id = nil
        } else {
            throw Malformed()
        }
        switch (object["result"], object["error"]) {
        case (let result?, nil):
            guard id != nil else { throw Malformed() }
            return Reply(id: id, outcome: .result(result))
        case (nil, let error?):
            guard let encoded = try? JSONEncoder().encode(error),
                  let decoded = try? JSONDecoder().decode(RPCError.self, from: encoded) else { throw Malformed() }
            return Reply(id: id, outcome: .error(decoded))
        default:
            throw Malformed()
        }
    }
}
