import Foundation

// One agent as dictation can address it: its registry id and the words that
// name it when spoken.
public struct DictationAddress: Equatable, Sendable {
    // Registry id: "claude".
    public let agent: String
    // Its name and the mishearings, lowercased: "claude", "cloud", "clod".
    // A form may be several words ("code x").
    public let spoken: [String]

    public init(agent: String, spoken: [String]) {
        self.agent = agent
        self.spoken = spoken
    }

    // The address for a registered agent: its id, its display name and the
    // known mishearings of either, lowercased and without duplicates.
    public static func forAgent(id: String, name: String) -> DictationAddress {
        var spoken: [String] = []
        for form in [id, name].map({ $0.lowercased() }) {
            for candidate in [form] + (mishearings[form] ?? []) where !candidate.isEmpty && !spoken.contains(candidate) {
                spoken.append(candidate)
            }
        }
        return DictationAddress(agent: id, spoken: spoken)
    }

    // What Whisper writes for an agent's name, keyed by the lowercased name.
    // TODO: filled from recordings.
    static let mishearings: [String: [String]] = [
        "claude": ["cloud", "clawed", "clod"],
        "codex": ["codecs", "code x"],
    ]
}

public enum DictationRoute: Equatable, Sendable {
    // "Codex, run the tests" → ("codex", "run the tests").
    case agent(String, String)
    // No prefix: the whole transcript, for the composer's current agent.
    case selected(String)
}

// Reads the spoken prefix of a transcript (dictation.md). Case is ignored and a leading "hey", "ok" or "okay" is skipped.
// An agent's name routes only when a comma, colon or full stop follows, so
// "Codex failed the build
// again" is a sentence about Codex for the selected agent. The "Dictate:"
// prefix, which pasted at the cursor, was dropped for now: every transcript goes to an agent. The prefix and its
// punctuation are stripped; the body is left as Whisper wrote it.
public enum DictationRouter {
    static let greetings = ["hey", "okay", "ok"]
    // What may follow a prefix and is stripped with it.
    static let prefixPunctuation: Set<Character> = [",", ":", ".", ";", "!"]
    // What must follow an agent's name for it to address the agent.
    static let addressPunctuation: Set<Character> = [",", ":", "."]

    public static func route(_ transcript: String, agents: [DictationAddress]) -> DictationRoute {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        if let end = greetings.lazy.compactMap({ matchWords([$0], in: rest) }).first {
            rest = skipPunctuation(rest[end...])
        }

        // The longest spoken form wins, so "code x," is Codex even if some
        // agent answers to "code"; a tie goes to the first agent listed.
        var best: (agent: String, end: Substring.Index, length: Int)?
        for address in agents {
            for form in address.spoken {
                let words = form.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty, let end = matchWords(words, in: rest),
                      end < rest.endIndex, addressPunctuation.contains(rest[end]) else { continue }
                let length = rest.distance(from: rest.startIndex, to: end)
                if length > (best?.length ?? 0) { best = (address.agent, end, length) }
            }
        }
        if let best { return .agent(best.agent, String(skipPunctuation(rest[best.end...]))) }

        return .selected(trimmed)
    }

    // Where `words` end if they open `text` as whole words, ignoring case,
    // with whitespace or a hyphen between them.
    static func matchWords(_ words: [String], in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        for (i, word) in words.enumerated() {
            if i > 0 {
                let gap = text[index...].prefix { $0.isWhitespace || $0 == "-" }
                guard !gap.isEmpty else { return nil }
                index = gap.endIndex
            }
            guard let range = text[index...].range(of: word, options: [.caseInsensitive, .anchored]) else {
                return nil
            }
            index = range.upperBound
        }
        if index < text.endIndex, text[index].isLetter || text[index].isNumber { return nil }
        return index
    }

    // Drops the punctuation and whitespace between a prefix and its body.
    static func skipPunctuation(_ text: Substring) -> Substring {
        text.drop { prefixPunctuation.contains($0) || $0.isWhitespace }
    }
}
