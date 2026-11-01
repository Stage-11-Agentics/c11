import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Finder tests use a temp directory as HOME. They never read the operator's
/// `~/.claude` or `~/.codex`. The file is a `c11LogicTests` member.
final class SessionFinderTests: XCTestCase {
    private let claudeID = "11111111-1111-4111-8111-111111111111"
    private let codexID = "22222222-2222-4222-8222-222222222222"
    private let goneID = "33333333-3333-4333-8333-333333333333"
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    func testFindsClaudeAndCodexByPromptPhrase() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false),
            roots: fixture.roots,
            now: fixture.when
        )
        XCTAssertEqual(result.matchCount, 2)
        XCTAssertFalse(result.truncated)
        let claude = try XCTUnwrap(result.rows.first { $0.sessionID == claudeID })
        let codex = try XCTUnwrap(result.rows.first { $0.sessionID == codexID })
        XCTAssertEqual(claude.harness, .claude)
        XCTAssertEqual(claude.kind, "claude-code")
        XCTAssertEqual(claude.state, .idle)
        XCTAssertEqual(claude.cwd, "/Users/test/proj")
        XCTAssertEqual(claude.title, "Lattice notes")
        XCTAssertEqual(codex.harness, .codex)
        XCTAssertEqual(codex.kind, "codex")
        XCTAssertEqual(codex.state, .idle)
        XCTAssertEqual(codex.cwd, "/Users/test/codex")
        XCTAssertEqual(codex.title, "ship the zephyr-needle")
        XCTAssertEqual(
            SessionFinder.formatISOTimestamp(claude.lastActive, timeZone: zone),
            "2026-10-31T15:04:00-07:00"
        )
        XCTAssertTrue(SessionFinder.formatLocalTimestamp(claude.lastActive, timeZone: zone).hasPrefix("2026-10-31 15:04"))

        let object = SessionFinder.jsonObject(result, timeZone: zone)
        XCTAssertEqual(object["query"] as? String, "zephyr-needle")
        XCTAssertEqual(object["deep"] as? Bool, false)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let skipped = try XCTUnwrap(object["skipped"] as? [String: Any])
        XCTAssertEqual(Set(skipped.keys), ["corrupt_lines", "huge_files", "unreadable_files"])
        let rows = try XCTUnwrap(object["results"] as? [[String: Any]])
        let claudeJSON = try XCTUnwrap(rows.first { $0["session_id"] as? String == claudeID })
        XCTAssertEqual(
            Set(claudeJSON.keys),
            ["harness", "kind", "session_id", "state", "cwd", "last_active", "title"]
        )
        XCTAssertEqual(claudeJSON["harness"] as? String, "claude")
        XCTAssertEqual(claudeJSON["state"] as? String, "idle")
        XCTAssertEqual(claudeJSON["last_active"] as? String, "2026-10-31T15:04:00-07:00")
        let encoded = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("SECRET-INSTRUCTIONS"))
        XCTAssertGreaterThanOrEqual(result.skipped.corruptLines, 1)
    }

    func testDefaultSearchSkipsAssistantTextAndHeaderInstructions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let assistant = SessionFinder.search(
            query: SessionFinder.Query(text: "assistant-only-quartz", deep: false),
            roots: fixture.roots
        )
        XCTAssertEqual(assistant.matchCount, 0)
        let secret = SessionFinder.search(
            query: SessionFinder.Query(text: "SECRET-INSTRUCTIONS", deep: false),
            roots: fixture.roots
        )
        XCTAssertEqual(secret.matchCount, 0)
        let deep = SessionFinder.search(
            query: SessionFinder.Query(text: "assistant-only-quartz", deep: true),
            roots: fixture.roots
        )
        XCTAssertEqual(deep.rows.map(\.sessionID), [claudeID])
    }

    func testLiveRowFocusesAndDoesNotResume() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let live = SessionFinder.LiveHit(
            kind: "claude-code",
            sessionID: claudeID,
            conversationState: "suspended",
            placeholder: false,
            panelID: "PANEL-LIVE",
            panelRef: "panel:4",
            workspaceID: "WS-LIVE",
            workspaceRef: "workspace:2",
            cwd: "/Users/test/proj"
        )
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false),
            roots: fixture.roots,
            liveHits: [live]
        )
        let claude = try XCTUnwrap(result.rows.first { $0.sessionID == claudeID })
        XCTAssertEqual(claude.state, .live)
        XCTAssertEqual(claude.panelRef, "panel:4")
        XCTAssertEqual(claude.workspaceRef, "workspace:2")
        XCTAssertNil(claude.link)
        XCTAssertNil(SessionFinder.panelLink(panelID: "PANEL-LIVE"))
        guard case .focus(let panelID, let workspaceID) = SessionFinder.action(for: claude) else {
            return XCTFail("live row must focus, not resume")
        }
        XCTAssertEqual(panelID, "PANEL-LIVE")
        XCTAssertEqual(workspaceID, "WS-LIVE")
        let call = SessionFinder.focusCall(panelID: panelID, workspaceID: workspaceID)
        XCTAssertEqual(call.method, "panel.focus")
        XCTAssertNotEqual(call.method, "workspace.select")
        XCTAssertEqual(Set(call.params.keys), ["panel_id", "workspace_id"])
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "zephyr-needle"))
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "Lattice notes"))
        let codex = try XCTUnwrap(result.rows.first { $0.sessionID == codexID })
        XCTAssertEqual(codex.state, .idle)
        XCTAssertNotEqual(SessionFinder.action(for: codex), SessionFinder.action(for: claude))
    }

    func testAlivePanelWinsAndPlaceholderIsNotLive() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let hits = [
            SessionFinder.LiveHit(
                kind: "claude-code", sessionID: claudeID, conversationState: "suspended",
                placeholder: false, panelID: "PANEL-B", panelRef: "panel:9",
                workspaceID: "WS", workspaceRef: "workspace:1", cwd: nil
            ),
            SessionFinder.LiveHit(
                kind: "claude-code", sessionID: claudeID, conversationState: "alive",
                placeholder: false, panelID: "PANEL-A", panelRef: "panel:3",
                workspaceID: "WS", workspaceRef: "workspace:1", cwd: nil
            ),
            SessionFinder.LiveHit(
                kind: "codex", sessionID: codexID, conversationState: "alive",
                placeholder: true, panelID: "PANEL-PH", panelRef: "panel:1",
                workspaceID: "WS", workspaceRef: "workspace:1", cwd: nil
            ),
            SessionFinder.LiveHit(
                kind: "codex", sessionID: codexID, conversationState: "tombstoned",
                placeholder: false, panelID: "PANEL-TOMB", panelRef: "panel:2",
                workspaceID: "WS", workspaceRef: "workspace:1", cwd: nil
            )
        ]
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false),
            roots: fixture.roots,
            liveHits: hits
        )
        let claude = try XCTUnwrap(result.rows.first { $0.sessionID == claudeID })
        XCTAssertEqual(claude.panelID, "PANEL-A")
        let codex = try XCTUnwrap(result.rows.first { $0.sessionID == codexID })
        XCTAssertEqual(codex.state, .idle)
        guard case .resume = SessionFinder.action(for: codex) else {
            return XCTFail("placeholder and tombstone leave the file idle")
        }
    }

    func testExitedAgentIsIdleAndResumes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let hit = SessionFinder.LiveHit(
            kind: "claude-code", sessionID: claudeID, conversationState: "unknown",
            placeholder: false, panelID: "PANEL-EXITED", panelRef: "panel:8",
            workspaceID: "WS", workspaceRef: "workspace:1", cwd: "/Users/test/proj"
        )
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false),
            roots: fixture.roots,
            liveHits: [hit]
        )
        let row = try XCTUnwrap(result.rows.first { $0.sessionID == claudeID })
        XCTAssertEqual(row.state, .idle)
        XCTAssertNil(row.panelID)
        guard case .resume = SessionFinder.action(for: row) else {
            return XCTFail("an exited agent resumes instead of focusing the empty shell")
        }
    }

    func testStoreTimeoutIsNotAnEmptyConversationList() {
        let missing = TerminalController.conversationListPayload(
            snapshot: nil, isDisabled: false, surfaceFilter: nil
        )
        guard case .err(let code, let message, _) = missing else {
            return XCTFail("a nil snapshot must be a store timeout")
        }
        XCTAssertEqual(code, "internal_error")
        XCTAssertEqual(message, "store timeout")
        let ref = ConversationRef(
            kind: "claude-code", id: claudeID, cwd: "/Users/test/proj",
            capturedVia: .hook, state: .alive
        )
        let listed = TerminalController.conversationListPayload(
            snapshot: ["PANEL": PanelConversations(active: ref)],
            isDisabled: true,
            surfaceFilter: nil
        )
        guard case .ok(let payload) = listed, let object = payload as? [String: Any] else {
            return XCTFail("a snapshot must still list")
        }
        XCTAssertEqual(object["is_disabled"] as? Bool, true)
        XCTAssertEqual((object["conversations"] as? [[String: Any]])?.count, 1)
    }

    func testDisabledStoreRefusesOpen() {
        XCTAssertTrue(SessionFinder.refusesOpen(liveList: ["is_disabled": true, "conversations": []]))
        XCTAssertTrue(SessionFinder.refusesOpen(liveList: ["is_disabled": NSNumber(value: true)]))
        XCTAssertFalse(SessionFinder.refusesOpen(liveList: ["is_disabled": false, "conversations": []]))
        XCTAssertFalse(SessionFinder.refusesOpen(liveList: ["conversations": []]))
    }

    func testPhraseAcrossChunkBoundaryIsFound() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let phrase = "boundary-pearl"
        let id = "44444444-4444-4444-8444-444444444448"
        let split = phrase.utf8.count / 2
        _ = try fixture.addClaude(
            id: id,
            bytes: SessionFinder.headByteCap + phrase.utf8.count,
            phrase: phrase,
            phraseAt: SessionFinder.headByteCap - split
        )
        let shallow = SessionFinder.search(
            query: SessionFinder.Query(text: phrase, deep: false),
            roots: fixture.roots
        )
        XCTAssertFalse(shallow.rows.contains { $0.sessionID == id })
        let deep = SessionFinder.search(
            query: SessionFinder.Query(text: phrase, deep: true),
            roots: fixture.roots
        )
        XCTAssertTrue(deep.rows.contains { $0.sessionID == id })
    }

    func testIdleResumeMatchesStrategy() throws {
        let cwd = "/Users/test/it's"
        let claude = SessionFinder.resumeCommand(kind: "claude-code", sessionID: claudeID, cwd: cwd)
        let codex = SessionFinder.resumeCommand(kind: "codex", sessionID: codexID, cwd: cwd)
        let claudeRef = ConversationRef(
            kind: "claude-code", id: claudeID, cwd: cwd, capturedVia: .hook, state: .alive
        )
        let codexRef = ConversationRef(
            kind: "codex", id: codexID, cwd: cwd, capturedVia: .hook, state: .alive
        )
        guard case .typeCommand(let claudeText, let claudeSubmit) = ClaudeCodeStrategy().resume(ref: claudeRef) else {
            return XCTFail("claude strategy resume")
        }
        guard case .typeCommand(let codexText, let codexSubmit) = CodexStrategy().resume(ref: codexRef) else {
            return XCTFail("codex strategy resume")
        }
        XCTAssertTrue(claudeSubmit)
        XCTAssertTrue(codexSubmit)
        XCTAssertEqual(claude, claudeText)
        XCTAssertEqual(codex, codexText)
        XCTAssertFalse(claudeText.contains("\n"))
        XCTAssertTrue(claudeText.contains("cd '/Users/test/it'\\''s' && claude --dangerously-skip-permissions --resume"))
        XCTAssertTrue(codexText.contains("codex resume --yolo"))
        XCTAssertNil(SessionFinder.resumeCommand(kind: "claude-code", sessionID: "not-a-uuid", cwd: cwd))
    }

    func testSocketParamsOmitTitleAndQuery() {
        let command = "cd '/tmp/proj' && claude --dangerously-skip-permissions --resume '\(claudeID)'"
        let call = SessionFinder.resumeCall(command: command, cwd: "/tmp/proj", callerWorkspaceID: "WS-CALLER")
        XCTAssertEqual(call.method, "panel.create")
        XCTAssertNotEqual(call.method, "workspace.select")
        XCTAssertEqual(call.params["type"], "terminal")
        XCTAssertEqual(call.params["cwd"], "/tmp/proj")
        XCTAssertEqual(call.params["workspace_id"], "WS-CALLER")
        XCTAssertEqual(call.params["initial_input"], command)
        XCTAssertFalse(call.params.keys.contains("title"))
        XCTAssertFalse(call.params.keys.contains("query"))
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "zephyr-needle"))
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "Lattice notes"))
    }

    func testGoneRowIsRefusedAndOmittedFromRecentList() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let found = SessionFinder.search(
            query: SessionFinder.Query(text: "gone-amber", deep: false),
            roots: fixture.roots
        )
        XCTAssertEqual(found.matchCount, 1)
        let row = try XCTUnwrap(found.rows.first)
        XCTAssertEqual(row.sessionID, goneID)
        XCTAssertEqual(row.state, .gone)
        XCTAssertEqual(row.lastActive.timeIntervalSince1970, 1_761_951_840, accuracy: 0.001)
        XCTAssertEqual(SessionFinder.action(for: row), .refuse)
        XCTAssertEqual(SessionFinder.openChoice(found), .gone(sessionID: goneID))
        let recent = SessionFinder.search(
            query: SessionFinder.Query(text: "", deep: false),
            roots: fixture.roots
        )
        XCTAssertFalse(recent.rows.contains { $0.sessionID == goneID })
        XCTAssertEqual(Set(recent.rows.map(\.sessionID)), [claudeID, codexID])
    }

    func testOpenUsesFullMatchCountNotDisplayLimit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false, limit: 1),
            roots: fixture.roots,
            liveHits: [
                SessionFinder.LiveHit(
                    kind: "claude-code", sessionID: claudeID, conversationState: "alive",
                    placeholder: false, panelID: "PANEL-LIVE", panelRef: "panel:4",
                    workspaceID: "WS", workspaceRef: "workspace:1", cwd: nil
                )
            ]
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.matchCount, 2)
        XCTAssertTrue(result.truncated)
        guard case .ambiguous(2) = SessionFinder.openChoice(result) else {
            return XCTFail("limit must not hide a second match from --open")
        }
    }

    func testLiveRowCarriesPanelLink() throws {
        let panel = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let hit = SessionFinder.LiveHit(
            kind: "claude-code", sessionID: claudeID, conversationState: "alive",
            placeholder: false, panelID: panel, panelRef: "panel:4",
            workspaceID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", workspaceRef: "workspace:2",
            cwd: "/Users/test/proj"
        )
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false),
            roots: fixture.roots,
            liveHits: [hit]
        )
        let row = try XCTUnwrap(result.rows.first { $0.sessionID == claudeID })
        let id = try XCTUnwrap(UUID(uuidString: panel))
        let expected = PanelLinkFormat.url(kind: .panel, id: id)
        XCTAssertEqual(expected, "c11://panel/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(row.link, expected)
        let json = SessionFinder.jsonRow(row, timeZone: zone)
        XCTAssertEqual(json["link"] as? String, expected)
        let idle = try XCTUnwrap(result.rows.first { $0.sessionID == codexID })
        XCTAssertNil(idle.link)
        XCTAssertNil(SessionFinder.jsonRow(idle, timeZone: zone)["link"])
        let call = SessionFinder.focusCall(panelID: panel, workspaceID: hit.workspaceID)
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "c11://"))
        XCTAssertFalse(SessionFinder.paramsContain(call.params, needle: "zephyr-needle"))
    }

    func testDeepScanStopsAtTheMatchLimit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let phrase = "stop-early-pearl"
        let newest = "44444444-4444-4444-8444-444444444441"
        let middle = "44444444-4444-4444-8444-444444444442"
        let oldest = "44444444-4444-4444-8444-444444444443"
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"\(phrase)\"}}\n".utf8).write(to: fixture.claudeFile(newest))
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"\(phrase)\"}}\n".utf8).write(to: fixture.claudeFile(middle))
        _ = try fixture.addClaude(
            id: oldest,
            bytes: SessionFinder.hugeFileBytes + 4096,
            phrase: phrase,
            phraseAt: 32
        )
        let now = fixture.when
        // Fixture history is dated `now`, so these matches have to be newer than that
        // or the newest-first walk opens those older files before it can stop.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(20)], ofItemAtPath: fixture.claudeFile(newest).path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: fixture.claudeFile(middle).path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-200_000)], ofItemAtPath: fixture.claudeFile(oldest).path)
        var reads: [Int] = []
        let stopped = SessionFinder.search(
            query: SessionFinder.Query(text: phrase, deep: true, limit: 2),
            roots: fixture.roots,
            now: now,
            matchStop: 2,
            progress: { reads.append($0.filesRead) }
        )
        XCTAssertEqual(reads, [1, 2])
        XCTAssertEqual(stopped.filesRead, 2)
        XCTAssertEqual(Set(stopped.rows.map(\.sessionID)), Set([newest, middle]))
        XCTAssertEqual(stopped.matchCount, 2)
        XCTAssertEqual(stopped.rows.count, 2)
        XCTAssertTrue(stopped.truncated)
        XCTAssertEqual(stopped.skipped.hugeFiles, 0)
        XCTAssertLessThan(stopped.bytesRead, SessionFinder.headByteCap * 2)
        XCTAssertFalse(stopped.rows.contains { $0.sessionID == oldest })
        let opened = SessionFinder.search(
            query: SessionFinder.Query(text: phrase, deep: true, limit: 1),
            roots: fixture.roots,
            now: now,
            matchStop: 2
        )
        XCTAssertEqual(opened.rows.count, 1)
        XCTAssertEqual(opened.matchCount, 2)
        XCTAssertEqual(opened.skipped.hugeFiles, 0)
        guard case .ambiguous(2) = SessionFinder.openChoice(opened) else {
            return XCTFail("stopping at two matches must still refuse --open")
        }
    }

    func testDeepReadStopsInsideTheMatchingFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let id = "44444444-4444-4444-8444-444444444449"
        _ = try fixture.addClaude(id: id, bytes: 2 * 1024 * 1024, phrase: "stream-pearl", phraseAt: 100)
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "stream-pearl", deep: true),
            roots: fixture.roots
        )
        XCTAssertEqual(result.rows.map(\.sessionID), [id])
        XCTAssertLessThan(result.bytesRead, SessionFinder.headByteCap * 2)
    }

    func testDeepReadDoesNotFindPhrasePastCaps() throws {
        XCTAssertEqual(SessionFinder.headByteCap, 64 * 1024)
        XCTAssertEqual(SessionFinder.deepReadCap, 1024 * 1024)
        XCTAssertEqual(SessionFinder.hugeFileBytes, 8 * 1024 * 1024)
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let phrase = "deep-only-lantern"
        let mid = try fixture.addClaude(id: "44444444-4444-4444-8444-444444444444", bytes: 2 * 1024 * 1024, phrase: phrase, phraseAt: 200 * 1024)
        let past = try fixture.addClaude(id: "55555555-5555-4555-8555-555555555555", bytes: SessionFinder.deepReadCap + 200_000, phrase: phrase, phraseAt: SessionFinder.deepReadCap + 64)
        let huge = try fixture.addClaude(id: "66666666-6666-4666-8666-666666666666", bytes: SessionFinder.hugeFileBytes + 1024 * 1024, phrase: phrase, phraseAt: 200 * 1024)
        let shallow = SessionFinder.search(query: SessionFinder.Query(text: phrase, deep: false), roots: fixture.roots)
        XCTAssertEqual(shallow.matchCount, 0)
        XCTAssertEqual(shallow.skipped.hugeFiles, 0)
        let deep = SessionFinder.search(query: SessionFinder.Query(text: phrase, deep: true), roots: fixture.roots)
        XCTAssertEqual(deep.rows.map(\.sessionID), [mid])
        XCTAssertEqual(deep.skipped.hugeFiles, 1)
        XCTAssertFalse(deep.rows.contains { $0.sessionID == past })
        XCTAssertFalse(deep.rows.contains { $0.sessionID == huge })
        let headOfHuge = "77777777-7777-4777-8777-777777777777"
        var headBytes = Data("{\"type\":\"user\",\"message\":{\"content\":\"huge-head-pearl\"}}\n".utf8)
        headBytes.append(Data(count: SessionFinder.hugeFileBytes + 4096 - headBytes.count))
        try headBytes.write(to: fixture.claudeFile(headOfHuge))
        let headHit = SessionFinder.search(query: SessionFinder.Query(text: "huge-head-pearl", deep: true), roots: fixture.roots)
        XCTAssertEqual(headHit.rows.map(\.sessionID), [headOfHuge])
        XCTAssertGreaterThanOrEqual(headHit.skipped.hugeFiles, 1)
    }

    func testSearchLeavesFixtureBytesUnchanged() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.addClaude(
            id: "88888888-8888-4888-8888-888888888888",
            bytes: 128 * 1024,
            phrase: "readonly-slate",
            phraseAt: 1000
        )
        let before = try fixture.snapshot()
        _ = SessionFinder.search(query: SessionFinder.Query(text: "zephyr-needle", deep: true), roots: fixture.roots)
        _ = SessionFinder.search(query: SessionFinder.Query(text: "readonly-slate", deep: false), roots: fixture.roots)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testUnreadableFileIsCounted() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let url = fixture.claudeFile("99999999-9999-4999-8999-999999999999")
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"hidden-copper\"}}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let result = SessionFinder.search(
            query: SessionFinder.Query(text: "hidden-copper", deep: false),
            roots: fixture.roots
        )
        XCTAssertEqual(result.matchCount, 0)
        XCTAssertGreaterThanOrEqual(result.skipped.unreadableFiles, 1)
    }

    func testMillisecondHistoryTimestampAndSessionFilter() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let filtered = SessionFinder.search(
            query: SessionFinder.Query(text: "zephyr-needle", deep: false, sessionID: codexID.uppercased()),
            roots: fixture.roots
        )
        XCTAssertEqual(filtered.rows.map(\.sessionID), [codexID])
        let both = SessionFinder.search(
            query: SessionFinder.Query(text: "missing-phrase", deep: false, sessionID: codexID),
            roots: fixture.roots
        )
        XCTAssertEqual(both.matchCount, 0)
    }

    func testParseArguments() {
        guard case .success(let parsed) = SessionFinder.parseArguments(["zephyr", "-a", "--open", "--limit", "5", "--session", claudeID, "--workspace", "WS"]) else {
            return XCTFail("parse")
        }
        XCTAssertEqual(parsed.query.text, "zephyr")
        XCTAssertTrue(parsed.query.deep)
        XCTAssertTrue(parsed.open)
        XCTAssertEqual(parsed.query.limit, 5)
        XCTAssertEqual(parsed.query.sessionID, claudeID)
        XCTAssertEqual(parsed.callerWorkspace, "WS")
        XCTAssertEqual(SessionFinder.parseArguments(["one", "two"]), .failure(.extraWord("two")))
        XCTAssertEqual(SessionFinder.parseArguments(["--limit", "0"]), .failure(.badLimit))
        XCTAssertEqual(SessionFinder.parseArguments(["--limit", "201"]), .failure(.badLimit))
        XCTAssertEqual(SessionFinder.parseArguments(["--session", "nope"]), .failure(.badSession))
        XCTAssertEqual(SessionFinder.parseArguments(["--nope"]), .failure(.unknownFlag("--nope")))
    }

    func testRootsStayInsideTheGivenHome() {
        let home = URL(fileURLWithPath: "/tmp/c11-518-home", isDirectory: true)
        let override = URL(fileURLWithPath: "/tmp/c11-518-fixture/.claude/projects", isDirectory: true)
        let plain = SessionFinder.roots(home: home, environment: [
            "C11_QA_CLAUDE_PROJECTS_ROOT": override.path
        ])
        XCTAssertEqual(plain.claudeProjects.path, home.appendingPathComponent(".claude/projects").path)
        let tagged = SessionFinder.roots(home: home, environment: [
            "C11_TAG": "C11-518",
            "C11_QA_CLAUDE_PROJECTS_ROOT": override.path,
            "C11_QA_CODEX_SESSIONS_ROOT": "/tmp/c11-518-fixture/.codex/sessions"
        ])
        XCTAssertEqual(tagged.claudeProjects.path, override.path)
        XCTAssertEqual(tagged.claudeHistory.lastPathComponent, "history.jsonl")
        XCTAssertTrue(tagged.claudeHistory.path.contains("c11-518-fixture"))
        XCTAssertEqual(tagged.codexHistory.lastPathComponent, "history.jsonl")
        XCTAssertFalse(tagged.claudeProjects.path.contains(NSHomeDirectory()))
    }

    private struct Fixture {
        var root: URL
        var roots: SessionFinder.Roots
        var when: Date
        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
        func claudeFile(_ id: String) -> URL {
            roots.claudeProjects
                .appendingPathComponent("-Users-test-proj", isDirectory: true)
                .appendingPathComponent("\(id).jsonl")
        }
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            while let url = enumerator.nextObject() as? URL {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                out[url.path] = try Data(contentsOf: url)
            }
            return out
        }
        @discardableResult
        func addClaude(id: String, bytes: Int, phrase: String, phraseAt: Int) throws -> String {
            let url = claudeFile(id)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            if phraseAt > 0 {
                try handle.seek(toOffset: UInt64(phraseAt))
            }
            try handle.write(contentsOf: Data(phrase.utf8))
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
            return id
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-518-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent(".claude/projects/-Users-test-proj", isDirectory: true)
        let sessions = root.appendingPathComponent(".codex/sessions/2026/10/31", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let when = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 31, hour: 15, minute: 4, second: 0
        )))
        let older = when.addingTimeInterval(-86_400)
        let claudeURL = projects.appendingPathComponent("\(claudeID).jsonl")
        let claudeBody = """
        {"type":"ai-title","aiTitle":"Lattice notes"}
        {"type":"user","cwd":"/Users/test/proj","message":{"role":"user","content":[{"type":"text","text":"find the zephyr-needle please"}]}}
        {"type":"assistant","message":{"content":"assistant-only-quartz"}}
        not-json
        """
        try claudeBody.write(to: claudeURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: claudeURL.path)
        let rollout = sessions.appendingPathComponent("rollout-2026-10-31T15-04-00-\(codexID).jsonl")
        let codexBody = """
        {"type":"session_meta","payload":{"cwd":"/Users/test/codex","id":"\(codexID)","instructions":"SECRET-INSTRUCTIONS"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship the zephyr-needle"}]}}
        """
        try codexBody.write(to: rollout, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: rollout.path)
        let claudeHistory = """
        {"display":"find the zephyr-needle please","project":"/Users/test/proj","sessionId":"\(claudeID)","timestamp":"2026-10-31T15:04:00-07:00"}
        {"display":"gone-amber","project":"/Users/test/old","sessionId":"\(goneID)","timestamp":1761951840000}
        """
        try claudeHistory.write(
            to: root.appendingPathComponent(".claude/history.jsonl"),
            atomically: false,
            encoding: .utf8
        )
        let codexHistory = """
        {"session_id":"\(codexID)","ts":\(Int(when.timeIntervalSince1970)),"text":"ship the zephyr-needle"}
        """
        try codexHistory.write(
            to: root.appendingPathComponent(".codex/history.jsonl"),
            atomically: false,
            encoding: .utf8
        )
        let roots = SessionFinder.Roots(
            claudeProjects: root.appendingPathComponent(".claude/projects", isDirectory: true),
            claudeHistory: root.appendingPathComponent(".claude/history.jsonl"),
            codexSessions: root.appendingPathComponent(".codex/sessions", isDirectory: true),
            codexHistory: root.appendingPathComponent(".codex/history.jsonl")
        )
        return Fixture(root: root, roots: roots, when: when)
    }
}
