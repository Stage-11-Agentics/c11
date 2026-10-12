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

    func testShellsAreNeverOpen() {
        var buffer = MailboxStdinBuffer()
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: UUID(), isAgentKind: false, agentOwnsTerminal: true
        ))
        let panel = UUID()
        open(&buffer, panel, at: t(0))
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: panel, isAgentKind: true, agentOwnsTerminal: false
        ))
        XCTAssertTrue(buffer.promptIsOpen(
            surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true
        ))
    }

    func testOperatorKeyDoesNotCloseThePrompt() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        open(&buffer, panel, at: t(0))
        buffer.noteSubmit(surfaceId: panel, at: t(-1))
        XCTAssertTrue(buffer.promptIsOpen(
            surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true
        ))
    }

    func testMidTurnAndMissingEdgeStayClosed() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true
        ))
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: UUID(), isAgentKind: true, agentOwnsTerminal: true
        ))
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
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: shell, isAgentKind: false, agentOwnsTerminal: true
        ))
    }

    func testHeadlessAgentStaysClosedAndTheShellDropsTheQueue() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t(0))
        XCTAssertTrue(buffer.isAgent(surfaceId: panel, isAgentKind: false))
        XCTAssertFalse(buffer.promptIsOpen(
            surfaceId: panel, isAgentKind: false, agentOwnsTerminal: true
        ))
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
