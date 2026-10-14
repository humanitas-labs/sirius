import XCTest
@testable import SiriusCore

final class GrantsTests: XCTestCase {
    private let ready = GrantContext(canRequestMicrophone: true)

    private func steps(_ grant: Grant, _ state: GrantState, _ context: GrantContext) -> [GrantStep] {
        Grants.allowSteps(for: grant, in: state, context: context)
    }

    func testNothingOnceGranted() {
        let all = GrantState(accessibility: true, microphone: .granted)
        XCTAssertTrue(all.allGranted)
        XCTAssertEqual(steps(.accessibility, all, ready), [])
        XCTAssertEqual(steps(.microphone, all, ready), [])
        XCTAssertFalse(GrantState(accessibility: true, microphone: .denied).allGranted)
    }

    func testAccessibilityPromptsOnceThenOpensThePane() {
        let none = GrantState(accessibility: false, microphone: .notDetermined)
        XCTAssertEqual(steps(.accessibility, none, ready), [.promptAccessibility])
        var asked = ready
        asked.accessibilityPrompted = true
        XCTAssertEqual(steps(.accessibility, none, asked), [.openAccessibilitySettings])
    }

    func testMicrophoneRequestsThenOpensThePaneOnceDenied() {
        XCTAssertEqual(steps(.microphone, GrantState(accessibility: true, microphone: .notDetermined), ready),
                       [.requestMicrophone])
        XCTAssertEqual(steps(.microphone, GrantState(accessibility: true, microphone: .denied), ready),
                       [.openMicrophoneSettings])
    }

    func testNoMicrophoneRequestWithoutTheUsageDescription() {
        let noKey = GrantContext(canRequestMicrophone: false)
        XCTAssertEqual(steps(.microphone, GrantState(accessibility: true, microphone: .notDetermined), noKey), [],
                       "a request without NSMicrophoneUsageDescription crashes")
        XCTAssertEqual(steps(.microphone, GrantState(accessibility: true, microphone: .denied), noKey),
                       [.openMicrophoneSettings], "opening the pane needs no key")
    }

    func testPromptsNeverStack() {
        let none = GrantState(accessibility: false, microphone: .notDetermined)
        for prompting in Grant.allCases {
            let context = GrantContext(canRequestMicrophone: true, prompting: prompting)
            XCTAssertEqual(steps(.accessibility, none, context), [], "while \(prompting)'s prompt is up")
            XCTAssertEqual(steps(.microphone, none, context), [], "while \(prompting)'s prompt is up")
        }
        // Each step that prompts is the only step its button takes.
        for grant in Grant.allCases {
            let first = steps(grant, none, ready)
            XCTAssertTrue(Grants.prompts(first))
            XCTAssertEqual(first.count, 1)
        }
        XCTAssertFalse(Grants.prompts([.openAccessibilitySettings, .openMicrophoneSettings]))
    }
}
