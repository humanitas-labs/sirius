import Darwin
import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class SocketServerTests: XCTestCase {
    private var base = ""
    private var directory = ""

    override func setUpWithError() throws {
        // sockaddr_un holds 104 bytes; the test scratch paths are too long.
        base = "/tmp/sst-\(UInt32.random(in: 0...UInt32.max))"
        directory = base + "/sirius"
        XCTAssertEqual(mkdir(base, 0o700), 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private func makeServer(_ commands: RecordingCommandQueue = RecordingCommandQueue(),
                            _ settings: SocketServerSettings = SocketServerSettings()) throws -> SocketServer {
        try SocketServer(commands: commands, directory: directory, settings: settings)
    }

    private let toast = #"{"jsonrpc":"2.0","sirius":1,"id":"1","method":"display","params":{"kind":"toast","content":"hi"}}"#

    // MARK: - Requests

    func testValidRequestReachesQueueAndResultComesBack() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let reply = try XCTUnwrap(SocketTestClient.exchange(path, toast + "\n"))
        let parsed = try Reply.parse(reply)
        XCTAssertEqual(parsed.id, .string("1"))
        XCTAssertEqual(parsed.outcome, .result(.object(["delivered": .bool(true)])))
        XCTAssertEqual(reply.last, 0x0A)
        let received = commands.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.agent, "dev")
        XCTAssertEqual(received.first?.id, .string("1"))
        XCTAssertEqual(received.first?.call, .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: "hi"))])))
    }

    func testQueueErrorComesBackAsErrorResponse() throws {
        let commands = RecordingCommandQueue(answer: .failure(RPCError(.queueFull, "Queue full",
                                                                       data: ErrorData(method: .display))))
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let parsed = try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, toast + "\n")))
        XCTAssertEqual(parsed.id, .string("1"))
        XCTAssertEqual(parsed.outcome, .error(RPCError(.queueFull, "Queue full", data: ErrorData(method: .display))))
    }

    func testResultThatDoesNotSuitTheCallIsAnInternalError() throws {
        let commands = RecordingCommandQueue(answer: .success(.queued(voice: "x", fallback: false)))
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let parsed = try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, toast + "\n")))
        XCTAssertEqual(parsed.id, .string("1"))
        XCTAssertEqual(parsed.outcome, .error(RPCError(.internalError, "Internal error", data: ErrorData(method: .display))))
    }

    func testCallAdmitsOnlyItsOwnResult() {
        let display = Call.display(DisplayParams(kind: .toast, content: [.text(TextContent(text: "hi"))]))
        XCTAssertTrue(display.admits(.delivered))
        XCTAssertFalse(display.admits(.queued(voice: "x", fallback: false)))
    }

    func testInvalidFrameGetsValidatorCode() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let unknown = #"{"jsonrpc":"2.0","sirius":1,"id":7,"method":"shout","params":{}}"#
        let parsed = try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, unknown + "\n")))
        XCTAssertEqual(parsed.id, .number(7))
        guard case .error(let error) = parsed.outcome else { return XCTFail("expected an error") }
        XCTAssertEqual(error.code, .methodNotFound)

        let garbage = try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, "{nope\n")))
        XCTAssertNil(garbage.id)
        guard case .error(let parseError) = garbage.outcome else { return XCTFail("expected an error") }
        XCTAssertEqual(parseError.code, .parseError)
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testNotificationGetsNoResponse() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let notification = #"{"jsonrpc":"2.0","sirius":1,"method":"display","params":{"kind":"toast","content":"hi"}}"#
        XCTAssertEqual(SocketTestClient.exchange(path, notification + "\n"), Data())
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testSecondFrameOnSameConnectionIsIgnored() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let second = toast.replacingOccurrences(of: #""id":"1""#, with: #""id":"2""#)
        let reply = try XCTUnwrap(SocketTestClient.exchange(path, toast + "\n" + second + "\n"))
        XCTAssertEqual(try Reply.parse(reply).id, .string("1"))
        XCTAssertEqual(reply.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(commands.received.count, 1)
    }

    // MARK: - Framing limits

    func testOversizeFrameIsAnsweredTooLargeWithNullId() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        // Real limit: a helper writes the whole 8 MiB + 1 before it reads.
        let oversize = Data(repeating: 0x20, count: Limits.maxRequestBytes + 1) + Data([0x0A])
        let parsed = try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, oversize, timeout: 10)))
        XCTAssertNil(parsed.id)
        guard case .error(let error) = parsed.outcome else { return XCTFail("expected an error") }
        XCTAssertEqual(error.code, .tooLarge)
        XCTAssertEqual(error.data?.limit, .maxRequestBytes)
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testFrameAtTheLimitIsParsed() throws {
        var settings = SocketServerSettings()
        settings.maxRequestBytes = toast.utf8.count
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands, settings)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        XCTAssertEqual(try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, toast + "\n"))).id, .string("1"))
        XCTAssertEqual(commands.received.count, 1)
    }

    func testPartialFrameThenEOFGetsNoResponse() throws {
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        XCTAssertEqual(SocketTestClient.exchange(path, String(toast.prefix(30))), Data())
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testReadDeadlineClosesWithNoResponse() throws {
        var settings = SocketServerSettings()
        settings.readDeadline = 0.3
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands, settings)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let start = Date()
        // No half-close: only the deadline can end this.
        XCTAssertEqual(SocketTestClient.exchange(path, String(toast.prefix(30)), halfClose: false, timeout: 5), Data())
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testConnectionsOverTheCapAreClosedAtOnce() throws {
        var settings = SocketServerSettings()
        settings.readDeadline = 30
        let server = try makeServer(RecordingCommandQueue(), settings)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        let idle = try (0..<Limits.maxConnectionsPerAgent).map { _ in try SocketTestClient.connect(path) }
        defer { idle.forEach { Darwin.close($0) } }
        try waitUntil { server.connectionCount(agent: "dev") == Limits.maxConnectionsPerAgent }

        let extra = try SocketTestClient.connect(path)
        defer { Darwin.close(extra) }
        // EOF well before the 30 s deadline.
        XCTAssertEqual(SocketTestClient.readToEnd(extra, timeout: 3), Data())
    }

    // MARK: - Peer uid

    func testOtherUidIsClosedWithNoResponse() throws {
        var settings = SocketServerSettings()
        settings.peerCheck = PeerCheck(expectedUid: getuid() &+ 1)
        let commands = RecordingCommandQueue()
        let server = try makeServer(commands, settings)
        defer { server.close() }
        let path = try server.add(agent: "dev")

        XCTAssertEqual(SocketTestClient.exchange(path, toast + "\n"), Data())
        XCTAssertTrue(commands.received.isEmpty)
    }

    func testPeerCheckComparesUid() {
        XCTAssertTrue(PeerCheck(expectedUid: 501, peerUid: { _ in 501 }).allows(3))
        XCTAssertFalse(PeerCheck(expectedUid: 501, peerUid: { _ in 0 }).allows(3))
        // getpeereid failing is a refusal.
        XCTAssertFalse(PeerCheck(expectedUid: 501, peerUid: { _ in nil }).allows(3))
    }

    // MARK: - Lifecycle

    func testSecondInstanceFailsOnTheLock() throws {
        let server = try makeServer()
        defer { server.close() }
        XCTAssertThrowsError(try makeServer()) { error in
            XCTAssertEqual(error as? SocketServerError,
                           .alreadyRunning(lockPath: directory + "/" + SocketDirectory.lockName))
        }
        // The lock file stays after close, and a new instance can take it.
        server.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/" + SocketDirectory.lockName))
        try makeServer().close()
    }

    func testStaleSocketNodesAreCleaned() throws {
        XCTAssertEqual(mkdir(directory, 0o700), 0)
        try SocketTestClient.leaveStaleSocket(directory + "/dev.sock")
        try SocketTestClient.leaveStaleSocket(directory + "/gone.sock")

        let server = try makeServer()
        defer { server.close() }
        // Swept at start, before any add.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/gone.sock"))
        let path = try server.add(agent: "dev")
        XCTAssertNotNil(try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, toast + "\n"))).id)
    }

    func testStaleNodeIsAlsoCleanedAtAdd() throws {
        let server = try makeServer()
        defer { server.close() }
        try SocketTestClient.leaveStaleSocket(directory + "/dev.sock")
        let path = try server.add(agent: "dev")
        XCTAssertNotNil(try Reply.parse(XCTUnwrap(SocketTestClient.exchange(path, toast + "\n"))).id)
    }

    func testPathTooLongIsRefused() throws {
        let long = base + "/" + String(repeating: "d", count: 60)
        let server = try SocketServer(commands: RecordingCommandQueue(), directory: long)
        defer { server.close() }
        let agent = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try server.add(agent: agent)) { error in
            guard case .pathTooLong(_, let bytes)? = error as? SocketServerError else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(bytes, 104)
        }
        XCTAssertEqual(server.agents, [])
    }

    func testInvalidAgentIdIsRefused() throws {
        let server = try makeServer()
        defer { server.close() }
        XCTAssertThrowsError(try server.add(agent: "../x")) { error in
            XCTAssertEqual(error as? SocketServerError, .invalidAgentId("../x"))
        }
    }

    func testRemoveUnlinksAndClosesConnections() throws {
        var settings = SocketServerSettings()
        settings.readDeadline = 30
        let server = try makeServer(RecordingCommandQueue(), settings)
        defer { server.close() }
        let path = try server.add(agent: "dev")
        XCTAssertEqual(server.agents, ["dev"])

        let open = try SocketTestClient.connect(path)
        defer { Darwin.close(open) }
        try waitUntil { server.connectionCount(agent: "dev") == 1 }

        server.remove(agent: "dev")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(server.agents, [])
        // The accepted connection is closed too, not left to its deadline.
        XCTAssertEqual(SocketTestClient.readToEnd(open, timeout: 3), Data())
        XCTAssertThrowsError(try SocketTestClient.connect(path))
        // And the id can be added again.
        try server.add(agent: "dev")
    }

    func testCloseUnlinksSockets() throws {
        let server = try makeServer()
        let path = try server.add(agent: "dev")
        server.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try server.add(agent: "other")) { error in
            XCTAssertEqual(error as? SocketServerError, .closed)
        }
    }

    // MARK: - Directory

    func testDirectoryIsCreatedPrivate() throws {
        let server = try makeServer()
        defer { server.close() }
        var info = stat()
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(info.st_uid, getuid())
    }

    func testDirectoryWithWrongModeIsRefused() throws {
        XCTAssertEqual(mkdir(directory, 0o700), 0)
        XCTAssertEqual(chmod(directory, 0o755), 0)
        XCTAssertThrowsError(try makeServer()) { error in
            guard case .directoryUnsafe? = error as? SocketServerError else {
                return XCTFail("expected directoryUnsafe, got \(error)")
            }
        }
    }

    func testDirectoryWithOtherOwnerIsRefused() throws {
        XCTAssertThrowsError(try SocketDirectory.prepare(base, uid: getuid() &+ 1)) { error in
            guard case .directoryUnsafe? = error as? SocketServerError else {
                return XCTFail("expected directoryUnsafe, got \(error)")
            }
        }
    }

    func testSymlinkInPlaceOfDirectoryIsRefused() throws {
        XCTAssertEqual(symlink(base, directory), 0)
        XCTAssertThrowsError(try makeServer())
    }

    func testDefaultDirectoryComesFromConfstr() throws {
        let path = try SocketDirectory.defaultPath()
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertTrue(path.hasSuffix("/sirius"))
        XCTAssertFalse(path.contains("//"))
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { throw SocketTestClient.Failure(call: "waitUntil", code: ETIMEDOUT) }
            usleep(10_000)
        }
    }
}

