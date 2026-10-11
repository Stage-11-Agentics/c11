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
            "You have mail: run c11 mailbox recv when you want to receive it."
        )
        XCTAssertNil(FeedAnswerTextPolicy.refusalCode(for: MailboxDoorbell.text))
    }

    // MARK: - Lifecycle

    func testWorkingAndWaitingDoNotRing() {
        var working = MailboxDoorbell.Input()
        working.working = true
        XCTAssertEqual(MailboxDoorbell.decide(working), .skip(reason: "working"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "working")), .keep(reason: "working"))

        var waiting = MailboxDoorbell.Input()
        waiting.waiting = true
        XCTAssertEqual(MailboxDoorbell.decide(waiting), .skip(reason: "waiting"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "waiting")), .keep(reason: "waiting"))
    }

    func testIdleCompletedBlockedCapabilityRings() {
        XCTAssertTrue(JournalAdapter.claudeHook.capabilities.contains("blocked"))
        XCTAssertTrue(JournalAdapter.opencodePlugin.capabilities.contains("blocked"))
        var input = MailboxDoorbell.Input()
        input.reportsBlocked = JournalAdapter.claudeHook.capabilities.contains("blocked")
        input.confirmedLive = true
        input.phaseIdle = true
        input.turnOutcomeCompleted = true
        XCTAssertEqual(MailboxDoorbell.decide(input), .ring)
    }

    func testGrokCodexAndPiStayOnTodaysPaste() {
        let ambiguous: [JournalAdapter] = [
            .grokTranscript, .codexNotify, .codexTranscript, .piPlugin,
        ]
        for adapter in ambiguous {
            XCTAssertFalse(adapter.capabilities.contains("blocked"))
            var input = MailboxDoorbell.Input()
            input.reportsBlocked = adapter.capabilities.contains("blocked")
            XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "harness_ambiguous"))
            XCTAssertEqual(
                MailboxDoorbell.arrival(for: .skip(reason: "harness_ambiguous")),
                .push
            )
        }
    }

    func testUnconfirmedHistoricalAndInterruptedDoNotRing() {
        var historical = MailboxDoorbell.Input()
        historical.confirmedLive = false
        XCTAssertEqual(MailboxDoorbell.decide(historical), .skip(reason: "not_idle"))

        var interrupted = MailboxDoorbell.Input()
        interrupted.turnOutcomeCompleted = false
        XCTAssertEqual(MailboxDoorbell.decide(interrupted), .skip(reason: "not_idle"))

        var unknownPhase = MailboxDoorbell.Input()
        unknownPhase.phaseIdle = false
        XCTAssertEqual(MailboxDoorbell.decide(unknownPhase), .skip(reason: "not_idle"))

        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "not_idle")), .push)
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
            .drop(reason: "once_per_idle", capped: false)
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
            .drop(reason: "rate_capped", capped: true)
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

    func testOptOutAndNonStdinFallBackToPush() {
        var opted = MailboxDoorbell.Input()
        opted.optedOut = true
        XCTAssertEqual(MailboxDoorbell.decide(opted), .skip(reason: "opted_out"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "opted_out")), .push)

        var other = MailboxDoorbell.Input()
        other.stdinDelivery = false
        XCTAssertEqual(MailboxDoorbell.decide(other), .skip(reason: "not_stdin"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "not_stdin")), .push)
    }

    func testNoUnreadKeepsWithoutPushing() {
        var empty = MailboxDoorbell.Input()
        empty.hasUnread = false
        XCTAssertEqual(MailboxDoorbell.decide(empty), .skip(reason: "no_mail"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "no_mail")), .keep(reason: "no_mail"))
    }

    // MARK: - Flush suppression

    func testSubmittedDoorbellRemovesLaterFlush() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "a"))
        buffer.enqueue(surfaceId: surface, entry: entry(id: "b"))
        let taken = MailboxDoorbell.commitFlushSuppression(
            buffer: &buffer, surfaceId: surface, submitted: true
        )
        XCTAssertEqual(taken.map(\.id), ["a", "b"])
        let later = buffer.drainForFlush(surfaceId: surface, now: Date(), trigger: .agentPrompt)
        XCTAssertTrue(later.fresh.isEmpty)
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
    }

    func testFailedDoorbellLeavesTheFlushQueue() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "a"))
        let taken = MailboxDoorbell.commitFlushSuppression(
            buffer: &buffer, surfaceId: surface, submitted: false
        )
        XCTAssertTrue(taken.isEmpty)
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 1)
        let later = buffer.drainForFlush(surfaceId: surface, now: Date(), trigger: .agentPrompt)
        XCTAssertEqual(later.fresh.map(\.id), ["a"])
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

    /// No prompt edge: a live TUI keeps the shell `.commandRunning`, so
    /// today's gate buffers. An idle Claude Code panel rings instead.
    func testBufferedEnvelopeForIdleClaudeRings() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var captures: [Bool] = []
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            captures.append(capture)
            var input = MailboxDoorbell.Input()
            input.prompt = capture ? .empty : nil
            return input
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        XCTAssertEqual(captures, [false, true])
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a doorbell admit, got \(admitted)")
        }
        XCTAssertEqual(effect, .ring)
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    /// An open prompt edge still pastes today's block. The ring is not that path.
    func testAtPromptDeliveryDoesNotRing() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: true, at: Date(timeIntervalSince1970: 0))
        var read = false
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            read = true
            return MailboxDoorbell.Input()
        }, push: { _ in pushed = true })
        XCTAssertFalse(read)
        XCTAssertTrue(pushed)
        guard case .ok = admitted else {
            return XCTFail("expected today's push, got \(admitted)")
        }
    }

    func testBufferedGrokIsNotRung() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var pushed = false
        var noted: MailboxDoorbell.Decision?
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            var input = MailboxDoorbell.Input()
            input.reportsBlocked = false
            input.prompt = .empty
            return input
        }, note: { decision, _ in noted = decision }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        XCTAssertEqual(noted, .skip(reason: "harness_ambiguous"))
        guard case .buffered = admitted else {
            return XCTFail("expected the block to stay buffered, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testRateCapDropsOnlyTheNewEntry() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.enqueue(surfaceId: surface, entry: entry(id: "older"))
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, id: "newer", ring: { _ in
            var input = MailboxDoorbell.Input()
            input.recentAttempts = MailboxDoorbell.rateCap
            input.prompt = .empty
            return input
        }, push: { _ in pushed = true })
        XCTAssertFalse(pushed)
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a capped doorbell, got \(admitted)")
        }
        XCTAssertEqual(effect, .drop(reason: "rate_capped", capped: true))
        XCTAssertEqual(state.buffer.queuedEntries(surfaceId: surface).map(\.id), ["older"])
    }

    func testDeferDoesNotPushOrDrop() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
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

    func testWorkingBufferDoesNotCaptureThePrompt() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var captures: [Bool] = []
        var pushed = false
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            captures.append(capture)
            var input = MailboxDoorbell.Input()
            input.working = true
            input.prompt = nil
            return input
        }, push: { _ in pushed = true })
        XCTAssertEqual(captures, [false])
        XCTAssertFalse(pushed)
        guard case .buffered = admitted else {
            return XCTFail("expected a buffer, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testIdleFlushThatDeliversDoesNotRing() {
        XCTAssertNil(MailboxDoorbell.arrivalAfterIdleFlush(
            delivered: true,
            stillPending: false,
            input: MailboxDoorbell.Input()
        ))
    }

    func testMailStillBufferedWhenIdleRingsOnce() {
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
        XCTAssertEqual(
            MailboxDoorbell.arrivalAfterIdleFlush(delivered: false, stillPending: true, input: again),
            .drop(reason: "once_per_idle", capped: false)
        )
        var working = MailboxDoorbell.Input()
        working.working = true
        XCTAssertNil(MailboxDoorbell.arrivalAfterIdleFlush(
            delivered: false, stillPending: true, input: working
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
    }

    func testConstantsMatchTheStatedWindowAndCap() {
        XCTAssertEqual(MailboxDoorbell.quietWindow, 3)
        XCTAssertEqual(MailboxDoorbell.rateWindow, 600)
        XCTAssertEqual(MailboxDoorbell.rateCap, 3)
    }
}
