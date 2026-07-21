// AgentLaunchStatsTests.swift
//
// Pure-logic tests for the C11-178 launch-stats rail. No Workspace/TabManager
// construction (bare-runner NSApp-nil crash) — everything runs against an
// injected temp directory and a pinned clock.

import XCTest
@testable import c11

final class AgentLaunchStatsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-launch-stats-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: helpers

    /// Fixed-UTC calendar so `.today` boundaries are deterministic regardless of
    /// the host machine's timezone.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore(now: Date) -> AgentLaunchStatsStore {
        AgentLaunchStatsStore(directory: tempDir, clock: { now }, calendar: utcCalendar)
    }

    private func iso(_ s: String) -> Date {
        guard let d = AgentLaunchStatsDate.date(from: s) else {
            fatalError("bad test date \(s)")
        }
        return d
    }

    private func jsonlLines() -> [String] {
        let url = tempDir.appendingPathComponent(AgentLaunchStatsStore.jsonlName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Provider derivation (§1.2)

    func testProviderFixedHarnesses() {
        XCTAssertEqual(AgentLaunchStats.provider(harness: "claude-code", model: "opus"), "anthropic")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "codex", model: "gpt-5.2"), "openai")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "grok", model: nil), "xai")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "kimi", model: "k2"), "moonshot")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "github-copilot", model: nil), "github")
    }

    func testProviderFixedHarnessIgnoresModel() {
        // Provider is the harness constant even with an empty/nil model.
        XCTAssertEqual(AgentLaunchStats.provider(harness: "claude-code", model: ""), "anthropic")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "claude-code", model: "  "), "anthropic")
    }

    func testProviderRouterPrefixParse() {
        XCTAssertEqual(AgentLaunchStats.provider(harness: "omp", model: "deepseek/deepseek-chat-v3.1"), "deepseek")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "pi", model: "anthropic/claude"), "anthropic")
        XCTAssertEqual(AgentLaunchStats.provider(harness: "opencode", model: "openai/gpt-5.2"), "openai")
    }

    func testProviderRouterNoSlashOrEmptyIsNil() {
        XCTAssertNil(AgentLaunchStats.provider(harness: "omp", model: "deepseek-chat"))  // no slash
        XCTAssertNil(AgentLaunchStats.provider(harness: "pi", model: nil))
        XCTAssertNil(AgentLaunchStats.provider(harness: "opencode", model: "/leading-slash")) // empty prefix
    }

    func testProviderCustomUnknownIsNil() {
        XCTAssertNil(AgentLaunchStats.provider(harness: "custom", model: "whatever"))
        XCTAssertNil(AgentLaunchStats.provider(harness: "totally-unknown", model: "x"))
    }

    // MARK: - Codec round-trips

    func testLaunchRecordSnakeCaseAndOptionalOmission() throws {
        let record = LaunchRecord(
            ts: iso("2026-07-20T21:14:00.000Z"),
            harness: "claude-code", model: "opus", effort: "high",
            provider: "anthropic", configId: nil, systemPromptMode: nil, source: "a-button"
        )
        let data = try AgentLaunchStatsDate.makeEncoder().encode(record)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"system_prompt_mode\"") == false, "nil mode should be omitted")
        XCTAssertTrue(json.contains("\"config_id\"") == false, "nil config_id should be omitted")
        XCTAssertTrue(json.contains("\"source\":\"a-button\""))
        let back = try AgentLaunchStatsDate.makeDecoder().decode(LaunchRecord.self, from: data)
        XCTAssertEqual(back, record)
    }

    func testAggregateRoundTripWithTotalsEnvelope() throws {
        var agg = AgentLaunchStatsAggregate.empty
        agg.totals.byModel = ["opus": 3]
        agg.totals.byHarness = ["claude-code": 3]
        agg.totals.byProvider = ["anthropic": 3]
        agg.count = 3
        agg.since = iso("2026-07-01T00:00:00.000Z")
        agg.lastTs = iso("2026-07-20T21:14:00.000Z")
        let data = try AgentLaunchStatsDate.makeEncoder().encode(agg)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"totals\""), "tallies must nest under totals (design §2.4)")
        XCTAssertTrue(json.contains("\"by_model\""))
        XCTAssertTrue(json.contains("\"schema_version\":1"))
        let back = try AgentLaunchStatsDate.makeDecoder().decode(AgentLaunchStatsAggregate.self, from: data)
        XCTAssertEqual(back, agg)
    }

    // MARK: - Append + aggregate consistency

    func testAppendAndAggregateConsistency() {
        let now = iso("2026-07-20T21:14:00.000Z")
        let store = makeStore(now: now)
        store.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus", effort: "high"), source: .aButton)
        store.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus", effort: "high"), source: .blueprint)
        store.recordLaunch(ResolvedLaunch(harness: "codex", model: "gpt-5.2", effort: "high"), source: .launchAgent)
        store.recordLaunch(ResolvedLaunch(harness: "omp", model: "deepseek/deepseek-chat-v3.1"), source: .socket)
        store.flush()

        XCTAssertEqual(jsonlLines().count, 4, "one jsonl line per launch")

        let agg = store.aggregate()
        XCTAssertEqual(agg.count, 4)
        XCTAssertEqual(agg.totals.byModel["opus"], 2)
        XCTAssertEqual(agg.totals.byModel["gpt-5.2"], 1)
        XCTAssertEqual(agg.totals.byModel["deepseek/deepseek-chat-v3.1"], 1)
        XCTAssertEqual(agg.totals.byHarness["claude-code"], 2)
        XCTAssertEqual(agg.totals.byHarness["codex"], 1)
        XCTAssertEqual(agg.totals.byHarness["omp"], 1)
        XCTAssertEqual(agg.totals.byProvider["anthropic"], 2)
        XCTAssertEqual(agg.totals.byProvider["openai"], 1)
        XCTAssertEqual(agg.totals.byProvider["deepseek"], 1)  // router prefix parsed
        // by_model sums equal count
        XCTAssertEqual(agg.totals.byModel.values.reduce(0, +), 4)
        XCTAssertEqual(agg.lastTs, now)
        XCTAssertEqual(agg.since, now)
    }

    func testNilAxesDoNotProduceBlankKeys() {
        let store = makeStore(now: iso("2026-07-20T21:14:00.000Z"))
        // custom harness → nil provider; empty model/effort → normalized to nil.
        store.recordLaunch(ResolvedLaunch(harness: "custom", model: "", effort: "  "), source: .aButton)
        store.flush()
        let agg = store.aggregate()
        XCTAssertEqual(agg.count, 1)
        XCTAssertNil(agg.totals.byModel[""])
        XCTAssertNil(agg.totals.byProvider[""])
        XCTAssertTrue(agg.totals.byModel.isEmpty)
        XCTAssertTrue(agg.totals.byProvider.isEmpty)
        XCTAssertEqual(agg.totals.byHarness["custom"], 1)
    }

    // MARK: - Windowing

    func testWindowingMath() {
        // now = mid-day 2026-07-20 (UTC calendar → deterministic day boundary)
        let now = iso("2026-07-20T12:00:00.000Z")
        let store = AgentLaunchStatsStore(directory: tempDir, clock: { now }, calendar: utcCalendar)
        // Writers use a moving clock closure to stamp records at controlled times.
        var t = iso("2026-07-20T09:00:00.000Z")  // today
        let s1 = AgentLaunchStatsStore(directory: tempDir, clock: { t })
        s1.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus"), source: .aButton)  // today
        t = iso("2026-07-10T09:00:00.000Z")  // within 30d, not today
        s1.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "sonnet"), source: .aButton)
        t = iso("2026-05-01T09:00:00.000Z")  // >30d
        s1.recordLaunch(ResolvedLaunch(harness: "codex", model: "gpt-5.2"), source: .launchAgent)
        s1.flush()

        let all = store.stats(window: .all, by: .model, now: now)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.tally["opus"], 1)
        XCTAssertEqual(all.tally["sonnet"], 1)
        XCTAssertEqual(all.tally["gpt-5.2"], 1)

        let today = store.stats(window: .today, by: .model, now: now)
        XCTAssertEqual(today.count, 1)
        XCTAssertEqual(today.tally["opus"], 1)
        XCTAssertNil(today.tally["sonnet"])

        let d30 = store.stats(window: .days(30), by: .model, now: now)
        XCTAssertEqual(d30.count, 2, "opus (today) + sonnet (10 days ago), not the May record")
        XCTAssertEqual(d30.tally["opus"], 1)
        XCTAssertEqual(d30.tally["sonnet"], 1)
        XCTAssertNil(d30.tally["gpt-5.2"])
    }

    func testAllWindowMatchesAggregateWithoutScan() {
        let now = iso("2026-07-20T12:00:00.000Z")
        let store = AgentLaunchStatsStore(directory: tempDir, clock: { now })
        for _ in 0..<5 {
            store.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus"), source: .aButton)
        }
        store.flush()
        let all = store.stats(window: .all, by: .harness, now: now)
        XCTAssertEqual(all.count, store.aggregate().count)
        XCTAssertEqual(all.tally, store.aggregate().totals.byHarness)
    }

    // MARK: - Source-rank tiebreak (§4.4)

    private func obs(_ ts: String, source: RecentObservationSource, model: String) -> RecentObservation {
        RecentObservation(
            configId: nil, harness: "claude-code", model: model, effort: nil,
            provider: "anthropic", systemPromptMode: nil,
            observedAt: iso(ts), source: source.rawValue, fieldSources: nil
        )
    }

    func testShouldReplaceRules() {
        let launchFresh = obs("2026-07-20T21:14:00.000Z", source: .launch, model: "opus")

        // nil stored → always replace
        XCTAssertTrue(AgentLaunchStatsStore.shouldReplace(stored: nil, incoming: launchFresh))

        // stale scrape (older ts) never clobbers a newer launch
        let staleScrape = obs("2026-07-20T21:00:00.000Z", source: .scrape, model: "sonnet")
        XCTAssertFalse(AgentLaunchStatsStore.shouldReplace(stored: launchFresh, incoming: staleScrape))

        // newer ts wins regardless of source
        let newerScrape = obs("2026-07-20T21:20:00.000Z", source: .scrape, model: "sonnet")
        XCTAssertTrue(AgentLaunchStatsStore.shouldReplace(stored: launchFresh, incoming: newerScrape))

        // genuine ts tie → higher rank wins
        let tieScrape = obs("2026-07-20T21:14:00.000Z", source: .scrape, model: "sonnet")
        XCTAssertFalse(AgentLaunchStatsStore.shouldReplace(stored: launchFresh, incoming: tieScrape),
                       "scrape must not clobber launch at equal ts (lower rank)")
        let tieHook = obs("2026-07-20T21:14:00.000Z", source: .sessionHook, model: "sonnet")
        XCTAssertFalse(AgentLaunchStatsStore.shouldReplace(stored: launchFresh, incoming: tieHook),
                       "sessionHook (rank 2) must not clobber launch (rank 3) at equal ts")
        let tieLaunch = obs("2026-07-20T21:14:00.000Z", source: .launch, model: "sonnet")
        XCTAssertTrue(AgentLaunchStatsStore.shouldReplace(stored: launchFresh, incoming: tieLaunch),
                      "equal rank at equal ts replaces (>=)")
    }

    func testUpdateRecentPersistsAndRanks() {
        let store = AgentLaunchStatsStore(directory: tempDir, clock: { self.iso("2026-07-20T21:14:00.000Z") })
        XCTAssertTrue(store.updateRecent(obs("2026-07-20T21:14:00.000Z", source: .launch, model: "opus")))
        XCTAssertEqual(store.recent()?.model, "opus")
        // stale scrape rejected, recent unchanged
        XCTAssertFalse(store.updateRecent(obs("2026-07-20T21:00:00.000Z", source: .scrape, model: "sonnet")))
        XCTAssertEqual(store.recent()?.model, "opus")
        // newer launch accepted
        XCTAssertTrue(store.updateRecent(obs("2026-07-20T22:00:00.000Z", source: .launch, model: "haiku")))
        XCTAssertEqual(store.recent()?.model, "haiku")
    }

    func testRecordLaunchUpdatesRecentAsLaunchSource() {
        let now = iso("2026-07-20T21:14:00.000Z")
        let store = makeStore(now: now)
        store.recordLaunch(ResolvedLaunch(harness: "codex", model: "gpt-5.2", effort: "high", configId: "cfg-1"), source: .launchAgent)
        store.flush()
        let recent = store.recent()
        XCTAssertEqual(recent?.model, "gpt-5.2")
        XCTAssertEqual(recent?.provider, "openai")
        XCTAssertEqual(recent?.source, RecentObservationSource.launch.rawValue)
        XCTAssertEqual(recent?.configId, "cfg-1")
        XCTAssertEqual(recent?.observedAt, now)
    }

    // MARK: - Rebuild / drift

    func testRebuildAggregateMatchesLiveAfterNLaunches() {
        var t = iso("2026-07-20T09:00:00.000Z")
        let store = AgentLaunchStatsStore(directory: tempDir, clock: { t })
        let models = ["opus", "opus", "sonnet", "gpt-5.2"]
        let harnesses = ["claude-code", "claude-code", "claude-code", "codex"]
        for i in 0..<models.count {
            t = iso(String(format: "2026-07-20T09:%02d:00.000Z", i))
            store.recordLaunch(ResolvedLaunch(harness: harnesses[i], model: models[i]), source: .aButton)
        }
        store.flush()
        let live = store.aggregate()
        let rebuilt = store.rebuildAggregate()
        XCTAssertEqual(rebuilt.count, live.count)
        XCTAssertEqual(rebuilt.totals, live.totals)
        XCTAssertEqual(rebuilt.lastTs, live.lastTs)
        XCTAssertEqual(rebuilt.since, live.since)
    }

    func testRebuildPreservesRecent() {
        let now = iso("2026-07-20T21:14:00.000Z")
        let store = makeStore(now: now)
        store.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus"), source: .aButton)
        store.flush()
        let recentBefore = store.recent()
        let rebuilt = store.rebuildAggregate()
        XCTAssertEqual(rebuilt.recent, recentBefore)
    }

    // MARK: - Fresh install

    func testFreshInstallEmptyAndNoThrow() {
        let store = AgentLaunchStatsStore(directory: tempDir, clock: { self.iso("2026-07-20T12:00:00.000Z") })
        let agg = store.aggregate()
        XCTAssertEqual(agg.count, 0)
        XCTAssertTrue(agg.totals.byModel.isEmpty)
        XCTAssertNil(store.recent())
        let all = store.stats(window: .all, by: .model)
        XCTAssertEqual(all.count, 0)
        let today = store.stats(window: .today, by: .model)
        XCTAssertEqual(today.count, 0)
    }

    // MARK: - No prompt/command text ever

    func testRecordNeverContainsPromptOrCommandText() {
        let now = iso("2026-07-20T21:14:00.000Z")
        let store = makeStore(now: now)
        // ResolvedLaunch has no field for prompt/command — this test guards the
        // jsonl surface stays limited to resolved axes.
        store.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus", effort: "high", configId: "cfg"), source: .aButton)
        store.flush()
        let line = jsonlLines().first ?? ""
        let allowedKeys = Set(["ts", "harness", "model", "effort", "provider", "config_id", "system_prompt_mode", "source"])
        let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let keys = Set((obj ?? [:]).keys)
        XCTAssertTrue(keys.isSubset(of: allowedKeys), "jsonl keys \(keys) must be within \(allowedKeys)")
    }
}
