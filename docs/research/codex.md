# Spike: Codex side

The throwaway scripts this refers to were removed from the repository once the adapters landed.

Run 2026.10.09. Throwaway. Scripts: `drive.py` drives `codex app-server` over stdio, `listener.py` is a Unix-socket listener that answers every request, `connect.py` is a probe client that prints the exact errno, and `mcp_stub.py` is an MCP server named `sirius`. The helper under test is the Claude spike's `helper.swift`, built with `swiftc -O helper.swift -o .bin/sirius`. The agent's cwd was a scratch dir, `~/.sirius-spike`, because the session scratchpad path (152 bytes) exceeds macOS's 104-byte socket limit.

## 1. Binaries

| Binary | Version | Notes |
|---|---|---|
| `codex` on PATH (`~/.local/bin/codex`) | `codex-cli 0.159.1` | |
| `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` | `codex-cli 0.160.1` | A 328-byte `sh` wrapper that execs `../CodexCLI.app/Contents/MacOS/codex` |

The bundled binary has `app-server` (same subcommands: `daemon`, `proxy`, `generate-ts`, `generate-json-schema`). From a plain shell outside ChatGPT.app (`env -i HOME=$HOME PATH=/usr/bin:/bin USER=$USER`), it initialised, started a thread and completed a turn ("bundled ok", 3.4 s). It uses the same `~/.codex` home, so it shares the CLI's login.

## 2. Warm process via app-server

Schema from the binary: `codex app-server generate-json-schema --out DIR`, giving 39 files plus v1/v2. Framing is newline-delimited JSON-RPC over stdio. The server omits the `"jsonrpc": "2.0"` member in what it sends but accepts it.

Sequence: `initialize` (requires `clientInfo {name, version}`), then the `initialized` notification, then `thread/start {cwd, sandbox, approvalPolicy}`, which returns `result.thread.id`, then `turn/start {threadId, input: [{type: "text", text}]}`.

| Step | Result |
|---|---|
| Turn 1, "Remember the word kumquat. Reply only: ok." | `ok.`, 3.3 s |
| Turn 2, same thread, "What word…?" | `kumquat`, 1.5 s. Context holds |
| Kill the server, start a new one, `thread/resume {threadId}`, ask again | `kumquat`, 3.6 s. Context is restored from disk |

The end of a turn is the `turn/completed` notification, carrying `params.turn.status` ("completed") and the turn's items. The final text is the `item/completed` with `item.type == "agentMessage"`, also present in `turn/completed.params.turn.items` with `phase: "final_answer"`. Other notifications per turn: `turn/started`, `item/started`, `item/agentMessage/delta`, `thread/status/changed`, `thread/tokenUsage/updated`, `account/rateLimits/updated`, plus about 13 `mcpServer/startupStatus/updated` at start from the user's own MCP config.

## 3. Sandbox and the socket

A throwaway listener ran outside any sandbox on four paths. From my shell, every connect succeeded. From the agent's shell under `sandbox: workspace-write`, `approvalPolicy: never`:

