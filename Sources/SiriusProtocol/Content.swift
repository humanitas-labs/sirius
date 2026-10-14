import Foundation

// A string, or MCP content blocks as defined by mcpSchemaRevision. At the
// boundary a string becomes one text block, once, and is never parsed again.
public enum ContentBlock: Equatable, Sendable {
    case text(TextContent)
    case image(MediaContent)
    case audio(MediaContent)
    case resourceLink(ResourceLink)
    case resource(EmbeddedResource)

    public enum BlockType: String, CaseIterable, Sendable, Codable {
        case text, image, audio
        case resourceLink = "resource_link"
        case resource
    }

    public var type: BlockType {
        switch self {
        case .text: .text
        case .image: .image
        case .audio: .audio
        case .resourceLink: .resourceLink
        case .resource: .resource
        }
    }
}

public struct TextContent: Equatable, Sendable, Codable {
    public var text: String
    public var annotations: Annotations?
    public var _meta: [String: JSONValue]?

    public init(text: String, annotations: Annotations? = nil, _meta: [String: JSONValue]? = nil) {
        self.text = text
        self.annotations = annotations
        self._meta = _meta
    }
}

// image and audio share a shape: base64 data and a MIME type.
public struct MediaContent: Equatable, Sendable, Codable {
    public var data: String
    public var mimeType: String
    public var annotations: Annotations?
    public var _meta: [String: JSONValue]?

    public init(data: String, mimeType: String, annotations: Annotations? = nil, _meta: [String: JSONValue]? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
        self._meta = _meta
    }
}

public struct ResourceLink: Equatable, Sendable, Codable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Double?
    // Never fetched.
    public var icons: [Icon]?
    public var annotations: Annotations?
    public var _meta: [String: JSONValue]?

    public init(uri: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil,
                size: Double? = nil, icons: [Icon]? = nil, annotations: Annotations? = nil,
                _meta: [String: JSONValue]? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.icons = icons
        self.annotations = annotations
        self._meta = _meta
    }
}

public struct Icon: Equatable, Sendable, Codable {
    public var src: String
    public var mimeType: String?
    public var sizes: [String]?
    public var theme: Theme?

    public init(src: String, mimeType: String? = nil, sizes: [String]? = nil, theme: Theme? = nil) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }

    public enum Theme: String, Sendable, Codable { case light, dark }
}

public struct EmbeddedResource: Equatable, Sendable, Codable {
    public var resource: ResourceContents
    public var annotations: Annotations?
    public var _meta: [String: JSONValue]?

    public init(resource: ResourceContents, annotations: Annotations? = nil, _meta: [String: JSONValue]? = nil) {
        self.resource = resource
        self.annotations = annotations
        self._meta = _meta
    }
}

public struct ResourceContents: Equatable, Sendable, Codable {
    public var uri: String
    public var mimeType: String?
    // Exactly one of text and blob (base64).
    public var text: String?
    public var blob: String?
    public var _meta: [String: JSONValue]?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil,
                _meta: [String: JSONValue]? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
        self._meta = _meta
    }
}

// Hints only, never instructions.
public struct Annotations: Equatable, Sendable, Codable {
    public var audience: [Role]?
    public var priority: Double?
    public var lastModified: String?

    public init(audience: [Role]? = nil, priority: Double? = nil, lastModified: String? = nil) {
        self.audience = audience
        self.priority = priority
        self.lastModified = lastModified
    }

    public enum Role: String, Sendable, Codable { case user, assistant }
}

extension ContentBlock: Encodable {
    enum TypeKey: String, CodingKey { case type }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .text(let block): try block.encode(to: encoder)
        case .image(let block), .audio(let block): try block.encode(to: encoder)
        case .resourceLink(let block): try block.encode(to: encoder)
        case .resource(let block): try block.encode(to: encoder)
        }
    }
}

extension ContentBlock {
    // Text blocks joined with "\n", as toast and notify present them.
    public static func joinedText(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { if case .text(let block) = $0 { block.text } else { nil } }
            .joined(separator: "\n")
    }
}
