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
            "c11 mail waiting: run c11 mailbox recv --ack"
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

    func testRecentInterruptionDefersDoorbellUntilNextLook() {
        var transitioning = MailboxDoorbell.Input(prompt: .empty)
        transitioning.journalInterruptionSettling = true
        XCTAssertEqual(
            MailboxDoorbell.decide(transitioning),
            .deferRing(after: MailboxDoorbellSequence.shortRecheck)
        )
        transitioning.journalInterruptionSettling = false
        XCTAssertEqual(MailboxDoorbell.decide(transitioning), .ring)
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

    func testPreReturnRefusesWhenCodexStartsANewTurnDuringPasteDelay() {
        XCTAssertEqual(
            MailboxDoorbellSequence.preReturn(
                rowIsCurrent: true,
                operatorInputUnchanged: true,
                agentOwnsTerminal: true,
                captured: true,
                prompt: .draft,
                composer: MailboxDoorbell.text,
                journalTurnOpen: true
            ),
            .pastedNotSubmitted
        )
    }

    func testPreReturnRefusesDuringCodexInterruptionTransition() {
        XCTAssertEqual(
            MailboxDoorbellSequence.preReturn(
                rowIsCurrent: true,
                operatorInputUnchanged: true,
                agentOwnsTerminal: true,
                captured: true,
                prompt: .draft,
                composer: MailboxDoorbell.text,
                journalInterruptionSettling: true
            ),
            .pastedNotSubmitted
        )
    }

    func testBusyInputTransactionSchedulesAnotherMailboxLook() {
        let state = MailboxStdinBufferStore()
        let surface = UUID()
        var gate = gateAt(11)
        gate.inputTransactionActive = true
        let captures = Box<[Bool]>([])
        var rechecks = 0
        let admitted = MailboxStdinDelivery.deliver(
            state: state,
            surfaceId: surface,
            entry: entry(id: "during-input-transaction"),
            gate: gate,
            logEvicted: { _ in },
            ringInput: emptyScreen(captures),
            noteInputTransactionHeld: { rechecks += 1 }
        )
        guard case .buffered = admitted else { return XCTFail("expected a buffer, got \(admitted)") }
        XCTAssertEqual(rechecks, 1)
        XCTAssertEqual(captures.value, [], "do not read or ring while another input owns the slot")
        XCTAssertEqual(state.buffer.pendingCount(surfaceId: surface), 1)
    }

    func testPreReturnRefusesAnOperatorKeystrokeDuringPasteDelay() {
        XCTAssertEqual(
            MailboxDoorbellSequence.preReturn(
                rowIsCurrent: true,
                operatorInputUnchanged: false,
                agentOwnsTerminal: true,
                captured: true,
                prompt: .draft,
                composer: MailboxDoorbell.text
            ),
            .pastedNotSubmitted
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

/// C11-414 and C11-400 K/M/G. A held composer (a draft, an unreadable
/// prompt, or the stranded doorbell line) looks again on one bounded series:
/// 5, 15, 30 s, then every 60 s. Every look is named so it can be logged.
final class HeldComposerSeriesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func plan(
        _ decision: MailboxDoorbell.Decision,
        stranded: Bool = false,
        watch: MailboxDoorbellSequence.DraftWatch? = nil,
        epoch: String = "1|prompt",
        ids: Set<String> = ["a"],
        at now: Date? = nil
    ) -> MailboxDoorbellSequence.Plan {
        MailboxDoorbellSequence.plan(
            decision: decision,
            attempts: [],
            now: now ?? start,
            busyExhausted: false,
            strandedDoorbell: stranded,
            draftWatch: watch,
            epoch: epoch,
            unreadIds: ids
        )
    }

    /// Follows a held skip for `looks` looks and returns the delays.
    private func series(
        _ decision: MailboxDoorbell.Decision,
        stranded: Bool = false,
        looks: Int
    ) -> (delays: [TimeInterval], relooks: [String?], watch: MailboxDoorbellSequence.DraftWatch?) {
        var watch: MailboxDoorbellSequence.DraftWatch?
        var now = start
        var delays: [TimeInterval] = []
        var relooks: [String?] = []
        for _ in 0..<looks {
            let step = plan(decision, stranded: stranded, watch: watch, at: now)
            watch = step.draftWatch
            relooks.append(step.relook)
            guard case .after(let delay) = step.rearm else { break }
            delays.append(delay)
            now = now.addingTimeInterval(delay)
        }
        return (delays, relooks, watch)
    }

    /// C11-414 part 2: an unreadable prompt used to wait for the next envelope.
    func testUnknownPromptLooksAgainOnTheHeldSeries() {
        let run = series(.skip(reason: "unknown_prompt"), looks: 40)
        XCTAssertEqual(run.delays.count, 40)
        XCTAssertEqual(Array(run.delays.prefix(3)), [5, 15, 30])
        XCTAssertTrue(run.delays.dropFirst(3).allSatisfy { $0 == 60 })
        XCTAssertTrue(run.relooks.allSatisfy { $0 == "unknown_prompt" })
        XCTAssertEqual(run.watch?.exhausted, true)
    }

    /// The unknown series ends on a ring, on no unread mail, on covered mail,
    /// and on a closed gate. It never rings on its own.
    func testUnknownSeriesEndsOnEveryOtherDecision() {
        let watch = series(.skip(reason: "unknown_prompt"), looks: 3).watch
        for decision: MailboxDoorbell.Decision in [
            .ring, .skip(reason: "no_mail"), .skip(reason: "already_covered"),
            .skip(reason: "gate_closed"), .skip(reason: "once_per_idle"),
        ] {
            let next = plan(decision, watch: watch)
            XCTAssertEqual(next.rearm, .none, "\(decision)")
            XCTAssertNil(next.draftWatch, "\(decision)")
            XCTAssertNil(next.relook, "\(decision)")
        }
    }

    /// An unreadable prompt that becomes a draft, or back, keeps one series.
    func testDraftAndUnknownShareOneSeries() {
        let first = plan(.skip(reason: "unknown_prompt"))
        XCTAssertEqual(first.rearm, .after(5))
        let second = plan(.skip(reason: "draft"), watch: first.draftWatch, at: start.addingTimeInterval(5))
        XCTAssertEqual(second.rearm, .after(15))
        let third = plan(.skip(reason: "unknown_prompt"), watch: second.draftWatch, at: start.addingTimeInterval(20))
        XCTAssertEqual(third.rearm, .after(30))
    }

    func testDialogKeepsLookingUntilTheComposerChanges() {
        let run = series(.skip(reason: "dialog"), looks: 40)
        XCTAssertEqual(run.delays.count, 40)
        XCTAssertEqual(Array(run.delays.prefix(3)), [5, 15, 30])
        XCTAssertTrue(run.delays.dropFirst(3).allSatisfy { $0 == 60 })
        XCTAssertTrue(run.relooks.allSatisfy { $0 == "dialog" })
        XCTAssertEqual(plan(.ring, watch: run.watch).rearm, .none)
        XCTAssertNil(plan(.ring, watch: run.watch).draftWatch)
    }

    /// C11-400 K: a composer still holding the doorbell line used to look
    /// again every 0.5 s with no bound. It is on the held series now.
    func testStrandedDoorbellLineLooksAgainOnTheBoundedSeries() {
        let run = series(.skip(reason: "draft"), stranded: true, looks: 40)
        XCTAssertEqual(Array(run.delays.prefix(3)), [5, 15, 30])
        XCTAssertTrue(run.delays.allSatisfy { $0 >= 5 })
        XCTAssertTrue(run.relooks.allSatisfy { $0 == "stranded" })
        XCTAssertFalse(run.delays.contains(MailboxDoorbellSequence.shortRecheck))
    }

    /// Once the stranded line is cleared the next look rings, and the series ends.
    func testClearedStrandedLineRingsOnTheNextLook() {
        let held = plan(.skip(reason: "draft"), stranded: true)
        var cleared = MailboxDoorbell.Input()
        cleared.unreadIds = ["a"]
        cleared.prompt = .empty
        let decision = MailboxDoorbell.decide(cleared)
        XCTAssertEqual(decision, .ring)
        let next = plan(decision, watch: held.draftWatch, at: start.addingTimeInterval(5))
        XCTAssertEqual(next.arrival, .ring)
        XCTAssertEqual(next.rearm, .none)
        XCTAssertNil(next.draftWatch)
    }

    /// A Return refused mid-paste (a turn opened, the journal lagged) left the
    /// whole line in the composer, and nothing ever pressed Return on it. The
    /// next look at an idle prompt submits it, even in the same idle period.
    func testStrandedLineIsSubmittedOnAnIdleLook() {
        var input = MailboxDoorbell.Input()
        input.unreadIds = ["a"]
        input.rungThisEpoch = true
        input.strandedPending = true
        input.prompt = nil
        XCTAssertFalse(MailboxDoorbell.needsPrompt(input))
        XCTAssertTrue(MailboxDoorbellSequence.needsStrandedLook(input))

        input.prompt = .draft
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "once_per_idle"))
        XCTAssertEqual(MailboxDoorbellSequence.look(input, composer: .matches, busyExhausted: false), .submitStranded)

        // A new idle period reads the prompt on the ordinary path.
        input.rungThisEpoch = false
        input.strandedPending = false
        XCTAssertEqual(MailboxDoorbellSequence.look(input, composer: .matches, busyExhausted: false), .submitStranded)
    }

    /// Without a refused Return in this idle period, once-per-idle stands and
    /// the prompt is not read.
    func testOncePerIdleStandsWithoutAStrandedLine() {
        var input = MailboxDoorbell.Input()
        input.unreadIds = ["a"]
        input.rungThisEpoch = true
        input.prompt = nil
        XCTAssertFalse(MailboxDoorbellSequence.needsStrandedLook(input))
        XCTAssertEqual(
            MailboxDoorbellSequence.look(input, composer: nil, busyExhausted: false),
            .decide(.skip(reason: "once_per_idle"))
        )
    }

    /// Only the whole line read back exactly is submitted. A prefix stays on
    /// the held series; an edit or a cleared composer stops at once-per-idle.
    func testStrandedSubmitNeedsTheWholeLine() {
        var input = MailboxDoorbell.Input()
        input.unreadIds = ["a"]
        input.rungThisEpoch = true
        input.strandedPending = true
        input.prompt = .draft
        let prefix = MailboxDoorbellSequence.look(input, composer: .notVisible, busyExhausted: false)
        XCTAssertEqual(prefix, .decide(.skip(reason: "draft")))
        XCTAssertEqual(
            MailboxDoorbellSequence.look(input, composer: .changed, busyExhausted: false),
            .decide(.skip(reason: "once_per_idle"))
        )
        input.prompt = .empty
        XCTAssertEqual(
            MailboxDoorbellSequence.look(input, composer: nil, busyExhausted: false),
            .decide(.skip(reason: "once_per_idle"))
        )
    }

    /// A stranded look that is held for any other reason plans from that
    /// reason, so a defer, a cap, a busy read, or a held composer looks again
    /// instead of ending at once-per-idle.
    func testHeldStrandedLookLooksAgain() {
        var base = MailboxDoorbell.Input()
        base.unreadIds = ["a"]
        base.rungThisEpoch = true
        base.strandedPending = true
        base.prompt = .draft

        var quiet = base
        quiet.focused = true
        quiet.operatorKeyAge = 1
        var settling = base
        settling.journalInterruptionSettling = true
        var capped = base
        capped.recentAttempts = MailboxDoorbell.rateCap
        var busy = base
        busy.prompt = nil

        let cases: [(String, MailboxDoorbell.Input, FeedAnswerComposerCheck?, Bool, MailboxDoorbellSequence.Rearm)] = [
            ("quiet_window", quiet, .matches, false, .after(2)),
            ("interruption", settling, .matches, false, .after(MailboxDoorbellSequence.shortRecheck)),
            ("rate_capped", capped, .matches, false, .at(start.addingTimeInterval(MailboxDoorbell.rateWindow))),
            ("busy", busy, nil, true, .after(MailboxDoorbellSequence.shortRecheck)),
            ("prefix", base, .notVisible, false, .after(5)),
        ]
        for (name, input, composer, busyExhausted, rearm) in cases {
            guard case .decide(let decision) = MailboxDoorbellSequence.look(
                input,
                composer: composer,
                busyExhausted: busyExhausted
            ) else {
                XCTFail("\(name) submitted")
                continue
            }
            let next = MailboxDoorbellSequence.plan(
                decision: decision,
                attempts: [start],
                now: start,
                busyExhausted: busyExhausted,
                strandedDoorbell: composer == .notVisible
            )
            XCTAssertEqual(next.rearm, rearm, name)
        }
    }

    /// Every other ring check still holds a stranded line.
    func testStrandedSubmitKeepsEveryOtherRingCheck() {
        var base = MailboxDoorbell.Input()
        base.unreadIds = ["a"]
        base.rungThisEpoch = true
        base.strandedPending = true
        base.prompt = .draft
        let holds: [(String, (inout MailboxDoorbell.Input) -> Void)] = [
            ("no_mail", { $0.hasUnread = false }),
            ("not_stdin", { $0.stdinDelivery = false }),
            ("opted_out", { $0.optedOut = true }),
            ("in_flight", { $0.inFlight = true }),
            ("flagged", { $0.flagged = true }),
            ("rate_capped", { $0.recentAttempts = MailboxDoorbell.rateCap }),
            ("covered", { $0.coveredIds = ["a"] }),
            ("text_box", { $0.textBoxUnsent = true }),
            ("quiet_window", { $0.focused = true; $0.operatorKeyAge = 1 }),
            ("interruption", { $0.journalInterruptionSettling = true }),
        ]
        for (name, mutate) in holds {
            var input = base
            mutate(&input)
            XCTAssertNotEqual(
                MailboxDoorbellSequence.look(input, composer: .matches, busyExhausted: false),
                .submitStranded,
                name
            )
        }
    }

    /// A read that shows the composer without the line clears the belief; an
    /// unreadable one keeps it. A Return pressed on the line counts toward
    /// the cap, and a submit clears the belief.
    func testStrandedBeliefAndCapAccounting() {
        typealias S = MailboxDoorbellSequence
        XCTAssertTrue(S.strandedPendingAfterRead(current: false, prompt: .draft, composer: .matches))
        XCTAssertTrue(S.strandedPendingAfterRead(current: false, prompt: .draft, composer: .notVisible))
        XCTAssertFalse(S.strandedPendingAfterRead(current: true, prompt: .draft, composer: .changed))
        XCTAssertFalse(S.strandedPendingAfterRead(current: true, prompt: .empty, composer: nil))
        XCTAssertTrue(S.strandedPendingAfterRead(current: true, prompt: nil, composer: nil))
        XCTAssertTrue(S.strandedPendingAfterRead(current: true, prompt: .unknown, composer: nil))

        var ledger = MailboxDoorbell.Ledger()
        ledger.strandedPending = true
        ledger.recordStrandedReturn(at: start, epoch: "1|prompt")
        XCTAssertEqual(ledger.rings(at: start), 1)
        XCTAssertTrue(ledger.rung(in: "1|prompt"))
        XCTAssertFalse(ledger.inFlight)
        S.coverAfterSubmit(ledger: &ledger, unread: ["a"])
        XCTAssertFalse(ledger.strandedPending)
    }

    /// C11-400 M: each held look is named for its dispatch line. Other
    /// re-arms are not held looks.
    func testEveryHeldLookIsNamed() {
        XCTAssertEqual(plan(.skip(reason: "draft")).relook, "draft")
        XCTAssertEqual(plan(.skip(reason: "draft"), stranded: true).relook, "stranded")
        XCTAssertEqual(plan(.skip(reason: "unknown_prompt")).relook, "unknown_prompt")
        XCTAssertNil(plan(.deferRing(after: 2)).relook)
        XCTAssertNil(plan(.skip(reason: "rate_capped")).relook)
        XCTAssertNil(MailboxDoorbellSequence.plan(
            decision: .skip(reason: "unavailable"), attempts: [], now: start,
            busyExhausted: true, strandedDoorbell: false
        ).relook)
    }

    func testRecheckLineCarriesReasonAndNextDelay() throws {
        let line = MailboxDispatchLog.serialize(
            event: .doorbellRecheck(id: "A", recipient: "watcher", reason: "unknown_prompt", nextMs: 15_000),
            at: Date(timeIntervalSince1970: 0)
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropLast().utf8)) as? [String: Any])
        XCTAssertEqual(obj["event"] as? String, "handler")
        XCTAssertEqual(obj["handler"] as? String, "stdin")
        XCTAssertEqual(obj["id"] as? String, "A")
        XCTAssertEqual(obj["outcome"] as? String, "doorbell_recheck")
        XCTAssertEqual(obj["reason"] as? String, "unknown_prompt")
        XCTAssertEqual(obj["next_ms"] as? Int, 15_000)
    }

    /// C11-400 G, adopted from the C11-405 verify probes: mail a submitted
    /// ring already covered is skipped before a text-box draft is considered,
    /// so it starts no held series.
    func testRV405CoveredBeatsTextBoxDraft() {
        var input = MailboxDoorbell.Input()
        input.unreadIds = ["a"]
        input.coveredIds = ["a"]
        input.textBoxUnsent = true
        input.prompt = nil
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "already_covered"))
        let covered = plan(MailboxDoorbell.decide(input))
        XCTAssertEqual(covered.rearm, .none)
        XCTAssertNil(covered.draftWatch)
    }
}

