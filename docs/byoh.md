# Sirius — Bring your own harness (BYOH)

> How to add a harness (agent CLI) to Sirius.

## 1. Model

A harness is an agent CLI that can hold a session without its terminal UI: Claude Code, Codex, Muse Code, Cursor, Antigravity and OpenCode today. Each one is an agent in Sirius, described by `~/.agents/registry/<agent>/agent.json`, whose `harness` field picks the adapter that runs it. The adapter is the only code written per harness. The composer, dictation, toasts and the log are the same for all of them.

## 2. Adding a harness

Adding one is a change to the source, in five steps. A CLI with an ACP server (the Agent Client Protocol over stdio, as `agent acp` and `agy acp` are) needs no adapter of its own: step 2 is then a profile, a few lines in `Sources/SiriusAdapters/ACP/ACPProfile.swift` saying how its server is started and how it signs in, and `ACPAdapter` does the rest.

1. **Name it.** Add a case to `AgentRegistration.Harness` in `Sources/SiriusProtocol/Registration.swift`. Its raw value is what `agent.json` says. The switches over the harness are exhaustive, so the compiler then points to the other places to fill in.
2. **Write the adapter** in `Sources/SiriusAdapters/`, implementing `Adapter` (`Sources/SiriusCore/Adapter.swift`): `open` starts the CLI warm in the agent's folder, resuming a session when given one, with `SIRIUS_SOCKET` in its environment and the agent's instructions; `prompt` delivers one message as a turn and returns when the turn ends; `close` stops it. `steer` (join a running turn) and `compact` are optional: declare them in the capabilities `open` returns, and Sirius calls only what you declared. If the CLI speaks JSON-RPC over stdio, as Codex, Muse and every ACP agent do, `JSONRPCStdio` is the transport.
3. **Give the agent its way back.** The agent reaches you by calling Sirius, never by its own output: the `sirius` command, or the `sirius-mcp` server for a harness that takes MCP servers. The adapter puts one of them within the session's reach.
4. **Return it** from `AgentHost.makeDefaultAdapter` in `Sources/SiriusAdapters/AgentHost.swift`.
5. **Add it to setup.** The command to look for (`AgentDetector`), its names and effort levels (`Sources/SiriusApp/Setup/AgentChoice.swift`), where it keeps its trusted folders (`TrustedFolders`), and its mark at `packaging/marks/<harness>.svg` — or `.png`, if the mark has a shape NSImage's SVG rasterizer cannot draw: it fills enclosed holes, so OpenCode's frame ships as a PNG.

`Sources/SiriusAdapters/Muse/` is the shortest complete native example, and `Sources/SiriusAdapters/ACP/` the one to read for an ACP agent, and its tests in `Tests/SiriusAdaptersTests/` run against a fake server and recorded streams, with no account. Check yours with `swift test`, then `scripts/dev-install.sh`. The adapters' shared jobs are described in [docs/architecture.md](architecture.md) §5. Pull requests for new harnesses are welcome.
