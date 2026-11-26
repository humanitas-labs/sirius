# Sirius — How messages follow each other

> What happens to a message after it is sent, how the next one follows it, and what the agent remembers between them. The wire shapes are in [protocol/proto.ts](protocol/proto.ts) and the components in [architecture.md](architecture.md); this page tells the story in order.

Last updated: `2026.11.22`.

## 1. One message is one turn

Everything you send — spoken, or typed in the composer — becomes one **Message** to one agent. The agent's queue delivers messages **one turn at a time, in the order sent**: a turn starts when the message reaches the warm agent process, and the next message's turn starts only when this one ends.

A turn ends in one of three ways, and each is written to the agent's log (`log.jsonl`, the entries `turn_started`, `turn_ended`, `interrupted`):

- **Completed.** The harness finished its turn. Claude calls it a turn, Codex a thread turn, the ACP agents a `session/prompt` that returns.
- **Failed.** The agent reported an error, or its process died mid-turn. The user hears about it; the next message starts the agent again.
- **Interrupted.** Sirius quit while the turn ran. An interrupted turn is never rerun: the message reached the agent, and running it again unasked could repeat whatever it did. Its turn stays marked interrupted in the log, and you simply send a follow-up.

## 2. A message sent while the agent works

Two things can happen to a message that arrives mid-turn, and which one depends on the harness, not on you:

- **It joins the running turn** (Claude Code, Codex, Muse Code). The harness takes the new text in at its next step, as typing into a running session does: the message rides the same turn and ends with it. In the log it is `turn_joined`.
- **It waits for the next turn** (Cursor and Gemini). The harness has no way to add text to a running turn over its protocol, so the message queues and is delivered the moment the turn ends. The queue's order is kept: nothing sent later can overtake it.

Neither case is ever lost. If Sirius restarts before a waiting message is delivered, it is **re-queued** at the next start, in log order and ahead of anything sent after — the log entry `requeued` records it, and the toast "Resent N messages" says so. A message is only dropped when its turn has actually run.

## 3. What the agent sees, and what it remembers

Every message reaches the agent as plain text in the same tagged wrapper, whichever harness carries it:

```
<sirius message="m_7f3k2" agent="claude">
why is this failing?

<attachment path="…/attachments/m_7f3k2/screenshot.png" type="image/png"/>
</sirius message="m_7f3k2">
Reach the user only through display, notify or speak; your plain output is never shown.
```

The closing tag repeats the message id, so text containing `</sirius>` cannot end the wrapper early. Attachments are files on disk, and images may also go to the harness as native image input beside their path.

What the agent *remembers* between messages is its harness's own session, not anything Sirius re-sends:

- **Within a session**, the harness keeps the full conversation, as it does in a terminal. Follow-ups need no quoting: "and now the tests?" lands in the same context.
- **Across restarts**, Sirius resumes the session the harness itself named — Claude's session id, Codex's thread, an ACP session — stored in Sirius's own `state.json` and handed back at the next start (`agent_started` in the log says whether it resumed). A message you send tomorrow continues the same conversation.
- **Across agents**, one thing is shared on purpose: working memory, `~/.agents/WMEM.md`, a short file of pointers ("the report from yesterday → where it lives") that every agent's instructions include. Each agent reads it at session start and adds a pointer whenever it had to search or ask to resolve a reference. It is the only memory that follows a message *between* agents; each harness's session stays its own.

## 4. Two other senders use the same queue

Messages reach the queue from three directions, and the agent is told which:

- **You** — the wrapper above, logged as `message`.
- **Another agent** — an `agent_message` turn headed `[dm · agent message]` with its self-reported sender and a line saying it carries no user authority. One agent can hand work to another the way a colleague messages you.
- **Sirius itself** — a `sirius_message` turn headed `[sirius · from the app]`. There is one kind today: the working-memory cleanup, sent to the first agent whose instructions include the file when it grows past its limit.

## 5. How a reply follows, and how yours follows the reply

The agent reaches you only by calling Sirius — `display` for a toast, `notify` for a notification, `speak` for speech — and its own output stream is never shown. Replies come during the turn; each is filed in the log against the message whose turn is running (`command`), so the record reads as a conversation.

To answer a reply, just send another message: the same session receives it, and the turn/join/wait rules of §1–2 apply again. That is the whole loop — message, turn, reply, message — for as long as the conversation runs.

## 6. Where the rules live

| Rule | Kept by | Recorded in |
|---|---|---|
| One turn at a time, in order | the agent's queue (`AgentTurnQueue`) | `turn_started`, `turn_ended` |
| Mid-turn: join or wait | the harness's adapter, by capability | `turn_joined`, or delivery after `turn_ended` |
| Interrupted turns never rerun | the log's recovery at open | `interrupted` |
| Undelivered messages re-queued | the log's recovery at open | `requeued` |
| Session resumed across restarts | the adapter, from `state.json` | `agent_started` (`resumed`) |
| The message wrapper | `MessageRenderer`, identical for every adapter | the `message` entry's id |
| Who sent a turn | the wrapper's header | `message`, `agent_message`, `sirius_message` |

Adapter authors: [byoh.md](byoh.md) is the guide for adding a harness, and the queue contract your adapter meets is `Adapter` in `Sources/SiriusCore/Adapter.swift`.
