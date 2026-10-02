import XCTest
import SQLite3

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
        response.source = .c11
        response.adapter = .c11
        response.nativeEvent = "operator_response"
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
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 7), filters: filters,
                                           writerInstanceID: JournalAnalyticsFixture.app)
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
                                           coverage: JournalAnalyticsFixture.coverage(highWater: 7), filters: filters,
                                           writerInstanceID: JournalAnalyticsFixture.app)
        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 2_000)
        let response = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(response["wait_ms"] as? Int64, 4_500)
        XCTAssertEqual(response["wait_count"] as? Int, 1)
        XCTAssertEqual(response["resume_count"] as? Int, 0)

        let noResponse = JournalQuery.evaluate(events: JournalAnalyticsFixture.lifecycleEvents(includeResponse: false),
                                               baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: 5),
                                               filters: filters, writerInstanceID: JournalAnalyticsFixture.app)
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
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 12_000),
                                           writerInstanceID: JournalAnalyticsFixture.restartedApp)
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
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: nil,
                                            highWaterSequence: 4, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: 2_000)
        let result = JournalQuery.evaluate(events: [], baselines: [baseline],
                                           coverage: coverage,
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 5_000))
        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 0)
        XCTAssertEqual(blocked["unconfirmed"], 1_000)
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["blocked"], 0)
        XCTAssertEqual(time["unconfirmed"], 1_000)
        XCTAssertEqual(time["disconnected"], 1_000)
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
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 10_000),
                                           writerInstanceID: JournalAnalyticsFixture.app)
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["idle"], 2_000)
    }

    func testOfflineBaselineStopsAtItsLastObservation() throws {
        var baseline = JournalSnapshot(owner: JournalOwner(tabID: JournalAnalyticsFixture.tab,
                                                            agentKind: "claude-code", sessionID: "analytics-session"),
                                       workspaceID: JournalAnalyticsFixture.workspace,
                                       appInstanceID: JournalAnalyticsFixture.app)
        baseline.phase = .working
        baseline.sinceMs = 1_000
        baseline.observedAtMs = 2_000
        baseline.lastSequence = 4
        baseline.connection = .live
        baseline.confirmation = .confirmed
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: 5,
                                            highWaterSequence: 4, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: 2_000)
        let result = JournalQuery.evaluate(events: [], baselines: [baseline], coverage: coverage,
                                           filters: JournalQueryFilters(fromMs: 0, toMs: 5_000))
        let time = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(time["working"], 0, "offline time is never promoted to confirmed work")
        XCTAssertEqual(time["disconnected"], 1_000)
        XCTAssertEqual(time["unconfirmed"], 1_000)
        let resultCoverage = try XCTUnwrap(result.object["coverage"] as? [String: Any])
        XCTAssertEqual(resultCoverage["incomplete"] as? Bool, true)
        XCTAssertGreaterThan(resultCoverage["censored_count"] as? Int ?? 0, 0)
    }

    func testStoreBackedBoundaryKeepsAttributionAndDoesNotDoubleCountBaseline() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-query-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: Int64 = 1_000
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory),
                                     instanceID: JournalAnalyticsFixture.app,
                                     clock: { now }, tickClock: { UInt64(now) * 1_000_000 })
        var start = JournalTestData.draft(.turnStarted, at: now)
        start.turnID = "turn-a"
        _ = try store.append(draft: start, context: JournalContext(eligible: true, modelID: "model-a"))

        now = 2_000
        var tool = JournalTestData.draft(.stateChanged, at: now)
        tool.signal = .toolActivity
        let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        tool.workspaceID = workspaceB
        _ = try store.append(draft: tool, context: JournalContext(eligible: true, modelID: "model-b"))
        let baseline = try XCTUnwrap(store.current(owner: start.owner!))
        XCTAssertEqual(baseline.sinceMs, 1_000, "same-phase tool evidence retains the phase origin")

        now = 2_500
        var disconnected = JournalTestData.draft(.stateChanged, at: now)
        disconnected.source = .c11; disconnected.adapter = .c11
        disconnected.nativeEvent = "connection_lost"; disconnected.signal = .connectionLost
        disconnected.workspaceID = workspaceB
        _ = try store.append(draft: disconnected, context: JournalContext(eligible: true, modelID: "model-b"))

        now = 3_000
        var recovered = JournalTestData.draft(.stateChanged, at: now)
        recovered.signal = .toolActivity
        let workspaceC = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        recovered.workspaceID = workspaceC
        _ = try store.append(draft: recovered, context: JournalContext(eligible: true, modelID: "model-c"))

        let frozen = try store.coverage()
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: frozen.first,
                                            highWaterSequence: frozen.highWater, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: frozen.lastObservation)
        let filters = JournalQueryFilters(fromMs: 0, toMs: 4_000)
        let stream = JournalQuery.Stream(baselines: try store.baselines(), coverage: coverage,
                                         filters: filters, writerInstanceID: JournalAnalyticsFixture.app)
        var cursor = max(0, frozen.first - 1)
        while cursor < frozen.highWater {
            let page = try store.readPage(after: cursor, through: frozen.highWater, limit: 1)
            guard !page.isEmpty else { break }
            page.forEach(stream.consume)
            cursor = page.last!.sequence
        }
        let result = stream.finish()
        let total = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(total["working"], 2_500)
        XCTAssertEqual(total["disconnected"], 500)
        XCTAssertEqual(total["unconfirmed"], 500)

        let models = try XCTUnwrap(result.object["by_model"] as? [String: [String: Any]])
        let modelA = try XCTUnwrap(models["model-a"]?["time_in_state_ms"] as? [String: Int64])
        let modelB = try XCTUnwrap(models["model-b"]?["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(modelA["working"], 1_000)
        XCTAssertEqual(modelB["working"], 500)
        let modelBUnconfirmed = try XCTUnwrap(models["model-b"]?["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(modelBUnconfirmed["disconnected"], 500)
        let modelC = try XCTUnwrap(models["model-c"]?["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(modelC["working"], 1_000)

        let workspaces = try XCTUnwrap(result.object["by_workspace"] as? [String: [String: Any]])
        let workspaceA = try XCTUnwrap(workspaces[JournalTestData.workspace.uuidString]?["time_in_state_ms"] as? [String: Int64])
        let workspaceBID = workspaceB.uuidString
        let workspaceBMetric = try XCTUnwrap(workspaces[workspaceBID]?["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(workspaceA["working"], 1_000)
        XCTAssertEqual(workspaceBMetric["working"], 500)
        XCTAssertEqual(workspaceBMetric["unconfirmed"], 500)
        let workspaceCMetric = try XCTUnwrap(workspaces[workspaceC.uuidString]?["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(workspaceCMetric["working"], 1_000)
    }

    func testStoreBackedQ1ThroughQ6HaveHandCalculatedTotalsAcrossToolRefreshes() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-query-q1-q6-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: Int64 = 1_000
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory),
                                     instanceID: JournalAnalyticsFixture.app,
                                     clock: { now }, tickClock: { UInt64(now) * 1_000_000 })
        let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000206")!
        let workspaceC = UUID(uuidString: "00000000-0000-0000-0000-000000000207")!

        func append(_ draft: JournalDraft, model: String) throws {
            do {
                _ = try store.append(draft: draft, context: JournalContext(eligible: true, modelID: model))
            } catch {
                XCTFail("store fixture rejected \(draft.kind.rawValue) (\(draft.nativeEvent)): \(error)")
                throw error
            }
        }
        now = 1_000
        var start = JournalTestData.draft(.turnStarted, at: now)
        start.turnID = "turn-q1"
        try append(start, model: "model-a")

        now = 1_500
        var firstTool = JournalTestData.draft(.stateChanged, at: now)
        firstTool.signal = .toolActivity
        firstTool.workspaceID = workspaceB
        try append(firstTool, model: "model-b")

        now = 2_000
        var ask = JournalTestData.draft(.questionRequested, at: now)
        ask.requestID = "ask-q2"
        ask.reasonCode = .question
        try append(ask, model: "model-b")

        now = 2_200
        var seen = JournalTestData.draft(.stateChanged, at: now)
        seen.signal = .observation
        try append(seen, model: "model-b")

        now = 2_500
        var response = JournalTestData.draft(.stateChanged, at: now)
        response.source = .c11; response.adapter = .c11
        response.nativeEvent = "operator_response"; response.signal = .operatorResponse
        response.requestID = "ask-q2"; response.occurredAtMs = now
        response.timeQuality = .observed; response.workspaceID = workspaceC
        try append(response, model: "model-c")

        now = 3_000
        var resumed = JournalTestData.draft(.attentionResolved, at: now)
        resumed.requestID = "ask-q2"; resumed.resolution = .resumed
        resumed.workspaceID = workspaceC
        try append(resumed, model: "model-c")

        now = 4_000
        var completed = JournalTestData.draft(.turnCompleted, at: now)
        completed.turnID = "turn-q1"; completed.workspaceID = workspaceC
        try append(completed, model: "model-c")

        now = 6_000
        var failed = JournalTestData.draft(.errorReported, at: now)
        failed.reasonCode = .sessionFailure; failed.workspaceID = workspaceC
        try append(failed, model: "model-c")

        now = 7_000
        var secondStart = JournalTestData.draft(.turnStarted, at: now)
        secondStart.turnID = "turn-q6"; secondStart.workspaceID = workspaceC
        try append(secondStart, model: "model-c")

        now = 10_000
        var secondTool = JournalTestData.draft(.stateChanged, at: now)
        secondTool.signal = .toolActivity; secondTool.workspaceID = workspaceB
        try append(secondTool, model: "model-d")

        now = 12_000
        var thirdTool = JournalTestData.draft(.stateChanged, at: now)
        thirdTool.signal = .toolActivity; thirdTool.workspaceID = workspaceB
        try append(thirdTool, model: "model-d")

        now = 15_000
        var interrupted = JournalTestData.draft(.turnInterrupted, at: now)
        interrupted.source = .transcript; interrupted.adapter = .codexTranscript
        interrupted.nativeEvent = "turn.interrupted"; interrupted.turnID = "turn-q6"
        interrupted.workspaceID = workspaceB
        try append(interrupted, model: "model-d")

        let frozen = try store.coverage()
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: frozen.first,
                                            highWaterSequence: frozen.highWater, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: frozen.lastObservation)
        let stream = JournalQuery.Stream(baselines: try store.baselines(), coverage: coverage,
                                         filters: JournalQueryFilters(fromMs: 0, toMs: 15_001,
                                                                      stallMs: 6_000),
                                         writerInstanceID: JournalAnalyticsFixture.app)
        var cursor = max(0, frozen.first - 1)
        while cursor < frozen.highWater {
            let page = try store.readPage(after: cursor, through: frozen.highWater, limit: 3)
            guard !page.isEmpty else { break }
            page.forEach(stream.consume)
            cursor = page.last!.sequence
        }
        let result = stream.finish()

        // Q1: independently summed confirmed work: 500 + 500 + 1,000 + 8,000.
        let states = try XCTUnwrap(result.object["time_in_state_ms"] as? [String: Int64])
        XCTAssertEqual(states["working"], 10_000)
        XCTAssertEqual(states["blocked"], 1_000)
        XCTAssertEqual(states["idle"], 2_001)
        XCTAssertEqual(states["error"], 1_000)

        // Q2: response-event model attribution; the observed response is not itself resolution.
        let operatorResponse = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(operatorResponse["wait_ms"] as? Int64, 500)
        XCTAssertEqual(operatorResponse["wait_count"] as? Int, 1)
        XCTAssertEqual(operatorResponse["resume_ms"] as? Int64, 1_000)
        let models = try XCTUnwrap(result.object["by_model"] as? [String: [String: Any]])
        XCTAssertEqual((models["model-c"]?["operator_response"] as? [String: Any])?["wait_count"] as? Int, 1)

        // Q3: one question wait, not charged as confirmed time before/after its exact interval.
        let blocked = try XCTUnwrap(result.object["blocked_ms"] as? [String: Int64])
        XCTAssertEqual(blocked["question"], 1_000)

        // Q4: two starts in 15,001 ms of requested coverage.
        let turns = try XCTUnwrap(result.object["turns"] as? [String: Any])
        XCTAssertEqual(turns["started"] as? Int, 2)
        XCTAssertEqual(turns["completed"] as? Int, 1)
        XCTAssertEqual(turns["interrupted"] as? Int, 1)
        let perHour = try XCTUnwrap(turns["per_hour"] as? Double)
        XCTAssertEqual(perHour, 2.0 / 15_001.0 * 3_600_000.0, accuracy: 0.0001)

        // Q5: exactly one root session error and one supported interrupt.
        let errors = try XCTUnwrap(result.object["errors"] as? [String: Int])
        XCTAssertEqual(errors["root"], 1)
        XCTAssertEqual(errors["interrupts"], 1)

        // Q6: tool refreshes split attribution segments, not the continuous 8,000 ms work streak.
        let stalls = try XCTUnwrap(result.object["stalls"] as? [[String: Any]])
        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first?["duration_ms"] as? Int64, 8_000)
        XCTAssertEqual(stalls.first?["censored"] as? Bool, false)
        XCTAssertEqual((models["model-d"]?["stalls"] as? [[String: Any]])?.count, 1)
    }

    func testStreamBoundsOwnerAndDimensionAggregationAndDisclosesTruncation() throws {
        func makeEvent(sequence: Int64, ownerIndex: Int, model: String,
                       workspaceID: UUID, tabID: UUID? = nil,
                       sessionID: String? = nil) -> JournalEvent {
            let draft = JournalDraft(kind: .turnStarted, emittedAtMs: sequence,
                                     tabID: tabID ?? UUID(), workspaceID: workspaceID,
                                     sessionID: sessionID ?? "bounded-owner-\(ownerIndex)",
                                     agentKind: "claude-code", source: .hook,
                                     adapter: .claudeHook, nativeEvent: "UserPromptSubmit",
                                     turnID: "turn-\(sequence)")
            return JournalEvent(sequence: sequence, committedAtMs: sequence,
                                observedTickNs: UInt64(sequence) * 1_000_000,
                                appInstanceID: JournalAnalyticsFixture.app,
                                draft: draft, draftHash: "bounded", attribution: "fixture",
                                confidenceRank: 60, capabilities: ["turn"], modelID: model,
                                foldVersion: 1, effect: .applied, effectReason: "fixture",
                                fromPhase: nil, toPhase: .working, fromSinceMs: nil)
        }

        let ownerCount = JournalQuery.maximumOwners + 1
        let workspace = UUID()
        let ownerEvents = (0..<ownerCount).map { index in
            makeEvent(sequence: Int64(index + 1), ownerIndex: index,
                      model: "model-a", workspaceID: workspace)
        }
        let ownerStream = JournalQuery.Stream(
            baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: Int64(ownerCount)),
            filters: JournalQueryFilters(fromMs: 0, toMs: Int64(ownerCount + 100)),
            writerInstanceID: JournalAnalyticsFixture.app)
        ownerEvents.forEach(ownerStream.consume)
        let ownerResult = ownerStream.finish().object
        let ownerCoverage = try XCTUnwrap(ownerResult["coverage"] as? [String: Any])
        XCTAssertEqual(ownerCoverage["aggregation_truncated"] as? Bool, true)
        XCTAssertEqual(ownerCoverage["incomplete"] as? Bool, true)
        XCTAssertEqual((ownerResult["turns"] as? [String: Any])?["started"] as? Int, ownerCount)

        let modelCount = JournalQuery.maximumGroupsPerDimension + 1
        let sharedTab = UUID()
        let sharedSession = "bounded-dimension-owner"
        let modelEvents = (0..<modelCount).map { index in
            makeEvent(sequence: Int64(index + 1), ownerIndex: 10_000,
                      model: "model-\(index)", workspaceID: workspace,
                      tabID: sharedTab, sessionID: sharedSession)
        }
        let modelStream = JournalQuery.Stream(
            baselines: [], coverage: JournalAnalyticsFixture.coverage(highWater: Int64(modelCount)),
            filters: JournalQueryFilters(fromMs: 0, toMs: Int64(modelCount + 100)),
            writerInstanceID: JournalAnalyticsFixture.app)
        modelEvents.forEach(modelStream.consume)
        let modelResult = modelStream.finish().object
        let modelCoverage = try XCTUnwrap(modelResult["coverage"] as? [String: Any])
        XCTAssertEqual(modelCoverage["aggregation_truncated"] as? Bool, true)
        XCTAssertEqual((modelResult["by_model"] as? [String: Any])?.count,
                       JournalQuery.maximumGroupsPerDimension)
        XCTAssertEqual((modelResult["turns"] as? [String: Any])?["started"] as? Int, modelCount)
    }

    func testStoreBackedResponsesAreRootScopedValidAndGroupedByResponseAttribution() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-query-q2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: Int64 = 1_000
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory),
                                     instanceID: JournalAnalyticsFixture.app,
                                     clock: { now }, tickClock: { UInt64(now) * 1_000_000 })
        let tabB = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!

        func ownerDraft(_ kind: JournalKind, tab: UUID = JournalTestData.tab,
                        session: String = "fixture-session", at: Int64) -> JournalDraft {
            var draft = JournalTestData.draft(kind, at: at)
            draft.tabID = tab
            draft.sessionID = session
            return draft
        }
        func appendAsk(tab: UUID, session: String, at: Int64) throws {
            now = at
            var ask = ownerDraft(.questionRequested, tab: tab, session: session, at: at)
            ask.requestID = "shared-request"
            ask.reasonCode = .question
            _ = try store.append(draft: ask, context: JournalContext(eligible: true, modelID: "ask-model"))
        }
        func response(tab: UUID, session: String, at: Int64, model: String,
                      source: JournalSource = .c11, adapter: JournalAdapter = .c11) throws -> JournalEvent {
            now = at
            var draft = ownerDraft(.stateChanged, tab: tab, session: session, at: at)
            draft.source = source
            draft.adapter = adapter
            draft.nativeEvent = "operator_response"
            draft.signal = .operatorResponse
            draft.requestID = "shared-request"
            draft.occurredAtMs = at
            draft.timeQuality = .observed
            let result = try store.append(draft: draft, context: JournalContext(eligible: true, modelID: model))
            return try XCTUnwrap(store.readPage(after: result.receipt.sequence - 1,
                                                through: result.receipt.sequence, limit: 1).first)
        }

        try appendAsk(tab: JournalTestData.tab, session: "fixture-session", at: 1_000)
        try appendAsk(tab: tabB, session: "second-session", at: 1_100)
        let firstResponse = try response(tab: JournalTestData.tab, session: "fixture-session", at: 3_000, model: "response-a")
        let secondResponse = try response(tab: tabB, session: "second-session", at: 3_200, model: "response-b")
        XCTAssertEqual(firstResponse.effect, .observation)
        XCTAssertEqual(secondResponse.effect, .observation)

        now = 4_000
        var cancelledAsk = ownerDraft(.questionRequested, tab: tabB, session: "cancel-session", at: now)
        cancelledAsk.requestID = "cancel-request"
        cancelledAsk.reasonCode = .question
        _ = try store.append(draft: cancelledAsk, context: JournalContext(eligible: true, modelID: "ask-model"))
        now = 5_000
        var cancel = ownerDraft(.attentionResolved, tab: tabB, session: "cancel-session", at: now)
        cancel.requestID = "cancel-request"
        cancel.resolution = .cancelled
        _ = try store.append(draft: cancel, context: JournalContext(eligible: true, modelID: "ask-model"))
        now = 6_000
        var late = ownerDraft(.stateChanged, tab: tabB, session: "cancel-session", at: now)
        late.source = .c11; late.adapter = .c11; late.nativeEvent = "operator_response"
        late.signal = .operatorResponse; late.requestID = "cancel-request"
        late.occurredAtMs = now; late.timeQuality = .observed
        let lateResult = try store.append(draft: late, context: JournalContext(eligible: true, modelID: "response-late"))
        XCTAssertEqual(lateResult.receipt.projectionEffect, .advisory)

        now = 7_000
        var hookAsk = ownerDraft(.questionRequested, tab: tabB, session: "hook-session", at: now)
        hookAsk.requestID = "hook-request"; hookAsk.reasonCode = .question
        _ = try store.append(draft: hookAsk, context: JournalContext(eligible: true, modelID: "ask-model"))
        now = 8_000
        var hookResponse = ownerDraft(.stateChanged, tab: tabB, session: "hook-session", at: now)
        hookResponse.source = .hook; hookResponse.adapter = .claudeHook
        hookResponse.nativeEvent = "operator_response"; hookResponse.signal = .operatorResponse
        hookResponse.requestID = "hook-request"; hookResponse.occurredAtMs = now
        hookResponse.timeQuality = .observed
        XCTAssertEqual(try store.append(draft: hookResponse, context: JournalContext(eligible: true, modelID: "response-hook"))
            .receipt.projectionEffect, .advisory)

        let frozen = try store.coverage()
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: frozen.first,
                                            highWaterSequence: frozen.highWater, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: frozen.lastObservation)
        let stream = JournalQuery.Stream(baselines: try store.baselines(), coverage: coverage,
                                         filters: JournalQueryFilters(fromMs: 0, toMs: 9_000),
                                         writerInstanceID: JournalAnalyticsFixture.app)
        var cursor = max(0, frozen.first - 1)
        while cursor < frozen.highWater {
            let page = try store.readPage(after: cursor, through: frozen.highWater, limit: 2)
            guard !page.isEmpty else { break }
            page.forEach(stream.consume)
            cursor = page.last!.sequence
        }
        let result = stream.finish()
        let responseMetrics = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(responseMetrics["wait_count"] as? Int, 2)
        XCTAssertEqual(responseMetrics["wait_ms"] as? Int64, 4_100)
        let models = try XCTUnwrap(result.object["by_model"] as? [String: [String: Any]])
        XCTAssertEqual((models["response-a"]?["operator_response"] as? [String: Any])?["wait_count"] as? Int, 1)
        XCTAssertEqual((models["response-b"]?["operator_response"] as? [String: Any])?["wait_count"] as? Int, 1)
        XCTAssertEqual((models["response-late"]?["operator_response"] as? [String: Any])?["wait_count"] as? Int,
                       0, "an advisory response after cancellation is not Q2 evidence")
        XCTAssertEqual((models["response-hook"]?["operator_response"] as? [String: Any])?["wait_count"] as? Int,
                       0, "hook-origin response is rejected by the real reducer")
    }

    func testStoreBackedUnknownSequenceGapCensorsOpenAskCorrelation() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appendingPathComponent("journal-query-gap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now: Int64 = 1_000
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory),
                                     instanceID: JournalAnalyticsFixture.app,
                                     clock: { now }, tickClock: { UInt64(now) * 1_000_000 })
        var ask = JournalTestData.draft(.questionRequested, at: now)
        ask.requestID = "gap-request"; ask.reasonCode = .question
        _ = try store.append(draft: ask, context: JournalContext(eligible: true))
        now = 2_000
        var unrelated = JournalTestData.draft(.turnStarted, at: now)
        unrelated.tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        unrelated.sessionID = "gap-owner"
        _ = try store.append(draft: unrelated, context: JournalContext(eligible: true))
        now = 3_000
        var response = JournalTestData.draft(.stateChanged, at: now)
        response.signal = .operatorResponse; response.source = .c11; response.adapter = .c11
        response.nativeEvent = "operator_response"; response.requestID = "gap-request"
        response.occurredAtMs = now; response.timeQuality = .observed
        XCTAssertEqual(try store.append(draft: response, context: JournalContext(eligible: true))
            .receipt.projectionEffect, .observation)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.layout.database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM journal_events WHERE sequence=2", nil, nil, nil), SQLITE_OK)

        let frozen = try store.coverage()
        let coverage = JournalQueryCoverage(retainedFromMs: 0, firstAvailableSequence: frozen.first,
                                            highWaterSequence: frozen.highWater, incomplete: false,
                                            uncertainCount: 0, censoredCount: 0, sources: [:],
                                            lastObservationMs: frozen.lastObservation)
        let stream = JournalQuery.Stream(baselines: try store.baselines(), coverage: coverage,
                                         filters: JournalQueryFilters(fromMs: 0, toMs: 5_000),
                                         writerInstanceID: JournalAnalyticsFixture.app)
        for event in try store.readPage(after: 0, through: frozen.highWater, limit: 1) { stream.consume(event) }
        let page = try store.readPage(after: 1, through: frozen.highWater, limit: 1)
        page.forEach(stream.consume)
        let result = stream.finish()
        let metrics = try XCTUnwrap(result.object["operator_response"] as? [String: Any])
        XCTAssertEqual(metrics["status"] as? String, "unavailable")
        XCTAssertTrue(metrics["wait_ms"] is NSNull)
        XCTAssertEqual(metrics["wait_count"] as? Int, 0)
        XCTAssertGreaterThan(metrics["censored_count"] as? Int ?? 0, 0)
        let resultCoverage = try XCTUnwrap(result.object["coverage"] as? [String: Any])
        XCTAssertEqual(resultCoverage["incomplete"] as? Bool, true)
    }
}
