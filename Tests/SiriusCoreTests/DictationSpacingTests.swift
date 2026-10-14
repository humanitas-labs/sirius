import XCTest
@testable import SiriusCore

final class DictationSpacingTests: XCTestCase {
    func testStartOfField() {
        XCTAssertEqual(DictationSpacing.spaced("run the tests", after: nil), "run the tests")
    }

    func testAfterAWord() {
        XCTAssertEqual(DictationSpacing.spaced("and then deploy", after: "s"), " and then deploy")
        XCTAssertEqual(DictationSpacing.spaced("Then deploy.", after: "."), " Then deploy.")
    }

    func testAfterWhitespace() {
        XCTAssertEqual(DictationSpacing.spaced("deploy", after: " "), "deploy")
        XCTAssertEqual(DictationSpacing.spaced("deploy", after: "\n"), "deploy")
        XCTAssertEqual(DictationSpacing.spaced("deploy", after: "\t"), "deploy")
    }

    func testLeadingWhitespaceNeverDoubles() {
        XCTAssertEqual(DictationSpacing.spaced("  deploy", after: "s"), " deploy")
        XCTAssertEqual(DictationSpacing.spaced(" deploy", after: " "), "deploy")
        XCTAssertEqual(DictationSpacing.spaced(" deploy", after: nil), "deploy")
    }

    func testEmpty() {
        XCTAssertEqual(DictationSpacing.spaced("", after: "s"), "")
        XCTAssertEqual(DictationSpacing.spaced("   ", after: "s"), "")
    }
}
