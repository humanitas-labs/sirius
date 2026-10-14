import Foundation
import SiriusProtocol

public enum AgentStorageError: Error, Equatable, Sendable {
    case invalidAgentId(String)
    case invalidMessageId(String)
}

// Sirius's own files for one agent, under
// ~/Library/Application Support/Sirius/agents/<agent>/: state.json, log.jsonl
// and attachments/<message>/. The base directory is injectable for tests.
public struct AgentStorage: Sendable {
    public static var defaultBaseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Sirius", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    public let agent: String
    public let directory: URL

    public init(agent: String, baseDirectory: URL = AgentStorage.defaultBaseDirectory) throws {
        // The id becomes a path component; the rule keeps it from escaping.
        guard AgentRegistration.isValidId(agent) else { throw AgentStorageError.invalidAgentId(agent) }
        self.agent = agent
        self.directory = baseDirectory.appendingPathComponent(agent, isDirectory: true)
    }

    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var logURL: URL { directory.appendingPathComponent("log.jsonl") }
    public var attachmentsDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    // Creates the agent's folder, owner-only since attachments may hold
    // anything the user pasted.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    // MARK: state.json

    // An absent file is the state before the first turn.
    public func readState() throws -> AgentState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AgentState() }
        return try JSONDecoder().decode(AgentState.self, from: Data(contentsOf: stateURL))
    }

    public func writeState(_ state: AgentState) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try data.write(to: stateURL, options: .atomic)
    }

    // MARK: log.jsonl

    // Opens the single writer for this agent's log. The app opens it once
    // per agent and keeps it; two writers on one file would interleave.
    public func openLog(now: @escaping @Sendable () -> Date = { Date() }) throws -> AgentLog {
        try prepare()
        return try AgentLog(url: logURL, now: now)
    }

    // MARK: attachments

    public func attachmentsDirectory(for message: String) throws -> URL {
        guard MessageID.isSafeFolderName(message) else { throw AgentStorageError.invalidMessageId(message) }
        return attachmentsDirectory.appendingPathComponent(message, isDirectory: true)
    }

    // Copies a file the user attached. The stored name is the source's name,
    // sanitized and de-duplicated within the message's folder.
    public func addAttachment(copying source: URL, to message: String, mimeType: String) throws
        -> Message.Attachment {
        let folder = try makeAttachmentsFolder(for: message)
        let destination = AttachmentNaming.uniqueURL(in: folder, for: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return Message.Attachment(path: destination.path, mimeType: mimeType)
    }

    // Writes pasted or dragged content that is not a file yet.
    public func addAttachment(data: Data, named name: String, to message: String, mimeType: String) throws
        -> Message.Attachment {
        let folder = try makeAttachmentsFolder(for: message)
        let destination = AttachmentNaming.uniqueURL(in: folder, for: name)
        try data.write(to: destination, options: .withoutOverwriting)
        return Message.Attachment(path: destination.path, mimeType: mimeType)
    }

    private func makeAttachmentsFolder(for message: String) throws -> URL {
        let folder = try attachmentsDirectory(for: message)
        try prepare()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

public enum MessageID {
    // TODO(andrew): the id format. "m_" plus 8 lowercase base-36 characters
    // for now (about 41 bits), enough to never collide within one agent's log.
    public static func make() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return "m_" + String((0..<8).map { _ in alphabet.randomElement(using: &generator)! })
    }

    // Looser than make()'s format so a later id scheme still passes, but
    // never a path separator, a dot or an empty name.
    public static func isSafeFolderName(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy {
                (0x61...0x7A).contains($0) || (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
                    || $0 == 0x5F || $0 == 0x2D
            }
    }
}

public enum AttachmentNaming {
    static let fallbackName = "attachment"
    // APFS allows 255 UTF-8 bytes per name; leave room for a "-NN" suffix.
    static let maxNameBytes = 200

    // A name safe to create inside the message's folder: no path separators,
    // no control characters, no leading dots (hidden, or "." and ".."), not
    // empty, and bounded in length.
    public static func sanitize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("_")
            } else if scalar.properties.generalCategory == .control || scalar.value == 0 {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return fallbackName }
        if result.utf8.count > maxNameBytes {
            let (base, ext) = split(result)
            let keptExt = ext.utf8.count <= 16 ? ext : ""
            var trimmedBase = base
            while trimmedBase.utf8.count + keptExt.utf8.count > maxNameBytes { trimmedBase.removeLast() }
            result = trimmedBase + keptExt
            if result.isEmpty || result.hasPrefix(".") { result = fallbackName + keptExt }
        }
        return result
    }

    // The sanitized name, or name-2.ext, name-3.ext… when it is taken.
    public static func uniqueURL(in folder: URL, for name: String) -> URL {
        let clean = sanitize(name)
        var candidate = folder.appendingPathComponent(clean)
        var counter = 2
        let (base, ext) = split(clean)
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)\(ext)")
            counter += 1
        }
        return candidate
    }

    // ("report", ".pdf"); a name without a dot after its first character has no extension.
    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
