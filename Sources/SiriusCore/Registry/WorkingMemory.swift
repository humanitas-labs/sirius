import Foundation
import SiriusMemory

// Working memory: WMEM.md in ~/.agents/sirius, beside the registry folder,
// a short list of pointers to what the user refers to, which an agent's
// instructions include with @~/.agents/sirius/WMEM.md. The agents keep it with the
// wmem helper (target wmem, in Sirius.app/Contents/Helpers) and
// clean it up as gc.md says: a prompt, not a script. gc.md beside WMEM.md
// is shared by every agent; an agent's own registry/<agent>/gc.md takes its
// place. Both are seeded from the app's templates, never over a user's file.
//
// Sirius only decides when: once WMEM.md's size, characters / 4 as
// `wmem ls` counts it, is over the agent's WMEM_TOKEN_LIMIT (consts.md,
// 2000 when it has none), Sirius sends that agent a turn of its own
// carrying the gc prompt (WorkingMemoryTrigger says when; AgentHost sends).
public enum WorkingMemory {
    public static let file = "WMEM.md"
    public static let cleanup = "gc.md"
    public static let limitName = "WMEM_TOKEN_LIMIT"
    public static let defaultLimit = 2000

    // Writes WMEM.md and gc.md into `folder` from the templates beside the
    // shared instructions.md when it lacks them. A file the user has, even
    // empty, is never touched. Returns whether it wrote.
    @discardableResult
    public static func seed(into folder: URL, templates: URL) throws -> Bool {
        var wrote = false
        for name in [file, cleanup] {
            let target = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path),
                  let text = try? String(contentsOf: templates.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
            wrote = true
        }
        return wrote
    }

    // The size estimate `wmem ls` prints: characters (code points) / 4.
    public static func tokens(_ text: String) -> Int {
        WmemFormat.tokens(text)
    }

    // The header's Cleaned: date, as written ("never" too); "never" when
    // the file has no header, as wmem reads it.
    public static func cleaned(_ text: String) -> String {
        WmemFormat.header(WmemFormat.lines(text)).cleaned
    }

    // The agent's WMEM_TOKEN_LIMIT from consts.md in its registry folder;
    // the default when absent or not a positive number.
    public static func limit(agentFolder: URL) -> Int {
        let url = agentFolder.appendingPathComponent(Instructions.consts)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Instructions.parseConsts(text)[limitName].flatMap({ Int($0) }), value > 0
        else { return defaultLimit }
        return value
    }

    // Whether the agent's instructions.md includes `memory`, directly or
    // through a file it includes. Symlinks are resolved on both sides.
    public static func isIncluded(_ memory: URL, agentFolder: URL) -> Bool {
        let target = canonical(memory)
        return Instructions.included(entrypoint: agentFolder.appendingPathComponent(Instructions.entrypoint))
            .contains { canonical($0) == target }
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // The cleanup prompt for the agent: its own gc.md, else the shared one
    // in `agents`, else the app's template; nil when none can be read.
    public static func cleanupText(agentFolder: URL, agents: URL, templates: URL) -> String? {
        for folder in [agentFolder, agents, templates] {
            if let text = try? String(contentsOf: folder.appendingPathComponent(cleanup), encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    // The turn Sirius sends: why now, then the cleanup prompt as written.
    // TODO(copy): wording.
    public static func prompt(memory: URL, tokens: Int, limit: Int, cleanup: String) -> String {
        let path = (memory.path as NSString).abbreviatingWithTildeInPath
        return "Working memory (\(path)) is at about \(tokens) tokens, over your limit of \(limit) "
            + "(\(limitName) in consts.md). Clean it up now by editing the file, as below.\n\n"
            + cleanup.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// When to ask for a cleanup: once per crossing of the limit. After a
// request it stays quiet until the size is back at or under the limit or
// the Cleaned: date changes (someone ran `wmem cleaned`); the next check
// over the limit then asks again. Lives as long as the app, so a restart
// with the file still over the limit asks once more.
public struct WorkingMemoryTrigger: Equatable, Sendable {
    // Whether a check over the limit asks.
    public private(set) var armed = true
    // The Cleaned: date when it last asked.
    private var cleanedWhenAsked: String?

    public init() {}

    // Whether to ask now, given the file's size, the limit and its Cleaned:
    // date. Asking disarms it.
    public mutating func shouldAsk(tokens: Int, limit: Int, cleaned: String) -> Bool {
        if !armed, tokens <= limit || cleaned != cleanedWhenAsked { armed = true }
        guard armed, tokens > limit else { return false }
        armed = false
        cleanedWhenAsked = cleaned
        return true
    }
}

// Calls `onChange` when the file at `file` may have changed: a write to it,
// or a change to its folder's entries, which is how an atomic save (wmem's
// own, most editors') replaces it. The file is watched again after each
// folder change, since a replaced file is a new one. A missing folder is
// not watched. Changes come in bursts; the caller's check is idempotent.
public final class FileWatcher: @unchecked Sendable {
    private let file: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "sirius.file-watcher")
    // Guarded by queue.
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    public init(file: URL, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.onChange = onChange
    }

    deinit {
        folderSource?.cancel()
        fileSource?.cancel()
    }

    public func start() {
        queue.sync {
            guard folderSource == nil else { return }
            folderSource = source(file.deletingLastPathComponent(), [.write]) { [weak self] _ in
                self?.watchFile()
                self?.onChange()
            }
            watchFile()
        }
    }

    public func stop() {
        queue.sync {
            folderSource?.cancel()
            fileSource?.cancel()
            folderSource = nil
            fileSource = nil
        }
    }

    // On queue.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = source(file, [.write, .extend, .delete, .rename]) { [weak self] _ in self?.onChange() }
    }

    private func source(_ url: URL, _ mask: DispatchSource.FileSystemEvent,
                        _ handler: @escaping (DispatchSource.FileSystemEvent) -> Void)
        -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
