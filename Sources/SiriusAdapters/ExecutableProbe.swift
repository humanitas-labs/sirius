import Darwin
import Foundation

// What an agent CLI can do, read once per executable by running it (claude
// --help, codex --version), cached by its resolved path and modification
// date, so an update that repoints ~/.local/bin/claude or replaces codex is
// probed afresh. ClaudeProbe and CodexProbe each keep one.
actor ExecutableProbe<Value: Sendable> {
    typealias Run = @Sendable (_ executable: String, _ environment: [String: String],
                               _ timeout: TimeInterval) async -> Value

    private struct Key: Hashable {
        var path: String
        var modified: Date?
    }

    private var cache: [Key: Task<Value, Never>] = [:]
    let timeout: TimeInterval
    private let run: Run
    private let isComplete: @Sendable (Value) -> Bool
    private let probed: @Sendable (Value, String) -> Void

    // `isComplete` false (the CLI timed out or crashed) means the value is
    // tried again at the next start rather than kept. `probed` runs once per
    // executable with a complete value, e.g. to log what Sirius leaves out.
    init(timeout: TimeInterval = 5, isComplete: @escaping @Sendable (Value) -> Bool,
         probed: @escaping @Sendable (Value, String) -> Void = { _, _ in }, run: @escaping Run) {
        self.timeout = timeout
        self.isComplete = isComplete
        self.probed = probed
        self.run = run
    }

    func capabilities(executable: String, environment: [String: String]) async -> Value {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.modificationDate] as? Date
        let key = Key(path: resolved, modified: modified)
        if let task = cache[key] { return await task.value }
        let (run, timeout) = (self.run, self.timeout)
        let task = Task.detached { await run(executable, environment, timeout) }
        cache[key] = task
        let value = await task.value
        if isComplete(value) {
            probed(value, executable)
        } else {
            cache[key] = nil
        }
        return value
    }
}

enum ProbeCommand {
    // The command's stdout, or nil if it did not run or finish in time.
    // Runs on a global queue so the wait never holds a thread of the
    // cooperative pool.
    static func output(of executable: String, _ arguments: [String], environment: [String: String],
                       timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, environment: environment,
                                                           timeout: timeout))
            }
        }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String],
                                    timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do { try process.run() } catch { return nil }
        let box = Box()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = stdout.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        if read.wait(timeout: .now() + timeout) == .timedOut {
            ClaudeProcess.signal(process.processIdentifier, SIGKILL)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }
}
