import Foundation

/// Value-only copy. No Workspace, Panel, view, store or mutable collection
/// escapes the main-thread capture. Projection and encoding run on the worker.
struct FleetSnapshot {
    struct Panel {
        let windowId: UUID
        let workspaceId: UUID
        let workspaceTitle: String
        let panelId: UUID
        let panelTitle: String
        let detectedKind: String?
        let activity: SidebarActivityState?
        let cold: Bool
        let unreadNotification: Bool
        let journalAttention: Bool
        let parentPanelId: UUID?
        /// C11H-260: who made the panel; nil reads as `unknown`.
        var origin: PanelOrigin? = nil
        var originDetail: String? = nil
        let lastTurnEndedMs: Int64?
        let promptCache: PromptCacheObservation?
        let promptCacheUnknown: Bool
        let unreadMail: Int?
        /// When the oldest unread envelope landed (C11-550).
        var oldestUnreadMailAt: Date? = nil
        /// C11H-237: why the panel's waiting mail is not rung yet (`code`, `since`).
        var mailWaitCode: String? = nil
        var mailWaitSince: Date? = nil
        let lastSeenAt: Date?
        let beingSeen: Bool
        /// c11 (C11H-197): the window's operator-given name, if any.
        var windowName: String? = nil
        /// C11H-261: the waiting check's verdict on the panel's still-unread
        /// notification; nil when it has none or the notification was read.
        var waitingCheck: WaitingCheckVerdict? = nil
        var isCaptain: Bool = false
        /// C11H-320: the panel's journal state, copied on main.
        var journal: FleetAgentState.Journal? = nil
        /// C11H-320 PR 3: the panel's restore record after a host end, as
        /// `c11 restore status` prints it; nil when it has none.
        var restore: Restore? = nil
    }

    /// C11H-320 PR 3: one panel's restore record, the same tokens as
    /// `c11 restore status`, copied on main from `TerminalPanel.hcHostEnd`.
    struct Restore: Equatable {
        /// `resuming`, `resumed`, `needs_operator` or `skipped`.
        let outcome: String
        /// `restore status`'s `state`, `phase`, `reason` and `cause`.
        let state: String
        let phase: String
        let reason: String?
        let cause: String
        let signal: Int?
        let endedAt: Date
        let offersResume: Bool
        let conversationKind: String?

        init(_ status: HCHostEndStatus) {
            state = status.recordState
            phase = status.stateToken
            reason = status.reasonToken
            cause = status.causeToken
            signal = status.signal.map { Int($0) }
            endedAt = status.endedAt
            offersResume = status.offersResume
            conversationKind = status.conversation?.kind
            outcome = Self.outcome(needsOperator: status.needsOperator, state: status.recordState)
        }

        static func outcome(needsOperator: Bool, state: String) -> String {
            if needsOperator { return "needs_operator" }
            switch state {
            case "pending", "resuming": return "resuming"
            case "resumed": return "resumed"
            default: return "skipped"
            }
        }

        /// An agent row is kept for a seat whose agent has not come back yet:
        /// one still resuming, or one waiting for the operator.
        var holdsAgentRow: Bool { outcome == "needs_operator" || outcome == "resuming" }

        func jsonObject(_ dates: FleetDateText) -> [String: Any] {
            [
                "outcome": outcome,
                "state": state,
                "phase": phase,
                "reason": reason as Any? ?? NSNull(),
                "cause": cause,
                "signal": signal as Any? ?? NSNull(),
                "ended_at": dates.string(endedAt),
                "offers_resume": offersResume,
                "conversation_kind": conversationKind as Any? ?? NSNull(),
            ]
        }
    }

    /// C11H-320 PR 2: what every row of one workspace shares (its handle, its
    /// group, its resolved Captain), copied on main once per workspace and
    /// joined to the rows on the worker.
    struct WorkspaceFacts: Equatable {
        var ref: String? = nil
        var groupId: UUID? = nil
        var groupName: String? = nil
        var captain: String? = nil
        var captainPresent: Bool = false
    }

