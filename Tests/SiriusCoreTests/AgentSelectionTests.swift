import XCTest
@testable import SiriusCore

final class AgentSelectionTests: XCTestCase {
    func testAListThatLacksTheChoiceNeverReplacesIt() {
        // The composer's first load can read the host before it has started.
        var selection = AgentSelection(chosen: "codex")
        selection.listed = []
        XCTAssertEqual(selection.current, "codex")
        XCTAssertEqual(selection.chosen, "codex")
        selection.listed = ["claude"]
        XCTAssertEqual(selection.current, "codex")
        XCTAssertFalse(selection.isListed)
        selection.listed = ["claude", "codex"]
        XCTAssertEqual(selection.current, "codex")
        XCTAssertTrue(selection.isListed)
    }

    func testNoChoiceShowsTheFirstWithoutStoringIt() {
        var selection = AgentSelection(chosen: nil)
        XCTAssertNil(selection.current)
        selection.listed = ["claude", "codex"]
        XCTAssertEqual(selection.current, "claude")
        XCTAssertNil(selection.chosen)
        // A later list with a different first agent follows it.
        selection.listed = ["alpha", "claude", "codex"]
        XCTAssertEqual(selection.current, "alpha")
    }

    func testNextStepsAndBecomesTheChoice() {
        var selection = AgentSelection(chosen: nil, listed: ["claude", "codex"])
        XCTAssertEqual(selection.next(), "codex")
        XCTAssertEqual(selection.chosen, "codex")
        XCTAssertEqual(selection.next(), "claude")
        XCTAssertEqual(selection.next(), "codex")
    }

    func testNextFromAnUnlistedChoiceGoesToTheFirst() {
        var selection = AgentSelection(chosen: "dev", listed: ["claude", "codex"])
        XCTAssertEqual(selection.next(), "claude")
    }

    func testNextWithNothingListedKeepsTheChoice() {
        var selection = AgentSelection(chosen: "codex")
        XCTAssertNil(selection.next())
        XCTAssertEqual(selection.chosen, "codex")
    }

    func testChooseSelectsStraightThere() {
        var selection = AgentSelection(chosen: nil, listed: ["claude", "codex"])
        XCTAssertTrue(selection.choose("codex"))
        XCTAssertEqual(selection.current, "codex")
        XCTAssertFalse(selection.choose("codex"))
        XCTAssertEqual(selection.chosen, "codex")
    }
}
