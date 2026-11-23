import Foundation
import SiriusCore
import SiriusProtocol

// Keeps an agent's model out of the user's own Cursor settings.
//
// `agent acp` saves every model it is asked to use, with the model's
// parameters, to cli-config.json in its config directory as the default for
// the person's own `agent` sessions; its ACP server has no way to set a
// session's model without saving it (2026.08.11 and issue #32). The CLI reads
// that directory from CURSOR_CONFIG_DIR, so each agent gets one of its own
// under its Sirius folder:
// - cli-config.json is a copy of the user's, made again at every open, so
//   their permissions, sandbox and other settings still apply and what the
//   agent's sessions save goes to the copy;
// - everything else there is a link to the user's, so sessions, skills and
//   plugins stay shared and a stored session still resumes.
// The sign-in is in the keychain and is not affected.
enum CursorConfig {
    static let variable = "CURSOR_CONFIG_DIR"
    static let settings = "cli-config.json"

    // The directory the CLI would use by itself, resolved as it does:
    // CURSOR_CONFIG_DIR, else $XDG_CONFIG_HOME/cursor, else ~/.cursor.
    static func userDirectory(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        func set(_ name: String) -> String? {
            guard let value = environment[name],
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        if let directory = set(variable) { return URL(fileURLWithPath: directory, isDirectory: true) }
        if let config = set("XDG_CONFIG_HOME") {
            return URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("cursor", isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cursor", isDirectory: true)
    }

    // Where one agent's own directory is.
    static func agentDirectory(agent: String, base: URL = AgentStorage.defaultBaseDirectory) -> URL {
        base.appendingPathComponent(agent, isDirectory: true).appendingPathComponent("cursor", isDirectory: true)
    }

    // Brings `own` up to date with `user` and returns the environment that
    // points the CLI at it.
    static func isolate(user: URL, own: URL, fileManager: FileManager = .default) throws -> [String: String] {
        try fileManager.createDirectory(at: own, withIntermediateDirectories: true)
        // Links whose target the user has since removed.
        for name in (try? fileManager.contentsOfDirectory(atPath: own.path)) ?? [] {
            let entry = own.appendingPathComponent(name)
            if (try? fileManager.destinationOfSymbolicLink(atPath: entry.path)) != nil,
               !fileManager.fileExists(atPath: entry.path) {
                try? fileManager.removeItem(at: entry)
            }
        }
        // A link for each thing of the user's that the agent's directory lacks.
        for name in (try? fileManager.contentsOfDirectory(atPath: user.path)) ?? [] where name != settings {
            let entry = own.appendingPathComponent(name)
            if (try? fileManager.attributesOfItem(atPath: entry.path)) == nil {
                try fileManager.createSymbolicLink(at: entry, withDestinationURL: user.appendingPathComponent(name))
            }
        }
        let copy = own.appendingPathComponent(settings)
        let source = user.appendingPathComponent(settings)
        if fileManager.fileExists(atPath: source.path) {
            try? fileManager.removeItem(at: copy)
            try fileManager.copyItem(at: source, to: copy)
        }
        return [variable: own.path]
    }
}
