import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The doorbell queue. No PTY and no Workspace. The ring types one line
/// elsewhere; this buffer only remembers the turn and the unread ids.
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

    private func open(_ buffer: inout MailboxStdinBuffer, _ panel: UUID, at: Date) {
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: at)
    }

    private func gate(
        _ buffer: MailboxStdinBuffer,
        _ panel: UUID,
        agent: Bool = true,
        owns: Bool = true,
        journalTurnOpen: Bool = false,
        at now: Date
    ) -> MailboxStdinBuffer.PromptGate {
        buffer.promptGate(surfaceId: panel, isAgentKind: agent, agentOwnsTerminal: owns,
                          journalTurnOpen: journalTurnOpen, now: now)
    }

    func testShellsAreNeverOpen() {
        var buffer = MailboxStdinBuffer()
        XCTAssertEqual(gate(buffer, UUID(), agent: false, at: t(0)), .closed)
        let panel = UUID()
        open(&buffer, panel, at: t(0))
        XCTAssertEqual(gate(buffer, panel, owns: false, at: t(0)), .closed)
        XCTAssertEqual(gate(buffer, panel, at: t(0)), .open)
    }

    func testOperatorKeyDoesNotCloseThePrompt() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        open(&buffer, panel, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(-1))
        XCTAssertEqual(gate(buffer, panel, at: t(0)), .open)
    }

    func testMidTurnStaysClosed() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertEqual(gate(buffer, panel, at: t(1)), .closed)
    }

    // MARK: - C11-398: unknown, and working that nothing supports

    /// A restored or freshly attached agent has no turn edge. That is
    /// unknown, not closed: the ring may read the screen.
    func testNoEdgeSinceAttachIsUnknown() {
        let buffer = MailboxStdinBuffer()
        let panel = UUID()
        XCTAssertEqual(gate(buffer, panel, at: t(0)), .unknown)
        XCTAssertNil(buffer.workingDecayDeadline(surfaceId: panel))
        // Still only for an agent that owns its terminal.
        XCTAssertEqual(gate(buffer, panel, owns: false, at: t(0)), .closed)
        XCTAssertEqual(gate(buffer, panel, agent: false, at: t(0)), .closed)
    }

    /// A working edge holds the gate for the decay window, then reads as
    /// unknown. Exactly at the deadline it has decayed.
    func testUnsupportedWorkingDecaysToUnknown() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        XCTAssertEqual(MailboxStdinBuffer.unsupportedWorkingDecay, 120)
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertEqual(buffer.workingDecayDeadline(surfaceId: panel), t(120))
        XCTAssertEqual(gate(buffer, panel, at: t(119.9)), .closed)
        XCTAssertEqual(gate(buffer, panel, at: t(120)), .unknown)
        // A later submit restarts the window.
        buffer.noteSubmit(surfaceId: panel, at: t(100))
        XCTAssertEqual(buffer.workingDecayDeadline(surfaceId: panel), t(220))
        XCTAssertEqual(gate(buffer, panel, at: t(150)), .closed)
        XCTAssertEqual(gate(buffer, panel, at: t(220)), .unknown)
    }

    /// A Return into an agent with no turn edge (an empty submit, a slash
    /// command) holds the gate only for the window.
    func testSubmitIntoAnUnknownAgentHoldsOnlyForTheWindow() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteSubmit(surfaceId: panel, at: t(0))
        XCTAssertNil(buffer.agentTurn(surfaceId: panel))
        XCTAssertEqual(gate(buffer, panel, at: t(60)), .closed)
        XCTAssertEqual(gate(buffer, panel, at: t(120)), .unknown)
    }

    /// The journal says a turn is in progress: a long tool call that prints
    /// nothing never decays, and neither does an agent with no edge yet.
    func testLiveJournalTurnHoldsTheGateForAnyLength() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertEqual(gate(buffer, panel, journalTurnOpen: true, at: t(3_600)), .closed)
        XCTAssertEqual(gate(buffer, UUID(), journalTurnOpen: true, at: t(0)), .closed)
        // A reported prompt edge still opens it.
        open(&buffer, panel, at: t(3_601))
        XCTAssertEqual(gate(buffer, panel, journalTurnOpen: true, at: t(3_602)), .open)
    }

    /// The live journal phase is the turn signal. A restored row, an ended
    /// session, and an idle or unknown phase are not.
    func testJournalTurnOpenNeedsALiveWorkingOrBlockedPhase() {
        let owner = JournalOwner(panelID: UUID(), agentKind: "claude-code", sessionID: "fixture")
        var live = JournalSnapshot(owner: owner, workspaceID: nil, appInstanceID: UUID())
        live.connection = .live
        live.confirmation = .confirmed
        for (phase, open) in [(JournalPhase.working, true), (.blocked, true), (.idle, false), (.unknown, false), (.error, false)] {
            live.phase = phase
            XCTAssertEqual(MailboxStdinDelivery.journalTurnOpen(live), open, "\(phase)")
        }
        live.phase = .working
        XCTAssertFalse(MailboxStdinDelivery.journalTurnOpen(JournalReplayPolicy.restored(live)))
        XCTAssertFalse(MailboxStdinDelivery.journalTurnOpen(nil))
    }

    /// An attach forgets the turn edges and submits from before it (the
    /// earlier process, and the Return that launched this one). A newer
    /// edge stays.
    func testAttachForgetsOlderEdgesOnly() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(1))
        buffer.noteAgentAttached(surfaceId: panel, at: t(2))
        XCTAssertNil(buffer.agentTurn(surfaceId: panel))
        XCTAssertNil(buffer.workingDecayDeadline(surfaceId: panel))
        XCTAssertEqual(gate(buffer, panel, at: t(2)), .unknown)

        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(5))
        buffer.noteAgentAttached(surfaceId: panel, at: t(4))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.since, t(5))
        XCTAssertEqual(gate(buffer, panel, at: t(6)), .closed)
    }

    func testQueueKeepsFifoAndIsolatesPanels() {
        var buffer = MailboxStdinBuffer()
        let a = UUID()
        let b = UUID()
        buffer.enqueue(surfaceId: a, entry: entry(id: "a0"))
        buffer.enqueue(surfaceId: a, entry: entry(id: "a1"))
        buffer.enqueue(surfaceId: b, entry: entry(id: "b0"))
        XCTAssertEqual(buffer.queuedEntries(surfaceId: a).map(\.id), ["a0", "a1"])
        XCTAssertEqual(buffer.takeQueue(surfaceId: a).map(\.id), ["a0", "a1"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: a), 0)
        XCTAssertEqual(buffer.pendingCount(surfaceId: b), 1)
        XCTAssertTrue(buffer.takeQueue(surfaceId: UUID()).isEmpty)
    }

    func testCapEvictsOldest() {
        var buffer = MailboxStdinBuffer()
        let surface = UUID()
        var evictions: [String] = []
        for i in 0...MailboxStdinBuffer.perSurfaceCap {
            if let evicted = buffer.enqueue(surfaceId: surface, entry: entry(id: "id-\(i)")) {
                evictions.append(evicted.id)
            }
        }
        XCTAssertEqual(evictions, ["id-0"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: surface), MailboxStdinBuffer.perSurfaceCap)
        XCTAssertEqual(buffer.queuedEntries(surfaceId: surface).first?.id, "id-1")
        XCTAssertNil(buffer.enqueue(surfaceId: UUID(), entry: entry(id: "solo")))
    }

    func testRemoveSurfaceAndRetainOnly() {
        var buffer = MailboxStdinBuffer()
        let keep = UUID()
        let drop = UUID()
        buffer.enqueue(surfaceId: keep, entry: entry(id: "k"))
        buffer.enqueue(surfaceId: drop, entry: entry(id: "d0"))
        buffer.enqueue(surfaceId: drop, entry: entry(id: "d1"))
        XCTAssertEqual(buffer.removeSurface(drop).map(\.id), ["d0", "d1"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: drop), 0)
        buffer.enqueue(surfaceId: drop, entry: entry(id: "d2"))
        buffer.retainOnly(surfaceIds: [keep])
        XCTAssertEqual(buffer.pendingCount(surfaceId: keep), 1)
        XCTAssertEqual(buffer.pendingCount(surfaceId: drop), 0)
    }

    func testSubmitStartsATurnAndAStaleEdgeDoesNot() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        open(&buffer, panel, at: t(0))
        let since = buffer.agentTurn(surfaceId: panel)?.since
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(5))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.since, since)
        buffer.noteSubmit(surfaceId: panel, at: t(2))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: true, at: t(1))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
        buffer.noteSubmit(surfaceId: panel, at: t(1))
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.since, t(2))
    }

    func testSubmitIntoAPlainShellDoesNotCreateATurn() {
        var buffer = MailboxStdinBuffer()
        let shell = UUID()
        buffer.noteSubmit(surfaceId: shell, at: t(1))
        XCTAssertNil(buffer.agentTurn(surfaceId: shell))
        XCTAssertEqual(gate(buffer, shell, agent: false, at: t(2)), .closed)
    }

    func testHeadlessAgentStaysClosedAndTheShellDropsTheQueue() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertTrue(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        XCTAssertEqual(gate(buffer, panel, agent: false, at: t(1)), .closed)
        buffer.enqueue(surfaceId: panel, entry: entry(id: "m"))
        buffer.forgetAgent(surfaceId: panel)
        XCTAssertEqual(buffer.takeQueue(surfaceId: panel).map(\.id), ["m"])
        XCTAssertEqual(buffer.pendingCount(surfaceId: panel), 0)
    }

    func testTurnEdgeAloneMarksThePanelAsAnAgent() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        XCTAssertFalse(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        open(&buffer, panel, at: t(0))
        XCTAssertTrue(buffer.isAgent(surfaceId: panel, isAgentKind: false))
    }

    /// Claude's Notification and AskUserQuestion hooks report idle with
    /// `--source=notification`: that drives the sidebar but is never a turn
    /// edge for the mailbox gate. Only a report carrying the interactive
    /// agent PID is a turn edge.
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

    func testAgentProcessBookkeeping() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4242, startTime: 7))
        XCTAssertEqual(buffer.agentPid(surfaceId: panel), 4242)
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4242, startTime: 9))
        XCTAssertEqual(buffer.agentProcess(surfaceId: panel)?.startTime, 7)
        buffer.forgetAgent(surfaceId: panel)
        XCTAssertNil(buffer.agentPid(surfaceId: panel))
        buffer.noteAgentProcess(surfaceId: panel, process: .init(pid: 4243, startTime: 8))
        buffer.removeSurface(panel)
        XCTAssertNil(buffer.agentPid(surfaceId: panel))
    }

    // MARK: - the agent must own the terminal

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

    func testAgentOwnsTerminalOnlyAsRawForegroundGroupOnPanelTTY() {
        XCTAssertTrue(owns(procInfo(pgid: 500, fg: 500)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 777)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, tty: 0x1000008)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, tty: -1)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, zombie: true)))
        XCTAssertFalse(owns(nil))
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: nil, panelTTYName: "ttys001"))
    }

    func testCanonicalOrUnreadableTTYFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), canonical: true))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), canonical: nil))
    }

    func testUnknownPanelTTYFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), panel: nil))
        let process = MailboxStdinBuffer.AgentProcess(pid: getpid(), startTime: 1)
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: process, panelTTYName: nil))
        XCTAssertFalse(MailboxAgentForeground.agentOwnsTerminal(process: process, panelTTYName: "ttys-not-a-device"))
    }

    func testReusedPIDFailsClosed() {
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500, start: 2_000_000)))
        XCTAssertFalse(owns(procInfo(pgid: 500, fg: 500), start: nil))
    }

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
}
