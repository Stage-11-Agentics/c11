import Foundation

struct JournalQueryFilters: Equatable {
    let agent: String?
    let model: String?
    let workspace: UUID?
    let fromMs: Int64
    let toMs: Int64
    let stallMs: Int64

    init(agent: String? = nil, model: String? = nil, workspace: UUID? = nil,
         fromMs: Int64, toMs: Int64, stallMs: Int64 = 900_000) {
        self.agent = agent
        self.model = model
        self.workspace = workspace
        self.fromMs = fromMs
        self.toMs = toMs
        self.stallMs = stallMs
    }
}

struct JournalQueryCoverage {
    let retainedFromMs: Int64?
    let firstAvailableSequence: Int64?
    let highWaterSequence: Int64
    let incomplete: Bool
    let uncertainCount: Int
    let censoredCount: Int
    let sources: [String: Int]
}

struct JournalQueryResult {
    let object: [String: Any]
    let humanText: String
}

/// The analytics fold is deliberately independent of SQLite and the app. The
/// CLI supplies decoded event pages and current baselines; tests can therefore
/// calculate the expected totals from a deterministic structural timeline.
enum JournalQuery {
    private static let phaseKeys = ["working", "blocked", "idle", "error", "unknown"]
    private static let blockedKeys = ["approval", "question", "plan_review", "unconfirmed"]

    static func evaluate(events: [JournalEvent], baselines: [JournalSnapshot],
                         coverage: JournalQueryCoverage, filters: JournalQueryFilters) -> JournalQueryResult {
        let ordered = events.sorted { $0.sequence < $1.sequence }
        let timeline = buildTimeline(events: ordered, baselines: baselines,
                                     highWater: coverage.highWaterSequence)
        let filteredEvents = ordered.filter { eventMatches($0, filters: filters) }
        let filteredIntervals = timeline.intervals.filter { intervalMatches($0, filters: filters) }
        let overall = metric(intervals: filteredIntervals, events: filteredEvents, filters: filters)

        var sourceCounts: [String: Int] = [:]
        for event in filteredEvents where event.committedAtMs >= filters.fromMs && event.committedAtMs < filters.toMs {
            sourceCounts[event.draft.source.rawValue, default: 0] += 1
        }
        let resultCoverage = JournalQueryCoverage(
            retainedFromMs: coverage.retainedFromMs,
            firstAvailableSequence: coverage.firstAvailableSequence,
            highWaterSequence: coverage.highWaterSequence,
            incomplete: coverage.incomplete || timeline.incomplete,
            uncertainCount: coverage.uncertainCount + timeline.uncertainCount,
            censoredCount: coverage.censoredCount + timeline.censoredCount,
            sources: sourceCounts
        )

        var object = overallObject(metric: overall, filters: filters, coverage: resultCoverage)
        object["by_agent"] = groupedObject(
            keys: Set(filteredIntervals.map { $0.agent } + filteredEvents.map { $0.draft.agentKind }),
            intervals: filteredIntervals,
            events: filteredEvents,
            filters: filters,
            dimension: .agent
        )
        object["by_model"] = groupedObject(
            keys: Set(filteredIntervals.map { $0.model ?? "unknown" } + filteredEvents.map { $0.modelID ?? "unknown" }),
            intervals: filteredIntervals,
            events: filteredEvents,
            filters: filters,
            dimension: .model
        )
        object["by_workspace"] = groupedObject(
            keys: Set(filteredIntervals.map { $0.workspace ?? "unknown" } + filteredEvents.map {
                $0.draft.workspaceID?.uuidString ?? "unknown"
            }),
            intervals: filteredIntervals,
            events: filteredEvents,
            filters: filters,
            dimension: .workspace
        )

        return JournalQueryResult(object: object, humanText: humanText(metric: overall, filters: filters))
    }

