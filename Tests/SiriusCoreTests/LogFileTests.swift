import Foundation
import XCTest
@testable import SiriusCore

final class LogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logfile-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testCreatesItsFolderAndAppends() throws {
        let file = LogFile(url: directory.appendingPathComponent("Sirius/sirius.log"), limit: 1024)
        file.append("one\n")
        file.append("two\n")
        XCTAssertEqual(try contents(file.url), "one\ntwo\n")
    }

    func testAppendsToAFileFromAnEarlierLaunch() throws {
        let url = directory.appendingPathComponent("sirius.log")
        LogFile(url: url, limit: 1024).append("before\n")
        LogFile(url: url, limit: 1024).append("after\n")
        XCTAssertEqual(try contents(url), "before\nafter\n")
    }

    // Past the limit the file rolls over to one backup, and an older backup
    // goes: at most two files, each under the limit.
    func testRollsOverToOneBackup() throws {
        let file = LogFile(url: directory.appendingPathComponent("sirius.log"), limit: 10)
        file.append("aaaaaa\n") // 7
        file.append("bbbbbb\n") // 14 > 10: rolls
        XCTAssertEqual(try contents(file.backupURL), "aaaaaa\n")
        XCTAssertEqual(try contents(file.url), "bbbbbb\n")
        file.append("cccccc\n")
        XCTAssertEqual(try contents(file.backupURL), "bbbbbb\n")
        XCTAssertEqual(try contents(file.url), "cccccc\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["sirius.log", "sirius.log.1"])
    }

    // A file already past the limit from an earlier launch rolls on the
    // next line.
    func testRollsAFileAlreadyFull() throws {
        let url = directory.appendingPathComponent("sirius.log")
        LogFile(url: url, limit: 1024).append(String(repeating: "x", count: 20) + "\n")
        let file = LogFile(url: url, limit: 10)
        file.append("new\n")
        XCTAssertEqual(try contents(url), "new\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    func testLineCarriesTimeLevelAndCategory() {
        let line = LogFile.line(date: Date(timeIntervalSince1970: 0), category: "hotkey", level: "error",
                                message: "compose hotkey ⌘⇧J not registered")
        XCTAssertEqual(line, "1970-01-01T00:00:00.000Z error [hotkey] compose hotkey ⌘⇧J not registered\n")
    }

    func testStandardFileIsInLibraryLogs() {
        let file = LogFile.standard()
        XCTAssertTrue(file.url.path.hasSuffix("/Library/Logs/Sirius/sirius.log"))
        XCTAssertEqual(file.limit, 5 * 1024 * 1024)
    }
}
