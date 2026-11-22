import AppKit
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusApp

// `last` through the app's own queue: an agent's accepted display is its
// last response, shown again on demand exactly as it was accepted — a
// toast, an alert where the display set one — and there is nothing to
// show before the agent has displayed anything.
@MainActor
final class AppCommandQueueTests: XCTestCase {
    private final class FakeSurface: ToastSurface {
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        var isVisible = false
        var presented: [(agent: String, mark: NSImage?, text: String)] = []

        var isStranded: Bool { false }
        var isOnScreen: Bool { isVisible }
        var state: String { "fake" }
        func present(agent: String, mark: NSImage?, text: String) {
            presented.append((agent, mark, text))
            isVisible = true
        }
        func dismiss() { isVisible = false }
        func retire() { isVisible = false }
    }

    private func makeQueue() -> (AppCommandQueue, LastResponses, () -> [FakeSurface]) {
        var made: [FakeSurface] = []
        let toasts = ToastPresenter(verifyDelay: nil, makeSurface: {
            let surface = FakeSurface()
            made.append(surface)
            return surface
        })
        let responses = LastResponses()
        let queue = AppCommandQueue(toasts: toasts, notifications: NotificationPresenter(),
                                    speech: SpeechPresenter(agentVoice: { _ in nil }), responses: responses)
        return (queue, responses, { made })
    }

    private func display(_ agent: String, _ text: String, alert: Bool = false) -> Command {
        Command(agent: agent, id: .string(UUID().uuidString),
                call: .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: text))], alert: alert)),
                received: Date())
    }

    private func last(_ agent: String) -> Command {
        Command(agent: agent, id: .string(UUID().uuidString), call: .last(LastParams()),
                received: Date(timeIntervalSince1970: 1_791_900_100))
    }

    func testNothingToShowBeforeADisplay() async {
        let (queue, _, _) = makeQueue()
        guard case .failure(let error) = await queue.accept(last("claude")) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(error.code, .nothingToShow)
        XCTAssertEqual(error.data?.method, .last)
    }

    func testALastDisplayIsShownAgainAsItWasAccepted() async {
        let (queue, _, made) = makeQueue()
        guard case .success(.delivered) = await queue.accept(display("claude", "Pushed the branch")) else {
            return XCTFail("the display was not accepted")
        }
        // The toast leaves, as toasts do.
        made()[0].onClick?()
        XCTAssertFalse(made()[0].isVisible)

        guard case .success(.delivered) = await queue.accept(last("claude")) else {
            return XCTFail("last was not accepted")
        }
        XCTAssertEqual(made().count, 1, "the same panel shows it again")
        XCTAssertEqual(made()[0].presented.map(\.text), ["Pushed the branch", "Pushed the branch"])
        XCTAssertEqual(made()[0].presented.map(\.agent), ["claude", "claude"], "under the agent's own mark")
        XCTAssertTrue(made()[0].isVisible)
    }

    func testAnAlertDisplayComesBackAsAnAlert() async {
        let (queue, responses, _) = makeQueue()
        _ = await queue.accept(display("claude", "cannot go on", alert: true))
        XCTAssertEqual(responses.latest(agent: "claude")?.alert, true, "the alert flag is kept")
        guard case .success(.delivered) = await queue.accept(last("claude")) else { return XCTFail() }
    }

    func testEachAgentsLastIsItsOwnAndTheNewestWinsTheMenu() async {
        let (queue, responses, _) = makeQueue()
        _ = await queue.accept(display("claude", "claude's"))
        _ = await queue.accept(display("codex", "codex's"))
        XCTAssertEqual(responses.latest(agent: "claude")?.text, "claude's")
        XCTAssertEqual(responses.latest(agent: "codex")?.text, "codex's")
        XCTAssertEqual(responses.newest()?.agent, "codex", "codex displayed last")
    }
}