final class FrameAccumulatorTests: XCTestCase {
    func testSplitReadsJoinAtTheNewline() {
        var accumulator = FrameAccumulator(limit: 100)
        XCTAssertEqual(accumulator.append(Array("{\"a\":".utf8)), .needMore)
        XCTAssertEqual(accumulator.append(Array("1}\n{\"b\"".utf8)), .frame(Data("{\"a\":1}".utf8)))
    }

    func testLimitExcludesTheNewline() {
        var exact = FrameAccumulator(limit: 4)
        XCTAssertEqual(exact.append(Array("abcd\n".utf8)), .frame(Data("abcd".utf8)))
        var over = FrameAccumulator(limit: 4)
        XCTAssertEqual(over.append(Array("abc".utf8)), .needMore)
        XCTAssertEqual(over.append(Array("de".utf8)), .oversize(received: 5))
    }
}

// A CommandQueue that records what it is given and answers with a fixed result.
final class RecordingCommandQueue: CommandQueue, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [Command] = []
    private let answer: Result<MethodResult, RPCError>

    init(answer: Result<MethodResult, RPCError> = .success(.delivered)) {
        self.answer = answer
    }

    var received: [Command] {
        lock.withLock { commands }
    }

    func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
        lock.withLock { commands.append(command) }
        return answer
    }
}

