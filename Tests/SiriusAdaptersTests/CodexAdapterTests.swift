import Darwin
import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class CodexAdapterTests: XCTestCase {
    private var root: URL!
    private var adapter: CodexAdapter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try CodexFakeAppServer.install(in: root)
        let registration = AgentRegistration(agent: "cx", name: "Codex", harness: .codex,
                                             executable: executable, root: root.path)
        adapter = CodexAdapter(registration: registration, socketPath: "/tmp/sirius-test/cx.sock",
                               helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"),
                               instructions: Self.instructions)
    }

    static let instructions = "Reply through Sirius."

    override func tearDown() async throws {
        await adapter?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func methods() -> [String] {
        CodexFakeAppServer.received(in: root).compactMap { $0["method"] as? String }
    }

    private func request(_ method: String) -> [String: Any]? {
        CodexFakeAppServer.received(in: root).last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    private func waitFor(_ method: String) async throws {
        for _ in 0..<200 {
            if methods().contains(method) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("\(method) never arrived")
    }

    private func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    func testModelGoesOnTheThreadAndEffortOnEachTurn() async throws {
        let registration = AgentRegistration(agent: "cx", name: "Codex", harness: .codex,
                                             executable: try CodexFakeAppServer.install(in: root), root: root.path,
                                             model: "gpt-6-astra", effort: "high")
        adapter = CodexAdapter(registration: registration, socketPath: "/tmp/sirius-test/cx.sock",
                               helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"))
        let start = try await adapter.start(session: nil)
        XCTAssertEqual(start.model, "gpt-6-astra")
        XCTAssertEqual(request("thread/start")?["model"] as? String, "gpt-6-astra")
        let end = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "hi"))
        XCTAssertEqual(end.model, "gpt-6-astra")
        XCTAssertEqual(request("turn/start")?["effort"] as? String, "high")
    }

    func testWithoutAModelTheHarnessDefaultIsReported() async throws {
        let start = try await adapter.start(session: nil)
        XCTAssertNil(request("thread/start")?["model"])
        XCTAssertEqual(start.model, "fake-default")
        XCTAssertEqual(start.effort, "medium")
        _ = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "hi"))
        XCTAssertNil(request("turn/start")?["effort"])
    }

    func testStartReturnsTheThreadIdAndConfiguresTheSession() async throws {
        let session = try await adapter.start(session: nil).session
        XCTAssertEqual(session, "thread-new")
        XCTAssertEqual(methods(), ["initialize", "initialized", "thread/start"])
        let start = try XCTUnwrap(request("thread/start"))
        XCTAssertEqual(start["cwd"] as? String, root.path)
        XCTAssertEqual(start["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(start["approvalPolicy"] as? String, "never")
        XCTAssertEqual(start["developerInstructions"] as? String, Self.instructions)

        let launch = try XCTUnwrap(CodexFakeAppServer.arguments(in: root))
        XCTAssertEqual(launch["socket"] as? String, "/tmp/sirius-test/cx.sock")
        let argv = try XCTUnwrap(launch["argv"] as? [String])
        XCTAssertEqual(argv.first, "app-server")
        let config = stride(from: 2, to: argv.count, by: 2).map { argv[$0] }
        XCTAssertEqual(Array(argv.dropFirst()).enumerated().filter { $0.offset % 2 == 0 }.map(\.element),
                       Array(repeating: "-c", count: config.count))
        XCTAssertEqual(config, [
            #"mcp_servers.sirius.command="/opt/sirius/Helpers/sirius-mcp""#,
            "mcp_servers.sirius.args=[]",
            #"mcp_servers.sirius.env={SIRIUS_SOCKET="/tmp/sirius-test/cx.sock"}"#,
            #"mcp_servers.sirius.tools.display.approval_mode="approve""#,
            #"mcp_servers.sirius.tools.notify.approval_mode="approve""#,
            #"mcp_servers.sirius.tools.speak.approval_mode="approve""#,
            "sandbox_workspace_write.network_access=true",
            "features.multi_agent_v2.multi_agent_mode_hint_text=\(CodexLaunch.toml(CodexLaunch.delegationHint))",
        ])
    }

    func testResumePassesTheSession() async throws {
        let session = try await adapter.start(session: "thread-old").session
        XCTAssertEqual(session, "thread-old")
        XCTAssertEqual(methods(), ["initialize", "initialized", "thread/resume"])
        let resume = try XCTUnwrap(request("thread/resume"))
        XCTAssertEqual(resume["threadId"] as? String, "thread-old")
        XCTAssertEqual(resume["cwd"] as? String, root.path)
        XCTAssertEqual(resume["approvalPolicy"] as? String, "never")
        XCTAssertEqual(resume["developerInstructions"] as? String, Self.instructions)
    }

    func testAThreadThatCannotBeResumedIsReplacedByANewOne() async throws {
        let session = try await adapter.start(session: "missing").session
        XCTAssertEqual(session, "thread-new")
        XCTAssertEqual(methods(), ["initialize", "initialized", "thread/resume", "thread/start"])
    }

    func testDeliverCompletesTheTurn() async throws {
        _ = try await adapter.start(session: nil)
        let message = Message(id: "m_1", agent: "cx", text: "hello",
                              attachments: [.init(path: "/a/shot.png", mimeType: "image/png"),
                                            .init(path: "/a/notes.txt", mimeType: "text/plain")])
        let end = try await adapter.deliver(message)
        XCTAssertEqual(end, TurnEnd(session: "thread-new", outcome: .completed, model: "fake-default"))

        let turn = try XCTUnwrap(request("turn/start"))
        XCTAssertEqual(turn["threadId"] as? String, "thread-new")
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, MessageRenderer.render(message))
        XCTAssertEqual(input[1]["type"] as? String, "localImage")
        XCTAssertEqual(input[1]["path"] as? String, "/a/shot.png")

        // The same process takes the next turn.
        let second = try await adapter.deliver(Message(id: "m_2", agent: "cx", text: "again"))
        XCTAssertEqual(second.outcome, .completed)
    }

    func testAFailedTurnIsReportedAndTheAgentStaysUp() async throws {
        _ = try await adapter.start(session: nil)
        let end = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "FAKE_FAIL"))
        XCTAssertEqual(end, TurnEnd(session: "thread-new", outcome: .failed("boom"), model: "fake-default"))
        let next = try await adapter.deliver(Message(id: "m_2", agent: "cx", text: "fine"))
        XCTAssertEqual(next.outcome, .completed)
    }

    func testApprovalRequestsAreDeclined() async throws {
        _ = try await adapter.start(session: nil)
        let end = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "FAKE_APPROVAL"))
        XCTAssertEqual(end.outcome, .completed)
        let reply = CodexFakeAppServer.received(in: root).first { ($0["id"] as? Int) == 900 }
        XCTAssertEqual((reply?["result"] as? [String: Any])?["decision"] as? String, "decline")
    }

    func testProcessExitMidTurnThrows() async throws {
        _ = try await adapter.start(session: nil)
        do {
            _ = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "FAKE_EXIT"))
            XCTFail("deliver returned")
        } catch is CancellationError {
            XCTFail("a lost process is not a cancellation")
        } catch {
            XCTAssertTrue(error is CodexAppServerError, "\(error)")
        }
        // The queue then stops the adapter and starts it again.
        await adapter.stop()
        let session = try await adapter.start(session: "thread-new").session
        XCTAssertEqual(session, "thread-new")
    }

    func testStopMidTurnCancelsDeliverAndEndsTheProcess() async throws {
        _ = try await adapter.start(session: nil)
        let running = await adapter.processIdentifier
        let pid = try XCTUnwrap(running)
        XCTAssertTrue(isRunning(pid))
        let adapter = self.adapter!
        let turn = Task { try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "FAKE_HANG")) }
        try await waitFor("turn/start")
        await adapter.stop()
        XCTAssertFalse(isRunning(pid))
        do {
            _ = try await turn.value
            XCTFail("deliver returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // Stopping again is harmless.
        await adapter.stop()
    }

    func testASteerJoinsTheRunningTurnAndNeedsOne() async throws {
        _ = try await adapter.start(session: nil)
        let idle = await adapter.steer(Message(id: "m_0", agent: "cx", text: "nobody is listening"))
        XCTAssertFalse(idle)
        let adapter = self.adapter!
        let turn = Task { try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "FAKE_HOLD")) }
        try await waitFor("turn/start")
        var joined = false
        for _ in 0..<200 where !joined {
            joined = await adapter.steer(Message(id: "m_2", agent: "cx", text: "also this"))
            if !joined { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(joined)
        let steer = try XCTUnwrap(request("turn/steer"))
        XCTAssertEqual(steer["threadId"] as? String, "thread-new")
        XCTAssertEqual(steer["expectedTurnId"] as? String, "turn-1")
        let input = try XCTUnwrap(steer["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String,
                       MessageRenderer.render(Message(id: "m_2", agent: "cx", text: "also this")))
        let done = await adapter.steer(Message(id: "m_3", agent: "cx", text: "FAKE_DONE"))
        XCTAssertTrue(done)
        let end = try await turn.value
        XCTAssertEqual(end.outcome, .completed)
        let after = await adapter.steer(Message(id: "m_4", agent: "cx", text: "too late"))
        XCTAssertFalse(after)
    }

    func testACodexBeforeTheMultiAgentSettingsStartsWithoutThem() async throws {
        try CodexFakeAppServer.set("fake-codex.version", "codex-cli 0.146.1", in: root)
        _ = try await adapter.start(session: nil)
        let argv = try XCTUnwrap(CodexFakeAppServer.arguments(in: root)?["argv"] as? [String])
        XCTAssertFalse(argv.contains { $0.hasPrefix("features.multi_agent_v2") }, "\(argv)")
        XCTAssertTrue(argv.contains("sandbox_workspace_write.network_access=true"))
        let end = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "hello"))
        XCTAssertEqual(end.outcome, .completed)
    }

    func testACodexBelowTheFloorIsTooOldAndNeverStarted() async throws {
        try CodexFakeAppServer.set("fake-codex.version", "codex-cli 0.131.0", in: root)
        do {
            _ = try await adapter.start(session: nil)
            XCTFail("expected a throw")
        } catch let error as CodexAdapterError {
            XCTAssertEqual(error, .tooOld(version: "0.131.0"))
            XCTAssertEqual(error.userMessage,
                           "Codex is too old for Sirius (0.131.0). Update Codex, then try again.")
        }
        XCTAssertNil(CodexFakeAppServer.arguments(in: root), "app-server never started")
    }

    // A codex that quits at initialize says why: its first stderr line
    // reaches the log and a toast.
    func testACodexThatQuitsAtInitializeSaysWhy() async throws {
        try CodexFakeAppServer.set("fake-codex.init", "exit", in: root)
        do {
            _ = try await adapter.start(session: nil)
            XCTFail("expected a throw")
        } catch let error as CodexAdapterError {
            guard case .startFailed(let line, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(line, "Error: data did not match any variant of untagged enum FeatureToml")
            XCTAssertTrue(reason.contains("app-server"), reason)
            XCTAssertEqual(error.userMessage, "Codex quit as it started: " + line)
        }
        let pid = await adapter.processIdentifier
        XCTAssertNil(pid)
    }

    func testAnErrorAtInitializeIsShown() async throws {
        try CodexFakeAppServer.set("fake-codex.init", "error", in: root)
        do {
            _ = try await adapter.start(session: nil)
            XCTFail("expected a throw")
        } catch let error as CodexAdapterError {
            guard case .startFailed(let line, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(line, "config: bad override")
            XCTAssertEqual(error.userMessage, "Codex quit as it started: config: bad override")
        }
    }

    func testDeliverBeforeStartThrows() async throws {
        do {
            _ = try await adapter.deliver(Message(id: "m_1", agent: "cx", text: "hi"))
            XCTFail("deliver returned")
        } catch {
            XCTAssertEqual(error as? CodexAdapterError, .notStarted)
        }
    }

    func testFindsCodexRegisteredThenOnPathThenInChatGPT() {
        let registered = "/custom/codex"
        let onPath = "/usr/local/bin/codex"
        let bundled = "/Applications/\(CodexLaunch.bundledSuffix)"
        let env = ["PATH": "/nowhere:/usr/local/bin"]
        func find(_ present: Set<String>, registered: String = registered) -> String? {
            CodexLaunch.findExecutable(registered: registered, environment: env, home: "/Users/u",
                                       isExecutable: { present.contains($0) })
        }
        XCTAssertEqual(find([registered, onPath, bundled]), registered)
        XCTAssertEqual(find([onPath, bundled]), onPath)
        XCTAssertEqual(find([bundled]), bundled)
        XCTAssertEqual(find(["/Users/u/Applications/\(CodexLaunch.bundledSuffix)"]),
                       "/Users/u/Applications/\(CodexLaunch.bundledSuffix)")
        XCTAssertNil(find([]))
    }

    func testTOMLStringsAreEscaped() {
        XCTAssertEqual(CodexLaunch.toml(#"/a "b"\c"#), #""/a \"b\"\\c""#)
        XCTAssertEqual(CodexLaunch.toml("x\ny"), #""x\ny""#)
    }
}

final class CodexLaunchConfigTests: XCTestCase {
    func testFastIsThePriorityTier() {
        let fast = CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s", fast: true)
        XCTAssertTrue(fast.contains(#"service_tier="priority""#))
        XCTAssertFalse(CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s").contains { $0.hasPrefix("service_tier") })
    }

    func testVersionsAreReadAndCompared() {
        XCTAssertEqual(CodexCapabilities.parse(version: "codex-cli 0.159.1\n").version, "0.159.1")
        XCTAssertEqual(CodexCapabilities.parse(version: "codex-cli 0.162.0-alpha.17.2").version, "0.162.0-alpha.17.2")
        XCTAssertNil(CodexCapabilities.parse(version: "garbage").version)
        XCTAssertNil(CodexCapabilities.parse(version: nil).version)
        func caps(_ version: String?) -> CodexCapabilities { CodexCapabilities(version: version) }
        XCTAssertTrue(caps("0.162.0-alpha.17.2").supportsMultiAgentSettings)
        XCTAssertTrue(caps("0.147.0").supportsMultiAgentSettings)
        XCTAssertFalse(caps("0.147.0-alpha.1").supportsMultiAgentSettings)
        XCTAssertFalse(caps("0.146.1").supportsMultiAgentSettings)
        XCTAssertFalse(caps("0.146.1").isTooOld)
        XCTAssertFalse(caps("0.132.0").isTooOld)
        XCTAssertTrue(caps("0.131.0").isTooOld)
        XCTAssertTrue(caps("0.1.2504301751").isTooOld)
        XCTAssertTrue(caps("0.99.0").isTooOld)
        XCTAssertTrue(caps("1.0.0").supportsMultiAgentSettings)
        // Unknown or unreadable: taken as new enough, as before the probe.
        XCTAssertFalse(CodexCapabilities.unknown.isTooOld)
        XCTAssertTrue(CodexCapabilities.unknown.supportsMultiAgentSettings)
        XCTAssertFalse(caps("0.159").isTooOld)
    }

    func testTheMultiAgentSettingsNeedACodexThatReadsThem() {
        let old = CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s", workers: "Do it.",
                                        capabilities: CodexCapabilities(version: "0.146.1"))
        XCTAssertFalse(old.contains { $0.hasPrefix("features.multi_agent_v2") })
        XCTAssertTrue(old.contains { $0.hasPrefix("mcp_servers.sirius.command=") })
        let new = CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s", workers: "Do it.",
                                        capabilities: CodexCapabilities(version: "0.147.0"))
        XCTAssertEqual(new.filter { $0.hasPrefix("features.multi_agent_v2") }.count, 2)
    }

    func testWorkersMdIsWhatWorkerAgentsAreGiven() {
        let key = "features.multi_agent_v2.subagent_developer_instructions="
        XCTAssertTrue(CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s", workers: "Do it.\nToast.")
            .contains(key + #""Do it.\nToast.""#))
        XCTAssertFalse(CodexLaunch.arguments(mcpHelper: "/h", socketPath: "/s").contains { $0.hasPrefix(key) })
    }
}
