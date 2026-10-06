import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SelectionReadTests: XCTestCase {
    func testWorkerPolicyAndLegacyMethod() {
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "panel.read_selection"), .socketWorker)
        XCTAssertEqual(LegacyWireAliases.canonicalMethod("surface.read_selection"), "panel.read_selection")
        XCTAssertEqual(LegacyWireAliases.canonicalMethod("tab.read_selection"), "panel.read_selection")
    }

    func testWithinAndExactlyAtLimitKeepBytes() {
        for bytes in [Data(), Data("界🙂selection\n".utf8), Data(repeating: 65, count: SelectionRead.byteLimit)] {
            let result = SelectionRead.utf8Prefix(bytes, originalCount: bytes.count)
            XCTAssertEqual(result.data, bytes)
            XCTAssertFalse(result.truncated)
        }
    }

    func testOverLimitDropsOnlyIncompleteUnicodeScalar() {
        for scalar in ["é", "界", "🙂"] {
            for split in 1..<scalar.utf8.count {
                let prefix = Data(repeating: 65, count: SelectionRead.byteLimit - split)
                var original = prefix
                original.append(Data((scalar + "tail").utf8))
                let mainCopy = Data(original.prefix(SelectionRead.byteLimit))
                let result = SelectionRead.utf8Prefix(mainCopy, originalCount: original.count)
                XCTAssertEqual(result.data, prefix)
                XCTAssertTrue(result.truncated)
                XCTAssertNotNil(String(data: result.data, encoding: .utf8))
                XCTAssertEqual(Data(base64Encoded: result.data.base64EncodedString()), result.data)
            }
        }
    }

    func testCompleteScalarAtLimitIsKeptWhenTruncated() {
        var bytes = Data(repeating: 65, count: SelectionRead.byteLimit - 4)
        bytes.append(Data("🙂".utf8))
        let result = SelectionRead.utf8Prefix(bytes, originalCount: bytes.count + 1)
        XCTAssertEqual(result.data, bytes)
        XCTAssertTrue(result.truncated)
    }

    func testCompletionIsOneShot() {
        let operation = SelectionReadOperation<String>(timeout: 1)
        XCTAssertTrue(operation.beginCapture())
        XCTAssertFalse(operation.beginCapture())
        XCTAssertTrue(operation.complete("first"))
        XCTAssertFalse(operation.complete("second"))
        XCTAssertEqual(operation.wait(), "first")
    }

    func testDefaultDeadlineBoundsWaitAndAbandonsLateCapture() {
        let operation = SelectionReadOperation<String>()
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertNil(operation.wait())
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertGreaterThanOrEqual(elapsed, 4.9)
        XCTAssertLessThan(elapsed, 6)
        XCTAssertFalse(operation.beginCapture())
        XCTAssertFalse(operation.complete("late"))
        XCTAssertFalse(operation.canPublish)
    }

    func testCallerCanLeaveWhileCaptureOwnsCleanup() {
        let operation = SelectionReadOperation<String>(timeout: 0.03)
        let cleanup = expectation(description: "capture finished its cleanup")
        let gate = DispatchSemaphore(value: 0)
        let began = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard operation.beginCapture() else { return }
            began.signal()
            gate.wait()
            defer { cleanup.fulfill() }
            XCTAssertFalse(operation.complete("abandoned native result"))
        }
        XCTAssertEqual(began.wait(timeout: .now() + 1), .success)
        XCTAssertNil(operation.wait())
        gate.signal()
        wait(for: [cleanup], timeout: 1)
    }

    func testEncodingConsumesSameDeadline() {
        let operation = SelectionReadOperation<String>(timeout: 0.03)
        XCTAssertTrue(operation.beginCapture())
        XCTAssertTrue(operation.complete("captured"))
        XCTAssertEqual(operation.wait(), "captured")
        let passedDeadline = DispatchSemaphore(value: 0)
        _ = passedDeadline.wait(timeout: operation.deadline + 0.01)
        XCTAssertFalse(operation.canPublish)
    }
}