    /// C11H-320: the lock-guarded sources a row reads on the worker, behind
    /// seams so the projection is testable without the shared stores.
    struct ObservationSources {
        var report: (UUID) -> AgentReportStore.Entry? = { AgentReportStore.shared.entry(forPanel: $0) }
        var look: (UUID) -> FleetScreenLook? = { FleetScreenMonitor.shared.look(forPanel: $0) }
        var wait: (UUID) -> FleetAgentState.Wait? = { FleetAgentState.Wait(readback: SupervisorMonitor.shared.readback(panel: $0)) }
        var sweep: () -> FleetScreenMonitor.SweepStats? = { FleetScreenMonitor.shared.lastSweepStats }
        /// C11H-320 PR 3: the Supervisor's no-progress stall, the turn's
        /// start, the stall threshold, the harness's own context window and
        /// the catalog's.
        var stall: (UUID) -> FleetAgentState.SupervisorStall? = {
            FleetAgentState.SupervisorStall(readback: SupervisorMonitor.shared.readback(panel: $0))
        }
        var turnStartedMs: (UUID) -> Int64? = { JournalCoordinator.shared.cachedTurnStartedMs(panelID: $0) }
        var stallThreshold: () -> TimeInterval = { FleetAgentState.stallThreshold() }
        var contextWindow: (UUID) -> PromptCacheReportStore.HarnessWindow? = {
            PromptCacheReportStore.shared.slot(forPanel: $0)?.harnessWindow
        }
        /// The transcript's model and model epoch now (`TranscriptSignals`).
        var transcriptModel: (UUID) -> PromptCacheReportStore.ModelEvidence? = { panel in
            AgentModelDetector.shared.signals(forSurface: panel).map { .init(signals: $0) }
        }
        var catalogLimit: (_ model: String, _ agent: String) -> Int? = {
            FleetContextLimits.shared.limit(forModel: $0, agent: $1)
        }
        var edges: () -> AgentEdgeMonitor.RunStats? = { AgentEdgeMonitor.shared.lastRunStats }
        /// Keep message and input text, read now: a text kept before the
        /// switch went off is not shown.
        var keepText: () -> Bool = { EventEmitter.shared.keepText }
    }

    /// C11H-261: the waiting check's settings and Jev health, copied on main.
    struct WaitingCheckSummary {
        let enabled: Bool
        let showDoneButton: Bool
        let jevHealth: WaitingCheckJevHealth
        let doneCount: Int

        func jsonObject(formatter: ISO8601DateFormatter) -> [String: Any] {
            var since: Any = NSNull()
            var reason: Any = NSNull()
            if case .failing(let failingSince, let failure) = jevHealth {
                since = formatter.string(from: failingSince)
                reason = failure
            }
            return [
                "enabled": enabled,
                "show_done_button": showDoneButton,
                "jev": jevHealth.label,
                "jev_failing_since": since,
                "jev_failure": reason,
                "done_count": doneCount,
            ]
        }
    }

    struct Workspace {
        let windowId: UUID
        let id: UUID
        let title: String
        let captain: WorkspaceCaptainSummary

        var jsonObject: [String: Any] {
            var row = captain.jsonObject
            row["id"] = id.uuidString
            row["window_id"] = windowId.uuidString
            row["title"] = title
            return row
        }
    }

    /// C11H-299: a window-local workspace group and its own Captain's presence.
    /// Members with no Captain of their own resolve this one (`captain_scope`).
    struct WorkspaceGroupRow {
        let windowId: UUID
        let id: UUID
        let name: String
        let memberWorkspaceIds: [UUID]
        let captain: WorkspaceCaptainSummary

        var jsonObject: [String: Any] {
            var row = captain.presenceJSONObject
            row["id"] = id.uuidString
            row["window_id"] = windowId.uuidString
            row["name"] = name
            row["member_workspace_ids"] = memberWorkspaceIds.map(\.uuidString)
            return row
        }
    }

    let capturedAt: Date
    let metadata: PanelMetadataStore.ReadSnapshot
    let panels: [Panel]
    let workspaceCount: Int
    let windowCount: Int
    let mainCopyDurationMs: Double
    var waitingCheck: WaitingCheckSummary? = nil
    var workspaces: [Workspace] = []
    var workspaceGroups: [WorkspaceGroupRow] = []
    /// C11H-320 PR 2: per-workspace facts, and each agent row's `panel:N`.
    var workspaceFacts: [UUID: WorkspaceFacts] = [:]
    var panelRefs: [UUID: String] = [:]
    /// C11H-320 PR 2: the read's filters and delta cursor, refs resolved on main.
    var query = FleetQuery()
    /// C11H-320 PR 3: `restore status`'s summary over every terminal panel.
    var restoreSummary: HCRestoreProgress.Summary? = nil

