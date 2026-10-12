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

    private func gateAt(_ seconds: TimeInterval, journalTurnOpen: Bool = false) -> MailboxStdinDelivery.Gate {
        MailboxStdinDelivery.Gate(isAgentKind: true, ownsTerminal: true, journalTurnOpen: journalTurnOpen,
                                  now: Date(timeIntervalSince1970: seconds))
    }

    /// The screen shows an empty composer whenever the ring asks for it.
    private func emptyScreen(_ captures: Box<[Bool]>) -> (Bool) -> MailboxDoorbell.Input {
        { capture in
            captures.value.append(capture)
            var input = MailboxDoorbell.Input()
            input.prompt = capture ? .empty : nil
            return input
        }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
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
        note: ((MailboxDoorbell.Decision, MailboxDoorbell.Arrival) -> Void)? = nil
    ) -> MailboxStdinDelivery.AdmitResult {
        MailboxStdinDelivery.deliver(
            state: state,
            surfaceId: surfaceId,
            entry: entry(id: id),
            gate: gate ?? openGate(),
            logEvicted: { _ in },
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

    /// Mid-turn: enqueue only. Do not ring and do not paste.
    func testClosedGateDoesNotRingOrPaste() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: false, at: Date(timeIntervalSince1970: 10))
        var captures: [Bool] = []
        let admitted = admit(state: state, surfaceId: surface, gate: gateAt(11), ring: { capture in
            captures.append(capture)
            return MailboxDoorbell.Input()
        })
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
        let admitted = admit(state: state, surfaceId: surface, ring: { capture in
            read = true
            var input = MailboxDoorbell.Input()
            input.prompt = capture ? .empty : nil
            return input
        })
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
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            MailboxDoorbell.Input()
        })
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
        var noted: MailboxDoorbell.Decision?
        let admitted = admit(state: state, surfaceId: surface, id: "newer", ring: { _ in
            var input = MailboxDoorbell.Input()
            input.recentAttempts = MailboxDoorbell.rateCap
            input.prompt = .empty
            return input
        }, note: { decision, _ in noted = decision })
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
        let admitted = admit(state: state, surfaceId: surface, ring: { _ in
            var input = MailboxDoorbell.Input()
            input.focused = true
            input.operatorKeyAge = 1
            input.prompt = .empty
            return input
        })
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a deferred doorbell, got \(admitted)")
        }
        XCTAssertEqual(effect, .deferRing(2))
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testClosedGateDoesNotCaptureThePrompt() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.noteSubmit(surfaceId: surface, at: Date(timeIntervalSince1970: 10))
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: false, at: Date(timeIntervalSince1970: 10))
        var captures: [Bool] = []
        let admitted = admit(state: state, surfaceId: surface, gate: gateAt(11, journalTurnOpen: true), ring: { capture in
            captures.append(capture)
            return MailboxDoorbell.Input()
        })
        XCTAssertEqual(captures, [])
        guard case .buffered = admitted else {
            return XCTFail("expected a buffer, got \(admitted)")
        }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    // MARK: - C11-398: restored sessions

    /// The observed trace: c11 restarted, the session resumed idle at its
    /// prompt, and no turn edge followed. Mail that arrives is rung through
    /// the screen read, not buffered until someone types.
    func testRestoredPanelWithNoEdgeIsRungWhenMailArrives() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        // The attach forgets the earlier process's working edge and the Return
        // that launched `claude --resume`.
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: false, at: Date(timeIntervalSince1970: 5))
        state.buffer.noteSubmit(surfaceId: surface, at: Date(timeIntervalSince1970: 9))
        state.buffer.noteAgentProcess(surfaceId: surface, process: .init(pid: 4242, startTime: 7))
        state.buffer.noteAgentAttached(surfaceId: surface, at: Date(timeIntervalSince1970: 10))
        let captures = Box<[Bool]>([])
        var held: [Date] = []
        let admitted = MailboxStdinDelivery.deliver(
            state: state, surfaceId: surface, entry: entry(id: "after-restart"), gate: gateAt(11),
            logEvicted: { _ in }, ringInput: emptyScreen(captures),
            noteHeldUntil: { held.append($0) }
        )
        XCTAssertEqual(captures.value, [false, true], "the ring reads the screen")
        guard case .doorbell(_, let effect) = admitted else {
            return XCTFail("expected a ring, got \(admitted)")
        }
        XCTAssertEqual(effect, .ring)
        XCTAssertEqual(held, [])
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)

        // Unknown is not a pass: the same screen read refuses a draft.
        let drafted = MailboxStdinDelivery.deliver(
            state: state, surfaceId: surface, entry: entry(id: "behind-draft"), gate: gateAt(12),
            logEvicted: { _ in }, ringInput: { capture in
                var input = MailboxDoorbell.Input()
                input.prompt = capture ? .draft : nil
                return input
            }
        )
        guard case .buffered = drafted else { return XCTFail("expected a draft to hold, got \(drafted)") }
    }

    /// A real long turn: the journal is live and working, and the tool call
    /// has printed nothing for an hour. The gate stays closed, the screen is
    /// not read, and nothing waits on a decay deadline: the turn end rings.
    func testLongJournalTurnIsNeverRung() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: false, at: Date(timeIntervalSince1970: 10))
        let captures = Box<[Bool]>([])
        var held: [Date] = []
        let admitted = MailboxStdinDelivery.deliver(
            state: state, surfaceId: surface, entry: entry(id: "mid-turn"),
            gate: gateAt(10 + 3_600, journalTurnOpen: true),
            logEvicted: { _ in }, ringInput: emptyScreen(captures),
            noteHeldUntil: { held.append($0) }
        )
        XCTAssertEqual(captures.value, [])
        XCTAssertEqual(held, [])
        guard case .buffered = admitted else { return XCTFail("expected a buffer, got \(admitted)") }
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    /// A working edge with no journal turn behind it holds the mail until the
    /// decay deadline, reports that deadline for the recheck, and rings once
    /// it has passed.
    func testUnsupportedWorkingHoldsUntilTheDecayThenRings() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: false, at: Date(timeIntervalSince1970: 10))
        let captures = Box<[Bool]>([])
        var held: [Date] = []
        let early = MailboxStdinDelivery.deliver(
            state: state, surfaceId: surface, entry: entry(id: "early"), gate: gateAt(70),
            logEvicted: { _ in }, ringInput: emptyScreen(captures),
            noteHeldUntil: { held.append($0) }
        )
        guard case .buffered = early else { return XCTFail("expected a buffer, got \(early)") }
        XCTAssertEqual(captures.value, [])
        XCTAssertEqual(held, [Date(timeIntervalSince1970: 10 + MailboxStdinBuffer.unsupportedWorkingDecay)])
        XCTAssertEqual(MailboxStdinDelivery.heldUntil(state: state, surfaceId: surface, gate: gateAt(70)), held.first)
        XCTAssertNil(MailboxStdinDelivery.heldUntil(state: state, surfaceId: surface,
                                                    gate: gateAt(70, journalTurnOpen: true)))

        let late = MailboxStdinDelivery.deliver(
            state: state, surfaceId: surface, entry: entry(id: "late"), gate: gateAt(130),
            logEvicted: { _ in }, ringInput: emptyScreen(captures),
            noteHeldUntil: { held.append($0) }
        )
        guard case .doorbell(_, let effect) = late else { return XCTFail("expected a ring, got \(late)") }
        XCTAssertEqual(effect, .ring)
        XCTAssertEqual(held.count, 1)
        XCTAssertNil(MailboxStdinDelivery.heldUntil(state: state, surfaceId: surface, gate: gateAt(130)))
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

    func testRungEnvelopeDoesNotRingOnALaterIdle() {
        var later = MailboxDoorbell.Input()
        later.unreadIds = ["a"]
        later.coveredIds = MailboxDoorbellSequence.coveredIds(for: ["a"])
        later.rungThisEpoch = false
        later.epoch = "2|prompt"
        later.prompt = .empty
        let decision = MailboxDoorbell.decide(later)
        XCTAssertEqual(decision, .skip(reason: "already_covered"))
        let plan = MailboxDoorbellSequence.plan(
            decision: decision,
            attempts: [],
            now: Date(timeIntervalSince1970: 20),
            busyExhausted: false,
            strandedDoorbell: false,
            epoch: later.epoch
        )
        XCTAssertEqual(plan.arrival, .keep(reason: "already_covered"))
        XCTAssertEqual(plan.rearm, .none)

        var unreadPrompt = later
        unreadPrompt.prompt = nil
        XCTAssertEqual(MailboxDoorbell.decide(unreadPrompt), .skip(reason: "already_covered"))
        XCTAssertFalse(MailboxDoorbell.needsPrompt(unreadPrompt))
    }

    func testNewEnvelopeRingsOnceAndCoversTheOld() {
        var arrived = MailboxDoorbell.Input()
        arrived.unreadIds = ["a", "b"]
        arrived.coveredIds = MailboxDoorbellSequence.coveredIds(for: ["a"])
        arrived.rungThisEpoch = false
        arrived.epoch = "2|prompt"
        arrived.prompt = .empty
        XCTAssertEqual(MailboxDoorbell.decide(arrived), .ring)
        var beforeRead = arrived
        beforeRead.prompt = nil
        XCTAssertTrue(MailboxDoorbell.needsPrompt(beforeRead))
        let covered = MailboxDoorbellSequence.coveredIds(for: arrived.unreadIds)
        XCTAssertEqual(covered, ["a", "b"])

        var later = arrived
        later.coveredIds = covered
        later.epoch = "3|prompt"
        XCTAssertEqual(MailboxDoorbell.decide(later), .skip(reason: "already_covered"))
    }

    func testDraftSkipRechecksAndRingsOnceTheDraftIsGone() {
        let start = Date(timeIntervalSince1970: 1_000)
        var held = MailboxDoorbell.Input()
        held.unreadIds = ["env"]
        held.prompt = .draft
        held.epoch = "1|prompt"
        let skipped = MailboxDoorbell.decide(held)
        XCTAssertEqual(skipped, .skip(reason: "draft"))
        let waiting = MailboxDoorbellSequence.plan(
            decision: skipped,
            attempts: [],
            now: start,
            busyExhausted: false,
            strandedDoorbell: false,
            epoch: held.epoch
        )
        XCTAssertEqual(waiting.rearm, .after(MailboxDoorbellSequence.draftRecheckDelays[0]))

        var cleared = held
        cleared.prompt = .empty
        cleared.now = start.addingTimeInterval(5)
        let decision = MailboxDoorbell.decide(cleared)
        XCTAssertEqual(decision, .ring)
        let plan = MailboxDoorbellSequence.plan(
            decision: decision,
            attempts: [],
            now: cleared.now,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: waiting.draftWatch,
            epoch: cleared.epoch
        )
        XCTAssertEqual(plan.arrival, .ring)
        XCTAssertEqual(plan.rearm, .none)
        XCTAssertNil(plan.draftWatch)
    }

    func testPersistentDraftStopsRecheckingAfterTheBound() {
        let start = Date(timeIntervalSince1970: 0)
        let ids: Set<String> = ["a"]
        var watch: MailboxDoorbellSequence.DraftWatch?
        var now = start
        var scheduled: [TimeInterval] = []
        for _ in 0..<40 {
            let step = MailboxDoorbellSequence.nextDraftRecheck(
                watch: watch,
                epoch: "1|prompt",
                unreadIds: ids,
                now: now
            )
            watch = step.watch
            guard case .after(let delay) = step.rearm else {
                XCTFail("the same unread mail keeps a look")
                return
            }
            scheduled.append(delay)
            now = now.addingTimeInterval(delay)
            if now.timeIntervalSince(start) > MailboxDoorbellSequence.draftRecheckBound {
                break
            }
        }
        XCTAssertEqual(Array(scheduled.prefix(3)), MailboxDoorbellSequence.draftRecheckDelays)
        XCTAssertFalse(scheduled.dropFirst(3).contains { $0 != MailboxDoorbellSequence.draftRecheckInterval })
        XCTAssertGreaterThan(now.timeIntervalSince(start), MailboxDoorbellSequence.draftRecheckBound)
        XCTAssertEqual(watch?.exhausted, true)
        XCTAssertEqual(watch?.ids, ids)
        XCTAssertEqual(scheduled.last, MailboxDoorbellSequence.draftRecheckInterval)

        let kept = MailboxDoorbellSequence.nextDraftRecheck(
            watch: watch,
            epoch: "1|prompt",
            unreadIds: ids,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(kept.rearm, .after(MailboxDoorbellSequence.draftRecheckInterval))
        XCTAssertEqual(kept.watch?.exhausted, true)

        let turned = MailboxDoorbellSequence.nextDraftRecheck(
            watch: kept.watch,
            epoch: "2|prompt",
            unreadIds: ids,
            now: now
        )
        XCTAssertEqual(turned.rearm, .after(MailboxDoorbellSequence.draftRecheckDelays[0]))
        XCTAssertEqual(turned.watch?.exhausted, false)
        XCTAssertEqual(turned.watch?.startedAt, now)
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

    /// W3. The inbox check drops only snapshot ids that are gone.
    func testInboxCheckDropsOnlyGoneIds() {
        let dropped = MailboxDoorbellSequence.droppedIds(
            snapshot: ["a", "b", "c"],
            stillPending: ["b"]
        )
        XCTAssertEqual(dropped, ["a", "c"])
        XCTAssertFalse(dropped.contains("b"))
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

    /// A new unread id starts at 5 seconds, including after the old series
    /// has passed its 10 minutes. The same ids stay on the 60 second look.
    func testNewMailRestartsADraftSeries() {
        let start = Date(timeIntervalSince1970: 0)
        let first = MailboxDoorbellSequence.nextDraftRecheck(
            watch: nil,
            epoch: "1|prompt",
            unreadIds: ["a"],
            now: start
        )
        let during = MailboxDoorbellSequence.nextDraftRecheck(
            watch: first.watch,
            epoch: "1|prompt",
            unreadIds: ["a", "b"],
            now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(during.rearm, .after(MailboxDoorbellSequence.draftRecheckDelays[0]))
        XCTAssertEqual(during.watch?.startedAt, start.addingTimeInterval(5))
        XCTAssertEqual(during.watch?.ids, ["a", "b"])

        let (watch, end) = exhaustedDraftWatch(epoch: "1|prompt", unreadIds: ["a"], start: start)
        XCTAssertEqual(watch?.exhausted, true)
        let later = end.addingTimeInterval(1_800)
        let fresh = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "draft"),
            attempts: [],
            now: later,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: watch,
            epoch: "1|prompt",
            unreadIds: ["b"]
        )
        XCTAssertEqual(fresh.rearm, .after(MailboxDoorbellSequence.draftRecheckDelays[0]))
        XCTAssertEqual(fresh.draftWatch?.ids, ["b"])
        XCTAssertEqual(fresh.draftWatch?.startedAt, later)
        XCTAssertEqual(fresh.draftWatch?.exhausted, false)

        let same = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "draft"),
            attempts: [],
            now: later,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: watch,
            epoch: "1|prompt",
            unreadIds: ["a"]
        )
        XCTAssertEqual(same.rearm, .after(MailboxDoorbellSequence.draftRecheckInterval))
        XCTAssertEqual(same.draftWatch?.ids, ["a"])
    }

    /// Mail that was read leaves its watch behind. The next envelope, held
    /// by a draft in the same idle period, gets its own 5 second look.
    func testStaleWatchDoesNotShortenTheNextEnvelope() {
        let start = Date(timeIntervalSince1970: 0)
        let first = MailboxDoorbellSequence.nextDraftRecheck(
            watch: nil,
            epoch: "1|prompt",
            unreadIds: ["a"],
            now: start
        )
        XCTAssertEqual(first.rearm, .after(5))
        let later = start.addingTimeInterval(660)
        let plan = MailboxDoorbellSequence.plan(
            decision: .skip(reason: "draft"),
            attempts: [],
            now: later,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: first.watch,
            epoch: "1|prompt",
            unreadIds: ["b"]
        )
        XCTAssertEqual(plan.rearm, .after(MailboxDoorbellSequence.draftRecheckDelays[0]))
        XCTAssertEqual(plan.draftWatch?.startedAt, later)
        XCTAssertEqual(plan.draftWatch?.ids, ["b"])
        XCTAssertEqual(plan.draftWatch?.steps, 1)
    }

    /// Past the bound, the same draft keeps a 60 second look. Clearing the
    /// composer rings on that look and drops the watch.
    func testLongDraftRingsOnceTheComposerClears() {
        let start = Date(timeIntervalSince1970: 0)
        let (watch, end) = exhaustedDraftWatch(epoch: "1|prompt", unreadIds: ["a"], start: start)
        var held = MailboxDoorbell.Input()
        held.unreadIds = ["a"]
        held.prompt = .draft
        held.epoch = "1|prompt"
        let still = MailboxDoorbellSequence.plan(
            decision: MailboxDoorbell.decide(held),
            attempts: [],
            now: end,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: watch,
            epoch: held.epoch,
            unreadIds: ["a"]
        )
        XCTAssertEqual(still.rearm, .after(MailboxDoorbellSequence.draftRecheckInterval))

        var cleared = held
        cleared.prompt = .empty
        let decision = MailboxDoorbell.decide(cleared)
        XCTAssertEqual(decision, .ring)
        let plan = MailboxDoorbellSequence.plan(
            decision: decision,
            attempts: [],
            now: end,
            busyExhausted: false,
            strandedDoorbell: false,
            draftWatch: still.draftWatch,
            epoch: cleared.epoch,
            unreadIds: ["a"]
        )
        XCTAssertEqual(plan.arrival, .ring)
        XCTAssertEqual(plan.rearm, .none)
        XCTAssertNil(plan.draftWatch)
    }

    /// An empty live set drops the watch. Mail that is still unread keeps it.
    func testPruneDropsAWatchWhenNoMailRemains() {
        let watch = MailboxDoorbellSequence.DraftWatch(
            startedAt: Date(timeIntervalSince1970: 0),
            steps: 1,
            epoch: "1|prompt",
            ids: ["a"],
            exhausted: false
        )
        XCTAssertNil(MailboxDoorbellSequence.draftWatchAfterPrune(watch: watch, liveIds: []))
        XCTAssertEqual(
            MailboxDoorbellSequence.draftWatchAfterPrune(watch: watch, liveIds: ["a"]),
            watch
        )
    }

    /// Submit coverage and the unread ids the idle path names. Breaking
    /// either seam rings a covered envelope again.
    func testSubmitRecordsTheQueuedIdsTheIdlePathNames() {
        let entries = [entry(id: "a"), entry(id: "b")]
        let ids = MailboxDoorbellSequence.unreadIds(in: entries)
        XCTAssertEqual(ids, ["a", "b"])

        var ledger = MailboxDoorbell.Ledger()
        ledger.draftWatch = MailboxDoorbellSequence.DraftWatch(
            startedAt: Date(timeIntervalSince1970: 0),
            steps: 2,
            epoch: "1|prompt",
            ids: ["a"],
            exhausted: false
        )
        MailboxDoorbellSequence.coverAfterSubmit(ledger: &ledger, unread: ids)
        XCTAssertEqual(ledger.coveredIds, ["a", "b"])
        XCTAssertNil(ledger.draftWatch)

        var base = MailboxDoorbell.Input()
        base.prompt = .empty
        base.rungThisEpoch = false
        base.epoch = "2|prompt"
        let named = MailboxDoorbellSequence.namingUnread(
            base,
            entries: entries,
            coveredIds: ledger.coveredIds
        )
        XCTAssertEqual(named.unreadIds, ["a", "b"])
        XCTAssertEqual(named.coveredIds, ["a", "b"])
        XCTAssertEqual(MailboxDoorbell.decide(named), .skip(reason: "already_covered"))
        XCTAssertFalse(MailboxDoorbell.needsPrompt(named))

        var unnamed = base
        unnamed.coveredIds = ledger.coveredIds
        XCTAssertEqual(MailboxDoorbell.decide(unnamed), .ring)
    }

    private func exhaustedDraftWatch(
        epoch: String,
        unreadIds: Set<String>,
        start: Date
    ) -> (MailboxDoorbellSequence.DraftWatch?, Date) {
        var watch: MailboxDoorbellSequence.DraftWatch?
        var now = start
        for _ in 0..<40 {
            let step = MailboxDoorbellSequence.nextDraftRecheck(
                watch: watch,
                epoch: epoch,
                unreadIds: unreadIds,
                now: now
            )
            watch = step.watch
            guard case .after(let delay) = step.rearm else { break }
            now = now.addingTimeInterval(delay)
            if watch?.exhausted == true { break }
        }
        return (watch, now)
    }
}
