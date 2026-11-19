import XCTest
import SwiftUI
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCInputAdmissionTests: XCTestCase {
    private let panel = UUID()
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")
    private let revision = HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 9)

    private func request(_ body: Data = Data("whole\nbody".utf8), guardScreen: HCInputGuard? = nil) -> HCInputRequest {
        HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 3,
            source: .socket, payload: body, submitReturn: true, screenGuard: guardScreen)
    }

    private func coordinator(_ writer: any HCFrameWriter, encoder: any HCInputEncoder = HCAdmissionEncoder(),
                             screen: (any HCScreenProvider)? = nil) -> HCInputCoordinator {
        let revision = revision
        return HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: encoder, screen: screen ?? HCAdmissionScreen(receipt: HCScreenReceipt(
                revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24)),
            displayRevision: { revision }, report: { _ in })
    }

    func testOversizedAndSaturatedTransactionsTransmitNothing() async {
        let writer = HCAdmissionWriter()
        let input = coordinator(writer)
        guard case .refused(.tooLarge) = await input.submit(request(Data(repeating: 1,
            count: HCLimits.transactionBytes + 1))) else { return XCTFail("oversize admitted") }
        writer.refuse = .queueFull
        guard case .refused(.queueFull) = await input.submit(request()) else { return XCTFail("saturation hidden") }
        XCTAssertEqual(writer.received, Data())
        XCTAssertEqual(writer.writeCount, 0)
    }

    func testCompleteBodyAndReturnHaveAnActualWriteReceipt() async {
        let writer = HCAdmissionWriter()
        let operation = request()
        guard case .written(let receipt) = await coordinator(writer).submit(operation) else { return XCTFail("write failed") }
        XCTAssertEqual(writer.received, operation.payload + Data([13]))
        XCTAssertEqual(receipt.bodyBytesWritten, operation.payload.count)
        XCTAssertTrue(receipt.returnWritten)
        XCTAssertEqual(receipt.operationID, operation.operationID)
    }

    func testGuardRefusesDraftAndMissingOrStaleReceipt() async {
        let writer = HCAdmissionWriter()
        guard case .refused(.guardRefused) = await coordinator(writer).submit(request(guardScreen: { _ in false }))
        else { return XCTFail("draft accepted") }
        for receipt in [nil, HCScreenReceipt(revision: HCDisplayRevision(attachmentGeneration: 2, displayGeneration: 9),
            parsedOutputWatermark: 1, columns: 80, rows: 24)] {
            let input = coordinator(writer, screen: HCAdmissionScreen(receipt: receipt))
            guard case .refused(.screenUnavailable) = await input.submit(request(guardScreen: { _ in
                XCTFail("guard received an invalid screen"); return true
            })) else { return XCTFail("missing or stale screen accepted") }
        }
        XCTAssertEqual(writer.writeCount, 0)
    }

    func testUncertainBodyLatchesFaultAndNeverReplaysOrSubmitsReturn() async {
        let writer = HCAdmissionWriter()
        writer.failAfter = 4
        let input = coordinator(writer)
        guard case .uncertain(let receipt) = await input.submit(request()) else { return XCTFail("must be uncertain") }
        XCTAssertEqual(receipt.bodyBytesWritten, 4)
        XCTAssertFalse(receipt.returnWritten)
        guard case .refused = await input.submit(request()) else { return XCTFail("fault not latched") }
        input.receiveRaw(Data("query".utf8), kind: .query, generation: 3)
        XCTAssertEqual(writer.received, Data("whol".utf8))
        XCTAssertEqual(writer.writeCount, 1)
    }

    func testInvalidationDuringEncodingCancelsReservationAndUnsentReturn() async {
        let entered = expectation(description: "encoding")
        let encoder = HCAdmissionHeldEncoder(entered: { entered.fulfill() })
        let writer = HCAdmissionWriter()
        let input = coordinator(writer, encoder: encoder)
        let operation = request()
        let task = Task { await input.submit(operation) }
        await fulfillment(of: [entered], timeout: 2)
        input.invalidate(generation: 3, reason: .inputFault)
        await encoder.release()
        guard case .refused = await task.value else { return XCTFail("stale body written") }
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertTrue(writer.cancelled.contains(operation.operationID))
    }

    func testEncodedExpansionCannotExceedTheReservation() async {
        let writer = HCAdmissionWriter()
        let input = coordinator(writer, encoder: HCAdmissionEncoder(expand: true))
        guard case .refused(.tooLarge) = await input.submit(request()) else { return XCTFail("encoded overflow accepted") }
        XCTAssertEqual(writer.writeCount, 0)
    }

    func testDisplayChangingInsideGuardRefusesBeforeAnyByte() async {
        let display = HCAdmissionDisplay(revision)
        let writer = HCAdmissionWriter()
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionScreen(receipt: HCScreenReceipt(
                revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24)),
            displayRevision: { display.current }, report: { _ in })
        let outcome = await input.submit(request(guardScreen: { _ in
            display.set(HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 10))
            return true
        }))
        guard case .refused(.screenUnavailable) = outcome else { return XCTFail("stale guard was admitted") }
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(writer.received, Data())
    }

    func testCancellationDuringWriteRevokesReturnAndPreservesPartialReceipt() async {
        let entered = expectation(description: "body reached transport")
        let cancelled = expectation(description: "writer revoked while awaiting write")
        let writer = HCAdmissionSuspendedWriter(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let revision = revision
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { revision }, report: { _ in })
        let operation = request()
        let task = Task { await input.submit(operation) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        writer.releaseForCleanup()
        guard case .uncertain(let receipt) = await task.value else { return XCTFail("partial write must stay uncertain") }
        XCTAssertEqual(receipt.bodyBytesWritten, 3)
        XCTAssertFalse(receipt.returnWritten)
        XCTAssertEqual(receipt.operationID, operation.operationID)
        guard case .refused(.inputFault) = await input.submit(request()) else { return XCTFail("uncertainty did not latch") }
    }

    func testReturnGuardReadsAttributedScreenAfterBodyAndSuppressesReturn() async {
        let writer = HCAdmissionReturnWriter()
        let operation = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
            attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
            returnGuard: { receipt in
                XCTAssertEqual(receipt.revision.attachmentGeneration, 3)
                XCTAssertEqual(writer.received, Data("invitation".utf8))
                return false
            })
        let input = coordinator(writer)
        guard case .uncertain(let receipt) = await input.submit(operation) else { return XCTFail("body-only outcome lost") }
        XCTAssertEqual(receipt.bodyBytesWritten, operation.payload.count)
        XCTAssertFalse(receipt.returnWritten)
        XCTAssertEqual(writer.received, operation.payload)
        guard case .refused(.inputFault) = await input.submit(request()) else { return XCTFail("body must not replay") }
    }

    /// C11H-124: a panel opening or closing re-lays-out the splits, and the display
    /// revision moves while the delayed Return waits on its guard. That said nothing
    /// about the prompt, but it cancelled the Return after the body was out, and
    /// the pause that follows silenced the panel for hours. The guard looks again.
    func testAScreenThatMovesOnceDuringTheReturnGuardIsCheckedAgainAndTheReturnIsSent() async {
        let display = HCAdmissionDisplay(revision)
        let writer = HCAdmissionReturnWriter()
        let calls = HCAdmissionCounter()
        let operation = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
            attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
            returnGuard: { _ in
                if calls.next() == 1 {
                    display.set(HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 77)) // a resize lands mid-check
                    return false // this verdict describes the obsolete screen
                }
                return true
            })
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionFollowingScreen(), displayRevision: { display.current },
            report: { _ in })
        guard case .written(let receipt) = await input.submit(operation) else { return XCTFail("a resize cut the Return") }
        XCTAssertTrue(receipt.returnWritten)
        XCTAssertEqual(calls.count, 2, "the composer was judged again on the new screen")
        // No pause followed: the next guarded send goes through.
        let next = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
            attachmentGeneration: 3, source: .mailbox, payload: Data("again".utf8), submitReturn: true,
            returnGuard: { _ in true })
        guard case .written(let again) = await input.submit(next) else { return XCTFail("the panel was paused") }
        XCTAssertTrue(again.returnWritten)
    }

    /// The re-check is one, not a loop: a screen that keeps moving, a changed
    /// prompt, or a reattach still stops the Return, as before.
    func testAScreenThatKeepsMovingOrAChangedPromptStillStopsTheReturn() async {
        let display = HCAdmissionDisplay(revision)
        let writer = HCAdmissionReturnWriter()
        let calls = HCAdmissionCounter()
        let moving = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
            attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
            returnGuard: { _ in
                display.set(HCDisplayRevision(attachmentGeneration: 3, displayGeneration: UInt64(100 + calls.next())))
                return true
            })
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionFollowingScreen(), displayRevision: { display.current },
            report: { _ in })
        guard case .uncertain(let receipt) = await input.submit(moving) else { return XCTFail("a moving screen sent the Return") }
        XCTAssertFalse(receipt.returnWritten)
        XCTAssertEqual(calls.count, 2, "one more look, then stop")

        let promptWriter = HCAdmissionReturnWriter()
        let promptCalls = HCAdmissionCounter()
        let changed = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
            attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
            returnGuard: { _ in _ = promptCalls.next(); return false })
        let second = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: promptWriter,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionFollowingScreen(), displayRevision: { self.revision },
            report: { _ in })
        guard case .uncertain = await second.submit(changed) else { return XCTFail("a changed prompt sent the Return") }
        XCTAssertEqual(promptCalls.count, 1, "a prompt that changed is not asked twice")
    }

    func testMissingReturnScreenRetriesOnlyWhenTheDisplayMoved() async {
        for moved in [false, true] {
            let display = HCAdmissionDisplay(revision), calls = HCAdmissionCounter()
            let writer = HCAdmissionReturnWriter()
            let screen = HCAdmissionCallbackScreen { revision in
                if calls.next() == 1 {
                    if moved { display.set(HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 10)) }
                    return nil
                }
                return HCScreenReceipt(revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24)
            }
            let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
                encoder: HCAdmissionEncoder(), screen: screen, displayRevision: { display.current }, report: { _ in })
            let operation = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
                attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
                returnGuard: { _ in true })
            let outcome = await input.submit(operation)
            if moved {
                guard case .written = outcome else { return XCTFail("moved screen was not rechecked") }
                XCTAssertEqual(calls.count, 2)
                XCTAssertEqual(writer.received, operation.payload + Data([13]))
            } else {
                guard case .uncertain = outcome else { return XCTFail("unavailable screen retried without a move") }
                XCTAssertEqual(calls.count, 1, "a stable-screen timeout must not double the writer stall")
                XCTAssertEqual(writer.received, operation.payload)
            }
        }
    }

    func testReturnRecheckNeverCrossesAnAttachmentOrClosedInputGate() async {
        for reattached in [true, false] {
            let display = HCAdmissionDisplay(revision)
            let writer = HCAdmissionReturnWriter()
            let calls = HCAdmissionCounter()
            let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
                encoder: HCAdmissionEncoder(), screen: HCAdmissionFollowingScreen(),
                displayRevision: { display.current }, report: { _ in })
            let operation = HCInputRequest(operationID: UUID(), panelID: panel, key: key,
                attachmentGeneration: 3, source: .mailbox, payload: Data("invitation".utf8), submitReturn: true,
                returnGuard: { _ in
                    _ = calls.next()
                    display.set(HCDisplayRevision(attachmentGeneration: reattached ? 4 : 3, displayGeneration: 10))
                    if !reattached { input.invalidate(generation: 3, reason: .unavailable) }
                    return true
                })
            guard case .uncertain(let receipt) = await input.submit(operation) else {
                return XCTFail("a new attachment or closed gate must not receive Return")
            }
            XCTAssertFalse(receipt.returnWritten)
            XCTAssertEqual(writer.received, operation.payload)
            XCTAssertEqual(calls.count, 1)
            guard case .refused = await input.submit(request()) else { return XCTFail("uncertainty must keep input closed") }
            XCTAssertEqual(writer.received, operation.payload, "uncertain bytes must never replay")
        }
    }

    func testRawFocusIsOwnedByAdapterAndSizeReportsKeepByteOrder() async {
        let completed = expectation(description: "two native writes")
        completed.expectedFulfillmentCount = 2
        let writer = HCAdmissionWriter()
        let revision = revision
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCUnavailableInputEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { revision }, report: { _ in completed.fulfill() })
        let size = Data("\u{1b}[48;24;80;480;800t".utf8)
        input.receiveRaw(Data("\u{1b}[I".utf8), kind: .key, generation: 3)
        input.receiveRaw(Data("\u{1b}[O".utf8), kind: .key, generation: 3)
        input.receiveRaw(size, kind: .query, generation: 3)
        input.receiveRaw(Data("x".utf8), kind: .key, generation: 3)
        await fulfillment(of: [completed], timeout: 2)
        let batches = writer.frames
        XCTAssertEqual(batches.count, 2)
        guard batches.count == 2, batches[0].count == 2, case .resize(let grid) = batches[0][0],
              case .data(let report) = batches[0][1], case .data(let key) = batches[1][0] else {
            return XCTFail("native framing/order changed")
        }
        XCTAssertEqual(grid, HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(report, size)
        XCTAssertEqual(key, Data("x".utf8))
        XCTAssertEqual(writer.received, size + Data("x".utf8))
    }

    func testDuplicateInBandGridStillTransmitsReportWithoutResize() async {
        let completed = expectation(description: "report sent")
        let writer = HCAdmissionWriter()
        let revision = revision
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCUnavailableInputEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { revision }, report: { _ in completed.fulfill() },
            claimInBandGrid: { _, _ in false })
        let bytes = Data("\u{1b}[48;24;80;480;800t".utf8)
        input.receiveRaw(bytes, kind: .query, generation: 3)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(writer.frames.first?.count, 1)
        XCTAssertEqual(writer.received, bytes)
    }

    func testNativeInputRingWrapPreservesBytesAndOrder() async {
        let writer = HCAdmissionWriter()
        let revision = revision
        let (completions, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCUnavailableInputEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { revision }, report: { _ in continuation.yield(()) })
        var iterator = completions.makeAsyncIterator()
        var expected = Data()
        // More than the fixed ring capacity, with completed reservations
        // released between bursts. A shifted/dropped/wrapped slot is visible.
        for burst in 0..<3 {
            for offset in 0..<128 {
                let bytes = Data("\(burst):\(offset),".utf8)
                expected.append(bytes)
                input.receiveRaw(bytes, kind: .key, generation: 3)
            }
            for _ in 0..<128 { _ = await iterator.next() }
        }
        XCTAssertEqual(writer.writeCount, 384)
        XCTAssertEqual(writer.received, expected)
    }

    func testAttachmentSendsInitialFocusAndOnlyRealFocusTransitions() async throws {
        for initiallyFocused in [false, true] {
            let channel = HCAdmissionFocusChannel()
            func display(_ sequence: UInt64, focused: Bool) -> HCDisplayState {
                HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: sequence),
                    grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: focused)
            }
            let attachment = HCPanelAttachment(panelID: panel, key: key, generation: 3,
                channel: channel, sink: HCAdmissionNoOutput(), rendering: HCUnavailableRenderingAdapter(),
                display: display(1, focused: initiallyFocused), encoder: HCUnavailableInputEncoder(), report: { _ in })
            try await attachment.initializeFocus()
            _ = await attachment.updateDisplay(display(2, focused: initiallyFocused))
            _ = await attachment.updateDisplay(display(3, focused: true))
            _ = await attachment.updateDisplay(display(4, focused: true))
            _ = await attachment.updateDisplay(display(5, focused: false))
            _ = await attachment.updateDisplay(display(6, focused: false))
            XCTAssertEqual(channel.focuses, [true, false], "resize/facts updates must not repeat a program's focus report")
            attachment.detach()
        }
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [HCInputOutcome] = []
        func add(_ outcome: HCInputOutcome) { lock.lock(); items.append(outcome); lock.unlock() }
        func removeAll() { lock.lock(); items.removeAll(); lock.unlock() }
        var all: [HCInputOutcome] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func gated(_ writer: HCAdmissionWriter, reports: Reports, admitted: Bool,
                       sources: Set<HCInputSource>? = nil) -> HCInputCoordinator {
        let revision = revision
        let screen = HCAdmissionScreen(receipt: HCScreenReceipt(
            revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24))
        if let sources {
            return HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
                encoder: HCAdmissionEncoder(), screen: screen, displayRevision: { revision },
                report: { reports.add($0) }, admitted: admitted, reportedSources: sources)
        }
        return HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: screen, displayRevision: { revision },
            report: { reports.add($0) }, admitted: admitted)
    }

    /// F13: a send that reached a port closed by the connection loss was named
    /// `.inputFault`, which latched "Input interrupted" for a send that wrote
    /// nothing.
    func testAClosedPortNamesWhyItIsClosedAndALatchNeedsAnActualFault() async {
        for reason in [HCInputRefusal.unavailable, .staleIdentity] {
            let writer = HCAdmissionWriter()
            let input = gated(writer, reports: Reports(), admitted: true)
            input.invalidate(generation: 3, reason: reason)
            guard case .refused(let named) = await input.submit(request()), named == reason else {
                return XCTFail("a port closed as \(reason) must refuse as \(reason), not as a fault")
            }
            XCTAssertEqual(writer.writeCount, 0)
        }
        let faulted = gated(HCAdmissionWriter(), reports: Reports(), admitted: true)
        faulted.invalidate(generation: 3, reason: .inputFault)
        guard case .refused(.inputFault) = await faulted.submit(request()) else {
            return XCTFail("a real fault still refuses as a fault")
        }
    }

    func testAKeyTypedOnAPortTheConnectionLossClosedIsRefusedWithoutAFault() {
        for reason in [HCInputRefusal.unavailable, .staleIdentity] {
            let reports = Reports()
            let input = gated(HCAdmissionWriter(), reports: reports, admitted: true)
            input.invalidate(generation: 3, reason: reason)
            input.receiveRaw(Data("k".utf8), kind: .key, generation: 3)
            XCTAssertFalse(reports.all.contains { if case .refused(.inputFault) = $0 { return true } else { return false } },
                "a key on a port closed as \(reason) latched an input fault")
            XCTAssertEqual(reports.all.count, 1)
        }
    }

    func testClosedPortRefusesVisiblyWithoutFaultAndReopenReplaysNothing() async {
        let writer = HCAdmissionWriter()
        let reports = Reports()
        let input = gated(writer, reports: reports, admitted: false)
        guard case .refused(.unavailable) = await input.submit(request()) else {
            return XCTFail("closed port accepted a transaction")
        }
        input.receiveRaw(Data("k".utf8), kind: .key, generation: 3)
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(reports.all.count, 2)
        XCTAssertFalse(reports.all.contains { if case .refused(.inputFault) = $0 { return true } else { return false } },
            "closing admission must not latch an input fault")
        input.setAdmission(true)
        let later = request(Data("after".utf8))
        guard case .written = await input.submit(later) else { return XCTFail("reopened port refused input") }
        XCTAssertEqual(writer.received, Data("after".utf8) + Data([13]), "refused input was replayed")
    }

    func testBackendInitialInputIsAdmittedBeforeTheOwnerOpensThePort() async {
        let writer = HCAdmissionWriter()
        let input = gated(writer, reports: Reports(), admitted: false)
        let initial = HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 3,
            source: .initial, payload: Data("first".utf8), submitReturn: true)
        guard case .written = await input.submit(initial) else { return XCTFail("initial input lost") }
        XCTAssertEqual(writer.received, Data("first".utf8) + Data([13]))
    }

    func testAdmissionToggleNeverClearsALatchedFault() async {
        let writer = HCAdmissionWriter()
        writer.failAfter = 2
        let input = gated(writer, reports: Reports(), admitted: true)
        guard case .uncertain = await input.submit(request()) else { return XCTFail("must be uncertain") }
        input.setAdmission(false)
        input.setAdmission(true)
        guard case .refused(.inputFault) = await input.submit(request()) else {
            return XCTFail("reopening admission cleared the fault")
        }
        XCTAssertEqual(writer.writeCount, 1)
    }

    func testOnlyListedSourcesReportProgrammaticOutcomesButRawAlwaysDoes() async {
        let writer = HCAdmissionWriter()
        let reports = Reports()
        let input = gated(writer, reports: reports, admitted: true, sources: [.initial])
        guard case .written = await input.submit(request()) else { return XCTFail("socket write failed") }
        XCTAssertEqual(reports.all.count, 0, "caller-recorded outcome was reported twice")
        let initial = HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 3,
            source: .initial, payload: Data("i".utf8), submitReturn: true)
        guard case .written = await input.submit(initial) else { return XCTFail("initial write failed") }
        XCTAssertEqual(reports.all.count, 1)
        let done = expectation(description: "raw write reported")
        let raw = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: HCAdmissionEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { self.revision }, report: { reports.add($0); done.fulfill() }, reportedSources: [])
        raw.receiveRaw(Data("x".utf8), kind: .key, generation: 3)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(reports.all.count, 2)
    }

    @MainActor
    func testReplacementPortIsClosedUntilAdoptedAndPolicyRecordsProgrammaticFaultOnce() async throws {
        let writer = HCAdmissionWriter()
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
        runtime.installReconnectPolicy()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let attachment = HCPanelAttachment(panelID: panel, key: key, generation: 3,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display,
            encoder: HCAdmissionEncoder(), report: { _ in })
        // Exposed to native callbacks before adoption: closed, visible, no fault.
        guard case .refused(.unavailable) = await attachment.submit(request()) else {
            return XCTFail("a replacement port accepted input before adoption")
        }
        XCTAssertTrue(runtime.bind(attachment, display: display.revision))
        guard case .written = await runtime.submitInput(request()) else { return XCTFail("adopted port refused input") }
        writer.failAfter = 2
        guard case .uncertain(let receipt) = await runtime.submitInput(request()) else { return XCTFail("must be uncertain") }
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        XCTAssertTrue(policy.isFaulted)
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        XCTAssertNotNil(runtime.inputFault, "runtime fault latch missing after a programmatic uncertain outcome")
        attachment.detach()
    }

    func testVetoedResizeIsOmittedWhileFactsAndFocusStillGo() async throws {
        struct Veto: HCRenderingAdapter {
            let admit: Bool
            @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
            func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
            func noteOutput(_ chunk: HCOutputChunk) {}
            func didParse(_ chunk: HCOutputChunk) {}
            func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
            @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
            @MainActor func attached(_ attachment: any HCAttachment) {}
            @MainActor func detached() {}
            @MainActor func surfaceSizeChanged() {}
            @MainActor func focusChanged(_ focused: Bool) {}
            func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
            func admitDisplayResize(_ state: HCDisplayState) -> Bool { admit }
        }
        func display(_ sequence: UInt64, focused: Bool) -> HCDisplayState {
            HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: sequence),
                grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: focused)
        }
        for admit in [true, false] {
            let channel = HCAdmissionFocusChannel()
            let attachment = HCPanelAttachment(panelID: panel, key: key, generation: 3, channel: channel,
                sink: HCAdmissionNoOutput(), rendering: Veto(admit: admit), display: display(1, focused: false),
                encoder: HCUnavailableInputEncoder(), report: { _ in })
            _ = await attachment.updateDisplay(display(2, focused: true))
            XCTAssertEqual(channel.controlKinds, admit ? ["resize", "facts"] : ["facts"])
            XCTAssertEqual(channel.focuses, [true], "FOCUS must still be sent when RESIZE is vetoed")
            attachment.detach()
        }
    }

    @MainActor
    func testLauncherInputWaitsForTheFirstAttachmentThenSendsOnceAndNeverReplays() async throws {
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
        runtime.installReconnectPolicy()
        let pending = HCPendingInput()
        func display(_ generation: UInt64) -> HCDisplayState {
            HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation, displayGeneration: 1),
                grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        }
        func attachment(_ generation: UInt64, _ writer: HCAdmissionWriter) -> HCPanelAttachment {
            HCPanelAttachment(panelID: panel, key: key, generation: generation,
                channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
                rendering: HCUnavailableRenderingAdapter(), display: display(generation),
                encoder: HCAdmissionEncoder(), report: { _ in })
        }
        let completed = expectation(description: "launcher completed")
        // A replay must fail the assertions below, not trap on a second fulfill.
        completed.assertForOverFulfill = false
        let results = Reports()
        let launcher = HCPendingInput.Item(text: "claude", submit: true, source: .textBox, screenGuard: nil,
            returnGuard: nil, completion: { results.add($0); completed.fulfill() })

        // Before any attachment: held, nothing sent, nothing reported.
        pending.submit(launcher, runtime: runtime, panelID: panel, allowQueue: true)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(results.all.isEmpty, "the launcher was refused before the creation could attach")

        // First attachment bound: exactly one launcher and one Return.
        let first = HCAdmissionWriter()
        let firstPort = attachment(3, first)
        XCTAssertTrue(runtime.bind(firstPort, display: display(3).revision))
        XCTAssertEqual(first.writeCount, 0, "nothing may be sent before the owner drains")
        pending.drain(runtime: runtime, panelID: panel)
        await fulfillment(of: [completed], timeout: 2)
        guard case .written(let receipt)? = results.all.first else { return XCTFail("launcher not written") }
        XCTAssertTrue(receipt.returnWritten)
        XCTAssertEqual(first.received, Data("claude".utf8) + Data([13]))
        XCTAssertEqual(pending.count, 0)

        // A replacement port must never see the launcher again.
        let second = HCAdmissionWriter()
        XCTAssertTrue(runtime.bind(attachment(4, second), display: display(4).revision))
        pending.drain(runtime: runtime, panelID: panel)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(second.writeCount, 0, "launcher input was replayed onto the replacement attachment")
        XCTAssertEqual(results.all.count, 1)
    }

    @MainActor
    func testQueueIsBoundedRefusesWhileReconnectingAndFailsVisiblyWhenTheCreationFails() async {
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
        runtime.installReconnectPolicy()
        let pending = HCPendingInput()
        let results = Reports()
        func item(_ text: String = "x") -> HCPendingInput.Item {
            HCPendingInput.Item(text: text, submit: false, source: .textBox, screenGuard: nil, returnGuard: nil,
                completion: { results.add($0) })
        }
        for _ in 0..<HCPendingInput.maxItems { pending.submit(item(), runtime: runtime, panelID: panel, allowQueue: true) }
        XCTAssertEqual(pending.count, HCPendingInput.maxItems)
        pending.submit(item(), runtime: runtime, panelID: panel, allowQueue: true)
        guard case .refused(.queueFull)? = results.all.last else { return XCTFail("queue overflow was not refused") }
        // The mailbox/launch-prompt rails never queue.
        pending.submit(item(), runtime: runtime, panelID: panel, allowQueue: false)
        guard case .refused(.unavailable)? = results.all.last else { return XCTFail("a non-queueing rail queued") }
        XCTAssertEqual(pending.count, HCPendingInput.maxItems)
        // The creation failed: every held item is refused, none is sent.
        results.removeAll()
        pending.failAll(.unavailable, runtime: runtime)
        XCTAssertEqual(results.all.count, HCPendingInput.maxItems)
        XCTAssertEqual(pending.count, 0)
        XCTAssertTrue(results.all.allSatisfy { if case .refused(.unavailable) = $0 { return true } else { return false } })
    }

    @MainActor
    func testAnAlreadyBoundPanelRefusesInputWhileReconnectingInsteadOfQueueingIt() {
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
        runtime.installReconnectPolicy()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let port = HCPanelAttachment(panelID: panel, key: key, generation: 3,
            channel: HCAdmissionWriteChannel(HCAdmissionWriter()), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display,
            encoder: HCAdmissionEncoder(), report: { _ in })
        XCTAssertTrue(runtime.bind(port, display: display.revision))
        runtime.detachSurface(forReattach: true)
        let results = Reports()
        let pending = HCPendingInput()
        pending.submit(HCPendingInput.Item(text: "late", submit: true, source: .textBox, screenGuard: nil,
            returnGuard: nil, completion: { results.add($0) }), runtime: runtime, panelID: panel, allowQueue: true)
        XCTAssertEqual(pending.count, 0, "input was queued for a replacement port")
        guard case .refused(.unavailable)? = results.all.first else { return XCTFail("reconnecting input was not refused") }
    }

    /// Mode-sensitive like Ghostty: a bracketed-paste program receives the body
    /// inside ESC[200~ ... ESC[201~, where an interior CR never executes; only a
    /// separate Return frame outside the brackets submits.
    private struct BracketedPasteEncoder: HCInputEncoder {
        func maximumEncodedBytes(for request: HCInputRequest) -> Int? { request.payload.count + 64 }
        func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
            var frames: [HCOutboundFrame] = [.data(Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) + request.payload
                + Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]))]
            if request.submitReturn { frames.append(.submitReturnAfter(Data([13]), delayNanoseconds: 0)) }
            return .success(frames)
        }
    }

    func testCreationInitialInputIsSubmittedOutsideTheBracketedPaste() async {
        let writer = HCAdmissionWriter()
        let revision = revision
        let input = HCInputCoordinator(panelID: panel, key: key, generation: 3, writer: writer,
            encoder: BracketedPasteEncoder(), screen: HCAdmissionScreen(receipt: nil),
            displayRevision: { revision }, report: { _ in })
        // CreateInitialInput queues "raw\r"; the hc creation must still run it.
        let initial = HCInitialInput.creation(from: "claude --resume\r", operationID: UUID())
        XCTAssertTrue(initial.submitReturn)
        XCTAssertEqual(initial.payload, Data("claude --resume".utf8))
        let request = HCInputRequest(operationID: initial.operationID, panelID: panel, key: key,
            attachmentGeneration: 3, source: .initial, payload: initial.payload, submitReturn: initial.submitReturn)
        guard case .written(let receipt) = await input.submit(request) else { return XCTFail("initial input lost") }
        XCTAssertTrue(receipt.returnWritten, "the launch line was typed but never submitted")
        let bytes = [UInt8](writer.received)
        XCTAssertEqual(bytes.last, 13, "Return must follow the closing bracket")
        XCTAssertFalse(bytes.dropLast().contains(13), "a CR inside the paste would not execute")
        // Without a trailing CR nothing is submitted.
        let draft = HCInitialInput.creation(from: "ls")
        XCTAssertFalse(draft.submitReturn)
        XCTAssertEqual(draft.payload, Data("ls".utf8))
    }

    func testClearingAFaultRequiresAStrictlyNewerAttachmentGeneration() {
        let gate = HCInputGeneration(panelID: panel, key: key, generation: 4)
        gate.invalidate(generation: 4, reason: .inputFault)
        let token = gate.faultToken!
        let revision = HCDisplayRevision(attachmentGeneration: 4, displayGeneration: 1)
        let receipt = HCScreenReceipt(revision: revision, parsedOutputWatermark: 1, columns: 80, rows: 24)
        XCTAssertFalse(gate.clearFault(receipt: receipt, expected: revision, interruptedGeneration: 4, faultToken: token),
            "the interrupted generation itself must not clear its own fault")
        XCTAssertTrue(gate.clearFault(receipt: receipt, expected: revision, interruptedGeneration: 3, faultToken: token))
    }

    func testFreshReceiptCannotClearANewerFaultOnTheSameReplacementPort() {
        let gate = HCInputGeneration(panelID: panel, key: key, generation: 4)
        let revision = HCDisplayRevision(attachmentGeneration: 4, displayGeneration: 1)
        let receipt = HCScreenReceipt(revision: revision, parsedOutputWatermark: 1, columns: 80, rows: 24)
        gate.invalidate(generation: 4, reason: .inputFault)
        let token = gate.faultToken!
        gate.invalidate(generation: 4, reason: .inputFault)
        XCTAssertFalse(gate.clearFault(receipt: receipt, expected: revision,
                                       interruptedGeneration: 3, faultToken: token))
        XCTAssertNil(gate.capture())
        XCTAssertTrue(gate.clearFault(receipt: receipt, expected: revision,
                                      interruptedGeneration: 3, faultToken: gate.faultToken!))
        XCTAssertNotNil(gate.capture())
    }

    func testDelayedStampCannotReviveAfterRetryOrChangeIdentity() {
        let gate = HCInputGeneration(panelID: panel, key: key, generation: 3)
        let stamp = gate.capture()!
        gate.invalidate(generation: 3, reason: .inputFault)
        XCTAssertNotNil(gate.refusal(for: stamp))
        XCTAssertFalse(gate.retryInput(receipt: HCScreenReceipt(revision: revision,
            parsedOutputWatermark: 2, columns: 80, rows: 24), expected: revision))
        let next = HCDisplayRevision(attachmentGeneration: 4, displayGeneration: 10)
        XCTAssertTrue(gate.retryInput(receipt: HCScreenReceipt(revision: next,
            parsedOutputWatermark: 3, columns: 80, rows: 24), expected: next))
        XCTAssertNotNil(gate.refusal(for: stamp))
        XCTAssertNotNil(gate.capture())
        let wrong = HCInputStamp(panelID: UUID(), key: key, attachmentGeneration: 4, epoch: 2)
        XCTAssertEqual(gate.refusal(for: wrong), .staleIdentity)
    }
}

