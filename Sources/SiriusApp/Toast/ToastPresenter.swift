import AppKit
import SiriusCore
import SiriusProtocol

// Drives the toast panel from the FIFO: shows the current toast and advances
// on timeout or click; the next toast swaps in place, the last one closes.
@MainActor
final class ToastPresenter {
    private var queue = ToastQueue(capacity: Limits.maxQueued)
    private var dismissTimer: Timer?
    // The pointer on the toast holds it; the timer looks again every 0.8 s,
    // as the reference ack bubble does.
    private var hovered = false
    private static let hoverRecheck: TimeInterval = 0.8
    // The sending agent's logo, so the user sees who answered.
    private let mark: (String) -> NSImage?

    init(mark: @escaping (String) -> NSImage? = { _ in nil }) {
        self.mark = mark
    }
    private lazy var panel: ToastPanel = {
        let panel = ToastPanel()
        panel.onClick = { [weak self] in self?.dismissCurrent() }
        panel.onHover = { [weak self] in self?.hovered = $0 }
        return panel
    }()

    // Told of each toast an agent sends, as it is queued: the onboarding's
    // first turn waits on the reply.
    var onToast: ((String) -> Void)?

    // False when the queue is full; the caller answers QUEUE_FULL.
    func enqueue(agent: String, text: String, alert: Bool) -> Bool {
        onToast?(agent)
        switch queue.enqueue(agent: agent, text: text, alert: alert) {
        case .shown(let toast):
            show(toast)
            return true
        case .queued:
            return true
        case .full:
            return false
        }
    }

    private func dismissCurrent() {
        guard let seq = queue.current?.seq else { return }
        dismiss(seq: seq)
    }

    private func dismiss(seq: Int) {
        guard let advance = queue.dismiss(seq: seq) else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let next = advance.next {
            show(next)
        } else {
            hovered = false
            panel.dismiss()
        }
    }

    private func show(_ toast: Toast) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.present(agent: toast.agent, mark: mark(toast.agent), text: toast.text)
        // An alert has no timer: it holds the queue until clicked.
        if let duration = toast.duration {
            expire(seq: toast.seq, after: duration)
        }
    }

    private func expire(seq: Int, after interval: TimeInterval) {
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovered { return self.expire(seq: seq, after: Self.hoverRecheck) }
                self.dismiss(seq: seq)
            }
        }
    }
}
