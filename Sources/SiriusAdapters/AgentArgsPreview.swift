import Foundation
import SiriusProtocol

// A debug path for scripts/compat-test.sh: `Sirius --print-agent-args
// <claude|codex> <executable> [root]` prints, as one JSON object on stdout,
// what Sirius would launch against that executable, then exits before the
// app starts. The arguments come from the adapters' own code, so the test
// never keeps a copy of them in bash.
//
// claude: probes the executable as ClaudeAdapter.start does (ClaudeProbe)
//   and prints either the argv it would run, or the "too old" refusal it
//   would show instead. Every optional feature is turned on (a system prompt,
//   --name, effort, fast), so each flag Sirius can pass is exercised.
// codex: probes the executable's version as CodexAdapter.start does
//   (CodexProbe) and prints either the "too old" refusal, or the app-server
//   argv (CodexLaunch.arguments, with worker instructions so every override
//   Sirius can pass is exercised) and the params of the initialize and
//   thread/start requests CodexAdapter.start sends, plus the JSON-RPC
//   methods it calls later.
public enum AgentArgsPreview {
    public static let flag = "--print-agent-args"

    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(index + 1)...])
        guard rest.count >= 2, ["claude", "codex"].contains(rest[0]) else {
            FileHandle.standardError.write(Data("usage: Sirius \(flag) <claude|codex> <executable> [root]\n".utf8))
            exit(2)
        }
        let root = rest.count > 2 ? rest[2] : FileManager.default.currentDirectoryPath
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            box.value = rest[0] == "claude"
                ? await claude(executable: rest[1], root: root)
                : await codex(executable: rest[1], root: root)
            done.signal()
        }
        done.wait()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let value = box.value, let data = try? encoder.encode(value) else { exit(1) }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(0)
    }

    private final class Box: @unchecked Sendable {
        var value: JSONValue?
    }

    static func claude(executable: String, root: String) async -> JSONValue {
        let environment = ProcessInfo.processInfo.environment
        let capabilities = await ClaudeProbe.shared.capabilities(executable: executable, environment: environment)
        var out: [String: JSONValue] = [
            "harness": .string("claude"),
            "version": capabilities.version.map(JSONValue.string) ?? .null,
        ]
        // As ClaudeAdapter.start: a CLI missing a required flag is refused.
        let missing = capabilities.missingRequired
        if !missing.isEmpty {
            let error = ClaudeAdapterError.tooOld(version: capabilities.version, missing: missing)
            out["outcome"] = .string("tooOld")
            out["missing"] = .array(missing.map(JSONValue.string))
            out["message"] = .string(error.userMessage ?? "\(error)")
            return .object(out)
        }
        let argv = ClaudeAdapter.arguments(session: nil, systemPrompt: "compat-test",
                                           name: ClaudeAdapter.sessionName(agent: "compat"),
                                           effort: "high", fast: true, capabilities: capabilities)
        out["outcome"] = .string("launch")
        out["argv"] = .array(argv.map(JSONValue.string))
        return .object(out)
    }

    static func codex(executable: String, root: String) async -> JSONValue {
        let capabilities = await CodexProbe.shared.capabilities(executable: executable,
                                                                environment: ProcessInfo.processInfo.environment)
        // As CodexAdapter.start: a Codex below the floor is refused.
        if capabilities.isTooOld {
            let error = CodexAdapterError.tooOld(version: capabilities.version)
            return .object([
                "harness": .string("codex"),
                "version": capabilities.version.map(JSONValue.string) ?? .null,
                "outcome": .string("tooOld"),
                "message": .string(error.userMessage ?? "\(error)"),
            ])
        }
        let registration = AgentRegistration(agent: "compat", name: "compat", harness: .codex,
                                             executable: executable, root: root, effort: "high", fast: true)
        let helper = AgentHost.helpersDirectory().appendingPathComponent("sirius-mcp").path
        let argv = CodexLaunch.arguments(mcpHelper: helper, socketPath: "/tmp/sirius-compat.sock",
                                         fast: true, workers: "compat-test", capabilities: capabilities)
        let thread = CodexAdapter.threadParams(registration: registration, instructions: "compat-test")
        return .object([
            "harness": .string("codex"),
            "version": capabilities.version.map(JSONValue.string) ?? .null,
            "outcome": .string("launch"),
            "multiAgentSettings": .bool(capabilities.supportsMultiAgentSettings),
            "argv": .array(argv.map(JSONValue.string)),
            // As CodexAdapter.start sends it.
            "initialize": .object([
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(CodexAdapter.clientVersion)]),
            ]),
            "threadStart": .object(thread),
            // A turn with an image beside the text, as deliver sends it.
            "turnStart": .object(CodexAdapter.turnParams(
                thread: "compat",
                message: Message(id: "m_compat", agent: "compat", text: "compat-test", attachments: [
                    Message.Attachment(path: "/tmp/compat.png", mimeType: "image/png"),
                ]),
                effort: "high")),
            "methods": .array(["initialize", "thread/start", "thread/resume", "turn/start", "turn/steer"]
                .map(JSONValue.string)),
        ])
    }
}
