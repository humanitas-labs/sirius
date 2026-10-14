import Darwin
import Foundation

enum TransportFailure: Error {
    case pathTooLong
    case connect(errno: Int32)
    case connectTimedOut
    case timedOut
    case connectionLost
    case responseTooLarge

    var outcome: Outcome {
        switch self {
        case .pathTooLong: .notRunning(.pathTooLong)
        case .connect(let code) where code == ENOENT || code == ENOTDIR: .notRunning(.noSocket)
        case .connect(let code) where code == ECONNREFUSED: .notRunning(.refused)
        case .connect(let code): .notRunning(.unreachable(errno: code))
        case .connectTimedOut: .notRunning(.connectTimedOut)
        case .timedOut: .unknown(.timedOut)
        case .connectionLost: .unknown(.connectionLost)
        case .responseTooLarge: .unknown(.malformedResponse)
        }
    }
}

enum UnixSocket {
    // A response is a short receipt or error; anything this long is not one.
    static let maxResponseBytes = 1 << 20

    // Connects, writes the whole frame, reads up to the first "\n" and
    // returns the line without it. Bytes after it are ignored. One deadline
    // covers all three steps. The socket is non-blocking and every wait is a
    // poll on the time left, so no step can outlive the deadline.
    static func exchange(path: String, frame: Data, timeout: TimeInterval) throws -> Data {
        let deadline = Deadline(seconds: timeout)

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw TransportFailure.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportFailure.connect(errno: errno) }
        defer { close(fd) }
        // A write to a socket the app has closed must fail, not kill the helper.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EINTR else { throw TransportFailure.connect(errno: code) }
            guard wait(fd, for: Int16(POLLOUT), until: deadline) else { throw TransportFailure.connectTimedOut }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 { throw TransportFailure.connect(errno: soError) }
        }

        // From here bytes may have reached the app, so every failure is an
        // unknown outcome.
        try frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if written < 0 && code == EINTR { continue }
                if written < 0 && code == EAGAIN {
                    guard wait(fd, for: Int16(POLLOUT), until: deadline) else { throw TransportFailure.timedOut }
                    continue
                }
                throw TransportFailure.connectionLost
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            guard wait(fd, for: Int16(POLLIN), until: deadline) else { throw TransportFailure.timedOut }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { throw TransportFailure.connectionLost }
            if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                throw TransportFailure.connectionLost
            }
            let start = response.count
            response.append(contentsOf: chunk[0..<count])
            if let newline = response[start...].firstIndex(of: 0x0A) {
                return response[..<newline]
            }
            if response.count > maxResponseBytes { throw TransportFailure.responseTooLarge }
        }
    }

    // Waits for the event or a hangup; false once the deadline has passed.
    private static func wait(_ fd: Int32, for events: Int16, until deadline: Deadline) -> Bool {
        while true {
            guard let milliseconds = deadline.remainingMilliseconds() else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 { return true }
            if ready < 0 && errno != EINTR { return true }  // let the read or write report it
        }
    }
}

struct Deadline {
    private let end: ContinuousClock.Instant

    init(seconds: TimeInterval) {
        end = .now + .nanoseconds(Int64(min(seconds, 1e9) * 1e9))
    }

    // Rounded up, so a wait never spins on zero; nil once passed.
    func remainingMilliseconds() -> Int32? {
        let left = ContinuousClock.now.duration(to: end)
        guard left > .zero else { return nil }
        let (seconds, attoseconds) = left.components
        let milliseconds = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: max(milliseconds, 1))
    }
}