/// A rendering adapter whose parser always answers with a receipt for the
/// revision it is asked about, so screen guards can pass in a fixture.
private struct HCAdmissionReceiptAdapter: HCRenderingAdapter {
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
    func noteOutput(_ chunk: HCOutputChunk) {}
    func didParse(_ chunk: HCOutputChunk) {}
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        HCScreenReceipt(revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24)
    }
}

private struct HCAdmissionScreen: HCScreenProvider {
    let receipt: HCScreenReceipt?
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { receipt }
}
private struct HCAdmissionNoOutput: HCOutputSink {
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption { .stale }
    func retire(completion: @escaping @Sendable () -> Void) { completion() }
}
private final class HCAdmissionFocusChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    private let lock = NSLock()
    private var values: [Bool] = []
    var focuses: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome { .refused(.unavailable) }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome { .refused(.unavailable) }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome {
        switch control {
        case .focus(let focused): record(focused)
        case .resize: recordKind("resize")
        case .facts: recordKind("facts")
        default: break
        }
        return .written
    }
    private func record(_ focused: Bool) { lock.lock(); values.append(focused); lock.unlock() }
    private var kinds: [String] = []
    var controlKinds: [String] { lock.lock(); defer { lock.unlock() }; return kinds }
    private func recordKind(_ kind: String) { lock.lock(); kinds.append(kind); lock.unlock() }
}
private final class HCAdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// A parser that answers for whatever revision it is asked about.
private struct HCAdmissionFollowingScreen: HCScreenProvider {
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        HCScreenReceipt(revision: revision, parsedOutputWatermark: 44, columns: 80, rows: 24)
    }
}

