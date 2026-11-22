import Foundation
import SiriusProtocol

// The folders each harness already trusts, so onboarding can give each agent
// a folder without asking. Claude Code keeps them in
// ~/.claude.json (`projects`, an entry per folder with
// `hasTrustDialogAccepted`), Codex in ~/.codex/config.toml
// (`[projects."<path>"]` with `trust_level = "trusted"`). Each harness's
// folders stay its own: Claude's never go to Codex, nor Codex's to Claude.
// Muse Code keeps them in ~/.config/muse/trust.json (`projects`, an entry
// per folder with `decision` "trusted"), with no last-use time.
// Antigravity keeps them in ~/.gemini/antigravity-cli/settings.json
// (`trustedWorkspaces`, a list of paths), with no last-use time either.
// Cursor's CLI does not document where it keeps its own, and OpenCode
// keeps its projects in a SQLite database rather than a readable file, so
// both have none here and their agents' folders are chosen by hand.
//
// Only the keys named here are read. ~/.claude.json holds much else; none of
// it is decoded, logged or copied.
public struct TrustedFolders: Sendable {
    // A trusted folder, with when the harness last used it, if known.
    public struct Folder: Equatable, Sendable {
        public var path: String
        public var lastUsed: Date?

        public init(path: String, lastUsed: Date? = nil) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    // Folders whose known last use is older than this are left out.
    public static let recentWindow: TimeInterval = 90 * 24 * 3600
    // Where the system keeps temporary folders; none is a working folder.
    public static let temporaryPrefixes = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    private let home: String
    private let now: @Sendable () -> Date
    private let isDirectory: @Sendable (String) -> Bool
    private let modified: @Sendable (String) -> Date?
    private let temporary: [String]

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                now: @escaping @Sendable () -> Date = { Date() },
                isDirectory: @escaping @Sendable (String) -> Bool = { TrustedFolders.directoryExists($0) },
                modified: @escaping @Sendable (String) -> Date? = { TrustedFolders.modificationDate($0) },
                temporaryPrefixes: [String] = TrustedFolders.temporaryPrefixes) {
        self.home = home
        self.temporary = temporaryPrefixes
        self.now = now
        self.isDirectory = isDirectory
        self.modified = modified
    }

    // The harness's trusted folders that can be working folders, most
    // recently used first: existing, not temporary, neither the home folder
    // nor the disk's root, and not long unused. Empty when the file is
    // missing or unreadable.
    public func folders(for harness: AgentRegistration.Harness) -> [String] {
        let found: [Folder]
        switch harness {
        case .claudeCode:
            guard let data = FileManager.default.contents(atPath: home + "/.claude.json") else { return [] }
            found = Self.claude(json: data).map { folder in
                // Claude's own timestamps are sparse; its transcripts'
                // folder dates every session there.
                var folder = folder
                if folder.lastUsed == nil {
                    folder.lastUsed = modified(home + "/.claude/projects/" + Self.claudeProjectKey(folder.path))
                }
                return folder
            }
        case .codex:
            guard let data = FileManager.default.contents(atPath: home + "/.codex/config.toml") else { return [] }
            found = Self.codex(toml: String(decoding: data, as: UTF8.self))
        case .museCode:
            guard let data = FileManager.default.contents(atPath: home + "/.config/muse/trust.json") else { return [] }
            found = Self.muse(json: data)
        case .antigravity:
            guard let data = FileManager.default.contents(atPath: home + "/.gemini/antigravity-cli/settings.json")
            else { return [] }
            found = Self.antigravity(json: data)
        case .cursor:
            return []
        case .opencode:
            // OpenCode has no trust gate of its own: it works in any
            // folder, asking permission for each action. Its project list
            // lives in a SQLite database (~/.local/share/opencode/
            // opencode.db), which Sirius does not read; its agent's folder
            // is chosen by hand, as Cursor's is.
            return []
        }
        return rank(found)
    }

    // Filters and orders: those with a known last use first, newest first;
    // then the rest, the later in the file first, as each harness appends a
    // folder as it is trusted.
    func rank(_ found: [Folder]) -> [String] {
        let cutoff = now().addingTimeInterval(-Self.recentWindow)
        var seen = Set<String>()
        let usable = found.enumerated().filter { _, folder in
            let path = (folder.path as NSString).standardizingPath
            guard seen.insert(path).inserted, isUsable(path) else { return false }
            if let lastUsed = folder.lastUsed, lastUsed < cutoff { return false }
            return true
        }
        return usable.sorted { a, b in
            switch (a.element.lastUsed, b.element.lastUsed) {
            case let (x?, y?): x != y ? x > y : a.offset > b.offset
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset > b.offset
            }
        }.map { ($0.element.path as NSString).standardizingPath }
    }