// A blocking client, as a helper would be.
enum SocketTestClient {
    struct Failure: Error { let call: String; let code: Int32 }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = UnixDomainSocket.address(path) else { throw Failure(call: "address", code: 0) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure(call: "connect", code: code)
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    // Everything until EOF; nil if the timeout passes first.
    static func readToEnd(_ fd: Int32, timeout: TimeInterval) -> Data? {
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: chunk[0..<count]); continue }
            if count == 0 { return data }
            if errno == EINTR { continue }
            // ECONNRESET counts as a close.
            return errno == EAGAIN ? nil : data
        }
    }

    // Connect, write, optionally half-close, read to EOF. nil on timeout.
    static func exchange(_ path: String, _ data: Data, halfClose: Bool = true,
                         timeout: TimeInterval = 3) -> Data? {
        guard let fd = try? connect(path) else { return nil }
        defer { Darwin.close(fd) }
        guard writeAll(fd, data) else { return nil }
        if halfClose { shutdown(fd, SHUT_WR) }
        return readToEnd(fd, timeout: timeout)
    }

    static func exchange(_ path: String, _ text: String, halfClose: Bool = true,
                         timeout: TimeInterval = 3) -> Data? {
        exchange(path, Data(text.utf8), halfClose: halfClose, timeout: timeout)
    }

    // A socket node with no listener behind it, as a crashed app leaves.
    static func leaveStaleSocket(_ path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        guard var address = UnixDomainSocket.address(path) else { throw Failure(call: "address", code: 0) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Failure(call: "bind", code: errno) }
    }
}