private struct HCAdmissionCallbackScreen: HCScreenProvider {
    let read: @Sendable (HCDisplayRevision) -> HCScreenReceipt?
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { read(revision) }
}

private final class HCAdmissionDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HCDisplayRevision
    init(_ value: HCDisplayRevision) { self.value = value }
    var current: HCDisplayRevision { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: HCDisplayRevision) { lock.lock(); self.value = value; lock.unlock() }
}

private final class HCAdmissionReturnWriter: HCFrameWriter, @unchecked Sendable {
    private let sink = HCAdmissionWriter()
    var received: Data { sink.received }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        sink.reserve(operationID: operationID, attachmentGeneration: attachmentGeneration, encodedByteCount: encodedByteCount)
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        let body = batch.frames.filter { if case .data = $0 { return true }; return false }
        let returns = batch.frames.filter {
            switch $0 { case .submitReturn, .submitReturnAfter: return true; default: return false }
        }
        guard case .written(let receipt) = await sink.write(HCWriteBatch(operationID: batch.operationID,
            attachmentGeneration: batch.attachmentGeneration, frames: body), reservation: reservation) else { return .refused(.cancelled) }
        if let guardReturn = batch.beforeReturn, !(await guardReturn()) { return .uncertain(receipt) }
        let result = await sink.write(HCWriteBatch(operationID: batch.operationID,
            attachmentGeneration: batch.attachmentGeneration, frames: returns), reservation: reservation)
        guard case .written(let returned) = result else { return .uncertain(receipt) }
        return .written(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
            bodyBytesWritten: receipt.bodyBytesWritten, returnWritten: returned.returnWritten))
    }
    func cancel(_ reservation: HCWriteReservation) { sink.cancel(reservation) }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

