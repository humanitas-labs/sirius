# Spike: Claude Code, critical unknowns

The throwaway scripts this refers to were removed from the repository once the adapters landed.

2026.10.09, Claude Code 2.1.296, model claude-fable-5-1, macOS 26 arm64. Throwaway: nothing here is a design.

Setup for every run:
- Helper: `swiftc -O helper.swift -o .bin/sirius`, on PATH.
- Listener: `swift listener.swift <socket>`.
- Agent cwd: a scratch folder (`$SCRATCH/agentcwd`).
- Driver: `claude_warm.py`, which writes stream-json turns to one process and prints the events per turn.
- Socket for items 1–5 and 7: `/tmp/sirius-501-c75.sock`, a separate path because another worker was on `/tmp/sirius-501.sock`.

## Answers

1. **Warm process.**
   - Yes, a second turn on the same stdin keeps context. "What word?" got `kumquat`.
   - End of turn is the `result` event (`type: "result"`, `subtype: "success"`), one per turn, carrying `session_id`. Every turn also re-emits `system/init` first.
   - The session id is the same across turns.
   - After killing the process, a new one started with `--resume <session_id>` restores the context (`kumquat` again) and keeps the same session id.
2. **Env.** Yes. `SIRIUS_SOCKET` and `SIRIUS_HANDLE` set on the `claude` process reach the Bash tool's subprocess. The listener logged `"handle":"claude"`, and `"handle":"claude-live"` for the live session.
3. **Permissions.**
   - `--allowedTools "Bash(sirius:*)"` runs the helper with no prompt and no hang, alone or with `--permission-mode dontAsk`.
   - With no flags, the call is denied at once: tool_result "This command requires approval", a `system/permission_denied` event, `permission_denials` in the result, and the turn still ends with `result/success`. No hang.
   - A disallowed command next to an allowed one also fails fast. `ls /` was blocked and `sirius` still ran in the same turn.
   - `--permission-mode dontAsk` without the allow rule denies Bash outright.
   - `auto` and `bypassPermissions` both ran it. `auto` is the classifier and isn't predictable; `bypassPermissions` is too broad.
   - Recommended: `--permission-mode dontAsk --allowedTools "Bash(sirius:*)"`.
   - Pitfall: `--allowedTools` takes several values, so a prompt written after it is swallowed as a tool name. Pass the prompt on stdin or before the flag. With `--resume` this showed as "No deferred tool marker found in the resumed session".
4. **MCP path.**
   - Works with `--mcp-config <file> --strict-mcp-config --allowedTools mcp__sirius__display`.
   - The env set in the MCP config reaches the server. `claude` was started with SIRIUS_SOCKET and SIRIUS_HANDLE unset, and the listener logged `"handle":"claude-via-mcp"` from the config.
   - The tool's error (unknown kind) comes back as `isError` with the helper's message.
   - Cost: MCP tools are deferred, so the model first calls ToolSearch (`select:mcp__sirius__display`). That's one extra step per session before the first display.
5. **Live session.**
   - The format is one JSON object per line on `/tmp/cc-socks/<pid>.sock`: `{"type":"user","message":{"role":"user","content":"<text>"}}`, optionally preceded by `{"type":"auth","token":"<key>"}`. The key is in `~/.claude/sessions/<pid>.<hash>.key`, mode 600.
   - Source: the session's own `--debug-file` log, which prints an "Inject messages (auth line optional here)" example.
   - Injection from outside Claude Code works without the auth line on this machine. The session queued it ("Routed user message to queue (priority=next)"), ran the turn and displayed the toast.
   - The flat form `{"type":"user","content":"…"}` is dropped ("missing or non-string content").
   - The session records the message with origin `{"kind":"peer","from":"unknown","verifiedPeerPid":…}` and presents it as a cross-session message from another session, wrapped with peer-trust instructions.
   - End of turn: nothing comes back on the socket (the connection gets no reply and is closed after 30 s idle). The only signal I found is the session transcript `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`: an `assistant` entry with `stop_reason: "end_turn"`, then `system/turn_duration`.
   - Tested only against a scratch session I started in a detached tmux and killed afterwards.
