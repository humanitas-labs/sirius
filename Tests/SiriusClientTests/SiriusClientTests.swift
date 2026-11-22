import Darwin
import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusClient

final class SiriusClientTests: XCTestCase {
    private let toast = JSONValue.object(["kind": .string("toast"), "content": .string("hi")])

    private func call(_ behavior: FakeServer.Behavior, timeout: TimeInterval = 2) throws -> (Outcome, FakeServer) {
        let server = try FakeServer(behavior)
        let outcome = SiriusClient(socketPath: server.path, timeout: timeout).call(.display, params: toast)
        server.stop()
        return (outcome, server)
    }

    // MARK: - Outcomes

    func testResult() throws {
        let (outcome, server) = try call(.reply { respond($0, result: #"{"delivered":true}"#) })
        XCTAssertEqual(outcome, .result(.object(["delivered": .bool(true)])))
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertNil(outcome.message)

        let frame = try XCTUnwrap(server.frames.first)
        XCTAssertEqual(frame["jsonrpc"], .string("2.0"))
        XCTAssertEqual(frame["sirius"], .number(1))
        XCTAssertEqual(frame["method"], .string("display"))
        XCTAssertNotNil(frame["id"]?.string, "the helper sends a string id")
        XCTAssertEqual(frame["params"], toast)
    }

    func testErrorResponse() throws {
        let (outcome, _) = try call(.reply { respond($0, code: -32003, message: "dialog isn't available yet") })
        XCTAssertEqual(outcome, .error(RPCError(.kindNotAvailable, "dialog isn't available yet")))
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(outcome.message, "dialog isn't available yet (-32003)")
    }

    func testNoSocketIsNotRunning() {
        let outcome = SiriusClient(socketPath: "/tmp/sct-missing-\(getpid())/s.sock").call(.display, params: toast)
        XCTAssertEqual(outcome, .notRunning(.noSocket))
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertEqual(outcome.message, "Sirius isn't running")
    }

    func testStaleSocketIsNotRunning() throws {
        let (directory, path) = try FakeServer.staleSocket()
        defer { unlink(path); rmdir(directory) }
        let outcome = SiriusClient(socketPath: path).call(.display, params: toast)
        XCTAssertEqual(outcome, .notRunning(.refused))
        XCTAssertEqual(outcome.exitCode, 3)
    }

    func testOverlongPathIsNotRunning() {
        let outcome = SiriusClient(socketPath: "/tmp/" + String(repeating: "x", count: 120)).call(.display, params: toast)
        XCTAssertEqual(outcome, .notRunning(.pathTooLong))
        XCTAssertEqual(outcome.exitCode, 3)
    }

    func testTimeoutIsUnknownAndHonoured() throws {
        let start = ContinuousClock.now
        let (outcome, server) = try call(.silent, timeout: 0.3)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(outcome, .unknown(.timedOut))
        XCTAssertTrue(outcome.isUnknown)
        XCTAssertEqual(outcome.exitCode, 4)
        XCTAssertEqual(outcome.message, "outcome unknown (timed out); not retried")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertEqual(server.connections.count, 1)
        XCTAssertEqual(server.frames.count, 1)
    }

    // The write waits on the same deadline as the read: an app that stops
    // reading cannot hold the helper past SIRIUS_TIMEOUT.
    func testWriteDeadline() throws {
        let server = try FakeServer(.neverRead)
        // Under Limits.freeFrameBytes, so the wait is the base alone.
        let small = JSONValue.object(["kind": .string("toast"), "content": .string(String(repeating: "x", count: 1024))])
        let start = ContinuousClock.now
        let outcome = SiriusClient(socketPath: server.path, timeout: 0.3).call(.display, params: small)
        let elapsed = ContinuousClock.now - start
        server.stop()
        XCTAssertEqual(outcome, .unknown(.timedOut))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    // MARK: - The receipt wait scales with the frame's size

    func testTheWaitIsTheBaseUnderTheFreeBytes() {
        XCTAssertEqual(SiriusEnvironment.receiptTimeout(base: 10, frameBytes: 0), 10)
        XCTAssertEqual(SiriusEnvironment.receiptTimeout(base: 10, frameBytes: Limits.freeFrameBytes), 10)
        XCTAssertEqual(SiriusEnvironment.receiptTimeout(base: 2.5, frameBytes: 1024), 2.5)
    }

    func testTheWaitGrowsOneSecondPerRateBeyondTheFreeBytes() {
        XCTAssertEqual(SiriusEnvironment.receiptTimeout(base: 10, frameBytes: Limits.freeFrameBytes + Limits.frameBytesPerSecond),
                       11)
        // The largest frame the app accepts, from the smallest useful base.
        XCTAssertEqual(SiriusEnvironment.receiptTimeout(base: 2.5, frameBytes: Limits.maxRequestBytes), 18.375)
    }

    // A long response is not cut short by a deadline sized for a short one:
    // the app answers after the base would have run out, within the
    // allowance the frame's size earns it.
    func testALongResponseOutlastsTheBaseDeadline() throws {
        let big = JSONValue.object(["kind": .string("toast"), "content": .string(String(repeating: "x", count: 512 * 1024))])
        let server = try FakeServer(.reply { frame in
            Thread.sleep(forTimeInterval: 0.8)
            return respond(frame, result: #"{"delivered":true}"#)
        })
        // The scaled wait is about 0.3 + 0.9 s; the base alone would end at 0.3 s.
        let outcome = SiriusClient(socketPath: server.path, timeout: 0.3).call(.display, params: big)
        server.stop()
        XCTAssertEqual(outcome, .result(.object(["delivered": .bool(true)])))
    }

    // A frame that never drains is given up on within its scaled wait, not
    // the base alone and not forever.
    func testTheWriteDeadlineScalesWithTheFrame() throws {
        let server = try FakeServer(.neverRead)
        let big = JSONValue.object(["kind": .string("toast"), "content": .string(String(repeating: "x", count: 1 << 20))])
        let start = ContinuousClock.now
        let outcome = SiriusClient(socketPath: server.path, timeout: 0.3).call(.display, params: big)
        let elapsed = ContinuousClock.now - start
        server.stop()
        XCTAssertEqual(outcome, .unknown(.timedOut))
        // 0.3 s plus the 1 MiB allowance (~1.9 s), with room for scheduling.
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(2))
        XCTAssertLessThan(elapsed, .seconds(4))
    }

    func testClosedWithoutResponseIsUnknown() throws {
        let (outcome, server) = try call(.closeAfterRead)
        XCTAssertEqual(outcome, .unknown(.connectionLost))
        XCTAssertEqual(outcome.exitCode, 4)
        XCTAssertEqual(outcome.message, "outcome unknown (connection lost); not retried")
        XCTAssertEqual(server.connections.count, 1, "never retried")
    }

    func testPartialResponseIsUnknown() throws {
        let (outcome, server) = try call(.partial(#"{"jsonrpc":"2.0","sirius":1,"#))
        XCTAssertEqual(outcome, .unknown(.connectionLost))
        XCTAssertEqual(server.connections.count, 1)
    }

    func testExactlyOneFrameAndNoRetry() throws {
        for behavior: FakeServer.Behavior in [.reply { respond($0, result: #"{"delivered":true}"#) },
                                              .closeAfterRead, .silent] {
            let (_, server) = try call(behavior, timeout: 0.3)
            XCTAssertEqual(server.connections.count, 1)
            let bytes = try XCTUnwrap(server.connections.first)
            XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 1, "one frame, one newline")
            XCTAssertEqual(bytes.last, 0x0A)
        }
    }

    // MARK: - The response envelope

    func testMalformedResponsesAreUnknown() throws {
        let bad: [@Sendable (JSONValue) -> String] = [
            { _ in "not json" },
            { _ in #"{"jsonrpc":"2.0","sirius":1,"id":"other","result":{"delivered":true}}"# },
            { _ in #"{"jsonrpc":"2.0","sirius":1,"id":null,"error":{"code":-32700,"message":"x"}}"# },
            { #"{"sirius":1,"id":\#(idJSON($0)),"result":{"delivered":true}}"# },
            { #"{"jsonrpc":"1.0","sirius":1,"id":\#(idJSON($0)),"result":{"delivered":true}}"# },
            { #"{"jsonrpc":"2.0","id":\#(idJSON($0)),"result":{"delivered":true}}"# },
            { #"{"jsonrpc":"2.0","sirius":2,"id":\#(idJSON($0)),"result":{"delivered":true}}"# },
            { #"{"jsonrpc":"2.0","sirius":1,"id":\#(idJSON($0))}"# },
            { #"{"jsonrpc":"2.0","sirius":1,"id":\#(idJSON($0)),"result":{},"error":{"code":-32603,"message":"x"}}"# },
        ]
        for (index, answer) in bad.enumerated() {
            let (outcome, _) = try call(.reply(answer))
            XCTAssertEqual(outcome, .unknown(.malformedResponse), "case \(index)")
            XCTAssertEqual(outcome.exitCode, 4, "case \(index)")
        }
    }

    // MARK: - Environment

    func testEnvironment() throws {
        XCTAssertThrowsError(try SiriusClient.fromEnvironment([:])) {
            XCTAssertEqual($0 as? ConfigurationError, .socketNotSet)
            XCTAssertEqual(($0 as? ConfigurationError)?.exitCode, 3)
        }
        XCTAssertThrowsError(try SiriusClient.fromEnvironment(["SIRIUS_SOCKET": ""]))
        let client = try SiriusClient.fromEnvironment(["SIRIUS_SOCKET": "/tmp/s.sock"])
        XCTAssertEqual(client.socketPath, "/tmp/s.sock")
        XCTAssertEqual(client.timeout, 10)
        XCTAssertEqual(try SiriusClient.fromEnvironment(["SIRIUS_SOCKET": "/s", "SIRIUS_TIMEOUT": "2.5"]).timeout, 2.5)
        for raw in ["0", "-1", "abc", "inf", "nan", ""] {
            XCTAssertThrowsError(try SiriusClient.fromEnvironment(["SIRIUS_SOCKET": "/s", "SIRIUS_TIMEOUT": raw])) {
                XCTAssertEqual(($0 as? ConfigurationError)?.exitCode, 2, raw)
            }
        }
    }
}
