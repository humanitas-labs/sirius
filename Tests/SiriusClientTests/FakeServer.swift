import Darwin
import Foundation
import SiriusProtocol

// A one-socket stand-in for the app, on a background thread. It records
// every connection and every byte received, and answers per Behavior.
final class FakeServer: @unchecked Sendable {
    enum Behavior: Sendable {
        // Answer with the line this returns for the request frame ("\n" added).
        case reply(@Sendable (JSONValue) -> String)
        // Read the frame and never answer.
        case silent
        // Read the frame, then close without answering.
        case closeAfterRead
        // Read the frame, send part of a response, close.
        case partial(String)
        // Accept and read nothing, so a large write fills the buffer.
        case neverRead
    }

    let directory: String
    let path: String
    private let behavior: Behavior
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var received: [Data] = []
    private let done = DispatchSemaphore(value: 0)

    // A short path under /tmp: sun_path holds 104 bytes, and the worktree
    // and scratch paths are longer than that.
    init(_ behavior: Behavior) throws {
        var template = Array("/tmp/sct-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.init(rawValue: errno)!) }
        directory = String(cString: template)
        path = directory + "/s.sock"
        self.behavior = behavior
        listener = try Self.bind(path)
        guard listen(listener, 8) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        Thread.detachNewThread { [self] in serve() }
    }

    // A socket node with no listener: connect gets ECONNREFUSED.
    static func staleSocket() throws -> (directory: String, path: String) {
        var template = Array("/tmp/sct-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.init(rawValue: errno)!) }
        let directory = String(cString: template)
        let path = directory + "/s.sock"
        close(try bind(path))
        return (directory, path)
    }

    static func bind(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        return fd
    }

    // Everything each connection sent, in order.
    var connections: [Data] {
        lock.withLock { received }
    }

    // The request frames received across all connections.
    var frames: [JSONValue] {
        connections.flatMap { $0.split(separator: 0x0A) }.compactMap { try? JSONValue.parse(Data($0)) }
    }

    func stop() {
        lock.withLock { stopped = true }
        done.wait()
        close(listener)
        unlink(path)
        rmdir(directory)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func serve() {
        defer { done.signal() }
        while !isStopped {
            guard ready(listener) else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let index = lock.withLock { received.append(Data()); return received.count - 1 }
            handle(fd, index)
            close(fd)
        }
    }

    private func handle(_ fd: Int32, _ index: Int) {
        if case .neverRead = behavior {
            while !isStopped { usleep(20_000) }
            return
        }
        // Up to the first frame.
        guard let frame = readFrame(fd, index) else { return }
        switch behavior {
        case .reply(let answer):
            let request = (try? JSONValue.parse(frame)) ?? .null
            send(fd, answer(request) + "\n")
            drain(fd, index)
        case .silent:
            drain(fd, index)
        case .closeAfterRead:
            return
        case .partial(let bytes):
            send(fd, bytes)
        case .neverRead:
            return
        }
    }

    private func readFrame(_ fd: Int32, _ index: Int) -> Data? {
        var buffer = Data()
        while !isStopped {
            guard ready(fd) else { continue }
            guard let chunk = readChunk(fd, index) else { return nil }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) { return buffer[..<newline] }
        }
        return nil
    }

    // Keeps reading until the client closes, so any second frame or
    // retried bytes are recorded.
    private func drain(_ fd: Int32, _ index: Int) {
        while !isStopped {
            guard ready(fd) else { continue }
            if readChunk(fd, index) == nil { return }
        }
    }

    private func readChunk(_ fd: Int32, _ index: Int) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return nil }
        let data = Data(chunk[0..<count])
        lock.withLock { received[index].append(data) }
        return data
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func ready(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 20) > 0
    }
}

// A well-formed response to the request, echoing its id.
func respond(_ request: JSONValue, result: String) -> String {
    #"{"jsonrpc":"2.0","sirius":1,"id":\#(idJSON(request)),"result":\#(result)}"#
}

func respond(_ request: JSONValue, code: Int, message: String) -> String {
    #"{"jsonrpc":"2.0","sirius":1,"id":\#(idJSON(request)),"error":{"code":\#(code),"message":"\#(message)"}}"#
}

func idJSON(_ request: JSONValue) -> String {
    guard let id = request["id"], let data = try? JSONEncoder().encode(id) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}