    func document(observations: ObservationSources = ObservationSources(),
                  delta: FleetDeltaTracker? = .shared) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let dates = FleetDateText(formatter)
        let threshold = observations.stallThreshold()
        var limits: [String: Int?] = [:]
        var restoreDates: FleetDateText?
        let rows: [[String: Any]] = panels.compactMap { panel in
            let values = metadata.metadata[panel.workspaceId]?[panel.panelId] ?? [:]
            let sources = metadata.sources[panel.workspaceId]?[panel.panelId] ?? [:]
            var kind = PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: panel.detectedKind,
                declaredTerminalType: values[MetadataKey.terminalType] as? String
            )
            // PR 3: a seat whose agent has not come back after a host end keeps
            // its row (its terminal reads as a shell), so its restore shows.
            if !AreaSizePolicy.isAgentKind(kind), let restore = panel.restore, restore.holdsAgentRow,
               AreaSizePolicy.isAgentKind(restore.conversationKind) {
                kind = restore.conversationKind
            }
            guard AreaSizePolicy.isAgentKind(kind) else { return nil }
            let model = AgentModelPrecedence.effective(
                model: values[MetadataKey.model] as? String,
                modelSource: sources[MetadataKey.model]?.source,
                modelLabel: values[MetadataKey.modelLabel] as? String,
                labelSource: sources[MetadataKey.modelLabel]?.source,
                detected: values[AgentModelDetector.MetadataKeys.detected] as? String
            )
            let reason = values[MetadataKey.flag] as? String
            let delegated = values[MetadataKey.suppressed] as? Bool ?? false
            let activity = PanelActivityResolver.resolve(
                hasExactSurfaceNotification: panel.unreadNotification,
                hasJournalAttention: panel.journalAttention,
                derivedActivity: panel.activity, isCold: panel.cold,
                terminalType: kind, flagged: reason != nil, suppressed: delegated
            )
            let lifecycle: String?
            switch activity {
            case .running: lifecycle = "working"
            case .waiting: lifecycle = "waiting"
            case .idle: lifecycle = "idle"
            case .cold: lifecycle = "cold"
            case nil: lifecycle = nil
            }
            var flagKind: [String: Any]?
            if let kind = PanelFlagKind.fromJSON(values[MetadataKey.flagKind]) {
                flagKind = kind.jsonObject
                flagKind?["emoji"] = kind.emoji as Any? ?? NSNull()
            }
            let cache = TerminalController.promptCacheField(
                panel.promptCache, reportedUnknown: panel.promptCacheUnknown, now: capturedAt, formatter: formatter)
            let observed = FleetSnapshot.observationFields(
                panel: panel, sources: observations, now: capturedAt, dates: dates, threshold: threshold)
            // The harness's own number for its current model, else its own
            // catalog route, else null.
            let limit: (tokens: Int, source: String)?
            if let window = panel.promptCache?.contextWindow {
                limit = (window, "harness")
            } else if let window = observations.contextWindow(panel.panelId),
                      FleetSnapshot.windowIsCurrent(window, transcript: observations.transcriptModel(panel.panelId)) {
                limit = (window.tokens, "harness")
            } else if let id = model.model, let agent = kind {
                let memo = agent + "\u{1}" + id
                let tokens: Int?
                if let known = limits[memo] { tokens = known } else { tokens = observations.catalogLimit(id, agent); limits[memo] = tokens }
                limit = tokens.map { ($0, "catalog") }
            } else {
                limit = nil
            }
            var cacheFields = cache as? [String: Any]
            if cacheFields != nil {
                for key in ["basis", "lifetime_seconds", "requested_at", "cold_at", "reset", "prompt_tokens", "misses"]
                where cacheFields?[key] == nil { cacheFields?[key] = NSNull() }
            }
            let facts = workspaceFacts[panel.workspaceId]
            var row: [String: Any] = [
                "window_id": panel.windowId.uuidString,
                "window_name": panel.windowName as Any? ?? NSNull(),
                "workspace_id": panel.workspaceId.uuidString,
                "workspace_title": panel.workspaceTitle,
                "panel_id": panel.panelId.uuidString,
                "panel_title": panel.panelTitle,
                "is_captain": panel.isCaptain,
                "agent_type": kind as Any? ?? NSNull(),
                "model": model.model as Any? ?? NSNull(),
                "model_label": model.label as Any? ?? NSNull(),
                "lifecycle": lifecycle as Any? ?? NSNull(),
                "flag": reason != nil,
                "flag_reason": reason as Any? ?? NSNull(),
                "flag_kind": flagKind as Any? ?? NSNull(),
                "delegated": delegated,
                "delegated_by": values[MetadataKey.delegatedBy] as? String as Any? ?? NSNull(),
                "parent_panel_id": panel.parentPanelId?.uuidString as Any? ?? NSNull(),
                "origin": (panel.origin ?? .unknown).rawValue,
                "origin_detail": panel.originDetail as Any? ?? NSNull(),
                "last_turn_end": panel.lastTurnEndedMs.map {
                    formatter.string(from: Date(timeIntervalSince1970: Double($0) / 1000))
                } as Any? ?? NSNull(),
                "prompt_cache": cacheFields as Any? ?? NSNull(),
                "mailbox_address": values[MetadataKey.mailboxAddress] as? String as Any? ?? NSNull(),
                "mailbox_unread_count": panel.unreadMail as Any? ?? NSNull(),
                "mailbox_unread": FleetSnapshot.unreadField(
                    count: panel.unreadMail, oldestAt: panel.oldestUnreadMailAt, now: capturedAt, formatter: formatter,
                    waitCode: panel.mailWaitCode, waitSince: panel.mailWaitSince),
                "description": values[MetadataKey.description] as? String as Any? ?? NSNull(),
                "last_seen_at": panel.lastSeenAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
                "being_seen": panel.beingSeen,
                "waiting_check": panel.waitingCheck?.jsonObject as Any? ?? NSNull(),
                "panel_ref": panelRefs[panel.panelId] as Any? ?? NSNull(),
                "workspace_ref": facts?.ref as Any? ?? NSNull(),
                "workspace_group_id": facts?.groupId?.uuidString as Any? ?? NSNull(),
                "workspace_group_name": facts?.groupName as Any? ?? NSNull(),
                "workspace_captain": facts?.captain as Any? ?? NSNull(),
                "workspace_captain_present": facts?.captainPresent ?? false,
                "context": FleetSnapshot.contextField(promptTokens: panel.promptCache?.promptTokens, limit: limit),
                "restore": panel.restore.map { restore -> [String: Any] in
                    // `restore status` writes its times in the Mac's zone; so does this.
                    if restoreDates == nil {
                        let local = ISO8601DateFormatter()
                        local.timeZone = .current
                        restoreDates = FleetDateText(local)
                    }
                    return restore.jsonObject(restoreDates!)
                } as Any? ?? NSNull(),
            ]
            for (key, value) in observed { row[key] = value }
            return row
        }
        // Ask 6: every row's last change, seen against all rows before any filter.
        var byId: [UUID: [String: Any]] = [:]
        for row in rows { if let id = (row["panel_id"] as? String).flatMap(UUID.init(uuidString:)) { byId[id] = row } }
        let tracked = delta?.observe(byId, now: capturedAt)
        // A cursor this run cannot answer exactly (an earlier run's, say) reads every row.
        let full = query.since.map { since in tracked.map { $0.isFull(since) } ?? true } ?? false
        var shown: [[String: Any]] = []
        // Rows that changed after the cursor and no longer match the filters: a
        // watcher holding them drops them, as it drops an agent that is gone.
        var left: [UUID] = []
        for (id, var row) in byId {
            let change = tracked?.changes[id]
            row["changed_seq"] = change?.seq as Any? ?? NSNull()
            row["changed_at"] = dates.value(change?.at)
            let admitted = query.admits(row)
            if let since = query.since, !full, let change {
                let changedAfter: Bool
                switch since {
                case .seq(let seq): changedAfter = change.seq > seq
                case .time(let time): changedAfter = change.at > time
                }
                guard changedAfter else { continue }
                guard admitted else {
                    if query.hasFilters { left.append(id) }
                    continue
                }
            } else if !admitted {
                continue
            }
            shown.append(row)
        }
        var document: [String: Any] = [
            "schema_version": 1,
            "scope": "agents",
            "captured_at": formatter.string(from: capturedAt),
            "main_copy_duration_ms": mainCopyDurationMs,
            "serialization_on_main_thread": Thread.isMainThread,
            "window_count": windowCount,
            "workspace_count": workspaceCount,
            "workspaces": workspaces.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.jsonObject),
            "workspace_groups": workspaceGroups.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.jsonObject),
            "panels": shown.sorted { ($0["panel_id"] as? String ?? "") < ($1["panel_id"] as? String ?? "") },
            "waiting_check": waitingCheck?.jsonObject(formatter: formatter) as Any? ?? NSNull(),
            "screen_sweep": observations.sweep().map { stats -> [String: Any] in
                ["at": formatter.string(from: stats.at), "main_ms": stats.mainMs, "max_hop_ms": stats.maxHopMs,
                 "hops": stats.hops, "looked": stats.looked, "wanted": stats.wanted,
                 "headless_looked": stats.headlessLooked]
            } as Any? ?? NSNull(),
            "agent_edges": observations.edges().map { stats -> [String: Any] in
                ["at": formatter.string(from: stats.at), "agents": stats.agents, "ms": stats.ms]
            } as Any? ?? NSNull(),
            "fleet_seq": tracked?.seq as Any? ?? NSNull(),
            "restore_summary": restoreSummary.map { summary -> [String: Any] in
                ["total": summary.total, "pending": summary.pending, "resuming": summary.resuming,
                 "resumed": summary.resumed, "failed": summary.failed, "skipped": summary.skipped,
                 "need_you": summary.needYou, "finished": summary.isFinished]
            } as Any? ?? NSNull(),
        ]
        for (key, value) in sinceFields(tracked, full: full, left: left) { document[key] = value }
        return document
    }

    /// `since`, `full` and `removed_panel_ids` for a delta read; nothing otherwise.
    /// The removals are agents gone from the fleet, then rows that left the filters.
    private func sinceFields(_ tracked: FleetDeltaTracker.Read?, full: Bool, left: [UUID]) -> [String: Any] {
        guard let since = query.since else { return [:] }
        let removed: [FleetDeltaTracker.Removal]
        switch since {
        case _ where full: removed = []
        case .seq(let seq): removed = tracked?.removed.filter { $0.seq > seq } ?? []
        case .time(let time): removed = tracked?.removed.filter { $0.at > time } ?? []
        }
        let sinceValue: Any
        switch since {
        case .seq(let seq): sinceValue = seq
        case .time(let time): sinceValue = ISO8601DateFormatter().string(from: time)
        }
        let ids = removed.map(\.panelId.uuidString) + left.map(\.uuidString).sorted()
        return ["since": sinceValue, "full": full, "removed_panel_ids": ids]
    }
}