    func isUsable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path != (home as NSString).standardizingPath else { return false }
        if Self.isTemporary(path, prefixes: temporary) { return false }
        if isScratch(path) { return false }
        return isDirectory(path)
    }

    // Folders a harness makes for itself, one per chat, which it then
    // trusts: the Codex app's ~/Documents/Codex/<date>/<chat>. None is
    // a project.
    public static let scratchRoots = ["Documents/Codex"]

    func isScratch(_ path: String) -> Bool {
        Self.scratchRoots.contains { root in
            let full = (home as NSString).appendingPathComponent(root)
            return path == full || path.hasPrefix(full + "/")
        }
    }

    public static func isTemporary(_ path: String, prefixes: [String] = temporaryPrefixes) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: Claude Code

    // Only `projects`, and in each entry only the trust flag and the two
    // last-used times; JSONDecoder skips every other key unread.
    private struct ClaudeConfig: Decodable {
        struct Project: Decodable {
            var hasTrustDialogAccepted: Bool?
            var lastStartTime: Double?
            var lastSessionModified: Double?
        }
        var projects: [String: Project]?
    }

    // The folders whose trust dialog was accepted, in no particular order
    // (a JSON object has none), with their last use from Claude's own times
    // (milliseconds since 1970).
    public static func claude(json: Data) -> [Folder] {
        guard let config = try? JSONDecoder().decode(ClaudeConfig.self, from: json),
              let projects = config.projects else { return [] }
        return projects.keys.sorted().compactMap { path in
            guard let project = projects[path], project.hasTrustDialogAccepted == true else { return nil }
            let times = [project.lastStartTime, project.lastSessionModified].compactMap { $0 }
            let lastUsed = times.max().map { Date(timeIntervalSince1970: $0 / 1000) }
            return Folder(path: path, lastUsed: lastUsed)
        }
    }

    // The folder under ~/.claude/projects holding a project's transcripts:
    // its path with every character but a letter or digit made "-".
    public static func claudeProjectKey(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }

    // MARK: Codex

    // The `[projects."<path>"]` tables with `trust_level = "trusted"`, in
    // file order. Enough TOML for what Codex writes: basic or literal
    // quoted keys, and the key read up to the next table.
    public static func codex(toml: String) -> [Folder] {
        var folders: [Folder] = []
        var current: String?
        var trusted = false
        func close() {
            if let current, trusted { folders.append(Folder(path: current)) }
            current = nil
            trusted = false
        }
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                close()
                current = projectPath(header: line)
                continue
            }
            guard current != nil, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "trust_level" else { continue }
            let value = parts[1].split(separator: "#", maxSplits: 1).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            trusted = value == "\"trusted\"" || value == "'trusted'"
        }
        close()
        return folders
    }

    // `[projects."/a/b"]` or `[projects.'/a/b']` to "/a/b"; nil for any
    // other table.
    static func projectPath(header: String) -> String? {
        guard header.hasPrefix("[projects."), header.hasSuffix("]"), !header.hasPrefix("[[") else { return nil }
        let key = header.dropFirst("[projects.".count).dropLast()
        guard key.count >= 2, let quote = key.first, quote == "\"" || quote == "'", key.last == quote else {
            return nil
        }
        let inner = String(key.dropFirst().dropLast())
        guard quote == "\"" else { return inner }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: The file system

    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Muse Code

    private struct MuseTrust: Decodable {
        struct Project: Decodable { var decision: String? }
        var projects: [String: Project]?
    }

    // The folders trust.json marks "trusted", in key order: the file keeps
    // no last-use time.
    static func muse(json: Data) -> [Folder] {
        guard let trust = try? JSONDecoder().decode(MuseTrust.self, from: json) else { return [] }
        return (trust.projects ?? [:]).filter { $0.value.decision == "trusted" }.keys.sorted()
            .map { Folder(path: $0) }
    }

    // MARK: Antigravity

    private struct AntigravitySettings: Decodable {
        var trustedWorkspaces: [String]?
    }

    // The folders in `trustedWorkspaces`, in file order: the CLI appends
    // each as it is trusted.
    static func antigravity(json: Data) -> [Folder] {
        guard let settings = try? JSONDecoder().decode(AntigravitySettings.self, from: json) else { return [] }
        return (settings.trustedWorkspaces ?? []).map { Folder(path: $0) }
    }
}
