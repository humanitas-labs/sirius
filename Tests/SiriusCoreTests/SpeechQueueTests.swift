import XCTest
@testable import SiriusCore

final class VoiceResolverTests: XCTestCase {
    let appDefault = SpeechVoice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US")
    let installed = [
        SpeechVoice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US"),
        SpeechVoice(identifier: "com.apple.speech.synthesis.voice.BadNews", name: "Bad News", language: "en-US"),
        SpeechVoice(identifier: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB"),
        SpeechVoice(identifier: "com.apple.voice.compact.en-US.Ava", name: "Ava", language: "en-US", quality: 1),
        SpeechVoice(identifier: "com.apple.voice.premium.en-US.Ava", name: "Ava", language: "en-US", quality: 3),
        SpeechVoice(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US"),
        SpeechVoice(identifier: "com.apple.eloquence.fr-FR.Eddy", name: "Eddy", language: "fr-FR"),
    ]

    func resolve(_ requested: String?, agent: String? = nil, language: String? = nil) -> VoiceResolver.Resolution {
        VoiceResolver.resolve(requested: requested, agentDefault: agent, appDefault: appDefault,
                              installed: installed, preferredLanguage: language)
    }

    func testRequestedByNameOrIdentifier() {
        XCTAssertEqual(resolve("bad news").voice.name, "Bad News")
        XCTAssertFalse(resolve("bad news").fallback)
        XCTAssertEqual(resolve("com.apple.voice.compact.en-GB.Daniel").voice.name, "Daniel")
        XCTAssertEqual(resolve(" Daniel ").voice.name, "Daniel")
    }

    func testRequestBeatsAgentDefault() {
        XCTAssertEqual(resolve("Daniel", agent: "Bad News"), .init(voice: installed[2], fallback: false))
    }

    func testNoRequestUsesAgentDefaultThenApp() {
        XCTAssertEqual(resolve(nil, agent: "Bad News"), .init(voice: installed[1], fallback: false))
        XCTAssertEqual(resolve(nil), .init(voice: appDefault, fallback: false))
    }

    func testUnknownRequestFallsBackToAgentThenApp() {
        XCTAssertEqual(resolve("Nonexistent", agent: "Daniel"), .init(voice: installed[2], fallback: true))
        XCTAssertEqual(resolve("Nonexistent"), .init(voice: appDefault, fallback: true))
        XCTAssertEqual(resolve("", agent: nil), .init(voice: appDefault, fallback: true))
    }

    func testUnavailableAgentDefaultFallsBackToApp() {
        XCTAssertEqual(resolve(nil, agent: "Gone"), .init(voice: appDefault, fallback: true))
        XCTAssertEqual(resolve("Also gone", agent: "Gone"), .init(voice: appDefault, fallback: true))
    }

    func testSharedNamePrefersQualityThenLanguage() {
        XCTAssertEqual(resolve("ava").voice.quality, 3)
        XCTAssertEqual(resolve("Eddy", language: "fr").voice.language, "fr-FR")
        XCTAssertEqual(resolve("Eddy").voice.language, "en-US", "first installed wins a tie")
    }

    func testTierSuffixInName() {
        let voices = [
            SpeechVoice(identifier: "compact.Karen", name: "Karen", language: "en-AU", quality: 1),
            SpeechVoice(identifier: "premium.Karen", name: "Karen (Premium)", language: "en-AU", quality: 3),
        ]
        func match(_ name: String) -> String? { VoiceResolver.match(name, in: voices)?.identifier }
        XCTAssertEqual(match("Karen"), "premium.Karen")
        XCTAssertEqual(match("karen (premium)"), "premium.Karen")
        XCTAssertEqual(match("compact.Karen"), "compact.Karen")
        XCTAssertNil(match("Kar"))
        XCTAssertEqual(VoiceResolver.baseName("Bad News"), "Bad News")
    }
}

final class SpeechQueueTests: XCTestCase {
    let voice = SpeechVoice(identifier: "v", name: "V", language: "en-US")

    func testFifoCapacityAndDrain() throws {
        var queue = SpeechQueue(capacity: 2)
        guard case .started(let first) = queue.enqueue(agent: "dev", text: "a", voice: voice) else {
            return XCTFail("the first utterance starts at once")
        }
        XCTAssertEqual(queue.enqueue(agent: "x", text: "b", voice: voice), .queued(backlog: 1))
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "c", voice: voice), .queued(backlog: 2))
        XCTAssertEqual(queue.enqueue(agent: "dev", text: "d", voice: voice), .full)

        XCTAssertNil(queue.finish(seq: 999), "a stale seq is ignored")
        XCTAssertEqual(queue.finish(seq: first.seq)?.next?.text, "b")
        XCTAssertNil(queue.finish(seq: first.seq), "a second finish for the same utterance is ignored")
        XCTAssertEqual(queue.backlog, 1)
        let second = try XCTUnwrap(queue.current)
        XCTAssertEqual(queue.finish(seq: second.seq)?.next?.text, "c")
        let third = try XCTUnwrap(queue.current)
        XCTAssertEqual(queue.finish(seq: third.seq), SpeechQueue.Advance(next: nil))
        XCTAssertNil(queue.current)
        guard case .started = queue.enqueue(agent: "dev", text: "e", voice: voice) else {
            return XCTFail("an idle queue starts the next utterance at once")
        }
    }
}
