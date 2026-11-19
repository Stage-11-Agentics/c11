import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCContractTests: XCTestCase {
    func testUnavailableRuntimeNeverAuthorizesRestoredCreationOrDelivery() async throws {
        let runtime = HCUnavailableRuntime()
        let identity = HCPanelIdentity(panelID: UUID(), origin: .restored)
        guard case .unresolved(let saved, .backendNotInstalled) = await runtime.resolve(identity) else {
            return XCTFail("Unavailable state must preserve a restored identity")
        }
        XCTAssertEqual(saved, identity)
        let request = HCCreateRequest(identity: identity, creationID: UUID(), argv: ["/bin/zsh"])
        guard case .rejectedBeforeTransmission(.backendNotInstalled) = await runtime.create(request) else {
            return XCTFail("The interface default must never launch a terminal")
        }
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let input = HCInputRequest(operationID: UUID(), panelID: identity.panelID, key: key,
                                   attachmentGeneration: 1, source: .mailbox, payload: Data("doorbell".utf8), submitReturn: true)
        guard case .refused(.unavailable) = await runtime.submit(input) else {
            return XCTFail("Unavailable input must report zero transmission")
        }
        let receipt = await runtime.screenCurrent(after: HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1))
        XCTAssertNil(receipt)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.readiness, .pending(.backendNotInstalled))
        guard case .unresolved(let unchanged, .backendNotInstalled) = await runtime.end(key) else {
            return XCTFail("Unavailable end cannot manufacture death evidence")
        }
        XCTAssertEqual(unchanged, key)
    }

    func testObservationCancellationIsSingleUseAndReentrant() {
        let probe = HCCancellationProbe()
        let observation = HCObservation { probe.cancelAgain() }
        probe.observation = observation
        observation.cancel()
        observation.cancel()
        XCTAssertEqual(probe.calls, 1)
    }

    func testWireJSONKeepsLargeSequenceAndBooleanDistinct() throws {
        let bytes = Data(#"{"seq":9007199254740993,"ready":true,"nothing":null,"labels":{"c11.panel":"p"}}"#.utf8)
        let decoded = try JSONDecoder().decode(HCJSONValue.self, from: bytes)
        guard case .object(let object) = decoded else { return XCTFail("Expected RPC object") }
        XCTAssertEqual(object["seq"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(object["ready"], .bool(true))
        XCTAssertEqual(try JSONDecoder().decode(HCJSONValue.self, from: JSONEncoder().encode(decoded)), decoded)
    }
}

// The test invokes cancellation synchronously on one thread; the probe keeps
// the callback capture Sendable without capturing mutable local variables.
private final class HCCancellationProbe: @unchecked Sendable {
    weak var observation: HCObservation?
    var calls = 0
    func cancelAgain() { calls += 1; observation?.cancel() }
}
