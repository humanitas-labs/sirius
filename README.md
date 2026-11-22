<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/icon-light.png">
    <img src="docs/assets/icon.png" width="128" alt="Sirius">
  </picture>
</p>

# Sirius

Sirius is the first ambient intelligence for macOS.

Hold `fn` and speak, or press ⌘⇧J to type, and your agent gets to work in its own folder. Replies come back as a toast, a notification or a spoken line.

We believe the future is multi-agent, so Sirius is bring your own harness (BYOH): it has no model of its own and drives the agent CLI you already use, with your account and settings. Claude Code, ChatGPT / Codex, Cursor, Google's Antigravity (Gemini), Muse Code and OpenCode work out of the box; others are one adapter away ([docs/byoh.md](docs/byoh.md)).

[Download Sirius](https://trysirius.app/download) for macOS 14+ on Apple Silicon.

## 1. Usage

| Shortcut | What it does |
|---|---|
| Hold `fn` and speak | Send to an agent. Start with its name ("Claude, …") to pick one |
| Hold ⌃ and `fn` | Paste what you said at the cursor, in any app |
| ⌘⇧J | Open the composer; `fn` dictates into it |
| ⌘/ (in the composer) | Switch to the next agent |

Change both shortcuts in **Settings…**. Speech recognition runs on your Mac; the first start downloads the speech model (about 145 MB), or reuses Parrot's model and dictionary. The full manual ships in the app under **Sirius Manual**, and your agent can answer questions from it ([read it here](docs/manual/index.md)).

## 2. How it works

Each agent is a CLI session Sirius keeps warm in its workspace through a per-harness adapter. The agent reaches you by calling Sirius (the `sirius` command or the `sirius-mcp` server), never by its own output. See [docs/architecture.md](docs/architecture.md) and [docs/byoh.md](docs/byoh.md).

## 3. Build from source

```sh
swift build && swift test
scripts/dev-install.sh      # build, sign, and install Sirius.app
```

Without a Developer ID in your keychain the app is ad-hoc signed, and macOS forgets its permissions on every rebuild.

## 4. License and bugs

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Report bugs at [github.com/humanitas-labs/sirius/issues](https://github.com/humanitas-labs/sirius/issues) with `~/Library/Logs/Sirius/sirius.log` attached; it records what Sirius did, not what you said.
