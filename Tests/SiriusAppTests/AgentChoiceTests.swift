import XCTest
import SiriusAdapters
import SiriusProtocol
@testable import SiriusApp

// A new registration starts Claude and Codex at effort low; an
// existing one keeps the effort it has.
@MainActor
final class AgentChoiceTests: XCTestCase {
    private func choice(_ harness: AgentRegistration.Harness, current: AgentRegistration? = nil) -> AgentChoice {
        let choice = AgentChoice(harness: harness, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        return choice
    }

    func testClaudeDefaultsToLowEffort() {
        XCTAssertEqual(AgentChoice.defaultEffort(.claudeCode), "low")
    }

    func testCodexDefaultsToLowEffort() {
        XCTAssertEqual(AgentChoice.defaultEffort(.codex), "low")
    }

    func testExistingRegistrationKeepsItsEffort() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                        executable: "/bin/sh", root: "/tmp/work", effort: "high")
        XCTAssertEqual(choice(.claudeCode, current: current).registration?.effort, "high")
    }

    // A new agent works in its harness's trusted folder with
    // nothing chosen.
    func testANewAgentTakesItsTrustedFolder() {
        let agent = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/Users/u/work")
        XCTAssertTrue(agent.usesTrusted, "trusted while the CLI is looked for")
        agent.simulateFound("/bin/sh")
        XCTAssertTrue(agent.usesTrusted)
        XCTAssertEqual(agent.registration?.root, "/Users/u/work")
        XCTAssertEqual(agent.registration?.harness, .codex)
    }

    func testAnExistingAgentKeepsItsFolderOverATrustedOne() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                        executable: "/bin/sh", root: "/Users/u/mine")
        let agent = AgentChoice(harness: .claudeCode, current: current, detector: AgentDetector(),
                                trusted: "/Users/u/other")
        agent.simulateFound("/bin/sh")
        XCTAssertFalse(agent.usesTrusted)
        XCTAssertEqual(agent.registration?.root, "/Users/u/mine")
    }

    func testWithoutTheCLIOrATrustedFolderNothingIsUsed() {
        let missing = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/Users/u/work")
        missing.simulateMissing()
        XCTAssertFalse(missing.usesTrusted)
        XCTAssertNil(missing.registration)
        XCTAssertNil(choice(.claudeCode).registration, "no folder, no registration")
    }
}

