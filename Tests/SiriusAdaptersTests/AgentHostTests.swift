import Darwin
import Foundation
import SiriusClient
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class AgentHostTests: XCTestCase {
    private var base = ""
    private var registryDirectory: URL!
    private var storageDirectory: URL!
    private var helpers: URL!
    private var server: SocketServer!
    private var commands: LoggingCommandQueue!
    private var inner: RecordingQueue!
    private var adapters: HostFakeAdapters!
    private var reports: Reports!

    override func setUpWithError() throws {
        // sockaddr_un holds 104 bytes; keep the socket directory short.
        base = "/tmp/aht-\(UInt32.random(in: 0...UInt32.max))"
        XCTAssertEqual(mkdir(base, 0o700), 0)
        let root = URL(fileURLWithPath: base, isDirectory: true)
        registryDirectory = root.appendingPathComponent("registry", isDirectory: true)
        storageDirectory = root.appendingPathComponent("storage", isDirectory: true)
        helpers = root.appendingPathComponent("Helpers", isDirectory: true)
        inner = RecordingQueue()
        let reports = Reports()
        self.reports = reports
        commands = LoggingCommandQueue(inner: inner, report: { reports.add($0) })
        server = try SocketServer(commands: commands, directory: base + "/sirius")
        adapters = HostFakeAdapters()
    }

    override func tearDownWithError() throws {
        server?.close()
        try? FileManager.default.removeItem(atPath: base)
    }

    private func register(_ agent: String, harness: AgentRegistration.Harness = .claudeCode,
                          instructions: String? = nil) throws {
        let registry = AgentRegistry(directory: registryDirectory)
        try registry.write(AgentRegistration(agent: agent, name: agent.capitalized, harness: harness,
                                             executable: "/usr/bin/true", root: base))
        if let instructions {
            try instructions.write(to: registryDirectory.appendingPathComponent(agent)
                .appendingPathComponent(AgentRegistry.instructionsFile), atomically: true, encoding: .utf8)
        }
    }

    private func makeHost() -> AgentHost {
        let adapters = adapters!
        let reports = reports!
        return AgentHost(registry: AgentRegistry(directory: registryDirectory), server: server, commands: commands,
                         storageDirectory: storageDirectory, helpersDirectory: helpers,
                         templatesDirectory: InstructionsTemplates.directory,
                         makeAdapter: { adapters.make($0) }, report: { reports.add($0) })
    }

    // MARK: -

    func testEachRegisteredAgentGetsASocketAWarmAdapterAndAQueue() async throws {
        try register("alpha", instructions: "Be brief.")
        try register("beta", harness: .codex)
        let broken = registryDirectory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let host = makeHost()
        await host.start()

        let summaries = await host.agents()
        XCTAssertEqual(summaries.map(\.agent), ["alpha", "beta"])
        XCTAssertEqual(summaries.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(summaries.map(\.harness), [.claudeCode, .codex])
        XCTAssertEqual(summaries.map(\.state), [.running, .running])
        XCTAssertEqual(server.agents, ["alpha", "beta"])

        let alpha = try XCTUnwrap(adapters.adapter("alpha"))
        XCTAssertEqual(alpha.context.socketPath, try server.socketPath(for: "alpha"))
        XCTAssertEqual(alpha.context.helpersDirectory, helpers)
        // alpha's own instructions.md is used as it is; beta had none, so
        // it was seeded from the template with Codex's way to reply.
        XCTAssertEqual(alpha.context.instructions, "Be brief.")
        let beta = try XCTUnwrap(adapters.adapter("beta")?.context.instructions)
        XCTAssertTrue(beta.contains("`sirius` MCP server"))
        XCTAssertFalse(beta.contains("{{"))
        // Started warm, before any message.
        XCTAssertEqual(alpha.starts, 1)
        XCTAssertEqual(adapters.adapter("beta")?.starts, 1)
        XCTAssertTrue(reports.all.contains { $0.contains("broken") })
        await host.stopAll()
    }

    func testAFailedWarmStartIsReportedNotFatal() async throws {
        try register("alpha")
        adapters.failStart = ["alpha"]
        let host = makeHost()
        await host.start()
        let state = await host.agents().first?.state
        guard case .failed = state else { return XCTFail("expected failed, got \(String(describing: state))") }
        XCTAssertTrue(reports.all.contains { $0.contains("alpha did not start") })
        await host.stopAll()
    }

    func testSendCopiesAttachmentsAndDeliversTheMessage() async throws {
        try register("alpha")
        let host = makeHost()
        await host.start()

        let source = URL(fileURLWithPath: base).appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let notes = URL(fileURLWithPath: base).appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)

        let id = try await host.send(text: "look at this", attachments: [source, notes], to: "alpha")
        let alpha = try XCTUnwrap(adapters.adapter("alpha"))
        try await alpha.waitForDelivery()

        let message = try XCTUnwrap(alpha.messages.first)
        XCTAssertEqual(message.id, id)
        XCTAssertEqual(message.agent, "alpha")
        XCTAssertEqual(message.text, "look at this")
        let folder = try AgentStorage(agent: "alpha", baseDirectory: storageDirectory).attachmentsDirectory(for: id)
        XCTAssertEqual(message.attachments, [
            Message.Attachment(path: folder.appendingPathComponent("shot.png").path, mimeType: "image/png"),
            Message.Attachment(path: folder.appendingPathComponent("notes.txt").path, mimeType: "text/plain"),
        ])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("shot.png")), Data([0x89, 0x50, 0x4E, 0x47]))

        do {
            _ = try await host.send(text: "hi", attachments: [], to: "nobody")
            XCTFail("expected unknownAgent")
        } catch {
            XCTAssertEqual(error as? AgentHostError, .unknownAgent("nobody"))
        }
        await host.stopAll()
    }

    func testACommandIsLoggedAgainstTheCurrentMessageAndReachesThePresenters() async throws {
        try register("alpha")
        adapters.turnDelay = 30
        let host = makeHost()
        await host.start()
        let id = try await host.send(text: "work", attachments: [], to: "alpha")
        let alpha = try XCTUnwrap(adapters.adapter("alpha"))
        try await alpha.waitForTurnStarted()

        let path = try server.socketPath(for: "alpha")
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let params = DisplayParams(kind: .toast, content: [.text(TextContent(text: "on it"))])
                continuation.resume(returning: SiriusClient(socketPath: path, timeout: 5)
                    .call(.display, params: params))
            }
        }
        XCTAssertEqual(outcome, .result(.object(["delivered": .bool(true)])))
        XCTAssertEqual(inner.received.map(\.agent), ["alpha"])

        let storage = try AgentStorage(agent: "alpha", baseDirectory: storageDirectory)
        let filed = try AgentLog.read(storage.logURL).entries.compactMap { entry -> String?? in
            if case .command(let message, _, .display, _) = entry.event { return message }
            return nil
        }
        XCTAssertEqual(filed, [.some(id)])
        await host.stopAll()
    }

    func testARegistrationNamedDevIsSkipped() async throws {
        try register("dev")
        try register("alpha")
        // The app's own dev socket, as main.swift binds it.
        try server.add(agent: "dev")
        let host = makeHost()
        await host.start()
        let ids = await host.agents().map(\.agent)
        XCTAssertEqual(ids, ["alpha"])
        XCTAssertNil(adapters.adapter("dev"))
        XCTAssertTrue(reports.all.contains { $0.contains("\"dev\" skipped") })
        await host.stopAll()
        // The dev socket outlives the agents.
        XCTAssertEqual(server.agents, ["dev"])
    }

    func testStopAllStopsEveryAdapterAndInterruptsTheRunningTurn() async throws {
        try register("alpha")
        try register("beta", harness: .codex)
        adapters.turnDelay = 30
        let host = makeHost()
        await host.start()
        let id = try await host.send(text: "long job", attachments: [], to: "alpha")
        try await XCTUnwrap(adapters.adapter("alpha")).waitForTurnStarted()

        await host.stopAll()

        XCTAssertGreaterThanOrEqual(adapters.adapter("alpha")?.stops ?? 0, 1)
        XCTAssertGreaterThanOrEqual(adapters.adapter("beta")?.stops ?? 0, 1)
        let states = await host.agents().map(\.state)
        XCTAssertEqual(states, [.stopped, .stopped])
        XCTAssertEqual(server.agents, [])
        let storage = try AgentStorage(agent: "alpha", baseDirectory: storageDirectory)
        let interrupted = try AgentLog.read(storage.logURL).entries.compactMap { entry -> String? in
            if case .interrupted(let message, _) = entry.event { return message }
            return nil
        }
        XCTAssertEqual(interrupted, [id])
    }

    func testReloadBeforeStartStartsTheHost() async throws {
        let host = makeHost()
        try register("alpha")
        await host.reload()
        let states = await host.agents().map(\.state)
        XCTAssertEqual(states, [.running])
    }

    func testReloadAddsNewAgentsAndRestartsChangedOnesWithANewSessionOnANewRoot() async throws {
        try register("alpha")
        try register("beta", harness: .codex)
        let host = makeHost()
        await host.start()
        let alpha = try XCTUnwrap(adapters.adapter("alpha"))
        let beta = try XCTUnwrap(adapters.adapter("beta"))
        let storage = try AgentStorage(agent: "beta", baseDirectory: storageDirectory)
        try storage.writeState(AgentState(session: "old"))

        // beta moves to a new folder; gamma is new; alpha is unchanged.
        let registry = AgentRegistry(directory: registryDirectory)
        let moved = base + "/elsewhere"
        XCTAssertEqual(mkdir(moved, 0o700), 0)
        try registry.write(AgentRegistration(agent: "beta", name: "Beta", harness: .codex,
                                             executable: "/usr/bin/true", root: moved))
        try register("gamma")
        await host.reload()

        XCTAssertEqual(alpha.stops, 0)
        XCTAssertTrue(adapters.adapter("alpha") === alpha)
        XCTAssertGreaterThanOrEqual(beta.stops, 1)
        let newBeta = try XCTUnwrap(adapters.adapter("beta"))
        XCTAssertFalse(newBeta === beta)
        XCTAssertEqual(newBeta.context.registration.root, moved)
        XCTAssertNil(try storage.readState().session)
        let agents = await host.agents()
        XCTAssertEqual(agents.map(\.agent), ["alpha", "beta", "gamma"])
        XCTAssertEqual(agents.map(\.state), [.running, .running, .running])
        XCTAssertEqual(Set(server.agents), ["alpha", "beta", "gamma"])
    }

    // #1: messages queued behind a long turn reach the agent after a
    // restart, and the user is told they were resent.
    func testARestartResendsQueuedMessagesAndSaysSo() async throws {
        try register("alpha")
        adapters.turnDelay = 30
        let host = makeHost()
        await host.start()
        _ = try await host.send(text: "long job", attachments: [], to: "alpha")
        let queued = [try await host.send(text: "two", attachments: [], to: "alpha"),
                      try await host.send(text: "three", attachments: [], to: "alpha")]
        try await XCTUnwrap(adapters.adapter("alpha")).waitForTurnStarted()
        await host.stopAll()

        adapters = HostFakeAdapters()
        let adapters = adapters!
        let reports = reports!
        let notices = Reports()
        let restarted = AgentHost(registry: AgentRegistry(directory: registryDirectory), server: server,
                                  commands: commands, storageDirectory: storageDirectory, helpersDirectory: helpers,
                                  makeAdapter: { adapters.make($0) }, report: { reports.add($0) },
                                  notice: { agent, text in notices.add("\(agent): \(text)") })
        await restarted.start()
        let alpha = try XCTUnwrap(adapters.adapter("alpha"))
        for _ in 0..<500 where alpha.messages.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(alpha.messages.map(\.id), queued)
        XCTAssertEqual(alpha.messages.map(\.text), ["two", "three"])
        XCTAssertEqual(notices.all, ["alpha: Resent 2 messages"])
        await restarted.stopAll()
    }

    func testHelpersDirectoryOutsideABundleIsTheBinarysDirectory() {
        // The test runner is not Sirius.app; the bundled case is checked live.
        let resolved = AgentHost.helpersDirectory(bundle: Bundle(for: AgentHostTests.self))
        XCTAssertFalse(resolved.path.hasSuffix("Contents/Helpers"))
        XCTAssertEqual(AgentHost.registryDirectory(environment: ["SIRIUS_REGISTRY_DIR": "/tmp/r"]).path, "/tmp/r")
        XCTAssertEqual(AgentHost.registryDirectory(environment: [:]), AgentRegistry.defaultDirectory)
    }
}

