import Foundation

// speak's logic with no AVFoundation: voices as plain data, the resolver,
// and the speech FIFO. The app's SpeechPresenter feeds them from
// AVSpeechSynthesisVoice and drives AVSpeechSynthesizer.

// An installed voice, as the app reads it from AVSpeechSynthesisVoice.
public struct SpeechVoice: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var language: String
    // AVSpeechSynthesisVoiceQuality's raw value: 1 default, 2 enhanced, 3 premium.
    public var quality: Int

    public init(identifier: String, name: String, language: String, quality: Int = 1) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }
}

public enum VoiceResolver {
    public struct Resolution: Equatable, Sendable {
        public var voice: SpeechVoice
        // A voice was asked for, by the request or the agent's default, and
        // could not be used.
        public var fallback: Bool
    }

    // Request, then the agent's default, then the app's default. A name that
    // matches nothing falls through and sets fallback.
    public static func resolve(requested: String?, agentDefault: String?, appDefault: SpeechVoice,
                               installed: [SpeechVoice], preferredLanguage: String? = nil) -> Resolution {
        var fallback = false
        for name in [requested, agentDefault] {
            guard let name else { continue }
            if let voice = match(name, in: installed, preferredLanguage: preferredLanguage) {
                return Resolution(voice: voice, fallback: fallback)
            }
            fallback = true
        }
        return Resolution(voice: appDefault, fallback: fallback)
    }

    // An exact identifier, else a case-insensitive name. Apple names the
    // better tiers "Karen (Premium)" and "Fiona (Enhanced)", so "Karen" also
    // matches those. Several voices can match: take the best quality, then
    // the user's language.
    public static func match(_ name: String, in installed: [SpeechVoice],
                             preferredLanguage: String? = nil) -> SpeechVoice? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let voice = installed.first(where: { $0.identifier == wanted }) { return voice }
        func same(_ a: String) -> Bool { a.caseInsensitiveCompare(wanted) == .orderedSame }
        let named = installed.filter { same($0.name) || same(baseName($0.name)) }
        func speaksPreferred(_ voice: SpeechVoice) -> Bool {
            guard let preferredLanguage else { return false }
            return voice.language.lowercased().hasPrefix(preferredLanguage.lowercased())
        }
        // Stable: among equals the first installed wins.
        return named.enumerated().min { a, b in
            if a.element.quality != b.element.quality { return a.element.quality > b.element.quality }
            let pa = speaksPreferred(a.element), pb = speaksPreferred(b.element)
            if pa != pb { return pa }
            return a.offset < b.offset
        }?.element
    }

    // "Karen (Premium)" -> "Karen". Only a trailing parenthetical.
    static func baseName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }
}

public struct Utterance: Equatable, Sendable {
    // Assigned by the queue; a late finish for an utterance that is no
    // longer current is ignored.
    public var seq: Int
    public var agent: String
    public var text: String
    public var voice: SpeechVoice
}

// One utterance at a time across all agents, the rest waiting in arrival
// order. Same shape as ToastQueue, without alerts or timers: playback ends
// when the synthesizer says so.
public struct SpeechQueue {
    // Utterances allowed to wait behind the one playing.
    public let capacity: Int
    public private(set) var current: Utterance?
    private var waiting: [Utterance] = []
    private var nextSeq = 1

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var backlog: Int { waiting.count }

    public enum EnqueueOutcome: Equatable {
        // Nothing was playing; start this one now.
        case started(Utterance)
        case queued(backlog: Int)
        case full
    }

    public mutating func enqueue(agent: String, text: String, voice: SpeechVoice) -> EnqueueOutcome {
        if current != nil && waiting.count >= capacity { return .full }
        let utterance = Utterance(seq: nextSeq, agent: agent, text: text, voice: voice)
        nextSeq += 1
        if current == nil {
            current = utterance
            return .started(utterance)
        }
        waiting.append(utterance)
        return .queued(backlog: waiting.count)
    }

    // Ends the current utterance, finished or stopped, if it is still `seq`,
    // and promotes the next. Returns nil when nothing changed.
    public mutating func finish(seq: Int) -> Advance? {
        guard let playing = current, playing.seq == seq else { return nil }
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return Advance(next: current)
    }

    public struct Advance: Equatable {
        public var next: Utterance?
    }
}
