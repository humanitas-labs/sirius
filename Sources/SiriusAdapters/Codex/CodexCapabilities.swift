import Foundation
import SiriusCore

// What the installed codex supports, by its version: Codex has no query for
// which config keys it accepts, and app-server exits at initialize on a -c
// key it parses differently. Read from `codex --version` ("codex-cli
// 0.159.1"); ChatGPT.app's copy prints the same.
public struct CodexCapabilities: Equatable, Sendable {
    // "0.159.1", "0.162.0-alpha.17.2". Nil when it could not be read:
    // everything is then taken as supported, as before the probe.
    public var version: String?

    public init(version: String?) {
        self.version = version
    }

    public static let unknown = CodexCapabilities(version: nil)

    // The oldest Codex Sirius runs: the oldest release macOS still runs,
    // which has every app-server method, thread/start and turn/start field,
    // input type and -c key Sirius uses (scripts/compat-test.sh). 0.131.0
    // and earlier are revoked or rejected by Gatekeeper (2026.10.12), so
    // nothing older could be checked.
    public static let floor = "0.132.0"

    // The first whose app-server accepts the features.multi_agent_v2 table.
    // Older ones read features.multi_agent_v2 as a plain flag and exit at
    // initialize: "data did not match any variant of untagged enum
    // FeatureToml in `features.multi_agent_v2`" (0.140.0 to 0.146.1).
    public static let multiAgentSettings = "0.147.0"

    public var isTooOld: Bool { !Self.atLeast(version, Self.floor) }

    public var supportsMultiAgentSettings: Bool { Self.atLeast(version, Self.multiAgentSettings) }

    // "codex-cli 0.159.1" → "0.159.1": the first word that starts with a digit.
    public static func parse(version output: String?) -> CodexCapabilities {
        let word = output?.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }
        return CodexCapabilities(version: word.map(String.init))
    }

    // Whether `version` is `minimum` or later, by semver precedence: a
    // prerelease comes before its release (0.147.0-alpha.1 < 0.147.0). An
    // unknown or unreadable version counts as new enough.
    static func atLeast(_ version: String?, _ minimum: String) -> Bool {
        guard let version, let have = Semver(version), let need = Semver(minimum) else { return true }
        return !(have < need)
    }

    struct Semver: Comparable {
        var numbers: [Int]
        var prerelease: Bool

        init?(_ text: String) {
            let core = text.split(separator: "-", maxSplits: 1)
            let numbers = core[0].split(separator: ".").map { Int($0) }
            guard numbers.count == 3, !numbers.contains(nil) else { return nil }
            self.numbers = numbers.compactMap { $0 }
            prerelease = core.count > 1
        }

        static func < (a: Semver, b: Semver) -> Bool {
            if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
            return a.prerelease && !b.prerelease
        }
    }
}

// Runs `codex --version` once per executable (ExecutableProbe), so an
// updated codex is probed afresh. A version that could not be read is tried
// again at the next start.
enum CodexProbe {
    static let shared = ExecutableProbe<CodexCapabilities>(
        isComplete: { $0.version != nil },
        probed: reportOmissions
    ) { executable, environment, timeout in
        CodexCapabilities.parse(version: await ProbeCommand.output(of: executable, ["--version"],
                                                                   environment: environment, timeout: timeout))
    }

    // Once per executable: what Sirius leaves out on this Codex, and what that costs.
    @Sendable private static func reportOmissions(_ capabilities: CodexCapabilities, executable: String) {
        guard !capabilities.isTooOld, !capabilities.supportsMultiAgentSettings else { return }
        SiriusLog.agents.info("codex \(capabilities.version ?? "") (\(executable)) predates "
            + "\(CodexCapabilities.multiAgentSettings), so Sirius leaves out features.multi_agent_v2: "
            + "the agent does its work itself instead of keeping helper agents, and helpers get no workers.md")
    }
}
