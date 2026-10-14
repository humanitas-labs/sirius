# Sirius docs :: Index

Last updated: `2026.10.13`

> How Sirius is built and the contract between Sirius and the agents it runs.

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | The app, the helpers and the adapters, and how a message and a reply flow through them |
| [protocol/proto.ts](protocol/proto.ts) | The wire contract: commands, content, errors, the registration and the Message. Draft 1 |
| [research/claude.md](research/claude.md) | Spike: driving Claude Code warm and headless over stream-json, and what the CLI helper needs |
| [research/codex.md](research/codex.md) | Spike: driving `codex app-server` with an MCP helper, and why Codex's sandbox blocks the CLI's socket |
| [research/channel.md](research/channel.md) | Spike: Claude Code channels as a push path, and why they don't work for a background session |
| [dictation.md](dictation.md) | Dictation as built: fn to an agent, ⌃fn to paste, the ParrotCore engine and permissions |
| [research/asr-models.md](research/asr-models.md) | Speech models for dictation: Whisper sizes measured here, the prompt that does nothing today, and the other families |
| [protocol/examples/](protocol/examples/) | Valid and invalid request frames (JSON, or raw bytes for lexical edges), one per validation rule and boundary, each with its full expected output: id and normalized params, or id, error code and data. Descriptions marked PENDING pin current behavior awaiting a decision |
