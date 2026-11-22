# Sirius — Manual

Sirius lets you talk to the coding agent you already use, from anywhere on your Mac. Hold a key and speak, or press a shortcut and type. The agent works in its own folder and answers with a small toast, a notification or a spoken line, so you can keep doing what you were doing.

This manual is inside the app. Your agent can read it too: ask "how do I change the shortcut?" and it answers from here, or say "open the manual".

## 1. What Sirius is

Sirius has no model of its own. It drives an agent program that is already installed and signed in on your Mac, with your account, your settings and your folders. Five work today:

| Agent | Program | Needs |
|---|---|---|
| Claude | Claude Code | 2.1.71 or later |
| Codex | Codex, or the copy inside ChatGPT.app | 0.132.0 or later |
| Cursor | Cursor's CLI, `agent` | checked with 2026.08.11 |
| Gemini | Google's Antigravity CLI, `agy` | checked with 1.5.11 |
| Muse | Muse Code | 1.4.14 or later |

If yours is older, a toast tells you to update it. Cursor and Gemini take one message at a time: a message sent while they work waits for the next turn instead of joining the one running.

Sirius lives in the menu bar, under the sparkle icon. It has no Dock icon and no main window.

## 2. Getting started

**Install.** Download Sirius from [trysirius.app/download](https://trysirius.app/download), drag it to Applications and open it. It needs macOS 14 or later on Apple Silicon.

**Setup is one sheet,** shown the first time you open Sirius:

* **Shortcuts.** Hold `fn` to talk, and ⌘⇧J to write. Click either to change it.
* **Permissions.** Each has its own Allow button; nothing is asked for unannounced.

    | Permission | Why |
    |---|---|
    | Microphone | So Sirius can hear you while you hold the key |
    | Accessibility | So it can see the key you hold, paste dictated text into other apps, and read what you have selected in a few apps (§5) |

* **Workspaces.** Sirius finds the agents you have installed. Each agent works in one folder, its workspace. Sirius picks the folder that agent's own program used most recently among the folders you already trust there. Click Change to pick another.

Get Started turns on once both permissions are allowed and at least one agent has a workspace.

A third permission comes later: the first time an agent sends a notification, macOS asks whether Sirius may show notifications.

If you use Parrot with `fn` as its key, quit Parrot, or the key is handled twice.

## 3. Talking

**Hold `fn` and speak.** Let go when you are done. What you said goes to an agent as a message. A small pill near the bottom of the screen shows that Sirius is listening.

* **To pick an agent, say its name first:** "Claude, …", "Codex, …", "Cursor, …", "Gemini, …" or "Muse, …". Without a name, the message goes to the agent you last chose in the composer.
* **To dictate into any app, hold ⌃ and `fn`.** What you said is pasted where your cursor is, and no agent is involved. You can choose another modifier than ⌃ in Settings… → General.

Speech is turned into text on your Mac. The first time, Sirius downloads the speech model (about 145 MB), and the pill shows the progress. If you already use Parrot, Sirius uses Parrot's model and your dictionary at `~/.config/parrot/dictionary`.

Dictation can mishear a word. Agents are told to read past that and to say how they understood you, so a wrong reading is quick to correct.

## 4. Writing

**Press ⌘⇧J** to open the composer, a small text box over whatever you are doing. **Compose** in the menu-bar menu does the same.

| To | Do |
|---|---|
| Send | Return |
| Start a new line | ⇧Return |
| Switch to the next agent | ⌘/ or ⇧Tab, or click the agent beside the send button |
| Attach files | Drag them onto the composer, or paste them |
| Remove the last attachment | ⌘⌫ with the cursor at the start of the text |
| Dictate into the composer | Hold `fn`; the words go into the text so you can edit them before sending |
| Close without sending | Esc |

Typing `->` makes an arrow, →. Undo (⌘Z) turns it back.

The agent shown beside the send button is the one that gets the message. It is also the one your next spoken message goes to when you do not say a name.

**Where your message goes.** One message is one turn: the agent answers it, and the next message's turn begins only then. Sent while the agent is working, your words join the running turn with Claude, Codex and Muse; the other agents hold them for the turn's end. Nothing is lost in between: a turn cut short by a restart is never repeated, and a message that never reached the agent is resent once Sirius opens again. The agent keeps the whole conversation in its own session — a follow-up needs no repeating of what you said — and one file, `~/.agents/WMEM.md`, is shared between agents, so a reference like "the report from yesterday" survives a change of agent.

## 5. What your agent sees

Your agent gets your words and any files you attach. It also gets context from the app behind the composer, when that app is one Sirius can get it from (see "Which apps" below): what you have open there and what you have selected.

**The context line.** When there is context, one quiet line at the bottom left of the composer says what will be sent, for example:

```
release-runbook.md  ·  “Before the release, check…”
```

* The picture is the app's own small icon, and the words are the app's own when it supplies them. Otherwise the line names what is open and quotes how your selection begins.
* The line follows you. Select something else in the app and the line changes.
* Hold the pointer over the line to see the start of the selected text.

**To send a message without the context,** click the × that appears on the line when you point at it, or press ⌘⌫ with the cursor at the start of the text. That removes it for this message only.

**To turn context off,** open Settings… → Context. "Use ambient context" turns all of it off; below it, every app has a switch of its own.

**Which apps.** Context comes in two ways.

* **Apps that share natively.** An app built for it tells Sirius what you have open, and decides what it shares. Each one appears in Settings… → Context the first time it gives Sirius context.
* **Onscreen.** For a short fixed list of apps, Sirius reads what is open and selected itself, through the Accessibility permission you gave it at setup.

    | App | What is sent | At first |
    |---|---|---|
    | Preview | The file's name and location, and the text you selected | On |
    | Safari | The page's title and address, and the text you selected | On |
    | Notes | The note's title, its folder and when it was changed, and the text you selected | On |
    | Finder | The folder's location, and the names and locations of the files you selected | On |
    | Mail | The window's title and the text you selected | Off; turn it on in Settings |

Sirius takes only that: the thing that is open and what you selected in it, never the rest of the window, and never a password field. It reads when you open the composer or speak a message, and while the composer is open. No other app is read, and Messages is not on the list. Your agent is told when context was read by Sirius and not given by the app.

**Sensitive apps.** Mail and Chrome often show someone else's words or a private page. An app that provides context can also say so itself, and is then treated the same. The first time you press Return with context from one of them, the message is not sent: the line says what would go, and Return again sends it. Cancel goes back; tick "Don't warn again" to stop the warning for that app. A spoken message gets the same warning: the composer opens with your words in it and the warning showing, and Return sends it. The switch for the warning is in Settings… → Context. Sirius does not remove private details from what an app gives it: deciding what to report, and leaving out or masking what should not go, is the app's job.

## 6. What comes back

You never read the agent's raw output. The agent chooses one of these for each thing it has to tell you:

| Form | What it is | How to dismiss it |
|---|---|---|
| Toast | A short line or two in a small capsule, with the agent's logo | It leaves by itself after 3 seconds, a little longer for a long one; change this in Settings (§8). Keep the pointer on it to hold it. Click the × at its top-left corner, or swipe up on it with two fingers, to dismiss it sooner. |
| Alert | A toast that stays, used when the agent cannot go on without you | Only the ×, or a swipe up |
| Notification | A normal macOS notification, for results you may come back to later | Notification Center |
| Speech | The agent reads a line aloud. It does this only when you ask to hear something. | Click the speech capsule to stop the line being spoken |

Clicking a toast does nothing, so a stray click never loses it. Toasts are shown one at a time, in order.

**To answer a toast or an alert,** send the agent another message, spoken or typed. It remembers the conversation.

Anything longer than a toast holds, the agent puts in a file and tells you where it is.

## 7. Your agents

**Settings… → Agents** lists every agent Sirius knows. Click one to change it.

| Setting | What it does |
|---|---|
| Enabled | Off: the agent is not started and is skipped when you switch agents in the composer |
| Workspace | The folder the agent works in |
| Fast mode | Faster answers, where the agent's program offers it |
| Model | Which model the agent uses |
| Effort | How hard the model thinks before answering |

An agent you have installed but never used in Sirius appears in the list too. Choosing a workspace for it starts it.

**Each agent's instructions are yours.** They are a plain text file:

```
~/.agents/registry/<agent>/instructions.md
```

`<agent>` is `claude`, `codex`, `cursor`, `gemini` or `muse`. Sirius writes the file once, when the agent is set up, and never overwrites it. Edit it to change how the agent behaves in Sirius: add rules of your own at the bottom, or include another file by naming it with `@`, like `@~/notes/agent.md`. Changes take effect the next time the agent starts.

Beside it, `consts.md` holds the numbers the instructions use, and `agent.json` holds the settings above.

**Working memory.** Agents share a short file of pointers to the things you refer to, at `~/.agents/WMEM.md`, so "the report from yesterday" means something tomorrow. Agents read it at the start of each session and add a one-line pointer whenever they had to search or ask to find something; they edit the file directly, with no extra tool. Sirius creates it the first time it runs if it is missing. You can read or edit it, and pin entries you want kept.

**Your agent keeps its own setup.** It runs with the settings, tools and permissions its program already has. Sirius adds only the way for it to reach you.

## 8. Settings

Open **Settings…** from the menu-bar menu, or press ⌘, while the menu is open.

| Group | Setting | Notes |
|---|---|---|
| General | Hold to talk | `fn`, right ⌥, right ⌘ or ⌃ |
| General | Paste at cursor | The modifier you hold with the hold key to paste at the cursor: ⌃ by default, or ⇧, ⌥ or ⌘ |
| General | Compose | Any key with ⌘, ⌃ or ⌥, or an F-key. Click it and press the new shortcut. |
| Permissions | Microphone, Accessibility | Shows Allowed, or an Allow button |
| Agents | One row per agent | See §7 |
| General | Toasts stay for | How long a toast stays before it leaves by itself: 3, 5, 8 or 12 seconds (3 by default), up to twice that for a long one. Alerts stay until you dismiss them. |
| Context | Use ambient context | Off: no message carries context from any app |
| Context | Warn before sending from sensitive apps | On: Sirius asks once more before a message carries context from Mail or Chrome |
| Context | One switch per app | The apps that provide context, and the apps Sirius reads (§5) |
| Dictation | Model | Shows the speech model in use and its size. It cannot be changed here. |

The window also shows the version of Sirius you are running.

## 9. Privacy

* **Speech is recognized on your Mac.** Audio is not sent anywhere.
* **Your messages go to your agent and nowhere else.** Sirius hands them to the agent program on your Mac. What that program sends to its maker is governed by your account with them, as when you use it in a terminal.
* **Context comes only from apps that offer it and from the few apps listed in §5,** is shown to you in the context line before you send, and can be removed for one message or turned off for any app (§5).
* **Sirius has no account and no server of its own.** It goes online only to download the speech model once and to check for updates.

Where Sirius keeps things:

| Path | What |
|---|---|
| `~/.agents/registry/<agent>/` | Each agent's settings and instructions |
| `~/.agents/WMEM.md` | Working memory, created on first run if missing |
| `~/Library/Application Support/Sirius/agents/<agent>/` | Each agent's message log and attachments |
| `~/Library/Application Support/Sirius/agents/manual/` | This manual |
| `~/Library/Logs/Sirius/sirius.log` | What Sirius did, for troubleshooting. It does not record what you said. At most 5 MB, with one older copy. |

## 10. Updates

Sirius checks for a new version once a day and tells you when one is ready. It installs when you click Install. **Check for updates…** in the menu checks now.

Sirius is signed and notarized, so the permissions you allowed stay allowed after an update.

## 11. When something is wrong

**Nothing happens when I hold the key.**

* Open Settings… and look at Permissions. Both must say Allowed.
* Another app may be using the same key. Quit Parrot if it is running, or choose another hold key in Settings.
* On some keyboards `fn` opens the emoji picker or changes the input source. Change that in System Settings → Keyboard → "Press 🌐 key to", or choose another hold key.

**The compose shortcut does nothing.** Another app may have taken it. Choose another in Settings… → General. Compose in the menu always works.

**The agent does not answer.**

* Check that it is Enabled and has a Workspace in Settings… → Agents.
* It may be busy with an earlier message; yours is waiting behind it.
* Open a terminal and run the agent's own program (`claude`, `codex`, `agent` for Cursor, `agy` for Gemini or `muse`). If it asks you to sign in or update, do that, then quit and reopen Sirius.

**Dictation hears nothing, or the wrong words.**

* Check that Microphone says Allowed, and that the right microphone is chosen in System Settings → Sound → Input.
* The first use waits for the speech model to download.
* For names it keeps getting wrong, add them to `~/.config/parrot/dictionary`.

**No notifications.** Open System Settings → Notifications → Sirius and allow them. Toasts do not depend on this.

**No context line.** The app behind the composer does not provide context and is not one Sirius reads, or it is switched off in Settings… → Context (§5).

**Still stuck.** Quit Sirius from its menu and open it again; that restarts the agents. If the problem stays, open an issue at [github.com/humanitas-labs/sirius/issues](https://github.com/humanitas-labs/sirius/issues) and attach `~/Library/Logs/Sirius/sirius.log`.

## 12. Shortcuts

The first three are the defaults and can be changed in Settings.

| Keys | Where | Does |
|---|---|---|
| Hold `fn` | Anywhere | Speak a message to an agent |
| Hold ⌃ and `fn` | Anywhere | Dictate at the cursor |
| ⌘⇧J | Anywhere | Open the composer |
| Return | Composer | Send |
| ⇧Return | Composer | New line |
| ⌘/ or ⇧Tab | Composer | Next agent |
| ⌘⌫ at the start of the text | Composer | Remove the context, then the last attachment |
| Hold `fn` | Composer | Dictate into the text |
| Esc | Composer | Close |
| ⌘, | Sirius menu | Settings… |
| ⌘Q | Sirius menu | Quit Sirius |