// What the Settings window shows of an agent and writes for it.
@MainActor
final class AgentChoiceSettingsTests: XCTestCase {
    // A trusted folder's chip makes it the workspace, which the next save
    // writes; the home folder and a missing folder are refused.
    func testATrustedFolderBecomesTheWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sirius-trusted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = registered(.claudeCode)
        claude.use(folder.path)
        XCTAssertEqual(claude.root, folder.path)
        XCTAssertEqual(claude.registration?.root, folder.path)
        claude.use(NSHomeDirectory())
        claude.use("/no/such/folder")
        XCTAssertEqual(claude.root, folder.path)
    }

    private func registered(_ harness: AgentRegistration.Harness, model: String? = nil, effort: String? = "low",
                            root: String = "/Users/u/notes") -> AgentChoice {
        let current = AgentRegistration(agent: AgentChoice.id(harness), name: AgentChoice.name(harness),
                                        harness: harness, executable: "/bin/sh", root: root,
                                        model: model, effort: effort)
        let choice = AgentChoice(harness: harness, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        return choice
    }

    func testSummaryNamesWorkspaceModelAndEffort() {
        XCTAssertEqual(registered(.claudeCode).settingsSummary, "notes · Default model · Low effort")
        XCTAssertEqual(registered(.claudeCode, model: "claude-opus-5-5", effort: "xhigh").settingsSummary,
                       "notes · Opus 5.5 · Extra high effort")
        XCTAssertEqual(registered(.codex, effort: nil).settingsSummary, "notes · Default model · Default effort")
    }

    func testSummaryWithoutWorkspaceOrCLI() {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        new.simulateFound("/bin/sh")
        XCTAssertEqual(new.settingsSummary, "No workspace yet")
        let missing = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        missing.simulateMissing()
        XCTAssertEqual(missing.settingsSummary, "Not installed")
    }

    func testEffortOptionsPerHarnessKeepAHandWrittenOne() {
        XCTAssertEqual(registered(.claudeCode).effortOptions, [nil, "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(registered(.codex).effortOptions, [nil, "minimal", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(registered(.codex, effort: "turbo").effortOptions.last, "turbo")
    }

    func testModelOptionsAreDefaultTheMainModelsAndAHandWrittenOne() {
        let claude = [nil, "claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        XCTAssertEqual(registered(.claudeCode).modelOptions, claude)
        XCTAssertEqual(registered(.claudeCode, model: "claude-opus-5-5").modelOptions, claude)
        XCTAssertEqual(registered(.claudeCode, model: "my-own-model").modelOptions, claude + ["my-own-model"])
        XCTAssertEqual(registered(.codex).modelOptions.count, 6)
        XCTAssertEqual(registered(.museCode).modelOptions, [nil])
        XCTAssertEqual(registered(.museCode, model: "muse-x").modelOptions, [nil, "muse-x"])
    }

    func testAModelIsShownByItsMakersName() {
        let claude = registered(.claudeCode)
        XCTAssertEqual(claude.modelLabel(nil), "Default")
        XCTAssertEqual(claude.modelLabel("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(claude.modelLabel("my-own-model"), "my-own-model")
        XCTAssertEqual(registered(.codex).modelLabel("gpt-6.1-sol"), "GPT-6.1 Sol")
        // Another harness's id is not this one's model.
        XCTAssertEqual(registered(.codex).modelLabel("claude-opus-5-5"), "claude-opus-5-5")
    }

    func testCursorAndAntigravityListModelsOfSeveralMakers() {
        let cursor = registered(.cursor)
        XCTAssertEqual(cursor.modelOptions.first, .some(nil))
        XCTAssertEqual(cursor.modelLabel("claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(cursor.modelMaker("claude-opus-5-5"), .anthropic)
        XCTAssertEqual(cursor.modelMaker("gpt-5.6-sol"), .openai)
        XCTAssertEqual(cursor.modelMaker("gemini-4-neon"), .google)
        XCTAssertEqual(cursor.modelMaker("grok-4.7"), .xai)
        XCTAssertEqual(cursor.modelMaker("muse-wonder-1.0"), .meta)
        XCTAssertEqual(cursor.modelMaker("composer-2.5"), .cursor)
        XCTAssertNil(cursor.modelMaker(nil))
        XCTAssertNil(cursor.modelMaker("my-own-model"))
        let gemini = registered(.antigravity)
        XCTAssertEqual(gemini.modelLabel("gemini-3.8-flash"), "Gemini 3.8 Flash")
        XCTAssertEqual(gemini.modelMaker("claude-sonnet-4-6"), .anthropic)
        // One maker, no logo.
        XCTAssertNil(registered(.claudeCode).modelMaker("claude-opus-5-5"))
        for harness in AgentRegistration.Harness.allCases {
            let ids = AgentChoice.models(harness).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(harness) lists a model twice")
        }
    }

    // Every maker a model names has its logo file.
    func testEveryMakerHasALogoFile() {
        let makers = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packaging/marks/makers")
        for maker in AgentChoice.Maker.allCases {
            let file = makers.appendingPathComponent("\(maker.rawValue).svg")
            XCTAssertNotNil(NSImage(contentsOf: file), "\(maker.rawValue).svg")
        }
    }

    @MainActor
    func testAnUntouchedSeededIconGivesWayAndAPersonsOwnIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seeded = folder.appendingPathComponent("seeded.svg")
        try Data("<svg>\n  <!-- simple-icons 15.16.0 (CC0), icons/meta.svg -->\n</svg>".utf8).write(to: seeded)
        let own = folder.appendingPathComponent("own.svg")
        try Data("<svg><path d=\"M0 0h24v24H0z\"/></svg>".utf8).write(to: own)
        XCTAssertTrue(AgentMarks.isSeededCopy(seeded, harness: .museCode))
        XCTAssertFalse(AgentMarks.isSeededCopy(own, harness: .museCode))

        // A png copy is seeded only when it is the bundled default itself;
        // one drawn by hand, or another harness's, is the person's own.
        let marks = AgentMarks.directory
        guard let defaultPNG = try? Data(contentsOf: marks.appendingPathComponent("opencode.png")) else {
            return XCTFail("packaging/marks/opencode.png is missing")
        }
        let copied = folder.appendingPathComponent("copied.png")
        try defaultPNG.write(to: copied)
        let drawn = folder.appendingPathComponent("drawn.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: drawn)
        XCTAssertTrue(AgentMarks.isSeededCopy(copied, harness: .opencode))
        XCTAssertFalse(AgentMarks.isSeededCopy(drawn, harness: .opencode))
        XCTAssertFalse(AgentMarks.isSeededCopy(copied, harness: .claudeCode))
    }

    func testCursorTakesNoEffortAndTheOthersDo() {
        XCTAssertFalse(registered(.cursor).takesEffort)
        XCTAssertEqual(registered(.cursor, effort: nil).effortOptions, [nil])
        XCTAssertTrue(registered(.antigravity).takesEffort)
        XCTAssertTrue(registered(.claudeCode).takesEffort)
    }

    func testRegistrationCarriesTheEditsAndKeepsTheRest() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode, executable: "/bin/sh",
                                        root: "/Users/u/w", voice: "Samantha", effort: "low",
                                        consolidateAfterIdle: 30)
        let choice = AgentChoice(harness: .claudeCode, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        XCTAssertEqual(choice.registration, current, "nothing changed, nothing to write")
        choice.model = "claude-opus-5-5"
        choice.effort = "max"
        choice.fast = true
        let written = choice.registration
        XCTAssertEqual(written?.model, "claude-opus-5-5")
        XCTAssertEqual(written?.effort, "max")
        XCTAssertEqual(written?.fast, true)
        XCTAssertEqual(written?.voice, "Samantha")
        XCTAssertEqual(written?.consolidateAfterIdle, 30)
    }

    func testWorkspaceNameIsCutInTheMiddle() {
        XCTAssertEqual(registered(.codex, root: "/Users/u/sirius").workspaceName, "sirius")
        XCTAssertEqual(registered(.codex, root: "/Users/u/a-very-long-workspace-name").workspaceName,
                       "a-very-lon…pace-name")
    }

    func testSavedMakesItRegistered() throws {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        XCTAssertFalse(new.isRegistered)
        new.saved(AgentRegistration(agent: "codex", name: "Codex", harness: .codex, executable: "/bin/sh", root: "/w"))
        XCTAssertTrue(new.isRegistered)
    }

    // A new Codex agent is registered with fast: true; one whose
    // agent.json leaves fast out stays so until it is turned off.
    func testCodexFastModeIsWrittenOnlyWhereItMatters() {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/w")
        new.simulateFound("/bin/sh")
        XCTAssertTrue(new.fast)
        XCTAssertEqual(new.registration?.fast, true)
        let existing = registered(.codex)
        XCTAssertTrue(existing.fast)
        XCTAssertNil(existing.registration?.fast, "left out, as it was")
        existing.fast = false
        XCTAssertEqual(existing.registration?.fast, false)
        let claude = AgentChoice(harness: .claudeCode, current: nil, detector: AgentDetector(), trusted: "/w")
        claude.simulateFound("/bin/sh")
        XCTAssertFalse(claude.fast)
        XCTAssertNil(claude.registration?.fast, "Claude stays as it was")
    }

    func testComposeTextFollowsTheRecording() {
        let shortcuts = ShortcutsModel(compose: .compose, holdKey: .fn)
        XCTAssertEqual(shortcuts.composeText, KeyComboText.string(.compose))
        shortcuts.simulate(.recording(hint: nil))
        XCTAssertEqual(shortcuts.composeText, "Press new shortcut…")
        shortcuts.simulate(.refused("Taken by macOS"))
        XCTAssertEqual(shortcuts.composeText, "Taken by macOS")
    }
}
