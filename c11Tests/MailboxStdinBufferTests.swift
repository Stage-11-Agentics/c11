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
        at: Date = Date(timeIntervalSince1970: 1_000),
        forAgent: Bool = false
    ) -> MailboxStdinBuffer.Entry {
        MailboxStdinBuffer.Entry(
            id: id, recipientName: recipient, block: block, bufferedAt: at, forAgent: forAgent
        )
    }

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000 + seconds)
    }

    // MARK: - decide()

    func testDecideInjectsWhenPromptIdle() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .promptIdle), .injectNow)
    }

    func testDecideBuffersWhenCommandRunning() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .commandRunning), .buffer)
    }

    func testDecideBuffersWhenUnknown() {
        XCTAssertEqual(MailboxStdinBuffer.decide(state: .unknown), .buffer)
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

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1))
        XCTAssertEqual(result.fresh.map(\.id), ["id-0", "id-1", "id-2"])
        XCTAssertTrue(result.expired.isEmpty)
        // Drained — queue is now empty.
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainOfEmptySurfaceIsNoOp() {
        var buffer = MailboxStdinBuffer()
        let result = buffer.drainForFlush(surfaceId: UUID(), now: Date())
        XCTAssertTrue(result.fresh.isEmpty)
        XCTAssertTrue(result.expired.isEmpty)
    }

    func testQueuesAreIsolatedPerSurface() {
        var buffer = MailboxStdinBuffer()
        let a = UUID()
        let b = UUID()
        buffer.enqueue(surfaceId: a, entry: entry(id: "a0"))
        buffer.enqueue(surfaceId: b, entry: entry(id: "b0"))
        let drainA = buffer.drainForFlush(surfaceId: a, now: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(drainA.fresh.map(\.id), ["a0"])
        // b untouched.
        XCTAssertEqual(buffer.pendingCount(surfaceId: b), 1)
    }

    // MARK: - freshness window

    func testStaleEntriesExpireRatherThanFlush() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let bufferedAt = Date(timeIntervalSince1970: 1_000)
        buffer.enqueue(surfaceId: surface, entry: entry(id: "stale", at: bufferedAt))
        buffer.enqueue(
            surfaceId: surface,
            entry: entry(id: "fresh", at: bufferedAt.addingTimeInterval(
                MailboxStdinBuffer.freshnessWindow
            ))
        )

        // Flush far enough out that the first entry is past the window but the
        // second is exactly on the boundary (<= window → fresh).
        let now = bufferedAt
            .addingTimeInterval(MailboxStdinBuffer.freshnessWindow)
            .addingTimeInterval(1)
        let result = buffer.drainForFlush(surfaceId: surface, now: now)
        XCTAssertEqual(result.expired.map(\.id), ["stale"])
        XCTAssertEqual(result.fresh.map(\.id), ["fresh"])
    }

    func testEntryExactlyAtWindowBoundaryIsFresh() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        let bufferedAt = Date(timeIntervalSince1970: 1_000)
        buffer.enqueue(surfaceId: surface, entry: entry(id: "edge", at: bufferedAt))
        let now = bufferedAt.addingTimeInterval(MailboxStdinBuffer.freshnessWindow)
        let result = buffer.drainForFlush(surfaceId: surface, now: now)
        XCTAssertEqual(result.fresh.map(\.id), ["edge"])
        XCTAssertTrue(result.expired.isEmpty)
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

        let result = buffer.drainForFlush(surfaceId: surface, now: base.addingTimeInterval(1))
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
        let tab = UUID()
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    func testAgentMidTurnBuffers() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        buffer.noteSubmit(surfaceId: tab, at: t(1))
        XCTAssertEqual(buffer.agentTurn(surfaceId: tab)?.atPrompt, false)
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: false, at: t(2))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .buffer
        )
    }

    /// A detected agent with no turn edge yet is not known to be at a prompt.
    func testAgentWithoutTurnEdgeBuffers() {
        let buffer = MailboxStdinBuffer()
        XCTAssertEqual(
            buffer.decide(surfaceId: UUID(), shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .buffer
        )
    }

    /// A recorded turn edge marks the tab as an agent even when its terminal
    /// type is not yet detected.
    func testTurnEdgeAloneMarksTabAsAgent() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        XCTAssertFalse(buffer.isAgent(surfaceId: tab, isAgentKind: false))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        XCTAssertTrue(buffer.isAgent(surfaceId: tab, isAgentKind: false))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: false, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    /// The push's Return lands 200 ms after the paste. Until the agent has
    /// reached a prompt again, a second message must wait, not join the first.
    func testPushWaitsForTheNextPromptEdge() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        buffer.notePush(surfaceId: tab, at: t(1))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .buffer
        )
        buffer.noteSubmit(surfaceId: tab, at: t(1.2))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(5))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: nil),
            .injectNow
        )
    }

    /// A keystroke after the last submit may be an unsent draft in the
    /// composer. Waiting does not clear it; only a submit does.
    func testOperatorDraftDefersUntilSubmit() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.noteSubmit(surfaceId: tab, at: t(0))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(10))
        let typed = t(20)
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: typed),
            .buffer
        )
        // Typing during the turn and leaving it unsent is a draft too: the
        // prompt edge arriving later does not clear it.
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: false, at: t(30))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(3_600))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: typed),
            .buffer
        )
        // The operator submits; the agent's turn ends; the gate opens.
        buffer.noteSubmit(surfaceId: tab, at: t(3_700))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(3_710))
        XCTAssertEqual(
            buffer.decide(surfaceId: tab, shell: .commandRunning, isAgentKind: true, lastOperatorKeyAt: t(3_700)),
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
    func testShellRuleForPlainShellsAndExitedAgents() {
        var buffer = MailboxStdinBuffer()
        let shell = UUID()
        XCTAssertEqual(
            buffer.decide(surfaceId: shell, shell: .commandRunning, isAgentKind: false, lastOperatorKeyAt: nil),
            .buffer
        )
        XCTAssertEqual(
            buffer.decide(surfaceId: shell, shell: .unknown, isAgentKind: false, lastOperatorKeyAt: nil),
            .buffer
        )
        let exited = UUID()
        buffer.noteAgentTurn(surfaceId: exited, atPrompt: false, at: t(0))
        XCTAssertEqual(
            buffer.decide(surfaceId: exited, shell: .promptIdle, isAgentKind: true, lastOperatorKeyAt: nil),
            .injectNow
        )
        buffer.forgetAgent(surfaceId: exited)
        XCTAssertNil(buffer.agentTurn(surfaceId: exited))
    }

    /// A submit into a tab with no agent turn edge (a plain shell's Return)
    /// does not turn it into an agent.
    func testSubmitIntoPlainShellDoesNotCreateTurn() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.noteSubmit(surfaceId: tab, at: t(0))
        XCTAssertNil(buffer.agentTurn(surfaceId: tab))
        XCTAssertFalse(buffer.isAgent(surfaceId: tab, isAgentKind: false))
    }

    func testRepeatedSameEdgeKeepsItsStart() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(50))
        XCTAssertEqual(buffer.agentTurn(surfaceId: tab), .init(atPrompt: true, since: t(0)))
    }

    // MARK: - agent flush

    /// Agent mail is still meant for its agent hours later: an agent-prompt
    /// flush delivers everything, regardless of age.
    func testAgentPromptFlushNeverExpires() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.enqueue(surfaceId: tab, entry: entry(id: "old", at: t(0), forAgent: true))
        buffer.enqueue(surfaceId: tab, entry: entry(id: "new", at: t(7_000), forAgent: true))
        let result = buffer.drainForFlush(surfaceId: tab, now: t(10_000), trigger: .agentPrompt)
        XCTAssertEqual(result.fresh.map(\.id), ["old", "new"])
        XCTAssertTrue(result.expired.isEmpty)
    }

    /// The agent exited to its shell: its buffered mail must not be pasted
    /// onto the bare prompt (the inbox still holds it).
    func testShellPromptFlushDropsAgentEntries() {
        var buffer = MailboxStdinBuffer()
        let tab = UUID()
        buffer.enqueue(surfaceId: tab, entry: entry(id: "agent", at: t(0), forAgent: true))
        buffer.enqueue(surfaceId: tab, entry: entry(id: "shell", at: t(0)))
        let result = buffer.drainForFlush(surfaceId: tab, now: t(1), trigger: .shellPrompt)
        XCTAssertEqual(result.fresh.map(\.id), ["shell"])
        XCTAssertEqual(result.expired.map(\.id), ["agent"])
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
        let tab = UUID()
        buffer.noteAgentTurn(surfaceId: tab, atPrompt: true, at: t(0))
        buffer.removeSurface(tab)
        XCTAssertNil(buffer.agentTurn(surfaceId: tab))
    }
}
