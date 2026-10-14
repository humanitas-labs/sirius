/*
 * Sirius protocol schema. DRAFT 1, not agreed.
 *
 * The source of truth for the wire contract between an agent's helper (`sirius` CLI or
 * `sirius-mcp`) and the Sirius app, for the text a Message reaches an agent as, and for the agent
 * registration the app keeps. Written in TypeScript like MCP's own proto.ts, because the wire is
 * JSON and content blocks must serialize exactly as MCP's do ({"type": "text", ...}), which
 * protobuf's JSON mapping of a oneof cannot produce. TypeScript types do not validate anything at
 * runtime: the app and the helpers validate against the JSON Schema generated from this file.
 *
 * Status markers: DECIDED (a recorded decision), AGREED (agreed in discussion, recorded here
 * first), PROPOSED (recommended, not agreed), TODO(andrew) for names or values that need a
 * maintainer's decision.
 */

/* ------------------------------------------------------------------------------------------ */
/* Versions                                                                                   */
/* ------------------------------------------------------------------------------------------ */

/**
 * DECIDED: JSON-RPC 2.0 is the envelope.
 */
export const JSONRPC_VERSION = "2.0";

/**
 * PROPOSED: Sirius protocol major version, an integer carried on every message. It changes only
 * on a breaking change. Adding a method, a display kind or an optional field is not breaking.
 * A missing, non-integer or unknown value fails with UNSUPPORTED_VERSION, so a plain JSON-RPC
 * client learns which version to send.
 */
export const SIRIUS_PROTOCOL_VERSION = 1;

/**
 * PROPOSED: content blocks follow this pinned MCP schema, not
 * "latest". Pin the artifact as well as the revision: the block definitions below are copied
 * from schema/2026-07-28/proto.ts at the commit below.
 */
export const MCP_SCHEMA_REVISION = "2026-07-28";
/**
 * TODO: the modelcontextprotocol/modelcontextprotocol commit the copy was taken from.
 */
export const MCP_SCHEMA_COMMIT = "TODO";

/* ------------------------------------------------------------------------------------------ */
/* Agent registration (AGREED 2026.10.09)                                                     */
/* ------------------------------------------------------------------------------------------ */

/**
 * The agent's definition, in a folder of its own under the shared, cross-tool ~/.agents/ (AGREED
 * 2026.10.09), beside ~/.agents/skills/:
 *   ~/.agents/registry/<agent>/agent.json
 * Written by setup; the user may edit it. Not part of the wire; the helper never reads it.
 * Only who the agent is lives here. Sirius's own state for the agent is AgentState. Permission
 * flags and the sirius tools are supplied by the adapter, not stored here, so the user cannot
 * misconfigure them.
 */
export interface AgentRegistration {
  /** Id: folder and socket name. [a-z0-9-]{1,32}. Fixed after setup (PROPOSED). */
  agent: string;
  /** Shown in the UI, e.g. "Claude". */
  name: string;
  /** The agent program, e.g. "claude-code". Selects the adapter. */
  harness: "claude-code" | "codex";
  /** Absolute path, found at setup. */
  executable: string;
  /** Folder the agent works in, picked at setup. Changing it starts a new session. */
  root: string;
  /** Default voice for speak. Absent: the app's default, TODO(andrew). Top-level until the
   * registry spec is written; Sirius-only fields may move under a "sirius" key then (AGREED
   * 2026.10.09). */
  voice?: string;
}

/**
 * Sirius's own state for one agent, written only by the app:
 *   ~/Library/Application Support/Sirius/agents/<agent>/state.json
 * Kept out of the definition so another tool reading ~/.agents never resumes Sirius's session.
 */
export interface AgentState {
  /** Resume id (Claude session, Codex thread). Absent until the first turn. */
  session?: string;
}

/*
 * Storage, per agent (AGREED 2026.10.09):
 *
 * ~/.agents/registry/<agent>/            the definition, shared with other tools
 *   agent.json                         AgentRegistration
 *   instructions.md                    optional, the user's instructions for this agent, appended
 *                                      after the base instructions Sirius ships
 *
 * ~/Library/Application Support/Sirius/agents/<agent>/    Sirius only
 *   state.json                         AgentState
 *   log.jsonl                          the record: append-only, written only by the app
 *   attachments/<message>/             files the user sent with that message
 */

/* ------------------------------------------------------------------------------------------ */
/* Transport                                                                                  */
/* ------------------------------------------------------------------------------------------ */