private final class HCAdmissionSuspendedWriter: HCFrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    private let entered: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private var continuation: CheckedContinuation<HCInputOutcome, Never>?
    private var receipt: HCWriteReceipt?
    init(entered: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.entered = entered; self.cancelled = cancelled
    }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        .reserved(HCWriteReservation(id: UUID(), operationID: operationID,
            attachmentGeneration: attachmentGeneration, connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            receipt = HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                     bodyBytesWritten: 3, returnWritten: false)
            lock.unlock()
            entered()
        }
    }
    func cancel(_ reservation: HCWriteReservation) { complete(notify: true) }
    func releaseForCleanup() { complete(notify: false) }
    private func complete(notify: Bool) {
        lock.lock()
        let continuation = continuation, receipt = receipt
        self.continuation = nil
        lock.unlock()
        guard let continuation, let receipt else { return }
        if notify { cancelled() }
        continuation.resume(returning: .uncertain(receipt))
    }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}
private struct HCAdmissionEncoder: HCInputEncoder {
    var expand = false
    func maximumEncodedBytes(for request: HCInputRequest) -> Int? { request.payload.count + 1 + 18 }
    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        .success([.data(expand ? request.payload + request.payload : request.payload), .submitReturn(Data([13]))])
    }
}
private actor HCAdmissionHeldEncoder: HCInputEncoder {
    let entered: @Sendable () -> Void
    var continuation: CheckedContinuation<Void, Never>?
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    nonisolated func maximumEncodedBytes(for request: HCInputRequest) -> Int? { request.payload.count + 1 + 18 }
    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered() }
        return .success([.data(request.payload), .submitReturn(Data([13]))])
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// Executable short-write sink. It records transport bytes, not input requests.
private final class HCAdmissionWriteChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    private let writer: HCAdmissionWriter
    init(_ writer: HCAdmissionWriter) { self.writer = writer }
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        writer.reserve(operationID: operationID, attachmentGeneration: attachmentGeneration, encodedByteCount: encodedByteCount)
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        await writer.write(batch, reservation: reservation)
    }
    func cancel(_ reservation: HCWriteReservation) { writer.cancel(reservation) }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}
private final class HCAdmissionWriter: HCFrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    var refuse: HCInputRefusal?
    var failAfter: Int?
    private var bytes = Data()
    private var writes = 0
    private var batches: [[HCOutboundFrame]] = []
    var frames: [[HCOutboundFrame]] { lock.lock(); defer { lock.unlock() }; return batches }
    private var cancellations: Set<UUID> = []
    var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var cancelled: Set<UUID> { lock.lock(); defer { lock.unlock() }; return cancellations }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        if let refuse { return .refused(refuse) }
        return .reserved(HCWriteReservation(id: UUID(), operationID: operationID,
            attachmentGeneration: attachmentGeneration, connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        writeNow(batch, reservation: reservation)
    }
    private func writeNow(_ batch: HCWriteBatch, reservation: HCWriteReservation) -> HCInputOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellations.contains(batch.operationID) else { return .refused(.cancelled) }
        writes += 1
        batches.append(batch.frames)
        var bodyCount = 0
        var returned = false
        for frame in batch.frames {
            switch frame {
            case .data(let data):
                let count = min(failAfter ?? data.count, data.count)
                bytes.append(data.prefix(count)); bodyCount += count
                if count < data.count {
                    return .uncertain(HCWriteReceipt(operationID: batch.operationID,
                        attachmentGeneration: batch.attachmentGeneration, bodyBytesWritten: bodyCount, returnWritten: false))
                }
            case .submitReturn(let data), .submitReturnAfter(let data, delayNanoseconds: _): bytes.append(data); returned = true
            default: break
            }
        }
        return .written(HCWriteReceipt(operationID: batch.operationID,
            attachmentGeneration: batch.attachmentGeneration, bodyBytesWritten: bodyCount, returnWritten: returned))
    }
    func cancel(_ reservation: HCWriteReservation) {
        lock.lock(); cancellations.insert(reservation.operationID); lock.unlock()
    }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

/// A resolver that deliberately ignores cancellation, as an already-dispatched
/// session lookup can. Feed delivery and runtime/coordinator ownership stay real.
private actor HCReattachHeldSession: HCSession {
    let record: HCTerminalRecord
    let gate: HCReconnectTestGate<Void>
    let entered: @Sendable () -> Void
    private nonisolated let feed = HCSessionFeed()
    private var didEnter = false
    init(record: HCTerminalRecord, gate: HCReconnectTestGate<Void>, entered: @escaping @Sendable () -> Void) {
        self.record = record; self.gate = gate; self.entered = entered
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [record.key: record]))
    }
    nonisolated func observe(on queue: DispatchQueue,
                             handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        if !didEnter { didEnter = true; entered() }
        await gate.wait()
        return .live(record)
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { .rejectedBeforeTransmission(.backendNotInstalled) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink,
                display: HCDisplayState) async throws -> any HCAttachment { throw HCUnavailableReason.backendNotInstalled }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .recoveryRequired(.backendNotInstalled) }
}

/// A transport paused after writing the body, before writing Return. Cancellation
/// at that boundary must honestly report uncertainty, just as the real channel does.
private final class HCReattachHeldChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    let gate: HCReconnectTestGate<Void>
    let entered: @Sendable () -> Void
    private let lock = NSLock()
    private var bytes = Data()
    private var cancelled = false
    var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    init(gate: HCReconnectTestGate<Void>, entered: @escaping @Sendable () -> Void) {
        self.gate = gate; self.entered = entered
    }
    func activate() async throws {}
    func close() { lock.lock(); cancelled = true; lock.unlock() }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        .reserved(HCWriteReservation(id: UUID(), operationID: operationID,
            attachmentGeneration: attachmentGeneration, connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func cancel(_ reservation: HCWriteReservation) { close() }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
    private func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    private func finish(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        bytes.append(data)
        return true
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        var body = Data(), submit = Data()
        for frame in batch.frames {
            switch frame {
            case .data(let data): body.append(data)
            case .submitReturn(let data), .submitReturnAfter(let data, delayNanoseconds: _): submit.append(data)
            default: break
            }
        }
        append(body)
        entered()
        await gate.wait()
        let returned = finish(submit)
        let receipt = HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
            bodyBytesWritten: body.count, returnWritten: returned)
        return returned ? .written(receipt) : .uncertain(receipt)
    }
}

/// A resume that is only partly written must stay visible and latched, exactly
/// like any other programmatic input. The helper's own once-per-terminal
/// bookkeeping cannot see that: only the owning runtime records the outcome.
@MainActor
final class HCResumeInputFaultTests: XCTestCase {
    private let panel = UUID()
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")

    private func display(_ generation: UInt64) -> HCDisplayState {
        HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
    }

    private func attachment(_ generation: UInt64, _ writer: HCAdmissionWriter,
                            key: HCTerminalKey? = nil) -> HCPanelAttachment {
        HCPanelAttachment(panelID: panel, key: key ?? self.key, generation: generation,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCAdmissionReceiptAdapter(), display: display(generation),
            encoder: HCAdmissionEncoder(), report: { _ in })
    }

    /// A native start can bind while the reconnect owner's resolve is suspended.
    /// Its obsolete continuation must not retire that newly admitted input port.
    func testFreshRuntimeBindingSupersedesPendingReconnectWithoutCuttingInput() async throws {
        let record = HCTerminalRecord(key: key, state: .running, pid: 707)
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent)
        let resolving = expectation(description: "reconnect resolving")
        let resolution = HCReconnectTestGate<Void>()
        let session = HCReattachHeldSession(record: record, gate: resolution, entered: { resolving.fulfill() })
        let runtime = HCPanelSession(identity: identity, session: session, registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        runtime.publish(.live(record))
        let original = attachment(1, HCAdmissionWriter())
        XCTAssertTrue(runtime.bind(original, display: display(1).revision))
        defer {
            runtime.reconnectAttachment = nil
            runtime.detachSurface()
            HCPanelRestoreState.shared.remove(panelID: panel)
        }

        var redundantAttaches = 0
        runtime.reconnectAttachment = { record in
            redundantAttaches += 1
            // Same composition order as TerminalSurface.recreateHCAttachment.
            runtime.prepareReattach()
            runtime.publish(.live(record))
            let third = self.attachment(3, HCAdmissionWriter())
            XCTAssertTrue(runtime.bind(third, display: self.display(3).revision))
            return third
        }
        runtime.connectionLost(.connectionLost)
        await fulfillment(of: [resolving], timeout: 2)
        let obsoleteAttempt = try XCTUnwrap(runtime.reconnectAttemptForTesting)

        let bodyWritten = expectation(description: "body written before Return")
        let returnGate = HCReconnectTestGate<Void>()
        let channel = HCReattachHeldChannel(gate: returnGate, entered: { bodyWritten.fulfill() })
        let fresh = HCPanelAttachment(panelID: panel, key: key, generation: 2, channel: channel,
            sink: HCAdmissionNoOutput(), rendering: HCAdmissionReceiptAdapter(), display: display(2),
            encoder: HCAdmissionEncoder(), report: { _ in })
        runtime.publish(.live(record))
        XCTAssertTrue(runtime.bind(fresh, display: display(2).revision))
        let request = HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 2,
            source: .socket, payload: Data("echo survived".utf8), submitReturn: true)
        let send = Task { @MainActor in await runtime.submitInput(request) }
        await fulfillment(of: [bodyWritten], timeout: 2)

