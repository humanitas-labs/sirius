import Foundation

// One frame from the socket, after validation.
public enum Inbound: Equatable, Sendable {
    // Accepted shape: queue it.
    case request(RequestId, Call)
    // No id: JSON-RPC's notification. Not executed, no response.
    case notification
    // Answer with this error. id is nil when the request's was missing or invalid.
    case failure(RequestId?, RPCError)
}

// Validates one frame (without its "\n") in proto.ts's order: envelope,
// then the method's params; for content, normalize, shape, empty, accepted
// types, limits. Unknown fields are ignored, so a newer helper's optional
// field reaches an older app harmlessly. File access (ACCESS_DENIED) and
// queue state (QUEUE_FULL, NOT_READY) are the app's checks, not this one's.
public func validate(frame: Data) -> Inbound {
    guard let json = try? JSONValue.parse(frame) else {
        return .failure(nil, RPCError(.parseError, "Not valid JSON"))
    }
    guard let object = json.object else {
        return .failure(nil, RPCError(.invalidRequest, "A request must be a JSON object"))
    }
    guard let rawId = object["id"] else {
        // Silence is for a well-formed notification only; a malformed frame
        // without an id still gets INVALID_REQUEST with id null.
        guard object["jsonrpc"]?.string == jsonrpcVersion, object["method"]?.string != nil else {
            return .failure(nil, RPCError(.invalidRequest, "Not a valid JSON-RPC request"))
        }
        return .notification
    }
    let id: RequestId
    if let string = rawId.string {
        id = .string(string)
    } else if let number = rawId.safeInteger {
        id = .number(number)
    } else {
        return .failure(nil, RPCError(.invalidRequest, "id must be a string or a safe integer"))
    }
    do {
        return .request(id, try validateRequest(object))
    } catch let error as RPCError {
        return .failure(id, error)
    } catch {
        return .failure(id, RPCError(.internalError, "\(error)"))
    }
}

func validateRequest(_ object: [String: JSONValue]) throws -> Call {
    guard object["jsonrpc"]?.string == jsonrpcVersion else {
        throw RPCError(.invalidRequest, "jsonrpc must be \"2.0\"")
    }
    // A missing tag is answered the same as an unknown one, so a plain
    // JSON-RPC client learns which version to send.
    guard object["sirius"]?.safeInteger == Int64(siriusProtocolVersion) else {
        throw RPCError(.unsupportedVersion, "Unsupported Sirius protocol version",
                       data: ErrorData(supported: [siriusProtocolVersion]))
    }
    guard let name = object["method"]?.string else {
        throw RPCError(.invalidRequest, "method must be a string")
    }
    guard let method = Method(rawValue: name) else {
        throw RPCError(.methodNotFound, "Unknown method \"\(name)\"")
    }
    guard let params = object["params"]?.object else {
        throw RPCError(.invalidParams, "params must be an object", data: ErrorData(method: method))
    }
    switch method {
    case .display: return .display(try validateDisplay(params))
    case .notify: return .notify(try validateNotify(params))
    case .speak: return .speak(try validateSpeak(params))
    }
}

// MARK: - Methods

func validateDisplay(_ params: [String: JSONValue]) throws -> DisplayParams {
    let method = Method.display
    guard let name = params["kind"]?.string else {
        throw invalid(method, "kind must be a string")
    }
    guard let kind = DisplayKind(rawValue: name) else {
        throw RPCError(.unknownDisplayKind, "Unknown display kind \"\(name)\"",
                       data: ErrorData(method: method, kind: name))
    }
    guard let accepts = kind.accepts else {
        throw RPCError(.kindNotAvailable, "display \(name) is not available yet",
                       data: ErrorData(method: method, kind: name))
    }
    let alert = try optionalBool(params["alert"], "alert", method)
    if alert != nil, kind != .toast { throw invalid(method, "alert applies to toast only", kind: name) }
    let session = try optionalString(params["session"], "session", method)
    if session != nil, kind != .aside { throw invalid(method, "session applies to aside only", kind: name) }

    let content = try validateContent(params["content"], method: method, kind: name, accepts: accepts)
    if kind == .toast {
        try limit(ContentBlock.joinedText(content).codePoints, Limits.maxToastChars, .maxToastChars, method)
    }
    return DisplayParams(kind: kind, content: content, alert: alert, session: session)
}

