import Foundation
import os

// Sirius's diagnostics: the unified log under the bundle id, a category per
// area, so `log show --predicate 'subsystem == "com.humanitas.sirius"'`
// finds them; and, once the app calls `mirror(to:)`, a rotating file a
// tester can send (LogFile). Under launchd stderr is /dev/null, so nothing
// goes there unless it is a terminal (a tester, 2026.10.12: 18 KB of stderr
// lost). Lines are metadata: never a message's text or a transcript.
public struct SiriusLog: Sendable {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.humanitas.sirius"

    public static let app = SiriusLog("app")
    public static let hotkey = SiriusLog("hotkey")
    public static let composer = SiriusLog("composer")
    public static let onboarding = SiriusLog("onboarding")
    public static let dictation = SiriusLog("dictation")
    public static let launch = SiriusLog("launch")
    public static let agents = SiriusLog("agents")
    public static let notifications = SiriusLog("notifications")

    public let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
        Self.mirror(category: category, level: "info", message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Self.mirror(category: category, level: "error", message)
    }

    // MARK: Mirrors

    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var file: LogFile?
    private static let stderrIsTerminal = isatty(STDERR_FILENO) != 0

    // Every line from now on also goes to `file`. The app sets it at launch;
    // tests and the helpers never do.
    public static func mirror(to file: LogFile?) {
        mirrorLock.withLock { Self.file = file }
    }

    private static func mirror(category: String, level: String, _ message: String) {
        let file = mirrorLock.withLock { Self.file }
        guard file != nil || stderrIsTerminal else { return }
        let line = LogFile.line(date: Date(), category: category, level: level, message: message)
        file?.append(line)
        if stderrIsTerminal { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

// An append-only text file that rolls over to one backup (`<name>.1`) once
// it passes `limit` bytes, so it stays under about twice that.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    public let limit: Int
    private let lock = NSLock()
    // Guarded by lock.
    private var handle: FileHandle?
    private var size = 0

    // ~/Library/Logs/Sirius/sirius.log, capped at 5 MB with one backup.
    public static func standard() -> LogFile {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sirius", isDirectory: true)
        return LogFile(url: logs.appendingPathComponent("sirius.log"), limit: 5 * 1024 * 1024)
    }

    public init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    public var backupURL: URL { url.appendingPathExtension("1") }

    // "2026-10-12T14:17:03.123Z info [hotkey] compose hotkey registered ⌘⇧J\n".
    public static func line(date: Date, category: String, level: String, message: String) -> String {
        "\(timestamp.string(from: date)) \(level) [\(category)] \(message)\n"
    }

    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public func append(_ line: String) {
        let data = Data(line.utf8)
        lock.withLock {
            guard let handle = openIfNeeded() else { return }
            if size > 0, size + data.count > limit {
                rotate()
                guard let fresh = openIfNeeded() else { return }
                write(data, to: fresh)
                return
            }
            write(data, to: handle)
        }
    }

    private func write(_ data: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        size = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: backupURL)
        try? manager.moveItem(at: url, to: backupURL)
        size = 0
    }
}
