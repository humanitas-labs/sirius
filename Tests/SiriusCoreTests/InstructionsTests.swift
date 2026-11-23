import Foundation
import XCTest
@testable import SiriusCore

final class InstructionsTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-instr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("t/codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("agent"), withIntermediateDirectories: true)
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

    private func seed() throws -> Bool {
        try Instructions.seed(folder: base.appendingPathComponent("agent"),
                              template: base.appendingPathComponent("t/instructions.md"),
                              harness: base.appendingPathComponent("t/codex"))
    }

    private func compose() throws -> String? {
        try Instructions.compose(entrypoint: base.appendingPathComponent("agent/instructions.md"))
    }

    func testSeedingFillsTheSharedTemplateWithTheHarnessParts() throws {
        try write("# Shared\n\n{{tools}}\n\nMiddle.\n- a\n{{turns}}\n- z\n", "t/instructions.md")
        try write("Use the MCP tool.\n", "t/codex/tools.md")
        try write("- codex only\n", "t/codex/turns.md")
        XCTAssertTrue(try seed())
        XCTAssertEqual(try read("agent/instructions.md"), "# Shared\n\nUse the MCP tool.\n\nMiddle.\n- a\n- codex only\n- z\n")
    }

    func testSeedingNeverTouchesAFileTheUserHas() throws {
        try write("template", "t/instructions.md")
        try write("", "agent/instructions.md")
        XCTAssertFalse(try seed())
        XCTAssertEqual(try read("agent/instructions.md"), "")
    }

    func testAMissingEntrypointIsNoInstructions() throws {
        XCTAssertNil(try compose())
    }

    func testRefsAreIncludedOnceInOrderAndCommentsAndCodeAreLeftOut() throws {
        try write("""
            Main. See @a.md, and @sub/b.md.
            <!-- a note with @c.md -->
            Mail me@example.com. Not `@c.md` either.
            ```
            @c.md
            ```
            @missing.md
            """, "agent/instructions.md")
        try write("A, which needs @sub/b.md", "agent/a.md")
        try write("B, back to @../a.md and @../instructions.md", "agent/sub/b.md")
        try write("C", "agent/c.md")
        let text = try XCTUnwrap(try compose())
        XCTAssertFalse(text.contains("a note"))
        XCTAssertFalse(text.contains("\nC"))
        XCTAssertTrue(text.hasSuffix("@missing.md\n\nA, which needs @sub/b.md\n\nB, back to @../a.md and @../instructions.md"),
                      text)
    }

    func testIncludesStopFiveLevelsDown() throws {
        try write("@1.md", "agent/instructions.md")
        for level in 1...7 { try write("L\(level) @\(level + 1).md", "agent/\(level).md") }
        let text = try XCTUnwrap(try compose())
        XCTAssertTrue(text.contains("L5"))
        XCTAssertFalse(text.contains("L6"))
    }

    func testConstsFillTheirNamesAndUnknownNamesStay() throws {
        try write("Warn past {{CONCURRENCY_WARNING}}; keep {{OTHER}}. @more.md", "agent/instructions.md")
        try write("Also {{CONCURRENCY_WARNING}}.", "agent/more.md")
        try write("# Settings\n\nNotes: here.\n- CONCURRENCY_WARNING: 8\n<!-- OTHER: 1 -->\n", "agent/consts.md")
        XCTAssertEqual(try compose(), "Warn past 8; keep {{OTHER}}. @more.md\n\nAlso 8.")
    }

    func testSeedingLeavesConstsNamesAndWritesConstsOnItsOwn() throws {
        try write("A {{tools}} B {{CONCURRENCY_WARNING}}", "t/instructions.md")
        try write("CONCURRENCY_WARNING: 8\n", "t/consts.md")
        try write("tools", "t/codex/tools.md")
        try write("mine", "agent/instructions.md")
        XCTAssertTrue(try seed())
        XCTAssertEqual(try read("agent/instructions.md"), "mine")
        XCTAssertEqual(try read("agent/consts.md"), "CONCURRENCY_WARNING: 8\n")
        try FileManager.default.removeItem(at: base.appendingPathComponent("agent/instructions.md"))
        XCTAssertTrue(try seed())
        XCTAssertEqual(try read("agent/instructions.md"), "A tools B {{CONCURRENCY_WARNING}}")
        XCTAssertEqual(try compose(), "A tools B 8")
    }

    func testPartsNestAndWorkersMdComesFromTheWorkersFolder() throws {
        try write("# Shared\n{{tools}}\n{{staying}}\n", "t/instructions.md")
        try write("## Free\n- first\n{{turns}}\n- last", "t/staying.md")
        try write("tools", "t/codex/tools.md")
        try write("- pool", "t/codex/turns.md")
        try write("## Worker", "t/codex/workers/staying.md")
        XCTAssertTrue(try seed())
        XCTAssertEqual(try read("agent/instructions.md"), "# Shared\ntools\n## Free\n- first\n- pool\n- last\n")
        XCTAssertEqual(try read("agent/workers.md"), "# Shared\ntools\n## Worker\n")
    }

    func testSharedFilesAreRewrittenFromTheTemplateWhenTheyDiffer() throws {
        try write("new rule", "t/toasts.md")
        let templates = base.appendingPathComponent("t")
        let agents = base.appendingPathComponent("agents")
        XCTAssertTrue(try Instructions.refreshShared(into: agents, templates: templates))
        XCTAssertEqual(try read("agents/toasts.md"), "new rule")
        XCTAssertFalse(try Instructions.refreshShared(into: agents, templates: templates))

        try write("old rule", "agents/toasts.md")
        XCTAssertTrue(try Instructions.refreshShared(into: agents, templates: templates))
        XCTAssertEqual(try read("agents/toasts.md"), "new rule")

        // No template: the file stays.
        XCTAssertFalse(try Instructions.refreshShared(into: agents, templates: base.appendingPathComponent("none")))
        XCTAssertEqual(try read("agents/toasts.md"), "new rule")
    }

    // The toast rule is in the one shared file, which the template every
    // agent and Codex worker is seeded from includes, and nowhere else.
    func testTheShippedToastRuleIsOneSharedFileTheTemplateIncludes() throws {
        let agent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/agent", isDirectory: true)
        let rule = try String(contentsOf: agent.appendingPathComponent("toasts.md"), encoding: .utf8)
        XCTAssertTrue(rule.contains("under 140 characters"))
        let template = try String(contentsOf: agent.appendingPathComponent("instructions.md"), encoding: .utf8)
        XCTAssertTrue(template.contains("@~/.agents/sirius/toasts.md"))
        XCTAssertFalse(template.contains("Keep toasts"))
        XCTAssertEqual(Instructions.shared, ["toasts.md"])
    }

    func testNoWorkersMdWithoutAWorkersFolder() throws {
        try write("{{tools}}", "t/instructions.md")
        XCTAssertTrue(try seed())
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("agent/workers.md").path))
    }

    func testTheManualsCopyIsRewrittenWhenItDiffersAndOtherFilesAreLeft() throws {
        try write("# Manual", "t/manual/index.md")
        try write("pdf", "t/manual/Sirius Manual.pdf")
        let templates = base.appendingPathComponent("t")
        let copy = base.appendingPathComponent("support/manual")
        XCTAssertTrue(try Instructions.refreshManual(into: copy, templates: templates))
        XCTAssertEqual(try read("support/manual/index.md"), "# Manual")
        XCTAssertEqual(try read("support/manual/Sirius Manual.pdf"), "pdf")
        XCTAssertFalse(try Instructions.refreshManual(into: copy, templates: templates))

        try write("stale", "support/manual/index.md")
        try write("mine", "support/manual/state.json")
        XCTAssertTrue(try Instructions.refreshManual(into: copy, templates: templates))
        XCTAssertEqual(try read("support/manual/index.md"), "# Manual")
        XCTAssertEqual(try read("support/manual/state.json"), "mine")

        // No bundled manual: nothing is written.
        XCTAssertFalse(try Instructions.refreshManual(into: copy, templates: base.appendingPathComponent("none")))
    }

    private func offer() throws -> Bool {
        try Instructions.offerManual(folder: base.appendingPathComponent("agent"),
                                     templates: base.appendingPathComponent("t"),
                                     marker: base.appendingPathComponent("support/agent/manual-offered"))
    }

    func testExistingInstructionsGainTheManualSectionOnceAndADeletedOneStaysDeleted() throws {
        try write("## The manual\n\nIt is at `x/manual/index.md`.\n", "t/manual.md")
        // No instructions yet: nothing happens, and it is not marked as done.
        XCTAssertFalse(try offer())
        try write("# Mine\n\nMy rules.\n", "agent/instructions.md")
        XCTAssertTrue(try offer())
        XCTAssertEqual(try read("agent/instructions.md"),
                       "# Mine\n\nMy rules.\n\n## The manual\n\nIt is at `x/manual/index.md`.\n")
        XCTAssertFalse(try offer())

        // The user deletes the section: it does not come back.
        try write("# Mine\n", "agent/instructions.md")
        XCTAssertFalse(try offer())
        XCTAssertEqual(try read("agent/instructions.md"), "# Mine\n")
    }

    func testInstructionsThatAlreadyNameTheManualAreLeftAsTheyAre() throws {
        try write("## The manual\n\nIt is at `x/manual/index.md`.\n", "t/manual.md")
        try write("# Mine\nSee manual/index.md, in my words.\n", "agent/instructions.md")
        XCTAssertFalse(try offer())
        XCTAssertEqual(try read("agent/instructions.md"), "# Mine\nSee manual/index.md, in my words.\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("support/agent/manual-offered").path))
    }

    // The shipped template carries the section for new agents, from the one
    // part an existing agent is offered, and Codex's workers are not told.
    func testTheShippedTemplateSeedsTheManualSection() throws {
        let agent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/agent", isDirectory: true)
        let folder = base.appendingPathComponent("agent")
        XCTAssertTrue(try Instructions.seed(folder: folder, template: agent.appendingPathComponent("instructions.md"),
                                            harness: agent.appendingPathComponent("codex")))
        let path = "~/Library/Application Support/Sirius/agents/manual/index.md"
        XCTAssertTrue(try read("agent/instructions.md").contains(path))
        XCTAssertFalse(try read("agent/workers.md").contains(path))
        XCTAssertFalse(try Instructions.offerManual(folder: folder, templates: agent,
                                                    marker: base.appendingPathComponent("support/agent/manual-offered")))
        // The manual's source is docs/manual; build-app.sh copies it into the bundle's agent folder.
        let docs = agent.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/manual/index.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.path))
    }
}
