import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class WorkingMemoryTests: XCTestCase {
    private var base: URL!
    // The repo's packaging/, which build-app.sh copies into Sirius.app.
    private let packaging = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("packaging", isDirectory: true)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-wmem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("registry/alpha"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    private var alpha: URL { base.appendingPathComponent("registry/alpha", isDirectory: true) }

    // MARK: Seeding

    func testSeedingWritesBothTemplatesAndNeverTouchesAUsersFile() throws {
        try write("memory", "t/WMEM.md")
        try write("cleanup", "t/gc.md")
        let templates = base.appendingPathComponent("t")
        let agents = base.appendingPathComponent("agents")
        XCTAssertTrue(try WorkingMemory.seed(into: agents, templates: templates))
        XCTAssertEqual(try read("agents/WMEM.md"), "memory")
        XCTAssertEqual(try read("agents/gc.md"), "cleanup")

        try write("", "agents/WMEM.md")
        try write("mine", "agents/gc.md")
        XCTAssertFalse(try WorkingMemory.seed(into: agents, templates: templates))
        XCTAssertEqual(try read("agents/WMEM.md"), "")
        XCTAssertEqual(try read("agents/gc.md"), "mine")
    }

    func testTheShippedTemplatesAreGenericAndWired() throws {
        let agent = packaging.appendingPathComponent("agent")
        let memory = try String(contentsOf: agent.appendingPathComponent("WMEM.md"), encoding: .utf8)
        XCTAssertEqual(WorkingMemory.cleaned(memory), "never")
        XCTAssertTrue(memory.contains("## Pinned") && memory.contains("## Learned"))
        let cleanup = try String(contentsOf: agent.appendingPathComponent("gc.md"), encoding: .utf8)
        XCTAssertTrue(cleanup.contains("Cleaned:") && cleanup.contains("Learned"))
        XCTAssertFalse(cleanup.contains("wmem "))
        XCTAssertFalse((memory + cleanup).contains("Andrew"))
        let instructions = try String(contentsOf: agent.appendingPathComponent("instructions.md"), encoding: .utf8)
        XCTAssertTrue(instructions.contains("@~/.agents/sirius/WMEM.md"))
        XCTAssertFalse(instructions.contains("`wmem`"))
        let consts = try String(contentsOf: agent.appendingPathComponent("consts.md"), encoding: .utf8)
        XCTAssertEqual(Instructions.parseConsts(consts)[WorkingMemory.limitName], "2000")
    }

    // MARK: Size and header

    func testTokensAreCodePointsOverFour() {
        XCTAssertEqual(WorkingMemory.tokens(""), 0)
        XCTAssertEqual(WorkingMemory.tokens("abcdefg"), 1)
        // "·" and "é" are one code point each, two bytes in UTF-8.
        XCTAssertEqual(WorkingMemory.tokens("··é·"), 1)
    }

    // The estimate is the one `wmem ls` prints, from the built helper.
    func testTokensMatchWmemLs() throws {
        // swift test puts the test bundle beside the built products.
        let binary = Bundle(for: WorkingMemoryTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("wmem")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("wmem not built at \(binary.path)")
        }
        let text = String(repeating: "- entry-name: a path with · and é in it\r\n", count: 37)
        try write("# Working memory\n\nWindow: 14 days · Cleaned: never\n\n## Learned\n\n" + text, "WMEM.md")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["ls"]
        process.environment = ["WMEM_FILE": base.appendingPathComponent("WMEM.md").path, "HOME": base.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(printed.contains("~\(WorkingMemory.tokens(try read("WMEM.md"))) tokens"), printed)
    }

    func testCleanedIsTheHeadersDateOrNever() {
        XCTAssertEqual(WorkingMemory.cleaned("# W\n\nWindow: 21 days · Cleaned: 2026-11-08\n\n## Pinned\n"), "2026-11-08")
        XCTAssertEqual(WorkingMemory.cleaned("Window: 14 days · Cleaned: never"), "never")
        XCTAssertEqual(WorkingMemory.cleaned("# no header\n- a: b\n"), "never")
        XCTAssertEqual(WorkingMemory.cleaned("Window: x days · Cleaned: 2026-11-08"), "never")
    }

    func testTheLimitIsTheAgentsConstOrTheDefault() throws {
        XCTAssertEqual(WorkingMemory.limit(agentFolder: alpha), 2000)
        try write("CONCURRENCY_WARNING: 8\n", "registry/alpha/consts.md")
        XCTAssertEqual(WorkingMemory.limit(agentFolder: alpha), 2000)
        try write("WMEM_TOKEN_LIMIT: 500\n", "registry/alpha/consts.md")
        XCTAssertEqual(WorkingMemory.limit(agentFolder: alpha), 500)
        try write("WMEM_TOKEN_LIMIT: lots\n", "registry/alpha/consts.md")
        XCTAssertEqual(WorkingMemory.limit(agentFolder: alpha), 2000)
    }

    // MARK: Who keeps it

    func testIncludedDirectlyOrThroughAnotherFile() throws {
        let memory = base.appendingPathComponent("WMEM.md")
        try write("memory", "WMEM.md")
        XCTAssertFalse(WorkingMemory.isIncluded(memory, agentFolder: alpha))
        try write("Mine. @../../WMEM.md\n", "registry/alpha/instructions.md")
        XCTAssertTrue(WorkingMemory.isIncluded(memory, agentFolder: alpha))
        try write("See @../../shared.md\n", "registry/alpha/instructions.md")
        try write("Shared. @WMEM.md\n", "shared.md")
        XCTAssertTrue(WorkingMemory.isIncluded(memory, agentFolder: alpha))
        // A ref in a comment or in code is not an include.
        try write("<!-- @../../WMEM.md --> `@../../WMEM.md`\n", "registry/alpha/instructions.md")
        XCTAssertFalse(WorkingMemory.isIncluded(memory, agentFolder: alpha))
    }

    func testTheAgentsOwnCleanupPromptOverridesTheSharedOne() throws {
        let agents: URL = base, templates = base.appendingPathComponent("t")
        XCTAssertNil(WorkingMemory.cleanupText(agentFolder: alpha, agents: agents, templates: templates))
        try write("template", "t/gc.md")
        XCTAssertEqual(WorkingMemory.cleanupText(agentFolder: alpha, agents: agents, templates: templates), "template")
        try write("shared", "gc.md")
        XCTAssertEqual(WorkingMemory.cleanupText(agentFolder: alpha, agents: agents, templates: templates), "shared")
        try write("own", "registry/alpha/gc.md")
        XCTAssertEqual(WorkingMemory.cleanupText(agentFolder: alpha, agents: agents, templates: templates), "own")
    }

    // MARK: Once per crossing

    func testItAsksOncePerCrossing() {
        var trigger = WorkingMemoryTrigger()
        XCTAssertFalse(trigger.shouldAsk(tokens: 100, limit: 100, cleaned: "never"))
        XCTAssertTrue(trigger.shouldAsk(tokens: 101, limit: 100, cleaned: "never"))
        XCTAssertFalse(trigger.shouldAsk(tokens: 150, limit: 100, cleaned: "never"))
        XCTAssertFalse(trigger.shouldAsk(tokens: 120, limit: 100, cleaned: "never"))
        // Back under the limit re-arms it; the next crossing asks again.
        XCTAssertFalse(trigger.shouldAsk(tokens: 80, limit: 100, cleaned: "never"))
        XCTAssertTrue(trigger.armed)
        XCTAssertTrue(trigger.shouldAsk(tokens: 130, limit: 100, cleaned: "never"))
        XCTAssertFalse(trigger.shouldAsk(tokens: 130, limit: 100, cleaned: "never"))
    }

    func testANewCleanedDateRearmsIt() {
        var trigger = WorkingMemoryTrigger()
        XCTAssertTrue(trigger.shouldAsk(tokens: 300, limit: 100, cleaned: "2026-11-01"))
        XCTAssertFalse(trigger.shouldAsk(tokens: 300, limit: 100, cleaned: "2026-11-01"))
        XCTAssertTrue(trigger.shouldAsk(tokens: 250, limit: 100, cleaned: "2026-11-09"))
        XCTAssertFalse(trigger.shouldAsk(tokens: 250, limit: 100, cleaned: "2026-11-09"))
    }

    func testTheTurnCarriesTheNumbersAndTheCleanupPrompt() {
        let text = WorkingMemory.prompt(memory: base.appendingPathComponent("WMEM.md"), tokens: 2400, limit: 2000,
                                        cleanup: "# Working memory cleanup\n\n1. Run `wmem ls`.\n")
        XCTAssertTrue(text.contains("about 2400 tokens, over your limit of 2000"))
        XCTAssertTrue(text.hasSuffix("# Working memory cleanup\n\n1. Run `wmem ls`."))
    }

    // MARK: Origin

    func testASiriusTurnRendersAsSiriusNotTheUserOrAPeer() {
        let rendered = MessageRenderer.render(Message(id: "m_1", agent: "alpha", text: "Clean up.", fromSirius: true))
        XCTAssertTrue(rendered.hasPrefix("[sirius · from the app]\nFrom: Sirius itself"))
        XCTAssertTrue(rendered.contains("\n\nClean up.\n\n"))
        XCTAssertFalse(rendered.contains("<sirius message="))
        XCTAssertFalse(rendered.contains("[dm"))
    }

    func testASiriusMessageIsLoggedAsSuchAndRequeuedAsSuch() async throws {
        let storage = try AgentStorage(agent: "alpha", baseDirectory: base.appendingPathComponent("storage"))
        let message = Message(id: "m_wmem", agent: "alpha", text: "Clean up.", fromSirius: true)
        let log = try storage.openLog()
        try await log.messageReceived(message)
        let entries = try AgentLog.read(storage.logURL).entries
        XCTAssertEqual(entries.map(\.event.name), ["sirius_message"])
        let reopened = try storage.openLog()
        XCTAssertEqual(reopened.requeued.first?.message(agent: "alpha"), message)
    }
}
