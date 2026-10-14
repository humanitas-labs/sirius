import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class AgentDetectorTests: XCTestCase {
    func testTheLoginShellsAnswerWins() {
        let detector = AgentDetector(home: "/Users/u", shell: "/bin/zsh",
                                     isExecutable: { ["/custom/bin/claude", "/Users/u/.local/bin/claude"].contains($0) },
                                     lookUp: { _, command in command == "claude" ? "/custom/bin/claude" : nil })
        XCTAssertEqual(detector.find(.claudeCode), "/custom/bin/claude")
    }

    func testWithoutTheShellTheInstallLocationsAreSearchedInOrder() {
        let detector = AgentDetector(home: "/Users/u", shell: nil,
                                     isExecutable: { ["/opt/homebrew/bin/codex", "/Users/u/.bun/bin/codex"].contains($0) },
                                     lookUp: { _, _ in XCTFail("no shell"); return nil })
        XCTAssertEqual(detector.find(.codex), "/opt/homebrew/bin/codex")
        XCTAssertNil(detector.find(.claudeCode))
    }

    func testCodexIsFoundInsideTheChatGPTApp() {
        let bundled = "/Users/u/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let detector = AgentDetector(home: "/Users/u", shell: nil, isExecutable: { $0 == bundled },
                                     lookUp: { _, _ in nil })
        XCTAssertEqual(detector.find(.codex), bundled)
    }

    func testAShellAnswerThatIsNotAnExecutablePathIsIgnored() {
        // An alias or function prints a name, not a path.
        let detector = AgentDetector(home: "/Users/u", shell: "/bin/zsh",
                                     isExecutable: { $0 == "/Users/u/.local/bin/claude" },
                                     lookUp: { _, _ in "claude: aliased to claude --foo" })
        XCTAssertEqual(detector.find(.claudeCode), "/Users/u/.local/bin/claude")
    }

    func testTheHomeFolderAndTheDiskRootAreNotRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("adt-\(UUID().uuidString)")
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let detector = AgentDetector(home: home.path, shell: nil)
        XCTAssertFalse(detector.isAcceptableRoot(home.path))
        XCTAssertFalse(detector.isAcceptableRoot(home.path + "/"))
        XCTAssertFalse(detector.isAcceptableRoot("/"))
        XCTAssertFalse(detector.isAcceptableRoot(home.appendingPathComponent("missing").path))
        XCTAssertTrue(detector.isAcceptableRoot(project.path))
    }
}
