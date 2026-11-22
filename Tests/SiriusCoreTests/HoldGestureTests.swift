import XCTest
@testable import SiriusCore

final class HoldGestureTests: XCTestCase {
    // flagsChanged keycodes.
    let fn: Int64 = 63, leftControl: Int64 = 59, rightControl: Int64 = 62
    let leftShift: Int64 = 56, leftCommand: Int64 = 55, rightCommand: Int64 = 54, rightOption: Int64 = 61

    func testThePasteChordIsTheHoldKeyPlusControlOrShiftForControl() {
        XCTAssertEqual(HoldKey.fn.pasteModifier, .control)
        XCTAssertEqual(HoldKey.rightOption.pasteModifier, .control)
        XCTAssertEqual(HoldKey.rightCommand.pasteModifier, .control)
        XCTAssertEqual(HoldKey.control.pasteModifier, .shift)
        XCTAssertEqual(HoldKey.fn.pasteGlyph, "⌃fn")
        XCTAssertEqual(HoldKey.rightOption.pasteGlyph, "⌃ right ⌥")
        XCTAssertEqual(HoldKey.control.pasteGlyph, "⌃⇧")
    }

    // The paste modifier is the user's choice, any but the talk key's own;
    // one stored for another key falls back to the standard one.
    func testThePasteModifierCanBeChosen() throws {
        XCTAssertEqual(PasteModifier.options(for: .fn), [.control, .shift, .option, .command])
        XCTAssertEqual(PasteModifier.options(for: .control), [.shift, .option, .command])
        XCTAssertEqual(HoldKey.fn.pasteGlyph(.option), "⌥fn")
        XCTAssertEqual(HoldKey.rightCommand.pasteGlyph(.shift), "⇧ right ⌘")
        let suite = "sirius-paste-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Shortcuts.pasteModifier(for: .fn, in: defaults), .control)
        Shortcuts.setPasteModifier(.option, in: defaults)
        XCTAssertEqual(Shortcuts.pasteModifier(for: .fn, in: defaults), .option)
        // Right Option as the talk key cannot also be the paste modifier.
        XCTAssertEqual(Shortcuts.pasteModifier(for: .rightOption, in: defaults), .control)
    }

