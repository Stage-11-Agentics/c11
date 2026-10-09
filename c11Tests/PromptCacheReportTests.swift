import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// `agent.prompt_cache.report`: what the socket accepts, how reports fold into
/// a panel's slot, and which source describes the panel when c11 also reads a
/// transcript.
final class PromptCacheReportTests: XCTestCase {
    private let panel = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    private func parse(_ params: [String: Any]) -> Result<(panelId: UUID, report: PromptCacheReport), PromptCacheReportParser.Failure> {
        PromptCacheReportParser.parse(params, now: now)
    }

    private func failure(_ params: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .failure(let failure) = parse(params) else {
            XCTFail("expected a validation failure", file: file, line: line)
            return nil
        }
        return failure.message
    }

    private func request(
        _ at: Date, provider: String? = "anthropic", model: String? = "claude-sonnet-4-5",
        input: Int? = 100, read: Int? = 0, write: Int? = 0, ttl: TimeInterval? = nil
    ) -> PromptCacheReport {
        .request(.init(at: at, provider: provider, model: model, inputTokens: input,
                       cacheReadTokens: read, cacheWriteTokens: write, ttl: ttl))
    }

    // MARK: - Validation

    func testARequestReportParsesWithItsPanelAndEveryField() throws {
        let at = now.addingTimeInterval(-30)
        let result = try parse([
            "panel_id": panel.uuidString,
            "request": [
                "at_ms": ms(at), "provider": " anthropic ", "model": "claude-opus-4-8",
                "input_tokens": 1_200, "cache_read_tokens": 180_000, "cache_write_tokens": 900, "ttl_seconds": 3600,
            ],
        ]).get()
        XCTAssertEqual(result.panelId, panel)
        XCTAssertEqual(result.report, .request(.init(
            at: at, provider: "anthropic", model: "claude-opus-4-8",
            inputTokens: 1_200, cacheReadTokens: 180_000, cacheWriteTokens: 900, ttl: 3600
        )))
    }

    func testTheCallersPanelIsTheDefaultAndAnExplicitPanelWins() throws {
        let caller = UUID()
        let canonical = LegacyWireAliases.canonicalParams(["caller_panel_id": caller.uuidString, "request": [String: Any]()])
        XCTAssertEqual(try parse(canonical).get().panelId, caller, "the CLI attributes the caller's panel")
        let both = LegacyWireAliases.canonicalParams([
            "panel_id": panel.uuidString, "caller_panel_id": caller.uuidString, "request": [String: Any](),
        ])
        XCTAssertEqual(try parse(both).get().panelId, panel)
        XCTAssertEqual(try parse(["panel_id": panel.uuidString, "request": [String: Any]()]).get().report,
                       .request(.init(at: now)), "a bare request is stamped on arrival")
    }

    func testInvalidReportsAreRejectedWithAReason() {
        let id = panel.uuidString
        XCTAssertEqual(failure(["request": [String: Any]()]), "panel_id is required outside a c11 panel")
        XCTAssertEqual(failure(["panel_id": "panel:3", "request": [String: Any]()]), "panel_id must be a panel UUID")
        XCTAssertEqual(failure(["panel_id": id, "request": [String: Any](), "colour": "blue"]), "unknown parameter 'colour'")
        XCTAssertEqual(failure(["panel_id": id]), "exactly one of request, prompt_cache, reset or unknown is required")
        XCTAssertEqual(failure(["panel_id": id, "request": [String: Any](), "unknown": true]),
                       "exactly one of request, prompt_cache, reset or unknown is required")
        XCTAssertEqual(failure(["panel_id": id, "request": ["prompt": "secret"]]), "unknown request field 'prompt'")
        XCTAssertEqual(failure(["panel_id": id, "request": ["cache_read_tokens": -1]]),
                       "request.cache_read_tokens must be a non-negative integer")
        XCTAssertEqual(failure(["panel_id": id, "request": ["input_tokens": 1.5]]),
                       "request.input_tokens must be a non-negative integer")
        XCTAssertEqual(failure(["panel_id": id, "request": ["cache_write_tokens": true]]),
                       "request.cache_write_tokens must be a non-negative integer", "a boolean is not a count")
        XCTAssertEqual(failure(["panel_id": id, "request": ["at_ms": ms(now.addingTimeInterval(3600))]]),
                       "request.at_ms is in the future")
        XCTAssertEqual(failure(["panel_id": id, "request": ["at_ms": "yesterday"]]),
                       "request.at_ms must be epoch milliseconds")
        XCTAssertEqual(failure(["panel_id": id, "request": ["at_ms": now.timeIntervalSince1970]]),
                       "request.at_ms must be epoch milliseconds", "seconds sent by mistake would anchor in 1970")
        XCTAssertEqual(failure(["panel_id": id, "request": ["ttl_seconds": 5]]),
                       "request.ttl_seconds must be between 60 and 86400")
        XCTAssertEqual(failure(["panel_id": id, "request": ["model": String(repeating: "m", count: 129)]]),
                       "request.model must be a string of at most 128 characters")
        XCTAssertEqual(failure(["panel_id": id, "request": "warm"]), "request must be an object")
    }