6. **Socket location.** The round trip works at all three paths, with the helper run by Claude's Bash tool:
   - `~/Library/Application Support/Sirius/sirius.sock`: 62 bytes here (`/Users/<user>/…`).
   - `$TMPDIR/sirius.sock`: 60 bytes (`/var/folders/3s/…/T/sirius.sock`).
   - `/tmp/sirius-501-c75.sock`: 24 bytes. `/tmp/sirius-$UID.sock` would be 20.

   The macOS limit is 103 usable bytes. The App Support path grows with the username: a 41-byte username would overflow.
7. **Latency.** Wall time from writing the turn to the listener receiving the toast.

   | Path | Runs | Times |
   |---|---|---|
   | Warm process (stream-json stdin), after a warm-up turn | 3 | 8.18 s, 3.90 s, 4.21 s (a fourth, in item 1: 2.36 s) |
   | Cold `claude -p --resume`, process start included | 3 | 5.95 s, 5.16 s, 5.26 s |
   | Live interactive session, socket injection (extra) | 3 | 2.05 s, 2.27 s, 2.04 s |

   The model turn dominates and varies. The 8.18 s warm run included a thinking block. Warm saves about 1 s over cold at the median here. The live session was fastest on the same model, and I haven't explained why.

## Unverified

- Whether the live socket's unauthenticated injection is allowed everywhere. The log says "auth line optional here", which suggests auth can be mandatory on other platforms or setups. The authenticated form wasn't tested.
- Whether a turn-end signal exists on the live socket protocol itself. Strings in the binary name `notify_when_idle` and `peer_idle_notice` frames, but their fields aren't documented, and the reply address has to be a socket in Claude Code's own namespace. Not attempted.
- Behaviour when a live session is busy mid-turn. The message queues (priority=next), but ordering and latency weren't measured.
- Why headless turns are slower than the live session.
- Inside Codex.s sandbox: nothing here; see the Codex spike ([codex.md](codex.md)).

## Raw results

### b1

```
$ claude -p --input-format stream-json --output-format stream-json --verbose --allowedTools Bash(sirius:*)

-- turn 1 written at 13:31:06.321: Remember the word kumquat. Reply only by running the shell command: sirius display toast "<your reply>"
   tool_use Bash: {"command": "sirius display toast \"Got it. Remembered: kumquat.\"", "description": "Display toast confirming the word is remembered"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > rate_limit_event > user > assistant > rate_limit_event > result/success
   result: subtype=success is_error=False session_id=e19f3d41-9afc-47cb-bd58-0de38ee34719 num_turns=2 duration_ms=6207 wall=6.82s
   text: Done. The toast reads: "Got it. Remembered: kumquat."

-- turn 2 written at 13:31:13.143: What word did I ask you to remember? Reply only by running: sirius display toast "<the word>"
   tool_use Bash: {"command": "sirius display toast \"kumquat\"", "description": "Display toast with the remembered word"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > user > assistant > result/success
   result: subtype=success is_error=False session_id=e19f3d41-9afc-47cb-bd58-0de38ee34719 num_turns=2 duration_ms=3867 wall=3.87s
   text: The toast reads: "kumquat".

exit 0
```

### b1r

```
$ claude -p --input-format stream-json --output-format stream-json --verbose --allowedTools Bash(sirius:*) --resume e19f3d41-9afc-47cb-bd58-0de38ee34719

-- turn 1 written at 13:31:24.661: What word did I ask you to remember? Reply only by running: sirius display toast "<the word>"
   tool_use Bash: {"command": "sirius display toast \"kumquat\"", "description": "Display toast with the remembered word"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > rate_limit_event > user > assistant > result/success
   result: subtype=success is_error=False session_id=e19f3d41-9afc-47cb-bd58-0de38ee34719 num_turns=2 duration_ms=4545 wall=5.17s
   text: The toast reads: "kumquat".

exit 0
```

