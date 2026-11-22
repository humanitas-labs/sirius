import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// The real `agent acp`, `agy acp` or `opencode acp` against the running
// Sirius.app's dev socket. Gated, one harness at a time:
//   SIRIUS_LIVE_ACP=cursor swift test --filter ACPLiveTests
//   SIRIUS_LIVE_ACP=antigravity swift test --filter ACPLiveTests
//   SIRIUS_LIVE_ACP=opencode swift test --filter ACPLiveTests
// Shows two real toasts and spends two short turns on the signed-in
// account. SIRIUS_LIVE_ACP_MODEL names the model; without it, the CLI's own.
// Every JSON-RPC line is printed, so the first run against a new CLI
// version shows what it really sends.
final class ACPLiveTests: XCTestCase {
    func testToastThenResume() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SIRIUS_LIVE_ACP"],
              let harness = AgentRegistration.Harness(rawValue: name),
              let profile = [AgentRegistration.Harness.cursor: ACPProfile.cursor,
                             .antigravity: ACPProfile.antigravity,
                             .opencode: ACPProfile.opencode][harness] else {
            throw XCTSkip("set SIRIUS_LIVE_ACP=cursor, antigravity or opencode to run against the real CLI and Sirius.app")
        }
        let socket = Self.userTempDirectory() + "sirius/dev.sock"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socket), "Sirius.app is not serving \(socket)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helpers = repo.appendingPathComponent(".build/debug")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("sirius-mcp").path),
                          "no sirius-mcp built")
        let tools = try String(contentsOf: repo.appendingPathComponent("packaging/agent/\(name)/tools.md"),
                               encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = Lines()
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: harness, executable: "",
                                             root: root.path, model: environment["SIRIUS_LIVE_ACP_MODEL"])
        let instructions = "You are an agent in Sirius. The user reads only what you send through these tools:\n" + tools
        func makeAdapter() async -> ACPAdapter {
            let adapter = ACPAdapter(registration: registration, profile: profile, socketPath: socket,
                                     helpersDirectory: helpers, instructions: instructions)
            await adapter.observe { line in
                print("live: \(line.prefix(600))")
                lines.append(line)
            }
            return adapter
        }

        let adapter = await makeAdapter()
        let opened = try await adapter.open(SessionRequest())
        print("live: open \(opened)")
        let first = try await adapter.prompt(Message(id: "m_live1", agent: "dev",
                                                      text: "Show me a toast saying \"ACP live check\"."))
        print("live: turn 1 \(first)")
        XCTAssertEqual(first.outcome, .completed)
        XCTAssertTrue(lines.mentionedDisplay(), "turn 1 called the sirius display tool")
        let session = try XCTUnwrap(first.session)
        await adapter.close()

        lines.clear()
        let resumed = await makeAdapter()
        let reopened = try await resumed.open(SessionRequest(resume: session))
        XCTAssertEqual(reopened.session, session, "the session was reopened, not replaced")
        let second = try await resumed.prompt(Message(id: "m_live2", agent: "dev",
                                                       text: "What did I ask you a moment ago? Reply via toast."))
        print("live: turn 2 \(second)")
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(lines.mentionedDisplay(), "the resumed turn replied via toast")
        await resumed.close()
    }

    private static func userTempDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func clear() { lock.withLock { lines.removeAll() } }

    // A line from the agent about a call of the sirius server's display
    // tool. Cursor names the tool only in its permission request
    // ("sirius-display: display"); its live tool_call says "MCP: tool".
    // Replayed history (toolCallId "replay-…") does not count.
    func mentionedDisplay() -> Bool {
        lock.withLock { lines }.contains { line in
            line.hasPrefix("<< ") && line.contains("sirius") && line.contains("display")
                && (line.contains("session/request_permission") || line.contains("tool_call"))
                && !line.contains("\"replay-")
        }
    }
}
