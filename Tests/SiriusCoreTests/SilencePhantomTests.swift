import XCTest
@testable import SiriusCore

final class SilencePhantomTests: XCTestCase {
    func testALoneYouIsAPhantom() {
        for text in ["You", "you", " You.", "You!\n", "YOU"] {
            XCTAssertTrue(SilencePhantom.isPhantom(text), text)
        }
    }

    func testAnythingElseIsKept() {
        for text in ["", "You there?", "Thank you.", "Yes", "you you", "Your"] {
            XCTAssertFalse(SilencePhantom.isPhantom(text), text)
        }
    }
}
