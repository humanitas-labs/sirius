import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class AgentLogTests: XCTestCase {
    private var baseDirectory: URL!
    private var storage: AgentStorage!
    // Whole seconds, so timestamps survive the millisecond format exactly.
    private let fixed: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_791_900_000) }

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-log-\(UUID().uuidString)", isDirectory: true)
        storage = try AgentStorage(agent: "claude", baseDirectory: baseDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func toast(_ id: Int64, _ text: String) -> Command {
        Command(agent: "claude", id: .number(id),
                call: .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: text))])),
                received: Date(timeIntervalSince1970: 1_791_900_100))
    }

    private func lines() throws -> [String] {
        try String(contentsOf: storage.logURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testAppendAndReadBack() async throws {
        let log = try storage.openLog(now: fixed)
        let attachment = Message.Attachment(path: "/tmp/a.png", mimeType: "image/png")
        try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "why?\n</sirius>",
                                              attachments: [attachment]))
        try await log.turnStarted(message: "m_1")
        try await log.commandReceived(toast(7, "Done"))
        try await log.turnEnded(message: "m_1", TurnEnd(session: "sess-1", outcome: .completed))
        try await log.messageReceived(Message(id: "m_2", agent: "claude", text: "again"))
        try await log.turnStarted(message: "m_2")
        try await log.turnEnded(message: "m_2", session: nil, outcome: .failed(reason: "exited 1"))

        let lines = try lines()
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines[0], #"{"at":"2026-10-13T14:00:00.000Z","attachments":[{"mimeType":"image/png","path":"/tmp/a.png"}],"event":"message","message":"m_1","text":"why?\n</sirius>","v":1}"#)
        XCTAssertEqual(lines[2], #"{"at":"2026-10-13T14:01:40.000Z","event":"command","message":"m_1","method":"display","params":{"kind":"toast","text":"Done"},"request":7,"v":1}"#)
        XCTAssertEqual(lines[3], #"{"at":"2026-10-13T14:00:00.000Z","event":"turn_ended","message":"m_1","outcome":"completed","session":"sess-1","v":1}"#)

        let contents = try AgentLog.read(storage.logURL)
        XCTAssertEqual(contents.skippedLines, [])
        XCTAssertEqual(contents.entries.map(\.event), [
            .message(id: "m_1", text: "why?\n</sirius>", attachments: [attachment]),
            .turnStarted(message: "m_1"),
            .command(message: "m_1", request: .number(7), method: .display,
                     params: CommandSummary(kind: .toast, text: "Done")),
            .turnEnded(message: "m_1", session: "sess-1", outcome: .completed),
            .message(id: "m_2", text: "again", attachments: []),
            .turnStarted(message: "m_2"),
            .turnEnded(message: "m_2", session: nil, outcome: .failed(reason: "exited 1")),
        ])
        XCTAssertTrue(contents.entries.allSatisfy { $0.version == 1 && $0.at.timeIntervalSince1970 >= 1_791_900_000 })
    }

    func testCommandsFiledAgainstCurrentThenMostRecentMessage() async throws {
        let log = try storage.openLog(now: fixed)

        // Before any turn there is nothing to file against.
        let none = try await log.commandReceived(toast(1, "early"))
        XCTAssertNil(none)

        try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "one"))
        try await log.turnStarted(message: "m_1")
        // m_2 queues behind the running turn; commands still go to m_1.
        try await log.messageReceived(Message(id: "m_2", agent: "claude", text: "two"))
        let during = try await log.commandReceived(toast(2, "during"))
        XCTAssertEqual(during, "m_1")

        try await log.turnEnded(message: "m_1", session: "s", outcome: .completed)
        // Late output after the turn ends: the most recent turn's message,
        // not the queued one that has not started.
        let late = try await log.commandReceived(toast(3, "late"))
        XCTAssertEqual(late, "m_1")

        try await log.turnStarted(message: "m_2")
        let next = try await log.commandReceived(toast(4, "next"))
        XCTAssertEqual(next, "m_2")

        let filed = try AgentLog.read(storage.logURL).entries.compactMap { entry -> String? in
            if case .command(let message, _, _, _) = entry.event { return message ?? "-" }
            return nil
        }
        XCTAssertEqual(filed, ["-", "m_1", "m_1", "m_2"])
    }

    func testTurnRulesAreEnforced() async throws {
        let log = try storage.openLog(now: fixed)
        await assertThrows(try await log.turnStarted(message: "m_x"), .unknownMessage("m_x"))
        try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "one"))
        await assertThrows(try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "dup")),
                           .duplicateMessage("m_1"))
        try await log.messageReceived(Message(id: "m_2", agent: "claude", text: "two"))
        try await log.turnStarted(message: "m_1")
        await assertThrows(try await log.turnStarted(message: "m_2"), .turnAlreadyRunning(current: "m_1"))
        await assertThrows(try await log.turnEnded(message: "m_2", session: nil, outcome: .completed),
                           .turnNotRunning("m_2"))
        try await log.turnEnded(message: "m_1", session: "s", outcome: .completed)
        await assertThrows(try await log.turnStarted(message: "m_1"), .messageFinished("m_1"))
        try await log.interrupted(message: "m_2", reason: "stopped by the user")
        await assertThrows(try await log.turnStarted(message: "m_2"), .messageFinished("m_2"))
    }

    // #1: a turn that started is interrupted, never rerun; a message that
    // never started is re-queued with its text and attachments.
    func testRestartInterruptsTheStartedTurnAndRequeuesTheRest() async throws {
        let attachment = Message.Attachment(path: "/tmp/demo.png", mimeType: "image/png")
        do {
            let log = try storage.openLog(now: fixed)
            try await log.messageReceived(Message(id: "m_done", agent: "claude", text: "finished"))
            try await log.turnStarted(message: "m_done")
            try await log.turnEnded(message: "m_done", session: "s", outcome: .completed)
            try await log.messageReceived(Message(id: "m_mid", agent: "claude", text: "crashes mid-turn"))
            try await log.turnStarted(message: "m_mid")
            try await log.messageReceived(Message(id: "m_q1", agent: "claude", text: "never started"))
            try await log.messageReceived(Message(id: "m_q2", agent: "claude", text: "nor this",
                                                  attachments: [attachment]))
            let pending = await log.pendingMessages
            XCTAssertEqual(pending, ["m_q1", "m_q2"])
        }

        // The app restarts.
        let reopened = try storage.openLog(now: fixed)
        XCTAssertEqual(reopened.recovered, ["m_mid"])
        XCTAssertEqual(reopened.requeued, [
            RequeuedMessage(id: "m_q1", text: "never started"),
            RequeuedMessage(id: "m_q2", text: "nor this", attachments: [attachment]),
        ])
        let current = await reopened.currentMessage
        let pending = await reopened.pendingMessages
        let recent = await reopened.mostRecentMessage
        XCTAssertNil(current)
        XCTAssertEqual(pending, ["m_q1", "m_q2"])
        XCTAssertEqual(recent, "m_mid")
        await assertThrows(try await reopened.turnStarted(message: "m_mid"), .messageFinished("m_mid"))
        try await reopened.turnStarted(message: "m_q1")

        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        let interrupted = events.compactMap { event -> String? in
            if case .interrupted(let message, let reason) = event {
                XCTAssertEqual(reason, AgentLog.restartReason)
                return message
            }
            return nil
        }
        XCTAssertEqual(interrupted, ["m_mid"])
        XCTAssertEqual(events.compactMap { if case .requeued(let m) = $0 { m } else { nil } }, ["m_q1", "m_q2"])
    }

    // #1: re-queued and still not started at the next restart, a message is
    // re-queued again, never marked interrupted.
    func testARequeuedMessageIsNotMarkedInterruptedOnTheNextOpen() async throws {
        do {
            let log = try storage.openLog(now: fixed)
            try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "one"))
        }
        let first = try storage.openLog(now: fixed)
        XCTAssertEqual(first.requeued.map(\.id), ["m_1"])
        XCTAssertEqual(first.recovered, [])

        // Sirius dies again before the turn starts.
        let second = try storage.openLog(now: fixed)
        XCTAssertEqual(second.requeued.map(\.id), ["m_1"])
        XCTAssertEqual(second.recovered, [])
        let pending = await second.pendingMessages
        XCTAssertEqual(pending, ["m_1"])

        let names = try AgentLog.read(storage.logURL).entries.map(\.event.name)
        XCTAssertEqual(names, ["message", "requeued", "requeued"])
        XCTAssertEqual(try lines()[1], #"{"at":"2026-10-13T14:00:00.000Z","event":"requeued","message":"m_1","v":1}"#)

        // Once delivered and ended, nothing is left to recover.
        try await second.turnStarted(message: "m_1")
        try await second.turnEnded(message: "m_1", session: "s", outcome: .completed)
        let third = try storage.openLog(now: fixed)
        XCTAssertEqual(third.requeued, [])
        XCTAssertEqual(third.recovered, [])
    }

    func testTruncatedLastLineIsTolerated() async throws {
        do {
            let log = try storage.openLog(now: fixed)
            try await log.messageReceived(Message(id: "m_1", agent: "claude", text: "one"))
            try await log.turnStarted(message: "m_1")
        }
        // A crash mid-write leaves half a line with no newline.
        let handle = try FileHandle(forWritingTo: storage.logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"at":"2026-10-14T05:20:00.000Z","event":"turn_en"#.utf8))
        try handle.close()

        let reopened = try storage.openLog(now: fixed)
        XCTAssertEqual(reopened.recovered, ["m_1"])
        try await reopened.messageReceived(Message(id: "m_2", agent: "claude", text: "two"))

        let contents = try AgentLog.read(storage.logURL)
        XCTAssertEqual(contents.skippedLines, [3])
        XCTAssertEqual(contents.entries.map(\.event.name), ["message", "turn_started", "interrupted", "message"])
        XCTAssertEqual(contents.entries.last?.event.message, "m_2")
    }

    func testCommandSummaryIsBounded() {
        let long = String(repeating: "é", count: CommandSummary.maxTextChars + 500)
        let summary = CommandSummary(.speak(SpeakParams(text: long, voice: "Ava")))
        XCTAssertEqual(summary.text?.codePoints, CommandSummary.maxTextChars)
        XCTAssertEqual(summary.truncated, true)
        XCTAssertEqual(summary.voice, "Ava")

        let notify = CommandSummary(.notify(NotifyParams(content: [.text(TextContent(text: "a")),
                                                                   .text(TextContent(text: "b"))],
                                                         title: "T")))
        XCTAssertEqual(notify, CommandSummary(text: "a\nb", title: "T"))
    }

    private func assertThrows(_ body: @autoclosure () async throws -> Void, _ expected: AgentLogError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentLogError, expected, file: file, line: line)
        }
    }
}
