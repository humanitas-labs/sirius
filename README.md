# Sirius

<!-- TODO(andrew): one-line description of Sirius -->

## 1. Usage

<!-- TODO(andrew): usage copy. At launch: hotkey opens the composer, the current agent shows beside the send button, ⌘/ switches agents; replies arrive as a toast, a notification or speech. No Aside, no captured context. -->

## 2. Agents

<!-- TODO(andrew): agents copy. At launch: Claude Code (`claude` on PATH) and Codex (`codex` on PATH or inside ChatGPT.app); setup picks a folder per agent. -->

Sirius needs Claude Code 2.1.71 or later (the first with `--permission-mode auto`; 2.1.257 or later keeps an edited instructions.md in a resumed session) and Codex 0.132.0 or later (the oldest release macOS still runs; before 0.147.0 Sirius leaves out its `features.multi_agent_v2` settings, so the agent does its work itself rather than handing it to helper agents). An older Claude Code gets a toast asking for `claude update`, an older Codex one asking to update it. `scripts/compat-test.sh` checks these floors against real releases, and `scripts/make-dmg.sh` runs it before it builds.

## 3. How it works

<!-- TODO(andrew): how-it-works copy. -->

The design is in [docs/architecture.md](docs/architecture.md).

## 4. Build from source

`scripts/build-app.sh` builds `build/Sirius.app`, signed with the keychain's Developer ID if there is one.

## 5. License

Sirius is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
