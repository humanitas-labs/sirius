import Foundation
import XCTest
@testable import SiriusProtocol

// Every fixture in docs/protocol/examples/ is checked against its full
// expected output, so a wrong id, a lost field or the wrong error data fails
// as surely as the wrong code. The fixtures are the contract's examples for
// any implementation. A fixture gives the request as "frame" (JSON) or "raw"
// (exact bytes, for lexical edges that decoding the fixture would erase), and
// "expect" as one of:
//   {"result": method, "id": id, "params": normalized params}
//   {"error": code, "id": id or null, "data": error data (absent: none)}
//   {"noResponse": true}
final class FixtureTests: XCTestCase {
    static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/protocol/examples")

    func testFixtures() throws {
        var count = 0
        for group in ["valid", "invalid"] {
            let folder = Self.examples.appendingPathComponent(group)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
                count += 1
                try check(group: group, file: file)
            }
        }
        XCTAssertGreaterThan(count, 120)
    }

    private func check(group: String, file: URL) throws {
        let name = "\(group)/\(file.lastPathComponent)"
        let fixture = try JSONValue.parse(Data(contentsOf: file))
        let frame: Data
        if let raw = fixture["raw"]?.string {
            frame = Data(raw.utf8)
        } else {
            frame = try JSONEncoder().encode(XCTUnwrap(fixture["frame"], name))
        }
        let expect = try XCTUnwrap(fixture["expect"], name)
        let inbound = validate(frame: frame)

        if expect["noResponse"] == .bool(true) {
            XCTAssertEqual(inbound, .notification, name)
            return
        }
        let expectedId = try XCTUnwrap(expect["id"], "\(name): expect.id is required")
        if let method = expect["result"]?.string {
            XCTAssertEqual(group, "valid", "\(name): accepted requests live in valid/")
            guard case .request(let id, let call) = inbound else {
                return XCTFail("\(name): expected a \(method) request, got \(inbound)")
            }
            XCTAssertEqual(call.method.rawValue, method, name)
            XCTAssertEqual(try json(id), expectedId, "\(name): id")
            XCTAssertEqual(try params(call), try XCTUnwrap(expect["params"], "\(name): expect.params is required"),
                           "\(name): params")
        } else {
            let code = try XCTUnwrap(expect["error"]?.safeInteger, "\(name): expect needs result, error or noResponse")
            XCTAssertEqual(group, "invalid", "\(name): errors live in invalid/")
            guard case .failure(let id, let error) = inbound else {
                return XCTFail("\(name): expected error \(code), got \(inbound)")
            }
            XCTAssertEqual(Int64(error.code.rawValue), code, "\(name): \(error.message)")
            XCTAssertEqual(try json(id), expectedId, "\(name): id")
            XCTAssertEqual(try error.data.map(json), expect["data"], "\(name): data")
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(value))
    }

    private func params(_ call: Call) throws -> JSONValue {
        switch call {
        case .display(let params): try json(params)
        case .notify(let params): try json(params)
        case .speak(let params): try json(params)
        }
    }
}
