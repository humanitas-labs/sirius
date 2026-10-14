import Foundation
import SiriusProtocol

// Where codex is and how app-server is started for Sirius.
enum CodexLaunch {
    // The copy ChatGPT.app ships: a small sh wrapper
    // that execs the CodexCLI.app beside it.
    static let bundledSuffix = "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    // The registered executable when it runs; else codex on PATH; else the
    // copy inside ChatGPT.app, system-wide then per user.
    static func findExecutable(registered: String, environment: [String: String],
                               home: String = NSHomeDirectory(),
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:))
        -> String? {
        if !registered.isEmpty, isExecutable(registered) { return registered }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/codex"
            if isExecutable(candidate) { return candidate }
        }
        for candidate in ["/Applications/\(bundledSuffix)", "\(home)/Applications/\(bundledSuffix)"]
        where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    // The three sirius-mcp tools. Each needs approval_mode "approve", or under
    // approvalPolicy never its call fails at once.
    static let tools = ["display", "notify", "speak"]

    // `codex app-server` with sirius-mcp as the MCP server "sirius". MCP
    // servers run outside Codex's sandbox; without network access the
    // sandbox refuses every socket connect from the agent's shell
    // (architecture.md §5.2).
    // Network access inside the workspace-write sandbox
    // (sandbox_workspace_write.network_access): if Claude gets network
    // access, Codex does too. Set on the process,
    // so the worker agents it starts get it too.
    // Fast is Codex's "priority" service tier, its "Fast" (checked on
    // 0.159.1 with gpt-6.1-sol: accepted, where an unknown tier is reported
    // and dropped).
    //
    // Worker agents (checked on 0.159.1): Codex adds
    // a developer message to every turn that cancels any instruction to
    // delegate unless the user or an AGENTS.md asks, so the pool that
    // instructions.md describes never forms. Sirius replaces that message's
    // text with a pointer back to the instructions. Worker agents don't get
    // the thread's developer instructions; they are given workers.md, when
    // the agent has one.
    //
    // Codex before 0.147.0 reads features.multi_agent_v2 as a plain flag and
    // exits at initialize on the table, so both are left out there
    // (CodexCapabilities): the agent then does its work itself.
    static let delegationHint = "Start and use worker agents as your developer instructions describe."

    static func arguments(mcpHelper: String, socketPath: String, fast: Bool = false,
                          workers: String? = nil, capabilities: CodexCapabilities = .unknown) -> [String] {
        var config = [
            "mcp_servers.sirius.command=\(toml(mcpHelper))",
            "mcp_servers.sirius.args=[]",
            "mcp_servers.sirius.env={\(SiriusEnvironment.socket)=\(toml(socketPath))}",
        ]
        for tool in tools {
            config.append("mcp_servers.sirius.tools.\(tool).approval_mode=\"approve\"")
        }
        config.append("sandbox_workspace_write.network_access=true")
        if fast { config.append("service_tier=\"priority\"") }
        if capabilities.supportsMultiAgentSettings {
            config.append("features.multi_agent_v2.multi_agent_mode_hint_text=\(toml(delegationHint))")
            if let workers {
                config.append("features.multi_agent_v2.subagent_developer_instructions=\(toml(workers))")
            }
        }
        return ["app-server"] + config.flatMap { ["-c", $0] }
    }

    // A TOML basic string.
    static func toml(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
