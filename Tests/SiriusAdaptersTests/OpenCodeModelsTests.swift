import Darwin
import Foundation
import XCTest
@testable import SiriusAdapters

// The models a user's OpenCode offers, read from a throwaway ACP session:
// the same config options its agent's session will show, with the session
// deleted on the way out and nothing left running.
final class OpenCodeModelsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheEnabledModelsAreOfferedWithTheirNames() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        let executable = try ACPFakeAgent.install(in: root)
        let offered = await OpenCodeModels.offered(executable: URL(fileURLWithPath: executable),
                                                   directory: root)
        // The session's current default comes first, whatever order the
        // session listed the rest in.
        XCTAssertEqual(offered, [
            .init(id: "opencode-go/hy3", name: "HY3"),
            .init(id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        ])
    }

    // The probe session is taken out again before the CLI is let go.
    func testTheProbeDeletesItsSession() async throws {
        try ACPFakeAgent.set(mode: "opencode", in: root)
        let executable = try ACPFakeAgent.install(in: root)
        _ = await OpenCodeModels.offered(executable: URL(fileURLWithPath: executable), directory: root)
        let methods = ACPFakeAgent.received(in: root).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["initialize", "session/new", "session/delete"])
    }

    // A server that answers with no config options has nothing to offer.
    func testACLIWithoutModelOptionsAnswersNothing() async throws {
        let executable = try ACPFakeAgent.install(in: root)
        let offered = await OpenCodeModels.offered(executable: URL(fileURLWithPath: executable),
                                                   directory: root, timeout: .seconds(5))
        XCTAssertNil(offered)
    }

    func testAMissingCLIAnswersNothing() async {
        let offered = await OpenCodeModels.offered(
            executable: URL(fileURLWithPath: "/nowhere/opencode-\(getpid())"),
            directory: root, timeout: .seconds(5))
        XCTAssertNil(offered)
    }

    // The real `opencode acp`, on demand: SIRIUS_LIVE_OPENCODE=1, with the
    // CLI installed. No model is called and the session is deleted again,
    // so it costs nothing; it shows what this account's Model menu will
    // list. Run against 2.3.2 on 2026.11.22.
    func testTheRealCLI() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_OPENCODE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_OPENCODE=1 to read the real CLI's models")
        }
        guard let executable = ACPProfile.opencode.findExecutable(registered: "",
                                                                 environment: ProcessInfo.processInfo.environment)
        else { throw XCTSkip("opencode was not found") }
        let offered = await OpenCodeModels.offered(executable: URL(fileURLWithPath: executable),
                                                   directory: root, timeout: .seconds(20))
        let models = try XCTUnwrap(offered)
        XCTAssertFalse(models.isEmpty)
        print("live: \(models.count) offered, first \(models.map(\.id).prefix(3))")
    }
}
