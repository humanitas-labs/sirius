import XCTest
@testable import SiriusCore

final class DictationDestinationTests: XCTestCase {
    let agents = [
        DictationAddress.forAgent(id: "claude", name: "Claude"),
        DictationAddress.forAgent(id: "codex", name: "Codex"),
    ]

    func destination(_ text: String, open: Bool = false, selected: String? = "claude",
                     agents: [DictationAddress]? = nil) -> DictationDestination {
        DictationDestination.of(text, composerOpen: open, selected: selected, agents: agents ?? self.agents)
    }

    func paste(_ text: String, open: Bool = false, focused: Bool = false) -> DictationDestination {
        DictationDestination.of(text, mode: .paste, composerOpen: open, composerFocused: focused,
                                selected: "claude", agents: agents)
    }

    func testAPasteHoldGoesToTheCursorNeverToAnAgent() {
        XCTAssertEqual(paste("see you at six"), .cursor("see you at six"))
        // An agent's name is just a word to type.
        XCTAssertEqual(paste("Codex, run the tests"), .cursor("Codex, run the tests"))
        // An open composer behind another app leaves the paste to that app.
        XCTAssertEqual(paste("see you at six", open: true), .cursor("see you at six"))
    }

    func testAPasteHoldWithTheComposerFocusedGoesIntoIt() {
        XCTAssertEqual(paste("see you at six", open: true, focused: true), .composer("see you at six"))
    }

    func testAnEmptyPasteDoesNothing() {
        XCTAssertEqual(paste(""), .nothing)
        XCTAssertEqual(paste("  \n"), .nothing)
        XCTAssertEqual(paste(" ", open: true, focused: true), .nothing)
    }

    func testAPlainHoldIsUnchangedByFocus() {
        XCTAssertEqual(DictationDestination.of("Run the tests", mode: .agent, composerOpen: false, composerFocused: true,
                                               selected: "claude", agents: agents),
                       .agent("claude", "Run the tests"))
    }

    func testComposerOpenTakesEverything() {
        XCTAssertEqual(destination("Codex, run the tests", open: true), .composer("Codex, run the tests"))
        XCTAssertEqual(destination("  ", open: true), .nothing)
    }

    func testPrefixes() {
        // The Dictate paste mode is gone for now: the prefix is just words
        // for the selected agent.
        XCTAssertEqual(destination("Dictate: see you at six"), .agent("claude", "Dictate: see you at six"))
        XCTAssertEqual(destination("Codex, run the tests"), .agent("codex", "run the tests"))
        XCTAssertEqual(destination("Run the tests"), .agent("claude", "Run the tests"))
        XCTAssertEqual(destination("Run the tests", selected: "codex"), .agent("codex", "Run the tests"))
    }

    func testEmptyBodiesAreDropped() {
        XCTAssertEqual(destination("Codex,"), .nothing)
        XCTAssertEqual(destination(""), .nothing)
    }

    func testSelectedAgentIsNeverReplaced() {
        // A list that lacks the selected agent (stale, or the agent gone)
        // does not send to another: the send to it fails loudly instead.
        XCTAssertEqual(destination("Run the tests", selected: "dev"), .agent("dev", "Run the tests"))
        XCTAssertEqual(destination("Run the tests", selected: "codex",
                                   agents: [DictationAddress.forAgent(id: "claude", name: "Claude")]),
                       .agent("codex", "Run the tests"))
        // The 2026-10-11 message: Codex selected, no name spoken.
        XCTAssertEqual(destination("I'm just testing whether or not this goes to you correctly.", selected: "codex"),
                       .agent("codex", "I'm just testing whether or not this goes to you correctly."))
    }

    func testNothingSelectedFallsBackToTheFirst() {
        XCTAssertEqual(destination("Run the tests", selected: nil), .agent("claude", "Run the tests"))
    }

    func testNoAgentsKnown() {
        // Before the agents are read, the remembered agent is still tried.
        XCTAssertEqual(destination("Run the tests", selected: "claude", agents: []), .agent("claude", "Run the tests"))
        XCTAssertEqual(destination("Run the tests", selected: nil, agents: []), .nothing)
    }

    // The agent the pill's exit shows at release: the selected
    // one, else the first; none for a paste, the open composer or no agents.
    func testTheAgentAtRelease() {
        XCTAssertEqual(DictationDestination.agent(composerOpen: false, selected: "codex", agents: agents), "codex")
        XCTAssertEqual(DictationDestination.agent(composerOpen: false, selected: nil, agents: agents), "claude")
        XCTAssertNil(DictationDestination.agent(composerOpen: false, selected: nil, agents: []))
        XCTAssertNil(DictationDestination.agent(mode: .paste, composerOpen: false, selected: "claude", agents: agents))
        XCTAssertNil(DictationDestination.agent(composerOpen: true, selected: "claude", agents: agents))
    }
}
