import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for the pure gating/buffer/flush logic behind C11-144's
/// prompt-gated stdin delivery. No PTY, no Workspace instance — the clock is
/// injected, so every decision is deterministic.
final class MailboxStdinBufferTests: XCTestCase {

    private func entry(
        id: String = "01K3A2B7X8PQRTVWYZ0123456J",
        recipient: String = "watcher",
        block: String = "<c11-msg/>",
        at: Date = Date(timeIntervalSince1970: 1_000)
    ) -> MailboxStdinBuffer.Entry {
        MailboxStdinBuffer.Entry(
            id: id, recipientName: recipient, block: block, bufferedAt: at
        )
    }

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000 + seconds)
    }

    // MARK: - nothing is typed into a shell

    /// A shell at its prompt, or a tab with no agent, is never typed into:
    /// a paste plus Return there runs as shell commands.
    func testShellsAreNeverTypedInto() {
        var buffer = MailboxStdinBuffer()
        // No agent at all: buffer, even if something owns the terminal.
        XCTAssertEqual(
            buffer.decide(surfaceId: UUID(), isAgentKind: false, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        // An agent at its prompt whose process does not own the terminal
        // (the shell, `vim`, `--bg`): buffer.
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: false, lastOperatorKeyAt: nil),
            .buffer
        )
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    // MARK: - enqueue / drain FIFO

    func testBufferedEntriesFlushInFifoOrder() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<3 {
            buffer.enqueue(
                surfaceId: surface,
                entry: entry(id: "id-\(i)", block: "block-\(i)", at: base)
            )
        }
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 3)

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1), trigger: .agentPrompt)
        XCTAssertEqual(result.fresh.map(\.id), ["id-0", "id-1", "id-2"])
        XCTAssertTrue(result.expired.isEmpty)
        // Drained — queue is now empty.
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainOfEmptySurfaceIsNoOp() {
        var buffer = MailboxStdinBuffer()
        let result = buffer.drainForFlush(surfaceId: UUID(), now: Date(), trigger: .agentPrompt)
        XCTAssertTrue(result.fresh.isEmpty)
        XCTAssertTrue(result.expired.isEmpty)
    }

    func testQueuesAreIsolatedPerSurface() {
        var buffer = MailboxStdinBuffer()
        let a = UUID()
        let b = UUID()
        buffer.enqueue(surfaceId: a, entry: entry(id: "a0"))
        buffer.enqueue(surfaceId: b, entry: entry(id: "b0"))
        let drainA = buffer.drainForFlush(surfaceId: a, now: Date(timeIntervalSince1970: 1_001), trigger: .agentPrompt)
        XCTAssertEqual(drainA.fresh.map(\.id), ["a0"])
        // b untouched.
        XCTAssertEqual(buffer.pendingCount(surfaceId: b), 1)
    }

    // MARK: - shell prompt drops

    /// A shell prompt edge means no agent is reading the terminal: whatever
    /// was buffered drops (the inbox keeps it), regardless of age.
    func testShellPromptFlushDropsEverything() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "a", at: t(0)))
        buffer.enqueue(surfaceId: surface, entry: entry(id: "b", at: t(59)))
        let result = buffer.drainForFlush(surfaceId: surface, now: t(60), trigger: .shellPrompt)
        XCTAssertTrue(result.fresh.isEmpty)
        XCTAssertEqual(result.expired.map(\.id), ["a", "b"])
    }

    // MARK: - per-surface cap eviction

    func testCapEvictsOldestAndReportsIt() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var evictions: [String] = []
        for i in 0...MailboxStdinBuffer.perSurfaceCap {
            if let evicted = buffer.enqueue(
                surfaceId: surface,
                entry: entry(id: "id-\(i)", at: base)
            ) {
                evictions.append(evicted.id)
            }
        }
        // One over the cap → exactly one eviction, the oldest.
        XCTAssertEqual(evictions, ["id-0"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), MailboxStdinBuffer.perSurfaceCap)

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1), trigger: .agentPrompt)
        XCTAssertEqual(result.fresh.first?.id, "id-1")
        XCTAssertEqual(result.fresh.count, MailboxStdinBuffer.perSurfaceCap)
    }

    func testEnqueueUnderCapDoesNotEvict() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let evicted = buffer.enqueue(surfaceId: surface, entry: entry())
        XCTAssertNil(evicted)
    }

    // MARK: - removeSurface / retainOnly

    func testRemoveSurfaceReturnsPendingAndClears() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        buffer.enqueue(surfaceId: surface, entry: entry(id: "x0"))
        buffer.enqueue(surfaceId: surface, entry: entry(id: "x1"))
        let dropped = buffer.removeSurface(surface)
        XCTAssertEqual(dropped.map(\.id), ["x0", "x1"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
    }

    func testRetainOnlyPrunesAbsentSurfaces() {
        var buffer = MailboxStdinBuffer()
        let keep = UUID()
        let drop = UUID()
        buffer.enqueue(surfaceId: keep, entry: entry(id: "k"))
        buffer.enqueue(surfaceId: drop, entry: entry(id: "d"))
        buffer.retainOnly(surfaceIds: [keep])
        XCTAssertEqual(buffer.pendingCount(surfaceId: keep), 1)
        XCTAssertEqual(buffer.pendingCount(surfaceId: drop), 0)
    }

    // MARK: - agent gate

    /// A live agent keeps its shell `commandRunning` for life; the shell rule
    /// alone would buffer forever. At its prompt, the agent gate injects.
    func testAgentAtPromptInjectsDespiteRunningShell() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    func testAgentMidTurnBuffers() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(1))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(2))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
    }

    /// A detected agent with no turn edge yet is not known to be at a prompt.
    func testAgentWithoutTurnEdgeBuffers() {
        let buffer = MailboxStdinBuffer()
        XCTAssertEqual(
            buffer.decide(surfaceId: UUID(), isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
    }

    /// A recorded turn edge marks the tab as an agent even when its terminal
    /// type is not yet detected.
    func testTurnEdgeAloneMarksTabAsAgent() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        XCTAssertFalse(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        XCTAssertTrue(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: false, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    /// The push's Return lands 200 ms after the paste. Until the agent has
    /// reached a prompt again, a second message must wait, not join the first.
    func testPushWaitsForTheNextPromptEdge() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.notePush(surfaceId: panel, at: t(1))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteSubmit(surfaceId: panel, at: t(1.2))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(5))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    /// A keystroke after the last submit may be an unsent draft in the
    /// composer. Waiting does not clear it; only a submit does.
    func testOperatorDraftDefersUntilSubmit() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteSubmit(surfaceId: panel, at: t(0))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(10))
        let typed = t(20)
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: typed),
            .buffer
        )
        // Typing during the turn and leaving it unsent is a draft too: the
        // prompt edge arriving later does not clear it.
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(30))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(3_600))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: typed),
            .buffer
        )
        // The operator submits; the agent's turn ends; the gate opens.
        buffer.noteSubmit(surfaceId: panel, at: t(3_700))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(3_710))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: t(3_700)),
            .injectNow
        )
    }

    /// The submit Return itself is a keystroke stamped just before the submit
    /// edge; it is not a draft.
    func testSubmitKeystrokeIsNotADraft() {
        XCTAssertEqual(
            MailboxStdinBuffer.decideAgent(
                turn: .init(atPrompt: true, since: t(9)),
                lastSubmitAt: t(2.001),
                lastOperatorKeyAt: t(2),
                lastPushAt: nil
            ),
            .injectNow
        )
    }

    /// A plain shell keeps the shell rule; any tab whose shell is back at its
    /// prompt has no foreground agent and takes the shell rule too.
    func testPlainShellsAndExitedAgentsBuffer() {
        var buffer = MailboxStdinBuffer()
        let shell = UUID()
        XCTAssertEqual(
            buffer.decide(surfaceId: shell, isAgentKind: false, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        XCTAssertEqual(
            buffer.decide(surfaceId: shell, isAgentKind: false, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        let exited = UUID()
        buffer.noteAgentTurn(surfaceId: exited, atPrompt: true, at: t(0))
        // The agent's shell is back at its prompt: it exited, so nothing types.
        XCTAssertEqual(
            buffer.decide(surfaceId: exited, isAgentKind: true, agentOwnsTerminal: false, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.forgetAgent(surfaceId: exited)
        XCTAssertNil(buffer.agentTurn(surfaceId: exited))
    }

    /// A submit into a tab with no agent turn edge (a plain shell's Return)
    /// does not turn it into an agent.
    func testSubmitIntoPlainShellDoesNotCreateTurn() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteSubmit(surfaceId: panel, at: t(0))
        XCTAssertNil(buffer.agentTurn(surfaceId: panel))
        XCTAssertFalse(buffer.isAgent(surfaceId: panel, isAgentKind: false))
    }

    func testRepeatedSameEdgeKeepsItsStart() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(50))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel), .init(atPrompt: true, since: t(0)))
    }

    // MARK: - agent flush

    /// Agent mail is still meant for its agent hours later: an agent-prompt
    /// flush delivers everything, regardless of age.
    func testAgentPromptFlushNeverExpires() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.enqueue(surfaceId: panel, entry: entry(id: "old", at: t(0)))
        buffer.enqueue(surfaceId: panel, entry: entry(id: "new", at: t(7_000)))
        let result = buffer.drainForFlush(surfaceId: panel, now: t(10_000), trigger: .agentPrompt)
        XCTAssertEqual(result.fresh.map(\.id), ["old", "new"])
        XCTAssertTrue(result.expired.isEmpty)
    }

    func testJoinedBlockIsOnePasteInOrder() {
        let blocks = [
            entry(id: "a", block: "\n<c11-msg id=\"a\">\nA\n</c11-msg>\n"),
            entry(id: "b", block: "\n<c11-msg id=\"b\">\nB\n</c11-msg>\n"),
        ]
        XCTAssertEqual(
            MailboxStdinBuffer.joinedBlock(blocks),
            "\n<c11-msg id=\"a\">\nA\n</c11-msg>\n\n<c11-msg id=\"b\">\nB\n</c11-msg>\n"
        )
    }

    func testRemoveSurfaceForgetsTurnState() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.removeSurface(panel)
        XCTAssertNil(buffer.agentTurn(surfaceId: panel))
    }

    // MARK: - review r1

    /// Return at t1, the operator starts a new draft at t2, and only then does
    /// the Return's submit edge arrive (it hops off-main and back). The edge
    /// carries the Return's own time, so the new draft still reads as one.
    func testLateSubmitEdgeKeepsPostSubmitDraft() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        let returnAt = t(1)
        let draftKeyAt = t(1.05)
        buffer.noteSubmit(surfaceId: panel, at: returnAt)  // delivered late, stamped at the event
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(4))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: draftKeyAt),
            .buffer
        )
    }

    /// An out-of-order (older) submit edge never moves the submit clock back.
    func testOlderSubmitEdgeDoesNotRewindClock() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteSubmit(surfaceId: panel, at: t(10))
        buffer.noteSubmit(surfaceId: panel, at: t(5))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(20))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: t(8)),
            .injectNow
        )
    }

    /// A submit edge older than the current prompt edge does not reopen a
    /// turn that already ended.
    func testStaleSubmitEdgeDoesNotStartTurn() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(10))
        buffer.noteSubmit(surfaceId: panel, at: t(9))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, true)
    }

    /// While one push is between claim and Return, nothing else is typed into
    /// the tab, on either gate; a push that typed nothing does not hold the
    /// agent gate closed afterwards.
    func testPushInFlightBlocksBothGates() {
        var buffer = MailboxStdinBuffer()
        let agent = UUID()
        let shell = UUID()
        buffer.noteAgentTurn(surfaceId: agent, atPrompt: true, at: t(0))
        buffer.beginPush(surfaceId: agent)
        buffer.beginPush(surfaceId: shell)
        XCTAssertEqual(
            buffer.decide(surfaceId: agent, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        XCTAssertEqual(
            buffer.decide(surfaceId: shell, isAgentKind: false, agentOwnsTerminal: false, lastOperatorKeyAt: nil),
            .buffer
        )
        XCTAssertEqual(
            buffer.decide(surfaceId: agent, isAgentKind: true, agentOwnsTerminal: true,
                          lastOperatorKeyAt: nil, ignoringInFlight: true),
            .injectNow
        )
        buffer.endPush(surfaceId: agent, typedAt: nil)
        XCTAssertEqual(
            buffer.decide(surfaceId: agent, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
        buffer.endPush(surfaceId: shell, typedAt: t(1))
        XCTAssertFalse(buffer.isPushInFlight(surfaceId: shell))
    }

    // MARK: - C11-365: turn ends that reach the gate late or from the transcript

    /// The MouthKeys stall, replayed at the gate: a push starts a Codex turn,
    /// the transcript's turn start closes the gate, and the turn end arrives
    /// from the transcript poll stamped with Codex's own clock. The idle agent
    /// gets the next message at once.
    func testIdleAgentAfterTranscriptTurnEndGetsMailInjected() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))      // notify, previous turn
        buffer.beginPush(surfaceId: panel)
        buffer.endPush(surfaceId: panel, typedAt: t(1))                       // paste
        buffer.noteSubmit(surfaceId: panel, at: t(1.2))                       // its Return
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(10))   // transcript turn start
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(29.8))  // transcript turn end, native time
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
        // The notify hook lands 25 ms after the poll; a repeated edge changes nothing.
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(30.025))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.since, t(29.8))
    }

    /// Mail for a busy agent waits for its next prompt edge and then flushes
    /// as one paste in arrival order.
    func testBusyAgentBuffersThenFlushesAtNextPromptEdge() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(1))
        for i in 0..<3 {
            XCTAssertEqual(
                buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
                .buffer
            )
            buffer.enqueue(surfaceId: panel, entry: entry(id: "m\(i)", block: "<m\(i)/>", at: t(2 + Double(i))))
        }
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(20))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
        let flush = buffer.drainForFlush(surfaceId: panel, now: t(20), trigger: .agentPrompt)
        XCTAssertEqual(flush.fresh.map(\.id), ["m0", "m1", "m2"])
        XCTAssertEqual(MailboxStdinBuffer.joinedBlock(flush.fresh), "<m0/><m1/><m2/>")
    }

    /// The operator typing after the push's Return is a draft: the transcript
    /// turn end does not open the gate over it.
    func testDraftStillDefersAfterTranscriptTurnEnd() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteSubmit(surfaceId: panel, at: t(1))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(1))
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(30))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: t(25)),
            .buffer
        )
    }

    /// A turn end older than the newest Return describes a turn the agent has
    /// moved past: a late transcript poll or hook must not reopen the gate.
    func testTurnEndOlderThanNewestReturnIsIgnored() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(10))                        // operator starts a new turn
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(8))     // previous turn's end, polled late
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(12))    // the new turn's end
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    /// Under a live journal the gate still hears Returns and explicit wrapper
    /// reports (Grok's only native turn edges); inferred and headless never.
    func testJournalLiveForwardsOnlyReturnsAndExplicitReports() {
        XCTAssertTrue(PanelLivenessDeriver.forwardsToMailboxGateWhileJournalLive(.submit))
        XCTAssertTrue(PanelLivenessDeriver.forwardsToMailboxGateWhileJournalLive(.reported))
        XCTAssertFalse(PanelLivenessDeriver.forwardsToMailboxGateWhileJournalLive(.inferred))
        XCTAssertFalse(PanelLivenessDeriver.forwardsToMailboxGateWhileJournalLive(.headless))
    }

    /// A push that typed waits for the agent's next prompt edge.
    func testTypedPushWaitsForNextEdge() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        buffer.beginPush(surfaceId: panel)
        buffer.endPush(surfaceId: panel, typedAt: t(1))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
    }

    func testRequeueFrontRestoresOrderAndEvictsOldest() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.enqueue(surfaceId: panel, entry: entry(id: "later"))
        buffer.requeueFront(surfaceId: panel, entries: [entry(id: "a"), entry(id: "b")])
        XCTAssertEqual(
            buffer.drainForFlush(surfaceId: panel, now: t(1), trigger: .agentPrompt).fresh.map(\.id),
            ["a", "b", "later"]
        )
        for i in 0..<MailboxStdinBuffer.perSurfaceCap {
            buffer.enqueue(surfaceId: panel, entry: entry(id: "q\(i)"))
        }
        let evicted = buffer.requeueFront(surfaceId: panel, entries: [entry(id: "x")])
        XCTAssertEqual(evicted.map(\.id), ["x"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: panel), MailboxStdinBuffer.perSurfaceCap)
    }

    /// Claude's Notification and AskUserQuestion hooks report idle with
    /// `--source=notification`: that drives the sidebar but is never a turn
    /// edge for the mailbox gate.
    /// Only a report carrying the interactive agent PID is a turn edge.
    /// Claude's Notification/AskUserQuestion idle is `--source=notification`;
    /// anything without the PID (`claude -p`, `--bg`, a piped run, an unknown
    /// caller) is headless: fail closed.
    func testReportSourceMappingFailsClosed() {
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["source": "notification", "pid": "4242"]), .inferred)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["pid": "4242"]), .reported)
        XCTAssertEqual(TerminalController.reportedAgentPID(["pid": "4242"]), 4242)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["source": "headless"]), .headless)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource([:]), .headless)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["tab": "x", "panel": "y"]), .headless)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["pid": "1"]), .headless)
        XCTAssertEqual(TerminalController.reportedAgentLifecycleSource(["pid": "abc"]), .headless)
    }

    // MARK: - review r2: re-check after the claim hop

    private func verdict(
        _ trigger: MailboxStdinBuffer.FlushTrigger,
        admitted: MailboxStdinBuffer.AgentTurn?,
        turn: MailboxStdinBuffer.AgentTurn?,
        submitAt: Date? = nil,
        keyAt: Date? = nil,
        pushAt: Date? = nil,
        attached: Bool = true,
        owns: Bool = true
    ) -> MailboxStdinBuffer.PushVerdict {
        MailboxStdinBuffer.pushVerdict(
            admittedAs: trigger, admittedTurn: admitted, turn: turn,
            lastSubmitAt: submitAt, lastOperatorKeyAt: keyAt, lastPushAt: pushAt,
            surfaceAttached: attached, agentOwnsTerminal: owns
        )
    }

    /// The r2 finding: the agent exits while its claims are off-main. The
    /// kernel no longer reports it as the terminal's reader (or its turn
    /// record is gone), so the push drops, never pastes into zsh.
    func testAgentPushDropsWhenAgentExitedDuringHop() {
        let atPrompt = MailboxStdinBuffer.AgentTurn(atPrompt: true, since: t(0))
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: atPrompt, owns: false), .drop)
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: nil, owns: false), .drop)
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: nil), .drop)
    }

    /// Through the buffer: `forgetAgent` (the shell's promptIdle edge) during
    /// the hop turns an admitted agent push into a drop.
    func testForgetAgentDuringHopDropsAdmittedPush() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(0))
        let admitted = buffer.agentTurn(surfaceId: panel)
        buffer.beginPush(surfaceId: panel)
        buffer.forgetAgent(surfaceId: panel)
        XCTAssertEqual(
            buffer.pushVerdict(surfaceId: panel, admittedAs: .agentPrompt, admittedTurn: admitted,
                               lastOperatorKeyAt: nil, surfaceAttached: true, agentOwnsTerminal: false),
            .drop
        )
    }

    func testAgentPushPastesWhenNothingChanged() {
        let atPrompt = MailboxStdinBuffer.AgentTurn(atPrompt: true, since: t(0))
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: atPrompt), .paste)
    }

    func testAgentPushRequeuesWhenGateClosedDuringHop() {
        let atPrompt = MailboxStdinBuffer.AgentTurn(atPrompt: true, since: t(0))
        // A new turn started.
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt,
                               turn: .init(atPrompt: false, since: t(1))), .requeue)
        // A fresh prompt edge replaced the admitted one.
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt,
                               turn: .init(atPrompt: true, since: t(2))), .requeue)
        // The operator started a draft.
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: atPrompt,
                               submitAt: t(0), keyAt: t(1)), .requeue)
        // The surface detached.
        XCTAssertEqual(verdict(.agentPrompt, admitted: atPrompt, turn: atPrompt,
                               attached: false), .requeue)
    }

    /// A shell-prompt push never pastes, whatever the shell is doing.
    func testShellPushAlwaysDrops() {
        XCTAssertEqual(verdict(.shellPrompt, admitted: nil, turn: nil), .drop)
        XCTAssertEqual(verdict(.shellPrompt, admitted: nil, turn: nil), .drop)
    }

    /// A headless agent's reports mark the tab as an agent that is never at
    /// its prompt: mail buffers, and drops when the run exits to the shell.
    func testHeadlessAgentNeverOpensGateAndDropsOnExit() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))  // SessionStart, headless
        XCTAssertTrue(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        XCTAssertEqual(
            buffer.decide(surfaceId: panel, isAgentKind: false, agentOwnsTerminal: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.enqueue(surfaceId: panel, entry: entry(id: "m"))
        buffer.forgetAgent(surfaceId: panel)  // the run exits; shell back at its prompt
        let flush = buffer.drainForFlush(surfaceId: panel, now: t(1), trigger: .shellPrompt)
        XCTAssertTrue(flush.fresh.isEmpty)
        XCTAssertEqual(flush.expired.map(\.id), ["m"])
    }

    // MARK: - review r3: the agent must own the terminal

    private func procInfo(pgid: pid_t, fg: pid_t, tty: dev_t = 0x1000007, zombie: Bool = false,
                          start: UInt64 = 1_000_000)
        -> MailboxAgentForeground.ProcessTerminalInfo {
        .init(processGroup: pgid, terminalForegroundGroup: fg, terminalDevice: tty, isZombie: zombie,
              startTime: start)
    }

    private func owns(_ info: MailboxAgentForeground.ProcessTerminalInfo?, start: UInt64? = 1_000_000,
                      panel: dev_t? = 0x1000007, canonical: Bool? = false) -> Bool {
        MailboxAgentForeground.agentOwnsTerminal(
            info, expectedStartTime: start, panelTerminalDevice: panel, terminalIsCanonical: canonical
        )
    }

    /// The kernel decides who reads the terminal: only the registered agent
    /// process, as its terminal's foreground group, on the tab's tty, with
    /// the tty in non-canonical (raw) mode.
    func testAgentOwnsTerminalOnlyAsRawForegroundGroupOnPanelTTY() {
        XCTAssertTrue(owns(procInfo(pgid: 500, fg: 500)))
        // vim, the shell, or a pipeline holds the foreground (`--bg`, Ctrl-Z, exit).
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 777)))
        // Another tab's terminal (an agent under tmux/screen in this tab).
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, tty: 0x1000008)))
        // No controlling terminal, a zombie, or no process: fail closed.
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, tty: -1)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, zombie: true)))
        XCTAssertFalse(owns(nil))
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: nil, panelTTYName: "ttys001"))
    }

    /// r4 #2: a print or one-shot run is the foreground group but leaves its
    /// tty canonical; anything typed would be read by the shell after it
    /// exits. Canonical, or unreadable termios, fails closed.
    func testCanonicalOrUnreadableTTYFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), canonical: true))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), canonical: nil))
    }

    /// r4 #3: a tab whose tty c11 does not know cannot be verified.
    func testUnknownPanelTTYFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), panel: nil))
        let process = MailboxStdinBuffer.AgentProcess(pid: getpid(), startTime: 1)
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: process, panelTTYName: nil))
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: process, panelTTYName: "ttys-not-a-device"))
    }

    /// A later process reusing the registered PID (an editor in the same
    /// tab) has a different start time: fail closed.
    func testReusedPIDFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, start: 2_000_000)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), start: nil))
    }

    /// The live reads: this process's real process group and start time, and
    /// a real pty's ICANON flag as set through termios.
    func testLiveProcessAndTerminalModeReads() throws {
        let info = try XCTUnwrap(MailboxAgentForeground.processTerminalInfo(pid: getpid()))
        XCTAssertEqual(info.processGroup, getpgrp())
        XCTAssertFalse(info.isZombie)
        XCTAssertGreaterThan(info.startTime, 0)
        XCTAssertEqual(MailboxAgentForeground.processTerminalInfo(pid: getpid())?.startTime, info.startTime)
        XCTAssertNil(MailboxAgentForeground.processTerminalInfo(pid: 0))

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw XCTSkip("openpty unavailable") }
        defer { close(master); close(slave) }
        let path = try XCTUnwrap(ttyname(slave).map { String(cString: $0) })
        var attrs = termios()
        XCTAssertEqual(tcgetattr(slave, &attrs), 0)
        attrs.c_lflag |= tcflag_t(ICANON)
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &attrs), 0)
        XCTAssertEqual(MailboxAgentForeground.terminalIsCanonical(path: path), true)
        attrs.c_lflag &= ~tcflag_t(ICANON)
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &attrs), 0)
        XCTAssertEqual(MailboxAgentForeground.terminalIsCanonical(path: path), false)
        XCTAssertNil(MailboxAgentForeground.terminalIsCanonical(path: "/dev/c11-no-such-tty"))
    }

    func testAgentPushDropsWhenAgentDoesNotOwnTerminal() {
        let atPrompt = MailboxStdinBuffer.AgentTurn(atPrompt: true, since: t(0))
        XCTAssertEqual(
            MailboxStdinBuffer.pushVerdict(
                admittedAs: .agentPrompt, admittedTurn: atPrompt, turn: atPrompt,
                lastSubmitAt: nil, lastOperatorKeyAt: nil, lastPushAt: nil,
                surfaceAttached: true, agentOwnsTerminal: false
            ),
            .drop
        )
    }

    /// Before the Return: a key typed after the paste is a draft (requeue);
    /// an agent that lost the terminal drops.
    func testPreReturnVerdictDraftRequeuesAndLostTerminalDrops() {
        let atPrompt = MailboxStdinBuffer.AgentTurn(atPrompt: true, since: t(0))
        func v(keyAt: Date?, owns: Bool) -> MailboxStdinBuffer.PushVerdict {
            MailboxStdinBuffer.pushVerdict(
                admittedAs: .agentPrompt, admittedTurn: atPrompt, turn: atPrompt,
                lastSubmitAt: t(-1), lastOperatorKeyAt: keyAt, lastPushAt: nil,
                surfaceAttached: true, agentOwnsTerminal: owns
            )
        }
        XCTAssertEqual(v(keyAt: nil, owns: true), .paste)
        XCTAssertEqual(v(keyAt: t(0.1), owns: true), .requeue)
        XCTAssertEqual(v(keyAt: nil, owns: false), .drop)
    }

    func testAgentProcessBookkeeping() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4242, startTime: 7))
        XCTAssertEqual(buffer.agentPid(surfaceId: panel), 4242)
        // A repeat report for the same PID keeps the pinned start time.
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4242, startTime: 9))
        XCTAssertEqual(buffer.agentProcess(surfaceId: panel)?.startTime, 7)
        buffer.forgetAgent(surfaceId: panel)
        XCTAssertNil(buffer.agentPid(surfaceId: panel))
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4243, startTime: 8))
        buffer.removeSurface(panel)
        XCTAssertNil(buffer.agentPid(surfaceId: panel))
    }
}
