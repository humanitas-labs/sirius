import Darwin
import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// The T13 check: from an empty root, with only the seeded instructions,
// each agent replies through Sirius on the first try in at least 9 of 10
// runs. The messages never mention toasts. Runs only with SIRIUS_LIVE_T13=1;
// it spends 20 model turns and shows about 20 toasts on the running
// Sirius.app. SIRIUS_LIVE_T13_RUNS sets the runs per agent (default 10).
final class InstructionsLiveTests: XCTestCase {
    static let prompts = [
        "what's 17 times 23?",
        "what files are in this folder?",
        "write a two-line poem about tea into poem.txt",
        "hey, are you there?",
        "is this folder a git repository?",
        "make a file todo.md with three items for a grocery run",
        "what's today's date?",
        "summarize what you can do for me in one sentence",
        "create hello.py that prints hello, then run it",
        "how many files are in this folder now?",
    ]

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private struct Run: CustomStringConvertible {
        var prompt: String
        var completed: Bool
        // The first send through Sirius, and whether it succeeded.
        var first: String?
        var firstSucceeded: Bool
        var passed: Bool { completed && firstSucceeded }
        var description: String {
            "\(passed ? "PASS" : "FAIL")  \(prompt)  ->  \(first ?? "no send")\(completed ? "" : " (turn failed)")"
        }
    }

    private static var socket: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return (count > 0 ? String(cString: buffer) : NSTemporaryDirectory()) + "sirius/dev.sock"
    }

    private static var helpers: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug")
    }

    private func freshRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-t13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withWatchdog<T>(_ stop: @escaping @Sendable () async -> Void,
                                 _ body: () async throws -> T) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 240_000_000_000)
            await stop()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    // MARK: Claude

    private func claudeRun(_ prompt: String, index: Int) async throws -> Run {
        let root = try freshRoot()
        let lines = Lines()
        let registration = AgentRegistration(agent: "dev", name: "Claude", harness: .claudeCode,
                                             executable: "", root: root.path)
        let adapter = ClaudeAdapter(registration: registration, socketPath: Self.socket,
                                    helpersDirectory: Self.helpers,
                                    systemPrompt: try InstructionsTemplates.seeded(.claudeCode),
                                    observer: { lines.append(String(decoding: $0, as: UTF8.self)) })
        _ = try await adapter.start(session: nil)
        let end = try? await withWatchdog({ await adapter.stop() }) {
            try await adapter.deliver(Message(id: "m_t13c\(index)", agent: "dev", text: prompt))
        }
        await adapter.stop()

        // The first Bash call that runs sirius, and its result.
        var firstId: String?, first: String?, succeeded = false
        for line in lines.all {
            guard let event = try? JSONValue.parse(Data(line.utf8)),
                  let content = event["message"]?["content"]?.array else { continue }
            for block in content {
                if firstId == nil, block["type"]?.string == "tool_use", block["name"]?.string == "Bash",
                   let command = block["input"]?["command"]?.string,
                   Self.runsSirius(command) {
                    firstId = block["id"]?.string
                    first = command
                }
                if let firstId, block["type"]?.string == "tool_result", block["tool_use_id"]?.string == firstId {
                    succeeded = block["is_error"] != .bool(true)
                }
            }
        }
        return Run(prompt: prompt, completed: end?.outcome == .completed, first: first, firstSucceeded: succeeded)
    }

    // A sirius send anywhere in the command: Claude often chains it after
    // the work, e.g. `cat > poem.txt <<EOF … EOF` then `sirius display toast …`.
    static func runsSirius(_ command: String) -> Bool {
        command.range(of: #"(^|[\n;&|(]\s*)sirius\s+(display|notify|speak)\b"#, options: .regularExpression) != nil
    }

    // MARK: Codex

    private func codexRun(_ prompt: String, index: Int) async throws -> Run {
        let root = try freshRoot()
        let lines = Lines()
        let registration = AgentRegistration(agent: "dev", name: "Codex", harness: .codex,
                                             executable: "", root: root.path)
        let adapter = CodexAdapter(registration: registration, socketPath: Self.socket,
                                   helpersDirectory: Self.helpers,
                                   instructions: try InstructionsTemplates.seeded(.codex))
        await adapter.observe { lines.append($0) }
        _ = try await adapter.start(session: nil)
        let end = try? await withWatchdog({ await adapter.stop() }) {
            try await adapter.deliver(Message(id: "m_t13x\(index)", agent: "dev", text: prompt))
        }
        await adapter.stop()

        var first: String?, succeeded = false
        for line in lines.all where line.hasPrefix("<< ") {
            guard let message = try? JSONValue.parse(Data(line.dropFirst(3).utf8)),
                  message["method"]?.string == "item/completed",
                  let item = message["params"]?["item"], item["type"]?.string == "mcpToolCall",
                  item["server"]?.string == "sirius" else { continue }
            let arguments = (try? String(decoding: JSONEncoder().encode(item["arguments"] ?? .null), as: UTF8.self)) ?? ""
            first = "\(item["tool"]?.string ?? "?") \(arguments)"
            succeeded = item["status"]?.string == "completed"
            break
        }
        return Run(prompt: prompt, completed: end?.outcome == .completed, first: first, firstSucceeded: succeeded)
    }

    // MARK: The check

    func testBothAgentsReplyThroughSiriusOnTheFirstTry() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SIRIUS_LIVE_T13"] == "1",
                          "set SIRIUS_LIVE_T13=1 to run 20 live turns against Sirius.app")
        let runs = Int(env["SIRIUS_LIVE_T13_RUNS"] ?? "") ?? 10
        let prompts = (0..<runs).map { Self.prompts[$0 % Self.prompts.count] }

        async let claude: [Run] = {
            var out: [Run] = []
            for (i, prompt) in prompts.enumerated() { out.append(try await self.claudeRun(prompt, index: i)) }
            return out
        }()
        async let codex: [Run] = {
            var out: [Run] = []
            for (i, prompt) in prompts.enumerated() { out.append(try await self.codexRun(prompt, index: i)) }
            return out
        }()
        let (claudeRuns, codexRuns) = try await (claude, codex)

        var report = ""
        for (name, results) in [("claude", claudeRuns), ("codex", codexRuns)] {
            let passed = results.filter(\.passed).count
            report += "\(name): \(passed)/\(results.count)\n" + results.map { "  \($0)" }.joined(separator: "\n") + "\n"
            XCTAssertGreaterThanOrEqual(passed * 10, results.count * 9, "\(name) passed \(passed)/\(results.count)")
        }
        print(report)
        if let path = env["SIRIUS_LIVE_T13_LOG"] { try report.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
