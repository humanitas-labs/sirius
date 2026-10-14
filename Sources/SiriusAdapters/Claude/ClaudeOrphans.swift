import Darwin
import Foundation

// A `claude` left running by a Sirius that died without stopping it (a kill,
// a crash) keeps working on the session. The next Sirius resuming the same
// session would make two processes write one session file, so before it
// resumes, start ends any such orphan (#2).
//
// An orphan is one of the user's processes, reparented to launchd (ppid 1),
// whose arguments carry the flags only Sirius passes, with the session to
// resume: "--resume <session> --replay-user-messages" (ClaudeAdapter.arguments
// puts them in that order). A claude the user runs in a terminal has a shell
// for a parent and never matches.
enum ClaudeOrphans {
    struct Entry: Equatable {
        var pid: pid_t
        var ppid: pid_t
        var pgid: pid_t
        var uid: uid_t
        var arguments: String
    }

    // Ends every orphan on `session`: SIGTERM to its group, then SIGKILL
    // after `grace` seconds. Returns the pids it found.
    @discardableResult
    static func end(session: String, grace: Double = 3) async -> [pid_t] {
        let orphans = find(session: session, in: list())
        guard !orphans.isEmpty else { return [] }
        for orphan in orphans { ClaudeProcess.signal(orphan.pid, SIGTERM) }
        if await !waitForExit(orphans.map(\.pid), seconds: grace) {
            for orphan in orphans where kill(orphan.pid, 0) == 0 { ClaudeProcess.signal(orphan.pid, SIGKILL) }
            _ = await waitForExit(orphans.map(\.pid), seconds: grace)
        }
        return orphans.map(\.pid)
    }

    static func find(session: String, in entries: [Entry], uid: uid_t = getuid()) -> [Entry] {
        guard !session.isEmpty else { return [] }
        let marker = "--resume \(session) --replay-user-messages"
        return entries.filter { $0.ppid == 1 && $0.uid == uid && $0.arguments.contains(marker) }
    }

    // `ps -axww -o pid=,ppid=,pgid=,uid=,args=` as entries; empty when ps
    // fails, which leaves recovery as it was before.
    static func list() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,pgid=,uid=,args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                  let pgid = pid_t(fields[2]), let uid = uid_t(fields[3]) else { return nil }
            return Entry(pid: pid, ppid: ppid, pgid: pgid, uid: uid,
                         arguments: fields[4].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func waitForExit(_ pids: [pid_t], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while pids.contains(where: { kill($0, 0) == 0 }) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