        await resolution.release(())
        await obsoleteAttempt.value
        await returnGate.release(())
        let outcome = await send.value
        XCTAssertEqual(redundantAttaches, 0, "a fresh runtime binding did not supersede its pending reconnect")
        XCTAssertTrue(runtime.attachment === fresh)
        guard case .written(let receipt) = outcome else {
            return XCTFail("the redundant reattach cut an admitted write: \(outcome)")
        }
        XCTAssertTrue(receipt.returnWritten)
        XCTAssertEqual(channel.received, Data("echo survived\r".utf8))
        XCTAssertFalse(try XCTUnwrap(runtime.disconnectedInput).isFaulted)
        XCTAssertNil(runtime.inputFault)
    }

    func testReconnectKeepsItsBoundResultAndANewOutageKeepsTheInputPause() async throws {
        let record = HCTerminalRecord(key: key, state: .running, pid: 707)
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent)
        let session = HCReconnectTestSession(identity: identity, record: record)
        let runtime = HCPanelSession(identity: identity, session: session, registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        runtime.publish(.live(record))
        XCTAssertTrue(runtime.bind(attachment(1, HCAdmissionWriter()), display: display(1).revision))
        defer {
            runtime.reconnectAttachment = nil
            runtime.detachSurface()
            HCPanelRestoreState.shared.remove(panelID: panel)
        }

        var attaches = 0
        let writer = HCAdmissionWriter()
        let replacement = attachment(2, writer)
        let later = attachment(3, HCAdmissionWriter())
        runtime.reconnectAttachment = { _ in
            attaches += 1
            runtime.prepareReattach()
            // Inventory can publish a wait while the verified attach finishes.
            runtime.publish(.unresolved(identity, .inventoryPending))
            let candidate = attaches == 1 ? replacement : later
            XCTAssertTrue(runtime.bind(candidate, display: candidate.currentDisplayState.revision))
            return candidate
        }
        runtime.connectionLost(.connectionLost)
        let reconnect = try XCTUnwrap(runtime.reconnectAttemptForTesting)
        await reconnect.value
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        XCTAssertTrue(runtime.attachment === replacement)
        XCTAssertTrue(policy.isBound(to: replacement))
        XCTAssertEqual(attaches, 1)
        func request(_ generation: UInt64) -> HCInputRequest {
            HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: generation,
                source: .socket, payload: Data("echo connected".utf8), submitReturn: true)
        }
        guard case .written = await runtime.submitInput(request(2)) else {
            return XCTFail("the reconnect retired its own adopted result")
        }
        XCTAssertEqual(writer.received, Data("echo connected\r".utf8))

        // A genuine partial write still latches. Adopting another port must
        // not replay it, clear its pause, or bypass explicit Retry input.
        writer.failAfter = 2
        guard case .uncertain = await runtime.submitInput(request(2)) else {
            return XCTFail("expected a genuine short write")
        }
        XCTAssertTrue(policy.isFaulted)
        runtime.connectionLost(.connectionLost)
        let nextReconnect = try XCTUnwrap(runtime.reconnectAttemptForTesting)
        await nextReconnect.value
        XCTAssertEqual(attaches, 2)
        XCTAssertTrue(runtime.attachment === later)
        XCTAssertTrue(policy.isBound(to: later))
        XCTAssertTrue(policy.isFaulted)
        XCTAssertNotNil(runtime.inputFault)
        let paused = await runtime.submitInput(request(3))
        guard case .refused(.inputFault) = paused else { return XCTFail("replacement bypassed the input pause") }
    }

    func testUncertainResumeLatchesTheFaultAndNeverReachesAReplacementAttachment() async throws {
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
        runtime.installReconnectPolicy()
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        let first = HCAdmissionWriter()
        first.failAfter = 6  // the body is cut short: uncertain
        let firstPort = attachment(3, first)
        XCTAssertTrue(runtime.bind(firstPort, display: display(3).revision))
        let sender = HCConversationResumeSubmission()

        let outcome = await sender.submit(panelID: panel, runtime: runtime, attachment: firstPort,
            text: "claude --resume exact-session", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        guard case .uncertain(let receipt) = outcome else { return XCTFail("expected an uncertain write: \(outcome)") }
        XCTAssertEqual(first.received.count, 6, "only part of the resume reached the shell")

        // Visible and latched at the runtime, not just skipped in a ledger.
        XCTAssertNotNil(runtime.inputFault, "an uncertain resume did not latch the runtime's input fault")
        XCTAssertTrue(policy.isFaulted)
        XCTAssertEqual(policy.notice, .interrupted(receipt))

        // The attachment is replaced (reconnect). The shell still holds the
        // partial resume: nothing may be replayed or admitted until Retry.
        let second = HCAdmissionWriter()
        let secondPort = attachment(4, second)
        XCTAssertTrue(runtime.bind(secondPort, display: display(4).revision))
        let replay = await sender.submit(panelID: panel, runtime: runtime, attachment: secondPort,
            text: "claude --resume exact-session", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        guard case .refused = replay else { return XCTFail("a resume was replayed after an uncertain write") }
        let later = HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 4,
            source: .textBox, payload: Data("ls".utf8), submitReturn: true)
        guard case .refused(.inputFault) = await runtime.submitInput(later) else {
            return XCTFail("later input reached a shell holding an incomplete resume")
        }
        XCTAssertEqual(second.writeCount, 0, "the replacement attachment received bytes")
        XCTAssertTrue(policy.isFaulted, "reattachment alone must not clear the interruption")
        firstPort.detach()
        secondPort.detach()
    }

    func testStartupReplacementRekeysTheExistingOwnerAndOpensInput() async throws {
        let newKey = HCTerminalKey(owningCoreID: "owned", localAddress: "t8")
        let oldRecord = HCTerminalRecord(key: key, state: .running, pid: 707)
        let newRecord = HCTerminalRecord(key: newKey, state: .running, pid: 808)
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent)
        let runtime = HCPanelSession(identity: identity,
            session: HCReconnectTestSession(identity: identity, record: newRecord), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        defer {
            runtime.reconnectAttachment = nil
            runtime.detachSurface()
            HCPanelRestoreState.shared.remove(panelID: panel)
        }
        runtime.publish(.live(oldRecord))
        XCTAssertTrue(runtime.bind(attachment(1, HCAdmissionWriter()), display: display(1).revision))
        XCTAssertEqual(runtime.reconnectOwnerKey, key)
        runtime.publish(.ended(HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished, hcReason: "killed")))
        // Ordinary startup can create a new shell while revealing a kept,
        // ended headless panel, without calling prepareEndedReplacement.
        runtime.publish(.live(newRecord))
        let writer = HCAdmissionWriter()
        let replacement = attachment(2, writer, key: newKey)
        XCTAssertTrue(runtime.bind(replacement, display: display(2).revision))
        XCTAssertTrue(try XCTUnwrap(runtime.disconnectedInput).isBound(to: replacement))
        XCTAssertEqual(runtime.reconnectOwnerKey, newKey)
        let request = HCInputRequest(operationID: UUID(), panelID: panel, key: newKey,
            attachmentGeneration: 2, source: .socket, payload: Data("echo replaced".utf8), submitReturn: true)
        guard case .written = await runtime.submitInput(request) else {
            return XCTFail("the startup replacement left input closed")
        }
        XCTAssertEqual(writer.received, Data("echo replaced\r".utf8))

        let regained = attachment(3, HCAdmissionWriter(), key: newKey)
        var attachedKeys: [HCTerminalKey] = []
        runtime.reconnectAttachment = { record in
            attachedKeys.append(record.key)
            runtime.publish(.live(record))
            XCTAssertTrue(runtime.bind(regained, display: self.display(3).revision))
            return regained
        }
        runtime.connectionLost(.connectionLost)
        let reconnect = try XCTUnwrap(runtime.reconnectAttemptForTesting)
        await reconnect.value
        XCTAssertTrue(runtime.attachment === regained)
        XCTAssertEqual(attachedKeys, [newKey])
    }

    func testRefusedFirstAdoptionDropsTheUnusedOwnerAndStillBindsInput() throws {
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        defer { runtime.detachSurface(); HCPanelRestoreState.shared.remove(panelID: panel) }
        // An incomplete live record cannot start a reconnect owner. It must
        // not leave a never-started owner blocking initial resolution later.
        runtime.publish(.live(HCTerminalRecord(key: key, state: .starting)))
        let port = attachment(1, HCAdmissionWriter())
        XCTAssertTrue(runtime.bind(port, display: display(1).revision))
        XCTAssertNil(runtime.reconnectOwnerKey)
        XCTAssertTrue(try XCTUnwrap(runtime.disconnectedInput).isBound(to: port))
    }

    func testLateAttachmentCannotReviveAnEndedTerminal() throws {
        let record = HCTerminalRecord(key: key, state: .running, pid: 707)
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        defer { runtime.detachSurface(); HCPanelRestoreState.shared.remove(panelID: panel) }
        runtime.publish(.live(record))
        let ended = HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished, hcReason: "killed")
        runtime.publish(.ended(ended))
        let late = attachment(1, HCAdmissionWriter())
        defer { late.detach() }
        XCTAssertFalse(runtime.bind(late, display: display(1).revision))
        XCTAssertNil(runtime.attachment)
        XCTAssertNil(runtime.reconnectOwnerKey)
        XCTAssertFalse(try XCTUnwrap(runtime.disconnectedInput).isBound(to: late))
        guard case .ended(let retained) = runtime.lifecycle else { return XCTFail("late bind revived an ended terminal") }
        XCTAssertEqual(retained.id, ended.id)
    }

    /// Holder loss, then a replacement terminal in the same panel, then an
    /// ordinary connection drop. The reconnect owner must belong to the
    /// replacement: one bound to the dead terminal would publish staleIdentity
    /// and never reattach the new key.
    func testReplacingAnEndedTerminalGivesTheReplacementItsOwnReconnectOwner() async throws {
        let newKey = HCTerminalKey(owningCoreID: "owned", localAddress: "t8")
        let oldRecord = HCTerminalRecord(key: key, state: .running, pid: 707)
        let newRecord = HCTerminalRecord(key: newKey, state: .running, pid: 808)
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            creationID: nil, origin: .fresh)
        // The first owner adopts its attachment directly, so the session only
        // ever resolves the replacement: the terminal a new owner must reach.
        let runtime = HCPanelSession(identity: identity,
            session: HCReconnectTestSession(identity: identity, record: newRecord))
        runtime.installReconnectPolicy()
        runtime.publish(.live(oldRecord))
        let original = attachment(1, HCAdmissionWriter())
        XCTAssertTrue(runtime.bind(original, display: display(1).revision))
        XCTAssertEqual(runtime.reconnectOwnerKey, key, "the original terminal has a reconnect owner")

        // A live terminal is never replaced.
        XCTAssertFalse(runtime.prepareEndedReplacement())
        XCTAssertEqual(runtime.reconnectOwnerKey, key)

        runtime.publish(.ended(HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished, hcReason: "holder_lost")))
        XCTAssertTrue(runtime.prepareEndedReplacement())
        XCTAssertNil(runtime.reconnectOwnerKey, "the dead terminal's owner outlived its replacement")
        XCTAssertNil(runtime.attachment)

        runtime.publish(.live(newRecord))
        let replacement = attachment(2, HCAdmissionWriter(), key: newKey)
        XCTAssertTrue(runtime.bind(replacement, display: display(2).revision))
        XCTAssertEqual(runtime.reconnectOwnerKey, newKey, "the replacement has no reconnect owner of its own")

        // The ordinary drop that follows reattaches the NEW key.
        let regained = attachment(3, HCAdmissionWriter(), key: newKey)
        var attachedKeys: [HCTerminalKey] = []
        runtime.reconnectAttachment = { record in
            attachedKeys.append(record.key)
            runtime.publish(.live(record))
            XCTAssertTrue(runtime.bind(regained, display: self.display(3).revision))
            return regained
        }
        runtime.connectionLost(.connectionLost)
        await eventually { runtime.attachment === regained }
        XCTAssertEqual(attachedKeys.first, newKey, "reconnect went to the dead terminal")
        guard case .live(let record) = runtime.lifecycle else {
            return XCTFail("a stale reconnect owner published into the replacement: \(runtime.lifecycle)")
        }
        XCTAssertEqual(record.key, newKey)
        XCTAssertEqual(runtime.identity.key, newKey)
        runtime.detachSurface()
    }

    /// The backend ending a terminal (host died, stopped, shut down, restarted)
    /// is not a shell exit: closing the panel would discard the very session
    /// recovery exists to bring back. Only an ordinary exit closes it.
    func testHostCausedEndsKeepThePanelAndOrdinaryExitsClose() async throws {
        for (reason, closes) in [("holder_lost", false), ("server_stop", false), ("host_shutdown", false),
                                 ("stopped_by_restart", false), ("exited", true), ("killed", true)] {
            let identity = HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent,
                creationID: nil, origin: .fresh)
            let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime())
            var closed = 0
            runtime.onEnded = { _ in closed += 1 }
            let revision = HCRevision(connectionGeneration: 1, sequence: 5)
            let record = HCTerminalRecord(key: key, state: .finished, exitCode: 0, endReason: reason)
            runtime.receiveInventory(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [key: record]))
            guard case .ended(let proof) = runtime.lifecycle else { return XCTFail("\(reason): not published as ended") }
            XCTAssertEqual(proof.hcReason, reason)
            XCTAssertEqual(closed, closes ? 1 : 0,
                           "\(reason): \(closes ? "an ordinary exit must close" : "a host-caused end must keep the panel")")
            HCPanelRestoreState.shared.remove(panelID: identity.panelID)
            if !closes {
                XCTAssertEqual(HCRestoreLifecycleProjection.notice(for: .ended(proof)), .holderLost,
                               "\(reason): the retained panel has no explanation")
            }
        }
    }
}

