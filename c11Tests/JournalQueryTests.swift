import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

enum JournalAnalyticsFixture {
    static let tab = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let app = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    static let restartedApp = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!

    static func draft(_ kind: JournalKind, at: Int64, agent: String = "claude-code") -> JournalDraft {
        JournalDraft(kind: kind, emittedAtMs: at, tabID: tab, workspaceID: workspace,
                     sessionID: "analytics-session", agentKind: agent, source: .hook,
                     adapter: .claudeHook,
                     nativeEvent: kind == .turnStarted ? "UserPromptSubmit" : "PreToolUse")
    }

    static func event(_ draft: JournalDraft, sequence: Int64, committedAt: Int64,
                      tick: UInt64, app: UUID = app, effect: JournalEffect = .applied,
                      from: JournalPhase? = nil, to: JournalPhase? = nil,
                      model: String? = "model-a") -> JournalEvent {
        JournalEvent(sequence: sequence, committedAtMs: committedAt, observedTickNs: tick,
                     appInstanceID: app, draft: draft, draftHash: "fixture-(sequence)",
                     attribution: "exact", confidenceRank: draft.source.rank,
                     capabilities: draft.adapter.capabilities, modelID: model, foldVersion: 1,
                     effect: effect, effectReason: "fixture", fromPhase: from,
                     toPhase: to, fromSinceMs: from == nil ? nil : committedAt - 1_000)
    }

    static func lifecycleEvents(includeResponse: Bool = true) -> [JournalEvent] {
        var start = draft(.turnStarted, at: 0)
        start.turnID = "turn-a"
        var ask = draft(.questionRequested, at: 1_000)
        ask.requestID = "ask-a"
        ask.reasonCode = .question
        var seen = draft(.stateChanged, at: 2_000)
        seen.signal = .observation
        var response = draft(.stateChanged, at: 5_500)
        response.signal = .operatorResponse
        response.requestID = "ask-a"
        response.occurredAtMs = 5_500
        response.timeQuality = .observed
        var repeatedResponse = response
        repeatedResponse.eventID = UUID()
        repeatedResponse.emittedAtMs = 6_000
        repeatedResponse.occurredAtMs = 6_000
        var resumed = draft(.attentionResolved, at: 7_000)
        resumed.requestID = "ask-a"
        resumed.resolution = .resumed
        var stop = draft(.turnCompleted, at: 8_000)
        stop.turnID = "turn-a"

        var events = [
            event(start, sequence: 1, committedAt: 0, tick: 1_000_000_000, to: .working),
            event(ask, sequence: 2, committedAt: 1_000, tick: 2_000_000_000,
                  from: .working, to: .blocked),
            event(seen, sequence: 3, committedAt: 2_000, tick: 3_000_000_000,
                  effect: .observation),
        ]
        if includeResponse {
            events.append(event(response, sequence: 4, committedAt: 5_500, tick: 5_500_000_000,
                                effect: .observation))
            events.append(event(repeatedResponse, sequence: 5, committedAt: 6_000, tick: 6_000_000_000,
                                effect: .observation))
        }
        events.append(event(resumed, sequence: Int64(events.count + 1), committedAt: 7_000,
                            tick: 7_000_000_000, from: .blocked, to: .working))
        events.append(event(stop, sequence: Int64(events.count + 1), committedAt: 8_000,
                            tick: 8_000_000_000, from: .working, to: .idle))
        return events
    }

    static func coverage(highWater: Int64, first: Int64? = 1) -> JournalQueryCoverage {
        JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: first,
                             highWaterSequence: highWater, incomplete: false,
                             uncertainCount: 0, censoredCount: 0, sources: [:])
    }
}

