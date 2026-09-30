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
            CREATE TABLE session (id text PRIMARY KEY, model text);
            INSERT INTO session VALUES ('\(sid)', '{"id":"k3","providerID":"kimi","variant":"default"}');
            INSERT INTO session VALUES ('ses_00000000000000000000000000', NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        var state = ModelTailState()
        XCTAssertEqual(detect("opencode", ref("opencode", id: sid), &state), .model("k3"))

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
