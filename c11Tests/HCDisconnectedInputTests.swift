import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class HCDisconnectedInputTests: XCTestCase {
    func testDisconnectedRequestsAreRefusedAndNeverReplayed() async {
        let f = HCReconnectFixture()
        var notices: [HCInputNotice] = []
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true },
                                         changed: { if let notice = $0.notice { notices.append(notice) } })
        for source in [HCInputSource.socket, .textBox, .filePaste, .feed, .mailbox, .launchPrompt, .resume, .initial] {
            let result = await policy.submit(f.request(source: source))
            guard case .refused(.unavailable) = result else { return XCTFail("accepted disconnected source \(source)") }
        }
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertTrue(f.attachment.submissions.isEmpty)
        XCTAssertEqual(notices.count, 9) // Eight refusals and the retained notice on bind.
        // C11H-443: the file paste is the operator's; it was dropped, so the notice outlives
        // the bind.
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        XCTAssertTrue(policy.noticeIsOperators)
    }

    func testInterruptedCompleteBodyPreservesTransportReceiptAndRequiresNewAttachment() async {
        let f = HCReconnectFixture()
        let request = f.request()
        let receipt = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                     bodyBytesWritten: request.payload.count, returnWritten: false)
        f.attachment.submitHandler = { _ in .uncertain(receipt) }
        var resets = 0
        var reattachments = 0
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in resets += 1; return true },
                                         reattach: { reattachments += 1 })
        policy.bind(f.attachment, display: f.display(1))
        guard case .uncertain(let actual) = await policy.submit(request) else { return XCTFail("not uncertain") }
        XCTAssertEqual(actual, receipt)
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        XCTAssertEqual(reattachments, 1)
        XCTAssertFalse(policy.canRetryInput)
        let oldRetry = await policy.retryInput()
        XCTAssertFalse(oldRetry, "same attachment is not fresh after the fault")
        XCTAssertEqual(resets, 0)
        policy.disconnect()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        policy.bind(second, display: f.display(2))
        XCTAssertTrue(policy.isFaulted)
        XCTAssertTrue(policy.canRetryInput)
        XCTAssertEqual(second.port.invalidations, [.inputFault])
        let denied = await policy.submit(f.request(2))
        guard case .refused(.inputFault) = denied else { return XCTFail("fault was cleared by reattach") }
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        XCTAssertTrue(second.submissions.isEmpty)
        let retried = await policy.retryInput()
        XCTAssertTrue(retried)
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(second.submissions.isEmpty, "retry must never replay old body or Return")
        XCTAssertFalse(policy.isFaulted)
        XCTAssertNil(policy.notice)
        _ = await policy.submit(f.request(2))
        XCTAssertEqual(second.submissions.count, 1)
    }

    /// C11H-124: the pause an agent reads on a socket error names the commands that
    /// recover it. The operator's banner says "choose Retry input", which an agent
    /// cannot do.
    func testAPausedPanelsErrorTextNamesTheRecoveryCommands() {
        let ref = "panel:7"
        for notice in [HCInputNotice.refused(.inputFault), .interrupted(nil)] {
            let text = notice.agentMessage(panelRef: ref)
            XCTAssertTrue(text.contains("c11 retry-input --panel panel:7"), text)
            // The clearing key names the panel that was retried: without --panel it
            // would clear the caller's own prompt, and the half-typed line would stay.
            XCTAssertTrue(text.contains("c11 send-key --panel panel:7 ctrl+u"), text)
        }
        // Only the pause is rewritten; every other refusal keeps its own text.
        XCTAssertEqual(HCInputNotice.refused(.unavailable).agentMessage(panelRef: ref),
                       HCInputNotice.refused(.unavailable).message)
        XCTAssertEqual(HCInputNotice.refused(.guardRefused).agentMessage(panelRef: ref),
                       HCInputNotice.refused(.guardRefused).message)
    }

    /// C11H-124: `retry-input` cannot click. The pause asks for a fresh attachment,
    /// so the call waits for it, then clears the pause once without replaying.
    func testRetryInputWaitsForTheFreshAttachmentThenClearsThePauseOnce() async {
        let f = HCReconnectFixture()
        let request = f.request()
        let receipt = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                     bodyBytesWritten: request.payload.count, returnWritten: false)
        f.attachment.submitHandler = { _ in .uncertain(receipt) }
        var resets = 0
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission,
                                         resetFault: { _, _ in resets += 1; return true })
        var retryLines: [String] = []
        policy.retryLog = { retryLines.append($0) }
        policy.bind(f.attachment, display: f.display(1))
        let notPaused = await policy.retryInputWaiting(seconds: 0.2)
        XCTAssertEqual(notPaused, .notPaused)
        XCTAssertEqual(retryLines, ["retry refused panel=\(f.panelID.uuidString) guard=policy.notPaused reason=notPaused isFaulted=false"],
                       "a retry of a panel that is not paused must log its guard")
        XCTAssertNil(policy.retryFailure, "a panel that is not paused shows no failure line")
        _ = await policy.submit(request)
        XCTAssertTrue(policy.isFaulted)

        let waiting = Task { await policy.retryInputWaiting(seconds: 3) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        policy.disconnect()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        policy.bind(second, display: f.display(2))
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(resets, 1)
        XCTAssertFalse(policy.isFaulted)
        XCTAssertTrue(second.submissions.isEmpty, "retry never replays the interrupted input")
    }

    /// C11H-124 review: what the socket answers. A key to a paused panel is refused
    /// (it used to be reported sent), a retry on a panel that is not paused is
    /// refused (it used to succeed), and neither is a success the caller can act on.
    func testTheSocketRefusesKeysToAPausedPanelAndARetryOfAPanelThatIsNotPaused() async {
        let f = HCReconnectFixture()
        let request = f.request()
        f.attachment.submitHandler = { _ in
            .uncertain(HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                      bodyBytesWritten: request.payload.count, returnWritten: false))
        }
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission,
                                         resetFault: { _, _ in true })
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertNil(HCPausedInputGate.keyRefusal(policy: policy, panelRef: "panel:7"), "a healthy panel takes keys")
        XCTAssertNil(HCPausedInputGate.keyRefusal(policy: nil, panelRef: "panel:7"))
        _ = await policy.submit(request)
        guard case .err(let code, let message, _)? = HCPausedInputGate.keyRefusal(policy: policy, panelRef: "panel:7") else {
            return XCTFail("a key to a paused panel was accepted")
        }
        XCTAssertEqual(code, "hc_input_inputFault")
        XCTAssertTrue(message.contains("c11 retry-input --panel panel:7"), message)

        guard case .err(let notPausedCode, _, _) = HCPausedInputGate.retryReply(.notPaused, envelope: [:]) else {
            return XCTFail("retrying a panel that is not paused succeeded")
        }
        XCTAssertEqual(notPausedCode, "hc_input_not_paused")
        guard case .ok(let reply) = HCPausedInputGate.retryReply(.recovered, envelope: ["panel_id": "p"]),
              let fields = reply as? [String: Any] else { return XCTFail("recovered was not a success") }
        XCTAssertEqual(fields["recovered"] as? Bool, true)
        XCTAssertEqual(fields["panel_id"] as? String, "p")
        for (outcome, expected) in [(HCDisconnectedInput.RetryOutcome.reconnecting, "hc_input_unavailable"),
                                    (.failed, "hc_input_retry_failed")] {
            guard case .err(let c, _, _) = HCPausedInputGate.retryReply(outcome, envelope: [:]) else {
                return XCTFail("\(outcome) was a success")
            }
            XCTAssertEqual(c, expected)
        }
    }

    func testRetryInputSocketRequiresAnExplicitNonemptyTarget() async {
        let controller = TerminalController.makeForTesting()
        for target in [nil, "", " \n"] as [String?] {
            let code = await Task.detached {
                switch controller.v2PanelRetryInput(params: target.map { ["surface_id": $0] } ?? [:]) {
                case .err(let code, _, _): return code
                case .ok: return "unexpected_success"
                }
            }.value
            XCTAssertEqual(code, "invalid_params")
        }
    }

    func testCancelledRetryCannotClearAReadyPause() async {
        let f = HCReconnectFixture()
        var resets = 0
        let policy = HCDisconnectedInput(panelID: f.panelID,
            setAdmission: HCReconnectTestAttachment.setAdmission,
            resetFault: { _, _ in resets += 1; return true })
        policy.bind(f.attachment, display: f.display(1))
        policy.record(.refused(.inputFault))
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        policy.bind(second, display: f.display(2))
        XCTAssertTrue(policy.canRetryInput)
        // This actor does not yield until cancellation is set, modeling the
        // socket timeout winning before a waiting retry resumes on main.
        let retry = Task { @MainActor in await policy.retryInputWaiting(seconds: 3) }
        retry.cancel()
        let outcome = await retry.value
        XCTAssertEqual(outcome, .reconnecting)
        XCTAssertEqual(resets, 0)
        XCTAssertTrue(policy.isFaulted)
        XCTAssertTrue(second.submissions.isEmpty)
    }

    func testRetryInputGivesUpAsReconnectingWhenNoFreshAttachmentComes() async {
        let f = HCReconnectFixture()
        let request = f.request()
        f.attachment.submitHandler = { _ in
            .uncertain(HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                      bodyBytesWritten: request.payload.count, returnWritten: false))
        }
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission,
                                         resetFault: { _, _ in true })
        policy.bind(f.attachment, display: f.display(1))
        _ = await policy.submit(request)
        let outcome = await policy.retryInputWaiting(seconds: 0.3)
        XCTAssertEqual(outcome, .reconnecting)
        XCTAssertTrue(policy.isFaulted)
    }

    func testLateUncertaintyLatchesReplacementAndDoesNotReplay() async {
        let f = HCReconnectFixture()
        let gate = HCReconnectTestGate<HCInputOutcome>()
        f.attachment.submitHandler = { _ in await gate.wait() }
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true })
        policy.bind(f.attachment, display: f.display(1))
        let request = f.request()
        let task = Task { await policy.submit(request) }
        await eventually { f.attachment.submissions.count == 1 }
        policy.disconnect()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        policy.bind(second, display: f.display(2))
        let replacementResult = await policy.submit(f.request(2))
        if case .refused(.unavailable) = replacementResult {} else {
            XCTFail("replacement admitted input before the previous write settled")
        }
        XCTAssertTrue(second.submissions.isEmpty)
        XCTAssertFalse(policy.isFaulted, "an outstanding write is not uncertainty")
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        second.port.receiveRaw(Data("new raw key".utf8), kind: .key, generation: 2)
        second.port.receiveRaw(Data("new raw paste".utf8), kind: .paste, generation: 2)
        XCTAssertTrue(second.port.rawWrites.isEmpty)
        XCTAssertFalse(second.port.isAdmitted)
        let receipt = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                     bodyBytesWritten: 4, returnWritten: false)
        await gate.release(.uncertain(receipt))
        if case .uncertain(let actual) = await task.value { XCTAssertEqual(actual, receipt) }
        else { XCTFail("changed the old transport outcome") }
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        XCTAssertEqual(second.port.invalidations, [.inputFault])
        XCTAssertTrue(second.submissions.isEmpty)
    }

    func testReplacementWaitsForEveryOldOutcomeWhileSameAttachmentStaysOpen() async {
        for uncertainFirst in [false, true] {
            let f = HCReconnectFixture()
            let firstRequest = f.request()
            let otherRequest = f.request()
            let firstGate = HCReconnectTestGate<HCInputOutcome>()
            let otherGate = HCReconnectTestGate<HCInputOutcome>()
            f.attachment.submitHandler = { request in
                if request.operationID == firstRequest.operationID { return await firstGate.wait() }
                return await otherGate.wait()
            }
            let policy = HCDisconnectedInput(panelID: f.panelID,
                setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true })
            policy.bind(f.attachment, display: f.display(1))
            let first = Task { await policy.submit(firstRequest) }
            await eventually { f.attachment.submissions.count == 1 }
            policy.bind(f.attachment, display: f.display(1))
            let other = Task { await policy.submit(otherRequest) }
            await eventually { f.attachment.submissions.count == 2 }
            f.attachment.port.receiveRaw(Data([65]), kind: .key, generation: 1)
            XCTAssertEqual(f.attachment.port.rawWrites, [Data([65])], "same-port backlog is still admitted")

            policy.disconnect()
            let second = HCReconnectTestAttachment(key: f.key, generation: 2)
            policy.bind(second, display: f.display(2))
            let receipt = HCWriteReceipt(operationID: firstRequest.operationID, attachmentGeneration: 1,
                bodyBytesWritten: firstRequest.payload.count, returnWritten: !uncertainFirst)
            await firstGate.release(uncertainFirst ? .uncertain(receipt) : .written(receipt))
            _ = await first.value
            XCTAssertFalse(second.port.isAdmitted, "one unresolved outcome still holds the replacement closed")
            XCTAssertFalse(policy.canRetryInput)
            let prematureRetry = await policy.retryInput()
            XCTAssertFalse(prematureRetry)
            let denied = await policy.submit(f.request(2))
            if case .refused(.unavailable) = denied {} else { XCTFail("admitted before every old outcome") }
            XCTAssertTrue(second.submissions.isEmpty)
            XCTAssertEqual(policy.isFaulted, uncertainFirst)

            await otherGate.release(.written(HCWriteReceipt(operationID: otherRequest.operationID,
                attachmentGeneration: 1, bodyBytesWritten: otherRequest.payload.count, returnWritten: true)))
            _ = await other.value
            XCTAssertEqual(second.port.isAdmitted, !uncertainFirst)
            if uncertainFirst {
                XCTAssertEqual(policy.notice, .interrupted(receipt))
                XCTAssertTrue(policy.canRetryInput)
                XCTAssertEqual(second.port.invalidations, [.inputFault])
                let retried = await policy.retryInput()
                XCTAssertTrue(retried)
                XCTAssertTrue(second.port.isAdmitted, "explicit successful retry releases admission")
            } else {
                let result = await policy.submit(f.request(2))
                if case .written = result {} else { XCTFail("successful handoff never reopened") }
                second.port.receiveRaw(Data([66]), kind: .key, generation: 2)
                XCTAssertEqual(second.port.rawWrites, [Data([66])])
                XCTAssertTrue(second.port.invalidations.isEmpty)
            }
        }
    }

    func testDisconnectDiscardsStagedBindingBeforeOldOutcomeReturns() async {
        for replaceAgain in [false, true] {
            let f = HCReconnectFixture()
            let gate = HCReconnectTestGate<HCInputOutcome>()
            f.attachment.submitHandler = { _ in await gate.wait() }
            let policy = HCDisconnectedInput(panelID: f.panelID,
                setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true })
            policy.bind(f.attachment, display: f.display(1))
            let task = Task { await policy.submit(f.request()) }
            await eventually { f.attachment.submissions.count == 1 }
            policy.disconnect()
            let second = HCReconnectTestAttachment(key: f.key, generation: 2)
            policy.bind(second, display: f.display(2))
            policy.disconnect()
            let third = HCReconnectTestAttachment(key: f.key, generation: 3)
            if replaceAgain { policy.bind(third, display: f.display(3)) }
            await gate.release(.refused(.unavailable))
            _ = await task.value
            XCTAssertFalse(second.port.isAdmitted, "a retired staged binding must stay closed")
            let result = await policy.submit(f.request(replaceAgain ? 3 : 2))
            if replaceAgain {
                if case .written = result {} else { XCTFail("latest replacement did not open") }
                XCTAssertTrue(third.port.isAdmitted)
            } else {
                if case .refused(.unavailable) = result {} else { XCTFail("disconnected binding resurrected") }
            }
            XCTAssertTrue(second.submissions.isEmpty)
            XCTAssertFalse(policy.isFaulted)
        }
    }

    func testRetryRejectsMissingOrWrongGenerationOrWrongGridReceipt() async {
        for kind in 0..<3 {
            let f = HCReconnectFixture()
            let second = HCReconnectTestAttachment(key: f.key, generation: 2)
            var resets = 0
            let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in resets += 1; return true })
            policy.bind(f.attachment, display: f.display(1))
            policy.record(.refused(.inputFault))
            policy.bind(second, display: f.display(2))
            second.screenHandler = { revision in
                if kind == 0 { return nil }
                return HCScreenReceipt(
                    revision: kind == 1 ? f.display(1).revision : revision,
                    parsedOutputWatermark: 10, columns: kind == 2 ? 79 : 80, rows: 24)
            }
            let result = await policy.retryInput()
            XCTAssertFalse(result)
            XCTAssertTrue(policy.isFaulted)
            XCTAssertEqual(resets, 0)
        }
    }

    func testOldRetryCannotClearNewFault() async {
        let f = HCReconnectFixture()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        let gate = HCReconnectTestGate<HCScreenReceipt?>()
        var checkingScreen = false
        var resets = 0
        second.screenHandler = { _ in checkingScreen = true; return await gate.wait() }
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in resets += 1; return true })
        policy.bind(f.attachment, display: f.display(1))
        policy.record(.refused(.inputFault))
        policy.bind(second, display: f.display(2))
        let retry = Task { await policy.retryInput() }
        await eventually { checkingScreen }
        let newer = HCWriteReceipt(operationID: UUID(), attachmentGeneration: 2, bodyBytesWritten: 7, returnWritten: false)
        policy.record(.uncertain(newer))
        await gate.release(HCScreenReceipt(revision: f.display(2).revision, parsedOutputWatermark: 9, columns: 80, rows: 24))
        let result = await retry.value
        XCTAssertFalse(result)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(policy.notice, .interrupted(newer))
        XCTAssertTrue(policy.isFaulted)
    }

    func testRetryCannotClearAfterDisconnectOrDisplayChange() async {
        for changeDisplay in [false, true] {
            let f = HCReconnectFixture()
            let second = HCReconnectTestAttachment(key: f.key, generation: 2)
            let gate = HCReconnectTestGate<HCScreenReceipt?>()
            var checkingScreen = false
            var resets = 0
            second.screenHandler = { _ in checkingScreen = true; return await gate.wait() }
            let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in resets += 1; return true })
            policy.bind(f.attachment, display: f.display(1))
            policy.record(.refused(.inputFault))
            policy.bind(second, display: f.display(2))
            let retry = Task { await policy.retryInput() }
            await eventually { checkingScreen }
            if changeDisplay {
                policy.updateDisplay(HCDisplayState(
                    revision: HCDisplayRevision(attachmentGeneration: 2, displayGeneration: 2),
                    grid: HCGridSize(columns: 100, rows: 30)))
            } else { policy.disconnect() }
            await gate.release(HCScreenReceipt(revision: f.display(2).revision, parsedOutputWatermark: 9, columns: 80, rows: 24))
            let result = await retry.value
            XCTAssertFalse(result)
            XCTAssertEqual(resets, 0)
            XCTAssertTrue(policy.isFaulted)
        }
    }

    func testStaleRequestNeverReachesPortAndQueueRefusalStaysVisible() async {
        let f = HCReconnectFixture()
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in false })
        policy.bind(f.attachment, display: f.display(1))
        let result = await policy.submit(f.request(99))
        guard case .refused(.staleIdentity) = result else { return XCTFail("stale request accepted") }
        XCTAssertTrue(f.attachment.submissions.isEmpty)
        f.attachment.submitHandler = { _ in .refused(.queueFull) }
        let full = await policy.submit(f.request())
        guard case .refused(.queueFull) = full else { return XCTFail("lost queue refusal") }
        XCTAssertEqual(policy.notice, .refused(.queueFull))
        XCTAssertFalse(policy.isFaulted)
        policy.dismissRefusal()
        XCTAssertNil(policy.notice)
    }

    func testAlreadyWrittenReturnIsReportedTruthfully() async {
        let f = HCReconnectFixture()
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true })
        let receipt = HCWriteReceipt(operationID: UUID(), attachmentGeneration: 1, bodyBytesWritten: 12, returnWritten: true)
        policy.record(.uncertain(receipt))
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        policy.dismissRefusal()
        XCTAssertEqual(policy.notice, .interrupted(receipt))
    }

    func testOpenWriteDelayedBeyondPathfinderBacklogStaysPending() async throws {
        let f = HCReconnectFixture()
        let gate = HCReconnectTestGate<HCInputOutcome>()
        f.attachment.submitHandler = { _ in await gate.wait() }
        var reattachments = 0
        var returned = false
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in true },
                                         reattach: { reattachments += 1 })
        policy.bind(f.attachment, display: f.display(1))
        let request = f.request()
        let sending = Task { let result = await policy.submit(request); returned = true; return result }
        await eventually { f.attachment.submissions.count == 1 }
        // Pathfinder observed 7–16 seconds through hc itself. Input policy owns
        // no clock and no timer, so only the transport's answer may settle the
        // write. A short real wait proves an in-flight write is not settled by
        // elapsed time alone (C11H-30: tests stay inside the 30 s run budget).
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(returned, "elapsed time is not a transport outcome")
        XCTAssertFalse(policy.isFaulted)
        XCTAssertNil(policy.notice)
        XCTAssertEqual(reattachments, 0)
        XCTAssertTrue(f.attachment.port.invalidations.isEmpty)
        let receipt = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                     bodyBytesWritten: request.payload.count, returnWritten: true)
        await gate.release(.written(receipt))
        guard case .written(let actual) = await sending.value else { return XCTFail("slow open write became a disconnect") }
        XCTAssertEqual(actual, receipt)
        XCTAssertEqual(f.attachment.submissions.count, 1)
        XCTAssertNil(policy.notice)
        XCTAssertFalse(policy.isFaulted)
    }

    func testAsyncResetCannotClearNewFaultDisconnectOrDisplayChange() async {
        for change in 0..<3 {
            let f = HCReconnectFixture()
            let second = HCReconnectTestAttachment(key: f.key, generation: 2)
            let gate = HCReconnectTestGate<Bool>()
            var resetting = false
            let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in
                resetting = true
                return await gate.wait()
            })
            policy.bind(f.attachment, display: f.display(1))
            policy.record(.refused(.inputFault))
            policy.bind(second, display: f.display(2))
            let retry = Task { await policy.retryInput() }
            await eventually { resetting }
            XCTAssertTrue(policy.isRetrying)
            XCTAssertFalse(policy.canRetryInput)
            let duplicate = await policy.retryInput()
            XCTAssertFalse(duplicate)
            if change == 0 {
                policy.record(.uncertain(HCWriteReceipt(operationID: UUID(), attachmentGeneration: 2,
                                                       bodyBytesWritten: 3, returnWritten: false)))
            } else if change == 1 {
                policy.disconnect()
            } else {
                policy.updateDisplay(HCDisplayState(
                    revision: HCDisplayRevision(attachmentGeneration: 2, displayGeneration: 2),
                    grid: HCGridSize(columns: 100, rows: 30)))
            }
            let retainedNotice = policy.notice
            await gate.release(true)
            let result = await retry.value
            XCTAssertFalse(result)
            XCTAssertTrue(policy.isFaulted)
            XCTAssertFalse(policy.isRetrying)
            XCTAssertEqual(policy.notice, retainedNotice)
            XCTAssertTrue(second.submissions.isEmpty)
        }
    }

    func testLateOldReceiptCannotMakeFaultedCurrentAttachmentFresh() async {
        let f = HCReconnectFixture()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        var resets = 0
        let policy = HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission, resetFault: { _, _ in resets += 1; return true })
        policy.bind(second, display: f.display(2))
        policy.record(.uncertain(HCWriteReceipt(operationID: UUID(), attachmentGeneration: 2,
                                               bodyBytesWritten: 3, returnWritten: false)))
        // A completion from the previous reader arrives after the current
        // generation has itself faulted. It cannot make generation 2 fresh.
        policy.record(.uncertain(HCWriteReceipt(operationID: UUID(), attachmentGeneration: 1,
                                               bodyBytesWritten: 7, returnWritten: false)))
        XCTAssertFalse(policy.canRetryInput)
        let staleRetry = await policy.retryInput()
        XCTAssertFalse(staleRetry)
        XCTAssertEqual(resets, 0)
        XCTAssertTrue(policy.isFaulted)
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertFalse(policy.canRetryInput, "an older attachment is not a fresh replacement either")
        let olderRetry = await policy.retryInput()
        XCTAssertFalse(olderRetry)
        XCTAssertEqual(resets, 0)
        let third = HCReconnectTestAttachment(key: f.key, generation: 3)
        policy.bind(third, display: f.display(3))
        XCTAssertTrue(policy.canRetryInput)
        let freshRetry = await policy.retryInput()
        XCTAssertTrue(freshRetry)
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(third.submissions.isEmpty)
    }

    // MARK: C11H-443: the reconnect bar is for input someone made

    /// A clock and a panel's last operator key, both set by the test; `reads` counts every
    /// time the policy asks for the key.
    private final class OperatorClock {
        var now = Date(timeIntervalSince1970: 1_000)
        var lastKey: Date?
        var reads = 0
        func tick() { now = now.addingTimeInterval(1) }
        func key() { tick(); lastKey = now }
    }

    private func makePolicy(_ f: HCReconnectFixture, _ clock: OperatorClock) -> HCDisconnectedInput {
        HCDisconnectedInput(panelID: f.panelID, setAdmission: HCReconnectTestAttachment.setAdmission,
                            resetFault: { _, _ in true }, lastOperatorKey: { clock.reads += 1; return clock.lastKey },
                            clock: { clock.now })
    }

    private func written(_ generation: UInt64 = 1) -> HCInputOutcome {
        .written(HCWriteReceipt(operationID: UUID(), attachmentGeneration: generation, bodyBytesWritten: 3, returnWritten: false))
    }

    /// Ghostty's own query replies and reports reach the policy through the native write
    /// callback that carries keys, told apart by their shape. Refused while the panel
    /// reconnects with no key pressed, they raise no bar. A key binding can send the same
    /// shapes, so a key pressed since the close makes such a refusal the operator's.
    func testAReportShapedWriteRaisesNoBarUnlessTheOperatorPressedAKey() {
        let f = HCReconnectFixture()
        let clock = OperatorClock()
        let policy = makePolicy(f, clock)
        clock.tick()
        policy.record(.refused(.unavailable), from: .terminal)
        policy.record(.refused(.staleIdentity), from: .terminal)
        XCTAssertNil(policy.notice, "a launch's size and colour reports raise no bar")

        policy.bind(f.attachment, display: f.display(1))
        clock.key()
        clock.tick()
        policy.disconnect()
        clock.tick()
        policy.record(.refused(.unavailable), from: .terminal)
        XCTAssertNil(policy.notice, "a key pressed before the reconnect does not make a report the operator's")

        clock.key()
        policy.record(.refused(.unavailable), from: .terminal)
        XCTAssertEqual(policy.notice, .refused(.unavailable), "a binding pressed now that sends `CSI 0 n` was dropped")
        XCTAssertTrue(policy.noticeIsOperators)
    }

    /// A keystroke-shaped native write is the operator's only when they pressed a key after the
    /// panel stopped taking input. Without one (Dictation, an accessibility client, send-key)
    /// the bar still rises, as a program's, and clears on bind.
    func testAKeystrokeNativeWriteIsTheOperatorsOnlyAfterAKeySinceTheClose() {
        let f = HCReconnectFixture()
        let clock = OperatorClock()
        let policy = makePolicy(f, clock)
        policy.bind(f.attachment, display: f.display(1))
        clock.key()
        policy.record(written(), from: .native)
        clock.tick()
        policy.disconnect()
        clock.tick()
        policy.record(.refused(.unavailable), from: .native)
        XCTAssertEqual(policy.notice, .refused(.unavailable), "an unattributed keystroke still shows the bar")
        XCTAssertFalse(policy.noticeIsOperators, "a key typed before the reconnect is not what was refused")
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertNil(policy.notice, "nobody's keys: it clears once input works")

        // A second disconnect for the same loss keeps the first close time.
        clock.tick()
        policy.disconnect()
        clock.key()
        clock.tick()
        policy.disconnect()
        clock.tick()
        policy.record(.refused(.unavailable), from: .native)
        XCTAssertTrue(policy.noticeIsOperators, "a key typed between the two disconnects was dropped")
    }

    /// A refused reconnect notice no operator input raised clears when the panel binds a
    /// fresh attachment, or, recorded after the bind, at the next write that goes through.
    func testAProgramsRefusedReconnectNoticeClearsOnBind() async {
        let f = HCReconnectFixture()
        let clock = OperatorClock()
        let policy = makePolicy(f, clock)
        for source in [HCInputSource.socket, .textBox, .mailbox, .feed] {
            let result = await policy.submit(f.request(source: source))
            guard case .refused(.unavailable) = result else { return XCTFail("accepted disconnected \(source)") }
        }
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        XCTAssertFalse(policy.noticeIsOperators)
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertNil(policy.notice, "nothing left to say once input works")

        policy.record(.refused(.unavailable), from: .program)
        XCTAssertEqual(policy.notice, .refused(.unavailable), "a refusal recorded after the bind")
        policy.record(written(), from: .terminal)
        XCTAssertNil(policy.notice, "a write went through: input works")

        // A pause stays latched through a bind.
        let request = f.request()
        let receipt = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: 1,
                                     bodyBytesWritten: 4, returnWritten: false)
        f.attachment.submitHandler = { _ in .uncertain(receipt) }
        _ = await policy.submit(request)
        policy.disconnect()
        policy.bind(HCReconnectTestAttachment(key: f.key, generation: 2), display: f.display(2))
        XCTAssertEqual(policy.notice, .interrupted(receipt))
        XCTAssertTrue(policy.isFaulted)
    }

    /// Keys the operator typed into a reconnecting panel really were dropped, so their bar
    /// outlives the bind. Only their own input going through clears it: a keystroke-shaped
    /// write or their paste. A report, a program's send, an unclassified write, or a key
    /// consumed locally (copy mode moves the key stamp and writes nothing) leave it, and no
    /// write that goes through ever reads the key stamp.
    func testTheOperatorsReconnectNoticeOutlivesBindUntilTheirNextWriteGoesThrough() {
        let f = HCReconnectFixture()
        let clock = OperatorClock()
        let policy = makePolicy(f, clock)
        clock.key()
        policy.record(.refused(.unavailable), from: .keystroke)
        clock.tick()
        policy.record(.refused(.unavailable), from: .program)
        XCTAssertTrue(policy.noticeIsOperators, "a program's refusal keeps the operator's notice theirs")
        clock.tick()
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertEqual(policy.notice, .refused(.unavailable), "the operator's dropped keys outlive the bind")

        let reads = clock.reads
        clock.key() // consumed locally: the stamps move, nothing is written
        policy.record(written(), from: .terminal)
        policy.record(written(), from: .program)
        policy.record(written(), from: .native)
        XCTAssertEqual(policy.notice, .refused(.unavailable), "none of these is the operator's own write")
        policy.record(written(), from: .keystroke)
        XCTAssertNil(policy.notice, "the operator's keystroke went through")
        XCTAssertFalse(policy.noticeIsOperators)
        XCTAssertEqual(clock.reads, reads, "a write that goes through never reads the key stamp")

        // A paste refused while reconnecting is theirs too; their next paste clears it.
        policy.disconnect()
        policy.record(.refused(.unavailable), from: .operatorInput)
        policy.bind(f.attachment, display: f.display(1))
        XCTAssertTrue(policy.noticeIsOperators)
        policy.record(written(), from: .program)
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        policy.record(written(), from: .operatorInput)
        XCTAssertNil(policy.notice, "their paste went through")
    }

    /// C11H-443, the production wiring. Refused bytes go from Ghostty's write callback
    /// (`HCNativeInputContext.receive`) through the unbound context, then through the bound but
    /// unadmitted port every attach starts with, through the runtime to the policy. Once it binds,
    /// successful writes take the same road, classified while the operator's notice is up.
    func testNativeBytesReachThePolicyThroughTheRealCallbacks() async throws {
        let f = HCReconnectFixture()
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: f.panelID, key: f.key, persistence: .persistent,
            origin: .fresh), session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.installReconnectPolicy()
        var lastKey: Date?
        var keyReads = 0
        runtime.lastOperatorKey = { keyReads += 1; return lastKey }
        let policy = try XCTUnwrap(runtime.disconnectedInput)
        var recorded: [HCInputAttribution] = []
        let deliver = runtime.onInputOutcome
        runtime.onInputOutcome = { outcome, attribution in recorded.append(attribution); deliver?(outcome, attribution) }
        let bridge = HCNativeBridge.reporting(to: runtime, panelID: f.panelID,
            rendering: HCUnavailableRenderingAdapter(), encoder: HCUnavailableInputEncoder())
        bridge.installProcessor(process: { _ in }, removeFromUse: {}, destroy: {})
        XCTAssertTrue(bridge.prepare(generation: 1))
        func type(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { bridge.context.receive($0.baseAddress!, count: $0.count) }
            }
        }
        let sizeReport = "\u{1b}[48;24;80;600;960t"

        // Before the attach binds the port, the context refuses.
        type(sizeReport)
        await eventually { recorded.count == 1 }
        XCTAssertEqual(recorded.last, .terminal)
        XCTAssertNil(policy.notice, "Ghostty's size report raises no bar")

        // Bound to the context, not yet admitted: how every attach starts.
        let channel = HCRetryTestChannel(holdWrites: false)
        let display = f.display(1)
        let attachment = try await HCBackendComposition.makeAttachment(key: f.key, generation: 1, channel: channel,
                                                                 sink: bridge, display: display)
        type("\u{1b}[?997;2n")
        await eventually { recorded.count == 2 }
        XCTAssertEqual(recorded.last, .terminal)
        XCTAssertNil(policy.notice, "the closed port's refusal of a colour report raises no bar")

        // A key binding pressed now that sends a report shape is the operator's.
        lastKey = Date()
        type("\u{1b}[0n")
        await eventually { recorded.count == 3 }
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        XCTAssertTrue(policy.noticeIsOperators)

        // The panel binds: the bar stays, and only the operator's own keystroke clears it.
        XCTAssertTrue(runtime.bind(attachment, display: display.revision))
        XCTAssertEqual(policy.notice, .refused(.unavailable))
        let readsBeforeWrites = keyReads
        lastKey = Date() // a key consumed locally moves the stamp and writes nothing
        type(sizeReport)
        await eventually { recorded.count == 4 }
        XCTAssertEqual(recorded.last, .terminal)
        XCTAssertEqual(policy.notice, .refused(.unavailable), "Ghostty's report going through is not the operator typing")
        type("x")
        await eventually { recorded.count == 5 }
        XCTAssertEqual(recorded.last, .keystroke)
        XCTAssertNil(policy.notice, "the operator's keystroke went through")
        XCTAssertEqual(keyReads, readsBeforeWrites, "a write that went through never read the key stamp")
        XCTAssertEqual(channel.writes.count, 2)

        // With no notice up, a write goes through unclassified, as before.
        type("y")
        await eventually { recorded.count == 6 }
        XCTAssertEqual(recorded.last, .native)
        attachment.detach()
    }

    /// The refused-write log names a sequence's shape and never the text typed: a kitty-
    /// encoded key carries its character in its parameters, which are left out.
    func testRefusedNativeWritesAreLoggedByClassWithoutTheirText() {
        func describe(_ text: String) -> String {
            Array(text.utf8).withUnsafeBytes { HCRawInputClass.describe($0) }
        }
        XCTAssertEqual(describe("\u{1b}[?62;22c"), "csi?c")
        XCTAssertEqual(describe("\u{1b}[>1;10;0c"), "csi>c")
        XCTAssertEqual(describe("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\"), "osc11")
        XCTAssertEqual(describe("\u{1b}[48;24;80;600;960t"), "csi48t")
        XCTAssertEqual(describe("\u{1b}[?2004;2$y"), "csi?$y")
        XCTAssertEqual(describe("\u{1b}P>|ghostty 1.2\u{1b}\\"), "dcs>|")
        XCTAssertEqual(describe("\u{1b}[I"), "csiI")
        XCTAssertEqual(describe("\u{1b}[97;5u"), "csiu")
        XCTAssertEqual(describe("\u{1b}OP"), "ss3P")
        XCTAssertEqual(describe("\u{1b}x"), "esc+")
        XCTAssertEqual(describe("hunter2"), "text")
        XCTAssertEqual(describe("\r"), "ctl")
        XCTAssertEqual(describe("\u{1b}[12"), "csi~partial")

        func report(_ text: String) -> Bool {
            Array(text.utf8).withUnsafeBytes { HCRawInputClass.isTerminalReport($0) }
        }
        for reply in ["\u{1b}[?62;22c", "\u{1b}[>1;10;0c", "\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\",
                      "\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{07}", "\u{1b}[48;24;80;600;960t", "\u{1b}[?997;2n",
                      "\u{1b}[0n", "\u{1b}[?2004;2$y", "\u{1b}[?1u", "\u{1b}P>|ghostty 1.2\u{1b}\\", "\u{1b}[I",
                      "\u{1b}[O", "\u{1b}[12;40R", "\u{1b}[48;24;80;600;960t\u{1b}[?997;2n"] {
            XCTAssertTrue(report(reply), "\(Array(reply.utf8)) is Ghostty's own")
        }
        for key in ["a", "hunter2", "\r", "\u{1b}", "\u{1b}x", "\u{1b}[A", "\u{1b}OP", "\u{1b}[97;5u",
                    "\u{1b}[1;5R", "\u{1b}[15~", "\u{1b}[<0;10;5M", "\u{1b}[Z", "\u{1b}[12", "\u{1b}]",
                    "\u{1b}[?62;22cx", "\u{1b}]11;rgb:1e1e"] {
            XCTAssertFalse(report(key), "\(Array(key.utf8)) could be a key")
        }
        XCTAssertEqual(Array("\u{1b}[0n".utf8).withUnsafeBytes { HCRawInputClass.attribution($0) }, .terminal)
        XCTAssertEqual(Array("x".utf8).withUnsafeBytes { HCRawInputClass.attribution($0) }, .keystroke)
    }
}
