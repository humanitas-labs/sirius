import Darwin
import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// A real Codex against the running Sirius.app's dev agent socket. Runs only
// with SIRIUS_LIVE_CODEX=1; it spends model turns and shows two toasts.
// SIRIUS_LIVE_CODEX_LOG=<file> keeps the JSON-RPC transcript.
final class CodexLiveTests: XCTestCase {
    private final class Transcript: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private static var userTempDirectory: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return count > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    }

    private static var helpers: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = packageRoot.appendingPathComponent(".build/debug")
        if FileManager.default.isExecutableFile(atPath: built.appendingPathComponent("sirius-mcp").path) {
            return built
        }
        return URL(fileURLWithPath: "/Applications/Sirius.app/Contents/Helpers")
    }

    // The sirius tool calls that finished, as (tool, status, arguments).
    private func siriusCalls(_ lines: [String]) -> [(tool: String, status: String, arguments: String)] {
        lines.compactMap { line -> (String, String, String)? in
            guard line.hasPrefix("<< "),
                  let message = try? JSONValue.parse(Data(line.dropFirst(3).utf8)),
                  message["method"]?.string == "item/completed",
                  let item = message["params"]?["item"], item["type"]?.string == "mcpToolCall",
                  item["server"]?.string == "sirius" else { return nil }
            let arguments = (try? String(decoding: JSONEncoder().encode(item["arguments"] ?? .null), as: UTF8.self)) ?? ""
            return (item["tool"]?.string ?? "", item["status"]?.string ?? "", arguments)
        }
    }

    private func deliver(_ adapter: CodexAdapter, _ message: Message) async throws -> TurnEnd {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 180_000_000_000)
            await adapter.stop()
        }
        defer { watchdog.cancel() }
        return try await adapter.deliver(message)
    }

    func testLiveCodexToastsAndResumes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIRIUS_LIVE_CODEX"] == "1",
                          "set SIRIUS_LIVE_CODEX=1 to run against a real Codex and Sirius.app")
        let socket = Self.userTempDirectory + "sirius/dev.sock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "Sirius.app is not serving \(socket)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sirius-t11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .codex, executable: "",
                                             root: root.path)
        print("live: helpers \(Self.helpers.path), socket \(socket), root \(root.path)")

        let transcript = Transcript()
        defer {
            if let path = ProcessInfo.processInfo.environment["SIRIUS_LIVE_CODEX_LOG"] {
                try? transcript.all.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        // Turn 1, on a new thread.
        let first = CodexAdapter(registration: registration, socketPath: socket, helpersDirectory: Self.helpers)
        await first.observe { transcript.append($0) }
        let session = try await first.start(session: nil).session
        let thread = try XCTUnwrap(session)
        print("live: thread \(thread)")
        let end1 = try await deliver(first, Message(
            id: "m_live1", agent: "dev", text: "Please show me a toast saying \"T11 live check\"."))
        print("live: turn 1 \(end1)")
        XCTAssertEqual(end1, TurnEnd(session: thread, outcome: .completed))
        let calls1 = siriusCalls(transcript.all)
        for call in calls1 { print("live: turn 1 tool \(call.tool) \(call.status) \(call.arguments)") }
        XCTAssertTrue(calls1.contains { $0.tool == "display" && $0.status == "completed" && $0.arguments.contains("T11 live check") },
                      "no successful sirius display call")
        await first.stop()

        // Turn 2, after a restart, on the resumed thread.
        let mark = transcript.all.count
        let second = CodexAdapter(registration: registration, socketPath: socket, helpersDirectory: Self.helpers)
        await second.observe { transcript.append($0) }
        let resumed = try await second.start(session: thread).session
        XCTAssertEqual(resumed, thread)
        let sent = transcript.all.dropFirst(mark).filter { $0.hasPrefix(">> ") }
        XCTAssertTrue(sent.contains { $0.contains("\"method\":\"thread/resume\"") && $0.contains(thread) },
                      "thread/resume was not used")
        XCTAssertFalse(sent.contains { $0.contains("\"method\":\"thread/start\"") }, "a new thread was started")
        let end2 = try await deliver(second, Message(
            id: "m_live2", agent: "dev", text: "What did I ask you a moment ago? Reply via toast."))
        print("live: turn 2 \(end2)")
        XCTAssertEqual(end2, TurnEnd(session: thread, outcome: .completed))
        let calls2 = siriusCalls(Array(transcript.all.dropFirst(mark)))
        for call in calls2 { print("live: turn 2 tool \(call.tool) \(call.status) \(call.arguments)") }
        await second.stop()
    }
}
