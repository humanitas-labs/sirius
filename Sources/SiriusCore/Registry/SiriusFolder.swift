import Foundation

// ~/.agents is shared with other tools: the registry and skills folders in
// it are meant to be read by any of them. What only Sirius uses (working
// memory, its log, the cleanup prompt and the shared rules) is kept out of
// their way in ~/.agents/sirius. These files were once directly in
// ~/.agents; migrate moves them and corrects the paths that name them.
public enum SiriusFolder {
    public static let name = "sirius"

    // The files that moved, by name.
    public static let files = [WorkingMemory.file, "wmem.log", WorkingMemory.cleanup] + Instructions.shared

    // `agents` is the registry folder's parent, ~/.agents.
    public static func directory(agents: URL) -> URL {
        agents.appendingPathComponent(name, isDirectory: true)
    }

    // Moves each file still directly in `agents` into its sirius folder, and
    // rewrites ~/.agents/<file> to ~/.agents/sirius/<file> in each agent's
    // instructions and the files under `agents` they include. A file already
    // in the sirius folder is never replaced: the old one is left where it
    // is, except a shared rule, which is the app's and is removed. A path is
    // rewritten only once its file is in `home`'s sirius folder and no
    // longer beside it, so a registry elsewhere (testing) changes nothing
    // until the user's own folder has moved. Safe to run on every start.
    @discardableResult
    public static func migrate(agents: URL, agentFolders: [URL],
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               fileManager: FileManager = .default) throws -> Bool {
        var wrote = false
        // Before the move, while every include still resolves.
        let texts = referencing(agents: agents, agentFolders: agentFolders)
        let own = directory(agents: agents)
        for name in files {
            let old = agents.appendingPathComponent(name)
            let new = own.appendingPathComponent(name)
            guard isFile(old, fileManager) else { continue }
            if !fileManager.fileExists(atPath: new.path) {
                try fileManager.createDirectory(at: own, withIntermediateDirectories: true)
                try fileManager.moveItem(at: old, to: new)
                wrote = true
            } else if Instructions.shared.contains(name) {
                try fileManager.removeItem(at: old)
                wrote = true
            }
        }
        let shared = home.appendingPathComponent(".agents", isDirectory: true)
        let moved = files.filter {
            isFile(directory(agents: shared).appendingPathComponent($0), fileManager)
                && !fileManager.fileExists(atPath: shared.appendingPathComponent($0).path)
        }
        guard !moved.isEmpty else { return wrote }
        let candidates = texts + files.map { own.appendingPathComponent($0) }.filter { $0.pathExtension == "md" }
        for url in candidates {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            var rewritten = text
            for name in moved {
                rewritten = rewritten.replacingOccurrences(of: "~/.agents/\(name)", with: "~/.agents/\(Self.name)/\(name)")
            }
            guard rewritten != text else { continue }
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            wrote = true
        }
        return wrote
    }

    // Each agent's own text files, and the files under `agents` that its
    // instructions include (the user's shared rules), each once.
    private static func referencing(agents: URL, agentFolders: [URL]) -> [URL] {
        let root = agents.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var seen: Set<String> = []
        var urls: [URL] = []
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted { urls.append(url) }
        }
        for folder in agentFolders {
            for name in [Instructions.entrypoint, Instructions.workers, Instructions.consts, WorkingMemory.cleanup] {
                add(folder.appendingPathComponent(name))
            }
            for name in [Instructions.entrypoint, Instructions.workers] {
                for url in Instructions.included(entrypoint: folder.appendingPathComponent(name))
                where url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) {
                    add(url)
                }
            }
        }
        return urls
    }

    private static func isFile(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