/*
 * DECIDED: a Unix domain socket owned by the app.
 * AGREED: one socket per registered agent. The socket a request arrives on identifies the
 * sending agent, so no request carries the sender.
 *
 * Trust assumption (PROPOSED): per-agent sockets give routing and
 * attribution among cooperating agents. They do not authenticate one agent against another: any
 * process running as the user can connect to any agent's socket. The uid check keeps out other
 * users only. Sirius accepts this for a single-user Mac.
 *
 * Socket lifecycle (PROPOSED):
 *  - Directory (AGREED 2026.10.09): $TMPDIR/sirius/, mode 0700, owned by the user, with the
 *    per-user temp folder read via confstr(_CS_DARWIN_USER_TEMP_DIR), not the environment.
 *    Path: <dir>/<agent>.sock. Private to the user and cleared on reboot. The app checks the full
 *    UTF-8 path is under 104 bytes including the terminating NUL before registering an agent.
 *  - The app is the only listener. At start it takes an exclusive lock on <dir>/sirius.lock;
 *    a second instance exits. Only the lock holder unlinks stale socket nodes, then binds.
 *  - Removing an agent closes and unlinks its socket. An id is never reused for a different
 *    agent while a helper from the old one could still be running (ids are fixed, see above).
 *  - No launchd activation: sockets the app creates at run time cannot be launchd endpoints.
 *    When the app is not running, the helper fails with "Sirius isn't running". Agents Sirius
 *    starts cannot outlive it, so this affects only sessions pointed at by hand.
 *
 * Framing (PROPOSED), a restricted profile of JSON-RPC 2.0:
 *  - One JSON object per line, UTF-8, terminated by "\n". JSON escapes embedded newlines.
 *  - One call per connection: the helper connects, writes one request, reads one response,
 *    closes. No batches. The app executes only the first frame; any further bytes are discarded.
 *  - The app accumulates reads until "\n", bounded by LIMITS.maxRequestBytes before parsing, and
 *    finishes partial writes. A connection that sends no complete frame within
 *    LIMITS.readDeadlineSeconds is closed without a response. An incomplete frame at EOF is
 *    discarded. At most LIMITS.maxConnectionsPerAgent connections are open per socket.
 *  - The whole request is validated before anything is queued.
 *  - The app checks the peer's uid (getpeereid) equals its own and closes the connection
 *    otherwise.
 */

/**
 * Environment the adapter gives every agent process and, through it, the helper.
 */
export interface SiriusEnvironment {
  /** Absolute path of this agent's socket. */
  SIRIUS_SOCKET: string;
  /** Seconds to wait for the app's response. Default 10. */
  SIRIUS_TIMEOUT?: string;
}

/* ------------------------------------------------------------------------------------------ */
/* Envelope                                                                                   */
/* ------------------------------------------------------------------------------------------ */

/**
 * PROPOSED: the helper sends a string id. Numbers are accepted if they are safe integers.
 */
export type RequestId = string | number;

/**
 * Every message on the socket carries both version tags. Unknown fields, at any level, are ignored
 * (PROPOSED), so a newer helper's optional field reaches an older app harmlessly.
 */
interface Versioned {
  jsonrpc: typeof JSONRPC_VERSION;
  sirius: number;
}

export interface Request<M extends Method, P> extends Versioned {
  id: RequestId;
  method: M;
  params: P;
}

export interface Result<R> extends Versioned {
  id: RequestId;
  result: R;
}

export interface ErrorResponse extends Versioned {
  /** null when the request's id is missing or invalid. */
  id: RequestId | null;
  error: {
    code: ErrorCode;
    message: string;
    data?: ErrorData;
  };
}

export type Response<R> = Result<R> | ErrorResponse;

/**
 * DECIDED: three methods. Sirius defines no JSON-RPC notifications. A well-formed frame without an
 * id is a notification by JSON-RPC's rules: the app does not execute it and sends no response. A
 * malformed one (no jsonrpc "2.0" or no string method) gets INVALID_REQUEST with id null.
 */
export type Method = "display" | "notify" | "speak";

/*
 * Outcomes (PROPOSED):
 *  - A result means the request was validated and accepted as a whole into the app's queue.
 *    It does not mean it was shown or heard: the app can still crash before presenting it.
 *  - Queued items do not survive an app restart.
 *  - A timeout or a dropped connection before the response means the outcome is unknown. The
 *    helper never retries automatically, since a retry after a lost receipt would show or speak
 *    the same thing twice. The CLI exits 4 and says the outcome is unknown.
 */

/* ------------------------------------------------------------------------------------------ */
/* display                                                                                    */
/* ------------------------------------------------------------------------------------------ */

