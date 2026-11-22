import AppKit
import XCTest
@testable import SiriusApp

// A display sleep left the toast panel on no Space: AppKit ordered it in and
// out, every `sirius display toast` exited 0, and nothing showed
// (2026.10.21). The presenter must replace such a panel, never reuse it.
@MainActor
final class ToastPresenterTests: XCTestCase {
    private final class FakeSurface: ToastSurface {
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        var isVisible = false
        // Whether WindowServer would strand this window once it is ordered in.
        var strands: Bool
        // Whether WindowServer leaves it off screen though AppKit reports it
        // up and on the active Space (2026.11.15).
        var hidden: Bool
        var presented: [String] = []
        var retired = false

        init(strands: Bool, hidden: Bool = false) {
            self.strands = strands
            self.hidden = hidden
        }

        var isStranded: Bool { isVisible && strands }
        var isOnScreen: Bool { isVisible && !hidden }
        var state: String { "fake" }
        func present(agent: String, mark: NSImage?, text: String) {
            presented.append(text)
            isVisible = true
        }
        func dismiss() { isVisible = false }
        func retire() {
            retired = true
            isVisible = false
        }
    }

    private func presenter(strandFirst: Int, hideFirst: Int = 0) -> (ToastPresenter, () -> [FakeSurface]) {
        var made: [FakeSurface] = []
        let presenter = ToastPresenter(verifyDelay: nil, makeSurface: {
            let surface = FakeSurface(strands: made.count < strandFirst, hidden: made.count < hideFirst)
            made.append(surface)
            return surface
        })
        return (presenter, { made })
    }

    // A logo that is not square keeps its aspect in the toast's mark box:
    // portrait fills the height, landscape the width, never stretched.
    func testAMarkThatIsNotSquareKeepsItsAspect() {
        let box: CGFloat = 18
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 18, height: 18), in: box),
                       NSSize(width: 18, height: 18))
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 24, height: 30), in: box).height, box)
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 24, height: 30), in: box).width, 14.4, accuracy: 0.0001)
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 30, height: 24), in: box).width, box)
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 30, height: 24), in: box).height, 14.4, accuracy: 0.0001)
        XCTAssertEqual(ToastPanel.markSize(for: NSSize(width: 0, height: 30), in: box), NSSize(width: 18, height: 18))
    }

    func testAStrandedPanelIsReplacedAndTheToastShownOnTheNewOne() {
        let (presenter, made) = presenter(strandFirst: 1)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "hello", alert: true))
        XCTAssertEqual(made().count, 2, "the stranded panel is replaced")
        XCTAssertTrue(made()[0].retired, "the stranded panel is retired")
        XCTAssertEqual(made()[1].presented, ["hello"], "the toast shows on the new panel")
        XCTAssertFalse(made()[1].isStranded)
    }

    func testAHealthyPanelIsReused() {
        let (presenter, made) = presenter(strandFirst: 0)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "one", alert: true))
        XCTAssertEqual(made().count, 1)
        XCTAssertEqual(made()[0].presented, ["one"])
        XCTAssertFalse(made()[0].retired)
    }

    func testAWakeReplacesThePanelAtTheNextOpen() {
        let (presenter, made) = presenter(strandFirst: 0)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "before", alert: true))
        // The alert is up when the displays wake: it stays where it is.
        presenter.displaysWoke()
        made()[0].onClick?()
        XCTAssertFalse(made()[0].isVisible, "the click dismissed the alert")
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "after", alert: true))
        XCTAssertEqual(made().count, 2, "a panel built before the wake is not reused")
        XCTAssertTrue(made()[0].retired)
        XCTAssertEqual(made()[1].presented, ["after"])
    }

    func testAWakeDoesNotReplaceAPanelThatIsShowing() {
        let (presenter, made) = presenter(strandFirst: 0)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "up", alert: true))
        presenter.displaysWoke()
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "next", alert: false))
        XCTAssertEqual(made().count, 1, "a queued toast waits; the showing panel is not swapped out")
        XCTAssertFalse(made()[0].retired)
    }

    func testAReplaceSwapsTheToastOnScreen() {
        let (presenter, made) = presenter(strandFirst: 0)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "ack", alert: false))
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "result", alert: false, replace: true))
        XCTAssertEqual(made()[0].presented, ["ack", "result"], "the result swaps in at once")
        made()[0].onClick?()
        XCTAssertFalse(made()[0].isVisible, "nothing was left queued behind it")
    }

    // AppKit has the panel up and on the active Space, so the check at show
    // passes, but WindowServer has it on no screen: the verify a moment
    // later replaces it and shows the toast again (2026.11.15).
    func testAPanelWindowServerHasOffScreenIsReplacedAtVerify() {
        let (presenter, made) = presenter(strandFirst: 0, hideFirst: 1)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "unseen", alert: false))
        XCTAssertEqual(made().count, 1, "the AppKit check at show does not catch it")
        presenter.verify(seq: 1)
        XCTAssertEqual(made().count, 2, "the off-screen panel is replaced")
        XCTAssertTrue(made()[0].retired)
        XCTAssertEqual(made()[1].presented, ["unseen"])
        XCTAssertTrue(made()[1].isOnScreen)
    }

    func testAVerifyOfAToastOnScreenChangesNothing() {
        let (presenter, made) = presenter(strandFirst: 0)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "seen", alert: false))
        presenter.verify(seq: 1)
        XCTAssertEqual(made().count, 1)
        XCTAssertFalse(made()[0].retired)
    }

    // A swap into a panel that is up is verified too, and a verify for a
    // toast no longer current does nothing.
    func testAVerifyCoversSwapsAndIgnoresAnOldToast() {
        let (presenter, made) = presenter(strandFirst: 0, hideFirst: 1)
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "ack", alert: false))
        XCTAssertTrue(presenter.enqueue(agent: "claude", text: "result", alert: false, replace: true))
        presenter.verify(seq: 1)
        XCTAssertEqual(made().count, 1, "the replaced toast's verify is stale")
        presenter.verify(seq: 2)
        XCTAssertEqual(made().count, 2)
        XCTAssertEqual(made()[1].presented, ["result"])
    }
}
