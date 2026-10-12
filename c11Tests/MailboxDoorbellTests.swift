import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Ring decision for C11-394. No PTY and no Workspace: every guard is an
/// input on `MailboxDoorbell.decide`.
final class MailboxDoorbellTests: XCTestCase {

    private func entry(
        id: String,
        block: String = "<c11-msg/>"
    ) -> MailboxStdinBuffer.Entry {
        MailboxStdinBuffer.Entry(
            id: id,
            recipientName: "watcher",
            block: block,
            bufferedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func openGate() -> MailboxStdinDelivery.Gate {
        MailboxStdinDelivery.Gate(isAgentKind: true, ownsTerminal: true)
    }

    private func openPrompt(_ state: MailboxStdinBufferStore, _ surface: UUID) {
        state.buffer.noteAgentTurn(
            surfaceId: surface,
            atPrompt: true,
            at: Date(timeIntervalSince1970: 10)
        )
    }

    private func admit(
        state: MailboxStdinBufferStore,
        surfaceId: UUID,
        id: String = "env-1",
        gate: MailboxStdinDelivery.Gate? = nil,
        ring: ((Bool) -> MailboxDoorbell.Input)? = nil,
        note: ((MailboxDoorbell.Decision, MailboxDoorbell.Arrival) -> Void)? = nil,
        push: @escaping (String?) -> Void = { _ in }
    ) -> MailboxStdinDelivery.AdmitResult {
        MailboxStdinDelivery.deliver(
            state: state,
            surfaceId: surfaceId,
            entry: entry(id: id),
            gate: gate ?? openGate(),
            logEvicted: { _ in },
            push: push,
            ringInput: ring,
            noteRing: note
        )
    }

    // MARK: - Prompt

    func testEmptyAndSuggestionRing() {
        XCTAssertEqual(MailboxDoorbell.decide(MailboxDoorbell.Input()), .ring)
        var suggestion = MailboxDoorbell.Input()
        suggestion.prompt = .suggestion
        XCTAssertEqual(MailboxDoorbell.decide(suggestion), .ring)
        XCTAssertTrue(FeedAnswerPromptCommit.admits(.empty))
        XCTAssertTrue(FeedAnswerPromptCommit.admits(.suggestion))
    }

    func testDraftDialogUnknownAndUnavailableDoNotRing() {
        let refused: [(PromptInputState, String)] = [
            (.draft, "draft"),
            (.dialog, "dialog"),
            (.unknown, "unknown_prompt"),
            (.unavailable, "unavailable"),
        ]
        for (state, reason) in refused {
            XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
            XCTAssertEqual(FeedAnswerPromptCommit.refusalReason(state), reason)
            var input = MailboxDoorbell.Input()
            input.prompt = state
            XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: reason))
            XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: reason)), .keep(reason: reason))
        }
        var missing = MailboxDoorbell.Input()
        missing.prompt = nil
        XCTAssertEqual(MailboxDoorbell.decide(missing), .skip(reason: "unavailable"))
    }

    func testInvitationIsTheFixedSentenceWithoutANewline() {
        XCTAssertEqual(
            MailboxDoorbell.text,
            "You have mail: run c11 mailbox recv --ack when you want to receive it."
        )
        XCTAssertNil(FeedAnswerTextPolicy.refusalCode(for: MailboxDoorbell.text))
    }

    // MARK: - Every harness

    func testEveryHarnessRings() {
        let adapters: [JournalAdapter] = [
            .claudeHook, .opencodePlugin, .piPlugin,
            .codexNotify, .codexTranscript, .grokTranscript,
        ]
        for adapter in adapters {
            _ = adapter.capabilities.contains("blocked")
            XCTAssertEqual(MailboxDoorbell.decide(MailboxDoorbell.Input()), .ring)
            XCTAssertEqual(MailboxDoorbell.arrival(for: .ring), .ring)
        }
    }

    // MARK: - Operator quiet window

    func testFocusedRecentKeyDefersAndUnfocusedRings() {
        var typing = MailboxDoorbell.Input()
        typing.focused = true
        typing.operatorKeyAge = 0
        XCTAssertEqual(MailboxDoorbell.decide(typing), .deferRing(after: 3))

        var almost = MailboxDoorbell.Input()
        almost.focused = true
        almost.operatorKeyAge = 1
        XCTAssertEqual(MailboxDoorbell.decide(almost), .deferRing(after: 2))

        var quiet = MailboxDoorbell.Input()
        quiet.focused = true
        quiet.operatorKeyAge = 3
        XCTAssertEqual(MailboxDoorbell.decide(quiet), .ring)

        var elsewhere = MailboxDoorbell.Input()
        elsewhere.focused = false
        elsewhere.operatorKeyAge = 0
        XCTAssertEqual(MailboxDoorbell.decide(elsewhere), .ring)
    }

    // MARK: - Once per idle and rate cap

    func testSecondMailInTheSameEpochDrops() {
        var again = MailboxDoorbell.Input()
        again.rungThisEpoch = true
        XCTAssertEqual(MailboxDoorbell.decide(again), .skip(reason: "once_per_idle"))
        XCTAssertEqual(
            MailboxDoorbell.arrival(for: .skip(reason: "once_per_idle")),
            .keep(reason: "once_per_idle")
        )

        var next = MailboxDoorbell.Input()
        next.rungThisEpoch = false
        next.epoch = "2|idle|completed"
        XCTAssertEqual(MailboxDoorbell.decide(next), .ring)
    }

    func testFourthAttemptInsideTheWindowIsCapped() {
        var capped = MailboxDoorbell.Input()
        capped.recentAttempts = 3
        XCTAssertEqual(MailboxDoorbell.decide(capped), .skip(reason: "rate_capped"))
        XCTAssertEqual(
            MailboxDoorbell.arrival(for: .skip(reason: "rate_capped")),
            .keep(reason: "rate_capped")
        )

        var allowed = MailboxDoorbell.Input()
        allowed.recentAttempts = 2
        XCTAssertEqual(MailboxDoorbell.decide(allowed), .ring)
    }

    func testAttemptExactlyOneWindowOldDoesNotCount() {
        let start = Date(timeIntervalSince1970: 10_000)
        var ledger = MailboxDoorbell.Ledger()
        ledger.beginAttempt(at: start, epoch: "1|idle|completed")
        ledger.beginAttempt(at: start.addingTimeInterval(1), epoch: "1|idle|completed")
        ledger.beginAttempt(at: start.addingTimeInterval(2), epoch: "1|idle|completed")
        XCTAssertEqual(ledger.rings(at: start.addingTimeInterval(599)), 3)
        XCTAssertEqual(ledger.rings(at: start.addingTimeInterval(600)), 2)
        XCTAssertEqual(ledger.rings(at: start.addingTimeInterval(602)), 0)
        ledger.endAttempt()
        XCTAssertFalse(ledger.inFlight)
        XCTAssertTrue(ledger.rung(in: "1|idle|completed"))
        XCTAssertFalse(ledger.rung(in: "2|idle|completed"))
    }

    func testInFlightKeepsTheNewArrival() {
        var flying = MailboxDoorbell.Input()
        flying.inFlight = true
        flying.rungThisEpoch = true
        XCTAssertEqual(MailboxDoorbell.decide(flying), .skip(reason: "in_flight"))
        XCTAssertEqual(
            MailboxDoorbell.arrival(for: .skip(reason: "in_flight")),
            .keep(reason: "in_flight")
        )
    }

    // MARK: - Attention and delivery

    func testSuppressedRingsAndFlaggedDoesNot() {
        var suppressed = MailboxDoorbell.Input()
        suppressed.suppressed = true
        XCTAssertEqual(MailboxDoorbell.decide(suppressed), .ring)

        var flagged = MailboxDoorbell.Input()
        flagged.flagged = true
        flagged.suppressed = true
        XCTAssertEqual(MailboxDoorbell.decide(flagged), .skip(reason: "flagged"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "flagged")), .keep(reason: "flagged"))
    }

    func testOptOutAndNonStdinTypeNothing() {
        var opted = MailboxDoorbell.Input()
        opted.optedOut = true
        XCTAssertEqual(MailboxDoorbell.decide(opted), .skip(reason: "opted_out"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "opted_out")), .keep(reason: "opted_out"))

        var other = MailboxDoorbell.Input()
        other.stdinDelivery = false
        XCTAssertEqual(MailboxDoorbell.decide(other), .skip(reason: "not_stdin"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "not_stdin")), .keep(reason: "not_stdin"))
    }

    func testNoUnreadKeepsWithoutPushing() {
        var empty = MailboxDoorbell.Input()
        empty.hasUnread = false
        XCTAssertEqual(MailboxDoorbell.decide(empty), .skip(reason: "no_mail"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "no_mail")), .keep(reason: "no_mail"))
    }

    // MARK: - Queue stays for the next idle period

    func testRingDoesNotTakeTheQueue() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "a"))
        buffer.enqueue(surfaceId: surface, entry: entry(id: "b"))
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 2)
        let later = buffer.drainForFlush(surfaceId: surface, now: Date(), trigger: .agentPrompt)
        XCTAssertEqual(later.fresh.map(\.id), ["a", "b"])
    }

    // MARK: - Dispatch log

    func testDoorbellHandlerLineCarriesOutcomeAndReason() throws {
        let stamped = MailboxDispatchLog.serialize(
            event: .handler(
                id: "A",
                recipient: "watcher",
                handler: "stdin",
                outcome: .doorbell,
                bytes: nil,
                elapsedMs: nil,
                reason: "started"
            ),
            at: Date(timeIntervalSince1970: 0)
        )
        let obj = try JSONSerialization.jsonObject(with: Data(stamped.dropLast().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["outcome"] as? String, "doorbell")
        XCTAssertEqual(obj?["reason"] as? String, "started")
        XCTAssertNil(obj?["bytes"])

        let capped = MailboxDispatchLog.serialize(
            event: .handler(
                id: "A",
                recipient: "watcher",
                handler: "stdin",
                outcome: .doorbellCapped,
                bytes: nil,
                elapsedMs: nil,
                reason: "rate_capped"
            ),
            at: Date(timeIntervalSince1970: 0)
        )
        let cappedObj = try JSONSerialization.jsonObject(with: Data(capped.dropLast().utf8)) as? [String: Any]
        XCTAssertEqual(cappedObj?["outcome"] as? String, "doorbell_capped")
        XCTAssertEqual(cappedObj?["reason"] as? String, "rate_capped")
    }

    func testHandlerOmitsNilReason() throws {
        let str = MailboxDispatchLog.serialize(
            event: .handler(
                id: "A", recipient: "w", handler: "silent", outcome: .ok,
                bytes: nil, elapsedMs: nil, reason: nil
            ),
            at: Date(timeIntervalSince1970: 0)
        )
        let obj = try JSONSerialization.jsonObject(with: Data(str.dropLast().utf8)) as? [String: Any]
        XCTAssertNil(obj?["reason"])
        XCTAssertNil(obj?["bytes"])
        XCTAssertEqual(obj?["outcome"] as? String, "ok")
    }

    // MARK: - deliver()

    /// No prompt edge yet: enqueue only. Do not ring and do not paste.
    func testClosedGateDoesNotRingOrPaste() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var captures: [Bool] = []
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            captures.append(capture)
            return MailboxDoorbell.Input()
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        XCTAssertEqual(captures, [])
        guard case .buffered = admitted else {
            return XCTFail("expected a buffer, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    /// An open prompt rings. The block is not pasted. The envelope stays queued.
    func testAtPromptDeliveryRingsAndDoesNotPaste() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        openPrompt(state, surface)
        var read = false
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            read = true
            var input = MailboxDoorbell.Input()
            input.prompt = capture ? .empty : nil
            return input
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        XCTAssertTrue(read)
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a ring, got \(admitted)")
        }
        XCTAssertEqual(effect, .ring)
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testOpenPromptRingsWithoutABlockedCapability() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        openPrompt(state, surface)
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            MailboxDoorbell.Input()
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a ring, got \(admitted)")
        }
        XCTAssertEqual(effect, .ring)
    }

    func testRateCapKeepsTheQueue() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        openPrompt(state, surface)
        state.buffer.enqueue(surfaceId: surface, entry: entry(id: "older"))
        var pushed = false
        var noted: MailboxDoorbell.Decision?
        let admitted = admit(state: state, surfaceId: surface, id: "newer", ring: { _ in
            var input = MailboxDoorbell.Input()
            input.recentAttempts = MailboxDoorbell.rateCap
            input.prompt = .empty
            return input
        }, note: { decision, _ in noted = decision }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        XCTAssertEqual(noted, .skip(reason: "rate_capped"))
        guard case .buffered = admitted else {
            return XCTFail("expected the mail to stay queued, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.queuedEntries(surfaceId: surface).map(\.id), ["older", "newer"])
    }

    func testDeferDoesNotPushOrDrop() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        openPrompt(state, surface)
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            var input = MailboxDoorbell.Input()
            input.focused = true
            input.operatorKeyAge = 1
            input.prompt = .empty
            return input
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a deferred doorbell, got \(admitted)")
        }
        XCTAssertEqual(effect, .deferRing(2))
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testClosedGateDoesNotCaptureThePrompt() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var captures: [Bool] = []
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            captures.append(capture)
            return MailboxDoorbell.Input()
        }, push: { _ in pushed = true })
        XCTAssertEqual(captures, [])
        XCTAssertFalse(pushed)
        guard case .buffered = admitted else {
            return XCTFail("expected a buffer, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testIdleFlushThatAlreadyDeliveredDoesNotRing() {
        XCTAssertNil(MailboxDoorbell.arrivalAfterIdleFlush(
            delivered: true,
            stillPending: false,
            input: MailboxDoorbell.Input()
        ))
    }

    func testMailStillQueuedAtIdleRingsOnce() {
        XCTAssertEqual(
            MailboxDoorbell.arrivalAfterIdleFlush(
                delivered: false,
                stillPending: true,
                input: MailboxDoorbell.Input()
            ),
            .ring
        )
        var again = MailboxDoorbell.Input()
        again.rungThisEpoch = true
        XCTAssertNil(MailboxDoorbell.arrivalAfterIdleFlush(
            delivered: false, stillPending: true, input: again
        ))
    }

    func testEpochStringIncludesPhaseAndOutcome() {
        XCTAssertEqual(
            MailboxDoorbell.epoch(sinceMs: 50, phase: "idle", turnOutcome: "completed"),
            "50|idle|completed"
        )
        XCTAssertEqual(
            MailboxDoorbell.epoch(sinceMs: 50, phase: "idle", turnOutcome: nil),
            "50|idle|"
        )
        XCTAssertEqual(
            MailboxDoorbell.promptEpoch(since: Date(timeIntervalSince1970: 1.5), atPrompt: true),
            "1500|prompt"
        )
    }

    func testConstantsMatchTheStatedWindowAndCap() {
        XCTAssertEqual(MailboxDoorbell.quietWindow, 3)
        XCTAssertEqual(MailboxDoorbell.rateWindow, 600)
        XCTAssertEqual(MailboxDoorbell.rateCap, 3)
    }
}
