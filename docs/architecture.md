# Sirius architecture

Last updated: `2026.10.09`

> Sirius is one Mac app and two small helpers. A message goes from the composer to one agent through an adapter, which is the only per-agent code. Replies come back through one protocol for every agent: the agent calls `display`, `notify` or `speak`, a helper sends that to the app's socket, and the app presents it.

The wire contract is [protocol/proto.ts](protocol/proto.ts). Each part below is marked **agreed** (decided) or **proposed** (recommended, not yet decided).

## Contents

1. [The whole picture](#1-the-whole-picture)
2. [Components](#2-components)
3. [User to agent](#3-user-to-agent)
4. [Agent to user](#4-agent-to-user)
5. [Adapters](#5-adapters)
   - [5.1 — Claude Code, warm headless](#51--claude-code-warm-headless)
   - [5.2 — Codex, app-server](#52--codex-app-server)
   - [5.3 — Claude Code, live session](#53--claude-code-live-session)
6. [Files on disk](#6-files-on-disk)
7. [Code layout](#7-code-layout)
8. [Open](#8-open)

---

## 1. The whole picture

```
┌──────────────────────────────── Sirius.app ─────────────────────────────────┐
│                                                                             │
│  Composer ──► Message ──► Adapter for the agent ───────────┐                │
│                  │                                          │ stdin / stdio  │
│                  ▼                                          ▼                │
│            agents/<agent>/                          agent process            │
│            log.jsonl, attachments/                  (claude, codex app-server)
│                  ▲                                          │                │
│                  │                                          │ display        │
│  Presenter ◄── Queue ◄── Socket server ◄── sirius / sirius-mcp (helper)     │
│  toast · notification · speech       $TMPDIR/sirius/<agent>.sock            │
└─────────────────────────────────────────────────────────────────────────────┘
```

Two directions, unified differently:

- **Agent to user** is one protocol for every agent (agreed). The agent runs `sirius display …` or calls the `display` tool on `sirius-mcp`. The helper sends one JSON-RPC request to the agent's socket and returns the app's receipt.
- **User to agent** is one Message for every agent, carried however that agent starts a turn. That translation is the adapter's whole job.

The agent's own output stream is never shown to the user (agreed). The adapter reads it only for the resume id, the end of the turn and failure.

## 2. Components

| Component | What it is | Status |
|---|---|---|
| Composer | The panel the hotkey opens. The user types and attaches files; the current agent shows as its icon beside the send button, and ⌘/ opens the agent selector. Produces a Message. | agreed |
| Registry | One folder per agent under `~/.agents/registry/`: `agent.json` (name, harness, executable, root, voice) and an optional `instructions.md`. Written by setup. Sirius's own state (the resume id) stays in Application Support. | agreed |
| Adapter | Per agent kind. Starts the agent warm in its root, delivers Messages, knows when a turn ends, keeps the resume id. | agreed |
| Socket server | One Unix socket per agent. Validates each request against the schema and accepts it whole or rejects it. | agreed |
| Queue and presenter | One toast at a time across all agents, "+N more" for a backlog; one utterance at a time; notifications go to Notification Center. | proposed |
| Log | One append-only `log.jsonl` per agent, written only by the app. Recovery and debugging. | agreed |
| `sirius` | The CLI helper: `sirius display toast "…"`, `sirius notify …`, `sirius speak …`. Used by Claude from its shell. | agreed |
| `sirius-mcp` | The MCP helper: tools `display`, `notify`, `speak`. Used by Codex, whose sandbox blocks the CLI's socket connect without network access. | agreed |

Both helpers are thin: parse the input, build the request, send it to `$SIRIUS_SOCKET`, print or return the receipt. They read no files and keep no state.

## 3. User to agent

1. The user types in the composer, attaches files and sends. The message goes to the agent shown beside the send button, changed with ⌘/.
2. The app assigns a message id, writes each attachment to `agents/claude/attachments/<message>/`, including pasted content that is not a file yet, and appends the Message to the log.
3. If the agent is mid-turn, the Message waits until the turn ends; one turn at a time per agent (proposed).
4. The adapter renders the Message as text and starts a turn. Every adapter gets the same text:

```
<sirius message="m_7f3k2" agent="claude">
why is this failing?

<attachment path="…/agents/claude/attachments/m_7f3k2/screenshot.png" type="image/png"/>
</sirius message="m_7f3k2">
Reach the user only through display, notify or speak; your plain output is never shown.
```

5. The adapter reads the agent's stream until the turn ends, stores the resume id in `state.json`, and logs the end or the failure.

The wrapper is decided: only the model reads it, and tagged, unescaped text is what models read best. The closing tag repeats the message id, so user text containing `</sirius>` cannot end it early, which answers Codex's case for a structured object. Images may also go to the harness as native image input; the path is always in the wrapper.

## 4. Agent to user

1. During its turn the agent decides to reach the user, as its bundled instructions tell it to.
2. Claude runs `sirius display toast "Pushed the branch; tests pass."` in its shell. Codex calls the `display` tool on `sirius-mcp`.
3. The helper connects to `$SIRIUS_SOCKET`, writes one JSON-RPC request, and waits up to `SIRIUS_TIMEOUT` seconds.

```json
{"jsonrpc":"2.0","sirius":1,"id":"1","method":"display","params":{"kind":"toast","content":"Pushed the branch; tests pass."}}
```

4. The app checks the peer's uid, reads one frame, validates it, and either queues it and answers `{"delivered": true}`, or answers with an error code. The socket the request arrived on names the agent.
5. The app logs the command against the agent's current message, and the presenter shows it when its turn in the queue comes.
6. The helper exits 0 on a result, 1 on an error, 3 when Sirius isn't running, 4 when the outcome is unknown. It never retries.

## 5. Adapters

Every adapter does the same five jobs and nothing else. It never shows anything to the user, parses the agent's answer, or treats attachments per agent.

| Job | Claude Code, headless | Codex | Claude Code, live session |
|---|---|---|---|
| Start | spawn `claude -p` with stream-json in and out, in the root | spawn `codex app-server`, `initialize`, `thread/start` | none; the session is already running |
| Resume | `--resume <session>` | `thread/resume {threadId}` | none |
| Deliver | a user turn on stdin | `turn/start {threadId, input}` | a JSON line to `/tmp/cc-socks/<pid>.sock` |
| Turn end | the `result` event | `turn/completed` | the session's transcript jsonl |
| Stop | close stdin | close stdio | none |

The adapter also hands the agent its environment (`SIRIUS_SOCKET`) and the instructions for using the three commands. Adding an agent later means writing these five jobs; the protocol, the log and the UI do not change.

### 5.1 — Claude Code, warm headless

Proposed for launch. Sirius starts one `claude -p --input-format stream-json --output-format stream-json` per agent when it launches and keeps it running, so each Message skips process start and session reload. Measured warm turns took 2.4–8.2 s, about 4 s typical, against 5.2–6.0 s for a cold resume; the model turn dominates ([research/claude.md](research/claude.md)). Permissions are `--permission-mode auto --allowedTools "Bash(sirius:*)"`. The agent runs with the user's own setup (MCP servers, settings, `CLAUDE.md`) and does its normal work; with no one to prompt, auto mode's classifier approves or refuses each action, and `sirius` is always allowed so the agent can reach the user.

Claude Code channels would replace this with a push into a background session, but a `--bg` session silently drops a development channel and the managed allowlist needs admin rights ([research/channel.md](research/channel.md)). Unresolved; the protocol is the same either way.

### 5.2 — Codex, app-server

Spike done ([research/codex.md](research/codex.md)). Sirius starts `codex app-server` with `sirius-mcp` configured as an MCP server, its tools set to `approve`, and `thread/start {cwd: root, sandbox: workspace-write, approvalPolicy: never}`. Warm turns took 2.0–3.6 s.

The workspace-write sandbox has network access: Sirius passes `-c sandbox_workspace_write.network_access=true` to the app-server, so it covers every thread and the worker agents Codex starts. If Claude gets network access, Codex does too. Claude Code runs with network access, and the two harnesses get the same reach.

Codex uses `sirius-mcp` rather than `sirius` because its sandbox without network access refuses every Unix socket connect from shell commands, wherever the socket lives. MCP servers run outside the sandbox. Verified on codex 0.159.1 and the copy inside ChatGPT.app, 0.160.1. Network access now lets the shell connect too ([research/codex.md](research/codex.md) §3), but the reply path stays on `sirius-mcp` and does not depend on it.

### 5.3 — Claude Code, live session

Plan §7 ships it at launch; the schema's `harness` field has no value for it yet. The user points an agent at a session they already have open, and Sirius writes the Message to that session's socket: 2.0–2.3 s. No reply comes back on the socket, so the turn end is read from the transcript. The session needs `sirius` allowed in its own permissions.

## 6. Files on disk

| Path | Contents | Written by |
|---|---|---|
| `~/.agents/registry/<agent>/agent.json` | The definition: name, harness, executable, root, voice | setup, then the user |
| `~/.agents/registry/<agent>/instructions.md` | Optional: the user's instructions for this agent | user |
| `~/Library/Application Support/Sirius/agents/<agent>/state.json` | The resume id | app |
| `~/Library/Application Support/Sirius/agents/<agent>/log.jsonl` | Messages, commands, turn ends, failures | app |
| `~/Library/Application Support/Sirius/agents/<agent>/attachments/<message>/` | Files sent with that message | app |
| `$TMPDIR/sirius/<agent>.sock` | The agent's socket, folder mode 0700 | app |
| `$TMPDIR/sirius/sirius.lock` | Held by the running app; a second instance exits | app |

The agent writes only inside its root. It reads its attachments by path. A `file://` link in a command is opened only inside the root or the attachments folder.

## 7. Code layout

One Swift package.

| Target | Contents | Depends on |
|---|---|---|
| `SiriusProtocol` | Swift types for proto.ts: requests, results, errors, content blocks, registration. Validation. No IO. | nothing |
| `SiriusClient` | The socket client both helpers share. Connect, write one frame, read one, map to an exit code or tool result. | Protocol |
| `SiriusCore` | Registry, log, socket server, queue. | Protocol |
| `SiriusAdapters` | One file per adapter, the five jobs. | Core |
| `sirius-mcp` | The MCP helper. | Protocol, Client |
| `sirius` | The CLI helper. | Protocol, Client |
| `SiriusApp` | Sirius.app: composer, presenter, setup. Installed as `Contents/MacOS/Sirius`. | Core, Adapters |

The app and the `sirius` CLI are separate executables, so the CLI the agents run stays small and free of AppKit. `scripts/build-app.sh` builds all three and signs them into Sirius.app, with the helpers in `Contents/Helpers/`.

## 8. Open

- The Claude adapter: warm headless at about 4 s, or channels if the allowlist can be solved.
- Whether the live-session adapter ships at launch, as planned, and so needs a value in the schema's `harness` field.
- Whether `sirius display "text"` without a kind stays allowed.
- Values for the limits, the message id format and the app's default voice.
