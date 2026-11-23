import Foundation
import XCTest
@testable import SiriusMemory

final class WmemTests: XCTestCase {
    private var base: URL!
    private var stdout = ""
    private var stderr = ""
    // 2026-11-09T10:30 UTC, read in UTC.
    private var clock = Date(timeIntervalSince1970: 1_794_220_200)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sirius-wmem-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var file: URL { base.appendingPathComponent("WMEM.md") }
    private var logURL: URL { base.appendingPathComponent("wmem.log") }

    @discardableResult
    private func wmem(_ arguments: String...) -> Int32 {
        stdout = ""
        stderr = ""
        let wmem = Wmem(file: file, now: { [clock] in clock }, timeZone: TimeZone(identifier: "UTC")!,
                        out: { self.stdout += $0 }, err: { self.stderr += $0 })
        return wmem.run(arguments)
    }

    private func memory() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    private func log() throws -> [String] {
        try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func advance(days: Int) { clock += TimeInterval(days * 86_400) }

    // MARK: Usage

    func testNoCommandPrintsUsageAndSucceedsAnUnknownOneFails() {
        XCTAssertEqual(wmem(), 0)
        XCTAssertEqual(stderr, Wmem.usage + "\n")
        XCTAssertTrue(stderr.hasPrefix("wmem: keep working memory"))
        XCTAssertEqual(wmem("bogus"), 1)
        XCTAssertEqual(stderr, Wmem.usage + "\n")
        XCTAssertEqual(stdout, "")
    }

    // MARK: add

    func testAddCreatesTheFileFromTheTemplateAndLogs() throws {
        XCTAssertEqual(wmem("add", "plans", "Cycle", "plans:", " `wm/.plan/` "), 0)
        XCTAssertEqual(try memory(), WmemFormat.template + "\n- plans: Cycle plans:  `wm/.plan/`\n")
        XCTAssertEqual(try log(), ["2026-11-09T10:30\tadd\tplans\tLearned"])
    }

    func testAddReplacesInPlaceSectionAndPinMovesIt() throws {
        wmem("add", "a", "one")
        wmem("add", "b", "two")
        wmem("add", "a", "uno")
        XCTAssertTrue(try memory().hasSuffix("## Learned\n\n- b: two\n- a: uno\n"))
        wmem("add", "b", "dos", "--pin")
        XCTAssertTrue(try memory().contains("## Pinned\n\n- b: dos\n\n## Learned\n\n- a: uno\n"))
        // Replacing a Pinned entry keeps it Pinned.
        wmem("add", "b", "zwei")
        XCTAssertTrue(try memory().contains("## Pinned\n\n- b: zwei\n"))
        XCTAssertEqual(try log().last, "2026-11-09T10:30\tadd\tb\tPinned")
    }

    func testAddRefusesBadNamesAndText() throws {
        XCTAssertEqual(wmem("add", "only"), 1)
        XCTAssertEqual(stderr, "wmem: usage: wmem add NAME TEXT... [--pin]\n")
        XCTAssertEqual(wmem("add", "Bad", "x"), 1)
        XCTAssertEqual(stderr, "wmem: name 'Bad': use lowercase letters, digits and dashes\n")
        XCTAssertEqual(wmem("add", "it's", "x"), 1)
        XCTAssertEqual(stderr, "wmem: name \"it's\": use lowercase letters, digits and dashes\n")
        XCTAssertEqual(wmem("add", "-a", "x"), 1)
        XCTAssertEqual(wmem("add", "a", "two\nlines"), 1)
        XCTAssertEqual(stderr, "wmem: text must be one non-empty line\n")
        XCTAssertEqual(wmem("add", "a", "  "), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAddingBackARemovedEntryIsARegret() throws {
        wmem("add", "a", "one")
        advance(days: 2)
        wmem("rm", "a")
        wmem("add", "a", "again")
        XCTAssertEqual(stdout, "wmem: a was removed on 2026-11-11; logged as a regret\n")
        XCTAssertEqual(Array(try log().suffix(2)),
                       ["2026-11-11T10:30\tregret\ta\tremoved 2026-11-11", "2026-11-11T10:30\tadd\ta\tLearned"])
        // Replacing an entry that is there is no regret.
        wmem("add", "a", "third")
        XCTAssertEqual(stdout, "")
    }

    func testAddMakesAMissingSectionAndHeaderStaysPut() throws {
        try "# Mine\n\nWindow: 21 days · Cleaned: 2026-11-01\n\n## Learned\n\n- x: y\n"
            .write(to: file, atomically: true, encoding: .utf8)
        wmem("add", "p", "pinned", "--pin")
        XCTAssertEqual(try memory(), "# Mine\n\nWindow: 21 days · Cleaned: 2026-11-01\n\n## Pinned\n\n- p: pinned\n\n\n"
                       + "## Learned\n\n- x: y\n")
    }

    // MARK: rm and hit

    func testRmRemovesAndLogsItsSection() throws {
        wmem("add", "a", "one")
        wmem("add", "b", "two", "--pin")
        XCTAssertEqual(wmem("rm", "a", "b"), 0)
        XCTAssertFalse(try memory().contains("- a:"))
        XCTAssertFalse(try memory().contains("- b:"))
        XCTAssertEqual(Array(try log().suffix(2)),
                       ["2026-11-09T10:30\trm\ta\tLearned", "2026-11-09T10:30\trm\tb\tPinned"])
    }

    func testRmOfAMissingEntryChangesNothing() throws {
        wmem("add", "a", "one")
        let before = try memory()
        XCTAssertEqual(wmem("rm", "x", "a", "y"), 1)
        XCTAssertEqual(stderr, "wmem: no entry: x, y\n")
        XCTAssertEqual(try memory(), before)
        XCTAssertEqual(wmem("rm"), 1)
        XCTAssertEqual(stderr, "wmem: usage: wmem rm NAME...\n")
    }

    func testHitLogsEvenAnUnknownName() throws {
        wmem("add", "a", "one")
        XCTAssertEqual(wmem("hit", "a", "nope"), 0)
        XCTAssertEqual(stderr, "wmem: no entry 'nope'; logged anyway\n")
        XCTAssertEqual(Array(try log().suffix(2)), ["2026-11-09T10:30\thit\ta\t", "2026-11-09T10:30\thit\tnope\t"])
        XCTAssertEqual(wmem("hit"), 1)
        XCTAssertEqual(stderr, "wmem: usage: wmem hit NAME...\n")
    }

    // MARK: window and cleaned

    func testWindowShowsAndSets() throws {
        XCTAssertEqual(wmem("window"), 0)
        XCTAssertEqual(stdout, "14\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(wmem("window", "021"), 0)
        XCTAssertTrue(try memory().contains("Window: 21 days · Cleaned: never\n"))
        XCTAssertEqual(try log().last, "2026-11-09T10:30\twindow\t\t021")
        wmem("window")
        XCTAssertEqual(stdout, "21\n")
        for bad in ["0", "x", "-3", ""] {
            XCTAssertEqual(wmem("window", bad), 1)
            XCTAssertEqual(stderr, "wmem: window is a whole number of days\n")
        }
    }

    func testCleanedStampsTodayAndAddsAHeaderWhenMissing() throws {
        try "# Mine\n\n## Learned\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(wmem("cleaned"), 0)
        XCTAssertEqual(try memory(), "# Mine\n\nWindow: 14 days · Cleaned: 2026-11-09\n\n## Learned\n")
        XCTAssertEqual(try log().last, "2026-11-09T10:30\tcleaned\t\t")
    }

    // MARK: ls

    func testLsListsStalestFirstWithFlagsAndTheSummary() throws {
        wmem("add", "old", "an old one")
        wmem("add", "keep", "pinned", "--pin")
        advance(days: 20)
        wmem("add", "new", "a new one")
        wmem("hit", "new", "new")
        try (try memory() + "- never-used: no log\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(wmem("ls"), 0)
        let size = WmemFormat.tokens(try memory())
        XCTAssertEqual(stdout, """
            STALE  never-used                last never (   ?)  hits   0  no log
            pin    keep                      last 2026-11-09 ( 20d)  hits   0  pinned
            STALE  old                       last 2026-11-09 ( 20d)  hits   0  an old one
                   new                       last 2026-11-29 (  0d)  hits   2  a new one

            window 14d · cleaned never · ~\(size) tokens · regrets since cleanup: none

            """)
    }

    func testLsCountsRegretsSinceTheLastCleanup() throws {
        wmem("add", "a", "one")
        wmem("rm", "a")
        wmem("add", "a", "one")
        wmem("ls")
        XCTAssertTrue(stdout.hasSuffix("regrets since cleanup: a\n"))
        advance(days: 1)
        wmem("cleaned")
        wmem("ls")
        XCTAssertTrue(stdout.hasSuffix("regrets since cleanup: none\n"))
    }

    func testLsOfNoFileIsAnEmptySummary() {
        XCTAssertEqual(wmem("ls"), 0)
        XCTAssertEqual(stdout, "\nwindow 14d · cleaned never · ~0 tokens · regrets since cleanup: none\n")
    }

    // MARK: Format

    func testWritesAreAtomicAndLeaveNoTemporaryFile() throws {
        wmem("add", "a", "one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted(), ["WMEM.md", "wmem.log"])
    }

    func testCRLFAndAMissingHeaderReadAsPythonReadThem() {
        let text = "# W\r\n\r\nWindow: 7 days · Cleaned: 2026-11-01\r\n## Learned\r\n- a: b\r\n"
        let lines = WmemFormat.lines(text)
        XCTAssertEqual(WmemFormat.header(lines), WmemFormat.Header(index: 2, window: "7", cleaned: "2026-11-01"))
        XCTAssertEqual(WmemFormat.entries(lines).map(\.name), ["a"])
        XCTAssertEqual(WmemFormat.tokens(text), (text.unicodeScalars.count - 5) / 4)
        XCTAssertEqual(WmemFormat.header(["# none"]).cleaned, "never")
        XCTAssertEqual(WmemFormat.header(["Window: 7 days · Cleaned: two words"]).index, nil)
    }

    func testFileComesFromTheEnvironment() {
        XCTAssertEqual(Wmem.file(environment: ["HOME": "/h"]).path, "/h/.agents/sirius/WMEM.md")
        XCTAssertEqual(Wmem.file(environment: ["HOME": "/h", "WMEM_FILE": ""]).path, "/h/.agents/sirius/WMEM.md")
        XCTAssertEqual(Wmem.file(environment: ["HOME": "/h", "WMEM_FILE": "~/m/W.md"]).path, "/h/m/W.md")
        XCTAssertEqual(Wmem.file(environment: ["WMEM_FILE": "/x/W.md"]).path, "/x/W.md")
    }

    func testReprQuotesAsPythonDoes() {
        XCTAssertEqual(PythonText.repr("abc"), "'abc'")
        XCTAssertEqual(PythonText.repr("it's"), "\"it's\"")
        XCTAssertEqual(PythonText.repr("a'\"b"), "'a\\'\"b'")
        XCTAssertEqual(PythonText.repr("t\tn\n\u{7}é\u{a0}"), "'t\\tn\\n\\x07é\\xa0'")
    }
}