func validateNotify(_ params: [String: JSONValue]) throws -> NotifyParams {
    let method = Method.notify
    let title = try optionalString(params["title"], "title", method)
    let content = try validateContent(params["content"], method: method, kind: nil, accepts: notifyAccepts)
    try limit(ContentBlock.joinedText(content).codePoints, Limits.maxNotifyChars, .maxNotifyChars, method)
    return NotifyParams(content: content, title: title)
}

func validateSpeak(_ params: [String: JSONValue]) throws -> SpeakParams {
    let method = Method.speak
    guard let text = params["text"]?.string else { throw invalid(method, "text must be a string") }
    guard !isBlank(text) else { throw invalid(method, "text is empty") }
    try limit(text.codePoints, Limits.maxSpeakChars, .maxSpeakChars, method)
    let voice = try optionalString(params["voice"], "voice", method)
    if let voice, isBlank(voice) { throw invalid(method, "voice is empty") }
    return SpeakParams(text: text, voice: voice)
}

// MARK: - Content

func validateContent(_ value: JSONValue?, method: Method, kind: String?,
                     accepts: Set<ContentBlock.BlockType>) throws -> [ContentBlock] {
    // 1. Normalize: a string becomes one text block, once.
    let raw: [JSONValue]
    switch value {
    case .string(let text)?: raw = [.object(["type": .string("text"), "text": .string(text)])]
    case .array(let blocks)?: raw = blocks
    default: throw invalid(method, "content must be a string or an array of content blocks", kind: kind)
    }

    // 2. Shape: every block of a known type against its MCP shape. Unknown
    // types are kept aside for step 4.
    var blocks: [ContentBlock] = []
    var unknown: [String] = []
    for (index, block) in raw.enumerated() {
        guard let object = block.object, let type = object["type"]?.string else {
            throw invalid(method, "content[\(index)] must be an object with a string type", kind: kind)
        }
        guard let blockType = ContentBlock.BlockType(rawValue: type) else {
            unknown.append(type)
            continue
        }
        blocks.append(try shape(object, blockType, path: "content[\(index)]", method: method, kind: kind))
    }

    // 3. Empty: no blocks, or only text blocks with nothing but whitespace.
    if raw.isEmpty || (unknown.isEmpty && blocks.allSatisfy { block in
        if case .text(let text) = block { return isBlank(text.text) }
        return false
    }) {
        throw invalid(method, "content is empty", kind: kind)
    }

    // 4. Accepted types: nothing is dropped.
    if let type = unknown.first ?? blocks.first(where: { !accepts.contains($0.type) })?.type.rawValue {
        throw RPCError(.unsupportedContent, "\(method.rawValue)\(kind.map { " \($0)" } ?? "") does not accept \(type) content",
                       data: ErrorData(method: method, kind: kind, type: type))
    }

    // 5. Limits on the normalized content.
    try limit(blocks.count, Limits.maxBlocks, .maxBlocks, method)
    let textChars = blocks.reduce(0) { total, block in
        if case .text(let text) = block { return total + text.text.codePoints }
        return total
    }
    try limit(textChars, Limits.maxTextChars, .maxTextChars, method)
    return blocks
}

func shape(_ object: [String: JSONValue], _ type: ContentBlock.BlockType, path: String,
           method: Method, kind: String?) throws -> ContentBlock {
    func fail(_ detail: String) -> RPCError { invalid(method, "\(path): \(detail)", kind: kind) }
    func required(_ key: String) throws -> String {
        guard let value = object[key]?.string else { throw fail("\(key) must be a string") }
        return value
    }
    func optional(_ key: String) throws -> String? {
        try field(object, key, "a string", fail) { $0.string }
    }
    func base64(_ key: String) throws -> String {
        let value = try required(key)
        guard Data(base64Encoded: value) != nil else { throw fail("\(key) is not valid base64") }
        return value
    }
    let annotations = try field(object, "annotations", "an object", fail) { $0.object }
        .map { try validateAnnotations($0) { fail("annotations.\($0)") } }
    let meta = try metaObject(object["_meta"]) { fail($0) }

    switch type {
    case .text:
        return .text(TextContent(text: try required("text"), annotations: annotations, _meta: meta))
    case .image, .audio:
        let media = MediaContent(data: try base64("data"), mimeType: try required("mimeType"),
                                 annotations: annotations, _meta: meta)
        return type == .image ? .image(media) : .audio(media)
    case .resourceLink:
        let size = try field(object, "size", "a number", fail) { $0.number }
        let icons = try field(object, "icons", "an array", fail) { $0.array }?.enumerated().map { index, icon in
            try validateIcon(icon) { fail("icons[\(index)].\($0)") }
        }
        return .resourceLink(ResourceLink(
            uri: try required("uri"), name: try required("name"), title: try optional("title"),
            description: try optional("description"), mimeType: try optional("mimeType"), size: size,
            icons: icons, annotations: annotations, _meta: meta))
    case .resource:
        guard let resource = object["resource"]?.object else { throw fail("resource must be an object") }
        guard let uri = resource["uri"]?.string else { throw fail("resource.uri must be a string") }
        func resourceFail(_ detail: String) -> RPCError { fail("resource.\(detail)") }
        let text = try field(resource, "text", "a string", resourceFail) { $0.string }
        let blob = try field(resource, "blob", "a string", resourceFail) { $0.string }
        guard (text == nil) != (blob == nil) else {
            throw fail("resource must have exactly one of text and blob")
        }
        if let blob, Data(base64Encoded: blob) == nil { throw fail("resource.blob is not valid base64") }
        let mimeType = try field(resource, "mimeType", "a string", resourceFail) { $0.string }
        let contents = ResourceContents(uri: uri, mimeType: mimeType, text: text, blob: blob,
                                        _meta: try metaObject(resource["_meta"]) { fail("resource.\($0)") })
        return .resource(EmbeddedResource(resource: contents, annotations: annotations, _meta: meta))
    }
}

