# Sirius docs :: Index

Last updated: `2026.10.13`

> How Sirius is built and the contract between Sirius and the agents it runs.

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | The app, the helpers and the adapters, and how a message and a reply flow through them |
| [protocol/proto.ts](protocol/proto.ts) | The wire contract: commands, content, errors, the registration and the Message. Draft 1 |
| [dictation.md](dictation.md) | Dictation as built: fn to an agent, ⌃fn to paste, the ParrotCore engine and permissions |
| [protocol/examples/](protocol/examples/) | Valid and invalid request frames (JSON, or raw bytes for lexical edges), one per validation rule and boundary, each with its full expected output: id and normalized params, or id, error code and data. Descriptions marked PENDING pin current behavior awaiting a decision |
