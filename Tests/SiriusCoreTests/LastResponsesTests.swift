import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

// The store behind `last` (LastResponses): what each agent last displayed,
// seeded from the logs at setup and recorded as the queue accepts displays.
final class LastResponsesTests: XCTestCase {
    private var base: URL!
    private let fixed: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_791_900_000) }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-last-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func log(agent: String) throws -> AgentLog {
        try AgentStorage(agent: agent, baseDirectory: base).openLog(now: fixed)
    }

    private func display(_ id: Int64, _ text: String, alert: Bool = false) -> Command {
        Command(agent: "claude", id: .number(id),
                call: .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: text))], alert: alert)),
                received: Date(timeIntervalSince1970: 1_791_900_100 + Double(id)))
    }

    private final class RefusingQueue: CommandQueue, @unchecked Sendable {
        func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
            .failure(RPCError(.queueFull, "never", data: ErrorData(method: command.call.method)))
        }
    }

    func testRecordLatestAndNewest() {
        let responses = LastResponses()
        XCTAssertNil(responses.latest(agent: "claude"))
        XCTAssertNil(responses.newest())

        responses.record(LastResponse(agent: "claude", alert: false, text: "one",
                                      at: Date(timeIntervalSince1970: 100)))
        responses.record(LastResponse(agent: "codex", alert: true, text: "two",
                                      at: Date(timeIntervalSince1970: 200)))
        responses.record(LastResponse(agent: "claude", alert: false, text: "three",
                                      at: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(responses.latest(agent: "claude")?.text, "three", "the latest wins")
        XCTAssertEqual(responses.latest(agent: "codex")?.alert, true)
        XCTAssertEqual(responses.newest()?.text, "three", "the newest across agents")

        responses.remove(agent: "claude")
        XCTAssertNil(responses.latest(agent: "claude"))
        XCTAssertEqual(responses.newest()?.text, "two")
    }

    // The logs seed the store at setup, from the recovery read each one
    // already runs; a log with no display clears what an earlier setup
    // might have left, and unregister takes the agent out.
    func testTheLogsSeedTheStore() async throws {
        let writer = try log(agent: "claude")
        try await writer.commandReceived(display(1, "pushed the branch"))

        let responses = LastResponses()
        let commands = LoggingCommandQueue(inner: RefusingQueue(), report: { _ in }, responses: responses)
        commands.register(try log(agent: "claude"), for: "claude")
        XCTAssertEqual(responses.latest(agent: "claude")?.text, "pushed the branch")

        // A log whose commands hold no display leaves nothing for `last`.
        let muse = try log(agent: "muse")
        try await muse.commandReceived(Command(
            agent: "muse", id: .number(1),
            call: .notify(NotifyParams(content: [.text(TextContent(text: "not a display"))])),
            received: Date(timeIntervalSince1970: 1_791_900_100)))
        commands.register(try log(agent: "muse"), for: "muse")
        XCTAssertNil(responses.latest(agent: "muse"))

        // A later open re-seeds; unregister takes the agent out.
        try await log(agent: "claude").commandReceived(display(2, "and the tests pass"))
        commands.register(try log(agent: "claude"), for: "claude")
        XCTAssertEqual(responses.latest(agent: "claude")?.text, "and the tests pass")
        commands.unregister(agent: "claude")
        XCTAssertNil(responses.latest(agent: "claude"))
    }
}