/**
 * DECIDED: three kinds. Launch builds toast only; the Aside does not ship at launch (DECIDED
 * 2026.10.09). dialog and aside are named but their content is deferred; until then they fail with
 * KIND_NOT_AVAILABLE.
 */
export type DisplayKind = "toast" | "dialog" | "aside";

export interface DisplayParams {
  /** Unknown kind: UNKNOWN_DISPLAY_KIND. */
  kind: DisplayKind;
  /** What each kind accepts: KIND_CONTENT. */
  content: Content;
  /** toast only. Stays until dismissed. */
  alert?: boolean;
  /** aside only. Binds the Aside to another session. DEFERRED. */
  session?: string;
}

export type DisplayRequest = Request<"display", DisplayParams>;

/**
 * Accepted into the display queue (see Outcomes and Presentation).
 */
export interface DisplayResult {
  delivered: true;
}

/* ------------------------------------------------------------------------------------------ */
/* notify                                                                                     */
/* ------------------------------------------------------------------------------------------ */

export interface NotifyParams {
  /** Text blocks only (NOTIFY_CONTENT), joined with "\n" (PROPOSED). */
  content: Content;
  /** TODO(andrew): keep, or always the agent's name. */
  title?: string;
}

export type NotifyRequest = Request<"notify", NotifyParams>;

/**
 * Handed to Notification Center. Not proof it was shown: the user may have notifications
 * off for Sirius.
 */
export interface NotifyResult {
  delivered: true;
}

/* ------------------------------------------------------------------------------------------ */
/* speak                                                                                      */
/* ------------------------------------------------------------------------------------------ */

export interface SpeakParams {
  /** Plain text, not Content. */
  text: string;
  /** Apple voice name, e.g. "Bad News". Absent: the agent's default voice. */
  voice?: string;
}

export type SpeakRequest = Request<"speak", SpeakParams>;

/**
 * DECIDED: returned once the speech is queued, not when playback ends.
 */
export interface SpeakResult {
  queued: true;
  /** The voice selected. */
  voice: string;
  /** Requested voice not installed; the default was used (PROPOSED). */
  fallback?: boolean;
}

/* ------------------------------------------------------------------------------------------ */
/* Content                                                                                    */
/* ------------------------------------------------------------------------------------------ */

/**
 * DECIDED: a string, or an array of MCP content blocks.
 * PROPOSED, in this order at the boundary:
 *  1. A string becomes [{type: "text", text}] once. It is never parsed again, even if it looks
 *     like JSON.
 *  2. Each block is validated against its MCP shape; a malformed block fails INVALID_PARAMS.
 *  3. Empty content fails INVALID_PARAMS: an empty array, or only text blocks whose text is all
 *     whitespace.
 *  4. Each block's type is checked against what the method or kind accepts; a valid block it
 *     does not accept, or an unknown type, fails UNSUPPORTED_CONTENT. Nothing is dropped.
 *  5. Limits apply to the normalized content, per block and in aggregate.
 */
export type Content = string | ContentBlock[];

/**
 * The five MCP content block types, as defined by MCP_SCHEMA_REVISION.
 */
export type ContentBlock =
  | TextContent
  | ImageContent
  | AudioContent
  | ResourceLink
  | EmbeddedResource;

type Meta = { [key: string]: unknown };

export interface TextContent {
  type: "text";
  /** Toast renders it as plain text (PROPOSED). */
  text: string;
  annotations?: Annotations;
  _meta?: Meta;
}

export interface ImageContent {
  type: "image";
  /** Base64. */
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: Meta;
}

export interface AudioContent {
  type: "audio";
  /** Base64. */
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: Meta;
}

/**
 * A reference to a resource. A reference, not permission: see Acceptance rules.
 */
export interface ResourceLink {
  type: "resource_link";
  uri: string;
  name: string;
  title?: string;
  description?: string;
  mimeType?: string;
  size?: number;
  /** Never fetched. */
  icons?: Icon[];
  annotations?: Annotations;
  _meta?: Meta;
}

export interface Icon {
  src: string;
  mimeType?: string;
  sizes?: string[];
  theme?: "light" | "dark";
}

export interface EmbeddedResource {
  type: "resource";
  resource: TextResourceContents | BlobResourceContents;
  annotations?: Annotations;
  _meta?: Meta;
}

export interface TextResourceContents {
  uri: string;
  mimeType?: string;
  text: string;
  _meta?: Meta;
}

export interface BlobResourceContents {
  uri: string;
  mimeType?: string;
  /** Base64. */
  blob: string;
  _meta?: Meta;
}

