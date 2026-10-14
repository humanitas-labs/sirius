import XCTest
@testable import SiriusApp

// Sparkle starts only in a bundle that can update itself: a numeric build
// number, a feed, and a real Ed25519 public key.
final class UpdaterTests: XCTestCase {
    private let release: [String: Any] = [
        "CFBundleVersion": "268",
        "SUFeedURL": "https://github.com/humanitas-labs/sirius/releases/latest/download/appcast.xml",
        "SUPublicEDKey": "+3akyxNtPI2icyFsuDFZp2FFfIWQ4bwqp+dCTCyViYw=",
    ]

    func testReleaseBundleUpdates() {
        XCTAssertNil(Updater.configurationProblem(info: release))
    }

    func testNonNumericBuildNumberDoesNot() {
        var info = release
        info["CFBundleVersion"] = "0.1.8-3-gabc1234-dirty"
        XCTAssertNotNil(Updater.configurationProblem(info: info))
        info["CFBundleVersion"] = nil
        XCTAssertNotNil(Updater.configurationProblem(info: info))
    }

    func testMissingFeedOrKeyDoesNot() {
        var info = release
        info["SUFeedURL"] = nil
        XCTAssertNotNil(Updater.configurationProblem(info: info))
        info = release
        info["SUPublicEDKey"] = "not-a-key"
        XCTAssertNotNil(Updater.configurationProblem(info: info))
    }

    func testShippedInfoPlistIsReleaseShaped() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/humanitas-labs/sirius/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertNil(info["NSAppTransportSecurity"], "release ATS stays at its default")
        // build-app.sh writes the commit count over the placeholder.
        info["CFBundleVersion"] = "268"
        XCTAssertNil(Updater.configurationProblem(info: info))
    }
}
