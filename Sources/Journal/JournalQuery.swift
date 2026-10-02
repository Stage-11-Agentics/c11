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
    let lastObservationMs: Int64?
    let firstAvailableSequence: Int64?
    let highWaterSequence: Int64
    let incomplete: Bool
    let uncertainCount: Int
    let censoredCount: Int
    let sources: [String: Int]

    init(retainedFromMs: Int64?, firstAvailableSequence: Int64?, highWaterSequence: Int64,
         incomplete: Bool, uncertainCount: Int, censoredCount: Int, sources: [String: Int],
         lastObservationMs: Int64? = nil) {
        self.retainedFromMs = retainedFromMs
        self.lastObservationMs = lastObservationMs
        self.firstAvailableSequence = firstAvailableSequence
        self.highWaterSequence = highWaterSequence
        self.incomplete = incomplete
        self.uncertainCount = uncertainCount
        self.censoredCount = censoredCount
        self.sources = sources
    }
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
    static let maximumOwners = 4_096
    static let maximumGroupsPerDimension = 256
    static let maximumStallsPerGroup = 128

    static func evaluate(events: [JournalEvent], baselines: [JournalSnapshot],
                         coverage: JournalQueryCoverage, filters: JournalQueryFilters,
                         writerInstanceID: UUID? = nil) -> JournalQueryResult {
        let stream = Stream(baselines: baselines, coverage: coverage, filters: filters,
                            writerInstanceID: writerInstanceID)
        for event in events.sorted(by: { $0.sequence < $1.sequence }) { stream.consume(event) }
        return stream.finish()
    }

    /// Incremental fold used by the CLI. Retained events are never accumulated:
    /// state is one current segment and one open ask per owner, plus bounded
    /// metric/group accumulators.
    final class Stream {
        private struct OpenAsk {
            let key: String
            let openedAtMs: Int64
            let appInstanceID: UUID
            var responded = false
        }

        private struct WorkingStreak {
            let owner: JournalOwner
            let startWall: Int64
            let startTick: UInt64
            let appInstanceID: UUID
            var lastEvidenceWall: Int64
            var lastEvidenceTick: UInt64
            var agent: String
            var model: String?
            var workspace: String?
            var source: JournalSource
        }

        private struct OwnerState {
            var active: ActiveInterval?
            var workingStreak: WorkingStreak?
            var openAsk: OpenAsk?
            var closedAskKey: String?
            var lastAppliedSequence: Int64 = 0
        }

        private let baselinesByOwner: [String: JournalSnapshot]
        private let coverage: JournalQueryCoverage
        private let filters: JournalQueryFilters
        private let writerInstanceID: UUID?
        private let coveredFromMs: Int64
        private let coveredToMs: Int64
        private let coveredHours: Double
        private var owners: [String: OwnerState] = [:]
        private var expectedSequence: Int64
        private var overall: MetricAccumulator
        private var byAgent: [String: MetricAccumulator] = [:]
        private var byModel: [String: MetricAccumulator] = [:]
        private var byWorkspace: [String: MetricAccumulator] = [:]
        private var sourceCounts: [String: Int] = [:]
        private var incomplete: Bool
        private var uncertainCount: Int
        private var censoredCount: Int
        private var unknownThroughSequence: Int64 = 0
        private var aggregationTruncated = false
        private var finished = false

        init(baselines: [JournalSnapshot], coverage: JournalQueryCoverage,
             filters: JournalQueryFilters, writerInstanceID: UUID?) {
            let orderedBaselines = baselines.sorted { $0.owner.key < $1.owner.key }
            self.baselinesByOwner = Dictionary(
                orderedBaselines.prefix(JournalQuery.maximumOwners).map { ($0.owner.key, $0) },
                uniquingKeysWith: { _, newest in newest })
            self.coverage = coverage
            self.filters = filters
            self.writerInstanceID = writerInstanceID
            let start = max(filters.fromMs, coverage.retainedFromMs ?? filters.fromMs)
            let observationEnd = coverage.lastObservationMs.map { $0 == Int64.max ? $0 : $0 + 1 }
                ?? filters.toMs
            let observedEnd = writerInstanceID == nil ? observationEnd : filters.toMs
            let end = min(filters.toMs, observedEnd)
            self.coveredFromMs = start
            self.coveredToMs = max(start, end)
            self.coveredHours = Double(max(0, self.coveredToMs - self.coveredFromMs)) / 3_600_000.0
            self.expectedSequence = coverage.firstAvailableSequence ?? (coverage.highWaterSequence + 1)
            self.overall = MetricAccumulator()
            self.incomplete = coverage.incomplete
                || (coverage.firstAvailableSequence ?? 1) > 1
                || orderedBaselines.count > JournalQuery.maximumOwners
            self.aggregationTruncated = orderedBaselines.count > JournalQuery.maximumOwners
            self.uncertainCount = coverage.uncertainCount
            self.censoredCount = coverage.censoredCount
            if self.coveredFromMs > filters.fromMs || self.coveredToMs < filters.toMs {
                self.incomplete = true
            }
        }

        func consume(_ event: JournalEvent) {
            guard !finished, event.sequence <= coverage.highWaterSequence else { return }
            if event.sequence < expectedSequence { return }
            if event.sequence > expectedSequence {
                breakAtUnknownGap(through: event.sequence - 1)
            }
            expectedSequence = event.sequence + 1

            addEventMetrics(event)
            guard let owner = event.draft.owner else { return }
            guard owners[owner.key] != nil || owners.count < JournalQuery.maximumOwners else {
                incomplete = true
                aggregationTruncated = true
                return
            }
            var state = owners[owner.key] ?? OwnerState()

            if state.openAsk?.appInstanceID != nil, state.openAsk?.appInstanceID != event.appInstanceID {
                state.openAsk = nil
                state.closedAskKey = nil
            }
            if let active = state.active, active.appInstanceID != event.appInstanceID {
                close(active, at: active.lastEvidenceWall, tick: active.lastEvidenceTick, censored: true)
                state.active = nil
                if let streak = state.workingStreak {
                    finishWorkingStreak(&state, at: streak.lastEvidenceWall,
                                        tick: streak.lastEvidenceTick,
                                        censored: true, ongoing: false)
                }
                state.openAsk = nil
                state.closedAskKey = nil
                incomplete = true
            }

            if event.effect == .applied, !event.draft.isChild,
               [.approvalRequested, .questionRequested, .planReviewRequested].contains(event.draft.kind) {
                state.openAsk = OpenAsk(key: event.draft.requestID ?? event.draft.eventID.uuidString,
                                        openedAtMs: event.committedAtMs, appInstanceID: event.appInstanceID)
                state.closedAskKey = nil
            }

            if event.draft.kind == .stateChanged, event.draft.signal == .operatorResponse,
               event.draft.source == .c11, event.effect == .observation, !event.draft.isChild {
                let responseAt = event.draft.occurredAtMs ?? event.committedAtMs
                if let ask = state.openAsk, ask.appInstanceID == event.appInstanceID,
                   ask.key == event.draft.requestID {
                    if !ask.responded, responseAt >= ask.openedAtMs {
                        addResponse(event, at: responseAt, waitMs: responseAt - ask.openedAtMs, resumeMs: nil)
                        state.openAsk?.responded = true
                    } else if !ask.responded {
                        addCensoredResponse(event, at: responseAt)
                    }
                } else if state.closedAskKey != event.draft.requestID {
                    addCensoredResponse(event, at: responseAt)
                }
            }

            if event.effect == .applied, !event.draft.isChild,
               event.draft.kind == .attentionResolved,
               let ask = state.openAsk, ask.appInstanceID == event.appInstanceID,
               event.draft.requestID == ask.key {
                if event.draft.resolution == .resumed {
                    let resumedAt = event.draft.occurredAtMs ?? event.committedAtMs
                    addResponse(event, at: resumedAt, waitMs: nil, resumeMs: max(0, resumedAt - ask.openedAtMs))
                }
                state.openAsk = nil
                state.closedAskKey = ask.key
            }

            if event.effect == .applied, let phase = event.toPhase {
                let flags = JournalQuery.stateFor(event: event, prior: state.active)
                let owner = event.draft.owner!
                let next = ActiveInterval(owner: owner, phase: phase, reason: flags.reason,
                                          agent: event.draft.agentKind, model: event.modelID,
                                          workspace: event.draft.workspaceID?.uuidString,
                                          source: event.draft.source, connection: flags.connection,
                                          confirmation: flags.confirmation, health: flags.health,
                                          timingUncertain: flags.timingUncertain,
                                          startWall: event.committedAtMs, startTick: event.observedTickNs,
                                          appInstanceID: event.appInstanceID,
                                          lastEvidenceWall: event.committedAtMs,
                                          lastEvidenceTick: event.observedTickNs, turnID: event.draft.turnID)
                if let active = state.active, sameSegment(active, next) {
                    var refreshed = active
                    refreshed.lastEvidenceWall = event.committedAtMs
                    refreshed.lastEvidenceTick = event.observedTickNs
                    state.active = refreshed
                } else {
                    if let active = state.active {
                        close(active, at: event.committedAtMs, tick: event.observedTickNs, censored: false)
                    }
                    state.active = next
                }
                updateWorkingStreak(&state, event: event, phase: phase, flags: flags)
                state.lastAppliedSequence = event.sequence
            } else if var active = state.active, active.appInstanceID == event.appInstanceID {
                // Any committed row is an observation boundary for right-censoring,
                // even when the reducer correctly declines its state transition.
                active.lastEvidenceWall = event.committedAtMs
                active.lastEvidenceTick = event.observedTickNs
                state.active = active
                if var streak = state.workingStreak, streak.appInstanceID == event.appInstanceID {
                    streak.lastEvidenceWall = event.committedAtMs
                    streak.lastEvidenceTick = event.observedTickNs
                    state.workingStreak = streak
                }
            }
            owners[owner.key] = state
        }

        func finish() -> JournalQueryResult {
            guard !finished else { return makeResult() }
            finished = true
            if expectedSequence <= coverage.highWaterSequence {
                breakAtUnknownGap(through: coverage.highWaterSequence)
                expectedSequence = coverage.highWaterSequence + 1
            }
            var consumedBaselines = Set<String>()
            for baseline in baselinesByOwner.values.sorted(by: { $0.owner.key < $1.owner.key })
                where baseline.lastSequence <= coverage.highWaterSequence {
                var state = owners[baseline.owner.key] ?? OwnerState()
                guard baseline.lastSequence >= state.lastAppliedSequence else { continue }
                consumedBaselines.insert(baseline.owner.key)
                let activeMatches = state.active.map { segmentMatches($0, baseline: baseline) } ?? false
                var startWall = max(baseline.sinceMs, coverage.retainedFromMs ?? baseline.sinceMs)
                var startTick: UInt64 = 0
                var stateFlags = baseline
                if let active = state.active {
                    if active.appInstanceID == baseline.appInstanceID && activeMatches {
                        startWall = active.startWall
                        startTick = active.startTick
                    } else if active.appInstanceID == baseline.appInstanceID {
                        let boundary = max(active.lastEvidenceWall, baseline.observedAtMs)
                        close(active, at: boundary, tick: baseline.observedTickNs, censored: false)
                        state.active = nil
                        startWall = boundary
                        startTick = baseline.observedTickNs
                        incomplete = true
                    } else {
                        close(active, at: active.lastEvidenceWall, tick: active.lastEvidenceTick, censored: true)
                        state.active = nil
                        incomplete = true
                        startWall = max(startWall, baseline.observedAtMs)
                        startTick = baseline.observedTickNs
                    }
                }

                var observedAt = baseline.observedAtMs
                var observedTick = baseline.observedTickNs
                if let active = state.active, active.appInstanceID == baseline.appInstanceID,
                   active.lastEvidenceWall > observedAt {
                    observedAt = active.lastEvidenceWall
                    observedTick = active.lastEvidenceTick
                }
                stateFlags.observedAtMs = observedAt
                stateFlags.observedTickNs = observedTick

                let liveCurrent = baseline.lastSequence >= unknownThroughSequence
                    && writerInstanceID == baseline.appInstanceID
                    && baseline.connection == .live && baseline.confirmation == .confirmed
                    && baseline.health == .ok
                if !liveCurrent {
                    stateFlags.confirmation = .unconfirmed
                    stateFlags.connection = .disconnected
                }
                let segment = ActiveInterval(owner: stateFlags.owner, phase: stateFlags.phase,
                                             reason: stateFlags.reason, agent: stateFlags.owner.agentKind,
                                             model: stateFlags.modelID, workspace: stateFlags.workspaceID?.uuidString,
                                             source: stateFlags.source, connection: stateFlags.connection,
                                             confirmation: stateFlags.confirmation, health: stateFlags.health,
                                             timingUncertain: stateFlags.timingUncertain,
                                             startWall: startWall, startTick: startTick,
                                             appInstanceID: stateFlags.appInstanceID,
                                             lastEvidenceWall: observedAt,
                                             lastEvidenceTick: observedTick,
                                             turnID: stateFlags.turnID)
                if liveCurrent {
                    add(segment.open())
                    if stateFlags.phase == .working {
                        ensureWorkingStreak(&state, baseline: stateFlags, startWall: startWall,
                                            startTick: startTick)
                        finishWorkingStreak(&state, at: filters.toMs, tick: nil,
                                            censored: false, ongoing: true)
                    } else {
                        finishWorkingStreak(&state, at: observedAt,
                                            tick: observedTick,
                                            censored: false, ongoing: false)
                    }
                } else {
                    let end = max(startWall, observedAt)
                    add(segment.closed(at: end, endTick: observedTick, censored: true))
                    if stateFlags.phase == .working {
                        ensureWorkingStreak(&state, baseline: stateFlags, startWall: startWall,
                                            startTick: startTick)
                    }
                    finishWorkingStreak(&state, at: end, tick: observedTick,
                                        censored: true, ongoing: false)
                    incomplete = true
                }
                owners[baseline.owner.key] = state
            }
            let unavailableBaselines = Set(baselinesByOwner.values
                .filter { $0.lastSequence > coverage.highWaterSequence }.map { $0.owner.key })
            if !unavailableBaselines.isEmpty { incomplete = true }

            for (key, var state) in owners where !consumedBaselines.contains(key) {
                guard let active = state.active else { continue }
                if unavailableBaselines.contains(key) {
                    close(active, at: active.lastEvidenceWall, tick: active.lastEvidenceTick, censored: true)
                    finishWorkingStreak(&state, at: active.lastEvidenceWall,
                                        tick: active.lastEvidenceTick, censored: true, ongoing: false)
                    continue
                }
                if active.appInstanceID == writerInstanceID,
                   active.connection == .live, active.confirmation == .confirmed, active.health == .ok {
                    add(active.open())
                    if active.phase == .working {
                        ensureWorkingStreak(&state, active: active)
                        finishWorkingStreak(&state, at: filters.toMs, tick: nil,
                                            censored: false, ongoing: true)
                    }
                } else {
                    var restored = active
                    restored.connection = .disconnected
                    restored.confirmation = .unconfirmed
                    close(restored, at: active.lastEvidenceWall, tick: active.lastEvidenceTick, censored: true)
                    finishWorkingStreak(&state, at: active.lastEvidenceWall,
                                        tick: active.lastEvidenceTick, censored: true, ongoing: false)
                    incomplete = true
                }
            }
            for key in unavailableBaselines where owners[key]?.active == nil {
                censoredCount += 1
            }
            if byAgent.values.contains(where: \.stallsTruncated)
                || byModel.values.contains(where: \.stallsTruncated)
                || byWorkspace.values.contains(where: \.stallsTruncated) || overall.stallsTruncated {
                aggregationTruncated = true
            }
            if aggregationTruncated { incomplete = true }
            return makeResult()
        }

        private func makeResult() -> JournalQueryResult {
            let resultCoverage = JournalQueryCoverage(
                retainedFromMs: coverage.retainedFromMs,
                firstAvailableSequence: coverage.firstAvailableSequence,
                highWaterSequence: coverage.highWaterSequence,
                incomplete: incomplete, uncertainCount: uncertainCount,
                censoredCount: censoredCount, sources: sourceCounts,
                lastObservationMs: coverage.lastObservationMs)
            var object = overallObject(metric: overall, filters: filters, coverage: resultCoverage,
                                       coveredFromMs: coveredFromMs, coveredToMs: coveredToMs,
                                       coveredHours: coveredHours, aggregationTruncated: aggregationTruncated)
            object["by_agent"] = groupedObject(byAgent, coveredHours: coveredHours)
            object["by_model"] = groupedObject(byModel, coveredHours: coveredHours)
            object["by_workspace"] = groupedObject(byWorkspace, coveredHours: coveredHours)
            return JournalQueryResult(object: object,
                                      humanText: humanText(metric: overall, filters: filters, coveredHours: coveredHours))
        }

        private func addEventMetrics(_ event: JournalEvent) {
            guard event.committedAtMs >= coveredFromMs, event.committedAtMs < coveredToMs, matches(event) else { return }
            overall.add(event: event, from: coveredFromMs, to: coveredToMs)
            sourceCounts[event.draft.source.rawValue, default: 0] += 1
            addToGroups(event: event)
        }

        private func addResponse(_ event: JournalEvent, at time: Int64, waitMs: Int64?, resumeMs: Int64?) {
            guard time >= coveredFromMs, time < coveredToMs, matches(event) else { return }
            overall.addResponse(waitMs: waitMs, resumeMs: resumeMs, censored: false)
            addGroupedResponse(event, waitMs: waitMs, resumeMs: resumeMs, censored: false)
        }

        private func addCensoredResponse(_ event: JournalEvent, at time: Int64) {
            guard time >= coveredFromMs, time < coveredToMs, matches(event) else { return }
            overall.addResponse(waitMs: nil, resumeMs: nil, censored: true)
            addGroupedResponse(event, waitMs: nil, resumeMs: nil, censored: true)
        }

        private func addGroupedResponse(_ event: JournalEvent, waitMs: Int64?, resumeMs: Int64?, censored: Bool) {
            let agent = event.draft.agentKind
            let model = event.modelID ?? "unknown"
            let workspace = event.draft.workspaceID?.uuidString ?? "unknown"
            addResponseMetric(&byAgent, key: agent, event: event, waitMs: waitMs, resumeMs: resumeMs, censored: censored)
            addResponseMetric(&byModel, key: model, event: event, waitMs: waitMs, resumeMs: resumeMs, censored: censored)
            addResponseMetric(&byWorkspace, key: workspace, event: event, waitMs: waitMs, resumeMs: resumeMs, censored: censored)
        }

        private func addResponseMetric(_ values: inout [String: MetricAccumulator], key: String,
                                       event: JournalEvent, waitMs: Int64?, resumeMs: Int64?, censored: Bool) {
            guard ensureGroup(&values, key: key) else { return }
            values[key]!.addResponse(waitMs: waitMs, resumeMs: resumeMs, censored: censored)
        }

        private func addToGroups(event: JournalEvent) {
            addEventMetric(&byAgent, key: event.draft.agentKind, event: event)
            addEventMetric(&byModel, key: event.modelID ?? "unknown", event: event)
            addEventMetric(&byWorkspace, key: event.draft.workspaceID?.uuidString ?? "unknown", event: event)
        }

        private func addEventMetric(_ values: inout [String: MetricAccumulator], key: String, event: JournalEvent) {
            guard ensureGroup(&values, key: key) else { return }
            values[key]!.add(event: event, from: coveredFromMs, to: coveredToMs)
        }

        private func add(_ interval: TimelineInterval) {
            if interval.timingUncertain { uncertainCount += 1 }
            if interval.censored { censoredCount += 1 }
            guard matches(interval) else { return }
            overall.add(interval: interval, from: coveredFromMs, to: coveredToMs)
            addIntervalMetric(&byAgent, key: interval.agent, interval: interval)
            addIntervalMetric(&byModel, key: interval.model ?? "unknown", interval: interval)
            addIntervalMetric(&byWorkspace, key: interval.workspace ?? "unknown", interval: interval)
        }

        private func addIntervalMetric(_ values: inout [String: MetricAccumulator], key: String,
                                       interval: TimelineInterval) {
            guard ensureGroup(&values, key: key) else { return }
            values[key]!.add(interval: interval, from: coveredFromMs, to: coveredToMs)
        }

        private func ensureGroup(_ values: inout [String: MetricAccumulator], key: String) -> Bool {
            if values[key] != nil { return true }
            guard values.count < JournalQuery.maximumGroupsPerDimension else {
                aggregationTruncated = true
                return false
            }
            values[key] = MetricAccumulator()
            return true
        }

        private func close(_ active: ActiveInterval, at wall: Int64, tick: UInt64?, censored: Bool) {
            add(active.closed(at: wall, endTick: tick, censored: censored))
        }

        private func updateWorkingStreak(_ state: inout OwnerState, event: JournalEvent,
                                         phase: JournalPhase, flags: StateFlags) {
            let trustedWorking = phase == .working && flags.connection == .live
                && flags.confirmation == .confirmed && flags.health == .ok
            guard trustedWorking else {
                if state.workingStreak != nil {
                    finishWorkingStreak(&state, at: event.committedAtMs,
                                        tick: event.observedTickNs,
                                        censored: phase == .working, ongoing: false)
                }
                return
            }
            if var streak = state.workingStreak, streak.appInstanceID == event.appInstanceID {
                streak.lastEvidenceWall = event.committedAtMs
                streak.lastEvidenceTick = event.observedTickNs
                if event.committedAtMs < coveredToMs {
                    streak.agent = event.draft.agentKind
                    streak.model = event.modelID
                    streak.workspace = event.draft.workspaceID?.uuidString
                    streak.source = event.draft.source
                }
                state.workingStreak = streak
                return
            }
            if let streak = state.workingStreak {
                finishWorkingStreak(&state, at: streak.lastEvidenceWall,
                                    tick: streak.lastEvidenceTick,
                                    censored: true, ongoing: false)
            }
            state.workingStreak = WorkingStreak(
                owner: event.draft.owner!, startWall: event.committedAtMs,
                startTick: event.observedTickNs, appInstanceID: event.appInstanceID,
                lastEvidenceWall: event.committedAtMs, lastEvidenceTick: event.observedTickNs,
                agent: event.draft.agentKind, model: event.modelID,
                workspace: event.draft.workspaceID?.uuidString, source: event.draft.source)
        }

        private func ensureWorkingStreak(_ state: inout OwnerState, baseline: JournalSnapshot,
                                         startWall: Int64, startTick: UInt64) {
            guard baseline.phase == .working else { return }
            if var streak = state.workingStreak, streak.appInstanceID == baseline.appInstanceID {
                streak.lastEvidenceWall = baseline.observedAtMs
                streak.lastEvidenceTick = baseline.observedTickNs
                if baseline.observedAtMs < coveredToMs {
                    streak.agent = baseline.owner.agentKind
                    streak.model = baseline.modelID
                    streak.workspace = baseline.workspaceID?.uuidString
                    streak.source = baseline.source
                }
                state.workingStreak = streak
            } else {
                if let streak = state.workingStreak {
                    finishWorkingStreak(&state, at: streak.lastEvidenceWall,
                                        tick: streak.lastEvidenceTick,
                                        censored: true, ongoing: false)
                }
                state.workingStreak = WorkingStreak(
                    owner: baseline.owner, startWall: startWall, startTick: startTick,
                    appInstanceID: baseline.appInstanceID, lastEvidenceWall: baseline.observedAtMs,
                    lastEvidenceTick: baseline.observedTickNs, agent: baseline.owner.agentKind,
                    model: baseline.modelID, workspace: baseline.workspaceID?.uuidString,
                    source: baseline.source)
            }
        }

        private func ensureWorkingStreak(_ state: inout OwnerState, active: ActiveInterval) {
            guard active.phase == .working else { return }
            if state.workingStreak == nil {
                state.workingStreak = WorkingStreak(
                    owner: active.owner, startWall: active.startWall, startTick: active.startTick,
                    appInstanceID: active.appInstanceID, lastEvidenceWall: active.lastEvidenceWall,
                    lastEvidenceTick: active.lastEvidenceTick, agent: active.agent,
                    model: active.model, workspace: active.workspace, source: active.source)
            }
        }

        private func finishWorkingStreak(_ state: inout OwnerState, at endWall: Int64,
                                         tick endTick: UInt64?, censored: Bool, ongoing: Bool) {
            guard let streak = state.workingStreak else { return }
            state.workingStreak = nil
            let start = max(coveredFromMs, streak.startWall)
            let end = min(coveredToMs, max(streak.startWall, endWall))
            guard end > start else { return }
            var duration = end - start
            if start == streak.startWall, end == endWall, let endTick,
               endTick >= streak.startTick {
                duration = Int64((endTick - streak.startTick) / 1_000_000)
            }
            guard duration > filters.stallMs,
                  matches(agent: streak.agent, model: streak.model, workspace: streak.workspace) else { return }
            let stall = Stall(durationMs: duration, thresholdMs: filters.stallMs,
                              lastEvidenceAgeMs: max(0, coveredToMs - streak.lastEvidenceWall),
                              source: streak.source.rawValue, censored: censored, ongoing: ongoing)
            overall.add(stall: stall)
            addStallMetric(&byAgent, key: streak.agent, stall: stall)
            addStallMetric(&byModel, key: streak.model ?? "unknown", stall: stall)
            addStallMetric(&byWorkspace, key: streak.workspace ?? "unknown", stall: stall)
        }

        private func addStallMetric(_ values: inout [String: MetricAccumulator], key: String,
                                    stall: Stall) {
            guard ensureGroup(&values, key: key) else { return }
            values[key]!.add(stall: stall)
        }

        private func matches(agent: String, model: String?, workspace: String?) -> Bool {
            if let filter = filters.agent, agent != filter { return false }
            if let filter = filters.model, model != filter { return false }
            if let filter = filters.workspace, workspace != filter.uuidString { return false }
            return true
        }

        private func breakAtUnknownGap(through sequence: Int64) {
            incomplete = true
            unknownThroughSequence = max(unknownThroughSequence, sequence)
            for key in Array(owners.keys) {
                guard var state = owners[key] else { continue }
                if let active = state.active {
                    close(active, at: active.lastEvidenceWall, tick: active.lastEvidenceTick, censored: true)
                    state.active = nil
                }
                if let streak = state.workingStreak {
                    finishWorkingStreak(&state, at: streak.lastEvidenceWall,
                                        tick: streak.lastEvidenceTick,
                                        censored: true, ongoing: false)
                }
                if state.openAsk != nil { censoredCount += 1 }
                state.openAsk = nil
                owners[key] = state
            }
        }

        private func matches(_ event: JournalEvent) -> Bool { JournalQuery.eventMatches(event, filters: filters) }
        private func matches(_ interval: TimelineInterval) -> Bool { JournalQuery.intervalMatches(interval, filters: filters) }

        private func sameSegment(_ lhs: ActiveInterval, _ rhs: ActiveInterval) -> Bool {
            lhs.phase == rhs.phase && lhs.reason == rhs.reason && lhs.agent == rhs.agent
                && lhs.model == rhs.model && lhs.workspace == rhs.workspace && lhs.source == rhs.source
                && lhs.connection == rhs.connection && lhs.confirmation == rhs.confirmation
                && lhs.health == rhs.health && lhs.timingUncertain == rhs.timingUncertain
                && lhs.appInstanceID == rhs.appInstanceID && lhs.turnID == rhs.turnID
        }

        private func segmentMatches(_ segment: ActiveInterval, baseline: JournalSnapshot) -> Bool {
            segment.phase == baseline.phase && segment.reason == baseline.reason
                && segment.model == baseline.modelID
                && segment.workspace == baseline.workspaceID?.uuidString
                && segment.source == baseline.source && segment.connection == baseline.connection
                && segment.confirmation == baseline.confirmation && segment.health == baseline.health
        }

        private func groupedObject(_ values: [String: MetricAccumulator], coveredHours: Double) -> [String: Any] {
            values.mapValues { $0.object(coveredHours: coveredHours) }
        }
    }

    private static func overallObject(metric: MetricAccumulator, filters: JournalQueryFilters,
                                      coverage: JournalQueryCoverage, coveredFromMs: Int64? = nil,
                                      coveredToMs: Int64? = nil, coveredHours: Double? = nil,
                                      aggregationTruncated: Bool = false) -> [String: Any] {
        var coverageObject = coverage.object
        if let coveredFromMs { coverageObject["covered_from_ms"] = coveredFromMs }
        if let coveredToMs { coverageObject["covered_to_ms"] = coveredToMs }
        if let coveredHours { coverageObject["covered_hours"] = coveredHours }
        if aggregationTruncated { coverageObject["aggregation_truncated"] = true }
        return [
            "schema_version": 1,
            "units": [
                "duration": "ms",
                "blocked_minutes": "ms/60000",
                "rate": "per covered hour",
                "window": "[from,to)"
            ],
            "window": ["from_ms": filters.fromMs, "to_ms": filters.toMs],
            "coverage": coverageObject,
            "time_in_state_ms": metric.timeInState,
            "operator_response": metric.operatorResponseObject,
            "blocked_ms": metric.blockedObject,
            "turns": metric.turnsObject(coveredHours: coveredHours ?? filters.coveredHours),
            "errors": metric.errorsObject,
            "stalls": metric.stalls.map(\.object)
        ]
    }

    private static func humanText(metric: MetricAccumulator, filters: JournalQueryFilters,
                                  coveredHours: Double? = nil) -> String {
        let time = phaseKeys.map { "\($0)=\(metric.timeInState[$0, default: 0])" }.joined(separator: " ")
        let blocked = blockedKeys.map { "\($0)=\(metric.blocked[$0, default: 0])" }.joined(separator: " ")
        let response = metric.operatorResponseObject
        let turns = metric.turnsObject(coveredHours: coveredHours ?? filters.coveredHours)
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

    private struct ActiveInterval {
        let owner: JournalOwner
        let phase: JournalPhase
        let reason: JournalReason?
        let agent: String
        let model: String?
        let workspace: String?
        let source: JournalSource
        var connection: JournalConnection
        var confirmation: JournalConfirmation
        let health: JournalHealth
        let timingUncertain: Bool
        let startWall: Int64
        let startTick: UInt64
        let appInstanceID: UUID
        var lastEvidenceWall: Int64
        var lastEvidenceTick: UInt64
        let turnID: String?

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

    private struct MetricAccumulator {
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
        var stallsTruncated = false

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
        }

        mutating func add(stall: Stall) {
            if stalls.count < JournalQuery.maximumStallsPerGroup {
                stalls.append(stall)
            } else {
                stallsTruncated = true
            }
        }

        mutating func add(event: JournalEvent, from: Int64, to: Int64) {
            guard event.committedAtMs >= from, event.committedAtMs < to else { return }
            if event.draft.isChild || [.childSpawned, .childCompleted, .childFailed].contains(event.draft.kind) {
                diagnostics += 1
                return
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

        mutating func addResponse(waitMs: Int64?, resumeMs: Int64?, censored: Bool) {
            if let waitMs { self.waitMs += waitMs; waitCount += 1 }
            if let resumeMs { self.resumeMs += resumeMs; resumeCount += 1 }
            if censored { responseCensored += 1 }
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
        let wallOverlap = clippedEnd - start
        let coversWholeInterval = from <= interval.startWall
            && interval.endWall.map { $0 <= to } == true
        if coversWholeInterval, let duration = interval.durationMs {
            return max(0, duration)
        }
        // Monotonic ticks are authoritative for a complete observed interval.
        // A query boundary has only committed wall-clock evidence, so partial
        // clipping must use that wall span rather than inventing a tick rate.
        return wallOverlap
    }

}

private extension JournalQueryFilters {
    var coveredHours: Double { Double(max(0, toMs - fromMs)) / 3_600_000.0 }
}

private extension JournalQueryCoverage {
    var object: [String: Any] {
        [
            "retained_from_ms": retainedFromMs as Any? ?? NSNull(),
            "last_observation_ms": lastObservationMs as Any? ?? NSNull(),
            "first_available_sequence": firstAvailableSequence as Any? ?? NSNull(),
            "high_water_sequence": highWaterSequence,
            "incomplete": incomplete,
            "uncertain_count": uncertainCount,
            "censored_count": censoredCount,
            "sources": sources
        ]
    }
}
