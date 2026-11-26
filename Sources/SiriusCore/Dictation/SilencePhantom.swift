import Foundation

// What Whisper writes when it is given silence: a quick tap of the talk key
// with nothing said comes back as "You" (2026.11.25: three taps of 0.46 to
// 0.88 s each sent "You" to the agent; 22 such in the log before them).
// A transcript that is nothing but that word is dropped, so nothing is
// delivered, as for an empty one. "You" inside a sentence is untouched. The
// cost is that the single word "you" cannot be dictated on its own.
public enum SilencePhantom {
    // The whole transcript, lowercased, without punctuation or outer spaces.
    static let phantoms: Set<String> = ["you"]

    public static func isPhantom(_ text: String) -> Bool {
        let word = text.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return phantoms.contains(word)
    }
}
