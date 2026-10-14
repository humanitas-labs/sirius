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

    func testNoWorkersMdWithoutAWorkersFolder() throws {
        try write("{{tools}}", "t/instructions.md")
        XCTAssertTrue(try seed())
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("agent/workers.md").path))
    }
}