    private static func groupedObject(
        keys: Set<String>, intervals: [TimelineInterval], events: [JournalEvent],
        filters: JournalQueryFilters, dimension: GroupDimension
    ) -> [String: Any] {
        var output: [String: Any] = [:]
        for group in keys.sorted() {
            let groupIntervals = intervals.filter { intervalGroupKey($0, dimension: dimension) == group }
            let groupEvents = events.filter { eventGroupKey($0, dimension: dimension, fallback: "unknown") == group }
            let groupMetric = metric(intervals: groupIntervals, events: groupEvents, filters: filters)
            output[group] = groupMetric.object(coveredHours: filters.coveredHours)
        }
        return output
    }

    private enum GroupDimension { case agent, model, workspace }

    private static func intervalGroupKey(_ interval: TimelineInterval, dimension: GroupDimension) -> String {
        switch dimension {
        case .agent: return interval.agent
        case .model: return interval.model ?? "unknown"
        case .workspace: return interval.workspace ?? "unknown"
        }
    }

    private static func eventGroupKey(_ event: JournalEvent, dimension: GroupDimension, fallback: String) -> String {
        switch dimension {
        case .agent: return event.draft.agentKind
        case .model: return event.modelID ?? fallback
        case .workspace: return event.draft.workspaceID?.uuidString ?? fallback
        }
    }

    private static func overallObject(metric: MetricAccumulator, filters: JournalQueryFilters,
                                      coverage: JournalQueryCoverage) -> [String: Any] {
        [
            "schema_version": 1,
            "units": [
                "duration": "ms",
                "blocked_minutes": "ms/60000",
                "rate": "per covered hour",
                "window": "[from,to)"
            ],
            "window": ["from_ms": filters.fromMs, "to_ms": filters.toMs],
            "coverage": coverage.object,
            "time_in_state_ms": metric.timeInState,
            "operator_response": metric.operatorResponseObject,
            "blocked_ms": metric.blockedObject,
            "turns": metric.turnsObject(coveredHours: filters.coveredHours),
            "errors": metric.errorsObject,
            "stalls": metric.stalls.map(\.object)
        ]
    }

    private static func humanText(metric: MetricAccumulator, filters: JournalQueryFilters) -> String {
        let time = phaseKeys.map { "\($0)=\(metric.timeInState[$0, default: 0])" }.joined(separator: " ")
        let blocked = blockedKeys.map { "\($0)=\(metric.blocked[$0, default: 0])" }.joined(separator: " ")
        let response = metric.operatorResponseObject
        let turns = metric.turnsObject(coveredHours: filters.coveredHours)
        let errors = metric.errorsObject
        let stallText = metric.stalls.map { stall in
            "duration_ms=\(stall.durationMs) threshold_ms=\(stall.thresholdMs) last_evidence_age_ms=\(stall.lastEvidenceAgeMs) source=\(stall.source) censored=\(stall.censored) ongoing=\(stall.ongoing)"
        }.joined(separator: ";")
        return [
            "units duration=ms blocked_minutes=ms/60000 rate=per covered hour window=[from,to)",
            "time_in_state_ms \(time) disconnected=\(metric.disconnected) unconfirmed=\(metric.unconfirmed) degraded=\(metric.degraded)",
            "operator_response status=\(response["status"] as? String ?? "unavailable") wait_ms=\(display(response["wait_ms"])) wait_count=\(response["wait_count"] ?? 0) resume_ms=\(display(response["resume_ms"])) resume_count=\(response["resume_count"] ?? 0) censored_count=\(response["censored_count"] ?? 0)",
            "blocked_ms \(blocked)",
            "turns started=\(turns["started"] ?? 0) completed=\(turns["completed"] ?? 0) interrupted=\(turns["interrupted"] ?? 0) ambiguous=\(turns["ambiguous"] ?? 0) covered_hours=\(turns["covered_hours"] ?? 0) per_hour=\(display(turns["per_hour"]))",
            "errors root=\(errors["root"] ?? 0) interrupts=\(errors["interrupts"] ?? 0) child_or_tool_diagnostic=\(errors["child_or_tool_diagnostic"] ?? 0)",
            "stalls \(stallText)"
        ].joined(separator: "\n")
    }

