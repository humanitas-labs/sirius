# Spike: Sirius as a Claude Code channel

The throwaway scripts this refers to were removed from the repository once the adapters landed.

Throwaway. Claude Code 2.1.296, macOS, claude.ai login. Status: **blocked at item 1**. A development channel needs a one-time interactive confirmation, and nothing headless accepts it. Items 2–5, 7 and 8 have not been run.

## Setup

- `channel/server.py` is a stdio MCP server. It declares `capabilities.experimental["claude/channel"]`, listens on `$CHANNEL_SOCKET` for JSON lines `{"content": ...}`, pushes each one as `notifications/claude/channel` `{content, meta: {request_id, handle}}`, and exposes a `display(kind, content)` tool that runs `.bin/sirius display` against `listener.swift`. It logs to `$CHANNEL_LOG`.
- `channel/push.py <socket> "<content>"` pushes one request.
- The server is loaded as a bare MCP server (`--mcp-config` with `--strict-mcp-config`, entry `server:sirius`), not as a plugin.
- The cwd is a trusted scratch directory, because `--bg` refuses an untrusted one ("Workspace not trusted").

## 1. Background start with a development channel

Run 1, with the development flag only:

```
claude --bg --mcp-config ch-mcp.json --strict-mcp-config \
  --dangerously-load-development-channels server:sirius \
  --permission-mode dontAsk --allowedTools "mcp__sirius__*" --debug-file ch-debug.txt
backgrounded · bd743efb
```

Debug log:

```
MCP server "sirius": Channel notifications skipped: server sirius not in --channels list for this session
```

Run 2, with `--channels server:sirius` and the development flag together:

```
backgrounded · 5705d0b3
MCP server "sirius": Channel notifications skipped: server sirius is not on the approved channels allowlist (use --dangerously-load-development-channels for local dev)
```

In both runs the MCP server connected (`initialize` from `claude-code 2.1.296`, inbox listening) and `claude logs` showed an idle prompt with no dialog. The channel was not registered. `--bg` does not fail, but it silently drops the development channel.

The same flags in a foreground session (inside a detached tmux pane) show a blocking dialog:

```
WARNING: Loading development channels
--dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you have downloaded off the internet.
Please use --channels to run a list of approved channels.
Channels: server:sirius
❯ 1. I am using this for local development
  2. Exit
Enter to confirm · Esc to cancel
```

Answer: no. A development channel needs this confirmation for each launch. `--bg` never shows the dialog, so the channel is never approved. The binary's strings show no setting or flag that pre-accepts it. The only gates are the `channelsEnabled` managed setting ("channels not enabled by org policy (set channelsEnabled: true in managed settings)") and the `allowedChannelPlugins` managed allowlist ("not on your org's approved channels list"). Both apply to `plugin:` entries under `--channels`. A `server:` entry always needs the development flag ("server: entries need --dangerously-load-development-channels").

Unverified: the agent did not confirm the dialog, by policy (it would be accepting a security warning on the user's behalf). So it is not known whether a foreground session, once confirmed, delivers pushes, or whether `claude attach` to a `--bg` session would show the dialog. Next step: a person confirms it once in tmux, or the channel ships as a plugin in a marketplace and runs as `--channels plugin:sirius@<marketplace>` with `allowedChannelPlugins` (managed settings).

TODO(andrew): ship Sirius as a plugin with an approved channel (managed `allowedChannelPlugins`), or accept a one-time manual confirmation per session launch.

## 2–5, 7, 8

Not run. Every one of them needs a session with the channel registered, and item 1 blocks that.

## 6. Login and `-p`

From the binary's strings, not tested:

- "channels are not available on third-party providers": channels need first-party auth (claude.ai or Console), not Bedrock or Vertex.
- "channels feature is not currently available": there is also a feature gate.
- `channelsEnabled` defaults to on for Console and off for claude.ai Teams/Enterprise, per the earlier strings read.

Whether `-p` registers channels at all was not tested.
