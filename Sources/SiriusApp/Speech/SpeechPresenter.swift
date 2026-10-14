import AVFoundation
import SiriusCore
import SiriusProtocol

// Speech is its own lane: one utterance at a time across all agents, FIFO,
// beside the toast queue rather than in it, so a long utterance never holds
// display toasts back and a toast backlog never delays speech.
@MainActor
final class SpeechPresenter: NSObject, AVSpeechSynthesizerDelegate {
    private var queue = SpeechQueue(capacity: Limits.maxQueued)
    private let synthesizer = AVSpeechSynthesizer()
    // The agent's default voice from its registration. "dev" has none; the
    // registry supplies it later.
    private let agentVoice: (String) -> String?
    // The utterance the synthesizer is playing, held so its identity is not
    // reused while a delegate callback for it may still arrive.
    private var playing: (seq: Int, utterance: AVSpeechUtterance)?
    private lazy var panel: SpeechPanel = {
        let panel = SpeechPanel()
        panel.onStop = { [weak self] in self?.stop() }
        return panel
    }()

    init(agentVoice: @escaping (String) -> String? = { _ in nil }) {
        self.agentVoice = agentVoice
        super.init()
        synthesizer.delegate = self
    }

    // The receipt, or nil when the queue is full and the caller answers
    // QUEUE_FULL. Never waits for playback.
    func enqueue(agent: String, text: String, voice requested: String?) -> MethodResult? {
        // Read on every request: the user can download a voice while Sirius runs.
        let installed = AVSpeechSynthesisVoice.speechVoices().map(SpeechVoice.init)
        let resolution = VoiceResolver.resolve(
            requested: requested, agentDefault: agentVoice(agent),
            appDefault: Self.appDefaultVoice(installed: installed), installed: installed,
            preferredLanguage: AVSpeechSynthesisVoice.currentLanguageCode())
        switch queue.enqueue(agent: agent, text: text, voice: resolution.voice) {
        case .started(let utterance):
            play(utterance)
        case .queued(let backlog):
            panel.setBacklog(backlog)
        case .full:
            return nil
        }
        return .queued(voice: resolution.voice.name, fallback: resolution.fallback)
    }

    // TODO(andrew): which Apple voice is the app's default.
    // Placeholder: the system's default voice for the current language.
    private static func appDefaultVoice(installed: [SpeechVoice]) -> SpeechVoice {
        if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
            return SpeechVoice(voice)
        }
        // An identifier that matches nothing makes the utterance use the
        // synthesizer's own default.
        return installed.first ?? SpeechVoice(identifier: "", name: "System voice", language: "")
    }

    // Stops the current utterance only and moves on to the next, as a click
    // on a toast does: what other agents queued was receipted and is not
    // dropped. The "+N more" on the capsule says more is coming.
    private func stop() {
        guard let seq = playing?.seq else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // Advance now; the didCancel that follows names a stale seq and is ignored.
        finished(seq: seq)
    }

    private func play(_ next: Utterance) {
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: next.voice.identifier)
        playing = (next.seq, utterance)
        panel.present(agent: next.agent, text: next.text, backlog: queue.backlog)
        synthesizer.speak(utterance)
    }

    private func finished(seq: Int) {
        guard let advance = queue.finish(seq: seq) else { return }
        playing = nil
        if let next = advance.next {
            play(next)
        } else {
            panel.orderOut(nil)
        }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard let playing, ObjectIdentifier(playing.utterance) == id else { return }
        finished(seq: playing.seq)
    }

    // The synthesizer calls back on a thread of its choosing.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}

extension SpeechVoice {
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(identifier: voice.identifier, name: voice.name, language: voice.language,
                  quality: voice.quality.rawValue)
    }
}
