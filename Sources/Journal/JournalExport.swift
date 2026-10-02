import Foundation

enum JournalExportError: Error, CustomStringConvertible {
    case invalidRecord
    case remoteOutput

    var description: String {
        switch self {
        case .invalidRecord: return "journal export: invalid record"
        case .remoteOutput: return "journal export: --output must be a local path"
        }
    }
}

/// Stable, body-free NDJSON export for dashboards and offline inspection.
enum JournalExport {
    static func encode(events: [JournalEvent], baselines: [JournalSnapshot],
                       coverage: JournalQueryCoverage, filters: JournalQueryFilters) throws -> Data {
        let ordered = events.filter { event in
            event.sequence <= coverage.highWaterSequence
                && event.committedAtMs >= filters.fromMs && event.committedAtMs < filters.toMs
                && exportMatches(event, filters: filters)
        }.sorted { $0.sequence < $1.sequence }
        let allRetained = events.filter { $0.sequence <= coverage.highWaterSequence }
            .sorted { $0.sequence < $1.sequence }
        var gaps: [[String: Any]] = []
        if let first = coverage.firstAvailableSequence, first > 1 {
            gaps.append([
                "record_type": "gap", "from_sequence": 1,
                "to_sequence": first - 1, "reason": "retention"
            ])
        }
        var sequenceCursor = coverage.firstAvailableSequence.map { $0 - 1 } ?? 0
        for event in allRetained {
            if event.sequence > sequenceCursor + 1 {
                gaps.append([
                    "record_type": "gap", "from_sequence": sequenceCursor + 1,
                    "to_sequence": event.sequence - 1, "reason": "missing_sequence"
                ])
            }
            sequenceCursor = event.sequence
        }
        let baselineUnavailable = baselines.contains { $0.lastSequence > coverage.highWaterSequence }
        var exportCoverage = coverageObject(coverage, retainedFromMs: coverage.retainedFromMs,
                                            baselineUnavailable: baselineUnavailable,
                                            incomplete: coverage.incomplete || !gaps.isEmpty)
        var lines: [Data] = []
        let manifest: [String: Any] = [
            "record_type": "manifest",
            "export_version": 1,
            "fold_version": 1,
            "from": filters.fromMs,
            "to": filters.toMs,
            "first_available_sequence": coverage.firstAvailableSequence as Any? ?? NSNull(),
            "high_water_sequence": coverage.highWaterSequence,
            "coverage": exportCoverage,
            "filters": filtersObject(filters)
        ]
        lines.append(try jsonLine(manifest))

        for gap in gaps { lines.append(try jsonLine(gap)) }
        for event in ordered {
            lines.append(try jsonLine(eventObject(event)))
        }

        let sortedBaselines = baselines.filter { baseline in
            guard baseline.lastSequence <= coverage.highWaterSequence else { return false }
            return exportMatches(baseline, filters: filters)
        }.sorted {
            ($0.owner.tabID.uuidString, $0.owner.agentKind, $0.owner.sessionID)
                < ($1.owner.tabID.uuidString, $1.owner.agentKind, $1.owner.sessionID)
        }
        for baseline in sortedBaselines {
            lines.append(try jsonLine(baselineObject(baseline)))
        }
        // The manifest is intentionally the first line. If a baseline was newer
        // than the frozen event cutoff, append an explicit coverage fact rather
        // than mixing that newer snapshot into this event cutoff.
        if baselineUnavailable {
            lines.append(try jsonLine([
                "record_type": "gap", "reason": "baseline_unavailable_at_cutoff",
                "high_water_sequence": coverage.highWaterSequence
            ]))
        }
        return lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
    }

