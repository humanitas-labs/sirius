import Foundation

// The wmem CLI: working memory's bookkeeping, a port of the Python
// reference that behaves as it did (the commands, WMEM.md and wmem.log,
// the output, the messages and the exit codes). What to keep or drop is
// the agent's call, per gc.md beside WMEM.md.
//
// The log is wmem.log beside WMEM.md, one event per line:
// `YYYY-MM-DDTHH:MM<TAB>event<TAB>name<TAB>detail`, local time. Events are
// add, rm, hit, regret (an entry added back after it was removed), window
// and cleaned.
public struct Wmem {
    public static let usage = """
        wmem: keep working memory, the pointers an agent needs to resolve what the user refers to without searching or
        asking. Bookkeeping only: what to keep or drop is the agent's call, per gc.md (cleanup) beside WMEM.md.
          wmem ls                       entries, stalest first, with last use and hits; then window, size and regrets
          wmem add NAME TEXT... [--pin] add or replace an entry (--pin: Pinned, never cleaned up automatically)
          wmem rm NAME...               remove entries
          wmem hit NAME...              log that an entry resolved a reference
          wmem window [DAYS]            show or set the cleanup window
          wmem cleaned                  stamp today as the last cleanup
        Files: $WMEM_FILE (default ~/.agents/sirius/WMEM.md) and wmem.log beside it, one tab-separated event per line.
        """
    public static let commands = ["ls", "add", "rm", "hit", "window", "cleaned"]

    public var file: URL
    public var log: URL
    // The clock and the zone its dates and times are read in.
    public var now: () -> Date
    public var timeZone: TimeZone
    public var out: (String) -> Void
    public var err: (String) -> Void

    public init(file: URL, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
                out: @escaping (String) -> Void, err: @escaping (String) -> Void) {
        self.file = file
        log = file.deletingLastPathComponent().appendingPathComponent("wmem.log")
        self.now = now
        self.timeZone = timeZone
        self.out = out
        self.err = err
    }