/// Contract L2: awaited programmatic input waits for its pinned attachment and
/// screen readiness in order, bounded by the caller's deadline (C11H-24 T3.9 and
/// T3.11 lost sends issued right after a new hc panel opened). Fakes only.
@MainActor
final class HCInputReadyQueueTests: XCTestCase {
    private final class Attachment: HCAttachment, HCInputPort, @unchecked Sendable {
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "ready")
        let generation: UInt64 = 1
        var input: any HCInputPort { self }
        let screenDelayNanoseconds: UInt64
        init(screenDelayNanoseconds: UInt64 = 0) { self.screenDelayNanoseconds = screenDelayNanoseconds }
        func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
        func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {}
        func invalidate(generation: UInt64, reason: HCInputRefusal) {}
        func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
            if screenDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: screenDelayNanoseconds) }
            return HCScreenReceipt(revision: revision, parsedOutputWatermark: 1, columns: 80, rows: 24)
        }
        func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .written }
        func detach() {}
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [HCInputOutcome] = []
        func add(_ outcome: HCInputOutcome) { lock.lock(); items.append(outcome); lock.unlock() }
        var all: [HCInputOutcome] { lock.lock(); defer { lock.unlock() }; return items }
    }
    @MainActor private final class Pick {
        var current: Attachment?
        var sentTo: (any HCAttachment)?
    }

    @MainActor private final class State {
        var ready = false
        var sent: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var screenAsks = 0
        var held: CheckedContinuation<Void, Never>?
        var holdFirst = false
    }

    private let attachment = Attachment()

    private func written() -> HCInputOutcome {
        .written(HCWriteReceipt(operationID: UUID(), attachmentGeneration: 1, bodyBytesWritten: 1, returnWritten: true))
    }

    private func submit(_ queue: HCInputReadyQueue, _ state: State, _ label: String, wait: TimeInterval = 3,
                        screen: (@MainActor (any HCAttachment, UInt64) async -> Bool)? = nil) -> Task<HCInputOutcome, Never> {
        let attachment = attachment
        let outcome = written()
        return Task { @MainActor in
            await queue.submit(waitSeconds: wait,
                readiness: { state.ready ? .ready(attachment) : .waiting(.unavailable) },
                screenReady: screen, send: { _ in
                    state.inFlight += 1
                    state.maxInFlight = max(state.maxInFlight, state.inFlight)
                    state.sent.append(label)
                    if state.holdFirst, state.sent.count == 1 {
                        await withCheckedContinuation { state.held = $0 }
                    }
                    state.inFlight -= 1
                    return outcome
                })
        }
    }

    private func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func isWritten(_ outcome: HCInputOutcome) -> Bool {
        if case .written = outcome { return true }
        return false
    }

    func testSendsBeforeTheTerminalIsReadyAreDeliveredOnceReadyInOrderAndOnce() async {
        let queue = HCInputReadyQueue(), state = State()
        state.holdFirst = true
        let a = submit(queue, state, "a")
        await until { queue.count == 1 }
        let b = submit(queue, state, "b")
        await until { queue.count == 2 }
        let c = submit(queue, state, "c")
        await until { queue.count == 3 }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.sent, [], "nothing is sent while the terminal attaches")

        state.ready = true
        await until { state.sent == ["a"] }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.sent, ["a"], "later sends wait for the one before them to finish")
        state.held?.resume()

        let outcomes = [await a.value, await b.value, await c.value]
        XCTAssertTrue(outcomes.allSatisfy(isWritten))
        XCTAssertEqual(state.sent, ["a", "b", "c"], "in order, each once")
        XCTAssertEqual(state.maxInFlight, 1)
        XCTAssertEqual(queue.count, 0)
    }

    func testAWaitThatTimesOutRefusesWithItsReasonAndSendsNothing() async {
        let queue = HCInputReadyQueue(), state = State()
        let started = Date()
        let outcome = await submit(queue, state, "late", wait: 0.15).value
        guard case .refused(.unavailable) = outcome else { return XCTFail("want refused(unavailable), got \(outcome)") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.14, "it waited its bound")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(state.sent, [])
    }

    func testAGuardedSendWaitsForTheScreenThenSendsOnce() async {
        let queue = HCInputReadyQueue(), state = State()
        state.ready = true
        let outcome = await submit(queue, state, "guarded", screen: { _, _ in
            state.screenAsks += 1
            return state.screenAsks >= 3
        }).value
        XCTAssertTrue(isWritten(outcome))
        XCTAssertEqual(state.sent, ["guarded"])
        XCTAssertEqual(state.screenAsks, 3)
    }

    func testAScreenThatNeverBecomesReadyRefusesScreenUnavailable() async {
        let queue = HCInputReadyQueue(), state = State()
        state.ready = true
        let outcome = await submit(queue, state, "guarded", wait: 0.15, screen: { _, _ in false }).value
        guard case .refused(.screenUnavailable) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(state.sent, [])
    }

    func testZeroWaitAnswersAtOnceAsBefore() async {
        let queue = HCInputReadyQueue(), state = State()
        let started = Date()
        guard case .refused(.unavailable) = await submit(queue, state, "now", wait: 0).value else {
            return XCTFail("a zero wait refuses at once")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        state.ready = true
        let outcome = await submit(queue, state, "ready", wait: 0, screen: { _, _ in
            state.screenAsks += 1; return false
        }).value
        XCTAssertTrue(isWritten(outcome), "the coordinator's own screen check answers a zero wait")
        XCTAssertEqual(state.screenAsks, 0)
    }

    func testAFailedTerminalRefusesWithoutWaiting() async {
        let queue = HCInputReadyQueue()
        let started = Date()
        let outcome = await queue.submit(waitSeconds: 3, readiness: { .failed(.unavailable) },
                                         screenReady: nil, send: { _ in XCTFail("sent"); return .refused(.cancelled) })
        guard case .refused(.unavailable) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testCancellingAWaitRefusesCancelledAndSendsNothing() async {
        let queue = HCInputReadyQueue(), state = State()
        let task = submit(queue, state, "cancelled")
        await until { queue.count == 1 }
        task.cancel()
        guard case .refused(.cancelled) = await task.value else { return XCTFail("want cancelled") }
        state.ready = true
        XCTAssertEqual(state.sent, [])
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: Repair round 1 (Grok, pr55)

    /// First attach: `postHCReady` binds and drains held launch input in one
    /// main-actor turn while a socket send waits. The port admits one
    /// programmatic writer, so the send must wait behind the drain: both are
    /// written, in order, and neither is refused `queueFull`.
    func testAWaitingSendQueuesBehindTheFirstAttachDrainAndBothAreWritten() async throws {
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "owned", localAddress: "drain")
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        let writer = HCAdmissionWriter(), encoder = HCFirstHeldEncoder()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let port = HCPanelAttachment(panelID: panel, key: key, generation: 3,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display, encoder: encoder, report: { _ in })
        defer { port.detach() }
        let pending = HCPendingInput(), queue = HCInputReadyQueue(), launched = Outcomes()
        pending.submit(HCPendingInput.Item(text: "launch", submit: true, source: .textBox, screenGuard: nil,
            returnGuard: nil, completion: { launched.add($0) }), runtime: runtime, panelID: panel, allowQueue: true)
        XCTAssertEqual(pending.count, 1, "held until the first attachment")
        let send = Task { @MainActor in
            await queue.submit(waitSeconds: 2, readiness: {
                HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: pending.isBusy)
            }, screenReady: nil) { attachment in
                await runtime.submitInput(HCInputRequest(operationID: UUID(), panelID: panel, key: attachment.key,
                    attachmentGeneration: attachment.generation, source: .socket, payload: Data("sent".utf8),
                    submitReturn: true, screenGuard: nil, returnGuard: nil))
            }
        }
        await until { queue.count == 1 }

        XCTAssertTrue(runtime.bind(port, display: display.revision))
        pending.drain(runtime: runtime, panelID: panel)
        for _ in 0..<500 where await encoder.enteredCount() == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        // The waiter polls several times while the drained write holds the port.
        try await Task.sleep(nanoseconds: 120_000_000)
        await encoder.release()

        let outcome = await send.value
        guard case .written = outcome else { return XCTFail("the socket send was not written: \(outcome)") }
        guard case .written? = launched.all.first else { return XCTFail("the held launch input was dropped: \(launched.all)") }
        XCTAssertEqual(launched.all.count, 1)
        XCTAssertEqual(writer.received, Data("launch\r".utf8) + Data("sent\r".utf8), "drain first, then the send, once each")
    }

    /// The production readiness rule, on a real runtime and bound port.
    // MARK: C11H-82: input after `hc server restart`

    @MainActor
    private func restartHarness(_ writer: HCAdmissionWriter, generation: UInt64)
        -> (HCPanelSession, HCPanelAttachment, HCDisplayState) {
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "owned", localAddress: "t9")
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let port = HCPanelAttachment(panelID: panel, key: key, generation: generation,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display, encoder: HCAdmissionEncoder(), report: { _ in })
        return (runtime, port, display)
    }

    private func input(_ runtime: HCPanelSession, generation: UInt64) -> HCInputRequest {
        HCInputRequest(operationID: UUID(), panelID: runtime.identity.panelID, key: runtime.identity.key!,
            attachmentGeneration: generation, source: .socket, payload: Data("x".utf8), submitReturn: true)
    }

    /// F13: sends during the reconnect, then a fresh attachment that takes no
    /// input. A refused send must leave the panel able to take input on the
    /// replacement.
    @MainActor
    func testASendDuringTheReconnectNeverLatchesAFaultOnTheReplacementAttachment() async throws {
        let (runtime, first, firstDisplay) = restartHarness(HCAdmissionWriter(), generation: 3)
        defer { first.detach() }
        XCTAssertTrue(runtime.bind(first, display: firstDisplay.revision))
        runtime.connectionLost(.connectionLost)
        for _ in 0..<3 {
            guard case .refused(let reason) = await runtime.submitInput(input(runtime, generation: 3)),
                  reason != .inputFault else { return XCTFail("a send during the reconnect reported a fault") }
        }
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        XCTAssertFalse(policy.isFaulted, "a refused send during the reconnect latched Input interrupted")
        XCTAssertNil(runtime.inputFault)

        let writer = HCAdmissionWriter()
        let replacementDisplay = HCDisplayState(
            revision: HCDisplayRevision(attachmentGeneration: 4, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let second = HCPanelAttachment(panelID: runtime.identity.panelID, key: runtime.identity.key!, generation: 4,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: replacementDisplay,
            encoder: HCAdmissionEncoder(), report: { _ in })
        defer { second.detach() }
        XCTAssertTrue(runtime.bind(second, display: replacementDisplay.revision))
        guard case .written = await runtime.submitInput(input(runtime, generation: 4)) else {
            return XCTFail("the reattached terminal takes no input")
        }
        XCTAssertEqual(writer.received, Data("x".utf8) + Data([13]))
    }

    /// The connection loss closes the policy's port at once, so a send waits for
    /// the replacement instead of reaching the closed one.
    @MainActor
    func testAPanelWhoseConnectionIsLostIsNotReadyForInputUntilItReattaches() {
        let (runtime, port, display) = restartHarness(HCAdmissionWriter(), generation: 3)
        defer { port.detach() }
        XCTAssertTrue(runtime.bind(port, display: display.revision))
        guard case .ready = HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false) else {
            return XCTFail("a bound, open port is ready")
        }
        runtime.connectionLost(.connectionLost)
        guard case .waiting(.unavailable) = HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false) else {
            return XCTFail("a port the connection loss closed must not be handed a send")
        }
    }

    func testReadinessFollowsTheRuntimeItsPortAndThePendingQueue() {
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "owned", localAddress: "ready-rule")
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let port = HCPanelAttachment(panelID: panel, key: key, generation: 3,
            channel: HCAdmissionWriteChannel(HCAdmissionWriter()), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display, encoder: HCAdmissionEncoder(), report: { _ in })
        defer { port.detach() }
        guard case .waiting(.unavailable) = HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false) else {
            return XCTFail("an unbound panel is still attaching")
        }
        XCTAssertTrue(runtime.bind(port, display: display.revision))
        guard case .ready(let ready) = HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false) else {
            return XCTFail("a bound, open port is ready")
        }
        XCTAssertTrue(ready === port)
        guard case .waiting = HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: true) else {
            return XCTFail("held input goes first")
        }
        let replacement = HCPanelSession(identity: HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        guard case .failed(.unavailable) = HCInputReadyQueue.readiness(of: runtime, current: replacement, pendingBusy: false) else {
            return XCTFail("a replaced runtime fails at once")
        }
    }

    func testASendGetsTheAttachmentStillReadyAfterTheScreenCheck() async {
        let queue = HCInputReadyQueue(), first = Attachment(), second = Attachment()
        let state = Pick()
        state.current = first
        let outcome = await queue.submit(waitSeconds: 1, readiness: { .ready(state.current!) }, screenReady: { _, _ in
            state.current = second
            return true
        }) { attachment in
            state.sentTo = attachment
            return self.written()
        }
        XCTAssertTrue(isWritten(outcome))
        XCTAssertTrue(state.sentTo === second, "a port replaced during the screen check is not the one written")
    }

    func testATurnThatNeverReachesTheHeadReportsWhatTheHeadWaitsFor() async {
        let queue = HCInputReadyQueue(), state = State()
        let head = submit(queue, state, "head", wait: 2)
        await until { queue.count == 1 }
        let behind = await submit(queue, state, "behind", wait: 0.1).value
        guard case .refused(.unavailable) = behind else { return XCTFail("want unavailable, got \(behind)") }
        head.cancel()
        _ = await head.value
        XCTAssertEqual(state.sent, [])
    }

    func testTheScreenCheckIsBoundedByTheCallersDeadline() async {
        let slow = Attachment(screenDelayNanoseconds: 1_500_000_000)
        let revision = HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1)
        let started = Date()
        let late = await HCInputReadyQueue.screenCurrent(slow, after: revision, within: 50_000_000)
        XCTAssertFalse(late)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        let current = await HCInputReadyQueue.screenCurrent(attachment, after: revision, within: 1_000_000_000)
        XCTAssertTrue(current)
    }

    // MARK: C11H-22 background input (Validator T5.8, T2.8, T2.10)

    @MainActor private final class Starts {
        var hasSurface = false
        var count = 0
    }

    private func deferredPanel(_ name: String) -> (HCPanelSession, HCPanelAttachment, HCDisplayState, HCAdmissionWriter) {
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "owned", localAddress: name)
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        let writer = HCAdmissionWriter()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 3, displayGeneration: 1),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
        let port = HCPanelAttachment(panelID: panel, key: key, generation: 3,
            channel: HCAdmissionWriteChannel(writer), sink: HCAdmissionNoOutput(),
            rendering: HCUnavailableRenderingAdapter(), display: display, encoder: HCAdmissionEncoder(), report: { _ in })
        return (runtime, port, display, writer)
    }

    /// A panel that is not its area's visible tab never mounts its view, so its
    /// surface defers (noWindow) and nothing attaches it. Sends to it are the
    /// demand that starts it, as for a native terminal: both are written once,
    /// in order, and the panel is started once.
    func testSendsToAPanelWhoseSurfaceIsDeferredStartItAndAreDeliveredInOrder() async {
        let (runtime, port, display, writer) = deferredPanel("deferred")
        defer { port.detach() }
        let queue = HCInputReadyQueue(), state = State(), starts = Starts()
        let demandStart: @MainActor () -> Void = {
            guard HCInputReadyQueue.needsStart(runtime, current: runtime, hasNativeSurface: starts.hasSurface) else { return }
            starts.count += 1
            starts.hasSurface = true
            // The headless start creates the surface on a later main turn, and
            // its first attachment binds after the hc creation answers.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                XCTAssertTrue(runtime.bind(port, display: display.revision))
            }
        }
        func send(_ text: String) -> Task<HCInputOutcome, Never> {
            Task { @MainActor in
                await queue.submit(waitSeconds: 1, readiness: {
                    HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false)
                }, screenReady: nil, demandStart: demandStart) { attachment in
                    state.sent.append(text)
                    return await runtime.submitInput(HCInputRequest(operationID: UUID(), panelID: runtime.identity.panelID,
                        key: attachment.key, attachmentGeneration: attachment.generation, source: .socket,
                        payload: Data(text.utf8), submitReturn: true, screenGuard: nil, returnGuard: nil))
                }
            }
        }
        let first = send("tput cols")
        await until { queue.count == 1 }
        let second = send("echo two")
        await until { queue.count == 2 }

        let outcomes = [await first.value, await second.value]
        XCTAssertTrue(outcomes.allSatisfy(isWritten), "a deferred panel's sends are delivered: \(outcomes)")
        XCTAssertEqual(writer.received, Data("tput cols\r".utf8) + Data("echo two\r".utf8), "in order, each once")
        XCTAssertEqual(starts.count, 1, "started once")
    }

    func testOnlyAPanelThatNeverAttachedAndHasNoSurfaceIsStarted() {
        let (runtime, port, display, _) = deferredPanel("start-rule")
        defer { port.detach() }
        XCTAssertTrue(HCInputReadyQueue.needsStart(runtime, current: runtime, hasNativeSurface: false),
                      "a hidden tab's deferred panel starts")
        XCTAssertFalse(HCInputReadyQueue.needsStart(runtime, current: runtime, hasNativeSurface: true),
                       "a surface being created attaches on its own")
        let (replacement, other, _, _) = deferredPanel("start-rule-2")
        defer { other.detach() }
        XCTAssertFalse(HCInputReadyQueue.needsStart(runtime, current: replacement, hasNativeSurface: false),
                       "a retired runtime never starts the surface")
        XCTAssertTrue(runtime.bind(port, display: display.revision))
        XCTAssertFalse(HCInputReadyQueue.needsStart(runtime, current: runtime, hasNativeSurface: false),
                       "a panel that attached before reconnects; starting it would create a second terminal")
    }

    func testAReadyOrFailedPanelIsNeverAskedToStart() async {
        let queue = HCInputReadyQueue(), asks = Starts()
        let ready = await queue.submit(waitSeconds: 1, readiness: { .ready(self.attachment) }, screenReady: nil,
                                       demandStart: { asks.count += 1 }) { _ in self.written() }
        XCTAssertTrue(isWritten(ready))
        let failed = await queue.submit(waitSeconds: 1, readiness: { .failed(.unavailable) }, screenReady: nil,
                                        demandStart: { asks.count += 1 }) { _ in self.written() }
        guard case .refused(.unavailable) = failed else { return XCTFail("got \(failed)") }
        XCTAssertEqual(asks.count, 0, "only a terminal still waiting is asked to start")
    }

    // MARK: C11H-6 demand-start gaps

    /// A send's first start can be parked behind the restore gate or blocked
    /// before the grid exists. The waiting send asks again within its bound,
    /// so the second ask's start is the one that attaches.
    func testAWaitingSendAsksAgainWhenItsFirstStartWentNowhere() async {
        let (runtime, port, display, writer) = deferredPanel("reask")
        defer { port.detach() }
        let queue = HCInputReadyQueue(), asks = Starts()
        let outcome = await queue.submit(waitSeconds: 2, readiness: {
            HCInputReadyQueue.readiness(of: runtime, current: runtime, pendingBusy: false)
        }, screenReady: nil, demandStart: {
            asks.count += 1
            // The first ask is parked and goes nowhere; the second starts it.
            if asks.count == 2 { XCTAssertTrue(runtime.bind(port, display: display.revision)) }
        }) { attachment in
            await runtime.submitInput(HCInputRequest(operationID: UUID(), panelID: runtime.identity.panelID,
                key: attachment.key, attachmentGeneration: attachment.generation, source: .socket,
                payload: Data("echo reask".utf8), submitReturn: true, screenGuard: nil, returnGuard: nil))
        }
        XCTAssertTrue(isWritten(outcome), "delivered after the second ask: \(outcome)")
        XCTAssertEqual(asks.count, 2, "asked again once the first went nowhere, and not after it attached")
        XCTAssertEqual(writer.received, Data("echo reask\r".utf8))
    }

    /// Asking again is spaced, not once per 20 ms poll.
    func testAsksAgainAreSpacedAcrossTheBound() async {
        let queue = HCInputReadyQueue(), asks = Starts()
        let outcome = await queue.submit(waitSeconds: 0.6, readiness: { .waiting(.unavailable) }, screenReady: nil,
                                         demandStart: { asks.count += 1 }) { _ in self.written() }
        guard case .refused(.unavailable) = outcome else { return XCTFail("got \(outcome)") }
        // Entry, then about every 250 ms: 3 within 0.6 s (allow scheduling slack).
        XCTAssertGreaterThanOrEqual(asks.count, 2)
        XCTAssertLessThanOrEqual(asks.count, 4, "spaced, not every poll")
    }

    /// The restore gate opens: a parked start creates in place, restarts
    /// headless when its view left the window and the panel still needs a
    /// start, and otherwise is dropped with a log line, never silently.
    func testAParkedStartCreatesRestartsHeadlessOrIsLoggedNeverSilentlyLost() {
        typealias P = HCInputReadyQueue.ParkedStart
        let rows: [(alive: Bool, window: Bool, needs: Bool, want: P)] = [
            (true, true, true, .create), (true, true, false, .create),
            (true, false, true, .startHeadless), (true, false, false, .drop),
            (false, true, true, .drop), (false, false, true, .drop),
        ]
        for row in rows {
            XCTAssertEqual(HCInputReadyQueue.parkedStart(viewAlive: row.alive, inWindow: row.window, needsStart: row.needs),
                           row.want, "alive=\(row.alive) window=\(row.window) needs=\(row.needs)")
        }
    }

    func testHeldInputAsksItsDeferredPanelToStartOnce() {
        let (runtime, port, display, _) = deferredPanel("held")
        defer { port.detach() }
        let pending = HCPendingInput(), asks = Starts()
        let item = HCPendingInput.Item(text: "launch", submit: true, source: .textBox, screenGuard: nil,
                                       returnGuard: nil, completion: nil)
        pending.submit(item, runtime: runtime, panelID: runtime.identity.panelID, allowQueue: false,
                       demandStart: { asks.count += 1 })
        XCTAssertEqual(asks.count, 0, "refused input asks nothing")
        pending.submit(item, runtime: runtime, panelID: runtime.identity.panelID, allowQueue: true,
                       demandStart: { asks.count += 1 })
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(asks.count, 1, "held input asks its panel to start")
        XCTAssertTrue(runtime.bind(port, display: display.revision))
        pending.drain(runtime: runtime, panelID: runtime.identity.panelID)
        pending.submit(item, runtime: runtime, panelID: runtime.identity.panelID, allowQueue: true,
                       demandStart: { asks.count += 1 })
        XCTAssertEqual(asks.count, 1, "a bound panel sends at once and asks nothing")
    }
}