### b3a

```
$ claude -p --input-format stream-json --output-format stream-json --verbose

-- turn 1 written at 13:32:30.146: Run the shell command: sirius display toast "no flags"
   tool_use Bash: {"command": "sirius display toast \"no flags\"", "description": "Show a toast via sirius"}
   tool_result (is_error=True): This command requires approval
   events: system/init > assistant > system/permission_denied > user > rate_limit_event > assistant > result/success
   result: subtype=success is_error=False session_id=cc9b921e-7ffd-4eaf-81b3-975ebd594e2e num_turns=2 duration_ms=4375 wall=5.07s
   text: The command was not run. The permission system blocked it with "This command requires approval", and this session is non-interactive, so nobody could grant it.

To run it, either approve the `sirius` command in an interactive session or add it to the allowlist in settings.json, for example under per
   permission_denials: [{"tool_name": "Bash", "tool_use_id": "toolu_01PFpavr2pvCwuYtQz7aw5Fk", "tool_input": {"command": "sirius display toast \"no flags\"", "description": "Show a toast via sirius"}}]

exit 0
```

### b3b

```
$ claude -p --input-format stream-json --output-format stream-json --verbose --allowedTools Bash(sirius:*)

-- turn 1 written at 13:32:36.124: Run the shell command: ls / . Then run: sirius display toast "after ls"
   tool_use Bash: {"command": "ls /", "description": "List root directory"}
   tool_result (is_error=True): ls in '/' was blocked. For security, Claude Code may only list files in the allowed working directories for this session: '$SCRATCH/agentcwd'.
   tool_use Bash: {"command": "sirius display toast \"after ls\"", "description": "Show a toast notification"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > system/permission_denied > user > rate_limit_event > system/thinking_tokens > assistant > rate_limit_event > user > assistant > result/success
   result: subtype=success is_error=False session_id=d2a26152-f652-4a85-b598-f8259cda6d4a num_turns=3 duration_ms=9749 wall=10.34s
   text: The toast ran. The `ls /` did not: the session sandbox blocks listing anything outside the working directory, so Claude Code refused it before the shell ran.

```
ls in '/' was blocked. For security, Claude Code may only list files in the allowed working directories for this session
```

The toast c
   permission_denials: [{"tool_name": "Bash", "tool_use_id": "toolu_01XKp2xQxKsgPYYuxL3FGNAv", "tool_input": {"command": "ls /", "description": "List root directory"}}]

exit 0
```

### b3c

```
=== --permission-mode dontAsk --allowedTools Bash(sirius:*)
=== --permission-mode dontAsk
   tool_result (is_error=True): Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using h
   events: system/init > assistant > system/permission_denied > user > rate_limit_event > assistant > rate_limit_event > result/success
   result: subtype=success is_error=False session_id=d6f7cdf0-a007-4020-b5fc-1a0b382c9769 num_turns=2 duration_ms=7962 wall=8.72s
=== --permission-mode auto
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > rate_limit_event > user > assistant > rate_limit_event > result/success
   result: subtype=success is_error=False session_id=98d25439-f764-4d22-b212-7779e9c74180 num_turns=2 duration_ms=10553 wall=11.18s
=== --permission-mode bypassPermissions
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > rate_limit_event > user > assistant > result/success
   result: subtype=success is_error=False session_id=dfa14b68-4fa1-4c70-9a19-21d9097a4ff2 num_turns=2 duration_ms=3385 wall=3.98s
   tool_use Bash: {"command": "sirius display toast \"dontAsk allowed\"", "description": "Show a toast notification via sirius"}
   tool_use Bash: {"command": "ls ~", "description": "List home directory"}
   tool_result (is_error=False): (Bash completed with no output)
   tool_result (is_error=True): Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that m
   events: system/init > assistant > rate_limit_event > user > system/permission_denied > user > system/thinking_tokens > assistant > result/success
   result: subtype=success is_error=False session_id=137014f3-202d-4b82-9c4f-f14319ceb7b1 num_turns=3 duration_ms=7419 wall=8.14s
   permission_denials: [{"tool_name": "Bash", "tool_use_id": "toolu_0173RPxnSvfhaQD28fRW83A7", "tool_input": {"command": "ls ~", "description": "List home directory"}}]
```

