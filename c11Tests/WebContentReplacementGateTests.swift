import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WebContentReplacementGateTests: XCTestCase {
    func testDuplicateTerminationBeforeNextTurnIsCoalesced() {
        var gate = WebContentReplacementGate()
        let instance = UUID()
        XCTAssertTrue(gate.enqueue(instanceID: instance))
        XCTAssertFalse(gate.enqueue(instanceID: instance))
        XCTAssertTrue(gate.beginTurn(currentInstanceID: instance))
        XCTAssertFalse(gate.beginTurn(currentInstanceID: instance))
    }

    func testStaleViewAndCloseInvalidateQueuedWork() {
        var gate = WebContentReplacementGate()
        XCTAssertTrue(gate.enqueue(instanceID: UUID()))
        XCTAssertFalse(gate.beginTurn(currentInstanceID: UUID()))
        let instance = UUID()
        XCTAssertTrue(gate.enqueue(instanceID: instance))
        gate.invalidate()
        XCTAssertFalse(gate.beginTurn(currentInstanceID: instance))
    }

    func testRepeatedURLRestoresThenShowsErrorThenStopsReplacing() {
        var gate = WebContentReplacementGate()
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(gate.outcome(url: url, now: 100), .restoreURL)
        XCTAssertEqual(gate.outcome(url: url, now: 101), .errorPage)
        XCTAssertEqual(gate.outcome(url: url, now: 102), .drop)
        XCTAssertEqual(gate.outcome(url: url, now: 109), .drop)
        XCTAssertEqual(gate.outcome(url: url, now: 110), .restoreURL)
    }

    func testDifferentURLGetsItsOwnRecoveryWindow() {
        var gate = WebContentReplacementGate()
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        XCTAssertEqual(gate.outcome(url: first, now: 100), .restoreURL)
        XCTAssertEqual(gate.outcome(url: first, now: 101), .errorPage)
        XCTAssertEqual(gate.outcome(url: second, now: 102), .restoreURL)
    }

    func testMissingAndExplicitBlankURLShareTheSameCap() {
        var gate = WebContentReplacementGate()
        XCTAssertEqual(gate.outcome(url: nil, now: 100), .restoreURL)
        XCTAssertEqual(gate.outcome(url: URL(string: "about:blank"), now: 101), .errorPage)
        XCTAssertEqual(gate.outcome(url: nil, now: 102), .drop)
    }
}