final class MailboxNativeDoorbellTests: XCTestCase {
    func testOpenCodeRouteRequiresMatchingHarnessAndProcess() throws {
        let route = try XCTUnwrap(MailboxNativeDoorbell.Route(rawValue: "opencode_plugin"))
        let reg = MailboxNativeDoorbell.Registration(id: UUID(), panelID: UUID(), agentPID: 123,
            processStart: 456, sessionID: UUID().uuidString, route: route, canQueue: false,
            supportsAttemptReplay: true)
        let process = MailboxStdinBuffer.AgentProcess(pid: 123, startTime: 456)
        XCTAssertTrue(reg.matches(process: process, kind: "opencode"))
        XCTAssertFalse(reg.canQueue)
        XCTAssertTrue(reg.supportsAttemptReplay)
        for kind in ["pi", "codex", "claude", "grok"] {
            XCTAssertFalse(reg.matches(process: process, kind: kind))
        }
        XCTAssertFalse(reg.matches(process: .init(pid: 124, startTime: 456), kind: "opencode"))
        XCTAssertFalse(reg.matches(process: .init(pid: 123, startTime: 457), kind: "opencode"))
        XCTAssertFalse(reg.matches(process: nil, kind: "opencode"))
    }

    func testAcceptedCoverageResetsOnlyForANewTUIProcess() {
        let original = MailboxStdinBuffer.AgentProcess(pid: 123, startTime: 456)
        XCTAssertFalse(MailboxNativeDoorbell.shouldResetCoverage(previousProcess: original, currentProcess: original),
                       "a new OpenCode root in the same TUI keeps its accepted unread IDs covered")
        XCTAssertFalse(MailboxNativeDoorbell.shouldResetCoverage(previousProcess: original, currentProcess: nil),
                       "a brief stream disconnect must not lose process identity")
        XCTAssertTrue(MailboxNativeDoorbell.shouldResetCoverage(previousProcess: nil, currentProcess: original))
        XCTAssertTrue(MailboxNativeDoorbell.shouldResetCoverage(
            previousProcess: original, currentProcess: .init(pid: 124, startTime: 456)))
        XCTAssertTrue(MailboxNativeDoorbell.shouldResetCoverage(
            previousProcess: original, currentProcess: .init(pid: 123, startTime: 457)),
            "PID reuse is a new TUI process")
    }

