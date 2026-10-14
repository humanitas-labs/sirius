import XCTest
@testable import SiriusCore

final class LaunchCueTests: XCTestCase {
    func testStaysAtLeastTheMinimumEvenWhenReady() {
        XCTAssertFalse(LaunchCue.leaves(elapsed: 0, ready: true))
        XCTAssertFalse(LaunchCue.leaves(elapsed: LaunchCue.minimum - 0.01, ready: true))
        XCTAssertTrue(LaunchCue.leaves(elapsed: LaunchCue.minimum, ready: true))
    }

    // Long enough for "Listening." to be read after it comes in at 1.25 s,
    // and short of the maximum.
    func testMinimumHoldsTheWordAboutTwoAndAHalfSeconds() {
        XCTAssertEqual(LaunchCue.minimum, 3.7, accuracy: 0.001)
        XCTAssertFalse(LaunchCue.leaves(elapsed: 2.2, ready: true))
        XCTAssertFalse(LaunchCue.leaves(elapsed: 3.1, ready: true))
        XCTAssertTrue(LaunchCue.leaves(elapsed: 3.7, ready: true))
        XCTAssertEqual(LaunchCue.maximum, 6, accuracy: 0.001)
        XCTAssertLessThan(LaunchCue.minimum, LaunchCue.maximum)
    }

    // Glass lands with the word; Hero is cut, faded, before its own hit.
    func testGlassLandsWithTheWord() {
        let sound = LaunchCue.Sound.self
        XCTAssertEqual(sound.start, 1.07, accuracy: 0.001)
        XCTAssertEqual(sound.start + sound.glassOffset, LaunchCue.wordAppears, accuracy: 0.001)
        XCTAssertLessThan(sound.heroCut, sound.glassOffset)
        XCTAssertLessThan(sound.heroFade, sound.heroCut)
        XCTAssertEqual(sound.glassGain, 0.9, accuracy: 0.001)
    }

    func testWaitsForReadyUntilTheMaximum() {
        XCTAssertFalse(LaunchCue.leaves(elapsed: LaunchCue.minimum + 1, ready: false))
        XCTAssertFalse(LaunchCue.leaves(elapsed: LaunchCue.maximum - 0.01, ready: false))
        XCTAssertTrue(LaunchCue.leaves(elapsed: LaunchCue.maximum, ready: false))
    }
}
