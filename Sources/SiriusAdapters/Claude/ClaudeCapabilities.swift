import Foundation
import SiriusCore

// What the installed claude accepts, read from its --help. A CLI exits at
// once on an option it doesn't know (2.1.212: "error: unknown option
// '--system-prompt-snapshot'"), so ClaudeAdapter leaves out the optional
// flags a CLI lacks and refuses to start one that lacks a required flag.
public struct ClaudeCapabilities: Equatable, Sendable {
    // Every long option help lists, aliases included ("--allowedTools" and
    // "--allowed-tools"). Nil when help could not be read: everything is
    // then taken as supported, as before the probe.
    public var options: Set<String>?
    // --permission-mode's choices, when help lists them.
    public var permissionModes: [String]?
    // The first word of `claude --version`, e.g. "2.1.296".
    public var version: String?

    public init(options: Set<String>?, permissionModes: [String]? = nil, version: String? = nil) {
        self.options = options
        self.permissionModes = permissionModes
        self.version = version
    }

    // Help unread: assume a CLI that has everything.
    public static let unknown = ClaudeCapabilities(options: nil)

    // The flags Sirius cannot run Claude without: headless stream-json in
    // and out, the echo that ties results to our lines, the tool list that
    // lets the agent reach the user, and auto mode (below).
    public static let required = ["--print", "--input-format", "--output-format", "--verbose",
                                  "--permission-mode", "--replay-user-messages", "--allowedTools"]

    public func supports(_ option: String) -> Bool {
        options?.contains(option) ?? true
    }

    // Auto mode, so a headless agent is never blocked on a permission
    // prompt. Never replaced by a looser mode. A help that lists no choices
    // is taken at its word that the option exists.
    public var supportsAutoMode: Bool {
        supports("--permission-mode") && (permissionModes?.contains("auto") ?? true)
    }

    // What is missing of the required, as the user would name it; empty
    // when Claude can run.
    public var missingRequired: [String] {
        var missing = Self.required.filter { !supports($0) }
        if supports("--permission-mode"), !supportsAutoMode { missing.append("--permission-mode auto") }
        return missing
    }

    // Reads `claude --help` (commander's layout: an option starts its line
    // after two spaces; its description follows on the same line or on
    // lines indented further) and `claude --version`.
    public static func parse(help: String, version: String? = nil) -> ClaudeCapabilities {
        var options = Set<String>()
        // Each option's line and the description lines under it.
        var blocks: [String: String] = [:]
        var current: [String] = []
        for raw in help.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("  -") {
                // "  -n, --name <name>      Set a display name…": the names
                // end at the first double space or at the end of the line.
                let head = line.dropFirst(2).components(separatedBy: "  ")[0]
                current = head.split(separator: ",").compactMap { part in
                    let word = part.trimmingCharacters(in: .whitespaces)
                        .split(whereSeparator: { $0 == " " || $0 == "=" }).first.map(String.init)
                    return word?.hasPrefix("--") == true ? word : nil
                }
                for name in current {
                    options.insert(name)
                    blocks[name] = line
                }
            } else if line.hasPrefix("   "), !current.isEmpty {
                for name in current { blocks[name, default: ""] += "\n" + line }
            } else {
                current = []
            }
        }
        guard !options.isEmpty else {
            return ClaudeCapabilities(options: nil, version: parseVersion(version))
        }
        return ClaudeCapabilities(options: options, permissionModes: blocks["--permission-mode"].flatMap(choices),
                                  version: parseVersion(version))
    }

    // `(choices: "acceptEdits", "auto", …)` in an option's description,
    // which help may wrap across lines.
    static func choices(in block: String) -> [String]? {
        let flat = block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let start = flat.range(of: "(choices: ") else { return nil }
        let rest = flat[start.upperBound...]
        let list = rest[..<(rest.firstIndex(of: ")") ?? rest.endIndex)]
        let values = list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty && !$0.contains(":") }
        return values.isEmpty ? nil : values
    }

    // "2.1.296 (Claude Code)" → "2.1.296".
    static func parseVersion(_ output: String?) -> String? {
        guard let word = output?.split(whereSeparator: \.isWhitespace).first,
              word.first?.isNumber == true else { return nil }
        return String(word)
    }
}

// Runs `claude --help` and `claude --version` once per executable
// (ExecutableProbe), so a `claude update` is probed afresh. A help that could
// not be read is tried again at the next start.
enum ClaudeProbe {
    static let shared = ExecutableProbe<ClaudeCapabilities>(
        isComplete: { $0.options != nil },
        probed: reportOmissions
    ) { executable, environment, timeout in
        async let help = ProbeCommand.output(of: executable, ["--help"], environment: environment, timeout: timeout)
        async let version = ProbeCommand.output(of: executable, ["--version"], environment: environment,
                                                timeout: timeout)
        return ClaudeCapabilities.parse(help: await help ?? "", version: await version)
    }

    // Once per executable: what Sirius leaves out on this CLI, and what that costs.
    @Sendable private static func reportOmissions(_ capabilities: ClaudeCapabilities, executable: String) {
        let costs: [(String, String)] = [
            ("--system-prompt-snapshot", "an edited instructions.md won't reach a resumed session"),
            ("--effort", "the registered effort is not applied"),
            ("--name", "the session goes by Claude's own name"),
            ("--settings", "fast mode is not applied"),
        ]
        let version = capabilities.version.map { " \($0)" } ?? ""
        for (option, cost) in costs where !capabilities.supports(option) {
            SiriusLog.agents.info("claude\(version) (\(executable)) has no \(option), so Sirius leaves it out: \(cost)")
        }
    }
}
