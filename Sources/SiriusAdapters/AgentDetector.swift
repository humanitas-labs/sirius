import Foundation
import SiriusProtocol

// Finds each harness's CLI for setup. An app opened from the Finder
// gets launchd's PATH, not the user's shell's, so the CLI is looked for in
// the user's login shell first, then in the places the installers use.
public struct AgentDetector: Sendable {
    // The command each harness installs.
    public static func command(for harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    // Install locations, relative to the home folder or absolute: Claude's
    // native installer (~/.local/bin), its older local install
    // (~/.claude/local), Homebrew, npm, bun, Volta and pnpm globals.
    public static let searchDirectories = [
        "~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin", "~/Library/pnpm",
    ]

    private let home: String
    private let shell: String?
    private let isExecutable: @Sendable (String) -> Bool
    private let lookUp: @Sendable (_ shell: String, _ command: String) -> String?

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                lookUp: @escaping @Sendable (_ shell: String, _ command: String) -> String? = AgentDetector.shellLookUp) {
        self.home = home
        self.shell = shell
        self.isExecutable = isExecutable
        self.lookUp = lookUp
    }

    // The absolute path of the harness's CLI, or nil when it is not installed.
    public func find(_ harness: AgentRegistration.Harness) -> String? {
        let command = Self.command(for: harness)
        if let shell, let path = lookUp(shell, command), path.hasPrefix("/"), isExecutable(path) {
            return path
        }
        var candidates = Self.searchDirectories.map { $0 + "/" + command }
        // The ChatGPT app carries its own codex, which CodexAdapter also falls back to.
        if harness == .codex {
            candidates += ["/Applications/", "~/Applications/"].map { $0 + CodexLaunch.bundledSuffix }
        }
        for candidate in candidates {
            let path = candidate.hasPrefix("~/") ? home + candidate.dropFirst() : candidate
            if isExecutable(path) { return path }
        }
        return nil
    }

    // `command -v <command>` in the user's login, interactive shell, which
    // reads the profile that sets PATH. Bounded at 5 s; nil on any failure.
    // The last line is taken, since a profile may print before it.
    public static func shellLookUp(shell: String, command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // A root setup accepts: an existing folder that is neither the home
    // folder nor the disk's root, so an agent never works across everything
    // the user has.
    public func isAcceptableRoot(_ path: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        guard standard.hasPrefix("/"), standard != "/", standard != (home as NSString).standardizingPath else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: standard, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
