import SiriusCore
import SiriusProtocol

// The app's side of the seam the socket server calls. Accepting means
// enqueued, never shown: the receipt goes back before the toast appears.
final class AppCommandQueue: CommandQueue {
    private let toasts: ToastPresenter
    private let notifications: NotificationPresenter
    private let speech: SpeechPresenter

    init(toasts: ToastPresenter, notifications: NotificationPresenter, speech: SpeechPresenter) {
        self.toasts = toasts
        self.notifications = notifications
        self.speech = speech
    }

    func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
        switch command.call {
        case .display(let params):
            switch params.kind {
            case .toast:
                let text = ContentBlock.joinedText(params.content)
                let alert = params.alert ?? false
                // The capacity check and the enqueue happen in one main-actor
                // hop, so concurrent agents cannot overfill the queue.
                let accepted = await toasts.enqueue(agent: command.agent, text: text, alert: alert)
                return accepted
                    ? .success(.delivered)
                    : .failure(RPCError(.queueFull, "Queue full", data: ErrorData(method: .display)))
            case .dialog, .aside:
                // Validation rejects these with KIND_NOT_AVAILABLE before they get here.
                return .failure(RPCError(.kindNotAvailable, "Kind not available",
                                         data: ErrorData(method: .display, kind: params.kind.rawValue)))
            }
        case .notify(let params):
            // A blank title counts as none. Without one, the agent's name: its
            // id until the registry's display name lands.
            let given = params.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = given.isEmpty ? command.agent : given
            let handed = await notifications.post(title: title, body: ContentBlock.joinedText(params.content))
            return handed
                ? .success(.delivered)
                : .failure(RPCError(.internalError, "notify needs the installed Sirius.app",
                                    data: ErrorData(method: .notify)))
        case .speak(let params):
            // Voice resolution, the capacity check and the enqueue in one
            // main-actor hop; the receipt goes back before playback starts.
            let receipt = await speech.enqueue(agent: command.agent, text: params.text, voice: params.voice)
            return receipt.map { .success($0) }
                ?? .failure(RPCError(.queueFull, "Queue full", data: ErrorData(method: .speak)))
        }
    }
}