final class JournalQueryTests: XCTestCase {
    func testSixMetricsUseCommittedTransitionsAndSeparateResumeFromResponse() throws {
        let filters = JournalQueryFilters(fromMs: 0, toMs: 9_000, stallMs: 500)
        let result = JournalQuery.evaluate(events: JournalAnalyticsFixture.lifecycleEvents(), baselines: [],
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 7), filters: filters)
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["working"], 2_000)
        XCTAssertEqual(time["blocked"], 5_000)
        XCTAssertEqual(time["idle"], 1_000)
        XCTAssertEqual(time["disconnected"], 0)

        let response = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? String, "available")
        XCTAssertEqual(response["wait_ms"] as? Int64, 4_500)
        XCTAssertEqual(response["wait_count"] as? Int, 1)
        XCTAssertEqual(response["resume_ms"] as? Int64, 6_000)
        XCTAssertEqual(response["resume_count"] as? Int, 1)

        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 5_000)
        XCTAssertEqual(blocked["approval"], 0)
        let turns = try XCTUnwrap(result.object["turns"] as? [String: Any])
        XCTAssertEqual(turns["started"] as? Int, 1)
        XCTAssertEqual(turns["completed"] as? Int, 1)
        XCTAssertEqual(turns["covered_hours"] as? Double, 0.0025)
        XCTAssertEqual((turns["per_hour"] as? Double).map { Int($0) }, 400)
        XCTAssertEqual((result.object["stalls"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(result.humanText.contains("units duration=ms"))

        let byModel = try XCTUnwrap(result.object["by_model"] as? [String: Any])
        XCTAssertNotNil(byModel["model-a"])
    }

    func testWindowAndDimensionsClipIntervalsAfterTheFullFold() throws {
        let filters = JournalQueryFilters(agent: "claude-code", model: "model-a",
                                          workspace: JournalAnalyticsFixture.workspace,
                                          fromMs: 4_000, toMs: 6_000)
        let result = JournalQuery.evaluate(events: JournalAnalyticsFixture.lifecycleEvents(), baselines: [],
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 7), filters: filters)
        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 2_000)
        let response = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(response["wait_ms"] as? Int64, 4_500)
        XCTAssertEqual(response["wait_count"] as? Int, 1)
        XCTAssertEqual(response["resume_count"] as? Int, 0)

        let noResponse = JournalQuery.evaluate(events: JournalAnalyticsFixture.lifecycleEvents(includeResponse: false),
                                               baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: 5),
                                               filters: filters)
        let unavailable = try XCTUnwrap(noResponse.object["operator_response"] as? [String: Any])
        XCTAssertEqual(unavailable["status"] as? String, "unavailable")
        XCTAssertTrue(unavailable["wait_ms"] is NSNull)
    }

    func testRestartGapIsCensoredAtTheLastObservationAndNeverChargedAsWorking() throws {
        let start = JournalAnalyticsFixture.draft(.turnStarted, at: 1_000)
        let observation = JournalAnalyticsFixture.draft(.stateChanged, at: 4_000)
        let restarted = JournalAnalyticsFixture.draft(.turnStarted, at: 10_000)
        let events = [
            JournalAnalyticsFixture.event(start, sequence: 1, committedAt: 1_000,
                                          tick: 1_000_000_000, to: .working),
            JournalAnalyticsFixture.event(observation, sequence: 2, committedAt: 4_000,
                                          tick: 4_000_000_000, effect: .observation),
            JournalAnalyticsFixture.event(restarted, sequence: 3, committedAt: 10_000,
                                          tick: 1_000_000_000, app: JournalAnalyticsFixture.restartedApp,
                                          to: .working)
        ]
        let result = JournalQuery.evaluate(events: events, baselines: [],
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 3),
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 12_000))
        let coverage = try XCTUnwrap(result.object["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["incomplete"] as? Bool, true)
        XCTAssertGreaterThan(coverage["censored_count"] as? Int ?? 0, 0)
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["working"], 5_000)
        XCTAssertGreaterThanOrEqual(time["working"] ?? 0, 0)
    }

    func testRetainedUnconfirmedBaselineIsSeparateFromConfirmedBlockedTime() throws {
        var baseline = JournalSnapshot(owner: JournalOwner(tabID: JournalAnalyticsFixture.tab,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.phase = .blocked
        baseline.reason = .question
        baseline.sinceMs = 1_000
        baseline.observedAtMs = 2_000
        baseline.lastSequence = 4
        baseline.confirmation = .unconfirmed
        baseline.connection = .disconnected
        let result = JournalQuery.evaluate(events: [], baselines: [baseline],
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 4, first: nil),
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 5_000))
        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 0)
        XCTAssertEqual(blocked["unconfirmed"], 4_000)
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["blocked"], 0)
        XCTAssertEqual(time["unconfirmed"], 4_000)
        XCTAssertEqual(time["disconnected"], 4_000)
    }

    func testCurrentBaselineReplacesEventDerivedOngoingInterval() throws {
        var baseline = JournalSnapshot(owner: JournalOwner(tabID: JournalAnalyticsFixture.tab,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.phase = .idle
        baseline.sinceMs = 8_000
        baseline.observedAtMs = 8_000
        baseline.observedTickNs = 8_000_000_000
        baseline.lastSequence = 7
        baseline.confirmation = .confirmed
        baseline.connection = .live

        let result = JournalQuery.evaluate(events: JournalAnalyticsFixture.lifecycleEvents(),
                                           baselines: [baseline],
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 7),
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 10_000))
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["idle"], 2_000)
    }
}
