import AppKit
import XCTest
import SiriusCore
import SiriusProtocol
@testable import SiriusApp

// The menu's Compose item opens the composer, its shortcut as the hint, so
// the composer is reachable whatever happened to the shortcut.
@MainActor
final class ComposeMenuTests: XCTestCase {
    func testFunctionKeyHint() throws {
        let key = try XCTUnwrap(KeyComboText.menuKey(KeyCombo(keyCode: 96, modifiers: 0))) // F5
        XCTAssertEqual(key.key, String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(key.modifiers, [])
    }

    func testModifiersCarryOver() throws {
        let combo = KeyCombo(keyCode: 122, modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        let key = try XCTUnwrap(KeyComboText.menuKey(combo))
        XCTAssertEqual(key.modifiers, [.command, .shift, .option, .control])
    }

    func testComposeItemShowsTheCurrentShortcutAndOpensTheComposer() throws {
        var shortcut = KeyCombo(keyCode: 96, modifiers: KeyCombo.command) // ⌘F5
        let opened = expectation(description: "opened")
        let delegate = AppDelegate(queue: NoQueue(), openOnboarding: { _ in },
                                   openComposer: { opened.fulfill() }, composeShortcut: { shortcut })
        let item = delegate.makeComposeItem()
        XCTAssertEqual(item.keyEquivalent, String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        shortcut = KeyCombo(keyCode: 97, modifiers: KeyCombo.control) // ⌃F6
        delegate.updateComposeItem(item)
        XCTAssertEqual(item.keyEquivalent, String(Character(UnicodeScalar(NSF6FunctionKey)!)))
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control])
        delegate.compose(item)
        wait(for: [opened], timeout: 1)
    }
}

private final class NoQueue: CommandQueue {
    func accept(_ command: Command) async -> Result<MethodResult, RPCError> { .failure(RPCError(.notReady, "")) }
}
