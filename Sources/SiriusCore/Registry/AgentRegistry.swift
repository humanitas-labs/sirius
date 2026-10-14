import Foundation
import SiriusProtocol

// One agent from ~/.agents/registry/<agent>/: its definition and its
// instructions (Instructions).
public struct RegisteredAgent: Equatable, Sendable {
    public var registration: AgentRegistration
    // instructions.md with the files it names included; nil when absent.
    public var instructions: String?
    // workers.md likewise, for a harness whose worker agents are given their
    // own (Codex); nil when absent.
    public var workerInstructions: String?
    // The agent's folder in the registry.
    public var directory: URL

    public init(registration: AgentRegistration, instructions: String?, workerInstructions: String? = nil,
                directory: URL) {
        self.registration = registration
        self.instructions = instructions
        self.workerInstructions = workerInstructions
        self.directory = directory
    }
}

public enum RegistryError: Error, Equatable, Sendable {
    // The folder has no agent.json.
    case missingDefinition
    // A file exists but could not be read (permissions, not UTF-8).
    case unreadable(file: String, reason: String)
    // agent.json is not a JSON object, or a field is missing or the wrong type.
    case malformed(String)
    // The id breaks [a-z0-9-]{1,32}.
    case invalidId(String)
    // The folder name and the `agent` field differ.
    case folderMismatch(folder: String, agent: String)
    case unknownHarness(String)
    case relativeExecutable(String)
    case relativeRoot(String)
}

// A registry folder that did not load. Reported, never fatal, and never
// hides the good entries beside it.
public struct RegistryFailure: Equatable, Sendable {
    public var folder: String
    public var error: RegistryError

    public init(folder: String, error: RegistryError) {
        self.folder = folder
        self.error = error
    }
}

public struct RegistryScan: Equatable, Sendable {
    // Sorted by id.
    public var agents: [RegisteredAgent]
    // Sorted by folder name.
    public var failures: [RegistryFailure]
}

// Reads and writes ~/.agents/registry/. The directory is injectable for tests.
public struct AgentRegistry: Sendable {
    public static let definitionFile = "agent.json"
    public static let instructionsFile = Instructions.entrypoint
    // The agent's logo, optional, in the first of these forms present.
    public static let iconFiles = ["icon.svg", "icon.png", "icon.pdf"]

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("registry", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = AgentRegistry.defaultDirectory) {
        self.directory = directory
    }

    // Every agent folder. A missing registry directory is an empty registry.
    public func loadAll() -> RegistryScan {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var agents: [RegisteredAgent] = []
        var failures: [RegistryFailure] = []
        for name in names.sorted() {
            // Dotfiles (.DS_Store, editor droppings) are not agents.
            if name.hasPrefix(".") { continue }
            var isDirectory: ObjCBool = false
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            switch load(folder: name) {
            case .success(let agent): agents.append(agent)
            case .failure(let error): failures.append(RegistryFailure(folder: name, error: error))
            }
        }
        return RegistryScan(agents: agents, failures: failures)
    }

    // One agent by folder name.
    public func load(agent: String) -> Result<RegisteredAgent, RegistryError> {
        load(folder: agent)
    }

