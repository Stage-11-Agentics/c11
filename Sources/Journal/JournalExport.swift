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

/// Stable, body-free NDJSON export. Each record is encoded and written before
/// the next one is visited; the journal history is never retained in memory.
enum JournalExport {
    final class StreamWriter {
        private let handle: FileHandle
        private let coverage: JournalQueryCoverage
        private let filters: JournalQueryFilters
        private var cursor: Int64
        private var sawGap = false
        private var baselineGapWritten = false

        init(handle: FileHandle, coverage: JournalQueryCoverage, filters: JournalQueryFilters) throws {
            self.handle = handle
            self.coverage = coverage
            self.filters = filters
            let first = coverage.firstAvailableSequence ?? (coverage.highWaterSequence + 1)
            self.cursor = max(0, first - 1)
            try write([
                "record_type": "manifest",
                "export_version": 1,
                "fold_version": 1,
                "from": filters.fromMs,
                "to": filters.toMs,
                "first_available_sequence": coverage.firstAvailableSequence as Any? ?? NSNull(),
                "high_water_sequence": coverage.highWaterSequence,
                "coverage": coverageObject(coverage, incomplete: coverage.incomplete || first > 1),
                "filters": filtersObject(filters)
            ])
            if first > 1 {
                try gap(from: 1, to: first - 1, reason: "retention")
            }
        }

        /// Feed one bounded SQLite page. Sequence accounting includes rows
        /// outside the selected time/dimension filters so gaps remain visible.
        func consume(_ page: [JournalEvent]) throws {
            for event in page where event.sequence <= coverage.highWaterSequence {
                guard event.sequence > cursor else { continue }
                if event.sequence > cursor + 1 {
                    try gap(from: cursor + 1, to: event.sequence - 1, reason: "missing_sequence")
                }
                cursor = event.sequence
                guard event.committedAtMs >= filters.fromMs, event.committedAtMs < filters.toMs,
                      exportMatches(event, filters: filters) else { continue }
                try write(eventObject(event))
            }
        }

        /// Emit an explicit trailing gap when concurrent pruning or clear
        /// removes rows after the export's frozen high-water was captured.
        func finish(baselines: [JournalSnapshot]) throws {
            if cursor < coverage.highWaterSequence {
                try gap(from: cursor + 1, to: coverage.highWaterSequence, reason: "unavailable_after_snapshot")
            }
            for baseline in baselines.sorted(by: {
                ($0.owner.tabID.uuidString, $0.owner.agentKind, $0.owner.sessionID)
                    < ($1.owner.tabID.uuidString, $1.owner.agentKind, $1.owner.sessionID)
            }) {
                guard baseline.lastSequence <= coverage.highWaterSequence else {
                    if !baselineGapWritten {
                        try write(["record_type": "gap", "reason": "baseline_unavailable_at_cutoff",
                                   "high_water_sequence": coverage.highWaterSequence, "incomplete": true])
                        baselineGapWritten = true
                    }
                    continue
                }
                guard exportMatches(baseline, filters: filters) else { continue }
                try write(baselineObject(baseline))
            }
            try write(["record_type": "coverage_summary",
                       "high_water_sequence": coverage.highWaterSequence,
                       "incomplete": coverage.incomplete || sawGap || baselineGapWritten])
        }

        private func gap(from: Int64, to: Int64, reason: String) throws {
            guard to >= from else { return }
            sawGap = true
            try write(["record_type": "gap", "from_sequence": from, "to_sequence": to,
                       "reason": reason, "incomplete": true])
        }

        private func write(_ object: [String: Any]) throws {
            guard JSONSerialization.isValidJSONObject(object) else { throw JournalExportError.invalidRecord }
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            line.append(0x0A)
            try handle.write(contentsOf: line)
        }
    }

    static func openOutput(_ output: String?) throws -> (handle: FileHandle, path: String?) {
        guard let output else { return (FileHandle.standardOutput, nil) }
        guard !output.contains("://") else { throw JournalExportError.remoteOutput }
        let expanded = (output as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (try FileHandle(forWritingTo: url), url.path)
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

    private static func coverageObject(_ coverage: JournalQueryCoverage, incomplete: Bool) -> [String: Any] {
        [
            "retained_from_ms": coverage.retainedFromMs as Any? ?? NSNull(),
            "last_observation_ms": coverage.lastObservationMs as Any? ?? NSNull(),
            "first_available_sequence": coverage.firstAvailableSequence as Any? ?? NSNull(),
            "high_water_sequence": coverage.highWaterSequence,
            "incomplete": incomplete,
            "uncertain_count": coverage.uncertainCount,
            "censored_count": coverage.censoredCount,
            "sources": coverage.sources
        ]
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
            "panel_id": draft.tabID?.uuidString as Any? ?? NSNull(),
            // C11-337: legacy spelling, emitted beside panel_id.
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
            "panel_id": baseline.owner.tabID.uuidString,
            // C11-337: legacy spelling, emitted beside panel_id.
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
}