/**
 * Hints only. Never treated as instructions.
 */
export interface Annotations {
  audience?: ("user" | "assistant")[];
  priority?: number;
  lastModified?: string;
}

/**
 * PROPOSED: the block types each display kind accepts.
 */
export const KIND_CONTENT: { [K in DisplayKind]: ContentBlock["type"][] | "not-available" } = {
  toast: ["text"],
  dialog: "not-available",
  aside: "not-available",
};

/**
 * PROPOSED: notify accepts text blocks only.
 */
export const NOTIFY_CONTENT: ContentBlock["type"][] = ["text"];

/* ------------------------------------------------------------------------------------------ */
/* Acceptance rules (PROPOSED)                                                                */
/* ------------------------------------------------------------------------------------------ */

/*
 * 1. A resource URI is a reference, never permission. Sirius opens a file:// URI only when the
 *    file lies inside the agent's root or its attachments folder (AGREED). The check opens the
 *    file first and verifies the opened file's real path (fcntl F_GETPATH), so a symlink swapped
 *    between check and read cannot redirect it. Embedded resource URIs are labels and trigger
 *    no read or fetch.
 * 2. No automatic network fetch: remote URLs, icons and Markdown images are not loaded.
 * 3. No HTML or script is executed. _meta, mimeType and annotations are untrusted labels.
 * 4. Base64 is validated, and media is decoded only after its header passes the limits: decoded
 *    bytes, pixels and frames for images, decoded bytes and duration for audio and blobs.
 * 5. A request is validated and accepted as a whole, or fails with an error. Never partly.
 */

/**
 * TODO(andrew): the values. Placeholders that show the shape and are mutually consistent.
 * Text lengths count Unicode code points (PROPOSED), so every implementation counts the same.
 */
export const LIMITS = {
  /** Whole frame, checked before parsing. */
  maxRequestBytes: 8 * 1024 * 1024,
  readDeadlineSeconds: 5,
  maxConnectionsPerAgent: 8,
  maxBlocks: 32,
  /** Across all text blocks. */
  maxTextChars: 20_000,
  maxToastChars: 280,
  maxNotifyChars: 1_000,
  maxSpeakChars: 2_000,
  maxImageBytesDecoded: 6 * 1024 * 1024,
  maxImagePixels: 4096 * 4096,
  maxImageFrames: 1,
  maxAudioSeconds: 120,
  /** Per queue, across all agents. */
  maxQueued: 50,
};

/* ------------------------------------------------------------------------------------------ */
/* Presentation (app behaviour, not wire; PROPOSED)                                           */
/* ------------------------------------------------------------------------------------------ */

/*
 * Agents may send at any time, concurrently. The app presents one thing at a time:
 *  - Toasts: one on screen, a single FIFO queue across all agents. A backlog collapses into a
 *    "+N more" marker rather than stacking. An alert toast holds the queue until dismissed.
 *  - Speech: one utterance at a time across all agents, FIFO.
 *  - notify: Notification Center does its own stacking.
 * Receipts mean accepted into the queue, so an agent never blocks on another agent's output.
 */

/* ------------------------------------------------------------------------------------------ */
/* Errors                                                                                     */
/* ------------------------------------------------------------------------------------------ */

/**
 * JSON-RPC's reserved codes, then Sirius's own in the implementation-defined server range
 * -32000..-32099. PROPOSED. A missing or refused socket is a transport failure, reported by the
 * helper, never a JSON-RPC response.
 */
export enum ErrorCode {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  /** Malformed params, empty content, or a field on the wrong kind. */
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603,

  /** data: { supported } */
  UNSUPPORTED_VERSION = -32001,
  /** data: { method, kind } */
  UNKNOWN_DISPLAY_KIND = -32002,
  /** dialog or aside, not built yet. data: { method, kind } */
  KIND_NOT_AVAILABLE = -32003,
  /** Block type not accepted here. data: { method, kind?, type } */
  UNSUPPORTED_CONTENT = -32004,
  /** data: { method, limit, value } */
  TOO_LARGE = -32005,
  /** URI outside root and attachments. data: { method, uri } */
  ACCESS_DENIED = -32006,
  /** data: { method } */
  QUEUE_FULL = -32007,
  /** App still starting. data: { method } */
  NOT_READY = -32008,
}

export interface ErrorData {
  method?: Method;
  kind?: string;
  type?: string;
  limit?: keyof typeof LIMITS;
  value?: number;
  uri?: string;
  supported?: number[];
}

