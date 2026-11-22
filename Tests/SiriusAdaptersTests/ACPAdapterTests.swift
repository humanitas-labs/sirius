import Darwin
import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class ACPAdapterTests: XCTestCase {
    private var root: URL!
    private var adapter: ACPAdapter!

    static let instructions = "Reply through Sirius."

    // A profile like Cursor's, signing in with the fake's own method.
    static let profile: ACPProfile = {
        var profile = ACPProfile.cursor
        profile.authMethod = "fake_login"
        return profile
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        adapter = try makeAdapter()
    }

    private func makeAdapter(_ harness: AgentRegistration.Harness = .cursor, profile: ACPProfile = ACPAdapterTests.profile,
                             model: String? = nil, effort: String? = nil,
                             instructions: String? = ACPAdapterTests.instructions) throws -> ACPAdapter {
        let executable = try ACPFakeAgent.install(in: root)
        let registration = AgentRegistration(agent: "ac", name: "ACP", harness: harness,
                                             executable: executable, root: root.path, model: model, effort: effort)
        return ACPAdapter(registration: registration, profile: profile, socketPath: "/tmp/sirius-test/ac.sock",
                          helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"),
                          instructions: instructions, authenticateTimeout: .milliseconds(300))
    }

    override func tearDown() async throws {
        await adapter?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func received() -> [[String: Any]] { ACPFakeAgent.received(in: root) }

    private func methods() -> [String] { received().compactMap { $0["method"] as? String } }

    private func request(_ method: String) -> [String: Any]? {
        received().last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    // Sirius's answer to the request the fake sent with this id.
    private func answer(_ id: Int) -> [String: Any]? {
        received().last { ($0["id"] as? Int) == id && $0["method"] == nil }
    }

    private func promptText(_ index: Int = 0) -> String? {
        let prompts = received().filter { $0["method"] as? String == "session/prompt" }
        guard prompts.indices.contains(index) else { return nil }
        let blocks = (prompts[index]["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        return blocks?.first?["text"] as? String
    }

    private func message(_ text: String, id: String = "m_1") -> Message {
        Message(id: id, agent: "ac", text: text)
    }

    // MARK: open

    func testOpenSignsInAndStartsASessionWithSiriusMCP() async throws {
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.session, "sess-new")
        XCTAssertNil(info.model)
        XCTAssertEqual(info.capabilities, AgentCapabilities())

        XCTAssertEqual(methods(), ["initialize", "authenticate", "session/new"])
        let initialize = try XCTUnwrap(request("initialize"))
        XCTAssertEqual(initialize["protocolVersion"] as? Int, 1)
        XCTAssertEqual((initialize["clientInfo"] as? [String: Any])?["name"] as? String, "sirius")
        let client = try XCTUnwrap(initialize["clientCapabilities"] as? [String: Any])
        XCTAssertEqual(client["terminal"] as? Bool, false)
        XCTAssertEqual((client["fs"] as? [String: Bool]), ["readTextFile": false, "writeTextFile": false])
        XCTAssertEqual(request("authenticate")?["methodId"] as? String, "fake_login")

        let new = try XCTUnwrap(request("session/new"))
        XCTAssertEqual(new["cwd"] as? String, root.path)
        XCTAssertNil(new["systemPrompt"], "not advertised, so not sent")
        let servers = try XCTUnwrap(new["mcpServers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0]["name"] as? String, "sirius")
        XCTAssertEqual(servers[0]["command"] as? String, "/opt/sirius/Helpers/sirius-mcp")
        XCTAssertEqual(servers[0]["args"] as? [String], [])
        let env = try XCTUnwrap(servers[0]["env"] as? [[String: String]])
        XCTAssertEqual(env, [["name": "SIRIUS_SOCKET", "value": "/tmp/sirius-test/ac.sock"]])
    }

    func testAMethodTheServerDoesNotOfferIsNeverCalled() async throws {
        var profile = ACPProfile.cursor
        profile.authMethod = "cursor_login"
        adapter = try makeAdapter(profile: profile)
        _ = try await adapter.open(SessionRequest())
        XCTAssertEqual(methods(), ["initialize", "session/new"])
    }

    func testCursorIsLaunchedForSirius() async throws {
        adapter = try makeAdapter(model: "gpt-5[effort=high]")
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.model, "gpt-5[effort=high]")
        let launched = try XCTUnwrap(ACPFakeAgent.arguments(in: root))
        XCTAssertEqual(launched["argv"] as? [String], ["--trust", "--approve-mcps", "acp"],
                       "never --model: it would rewrite the user's own default")
        XCTAssertEqual(launched["socket"] as? String, "/tmp/sirius-test/ac.sock")
        XCTAssertTrue((launched["path"] as? String)?.hasPrefix("/opt/sirius/Helpers:") == true)
        XCTAssertNil(launched["noUpdate"] as? String)
    }

    func testAntigravityIsLaunchedForSiriusAndSignsInByItself() async throws {
        adapter = try makeAdapter(.antigravity, profile: .antigravity)
        _ = try await adapter.open(SessionRequest())
        let launched = try XCTUnwrap(ACPFakeAgent.arguments(in: root))
        XCTAssertEqual(launched["argv"] as? [String], ["acp"])
        XCTAssertEqual(launched["noUpdate"] as? String, "true")
        XCTAssertEqual(methods(), ["initialize", "session/new"], "no auth method that could open a browser")
    }

    // MARK: opencode

    // The fake's "opencode" mode is the server as run against 2.3.2.
    func testOpenCodeIsLaunchedForSiriusAndNeverSendsTheTerminalAuthMethod() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        adapter = try makeAdapter(.opencode, profile: .opencode)
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.session, "sess-new")
        XCTAssertEqual(info.model, "opencode-go/hy3", "the session's own model, with none registered")
        let launched = try XCTUnwrap(ACPFakeAgent.arguments(in: root))
        XCTAssertEqual(launched["argv"] as? [String], ["acp"])
        XCTAssertEqual(launched["socket"] as? String, "/tmp/sirius-test/ac.sock")
        // opencode-login is a terminal method ("run `opencode auth login` in
        // the terminal"): the server uses the credentials it already has, and
        // Sirius never calls a method that could open one.
        XCTAssertEqual(methods(), ["initialize", "session/new"])
    }

    func testOpenCodeResumesWithoutReplayAndCarriesItsInstructionsOnTheFirstPrompt() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        adapter = try makeAdapter(.opencode, profile: .opencode)
        let resumed = try await adapter.open(SessionRequest(resume: "sess-oc"))
        XCTAssertEqual(resumed.session, "sess-oc")
        XCTAssertFalse(methods().contains("session/load"), "resume replays no history")
        let resume = try XCTUnwrap(request("session/resume"))
        XCTAssertEqual(resume["sessionId"] as? String, "sess-oc")
        XCTAssertEqual(resume["cwd"] as? String, root.path)
        XCTAssertNil(resume["systemPrompt"], "OpenCode advertises no systemPrompt capability")

        // With no systemPrompt to carry them, the instructions ride in front
        // of the first prompt, then never again.
        _ = try await adapter.prompt(message("hello"))
        XCTAssertTrue(promptText()?.hasPrefix(ACPAdapter.instructionsHeader) == true)
        _ = try await adapter.prompt(message("again"))
        XCTAssertEqual(promptText(1), MessageRenderer.render(message("again")),
                       "the instructions went once, on the first turn")
    }

    func testOpenCodeTakesTheRegisteredModelAndEffortThroughItsConfigOptions() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        adapter = try makeAdapter(.opencode, profile: .opencode,
                                  model: "anthropic/claude-sonnet-5-5", effort: "low")
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.model, "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(info.effort, "low")
        let sets = received().filter { $0["method"] as? String == "session/set_config_option" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(sets.map { $0["configId"] as? String }, ["model", "effort"])
        XCTAssertEqual(sets.map { $0["value"] as? String }, ["anthropic/claude-sonnet-5-5", "low"])
        XCTAssertEqual(sets.map { $0["sessionId"] as? String }, ["sess-new", "sess-new"])
    }

    func testAModelOpenCodeDoesNotOfferIsRefusedWithWhatItOffers() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        adapter = try makeAdapter(.opencode, profile: .opencode, model: "anthropic/nonexistent")
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("open should throw")
        } catch let error as ACPAdapterError {
            XCTAssertEqual(error, .modelUnavailable(product: "OpenCode", "anthropic/nonexistent",
                                                    available: ["anthropic/claude-sonnet-5-5", "opencode-go/hy3"]))
            XCTAssertNotNil(error.userMessage)
        }
        let pid = await adapter.processIdentifier
        XCTAssertNil(pid, "the server is not left running")
    }

    func testAStoredSessionIsLoadedAndAGoneOneIsReplaced() async throws {
        let updates = adapter.updates
        let loaded = try await adapter.open(SessionRequest(resume: "sess-old"))
        XCTAssertEqual(loaded.session, "sess-old")
        let load = try XCTUnwrap(request("session/load"))
        XCTAssertEqual(load["sessionId"] as? String, "sess-old")
        XCTAssertEqual(load["cwd"] as? String, root.path)
        XCTAssertEqual((load["mcpServers"] as? [[String: Any]])?.count, 1)

        // The usage in the replayed history is not this session's news.
        _ = try await adapter.prompt(message("hello"))
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .usage(contextTokens: 53001))

        let replaced = try await adapter.open(SessionRequest(resume: "missing"))
        XCTAssertEqual(replaced.session, "sess-new")
    }

    func testResumeAndTheSystemPromptAreUsedWhereAdvertised() async throws {
        try ACPFakeAgent.set(mode: "full", in: root)
        let info = try await adapter.open(SessionRequest(resume: "sess-old"))
        XCTAssertEqual(info.session, "sess-old")
        XCTAssertFalse(methods().contains("session/load"))
        let resume = try XCTUnwrap(request("session/resume"))
        XCTAssertEqual(resume["sessionId"] as? String, "sess-old")
        let prompt = try XCTUnwrap(resume["systemPrompt"] as? [String: Any])
        XCTAssertEqual(prompt["mode"] as? String, "append")
        XCTAssertEqual((prompt["content"] as? [[String: String]]), [["type": "text", "text": Self.instructions]])

        let sent = message("hello")
        _ = try await adapter.prompt(sent)
        XCTAssertEqual(promptText(), MessageRenderer.render(sent), "the instructions are the session's, not the turn's")
    }

    func testTheModelAndEffortAreSetThroughTheSessionsOptions() async throws {
        try ACPFakeAgent.set(mode: "full", in: root)
        adapter = try makeAdapter(.antigravity, profile: .antigravity, model: "gemini-4-neon-high", effort: "xhigh")
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.model, "gemini-4-neon-high")
        XCTAssertEqual(info.effort, "xhigh")
        let sets = received().filter { $0["method"] as? String == "session/set_config_option" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(sets.map { $0["configId"] as? String }, ["model", "thinking"])
        XCTAssertEqual(sets.map { $0["value"] as? String }, ["gemini-4-neon-high", "extra"], "xhigh is Antigravity's Extra")
        XCTAssertEqual(sets.map { $0["sessionId"] as? String }, ["sess-new", "sess-new"])
    }

    func testWithoutARegisteredModelTheSessionsOwnIsReportedAndAnUnknownEffortIsLeft() async throws {
        try ACPFakeAgent.set(mode: "full", in: root)
        adapter = try makeAdapter(.antigravity, profile: .antigravity, effort: "ultra")
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.model, "gemini-4-carbon-medium")
        XCTAssertFalse(methods().contains("session/set_config_option"))
    }

    func testAModelTheSessionDoesNotOfferIsRefusedWithWhatItOffers() async throws {
        try ACPFakeAgent.set(mode: "full", in: root)
        adapter = try makeAdapter(.antigravity, profile: .antigravity, model: "gemini-9")
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("open should throw")
        } catch let error as ACPAdapterError {
            XCTAssertEqual(error, .modelUnavailable(product: "Antigravity", "gemini-9",
                                                    available: ["gemini-4-neon-high", "gemini-4-carbon-medium"]))
            XCTAssertNotNil(error.userMessage)
        }
        let pid = await adapter.processIdentifier
        XCTAssertNil(pid, "the server is not left running")
    }

    // MARK: sign-in and start failures

    func testASignedOutCLISaysHowToSignIn() async throws {
        for mode in ["signedout", "silent"] {
            try ACPFakeAgent.set(mode: mode, in: root)
            do {
                _ = try await adapter.open(SessionRequest())
                XCTFail("open should throw (\(mode))")
            } catch let error as ACPAdapterError {
                XCTAssertEqual(error, .signInRequired(product: "Cursor", command: "agent login"), mode)
                XCTAssertEqual(error.userMessage,
                               "Cursor is signed out. Run `agent login` in a terminal, then try again.")
            }
        }
    }

    func testAServerThatQuitsAtStartIsReportedWithItsFirstLine() async throws {
        try ACPFakeAgent.set(mode: "exit", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("open should throw")
        } catch let error as ACPAdapterError {
            guard case .startFailed("Cursor", let line, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(line, "Error: the keychain is locked")
        }
    }

    func testAnotherProtocolVersionIsRefused() async throws {
        try ACPFakeAgent.set(mode: "v2", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("open should throw")
        } catch let error as ACPAdapterError {
            XCTAssertEqual(error, .unsupportedProtocol(product: "Cursor", 2))
        }
    }

    func testAMissingCLIIsReported() async throws {
        let registration = AgentRegistration(agent: "ac", name: "ACP", harness: .antigravity,
                                             executable: "/nowhere/agy", root: root.path)
        let missing = ACPAdapter(registration: registration, profile: .antigravity, socketPath: "/tmp/x.sock",
                                 helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"),
                                 environment: ["PATH": "/nowhere", "HOME": root.path])
        guard ACPProfile.antigravity.findExecutable(registered: "/nowhere/agy", environment: ["PATH": "/nowhere"]) == nil
        else { throw XCTSkip("agy is installed in ~/.local/bin on this machine") }
        do {
            _ = try await missing.open(SessionRequest())
            XCTFail("open should throw")
        } catch let error as ACPAdapterError {
            XCTAssertEqual(error, .notFound(product: "Antigravity", command: "agy"))
        }
    }

    func testTheCLIIsFoundUnderEitherOfItsNames() {
        let found = ACPProfile.cursor.findExecutable(registered: "/gone/agent", environment: ["PATH": "/a:/b"],
                                                     home: "/Users/u", isExecutable: { $0 == "/b/cursor-agent" })
        XCTAssertEqual(found, "/b/cursor-agent")
        let installed = ACPProfile.cursor.findExecutable(registered: "", environment: [:], home: "/Users/u",
                                                         isExecutable: { $0 == "/Users/u/.local/bin/agent" })
        XCTAssertEqual(installed, "/Users/u/.local/bin/agent")
    }

    // MARK: prompt

    func testInstructionsGoInFrontOfTheFirstPromptAfterEachOpen() async throws {
        _ = try await adapter.open(SessionRequest())
        let first = message("hello"), second = message("again", id: "m_2")
        let end = try await adapter.prompt(first)
        XCTAssertEqual(end, TurnEnd(session: "sess-new", outcome: .completed, model: nil))
        _ = try await adapter.prompt(second)
        let prefixed = try XCTUnwrap(promptText(0))
        XCTAssertTrue(prefixed.hasPrefix(ACPAdapter.instructionsHeader + "\n\n" + Self.instructions + "\n\n"))
        XCTAssertTrue(prefixed.hasSuffix(ACPAdapter.instructionsFooter + "\n\n" + MessageRenderer.render(first)))
        XCTAssertEqual(promptText(1), MessageRenderer.render(second))
        XCTAssertEqual(request("session/prompt")?["sessionId"] as? String, "sess-new")

        // A resumed session gets them again: instructions.md may have changed.
        _ = try await adapter.open(SessionRequest(resume: "sess-new"))
        _ = try await adapter.prompt(message("back", id: "m_3"))
        XCTAssertTrue(try XCTUnwrap(promptText(2)).hasPrefix(ACPAdapter.instructionsHeader))
    }

    func testAPromptCarriesItsImagesAsBlocks() async throws {
        let image = root.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        adapter = try makeAdapter(instructions: nil)
        _ = try await adapter.open(SessionRequest())
        let sent = Message(id: "m_1", agent: "ac", text: "look",
                           attachments: [.init(path: image.path, mimeType: "image/png"),
                                         .init(path: "/a/notes.txt", mimeType: "text/plain")])
        _ = try await adapter.prompt(sent)
        let blocks = try XCTUnwrap(request("session/prompt")?["prompt"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, MessageRenderer.render(sent))
        XCTAssertEqual(blocks[1]["type"] as? String, "image")
        XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(blocks[1]["data"] as? String, "iVBORw==")
    }

    func testImagesStayPathsForAServerThatDoesNotTakeThem() {
        let blocks = ACPAdapter.prompt(for: Message(id: "m_1", agent: "ac", text: "look",
                                                    attachments: [.init(path: "/a/shot.png", mimeType: "image/png")]),
                                       instructions: nil, images: false)
        XCTAssertEqual(blocks.count, 1)
    }

    func testATurnThatDidNotEndWellFailsAndTheAgentStaysUp() async throws {
        _ = try await adapter.open(SessionRequest())
        let refused = try await adapter.prompt(message("FAKE_REFUSE"))
        XCTAssertEqual(refused.outcome, .failed("the model refused the request"))
        XCTAssertEqual(refused.session, "sess-new")
        let errored = try await adapter.prompt(message("FAKE_ERROR", id: "m_2"))
        XCTAssertEqual(errored.outcome, .failed("boom"))
        // The instructions were not taken in by a turn yet, so they go again.
        let next = try await adapter.prompt(message("fine", id: "m_3"))
        XCTAssertEqual(next.outcome, .completed)
    }

    func testEveryStopReasonButEndTurnFails() {
        XCTAssertEqual(ACPAdapter.outcome(stopReason: "end_turn"), .completed)
        for reason in ["max_tokens", "max_turn_requests", "refusal", "cancelled", "something_new", nil] {
            guard case .failed = ACPAdapter.outcome(stopReason: reason) else {
                return XCTFail("\(reason ?? "nil") should fail")
            }
        }
    }

    func testAnExitMidTurnThrowsAndAPromptWithoutASessionToo() async throws {
        do {
            _ = try await adapter.prompt(message("too early"))
            XCTFail("prompt should throw")
        } catch let error as ACPAdapterError {
            XCTAssertEqual(error, .notStarted(product: "Cursor"))
        }
        _ = try await adapter.open(SessionRequest())
        do {
            _ = try await adapter.prompt(message("FAKE_EXIT"))
            XCTFail("prompt should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("exited with status 3") || "\(error)".contains("closed its output"),
                          "\(error)")
        }
    }

    func testUsageIsReported() async throws {
        let updates = adapter.updates
        _ = try await adapter.open(SessionRequest())
        _ = try await adapter.prompt(message("hello"))
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .usage(contextTokens: 53001))
    }

    // MARK: requests from the agent

    func testAPermissionIsAllowedOnceAndOneWithNoAllowIsCancelled() async throws {
        _ = try await adapter.open(SessionRequest())
        let allowed = try await adapter.prompt(message("FAKE_PERMISSION"))
        XCTAssertEqual(allowed.outcome, .completed)
        let outcome = (answer(900)?["result"] as? [String: Any])?["outcome"] as? [String: String]
        XCTAssertEqual(outcome, ["outcome": "selected", "optionId": "yes"])

        let cancelled = try await adapter.prompt(message("FAKE_NOALLOW", id: "m_2"))
        XCTAssertEqual(cancelled.outcome, .completed)
        XCTAssertEqual((answer(901)?["result"] as? [String: Any])?["outcome"] as? [String: String],
                       ["outcome": "cancelled"])
    }

    func testAStandingAllowIsTakenWhenThereIsNoOneTimeOne() {
        let params: JSONValue = .object(["options": .array([
            .object(["optionId": .string("no"), "kind": .string("reject_always")]),
            .object(["optionId": .string("always"), "kind": .string("allow_always")]),
        ])])
        XCTAssertEqual(ACPAdapter.permission(params)["outcome"]?["optionId"]?.string, "always")
    }

    func testCursorsQuestionIsSkippedAndItsPlanAccepted() async throws {
        _ = try await adapter.open(SessionRequest())
        let asked = try await adapter.prompt(message("FAKE_ASK"))
        XCTAssertEqual(asked.outcome, .completed)
        let skipped = (answer(902)?["result"] as? [String: Any])?["outcome"] as? [String: String]
        XCTAssertEqual(skipped?["outcome"], "skipped")
        XCTAssertEqual(skipped?["reason"], ACPProfile.unattended)

        let planned = try await adapter.prompt(message("FAKE_PLAN", id: "m_2"))
        XCTAssertEqual(planned.outcome, .completed)
        XCTAssertEqual((answer(903)?["result"] as? [String: Any])?["outcome"] as? [String: String],
                       ["outcome": "accepted"])
    }

    func testWhatSiriusDoesNotServeIsRefusedAndTheTurnGoesOn() async throws {
        _ = try await adapter.open(SessionRequest())
        let end = try await adapter.prompt(message("FAKE_FS"))
        XCTAssertEqual(end.outcome, .completed)
        XCTAssertEqual((answer(904)?["error"] as? [String: Any])?["code"] as? Int, -32601)
        // Antigravity has no requests of its own: Cursor's are not answered for it.
        guard case .error(let code, _) = ACPAdapter.answer("cursor/ask_question", .null, profile: .antigravity)
        else { return XCTFail("should be refused") }
        XCTAssertEqual(code, -32601)
    }

    // MARK: close

    func testCloseEndsAServerThatOutlivesItsStdin() async throws {
        _ = try await adapter.open(SessionRequest())
        let running = await adapter.processIdentifier
        let pid = try XCTUnwrap(running)
        XCTAssertEqual(kill(pid, 0), 0, "running")
        await adapter.close()
        XCTAssertEqual(kill(pid, 0), -1, "gone")
        let closed = await adapter.processIdentifier
        XCTAssertNil(closed)
        await adapter.close()
    }

    func testOpeningAgainReplacesTheServer() async throws {
        _ = try await adapter.open(SessionRequest())
        let one = await adapter.processIdentifier
        let first = try XCTUnwrap(one)
        _ = try await adapter.open(SessionRequest(resume: "sess-new"))
        let two = await adapter.processIdentifier
        let second = try XCTUnwrap(two)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(kill(first, 0), -1, "the first server is gone")
    }

    // MARK: host

    func testTheHostBuildsAnACPAdapterForEveryACPHarness() {
        for (harness, product) in [(AgentRegistration.Harness.cursor, "Cursor"), (.antigravity, "Antigravity"),
                                   (.opencode, "OpenCode")] {
            let registration = AgentRegistration(agent: "a", name: "A", harness: harness, executable: "/x", root: "/r")
            let built = AgentHost.makeDefaultAdapter(AgentHost.AdapterContext(
                registration: registration, socketPath: "/tmp/a.sock",
                helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"), instructions: "i"))
            XCTAssertEqual((built as? ACPAdapter)?.profile.product, product)
        }
    }
}
