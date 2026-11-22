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
    // The model is the session's "model" config option, whose values carry
    // their parameters ("gemini-4-carbon[reasoning_effort=medium]"); a
    // registered bare name matches the option of that name. Not --model:
    // that flag works before `acp`, but it also rewrites the user's own
    // default model in ~/.cursor/cli-config.json (seen on 2026.11.18), and
    // an agent's model is not the user's default. Whether setting the
    // config option leaves that file alone is not yet checked.
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

    // OpenCode: `opencode acp` (opencode.ai/docs/cli/acp), run against
    // 2.3.2 on 2026.11.22: initialize reports protocol 1, image prompts and
    // session/resume (no history replay), and one auth method,
    // opencode-login, which is a terminal method ("run `opencode auth
    // login` in the terminal"): never called, as the server uses the
    // provider credentials it already has and answers a prompt that needs
    // them with auth_required. The registered model and effort are session
    // config options, "model" taking provider/model ids and "effort"
    // (thought_level) offered only for models with variants; one that is
    // not offered is left alone, as elsewhere. It advertises no system
    // prompt capability, so instructions go in front of the first prompt.
    // A session takes the MCP servers session/new names, accepts them
    // without a prompt, and asks permission for each call of their tools,
    // with allow_once, allow_always and reject options; it reports
    // usage_update before the prompt response. session/resume must carry
    // the session's own cwd (checked: another cwd answers "does not belong
    // to cwd"), which the adapter's root always is. It exits when its
    // stdin closes.
    //
    // initialize also says _meta.steering supported. Sirius sends one
    // turn at a time regardless, as it does for the other ACP agents:
    // a message sent while one runs waits for the next turn.
    static let opencode = ACPProfile(
        product: "OpenCode", command: "opencode", signIn: "opencode auth login",
        authMethod: nil,
        arguments: { _ in ["acp"] })
}