    private static func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return String(describing: value)
    }

    private static func eventMatches(_ event: JournalEvent, filters: JournalQueryFilters) -> Bool {
        if let agent = filters.agent, event.draft.agentKind != agent { return false }
        if let model = filters.model, event.modelID != model { return false }
        if let workspace = filters.workspace, event.draft.workspaceID != workspace { return false }
        return true
    }

    private static func intervalMatches(_ interval: TimelineInterval, filters: JournalQueryFilters) -> Bool {
        if let agent = filters.agent, interval.agent != agent { return false }
        if let model = filters.model, interval.model != model { return false }
        if let workspace = filters.workspace, interval.workspace != workspace.uuidString { return false }
        return true
    }

    private static func metric(intervals: [TimelineInterval], events: [JournalEvent],
                               filters: JournalQueryFilters) -> MetricAccumulator {
        var accumulator = MetricAccumulator(stallMs: filters.stallMs)
        for interval in intervals {
            accumulator.add(interval: interval, from: filters.fromMs, to: filters.toMs)
        }
        accumulator.add(events: events, from: filters.fromMs, to: filters.toMs)
        return accumulator
    }

    private struct TimelineBuild {
        var intervals: [TimelineInterval] = []
        var incomplete = false
        var uncertainCount = 0
        var censoredCount = 0
    }

    private struct ActiveInterval {
        let owner: JournalOwner
        let phase: JournalPhase
        let reason: JournalReason?
        let agent: String
        let model: String?
        let workspace: String?
        let source: JournalSource
        let connection: JournalConnection
        let confirmation: JournalConfirmation
        let health: JournalHealth
        let timingUncertain: Bool
        let startWall: Int64
        let startTick: UInt64
        let appInstanceID: UUID
        var lastEvidenceWall: Int64
        var lastEvidenceTick: UInt64

        func closed(at endWall: Int64, endTick: UInt64?, censored: Bool) -> TimelineInterval {
            let duration: Int64?
            let uncertain: Bool
            if endWall < startWall {
                duration = nil
                uncertain = true
            } else if startTick > 0, let endTick, endTick >= startTick {
                duration = Int64((endTick - startTick) / 1_000_000)
                uncertain = timingUncertain
            } else {
                duration = endWall - startWall
                uncertain = timingUncertain || startTick > 0 || (endTick ?? 0) > 0
            }
            return TimelineInterval(owner: owner, phase: phase, reason: reason, agent: agent, model: model,
                                    workspace: workspace, source: source, connection: connection,
                                    confirmation: confirmation, health: health, timingUncertain: uncertain,
                                    startWall: startWall, endWall: endWall, durationMs: duration,
                                    startTick: startTick, endTick: endTick, appInstanceID: appInstanceID,
                                    lastEvidenceWall: lastEvidenceWall, ongoing: false, censored: censored)
        }

        func open() -> TimelineInterval {
            TimelineInterval(owner: owner, phase: phase, reason: reason, agent: agent, model: model,
                             workspace: workspace, source: source, connection: connection,
                             confirmation: confirmation, health: health, timingUncertain: timingUncertain,
                             startWall: startWall, endWall: nil, durationMs: nil, startTick: startTick,
                             endTick: nil, appInstanceID: appInstanceID, lastEvidenceWall: lastEvidenceWall,
                             ongoing: true, censored: false)
        }
    }

    private struct TimelineInterval {
        let owner: JournalOwner
        let phase: JournalPhase
        let reason: JournalReason?
        let agent: String
        let model: String?
        let workspace: String?
        let source: JournalSource
        let connection: JournalConnection
        let confirmation: JournalConfirmation
        let health: JournalHealth
        let timingUncertain: Bool
        let startWall: Int64
        let endWall: Int64?
        let durationMs: Int64?
        let startTick: UInt64
        let endTick: UInt64?
        let appInstanceID: UUID
        let lastEvidenceWall: Int64
        let ongoing: Bool
        let censored: Bool
    }

    private static func buildTimeline(events: [JournalEvent], baselines: [JournalSnapshot],
                                      highWater: Int64) -> TimelineBuild {
        var result = TimelineBuild()
        let retained = events.filter { $0.draft.owner != nil && $0.sequence <= highWater }
        let grouped = Dictionary(grouping: retained, by: { $0.draft.owner!.key })
        let baselineByOwner: [String: JournalSnapshot] = Dictionary(uniqueKeysWithValues: baselines.compactMap { baseline in
            guard baseline.lastSequence <= highWater else { return nil }
            return (baseline.owner.key, baseline)
        })

        for rows in grouped.values {
            let orderedRows = rows.sorted { $0.sequence < $1.sequence }
            guard let ownerKey = orderedRows.first?.draft.owner?.key else { continue }
            var active: ActiveInterval?
            for event in orderedRows {
                var prior = active
                if let current = active, current.appInstanceID != event.appInstanceID {
                    let closed = current.closed(at: current.lastEvidenceWall,
                                                endTick: current.lastEvidenceTick, censored: true)
                    result.intervals.append(closed)
                    if closed.timingUncertain { result.uncertainCount += 1 }
                    if event.committedAtMs > current.lastEvidenceWall {
                        result.incomplete = true
                        result.uncertainCount += 1
                    }
                    result.censoredCount += 1
                    active = nil
                    prior = nil
                }

                guard let owner = event.draft.owner else { continue }
                guard event.effect == .applied, let phase = event.toPhase else {
                    if var current = active, current.appInstanceID == event.appInstanceID {
                        current.lastEvidenceWall = event.committedAtMs
                        current.lastEvidenceTick = event.observedTickNs
                        active = current
                    }
                    continue
                }

                if let current = active {
                    let closed = current.closed(at: event.committedAtMs,
                                                endTick: event.observedTickNs, censored: false)
                    result.intervals.append(closed)
                    if closed.timingUncertain { result.uncertainCount += 1 }
                    active = nil
                }

                let state = stateFor(event: event, prior: prior)
                active = ActiveInterval(owner: owner, phase: phase, reason: state.reason,
                                        agent: event.draft.agentKind, model: event.modelID,
                                        workspace: event.draft.workspaceID?.uuidString,
                                        source: event.draft.source, connection: state.connection,
                                        confirmation: state.confirmation, health: state.health,
                                        timingUncertain: state.timingUncertain,
                                        startWall: event.committedAtMs, startTick: event.observedTickNs,
                                        appInstanceID: event.appInstanceID,
                                        lastEvidenceWall: event.committedAtMs,
                                        lastEvidenceTick: event.observedTickNs)
            }

            let lastAppliedSequence = orderedRows.last(where: { $0.effect == .applied })?.sequence ?? 0
            if let baseline = baselineByOwner[ownerKey], baseline.lastSequence >= lastAppliedSequence {
                if let current = active, current.appInstanceID != baseline.appInstanceID {
                    let closed = current.closed(at: current.lastEvidenceWall,
                                                endTick: current.lastEvidenceTick, censored: true)
                    result.intervals.append(closed)
                    if closed.timingUncertain { result.uncertainCount += 1 }
                    result.censoredCount += 1
                }
                result.intervals.append(TimelineInterval(
                    owner: baseline.owner, phase: baseline.phase, reason: baseline.reason,
                    agent: baseline.owner.agentKind, model: baseline.modelID,
                    workspace: baseline.workspaceID?.uuidString, source: baseline.source,
                    connection: baseline.connection, confirmation: baseline.confirmation,
                    health: baseline.health, timingUncertain: baseline.timingUncertain,
                    startWall: baseline.sinceMs, endWall: nil, durationMs: nil,
                    startTick: baseline.observedTickNs, endTick: nil,
                    appInstanceID: baseline.appInstanceID, lastEvidenceWall: baseline.observedAtMs,
                    ongoing: true, censored: false))
            } else if let current = active {
                let open = current.open()
                result.intervals.append(open)
                if open.timingUncertain { result.uncertainCount += 1 }
            }
        }

        let present = Set(grouped.keys)
        for baseline in baselines where baseline.lastSequence <= highWater && !present.contains(baseline.owner.key) {
            result.intervals.append(TimelineInterval(
                owner: baseline.owner, phase: baseline.phase, reason: baseline.reason,
                agent: baseline.owner.agentKind, model: baseline.modelID,
                workspace: baseline.workspaceID?.uuidString, source: baseline.source,
                connection: baseline.connection, confirmation: baseline.confirmation,
                health: baseline.health, timingUncertain: baseline.timingUncertain,
                startWall: baseline.sinceMs, endWall: nil, durationMs: nil,
                startTick: baseline.observedTickNs, endTick: nil,
                appInstanceID: baseline.appInstanceID, lastEvidenceWall: baseline.observedAtMs,
                ongoing: true, censored: false
            ))
        }
        return result
    }

    private struct StateFlags {
        let reason: JournalReason?
        let connection: JournalConnection
        let confirmation: JournalConfirmation
        let health: JournalHealth
        let timingUncertain: Bool
    }

    private static func stateFor(event: JournalEvent, prior: ActiveInterval?) -> StateFlags {
        var connection = prior?.connection ?? .live
        var confirmation = prior?.confirmation ?? .confirmed
        var health = prior?.health ?? .ok
        switch event.draft.signal {
        case .connectionLost:
            connection = .disconnected
            confirmation = .unconfirmed
        case .adapterGap:
            health = .degraded
            confirmation = .unconfirmed
        case .adapterRecovered:
            health = .ok
        default:
            if event.draft.kind == .sessionEnded {
                connection = .disconnected
                confirmation = .unconfirmed
            } else {
                connection = .live
                confirmation = .confirmed
            }
        }
        let timingUncertain = prior?.timingUncertain == true || event.draft.timeQuality == .nativeLocal
            && event.draft.occurredAtMs == nil
        return StateFlags(reason: event.draft.reasonCode ?? prior?.reason,
                          connection: connection, confirmation: confirmation,
                          health: health, timingUncertain: timingUncertain)
    }

    private struct ResponseSample {
        let waitMs: Int64?
        let resumeMs: Int64?
        let ownerKey: String
        let agent: String
        let model: String?
        let workspace: String?
    }

    private struct Ask {
        let key: String
        let openedAtMs: Int64
        let eventID: UUID
        let ownerKey: String
        let agent: String
        let model: String?
        let workspace: String?
        var responded = false
        var resolved = false
    }

    private static func responseSamples(events: [JournalEvent], from: Int64, to: Int64) -> (samples: [ResponseSample], censored: Int) {
        var asks: [String: Ask] = [:]
        var samples: [ResponseSample] = []
        var censored = 0
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            guard let owner = event.draft.owner else { continue }
            if event.effect == .applied && !event.draft.isChild,
               [.approvalRequested, .questionRequested, .planReviewRequested].contains(event.draft.kind) {
                let key = event.draft.requestID ?? event.draft.eventID.uuidString
                asks[key] = Ask(key: key, openedAtMs: event.committedAtMs, eventID: event.draft.eventID,
                                ownerKey: owner.key, agent: event.draft.agentKind, model: event.modelID,
                                workspace: event.draft.workspaceID?.uuidString)
            }
            if event.draft.kind == .stateChanged, event.draft.signal == .operatorResponse,
               let request = event.draft.requestID, var ask = asks[request], ask.ownerKey == owner.key,
               !ask.responded {
                ask.responded = true
                asks[request] = ask
                let responseAt = event.draft.occurredAtMs ?? event.committedAtMs
                if responseAt >= from && responseAt < to {
                    samples.append(ResponseSample(waitMs: max(0, responseAt - ask.openedAtMs), resumeMs: nil,
                                                  ownerKey: owner.key, agent: ask.agent, model: ask.model,
                                                  workspace: ask.workspace))
                }
            }
            if event.draft.kind == .attentionResolved,
               let request = event.draft.requestID, var ask = asks[request], ask.ownerKey == owner.key,
               !ask.resolved {
                ask.resolved = true
                asks[request] = ask
                if event.draft.resolution == .resumed {
                    let resumedAt = event.draft.occurredAtMs ?? event.committedAtMs
                    if resumedAt >= from && resumedAt < to {
                        samples.append(ResponseSample(waitMs: nil, resumeMs: max(0, resumedAt - ask.openedAtMs),
                                                      ownerKey: owner.key, agent: ask.agent, model: ask.model,
                                                      workspace: ask.workspace))
                    }
                }
            }
        }
        for event in events where event.draft.kind == .stateChanged && event.draft.signal == .operatorResponse {
            guard let request = event.draft.requestID else { continue }
            if asks[request] == nil {
                let responseAt = event.draft.occurredAtMs ?? event.committedAtMs
                if responseAt >= from && responseAt < to { censored += 1 }
            }
        }
        return (samples, censored)
    }

    private struct MetricAccumulator {
        let stallMs: Int64
        var timeInState: [String: Int64] = Dictionary(uniqueKeysWithValues:
            (JournalQuery.phaseKeys + ["disconnected", "unconfirmed", "degraded"]).map { ($0, 0) })
        var disconnected: Int64 = 0
        var unconfirmed: Int64 = 0
        var degraded: Int64 = 0
        var blocked: [String: Int64] = Dictionary(uniqueKeysWithValues: JournalQuery.blockedKeys.map { ($0, 0) })
        var started = 0
        var completed = 0
        var interrupted = 0
        var ambiguous = 0
        var rootErrors = 0
        var interruptErrors = 0
        var diagnostics = 0
        var waitMs: Int64 = 0
        var waitCount = 0
        var resumeMs: Int64 = 0
        var resumeCount = 0
        var responseCensored = 0
        var stalls: [Stall] = []

        mutating func add(interval: TimelineInterval, from: Int64, to: Int64) {
            let overlap = intervalOverlap(interval, from: from, to: to)
            guard overlap > 0 else { return }
            if interval.connection == .disconnected {
                disconnected += overlap
                timeInState["disconnected", default: 0] += overlap
            }
            if interval.confirmation == .unconfirmed {
                unconfirmed += overlap
                timeInState["unconfirmed", default: 0] += overlap
            }
            if interval.health == .degraded {
                degraded += overlap
                timeInState["degraded", default: 0] += overlap
            }
            if interval.phase == .blocked {
                let key = interval.confirmation == .unconfirmed || interval.connection == .disconnected ? "unconfirmed" : (interval.reason?.rawValue ?? "question")
                blocked[JournalQuery.blockedKeys.contains(key) ? key : "unconfirmed", default: 0] += overlap
            }
            if interval.connection != .disconnected && interval.confirmation != .unconfirmed
                && interval.health != .degraded {
                timeInState[interval.phase.rawValue, default: 0] += overlap
            }
            if interval.phase == .working {
                let duration = intervalDuration(interval, from: from, to: to)
                if duration > stallMs {
                    stalls.append(Stall(durationMs: duration, thresholdMs: stallMs,
                                         lastEvidenceAgeMs: max(0, to - interval.lastEvidenceWall),
                                         source: interval.source.rawValue,
                                         censored: interval.censored, ongoing: interval.ongoing))
                }
            }
        }

        mutating func add(events: [JournalEvent], from: Int64, to: Int64) {
            let response = JournalQuery.responseSamples(events: events, from: from, to: to)
            for sample in response.samples {
                if let wait = sample.waitMs {
                    waitMs += wait
                    waitCount += 1
                }
                if let resume = sample.resumeMs {
                    resumeMs += resume
                    resumeCount += 1
                }
            }
            responseCensored += response.censored
            for event in events where event.committedAtMs >= from && event.committedAtMs < to {
                if event.draft.isChild || [.childSpawned, .childCompleted, .childFailed].contains(event.draft.kind) {
                    diagnostics += 1
                    continue
                }
                switch event.draft.kind {
                case .turnStarted where event.effect == .applied: started += 1
                case .turnCompleted where event.effect == .applied: completed += 1
                case .turnInterrupted where event.effect == .applied: interrupted += 1
                case .turnStarted where event.effect == .duplicateEvidence && event.effectReason.contains("ambiguous"):
                    ambiguous += 1
                case .errorReported where event.effect == .applied && event.draft.reasonCode == .sessionFailure:
                    rootErrors += 1
                case .errorReported, .turnInterrupted:
                    diagnostics += 1
                default: break
                }
            }
        }

        var operatorResponseObject: [String: Any] {
            [
                "status": waitCount > 0 ? "available" : "unavailable",
                "wait_ms": waitCount > 0 ? waitMs : NSNull(),
                "wait_count": waitCount,
                "resume_ms": resumeCount > 0 ? resumeMs : NSNull(),
                "resume_count": resumeCount,
                "censored_count": responseCensored
            ]
        }

        var errorsObject: [String: Any] {
            ["root": rootErrors, "interrupts": interruptErrors + interrupted, "child_or_tool_diagnostic": diagnostics]
        }

        func turnsObject(coveredHours: Double) -> [String: Any] {
            [
                "started": started, "completed": completed, "interrupted": interrupted,
                "ambiguous": ambiguous, "covered_hours": coveredHours,
                "per_hour": coveredHours > 0 ? Double(started) / coveredHours : NSNull()
            ]
        }

        var blockedObject: [String: Any] { blocked }

        func object(coveredHours: Double) -> [String: Any] {
            [
                "time_in_state_ms": timeInState,
                "operator_response": operatorResponseObject,
                "blocked_ms": blockedObject,
                "turns": turnsObject(coveredHours: coveredHours),
                "errors": errorsObject,
                "stalls": stalls.map(\.object)
            ]
        }
    }

    private struct Stall {
        let durationMs: Int64
        let thresholdMs: Int64
        let lastEvidenceAgeMs: Int64
        let source: String
        let censored: Bool
        let ongoing: Bool

        var object: [String: Any] {
            ["duration_ms": durationMs, "threshold_ms": thresholdMs,
             "last_evidence_age_ms": lastEvidenceAgeMs, "source": source,
             "censored": censored, "ongoing": ongoing]
        }
    }

    private static func intervalOverlap(_ interval: TimelineInterval, from: Int64, to: Int64) -> Int64 {
        let end = interval.endWall ?? to
        let start = max(from, interval.startWall)
        let clippedEnd = min(to, end)
        guard clippedEnd > start else { return 0 }
        let wallSpan = max(0, end - interval.startWall)
        if let duration = interval.durationMs, wallSpan > 0 {
            let wallOverlap = clippedEnd - start
            return max(0, Int64((Double(duration) * Double(wallOverlap) / Double(wallSpan)).rounded()))
        }
        return clippedEnd - start
    }

    private static func intervalDuration(_ interval: TimelineInterval, from: Int64, to: Int64) -> Int64 {
        intervalOverlap(interval, from: from, to: to)
    }
}

private extension JournalQueryFilters {
    var coveredHours: Double { Double(max(0, toMs - fromMs)) / 3_600_000.0 }
}

private extension JournalQueryCoverage {
    var object: [String: Any] {
        [
            "retained_from_ms": retainedFromMs as Any? ?? NSNull(),
            "first_available_sequence": firstAvailableSequence as Any? ?? NSNull(),
            "high_water_sequence": highWaterSequence,
            "incomplete": incomplete,
            "uncertain_count": uncertainCount,
            "censored_count": censoredCount,
            "sources": sources
        ]
    }
}
