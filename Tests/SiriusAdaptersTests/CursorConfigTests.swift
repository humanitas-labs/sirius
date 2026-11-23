import XCTest
@testable import SiriusAdapters

final class CursorConfigTests: XCTestCase {
    private var root: URL!
    private var user: URL { root.appendingPathComponent("user") }
    private var own: URL { root.appendingPathComponent("agents/dev/cursor") }
    private let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("cursor-config-\(UUID().uuidString)")
        try files.createDirectory(at: user.appendingPathComponent("acp-sessions"), withIntermediateDirectories: true)
        try write(#"{"model":"theirs","permissions":["x"]}"#, to: user.appendingPathComponent("cli-config.json"))
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testTheUsersDirectoryIsResolvedAsTheCLIDoes() {
        XCTAssertEqual(CursorConfig.userDirectory(environment: [:], home: "/Users/u").path, "/Users/u/.cursor")
        XCTAssertEqual(CursorConfig.userDirectory(environment: ["XDG_CONFIG_HOME": "/cfg"], home: "/Users/u").path,
                       "/cfg/cursor")
        XCTAssertEqual(CursorConfig.userDirectory(environment: ["CURSOR_CONFIG_DIR": "/c", "XDG_CONFIG_HOME": "/cfg"],
                                                  home: "/Users/u").path, "/c")
        XCTAssertEqual(CursorConfig.userDirectory(environment: ["CURSOR_CONFIG_DIR": " "], home: "/Users/u").path,
                       "/Users/u/.cursor")
    }

    func testTheAgentGetsACopyOfTheSettingsAndLinksToTheRest() throws {
        let environment = try CursorConfig.isolate(user: user, own: own)
        XCTAssertEqual(environment, ["CURSOR_CONFIG_DIR": own.path])
        let copy = own.appendingPathComponent("cli-config.json")
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: copy.path), "a copy, not a link")
        XCTAssertEqual(try read(copy), try read(user.appendingPathComponent("cli-config.json")))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: own.appendingPathComponent("acp-sessions").path),
                       user.appendingPathComponent("acp-sessions").path)

        // What the agent's sessions save stays out of the user's file.
        try write(#"{"model":"the agent's"}"#, to: copy)
        XCTAssertEqual(try read(user.appendingPathComponent("cli-config.json")),
                       #"{"model":"theirs","permissions":["x"]}"#)
    }

    func testEachOpenTakesTheUsersSettingsAgainAndKeepsWhatTheServerWrote() throws {
        _ = try CursorConfig.isolate(user: user, own: own)
        try write(#"{"model":"the agent's"}"#, to: own.appendingPathComponent("cli-config.json"))
        try write("{}", to: own.appendingPathComponent("acp-config.json"))
        try write(#"{"model":"theirs now"}"#, to: user.appendingPathComponent("cli-config.json"))
        try files.createDirectory(at: user.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try files.removeItem(at: user.appendingPathComponent("acp-sessions"))

        _ = try CursorConfig.isolate(user: user, own: own)
        XCTAssertEqual(try read(own.appendingPathComponent("cli-config.json")), #"{"model":"theirs now"}"#)
        XCTAssertEqual(try read(own.appendingPathComponent("acp-config.json")), "{}", "the server's own file is kept")
        XCTAssertNotNil(try? files.destinationOfSymbolicLink(atPath: own.appendingPathComponent("plugins").path))
        XCTAssertNil(try? files.attributesOfItem(atPath: own.appendingPathComponent("acp-sessions").path),
                     "a link to something the user removed is dropped")
    }

    func testAUserWithNoCursorDirectoryStillGetsOne() throws {
        try files.removeItem(at: user)
        XCTAssertEqual(try CursorConfig.isolate(user: user, own: own), ["CURSOR_CONFIG_DIR": own.path])
        XCTAssertEqual(try files.contentsOfDirectory(atPath: own.path), [])
    }
}