extension FleetSnapshot {
    /// C11H-320: `blocked`, `input`, `account`, `account_source`,
    /// `last_message` and `last_turn_stop` for one agent row. Every value is
    /// null when unknown, never guessed.
    static func observationFields(
        panel: Panel, sources: ObservationSources, now: Date, dates: FleetDateText,
        threshold: TimeInterval = FleetAgentState.stallThreshold()
    ) -> [String: Any] {
        let report = sources.report(panel.panelId)
        let journal = panel.journal
        let look = FleetAgentState.currentLook(sources.look(panel.panelId), journal: journal, now: now)
        let blocked = FleetAgentState.blocked(
            journal: journal, wait: sources.wait(panel.panelId), look: look, failure: report?.failure, now: now)
        let stalled = FleetAgentState.stalled(
            journal: journal, supervisor: sources.stall(panel.panelId), stop: report?.stop,
            turnStartedMs: sources.turnStartedMs(panel.panelId), blocked: blocked, now: now, threshold: threshold)
        let stop = FleetAgentState.lastTurnStop(journal: journal, failure: report?.failure)
        let keepText = sources.keepText()
        func iso(_ date: Date?) -> Any { dates.value(date) }
        return [
            "blocked": blocked.map { value -> [String: Any] in
                [
                    "reason": value.reason,
                    "since": iso(value.since),
                    "source": value.source,
                    "detail": value.detail as Any? ?? NSNull(),
                    "resets_at": iso(value.resetsAt),
                    "account": report?.account as Any? ?? NSNull(),
                ]
            } as Any? ?? NSNull(),
            "input": look.map { value -> [String: Any] in
                [
                    "state": value.state.rawValue,
                    "draft_length": value.draftLength as Any? ?? NSNull(),
                    "dialog_kind": value.dialogKind as Any? ?? NSNull(),
                    "since": iso(value.since),
                    "observed_at": iso(value.observedAt),
                ]
            } as Any? ?? NSNull(),
            "account": report?.account as Any? ?? NSNull(),
            "account_source": report?.accountSource as Any? ?? NSNull(),
            "last_message": report?.lastMessage.map { message -> [String: Any] in
                [
                    "text": (keepText ? message.text : nil) as Any? ?? NSNull(),
                    "chars": message.chars,
                    "at": iso(message.at),
                    "text_recorded": keepText && message.textRecorded,
                    "source": "claude_stop_hook",
                ]
            } as Any? ?? NSNull(),
            "background_tasks": report?.background.map { ["count": $0.count, "at": iso($0.at)] as [String: Any] }
                as Any? ?? NSNull(),
            "last_turn_stop": stop.map { value -> [String: Any] in
                ["reason": value.reason, "text": (keepText ? value.text : nil) as Any? ?? NSNull()]
            } as Any? ?? NSNull(),
            "stalled": stalled.map { value -> [String: Any] in
                [
                    "reason": value.reason,
                    "since": iso(value.since),
                    "detail": value.detail as Any? ?? NSNull(),
                    "threshold_seconds": value.thresholdSeconds,
                    "last_progress_at": iso(value.lastProgressAt),
                    "turn_ended_at": iso(value.turnEndedAt),
                ]
            } as Any? ?? NSNull(),
        ]
    }

