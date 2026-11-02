import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

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

    override func setUp() async throws {
        controller = TerminalController.makeForTesting()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-580-journal-\(UUID().uuidString)", isDirectory: true)
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory))
        previousStore = JournalCoordinator.shared.replaceStoreForTesting(store)
        JournalCoordinator.shared.register(panelID: panelID, workspaceID: workspaceID)
    }

    override func tearDown() async throws {
        JournalCoordinator.shared.remove(panelID: panelID)
        _ = JournalCoordinator.shared.replaceStoreForTesting(previousStore)
        try? FileManager.default.removeItem(at: directory)
    }

    private func claimPlaceholder() async {
        _ = await ConversationStore.shared.claim(
            surfaceId: panelID.uuidString,
            kind: "claude-code",
            cwd: "/tmp/c11-580",
            placeholderId: "wrapper-claim:\(panelID.uuidString):1",
            expiresAt: nil
        )
    }

    /// Off main, as the socket worker runs it: the store hop must not need main.
    private func append(_ subcommand: String, object: [String: Any]? = nil, interactive: Bool = true) async throws {
        var draft = try XCTUnwrap(ClaudeHookMapping.map(
            subcommand: subcommand,
            object: object ?? ["session_id": sessionID, "tool_name": "Bash", "tool_use_id": "toolu_c11_580"]
        ))
        draft.panelID = panelID
        draft.workspaceID = workspaceID
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.canonicalData()) as? [String: Any])
        var params: [String: Any] = ["event": event]
        if interactive { params["interactive_pid"] = interactivePID }
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

    private func assertRecovered(phase: String, turnOpen: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(readback["connection"] as? String, "live", file: file, line: line)
        XCTAssertEqual(readback["coverage"] as? String, "observed", file: file, line: line)
        XCTAssertEqual(readback["phase"] as? String, phase, file: file, line: line)
        XCTAssertEqual(MailboxStdinDelivery.journalTurnOpen(JournalCoordinator.shared.snapshot(panelID: panelID)),
                       turnOpen, "the doorbell gate reads this", file: file, line: line)
        let active = await ConversationStore.shared.active(for: panelID.uuidString)
        XCTAssertEqual(active?.id, sessionID, file: file, line: line)
        XCTAssertEqual(active?.placeholder, false, file: file, line: line)
    }

    func testPromptSubmitRecoversAWorkingTurnThatHoldsTheDoorbell() async throws {
        await claimPlaceholder()
        await assertNoOwner()
        try await append("prompt-submit")
        await assertRecovered(phase: "working", turnOpen: true)
    }

    func testToolHookRecoversAWorkingTurnThatHoldsTheDoorbell() async throws {
        await claimPlaceholder()
        try await append("pre-tool-use")
        XCTAssertEqual(readback["connection"] as? String, "live")
        XCTAssertEqual(JournalCoordinator.shared.exactOwner(panelID: panelID)?.sessionID, sessionID)
        // Evidence of a running tool must never read as an idle prompt.
        XCTAssertNotEqual(readback["phase"] as? String, "idle")
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
