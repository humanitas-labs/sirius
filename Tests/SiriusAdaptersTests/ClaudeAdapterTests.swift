import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// ClaudeAdapter against a fake `claude`: a shell script that speaks the
// stream-json subset the adapter reads. The turn's text picks its behaviour:
// FAIL reports an error result, EXIT exits mid-turn, HANG never ends, CHILD
// never ends and leaves a tool process running beside it,
// BACKGROUND follows the turn with one the agent starts by itself (a
// background task finishing) and the empty result after it, and AHEAD runs
// such a turn before ours, as when a task finishes as the line arrives.
// HOLD keeps the turn open until the next line, which joins it (a steer):
// one result then names both uuids, as Claude 2.1.296 does. Other results
// name none, as an older CLI's do. --help prints $FAKE_CLAUDE_HELP (nothing
// when unset: help unread, every flag goes); $FAKE_CLAUDE_REFUSE, when set,
// is printed on stderr before it exits 1 without a word on stdout, as a CLI
// does on an option it doesn't know.
final class ClaudeAdapterTests: XCTestCase {
    private var dir: URL!
    private var log: URL!
    private var root: URL!
    private var helpers: URL!
    private var fake: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-adapter-\(UUID().uuidString)")
        log = dir.appendingPathComponent("log")
        root = dir.appendingPathComponent("root")
        helpers = dir.appendingPathComponent("helpers")
        for url in [log!, root!, helpers!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        fake = dir.appendingPathComponent("claude")
        try Self.fakeClaude.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let fakeClaude = #"""
    #!/bin/bash
    case "$1" in
      --help) if [ -n "$FAKE_CLAUDE_HELP" ]; then cat "$FAKE_CLAUDE_HELP"; fi; exit 0 ;;
      --version) echo "2.1.212 (Claude Code)"; exit 0 ;;
    esac
    if [ -n "$FAKE_CLAUDE_REFUSE" ]; then printf '%s\nRun claude --help for usage.\n' "$FAKE_CLAUDE_REFUSE" >&2; exit 1; fi
    log="$FAKE_CLAUDE_LOG"
    printf '%s\0' "$@" > "$log/args"
    printf '%s' "$SIRIUS_SOCKET" > "$log/socket"
    printf '%s' "$PATH" > "$log/path"
    pwd -P > "$log/cwd"
    echo $$ > "$log/pid"
    session="fake-session"
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--resume" ]; then session="$a"; fi
      prev="$a"
    done
    if [ "$session" = "bad" ]; then
      echo "No conversation found with session ID: bad" >&2
      echo '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"bad","errors":["No conversation found with session ID: bad"]}'
      exit 1
    fi
    held=""
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$log/stdin"
      uuid=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
      if [ -n "$held" ]; then
        echo "{\"type\":\"user\",\"isReplay\":true,\"uuid\":\"$uuid\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}"
        echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$session\",\"num_turns\":2,\"result\":\"both\",\"user_message_uuid\":\"$held\",\"user_message_uuids\":[\"$held\",\"$uuid\"]}"
        held=""
        continue
      fi
      own() {
        echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\",\"model\":\"fake-model\"}"
        echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"background done\"}]}}"
        echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$session\",\"num_turns\":1,\"result\":\"bg\"}"
        echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$session\",\"num_turns\":0,\"result\":\"\"}"
      }
      case "$line" in *AHEAD*) own ;; esac
      echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\",\"model\":\"fake-model\"}"
      echo "{\"type\":\"user\",\"isReplay\":true,\"uuid\":\"$uuid\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}"
      case "$line" in
        *FAIL*) echo "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"session_id\":\"$session\",\"errors\":[\"boom\"]}" ;;
        *EXIT*) echo "dying" >&2; exit 3 ;;
        *HANG*) exec sleep 600 </dev/null ;;
        *HOLD*) held="$uuid"; continue ;;
        *CHILD*) sleep 600 </dev/null & echo $! > "$log/child"; exec sleep 600 </dev/null ;;
        *) echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
           echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$session\",\"num_turns\":1,\"result\":\"ok\"}" ;;
      esac
      case "$line" in *BACKGROUND*) sleep 0.2; own ;; esac
    done
    """#

    private func adapter(executable: String? = nil, systemPrompt: String? = nil,
                         extra: [String: String] = [:]) -> ClaudeAdapter {
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CLAUDE_LOG"] = log.path
        env.merge(extra) { $1 }
        let registration = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                             executable: executable ?? fake.path, root: root.path)
        return ClaudeAdapter(registration: registration, socketPath: "/tmp/sirius-test.sock",
                             helpersDirectory: helpers, systemPrompt: systemPrompt, environment: env)
    }

    // MARK: Older CLIs

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/claude")

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // `claude --help` of 2.1.296, which has every flag Sirius passes.
    func testTheCurrentHelpHasEveryFlag() throws {
        let capabilities = ClaudeCapabilities.parse(help: try Self.fixture("help-2.1.296.txt"),
                                                    version: "2.1.296 (Claude Code)\n")
        XCTAssertEqual(capabilities.version, "2.1.296")
        for option in ["--print", "--allowedTools", "--allowed-tools", "--name", "--effort", "--settings",
                       "--system-prompt-snapshot", "--replay-user-messages", "--resume", "--verbose"] {
            XCTAssertTrue(capabilities.options?.contains(option) == true, option)
        }
        // Options a description mentions on a line of its own are not options.
        XCTAssertFalse(capabilities.options?.contains("--tmux=classic") == true)
        XCTAssertEqual(capabilities.permissionModes,
                       ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"])
        XCTAssertEqual(capabilities.missingRequired, [])
        let args = ClaudeAdapter.arguments(session: "s", systemPrompt: "x", name: "n", model: "m", effort: "high",
                                           fast: true, capabilities: capabilities)
        XCTAssertEqual(args, ClaudeAdapter.arguments(session: "s", systemPrompt: "x", name: "n", model: "m",
                                                     effort: "high", fast: true))
        XCTAssertTrue(args.contains("--system-prompt-snapshot"))
    }

    // A CLI without --system-prompt-snapshot (2.1.212) still runs, without it.
    func testAnOlderHelpLeavesOutTheSnapshot() throws {
        let capabilities = ClaudeCapabilities.parse(help: try Self.fixture("help-no-snapshot.txt"))
        XCTAssertFalse(capabilities.supports("--system-prompt-snapshot"))
        XCTAssertEqual(capabilities.missingRequired, [])
        let args = ClaudeAdapter.arguments(session: "s", systemPrompt: "x", name: "n", capabilities: capabilities)
        XCTAssertFalse(args.contains("--system-prompt-snapshot"))
        XCTAssertFalse(args.contains("off"))
        XCTAssertEqual(args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] }, "x")
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "Bash(sirius:*)"])
        let resume = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(Array(args[resume...(resume + 2)]), ["--resume", "s", "--replay-user-messages"])
    }

    func testOptionalFlagsAreLeftOutAndRequiredOnesReported() {
        let bare = ClaudeCapabilities(options: ["--print", "--input-format", "--output-format", "--verbose",
                                                "--permission-mode", "--replay-user-messages", "--allowedTools",
                                                "--resume", "--append-system-prompt", "--model"],
                                      permissionModes: ["default", "acceptEdits", "plan"], version: "2.0.0")
        let args = ClaudeAdapter.arguments(session: nil, systemPrompt: "x", name: "n", model: "m", effort: "high",
                                           fast: true, capabilities: bare)
        for option in ["--effort", "--settings", "--name", "--system-prompt-snapshot"] {
            XCTAssertFalse(args.contains(option), option)
        }
        XCTAssertTrue(args.contains("--model"))
        // Auto mode is never traded for a looser one: the CLI is refused.
        XCTAssertEqual(bare.missingRequired, ["--permission-mode auto"])
        var noEcho = bare
        noEcho.options?.remove("--replay-user-messages")
        noEcho.permissionModes = nil
        XCTAssertEqual(noEcho.missingRequired, ["--replay-user-messages"])
        // Help unread: every flag goes, as before the probe.
        let unknown = ClaudeCapabilities.parse(help: "", version: nil)
        XCTAssertEqual(unknown, .unknown)
        XCTAssertEqual(unknown.missingRequired, [])
        XCTAssertTrue(ClaudeAdapter.arguments(session: nil, systemPrompt: "x", capabilities: unknown)
            .contains("--system-prompt-snapshot"))
        XCTAssertNil(ClaudeCapabilities.parseVersion("garbage"))
    }

    func testAnOlderClaudeLaunchesWithoutTheSnapshot() async throws {
        let adapter = adapter(systemPrompt: "be brief",
                              extra: ["FAKE_CLAUDE_HELP": Self.fixtures.appendingPathComponent("help-no-snapshot.txt").path])
        _ = try await adapter.start(session: nil)
        let end = try await adapter.deliver(message("hello"))
        XCTAssertEqual(end.outcome, .completed)
        let args = try read("args").split(separator: "\0").map(String.init)
        XCTAssertFalse(args.contains("--system-prompt-snapshot"))
        XCTAssertTrue(args.contains("--append-system-prompt"))
        XCTAssertTrue(args.contains("--name"))
        await adapter.stop()
    }

    func testAClaudeWithoutAutoModeIsTooOld() async throws {
        let help = try Self.fixture("help-2.1.296.txt").replacingOccurrences(of: #""auto","#, with: "")
        let file = dir.appendingPathComponent("help-no-auto.txt")
        try help.write(to: file, atomically: true, encoding: .utf8)
        let adapter = adapter(extra: ["FAKE_CLAUDE_HELP": file.path])
        do {
            _ = try await adapter.start(session: nil)
            XCTFail("expected a throw")
        } catch let error as ClaudeAdapterError {
            XCTAssertEqual(error, .tooOld(version: "2.1.212", missing: ["--permission-mode auto"]))
            XCTAssertEqual(error.userMessage,
                           "Claude Code is too old for Sirius (2.1.212). Run `claude update`, then try again.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.appendingPathComponent("pid").path),
                       "claude never started")
    }

    // A claude that refuses to start says why on stderr; that line reaches
    // the user, not just "not running".
    func testAClaudeThatQuitsAtLaunchSaysWhy() async throws {
        let adapter = adapter(extra: ["FAKE_CLAUDE_REFUSE": "error: unknown option '--system-prompt-snapshot'"])
        _ = try await adapter.start(session: nil)
        for _ in 0..<2 {
            do {
                _ = try await adapter.deliver(message("hello"))
                XCTFail("expected a throw")
            } catch let error as ClaudeAdapterError {
                guard case .quitAtLaunch(let line, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(line, "error: unknown option '--system-prompt-snapshot'")
                XCTAssertEqual(error.userMessage,
                               "Claude Code quit as it started: error: unknown option '--system-prompt-snapshot'")
            }
            // The second deliver finds the process gone.
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        await adapter.stop()
    }

    private func message(_ text: String, attachments: [Message.Attachment] = []) -> Message {
        Message(id: "m_1", agent: "claude", text: text, attachments: attachments)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: log.appendingPathComponent(name), encoding: .utf8)
    }

    private func pid() throws -> pid_t {
        pid_t(try read("pid").trimmingCharacters(in: .whitespacesAndNewlines))!
    }

    private func waitFor(_ name: String) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: log.appendingPathComponent(name).path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("fake claude never wrote \(name)")
    }

    // The onboarding's throwaway first turn: no session name, no resume.
    func testAnUnnamedAdapterStartsWithoutTheSessionName() async throws {
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CLAUDE_LOG"] = log.path
        let registration = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                             executable: fake.path, root: root.path)
        let adapter = ClaudeAdapter(registration: registration, socketPath: "/tmp/sirius-test.sock",
                                    helpersDirectory: helpers, systemPrompt: "first", named: false,
                                    environment: env)
        _ = try await adapter.start(session: nil)
        try await waitFor("pid")
        let args = try read("args").split(separator: "\0").map(String.init)
        XCTAssertEqual(args, ClaudeAdapter.arguments(session: nil, systemPrompt: "first", name: nil))
        XCTAssertFalse(args.contains("--name"))
        XCTAssertFalse(args.contains("--resume"))
        await adapter.stop()
    }

    func testStartLaunchesInTheRootWithTheEnvironment() async throws {
        let adapter = adapter()
        let session = try await adapter.start(session: nil).session
        XCTAssertNil(session, "Claude names the session only with the first turn")
        try await waitFor("pid")
        let args = try read("args").split(separator: "\0").map(String.init)
        XCTAssertEqual(args, ClaudeAdapter.arguments(session: nil, systemPrompt: nil, name: "sirius-claude"))
        XCTAssertEqual(args.firstIndex(of: "--name").map { args[$0 + 1] }, "sirius-claude")
        XCTAssertEqual(Array(args.prefix(6)),
                       ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "Bash(sirius:*)"])
        XCTAssertTrue(args.contains("auto"))
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertEqual(try read("socket"), "/tmp/sirius-test.sock")
        XCTAssertTrue(try read("path").hasPrefix(helpers.path + ":"))
        let real = try XCTUnwrap(realpath(root.path, nil))
        defer { free(real) }
        XCTAssertEqual(try read("cwd").trimmingCharacters(in: .whitespacesAndNewlines), String(cString: real))
        await adapter.stop()
    }

    func testResumePassesTheSession() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: "abc-123")
        let end = try await adapter.deliver(message("hello"))
        XCTAssertEqual(end, TurnEnd(session: "abc-123", outcome: .completed, model: "fake-model"))
        let args = try read("args").split(separator: "\0").map(String.init)
        let i = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(args[i + 1], "abc-123")
        // The orphan check finds a resumed claude by these two side by side.
        XCTAssertEqual(args[i + 2], "--replay-user-messages")
        XCTAssertEqual(args.firstIndex(of: "--name").map { args[$0 + 1] }, "sirius-claude")
        let launched = await adapter.launchArguments
        XCTAssertEqual(launched, args)
        await adapter.stop()
    }

    func testDeliverCompletesOnResultAndStaysWarm() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let first = try await adapter.deliver(message("one"))
        XCTAssertEqual(first, TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model"))
        let second = try await adapter.deliver(message("two"))
        XCTAssertEqual(second, TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model"))

        let lines = try read("stdin").split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one process, two turns")
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(turn["type"] as? String, "user")
        let body = try XCTUnwrap(turn["message"] as? [String: Any])
        XCTAssertEqual(body["role"] as? String, "user")
        let content = try XCTUnwrap(body["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["text"] as? String,
                       MessageRenderer.render(message("one")))
        await adapter.stop()
    }

    func testErrorResultIsAFailedTurnAndTheAgentStaysUp() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let end = try await adapter.deliver(message("please FAIL"))
        XCTAssertEqual(end, TurnEnd(session: "fake-session", outcome: .failed("boom"), model: "fake-model"))
        let next = try await adapter.deliver(message("again"))
        XCTAssertEqual(next.outcome, .completed)
        await adapter.stop()
    }

    func testExitMidTurnThrows() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        do {
            _ = try await adapter.deliver(message("EXIT now"))
            XCTFail("expected a throw")
        } catch let error as ClaudeAdapterError {
            guard case .exited(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("status 3"), reason)
            XCTAssertTrue(reason.contains("dying"), reason)
        }
        do {
            _ = try await adapter.deliver(message("after"))
            XCTFail("expected a throw")
        } catch let error as ClaudeAdapterError {
            guard case .notRunning = error else { return XCTFail("\(error)") }
        }
    }

    func testABadResumeStartsANewSession() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: "bad")
        try await Task.sleep(nanoseconds: 300_000_000)
        let end = try await adapter.deliver(message("hello"))
        XCTAssertEqual(end, TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model"))
        let launched = await adapter.launchArguments
        XCTAssertFalse(launched.contains("--resume"))
        await adapter.stop()
    }

    func testABadResumeRacingTheFirstTurnStartsANewSession() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: "bad")
        let end = try await adapter.deliver(message("hello"))
        XCTAssertEqual(end, TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model"))
        await adapter.stop()
    }

    func testStopMidTurnCancelsTheDeliverAndEndsTheProcess() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let turn = Task { try await adapter.deliver(self.message("HANG")) }
        try await waitFor("stdin")
        let pid = try pid()
        XCTAssertEqual(kill(pid, 0), 0, "fake claude is running")

        await adapter.stop()
        do {
            _ = try await turn.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        XCTAssertEqual(kill(pid, 0), -1, "the process is gone")
        XCTAssertEqual(errno, ESRCH)
    }

    // #2: the tools claude was running go with it.
    func testStopEndsTheProcessGroup() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let turn = Task { try await adapter.deliver(self.message("CHILD")) }
        try await waitFor("child")
        let child = pid_t(try read("child").trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(child, 0), 0, "the tool is running")

        await adapter.stop()
        _ = try? await turn.value
        let childGone = await Self.gone(child)
        XCTAssertTrue(childGone, "the tool outlived the stop")
    }

    // #2: an orphan a dead Sirius left on the session is ended before the
    // session is resumed; one on another session is left alone.
    func testStartEndsAnOrphanOnTheSessionItResumes() async throws {
        let session = UUID().uuidString.lowercased()
        let mine = try spawnOrphan(session: session)
        let other = try spawnOrphan(session: UUID().uuidString.lowercased())
        defer { kill(other, SIGKILL) }
        let entries = ClaudeOrphans.list()
        XCTAssertEqual(ClaudeOrphans.find(session: session, in: entries).map(\.pid), [mine])

        let adapter = adapter()
        _ = try await adapter.start(session: session)
        let orphanGone = await Self.gone(mine)
        XCTAssertTrue(orphanGone, "the orphan outlived the start")
        XCTAssertEqual(kill(other, 0), 0, "an orphan on another session was ended")
        await adapter.stop()
    }

    func testOrphansNeedLaunchdForAParentTheUserAndTheSession() {
        let listing = """
          101     1   101   501 /usr/local/bin/claude -p --verbose --resume s-1 --replay-user-messages --append-system-prompt x
          102   900   102   501 /usr/local/bin/claude -p --resume s-1 --replay-user-messages
          103     1   103     0 /usr/local/bin/claude -p --resume s-1 --replay-user-messages
          104     1   104   501 /usr/local/bin/claude -p --resume s-2 --replay-user-messages
          105     1   105   501 claude --resume s-1
        not a process line
        """
        let entries = ClaudeOrphans.parse(listing)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.first, ClaudeOrphans.Entry(
            pid: 101, ppid: 1, pgid: 101, uid: 501,
            arguments: "/usr/local/bin/claude -p --verbose --resume s-1 --replay-user-messages --append-system-prompt x"))
        XCTAssertEqual(ClaudeOrphans.find(session: "s-1", in: entries, uid: 501).map(\.pid), [101])
        XCTAssertEqual(ClaudeOrphans.find(session: "", in: entries, uid: 501), [])
    }

    // A process standing in for an orphaned claude: started through a shell
    // that exits at once, so launchd becomes its parent.
    private func spawnOrphan(session: String) throws -> pid_t {
        let script = dir.appendingPathComponent("orphan")
        if !FileManager.default.fileExists(atPath: script.path) {
            try "#!/bin/bash\nwhile :; do sleep 0.1; done\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let pidFile = dir.appendingPathComponent("orphan-\(session)")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" -p --input-format stream-json --resume \"$1\" --replay-user-messages "
                           + "</dev/null >/dev/null 2>&1 & echo $! > \"$2\"",
                           script.path, session, pidFile.path]
        try shell.run()
        shell.waitUntilExit()
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<200 where ClaudeOrphans.list().first(where: { $0.pid == pid })?.ppid != 1 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return pid
    }

    // Gone, or a zombie on its way to being reaped.
    private static func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testCancellingTheDeliverTaskStopsTheTurn() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let turn = Task { try await adapter.deliver(self.message("HANG")) }
        try await waitFor("stdin")
        turn.cancel()
        do {
            _ = try await turn.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        await adapter.stop()
    }

    func testRestartAfterStop() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        _ = try await adapter.deliver(message("one"))
        await adapter.stop()
        await adapter.stop()
        _ = try await adapter.start(session: "fake-session")
        let end = try await adapter.deliver(message("two"))
        XCTAssertEqual(end.outcome, .completed)
        await adapter.stop()
    }

    func testImagesGoAsNativeBlocksBesideTheirPath() async throws {
        let image = dir.appendingPathComponent("shot.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try bytes.write(to: image)
        let big = dir.appendingPathComponent("big.png")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ClaudeStream.maxImageBytes + 1))
        try handle.close()
        let text = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)

        let msg = message("look", attachments: [
            .init(path: image.path, mimeType: "image/png"),
            .init(path: big.path, mimeType: "image/png"),
            .init(path: text.path, mimeType: "text/plain"),
        ])
        let line = try ClaudeStream.userMessage(msg)
        XCTAssertEqual(line.last, 0x0A)
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let content = try XCTUnwrap((turn["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2, "one image block (the big one is over the cap), then the text")
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, bytes.base64EncodedString())
        let wrapper = try XCTUnwrap(content[1]["text"] as? String)
        XCTAssertEqual(wrapper, MessageRenderer.render(msg))
        for path in [image.path, big.path, text.path] {
            XCTAssertTrue(wrapper.contains(path), "every attachment stays in the wrapper by path")
        }
    }

    private final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var ends: [TurnEnd] = []
        func append(_ end: TurnEnd) { lock.withLock { ends.append(end) } }
        var all: [TurnEnd] { lock.withLock { ends } }
    }

    func testATurnTheAgentStartsItselfIsReportedAndNotTakenForOurs() async throws {
        let adapter = adapter()
        let ends = Ends()
        await adapter.onAgentTurn { ends.append($0) }
        _ = try await adapter.start(session: nil)
        let first = try await adapter.deliver(message("BACKGROUND please"))
        XCTAssertEqual(first.outcome, .completed)
        for _ in 0..<200 where ends.all.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ends.all, [TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model")],
                       "one agent turn; the empty result after it is ignored")
        // The next message gets its own result, not a leftover.
        let second = try await adapter.deliver(Message(id: "m_2", agent: "claude", text: "again"))
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertEqual(ends.all.count, 1)
        await adapter.stop()
    }

    func testAnAgentTurnAheadOfOursDoesNotEndOurs() async throws {
        let adapter = adapter()
        let ends = Ends()
        await adapter.onAgentTurn { ends.append($0) }
        _ = try await adapter.start(session: nil)
        let end = try await adapter.deliver(message("AHEAD of mine"))
        XCTAssertEqual(end, TurnEnd(session: "fake-session", outcome: .completed, model: "fake-model"))
        XCTAssertEqual(ends.all.count, 1)
        await adapter.stop()
    }

    func testEachLineCarriesAUuidAndClaudeEchoesIt() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        _ = try await adapter.deliver(message("hi"))
        let line = try read("stdin")
        XCTAssertNotNil(line.range(of: #""uuid":"[0-9a-f-]{36}""#, options: .regularExpression))
        let args = await adapter.launchArguments
        XCTAssertTrue(args.contains("--replay-user-messages"))
        await adapter.stop()
    }

    func testASteeredLineJoinsTheTurnAndItsResultEndsBoth() async throws {
        let adapter = adapter()
        _ = try await adapter.start(session: nil)
        let idle = await adapter.steer(Message(id: "m_0", agent: "cc", text: "nobody is listening"))
        XCTAssertFalse(idle)
        let turn = Task { try await adapter.deliver(Message(id: "m_1", agent: "cc", text: "HOLD")) }
        var joined = false
        for _ in 0..<200 where !joined {
            joined = await adapter.steer(Message(id: "m_2", agent: "cc", text: "also this"))
            if !joined { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(joined)
        let end = try await turn.value
        XCTAssertEqual(end.outcome, .completed)
        let next = try await adapter.deliver(Message(id: "m_3", agent: "cc", text: "hi"))
        XCTAssertEqual(next.outcome, .completed)
    }

    func testModelAndEffortGoBeforeTheToolList() {
        let args = ClaudeAdapter.arguments(session: "s", systemPrompt: nil,
                                           model: "claude-opus-5-5", effort: "high")
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "Bash(sirius:*)"])
        let model = try? XCTUnwrap(args.firstIndex(of: "--model"))
        XCTAssertEqual(model.map { args[$0 + 1] }, "claude-opus-5-5")
        let effort = try? XCTUnwrap(args.firstIndex(of: "--effort"))
        XCTAssertEqual(effort.map { args[$0 + 1] }, "high")
        XCTAssertFalse(ClaudeAdapter.arguments(session: nil, systemPrompt: nil).contains("--model"))
    }

    func testTheSessionIsNamedForTheAgent() {
        XCTAssertEqual(ClaudeAdapter.sessionName(agent: "claude"), "sirius-claude")
        let args = ClaudeAdapter.arguments(session: "s", systemPrompt: "x", name: "sirius-claude")
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "Bash(sirius:*)"])
        let resume = try? XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(resume.map { Array(args[$0...($0 + 2)]) }, ["--resume", "s", "--replay-user-messages"])
        XCTAssertFalse(ClaudeAdapter.arguments(session: nil, systemPrompt: nil).contains("--name"))
    }

    func testFastTurnsOnClaudesFastModeSetting() {
        let args = ClaudeAdapter.arguments(session: nil, systemPrompt: nil, fast: true)
        let settings = args.firstIndex(of: "--settings").map { args[$0 + 1] }
        XCTAssertEqual(settings, #"{"fastMode":true}"#)
        XCTAssertEqual(Array(args.suffix(2)), ["--allowedTools", "Bash(sirius:*)"])
        XCTAssertFalse(ClaudeAdapter.arguments(session: nil, systemPrompt: nil).contains("--settings"))
    }

    func testInitNamesTheModel() {
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"system","subtype":"init","session_id":"s","model":"claude-fable-5-1"}"#.utf8)),
                       .initialized(session: "s", model: "claude-fable-5-1"))
    }

    func testResultParsing() {
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"system","subtype":"init","session_id":"s"}"#.utf8)),
                       .initialized(session: "s", model: nil))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"success","is_error":false,"session_id":"s"}"#.utf8)),
                       .result(session: "s", failure: nil))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"error_max_turns","is_error":false,"session_id":"s"}"#.utf8)),
                       .result(session: "s", failure: "error_max_turns"))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error"}"#.utf8)),
                       .result(session: nil, failure: "API Error"))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"rate_limit_event"}"#.utf8)), .other)
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":""}"#.utf8)),
                       .result(session: nil, failure: nil, turns: 0))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"success","user_message_uuid":"a","user_message_uuids":["a","b"]}"#.utf8)),
                       .result(session: nil, failure: nil, messages: ["a", "b"]))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"result","subtype":"success","user_message_uuid":null}"#.utf8)),
                       .result(session: nil, failure: nil, messages: []))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"user","isReplay":true,"uuid":"u1"}"#.utf8)), .replayed(uuid: "u1"))
        XCTAssertEqual(ClaudeStream.parse(Data(#"{"type":"user","uuid":"u1"}"#.utf8)), .other)
        XCTAssertNil(ClaudeStream.parse(Data("not json".utf8)))
    }

    func testLocator() throws {
        XCTAssertEqual(ClaudeLocator.locate(executable: fake.path, environment: [:], home: "/nonexistent"), fake.path)
        XCTAssertEqual(ClaudeLocator.locate(executable: "/nonexistent/claude", environment: ["PATH": "/nope:\(dir.path)"],
                                            home: "/nonexistent"), fake.path)
        let home = dir.appendingPathComponent("home")
        let local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fake, to: local.appendingPathComponent("claude"))
        XCTAssertEqual(ClaudeLocator.locate(executable: "", environment: ["PATH": "/nope"], home: home.path),
                       local.appendingPathComponent("claude").path)
    }

    func testMissingExecutableThrowsAtStart() async throws {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/nonexistent"
        let registration = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                             executable: "/nonexistent/claude", root: root.path)
        let adapter = ClaudeAdapter(registration: registration, socketPath: "/tmp/x.sock",
                                    helpersDirectory: helpers, environment: env)
        // The common install locations may hold a real claude on this machine;
        // only assert when none does.
        guard ClaudeLocator.locate(executable: "", environment: env) == nil else { return }
        do {
            _ = try await adapter.start(session: nil)
            XCTFail("expected a throw")
        } catch let error as ClaudeAdapterError {
            guard case .executableNotFound = error else { return XCTFail("\(error)") }
        }
    }
}