    func testAmbiguousOpenCodeAttemptKeepsItsExactEnvelopeSnapshot() {
        let process = MailboxStdinBuffer.AgentProcess(pid: 123, startTime: 456)
        let attempt = MailboxNativeDoorbell.Attempt(id: UUID(), process: process, ids: ["mail-a"])
        XCTAssertEqual(MailboxNativeDoorbell.reusableAttempt(attempt, process: process,
            unreadIDs: ["mail-a", "mail-b"]), attempt,
            "new mail cannot be folded into an attempt whose prompt result is ambiguous")
        XCTAssertNil(MailboxNativeDoorbell.reusableAttempt(attempt,
            process: .init(pid: 124, startTime: 456), unreadIDs: ["mail-a", "mail-b"]),
            "a different TUI process must retry unread mail with a fresh attempt")
        XCTAssertNil(MailboxNativeDoorbell.reusableAttempt(attempt, process: process,
            unreadIDs: ["mail-b"]), "an attempt with no still-unread envelope is no longer reusable")
    }

    func testAcceptedDeliverySettlesOnlyAfterWorkspaceCallback() {
        let broker = MailboxNativeDoorbell(), reg = registration()
        let sent = expectation(description: "native invitation")
        let settledFrame = expectation(description: "workspace settlement frame")
        let lock = NSLock()
        var settlement: (() -> Void)?
        var settledCount = 0
        broker.register(reg, write: { frame in
            if frame["type"] as? String == "deliver" { sent.fulfill() }
            if frame["type"] as? String == "settled" {
                lock.lock(); settledCount += 1; lock.unlock()
                settledFrame.fulfill()
            }
            return true
        }, close: {})
        defer { broker.disconnect(reg) }
        let request = broker.deliver(reg, timeout: 30) { result, finish in
            XCTAssertEqual(result, .accepted(late: false))
            settlement = finish
        }
        wait(for: [sent], timeout: 1)
        broker.resolve(reg, requestID: request, result: .accepted(late: false))
        lock.lock(); let beforeWorkspace = settledCount; lock.unlock()
        XCTAssertEqual(beforeWorkspace, 0, "the acceptance frame alone cannot confirm Workspace coverage")
        settlement?()
        wait(for: [settledFrame], timeout: 1)
        lock.lock(); let afterWorkspace = settledCount; lock.unlock()
        XCTAssertEqual(afterWorkspace, 1)
    }

