import Foundation
import SiriusProtocol

// The three tools, one per Sirius method. Each inputSchema is the generated
// JSON Schema of the method's Params (scripts/gen-schema.sh), so the
// arguments pass through to the app untouched and the app validates them.
struct Tool {
    var method: SiriusProtocol.Method
    var title: String
    var description: String
    var inputSchema: String

    var name: String { method.rawValue }

    static let all: [Tool] = [display, notify, speak, last]

    static func named(_ name: String) -> Tool? {
        all.first { $0.name == name }
    }

    static let display = Tool(
        method: .display,
        title: "Display",
        description: """
            Show something to the user on screen. kind "toast" is a short message near the bottom \
            of the screen; it takes text only, up to \(Limits.maxToastChars) characters. Set alert \
            to keep the toast up until the user dismisses it, only when you cannot go on until the \
            user answers, or for something urgent; use it rarely. Set replace to have the toast take \
            the place of your own toast instead of queueing behind it, such as a result after its ack. content \
            is a string, or an array of content blocks such as {"type": "text", "text": "..."}. \
            Returns once Sirius has queued it.
            """,
        inputSchema: Schemas.displayParams
    )

    static let notify = Tool(
        method: .notify,
        title: "Notify",
        description: """
            Post a notification to the user's Notification Center. content is a string or an \
            array of text blocks, up to \(Limits.maxNotifyChars) characters; title is optional. \
            Returns once handed to Notification Center, which does not prove the user saw it.
            """,
        inputSchema: Schemas.notifyParams
    )

    static let speak = Tool(
        method: .speak,
        title: "Speak",
        description: """
            Speak text aloud to the user, up to \(Limits.maxSpeakChars) characters of plain text. \
            voice is an installed Apple voice name; omit it for your default voice. Returns once \
            the speech is queued, not when it ends; the result names the voice used and has \
            fallback: true if the requested voice was not installed.
            """,
        inputSchema: Schemas.speakParams
    )

    static let last = Tool(
        method: .last,
        title: "Last",
        description: """
            Show the user your last displayed response again, exactly as it was shown: a toast, \
            an alert where the display set one. Use it when they ask you to say or show it again. \
            It is refused with NOTHING_TO_SHOW if you have displayed nothing yet. Nothing is passed.
            """,
        inputSchema: Schemas.lastParams
    )

    // The entry in a tools/list result.
    var listing: JSONValue {
        // The schema is generated and checked by the build's tests; a parse
        // failure here is a bug in the generator run, not an input error.
        let schema = (try? JSONValue.parse(Data(inputSchema.utf8))) ?? .object(["type": .string("object")])
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": schema,
            // Every call changes what the user sees or hears, and a repeat
            // shows it twice; nothing is deleted and nothing leaves the Mac.
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(false),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}