    /// A reported window is used only with positive proof that it belongs to
    /// the agent's current model: it arrived after the transcript had named a
    /// model (an epoch), no model change has come since (the same epoch now),
    /// and its model is the one the transcript names now. Missing evidence
    /// anywhere means unused.
    static func windowIsCurrent(_ window: PromptCacheReportStore.HarnessWindow,
                                transcript: PromptCacheReportStore.ModelEvidence?) -> Bool {
        guard let bound = window.model, let arrived = window.epoch,
              let current = transcript?.model, let now = transcript?.epoch, now == arrived,
              PromptCacheReportStore.modelKey(bound) == PromptCacheReportStore.modelKey(current) else { return false }
        return true
    }

    /// C11H-320 PR 3: `{prompt_tokens, limit, fraction, limit_source}`, or
    /// null when neither is known. `fraction` needs both.
    static func contextField(promptTokens: Int?, limit: (tokens: Int, source: String)?) -> Any {
        guard promptTokens != nil || limit != nil else { return NSNull() }
        var fraction: Any = NSNull()
        if let promptTokens, let limit, limit.tokens > 0 {
            fraction = (Double(promptTokens) / Double(limit.tokens) * 1000).rounded() / 1000
        }
        return [
            "prompt_tokens": promptTokens as Any? ?? NSNull(),
            "limit": limit?.tokens as Any? ?? NSNull(),
            "fraction": fraction,
            "limit_source": limit?.source as Any? ?? NSNull(),
        ] as [String: Any]
    }

