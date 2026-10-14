import Darwin
import Foundation
import SiriusProtocol

// $TMPDIR/sirius/: the agents' sockets and the instance lock.
public enum SocketDirectory {
    public static let lockName = "sirius.lock"
    public static let socketSuffix = ".sock"

    // The per-user temp folder from confstr, not $TMPDIR: the environment
    // can be changed by whoever launched us, the confstr answer cannot.
    public static func userTemporaryDirectory() throws -> String {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { throw SocketServerError.temporaryDirectoryUnavailable }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else {
            throw SocketServerError.temporaryDirectoryUnavailable
        }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard path.hasPrefix("/") else { throw SocketServerError.temporaryDirectoryUnavailable }
        return path
    }

    public static func defaultPath() throws -> String {
        let base = try userTemporaryDirectory()
        return base.hasSuffix("/") ? base + "sirius" : base + "/sirius"
    }

    // Creates the directory at 0700, or checks an existing one is a real
    // directory (not a symlink) owned by the user at exactly 0700.
    static func prepare(_ path: String, uid: uid_t = getuid()) throws {
        if mkdir(path, 0o700) == 0 {
            // mkdir's mode is masked by the umask; set it outright.
            guard chmod(path, 0o700) == 0 else { throw SocketServerError.posix("chmod") }
        } else if errno != EEXIST {
            throw SocketServerError.posix("mkdir")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw SocketServerError.posix("lstat") }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw SocketServerError.directoryUnsafe(path: path, reason: "not a directory")
        }
        guard info.st_uid == uid else {
            throw SocketServerError.directoryUnsafe(path: path, reason: "owned by uid \(info.st_uid), not \(uid)")
        }
        guard info.st_mode & 0o777 == 0o700 else {
            throw SocketServerError.directoryUnsafe(
                path: path, reason: "mode \(String(info.st_mode & 0o777, radix: 8)), not 700")
        }
    }

    // <dir>/<agent>.sock, checked against the id rule and sockaddr_un's size.
    static func socketPath(directory: String, agent: String) throws -> String {
        guard AgentRegistration.isValidId(agent) else { throw SocketServerError.invalidAgentId(agent) }
        let path = (directory.hasSuffix("/") ? directory : directory + "/") + agent + socketSuffix
        let bytes = path.utf8.count + 1
        guard bytes < UnixDomainSocket.pathCapacity else {
            throw SocketServerError.pathTooLong(path: path, bytes: bytes)
        }
        return path
    }

    // Unlinks a leftover socket node. Only the lock holder calls this.
    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return }
            throw SocketServerError.posix("lstat")
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw SocketServerError.pathOccupied(path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw SocketServerError.posix("unlink") }
    }

    // Every *.sock node left by an instance that is gone.
    static func sweepStaleSockets(in directory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasSuffix(socketSuffix) {
            try? removeStaleSocket(at: (directory as NSString).appendingPathComponent(name))
        }
    }
}

// Exclusive flock on <dir>/sirius.lock for the app's life. The file is never
// unlinked or recreated: a recreated file is a second inode a second instance
// could lock independently.
// Released only on the server's io queue, hence @unchecked Sendable.
final class InstanceLock: @unchecked Sendable {
    let path: String
    private var fd: Int32

    init(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw SocketServerError.posix("open \(path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw SocketServerError.alreadyRunning(lockPath: path) }
            throw SocketServerError.system(call: "flock", errno: code)
        }
        self.path = path
        self.fd = fd
    }

    func release() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { release() }
}
