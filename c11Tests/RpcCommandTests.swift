import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class RpcCommandTests: XCTestCase {
    func testMethodWithoutPayloadHasEmptyParams() throws {
        let call = try RpcCommand.parse(["system.ping"])
        XCTAssertEqual(call.method, "system.ping")
        XCTAssertTrue(call.params.isEmpty)
    }

    func testJSONKeepsLiteralTextAndNestedValues() throws {
        let call = try RpcCommand.parse(["fixture.method", #"{"text":"hello\\n世界","nested":{"flag":true},"items":[1,null]}"#])
        XCTAssertEqual(call.method, "fixture.method")
        XCTAssertEqual(call.params["text"] as? String, #"hello\n世界"#)
        XCTAssertEqual((call.params["nested"] as? [String: Any])?["flag"] as? Bool, true)
        XCTAssertEqual((call.params["items"] as? [Any])?.count, 2)
    }

    func testMalformedAndNonObjectPayloadsAreRejected() {
        for payload in ["[]", "null", "1", "true", #""hello""#, "{broken"] {
            XCTAssertThrowsError(try RpcCommand.parse(["system.ping", payload])) { error in
                XCTAssertTrue(String(describing: error).contains("JSON object"))
            }
        }
    }

    func testMissingInvalidMethodAndExtraPositionalsAreRejected() {
        for args in [[], [""], [" "], ["system.\nping"], ["system.ping", "{}", "extra"]] {
            XCTAssertThrowsError(try RpcCommand.parse(args))
        }
    }

    func testJSONFlagDoesNotChangeCall() throws {
        for args in [["system.ping", "--json"], ["--json", "system.ping", "{}"]] {
            let call = try RpcCommand.parse(args)
            XCTAssertEqual(call.method, "system.ping")
            XCTAssertTrue(call.params.isEmpty)
        }
    }
}
