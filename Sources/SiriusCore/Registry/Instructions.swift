import Foundation

// An agent's instructions are a file the user owns, not hardcoded:
// instructions.md in the agent's registry
// folder, passed to the agent when it starts. Setup seeds it from the app's
// template, which is shared by every harness with the parts that differ
// (how to call Sirius, how to keep a turn short) filled in from the
// harness's folder. The user edits it, or points to their own files with
// @path, Claude's import syntax. Neither CLI expands @ in a prompt Sirius
// passes (checked on Claude 2.1.296), so Sirius does: each @path that names
// an existing file is read and added after the text that names it,
// recursively, each file once, five levels deep as Claude does. A path is
// relative to the file naming it, or starts with ~/ or /. HTML comments are
// notes for people: refs in them are not followed and they are left out of
// the prompt, as are refs in code.
//
// Settings the text uses are in consts.md beside it, one `NAME: value` per
// line, so a user changes a number without touching the wording. Each {{NAME}} in the prompt
// is replaced by its value when the agent starts; a name consts.md lacks
// stays as written. consts.md is seeded like instructions.md, on its own.
public enum Instructions {
    public static let entrypoint = "instructions.md"
    // What a Codex agent's worker agents are given (seed).
    public static let workers = "workers.md"
    public static let consts = "consts.md"
    static let maxDepth = 5

    // The prompt for the entrypoint at `url`, or nil when it is absent.
    // Throws when the entrypoint exists but is not UTF-8; an included file
    // that can't be read is skipped.
    public static func compose(entrypoint url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let text = read(url) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        var seen: Set<String> = [url.standardizedFileURL.path]
        var parts = [stripComments(text)]
        include(refs(in: text, relativeTo: url.deletingLastPathComponent()), depth: 1, seen: &seen, into: &parts)
        let prompt = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let values = read(url.deletingLastPathComponent().appendingPathComponent(consts)).map(parseConsts) ?? [:]
        return fill(prompt) { values[$0] }
    }

    // `NAME: value` (or `NAME = value`) lines, a leading `- ` allowed;
    // NAME is upper case, digits and underscores. Other lines are notes.
    static func parseConsts(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in stripComments(text).components(separatedBy: "\n") {
            var body = Substring(line.trimmingCharacters(in: .whitespaces))
            if body.hasPrefix("- ") || body.hasPrefix("* ") { body = body.dropFirst(2) }
            guard let separator = body.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let name = body[..<separator].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty,
                  name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { continue }
            values[name] = value
        }
        return values
    }

    // Each {{name}} with a value replaced; the rest left as written.
    static func fill(_ text: String, _ value: (String) -> String?) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = String(rest[open.upperBound..<close.lowerBound])
            result += rest[..<open.lowerBound]
            result += value(name) ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private static func include(_ urls: [URL], depth: Int, seen: inout Set<String>, into parts: inout [String]) {
        guard depth <= maxDepth else { return }
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), let text = read(url) else { continue }
            seen.insert(path)
            parts.append(stripComments(text))
            include(refs(in: text, relativeTo: url.deletingLastPathComponent()), depth: depth + 1,
                    seen: &seen, into: &parts)
        }
    }

    private static func read(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // The files named by @path outside comments and code, in order, that
    // exist. An @ inside a word (an email address) is not a ref.
    static func refs(in text: String, relativeTo folder: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        var inFence = false
        for line in stripComments(text).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let prose = line.split(separator: "`", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: " ")
            for word in prose.split(whereSeparator: \.isWhitespace) where word.hasPrefix("@") {
                var path = String(word.dropFirst())
                while let last = path.last, ".,;:!?)]\"'".contains(last) { path.removeLast() }
                guard !path.isEmpty else { continue }
                let url: URL
                if path.hasPrefix("~/") {
                    url = home.appendingPathComponent(String(path.dropFirst(2)))
                } else if path.hasPrefix("/") {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = folder.appendingPathComponent(path)
                }
                if read(url) != nil { urls.append(url) }
            }
        }
        return urls
    }

    static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "-->") else { return result }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    // Writes an agent's instructions.md, workers.md and consts.md from the
    // templates when it lacks them: at setup, and for an agent registered
    // before they were files. `template` is the shared instructions.md, with
    // consts.md and the shared parts beside it. Each {{name}} in it is
    // replaced by the first <name>.md found in the harness's folder, then
    // the shared folder, trimmed and filled the same way; any other {{NAME}}
    // is left for consts.md. A harness whose folder has a workers/ folder
    // (Codex, whose worker agents are given their own instructions) also
    // gets workers.md: the same template with workers/ looked in first. A
    // file the user has, even empty, is never touched. Returns whether it
    // wrote.
    @discardableResult
    public static func seed(folder: URL, template: URL, harness: URL) throws -> Bool {
        var wrote = false
        let shared = template.deletingLastPathComponent()
        var targets = [(entrypoint, [harness, shared])]
        let workerParts = harness.appendingPathComponent("workers", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workerParts.path, isDirectory: &isDirectory), isDirectory.boolValue {
            targets.append((workers, [workerParts, harness, shared]))
        }
        if let text = read(template) {
            for (name, parts) in targets {
                let target = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                try fill(text, parts: parts, depth: 1).write(to: target, atomically: true, encoding: .utf8)
                wrote = true
            }
        }
        let constsTarget = folder.appendingPathComponent(consts)
        if !FileManager.default.fileExists(atPath: constsTarget.path),
           let text = read(shared.appendingPathComponent(consts)) {
            try text.write(to: constsTarget, atomically: true, encoding: .utf8)
            wrote = true
        }
        return wrote
    }

    // Template slots, filled from the first folder with <name>.md.
    private static func fill(_ text: String, parts: [URL], depth: Int) -> String {
        fill(text) { name in
            guard depth <= maxDepth,
                  let part = parts.lazy.compactMap({ read($0.appendingPathComponent(name + ".md")) }).first
            else { return nil }
            return fill(part.trimmingCharacters(in: .whitespacesAndNewlines), parts: parts, depth: depth + 1)
        }
    }
}