    func testAlreadyAdmittedReplayCarriesStableAttemptAndSettlesCoverage() throws {
        let broker = MailboxNativeDoorbell(), reg = registration(route: .opencodePlugin)
        let attemptID = UUID()
        let sent = expectation(description: "attempt id sent")
        let replayed = expectation(description: "already admitted replay")
        let settledFrame = expectation(description: "replay coverage settled")
        var settleCoverage: (() -> Void)?
        broker.register(reg, write: { frame in
            if frame["type"] as? String == "deliver" {
                XCTAssertEqual(frame["attempt_id"] as? String, attemptID.uuidString)
                sent.fulfill()
            }
            if frame["type"] as? String == "settled" { settledFrame.fulfill() }
            return true
        }, close: {})
        defer { broker.disconnect(reg) }
        let request = broker.deliver(reg, attemptID: attemptID) { result, settle in
            XCTAssertEqual(result, .alreadyAdmitted)
            settleCoverage = settle
            replayed.fulfill()
        }
        wait(for: [sent], timeout: 1)
        let frame = try JSONSerialization.data(withJSONObject: [
            "type": "accepted", "delivery_id": request.uuidString, "disposition": "already_admitted",
        ])
        broker.consume(frame, registration: reg)
        wait(for: [replayed], timeout: 1)
        settleCoverage?()
        wait(for: [settledFrame], timeout: 1)
    }

    func testReplacementWritesRetirementFrameBeforeClosingOldStream() {
        let broker = MailboxNativeDoorbell(), old = registration()
        let retired = expectation(description: "old stream retired")
        var frame: [String: Any]?
        broker.register(old, write: { frame = $0; return true }, close: {
            XCTAssertEqual(frame?["type"] as? String, "replaced")
            retired.fulfill()
        })
        let next = registration(panel: old.panelID)
        broker.register(next, write: { _ in true }, close: {})
        wait(for: [retired], timeout: 1)
        XCTAssertEqual(broker.registration(panelID: old.panelID), next)
        broker.disconnect(next)
    }

    func testAcceptanceCoversOriginalIDsWhenListenerClosesBeforeMainHop() {
        let broker = MailboxNativeDoorbell(), reg = registration()
        let sent = expectation(description: "native sent")
        var completion: MailboxNativeDoorbell.Result?
        broker.register(reg, write: { _ in sent.fulfill(); return true }, close: {})
        let request = broker.deliver(reg) { completion = $0 }
        wait(for: [sent], timeout: 1)
        broker.resolve(reg, requestID: request, result: .accepted(late: false))
        broker.disconnect(reg) // Before the queued main-actor callback executes.
        XCTAssertEqual(completion, .accepted(late: false))
        var ledger = MailboxDoorbell.Ledger()
        ledger.beginAttempt(at: Date(), epoch: "idle")
        ledger.endAttempt()
        var covered: Set<String> = []
        let shouldContinue = MailboxNativeDoorbell.recordAcceptance(["offered"], registrationID: reg.id,
            currentRegistrationID: broker.registration(panelID: reg.panelID)?.id,
            nativeCovered: &covered, ledger: &ledger)
        XCTAssertFalse(shouldContinue, "stale acceptance must not trigger another ring")
        XCTAssertEqual(covered, ["offered"])
        XCTAssertEqual(ledger.coveredIds, ["offered"], "mail arriving during the attempt stays uncovered")
        XCTAssertEqual(ledger.rungEpoch, "idle", "route-change handling owns clearing the epoch")
    }

