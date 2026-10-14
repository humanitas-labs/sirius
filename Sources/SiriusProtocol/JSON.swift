import Foundation

// A parsed JSON value. Requests are parsed into this first and validated by
// hand, so every failure maps to the error code proto.ts gives it; Codable
// alone would fold them all into one decoding error.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // Lexical edges, as Foundation's JSONDecoder handles them today and the
    // raw fixtures pin (pending a decision): NaN and Infinity are
    // invalid JSON; a number outside Double's range (1e400, 1e-400) and a
    // lone surrogate escape fail the parse; nesting deeper than 511 fails
    // the parse rather than the stack; a duplicate key keeps its first
    // value; every number becomes a Double, so 1.0000000000000001 reads as 1.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    // An integer that survives a round trip through a double, as JSON-RPC
    // ids and the version tag must.
    public var safeInteger: Int64? {
        guard case .number(let value) = self, value.rounded() == value,
              abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int64(value)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let integer = safeInteger { try container.encode(integer) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// One frame on the socket: compact JSON, keys sorted, terminated by "\n".
public func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}
