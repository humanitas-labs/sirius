import Foundation

// Dictated text going into the open composer at its caret (dictation.md:
// "with the composer open, fn dictates into the composer"). One space is
// added before it when it would otherwise run on from the word before the
// caret, so two dictations in a row make one message; nothing is added at
// the start of the field or after whitespace. A simpler rule than Parrot's
// Spacing, which reads any app's field through Accessibility: the composer
// is Sirius's own text view, so the character before the caret is known.
public enum DictationSpacing {
    // `text` as it goes in after `previous`, the character before the caret,
    // or nil at the start of the field. Leading whitespace in `text` is
    // dropped, so the space is never doubled.
    public static func spaced(_ text: String, after previous: Character?) -> String {
        let body = String(text.drop(while: \.isWhitespace))
        guard !body.isEmpty, let previous, !previous.isWhitespace else { return body }
        return " " + body
    }
}
