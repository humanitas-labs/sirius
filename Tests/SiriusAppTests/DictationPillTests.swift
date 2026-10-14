import AppKit
import ParrotCore
import XCTest
@testable import SiriusApp

// The pill's state machine against the timings a fast hand gives it: a new
// hold inside every exit, and an earlier hold's transcription ending during
// a new one. Off every screen, on the real run loop.
@MainActor
final class DictationPillTests: XCTestCase {
    private struct Failure: Error {}

    private func makePill() -> DictationPill {
        let pill = DictationPill(mark: NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil))
        pill.parksOffscreen = true
        return pill
    }

    private func run(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func assertShowing(_ pill: DictationPill, _ state: DictationPill.State, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pill.isOrderedIn, "\(message): window ordered out", file: file, line: line)
        XCTAssertTrue(pill.isShown, "\(message): pill at scale 0", file: file, line: line)
        XCTAssertEqual(pill.shownState, state, message, file: file, line: line)
        XCTAssertFalse(pill.isRed, "\(message): still red", file: file, line: line)
    }

    private func assertGone(_ pill: DictationPill, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(pill.isShown, message, file: file, line: line)
        XCTAssertFalse(pill.isOrderedIn, message, file: file, line: line)
    }

    private var hold: TimeInterval { DictationPill.markHold + 0.2 }

    // The transcription of the hold before ends while the next one records:
    // the new hold keeps its pill, and its own release closes it.
    func testAnEarlierTranscriptionEndingDuringANewHoldKeepsItsPill() {
        let pill = makePill()
        pill.dictationStarted()
        run(hold)
        pill.dictationTranscribing()
        run(0.1)
        pill.dictationStarted()
        run(0.1)
        pill.dictationFinished()
        run(DictationPill.scaleDuration + 0.2)
        assertShowing(pill, .recording, "new hold after the earlier one finished")
        pill.dictationFailed()
        run(DictationPill.scaleDuration + 0.2)
        assertShowing(pill, .recording, "new hold after the earlier one failed")
        pill.dictationTranscribing()
        pill.dictationFinished()
        run(DictationPill.transcribingHold + DictationPill.scaleDuration + 0.2)
        assertGone(pill, "closed after the new hold's own transcript")
    }

    // A pill hidden in the same turn it was shown stays hidden: the show's
    // deferred grow does not bring it back and leave it stuck.
    func testAPillHiddenAsItOpensStaysHidden() {
        let pill = makePill()
        pill.dictationStarted()
        pill.dictationFailed(DictationError.cancelled)
        run(DictationPill.scaleDuration + 0.2)
        assertGone(pill, "cancelled in the same turn")
    }

    // A new hold during the close's shrink opens at once and stays.
    func testANewHoldDuringTheCloseShowsAtOnce() {
        let pill = makePill()
        for delay in [0.0, 0.1, DictationPill.transcribingHold - 0.05, DictationPill.transcribingHold + 0.1,
                      DictationPill.transcribingHold + DictationPill.scaleDuration - 0.02] {
            pill.dictationStarted()
            run(hold)
            pill.dictationTranscribing()
            pill.dictationFinished()
            run(delay)
            pill.dictationStarted()
            run(0.05)
            XCTAssertTrue(pill.isOrderedIn, "re-held \(delay)s into the close")
            run(hold + DictationPill.scaleDuration)
            assertShowing(pill, .recording, "re-held \(delay)s into the close")
            pill.dictationFailed(DictationError.cancelled)
            run(DictationPill.scaleDuration + 0.1)
        }
    }

    // A new hold during a failure's red exit drops the red and the shake
    // and opens at once.
    func testANewHoldDuringAFailureShowsAFreshPill() {
        let pill = makePill()
        for delay in [0.1, DictationPill.scaleDuration + 0.1, DictationPill.scaleDuration + DictationPill.errorHold + 0.1] {
            pill.dictationStarted()
            run(hold)
            pill.dictationTranscribing()
            run(DictationPill.scaleDuration)
            pill.dictationFailed(Failure())
            run(delay)
            pill.dictationStarted()
            run(0.05)
            XCTAssertFalse(pill.isRed, "re-held \(delay)s into the failure")
            run(DictationPill.errorHold + DictationPill.scaleDuration + 0.2)
            assertShowing(pill, .recording, "re-held \(delay)s into the failure")
            pill.dictationFailed(DictationError.cancelled)
            run(DictationPill.scaleDuration + 0.1)
        }
    }

    // A release with no audio closes as an empty transcript does: no red.
    func testNoAudioClosesWithoutRed() {
        let pill = makePill()
        pill.dictationStarted()
        run(hold)
        pill.dictationTranscribing()
        pill.dictationFailed(DictationError.noAudio)
        run(DictationPill.transcribingHold)
        XCTAssertFalse(pill.isRed)
        run(DictationPill.scaleDuration + 0.2)
        assertGone(pill, "closed after no audio")
    }

    // A real failure still turns the sparkle red, then leaves.
    func testAFailureTurnsRedThenLeaves() {
        let pill = makePill()
        pill.dictationStarted()
        run(hold)
        pill.dictationTranscribing()
        pill.dictationFailed(Failure())
        run(DictationPill.scaleDuration + 0.1)
        XCTAssertTrue(pill.isRed)
        XCTAssertTrue(pill.isShown)
        run(DictationPill.errorHold + DictationPill.fadeDuration + DictationPill.scaleDuration + 0.2)
        assertGone(pill, "closed after the failure")
    }

    // The pill opens on the target's logo read at the press; a late ⌃
    // turns it back to the mark; no target opens on the mark.
    func testThePillOpensOnTheTargetsLogo() {
        let pill = makePill()
        let claude = NSImage(size: NSSize(width: 16, height: 16))
        var target: NSImage? = claude
        pill.destination = { target }
        pill.dictationStarted()
        XCTAssertTrue(pill.shownOpenLogo === claude, "opens on the logo")
        pill.pastes = true
        XCTAssertNil(pill.shownOpenLogo, "a late paste turns back to the mark")
        pill.dictationFailed(DictationError.cancelled)
        run(DictationPill.scaleDuration + 0.1)
        pill.pastes = false
        target = nil
        pill.dictationStarted()
        XCTAssertNil(pill.shownOpenLogo, "no target: the mark")
        pill.dictationFailed(DictationError.cancelled)
        run(DictationPill.scaleDuration + 0.1)
    }

    // From the release on the pill is the sparkle's: a hold opened on a
    // logo closes no later than one opened on the mark.
    func testAHoldOpenedOnALogoClosesAsTheSparkleDoes() {
        let pill = makePill()
        pill.destination = { NSImage(size: NSSize(width: 16, height: 16)) }
        pill.dictationStarted()
        run(hold)
        pill.dictationTranscribing()
        pill.dictationFinished()
        run(DictationPill.transcribingHold + DictationPill.scaleDuration + 0.2)
        assertGone(pill, "closed at the sparkle's time")
    }
}