// MARK: - The first turn

extension AgentHostTests {
    func testTheFirstTurnRunsInAThrowawaySessionWithTheFirstTurnInstruction() async throws {
        try register("alpha", instructions: "Be brief.")
        let host = makeHost()
        await host.start()
        let regular = try XCTUnwrap(adapters.adapter("alpha"))

        let id = try await host.sendFirstTurn(text: "Hello, what can you do?", to: "alpha")
        let throwaway = try XCTUnwrap(adapters.adapter("alpha"))
        XCTAssertFalse(throwaway === regular, "a fresh adapter, not the agent's own")
        try await throwaway.waitForDelivery()

        XCTAssertTrue(throwaway.context.firstTurn)
        XCTAssertEqual(throwaway.context.instructions, "Be brief.\n\n" + AgentHost.firstTurnInstruction)
        XCTAssertEqual(throwaway.context.socketPath, try server.socketPath(for: "alpha"))
        XCTAssertEqual(throwaway.sessions, [nil], "never resumes a session")
        XCTAssertEqual(throwaway.messages.map(\.text), ["Hello, what can you do?"])
        XCTAssertEqual(throwaway.messages.map(\.id), [id])
        for _ in 0..<500 where throwaway.stops == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(throwaway.stops, 1, "stopped once the turn ends")
        // The regular session is left alone.
        XCTAssertFalse(regular.context.firstTurn)
        XCTAssertEqual(regular.context.instructions, "Be brief.")
        XCTAssertTrue(regular.messages.isEmpty)
        XCTAssertEqual(regular.stops, 0)
        await host.stopAll()
    }

