import Foundation

// A stand-in for an ACP agent (`agent acp`, `agy acp`): the ACP v1 subset
// the adapter uses. It logs its argv and environment to fake-acp.args and
// every line it receives to fake-acp.log, both in its working directory
// (the agent's root). Like Cursor's server it stays up after its stdin
// closes. The turn's text picks the behaviour: FAKE_REFUSE ends it with
// stopReason refusal, FAKE_ERROR answers the prompt with a JSON-RPC error,
// FAKE_EXIT exits mid-turn, FAKE_PERMISSION asks permission and ends once
// answered, FAKE_NOALLOW asks with no allow option, FAKE_ASK and FAKE_PLAN
// send Cursor's blocking requests, FAKE_FS asks for fs/read_text_file. A
// session/load or session/resume of "missing" is refused; a load replays a
// user message and a usage update first.
//
// fake-acp.mode beside the script changes the server: "full" advertises
// session/resume and systemPrompt and offers model and thinking-level
// config options, as Antigravity's docs describe; "cursor" models Cursor's
// `agent acp`, switching between parameterized and exploded-variant model
// pickers by initialize's clientCapabilities._meta.parameterizedModelPicker;
// "variants" always returns exploded bracketed variants with human display
// names; "signedout" refuses sessions as signed out; "silent" never answers
// authenticate and refuses sessions; "exit" writes to stderr and exits 1 at
// initialize; "v2" answers initialize with protocol version 2.
enum ACPFakeAgent {
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys, time

    here = os.path.dirname(os.path.realpath(sys.argv[0]))
    def setting(name):
        try:
            return open(os.path.join(here, name)).read().strip()
        except OSError:
            return None

    cwd = os.getcwd()
    with open(os.path.join(cwd, "fake-acp.args"), "w") as f:
        json.dump({"argv": sys.argv[1:], "socket": os.environ.get("SIRIUS_SOCKET"),
                   "noUpdate": os.environ.get("AGY_CLI_DISABLE_AUTO_UPDATE"),
                   "configDir": os.environ.get("CURSOR_CONFIG_DIR"),
                   "path": os.environ.get("PATH")}, f)
    log = open(os.path.join(cwd, "fake-acp.log"), "a")

    def send(obj):
        obj["jsonrpc"] = "2.0"
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def update(sid, body):
        send({"method": "session/update", "params": {"sessionId": sid, "update": body}})

