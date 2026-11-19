import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// `hc ls|get|server|run` inside a c11 terminal returned `method_not_found`:
/// `hc.call` had a handler (`v2HCCall`) but was in neither the socket worker
/// table nor the dispatcher. These tests send real requests through the
/// controller's worker dispatch and read what the CLI would receive.
final class HCCallRoutingTests: XCTestCase {
    /// The worker dispatch on a background thread, as a socket connection runs it.
    static func workerResponse(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let controller = TerminalController.shared
        let text: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: controller.socketWorkerV2Response(
                    TerminalController.V2SocketRequest(id: 7, method: method, params: params)))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func code(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }

    func testHCCallRunsOnTheSocketWorkerLikeHCDiagnostics() {
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "hc.diagnostics"), .socketWorker, "control")
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "hc.call"), .socketWorker)
        XCTAssertNotEqual(TerminalController.executionPolicy(forV2Method: "hc.not_a_method"), .socketWorker, "control")
    }

    func testHCCallIsAdvertisedByCapabilities() throws {
        let methods = try XCTUnwrap(TerminalController.shared.v2Capabilities()["methods"] as? [String])
        XCTAssertTrue(methods.contains("hc.diagnostics"), "control")
        XCTAssertTrue(methods.contains("hc.call"))
    }

    func testHCCallReachesItsHandlerInsteadOfMethodNotFound() async throws {
        let unknown = try await Self.workerResponse("hc.not_a_method", params: [:])
        XCTAssertEqual(code(unknown), "method_not_found", "control: an unregistered method still fails this way")

        let invalid = try await Self.workerResponse("hc.call", params: [:])
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        XCTAssertEqual(code(invalid), "hc_invalid_arguments", "the handler decoded (and refused) the empty command")
    }

    func testHCCallWithoutAComposedBackendRefusesWithoutStartingAnything() async throws {
        await HCManagedCommandEndpoint.shared.uninstall()
        let command = try HCManagedCommandParser.parse(["ls"], environment: ["HC_SESSION": "c11", "HC_SOCKET": "/tmp/x.sock"], cwd: "/")
        let params = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])

        let response = try await Self.workerResponse("hc.call", params: params)

        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertNotEqual(code(response), "method_not_found")
        XCTAssertEqual(code(response), "hc_backendNotInstalled")
    }
}
