import AppKit
import XCTest
import SiriusCore
@testable import SiriusApp

// The compose shortcut is set aside while a new one is recorded; every way
// a recording ends must put it back (a tester, 2026.10.12: ⌘⇧J never opened
// the composer after the onboarding closed mid-recording).
@MainActor
final class ShortcutsModelTests: XCTestCase {
    private var suspended = 0
    private var resumed = 0

    private func model(rebind: @escaping (KeyCombo) -> ComposerController.Rebind = { _ in .bound }) -> ShortcutsModel {
        ShortcutsModel(compose: .compose, holdKey: .fn, rebind: rebind,
                       suspend: { [unowned self] in self.suspended += 1 },
                       resume: { [unowned self] in self.resumed += 1 })
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     windowNumber: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testStartingSetsTheShortcutAside() {
        let model = model()
        model.startRecording(in: window())
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(suspended, 1)
        XCTAssertEqual(resumed, 0)
        model.cancelRecording()
    }

    // Skip, the dissolve as the composer opens, and ⌘W all close the
    // window; SwiftUI's onDisappear does not fire then.
    func testTheWindowClosingEndsTheRecordingAndResumesTheShortcut() {
        let model = model()
        let window = window()
        model.startRecording(in: window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(resumed, 1)
    }

    // A click in another app.
    func testTheWindowLosingTheKeyboardEndsTheRecording() {
        let model = model()
        let window = window()
        model.startRecording(in: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(resumed, 1)
    }

    func testSiriusLosingTheKeyboardEndsTheRecording() {
        let model = model()
        model.startRecording(in: window())
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(resumed, 1)
    }

    // Another window's events leave the recording running.
    func testAnotherWindowClosingLeavesTheRecording() {
        let model = model()
        model.startRecording(in: window())
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window())
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(resumed, 0)
        model.cancelRecording()
    }

    // Once ended, nothing resumes it again: one resume per suspension.
    func testEndsOnce() {
        let model = model()
        let window = window()
        model.startRecording(in: window)
        model.cancelRecording()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        model.cancelRecording()
        XCTAssertEqual(resumed, 1)
    }

    // A recording takes only its own window's keys: the composer's typing
    // passes through (it once took every key Sirius was sent).
    func testTakesOnlyTheRecordingWindowsKeys() {
        let model = model()
        let window = window()
        model.startRecording(in: window)
        let elsewhere = key("a", code: 0, windowNumber: window.windowNumber + 1000)
        XCTAssertFalse(model.take(elsewhere))
        XCTAssertTrue(model.isRecording)
        let here = key("k", code: 40, modifiers: [.command, .option], windowNumber: window.windowNumber)
        XCTAssertTrue(model.take(here))
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.compose, KeyCombo(keyCode: 40, modifiers: KeyCombo.command | KeyCombo.option))
    }

    func testTakesNothingWhenNotRecording() {
        let model = model()
        XCTAssertFalse(model.take(key("a", code: 0, windowNumber: 0)))
    }

    // A refused combo puts the old shortcut back at once.
    func testARefusalResumes() {
        let model = model(rebind: { _ in .takenByApp })
        let window = window()
        model.startRecording(in: window)
        XCTAssertTrue(model.take(key("k", code: 40, modifiers: [.command], windowNumber: window.windowNumber)))
        XCTAssertEqual(model.state, .refused("Taken by another app"))
        XCTAssertEqual(resumed, 1)
    }

    func testEscCancels() {
        let model = model()
        let window = window()
        model.startRecording(in: window)
        XCTAssertTrue(model.take(key("\u{1b}", code: 53, windowNumber: window.windowNumber)))
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(resumed, 1)
    }
}