    /// `{count, oldest_at, oldest_age_seconds, reason, reason_since, reason_text}`
    /// from the cached mailbox counts; null when the panel's inbox has not been
    /// counted yet. `reason` is why the oldest unread is not rung yet (C11H-237),
    /// null with no unread mail or no hold seen. Never a body.
    static func unreadField(count: Int?, oldestAt: Date?, now: Date, formatter: ISO8601DateFormatter,
                            waitCode: String? = nil, waitSince: Date? = nil) -> Any {
        guard let count else { return NSNull() }
        let oldest = count > 0 ? oldestAt : nil
        let code = count > 0 ? waitCode : nil
        let since = code == nil ? nil : waitSince
        return [
            "count": count,
            "oldest_at": oldest.map { formatter.string(from: $0) } as Any? ?? NSNull(),
            "oldest_age_seconds": oldest.map { max(0, Int(now.timeIntervalSince($0).rounded(.down))) } as Any? ?? NSNull(),
            "reason": code as Any? ?? NSNull(),
            "reason_since": since.map { formatter.string(from: $0) } as Any? ?? NSNull(),
            "reason_text": code.map {
                MailboxReceiptStatus.waitText(code: $0, since: since, clock: .init(now: now, timeZone: .current))
            } as Any? ?? NSNull(),
        ] as [String: Any]
    }
}