### b4

```
$ claude -p --input-format stream-json --output-format stream-json --verbose --mcp-config $SCRATCH/

-- turn 1 written at 13:33:54.950: Use the sirius display tool with kind toast and content "via mcp". Then use it again with kind dialog and content "x".
   tool_use ToolSearch: {"query": "select:mcp__sirius__display", "max_results": 1}
   tool_result (is_error=None): [{"type": "tool_reference", "tool_name": "mcp__sirius__display"}]
   tool_use mcp__sirius__display: {"kind": "toast", "content": "via mcp"}
   tool_result (is_error=None): [{"type": "text", "text": "delivered"}]
   tool_use mcp__sirius__display: {"kind": "dialog", "content": "x"}
   tool_result (is_error=True): sirius: unknown display kind: dialog (code -32001)
   events: system/init > assistant > user > rate_limit_event > system/thinking_tokens > assistant > user > assistant > rate_limit_event > user > assistant > result/success
   result: subtype=success is_error=False session_id=3fc77433-770c-4089-a8d6-a2ab989f8cfb num_turns=4 duration_ms=7469 wall=8.06s
   text: The toast "via mcp" was delivered. The dialog call failed: sirius returned "unknown display kind: dialog (code -32001)". The tool's own description says only the toast kind is built, so dialog and aside are decl

exit 0
```

### b7w

```
$ claude -p --input-format stream-json --output-format stream-json --verbose --allowedTools Bash(sirius:*) Bash(echo:*)

-- turn 1 written at 13:37:57.146: Reply only by running the shell command: sirius display toast "warmup". Also tell me your TMPDIR by running: echo $TMPDIR
   tool_use Bash: {"command": "sirius display toast \"warmup\"", "description": "Display a warmup toast via sirius"}
   tool_use Bash: {"command": "echo $TMPDIR", "description": "Print TMPDIR environment variable"}
   tool_result (is_error=False): (Bash completed with no output)
   tool_result (is_error=True): A variable in this command can't be checked before it runs
   tool_use Bash: {"command": "printenv TMPDIR", "description": "Print TMPDIR environment variable"}
   tool_result (is_error=True): This command requires approval
   events: system/init > assistant > rate_limit_event > user > system/permission_denied > user > assistant > system/permission_denied > user > assistant > rate_limit_event > result/success
   result: subtype=success is_error=False session_id=7cdbb7db-7b61-4d56-979c-1cced1db615f num_turns=4 duration_ms=11720 wall=12.33s
   text: The toast command ran with no output. The TMPDIR lookup was denied by the permission layer in both forms (`echo $TMPDIR` and `printenv TMPDIR`), so I cannot report it from this session.
   permission_denials: [{"tool_name": "Bash", "tool_use_id": "toolu_016RrNJ2Sj8rEMaizQhBudgw", "tool_input": {"command": "echo $TMPDIR", "description": "Print TMPDIR environment variable"}}, {"tool_name": "Bash", "tool_use_id": "toolu_01SsYN3JnYb1xL9ipYdm3s6b"

-- turn 2 written at 13:38:09.477: Reply only by running the shell command: sirius display toast "warm 1"
   tool_use Bash: {"command": "sirius display toast \"warm 1\"", "description": "Display a toast via sirius"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > user > assistant > result/success
   result: subtype=success is_error=False session_id=7cdbb7db-7b61-4d56-979c-1cced1db615f num_turns=2 duration_ms=10644 wall=10.65s
   text: Done. The toast command ran with no output.

-- turn 3 written at 13:38:20.126: Reply only by running the shell command: sirius display toast "warm 2"
   tool_use Bash: {"command": "sirius display toast \"warm 2\"", "description": "Display a toast via sirius"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > user > assistant > result/success
   result: subtype=success is_error=False session_id=7cdbb7db-7b61-4d56-979c-1cced1db615f num_turns=2 duration_ms=6256 wall=6.26s
   text: Done. The toast command ran with no output.

-- turn 4 written at 13:38:26.386: Reply only by running the shell command: sirius display toast "warm 3"
   tool_use Bash: {"command": "sirius display toast \"warm 3\"", "description": "Display a toast via sirius"}
   tool_result (is_error=False): (Bash completed with no output)
   events: system/init > assistant > user > assistant > result/success
   result: subtype=success is_error=False session_id=7cdbb7db-7b61-4d56-979c-1cced1db615f num_turns=2 duration_ms=6466 wall=6.47s
   text: Done. The toast command ran with no output.

exit 0
```

