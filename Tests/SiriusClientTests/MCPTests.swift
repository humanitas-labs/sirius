import Foundation
import SiriusProtocol
import XCTest

// Runs the built `sirius-mcp` binary over stdio against a fake server, as a
// host would: lines in, lines out, and the frame the app would receive.
final class MCPTests: XCTestCase {
    struct Run {
        var status: Int32
        // Every stdout line, parsed; a line that is not JSON fails the test.
        var messages: [JSONValue]
        var stderr: String

        func response(_ id: Int) -> JSONValue? {
            messages.first { $0["id"]?.safeInteger == Int64(id) }
        }
    }

    private var binary: URL {
        get throws {
            let url = Bundle(for: MCPTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sirius-mcp")
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw XCTSkip("sirius-mcp binary not built at \(url.path)")
            }
            return url
        }
    }

    private func run(_ lines: [String], socket: String? = nil, timeout: String? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        let process = Process()
        process.executableURL = try binary
        var environment = ProcessInfo.processInfo.environment
        environment["SIRIUS_SOCKET"] = socket
        environment["SIRIUS_TIMEOUT"] = timeout
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var messages: [JSONValue] = []
        for raw in out.split(separator: 0x0A) {
            guard let message = try? JSONValue.parse(Data(raw)), message.object != nil else {
                XCTFail("stdout line is not a JSON object: \(String(decoding: raw, as: UTF8.self))", file: file, line: line)
                continue
            }
            XCTAssertEqual(message["jsonrpc"], .string("2.0"), file: file, line: line)
            messages.append(message)
        }
        return Run(status: process.terminationStatus, messages: messages,
                   stderr: String(decoding: err, as: UTF8.self))
    }

    private static let initialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    private static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

    private func call(_ id: Int, _ tool: String, _ arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
    }

    private func text(_ result: JSONValue?) -> String {
        result?["content"]?.array?.first?["text"]?.string ?? ""
    }

    // MARK: - Lifecycle

    func testInitializeAndNotifications() throws {
        let run = try run([
            Self.initialize, Self.initialized,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ])
        XCTAssertEqual(run.status, 0)
        // Notifications get nothing back: one response per request.
        XCTAssertEqual(run.messages.count, 2)
        let result = try XCTUnwrap(run.response(1)?["result"])
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(result["serverInfo"]?["name"], .string("sirius"))
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertEqual(run.response(2)?["result"], .object([:]))
    }

