import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class AgentStorageTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-storage-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func testRejectsInvalidAgentId() {
        XCTAssertThrowsError(try AgentStorage(agent: "../etc", baseDirectory: baseDirectory))
        XCTAssertThrowsError(try AgentStorage(agent: "", baseDirectory: baseDirectory))
    }

    func testStateRoundTrip() throws {
        let storage = try AgentStorage(agent: "claude", baseDirectory: baseDirectory)
        XCTAssertEqual(try storage.readState(), AgentState())

        try storage.writeState(AgentState(session: "sess-1"))
        XCTAssertEqual(try storage.readState(), AgentState(session: "sess-1"))
        try storage.writeState(AgentState(session: "sess-2"))
        XCTAssertEqual(try storage.readState(), AgentState(session: "sess-2"))

        XCTAssertEqual(try String(contentsOf: storage.stateURL, encoding: .utf8), "{\n  \"session\" : \"sess-2\"\n}\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path), ["state.json"])
    }

    func testMessageIds() {
        let ids = (0..<500).map { _ in MessageID.make() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("m_"))
            XCTAssertEqual(id.count, 10)
            XCTAssertTrue(MessageID.isSafeFolderName(id))
        }
        XCTAssertFalse(MessageID.isSafeFolderName(".."))
        XCTAssertFalse(MessageID.isSafeFolderName("m_1/2"))
        XCTAssertFalse(MessageID.isSafeFolderName(""))
    }

    func testSanitizesAttachmentNames() {
        XCTAssertEqual(AttachmentNaming.sanitize("screenshot.png"), "screenshot.png")
        XCTAssertEqual(AttachmentNaming.sanitize("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(AttachmentNaming.sanitize("a/b\\c:d.txt"), "a_b_c_d.txt")
        XCTAssertEqual(AttachmentNaming.sanitize(".bashrc"), "bashrc")
        XCTAssertEqual(AttachmentNaming.sanitize("..."), "attachment")
        XCTAssertEqual(AttachmentNaming.sanitize(""), "attachment")
        XCTAssertEqual(AttachmentNaming.sanitize("  bad\u{0}na\nme.txt "), "badname.txt")
        XCTAssertEqual(AttachmentNaming.sanitize("résumé 2026.pdf"), "résumé 2026.pdf")

        let long = String(repeating: "x", count: 400) + ".png"
        let cut = AttachmentNaming.sanitize(long)
        XCTAssertEqual(cut.utf8.count, AttachmentNaming.maxNameBytes)
        XCTAssertTrue(cut.hasSuffix(".png"))
    }

    func testAttachmentsAreWrittenAndDeduplicated() throws {
        let storage = try AgentStorage(agent: "claude", baseDirectory: baseDirectory)
        let message = MessageID.make()

        let first = try storage.addAttachment(data: Data("one".utf8), named: "note.txt", to: message,
                                              mimeType: "text/plain")
        let second = try storage.addAttachment(data: Data("two".utf8), named: "note.txt", to: message,
                                               mimeType: "text/plain")

        let source = baseDirectory.appendingPathComponent("source.txt")
        try Data("three".utf8).write(to: source)
        let third = try storage.addAttachment(copying: source, to: message, mimeType: "text/plain")
        let fourth = try storage.addAttachment(data: Data("four".utf8), named: "../note.txt", to: message,
                                               mimeType: "text/plain")

        let folder = try storage.attachmentsDirectory(for: message)
        XCTAssertEqual(first.path, folder.appendingPathComponent("note.txt").path)
        XCTAssertEqual(second.path, folder.appendingPathComponent("note-2.txt").path)
        XCTAssertEqual(third.path, folder.appendingPathComponent("source.txt").path)
        XCTAssertEqual(fourth.path, folder.appendingPathComponent("_note.txt").path)
        XCTAssertTrue(first.path.hasPrefix("/"))
        XCTAssertEqual(first.mimeType, "text/plain")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: first.path), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: second.path), encoding: .utf8), "two")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: third.path), encoding: .utf8), "three")

        XCTAssertThrowsError(try storage.addAttachment(data: Data(), named: "x", to: "../m", mimeType: "text/plain"))
    }
}
