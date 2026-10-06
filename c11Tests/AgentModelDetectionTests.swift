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

    private func codexFixture(_ id: String) throws -> Data {
        let raw = try String(data: fixture("codex-rollout.jsonl"), encoding: .utf8)!
        return Data(raw.replacingOccurrences(of: "019a0000-0000-7000-8000-000000000001", with: id).utf8)
    }

    func testCodexTakesLatestTurnContextModel() throws {
        let now = Date()
        let id = uuidV7(now)
        try place(codexFixture(id), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        XCTAssertEqual(detect("codex", ref("codex", id: id), &state), .model("gpt-6-astra"))
    }

    func testCodexPicksUpModelChangeOnTheNextTurn() throws {
        let now = Date()
        let id = uuidV7(now)
        let url = try place(codexFixture(id), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let r = ref("codex", id: id)
        _ = detect("codex", r, &state)
        try append(#"{"type":"turn_context","payload":{"model":"gpt-5.5-codex"}}"# + "\n", to: url)
        XCTAssertEqual(detect("codex", r, &state), .model("gpt-5.5-codex"))
    }

    func testCodexLifecycleEdgesAreAdvisoryAndDoNotRepeatOnASecondPoll() throws {
        let now = Date()
        let id = uuidV7(now)
        let lines = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)","model_provider":"openai"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"root-1"}}
        {"timestamp":"2026-01-01T09:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"SENTINEL"}}
        {"timestamp":"2026-01-01T09:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"root-1","last_agent_message":"SENTINEL"}}
        """
        try place(Data((lines + "\n").utf8), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let first = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &state)
        XCTAssertEqual(first.lifecycle.map(\.nativeEvent), ["turn.started", "turn.completed"])
        XCTAssertEqual(first.lifecycle.map(\.turnID), ["root-1", "root-1"])
        XCTAssertEqual(first.lifecycle.map(\.isChild), [false, false])
        XCTAssertTrue(first.lifecycle.allSatisfy { $0.occurredAt != nil })
        XCTAssertTrue(first.lifecycle.allSatisfy { $0.kind != .questionRequested })
        let second = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &state)
        XCTAssertTrue(second.lifecycle.isEmpty, "the same byte range must not emit a second edge")
    }

    func testCodexLargeRolloutVerifiesSessionMetaOutsideTailWindow() throws {
        let now = Date()
        let id = uuidV7(now)
        let otherID = uuidV7(now.addingTimeInterval(-1))
        let path = codexPath(id: id, date: now)
        let header = #"{"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)"}}"# + "\n"
        let fillerLine = #"{"timestamp":"2026-01-01T09:00:00.500Z","type":"response_item","payload":{"type":"reasoning","text":"\#(String(repeating: "x", count: 900))"}}"# + "\n"
        let tail = """
        {"timestamp":"2026-01-01T09:05:00.000Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}
        {"timestamp":"2026-01-01T09:05:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"large-root"}}
        {"timestamp":"2026-01-01T09:05:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"large-root"}}
        """
        let content = header + String(repeating: fillerLine, count: 5_000) + tail + "\n"
        let url = try place(Data(content.utf8), at: path)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, AgentModelProbe.maxInitialWindow)

        var matchingState = ModelTailState()
        let matching = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &matchingState)
        XCTAssertEqual(matching.lifecycle.map(\.nativeEvent), ["turn.started", "turn.completed"])
        XCTAssertTrue(matchingState.transcriptIdentityVerified)
        guard case .gap = matching.coverage else { return XCTFail("expected the bounded tail to report its omitted prefix") }
        try append("""
        {"timestamp":"2026-01-01T09:06:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"fresh-root"}}
        {"timestamp":"2026-01-01T09:06:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"fresh-root"}}
        """ + "\n", to: url)
        let incremental = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &matchingState)
        XCTAssertEqual(incremental.lifecycle.map(\.turnID), ["fresh-root", "fresh-root"])

        let mismatchedHeader = header.replacingOccurrences(of: id, with: otherID)
        let mismatchedContent = content.replacingOccurrences(of: header, with: mismatchedHeader)
        try Data(mismatchedContent.utf8).write(to: url)
        var mismatchedState = ModelTailState()
        let mismatched = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &mismatchedState)
        XCTAssertTrue(mismatched.lifecycle.isEmpty)
        XCTAssertFalse(mismatchedState.transcriptIdentityVerified)
        XCTAssertTrue(mismatchedState.transcriptIdentityInvalid)
    }

    func testCodexChildEdgesAndOutputDoNotBecomeRootEdges() throws {
        let now = Date()
        let id = uuidV7(now)
        let lines = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"root-1"}}
        {"timestamp":"2026-01-01T09:00:02.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"child-1","root_turn_id":"root-1"}}
        {"timestamp":"2026-01-01T09:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"child-1"}}
        {"timestamp":"2026-01-01T09:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"SENTINEL"}}
        {"timestamp":"2026-01-01T09:00:05.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"root-1"}}
        """
        try place(Data((lines + "\n").utf8), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let result = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &state)
        XCTAssertEqual(result.lifecycle.map(\.nativeEvent), ["turn.started", "turn.interrupted"])
        XCTAssertEqual(result.lifecycle.map(\.turnID), ["root-1", "root-1"])
        XCTAssertFalse(result.lifecycle.contains { $0.turnID == "child-1" })
    }

    func testCodexQuietAndOutputOnlyRecordsDoNotClaimCompletionOrBlocked() throws {
        let now = Date()
        let id = uuidV7(now)
        let lines = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"SENTINEL"}}
        {"timestamp":"2026-01-01T09:00:02.000Z","type":"event_msg","payload":{"type":"phase_changed","phase":"working"}}
        """
        try place(Data((lines + "\n").utf8), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let result = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &state)
        XCTAssertTrue(result.lifecycle.isEmpty)
        XCTAssertNotEqual(result.lifecycle.map(\.kind), [.turnCompleted])
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

    func testGrokSummaryModelAndActivitySurviveEmptyAndNonemptyEventTails() throws {
        let sessionID = "F0000000-0000-4000-8000-000000000004"
        for (name, eventBytes) in [
            ("empty", Data()),
            ("nonempty", Data((#"{"type":"phase_changed","ts":"2026-01-01T05:59:00.000Z","phase":"working"}"# + "\n").utf8))
        ] {
            let dir = "grok-summary-\(name)"
            let summaryURL = try place(fixture("grok-summary.json"), at: "\(dir)/summary.json")
            try place(eventBytes, at: "\(dir)/events.jsonl")
            let r = ref("grok", id: sessionID,
                        payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(summaryURL.deletingLastPathComponent().path)])
            var state = ModelTailState()
            XCTAssertEqual(detect("grok", r, &state), .model("grok-4.7"), "events tail: \(name)")
            XCTAssertEqual(state.signals.lastEventAt, AgentModelProbe.parseISO("2026-01-01T06:00:00.123456Z"))
            XCTAssertEqual(detect("grok", r, &state), .model("grok-4.7"), "second poll: \(name)")
            XCTAssertEqual(state.signals.lastEventAt, AgentModelProbe.parseISO("2026-01-01T06:00:00.123456Z"))
        }
    }

    func testGrokQualifiedTurnPairEmitsOnceAndUsesTheNativeTurnNumber() throws {
        let sessionID = "grok-session-276"
        let dir = "grok-edge"
        let events = """
        {"type":"turn_started","ts":"2026-01-01T06:10:00.123456Z","turn_number":42,"session_id":"\(sessionID)","session_relationship":"primary"}
        {"type":"phase_changed","ts":"2026-01-01T06:10:01.000Z","phase":"working"}
        """
        let url = try place(Data((events + "\n").utf8), at: "\(dir)/events.jsonl")
        let r = ref("grok", id: sessionID,
                   payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()

        let first = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertEqual(first.lifecycle.map(\.nativeEvent), ["turn.started"])
        XCTAssertEqual(first.lifecycle.first?.turnID, "42")

        try append(#"{"type":"turn_ended","ts":"2026-01-01T06:10:02.123456Z","outcome":"completed"}"# + "\n", to: url)
        let second = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertEqual(second.lifecycle.map(\.nativeEvent), ["turn.completed"])
        XCTAssertEqual(second.lifecycle.first?.turnID, "42")
        XCTAssertTrue(probe.detectWithObservations(kind: "grok", ref: r, state: &state).lifecycle.isEmpty)
    }

    func testGrokRetainedStartAfterInitialGapCanPairWithIncrementalEnd() throws {
        let sessionID = "grok-session-276"
        let dir = "grok-retained-start-gap"
        let fillerLine = #"{"type":"phase_changed","ts":"2026-01-01T06:39:59.000Z","phase":"working","detail":"\#(String(repeating: "x", count: 900))"}"# + "\n"
        let start = #"{"type":"turn_started","ts":"2026-01-01T06:40:00.000Z","turn_number":11,"session_id":"grok-session-276","session_relationship":"primary"}"# + "\n"
        let url = try place(Data((String(repeating: fillerLine, count: 5_000) + start).utf8), at: "\(dir)/events.jsonl")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, AgentModelProbe.maxInitialWindow)
        let r = ref("grok", id: sessionID,
                    payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()

        let initial = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertEqual(initial.lifecycle.map(\.nativeEvent), ["turn.started"])
        XCTAssertEqual(initial.lifecycle.first?.turnID, "11")
        guard case .gap = initial.coverage else { return XCTFail("expected an initial omitted-prefix gap") }

        try append(#"{"type":"turn_ended","ts":"2026-01-01T06:40:01.000Z","outcome":"completed"}"# + "\n", to: url)
        let finished = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertEqual(finished.lifecycle.map(\.nativeEvent), ["turn.completed"])
        XCTAssertEqual(finished.lifecycle.first?.turnID, "11")
    }

    func testGrokMismatchedOrNonPrimaryStartCannotPairAnIdlessEnd() throws {
        let sessionID = "grok-session-276"
        let dir = "grok-unqualified"
        let events = """
        {"type":"turn_started","ts":"2026-01-01T06:20:00.000Z","turn_number":7,"session_id":"\(sessionID)","session_relationship":"child"}
        {"type":"turn_started","ts":"2026-01-01T06:20:01.000Z","turn_number":8,"session_id":"other-session","session_relationship":"primary"}
        {"type":"turn_ended","ts":"2026-01-01T06:20:02.000Z","outcome":"completed"}
        {"type":"phase_changed","ts":"2026-01-01T06:20:03.000Z","phase":"working"}
        """
        let url = try place(Data((events + "\n").utf8), at: "\(dir)/events.jsonl")
        let r = ref("grok", id: sessionID,
                   payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()
        let result = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertTrue(result.lifecycle.isEmpty)
        XCTAssertEqual(result.coverage, .none)
    }

    func testGrokPartialEndCompletesOnceThenReplacementCannotCompleteWithoutAStart() throws {
        let sessionID = "grok-session-276"
        let dir = "grok-partial"
        let start = #"{"type":"turn_started","ts":"2026-01-01T06:30:00.000Z","turn_number":9,"session_id":"grok-session-276","session_relationship":"primary"}"# + "\n"
        let end = #"{"type":"turn_ended","ts":"2026-01-01T06:30:01.000Z","outcome":"completed"}"#
        let url = try place(Data((start + String(end.prefix(24))).utf8), at: "\(dir)/events.jsonl")
        let r = ref("grok", id: sessionID,
                   payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()
        XCTAssertEqual(probe.detectWithObservations(kind: "grok", ref: r, state: &state).lifecycle.map(\.nativeEvent), ["turn.started"])

        try append(String(end.dropFirst(24)) + "\n", to: url)
        XCTAssertEqual(probe.detectWithObservations(kind: "grok", ref: r, state: &state).lifecycle.map(\.nativeEvent), ["turn.completed"])

        try Data((end + "\n").utf8).write(to: url)
        XCTAssertTrue(probe.detectWithObservations(kind: "grok", ref: r, state: &state).lifecycle.isEmpty)
    }

    func testCodexIncrementalBacklogGapDoesNotCompleteASkippedTurn() throws {
        let now = Date()
        let id = uuidV7(now)
        let path = codexPath(id: id, date: now)
        let prefix = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)","model_provider":"openai"}}
        {"timestamp":"2026-01-01T09:00:00.500Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"root-1"}}
        """
        let url = try place(Data((prefix + "\n").utf8), at: path)
        let r = ref("codex", id: id)
        var state = ModelTailState()
        XCTAssertEqual(probe.detectWithObservations(kind: "codex", ref: r, state: &state).lifecycle.map(\.nativeEvent), ["turn.started"])

        let fillerLine = "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"text\":\"" + String(repeating: "x", count: 900) + "\"}}\n"
        let filler = String(repeating: fillerLine, count: 5_000)
        try append(filler + #"{"timestamp":"2026-01-01T09:05:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"root-1"}}"# + "\n", to: url)
        let result = probe.detectWithObservations(kind: "codex", ref: r, state: &state)
        guard case .gap(let skipped) = result.coverage else { return XCTFail("expected a transcript coverage gap") }
        XCTAssertGreaterThan(skipped, 0)
        XCTAssertTrue(state.coverageDegraded)
        XCTAssertTrue(result.lifecycle.isEmpty, "the completion's matching start was in the skipped span")
    }

    func testCodexLifecycleRequiresAnExactSessionMetaIdentity() throws {
        let now = Date()
        let id = uuidV7(now)
        let lines = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"turn_context","payload":{"id":"\(id)","model":"gpt-6-astra"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"root-1"}}
        """
        try place(Data((lines + "\n").utf8), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let result = probe.detectWithObservations(kind: "codex", ref: ref("codex", id: id), state: &state)
        XCTAssertTrue(result.lifecycle.isEmpty)
        XCTAssertEqual(result.detection, .model("gpt-6-astra"))
    }

    func testTranscriptRescanUsesProductionAppendPathAndPreservesNotifyBarrier() throws {
        let now = Date()
        let sessionID = uuidV7(now)
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let target = AgentModelDetector.Target(workspaceId: workspaceID, surfaceId: tabID, kind: "codex")
        let conversation = ref("codex", id: sessionID)
        let text = """
        {"timestamp":"2026-01-01T09:00:00.000Z","type":"session_meta","payload":{"id":"\(sessionID)"}}
        {"timestamp":"2026-01-01T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-A"}}
        {"timestamp":"2026-01-01T09:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-A"}}
        {"timestamp":"2026-01-01T09:00:03.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-B"}}
        {"timestamp":"2026-01-01T09:00:04.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-B"}}
        """
        let url = try place(Data((text + "\n").utf8), at: codexPath(id: sessionID, date: now))
        var state = ModelTailState()
        let observed = probe.detectWithObservations(kind: "codex", ref: conversation, state: &state)
        XCTAssertEqual(observed.lifecycle.map(\.turnID), ["turn-A", "turn-A", "turn-B", "turn-B"])

        let journalDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("c11-transcript-fold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let store = try JournalStore(layout: JournalStorageLayout(directory: journalDirectory), clock: { nowMs })
        let coordinator = JournalCoordinator(store: store)
        coordinator.register(tabID: tabID, workspaceID: workspaceID)
        coordinator.setOwner(tabID: tabID, owner: JournalOwner(tabID: tabID, agentKind: "codex", sessionID: sessionID))
        defer { coordinator.remove(tabID: tabID) }
        let emittedAt = Date()
        func appendTranscript(_ observations: [TranscriptLifecycleObservation]) throws -> [JournalAppendResult] {
            try observations.map { observation in
                let draft = try XCTUnwrap(JournalTranscriptProducer.makeDraft(
                    observation: observation, target: target, ref: conversation, emittedAt: emittedAt
                ))
                return try coordinator.appendTranscript(draft)
            }
        }

        let gapDeadline = Date().addingTimeInterval(3)
        var observedCodexGap = false
        while Date() < gapDeadline {
            if try store.readPage(after: 0, limit: 20).contains(where: { $0.draft.nativeEvent == "adapter_gap" }) {
                observedCodexGap = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(observedCodexGap, "the normal owner path should persist Codex's notify-only adapter gap")

        let firstAppend = try appendTranscript(observed.lifecycle)
        XCTAssertEqual(firstAppend.map(\.receipt.projectionEffect), Array(repeating: .applied, count: 4))
        let prior = try XCTUnwrap(store.current(owner: JournalOwner(tabID: tabID, agentKind: "codex", sessionID: sessionID)))
        XCTAssertEqual(prior.phase, .idle)
        XCTAssertEqual(prior.turnID, "turn-B")
        XCTAssertEqual(prior.nativeWatermarks["codex_transcript:\(JournalNativeClockEvidence.codexTranscriptVersion)"],
                       Int64(t("09:00:04").timeIntervalSince1970 * 1000))

        var notify = JournalDraft(kind: .turnCompleted, emittedAtMs: nowMs, tabID: tabID,
                                  workspaceID: workspaceID, sessionID: sessionID, agentKind: "codex",
                                  source: .hook, adapter: .codexNotify, nativeEvent: "agent-turn-complete")
        notify.turnID = "turn-B"
        XCTAssertEqual(try coordinator.append(notify).receipt.projectionEffect, .duplicateEvidence)
        let barrier = try XCTUnwrap(store.current(owner: prior.owner))
        XCTAssertEqual(barrier.phase, .idle)
        XCTAssertEqual(barrier.turnOutcome, "completed")
        XCTAssertEqual(barrier.rank, JournalSource.hook.rank)
        XCTAssertEqual(barrier.terminalRank, JournalSource.hook.rank)
        XCTAssertEqual(barrier.adapter, .codexNotify)

        let replacement = url.appendingPathExtension("replacement")
        try Data((text + "\n").utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        let rescanned = probe.detectWithObservations(kind: "codex", ref: conversation, state: &state)
        XCTAssertEqual(rescanned.lifecycle.map(\.turnID), ["turn-A", "turn-A", "turn-B", "turn-B"])
        let rescanAppend = try appendTranscript(rescanned.lifecycle)
        XCTAssertEqual(rescanAppend.map(\.receipt.projectionEffect), [.stale, .stale, .stale, .duplicateEvidence])
        let afterRescan = try XCTUnwrap(store.current(owner: prior.owner))
        XCTAssertEqual(afterRescan.phase, .idle)
        XCTAssertEqual(afterRescan.turnOutcome, "completed")
        XCTAssertEqual(afterRescan.turnID, "turn-B")
        XCTAssertEqual(afterRescan.rank, JournalSource.hook.rank)
        XCTAssertEqual(afterRescan.terminalRank, JournalSource.hook.rank)
        XCTAssertEqual(afterRescan.lastSequence, 6)
    }

    func testTranscriptDraftKeepsOnlyAllowlistedProvenanceAndGapSignal() throws {
        let target = AgentModelDetector.Target(
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            surfaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: "codex"
        )
        let r = ref("codex", id: "codex-session-276")
        let observation = TranscriptLifecycleObservation(
            kind: .turnCompleted, occurredAt: t("09:05:07"), nativeEvent: "turn.completed",
            turnID: "root-1", isChild: false
        )
        let draft = try XCTUnwrap(JournalTranscriptProducer.makeDraft(
            observation: observation, target: target, ref: r, emittedAt: t("09:05:08")
        ))
        XCTAssertEqual(draft.source, .transcript)
        XCTAssertEqual(draft.adapter, .codexTranscript)
        XCTAssertEqual(draft.adapterVersion, JournalNativeClockEvidence.codexTranscriptVersion)
        XCTAssertEqual(draft.kind, .turnCompleted)
        XCTAssertEqual(draft.turnID, "root-1")
        XCTAssertTrue(JournalNativeClockEvidence.verifies(draft))
        var unsupportedClockVersion = draft
        unsupportedClockVersion.adapterVersion = "1"
        XCTAssertFalse(JournalNativeClockEvidence.verifies(unsupportedClockVersion))
        var mismatchedClockKind = draft
        mismatchedClockKind.kind = .turnStarted
        XCTAssertFalse(JournalNativeClockEvidence.verifies(mismatchedClockKind))
        XCTAssertFalse(String(decoding: try draft.canonicalData(), as: UTF8.self).contains("last_agent_message"))
        XCTAssertNil(JournalTranscriptProducer.makeDraft(
            observation: .init(kind: .questionRequested, occurredAt: nil,
                               nativeEvent: "question.requested", turnID: nil, isChild: false),
            target: target, ref: r, emittedAt: t("09:05:08")
        ))
        XCTAssertNil(JournalTranscriptProducer.makeDraft(
            observation: .init(kind: .turnStarted, occurredAt: nil,
                               nativeEvent: "turn.started", turnID: "root-2", isChild: false),
            target: target, ref: r, emittedAt: t("09:05:08")
        ), "a turn without native clock evidence cannot enter the fold")
        let grokTarget = AgentModelDetector.Target(
            workspaceId: target.workspaceId, surfaceId: target.surfaceId, kind: "grok"
        )
        let grokStart = try XCTUnwrap(JournalTranscriptProducer.makeDraft(
            observation: .init(kind: .turnStarted, occurredAt: t("09:05:07"),
                               nativeEvent: "turn.started", turnID: "42", isChild: false),
            target: grokTarget, ref: ref("grok", id: "grok-session-276"), emittedAt: t("09:05:08")
        ))
        XCTAssertEqual(grokStart.adapterVersion, JournalNativeClockEvidence.grokTranscriptVersion)
        XCTAssertTrue(JournalNativeClockEvidence.verifies(grokStart))
        XCTAssertNil(JournalTranscriptProducer.makeDraft(
            observation: .init(kind: .turnInterrupted, occurredAt: t("09:05:07"),
                               nativeEvent: "turn.interrupted", turnID: "7", isChild: false),
            target: grokTarget, ref: ref("grok", id: "grok-session-276"), emittedAt: t("09:05:08")
        ))

        let gap = try XCTUnwrap(JournalTranscriptProducer.makeGapDraft(target: target, ref: r, emittedAt: t("09:05:08")))
        XCTAssertEqual(gap.source, .c11)
        XCTAssertEqual(gap.signal, .adapterGap)
        XCTAssertNoThrow(try gap.validate())
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
        try place(codexFixture(id), at: codexPath(id: id, date: now))
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
        try place(codexFixture(id), at: codexPath(id: id, date: now))
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


    // MARK: - Prompt cache

    private func claudeUser(_ hms: String, toolResult: Bool = false) -> String {
        let content = toolResult ? #"[{"type":"tool_result","tool_use_id":"t","content":"ok"}]"# : #""go""#
        return #"{"type":"user","isSidechain":false,"timestamp":"2026-01-01T\#(hms).000Z","message":{"role":"user","content":\#(content)}}"#
    }

    private func claudeAssistant(
        _ id: String, _ hms: String, read: Int, written: Int,
        oneHour: Int = 0, fiveMinute: Int = 0, sidechain: Bool = false
    ) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"2026-01-01T\#(hms).000Z","message":{"model":"claude-opus-5-5","id":"\#(id)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(written),"output_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":\#(oneHour),"ephemeral_5m_input_tokens":\#(fiveMinute)}}}}"#
    }

    func testClaudePromptCacheAnchorsOnTheRequestAndCarriesItsTier() throws {
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:20", read: 0, written: 500, oneHour: 500),
            claudeUser("10:00:25", toolResult: true),
            claudeAssistant("m2", "10:00:40", read: 1000, written: 0),
            claudeAssistant("m2", "10:00:41", read: 1000, written: 0),
        ]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        let cache = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(cache.requestAt, t("10:00:25"), "the request went out after the tool result, not when its response was written")
        XCTAssertEqual(cache.basis, .ttl(PromptCachePolicy.anthropicExtendedTTL), "a pure read keeps the tier the session wrote")
        XCTAssertEqual(cache.promptTokens, 2 + 1000)
        XCTAssertEqual(cache.coldAt(estimateOverride: nil), t("11:00:25"))
    }

    func testClaudeFiveMinuteTierIgnoresSidechainsAndResetsAtCompaction() throws {
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 300, fiveMinute: 300),
            claudeAssistant("s1", "10:00:30", read: 0, written: 900, oneHour: 900, sidechain: true),
        ]
        let url = try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)
        XCTAssertEqual(state.signals.promptCache?.basis, .ttl(PromptCachePolicy.anthropicDefaultTTL))
        XCTAssertEqual(state.signals.promptCache?.requestAt, t("10:00:00"), "a subagent's request does not touch the main cache")

        // What a real /compact writes: the boundary, the summary (timestamped before
        // the boundary), the caveat, and the command echo replayed with its old time.
        let compaction = [
            #"{"type":"system","subtype":"compact_boundary","isSidechain":false,"timestamp":"2026-01-01T10:01:00.000Z","compactMetadata":{"trigger":"manual","preTokens":900000,"postTokens":18858}}"#,
            #"{"type":"user","isSidechain":false,"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"2026-01-01T10:00:59.000Z","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}"#,
            #"{"type":"user","isSidechain":false,"isMeta":true,"timestamp":"2026-01-01T10:00:40.000Z","message":{"role":"user","content":"<local-command-caveat>Caveat: generated by local commands.</local-command-caveat>"}}"#,
            claudeLocal("10:00:40", "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"),
            claudeLocal("10:01:01", "<local-command-stdout>Compacted (ctrl+o to see full summary)</local-command-stdout>"),
        ]
        try append(compaction.joined(separator: "\n") + "\n", to: url)
        _ = detect("claude-code", r, &state)
        let compacted = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(compacted.reset, .compaction, "compaction replaces the cached prefix")
        XCTAssertEqual(compacted.coldAt(estimateOverride: nil), t("10:01:00"), "cold at once")
        XCTAssertEqual(compacted.promptTokens, 18_858, "the next message re-caches the compacted context")

        try append(claudeUser("10:01:20") + "\n" + claudeAssistant("m2", "10:01:30", read: 0, written: 400, fiveMinute: 400) + "\n", to: url)
        _ = detect("claude-code", r, &state)
        XCTAssertEqual(state.signals.promptCache?.requestAt, t("10:01:20"))
        XCTAssertNil(state.signals.promptCache?.reset)
    }

    func testClaudeWithoutCacheUseSaysNothingAboutTheCache() throws {
        let lines = [claudeUser("10:00:00"), claudeAssistant("m1", "10:00:10", read: 0, written: 0)]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        XCTAssertNil(state.signals.promptCache)
    }

    func testCodexPromptCacheIsAnEstimateFromTheLastTokenCount() throws {
        let now = Date()
        let id = uuidV7(now)
        try place(codexFixture(id), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        _ = detect("codex", ref("codex", id: id), &state)
        let cache = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(cache.requestAt, t("09:05:07"))
        XCTAssertEqual(cache.basis, .estimate(PromptCachePolicy.codexColdAfter))
        XCTAssertTrue(cache.isEstimate)
        XCTAssertEqual(cache.promptTokens, 1000, "OpenAI input tokens include the cached part")
    }

    func testGrokPromptCacheFollowsTheEndOfAVerifiedTurn() throws {
        let sessionID = "grok-session-cache"
        let lonelyEnd = #"{"type":"turn_ended","ts":"2026-01-01T06:09:00.000Z","outcome":"completed"}"#
        let url = try place(Data((lonelyEnd + "\n").utf8), at: "grok-cache/events.jsonl")
        let r = ref("grok", id: sessionID,
                   payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()
        _ = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertNil(state.signals.promptCache, "an end with no verified start is not this session's turn")

        try append(#"{"type":"turn_started","ts":"2026-01-01T06:10:00.000Z","turn_number":7,"session_id":"\#(sessionID)","session_relationship":"primary"}"# + "\n", to: url)
        try append(#"{"type":"turn_ended","ts":"2026-01-01T06:12:00.000Z","outcome":"cancelled"}"# + "\n", to: url)
        _ = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        let cache = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(cache.requestAt, AgentModelProbe.parseISO("2026-01-01T06:12:00.000Z"))
        XCTAssertEqual(cache.basis, .estimate(PromptCachePolicy.grokColdAfter))
    }

    @MainActor
    func testPromptCacheFieldDescribesTheCacheOrIsNull() throws {
        XCTAssertTrue(TerminalController.promptCacheField(nil, now: Date()) is NSNull)
        let requested = Date(timeIntervalSince1970: 1_000_000)
        let cache = PromptCacheObservation(requestAt: requested, basis: .ttl(3600), promptTokens: 182_000)
        let warm = try XCTUnwrap(TerminalController.promptCacheField(cache, now: requested.addingTimeInterval(60)) as? [String: Any])
        XCTAssertEqual(warm["state"] as? String, "warm")
        XCTAssertEqual(warm["basis"] as? String, "ttl")
        XCTAssertEqual(warm["lifetime_seconds"] as? Int, 3600)
        XCTAssertEqual(warm["prompt_tokens"] as? Int, 182_000)
        XCTAssertEqual(warm["cold_at"] as? String, ISO8601DateFormatter().string(from: requested.addingTimeInterval(3600)))
        let cold = try XCTUnwrap(TerminalController.promptCacheField(cache, now: requested.addingTimeInterval(3600)) as? [String: Any])
        XCTAssertEqual(cold["state"] as? String, "cold")
    }


    func testANewPromptMovesTheCacheAnchorEvenWithoutAResponse() throws {
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 500, oneHour: 500),
            claudeUser("10:30:00"),
        ]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        XCTAssertEqual(
            state.signals.promptCache?.requestAt, t("10:30:00"),
            "an interrupted request still read the cache when the prompt went out"
        )
        XCTAssertEqual(state.signals.promptCache?.basis, .ttl(PromptCachePolicy.anthropicExtendedTTL))
    }

    func testARequestWritingBothTiersCountsAsFiveMinutes() throws {
        let lines = [claudeUser("10:00:00"), claudeAssistant("m1", "10:00:10", read: 0, written: 900, oneHour: 100, fiveMinute: 800)]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        XCTAssertEqual(state.signals.promptCache?.basis, .ttl(PromptCachePolicy.anthropicDefaultTTL), "the 5-minute part is the conversation's tail")
    }

    func testCodexTokenCountWithoutUsageIsNotARequest() throws {
        let now = Date()
        let id = uuidV7(now)
        let url = try place(codexFixture(id), at: codexPath(id: id, date: now))
        var state = ModelTailState()
        let r = ref("codex", id: id)
        _ = detect("codex", r, &state)
        try append(#"{"timestamp":"2026-01-01T09:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"# + "\n", to: url)
        _ = detect("codex", r, &state)
        XCTAssertEqual(state.signals.promptCache?.requestAt, t("09:05:07"))
    }

    func testGrokTurnStartCountsEvenWhenItsEndCannotPair() throws {
        let sessionID = "grok-session-start"
        let events = """
        {"type":"turn_started","ts":"2026-01-01T06:20:00.000Z","turn_number":3,"session_id":"\(sessionID)","session_relationship":"primary"}
        {"type":"turn_started","ts":"2026-01-01T06:21:00.000Z","turn_number":1,"session_id":"child","session_relationship":"subagent"}
        {"type":"turn_ended","ts":"2026-01-01T06:25:00.000Z","outcome":"completed"}
        """
        let url = try place(Data((events + "\n").utf8), at: "grok-start/events.jsonl")
        let r = ref("grok", id: sessionID,
                   payload: [GrokStrategy.sessionDirectoryPayloadKey: .string(url.deletingLastPathComponent().path)])
        var state = ModelTailState()
        _ = probe.detectWithObservations(kind: "grok", ref: r, state: &state)
        XCTAssertEqual(state.signals.promptCache?.requestAt, AgentModelProbe.parseISO("2026-01-01T06:20:00.000Z"))
    }

    private func claudeLocal(_ hms: String, _ content: String) -> String {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"user","isSidechain":false,"timestamp":"2026-01-01T\#(hms).000Z","message":{"role":"user","content":"\#(escaped)"}}"#
    }

    func testSlashCommandsAndShellLinesSendNoRequestAndDoNotRewarmTheCache() throws {
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 500, oneHour: 500),
            claudeLocal("10:30:00", "<command-name>/context</command-name>\n<command-message>context</command-message>\n<command-args></command-args>"),
            claudeLocal("10:30:01", "<local-command-stdout>Context usage: 12%</local-command-stdout>"),
            claudeLocal("10:31:00", "<bash-input>ls</bash-input>"),
            claudeLocal("10:31:01", "<bash-stdout>README.md</bash-stdout><bash-stderr></bash-stderr>"),
            claudeLocal("10:32:00", "<local-command-stderr>Unknown command</local-command-stderr>"),
        ]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        let cache = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(cache.requestAt, t("10:00:00"), "/context, its output and ! shell lines send no request")
        XCTAssertNil(cache.reset)
    }

    func testModelSwitchResetsTheCacheUntilTheNextPrompt() throws {
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 500, oneHour: 500),
            claudeLocal("10:20:00", "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"),
            claudeLocal("10:20:01", "<local-command-stdout>Set model to `Sonnet 5.5` and saved as your default for new sessions</local-command-stdout>"),
        ]
        let url = try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)
        let switched = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(switched.reset, .modelSwitch)
        XCTAssertEqual(switched.coldAt(estimateOverride: nil), t("10:20:01"), "the cache belongs to the old model: cold at once")
        XCTAssertEqual(switched.promptTokens, 2 + 500, "the next message re-caches the whole context")

        try append(claudeUser("10:25:00") + "\n", to: url)
        _ = detect("claude-code", r, &state)
        let prompted = try XCTUnwrap(state.signals.promptCache)
        XCTAssertNil(prompted.reset, "the next prompt's request writes a fresh cache")
        XCTAssertEqual(prompted.requestAt, t("10:25:00"))
        XCTAssertEqual(prompted.basis, .ttl(PromptCachePolicy.anthropicExtendedTTL))
    }

    @MainActor
    func testPromptCacheFieldNamesAReset() throws {
        let at = Date(timeIntervalSince1970: 2_000_000)
        let cache = PromptCacheObservation(
            requestAt: at.addingTimeInterval(-60), basis: .ttl(3_600), promptTokens: 10,
            reset: .modelSwitch, resetAt: at
        )
        let field = try XCTUnwrap(TerminalController.promptCacheField(cache, now: at.addingTimeInterval(1)) as? [String: Any])
        XCTAssertEqual(field["state"] as? String, "cold")
        XCTAssertEqual(field["reset"] as? String, "model_switch")
        XCTAssertEqual(field["lifetime_seconds"] as? Int, 3_600)
    }

    func testEffortChangeResetsAndAResetNeedsAPriorRequest() throws {
        let lines = [
            claudeLocal("09:59:00", "<local-command-stdout>Set model to `Opus 5.5` and saved as your default for new sessions</local-command-stdout>"),
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 500, oneHour: 500),
            claudeLocal("10:20:00", "<local-command-stdout>Set effort level to max (this session only)</local-command-stdout>"),
        ]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        let r = ref("claude-code", id: claudeId)
        _ = detect("claude-code", r, &state)
        let cache = try XCTUnwrap(state.signals.promptCache)
        XCTAssertEqual(cache.reset, .effortChange)
        XCTAssertEqual(cache.coldAt(estimateOverride: nil), t("10:20:00"))
        XCTAssertEqual(cache.requestAt, t("10:00:00"), "a /model before any request had no cache to reset")

        try place(Data((lines.prefix(1).joined(separator: "\n") + "\n").utf8), at: claudePath())
        var fresh = ModelTailState()
        _ = detect("claude-code", r, &fresh)
        XCTAssertNil(fresh.signals.promptCache, "a /model before any request leaves the cache unknown, not cold")
    }

    func testAnOversizeShellOutputSendsNoRequest() throws {
        let huge = String(repeating: "x", count: 1_100_000)
        let lines = [
            claudeUser("10:00:00"),
            claudeAssistant("m1", "10:00:10", read: 0, written: 500, oneHour: 500),
            claudeLocal("10:30:00", "<bash-stdout>\(huge)</bash-stdout><bash-stderr></bash-stderr>"),
        ]
        try place(Data((lines.joined(separator: "\n") + "\n").utf8), at: claudePath())
        var state = ModelTailState()
        _ = detect("claude-code", ref("claude-code", id: claudeId), &state)
        XCTAssertEqual(state.signals.promptCache?.requestAt, t("10:00:00"))
    }
}