    func testUnknownProtocolVersionGetsTheNewest() throws {
        let run = try run([#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#])
        let response = try XCTUnwrap(run.messages.first)
        XCTAssertEqual(response["id"], .string("a"))
        XCTAssertEqual(response["result"]?["protocolVersion"], .string("2026-07-28"))
    }

    func testJSONRPCErrors() throws {
        let run = try run([
            "not json",
            "[1,2]",
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"shout","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#,
            #"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#,
        ])
        XCTAssertEqual(run.messages.count, 6)
        XCTAssertEqual(run.messages[0]["error"]?["code"], .number(-32700))
        XCTAssertEqual(run.messages[0]["id"], .null)
        XCTAssertEqual(run.messages[1]["error"]?["code"], .number(-32600))
        XCTAssertEqual(run.response(3)?["error"]?["code"], .number(-32601))
        XCTAssertEqual(run.response(4)?["error"]?["code"], .number(-32602))
        XCTAssertEqual(run.response(5)?["error"]?["code"], .number(-32602))
        XCTAssertEqual(run.messages[5]["error"]?["code"], .number(-32600))
        XCTAssertEqual(run.messages[5]["id"], .null)
    }

    // MARK: - tools/list

    func testToolsListCarriesTheGeneratedSchemas() throws {
        let run = try run([Self.initialize, Self.initialized, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
        let tools = try XCTUnwrap(run.response(2)?["result"]?["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["display", "notify", "speak"])

        // The embedded schemas match the committed schema.json, so
        // scripts/gen-schema.sh was rerun after any change to it.
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/protocol/schema.json")
        let schema = try JSONValue.parse(Data(contentsOf: schemaURL))
        let expected = ["display": "DisplayParams", "notify": "NotifyParams", "speak": "SpeakParams"]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"]?.string)
            XCTAssertEqual(tool["inputSchema"], schema["definitions"]?[expected[name]!], name)
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"), name)
            XCTAssertFalse(tool["description"]?.string?.isEmpty ?? true, name)
        }

        // The string-or-blocks union sits under properties.content.
        let display = try XCTUnwrap(tools.first)
        let union = try XCTUnwrap(display["inputSchema"]?["properties"]?["content"]?["anyOf"]?.array)
        XCTAssertEqual(union.first, .object(["type": .string("string")]))
        XCTAssertEqual(union.last?["type"], .string("array"))
        XCTAssertEqual(union.last?["items"]?["anyOf"]?.array?.count, 5)
        XCTAssertEqual(display["inputSchema"]?["required"], .array([.string("kind"), .string("content")]))
    }

    // MARK: - tools/call

    func testCallPassesArgumentsThroughAndReturnsTheReceipt() throws {
        let server = try FakeServer(.reply { respond($0, result: #"{"delivered":true}"#) })
        let arguments = #"{"kind":"toast","content":[{"type":"text","text":"{\"looks\":\"like json\"}"}],"alert":true,"extra":1}"#
        let run = try run([Self.initialize, Self.initialized, call(2, "display", arguments)], socket: server.path)
        server.stop()

        let result = try XCTUnwrap(run.response(2)?["result"])
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(text(result), #"{"delivered":true}"#)

        XCTAssertEqual(server.connections.count, 1)
        let frame = try XCTUnwrap(server.frames.first)
        XCTAssertEqual(frame["method"], .string("display"))
        XCTAssertEqual(frame["sirius"], .number(1))
        XCTAssertEqual(frame["params"], try JSONValue.parse(Data(arguments.utf8)))
    }

    func testSpeakAndNotifyUseTheirMethods() throws {
        let server = try FakeServer(.reply { request in
            request["method"] == .string("speak")
                ? respond(request, result: #"{"queued":true,"voice":"Samantha","fallback":true}"#)
                : respond(request, result: #"{"delivered":true}"#)
        })
        let run = try run([
            call(2, "speak", #"{"text":"hello","voice":"Nobody"}"#),
            call(3, "notify", #"{"content":"done","title":"Build"}"#),
        ], socket: server.path)
        server.stop()
        XCTAssertEqual(server.frames.compactMap { $0["method"]?.string }, ["speak", "notify"])
        XCTAssertEqual(text(run.response(2)?["result"]), #"{"fallback":true,"queued":true,"voice":"Samantha"}"#)
        XCTAssertEqual(run.response(3)?["result"]?["isError"], .bool(false))
    }

    func testErrorResponseIsAToolErrorWithCodeAndData() throws {
        let server = try FakeServer(.reply { request in
            #"{"jsonrpc":"2.0","sirius":1,"id":\#(idJSON(request)),"error":{"code":-32004,"message":"toast accepts text only","data":{"method":"display","kind":"toast","type":"image"}}}"#
        })
        let run = try run([call(2, "display", #"{"kind":"toast","content":[{"type":"image","data":"AA==","mimeType":"image/png"}]}"#)],
                          socket: server.path)
        server.stop()
        let result = try XCTUnwrap(run.response(2)?["result"])
        XCTAssertEqual(result["isError"], .bool(true))
        let message = text(result)
        XCTAssertTrue(message.hasPrefix("Sirius rejected this request; it was not accepted. toast accepts text only\n"), message)
        let detail = try JSONValue.parse(Data(message.split(separator: "\n").last!.utf8))
        XCTAssertEqual(detail["error"]?["code"], .number(-32004))
        XCTAssertEqual(detail["error"]?["data"]?["type"], .string("image"))
        XCTAssertEqual(detail["error"]?["data"]?["kind"], .string("toast"))
    }

    func testMissingArgumentsGoAsAnEmptyObject() throws {
        let server = try FakeServer(.reply { respond($0, code: -32602, message: "content is required") })
        let run = try run([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notify"}}"#], socket: server.path)
        server.stop()
        XCTAssertEqual(server.frames.first?["params"], .object([:]))
        XCTAssertEqual(run.response(2)?["result"]?["isError"], .bool(true))
    }

    func testUnknownOutcomeSaysSoAndIsNotRetried() throws {
        let server = try FakeServer(.silent)
        let run = try run([call(2, "display", #"{"kind":"toast","content":"hi"}"#)], socket: server.path, timeout: "0.3")
        server.stop()
        XCTAssertEqual(server.connections.count, 1)
        XCTAssertEqual(server.frames.count, 1)
        let result = try XCTUnwrap(run.response(2)?["result"])
        XCTAssertEqual(result["isError"], .bool(true))
        let message = text(result)
        XCTAssertTrue(message.contains("The outcome is unknown"), message)
        XCTAssertTrue(message.contains("may have accepted"), message)
        XCTAssertTrue(message.contains("Do not retry"), message)
        XCTAssertFalse(message.contains("rejected"), message)
    }

    func testDroppedConnectionIsUnknown() throws {
        let server = try FakeServer(.closeAfterRead)
        let run = try run([call(2, "speak", #"{"text":"hi"}"#)], socket: server.path)
        server.stop()
        XCTAssertTrue(text(run.response(2)?["result"]).contains("The outcome is unknown"))
    }

    func testNotRunning() throws {
        let stale = try FakeServer.staleSocket()
        defer { unlink(stale.path); rmdir(stale.directory) }
        let run = try run([
            call(2, "display", #"{"kind":"toast","content":"hi"}"#),
        ], socket: stale.path)
        let result = try XCTUnwrap(run.response(2)?["result"])
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(text(result), "Sirius isn't running; nothing was sent.")

        let unset = try self.run([call(3, "notify", #"{"content":"hi"}"#)])
        let unsetText = text(unset.response(3)?["result"])
        XCTAssertTrue(unsetText.hasPrefix("Sirius isn't running (SIRIUS_SOCKET is not set"), unsetText)
        XCTAssertTrue(unsetText.hasSuffix("nothing was sent."), unsetText)
    }
}