    func testTheFirstTurnInstructionStandsAloneWithoutInstructions() {
        XCTAssertEqual(AgentHost.firstTurnInstructions(nil), AgentHost.firstTurnInstruction)
        XCTAssertEqual(AgentHost.firstTurnInstructions(""), AgentHost.firstTurnInstruction)
        XCTAssertTrue(AgentHost.firstTurnInstruction.contains("2–3 short spoken-style sentences"))
    }

    func testAFirstTurnToAnUnknownAgentThrows() async throws {
        let host = makeHost()
        await host.start()
        do {
            _ = try await host.sendFirstTurn(text: "hi", to: "nobody")
            XCTFail("expected unknownAgent")
        } catch AgentHostError.unknownAgent {}
    }

    func testTheDefaultFirstTurnAdaptersBuildTheirSessionsFresh() {
        let claude = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                       executable: "/usr/bin/true", root: "/tmp")
        let instructions = AgentHost.firstTurnInstructions("Reply through Sirius.")
        // Claude: a fresh process, no --resume and no session name, with the
        // first-turn text appended to the normal instructions.
        let args = ClaudeAdapter.arguments(session: nil, systemPrompt: instructions, name: nil)
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertFalse(args.contains("--name"))
        XCTAssertEqual(args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] }, instructions)
        XCTAssertTrue(AgentHost.makeDefaultAdapter(AgentHost.AdapterContext(
            registration: claude, socketPath: "/tmp/s.sock", helpersDirectory: URL(fileURLWithPath: "/tmp"),
            instructions: instructions, firstTurn: true)) is ClaudeAdapter)
        // Codex: a new thread whose developer instructions end with it.
        let codex = AgentRegistration(agent: "codex", name: "Codex", harness: .codex,
                                      executable: "/usr/bin/true", root: "/tmp")
        let params = CodexAdapter.threadParams(registration: codex, instructions: instructions)
        XCTAssertEqual(params["developerInstructions"]?.string, instructions)
        XCTAssertTrue(instructions.hasSuffix(AgentHost.firstTurnInstruction))
        XCTAssertNil(params["threadId"])
    }
}

