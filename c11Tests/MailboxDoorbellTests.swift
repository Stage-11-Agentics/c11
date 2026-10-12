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

    func testAttemptAtTheCapIsCapped() {
        XCTAssertEqual(MailboxDoorbell.rateCap, 20)
        var capped = MailboxDoorbell.Input()
        capped.recentAttempts = MailboxDoorbell.rateCap
        XCTAssertEqual(MailboxDoorbell.decide(capped), .skip(reason: "rate_capped"))
        XCTAssertEqual(
            MailboxDoorbell.arrival(for: .skip(reason: "rate_capped")),
            .keep(reason: "rate_capped")
        )

        var allowed = MailboxDoorbell.Input()
        allowed.recentAttempts = MailboxDoorbell.rateCap - 1
        XCTAssertEqual(MailboxDoorbell.decide(allowed), .ring)
    }

    func testTextBoxInputDefersAndUnsentTextSkips() {
        let now = Date(timeIntervalSince1970: 5_000)
        let age = MailboxDoorbellSequence.operatorKeyAge(
            keyAt: nil,
            inputAt: now.addingTimeInterval(-1),
            now: now
        )
        var typing = MailboxDoorbell.Input()
        typing.focused = true
        typing.operatorKeyAge = age
        XCTAssertEqual(MailboxDoorbell.decide(typing), .deferRing(after: 2))

        XCTAssertEqual(
            MailboxDoorbellSequence.operatorKeyAge(
                keyAt: now.addingTimeInterval(-10),
                inputAt: now.addingTimeInterval(-1),
                now: now
            ),
            1
        )

        var unsent = MailboxDoorbell.Input()
        unsent.prompt = .empty
        unsent.textBoxUnsent = MailboxDoorbellSequence.textBoxHoldsUnsent("fix the todo")
        XCTAssertEqual(MailboxDoorbell.decide(unsent), .skip(reason: "draft"))
        XCTAssertFalse(MailboxDoorbellSequence.textBoxHoldsUnsent("  \n"))
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

    func testSuppressedRingsAndSelfRaisedFlagHolds() {
        var suppressed = MailboxDoorbell.Input()
        suppressed.suppressed = true
        XCTAssertEqual(MailboxDoorbell.decide(suppressed), .ring)

        let surface = UUID()
        var flagged = MailboxDoorbell.Input()
        flagged.flagged = MailboxDoorbellSequence.holdsForFlag(
            isFlagged: true,
            callerPanelId: surface,
            surfaceId: surface
        )
        flagged.suppressed = true
        XCTAssertEqual(MailboxDoorbell.decide(flagged), .skip(reason: "flagged"))
        XCTAssertEqual(MailboxDoorbell.arrival(for: .skip(reason: "flagged")), .keep(reason: "flagged"))
    }

    func testDispatchFlagRingsAndLoweringRearms() {
        let surface = UUID()
        let dispatcher = UUID()
        XCTAssertFalse(MailboxDoorbellSequence.holdsForFlag(
            isFlagged: true, callerPanelId: dispatcher, surfaceId: surface
        ))
        XCTAssertFalse(MailboxDoorbellSequence.holdsForFlag(
            isFlagged: true, callerPanelId: nil, surfaceId: surface
        ))
        XCTAssertTrue(MailboxDoorbellSequence.holdsForFlag(
            isFlagged: true, callerPanelId: surface, surfaceId: surface
        ))
        XCTAssertFalse(MailboxDoorbellSequence.holdsForFlag(
            isFlagged: false, callerPanelId: surface, surfaceId: surface
        ))

        var dispatch = MailboxDoorbell.Input()
        dispatch.flagged = MailboxDoorbellSequence.holdsForFlag(
            isFlagged: true, callerPanelId: dispatcher, surfaceId: surface
        )
        dispatch.prompt = .empty
        XCTAssertEqual(MailboxDoorbell.decide(dispatch), .ring)

        XCTAssertEqual(
            MailboxDoorbellSequence.rearmAfterFlagLower(unreadQueued: true),
            .after(0)
        )
        XCTAssertEqual(
            MailboxDoorbellSequence.rearmAfterFlagLower(unreadQueued: false),
            .none
        )
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

    func testPromptEpochFollowsTheTurnClock() {
        XCTAssertEqual(
            MailboxDoorbell.promptEpoch(since: Date(timeIntervalSince1970: 1.5), atPrompt: true),
            "1500|prompt"
        )
        XCTAssertEqual(
            MailboxDoorbell.promptEpoch(since: Date(timeIntervalSince1970: 1.5), atPrompt: false),
            "1500|turn"
        )
    }

    // MARK: - Re-arm

    func testCappedKeepRearmsAtTheWindowEndAndThenRings() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldest = now.addingTimeInterval(-100)
        let plan = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "rate_capped"),
            attempts: [oldest, now.addingTimeInterval(-40), now.addingTimeInterval(-10)],
            now: now,
            busyExhausted: false,
            strandedDoorbell: false
        )
        XCTAssertEqual(plan.arrival, .keep(reason: "rate_capped"))
        XCTAssertEqual(plan.rearm, .at(oldest.addingTimeInterval(MailboxDoorbell.rateWindow)))

        var later = MailboxDoorbell.Input()
        later.prompt = .empty
        later.recentAttempts = 0
        let again = MailboxDoorbellSequence.plan(
            decision: MailboxDoorbell.decide(later),
            attempts: [],
            now: oldest.addingTimeInterval(MailboxDoorbell.rateWindow),
            busyExhausted: false,
            strandedDoorbell: false
        )
        XCTAssertEqual(again.arrival, .ring)
        XCTAssertEqual(again.rearm, .none)
    }

    func testBusyReadRetriesThenRearms() {
        XCTAssertTrue(MailboxDoorbellSequence.shouldRetryBusy(tryIndex: 0))
        XCTAssertTrue(MailboxDoorbellSequence.shouldRetryBusy(tryIndex: 1))
        XCTAssertFalse(MailboxDoorbellSequence.shouldRetryBusy(tryIndex: 2))
        XCTAssertFalse(MailboxDoorbellSequence.shouldRetryBusy(tryIndex: 3))
        let now = Date(timeIntervalSince1970: 20)
        let exhausted = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "unavailable"),
            attempts: [],
            now: now,
            busyExhausted: true,
            strandedDoorbell: false
        )
        XCTAssertEqual(exhausted.arrival, .keep(reason: "unavailable"))
        XCTAssertEqual(exhausted.rearm, .after(MailboxDoorbellSequence.shortRecheck))
        let unreadSurface = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "unavailable"),
            attempts: [],
            now: now,
            busyExhausted: false,
            strandedDoorbell: false
        )
        XCTAssertEqual(unreadSurface.rearm, .none)
    }

    func testPrePasteFailureLeavesTheIdlePeriodUnconsumed() {
        let now = Date(timeIntervalSince1970: 30)
        var ledger = MailboxDoorbell.Ledger()
        ledger.reserve()
        let refused = MailboxDoorbellSequence.start(
            hasSurface: false,
            inputTransactionActive: false,
            feedAnswerBegan: false
        )
        MailboxDoorbellSequence.apply(start: refused, ledger: &ledger, now: now, epoch: "1|prompt")
        XCTAssertEqual(refused, .fail("unavailable"))
        XCTAssertFalse(ledger.inFlight)
        XCTAssertFalse(ledger.rung(in: "1|prompt"))
        XCTAssertEqual(ledger.rings(at: now), 0)

        ledger.reserve()
        let typed = MailboxDoorbellSequence.start(
            hasSurface: true,
            inputTransactionActive: false,
            feedAnswerBegan: true
        )
        MailboxDoorbellSequence.apply(start: typed, ledger: &ledger, now: now, epoch: "1|prompt")
        XCTAssertEqual(typed, .type)
        XCTAssertTrue(ledger.rung(in: "1|prompt"))
        XCTAssertEqual(ledger.rings(at: now), 1)
    }

    func testStrandedInvitationLooksAgainAndAnEditStops() {
        XCTAssertEqual(
            MailboxDoorbellSequence.rearmAfterPasteFailure(
                outcome: .pastedNotSubmitted,
                state: .draft,
                composer: MailboxDoorbell.text
            ),
            .after(MailboxDoorbellSequence.shortRecheck)
        )
        XCTAssertEqual(
            MailboxDoorbellSequence.rearmAfterPasteFailure(
                outcome: .pastedNotSubmitted,
                state: .draft,
                composer: "operator draft"
            ),
            .none
        )
        XCTAssertEqual(
            MailboxDoorbellSequence.rearmAfterPasteFailure(
                outcome: .targetLost,
                state: nil,
                composer: nil
            ),
            .none
        )
    }

    // MARK: - Seam guards

    /// W1. A changed composer refuses the Return. The compare is inside the seam.
    func testPreReturnRefusesAChangedComposer() {
        XCTAssertEqual(
            MailboxDoorbellSequence.preReturn(
                rowIsCurrent: true,
                operatorInputUnchanged: true,
                agentOwnsTerminal: true,
                captured: true,
                prompt: .draft,
                composer: "operator draft"
            ),
            .pastedNotSubmitted
        )
        XCTAssertNil(MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true,
            operatorInputUnchanged: true,
            agentOwnsTerminal: true,
            captured: true,
            prompt: .draft,
            composer: MailboxDoorbell.text
        ))
        XCTAssertEqual(
            MailboxDoorbellSequence.preReturn(
                rowIsCurrent: true,
                operatorInputUnchanged: true,
                agentOwnsTerminal: false,
                captured: true,
                prompt: .draft,
                composer: MailboxDoorbell.text
            ),
            .targetLost
        )
    }

    /// W2. An idle-edge keep leaves the queue in place.
    func testKeepLeavesTheQueue() {
        XCTAssertEqual(
            MailboxDoorbellSequence.idsRemainingAfterKeep(queued: ["a", "b"]),
            ["a", "b"]
        )
    }

    /// W3. The inbox check drops only snapshot ids that are gone.
    func testInboxCheckDropsOnlyGoneIds() {
        let dropped = MailboxDoorbellSequence.droppedIds(
            snapshot: ["a", "b", "c"],
            stillPending: ["b"]
        )
        XCTAssertEqual(dropped, ["a", "c"])
        XCTAssertFalse(dropped.contains("b"))
    }

    /// W4. The decision uses the captured prompt, not an assumed empty one.
    func testDecisionUsesTheCapturedPrompt() {
        let captured = MailboxDoorbellSequence.promptForDecision(captured: .draft)
        var input = MailboxDoorbell.Input()
        input.prompt = captured
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "draft"))
    }

    /// Review 2 W3. An agent prompt edge rings. A shell prompt does not.
    func testIdleEdgeIsThePromptRing() {
        XCTAssertTrue(MailboxDoorbellSequence.shouldRingOnPromptEdge(.agentPrompt))
        XCTAssertFalse(MailboxDoorbellSequence.shouldRingOnPromptEdge(.shellPrompt))
    }

    /// Review 2 W7. The ring types the invitation. The queued block stays unread.
    func testRingTypesTheInvitationNotTheBlock() {
        let typed = MailboxDoorbellSequence.typedText(
            queuedBlocks: ["<c11-msg from=\"a\">body</c11-msg>"]
        )
        XCTAssertEqual(typed, MailboxDoorbell.text)
        XCTAssertFalse(typed.contains("<c11-msg"))
    }

    /// W5. Starting a ring records the attempt. Skipping the record leaves
    /// the cap and the idle period unused.
    func testTypeRecordsAnAttempt() {
        var ledger = MailboxDoorbell.Ledger()
        let now = Date(timeIntervalSince1970: 40)
        MailboxDoorbellSequence.apply(start: .type, ledger: &ledger, now: now, epoch: "9|prompt")
        XCTAssertEqual(ledger.rings(at: now), 1)
        XCTAssertTrue(ledger.rung(in: "9|prompt"))
    }
}