    /// One native ring, then the ring decision for the next envelope, with
    /// `edges` run between the ring's start and its acceptance.
    private func nativeRingThenNextDecision(
        edges: (inout MailboxStdinBuffer, UUID, Date) -> Void,
        afterAcceptance: (inout MailboxStdinBuffer, UUID, Date) -> Void = { _, _, _ in }
    ) -> (rung: String, next: String, decision: MailboxDoorbell.Decision) {
        var buffer = MailboxStdinBuffer()
        var ledger = MailboxDoorbell.Ledger()
        let panel = UUID(), idleAt = Date(timeIntervalSince1970: 1_000)
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: idleAt)
        let rung = buffer.ringEpoch(surfaceId: panel)
        let startedAt = idleAt.addingTimeInterval(40)
        ledger.beginAttempt(at: startedAt, epoch: rung)
        edges(&buffer, panel, startedAt)
        ledger.endAttempt()
        buffer.noteNativeTurnStarted(surfaceId: panel, at: startedAt)
        afterAcceptance(&buffer, panel, startedAt)
        let next = buffer.ringEpoch(surfaceId: panel)
        var input = MailboxDoorbell.Input(nativeRoute: true, epoch: next)
        input.rungThisEpoch = ledger.rung(in: next)
        input.recentAttempts = ledger.rings(at: startedAt)
        input.inFlight = ledger.inFlight
        return (rung, next, MailboxDoorbell.decide(input))
    }

    /// OpenCode's journal dropped the invitation turn's working edge; only its
    /// idle edge landed, before the acceptance. The next envelope rings.
    func testNativeAcceptanceOpensNextIdleWhenOnlyTheIdleEdgeLanded() {
        let result = nativeRingThenNextDecision(edges: { buffer, panel, startedAt in
            buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: startedAt.addingTimeInterval(0.17))
        })
        XCTAssertNotEqual(result.next, result.rung)
        XCTAssertEqual(result.decision, .ring)
    }

    /// The acceptance landed before the idle edge: the turn is working until
    /// that edge, and the edge opens a new idle period that rings.
    func testNativeAcceptanceBeforeIdleEdgeRingsAtThatEdge() {
        var working: String?
        let result = nativeRingThenNextDecision(edges: { _, _, _ in }, afterAcceptance: { buffer, panel, startedAt in
            working = buffer.ringEpoch(surfaceId: panel)
            XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
            buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: startedAt.addingTimeInterval(0.2))
        })
        XCTAssertNotEqual(working, result.rung)
        XCTAssertNotEqual(result.next, result.rung)
        XCTAssertEqual(result.decision, .ring)
    }

    /// Pi and omp report both edges directly: the acceptance changes nothing,
    /// and a second ring inside the new idle period is still refused.
    func testNativeAcceptanceKeepsSeenEdgesAndOncePerIdle() {
        var buffer = MailboxStdinBuffer()
        var ledger = MailboxDoorbell.Ledger()
        let panel = UUID(), idleAt = Date(timeIntervalSince1970: 1_000)
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: idleAt)
        let startedAt = idleAt.addingTimeInterval(40)
        ledger.beginAttempt(at: startedAt, epoch: buffer.ringEpoch(surfaceId: panel))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: startedAt.addingTimeInterval(0.05))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: startedAt.addingTimeInterval(0.1))
        ledger.endAttempt()
        let afterEdges = buffer.ringEpoch(surfaceId: panel)
        buffer.noteNativeTurnStarted(surfaceId: panel, at: startedAt)
        XCTAssertEqual(buffer.ringEpoch(surfaceId: panel), afterEdges)

        // Second envelope rings in the new idle period; a third in that same period does not.
        ledger.beginAttempt(at: startedAt.addingTimeInterval(1), epoch: afterEdges)
        ledger.endAttempt()
        var input = MailboxDoorbell.Input(nativeRoute: true, epoch: afterEdges)
        input.rungThisEpoch = ledger.rung(in: buffer.ringEpoch(surfaceId: panel))
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "once_per_idle"))

        // The typed route's once-per-idle rule is untouched too.
        input.nativeRoute = false
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "once_per_idle"))
    }

    func testAlreadyAdmittedReplayRearmsIdleEpochForLaterMail() {
        let registrationID = UUID()
        let epoch = "idle"
        var ledger = MailboxDoorbell.Ledger()
        ledger.beginAttempt(at: Date(timeIntervalSince1970: 1), epoch: epoch)
        var nativeCovered: Set<String> = []

        XCTAssertTrue(MailboxNativeDoorbell.recordAcceptance(["mail-a"],
            registrationID: registrationID, currentRegistrationID: registrationID,
            nativeCovered: &nativeCovered, ledger: &ledger, rearmEpoch: epoch))
        XCTAssertEqual(nativeCovered, ["mail-a"])
        XCTAssertEqual(ledger.coveredIds, ["mail-a"])
        XCTAssertNil(ledger.rungEpoch)

        var input = MailboxDoorbell.Input(nativeRoute: true, epoch: epoch)
        input.hasUnread = true
        input.unreadIds = ["mail-a", "mail-b"]
        input.coveredIds = ledger.coveredIds
        input.rungThisEpoch = ledger.rung(in: epoch)
        XCTAssertEqual(MailboxDoorbell.decide(input), .ring,
            "the replay covers A but must not strand uncovered B in the same idle period")
    }

    private func nativeProcess(_ parent: pid_t, start: UInt64, tty: dev_t = -1) -> MailboxAgentForeground.ProcessTerminalInfo {
        .init(processGroup: 10, terminalForegroundGroup: 10, terminalDevice: tty,
              isZombie: false, startTime: start, parentPID: parent)
    }

    func testNativeSubscriberAcceptsDetachedDescendantWithoutTTY() {
        let processes: [pid_t: MailboxAgentForeground.ProcessTerminalInfo] = [
            10: nativeProcess(1, start: 100, tty: 7),
            20: nativeProcess(10, start: 200),
            30: nativeProcess(20, start: 300)
        ]
        // The kernel peer is the no-TTY hook's child; agent_pid names its
        // foreground harness. The direct in-process Pi listener also works.
        for (pid, start): (pid_t, UInt64) in [(30, 300), (10, 100)] {
            XCTAssertEqual(MailboxNativeDoorbell.verifiedAgent(peer: .init(pid: pid, startTime: start),
                agentPID: 10, readProcess: { processes[$0] }), processes[10])
        }
    }

    func testNativeSubscriberRejectsUnrelatedCallerEvenOnSameTTY() {
        let processes: [pid_t: MailboxAgentForeground.ProcessTerminalInfo] = [
            10: nativeProcess(1, start: 100, tty: 7),
            20: nativeProcess(1, start: 200, tty: 7)
        ]
        XCTAssertNil(MailboxNativeDoorbell.verifiedAgent(peer: .init(pid: 20, startTime: 200),
            agentPID: 10, readProcess: { processes[$0] }))
        XCTAssertNil(MailboxNativeDoorbell.verifiedAgent(peer: nil,
            agentPID: 10, readProcess: { processes[$0] }))
    }

    func testNativeSubscriberRejectsReusedProcessIdentities() {
        let processes: [pid_t: MailboxAgentForeground.ProcessTerminalInfo] = [
            10: nativeProcess(1, start: 100, tty: 7),
            20: nativeProcess(10, start: 200),
            30: nativeProcess(20, start: 300)
        ]
        let peer = MailboxStdinBuffer.AgentProcess(pid: 30, startTime: 300)
        XCTAssertNil(MailboxNativeDoorbell.verifiedAgent(peer: .init(pid: 30, startTime: 299),
            agentPID: 10, readProcess: { processes[$0] }), "peer replaced since socket acceptance")
        var replacedParent = processes
        replacedParent[20] = nativeProcess(10, start: 400)
        XCTAssertNil(MailboxNativeDoorbell.verifiedAgent(peer: peer, agentPID: 10,
            readProcess: { replacedParent[$0] }), "replacement parent cannot be younger than child")
        for changedPID: pid_t in [10, 20, 30] {
            var reads: [pid_t: Int] = [:]
            XCTAssertNil(MailboxNativeDoorbell.verifiedAgent(peer: peer, agentPID: 10, readProcess: { pid in
                reads[pid, default: 0] += 1
                guard var info = processes[pid] else { return nil }
                if pid == changedPID && reads[pid, default: 0] > 1 { info.startTime += 1 }
                return info
            }), "PID \(changedPID) changed identity during ancestry walk")
        }
    }

    func testOpenCodeClaimRequiresTheForegroundTUIProcessGroupLeader() {
        func process(group: pid_t, foreground: pid_t, tty: dev_t, start: UInt64, parent: pid_t) -> MailboxAgentForeground.ProcessTerminalInfo {
            .init(processGroup: group, terminalForegroundGroup: foreground, terminalDevice: tty,
                  isZombie: false, startTime: start, parentPID: parent)
        }
        let trusted: [pid_t: MailboxAgentForeground.ProcessTerminalInfo] = [
            100: process(group: 100, foreground: 100, tty: 7, start: 100, parent: 1),
            110: process(group: 100, foreground: 100, tty: 7, start: 200, parent: 100),
        ]
        XCTAssertTrue(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 100, peerTTYDevice: 7, panelTTYDevice: 7,
            readProcess: { trusted[$0] }
        ), "the wrapper's c11 CLI child may claim its foreground TUI parent on the target panel")

        XCTAssertFalse(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 110, peerTTYDevice: 7, panelTTYDevice: 7,
            readProcess: { trusted[$0] }
        ), "a child cannot claim itself as the displayed TUI")
        XCTAssertFalse(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 100, peerTTYDevice: 8, panelTTYDevice: 7,
            readProcess: { trusted[$0] }
        ), "claim socket must come from the TUI's own terminal")
        XCTAssertFalse(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 100, peerTTYDevice: 7, panelTTYDevice: 8,
            readProcess: { trusted[$0] }
        ), "a TUI cannot claim a different panel's terminal")
        XCTAssertFalse(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 100, peerTTYDevice: 7, panelTTYDevice: nil,
            readProcess: { trusted[$0] }
        ), "an unknown target panel terminal fails closed")
        XCTAssertFalse(MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
            peerPID: 110, claimedTuiPID: 100, peerTTYDevice: nil, panelTTYDevice: 7,
            readProcess: { trusted[$0] }
        ), "unreadable peer terminal identity fails closed")
    }

    private func registration(panel: UUID = UUID(), pid: pid_t = 123, start: UInt64 = 456,
                              route: MailboxNativeDoorbell.Route = .piExtension) -> MailboxNativeDoorbell.Registration {
        .init(id: UUID(), panelID: panel, agentPID: pid, processStart: start,
              sessionID: UUID().uuidString, route: route, canQueue: false)
    }

    func testNativeDeliveryUsesCommonGuardsWithoutReadingDraft() {
        let panel = UUID()
        let state = MailboxStdinBufferStore()
        state.buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: Date())
        let entry = MailboxStdinBuffer.Entry(id: "mail", recipientName: "pi", block: "body", bufferedAt: Date())
        var captures = 0
        let gate = MailboxStdinDelivery.Gate(nativeRoute: true, ownsTerminal: true, inputTransactionActive: true)
        let result = MailboxStdinDelivery.deliver(state: state, surfaceId: panel, entry: entry, gate: gate,
            logEvicted: { _ in }, ringInput: { capture in
                if capture { captures += 1 }
                return MailboxDoorbell.Input(nativeRoute: true, focused: true, operatorKeyAge: 0, textBoxUnsent: true, prompt: nil)
            })
        XCTAssertEqual(result, .doorbell(bytes: 4, effect: .ring))
        XCTAssertEqual(captures, 0)
        let stranded = MailboxDoorbell.Input(nativeRoute: true, rungThisEpoch: true, prompt: nil, strandedPending: true)
        XCTAssertFalse(MailboxDoorbellSequence.needsStrandedLook(stranded))
        XCTAssertFalse(MailboxDoorbellSequence.submitsStranded(stranded, composer: .matches))
        var input = MailboxDoorbell.Input(nativeRoute: true, prompt: nil)
        input.flagged = true; XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "flagged"))
        input.flagged = false; input.optedOut = true; XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "opted_out"))
        input.optedOut = false; input.stdinDelivery = false; XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "not_stdin"))
        input.stdinDelivery = true; input.recentAttempts = MailboxDoorbell.rateCap
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "rate_capped"))
        input.recentAttempts = 0; input.unreadIds = ["mail"]; input.coveredIds = ["mail"]
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "already_covered"))
    }

    func testIdleOnlyNativeWaitsThroughTurnAndThenRingsWithoutCapture() {
        let panel = UUID(), state = MailboxStdinBufferStore()
        state.buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: Date())
        let entry = MailboxStdinBuffer.Entry(id: "mail", recipientName: "pi", block: "body", bufferedAt: Date())
        var reads = 0
        let input: (Bool) -> MailboxDoorbell.Input = { capture in
            if capture { reads += 1 }; return .init(nativeRoute: true, prompt: nil)
        }
        let busy = MailboxStdinDelivery.Gate(nativeRoute: true, ownsTerminal: true, journalTurnOpen: true)
        XCTAssertEqual(MailboxStdinDelivery.deliver(state: state, surfaceId: panel, entry: entry, gate: busy,
            logEvicted: { _ in }, ringInput: input), .buffered(bytes: 4))
        state.buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: Date().addingTimeInterval(1))
        XCTAssertEqual(MailboxStdinDelivery.deliver(state: state, surfaceId: panel, entry: entry,
            gate: .init(nativeRoute: true, ownsTerminal: true), logEvicted: { _ in }, ringInput: input), .doorbell(bytes: 4, effect: .ring))
        XCTAssertEqual(reads, 0)
    }

    func testTimeoutFallsThroughTypedTurnGateAndLateAcceptanceIsReportedOnce() {
        let broker = MailboxNativeDoorbell(), reg = registration()
        let dispatched = expectation(description: "native dispatched")
        let failed = expectation(description: "timeout enters typed gate")
        let accepted = expectation(description: "late acceptance")
        let state = MailboxStdinBufferStore()
        state.buffer.noteAgentTurn(surfaceId: reg.panelID, atPrompt: false, at: Date())
        broker.register(reg, write: { frame in
            XCTAssertEqual(frame["text"] as? String, MailboxDoorbell.text)
            dispatched.fulfill(); return true
        }, close: {})
        let request = broker.deliver(reg, timeout: 0.03) { result in
            switch result {
            case .failed(let reason):
                XCTAssertEqual(reason, "native_timeout")
                // Native acceptance already started a turn, but its ack is late.
                // The production typed admission path must buffer without capture.
                let entry = MailboxStdinBuffer.Entry(id: "mail", recipientName: "pi", block: "body", bufferedAt: Date())
                let outcome = MailboxStdinDelivery.deliver(state: state, surfaceId: reg.panelID, entry: entry,
                    gate: .init(ownsTerminal: true, journalTurnOpen: true), logEvicted: { _ in },
                    ringInput: { _ in XCTFail("typed fallback read a running turn"); return .init() })
                XCTAssertEqual(outcome, .buffered(bytes: 4)); failed.fulfill()
            case .accepted(let late): XCTAssertTrue(late); accepted.fulfill()
            case .alreadyAdmitted: XCTFail("timeout attempt cannot replay as already admitted")
            }
        }
        wait(for: [dispatched, failed], timeout: 2)
        broker.resolve(reg, requestID: request, result: .accepted(late: false))
        broker.resolve(reg, requestID: request, result: .accepted(late: false))
        wait(for: [accepted], timeout: 1)
        broker.disconnect(reg)
    }

    /// Each consumer reason the log names is distinct from a timeout; unknown
    /// or absent reasons stay `native_rejected`.
    func testConsumerRejectionReasonsNameTheNativeFailure() throws {
        let cases: [(String?, String)] = [
            ("transcript_unavailable", "native_transcript_unavailable"),
            ("inbox_unavailable", "native_inbox_unavailable"),
            ("inbox_write_failed", "native_inbox_write_failed"),
            ("unconfirmed", "native_unconfirmed"),
            ("refused", "native_refused"),
            ("unsupported_invitation", "native_unsupported_invitation"),
            ("session_conflict", "native_session_conflict"),
            (nil, "native_rejected"),
            ("anything else", "native_rejected"),
        ]
        for (reason, expected) in cases {
            let broker = MailboxNativeDoorbell(), reg = registration()
            let offered = offerNatively(broker, reg)
            let failed = expectation(description: expected)
            offered.reply = { result in XCTAssertEqual(result, .failed(expected)); failed.fulfill() }
            var frame: [String: Any] = ["type": "rejected", "delivery_id": try offered.deliveryID()]
            if let reason { frame["reason"] = reason }
            broker.consume(try JSONSerialization.data(withJSONObject: frame), registration: reg)
            wait(for: [failed], timeout: 1)
            broker.disconnect(reg)
        }
    }

    func testAcceptanceAfterNamedRejectionIsLate() throws {
        let broker = MailboxNativeDoorbell(), reg = registration()
        let offered = offerNatively(broker, reg)
        let failed = expectation(description: "unconfirmed"), accepted = expectation(description: "late")
        offered.reply = { result in
            if result == .failed("native_unconfirmed") { failed.fulfill() }
            if result == .accepted(late: true) { accepted.fulfill() }
        }
        let id = try offered.deliveryID()
        broker.consume(try JSONSerialization.data(withJSONObject: ["type": "rejected", "delivery_id": id, "reason": "unconfirmed"]), registration: reg)
        wait(for: [failed], timeout: 1)
        broker.consume(try JSONSerialization.data(withJSONObject: ["type": "accepted", "delivery_id": id]), registration: reg)
        wait(for: [accepted], timeout: 1)
        broker.disconnect(reg)
    }

    private final class NativeOffer {
        private let lock = NSLock()
        private var id: String?
        private var handler: ((MailboxNativeDoorbell.Result) -> Void)?
        let sent: XCTestExpectation
        init(_ sent: XCTestExpectation) { self.sent = sent }
        func record(_ value: String?) { lock.lock(); id = value; lock.unlock(); sent.fulfill() }
        func deliveryID() throws -> String { lock.lock(); defer { lock.unlock() }; return try XCTUnwrap(id) }
        var reply: ((MailboxNativeDoorbell.Result) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return handler }
            set { lock.lock(); handler = newValue; lock.unlock() }
        }
    }

    /// Registers a listener, offers once with a long deadline, and waits for the
    /// deliver frame so its delivery ID is known.
    private func offerNatively(_ broker: MailboxNativeDoorbell, _ reg: MailboxNativeDoorbell.Registration) -> NativeOffer {
        let offer = NativeOffer(expectation(description: "deliver frame"))
        broker.register(reg, write: { frame in
            if frame["type"] as? String == "deliver" { offer.record(frame["delivery_id"] as? String) }
            return true
        }, close: {})
        broker.deliver(reg, timeout: 30) { result in offer.reply?(result) }
        wait(for: [offer.sent], timeout: 1)
        return offer
    }

    func testDeadlineDoesNotWaitForAnotherPanelSocketWrite() {
        let broker = MailboxNativeDoorbell(), first = registration(), second = registration()
        let writing = expectation(description: "first socket blocked")
        let deadline = expectation(description: "second deadline is independent of writer")
        let release = DispatchSemaphore(value: 0)
        broker.register(first, write: { _ in
            writing.fulfill(); _ = release.wait(timeout: .now() + 2); return true
        }, close: {})
        broker.register(second, write: { _ in true }, close: {})
        broker.deliver(first, timeout: 5) { _ in }
        wait(for: [writing], timeout: 1)
        broker.deliver(second, timeout: 0.03) { result in
            XCTAssertEqual(result, .failed("native_timeout")); deadline.fulfill()
        }
        wait(for: [deadline], timeout: 0.3)
        release.signal()
        broker.disconnect(first)
        broker.disconnect(second)
    }

    func testReplacementRejectsOldInFlightAndOldDisconnectCannotRemoveNewSession() {
        let broker = MailboxNativeDoorbell(), old = registration()
        let sent = expectation(description: "old sent"), failed = expectation(description: "old failed")
        broker.register(old, write: { frame in
            if frame["type"] as? String == "deliver" { sent.fulfill() }
            return true
        }, close: {})
        let request = broker.deliver(old) { result in XCTAssertEqual(result, .failed("native_replaced")); failed.fulfill() }
        wait(for: [sent], timeout: 1)
        let next = registration(panel: old.panelID)
        broker.register(next, write: { _ in true }, close: {})
        broker.disconnect(old)
        broker.resolve(old, requestID: request, result: .accepted(late: false))
        XCTAssertEqual(broker.registration(panelID: old.panelID), next)
        wait(for: [failed], timeout: 1)
        broker.disconnect(next)
    }

    func testProcessIdentityRejectsPIDReuseAndOtherHarness() {
        let reg = registration()
        XCTAssertTrue(reg.matches(process: .init(pid: 123, startTime: 456), kind: "pi"))
        XCTAssertFalse(reg.matches(process: .init(pid: 123, startTime: 457), kind: "pi"))
        XCTAssertFalse(reg.matches(process: .init(pid: 124, startTime: 456), kind: "pi"))
        XCTAssertFalse(reg.matches(process: .init(pid: 123, startTime: 456), kind: "codex"))
        XCTAssertFalse(reg.matches(process: nil, kind: "pi"))
    }

    func testOmpRouteBindsOnlyToOmpAndHasAWireName() {
        let omp = MailboxNativeDoorbell.Registration(id: UUID(), panelID: UUID(), agentPID: 123, processStart: 456,
            sessionID: UUID().uuidString, route: .ompExtension, canQueue: false)
        XCTAssertEqual(MailboxNativeDoorbell.Route(rawValue: "omp_extension"), .ompExtension)
        XCTAssertTrue(omp.matches(process: .init(pid: 123, startTime: 456), kind: "omp"))
        // A Pi panel never accepts an omp stream, nor the reverse.
        XCTAssertFalse(omp.matches(process: .init(pid: 123, startTime: 456), kind: "pi"))
        XCTAssertFalse(registration().matches(process: .init(pid: 123, startTime: 456), kind: "omp"))
        XCTAssertFalse(omp.matches(process: .init(pid: 123, startTime: 457), kind: "omp"))
    }

    func testOmpRejectedBusyDoesNotStickFallback() {
        // omp has no typed composer reader: a busy reject (before any side
        // effect) must try native again at the next ring.
        XCTAssertFalse(MailboxNativeDoorbell.failureSticksToTypedGate(route: .ompExtension, reason: "native_rejected"))
        // Pi has a typed reader, so its busy reject is the seam's typed handoff.
        XCTAssertTrue(MailboxNativeDoorbell.failureSticksToTypedGate(route: .piExtension, reason: "native_rejected"))
        // A timeout may follow a turn that already started; it still sticks.
        for reason in ["native_timeout", "native_unavailable", "native_disconnected", "native_replaced", "native_write_failed"] {
            XCTAssertTrue(MailboxNativeDoorbell.failureSticksToTypedGate(route: .ompExtension, reason: reason), reason)
        }
        XCTAssertTrue(MailboxNativeDoorbell.failureSticksToTypedGate(route: .claudeInbox, reason: "native_rejected"))
    }

    func testOmpHardFailureAdmitsNewMailWithoutRetryingTheSameFailedIDs() {
        let broker = MailboxNativeDoorbell(), reg = registration(route: .ompExtension)
        let state = MailboxStdinBufferStore()
        state.buffer.noteAgentTurn(surfaceId: reg.panelID, atPrompt: true, at: Date())
        var fallback: MailboxNativeDoorbell.Fallback?
        var nativeCovered: Set<String> = []
        let sent = [expectation(description: "first native invitation"), expectation(description: "new mail invitation")]
        var writes = 0
        broker.register(reg, write: { frame in
            XCTAssertEqual(frame["text"] as? String, MailboxDoorbell.text)
            if writes < sent.count { sent[writes].fulfill() }
            writes += 1
            return true
        }, close: {})
        defer { broker.disconnect(reg) }

        func nativeAvailable(arrivingID: String? = nil) -> Bool {
            let unread = Set(state.buffer.queuedEntries(surfaceId: reg.panelID).map(\.id))
            return fallback?.blocksNative(registrationID: reg.id, unreadIDs: unread,
                coveredIDs: state.doorbell.ledger(for: reg.panelID).coveredIds, arrivingID: arrivingID) != true
        }
        func admit(_ id: String) -> MailboxStdinDelivery.AdmitResult {
            // Workspace reads the admission gate before enqueue. An active
            // input transaction must not hide newly available native delivery.
            let gate = MailboxStdinDelivery.Gate(nativeRoute: nativeAvailable(arrivingID: id),
                ownsTerminal: true, inputTransactionActive: true)
            return MailboxStdinDelivery.deliver(state: state, surfaceId: reg.panelID,
                entry: .init(id: id, recipientName: "omp", block: "body", bufferedAt: Date()), gate: gate,
                logEvicted: { _ in }, ringInput: { capture in
                    XCTAssertFalse(capture, "omp must not fall through to a composer reader")
                    return .init(nativeRoute: nativeAvailable(), prompt: nil)
                })
        }
        func offer(_ ids: Set<String>) -> UUID {
            broker.deliver(reg, timeout: 30) { result in
                switch result {
                case .failed(let reason):
                    fallback = .init(registration: reg, ids: ids, reason: reason)
                case .accepted(let late):
                    XCTAssertTrue(late)
                    state.doorbell.update(surfaceId: reg.panelID) { ledger in
                        _ = MailboxNativeDoorbell.recordAcceptance(ids, registrationID: reg.id,
                            currentRegistrationID: broker.registration(panelID: reg.panelID)?.id,
                            nativeCovered: &nativeCovered, ledger: &ledger)
                    }
                case .alreadyAdmitted:
                    XCTFail("this test does not send a replayed acceptance")
                }
            }
        }

        XCTAssertEqual(admit("first"), .doorbell(bytes: 4, effect: .ring))
        let first = offer(["first"])
        wait(for: [sent[0]], timeout: 1)
        broker.resolve(reg, requestID: first, result: .failed("native_timeout"))
        XCTAssertFalse(nativeAvailable(), "rechecks must not retry the failed envelope")
        XCTAssertEqual(admit("first"), .buffered(bytes: 4), "redelivery of one ID is not new mail")

        XCTAssertEqual(admit("second"), .doorbell(bytes: 4, effect: .ring))
        let second = offer(["first", "second"])
        wait(for: [sent[1]], timeout: 1)
        broker.resolve(reg, requestID: second, result: .failed("native_write_failed"))
        XCTAssertFalse(nativeAvailable(), "a failed retry must latch its new IDs too")
        XCTAssertEqual(admit("second"), .buffered(bytes: 4))

        broker.resolve(reg, requestID: first, result: .accepted(late: false))
        XCTAssertEqual(nativeCovered, ["first"], "late acceptance covers only dispatch-time IDs")
        XCTAssertFalse(nativeAvailable(), "late acceptance must not clear the newer failure")
        XCTAssertEqual(admit("third"), .doorbell(bytes: 4, effect: .ring))
    }

    func testNativeFallbackPreservesTypedRoutesAndIgnoresCoveredNewMail() {
        for route: MailboxNativeDoorbell.Route in [.ompExtension, .piExtension, .claudeInbox] {
            let reg = registration(route: route)
            let fallback = MailboxNativeDoorbell.Fallback(registration: reg, ids: ["failed"], reason: "native_timeout")
            XCTAssertTrue(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed"], coveredIDs: []))
            XCTAssertEqual(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed", "new"], coveredIDs: []),
                           route != .ompExtension)
            XCTAssertEqual(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed"], coveredIDs: [], arrivingID: "new"),
                           route != .ompExtension, "arrival is visible before enqueue")
            XCTAssertTrue(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed", "new"], coveredIDs: ["new"]))
            XCTAssertTrue(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed"], coveredIDs: ["new"], arrivingID: "new"))
            XCTAssertFalse(fallback.blocksNative(registrationID: reg.id, unreadIDs: ["failed"], coveredIDs: ["failed"]))
            XCTAssertFalse(fallback.blocksNative(registrationID: UUID(), unreadIDs: ["failed"], coveredIDs: []))
        }
    }

    func testOpenCodeDisplayedRouteConflictHoldsTypedDelivery() {
        let reg = MailboxNativeDoorbell.Registration(id: UUID(), panelID: UUID(), agentPID: 123,
            processStart: 456, sessionID: UUID().uuidString, route: .opencodePlugin,
            canQueue: false, supportsAttemptReplay: true)
        let conflict = MailboxNativeDoorbell.Fallback(
            registration: reg, ids: ["mail-a"], reason: "native_session_conflict"
        )
        XCTAssertTrue(conflict.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []))
        XCTAssertFalse(conflict.blocksTyped(unreadIDs: ["mail-b"], coveredIDs: []))
        XCTAssertFalse(conflict.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: ["mail-a"]))

        let ordinaryFailure = MailboxNativeDoorbell.Fallback(
            registration: reg, ids: ["mail-a"], reason: "native_timeout"
        )
        XCTAssertTrue(ordinaryFailure.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []),
                      "an ambiguous prompt result must be retried natively with the same attempt ID")
        XCTAssertFalse(ordinaryFailure.blocksTyped(unreadIDs: ["mail-b"], coveredIDs: []),
                       "the ambiguous attempt does not hide later mail")

        let notReady = MailboxNativeDoorbell.Fallback(
            registration: reg, ids: ["mail-a"], reason: "native_not_ready"
        )
        XCTAssertTrue(notReady.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []),
                      "busy OpenCode mail must stay buffered until native delivery can resume")
        XCTAssertFalse(notReady.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: ["mail-a"]))
        XCTAssertTrue(MailboxNativeDoorbell.namedRejections.contains("not_ready"))

        let otherRoute = MailboxNativeDoorbell.Fallback(
            registration: registration(route: .piExtension), ids: ["mail-a"], reason: "native_not_ready"
        )
        XCTAssertFalse(otherRoute.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []),
                       "OpenCode readiness policy must not leak into other consumers")
    }

    func testNativeAndFallbackLogsNameTheirRoutes() throws {
        let line = MailboxDispatchLog.serialize(event: .handler(id: "mail", recipient: "pi", handler: "stdin", outcome: .doorbell,
            bytes: 5, elapsedMs: nil, reason: "submitted", route: "typed", nativeRoute: "pi_extension", nativeFailure: "native_timeout"), at: Date())
        let data = try XCTUnwrap(line.data(using: .utf8))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["route"] as? String, "typed")
        XCTAssertEqual(event["native_route"] as? String, "pi_extension")
        XCTAssertEqual(event["native_failure"] as? String, "native_timeout")
    }
}
