import XCTest
import SQLite3

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Live model detection: one fixture transcript per harness (scrubbed, in
/// `Fixtures/agent-models/`) laid out under a throwaway HOME, probed exactly the
/// way the AgentDetector sweep does.
final class AgentModelDetectionTests: XCTestCase {
    private var home: URL!
    private var probe: AgentModelProbe!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-model-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        probe = AgentModelProbe(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-models/\(name)")
        return try Data(contentsOf: url)
    }

    @discardableResult
    private func place(_ data: Data, at relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func ref(
        _ kind: String, id: String, cwd: String? = "/work/demo",
        payload: [String: PersistedJSONValue]? = nil
    ) -> ConversationRef {
        ConversationRef(kind: kind, id: id, placeholder: false, cwd: cwd,
                        capturedVia: .hook, state: .alive, payload: payload)
    }

    private func detect(_ kind: String, _ ref: ConversationRef?, _ state: inout ModelTailState) -> AgentModelDetection {
        probe.detect(kind: kind, ref: ref, state: &state)
    }

    // MARK: - Claude Code

    private let claudeId = "11111111-2222-4333-8444-555555555555"

    private func claudePath() -> String {
        ".claude/projects/\(ClaudeCodeStrategy.projectSlug(forCwd: "/work/demo"))/\(claudeId).jsonl"
    }

    func testClaudeTakesLatestAssistantModelIgnoringSidechainAndSynthetic() throws {
        try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: claudeId), &state), .model("claude-opus-5-5"))
    }

    func testClaudeSidechainAndSyntheticAloneYieldNothing() throws {
        let lines = try String(data: fixture("claude-session.jsonl"), encoding: .utf8)!
            .split(separator: "\n").filter { !$0.contains("claude-opus-5-5") && !$0.contains("claude-sonnet-4-6") }
            .joined(separator: "\n") + "\n"
        try place(Data(lines.utf8), at: claudePath())
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: claudeId), &state), .none)
    }

    func testClaudeModelSwitchMidSessionIsPickedUpIncrementally() throws {
        let url = try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-opus-5-5"))
        let offsetAfterFirst = state.offset

        try append(#"{"type":"assistant","isSidechain":false,"message":{"model":"claude-sonnet-4-6","role":"assistant","content":[]}}"# + "\n", to: url)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-sonnet-4-6"))
        XCTAssertGreaterThan(state.offset, offsetAfterFirst)
    }

    func testPartialTrailingLineIsNotConsumedUntilComplete() throws {
        let url = try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)

        let line = #"{"type":"assistant","isSidechain":false,"message":{"model":"claude-haiku-4-5","role":"assistant","content":[]}}"#
        try append(String(line.prefix(40)), to: url)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-opus-5-5"))
        try append(String(line.dropFirst(40)) + "\n", to: url)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-haiku-4-5"))
    }

    func testIncrementalPollDoesNotRereadTheWholeTranscript() throws {
        let url = try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64
        XCTAssertEqual(state.offset, size, "offset sits at the end of the last complete line")
        // Nothing appended: state is untouched.
        let before = state
        _ = detect("claude-code", r, &state)
        XCTAssertEqual(state, before)
    }

    func testLargeTranscriptWithModelFarFromTheEndIsStillFoundWithoutReadingItAll() throws {
        var data = try fixture("claude-session.jsonl")
        let filler = Data((String(repeating: "x", count: 900) + "\n").utf8)
        // ~3 MB of non-model lines after the last model line.
        for _ in 0..<3_400 { data.append(filler) }
        try place(data, at: claudePath())
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: claudeId), &state), .model("claude-opus-5-5"))
    }

    func testTruncatedOrReplacedFileRestartsScan() throws {
        let url = try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-opus-5-5"))
        try Data((#"{"type":"assistant","isSidechain":false,"message":{"model":"claude-haiku-4-5","content":[]}}"# + "\n").utf8).write(to: url)
        XCTAssertEqual(detect("claude-code", r, &state), .model("claude-haiku-4-5"))
    }

    func testMissingTranscriptIsNoneAndBackedOff() throws {
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        let now = Date()
        XCTAssertEqual(probe.detect(kind: "claude-code", ref: r, state: &state, now: now), .none)
        XCTAssertNotNil(state.nextLocateAt)
        // The file appears, but the locate back-off has not elapsed.
        try place(fixture("claude-session.jsonl"), at: claudePath())
        XCTAssertEqual(probe.detect(kind: "claude-code", ref: r, state: &state, now: now.addingTimeInterval(5)), .none)
        XCTAssertEqual(probe.detect(kind: "claude-code", ref: r, state: &state, now: now.addingTimeInterval(31)),
                       .model("claude-opus-5-5"))
    }

    func testNewConversationIdResetsTail() throws {
        try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: claudeId), &state), .model("claude-opus-5-5"))
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: "99999999-2222-4333-8444-555555555555"), &state), .none)
        XCTAssertNil(state.model)
    }

    func testPlaceholderOrMissingRefIsNone() {
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", nil, &state), .none)
        let placeholder = ConversationRef(kind: "claude-code", id: claudeId, placeholder: true, capturedVia: .wrapperClaim, state: .alive)
        XCTAssertEqual(detect("claude-code", placeholder, &state), .none)
    }

    // MARK: - Codex

    /// A UUIDv7 whose embedded timestamp is `date`.
    private func uuidV7(_ date: Date, tail: String = "7000-8000-000000000001") -> String {
        let ms = UInt64(date.timeIntervalSince1970 * 1000)
        let hex = String(format: "%012llx", ms)
        return "\(hex.prefix(8))-\(hex.suffix(4))-\(tail)"
    }

    private func codexPath(id: String, date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: ".codex/sessions/%04d/%02d/%02d/rollout-2026-01-01T00-00-00-%@.jsonl", c.year!, c.month!, c.day!, id)
    }

    func testCodexTakesLatestTurnContextModel() throws {
        let now = Date()
        let id = uuidV7(now)
        try place(fixture("codex-rollout.jsonl"), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        XCTAssertEqual(detect("codex", ref("codex", id: id), &state), .model("gpt-6-astra"))
    }

    func testCodexPicksUpModelChangeOnTheNextTurn() throws {
        let now = Date()
        let id = uuidV7(now)
        let url = try place(fixture("codex-rollout.jsonl"), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let r = ref("codex", id: id)
        _ = detect("codex", r, &state)
        try append(#"{"type":"turn_context","payload":{"model":"gpt-5.5-codex"}}"# + "\n", to: url)
        XCTAssertEqual(detect("codex", r, &state), .model("gpt-5.5-codex"))
    }

    // MARK: - Pi and omp

    func testPiTakesLatestModelChange() throws {
        let id = "019b0000-0000-7000-8000-000000000002"
        try place(fixture("pi-session.jsonl"),
                  at: ".pi/agent/sessions/\(PiScraper.sessionSlug(forCwd: "/work/demo"))/2026-01-01T00-00-00-000Z_\(id).jsonl")
        var state = ModelTailState()
        XCTAssertEqual(detect("pi", ref("pi", id: id), &state), .model("claude-opus-5-5"))
    }

    func testOmpFindsFileBySlugAndByExplicitPath() throws {
        let id = "019c0000-0000-7000-8000-000000000003"
        let slug = OmpScraper.sessionSlug(forCwd: "/work/demo", homeDirectory: home)
        let url = try place(fixture("omp-session.jsonl"), at: ".omp/agent/sessions/\(slug)/2026-01-01T00-00-00-000Z_\(id).jsonl")
        var bySlug = ModelTailState()
        XCTAssertEqual(detect("omp", ref("omp", id: id), &bySlug), .model("openrouter/~x-ai/grok-latest"))

        var byPath = ModelTailState()
        let r = ref("omp", id: id, cwd: nil, payload: [OmpStrategy.sessionFilePayloadKey: .string(url.path)])
        XCTAssertEqual(detect("omp", r, &byPath), .model("openrouter/~x-ai/grok-latest"))
    }

    // MARK: - Grok and opencode

    func testGrokReadsCurrentModelFromSummaryAndFollowsChanges() throws {
        let dir = "grok-session"
        let url = try place(fixture("grok-summary.json"), at: "\(dir)/summary.json")
        let r = ref("grok", id: "F0000000-0000-4000-8000-000000000004",
                    payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()
        XCTAssertEqual(detect("grok", r, &state), .model("grok-4.7"))
        XCTAssertEqual(state.signals.lastEventAt, AgentModelProbe.parseISO("2026-01-01T06:00:00.123Z"))
        let updated = String(data: try fixture("grok-summary.json"), encoding: .utf8)!.replacingOccurrences(of: "grok-4.7", with: "grok-5")
        try Data(updated.utf8).write(to: url)
        XCTAssertEqual(detect("grok", r, &state), .model("grok-5"))
    }

    func testOpencodeReadsSessionModelFromSqlite() throws {
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sid = "ses_f2a0e887affevLMZYvNBsbaFBj"
        let sql = """
            CREATE TABLE session (id text PRIMARY KEY, model text, time_updated integer, tokens_input integer, tokens_output integer, tokens_reasoning integer);
            INSERT INTO session VALUES ('\(sid)', '{"id":"k3","providerID":"kimi","variant":"default"}', 1790296534888, 100, 20, 5);
            INSERT INTO session VALUES ('ses_00000000000000000000000000', NULL, 0, 0, 0, 0);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        var state = ModelTailState()
        XCTAssertEqual(detect("opencode", ref("opencode", id: sid), &state), .model("k3"))
        XCTAssertEqual(state.signals.lastEventAt, Date(timeIntervalSince1970: 1_790_296_534.888))
        XCTAssertEqual(state.signals.sessionTokens, 125, "opencode's row holds session totals, not a turn")
        XCTAssertNil(state.signals.turnStartedAt)

        XCTAssertEqual(sqlite3_exec(db, "UPDATE session SET model = '{\"id\":\"gpt-5.5\"}' WHERE id = '\(sid)'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(detect("opencode", ref("opencode", id: sid), &state), .model("gpt-5.5"))
    }

    // MARK: - Harnesses with no model in their files

    func testKimiAndCopilotReportUnsupportedRatherThanGuessing() {
        var state = ModelTailState()
        XCTAssertEqual(detect("kimi", ref("kimi", id: "any"), &state),
                       .unsupported("kimi session files carry no model"))
        XCTAssertEqual(detect("github-copilot", nil, &state),
                       .unsupported("copilot session files carry no model c11 can read"))
    }

    // MARK: - Agent signals (active, turn, tools, tokens)

    private func t(_ hms: String) -> Date { AgentModelProbe.parseISO("2026-01-01T\(hms).000Z")! }

    func testClaudeSignalsForTheCurrentTurn() throws {
        try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        let s = state.signals
        XCTAssertEqual(s.lastEventAt, t("10:05:12"), "the tool result is the last thing the agent added")
        XCTAssertEqual(s.turnStartedAt, t("10:05:00"), "the second human prompt starts the turn")
        XCTAssertEqual(s.turnToolCalls, 1)
        XCTAssertEqual(s.turnTokens, 200 + 30 + 300 + 40, "fresh input + output; cache reads excluded")
    }

    func testClaudeMessageSplitAcrossLinesCountsOnce() throws {
        // Turn one of the fixture: message m2 is written on two lines with the same usage.
        let lines = try String(data: fixture("claude-session.jsonl"), encoding: .utf8)!
            .split(separator: "\n").prefix(8).joined(separator: "\n") + "\n"
        try place(Data(lines.utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        XCTAssertEqual(state.signals.turnStartedAt, t("10:00:00"))
        XCTAssertEqual(state.signals.turnTokens, (100 + 50 + 10) + (100 + 20), "m1 + m2 once")
        XCTAssertEqual(state.signals.turnToolCalls, 2, "sidechain tool calls are not the agent's own")
        XCTAssertEqual(state.signals.lastEventAt, t("10:00:15"), "sidechain and synthetic lines add nothing")
    }

    func testAppendedEventsMoveActiveAndANewPromptResetsTheTurn() throws {
        let url = try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)

        try append(#"{"type":"assistant","isSidechain":false,"timestamp":"2026-01-01T10:06:00.000Z","message":{"model":"claude-opus-5-5","id":"m9","content":[{"type":"tool_use","id":"a"}],"usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n", to: url)
        _ = detect("claude-code", r, &state)
        XCTAssertEqual(state.signals.lastEventAt, t("10:06:00"))
        XCTAssertEqual(state.signals.turnToolCalls, 2)
        XCTAssertEqual(state.signals.turnTokens, 570 + 15)

        try append(#"{"type":"user","isSidechain":false,"timestamp":"2026-01-01T10:07:00.000Z","message":{"role":"user","content":"next"}}"# + "\n", to: url)
        _ = detect("claude-code", r, &state)
        XCTAssertEqual(state.signals.turnStartedAt, t("10:07:00"))
        XCTAssertEqual(state.signals.turnToolCalls, 0)
        XCTAssertEqual(state.signals.turnTokens, 0)
        XCTAssertEqual(state.signals.lastEventAt, t("10:06:00"), "a human prompt is not the agent adding something")
    }

    func testCodexSignalsUseTaskStartedAndTokenCounts() throws {
        let now = Date()
        let id = uuidV7(now)
        try place(fixture("codex-rollout.jsonl"), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        _ = detect("codex", ref("codex", id: id), &state)
        let s = state.signals
        XCTAssertEqual(s.turnStartedAt, t("09:05:00"))
        XCTAssertEqual(s.turnToolCalls, 2)
        XCTAssertEqual(s.turnTokens, (1000 - 600) + 50)
        XCTAssertEqual(s.lastEventAt, t("09:05:07"))
    }

    func testPiAndOmpSignalsFollowMessageRoles() throws {
        let pid = "019b0000-0000-7000-8000-000000000002"
        try place(fixture("pi-session.jsonl"),
                  at: ".pi/agent/sessions/\(PiScraper.sessionSlug(forCwd: "/work/demo"))/2026-01-01T00-00-00-000Z_\(pid).jsonl")
        var pi = ModelTailState()
        _ = detect("pi", ref("pi", id: pid), &pi)
        XCTAssertEqual(pi.signals.turnStartedAt, t("08:10:05"))
        XCTAssertEqual(pi.signals.turnToolCalls, 1)
        XCTAssertEqual(pi.signals.turnTokens, 300 + 30 + 5)
        XCTAssertEqual(pi.signals.lastEventAt, t("08:10:09"))

        let oid = "019c0000-0000-7000-8000-000000000003"
        let slug = OmpScraper.sessionSlug(forCwd: "/work/demo", homeDirectory: home)
        try place(fixture("omp-session.jsonl"), at: ".omp/agent/sessions/\(slug)/2026-01-01T00-00-00-000Z_\(oid).jsonl")
        var omp = ModelTailState()
        _ = detect("omp", ref("omp", id: oid), &omp)
        XCTAssertEqual(omp.signals.turnStartedAt, t("07:00:05"))
        XCTAssertNil(omp.signals.lastEventAt, "only the operator has spoken so far")
    }

    func testTimestampParsingToleratesSixFractionalDigitsAndSpaces() {
        XCTAssertEqual(AgentModelProbe.parseISO("2026-01-01T06:00:00.123456Z"), AgentModelProbe.parseISO("2026-01-01T06:00:00.123Z"))
        XCTAssertNotNil(AgentModelProbe.timestamp(in: Data(#"{"a":1, "timestamp" : "2026-01-01T06:00:00Z"}"#.utf8)))
        XCTAssertNil(AgentModelProbe.timestamp(in: Data(#"{"a":1}"#.utf8)))
    }

    func testCodexRepeatedTokenCountLinesCountOnce() throws {
        // The fixture repeats every token_count line three times, as real rollouts do.
        let now = Date()
        let id = uuidV7(now)
        try place(fixture("codex-rollout.jsonl"), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        _ = detect("codex", ref("codex", id: id), &state)
        XCTAssertEqual(state.signals.turnTokens, (1000 - 600) + 50, "one call, not three")
    }

    func testPlaceholderRefDropsThePreviousSessionsState() throws {
        try place(fixture("claude-session.jsonl"), at: claudePath())
        var state = ModelTailState()
        XCTAssertEqual(detect("claude-code", ref("claude-code", id: claudeId), &state), .model("claude-opus-5-5"))
        XCTAssertNotNil(state.signals.lastEventAt)
        let placeholder = ConversationRef(kind: "claude-code", id: "fresh", placeholder: true, capturedVia: .wrapperClaim, state: .alive)
        XCTAssertEqual(detect("claude-code", placeholder, &state), .none)
        XCTAssertNil(state.model)
        XCTAssertEqual(state.signals, TranscriptSignals())
    }

    func testAVeryLongCodexTurnStillFindsItsModelByBackwardSearch() throws {
        let now = Date()
        let id = uuidV7(now)
        // turn_context at the top, then > 4 MiB of tool traffic with none.
        var data = Data(#"{"timestamp":"2026-01-01T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}"# .utf8) + Data([0x0A])
        let filler = Data((#"{"timestamp":"2026-01-01T09:00:01.000Z","type":"response_item","payload":{"type":"reasoning","x":""# + String(repeating: "x", count: 900) + #""}}"# + "\n").utf8)
        for _ in 0..<5_000 { data.append(filler) }
        try place(data, at: codexPath(id: id, date: now))
        var state = ModelTailState()
        XCTAssertEqual(detect("codex", ref("codex", id: id), &state), .model("gpt-6-astra"))
    }

    func testTimestampComesFromTheLinesOwnKeyNotANestedOne() {
        let line = Data((#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]},"toolUseResult":{"timestamp":"1999-01-01T00:00:00.000Z"},"timestamp":"2026-01-01T10:00:00.000Z"}"#).utf8)
        let parsed = AgentModelProbe.parseLine(kind: "claude-code", line: line)
        XCTAssertEqual(parsed.event, .toolResult(at: t("10:00:00")))
        // Oversize fallback (no JSON parse) takes the last key, which is the line's own.
        XCTAssertEqual(AgentModelProbe.timestamp(in: line, last: true), t("10:00:00"))
    }

    func testPiRoleComesFromTheParsedFieldNotASubstring() {
        // An assistant message whose tool arguments contain {"role":"user"}.
        let line = Data((#"{"type":"message","id":"a","timestamp":"2026-01-01T08:00:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"x","arguments":{"role":"user"}}],"usage":{"input":1,"output":2,"cacheWrite":0}}}"#).utf8)
        let parsed = AgentModelProbe.parseLine(kind: "pi", line: line)
        guard case .agent(let at, let tools, let tokens, _)? = parsed.event else { return XCTFail("not an agent event: \(String(describing: parsed.event))") }
        XCTAssertEqual(at, t("08:00:00"))
        XCTAssertEqual(tools, 1)
        XCTAssertEqual(tokens, 3)
    }

    // MARK: - Tiering across upgrade and restore

    func testSnapshotsFromBeforeTheTieringRestoreLaunchStampsAtTheLaunchTier() {
        var values: [String: Any] = ["model": "claude-opus-4-7", "model_label": "gpt-5.2", "task": "x"]
        var sources: [String: TabMetadataStore.SourceRecord] = [
            "model": .init(source: .declare, ts: 5),
            "model_label": .init(source: .declare, ts: 6),
            "task": .init(source: .declare, ts: 7),
        ]
        Workspace.migrateLaunchStampTiers(values: &values, sources: &sources)
        XCTAssertEqual(sources["model"]?.source, .heuristic)
        XCTAssertEqual(sources["model_label"]?.source, .heuristic)
        XCTAssertEqual(sources["model"]?.ts, 5, "the original time is kept")
        XCTAssertEqual(sources["task"]?.source, .declare, "only the launch model is re-tiered")
    }

    func testSnapshotsWrittenWithTheMarkerRestoreVerbatimAndDropTheMarker() {
        var values: [String: Any] = ["model": "claude-haiku-4-5", Workspace.modelTieringMarkerKey: "2"]
        var sources: [String: TabMetadataStore.SourceRecord] = ["model": .init(source: .declare, ts: 5)]
        Workspace.migrateLaunchStampTiers(values: &values, sources: &sources)
        XCTAssertEqual(sources["model"]?.source, .declare, "an agent's own set-agent --model stays declared")
        XCTAssertNil(values[Workspace.modelTieringMarkerKey])
    }

    // MARK: - Model precedence

    func testAgentDeclaredBeatsDetectedBeatsLaunchStamp() {
        typealias P = AgentModelPrecedence
        // Launch stamp only: shown.
        XCTAssertEqual(P.effective(model: "claude-opus-4-7", modelSource: .heuristic, modelLabel: nil, labelSource: nil, detected: nil).model, "claude-opus-4-7")
        // Detection outranks the launch stamp (a later /model wins).
        let detected = P.effective(model: "claude-opus-4-7", modelSource: .heuristic, modelLabel: "gpt-5.2", labelSource: .heuristic, detected: "claude-sonnet-4-6")
        XCTAssertEqual(detected.model, "claude-sonnet-4-6")
        XCTAssertNil(detected.label, "a launch model_label must not mask the detected model")
        // An agent's own set-agent --model wins over detection.
        let declared = P.effective(model: "claude-haiku-4-5", modelSource: .declare, modelLabel: nil, labelSource: nil, detected: "claude-sonnet-4-6")
        XCTAssertEqual(declared.model, "claude-haiku-4-5")
        // Explicit (operator) also wins.
        XCTAssertEqual(P.effective(model: "x", modelSource: .explicit, modelLabel: nil, labelSource: nil, detected: "y").model, "x")
    }

    func testChipUsesTheSamePrecedence() {
        let surface = UUID()
        let detected = AgentModelDetector.MetadataKeys.detected
        let chip = AgentChipResolver.resolve(
            focusedSurfaceId: surface,
            metadata: ["terminal_type": "claude-code", "model": "claude-opus-4-7", detected: "claude-sonnet-4-6"],
            sources: ["model": .heuristic]
        )
        XCTAssertEqual(chip?.displayLabel, "Sonnet 4.6")
    }

    // MARK: - Friendly names and display precedence

    func testFriendlyNames() {
        let cases: [(String, String)] = [
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-opus-4-7[1m]", "Opus 4.7"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-sonnet-4-6", "Sonnet 4.6"),
            ("claude-fable-5-1", "Fable 5.1"),
            ("claude-sonnet-4", "Sonnet 4"),
            ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
            ("gpt-5.5", "gpt-5.5"),
            ("gpt-6-astra", "gpt-6-astra"),
            ("openrouter/~x-ai/grok-latest", "grok-latest"),
            ("k3-256k", "k3-256k"),
            ("grok-4.7", "grok-4.7"),
        ]
        for (raw, friendly) in cases {
            XCTAssertEqual(AgentChipResolver.shortenModel(raw), friendly, raw)
        }
    }

    func testDetectedModelFillsInButNeverOverridesADeclaredOne() {
        let surface = UUID()
        let detected = AgentModelDetector.MetadataKeys.detected
        let fill = AgentChipResolver.resolve(
            focusedSurfaceId: surface,
            metadata: ["terminal_type": "claude-code", detected: "claude-opus-5-5"],
            sources: [:]
        )
        XCTAssertEqual(fill?.displayLabel, "Opus 5.5")
        XCTAssertEqual(fill?.detectedModel, "claude-opus-5-5")

        let declared = AgentChipResolver.resolve(
            focusedSurfaceId: surface,
            metadata: ["terminal_type": "claude-code", "model": "claude-sonnet-4-6", detected: "claude-opus-5-5"],
            sources: [:]
        )
        XCTAssertEqual(declared?.displayLabel, "Sonnet 4.6")
        XCTAssertEqual(declared?.detectedModel, "claude-opus-5-5", "raw detected id stays visible")

        let none = AgentChipResolver.resolve(focusedSurfaceId: surface, metadata: ["terminal_type": "claude-code"], sources: [:])
        XCTAssertNil(none?.displayLabel)
    }

    func testAgentLabelUsesDetectedModelWhenNothingDeclared() {
        XCTAssertEqual(
            TabSheetDetailBuilder.agentLabel(terminalKind: "codex", model: "gpt-5.5", modelLabel: nil),
            "Codex · gpt-5.5"
        )
    }
}