    static func write(events: [JournalEvent], baselines: [JournalSnapshot],
                      coverage: JournalQueryCoverage, filters: JournalQueryFilters,
                      output: String?) throws -> Data? {
        let data = try encode(events: events, baselines: baselines, coverage: coverage, filters: filters)
        guard let output else { return data }
        guard !output.contains("://") else { throw JournalExportError.remoteOutput }
        let expanded = (output as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return nil
    }

    private static func exportMatches(_ event: JournalEvent, filters: JournalQueryFilters) -> Bool {
        if let agent = filters.agent, event.draft.agentKind != agent { return false }
        if let model = filters.model, event.modelID != model { return false }
        if let workspace = filters.workspace, event.draft.workspaceID != workspace { return false }
        return true
    }

    private static func exportMatches(_ baseline: JournalSnapshot, filters: JournalQueryFilters) -> Bool {
        if let agent = filters.agent, baseline.owner.agentKind != agent { return false }
        if let model = filters.model, baseline.modelID != model { return false }
        if let workspace = filters.workspace, baseline.workspaceID != workspace { return false }
        return true
    }

    private static func filtersObject(_ filters: JournalQueryFilters) -> [String: Any] {
        [
            "agent": filters.agent as Any? ?? NSNull(),
            "model": filters.model as Any? ?? NSNull(),
            "workspace": filters.workspace?.uuidString as Any? ?? NSNull(),
            "from_ms": filters.fromMs,
            "to_ms": filters.toMs,
            "stall_ms": filters.stallMs
        ]
    }

    private static func coverageObject(_ coverage: JournalQueryCoverage, retainedFromMs: Int64?,
                                      baselineUnavailable: Bool, incomplete: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "retained_from_ms": retainedFromMs as Any? ?? NSNull(),
            "first_available_sequence": coverage.firstAvailableSequence as Any? ?? NSNull(),
            "high_water_sequence": coverage.highWaterSequence,
            "incomplete": incomplete,
            "uncertain_count": coverage.uncertainCount,
            "censored_count": coverage.censoredCount,
            "sources": coverage.sources
        ]
        if baselineUnavailable { result["baseline_unavailable_at_cutoff"] = true }
        return result
    }

    private static func eventObject(_ event: JournalEvent) -> [String: Any] {
        let draft = event.draft
        return [
            "record_type": "event",
            "sequence": event.sequence,
            "event_id": draft.eventID.uuidString,
            "kind": draft.kind.rawValue,
            "fold_effect": event.effect.rawValue,
            "source": draft.source.rawValue,
            "adapter": draft.adapter.rawValue,
            "tab_id": draft.tabID?.uuidString as Any? ?? NSNull(),
            "workspace_id": draft.workspaceID?.uuidString as Any? ?? NSNull(),
            "agent_kind": draft.agentKind,
            "model_id": event.modelID as Any? ?? NSNull(),
            "session_id": draft.sessionID as Any? ?? NSNull(),
            "turn_id": draft.turnID as Any? ?? NSNull(),
            "request_id": draft.requestID as Any? ?? NSNull(),
            "tool_class": draft.toolClass?.rawValue as Any? ?? NSNull(),
            "reason_code": draft.reasonCode?.rawValue as Any? ?? NSNull(),
            "signal": draft.signal?.rawValue as Any? ?? NSNull(),
            "resolution": draft.resolution?.rawValue as Any? ?? NSNull(),
            "from_phase": event.fromPhase?.rawValue as Any? ?? NSNull(),
            "to_phase": event.toPhase?.rawValue as Any? ?? NSNull(),
            "from_since_ms": event.fromSinceMs as Any? ?? NSNull(),
            "occurred_at_ms": draft.occurredAtMs as Any? ?? NSNull(),
            "time_quality": draft.timeQuality.rawValue,
            "committed_at_ms": event.committedAtMs,
            "observed_tick_ns": event.observedTickNs,
            "app_instance_id": event.appInstanceID.uuidString
        ]
    }

    private static func baselineObject(_ baseline: JournalSnapshot) -> [String: Any] {
        [
            "record_type": "current_state",
            "tab_id": baseline.owner.tabID.uuidString,
            "agent_kind": baseline.owner.agentKind,
            "session_id": baseline.owner.sessionID,
            "workspace_id": baseline.workspaceID?.uuidString as Any? ?? NSNull(),
            "model_id": baseline.modelID as Any? ?? NSNull(),
            "phase": baseline.phase.rawValue,
            "reason": baseline.reason?.rawValue as Any? ?? NSNull(),
            "request_id": baseline.requestID as Any? ?? NSNull(),
            "turn_id": baseline.turnID as Any? ?? NSNull(),
            "turn_outcome": baseline.turnOutcome as Any? ?? NSNull(),
            "source": baseline.source.rawValue,
            "adapter": baseline.adapter.rawValue,
            "since_ms": baseline.sinceMs,
            "observed_at_ms": baseline.observedAtMs,
            "observed_tick_ns": baseline.observedTickNs,
            "app_instance_id": baseline.appInstanceID.uuidString,
            "last_applied_sequence": baseline.lastSequence,
            "confirmation": baseline.confirmation.rawValue,
            "connection": baseline.connection.rawValue,
            "health": baseline.health.rawValue,
            "timing_uncertain": baseline.timingUncertain
        ]
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw JournalExportError.invalidRecord }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
