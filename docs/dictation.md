# Dictation

Last updated: `2026.10.13`. Built; this records the design decisions. The plan and implementation plan it came from were removed after dictation shipped.

> Hold `fn` anywhere, speak, release, and what you said goes to an agent. Hold ⌃ with `fn` and it is pasted at the cursor instead. Sirius takes over from Parrot, using ParrotCore as its engine.

## Decisions

- **One key, `fn`, system-wide.** Not limited to the composer. Sirius owns `fn` and Parrot is being retired; onboarding asks the user to quit Parrot while it is open (db1e1f7).
- **Commands by default.** The main use is speaking to an agent, not dictating into text fields.
- **⌃fn pastes at the cursor.** Hold ⌃ and `fn` together, in either order (⌃ may join within 0.3 s of `fn`), and the transcript is pasted into the frontmost app through ParrotCore's `CursorDelivery` (clipboard, ⌘V, clipboard restored after 0.25 s), or into the composer when it has focus. The chord is the hold key plus ⌃, or ⌃⇧ when the hold key is ⌃ (`HoldKey.pasteModifier`). This replaced the spoken "Dictate:" prefix, removed in 71b20e7. Sirius holds its own tap (`HoldMonitor`, matched in SiriusCore's `HoldGesture`) instead of ParrotCore's `HotkeyMonitor`, whose `Gesture` cancels every chord (8480aa7, 9c48e55).
- **An agent's name addresses it.** Leading with "Claude, …" or "Codex, …" sends to that agent. The agent names go into the transcription prompt as vocabulary.
- **No name, the composer's agent.** The agent selected in the composer, remembered across launches (`composer.lastAgent`), is the default until switched. A fixed default agent is the fallback if this keeps misrouting.
- **With the composer open, `fn` dictates into the composer** rather than sending, so attachments and edits can follow.
- **`whisper-base.en`** (145 MB) downloads silently at launch, as Parrot does.
- **A standalone pill where Parrot's sits, in Parrot's style.** The pill's exit has since been reworked in Sirius.

## Engine

ParrotCore supplies capture (`AudioCapture`), transcription (`WhisperKitTranscriber`, `ModelRegistry`), the dictionary (`DictionaryStore`, `DictionaryContext`, `DictionaryProcessor`) and cursor delivery. Sirius shares Parrot's model folder and `~/.config/parrot/dictionary`, so a Parrot user downloads nothing new. Sirius depends on Parrot by git URL pinned to a tag, so DMG builds are reproducible.

## Permissions

Accessibility (the `fn` tap and pasting) and Microphone. Neither prompt appears unannounced: onboarding's Permissions page explains both, each with its own Allow button.
