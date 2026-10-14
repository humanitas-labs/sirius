import Foundation
import SiriusProtocol
import XCTest

// Runs the built `sirius` binary against a fake server, so argument
// parsing, the request it builds, stderr and the exit code are all tested
// as an agent would see them.
final class CLITests: XCTestCase {
    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private var binary: URL {
        get throws {
            // swift test puts the test bundle beside the built products.
            let url = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sirius")
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw XCTSkip("sirius binary not built at \(url.path)")
            }
            return url
        }
    }

    private func run(_ arguments: [String], socket: String? = nil, timeout: String? = nil,
                     stdin: String = "") throws -> Run {
        let process = Process()
        process.executableURL = try binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SIRIUS_SOCKET"] = socket
        environment["SIRIUS_TIMEOUT"] = timeout
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self))
    }

    // Runs against a server that accepts everything, returning the run
    // and the one request it received.
    private func accepted(_ arguments: [String], stdin: String = "",
                          result: String = #"{"delivered":true}"#) throws -> (Run, JSONValue) {
        let server = try FakeServer(.reply { respond($0, result: result) })
        let run = try run(arguments, socket: server.path, stdin: stdin)
        server.stop()
        XCTAssertEqual(server.connections.count, 1, "\(arguments)")
        XCTAssertEqual(server.frames.count, 1, "\(arguments)")
        return (run, server.frames.first ?? .null)
    }

    private func assertUsage(_ arguments: [String], stdin: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let server = try FakeServer(.reply { respond($0, result: #"{"delivered":true}"#) })
        let run = try run(arguments, socket: server.path, stdin: stdin)
        server.stop()
        XCTAssertEqual(run.status, 2, "\(arguments): \(run.stderr)", file: file, line: line)
        XCTAssertEqual(server.connections.count, 0, "bad usage sends nothing", file: file, line: line)
    }

    // MARK: - Mapping arguments to requests

    func testDisplayJoinsTextLikeEcho() throws {
        let (run, request) = try accepted(["display", "toast", "Pushed", "the branch;", "tests pass."])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "", "quiet on success")
        XCTAssertEqual(run.stderr, "")
        XCTAssertEqual(request["jsonrpc"], .string("2.0"))
        XCTAssertEqual(request["sirius"], .number(1))
        XCTAssertEqual(request["method"], .string("display"))
        XCTAssertNotNil(request["id"]?.string)
        XCTAssertEqual(request["params"], .object(["kind": .string("toast"),
                                                   "content": .string("Pushed the branch; tests pass.")]))
    }

    func testDisplayAlertAndTerminator() throws {
        let (run, request) = try accepted(["display", "toast", "--alert", "--", "-1", "failed"])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(request["params"], .object(["kind": .string("toast"), "content": .string("-1 failed"),
                                                   "alert": .bool(true)]))
    }

    func testKindAsText() throws {
        let (_, request) = try accepted(["display", "toast", "toast"])
        XCTAssertEqual(request["params"]?["content"], .string("toast"))
    }

    func testDialogIsLeftToTheApp() throws {
        let (_, request) = try accepted(["display", "dialog", "hi"])
        XCTAssertEqual(request["params"]?["kind"], .string("dialog"))
    }

    func testDisplayJSONBlocksPassThrough() throws {
        let blocks = #"[{"type":"text","text":"one"},{"type":"text","text":"two","annotations":{"priority":1}}]"#
        let (run, request) = try accepted(["display", "toast", "--json"], stdin: blocks)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(request["params"]?["content"], try JSONValue.parse(Data(blocks.utf8)))
    }

    func testDisplayJSONStringStaysAString() throws {
        let (_, request) = try accepted(["display", "toast", "--json"], stdin: #""[{\"type\":\"text\"}]""#)
        XCTAssertEqual(request["params"]?["content"], .string(#"[{"type":"text"}]"#))
    }

    func testNotify() throws {
        let (run, request) = try accepted(["notify", "--title", "Build", "All", "tests pass"])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(request["method"], .string("notify"))
        XCTAssertEqual(request["params"], .object(["content": .string("All tests pass"), "title": .string("Build")]))
    }

    func testNotifyJSON() throws {
        let (_, request) = try accepted(["notify", "--json"], stdin: #""done""#)
        XCTAssertEqual(request["params"], .object(["content": .string("done")]))
    }

    func testSpeak() throws {
        let (run, request) = try accepted(["speak", "--voice", "Bad News", "The build", "is broken"],
                                          result: #"{"queued":true,"voice":"Bad News"}"#)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "")
        XCTAssertEqual(request["method"], .string("speak"))
        XCTAssertEqual(request["params"], .object(["text": .string("The build is broken"), "voice": .string("Bad News")]))
    }

    func testSpeakFallbackNotesOnStderr() throws {
        let (run, _) = try accepted(["speak", "--voice", "Nobody", "hi"],
                                    result: #"{"queued":true,"voice":"Samantha","fallback":true}"#)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "sirius: voice \"Nobody\" isn't installed; used \"Samantha\"\n")
    }

    // MARK: - Usage, exit 2

    func testBadUsage() throws {
        try assertUsage([])
        try assertUsage(["display"])
        try assertUsage(["display", "toast"])
        try assertUsage(["display", "banner", "hi"])
        try assertUsage(["display", "toast", "-1"])
        try assertUsage(["display", "toast", "--json", "hi"], stdin: #""x""#)
        try assertUsage(["display", "toast", "--json"], stdin: "not json")
        try assertUsage(["notify"])
        try assertUsage(["speak"])
        try assertUsage(["speak", "--json"], stdin: #""x""#)
        try assertUsage(["shout", "hi"])
    }

    func testBadTimeoutIsUsage() throws {
        let run = try run(["display", "toast", "hi"], socket: "/tmp/sct-unused.sock", timeout: "soon")
        XCTAssertEqual(run.status, 2)
        XCTAssertEqual(run.stderr, "sirius: SIRIUS_TIMEOUT must be a positive number of seconds, not \"soon\"\n")
    }

    func testHelpExitsZero() throws {
        let run = try run(["display", "--help"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.contains("sirius display"))
    }

    // MARK: - Outcomes, exit 1, 3, 4

    func testErrorResponse() throws {
        let server = try FakeServer(.reply { respond($0, code: -32003, message: "dialog isn't available yet") })
        let run = try run(["display", "dialog", "hi"], socket: server.path)
        server.stop()
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "sirius: dialog isn't available yet (-32003)\n")
    }

    func testNotRunning() throws {
        let run = try run(["display", "toast", "hi"], socket: "/tmp/sct-missing-\(getpid())/s.sock")
        XCTAssertEqual(run.status, 3)
        XCTAssertEqual(run.stderr, "sirius: Sirius isn't running\n")
    }

    func testSocketNotSet() throws {
        let run = try run(["display", "toast", "hi"])
        XCTAssertEqual(run.status, 3)
        XCTAssertTrue(run.stderr.hasPrefix("sirius: Sirius isn't running (SIRIUS_SOCKET is not set"), run.stderr)
    }

    func testTimeout() throws {
        let server = try FakeServer(.silent)
        let start = ContinuousClock.now
        let run = try run(["display", "toast", "hi"], socket: server.path, timeout: "0.5")
        let elapsed = ContinuousClock.now - start
        server.stop()
        XCTAssertEqual(run.status, 4)
        XCTAssertEqual(run.stderr, "sirius: outcome unknown (timed out); not retried\n")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(500))
        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertEqual(server.connections.count, 1, "not retried")
        XCTAssertEqual(server.frames.count, 1)
    }

    func testConnectionLost() throws {
        let server = try FakeServer(.closeAfterRead)
        let run = try run(["notify", "hi"], socket: server.path)
        server.stop()
        XCTAssertEqual(run.status, 4)
        XCTAssertEqual(run.stderr, "sirius: outcome unknown (connection lost); not retried\n")
        XCTAssertEqual(server.connections.count, 1, "not retried")
    }

    func testMalformedResponse() throws {
        let server = try FakeServer(.reply { _ in #"{"jsonrpc":"2.0","sirius":1,"id":"wrong","result":{}}"# })
        let run = try run(["speak", "hi"], socket: server.path)
        server.stop()
        XCTAssertEqual(run.status, 4)
        XCTAssertEqual(run.stderr, "sirius: outcome unknown (malformed response); not retried\n")
    }
}