    // $WMEM_FILE with ~ expanded, else ~/.agents/sirius/WMEM.md; ~ is $HOME.
    public static func file(environment: [String: String]) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        guard let path = environment["WMEM_FILE"], !path.isEmpty else {
            return URL(fileURLWithPath: home).appendingPathComponent(".agents/sirius").appendingPathComponent("WMEM.md")
        }
        if path == "~" { return URL(fileURLWithPath: home) }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: home + String(path.dropFirst(1))) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // Runs `wmem <arguments>` (without the program name); returns the exit
    // status. Usage goes to stderr: status 0 with no command, 1 for an
    // unknown one.
    public func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first, Self.commands.contains(command) else {
            err(Self.usage + "\n")
            return arguments.isEmpty ? 0 : 1
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "ls": try ls()
            case "add": try add(rest)
            case "rm": try rm(rest)
            case "hit": try hit(rest)
            case "window": try window(rest)
            default: try cleaned()
            }
            return 0
        } catch let failure as Failure {
            err(failure.message + "\n")
            return 1
        } catch {
            err("wmem: \(error)\n")
            return 1
        }
    }

    // A message for stderr and status 1: die() in the reference, or what
    // its uncaught exception would have ended with.
    struct Failure: Error {
        var message: String

        static func die(_ message: String) -> Failure { Failure(message: "wmem: \(message)") }
    }

    // MARK: Commands

    func add(_ arguments: [String]) throws {
        let pin = arguments.contains("--pin")
        let arguments = arguments.filter { $0 != "--pin" }
        guard arguments.count >= 2 else { throw Failure.die("usage: wmem add NAME TEXT... [--pin]") }
        let name = arguments[0]
        let text = PythonText.strip(arguments.dropFirst().joined(separator: " "))
        guard WmemFormat.isValidName(name) else {
            throw Failure.die("name \(PythonText.repr(name)): use lowercase letters, digits and dashes")
        }
        guard !text.unicodeScalars.contains("\n"), !text.isEmpty else {
            throw Failure.die("text must be one non-empty line")
        }
        var lines = try read()
        let existing = WmemFormat.entries(lines).filter { $0.name == name }
        let section = pin ? "Pinned" : (existing.first?.section ?? "Learned")
        for entry in existing.sorted(by: { $0.index > $1.index }) { lines.remove(at: entry.index) }
        var end = WmemFormat.sectionEnd(&lines, section)
        if end > 0, PythonText.startsWith(lines[end - 1], "## ") {
            lines.insert("", at: end)
            end += 1
        }
        lines.insert("- \(name): \(text)", at: end)
        try write(lines)
        let removed = try events().filter { $0.event == "rm" && $0.name == name }
        if let last = removed.last, existing.isEmpty {
            let date = PythonText.prefix(last.time, 10)
            try append("regret", name, "removed \(date)")
            out("wmem: \(name) was removed on \(date); logged as a regret\n")
        }
        try append("add", name, section)
    }

    func rm(_ names: [String]) throws {
        guard !names.isEmpty else { throw Failure.die("usage: wmem rm NAME...") }
        var lines = try read()
        var found: [String: WmemFormat.Entry] = [:]
        for entry in WmemFormat.entries(lines) { found[entry.name] = entry }
        let missing = names.filter { found[$0] == nil }
        guard missing.isEmpty else { throw Failure.die("no entry: \(missing.joined(separator: ", "))") }
        // A name given twice deletes twice, as the reference does.
        for index in names.compactMap({ found[$0]?.index }).sorted(by: >) {
            guard index < lines.count else {
                throw Failure(message: "IndexError: list assignment index out of range")
            }
            lines.remove(at: index)
        }
        try write(lines)
        for name in names { try append("rm", name, found[name]!.section) }
    }

    func hit(_ names: [String]) throws {
        guard !names.isEmpty else { throw Failure.die("usage: wmem hit NAME...") }
        let known = Set(WmemFormat.entries(try read()).map(\.name))
        for name in names {
            if !known.contains(name) { err("wmem: no entry \(PythonText.repr(name)); logged anyway\n") }
            try append("hit", name)
        }
    }

    func window(_ arguments: [String]) throws {
        var lines = try read()
        guard let days = arguments.first else {
            out(WmemFormat.header(lines).window + "\n")
            return
        }
        guard PythonText.isDigit(days) else { throw Failure.die("window is a whole number of days") }
        guard let value = PythonText.integerText(days) else {
            throw Failure(message: "ValueError: invalid literal for int() with base 10: \(PythonText.repr(days))")
        }
        guard value != "0" else { throw Failure.die("window is a whole number of days") }
        WmemFormat.setHeader(&lines, window: value)
        try write(lines)
        try append("window", "", days)
    }

    func cleaned() throws {
        var lines = try read()
        WmemFormat.setHeader(&lines, cleaned: today())
        try write(lines)
        try append("cleaned")
    }

    func ls() throws {
        let lines = try read()
        let header = WmemFormat.header(lines)
        let rows = try events()
        let today = try Self.day(today())
        let never = 1_000_000
        var table: [(age: Int, section: String, name: String, last: String, hits: Int, text: String)] = []
        for entry in WmemFormat.entries(lines) {
            let mine = rows.filter { $0.name == entry.name && ($0.event == "add" || $0.event == "hit") }
            let last = mine.map { PythonText.prefix($0.time, 10) }.reduce(nil as String?) { best, date in
                guard let best else { return date }
                return PythonText.less(best, date) ? date : best
            }
            let hits = mine.filter { $0.event == "hit" }.count
            let age = try last.map { try today - Self.day($0) }
            table.append((age ?? never, entry.section, entry.name, last ?? "never", hits, entry.text))
        }
        // Stalest first; a stable sort, as Python's.
        let sorted = table.enumerated().sorted { a, b in
            a.element.age != b.element.age ? a.element.age > b.element.age : a.offset < b.offset
        }.map(\.element)
        for row in sorted {
            let flag = row.section == "Pinned" ? "pin" : (row.age > header.windowDays ? "STALE" : "")
            let days = row.age == never ? "?" : "\(row.age)d"
            out(PythonText.leftAligned(flag, 5) + "  " + PythonText.leftAligned(row.name, 24) + "  last \(row.last) ("
                + PythonText.rightAligned(days, 4) + ")  hits " + PythonText.rightAligned(String(row.hits), 3)
                + "  \(row.text)\n")
        }
        let since = header.cleaned != "never" ? header.cleaned : "0000"
        let regrets = rows.filter { $0.event == "regret" && !PythonText.less(PythonText.prefix($0.time, 10), since) }
            .map(\.name)
        let size = FileManager.default.fileExists(atPath: file.path) ? PythonText.length(try readFile(file)) : 0
        out("\nwindow \(header.window)d · cleaned \(header.cleaned) · ~\(size / 4) tokens · "
            + "regrets since cleanup: \(regrets.isEmpty ? "none" : regrets.joined(separator: ", "))\n")
    }

    // MARK: Files

    // WMEM.md as lines; the template's when it is missing.
    func read() throws -> [String] {
        WmemFormat.lines(FileManager.default.fileExists(atPath: file.path) ? try readFile(file) : WmemFormat.template)
    }

    // Through a temporary file beside it, renamed over it.
    func write(_ lines: [String]) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tmp")
        try Data(WmemFormat.text(lines).utf8).write(to: temporary)
        guard rename(temporary.path, file.path) == 0 else {
            throw Failure(message: "OSError: [Errno \(errno)] \(String(cString: strerror(errno))): "
                          + PythonText.repr(temporary.path) + " -> " + PythonText.repr(file.path))
        }
    }

    // A text-mode read: UTF-8, universal newlines.
    private func readFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "UnicodeDecodeError: \(url.path) is not UTF-8")
        }
        return PythonText.readText(text)
    }

    struct Event: Equatable {
        var time: String
        var event: String
        var name: String
        var detail: String
    }

    // Each log line with at least three fields.
    func events() throws -> [Event] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try PythonText.splitlines(readFile(log)).compactMap { line in
            let parts = PythonText.split(line, on: "\t")
            guard parts.count >= 3 else { return nil }
            return Event(time: parts[0], event: parts[1], name: parts[2], detail: parts.count > 3 ? parts[3] : "")
        }
    }

    func append(_ event: String, _ name: String = "", _ detail: String = "") throws {
        let line = "\(timestamp())\t\(event)\t\(name)\t\(detail)\n"
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o666)
        guard fd >= 0 else {
            throw Failure(message: "OSError: [Errno \(errno)] \(String(cString: strerror(errno))): "
                          + PythonText.repr(log.path))
        }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else {
            throw Failure(message: "OSError: couldn't write \(log.path)")
        }
    }

    // MARK: Time

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // Now as YYYY-MM-DDTHH:MM, local.
    func timestamp() -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now())
        return String(format: "%04d-%02d-%02dT%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!,
                      parts.minute!)
    }

    // Today as YYYY-MM-DD, local.
    func today() -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // YYYY-MM-DD as a day number, so a difference counts calendar days.
    static func day(_ iso: String) throws -> Int {
        let scalars = Array(iso.unicodeScalars)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count,
                  scalars[range].allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(String(String.UnicodeScalarView(scalars[range])))
        }
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-", let year = number(0..<4),
              let month = number(5..<7), let day = number(8..<10), year >= 1, (1...12).contains(month),
              day >= 1, day <= daysIn(month: month, year: year) else {
            throw Failure(message: "ValueError: Invalid isoformat string: \(PythonText.repr(iso))")
        }
        // Days from civil (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
