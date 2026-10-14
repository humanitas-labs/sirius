import XCTest
@testable import SiriusCore

final class DictationRouterTests: XCTestCase {
    let agents = [
        DictationAddress.forAgent(id: "claude", name: "Claude"),
        DictationAddress.forAgent(id: "codex", name: "Codex"),
        DictationAddress(agent: "dev", spoken: ["dev", "dev box"]),
    ]

    func check(_ cases: [(String, DictationRoute)], file: StaticString = #filePath, line: UInt = #line) {
        for (transcript, expected) in cases {
            XCTAssertEqual(DictationRouter.route(transcript, agents: agents), expected,
                           "routing \"\(transcript)\"", file: file, line: line)
        }
    }

    // The Dictate paste mode is gone for now (2026.10.11): "Dictate" is no
    // prefix, so the transcript goes whole to the selected agent.
    func testDictateIsNoPrefix() {
        check([
            ("Dictate: see you at six", .selected("Dictate: see you at six")),
            ("Dictate: Codex, run the tests", .selected("Dictate: Codex, run the tests")),
            ("Okay. Dictate: see you at six", .selected("Okay. Dictate: see you at six")),
        ])
    }

    func testAgentNeedsPunctuation() {
        check([
            ("Codex, run the tests", .agent("codex", "run the tests")),
            ("Codex: run the tests", .agent("codex", "run the tests")),
            ("Codex. Run the tests.", .agent("codex", "Run the tests.")),
            ("codex,run the tests", .agent("codex", "run the tests")),
            ("CLAUDE, What's next?", .agent("claude", "What's next?")),
            ("Codex failed the build again", .selected("Codex failed the build again")),
            ("Codex! Run the tests", .selected("Codex! Run the tests")),
            ("Ask Codex, then Claude, to review", .selected("Ask Codex, then Claude, to review")),
            ("Codexes, everywhere", .selected("Codexes, everywhere")),
        ])
    }

    func testGreetings() {
        check([
            ("Hey Claude, what's next?", .agent("claude", "what's next?")),
            ("Hey, Claude, what's next?", .agent("claude", "what's next?")),
            ("OK Codex: run the tests", .agent("codex", "run the tests")),
            ("Hey there, Claude", .selected("Hey there, Claude")),
            ("Okay, run the tests", .selected("Okay, run the tests")),
            ("Hey Claude what's next", .selected("Hey Claude what's next")),
        ])
    }

    func testMishearingsAndMultiWordForms() {
        check([
            ("Cloud, what's next?", .agent("claude", "what's next?")),
            ("clawed: summarise the thread", .agent("claude", "summarise the thread")),
            ("Clod. Stop.", .agent("claude", "Stop.")),
            ("Codecs, run the tests", .agent("codex", "run the tests")),
            ("Code X, run the tests", .agent("codex", "run the tests")),
            ("Code-X, run the tests", .agent("codex", "run the tests")),
            ("code  x: run the tests", .agent("codex", "run the tests")),
            ("Dev box, restart", .agent("dev", "restart")),
            ("Dev, restart", .agent("dev", "restart")),
            ("Cloud storage is full", .selected("Cloud storage is full")),
        ])
    }

    func testEmptyBodyAndEmptyInput() {
        check([
            ("Claude.", .agent("claude", "")),
            ("Hey Codex,", .agent("codex", "")),
            ("Claude", .selected("Claude")),
            ("", .selected("")),
            ("   ", .selected("")),
        ])
    }

    func testUnknownNamesStayWithTheSelectedAgent() {
        check([
            ("Gemini, run the tests", .selected("Gemini, run the tests")),
            ("Run the tests", .selected("Run the tests")),
            ("  Run the tests.  ", .selected("Run the tests.")),
        ])
        XCTAssertEqual(DictationRouter.route("Claude, hi", agents: []), .selected("Claude, hi"))
    }

    func testLongestFormWinsThenFirstAgent() {
        let code = DictationAddress(agent: "code", spoken: ["code"])
        let codex = DictationAddress.forAgent(id: "codex", name: "Codex")
        XCTAssertEqual(DictationRouter.route("Code x, go", agents: [code, codex]), .agent("codex", "go"))
        XCTAssertEqual(DictationRouter.route("Code, go", agents: [code, codex]), .agent("code", "go"))
        let twin = DictationAddress(agent: "twin", spoken: ["claude"])
        XCTAssertEqual(DictationRouter.route("Claude, go", agents: [twin] + agents), .agent("twin", "go"))
    }

    func testForAgent() {
        XCTAssertEqual(DictationAddress.forAgent(id: "claude", name: "Claude"),
                       DictationAddress(agent: "claude", spoken: ["claude", "cloud", "clawed", "clod"]))
        XCTAssertEqual(DictationAddress.forAgent(id: "rev", name: "Reviewer"),
                       DictationAddress(agent: "rev", spoken: ["rev", "reviewer"]))
        XCTAssertEqual(DictationAddress.forAgent(id: "cx", name: "Codex").spoken, ["cx", "codex", "codecs", "code x"])
    }
}
