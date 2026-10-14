import Foundation
import SiriusProtocol

// The text every adapter gives the agent as one turn (proto.ts, "Sirius to
// agent"). A tagged wrapper, not a parsed format: the user's words go in
// verbatim, as Claude Code passes pasted text to its own model. The closing tag repeats the message id, so user text that
// contains "</sirius>" cannot end the wrapper early.
public enum MessageRenderer {
    // Every turn ends with it, so the agent never loses it to a long context.
    // TODO(andrew): the wording.
    public static let replyNote = "Reach the user only through display, notify or speak; your plain output is never shown."

    public static func render(_ message: Message) -> String {
        var lines = ["<sirius message=\"\(escape(message.id))\" agent=\"\(escape(message.agent))\">"]
        lines.append(message.text)
        if !message.attachments.isEmpty {
            lines.append("")
            for attachment in message.attachments {
                lines.append("<attachment path=\"\(escape(attachment.path))\" type=\"\(escape(attachment.mimeType))\"/>")
            }
        }
        lines.append("</sirius message=\"\(escape(message.id))\">")
        lines.append(replyNote)
        return lines.joined(separator: "\n")
    }

    // Attribute values only; the user's words are never escaped.
    static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            default: out.append(character)
            }
        }
        return out
    }
}
