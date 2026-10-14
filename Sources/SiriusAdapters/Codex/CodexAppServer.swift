import Darwin
import Foundation
import SiriusProtocol

// One `codex app-server` process and the JSON-RPC over its stdio: one JSON
// object per line, requests from us, responses and notifications from it,
// and the rare request from it (approvals), which Sirius always declines.
// When the process exits or its stdout closes, every pending request and
// turn wait fails; after terminate() they fail with CancellationError.
final class CodexAppServer: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private let lock = NSLock()
    private var nextId: Int64 = 0
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var turnWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var finishedTurns: [String: JSONValue] = [:]
    // Set once: why the connection is gone.
    private var failure: Error?
    private var stopping = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var exited = false
    private var launched = false
    private var stderrTail = Data()
    // The start of stderr, for why it quit as it started.
    private var stderrHead = Data()
    private var stderrClosed = false
    private var observer: (@Sendable (String) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var processIdentifier: Int32 { process.processIdentifier }

    // Every line in both directions, prefixed ">> " (sent) or "<< "
    // (received). For tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.observer = observer }
    }

    func launch() throws {
        // A write to a dead server must fail with EPIPE, not kill the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] process in
            self?.didExit(status: process.terminationStatus, reason: process.terminationReason)
        }
        try process.run()
        lock.withLock { launched = true }
        let out = stdout.fileHandleForReading.fileDescriptor
        let err = stderr.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in readLines(out) }
        Thread.detachNewThread { [self] in drainStderr(err) }
    }

    // Sends a request and waits for its result. Throws the server's error
    // as CodexAppServerError.rpc, or why the connection is gone.
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int64? = lock.withLock {
                if let failure {
                    continuation.resume(throwing: failure)
                    return nil
                }
                nextId += 1
                pending[nextId] = continuation
                return nextId
            }
            guard let id else { return }
            let frame: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string(method), "params": params,
            ])
            if let error = send(frame) {
                lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String) throws {
        if let error = send(.object(["jsonrpc": .string("2.0"), "method": .string(method)])) { throw error }
    }

    // Waits for turn/completed for this turn; returns its `turn` object.
    func turnCompleted(_ turnId: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let turn = finishedTurns.removeValue(forKey: turnId) {
                    continuation.resume(returning: turn)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    turnWaiters[turnId] = continuation
                }
            }
        }
    }

    // Closes stdin, asks the process to exit, kills it if it has not within
    // `grace`, and returns once it is gone. Pending waits throw
    // CancellationError, before this returns.
    func terminate(grace: TimeInterval = 2) async {
        lock.withLock { stopping = true }
        fail(CancellationError())
        try? stdin.fileHandleForWriting.close()
        guard lock.withLock({ launched && !exited }) else { return }
        process.terminate()
        let pid = process.processIdentifier
        let killer = Task {
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if !Task.isCancelled { kill(pid, SIGKILL) }
        }
        await waitForExit()
        killer.cancel()
    }

    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock {
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    // MARK: - Writing

    // nil on success.
    private func send(_ frame: JSONValue) -> Error? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(frame) else { return CodexAppServerError.closed("unencodable frame") }
        if let observer = lock.withLock({ observer }) {
            observer(">> " + String(decoding: data, as: UTF8.self))
        }
        data.append(0x0A)
        let fd = stdin.fileHandleForWriting.fileDescriptor
        // One writer at a time, so lines never interleave.
        return lock.withLock { () -> Error? in
            if let failure { return failure }
            var offset = 0
            while offset < data.count {
                let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR { continue }
                    return CodexAppServerError.closed("stdin: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
            return nil
        }
    }

    // MARK: - Reading

    private func readLines(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                handle(Data(line))
            }
        }
        // stdout closed: the server cannot answer anything more.
        fail(CodexAppServerError.closed("app-server closed its output\(stderrSuffix())"))
    }

    private func drainStderr(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                lock.withLock { stderrClosed = true }
                return
            }
            lock.withLock {
                if stderrHead.count < 2048 { stderrHead.append(contentsOf: chunk[0..<min(count, 2048)]) }
                stderrTail.append(contentsOf: chunk[0..<count])
                if stderrTail.count > 2048 { stderrTail = stderrTail.suffix(2048) }
            }
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        if let observer = lock.withLock({ observer }) {
            observer("<< " + String(decoding: line, as: UTF8.self))
        }
        guard let message = try? JSONValue.parse(line), message.object != nil else { return }
        let method = message["method"]?.string
        let id = message["id"]
        if let method, let id {
            answerServerRequest(method: method, id: id)
        } else if let method {
            if method == "turn/completed", let turn = message["params"]?["turn"], let turnId = turn["id"]?.string {
                let waiter: CheckedContinuation<JSONValue, Error>? = lock.withLock {
                    if let waiter = turnWaiters.removeValue(forKey: turnId) { return waiter }
                    finishedTurns[turnId] = turn
                    return nil
                }
                waiter?.resume(returning: turn)
            }
        } else if let id = id?.safeInteger {
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: CodexAppServerError.rpc(
                    code: error["code"]?.safeInteger ?? 0, message: error["message"]?.string ?? "unknown error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    // Sirius never grants anything: approvals are declined, everything else
    // is refused. Under approvalPolicy never none of these should arrive.
    private func answerServerRequest(method: String, id: JSONValue) {
        let reply: JSONValue
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            reply = .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["decision": .string("decline")])])
        case "mcpServer/elicitation/request":
            reply = .object(["jsonrpc": .string("2.0"), "id": id,
                             "result": .object(["action": .string("decline"), "content": .null, "_meta": .null])])
        default:
            reply = .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                "code": .number(-32601), "message": .string("Sirius does not handle \(method)"),
            ])])
        }
        _ = send(reply)
    }

    // MARK: - Ending

    private func didExit(status: Int32, reason: Process.TerminationReason) {
        let how = reason == .uncaughtSignal ? "was killed by signal \(status)" : "exited with status \(status)"
        fail(CodexAppServerError.exited("app-server \(how)\(stderrSuffix())"))
        let waiters = lock.withLock {
            exited = true
            defer { exitWaiters.removeAll() }
            return exitWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ error: Error) {
        let (requests, turns) = lock.withLock { () -> ([CheckedContinuation<JSONValue, Error>], [CheckedContinuation<JSONValue, Error>]) in
            if failure == nil { failure = stopping ? CancellationError() : error }
            defer {
                pending.removeAll()
                turnWaiters.removeAll()
            }
            return (Array(pending.values), Array(turnWaiters.values))
        }
        let reason = lock.withLock { failure ?? error }
        for continuation in requests + turns { continuation.resume(throwing: reason) }
    }

    // The first line of stderr, once the process has exited and stderr has
    // been read to its end, waiting up to `seconds` for both: stdout can
    // close before the exit and the last of stderr. Nil when it wrote none.
    func firstStderrLine(within seconds: Double = 0.5) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ exited && stderrClosed }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let head = lock.withLock { String(decoding: stderrHead, as: UTF8.self) }
        return head.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private func stderrSuffix() -> String {
        let tail = lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = tail.split(separator: "\n").last else { return "" }
        return ": \(last)"
    }
}

enum CodexAppServerError: Error, Equatable, CustomStringConvertible {
    // The server answered a request with a JSON-RPC error.
    case rpc(code: Int64, message: String)
    // stdout closed or stdin refused a write.
    case closed(String)
    // The process exited.
    case exited(String)

    var description: String {
        switch self {
        case .rpc(let code, let message): return "codex app-server error \(code): \(message)"
        case .closed(let reason), .exited(let reason): return reason
        }
    }
}
