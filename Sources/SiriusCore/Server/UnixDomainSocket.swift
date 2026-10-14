import Darwin

// The POSIX calls the server makes on its descriptors.
enum UnixDomainSocket {
    // sizeof(sun_path), the terminating NUL included.
    static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count + 1 <= pathCapacity else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    // A non-blocking, close-on-exec listening socket bound at path.
    static func listen(path: String, backlog: Int32 = SOMAXCONN) throws -> Int32 {
        guard var address = address(path) else {
            throw SocketServerError.pathTooLong(path: path, bytes: path.utf8.count + 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.posix("socket") }
        do {
            try configure(fd)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw SocketServerError.posix("bind \(path)") }
            // The directory is already 0700; this keeps the node private too.
            _ = chmod(path, 0o600)
            guard Darwin.listen(fd, backlog) == 0 else {
                let error = SocketServerError.posix("listen")
                unlink(path)
                throw error
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    // Non-blocking, close-on-exec (so agents we spawn never inherit it), and
    // no SIGPIPE when a helper hangs up before reading its response.
    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SocketServerError.posix("fcntl F_SETFD") }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketServerError.posix("fcntl F_SETFL")
        }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketServerError.posix("setsockopt SO_NOSIGPIPE")
        }
    }

    static func peerUid(_ fd: Int32) -> uid_t? {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}

// The uid check, apart from the socket so it can be tested: getpeereid must
// succeed and name the uid we run as. Any other user is closed on silently.
struct PeerCheck: Sendable {
    var expectedUid: uid_t
    var peerUid: @Sendable (Int32) -> uid_t?

    init(expectedUid: uid_t = getuid(), peerUid: @escaping @Sendable (Int32) -> uid_t? = { UnixDomainSocket.peerUid($0) }) {
        self.expectedUid = expectedUid
        self.peerUid = peerUid
    }

    func allows(_ fd: Int32) -> Bool {
        guard let uid = peerUid(fd) else { return false }
        return uid == expectedUid
    }
}
