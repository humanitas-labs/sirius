import ArgumentParser
import Foundation
import SiriusClient
import SiriusProtocol

struct Sirius: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sirius",
        abstract: "Reach the user through Sirius: a toast, a notification or speech.",
        discussion: """
            Sends one request to the Sirius app over $SIRIUS_SOCKET and waits up to \
            $SIRIUS_TIMEOUT seconds (default \(SiriusEnvironment.defaultTimeoutSeconds)) for the \
            receipt. Prints nothing on success. Never retries.

            Text is the remaining arguments joined with single spaces, like echo. Put "--" before \
            text that starts with "-": sirius display toast -- -1 failed

            Exit codes:
              0  accepted by Sirius
              1  rejected by Sirius; "sirius: <message> (<code>)" on stderr
              2  bad usage
              3  Sirius isn't running, or SIRIUS_SOCKET is not set; nothing was sent
              4  outcome unknown: it may have been accepted; not retried
            """,
        subcommands: [Display.self, Notify.self, Speak.self]
    )

    // Bare `sirius` is a usage error, not a request for help.
    func run() throws {
        FileHandle.standardError.write(Data((Sirius.helpMessage() + "\n").utf8))
        throw ExitCode(ExitStatus.usage)
    }
}

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show content in a display kind.",
        discussion: """
            sirius display toast "Pushed the branch"
            sirius display toast --alert -- -1 test failed
            echo '[{"type":"text","text":"done"}]' | sirius display toast --json
            """
    )

    @Argument(help: "The display kind: \(DisplayKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    var kind: String

    @Flag(help: "toast only: stays until dismissed.")
    var alert = false

    @Flag(help: "Read the content from stdin as JSON: a string or an array of content blocks.")
    var json = false

    @Argument(help: "The text, joined with spaces. Omit with --json.")
    var text: [String] = []

    func validate() throws {
        // Cheap and offline; the app still validates everything.
        guard DisplayKind(rawValue: kind) != nil else {
            throw ValidationError("unknown display kind \"\(kind)\"; expected one of: "
                + DisplayKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        try validateText(text, json: json)
    }

    func run() throws {
        var params: [String: JSONValue] = ["kind": .string(kind), "content": try content(text, json: json)]
        if alert { params["alert"] = .bool(true) }
        try send(.display, params)
    }
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Post a notification to Notification Center.",
        discussion: """
            sirius notify --title "Build" "All tests pass"
            echo '"done"' | sirius notify --json
            """
    )

    @Option(help: "The notification's title.")
    var title: String?

    @Flag(help: "Read the content from stdin as JSON: a string or an array of content blocks.")
    var json = false

    @Argument(help: "The text, joined with spaces. Omit with --json.")
    var text: [String] = []

    func validate() throws {
        try validateText(text, json: json)
    }

    func run() throws {
        var params: [String: JSONValue] = ["content": try content(text, json: json)]
        if let title { params["title"] = .string(title) }
        try send(.notify, params)
    }
}

struct Speak: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak text aloud.",
        discussion: """
            Returns once the speech is queued, not when it ends. If the voice is not installed, \
            the default is used and a note goes to stderr; the exit code is still 0.

            sirius speak --voice "Bad News" "The build is broken"
            """
    )

    @Option(help: "An installed Apple voice name. Default: the agent's voice.")
    var voice: String?

    @Argument(help: "The text, joined with spaces.")
    var text: [String] = []

    func validate() throws {
        try validateText(text, json: false)
    }

    func run() throws {
        var params: [String: JSONValue] = ["text": .string(text.joined(separator: " "))]
        if let voice { params["voice"] = .string(voice) }
        let receipt = try send(.speak, params)
        // The only receipt worth reading: the voice asked for was not used.
        if receipt["fallback"] == .bool(true), let used = receipt["voice"]?.string {
            let asked = voice.map { "voice \"\($0)\"" } ?? "the default voice"
            printError("\(asked) isn't installed; used \"\(used)\"")
        }
    }
}

// MARK: - Shared

private func validateText(_ text: [String], json: Bool) throws {
    if json && !text.isEmpty { throw ValidationError("give the text as arguments or --json on stdin, not both") }
    if !json && text.isEmpty { throw ValidationError("missing text") }
}

// The content as the app receives it. Text arguments go as one string, which
// the app turns into a text block. --json input is passed through as parsed,
// so a string that looks like JSON stays a string and blocks stay blocks; the
// app judges both.
private func content(_ text: [String], json: Bool) throws -> JSONValue {
    guard json else { return .string(text.joined(separator: " ")) }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let value = try? JSONValue.parse(input) else {
        printError("--json: stdin is not valid JSON")
        throw ExitCode(ExitStatus.usage)
    }
    return value
}

// Sends one request and maps the outcome to stderr and the exit code.
// Returns the receipt on success.
@discardableResult
private func send(_ method: SiriusProtocol.Method, _ params: [String: JSONValue]) throws -> JSONValue {
    let client: SiriusClient
    do {
        client = try SiriusClient.fromEnvironment()
    } catch let error as ConfigurationError {
        printError(error.message)
        throw ExitCode(error.exitCode)
    }
    let outcome = client.call(method, params: JSONValue.object(params))
    if case .result(let receipt) = outcome { return receipt }
    if let message = outcome.message { printError(message) }
    throw ExitCode(outcome.exitCode)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("sirius: \(message)\n".utf8))
}
