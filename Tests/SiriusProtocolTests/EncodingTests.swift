import Foundation
import XCTest
@testable import SiriusProtocol

final class EncodingTests: XCTestCase {
    func testHelperRequestValidates() throws {
        let request = Request(id: .string("1"), method: .display,
                              params: DisplayParams(kind: .toast, content: [.text(TextContent(text: "hi"))], alert: true))
        let frame = try encodeFrame(request)
        XCTAssertEqual(frame.last, 0x0A)
        XCTAssertEqual(validate(frame: frame.dropLast()),
                       .request(.string("1"), .display(DisplayParams(kind: .toast, content: [.text(TextContent(text: "hi"))], alert: true))))
    }

    func testStringContentNormalizesToOneTextBlock() {
        let frame = Data(#"{"jsonrpc":"2.0","sirius":1,"id":2,"method":"notify","params":{"content":"done"}}"#.utf8)
        XCTAssertEqual(validate(frame: frame),
                       .request(.number(2), .notify(NotifyParams(content: [.text(TextContent(text: "done"))]))))
    }

    func testResultRoundTrip() throws {
        let frame = try encodeFrame(Response(id: .string("1"), .result(.queued(voice: "Samantha", fallback: true))))
        XCTAssertEqual(String(decoding: frame, as: UTF8.self),
                       #"{"id":"1","jsonrpc":"2.0","result":{"fallback":true,"queued":true,"voice":"Samantha"},"sirius":1}"# + "\n")
        let reply = try Reply.parse(frame)
        XCTAssertEqual(reply.id, .string("1"))
        XCTAssertEqual(reply.outcome, .result(.object(["fallback": .bool(true), "queued": .bool(true), "voice": .string("Samantha")])))
    }

    func testErrorRoundTripKeepsCodeAndData() throws {
        let error = RPCError(.tooLarge, "maxToastChars is 280; got 300",
                             data: ErrorData(method: .display, limit: .maxToastChars, value: 300))
        let frame = try encodeFrame(Response(id: nil, .error(error)))
        XCTAssertTrue(String(decoding: frame, as: UTF8.self).contains(#""id":null"#))
        XCTAssertEqual(try Reply.parse(frame), Reply(id: nil, outcome: .error(error)))
    }

    func testBlockEncodesWithItsTypeTag() throws {
        let data = try JSONEncoder().encode(ContentBlock.text(TextContent(text: "hi")))
        XCTAssertEqual(try JSONValue.parse(data), .object(["type": .string("text"), "text": .string("hi")]))
    }

    func testCodePointsNotGraphemes() {
        XCTAssertEqual("👍🏽".codePoints, 2)
    }

    func testRegistrationIds() {
        XCTAssertTrue(AgentRegistration.isValidId("claude-2"))
        XCTAssertFalse(AgentRegistration.isValidId("Claude"))
        XCTAssertFalse(AgentRegistration.isValidId(""))
        XCTAssertFalse(AgentRegistration.isValidId(String(repeating: "a", count: 33)))
    }

    func testRegistrationDecodesHarness() throws {
        let json = #"{"agent":"claude","name":"Claude","harness":"claude-code","executable":"/usr/local/bin/claude","root":"/Users/a/work"}"#
        let registration = try JSONDecoder().decode(AgentRegistration.self, from: Data(json.utf8))
        XCTAssertEqual(registration.harness, .claudeCode)
        XCTAssertNil(registration.voice)
    }
}

final class ReplyLeniencyTests: XCTestCase {
    func testUnknownCodeAndDataStillReadAsARejection() throws {
        let frame = #"{"jsonrpc":"2.0","sirius":1,"id":"1","error":{"code":-31999,"message":"new","data":{"limit":"maxFuture","value":1.5,"method":"display"}}}"#
        let reply = try Reply.parse(Data(frame.utf8))
        guard case .error(let error) = reply.outcome else { return XCTFail("expected an error") }
        XCTAssertEqual(error.code.rawValue, -31999)
        XCTAssertEqual(error.data?.method, .display)
        XCTAssertNil(error.data?.limit)
        XCTAssertNil(error.data?.value)
    }

    // The envelope is strict: anything Reply.parse accepts reads
    // as a definite answer.
    func testEnvelopeIsStrict() {
        let malformed = [
            #"{"result":false}"#,
            #"[]"#,
            #"{"sirius":1,"id":"1","result":{}}"#,
            #"{"jsonrpc":"1.0","sirius":1,"id":"1","result":{}}"#,
            #"{"jsonrpc":"2.0","id":"1","result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":2,"id":"1","result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1.5,"id":"1","result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":"1","id":"1","result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"error":{"code":-32700,"message":"x"}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":true,"result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":1.5,"result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":9007199254740992,"result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":{},"error":{"code":-32700,"message":"x"}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":null,"result":{}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":"1"}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":"1","result":{},"error":{"code":-32603,"message":"x"}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":"1","error":null}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":"1","error":{"message":"x"}}"#,
            #"{"jsonrpc":"2.0","sirius":1,"id":"1","error":{"code":-32603}}"#,
        ]
        for frame in malformed {
            XCTAssertThrowsError(try Reply.parse(Data(frame.utf8)), frame)
        }
    }

    func testEnvelopeAccepts() throws {
        XCTAssertEqual(try Reply.parse(Data(#"{"jsonrpc":"2.0","sirius":1,"id":7,"result":{"delivered":true}}"#.utf8)),
                       Reply(id: .number(7), outcome: .result(.object(["delivered": .bool(true)]))))
        XCTAssertEqual(try Reply.parse(Data(#"{"jsonrpc":"2.0","sirius":1,"id":null,"error":{"code":-32700,"message":"x"}}"#.utf8)),
                       Reply(id: nil, outcome: .error(RPCError(.parseError, "x"))))
        XCTAssertEqual(try Reply.parse(Data(#"{"jsonrpc":"2.0","sirius":1.0,"id":"a","result":{},"future":1}"#.utf8)).id,
                       .string("a"))
    }
}