/// Holds the first encode until released, so a drained write keeps the port's
/// single programmatic slot while another submission becomes ready.
private actor HCFirstHeldEncoder: HCInputEncoder {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = 0
    nonisolated func maximumEncodedBytes(for request: HCInputRequest) -> Int? { request.payload.count + 1 + 18 }
    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        entered += 1
        if !held {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .success([.data(request.payload), .submitReturn(Data([13]))])
    }
    func release() { continuation?.resume(); continuation = nil }
    func enteredCount() -> Int { entered }
}

/// C11H-124 part 3: Retry input recovers a panel paused by an uncertain write,
/// driven through the runtime the way the native bridge drives it. The live
/// repro: keys refused as staleIdentity, the terminal reattached, then every key
/// refused as inputFault, and Retry input did nothing.
@MainActor
final class HCRetryInputRecoveryTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1v")

    private func display(_ generation: UInt64, _ displayGeneration: UInt64 = 1) -> HCDisplayState {
        HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation, displayGeneration: displayGeneration),
            grid: HCGridSize(columns: 80, rows: 24), facts: HCDisplayFacts(), focused: false)
    }

    private struct Harness {
        let runtime: HCPanelSession
        let policy: HCDisconnectedInput
        let reattaches: Counter
        let log: Lines
    }
    final class Counter { var value = 0 }
    final class Lines { var all: [String] = [] }

    private func harness() throws -> Harness {
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        let reattaches = Counter(), log = Lines()
        // The reconnect owner's side of a requested reattach; the test binds the
        // fresh port itself when it wants one to arrive.
        runtime.requestInputFaultReattach = { reattaches.value += 1 }
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        policy.retryLog = { log.all.append($0) }
        return Harness(runtime: runtime, policy: policy, reattaches: reattaches, log: log)
    }

    /// A port wired like the native bridge: its raw outcomes hop to the runtime.
    private func port(_ generation: UInt64, _ channel: any HCChannel, runtime: HCPanelSession,
                      rendering: any HCRenderingAdapter = HCAdmissionReceiptAdapter()) -> HCPanelAttachment {
        HCPanelAttachment(panelID: runtime.identity.panelID, key: key, generation: generation,
            channel: channel, sink: HCAdmissionNoOutput(), rendering: rendering, display: display(generation),
            encoder: HCAdmissionEncoder(), report: { [weak runtime] outcome in
                Task { @MainActor in runtime?.recordInputOutcome(outcome) }
            })
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func request(_ runtime: HCPanelSession, generation: UInt64, _ text: String) -> HCInputRequest {
        HCInputRequest(operationID: UUID(), panelID: runtime.identity.panelID, key: key,
            attachmentGeneration: generation, source: .socket, payload: Data(text.utf8), submitReturn: true)
    }

    /// The repro, up to the pause: a key in flight on port 3, the reattach (which
    /// refuses the next key as staleIdentity), port 4 bound, and the in-flight
    /// key's uncertain outcome landing after it. Then, optionally, keys typed while
    /// paused (each refused, none a new interruption).
    private func pauseAfterReattach(_ h: Harness, rendering: any HCRenderingAdapter = HCAdmissionReceiptAdapter(),
                                    typeWhilePaused: Bool = false) async throws -> (old: HCRetryTestChannel, fresh: HCRetryTestChannel, port: HCPanelAttachment) {
        let old = HCRetryTestChannel(holdWrites: true)
        let first = port(3, old, runtime: h.runtime)
        XCTAssertTrue(h.runtime.bind(first, display: display(3).revision))
        first.input.receiveRaw(Data("a".utf8), kind: .key, generation: 3)
        await settle { old.held }
        XCTAssertTrue(old.held, "the key never reached the wire")

        // The reattach cancels the held write, so its outcome is uncertain. That
        // outcome hops to main, and lands after port 4 is bound.
        h.runtime.prepareReattach()
        let fresh = HCRetryTestChannel(holdWrites: false)
        let second = port(4, fresh, runtime: h.runtime, rendering: rendering)
        XCTAssertTrue(h.runtime.bind(second, display: display(4).revision))
        guard case .refused(.staleIdentity) = await h.runtime.submitInput(request(h.runtime, generation: 3, "x")) else {
            XCTFail("a send stamped for the replaced port was not refused as staleIdentity")
            throw CancellationError()
        }
        await settle { h.policy.isFaulted }
        XCTAssertTrue(h.policy.isFaulted, "the late uncertain write did not pause the panel")
        guard case .interrupted(let receipt?) = h.policy.notice else {
            XCTFail("no interrupted notice: \(String(describing: h.policy.notice))")
            throw CancellationError()
        }
        XCTAssertEqual(receipt.attachmentGeneration, 3, "the uncertain write belongs to the replaced port")
        XCTAssertNotNil(h.runtime.inputFault)

        guard typeWhilePaused else { return (old, fresh, second) }
        for text in ["c", "d", "e"] { second.input.receiveRaw(Data(text.utf8), kind: .key, generation: 4) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(fresh.writes.isEmpty, "a key reached the shell while paused")
        return (old, fresh, second)
    }

    func testRetryRecoversAPauseFromAnUncertainWriteThatLandsAfterTheReattach() async throws {
        let h = try harness()
        let (old, fresh, second) = try await pauseAfterReattach(h, typeWhilePaused: true)
        defer { second.detach() }
        XCTAssertTrue(h.policy.canRetryInput, "port 4 is newer than the interrupted port 3: \(h.log.all)")

        let outcome = await h.policy.retryInputWaiting(seconds: 1)
        XCTAssertEqual(outcome, .recovered, "Retry input failed: \(h.log.all)")
        XCTAssertFalse(h.policy.isFaulted)
        XCTAssertNil(h.runtime.inputFault)
        XCTAssertNil(h.policy.retryFailure)
        XCTAssertEqual(h.reattaches.value, 0, "a pause from a replaced port needs no new reattach")
        XCTAssertTrue(fresh.writes.isEmpty, "retry replayed bytes or a Return")
        XCTAssertEqual(old.writes, [Data("a".utf8)], "the interrupted key was sent again")

        guard case .written = await h.runtime.submitInput(request(h.runtime, generation: 4, "ok")) else {
            return XCTFail("the recovered panel refused input")
        }
        XCTAssertEqual(fresh.writes, [Data("ok".utf8) + Data([13])])
    }

    /// The policy hears of display changes through a main-actor hop, so its copy
    /// can lag the port's. Retry reads the owner's current display.
    func testRetryRecoversWhenThePolicysDisplayLagsThePort() async throws {
        let h = try harness()
        let (_, fresh, second) = try await pauseAfterReattach(h)
        defer { second.detach() }
        let moved = display(4, 2)
        guard case .written = await second.updateDisplay(moved) else { return XCTFail("display update refused") }
        XCTAssertEqual(h.runtime.currentDisplayRevision, moved.revision)

        let recovered = await h.policy.retryInput()
        XCTAssertTrue(recovered, "Retry input failed on a lagging display: \(h.log.all)")
        XCTAssertFalse(h.policy.isFaulted)
        XCTAssertTrue(fresh.writes.isEmpty, "retry replayed bytes or a Return")
    }

    /// A write on the current port pauses it, so only a newer port can clear it.
    /// Retry says "reconnecting", asks for that port again, and recovers once it binds.
    func testAPauseOnTheCurrentPortSaysReconnectingUntilAFreshPortBinds() async throws {
        let h = try harness()
        let channel = HCRetryTestChannel(holdWrites: false, cutWritesShort: true)
        let current = port(4, channel, runtime: h.runtime)
        defer { current.detach() }
        XCTAssertTrue(h.runtime.bind(current, display: display(4).revision))
        guard case .uncertain = await h.runtime.submitInput(request(h.runtime, generation: 4, "long")) else {
            return XCTFail("expected an uncertain write")
        }
        XCTAssertEqual(h.reattaches.value, 1, "the pause asks for a fresh port")
        XCTAssertFalse(h.policy.canRetryInput)

        let outcome = await h.policy.retryInputWaiting(seconds: 0.2)
        XCTAssertEqual(outcome, .reconnecting)
        XCTAssertEqual(h.reattaches.value, 2, "Retry asks for the fresh port again")
        XCTAssertEqual(h.policy.retryFailure?.reason, .reconnecting)
        XCTAssertEqual(HCInputBarModel(h.policy)?.status,
                       "Retry failed: the terminal is still reconnecting.")
        XCTAssertTrue(h.log.all.contains { $0.contains("guard=policy.freshAttachment") && $0.contains("port=4 interrupted=4") },
                      "\(h.log.all)")

        let next = HCRetryTestChannel(holdWrites: false)
        let fresh = port(5, next, runtime: h.runtime)
        defer { fresh.detach() }
        XCTAssertTrue(h.runtime.bind(fresh, display: display(5).revision))
        let recovered = await h.policy.retryInputWaiting(seconds: 1)
        XCTAssertEqual(recovered, .recovered, "\(h.log.all)")
        XCTAssertTrue(next.writes.isEmpty, "retry replayed bytes or a Return")
    }

    /// A refused retry is never silent: the log names the panel, the guard and
    /// the values, and the bar names the reason in plain words.
    func testARefusedRetryReportsItsGuardToTheLogAndTheBar() async throws {
        let h = try harness()
        let (_, _, second) = try await pauseAfterReattach(h, rendering: HCRetryBlankScreen())
        defer { second.detach() }
        let recovered = await h.policy.retryInput()
        XCTAssertFalse(recovered)
        XCTAssertTrue(h.policy.isFaulted)
        let line = try XCTUnwrap(h.log.all.last)
        XCTAssertTrue(line.contains("panel=\(h.runtime.identity.panelID.uuidString)"), line)
        XCTAssertTrue(line.contains("guard=policy.screenUnavailable"), line)
        XCTAssertTrue(line.contains("display=4.1"), line)
        XCTAssertEqual(h.policy.retryFailure?.reason, .screenNotSettled)
        let bar = try XCTUnwrap(HCInputBarModel(h.policy))
        XCTAssertEqual(bar.status, "Retry failed: the screen did not settle.")

        // `c11 retry-input` answers with the same reason and names the guard.
        guard case .err(let code, let message, let data) = HCPausedInputGate.retryReply(.failed,
            refusal: h.policy.retryFailure, envelope: [:]) else { return XCTFail("a refused retry succeeded") }
        XCTAssertEqual(code, "hc_input_retry_failed")
        XCTAssertTrue(message.contains("the screen did not settle"), message)
        XCTAssertEqual((data as? [String: Any])?["guard"] as? String, "policy.screenUnavailable")
    }

    /// The port's own guards name themselves too.
    func testThePortNamesTheGuardThatRefusedAClear() {
        let gate = HCInputGeneration(panelID: UUID(), key: key, generation: 4)
        gate.invalidate(generation: 4, reason: .inputFault)
        let revision = HCDisplayRevision(attachmentGeneration: 4, displayGeneration: 1)
        let receipt = HCScreenReceipt(revision: revision, parsedOutputWatermark: 1, columns: 80, rows: 24)
        let token = gate.faultToken!
        let same = gate.clearFaultRefusal(receipt: receipt, expected: revision, interruptedGeneration: 4, faultToken: token)
        XCTAssertEqual(same?.check, "gate.freshGeneration")
        XCTAssertEqual(same?.values, "port=4 interrupted=4")
        XCTAssertEqual(same?.reason, .reconnecting)
        let stale = gate.clearFaultRefusal(receipt: receipt, expected: revision, interruptedGeneration: 3,
                                           faultToken: token &+ 1)
        XCTAssertEqual(stale?.check, "gate.faultToken")
        XCTAssertNil(gate.clearFaultRefusal(receipt: receipt, expected: revision, interruptedGeneration: 3,
                                            faultToken: token))
    }

    /// The bar: a warning role per state, its text, and one height in every state.
    func testTheInputBarModelHasAWarningRoleItsTextAndOneHeight() async throws {
        let h = try harness()
        XCTAssertNil(HCInputBarModel(h.policy), "no notice, no bar")
        h.policy.record(.refused(.queueFull))
        let refused = try XCTUnwrap(HCInputBarModel(h.policy))
        XCTAssertEqual(refused.role, .refused)
        XCTAssertFalse(refused.showsRetry)
        XCTAssertEqual(refused.status, "")
        XCTAssertEqual(refused.message, HCInputNotice.refused(.queueFull).message)

        let (_, _, second) = try await pauseAfterReattach(h, rendering: HCRetryBlankScreen())
        defer { second.detach() }
        let paused = try XCTUnwrap(HCInputBarModel(h.policy))
        XCTAssertEqual(paused.role, .paused)
        XCTAssertTrue(paused.showsRetry)
        XCTAssertTrue(paused.retryEnabled)
        XCTAssertEqual(paused.status, "")
        XCTAssertTrue(paused.message.hasPrefix("Input interrupted."), paused.message)
        XCTAssertNotEqual(paused.fill, refused.fill)
        XCTAssertNotEqual(paused.fill, Color(nsColor: .controlBackgroundColor))
        _ = await h.policy.retryInput()
        let failed = try XCTUnwrap(HCInputBarModel(h.policy))
        XCTAssertEqual(failed.status, "Retry failed: the screen did not settle.")
        XCTAssertEqual(HCInputBarModel.height, 64, "the bar's height is fixed")
    }
}

/// A rendering adapter whose parser never reports a current screen.
private struct HCRetryBlankScreen: HCRenderingAdapter {
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
    func noteOutput(_ chunk: HCOutputChunk) {}
    func didParse(_ chunk: HCOutputChunk) {}
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
}

/// A wire that records each written body, holds a write until it is cancelled
/// (which then reports what reached the wire as uncertain), or cuts bodies short.
final class HCRetryTestChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    private let lock = NSLock()
    private let holdWrites: Bool
    private let cutWritesShort: Bool
    private var written: [Data] = []
    private var heldWrite: (CheckedContinuation<HCInputOutcome, Never>, HCWriteReceipt)?
    private var holding = false

    init(holdWrites: Bool, cutWritesShort: Bool = false) {
        self.holdWrites = holdWrites
        self.cutWritesShort = cutWritesShort
    }
    var writes: [Data] { lock.lock(); defer { lock.unlock() }; return written }
    var held: Bool { lock.lock(); defer { lock.unlock() }; return holding }

    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        .reserved(HCWriteReservation(id: UUID(), operationID: operationID,
            attachmentGeneration: attachmentGeneration, connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        var body = Data()
        var returned = false
        for frame in batch.frames {
            switch frame {
            case .data(let bytes): body.append(bytes)
            case .submitReturn(let bytes), .submitReturnAfter(let bytes, delayNanoseconds: _):
                body.append(bytes); returned = true
            default: break
            }
        }
        if cutWritesShort {
            let part = body.prefix(1)
            lock.lock(); written.append(Data(part)); lock.unlock()
            return .uncertain(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                             bodyBytesWritten: part.count, returnWritten: false))
        }
        let receipt = HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                     bodyBytesWritten: body.count, returnWritten: returned)
        lock.lock(); written.append(body); lock.unlock()
        guard holdWrites else { return .written(receipt) }
        return await withCheckedContinuation { continuation in
            lock.lock(); heldWrite = (continuation, receipt); holding = true; lock.unlock()
        }
    }
    func cancel(_ reservation: HCWriteReservation) {
        lock.lock()
        let held = heldWrite
        heldWrite = nil
        lock.unlock()
        guard let (continuation, receipt) = held else { return }
        continuation.resume(returning: .uncertain(receipt))
    }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}