    func testTheClaudeStatuslineObjectParsesAsIsAndIgnoresFieldsC11DoesNotUse() throws {
        let expires = now.addingTimeInterval(38 * 60)
        let parsed = try parse([
            "panel_id": panel.uuidString,
            "prompt_cache": [
                "warm": true, "ttl": "1h", "expires_at": expires.timeIntervalSince1970,
                "hit_ratio": 0.97, "misses": 2, "recache_tokens_if_cold": 182_000,
            ],
        ]).get()
        XCTAssertEqual(parsed.report, .state(.init(warm: true, expiresAt: expires, ttl: 3600, misses: 2, recacheTokens: 182_000)))
        let cold = try parse(["panel_id": panel.uuidString, "prompt_cache": ["warm": false, "ttl": "5m", "expires_at": NSNull()]]).get()
        XCTAssertEqual(cold.report, .state(.init(warm: false, expiresAt: nil, ttl: 300)))
        XCTAssertEqual(failure(["panel_id": panel.uuidString, "prompt_cache": ["warm": 1]]), "prompt_cache.warm must be a boolean")
        XCTAssertEqual(failure(["panel_id": panel.uuidString, "prompt_cache": ["warm": true, "ttl": "forever"]]),
                       "prompt_cache.ttl must be a lifetime such as \"5m\" or \"1h\"")
        XCTAssertEqual(failure(["panel_id": panel.uuidString,
                                "prompt_cache": ["warm": true, "ttl": "5m", "expires_at": now.addingTimeInterval(3 * 3600).timeIntervalSince1970]]),
                       "prompt_cache.expires_at is further ahead than its ttl")
    }

    func testAResetNamesWhatReplacedThePrefix() throws {
        let at = now.addingTimeInterval(-5)
        XCTAssertEqual(try parse(["panel_id": panel.uuidString, "reset": ["reason": "compaction", "at_ms": ms(at)]]).get().report,
                       .reset(.compaction, at: at))
        XCTAssertEqual(try parse(["panel_id": panel.uuidString, "reset": ["reason": "model_switch"]]).get().report,
                       .reset(.modelSwitch, at: now))
        XCTAssertEqual(failure(["panel_id": panel.uuidString, "reset": ["reason": "restart"]]),
                       "reset.reason must be compaction, model_switch or effort_change")
        XCTAssertEqual(failure(["panel_id": panel.uuidString, "reset": ["reason": "compaction", "why": "x"]]),
                       "reset must be {\"reason\": …, \"at_ms\": …}")
    }

    func testUnknownTakesTrueOrAReason() throws {
        XCTAssertEqual(try parse(["panel_id": panel.uuidString, "unknown": true]).get().report, .unknown)
        XCTAssertEqual(try parse(["panel_id": panel.uuidString, "unknown": ["reason": "cache_warming"]]).get().report, .unknown)
        XCTAssertEqual(failure(["panel_id": panel.uuidString, "unknown": false]), "unknown must be true or {\"reason\": …}")
    }