| Socket | Default workspace-write | `-c sandbox_workspace_write.network_access=true` |
|---|---|---|
| `~/Library/Application Support/Sirius/sirius.sock` | FAIL errno=1 Operation not permitted | not retested |
| `$TMPDIR/sirius.sock` | FAIL errno=1 Operation not permitted | not retested |
| `/tmp/sirius-501.sock` | FAIL errno=1 Operation not permitted | OK* |
| `~/.sirius-spike/sirius.sock` (inside the thread's cwd) | FAIL errno=1 Operation not permitted | OK |

The default sandbox blocks the `connect()` itself, regardless of location, even inside a writable root. Network access is what governs Unix-socket connects, not file permissions. Enabling network access on the turn allows it.

\* The `/tmp/sirius-501.sock` OK under network access was answered by the Claude spike's listener, which had taken that path at 13:31. The connect still succeeded from inside the sandbox, which is the point; later runs used `/tmp/sirius-501-c76.sock`.

The real helper confirmed the same result. Default sandbox: exit 1, `sirius: cannot connect to /tmp/sirius-501-c76.sock: Operation not permitted`. With `network_access=true`: exit 0, delivered (listener got `{"method":"display","params":{"handle":"codex","kind":"toast","content":"helper shell"}}`).

A narrower allowlist did not work from `-c`. `-c 'network.allow_unix_sockets=[...]'` still gave EPERM, and app-server stderr said "session-flags: `network` is ignored". The schema and the binary do have `allowUnixSockets` / `dangerouslyAllowAllUnixSockets` / `network.unix_sockets` under the managed network requirements and permission profiles. That route is unverified.

## 4. MCP path

The stub server was configured per process with:

```
-c 'mcp_servers.sirius.command="python3"'
-c 'mcp_servers.sirius.args=["…/codex/mcp_stub.py"]'
-c 'mcp_servers.sirius.env={SIRIUS_SOCKET="/tmp/sirius-501-c76.sock", SIRIUS_HANDLE="codex", SIRIUS_HELPER="…/.bin/sirius"}'
-c 'mcp_servers.sirius.tools.display.approval_mode="approve"'
```

- **The MCP server runs outside the sandbox.** With the default workspace-write sandbox and no network access, the stub connected to the socket itself ("OK … delivered"). Shelling out to the real helper also worked (`helper rc=0`, listener got "mcp via helper").
- **The env table reaches the MCP server.** The tool's result echoed `SIRIUS_SOCKET=/tmp/sirius-501-c76.sock SIRIUS_HANDLE=codex`.
- **Approval needs a per-tool setting.** Without `tools.display.approval_mode="approve"` and with `approvalPolicy: never`, the call fails at once with "MCP tool call requires approval, but approval policy is never". It doesn't hang.

## 5. Env

SIRIUS_SOCKET and SIRIUS_HANDLE set on the app-server process did **not** reach the agent's shell on this machine. `echo` printed them empty, because `~/.codex/config.toml` sets `[shell_environment_policy] inherit = "core"`. Two settings make them arrive:

- `-c shell_environment_policy.inherit=all`, which passes the whole environment;
- `-c 'shell_environment_policy.set.SIRIUS_SOCKET="…"'` and `…set.SIRIUS_HANDLE="…"`, which sets just these two.

The second is the safer choice for the adapter, since it works whatever the user's inherit setting is. It was used in the latency runs.

## 6. Approvals that run headless without a hang

| Path | Settings |
|---|---|
| Shell | `approvalPolicy: never`, `sandbox: workspace-write`, `-c sandbox_workspace_write.network_access=true`, plus `shell_environment_policy.set.SIRIUS_*` |
| MCP | `approvalPolicy: never`, default workspace-write (no network needed), plus `mcp_servers.sirius.tools.display.approval_mode="approve"` |

Under `never`, nothing hung in any run. A blocked connect returns EPERM, and an unapproved MCP call fails immediately. Untested: `on-request` or `untrusted` policies, which would send approval requests to the client. drive.py auto-declines those, and the adapter would need to answer them.

The trade-off: network access opens all network for the turn, not just the socket. The MCP path needs no sandbox widening.

## 7. Latency, warm

Wall time from `turn/start` sent to the listener's receive timestamp, same warm process, after a first "remember kumquat" turn:

| Run | Shell (`sirius display toast`) | MCP (`display` tool → helper) |
|---|---|---|
| 1 | 3.62 s | 4.84 s |
| 2 | 2.98 s | 1.90 s |
| 3 | 1.96 s | 2.13 s |

Almost all of it is the model deciding to call the tool. Full turn times were 3.5–6.4 s.

## Unverified

- Codex's managed Unix-socket allowlist (`network.unix_sockets` / `allowUnixSockets` via a permission profile or requirements).
- The `~/Library/Application Support/Sirius` and `$TMPDIR` paths were not retested with network access, though the block is not path-based.
- Approval policies other than `never`.
- The bundled binary's sandbox and MCP behaviour. Only a plain turn was run with it.
- Codex's sandbox profile with the ChatGPT app's own config, as opposed to this user's `~/.codex/config.toml`.

## 8. Items 3 and 4 with the bundled ChatGPT.app binary

Rerun with `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (`codex-cli 0.160.1`, `userAgent … 0.160.1`), same scratch cwd, `approvalPolicy: never`, default `workspace-write` with no network flag, and the listener at `/tmp/sirius-501-c76.sock`.

- **Shell is blocked, as with the CLI.** `connect.py` gave `FAIL /tmp/sirius-501-c76.sock errno=1 Operation not permitted` (exit 1). The real helper gave `sirius: cannot connect to /tmp/sirius-501-c76.sock: Operation not permitted` (exit 1).
- **MCP holds.** With `mcp_servers.sirius.tools.display.approval_mode="approve"` and the env table, the `display` tool completed. The stub shelled out to the helper (`helper rc=0`) and echoed `SIRIUS_SOCKET=/tmp/sirius-501-c76.sock SIRIUS_HANDLE=codex`. The listener received `{"method":"display","params":{"handle":"codex","kind":"toast","content":"bundled mcp"}}`. So on the bundled binary the MCP server runs outside the sandbox and its connect succeeds.

Still unverified on the bundled binary: whether ChatGPT.app's own managed config, if any, changes this. The binary read this user's `~/.codex`.