// MARK: - Helpers

func metaObject(_ value: JSONValue?, _ fail: (String) -> RPCError) throws -> [String: JSONValue]? {
    guard let value else { return nil }
    guard let object = value.object else { throw fail("_meta must be an object") }
    return object
}

// An optional field at any depth: absent is nil, but present it must have
// its type. proto.ts allows omitting an optional field, never null, so an
// explicit null fails like any other wrong type. Unknown fields
// are not looked at.
func field<T>(_ object: [String: JSONValue], _ key: String, _ expected: String,
              _ fail: (String) -> RPCError, _ read: (JSONValue) -> T?) throws -> T? {
    guard let value = object[key] else { return nil }
    guard let typed = read(value) else { throw fail("\(key) must be \(expected)") }
    return typed
}

func validateAnnotations(_ object: [String: JSONValue], _ fail: (String) -> RPCError) throws -> Annotations {
    let audience = try field(object, "audience", "an array", fail) { $0.array }?.map { role in
        guard let role = role.string.flatMap(Annotations.Role.init(rawValue:)) else {
            throw fail("audience must hold \"user\" or \"assistant\"")
        }
        return role
    }
    return Annotations(audience: audience,
                       priority: try field(object, "priority", "a number", fail) { $0.number },
                       lastModified: try field(object, "lastModified", "a string", fail) { $0.string })
}

func validateIcon(_ value: JSONValue, _ fail: (String) -> RPCError) throws -> Icon {
    guard let object = value.object else { throw fail("must be an object") }
    guard let src = object["src"]?.string else { throw fail("src must be a string") }
    let sizes = try field(object, "sizes", "an array", fail) { $0.array }?.map { size in
        guard let size = size.string else { throw fail("sizes must hold strings") }
        return size
    }
    return Icon(src: src,
                mimeType: try field(object, "mimeType", "a string", fail) { $0.string },
                sizes: sizes,
                theme: try field(object, "theme", "\"light\" or \"dark\"", fail) {
                    $0.string.flatMap(Icon.Theme.init(rawValue:))
                })
}

func optionalBool(_ value: JSONValue?, _ key: String, _ method: Method) throws -> Bool? {
    guard let value else { return nil }
    guard case .bool(let bool) = value else { throw invalid(method, "\(key) must be a boolean") }
    return bool
}

func optionalString(_ value: JSONValue?, _ key: String, _ method: Method) throws -> String? {
    guard let value else { return nil }
    guard let string = value.string else { throw invalid(method, "\(key) must be a string") }
    return string
}

func limit(_ value: Int, _ max: Int, _ name: LimitName, _ method: Method) throws {
    guard value <= max else {
        throw RPCError(.tooLarge, "\(name.rawValue) is \(max); got \(value)",
                       data: ErrorData(method: method, limit: name, value: value))
    }
}

func invalid(_ method: Method, _ message: String, kind: String? = nil) -> RPCError {
    RPCError(.invalidParams, message, data: ErrorData(method: method, kind: kind))
}

func isBlank(_ text: String) -> Bool {
    text.allSatisfy { $0.isWhitespace }
}
