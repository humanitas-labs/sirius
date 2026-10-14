import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class AgentRegistryTests: XCTestCase {
    private var registryDirectory: URL!

    override func setUpWithError() throws {
        registryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: registryDirectory)
    }

    private func put(_ folder: String, json: String, instructions: String? = nil) throws {
        let directory = registryDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("agent.json"))
        if let instructions {
            try Data(instructions.utf8).write(to: directory.appendingPathComponent("instructions.md"))
        }
    }

    private func definition(agent: String, harness: String = "claude-code", executable: String = "/usr/local/bin/claude",
                            root: String = "/Users/me/code") -> String {
        """
        {"agent": "\(agent)", "name": "Claude", "harness": "\(harness)", "executable": "\(executable)",
         "root": "\(root)", "extra": {"ignored": true}}
        """
    }

    func testLoadsGoodEntriesBesideBadOnes() throws {
        try put("claude", json: definition(agent: "claude"), instructions: "Be brief.\n")
        try put("codex", json: definition(agent: "codex", harness: "codex"))
        try put("broken", json: "{ not json")
        try put("gemini", json: definition(agent: "gemini", harness: "gemini-cli"))
        try put("relexec", json: definition(agent: "relexec", executable: "bin/claude"))
        try put("relroot", json: definition(agent: "relroot", root: "~/code"))
        try put("Bad_Id", json: definition(agent: "Bad_Id"))
        try put("noname", json: #"{"agent": "noname", "harness": "codex", "executable": "/x", "root": "/y"}"#)
        try FileManager.default.createDirectory(at: registryDirectory.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory.appendingPathComponent(".hidden"),
                                                withIntermediateDirectories: true)
        try Data().write(to: registryDirectory.appendingPathComponent(".DS_Store"))

        let scan = AgentRegistry(directory: registryDirectory).loadAll()

        XCTAssertEqual(scan.agents.map(\.registration.agent), ["claude", "codex"])
        XCTAssertEqual(scan.agents[0].registration.harness, .claudeCode)
        XCTAssertEqual(scan.agents[0].instructions, "Be brief.")
        XCTAssertNil(scan.agents[1].instructions)
        XCTAssertEqual(scan.agents[1].registration.harness, .codex)

        let failures = Dictionary(uniqueKeysWithValues: scan.failures.map { ($0.folder, $0.error) })
        XCTAssertEqual(Set(failures.keys), ["broken", "gemini", "relexec", "relroot", "Bad_Id", "noname", "empty"])
        XCTAssertEqual(failures["broken"], .malformed("agent.json is not a JSON object"))
        XCTAssertEqual(failures["gemini"], .unknownHarness("gemini-cli"))
        XCTAssertEqual(failures["relexec"], .relativeExecutable("bin/claude"))
        XCTAssertEqual(failures["relroot"], .relativeRoot("~/code"))
        XCTAssertEqual(failures["Bad_Id"], .invalidId("Bad_Id"))
        XCTAssertEqual(failures["noname"], .malformed("missing name"))
        XCTAssertEqual(failures["empty"], .missingDefinition)
    }

    func testFolderNameMustEqualAgent() throws {
        try put("claude-2", json: definition(agent: "claude"))
        let scan = AgentRegistry(directory: registryDirectory).loadAll()
        XCTAssertTrue(scan.agents.isEmpty)
        XCTAssertEqual(scan.failures, [RegistryFailure(folder: "claude-2",
                                                       error: .folderMismatch(folder: "claude-2", agent: "claude"))])
    }

    func testModelAndEffortAreOptionalAndBlankMeansAbsent() throws {
        let full = try AgentRegistry.parse(Data(#"{"agent":"a","name":"A","harness":"codex","executable":"/x","root":"/r","model":"gpt-6-astra","effort":"high"}"#.utf8)).get()
        XCTAssertEqual(full.model, "gpt-6-astra")
        XCTAssertEqual(full.effort, "high")
        let blank = try AgentRegistry.parse(Data(#"{"agent":"a","name":"A","harness":"codex","executable":"/x","root":"/r","model":" ","effort":null}"#.utf8)).get()
        XCTAssertNil(blank.model)
        XCTAssertNil(blank.effort)
        XCTAssertThrowsError(try AgentRegistry.parse(Data(#"{"agent":"a","name":"A","harness":"codex","executable":"/x","root":"/r","model":5}"#.utf8)).get())
    }

    func testFastIsOptionalAndMustBeABool() throws {
        let base = #"{"agent":"a","name":"A","harness":"codex","executable":"/x","root":"/r""#
        XCTAssertEqual(try AgentRegistry.parse(Data((base + #","fast":true}"#).utf8)).get().fast, true)
        XCTAssertNil(try AgentRegistry.parse(Data((base + "}").utf8)).get().fast)
        XCTAssertThrowsError(try AgentRegistry.parse(Data((base + #","fast":"yes"}"#).utf8)).get())
    }

    func testIconIsTheFirstFormPresent() throws {
        try put("claude", json: definition(agent: "claude"))
        let registry = AgentRegistry(directory: registryDirectory)
        XCTAssertNil(registry.icon(agent: "claude"))
        let folder = registryDirectory.appendingPathComponent("claude", isDirectory: true)
        try Data().write(to: folder.appendingPathComponent("icon.png"))
        XCTAssertEqual(registry.icon(agent: "claude")?.lastPathComponent, "icon.png")
        try Data().write(to: folder.appendingPathComponent("icon.svg"))
        XCTAssertEqual(registry.icon(agent: "claude")?.lastPathComponent, "icon.svg")
        XCTAssertNil(registry.icon(agent: "codex"))
    }

    func testMissingRegistryIsEmpty() {
        let scan = AgentRegistry(directory: registryDirectory.appendingPathComponent("absent")).loadAll()
        XCTAssertEqual(scan, RegistryScan(agents: [], failures: []))
    }

    func testWriteRoundTripsPrettyAndSorted() throws {
        let registry = AgentRegistry(directory: registryDirectory)
        let registration = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                             executable: "/opt/homebrew/bin/claude", root: "/Users/me/code",
                                             voice: "Ava")
        try registry.write(registration)

        let file = registryDirectory.appendingPathComponent("claude/agent.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "agent" : "claude",
          "executable" : "/opt/homebrew/bin/claude",
          "harness" : "claude-code",
          "name" : "Claude",
          "root" : "/Users/me/code",
          "voice" : "Ava"
        }

        """)

        let loaded = try registry.load(agent: "claude").get()
        XCTAssertEqual(loaded.registration, registration)
        XCTAssertNil(loaded.instructions)

        // Overwrite in place; no temporary files left beside it.
        var changed = registration
        changed.voice = nil
        try registry.write(changed)
        XCTAssertEqual(try registry.load(agent: "claude").get().registration, changed)
        let files = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["agent.json"])
    }

    func testWriteRefusesInvalidRegistration() {
        let registry = AgentRegistry(directory: registryDirectory)
        let bad = AgentRegistration(agent: "../x", name: "X", harness: .codex, executable: "/x", root: "/y")
        XCTAssertThrowsError(try registry.write(bad)) { error in
            XCTAssertEqual(error as? RegistryError, .invalidId("../x"))
        }
        let relative = AgentRegistration(agent: "x", name: "X", harness: .codex, executable: "x", root: "/y")
        XCTAssertThrowsError(try registry.write(relative))
    }

    // The harness's default mark lands as icon.svg when the folder has no
    // icon, and an icon already there, of any form, is never replaced.
    func testSeedIconCopiesTheDefaultOnlyWhenAbsent() throws {
        let marks = registryDirectory.appendingPathComponent(".marks", isDirectory: true)
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        try Data("<svg>claude</svg>".utf8).write(to: marks.appendingPathComponent("claude-code.svg"))
        try Data("<svg>codex</svg>".utf8).write(to: marks.appendingPathComponent("codex.svg"))
        let registry = AgentRegistry(directory: registryDirectory)

        try put("claude", json: definition(agent: "claude"))
        XCTAssertTrue(try registry.seedIcon(agent: "claude", harness: .claudeCode, marks: marks))
        let seeded = registryDirectory.appendingPathComponent("claude/icon.svg")
        XCTAssertEqual(try String(contentsOf: seeded, encoding: .utf8), "<svg>claude</svg>")
        XCTAssertEqual(registry.icon(agent: "claude"), seeded)

        // Their own icon.svg stays.
        try Data("<svg>mine</svg>".utf8).write(to: seeded)
        XCTAssertFalse(try registry.seedIcon(agent: "claude", harness: .claudeCode, marks: marks))
        XCTAssertEqual(try String(contentsOf: seeded, encoding: .utf8), "<svg>mine</svg>")

        // So does an icon.png: no icon.svg is added beside it.
        try put("codex", json: definition(agent: "codex", harness: "codex"))
        let png = registryDirectory.appendingPathComponent("codex/icon.png")
        try Data([0x89, 0x50]).write(to: png)
        XCTAssertFalse(try registry.seedIcon(agent: "codex", harness: .codex, marks: marks))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryDirectory.appendingPathComponent("codex/icon.svg").path))

        // No default for the harness: nothing is written.
        let empty = registryDirectory.appendingPathComponent(".empty", isDirectory: true)
        try put("other", json: definition(agent: "other", harness: "codex"))
        XCTAssertFalse(try registry.seedIcon(agent: "other", harness: .codex, marks: empty))
        XCTAssertNil(registry.icon(agent: "other"))
    }

    func testDefaultIconIsNamedForTheHarness() {
        let marks = URL(fileURLWithPath: "/marks", isDirectory: true)
        XCTAssertEqual(AgentRegistry.defaultIcon(harness: .claudeCode, marks: marks).path, "/marks/claude-code.svg")
        XCTAssertEqual(AgentRegistry.defaultIcon(harness: .codex, marks: marks).path, "/marks/codex.svg")
    }

    // packaging/marks has a default mark for every harness.
    func testEveryHarnessShipsADefaultMark() {
        let marks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../packaging/marks", isDirectory: true).standardized
        for harness in AgentRegistration.Harness.allCases {
            let url = AgentRegistry.defaultIcon(harness: harness, marks: marks)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