extension TerminalController {
    /// A single async main copy is necessary for the live graph and its UI-owned
    /// caches. Everything else stays on the requesting worker, including JSON.
    nonisolated func v2FleetWorker(id: Any?, params: [String: Any], timeout: TimeInterval = 8) -> String {
        guard CapabilityFeatures.current.supports(.fleet) else {
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        // C11H-320 PR 2: optional filters and a delta cursor.
        let query: FleetQuery
        switch FleetQuery.parse(params) {
        case .success(let parsed): query = parsed
        case .failure(let error): return v2Error(id: id, code: "invalid_params", message: error.message)
        }
        FleetScreenMonitor.shared.noteFleetRead()
        // Initialize the registry before main capture (it may load manifests).
        _ = AgentIdentityPolicy.recognizedKinds
        let operation = SelectionReadOperation<FleetSnapshot>(timeout: timeout)
        let capture = {
            MainActor.assumeIsolated {
                guard operation.beginCapture() else { return }
                operation.complete(self.captureFleetSnapshot(query: query))
            }
        }
        if Thread.isMainThread { capture() } else { DispatchQueue.main.async(execute: capture) }
        guard let snapshot = operation.wait() else {
            return v2Error(id: id, code: "main_thread_timeout", message: String(
                localized: "browser.profile.error.mainThreadTimeout", defaultValue: "Main thread did not respond within deadline"))
        }
        if let message = snapshot.query.notFound {
            return v2Error(id: id, code: "not_found", message: message)
        }
        let response = v2Ok(id: id, result: snapshot.document())
        guard operation.canPublish else {
            return v2Error(id: id, code: "main_thread_timeout", message: String(
                localized: "browser.profile.error.mainThreadTimeout", defaultValue: "Main thread did not respond within deadline"))
        }
        return response
    }

    func captureFleetSnapshot(mailboxBadges: MailboxBadgeStore = .shared, query: FleetQuery = FleetQuery()) -> FleetSnapshot {
        let start = DispatchTime.now().uptimeNanoseconds
        let now = Date()
        let metadata = PanelMetadataStore.shared.readSnapshot()
        let workspaces = AppDelegate.shared?.fleetWorkspaces() ?? []
        let groups = AppDelegate.shared?.fleetWorkspaceGroups() ?? []
        let captains = WorkspaceCaptainCoordinator.capture(workspaces: workspaces, groups: groups, metadata: metadata)
        var panels: [FleetSnapshot.Panel] = []
        panels.reserveCapacity(workspaces.count * 4)
        let notificationStore = AppDelegate.shared?.notificationStore
        let waitingCheckEnabled = WaitingCheckSettings.isEnabled()
        let unreadNotificationIDs = Set(notificationStore?.notifications.filter { !$0.isRead }.map(\.id) ?? [])
        // C11H-320 PR 2: refs resolve only when a filter names one; rows get
        // their workspace's facts once per workspace and their `panel:N` from
        // one ledger read, so the per-row copy below is PR 1's.
        var query = query
        if query.workspace != nil || query.group != nil || query.parent != nil {
            Self.resolveFleetRefs(&query, workspaces: Set(workspaces.map(\.workspace.id)),
                                  groups: groups.map { (id: $0.group.id, name: $0.group.name) }) { self.v2ResolveHandleRef($0) }
        }
        var terminalPanelIds: [UUID] = []
        var restoreStatuses: [HCHostEndStatus] = []
        var workspaceFacts: [UUID: FleetSnapshot.WorkspaceFacts] = [:]
        for (windowId, workspace) in workspaces {
            let captain = captains.summary(for: workspace.id)
            workspaceFacts[workspace.id] = .init(
                ref: v2EnsureHandleRef(kind: .workspace, uuid: workspace.id), groupId: workspace.groupId,
                groupName: workspace.groupId.flatMap { id in groups.first { $0.group.id == id }?.group.name },
                captain: captain.address, captainPresent: captain.present)
            for panel in workspace.panels.values {
                guard panel.panelType == .terminal else { continue }
                let id = panel.id
                // PR 3: the restore record `restore status` prints, one property read.
                let hostEnd = (panel as? TerminalPanel)?.hcHostEnd
                if let hostEnd { restoreStatuses.append(hostEnd) }
                panels.append(.init(
                    windowId: windowId, workspaceId: workspace.id, workspaceTitle: workspace.title,
                    panelId: id, panelTitle: workspace.panelTitle(panelId: id) ?? panel.displayTitle,
                    detectedKind: workspace.detectedTerminalTypesByPanel[id],
                    activity: workspace.derivedActivityByPanel[id],
                    cold: workspace.coldAgentSurfaceIds.contains(id),
                    unreadNotification: AppDelegate.shared?.notificationStore?
                        .hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: id) ?? false,
                    journalAttention: workspace.journalByPanel[id]?.paintsAttention == true,
                    parentPanelId: PanelLineage.shared.parentPanelId(panelId: id),
                    origin: PanelLineage.shared.origin(panelId: id)?.origin,
                    originDetail: PanelLineage.shared.origin(panelId: id)?.detail,
                    lastTurnEndedMs: JournalCoordinator.shared.cachedLastTurnEndedMs(panelID: id),
                    promptCache: PromptCacheSources.observation(forPanel: id, now: now),
                    promptCacheUnknown: PromptCacheSources.reportsUnknown(forPanel: id),
                    unreadMail: mailboxBadges.knownSummary(panelId: id)?.unread,
                    oldestUnreadMailAt: mailboxBadges.knownSummary(panelId: id)?.oldestUnreadAt,
                    mailWaitCode: workspace.mailboxWaitByPanel[id]?.code,
                    mailWaitSince: workspace.mailboxWaitByPanel[id]?.since,
                    lastSeenAt: PanelSeenTracker.shared.lastSeenAt(panelId: id),
                    beingSeen: PanelSeenTracker.shared.isBeingSeen(panelId: id),
                    windowName: WindowAttributesStore.shared.name(for: windowId),
                    waitingCheck: waitingCheckEnabled
                        ? WaitingCheckJudge.latestVerdict(panelID: id).flatMap {
                            unreadNotificationIDs.contains($0.notificationID) ? $0 : nil
                        }
                        : nil,
                    isCaptain: captains.isCaptain(id),
                    journal: workspace.journalByPanel[id].map(FleetAgentState.Journal.init),
                    restore: hostEnd.map(FleetSnapshot.Restore.init)
                ))
                terminalPanelIds.append(id)
            }
        }
        let panelRefs = v2PanelRefs(terminalPanelIds)
        return FleetSnapshot(
            capturedAt: now, metadata: metadata, panels: panels,
            workspaceCount: workspaces.count, windowCount: Set(workspaces.map(\.windowId)).count,
            mainCopyDurationMs: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
            waitingCheck: FleetSnapshot.WaitingCheckSummary(
                enabled: waitingCheckEnabled,
                showDoneButton: WaitingCheckSettings.showsDoneButton(),
                jevHealth: WaitingCheckJudge.shared.jevHealth,
                doneCount: notificationStore?.doneCount ?? 0),
            workspaces: workspaces.map { windowId, workspace in
                .init(windowId: windowId, id: workspace.id, title: workspace.title,
                      captain: captains.summary(for: workspace.id))
            },
            workspaceGroups: groups.map { windowId, group in
                .init(windowId: windowId, id: group.id, name: group.name,
                      memberWorkspaceIds: workspaces.filter { $0.windowId == windowId && $0.workspace.groupId == group.id }
                        .map(\.workspace.id),
                      captain: captains.groupSummary(for: group.id))
            },
            workspaceFacts: workspaceFacts,
            panelRefs: panelRefs,
            query: query,
            restoreSummary: HCRestoreProgress.summary(restoreStatuses))
    }