    model, level = "gemini-4-carbon-medium", "medium"
    parameterized = False
    cursor_model = "default"
    cursor_params = {}
    cursor_variant = "default[]"
    CURSOR_MODELS = [
        ("default", "Auto", []),
        ("composer-2.5", "Composer 2.5", [
            {"id": "fast", "name": "Fast", "category": "model_config", "type": "select",
             "options": [{"value": "false", "name": "Off"}, {"value": "true", "name": "On"}]},
        ]),
        ("claude-opus-5-5", "Claude Opus 5.5", [
            {"id": "thinking", "name": "Thinking", "category": "thought_level", "type": "select",
             "options": [{"value": "false", "name": "Off"}, {"value": "true", "name": "On"}]},
            {"id": "effort", "name": "Effort", "category": "thought_level", "type": "select",
             "options": [{"value": v, "name": v.title()} for v in ("low", "medium", "high", "xhigh", "max")]},
            {"id": "fast", "name": "Fast", "category": "model_config", "type": "select",
             "options": [{"value": "false", "name": "Off"}, {"value": "true", "name": "On"}]},
        ]),
        ("gpt-5.3-codex", "Codex 5.3", [
            {"id": "reasoning", "name": "Reasoning", "category": "thought_level", "type": "select",
             "options": [{"value": v, "name": v} for v in ("low", "medium", "high", "extra-high")]},
            {"id": "fast", "name": "Fast", "category": "model_config", "type": "select",
             "options": [{"value": "false", "name": "Off"}, {"value": "true", "name": "On"}]},
        ]),
        ("muse-wonder-1.0", "Muse Wonder", [
            {"id": "context", "name": "Context", "category": "model_config", "type": "select",
             "options": [{"value": "300k", "name": "300K"}, {"value": "1m", "name": "1M"}]},
            {"id": "effort", "name": "Effort", "category": "thought_level", "type": "select",
             "options": [{"value": v, "name": v.title()} for v in ("minimal", "low", "medium", "high", "xhigh", "max")]},
        ]),
    ]
    CURSOR_VARIANTS = [
        {"value": "default[]", "name": "Auto"},
        {"value": "composer-2.5[fast=true]", "name": "Composer 2.5"},
        {"value": "claude-opus-5-5[thinking=true,context=300k,effort=medium,fast=false]", "name": "Claude Opus 5.5"},
        {"value": "gpt-5.4-mini[reasoning=medium]", "name": "GPT-5.4 Mini"},
        {"value": "muse-wonder-1.0[context=300k,effort=high]", "name": "Muse Wonder 300K High"},
    ]
    def options(mode=None):
        if mode == "variants" or (mode == "cursor" and not parameterized):
            return [{"id": "model", "name": "Model", "category": "model", "type": "select",
                     "currentValue": cursor_variant, "options": CURSOR_VARIANTS}]
        if mode == "cursor":
            entry = next((m for m in CURSOR_MODELS if m[0] == cursor_model), CURSOR_MODELS[0])
            result = [{"id": "model", "name": "Model", "category": "model", "type": "select",
                       "currentValue": cursor_model,
                       "options": [{"value": m[0], "name": m[1]} for m in CURSOR_MODELS]}]
            for opt in entry[2]:
                cur = cursor_params.get(opt["id"], opt["options"][0]["value"])
                result.append({**opt, "currentValue": cur})
            return result
        return [
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
             "options": [{"group": "g4", "name": "Gemini 4", "options": [
                 {"value": "gemini-4-neon-high", "name": "Neon"},
                 {"value": "gemini-4-carbon-medium", "name": "Carbon"}]}]},
            {"id": "thinking", "name": "Thinking level", "category": "thought_level", "type": "select",
             "currentValue": level,
             "options": [{"value": "lo", "name": "Low"}, {"value": "medium", "name": "Medium"},
                         {"value": "extra", "name": "Extra"}]},
        ]

    SIGNED_OUT = {"code": -32000, "message": "Authentication required"}
    turns = 0
    waiting = None  # (request id we sent, prompt id to finish, session)

    def finish(mid, sid, stop="end_turn"):
        update(sid, {"sessionUpdate": "usage_update", "used": 53000 + turns, "size": 200000})
        send({"id": mid, "result": {"stopReason": stop}})

    for line in sys.stdin:
        log.write(line); log.flush()
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}
        mode = setting("fake-acp.mode")
        if method is None:
            if waiting and waiting[0] == mid:
                finish(waiting[1], waiting[2])
                waiting = None
            continue
        if method == "initialize":
            if mode == "exit":
                sys.stderr.write("Error: the keychain is locked\nbye\n")
                sys.exit(1)
            meta = (params.get("clientCapabilities") or {}).get("_meta") or {}
            parameterized = meta.get("parameterizedModelPicker") is True
            caps = {"loadSession": True, "promptCapabilities": {"image": True, "audio": False},
                    "mcpCapabilities": {"http": True, "sse": True}, "sessionCapabilities": {"list": {}}}
            if mode == "full":
                caps["sessionCapabilities"] = {"list": {}, "resume": {}, "systemPrompt": {}}
            send({"id": mid, "result": {"protocolVersion": 2 if mode == "v2" else 1, "agentCapabilities": caps,
                                        "authMethods": [{"id": "fake_login", "name": "Fake login"},
                                                        {"id": "browser", "name": "Opens a browser"}]}})
        elif method == "authenticate":
            if mode == "silent":
                continue
            send({"id": mid, "result": {}})
        elif method == "session/new":
            if mode in ("signedout", "silent"):
                send({"id": mid, "error": SIGNED_OUT})
                continue
            result = {"sessionId": "sess-new"}
            if mode in ("full", "cursor", "variants"): result["configOptions"] = options(mode)
            send({"id": mid, "result": result})
        elif method in ("session/load", "session/resume"):
            sid = params.get("sessionId")
            if sid == "missing":
                send({"id": mid, "error": {"code": -32002, "message": "Resource not found", "data": {"sessionId": sid}}})
                continue
            if method == "session/load":
                update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "earlier"}})
                update(sid, {"sessionUpdate": "usage_update", "used": 999, "size": 200000})
            result = {}
            if mode in ("full", "cursor", "variants"): result["configOptions"] = options(mode)
            send({"id": mid, "result": result})
        elif method == "session/set_config_option":
            cid, val = params.get("configId"), params.get("value")
            if mode == "variants" or (mode == "cursor" and not parameterized):
                if cid != "model" or not any(v["value"] == val for v in CURSOR_VARIANTS):
                    send({"id": mid, "error": {"code": -32602, "message": f"Invalid model value: {val}"}})
                    continue
                cursor_variant = val
            elif mode == "cursor":
                if cid == "model":
                    if not any(m[0] == val for m in CURSOR_MODELS):
                        send({"id": mid, "error": {"code": -32602, "message": f"Invalid model value: {val}"}})
                        continue
                    cursor_model = val
                    cursor_params = {}
                else:
                    entry = next((m for m in CURSOR_MODELS if m[0] == cursor_model), CURSOR_MODELS[0])
                    opt = next((o for o in entry[2] if o["id"] == cid), None)
                    if not opt or not any(o["value"] == val for o in opt["options"]):
                        send({"id": mid, "error": {"code": -32602, "message": f"Invalid value for {cid}: {val}"}})
                        continue
                    cursor_params[cid] = val
            else:
                if cid == "model": model = val
                if cid == "thinking": level = val
            send({"id": mid, "result": {"configOptions": options(mode)}})
        elif method == "session/prompt":
            turns += 1
            sid = params["sessionId"]
            text = params["prompt"][0]["text"]
            call = {"toolCallId": "call_1", "title": "Run a command", "kind": "execute"}
            if "FAKE_EXIT" in text:
                time.sleep(0.1)
                sys.exit(3)
            elif "FAKE_ERROR" in text:
                send({"id": mid, "error": {"code": -32603, "message": "boom"}})
            elif "FAKE_REFUSE" in text:
                finish(mid, sid, "refusal")
            elif "FAKE_PERMISSION" in text:
                waiting = (900, mid, sid)
                send({"id": 900, "method": "session/request_permission", "params": {
                    "sessionId": sid, "toolCall": call, "options": [
                        {"optionId": "no", "name": "Reject", "kind": "reject_once"},
                        {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                        {"optionId": "yes", "name": "Allow once", "kind": "allow_once"}]}})
            elif "FAKE_NOALLOW" in text:
                waiting = (901, mid, sid)
                send({"id": 901, "method": "session/request_permission", "params": {
                    "sessionId": sid, "toolCall": call, "options": [
                        {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
            elif "FAKE_ASK" in text:
                waiting = (902, mid, sid)
                send({"id": 902, "method": "cursor/ask_question", "params": {
                    "toolCallId": "call_2", "questions": [{"id": "q1", "prompt": "Which?", "options": [
                        {"id": "a", "label": "A"}]}]}})
            elif "FAKE_PLAN" in text:
                waiting = (903, mid, sid)
                send({"id": 903, "method": "cursor/create_plan", "params": {
                    "toolCallId": "call_3", "plan": "# Plan", "todos": []}})
            elif "FAKE_FS" in text:
                waiting = (904, mid, sid)
                send({"id": 904, "method": "fs/read_text_file", "params": {"sessionId": sid, "path": "/etc/hosts"}})
            else:
                finish(mid, sid)

    # Cursor's server stays up after its stdin closes.
    while True:
        time.sleep(1)
    """#

    static func install(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("fake-acp")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func set(mode: String, in directory: URL) throws {
        try mode.write(to: directory.appendingPathComponent("fake-acp.mode"), atomically: true, encoding: .utf8)
    }

    // The JSON objects the fake received, in order.
    static func received(in root: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("fake-acp.log"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    static func arguments(in root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fake-acp.args")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
