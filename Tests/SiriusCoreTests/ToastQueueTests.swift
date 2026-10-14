import XCTest
@testable import SiriusCore

final class ToastQueueTests: XCTestCase {
    func testFifoCapacityAlertAndDrain() throws {
        var queue = ToastQueue(capacity: 3)
        guard case .shown(let first) = queue.enqueue(agent: "dev", text: "a", alert: false) else {
            return XCTFail("the first toast shows at once")
        }
        XCTAssertEqual(queue.current, first)
        XCTAssertEqual(queue.backlog, 0)
        XCTAssertEqual(queue.enqueue(agent: "x", text: "b", alert: true), .queued(backlog: 1))
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "c", alert: false), .queued(backlog: 2))
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "d", alert: false), .queued(backlog: 3))
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "e", alert: false), .full)

        XCTAssertNil(queue.dismiss(seq: 999), "a stale seq is ignored")
        XCTAssertEqual(queue.dismiss(seq: first.seq)?.next?.text, "b")
        XCTAssertEqual(queue.backlog, 2)
        XCTAssertNil(queue.current?.duration, "an alert has no timer")
        XCTAssertNil(queue.dismiss(seq: first.seq), "a double dismiss is ignored")
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "e", alert: false), .queued(backlog: 3))

        let alert = try XCTUnwrap(queue.current)
        XCTAssertEqual(queue.dismiss(seq: alert.seq)?.next?.text, "c")
        _ = queue.dismiss(seq: try XCTUnwrap(queue.current).seq)
        _ = queue.dismiss(seq: try XCTUnwrap(queue.current).seq)
        XCTAssertEqual(queue.current?.text, "e")
        XCTAssertEqual(queue.dismiss(seq: try XCTUnwrap(queue.current).seq), ToastQueue.Advance(next: nil))
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.backlog, 0)
    }

    func testDurations() {
        func duration(_ count: Int) -> Double? {
            Toast(seq: 0, agent: "", text: String(repeating: "x", count: count), alert: false).duration
        }
        XCTAssertEqual(duration(0), 5)
        XCTAssertEqual(duration(60), 5)
        XCTAssertEqual(duration(110)!, 8, accuracy: 0.001)
        XCTAssertEqual(duration(150), 10)
        XCTAssertEqual(duration(280), 10)
    }
}
