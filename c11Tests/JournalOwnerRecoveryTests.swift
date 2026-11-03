import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The kernel's process table, as the recovery check sees it.
private final class FakeProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [pid_t: MailboxAgentForeground.ProcessTerminalInfo] = [:]

    /// A foreground interactive process that started `secondsAgo` ago.
    func start(_ pid: pid_t, secondsAgo: TimeInterval) {
        let startUs = UInt64((Date().timeIntervalSince1970 - secondsAgo) * 1_000_000)
        set(pid, .init(processGroup: pid, terminalForegroundGroup: pid, terminalDevice: 0x1000_0007,
                       isZombie: false, startTime: startUs, parentPID: 1))
    }
    func set(_ pid: pid_t, _ info: MailboxAgentForeground.ProcessTerminalInfo?) {
        lock.lock(); table[pid] = info; lock.unlock()
    }
    func exit(_ pid: pid_t) { set(pid, nil) }
    func info(_ pid: pid_t) -> MailboxAgentForeground.ProcessTerminalInfo? {
        lock.lock(); defer { lock.unlock() }; return table[pid]
    }
}

/// C11-580: a SessionStart that missed its socket window leaves the panel with
/// a wrapper placeholder, so no journal owner. A later hook from the same
/// interactive session recovers it through the real append route.
@MainActor
final class JournalOwnerRecoveryTests: XCTestCase {
    private var controller: TerminalController!
    private var previousStore: JournalStore?
    private var directory: URL!
    private let workspaceID = UUID()
    private let panelID = UUID()
    private let sessionID = UUID().uuidString.lowercased()
    private let interactivePID: Int32 = 54321
    private let processes = FakeProcesses()
    private var previousProbe: ((pid_t) -> MailboxAgentForeground.ProcessTerminalInfo?)?

