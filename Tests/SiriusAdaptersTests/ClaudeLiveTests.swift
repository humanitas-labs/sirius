import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// The real `claude` against the running Sirius.app's dev socket. Gated:
//   SIRIUS_LIVE_CLAUDE=1 swift test --filter ClaudeLiveTests
// Shows two real toasts and spends two short model turns.
final class ClaudeLiveTests: XCTestCase {
    func testToastThenResume() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_CLAUDE=1 to run against the real claude and Sirius.app")
        }
        let socket = Self.userTempDirectory() + "sirius/dev.sock"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socket), "Sirius.app is not serving \(socket)")
        let helpers = try XCTUnwrap(Self.helpersDirectory(), "no sirius helper built or installed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let events = EventRecorder()
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .claudeCode,
                                             executable: "", root: root.path)
        let adapter = ClaudeAdapter(registration: registration, socketPath: socket, helpersDirectory: helpers,
                                    observer: { events.append($0) })
        print("live: helpers \(helpers.path), socket \(socket), root \(root.path)")

        let started = try await adapter.start(session: nil)
        print("live: start returned \(started)")
        let first = try await adapter.deliver(Message(id: "m_live1", agent: "dev",
                                                      text: "Show me a toast saying \"T12 live check\"."))
        print("live: turn 1 \(first)")
        events.dump(label: "turn 1")
        XCTAssertEqual(first.outcome, .completed)
        let session = try XCTUnwrap(first.session)
        XCTAssertTrue(events.succeededToast(), "a Bash `sirius display toast` call succeeded")
        await adapter.stop()

        events.clear()
        let resumed = try await adapter.start(session: session)
        print("live: restart returned \(resumed)")
        let args = await adapter.launchArguments
        print("live: args \(args)")
        let i = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(args[i + 1], session)
        let second = try await adapter.deliver(Message(id: "m_live2", agent: "dev",
                                                       text: "What did I ask you a moment ago? Reply via toast."))
        print("live: turn 2 \(second)")
        events.dump(label: "turn 2")
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertEqual(second.session, session)
        XCTAssertTrue(events.succeededToast(), "the resumed turn replied via toast")
        await adapter.stop()
    }

    private static func userTempDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    }

    // This worktree's build, else the installed app's.
    private static func helpersDirectory() -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [repo.appendingPathComponent(".build/debug"),
                          URL(fileURLWithPath: "/Applications/Sirius.app/Contents/Helpers")]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("sirius").path)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func append(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }

    private var objects: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func blocks(_ event: [String: Any]) -> [[String: Any]] {
        (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    // A Bash tool_use running `sirius display toast` whose tool_result is not an error.
    func succeededToast() -> Bool {
        let events = objects
        var toastCalls: Set<String> = []
        for event in events where event["type"] as? String == "assistant" {
            for block in blocks(event) where block["type"] as? String == "tool_use" && block["name"] as? String == "Bash" {
                let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
                if command.contains("sirius display toast"), let id = block["id"] as? String { toastCalls.insert(id) }
            }
        }
        for event in events where event["type"] as? String == "user" {
            for block in blocks(event) where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String, toastCalls.contains(id), block["is_error"] as? Bool != true {
                    return true
                }
            }
        }
        return false
    }

    func dump(label: String) {
        for event in objects {
            let type = (event["type"] as? String ?? "?") + ((event["subtype"] as? String).map { "/\($0)" } ?? "")
            var detail = ""
            if type == "system/init" {
                detail = "session_id=\(event["session_id"] ?? "-") model=\(event["model"] ?? "-")"
            }
            for block in blocks(event) {
                switch block["type"] as? String {
                case "tool_use":
                    detail += " tool_use \(block["name"] ?? "?"): \((block["input"] as? [String: Any])?["command"] ?? "")"
                case "tool_result":
                    detail += " tool_result is_error=\(block["is_error"] ?? "nil"): \(String(describing: block["content"] ?? "").prefix(200))"
                case "text":
                    detail += " text: \(String(describing: block["text"] ?? "").prefix(200))"
                default: break
                }
            }
            if type.hasPrefix("result") {
                detail = "is_error=\(event["is_error"] ?? "-") session_id=\(event["session_id"] ?? "-") num_turns=\(event["num_turns"] ?? "-") duration_ms=\(event["duration_ms"] ?? "-") permission_denials=\(event["permission_denials"] ?? "-")"
            }
            print("live[\(label)]: \(type) \(detail)")
        }
    }
}