    func testAChosenModifierPastesAndControlNoLongerDoes() {
        var gesture = HoldGesture(key: .fn, paste: .option)
        XCTAssertEqual(gesture.handle(keycode: 58, flags: [.option, .fn], at: 0), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .option, at: 1), .transcribe)
        // ⌃ with fn is now just a chord: ignored, nothing recorded.
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 2), nil)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .control, at: 3), nil)
        XCTAssertFalse(gesture.isHeld)
    }

    func testEventFlagsKeepOnlyTheModifierBits() {
        // maskControl | maskSecondaryFn | maskNonCoalesced and device bits.
        XCTAssertEqual(HoldModifiers(eventFlags: 0x0004_0000 | 0x0080_0000 | 0x100 | 0x1), [.control, .fn])
    }

    func testPlainFnStillTalksToTheAgent() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 0), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [], at: 1), .transcribe)
        XCTAssertFalse(gesture.isHeld)
    }

    func testControlThenFnPastes() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertNil(gesture.handle(keycode: leftControl, flags: .control, at: 0))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 2), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .control, at: 3), .transcribe)
    }

    func testFnThenControlWithinTheWindowPastes() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 0), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: rightControl, flags: [.fn, .control], at: 0.1), .paste)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .control, at: 2), .transcribe)
    }

    func testControlLateCancelsAsAnyChordDoes() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 0), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: [.fn, .control], at: 0.5), .cancel)
        XCTAssertNil(gesture.handle(keycode: fn, flags: .control, at: 2), "the rest of the hold is ignored")
        XCTAssertFalse(gesture.isHeld)
    }

    func testControlMayGoUpFirstInAPasteHold() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 0), .start(.paste))
        XCTAssertNil(gesture.handle(keycode: leftControl, flags: .fn, at: 1))
        XCTAssertNil(gesture.handle(keycode: leftControl, flags: [.control, .fn], at: 1.2))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [], at: 2), .transcribe)
    }

    func testOtherModifiersStillCancel() {
        var gesture = HoldGesture(key: .fn)
        // ⌘fn and ⌃⌘fn never record.
        XCTAssertNil(gesture.handle(keycode: fn, flags: [.command, .fn], at: 0))
        XCTAssertNil(gesture.handle(keycode: fn, flags: .command, at: 1))
        XCTAssertNil(gesture.handle(keycode: fn, flags: [.control, .command, .fn], at: 2))
        XCTAssertNil(gesture.handle(keycode: fn, flags: [.control, .command], at: 3))
        // ⌘ during a paste hold cancels it.
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 4), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: leftCommand, flags: [.control, .command, .fn], at: 4.1), .cancel)
        XCTAssertNil(gesture.handle(keycode: fn, flags: [.control, .command], at: 5))
        // ⇧ joining fn early is not the chord.
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 6), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: leftShift, flags: [.shift, .fn], at: 6.1), .cancel)
    }

    func testAShortPasteHoldIsDiscarded() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 0), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .control, at: 0.1), .cancel)
    }

    func testControlHoldPastesWithShift() {
        var gesture = HoldGesture(key: .control)
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: .control, at: 0), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: leftShift, flags: [.control, .shift], at: 0.2), .paste)
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: .shift, at: 1), .transcribe)
        // ⇧ first.
        XCTAssertNil(gesture.handle(keycode: leftShift, flags: .shift, at: 2))
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: [.shift, .control], at: 2.1), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: .shift, at: 3), .transcribe)
        // Right ⌃ is another key, not the chord.
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: .control, at: 4), .start(.agent))
        XCTAssertEqual(gesture.handle(keycode: rightControl, flags: .control, at: 4.1), .cancel)
    }

    func testRightCommandHoldPastesWithControl() {
        var gesture = HoldGesture(key: .rightCommand)
        XCTAssertNil(gesture.handle(keycode: leftCommand, flags: .command, at: 0), "left ⌘ is not the key")
        XCTAssertNil(gesture.handle(keycode: leftCommand, flags: [], at: 0.5))
        XCTAssertEqual(gesture.handle(keycode: rightCommand, flags: [.control, .command], at: 1), .start(.paste))
        XCTAssertEqual(gesture.handle(keycode: rightCommand, flags: .control, at: 2), .transcribe)
        XCTAssertEqual(gesture.handle(keycode: rightOption, flags: .option, at: 3), nil)
    }

    func testAMissedReleaseAndAKeySwitch() {
        var gesture = HoldGesture(key: .fn)
        XCTAssertEqual(gesture.handle(keycode: fn, flags: [.control, .fn], at: 0), .start(.paste))
        XCTAssertEqual(gesture.released(at: 1), .transcribe)
        XCTAssertNil(gesture.released(at: 2))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 3), .start(.agent))
        XCTAssertEqual(gesture.setKey(.control), .cancel)
        XCTAssertFalse(gesture.isHeld)
        XCTAssertNil(gesture.setKey(.control))
    }

    // `/` steps the agent selector only while an agent hold records, and
    // only with no modifier but the hold key's own.
    func testSlashSwitchesTheAgentOnlyDuringAnAgentHold() {
        let slash = HoldGesture.switchKeycode
        var gesture = HoldGesture(key: .fn)
        XCTAssertFalse(gesture.switches(keycode: slash, flags: []), "no hold")
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .fn, at: 0), .start(.agent))
        XCTAssertTrue(gesture.switchesAgent)
        XCTAssertTrue(gesture.switches(keycode: slash, flags: .fn))
        XCTAssertFalse(gesture.switches(keycode: 0, flags: .fn), "another key")
        XCTAssertFalse(gesture.switches(keycode: slash, flags: [.fn, .command]), "⌘/ is the app's")
        // ⌃ joins: a paste hold types its `/`.
        XCTAssertEqual(gesture.handle(keycode: leftControl, flags: [.control, .fn], at: 0.1), .paste)
        XCTAssertFalse(gesture.switches(keycode: slash, flags: [.control, .fn]))
        XCTAssertEqual(gesture.handle(keycode: fn, flags: .control, at: 1), .transcribe)
        XCTAssertFalse(gesture.switches(keycode: slash, flags: []), "released")
    }

    func testSlashIsLeftAloneInAChordAndSwitchesUnderAModifierHoldKey() {
        let slash = HoldGesture.switchKeycode
        // A chord on the key is ignored, and so is its `/`.
        var gesture = HoldGesture(key: .fn)
        XCTAssertNil(gesture.handle(keycode: fn, flags: [.shift, .fn], at: 0))
        XCTAssertFalse(gesture.switches(keycode: slash, flags: [.shift, .fn]))
        // Right ⌘ held to talk: its own flag is not a chord, so `/` switches
        // and the app never sees a ⌘/.
        var command = HoldGesture(key: .rightCommand)
        XCTAssertEqual(command.handle(keycode: rightCommand, flags: .command, at: 0), .start(.agent))
        XCTAssertTrue(command.switches(keycode: slash, flags: .command))
        XCTAssertFalse(command.switches(keycode: slash, flags: [.command, .shift]))
    }
}