/* ------------------------------------------------------------------------------------------ */
/* CLI mapping (PROPOSED)                                                                     */
/* ------------------------------------------------------------------------------------------ */

/*
 * sirius display <kind> [--alert] [--] <text>      kind is required, so "toast" as text is
 *                                                   `sirius display toast toast`
 * sirius display <kind> --json                      content read from stdin as JSON: a string
 *                                                   or a ContentBlock[], never guessed
 * sirius notify [--title <t>] [--] <text>
 * sirius notify --json
 * sirius speak [--voice <name>] [--] <text>
 *
 * "--" ends options, so text starting with "-" is passed as `sirius display toast -- -1 failed`.
 * TODO(andrew): whether `display "text"` without a kind stays allowed
 * (the plan's AppleScript-style default); draft 1 requires the kind to remove the ambiguity.
 *
 * Exit codes:
 *   0  result received
 *   1  error response; message on stderr as "sirius: <message> (<code>)"
 *   2  bad usage
 *   3  Sirius isn't running, or the socket refused the connection
 *   4  outcome unknown: timeout or connection lost before the response. Not retried.
 */

/* ------------------------------------------------------------------------------------------ */
/* MCP mapping (PROPOSED)                                                                     */
/* ------------------------------------------------------------------------------------------ */

/*
 * sirius-mcp exposes tools `display`, `notify`, `speak`. Each tool's inputSchema is the JSON
 * Schema of its Params, rooted at an object with the string-or-blocks union under
 * properties.content (Claude Code passes nested combinators through; Codex's MCP
 * conversion is non-strict and keeps unions). MCP defines content blocks for tool results, not
 * a `content` argument; Sirius defines this argument with the same shape.
 * The tool result is a text block with the receipt. On an error response it sets isError and
 * keeps the code and data, so the agent can tell a rejection from an unknown outcome. Before
 * freezing: validate the generated schema in both hosts.
 */

/* ------------------------------------------------------------------------------------------ */
/* Sirius to agent: the Message                                                               */
/* ------------------------------------------------------------------------------------------ */

/*
 * AGREED 2026.10.09: a Message is the unit the user sends from the composer to one agent, the
 * working term as in A2A. It reaches the agent as plain text in a tagged
 * wrapper, identical for every adapter: Claude gets it as a user turn on stream-json stdin,
 * Codex as the text input of turn/start.
 *
 *   <sirius message="m_7f3k2" agent="claude">
 *   why is this failing?
 *
 *   <attachment path="/Users/<user>/Library/Application Support/Sirius/agents/claude/attachments/m_7f3k2/screenshot.png" type="image/png"/>
 *   </sirius message="m_7f3k2">
 *   Reach the user only through display, notify or speak; your plain output is never shown.
 *
 * DECIDED 2026.10.09: the tagged wrapper, not a structured JSON object. Only the model
 * reads it, and the model reads tagged, unescaped text best; Claude Code hands its own model
 * pasted text, subagent reports and notices the same way. Tags also nest, should a Message ever
 * carry grouped context. Rendered by MessageRenderer in SiriusCore.
 *
 * Rules (PROPOSED):
 *  - The user's words are verbatim, first. Nothing is rewritten or summarized.
 *  - One <attachment> per file, after the words, with the absolute path and the MIME type. Every
 *    attachment is a file path, images included; Sirius writes pasted or dragged content
 *    to a file first.
 *  - `message` is the id used in the agent's log. The agent need not act on it.
 *  - The full instructions are given once at agent start (bundled skill or system prompt). One
 *    reply note follows the closing tag on every turn, so a long context never loses it
 *    (DECIDED 2026.10.09; TODO(andrew): the wording).
 *  - Attribute values and paths are XML-escaped. The user's words are not escaped; the wrapper
 *    is a convention for the agent, not a parsed format.
 *  - The closing tag repeats the message id, so user text containing "</sirius>" cannot end the
 *    wrapper early (DECIDED 2026.10.09).
 *  - Image attachments may also go to the harness as native image input beside their path
 *    (DECIDED 2026.10.09; the adapters). The path is always in the wrapper.
 *  - Captured context (frontmost app, selection) is deferred; when it comes it is another
 *    element inside the wrapper.
 *  - A message sent while the agent is mid-turn queues and is delivered after the turn ends
 *    (one turn at a time per agent). PROPOSED, not decided.
 *  - Commands from the agent are filed in its log against its current message, or its most
 *    recent one when no turn is running (late output after a turn ends). PROPOSED.
 *
 * TODO(andrew): the message id format (m_ plus a short random id is a placeholder).
 */