    func testTTLSpellings() {
        XCTAssertEqual(PromptCacheReportParser.ttlSeconds("5m"), 300)
        XCTAssertEqual(PromptCacheReportParser.ttlSeconds("1h"), 3600)
        XCTAssertEqual(PromptCacheReportParser.ttlSeconds("90s"), 90)
        XCTAssertEqual(PromptCacheReportParser.ttlSeconds(3600), 3600)
        XCTAssertNil(PromptCacheReportParser.ttlSeconds("1d"))
    }

    // MARK: - Policy

    func testTheReportedPolicyRowFollowsTheProvider() {
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "anthropic", model: "claude-opus-4-8", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "anthropic", model: nil, ttl: 3600), .ttl(3600), "the harness's TTL wins")
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "openrouter", model: "anthropic/claude-sonnet-4.5", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "amazon-bedrock", model: "us.anthropic.claude-sonnet-4-5", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "google-vertex-anthropic", model: "claude", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "vercel-ai-gateway", model: "anthropic/claude-opus-4-8", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "google-vertex", model: "claude-opus-4-8@default", ttl: nil), .ttl(300),
                       "Vertex passes Anthropic's cache through under a bare claude- id")
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "opencode", model: "claude-sonnet-4-5", ttl: nil), .ttl(300))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "kimi-coding", model: "k3", ttl: nil), .estimate(3600),
                       "another provider behind the anthropic-messages API caches implicitly")
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "openai", model: "gpt-5.6", ttl: nil), .estimate(2 * 3600))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "openai-codex", model: "gpt-5.6", ttl: nil), .estimate(2 * 3600))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "azure-openai-responses", model: "gpt-5.6", ttl: nil), .estimate(2 * 3600))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "moonshotai", model: "kimi-k3", ttl: nil), .estimate(3600))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "openrouter", model: "deepseek/deepseek-v4", ttl: nil), .estimate(3600))
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: "github-copilot", model: "claude-sonnet-4.5", ttl: nil), .estimate(3600),
                       "Copilot's backend cache is not Anthropic's")
        XCTAssertEqual(PromptCachePolicy.reportedBasis(provider: nil, model: nil, ttl: nil), .estimate(3600))
    }

    // MARK: - Folding reports into a slot

    func testAnExplicitCacheCountsOnlyRequestsThatTouchIt() throws {
        let t0 = now
        var slot = PromptCacheReportStore.fold(nil, request(t0, read: 0, write: 0), receivedAt: t0)
        XCTAssertNil(slot.observation, "caching off says nothing about the cache")
        slot = PromptCacheReportStore.fold(slot, request(t0.addingTimeInterval(5), input: 50, read: 0, write: 20_000), receivedAt: t0)
        let cache = try XCTUnwrap(slot.observation)
        XCTAssertEqual(cache.requestAt, t0.addingTimeInterval(5))
        XCTAssertEqual(cache.basis, .ttl(300))
        XCTAssertEqual(cache.promptTokens, 20_050)
        XCTAssertEqual(cache.source, .report)
        slot = PromptCacheReportStore.fold(slot, request(t0.addingTimeInterval(9), read: 0, write: 0), receivedAt: t0)
        XCTAssertEqual(slot.observation?.requestAt, t0.addingTimeInterval(5), "a request that touched no cache moves nothing")
    }

    func testARequestWithoutUsageMovesAnEstablishedAnchorOnly() {
        let t0 = now
        let ping = PromptCacheReport.request(.init(at: t0))
        XCTAssertNil(PromptCacheReportStore.fold(nil, ping, receivedAt: t0).observation)
        var slot = PromptCacheReportStore.fold(nil, request(t0, read: 1_000, write: 0, ttl: 3600), receivedAt: t0)
        slot = PromptCacheReportStore.fold(slot, .request(.init(at: t0.addingTimeInterval(600))), receivedAt: t0.addingTimeInterval(600))
        XCTAssertEqual(slot.observation?.requestAt, t0.addingTimeInterval(600), "an interrupted request still read the cache")
        XCTAssertEqual(slot.observation?.basis, .ttl(3600))
    }

    func testAnImplicitCacheProvesItselfWithItsFirstRead() throws {
        let t0 = now
        var slot = PromptCacheReportStore.fold(nil, request(t0, provider: "deepseek", read: 0), receivedAt: t0)
        XCTAssertNil(slot.observation, "a provider that never reads may not cache at all")
        slot = PromptCacheReportStore.fold(slot, request(t0.addingTimeInterval(10), provider: "deepseek", read: 4_000), receivedAt: t0)
        XCTAssertEqual(slot.observation?.basis, .estimate(PromptCachePolicy.implicitColdAfter))
        slot = PromptCacheReportStore.fold(slot, request(t0.addingTimeInterval(20), provider: "deepseek", read: 0), receivedAt: t0)
        XCTAssertEqual(slot.observation?.requestAt, t0.addingTimeInterval(20), "once proven, a miss still re-caches")
    }

    func testOutOfOrderReportsCoalesceToTheNewestRequest() {
        let store = PromptCacheReportStore()
        let t0 = now
        for offset in [0, 30, 10, 20] as [TimeInterval] {
            store.record(request(t0.addingTimeInterval(offset), read: 500, write: Int(offset)), panelId: panel, receivedAt: t0.addingTimeInterval(40))
        }
        let slot = store.slot(forPanel: panel)
        XCTAssertEqual(slot?.observation?.requestAt, t0.addingTimeInterval(30))
        XCTAssertEqual(slot?.observation?.promptTokens, 100 + 500 + 30, "the late, older reports changed nothing")
    }

    func testAnExactStatuslineStateExpiresWhenTheHarnessSays() throws {
        let expires = now.addingTimeInterval(38 * 60)
        let warm = PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: expires, ttl: 3600, misses: 2, recacheTokens: 182_000)), receivedAt: now)
        let cache = try XCTUnwrap(warm.observation)
        XCTAssertEqual(cache.coldAt(), expires)
        XCTAssertEqual(cache.basis, .ttl(3600))
        XCTAssertEqual(cache.source, .statusline)
        XCTAssertEqual(cache.misses, 2)
        XCTAssertEqual(cache.promptTokens, 182_000)
        XCTAssertFalse(cache.isCold(at: now))

        let cold = PromptCacheReportStore.fold(warm, .state(.init(warm: false, expiresAt: expires, ttl: 3600)), receivedAt: now)
        XCTAssertEqual(cold.observation?.coldAt(), now, "a cold report is cold no later than its arrival")
        let longCold = PromptCacheReportStore.fold(nil, .state(.init(warm: false, expiresAt: now.addingTimeInterval(-600), ttl: 300)), receivedAt: now)
        XCTAssertEqual(longCold.observation?.coldAt(), now.addingTimeInterval(-600))
    }

    func testAStatuslineReportWithoutAnExpiryKeepsTheOneItHas() {
        let expires = now.addingTimeInterval(600)
        var slot = PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: expires, ttl: 3600)), receivedAt: now)
        slot = PromptCacheReportStore.fold(slot, .state(.init(warm: true, expiresAt: nil, ttl: 3600)), receivedAt: now.addingTimeInterval(60))
        XCTAssertEqual(slot.observation?.coldAt(), expires, "a warm report without an expiry does not extend it")
        slot = PromptCacheReportStore.fold(slot, .state(.init(warm: false, expiresAt: nil, ttl: 3600)), receivedAt: now.addingTimeInterval(300))
        XCTAssertEqual(slot.observation?.coldAt(), now.addingTimeInterval(300), "evicted before its expiry: cold from this report")
        slot = PromptCacheReportStore.fold(slot, .state(.init(warm: false, expiresAt: nil, ttl: 3600)), receivedAt: now.addingTimeInterval(360))
        XCTAssertEqual(slot.observation?.coldAt(), now.addingTimeInterval(300), "a repeated cold report does not move the expiry to now")
        let lapsed = PromptCacheReportStore.fold(
            PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: expires, ttl: 3600)), receivedAt: now),
            .state(.init(warm: false, expiresAt: nil, ttl: 3600)), receivedAt: now.addingTimeInterval(900)
        )
        XCTAssertEqual(lapsed.observation?.coldAt(), expires, "a cold report after the expiry keeps when it went cold")
        let fresh = PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: nil, ttl: 300)), receivedAt: now)
        XCTAssertEqual(fresh.observation?.coldAt(), now.addingTimeInterval(300))
    }

    func testAResetIsColdUntilTheNextRequest() throws {
        var slot = PromptCacheReportStore.fold(nil, .reset(.compaction, at: now), receivedAt: now)
        XCTAssertNil(slot.observation, "before any request there is no cache to reset")
        slot = PromptCacheReportStore.fold(slot, request(now, read: 900, ttl: 3600), receivedAt: now)
        slot = PromptCacheReportStore.fold(slot, .reset(.modelSwitch, at: now.addingTimeInterval(60)), receivedAt: now.addingTimeInterval(60))
        let reset = try XCTUnwrap(slot.observation)
        XCTAssertEqual(reset.reset, .modelSwitch)
        XCTAssertEqual(reset.coldAt(), now.addingTimeInterval(60))
        XCTAssertEqual(PromptCacheReportStore.stateWord(slot, now: now.addingTimeInterval(61)), "cold")

        let stale = PromptCacheReportStore.fold(slot, request(now.addingTimeInterval(30), read: 900, ttl: 3600), receivedAt: now.addingTimeInterval(70))
        XCTAssertEqual(stale.observation?.reset, .modelSwitch, "a request sent before the reset does not undo it")
        let ping = PromptCacheReportStore.fold(slot, .request(.init(at: now.addingTimeInterval(90))), receivedAt: now.addingTimeInterval(90))
        XCTAssertNil(ping.observation?.reset, "the next request writes a new cache")
        XCTAssertEqual(ping.observation?.requestAt, now.addingTimeInterval(90))

        let olderReset = PromptCacheReportStore.fold(ping, .reset(.compaction, at: now.addingTimeInterval(80)), receivedAt: now.addingTimeInterval(95))
        XCTAssertNil(olderReset.observation?.reset, "a reset older than the last request was already superseded")
    }

    func testUnknownClearsTheCacheUntilTheNextRequest() {
        var slot = PromptCacheReportStore.fold(nil, request(now, read: 900, ttl: 300), receivedAt: now)
        slot = PromptCacheReportStore.fold(slot, .unknown, receivedAt: now.addingTimeInterval(250))
        XCTAssertTrue(slot.unknown)
        XCTAssertNil(slot.observation)
        XCTAssertEqual(PromptCacheReportStore.stateWord(slot, now: now), "unknown")
        slot = PromptCacheReportStore.fold(slot, request(now.addingTimeInterval(400), read: 900, ttl: 300), receivedAt: now.addingTimeInterval(400))
        XCTAssertFalse(slot.unknown)
        XCTAssertEqual(slot.observation?.requestAt, now.addingTimeInterval(400))
    }

    func testTheStoreForgetsClosedPanelsAndStaysBounded() {
        let store = PromptCacheReportStore()
        let other = UUID()
        store.record(.unknown, panelId: panel, receivedAt: now)
        store.record(.unknown, panelId: other, receivedAt: now)
        store.retain(livePanels: [panel])
        XCTAssertNotNil(store.slot(forPanel: panel))
        XCTAssertNil(store.slot(forPanel: other))
        store.remove(panelId: panel)
        XCTAssertNil(store.slot(forPanel: panel))

        let first = UUID()
        store.record(.unknown, panelId: first, receivedAt: now)
        for index in 1...PromptCacheReportStore.capacity {
            store.record(.unknown, panelId: UUID(), receivedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertNil(store.slot(forPanel: first), "the oldest slot makes room")
    }

    func testReportsEndWhenTheAgentLeavesNotWhenAToolItOpenedTakesTheTerminal() {
        XCTAssertTrue(AgentDetector.endsPromptCacheReports(from: "pi", to: "shell"))
        XCTAssertTrue(AgentDetector.endsPromptCacheReports(from: "pi", to: "claude-code"))
        XCTAssertFalse(AgentDetector.endsPromptCacheReports(from: "opencode", to: "unknown"), "an editor the agent opened")
        XCTAssertFalse(AgentDetector.endsPromptCacheReports(from: nil, to: "opencode"), "a report can land before the first scan")
        XCTAssertFalse(AgentDetector.endsPromptCacheReports(from: "omp", to: "omp"))
    }

    // MARK: - The socket method

    func testTheSocketMethodRunsOffMainAndAnswersWithTheSlotsState() throws {
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "agent.prompt_cache.report"), .socketWorker)
        let store = PromptCacheReportStore()
        let ok = TerminalController.promptCacheReportResult(
            params: ["panel_id": panel.uuidString,
                     "request": ["at_ms": ms(now), "provider": "anthropic", "cache_read_tokens": 10, "ttl_seconds": 300]],
            store: store, now: now
        )
        guard case .ok(let payload) = ok, let result = payload as? [String: Any] else {
            return XCTFail("expected ok, got \(ok)")
        }
        XCTAssertEqual(result["panel_id"] as? String, panel.uuidString)
        XCTAssertEqual(result["state"] as? String, "warm")
        XCTAssertEqual(result["source"] as? String, "report")
        XCTAssertEqual(store.slot(forPanel: panel)?.observation?.coldAt(), now.addingTimeInterval(300))

        let rejected = TerminalController.promptCacheReportResult(params: ["request": [String: Any]()], store: store, now: now)
        guard case .err(let code, _, _) = rejected else { return XCTFail("expected an error") }
        XCTAssertEqual(code, "invalid_params")
    }

    // MARK: - Which source describes the panel

    private func transcript(_ requestAt: Date, scannedAt: Date) -> PromptCacheReading {
        PromptCacheReading(
            observation: PromptCacheObservation(requestAt: requestAt, basis: .ttl(3600), promptTokens: 1_000),
            scannedAt: scannedAt
        )
    }

    func testAnExactStatuslineBeatsTheTranscriptUntilTheTranscriptHasANewerRequest() throws {
        let t0 = now
        let read = transcript(t0, scannedAt: t0.addingTimeInterval(10))
        // Keepalive touches moved the expiry past the transcript's estimate.
        let tap = PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: t0.addingTimeInterval(5_400), ttl: 3600)),
                                              receivedAt: t0.addingTimeInterval(2))
        let chosen = try XCTUnwrap(PromptCacheSources.resolve(transcript: read, report: tap, now: t0.addingTimeInterval(4_000)))
        XCTAssertEqual(chosen.observation?.source, .statusline)
        XCTAssertFalse(try XCTUnwrap(chosen.observation).isCold(at: t0.addingTimeInterval(4_000)), "exact data wins over the estimate")

        let newer = transcript(t0.addingTimeInterval(60), scannedAt: t0.addingTimeInterval(70))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: newer, report: tap, now: t0.addingTimeInterval(70)), newer,
                       "a request after the last statusline report is newer evidence")
    }

    func testATranscriptResetAfterTheStatuslinesLastRequestWins() throws {
        let t0 = now
        let tap = PromptCacheReportStore.fold(nil, .state(.init(warm: true, expiresAt: t0.addingTimeInterval(3_600), ttl: 3600)),
                                              receivedAt: t0.addingTimeInterval(200))
        var reset = PromptCacheObservation(requestAt: t0, basis: .ttl(3600), promptTokens: 1_000)
        reset.reset = .modelSwitch
        reset.resetAt = t0.addingTimeInterval(100)
        let read = PromptCacheReading(observation: reset, scannedAt: t0.addingTimeInterval(110))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: read, report: tap, now: t0.addingTimeInterval(300)), read,
                       "the statusline keeps reporting the old expiry after a /model; the transcript knows")
        let later = PromptCacheReportStore.fold(tap, .state(.init(warm: true, expiresAt: t0.addingTimeInterval(3_900), ttl: 3600)),
                                                receivedAt: t0.addingTimeInterval(310))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: read, report: later, now: t0.addingTimeInterval(320))?.observation?.source,
                       .statusline, "a request after the reset brings the statusline back")
    }

    func testAPluginReportAndATranscriptCompareByRequestTime() {
        let t0 = now
        let read = transcript(t0, scannedAt: t0.addingTimeInterval(10))
        let older = PromptCacheReportStore.fold(nil, request(t0.addingTimeInterval(-5), read: 10), receivedAt: t0.addingTimeInterval(30))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: read, report: older, now: t0.addingTimeInterval(40)), read)
        let tie = PromptCacheReportStore.fold(nil, request(t0, read: 10), receivedAt: t0.addingTimeInterval(30))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: read, report: tie, now: t0.addingTimeInterval(40))?.observation?.source,
                       .report, "a report wins a tie")
    }

    func testAnUnknownReportFallsBackToDormancyAndANoEvidenceSlotDefersToTheTranscript() {
        let t0 = now
        let read = transcript(t0, scannedAt: t0.addingTimeInterval(10))
        let unknown = PromptCacheReportStore.fold(nil, .unknown, receivedAt: t0.addingTimeInterval(20))
        let resolved = PromptCacheSources.resolve(transcript: read, report: unknown, now: t0.addingTimeInterval(9_000))
        XCTAssertNotNil(resolved)
        XCTAssertNil(resolved?.observation)
        XCTAssertNil(PanelLivenessDeriver.isPromptCacheCold(resolved, restingSince: t0, now: t0.addingTimeInterval(9_000)),
                     "no cache state: the dormancy rule decides")

        let noEvidence = PromptCacheReportStore.fold(nil, request(t0.addingTimeInterval(30), provider: "deepseek", read: 0),
                                                     receivedAt: t0.addingTimeInterval(30))
        XCTAssertEqual(PromptCacheSources.resolve(transcript: read, report: noEvidence, now: t0.addingTimeInterval(40)), read)
        XCTAssertNil(PromptCacheSources.resolve(transcript: nil, report: noEvidence, now: t0.addingTimeInterval(40)))
    }

    func testAReportStillInFlightAsTheAgentRestsFailsWarm() throws {
        let t0 = now
        let slot = PromptCacheReportStore.fold(nil, request(t0, read: 10), receivedAt: t0)
        let restingSince = t0.addingTimeInterval(400)
        let early = PromptCacheSources.resolve(transcript: nil, report: slot, now: restingSince.addingTimeInterval(2))
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(early, restingSince: restingSince, now: restingSince.addingTimeInterval(2)), false)
        let settled = PromptCacheSources.resolve(transcript: nil, report: slot, now: restingSince.addingTimeInterval(10))
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(settled, restingSince: restingSince, now: restingSince.addingTimeInterval(10)), true)
    }

    @MainActor
    func testTheTabFieldNamesItsSourceAndAReportedUnknown() throws {
        let cache = PromptCacheObservation(requestAt: now, basis: .ttl(3600), promptTokens: 9, source: .statusline, misses: 3)
        let field = try XCTUnwrap(TerminalController.promptCacheField(cache, now: now) as? [String: Any])
        XCTAssertEqual(field["source"] as? String, "statusline")
        XCTAssertEqual(field["misses"] as? Int, 3)
        let transcriptField = try XCTUnwrap(TerminalController.promptCacheField(
            PromptCacheObservation(requestAt: now, basis: .ttl(300), promptTokens: nil), now: now
        ) as? [String: Any])
        XCTAssertEqual(transcriptField["source"] as? String, "transcript")
        XCTAssertTrue(transcriptField["misses"] is NSNull)
        let unknown = try XCTUnwrap(TerminalController.promptCacheField(nil, reportedUnknown: true, now: now) as? [String: Any])
        XCTAssertEqual(unknown["state"] as? String, "unknown")
        XCTAssertTrue(TerminalController.promptCacheField(nil, now: now) is NSNull)
    }
}
