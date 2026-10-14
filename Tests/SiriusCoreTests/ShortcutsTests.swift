import XCTest
@testable import SiriusCore

final class ShortcutsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ShortcutsTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAShortcutNeedsCommandControlOrOptionUnlessItIsAnFKey() {
        XCTAssertTrue(KeyCombo.compose.isAcceptable)
        XCTAssertTrue(KeyCombo(keyCode: 38, modifiers: KeyCombo.control).isAcceptable)
        XCTAssertTrue(KeyCombo(keyCode: 38, modifiers: KeyCombo.option).isAcceptable)
        XCTAssertFalse(KeyCombo(keyCode: 38, modifiers: 0).isAcceptable)
        XCTAssertFalse(KeyCombo(keyCode: 38, modifiers: KeyCombo.shift).isAcceptable)
        XCTAssertTrue(KeyCombo(keyCode: 122, modifiers: 0).isAcceptable, "F1 alone")
        XCTAssertTrue(KeyCombo(keyCode: 111, modifiers: KeyCombo.shift).isAcceptable, "⇧F12")
    }

    func testModifiersReadAsTheFramesWriteThem() {
        XCTAssertEqual(KeyCombo.compose.modifierGlyphs, "⌘⇧")
        let all = KeyCombo(keyCode: 0, modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        XCTAssertEqual(all.modifierGlyphs, "⌃⌥⌘⇧")
    }

    func testOnlyAnEnabledSymbolicHotKeyWithTheSameKeysClashes() {
        // ⌘Space, Spotlight, as CopySymbolicHotKeys lists it.
        let spotlight = SymbolicHotKey(keyCode: 49, modifiers: 256, enabled: true)
        XCTAssertTrue(KeyCombo(keyCode: 49, modifiers: KeyCombo.command).clashes(withSymbolic: spotlight))
        XCTAssertFalse(KeyCombo(keyCode: 49, modifiers: KeyCombo.command | KeyCombo.shift).clashes(withSymbolic: spotlight))
        var off = spotlight
        off.enabled = false
        XCTAssertFalse(KeyCombo(keyCode: 49, modifiers: KeyCombo.command).clashes(withSymbolic: off))
        // The F-keys' entries carry the fn bit, which a hot key ignores.
        let missionControl = SymbolicHotKey(keyCode: 99, modifiers: 135_168, enabled: true)
        XCTAssertTrue(KeyCombo(keyCode: 99, modifiers: KeyCombo.control).clashes(withSymbolic: missionControl))
    }

    func testComposeDefaultsToCommandShiftJAndPersists() {
        XCTAssertEqual(Shortcuts.compose(in: defaults), .compose)
        let combo = KeyCombo(keyCode: 40, modifiers: KeyCombo.control | KeyCombo.option)
        Shortcuts.setCompose(combo, in: defaults)
        XCTAssertEqual(Shortcuts.compose(in: defaults), combo)
        // A stored combo that breaks the rule falls back to the default.
        Shortcuts.setCompose(KeyCombo(keyCode: 40, modifiers: 0), in: defaults)
        XCTAssertEqual(Shortcuts.compose(in: defaults), .compose)
    }

    func testHoldToTalkDefaultsToFnAndPersistsAsParrotsName() {
        XCTAssertEqual(Shortcuts.holdKey(in: defaults), .fn)
        Shortcuts.setHoldKey(.rightOption, in: defaults)
        XCTAssertEqual(Shortcuts.holdKey(in: defaults), .rightOption)
        XCTAssertEqual(defaults.string(forKey: Shortcuts.holdKey), "right-option")
        defaults.set("left-shift", forKey: Shortcuts.holdKey)
        XCTAssertEqual(Shortcuts.holdKey(in: defaults), .fn, "not on the list")
        XCTAssertEqual(HoldKey.allCases.map(\.glyph), ["fn", "right ⌥", "right ⌘", "⌃"])
    }

    // The toast when the compose shortcut cannot be had names the user's own
    // shortcut, not the default.
    func testTakenMessageNamesTheShortcut() {
        XCTAssertEqual(Shortcuts.takenMessage("⌘⇧J"),
                       "⌘⇧J is taken by another app. Pick a new compose shortcut in Settings.")
        XCTAssertTrue(Shortcuts.takenMessage("⌃⌥K").hasPrefix("⌃⌥K is taken"))
    }
}