    // Writes agent.json atomically, pretty-printed with sorted keys, creating
    // the folder. Used by setup. Leaves instructions.md alone.
    public func write(_ registration: AgentRegistration) throws {
        if let error = Self.validate(registration, folder: registration.agent) { throw error }
        let folder = directory.appendingPathComponent(registration.agent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(registration)
        data.append(0x0A)
        try data.write(to: folder.appendingPathComponent(Self.definitionFile), options: .atomic)
    }

    // Seeds each agent's instructions.md from the app's templates:
    // `templates`/instructions.md and a folder per harness beside it
    // (Instructions.seed). Returns whether anything was written; a failure
    // is reported and never fatal.
    @discardableResult
    public func seedInstructions(for agents: [RegisteredAgent], templates: URL,
                                 report: (String) -> Void = { _ in }) -> Bool {
        var wrote = false
        for agent in agents {
            let source = templates.appendingPathComponent(agent.registration.harness.rawValue, isDirectory: true)
            do {
                if try Instructions.seed(folder: agent.directory,
                                         template: templates.appendingPathComponent(Instructions.entrypoint),
                                         harness: source) {
                    wrote = true
                }
            } catch {
                report("Sirius: \(agent.registration.agent): couldn't write its instructions: \(error)")
            }
        }
        return wrote
    }

    // The agent's own logo file, if its folder has one (iconFiles). Read on
    // each use, so a new logo shows without a restart.
    public func icon(agent: String) -> URL? {
        let folder = directory.appendingPathComponent(agent, isDirectory: true)
        return Self.iconFiles.lazy.map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // A harness's default mark in `marks`, the app's copy of packaging/marks:
    // <harness>.svg, so a new harness needs only its file.
    public static func defaultIcon(harness: AgentRegistration.Harness, marks: URL) -> URL {
        marks.appendingPathComponent("\(harness.rawValue).svg")
    }

    // Copies the harness's default mark into the agent's folder as icon.svg
    // when the folder has no icon of any form; one already there is never
    // replaced. Returns whether it copied; a missing default copies nothing.
    @discardableResult
    public func seedIcon(agent: String, harness: AgentRegistration.Harness, marks: URL) throws -> Bool {
        guard icon(agent: agent) == nil else { return false }
        let source = Self.defaultIcon(harness: harness, marks: marks)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let folder = directory.appendingPathComponent(agent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(Self.iconFiles[0]))
        return true
    }

    private func load(folder name: String) -> Result<RegisteredAgent, RegistryError> {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        let definitionURL = folder.appendingPathComponent(Self.definitionFile)
        guard FileManager.default.fileExists(atPath: definitionURL.path) else {
            return .failure(.missingDefinition)
        }
        let data: Data
        do {
            data = try Data(contentsOf: definitionURL)
        } catch {
            return .failure(.unreadable(file: Self.definitionFile, reason: error.localizedDescription))
        }
        let registration: AgentRegistration
        switch Self.parse(data) {
        case .success(let parsed): registration = parsed
        case .failure(let error): return .failure(error)
        }
        if let error = Self.validate(registration, folder: name) { return .failure(error) }

        var composed: [String: String] = [:]
        for file in [Self.instructionsFile, Instructions.workers] {
            do {
                composed[file] = try Instructions.compose(entrypoint: folder.appendingPathComponent(file))
            } catch {
                return .failure(.unreadable(file: file, reason: "not readable as UTF-8"))
            }
        }
        return .success(RegisteredAgent(registration: registration, instructions: composed[Self.instructionsFile],
                                        workerInstructions: composed[Instructions.workers],
                                        directory: folder))
    }

    // Parsed by hand so an unknown harness gets its own error rather than a
    // generic decoding failure. Unknown fields are ignored.
    static func parse(_ data: Data) -> Result<AgentRegistration, RegistryError> {
        guard let value = try? JSONValue.parse(data), let object = value.object else {
            return .failure(.malformed("agent.json is not a JSON object"))
        }
        func required(_ key: String) -> Result<String, RegistryError> {
            guard let field = object[key] else { return .failure(.malformed("missing \(key)")) }
            guard let string = field.string else { return .failure(.malformed("\(key) is not a string")) }
            return .success(string)
        }
        do {
            let agent = try required("agent").get()
            let name = try required("name").get()
            let harnessName = try required("harness").get()
            let executable = try required("executable").get()
            let root = try required("root").get()
            // Optional strings; a blank one counts as absent.
            func optional(_ key: String) -> Result<String?, RegistryError> {
                guard let field = object[key], field != .null else { return .success(nil) }
                guard let string = field.string else { return .failure(.malformed("\(key) is not a string")) }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(trimmed.isEmpty ? nil : trimmed)
            }
            let voice = try optional("voice").get()
            let model = try optional("model").get()
            let effort = try optional("effort").get()
            var fast: Bool?
            switch object["fast"] {
            case nil, .null?: break
            case .bool(let value)?: fast = value
            default: return .failure(.malformed("fast is not true or false"))
            }
            guard let harness = AgentRegistration.Harness(rawValue: harnessName) else {
                return .failure(.unknownHarness(harnessName))
            }
            return .success(AgentRegistration(agent: agent, name: name, harness: harness,
                                              executable: executable, root: root, voice: voice,
                                              model: model, effort: effort, fast: fast))
        } catch {
            // Result.get() throws the typed RegistryError.
            return .failure(error)
        }
    }

    static func validate(_ registration: AgentRegistration, folder: String) -> RegistryError? {
        guard AgentRegistration.isValidId(registration.agent) else { return .invalidId(registration.agent) }
        guard folder == registration.agent else {
            return .folderMismatch(folder: folder, agent: registration.agent)
        }
        guard registration.executable.hasPrefix("/") else { return .relativeExecutable(registration.executable) }
        guard registration.root.hasPrefix("/") else { return .relativeRoot(registration.root) }
        return nil
    }
}
