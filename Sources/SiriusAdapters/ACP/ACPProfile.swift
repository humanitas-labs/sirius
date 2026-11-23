import Foundation
import SiriusProtocol

// What is one ACP harness's own: where its CLI is, how its server is
// started for Sirius, how it signs in, and the requests it sends beyond
// ACP's. ACPAdapter does the rest the same way for all of them.
struct ACPProfile: Sendable {
    // Shown in errors: "Cursor".
    var product: String
    // The CLI's command, and other names its installer gives it.
    var command: String
    var otherCommands: [String] = []
    // What the user runs to sign the CLI in.
    var signIn: String
    // The ACP auth method that reuses the CLI's cached sign-in, called
    // after initialize when the server offers it. Nil: the server uses its
    // credentials unasked, and Sirius never calls a method that could open
    // a browser.
    var authMethod: String?
    // The server's arguments for one agent.
    var arguments: @Sendable (AgentRegistration) -> [String]
    // Added to the child's environment.
    var environment: [String: String] = [:]
    // Extra keys sent under initialize's clientCapabilities._meta (ACP's
    // extension point for server-specific capabilities).
    var clientCapabilitiesMeta: [String: JSONValue] = [:]
    // Run before each start, with the adapter's environment: readies what
    // the server needs on disk and returns more environment for it.
    var prepare: @Sendable (AgentRegistration, [String: String]) throws -> [String: String] = { _, _ in [:] }
    // The harness's own requests (not ACP's), or nil for one it has none for.
    var answer: @Sendable (_ method: String, _ params: JSONValue) -> JSONRPCStdio.Reply? = { _, _ in nil }

    // The registered executable when it runs; else the command on PATH;
    // else where both installers put it, ~/.local/bin.
    func findExecutable(registered: String, environment: [String: String],
                        home: String = NSHomeDirectory(),
                        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        if !registered.isEmpty, isExecutable(registered) { return registered }
        let commands = [command] + otherCommands
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            for command in commands where isExecutable("\(directory)/\(command)") { return "\(directory)/\(command)" }
        }
        return commands.map { "\(home)/.local/bin/\($0)" }.first(where: isExecutable)
    }

    // The child's environment: the socket for the sirius helpers, the
    // helpers first on PATH, and the profile's own.
    func environment(_ base: [String: String], socketPath: String, helpers: URL) -> [String: String] {
        var env = base
        env[SiriusEnvironment.socket] = socketPath
        env["PATH"] = helpers.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        for (name, value) in environment { env[name] = value }
        return env
    }
}

extension ACPProfile {
    // Cursor's CLI: `agent acp` (cursor.com/docs/cli/acp), run against
    // 2026.08.11 on 2026.11.18: initialize reports protocol 1, session/load
    // (which replays the history first), image prompts and the auth method
    // cursor_login, which reuses what `agent login` stored. A session takes
    // the MCP servers session/new names, and asks permission for each call
    // of their tools, which the adapter allows.
    //
    // The model is set through the session's "model" config option, never
    // --model: that flag works before `acp`, but it also rewrites the user's
    // own default model in ~/.cursor/cli-config.json. Setting the config
    // option rewrites it too (checked 2026.11.23), so the server runs on
    // the agent's own config directory: see CursorConfig. Advertising
    // clientCapabilities._meta.parameterizedModelPicker asks `agent acp` for
    // the parameterized catalog (bare model ids plus separate thought_level
    // and model_config options, matching the interactive CLI) rather than
    // its exploded variant list ("model[param=value]"). Older builds that
    // ignore the capability still work through ACPConfig's bracket matching.
    //
    // The root flags go before `acp`, as the docs show for --api-key:
    // - --trust: the agent's root, without the prompt nobody would answer.
    // - --approve-mcps: sirius-mcp, without the approval nobody would give.
    // The CLI accepts both there; that they matter in ACP mode is not
    // documented, and a session opened without trouble either way.
    static let cursor = ACPProfile(
        product: "Cursor", command: "agent", otherCommands: ["cursor-agent"], signIn: "agent login",
        authMethod: "cursor_login",
        arguments: { _ in ["--trust", "--approve-mcps", "acp"] },
        clientCapabilitiesMeta: ["parameterizedModelPicker": .bool(true)],
        prepare: { registration, environment in
            try CursorConfig.isolate(user: CursorConfig.userDirectory(environment: environment),
                                     own: CursorConfig.agentDirectory(agent: registration.agent))
        },
        answer: cursorAnswer)

    // Cursor's blocking requests (docs: "Your client must reply"), each
    // answered at once so a turn never hangs on a person who is not there:
    // a question is skipped with the reason, a plan is accepted. The other
    // cursor/* methods are documented as notifications; one that arrives as
    // a request anyway gets an empty result rather than an error that would
    // fail the tool call.
    static let cursorAnswer: @Sendable (String, JSONValue) -> JSONRPCStdio.Reply? = { method, params in
        func outcome(_ fields: [String: JSONValue]) -> JSONRPCStdio.Reply {
            .result(.object(["outcome": .object(fields)]))
        }
        switch method {
        case "cursor/ask_question":
            return outcome(["outcome": .string("skipped"), "reason": .string(unattended)])
        case "cursor/create_plan":
            return outcome(["outcome": .string("accepted")])
        case "cursor/update_todos":
            return outcome(["outcome": .string("accepted"), "todos": params["todos"] ?? .array([])])
        case _ where method.hasPrefix("cursor/"):
            return .result(.object([:]))
        default:
            return nil
        }
    }

    static let unattended = "Sirius agents run with nobody at the terminal. Ask the user with a toast through the sirius tools and end the turn."

    // Antigravity CLI: `agy acp` (antigravity.google/docs/cli/acp), run
    // against 1.5.11 on 2026.11.18: two turns with a toast and a resumed
    // session. initialize reports protocol 1, session/resume and
    // session/load, image prompts, and four auth methods, of which
    // "oauth-personal" opens a browser: none is called. The server reuses
    // the sign-in an interactive `agy` cached, and without one answers
    // session/new "Authentication required", which the adapter reports with
    // the command to run. A session takes the MCP servers session/new
    // names and asks permission for each call of their tools; it reports
    // usage_update. It exits when its stdin closes. The model and thinking
    // level are session config options. It advertises a system prompt only
    // under its own _meta key, whose request shape is not documented, so
    // instructions go in front of the first prompt. The child does not
    // update itself mid-session; the user's own agy keeps updating.
    static let antigravity = ACPProfile(
        product: "Antigravity", command: "agy", signIn: "agy",
        authMethod: nil,
        arguments: { _ in ["acp"] },
        environment: ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"])
}
