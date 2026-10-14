import Foundation

// A stand-in for `codex app-server`: the JSON-RPC subset the adapter uses.
// It logs its argv to fake-codex.args and every line it receives to
// fake-codex.log, both in its working directory (the agent's root). The
// turn's text picks the behaviour: FAKE_FAIL ends the turn failed, FAKE_EXIT
// exits mid-turn, FAKE_HANG never ends it, FAKE_APPROVAL asks for a command
// approval first, FAKE_HOLD keeps it running until a turn/steer whose text
// has FAKE_DONE. A steer with no turn held is refused, as Codex does. A
// thread/resume of "missing" is refused.
//
// `--version` prints "codex-cli 0.159.1", or the contents of
// fake-codex.version beside the script. fake-codex.init beside it makes
// initialize fail: "exit" writes two lines to stderr and exits 1, "error"
// answers with a JSON-RPC error.
enum CodexFakeAppServer {
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys, time

    here = os.path.dirname(os.path.realpath(sys.argv[0]))
    def setting(name):
        try:
            return open(os.path.join(here, name)).read().strip()
        except OSError:
            return None

    if sys.argv[1:] == ["--version"]:
        print(setting("fake-codex.version") or "codex-cli 0.159.1")
        sys.exit(0)

    cwd = os.getcwd()
    with open(os.path.join(cwd, "fake-codex.args"), "w") as f:
        json.dump({"argv": sys.argv[1:], "socket": os.environ.get("SIRIUS_SOCKET")}, f)
    log = open(os.path.join(cwd, "fake-codex.log"), "a")

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    turns = 0
    held = None
    for line in sys.stdin:
        log.write(line); log.flush()
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize" and setting("fake-codex.init") == "exit":
            sys.stderr.write("Error: data did not match any variant of untagged enum FeatureToml\nin `features.multi_agent_v2`\n")
            sys.exit(1)
        elif method == "initialize" and setting("fake-codex.init") == "error":
            send({"id": mid, "error": {"code": -32603, "message": "config: bad override"}})
        elif method == "initialize":
            send({"id": mid, "result": {"userAgent": "fake"}})
        elif method == "thread/start":
            send({"id": mid, "result": {"thread": {"id": "thread-new"},
                                        "model": params.get("model") or "fake-default",
                                        "reasoningEffort": "medium"}})
        elif method == "thread/resume":
            if params.get("threadId") == "missing":
                send({"id": mid, "error": {"code": -32600, "message": "no rollout found"}})
            else:
                send({"id": mid, "result": {"thread": {"id": params["threadId"]}}})
        elif method == "turn/start":
            turns += 1
            tid = "turn-%d" % turns
            text = params["input"][0]["text"]
            send({"id": mid, "result": {"turn": {"id": tid, "status": "inProgress", "items": [], "error": None}}})
            if "FAKE_EXIT" in text:
                time.sleep(0.1)
                sys.exit(3)
            if "FAKE_HANG" in text:
                continue
            if "FAKE_HOLD" in text:
                held = (params["threadId"], tid)
                continue
            if "FAKE_APPROVAL" in text:
                send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"threadId": params["threadId"], "turnId": tid}})
            send({"method": "turn/started", "params": {"threadId": params["threadId"], "turn": {"id": tid}}})
            if "FAKE_FAIL" in text:
                send({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": tid, "status": "failed", "items": [], "error": {"message": "boom"}}}})
            else:
                send({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": tid, "status": "completed", "items": [], "error": None}}})
        elif method == "turn/steer":
            if held is None or params.get("expectedTurnId") != held[1]:
                send({"id": mid, "error": {"code": -32600, "message": "no active turn to steer"}})
                continue
            send({"id": mid, "result": {"turnId": held[1]}})
            if "FAKE_DONE" in params["input"][0]["text"]:
                send({"method": "turn/completed", "params": {"threadId": held[0], "turn": {"id": held[1], "status": "completed", "items": [], "error": None}}})
                held = None
        elif mid is not None and method is None:
            pass  # a reply to our request; already logged
    """#

    // Writes the script into `directory` and returns its path.
    static func install(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("fake-codex")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // Writes one of the settings above beside the script.
    static func set(_ name: String, _ value: String, in directory: URL) throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // The JSON objects the fake received, in order.
    static func received(in root: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("fake-codex.log"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    static func arguments(in root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fake-codex.args")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
