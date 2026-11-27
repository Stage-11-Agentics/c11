import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCOutputLeaseTests: XCTestCase {
    @MainActor
    func testPreparedNativeBridgeBindsRepliesBeforeOutputAndRejectsStalePaint() async {
        let state = HCLeaseTestState()
        let rendering = HCBridgeTestRendering(state: state)
        let bridge = HCNativeBridge(panelID: UUID(), rendering: rendering,
            encoder: HCUnavailableInputEncoder(), report: { _ in XCTFail("reply reached an unbound port") })
        let input = HCBridgeTestInput(state: state, generation: 17)
        let context = bridge.context
        bridge.installProcessor(process: { _ in
            state.append("parse")
            "\u{1b}[0n".withCString { context.receive($0, count: 4) }
        }, removeFromUse: { state.append("remove") }, destroy: { state.append("free") })
        XCTAssertFalse(bridge.bind(generation: 17, input: input))
        XCTAssertTrue(bridge.prepare(generation: 17))
        XCTAssertFalse(bridge.bind(generation: 16, input: input))
        XCTAssertTrue(bridge.bind(generation: 17, input: input))
        XCTAssertFalse(bridge.bind(generation: 17, input: input))
        guard case .stale = await bridge.consume(HCOutputChunk(attachmentGeneration: 16,
            watermark: 1, bytes: Data("old".utf8))) else { return XCTFail("stale paint admitted") }
        XCTAssertEqual(state.values, [])
        guard case .consumed = await bridge.consume(HCOutputChunk(attachmentGeneration: 17,
            watermark: 2, bytes: Data("query".utf8))) else { return XCTFail("paint not consumed") }
        XCTAssertEqual(state.values, ["output", "parse", "raw", "reply", "parsed"])
        let retired = expectation(description: "bridge retired")
        bridge.retire { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
        XCTAssertEqual(state.values, ["output", "parse", "raw", "reply", "parsed", "remove", "free"])
    }

    func testRetirementDoesNotBlockMainCallbackAndDestroysAfterOutput() async {
        let entered = expectation(description: "output entered native call")
        let heartbeat = expectation(description: "main consumed native event")
        let destroyed = expectation(description: "surface destroyed")
        let retired = expectation(description: "retirement completed")
        let releaseOutput = DispatchSemaphore(value: 0)
        let state = HCLeaseTestState()
        let lease = HCOutputLease(generation: 7, process: { _ in
            entered.fulfill()
            // Model Ghostty waiting for a main-consumed mailbox event. A
            // bounded wait makes the unsafe-retirement mutation fail, not hang.
            XCTAssertEqual(releaseOutput.wait(timeout: .now() + 2), .success)
            state.append("output")
        }, destroy: {
            XCTAssertEqual(state.values, ["output"])
            state.append("free")
            destroyed.fulfill()
        })
        let output = Task { await lease.consume(HCOutputChunk(attachmentGeneration: 7,
            watermark: 1, bytes: Data("event".utf8))) }
        await fulfillment(of: [entered], timeout: 2)
        await MainActor.run {
            lease.retire { retired.fulfill() }
            DispatchQueue.main.async {
                heartbeat.fulfill()
                releaseOutput.signal()
            }
        }
        await fulfillment(of: [heartbeat, destroyed, retired], timeout: 3)
        guard case .consumed = await output.value else { return XCTFail("started output must finish") }
        XCTAssertEqual(state.values, ["output", "free"])
    }

    func testStaleAndRetiredOutputNeverCallsNativeAndFreeOccursOnce() async {
        let freed = expectation(description: "free once")
        let retired = expectation(description: "both retire callbacks")
        retired.expectedFulfillmentCount = 2
        let lease = HCOutputLease(generation: 4, process: { _ in XCTFail("stale output reached native") },
                                  destroy: { freed.fulfill() })
        guard case .stale = await lease.consume(HCOutputChunk(attachmentGeneration: 3,
            watermark: 1, bytes: Data([1]))) else { return XCTFail("old generation") }
        lease.retire { retired.fulfill() }
        lease.retire { retired.fulfill() }
        guard case .stale = await lease.consume(HCOutputChunk(attachmentGeneration: 4,
            watermark: 2, bytes: Data([2]))) else { return XCTFail("retired generation") }
        await fulfillment(of: [freed, retired], timeout: 2)
    }

    func testOutputIsChunkedAndOversizeIsRefusedBeforeNativeEntry() async {
        let sizes = HCLeaseTestSizes()
        let retired = expectation(description: "retired")
        let lease = HCOutputLease(generation: 1, process: { sizes.append($0.bytes.count) }, destroy: {})
        guard case .consumed = await lease.consume(HCOutputChunk(attachmentGeneration: 1,
            watermark: 1, bytes: Data(repeating: 1, count: 150_000))) else { return XCTFail("valid output") }
        XCTAssertEqual(sizes.values, [65_536, 65_536, 18_928])
        guard case .failed(.bufferOverflow) = await lease.consume(HCOutputChunk(attachmentGeneration: 1,
            watermark: 2, bytes: Data(repeating: 2, count: HCLimits.initialCreditBytes + 1))) else {
            return XCTFail("oversize output admitted")
        }
        XCTAssertEqual(sizes.values.count, 3)
        lease.retire { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
    }
}

/// C11H-434: when hc ends a terminal it closes the stream, and the bridge used
/// to free the surface; the panel then made a blank one. A surface its owner
/// keeps stays on screen with its last frame until the owner releases it.
final class HCNativeBridgeKeptSurfaceTests: XCTestCase {
    @MainActor
    private func preparedBridge(_ state: HCLeaseTestState, keeps: @escaping @MainActor @Sendable () -> Bool) -> HCNativeBridge {
        let bridge = HCNativeBridge(panelID: UUID(), rendering: HCBridgeTestRendering(state: state),
                                    encoder: HCUnavailableInputEncoder(), report: { _ in })
        bridge.installProcessor(process: { _ in }, removeFromUse: { state.append("remove") },
                                keepsSurface: keeps, destroy: { state.append("free") })
        XCTAssertTrue(bridge.prepare(generation: 1))
        return bridge
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    @MainActor
    func testAnEndedStreamKeepsTheSurfaceUntilTheOwnerReleasesIt() async {
        let state = HCLeaseTestState()
        let bridge = preparedBridge(state, keeps: { true })
        let retired = expectation(description: "the stream retired the bridge")
        bridge.retire { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
        await settle()
        XCTAssertEqual(state.values, [], "the last screen stays: the surface is neither removed nor freed")
        guard case .stale = await bridge.consume(HCOutputChunk(attachmentGeneration: 1, watermark: 1,
            bytes: Data("late".utf8))) else { return XCTFail("a kept surface took output") }
        bridge.retire {}
        await settle()
        XCTAssertEqual(state.values, [], "another stream retire frees nothing")
        let released = expectation(description: "the owner released it")
        bridge.release { released.fulfill() }
        await fulfillment(of: [released], timeout: 2)
        await settle()
        XCTAssertEqual(state.values, ["remove", "free"], "out of use first, then freed")
        bridge.release {}
        await settle()
        XCTAssertEqual(state.values, ["remove", "free"], "freed exactly once")
    }

    @MainActor
    func testWithoutTheOwnersWordAnEndedStreamFreesTheSurface() async {
        let state = HCLeaseTestState()
        let bridge = preparedBridge(state, keeps: { false })
        let retired = expectation(description: "the stream retired the bridge")
        bridge.retire { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
        await settle()
        XCTAssertEqual(state.values, ["remove", "free"])
    }

    @MainActor
    func testAReleaseBeforeTheKeepDecisionFreesTheSurface() async {
        let state = HCLeaseTestState()
        let bridge = preparedBridge(state, keeps: { true })
        // Both on main before the stream retire's main hop decides to keep.
        bridge.retire {}
        let released = expectation(description: "the owner released it")
        bridge.release { released.fulfill() }
        await fulfillment(of: [released], timeout: 2)
        await settle()
        XCTAssertEqual(state.values, ["remove", "free"], "the owner's release wins; nothing is kept")
    }

    @MainActor
    func testTheOwnersOwnRetireNeverKeepsTheSurface() async {
        let state = HCLeaseTestState()
        let bridge = preparedBridge(state, keeps: { true })
        let released = expectation(description: "the owner released it")
        bridge.release { released.fulfill() }
        await fulfillment(of: [released], timeout: 2)
        await settle()
        XCTAssertEqual(state.values, ["remove", "free"], "teardown and replacement free the surface")
    }
}

private final class HCLeaseTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
}
private final class HCLeaseTestSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return sizes }
    func append(_ size: Int) { lock.lock(); sizes.append(size); lock.unlock() }
}

private final class HCBridgeTestInput: HCInputPort, @unchecked Sendable {
    let state: HCLeaseTestState
    let generation: UInt64
    init(state: HCLeaseTestState, generation: UInt64) { self.state = state; self.generation = generation }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {
        XCTAssertEqual(generation, self.generation)
        XCTAssertEqual(bytes, Data("\u{1b}[0n".utf8))
        state.append("reply")
    }
    func invalidate(generation: UInt64, reason: HCInputRefusal) {}
}
private struct HCBridgeTestRendering: HCRenderingAdapter {
    let state: HCLeaseTestState
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) { state.append("raw") }
    func noteOutput(_ chunk: HCOutputChunk) { state.append("output") }
    func didParse(_ chunk: HCOutputChunk) { state.append("parsed") }
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
}