// MARK: - Fakes

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

final class RecordingQueue: CommandQueue, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [Command] = []
    var received: [Command] { lock.withLock { commands } }

    func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
        lock.withLock { commands.append(command) }
        return .success(.delivered)
    }
}

final class HostFakeAdapters: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String: HostFakeAdapter] = [:]
    private var _turnDelay: Double = 0
    private var _failStart: Set<String> = []

    var turnDelay: Double {
        get { lock.withLock { _turnDelay } }
        set { lock.withLock { _turnDelay = newValue } }
    }

    var failStart: Set<String> {
        get { lock.withLock { _failStart } }
        set { lock.withLock { _failStart = newValue } }
    }

    func make(_ context: AgentHost.AdapterContext) -> any Adapter {
        let adapter = HostFakeAdapter(context: context, turnDelay: turnDelay,
                                      failStart: failStart.contains(context.registration.agent))
        lock.withLock { made[context.registration.agent] = adapter }
        return adapter
    }

    func adapter(_ agent: String) -> HostFakeAdapter? { lock.withLock { made[agent] } }
}

final class HostFakeAdapter: Adapter, @unchecked Sendable {
    struct NoStart: Error {}

    let context: AgentHost.AdapterContext
    private let turnDelay: Double
    private let failStart: Bool
    private let lock = NSLock()
    private var _starts = 0
    private var _stops = 0
    private var _turns = 0
    private var _messages: [Message] = []
    private var _sessions: [String?] = []

    init(context: AgentHost.AdapterContext, turnDelay: Double, failStart: Bool) {
        self.context = context
        self.turnDelay = turnDelay
        self.failStart = failStart
    }

    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var messages: [Message] { lock.withLock { _messages } }
    // The session each start was asked to resume.
    var sessions: [String?] { lock.withLock { _sessions } }

    func start(session: String?) async throws -> AgentStart {
        lock.withLock {
            _starts += 1
            _sessions.append(session)
        }
        if failStart { throw NoStart() }
        return AgentStart()
    }

    func deliver(_ message: Message) async throws -> TurnEnd {
        lock.withLock { _turns += 1 }
        try await Task.sleep(nanoseconds: UInt64(turnDelay * 1_000_000_000))
        lock.withLock { _messages.append(message) }
        return TurnEnd(session: nil, outcome: .completed)
    }

    func stop() async { lock.withLock { _stops += 1 } }

    func waitForDelivery() async throws {
        for _ in 0..<500 where messages.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(messages.isEmpty)
    }

    func waitForTurnStarted() async throws {
        for _ in 0..<500 where lock.withLock({ _turns }) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThan(lock.withLock { _turns }, 0)
    }
}
