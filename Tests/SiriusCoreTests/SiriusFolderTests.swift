import Foundation
import XCTest
@testable import SiriusCore

final class SiriusFolderTests: XCTestCase {
    // Stands in for the user's home; .agents in it is the shared folder.
    private var home: URL!
    private var agents: URL { home.appendingPathComponent(".agents") }
    private var alpha: URL { agents.appendingPathComponent("registry/alpha") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = agents.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: agents.appendingPathComponent(path), encoding: .utf8)
    }

    private func migrate() throws -> Bool {
        try SiriusFolder.migrate(agents: agents, agentFolders: [alpha], home: home)
    }

    func testMovesTheFilesAndRewritesThePathsThatNameThem() throws {
        try write("memory, cleaned per `~/.agents/gc.md`", "WMEM.md")
        try write("log", "wmem.log")
        try write("cleanup", "gc.md")
        try write("rule", "toasts.md")
        try write("Toasts: @~/.agents/toasts.md and memory @~/.agents/WMEM.md. @../../RULES.md", "registry/alpha/instructions.md")
        try write("Workers: @~/.agents/toasts.md", "registry/alpha/workers.md")
        try write("when (`~/.agents/WMEM.md`) grows\nWMEM_TOKEN_LIMIT: 2000\n", "registry/alpha/consts.md")
        // The user's own file, included by the instructions.
        try write("Mine: @~/.agents/WMEM.md, and ~/.agents/registry stays.", "RULES.md")

        XCTAssertTrue(try migrate())

        for name in SiriusFolder.files {
            XCTAssertNil(read(name), name)
            XCTAssertNotNil(read("sirius/" + name), name)
        }
        XCTAssertEqual(read("sirius/WMEM.md"), "memory, cleaned per `~/.agents/sirius/gc.md`")
        XCTAssertEqual(read("registry/alpha/instructions.md"),
                       "Toasts: @~/.agents/sirius/toasts.md and memory @~/.agents/sirius/WMEM.md. @../../RULES.md")
        XCTAssertEqual(read("registry/alpha/workers.md"), "Workers: @~/.agents/sirius/toasts.md")
        XCTAssertEqual(read("registry/alpha/consts.md"), "when (`~/.agents/sirius/WMEM.md`) grows\nWMEM_TOKEN_LIMIT: 2000\n")
        XCTAssertEqual(read("RULES.md"), "Mine: @~/.agents/sirius/WMEM.md, and ~/.agents/registry stays.")

        // Nothing left to do the second time.
        XCTAssertFalse(try migrate())
    }

    func testAFileAlreadyInTheSiriusFolderIsNotReplaced() throws {
        try write("old", "WMEM.md")
        try write("new", "sirius/WMEM.md")
        try write("old rule", "toasts.md")
        try write("new rule", "sirius/toasts.md")
        try write("@~/.agents/WMEM.md @~/.agents/toasts.md", "registry/alpha/instructions.md")

        XCTAssertTrue(try migrate())

        // The user's memory is left where it is, and so is the path to it;
        // the stale shared rule, which is the app's, is removed.
        XCTAssertEqual(read("WMEM.md"), "old")
        XCTAssertEqual(read("sirius/WMEM.md"), "new")
        XCTAssertNil(read("toasts.md"))
        XCTAssertEqual(read("sirius/toasts.md"), "new rule")
        XCTAssertEqual(read("registry/alpha/instructions.md"), "@~/.agents/WMEM.md @~/.agents/sirius/toasts.md")
    }

    func testARegistryElsewhereMovesItsFilesButLeavesPathsToTheUsersFolderAlone() throws {
        let other = home.appendingPathComponent("elsewhere")
        let agent = other.appendingPathComponent("registry/alpha")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try "memory".write(to: other.appendingPathComponent("WMEM.md"), atomically: true, encoding: .utf8)
        try "@~/.agents/WMEM.md".write(to: agent.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
        try write("the user's", "WMEM.md")

        XCTAssertTrue(try SiriusFolder.migrate(agents: other, agentFolders: [agent], home: home))

        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("sirius/WMEM.md"), encoding: .utf8), "memory")
        XCTAssertEqual(try String(contentsOf: agent.appendingPathComponent("instructions.md"), encoding: .utf8),
                       "@~/.agents/WMEM.md")
        XCTAssertEqual(read("WMEM.md"), "the user's")
    }

    func testNothingToMoveIsNothingWritten() throws {
        try write("@~/.agents/sirius/WMEM.md", "registry/alpha/instructions.md")
        XCTAssertFalse(try migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent("sirius").path))
    }
}