### b7c

```
cold run 1: start 13:39:42.877 toast 13:39:48.825 = 5.95s
cold run 2: start 13:39:58.455 toast 13:40:03.612 = 5.16s
cold run 3: start 13:40:07.177 toast 13:40:12.439 = 5.26s
```

### b7l

```
live run 1: 2.05s
live run 2: 2.27s
live run 3: 2.04s
```

### live session debug log (uds lines)

```
2026-10-09T20:36:14.291Z [INFO] [uds-messaging] Listening: /tmp/cc-socks/13048.sock
2026-10-09T20:36:14.291Z [INFO] [uds-messaging] Inject messages (auth line optional here): { echo '{"type":"auth","token":"[REDACTED]"$CLAUDE_CODE_MESSAGING_TOKEN"'"}'; echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } | socat - UNIX-CONNEC
2026-10-09T20:36:14.294Z [INFO] [uds-messaging] Connect when the data is ready (e.g. out=$(cmd); printf '%s\n' "$out" | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET" — or the socat form above): a connection that sends no complete line within 30000 ms is closed
2026-10-09T20:36:24.151Z [DEBUG] [uds-messaging] Client connected
2026-10-09T20:36:24.151Z [WARN] [uds-messaging] Ignoring user message with missing or non-string content
2026-10-09T20:36:28.156Z [DEBUG] [uds-messaging] Client disconnected
2026-10-09T20:36:42.357Z [DEBUG] [uds-messaging] Client connected
2026-10-09T20:36:42.359Z [DEBUG] [uds-messaging] Routed user message to queue (priority=next): Reply only by running the shell command: sirius display toast "live ok"
2026-10-09T20:36:45.360Z [DEBUG] [uds-messaging] Client disconnected
2026-10-09T20:40:22.464Z [DEBUG] [uds-messaging] Client connected
2026-10-09T20:40:22.466Z [DEBUG] [uds-messaging] Routed user message to queue (priority=next): Reply only by running the shell command: sirius display toast "live run 1"
2026-10-09T20:40:22.498Z [DEBUG] [uds-messaging] Client disconnected
2026-10-09T20:40:28.676Z [DEBUG] [uds-messaging] Client connected
2026-10-09T20:40:28.677Z [DEBUG] [uds-messaging] Routed user message to queue (priority=next): Reply only by running the shell command: sirius display toast "live run 2"
2026-10-09T20:40:28.692Z [DEBUG] [uds-messaging] Client disconnected
2026-10-09T20:40:35.101Z [DEBUG] [uds-messaging] Client connected
2026-10-09T20:40:35.102Z [DEBUG] [uds-messaging] Routed user message to queue (priority=next): Reply only by running the shell command: sirius display toast "live run 3"
2026-10-09T20:40:35.118Z [DEBUG] [uds-messaging] Client disconnected
2026-10-09T20:40:53.692Z [DEBUG] [uds-messaging] Shutting down
```
