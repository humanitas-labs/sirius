import SiriusCore
import SiriusProtocol

// The app's side of the seam the socket server calls. Accepting means
// enqueued, never shown: the receipt goes back before the toast appears.
final class AppCommandQueue: CommandQueue {
    private let toasts: ToastPresenter
    private let notifications: NotificationPresenter
    private let speech: SpeechPresenter
    // The last display each agent sent, seeded from the logs by the outer
    // LoggingCommandQueue and recorded here as displays are accepted;
    // `last` shows one again.
    private let responses: LastResponses?

    init(toasts: ToastPresenter, notifications: NotificationPresenter, speech: SpeechPresenter,
         responses: LastResponses? = nil) {
        self.toasts = toasts
        self.notifications = notifications
        self.speech = speech
        self.responses = responses
    }

    func accept(_ command: Command) async -> Result<MethodResult, RPCError> {
        switch command.call {
        case .agentMessage:
            return .failure(RPCError(.notReady, "No agent queue for peer delivery"))
        case .display(let params):
            switch params.kind {
            case .toast:
                let text = ContentBlock.joinedText(params.content)
                let alert = params.alert ?? false
                let replace = params.replace ?? false
                // The capacity check and the enqueue happen in one main-actor
                // hop, so concurrent agents cannot overfill the queue.
                let accepted = await toasts.enqueue(agent: command.agent, text: text, alert: alert, replace: replace)
                if accepted {
                    // The user's way to ask for this again (sirius last, the
                    // menu's Last response): what the queue took, not what it
                    // refused.
                    responses?.record(LastResponse(agent: command.agent, alert: alert, text: text,
                                                    at: command.received))
                    return .success(.delivered)
                }
                return .failure(RPCError(.queueFull, "Queue full", data: ErrorData(method: .display)))
            case .dialog:
                // Validation rejects this with KIND_NOT_AVAILABLE before it gets here.
                return .failure(RPCError(.kindNotAvailable, "Kind not available",
                                         data: ErrorData(method: .display, kind: params.kind.rawValue)))
            }
        case .last:
            guard let last = responses?.latest(agent: command.agent) else {
                return .failure(RPCError(.nothingToShow, "Nothing has been displayed yet",
                                         data: ErrorData(method: .last)))
            }
            let accepted = await toasts.enqueue(agent: last.agent, text: last.text, alert: last.alert)
            return accepted
                ? .success(.delivered)
                : .failure(RPCError(.queueFull, "Queue full", data: ErrorData(method: .last)))
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