    override func setUp() async throws {
        controller = TerminalController.makeForTesting()
        let processes = self.processes
        previousProbe = JournalOwnerRecovery.replaceProcessProbeForTesting { processes.info($0) }
        processes.start(interactivePID, secondsAgo: 30)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-580-journal-\(UUID().uuidString)", isDirectory: true)
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory))
        previousStore = JournalCoordinator.shared.replaceStoreForTesting(store)
        JournalCoordinator.shared.register(panelID: panelID, workspaceID: workspaceID)
    }

    override func tearDown() async throws {
        if let previousProbe { JournalOwnerRecovery.replaceProcessProbeForTesting(previousProbe) }
        JournalCoordinator.shared.remove(panelID: panelID)
        _ = JournalCoordinator.shared.replaceStoreForTesting(previousStore)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A wrapper's launch boundary, `secondsAgo` ago.
    private func claimPlaceholder(launch: Int = 1, secondsAgo: TimeInterval = 10) async {
        _ = await ConversationStore.shared.claim(
            surfaceId: panelID.uuidString,
            kind: "claude-code",
            cwd: "/tmp/c11-580",
            placeholderId: "wrapper-claim:\(panelID.uuidString):\(launch)",
            capturedAt: Date().addingTimeInterval(-secondsAgo),
            expiresAt: nil
        )
    }

    private func draft(_ subcommand: String, session: String? = nil, object: [String: Any]? = nil) throws -> JournalDraft {
        var draft = try XCTUnwrap(ClaudeHookMapping.map(
            subcommand: subcommand,
            object: object ?? ["session_id": session ?? sessionID, "tool_name": "Bash", "tool_use_id": "toolu_c11_580"]
        ))
        draft.panelID = panelID
        draft.workspaceID = workspaceID
        return draft
    }

    private func append(_ subcommand: String, object: [String: Any]? = nil, interactive: Bool = true) async throws {
        try await send(try draft(subcommand, object: object), pid: interactive ? interactivePID : nil)
    }

    /// Off main, as the socket worker runs it: the store hop must not need main.
    private func send(_ draft: JournalDraft, pid: Int32?) async throws {
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.canonicalData()) as? [String: Any])
        var params: [String: Any] = ["event": event]
        if let pid { params["interactive_pid"] = pid }
        let request = try XCTUnwrap(String(
            data: JSONSerialization.data(
                withJSONObject: ["id": 1, "method": "agent.event.append", "params": params],
                options: [.sortedKeys]
            ),
            encoding: .utf8
        ))
        let controller = self.controller!
        let reply: String = await withCheckedContinuation { continuation in
            nonisolated(unsafe) let unsafeController = controller
            DispatchQueue.global().async {
                continuation.resume(returning: unsafeController.processCommandUsingSocketExecutionPolicy(request))
            }
        }
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, true, reply)
    }

    private var readback: [String: Any] { JournalCoordinator.shared.readback(panelID: panelID) }

    private func assertNoOwner(file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(readback["connection"] as? String, "unknown", file: file, line: line)
        XCTAssertEqual(readback["coverage"] as? String, "unavailable", file: file, line: line)
        XCTAssertNil(JournalCoordinator.shared.exactOwner(panelID: panelID), file: file, line: line)
        let active = await ConversationStore.shared.active(for: panelID.uuidString)
        XCTAssertEqual(active?.placeholder, true, file: file, line: line)
    }

    private func assertRecovered(phase: String, turnOpen: Bool, session: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(readback["connection"] as? String, "live", file: file, line: line)
        XCTAssertEqual(readback["coverage"] as? String, "observed", file: file, line: line)
        XCTAssertEqual(readback["phase"] as? String, phase, file: file, line: line)
        XCTAssertEqual(MailboxStdinDelivery.journalTurnOpen(JournalCoordinator.shared.snapshot(panelID: panelID)),
                       turnOpen, "the doorbell gate reads this", file: file, line: line)
        let active = await ConversationStore.shared.active(for: panelID.uuidString)
        XCTAssertEqual(active?.id, session ?? sessionID, file: file, line: line)
        XCTAssertEqual(active?.placeholder, false, file: file, line: line)
    }

    private var owner: JournalOwner { JournalOwner(panelID: panelID, agentKind: "claude-code", sessionID: sessionID) }

    func testPromptSubmitRecoversAWorkingTurnThatHoldsTheDoorbell() async throws {
        await claimPlaceholder()
        await assertNoOwner()
        try await append("prompt-submit")
        await assertRecovered(phase: "working", turnOpen: true)
    }

    /// A tool observation alone recovers the owner but does not invent a turn
    /// state; the session's next turn edge connects it.
    func testToolHookRecoversTheOwnerAndTheNextEdgeConnects() async throws {
        await claimPlaceholder()
        try await append("pre-tool-use")
        XCTAssertEqual(JournalCoordinator.shared.exactOwner(panelID: panelID)?.sessionID, sessionID)
        // Evidence of a running tool must never read as an idle prompt.
        XCTAssertNotEqual(readback["phase"] as? String, "idle")
        try await append("stop")
        await assertRecovered(phase: "idle", turnOpen: false)
    }

    func testPermissionRequestRecoversABlockedTurnThatHoldsTheDoorbell() async throws {
        await claimPlaceholder()
        try await append("permission-request")
        await assertRecovered(phase: "blocked", turnOpen: true)
    }

    func testStopRecoversAnIdlePrompt() async throws {
        await claimPlaceholder()
        try await append("stop")
        await assertRecovered(phase: "idle", turnOpen: false)
    }

    func testLaterHooksKeepFlowingAfterRecovery() async throws {
        await claimPlaceholder()
        try await append("prompt-submit")
        try await append("stop")
        await assertRecovered(phase: "idle", turnOpen: false)
    }

    func testEmptySlotIsRecoveredToo() async throws {
        try await append("prompt-submit")
        await assertRecovered(phase: "working", turnOpen: true)
    }

    /// A nested `claude -p` carries no interactive marker.
    func testHeadlessHookDoesNotAdopt() async throws {
        await claimPlaceholder()
        try await append("prompt-submit", interactive: false)
        await assertNoOwner()
    }

    func testSubagentHookDoesNotAdopt() async throws {
        await claimPlaceholder()
        try await append("subagent-stop", object: ["session_id": sessionID, "agent_id": "a61650034a3b08687"])
        await assertNoOwner()
    }

    func testSessionEndDoesNotAdopt() async throws {
        await claimPlaceholder()
        try await append("session-end")
        await assertNoOwner()
    }

    // MARK: - Provenance (Astra P1 on #915)

    /// Astra's sequence: A loses SessionStart and has a hook in flight; A
    /// exits; B claims the panel and also loses SessionStart; A's request is
    /// processed late. A must not become B's owner, and B must still recover.
    func testDelayedHookFromAnExitedClaudeCannotClaimTheNextLaunch() async throws {
        let sessionA = UUID().uuidString.lowercased(), pidA: Int32 = 40001
        processes.start(pidA, secondsAgo: 120)
        await claimPlaceholder(launch: 1, secondsAgo: 120)
        var late = try draft("pre-tool-use", session: sessionA)
        late.emittedAtMs -= 60_000
        processes.exit(pidA)
        await claimPlaceholder(launch: 2, secondsAgo: 20)
        try await send(late, pid: pidA)
        await assertNoOwner()
        try await append("prompt-submit")
        await assertRecovered(phase: "working", turnOpen: true)
    }

    /// A exited before B's claim landed, so A's placeholder is still the
    /// newest. Only the live-process check stands between A and the panel.
    func testHookFromAnExitedClaudeIsRefusedBeforeTheNextClaimLands() async throws {
        let sessionA = UUID().uuidString.lowercased(), pidA: Int32 = 40002
        processes.start(pidA, secondsAgo: 120)
        await claimPlaceholder(launch: 1, secondsAgo: 120)
        let late = try draft("stop", session: sessionA)
        processes.exit(pidA)
        try await send(late, pid: pidA)
        await assertNoOwner()
        XCTAssertFalse(JournalCoordinator.shared.ownerRecoveryRefused(
            JournalOwner(panelID: panelID, agentKind: "claude-code", sessionID: sessionA)),
            "a dead-process rejection is not a refusal")
        try await append("prompt-submit")
        await assertRecovered(phase: "working", turnOpen: true)
    }

    /// A's PID now belongs to a process that started after A's event.
    func testReusedPidCannotVouchForAnEarlierEvent() async throws {
        let sessionA = UUID().uuidString.lowercased(), pidA: Int32 = 40003
        processes.start(pidA, secondsAgo: 120)
        await claimPlaceholder(launch: 1, secondsAgo: 120)
        var late = try draft("stop", session: sessionA)
        late.emittedAtMs -= 30_000
        processes.start(pidA, secondsAgo: 5)
        try await send(late, pid: pidA)
        await assertNoOwner()
    }

    /// The store keeps an observation older than the newest wrapper claim
    /// out, whatever the process check said.
    func testHookOlderThanTheNewestClaimIsStale() async throws {
        let sessionA = UUID().uuidString.lowercased(), pidA: Int32 = 40004
        processes.start(pidA, secondsAgo: 120)
        await claimPlaceholder(launch: 1, secondsAgo: 120)
        var late = try draft("stop", session: sessionA)
        late.emittedAtMs -= 60_000
        await claimPlaceholder(launch: 2, secondsAgo: 20)
        try await send(late, pid: pidA)
        await assertNoOwner()
        XCTAssertFalse(JournalCoordinator.shared.ownerRecoveryRefused(
            JournalOwner(panelID: panelID, agentKind: "claude-code", sessionID: sessionA)),
            "a stale observation is not a refusal")
        try await append("stop")
        await assertRecovered(phase: "idle", turnOpen: false)
    }

    func testLiveSourceNeedsAForegroundProcessThatPredatesTheEvent() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let started = UInt64(now - 10_000) * 1_000
        func info(group: pid_t = 7, foreground: pid_t = 7, device: dev_t = 0x1000_0007,
                  zombie: Bool = false, start: UInt64? = nil) -> MailboxAgentForeground.ProcessTerminalInfo {
            .init(processGroup: group, terminalForegroundGroup: foreground, terminalDevice: device,
                  isZombie: zombie, startTime: start ?? started, parentPID: 1)
        }
        XCTAssertTrue(JournalOwnerRecovery.isLiveSource(info(), emittedAtMs: now))
        XCTAssertFalse(JournalOwnerRecovery.isLiveSource(nil, emittedAtMs: now), "exited")
        XCTAssertFalse(JournalOwnerRecovery.isLiveSource(info(zombie: true), emittedAtMs: now), "zombie")
        XCTAssertFalse(JournalOwnerRecovery.isLiveSource(info(device: -1), emittedAtMs: now), "no terminal")
        XCTAssertFalse(JournalOwnerRecovery.isLiveSource(info(foreground: 9), emittedAtMs: now), "suspended or backgrounded")
        XCTAssertFalse(JournalOwnerRecovery.isLiveSource(info(start: UInt64(now + 1_000) * 1_000), emittedAtMs: now),
                       "started after the event")
    }

    // MARK: - Refusals

    func testARefusedSessionIsNotTriedAgain() async throws {
        await claimPlaceholder()
        JournalCoordinator.shared.noteOwnerRecoveryRefused(owner)
        try await append("prompt-submit")
        await assertNoOwner()
    }

    /// Refusals are a set per panel: A, B, then A again stays refused.
    func testRefusalsAreRememberedPerSession() async throws {
        let scraped = UUID().uuidString.lowercased()
        _ = await ConversationStore.shared.push(
            surfaceId: panelID.uuidString, kind: "claude-code", id: scraped, source: .scrape)
        XCTAssertNil(JournalCoordinator.shared.exactOwner(panelID: panelID), "a scraped ref is not a causal owner")
        let sessionB = UUID().uuidString.lowercased()
        try await append("prompt-submit")
        try await send(try draft("prompt-submit", session: sessionB), pid: interactivePID)
        XCTAssertTrue(JournalCoordinator.shared.ownerRecoveryRefused(owner))
        XCTAssertTrue(JournalCoordinator.shared.ownerRecoveryRefused(
            JournalOwner(panelID: panelID, agentKind: "claude-code", sessionID: sessionB)))
        let active = await ConversationStore.shared.active(for: panelID.uuidString)
        XCTAssertEqual(active?.id, scraped)
    }

    func testRealRefIsNeverDisplaced() async throws {
        let real = UUID().uuidString.lowercased()
        _ = await ConversationStore.shared.push(
            surfaceId: panelID.uuidString, kind: "claude-code", id: real, source: .hook)
        try await append("prompt-submit")
        let active = await ConversationStore.shared.active(for: panelID.uuidString)
        XCTAssertEqual(active?.id, real)
        XCTAssertEqual(JournalCoordinator.shared.exactOwner(panelID: panelID)?.sessionID, real)
    }
}