    /// The filters' refs, resolved against what is live, as every other
    /// command resolves a ref (`resolve` is `v2ResolveHandleRef`: the handles
    /// `tree` prints, their old aliases, durable panel numbers).
    /// - `workspace`: a UUID or `workspace:N` naming a live workspace.
    /// - `group`: a UUID or `workspace_group:N` naming a live group, else a
    ///   group name (any case); a name several groups share selects them all.
    /// - `parent`: a panel UUID (a closed Captain's still selects its crew),
    ///   or a `panel:N` ref.
    /// A ref of another kind, or one naming nothing live, sets `notFound`;
    /// an existing workspace or group with no agents is still a success.
    nonisolated static func resolveFleetRefs(_ query: inout FleetQuery, workspaces: Set<UUID>,
                                             groups: [(id: UUID, name: String)], resolve: (String) -> UUID?) {
        func kind(_ raw: String) -> String? {
            let canonical = LegacyWireAliases.canonicalHandle(raw)
            guard let colon = canonical.firstIndex(of: ":") else { return nil }
            return canonical[..<colon].lowercased()
        }
        if let raw = query.workspace {
            let id = UUID(uuidString: raw) ?? (kind(raw) == V2HandleKind.workspace.rawValue ? resolve(raw) : nil)
            if let id, workspaces.contains(id) {
                query.workspaceId = id
            } else {
                let wrongKind = kind(raw).map { $0 != V2HandleKind.workspace.rawValue } ?? false
                query.notFound = wrongKind ? "\(raw) is not a workspace" : "No workspace \(raw)"
            }
        }
        if let raw = query.group {
            let live = Set(groups.map(\.id))
            var ids = Set<UUID>()
            if let id = UUID(uuidString: raw) ?? (kind(raw) == V2HandleKind.workspaceGroup.rawValue ? resolve(raw) : nil),
               live.contains(id) {
                ids = [id]
            } else {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ids = Set(groups.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name }.map(\.id))
            }
            if ids.isEmpty { query.notFound = query.notFound ?? "No workspace group \(raw)" }
            query.groupIds = ids
        }
        if let raw = query.parent {
            if let uuid = UUID(uuidString: raw) {
                query.parentId = uuid
            } else if kind(raw) == V2HandleKind.surface.rawValue, let id = resolve(raw) {
                query.parentId = id
            } else {
                let wrongKind = kind(raw).map { $0 != V2HandleKind.surface.rawValue } ?? false
                query.notFound = query.notFound ?? (wrongKind ? "\(raw) is not a panel" : "No panel \(raw)")
            }
        }
    }
}
