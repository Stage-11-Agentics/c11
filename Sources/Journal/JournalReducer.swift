import Foundation

struct JournalFoldResult {
    let snapshot: JournalSnapshot?
    let effect: JournalEffect
    let reason: String
    let fromPhase: JournalPhase?
    let fromSinceMs: Int64?
    var fromReason: JournalReason? = nil
}

enum JournalReducer {
    /// Sequence is the processing order, not proof that a delayed hook happened later.
    static func fold(previous: JournalSnapshot?, draft d: JournalDraft, sequence: Int64,
                     committedAtMs now: Int64, tick: UInt64, instanceID: UUID,
                     context: JournalContext) -> JournalFoldResult {
        func unchanged(_ effect: JournalEffect, _ reason: String) -> JournalFoldResult {
            JournalFoldResult(snapshot: previous, effect: effect, reason: reason, fromPhase: nil, fromSinceMs: nil)
        }
        guard !d.isChild, ![.childSpawned, .childCompleted, .childFailed].contains(d.kind) else {
            return unchanged(.child, "child_evidence")
        }
        guard context.eligible, let owner = d.owner else { return unchanged(.unattributed, "owner_unavailable") }
        guard d.adapter != .hcStatus || context.hcStatusEvidence else {
            return unchanged(.advisory, "unverified_hc_status")
        }
        guard d.nativeEvent != "other" else { return unchanged(.observation, "unknown_native_event") }
        var s = previous ?? JournalSnapshot(owner: owner, workspaceID: d.workspaceID, appInstanceID: instanceID)
        if !context.historical, d.source == .hook, d.adapter == .claudeHook, d.agentKind == "claude-code" {
            // An unverified/headless hook cannot lend an older process's
            // continuity to its newly projected state.
            s.runtimeIdentity = context.verifiedRuntimeIdentity
        }
        // Live priority belongs to one process. A historical transition after
        // restart must not carry the old process's live watermark into this run
        // and incorrectly suppress the remaining records in the same drain.
        if s.appInstanceID != instanceID {
            s.lastLiveSequence = 0
            s.lastLiveEmittedAtMs = 0
        }
        // Drain is historical: no old file can displace an event admitted live in this run.
        if context.historical && s.appInstanceID == instanceID && s.lastLiveSequence > 0 {
            return unchanged(.stale, "newer_live_evidence")
        }
        let nativeClockKey = context.verifiedNativeClock
            ? (JournalNativeClockEvidence.watermarkKey(for: d) ?? d.adapter.rawValue)
            : nil
        let comparable = context.verifiedNativeClock && d.timeQuality == .nativeLocal
            && d.occurredAtMs.map { $0 <= now + 300_000 } == true
        let nativeTime = comparable ? d.occurredAtMs : nil
        if let nativeTime, let nativeClockKey,
           let watermark = s.nativeWatermarks[nativeClockKey], nativeTime < watermark {
            return unchanged(.stale, "native_time_older")
        }
        if let activeTurn = s.turnID, let eventTurn = d.turnID, activeTurn != eventTurn,
           d.kind != .turnStarted && d.kind != .sessionStarted && d.adapter != .hcStatus {
            return unchanged(.stale, "different_turn")
        }
        let caps = d.adapter.capabilities
        let supportsTurn = caps.contains("turn")
        let supportsBlocked = caps.contains("blocked")
        let transcript = d.source == .transcript
        let fromPhase = s.phase
        let fromSince = s.sinceMs
        let fromReason = s.reason
        var reason = "state_transition"
        var preserveEvidence = false
        var evidenceOnly = false
        // C11H-123: when Codex's own signal ended a turn, on the Codex's clock.
        func noteCodexTurnEnd(_ snapshot: inout JournalSnapshot) {
            guard CodexTurnAuthority.isTurnSignal(d.adapter), d.agentKind == "codex",
                  [.turnCompleted, .turnInterrupted].contains(d.kind) else { return }
            let endedAt = d.occurredAtMs ?? d.emittedAtMs
            snapshot.nativeWatermarks[CodexTurnAuthority.turnEndKey] = max(
                snapshot.nativeWatermarks[CodexTurnAuthority.turnEndKey] ?? endedAt, endedAt)
        }
        func duplicate(_ reason: String) -> JournalFoldResult {
            guard !context.historical, d.source.rank >= s.rank else { return unchanged(.duplicateEvidence, reason) }
            var refreshed = s
            if s.phase == .idle { noteCodexTurnEnd(&refreshed) }
            RemoteClaudeTurnAuthority.noteHookEdge(d, in: &refreshed)
            refreshed.confirmation = .confirmed
            refreshed.connection = .live
            refreshed.observedAtMs = now
            refreshed.observedTickNs = tick
            refreshed.appInstanceID = instanceID
            refreshed.lastSequence = sequence
            refreshed.lastLiveSequence = sequence
            refreshed.lastLiveEmittedAtMs = d.emittedAtMs
            if d.source.rank > refreshed.rank {
                refreshed.source = d.source
                refreshed.adapter = d.adapter
                refreshed.rank = d.source.rank
                if s.terminalBarrier && [.turnCompleted, .turnInterrupted].contains(d.kind) {
                    refreshed.terminalRank = max(refreshed.terminalRank, d.source.rank)
                }
            }
            if let nativeTime, let nativeClockKey {
                refreshed.nativeWatermarks[nativeClockKey] = max(
                    refreshed.nativeWatermarks[nativeClockKey] ?? nativeTime, nativeTime
                )
            }
            return JournalFoldResult(snapshot: refreshed, effect: .duplicateEvidence, reason: reason, fromPhase: nil, fromSinceMs: nil)
        }

        switch d.kind {
        case .sessionStarted:
            guard caps.contains("session") else { return unchanged(.advisory, "unsupported_session") }
            // C11H-322: the panel's own interactive Claude (its process
            // verified behind the hook) reports its session start before it
            // reads a first prompt: that process is at its prompt. A relayed,
            // headless or drained start says nothing about the turn (C11-398).
            // A mid-turn `compact` start never reaches here (ClaudeHookMapping).
            let verifiedStart = !context.historical && context.verifiedRuntimeIdentity != nil
                && d.source == .hook && d.adapter == .claudeHook && d.agentKind == "claude-code"
            if let previous {
                // A row this process admitted live evidence for is the same
                // session, or one it saw end, which keeps its ended label,
                // unless a newly verified process started it again (a resume
                // after `/exit` or an outside signal): that process is at its
                // prompt. Any other row is a session resumed after a restart,
                // including one the startup spool drain restamped with its
                // SessionEnd: it re-attaches, at its prompt when verified and
                // otherwise unknown until the harness reports a turn edge.
                let liveInThisProcess = previous.appInstanceID == instanceID && previous.lastLiveSequence > 0
                let newProcess = verifiedStart && context.verifiedRuntimeIdentity != previous.runtimeIdentity
                guard !context.historical, !liveInThisProcess || newProcess else {
                    return unchanged(.observation, "session_already_known")
                }
                s.turnID = nil
                s.turnOutcome = nil
                s.requestID = nil
                s.reason = nil
                s.terminalBarrier = false
                s.terminalRank = 0
                if newProcess {
                    // Teardown evidence belongs to the newly verified process
                    // (C11H-271), never to the launch before it.
                    s.sessionEndedAtMs = nil
                    s.sessionEndedRootExit = nil
                }
                reason = liveInThisProcess ? "session_process_changed" : "session_reattached"
            } else {
                reason = "session_observed"
            }
            s.phase = verifiedStart ? .idle : .unknown
        case .sessionEnded:
            guard caps.contains("session") else { return unchanged(.advisory, "unsupported_session") }
            s.sessionEndedAtMs = d.emittedAtMs
            s.sessionEndedRootExit = context.historical ? nil : context.sessionEndRootExit
            s.connection = .disconnected
            s.confirmation = .unconfirmed
            s.runtimeIdentity = nil
            preserveEvidence = true
            reason = "session_disconnected"
        case .turnStarted:
            // C11H-123: a Return starts a turn only for a Codex whose own
            // signal ended its last turn (a Codex on another machine has no
            // turn-start signal); for any other agent it changes nothing.
            guard supportsTurn || (caps.contains("submit") && CodexTurnAuthority.turnEndMs(s) != nil) else {
                return unchanged(.advisory, "unsupported_turn")
            }
            if s.terminalBarrier, let turn = d.turnID, turn == s.turnID {
                return unchanged(.duplicateEvidence, "turn_already_terminal")
            }
            if s.phase == .blocked {
                // The existing native submission boundary is positive continuation;
                // tool/status activity is not. Missing IDs remain explicitly missing.
                let nativeSubmission = ["UserPromptSubmit", "chat.message"].contains(d.nativeEvent)
                let newTurn = d.turnID != nil && d.turnID != s.turnID
                guard !transcript, d.source.rank >= s.rank, nativeSubmission || newTurn else {
                    return unchanged(.advisory, "unresolved_request")
                }
            }
            if s.phase == .error && d.source.rank < s.rank { return unchanged(.advisory, "lower_confidence") }
            if transcript && s.terminalBarrier && s.terminalRank > d.source.rank {
                let newNativeTurn = d.turnID != nil && d.turnID != s.turnID
                let newerNativeTime = nativeTime.map { t in
                    guard let nativeClockKey else { return false }
                    return s.nativeWatermarks[nativeClockKey].map { t > $0 } ?? false
                } ?? false
                guard newNativeTurn || newerNativeTime else { return unchanged(.duplicateEvidence, "ambiguous_turn_start") }
            }
            if s.phase == .working && (d.turnID == nil || d.turnID == s.turnID) {
                return duplicate("turn_already_working")
            }
            s.phase = .working
            s.turnID = d.turnID
            s.turnOutcome = nil
            s.requestID = nil
            s.reason = nil
            s.terminalBarrier = false
            s.terminalRank = 0
        case .questionRequested, .planReviewRequested, .approvalRequested:
            guard supportsBlocked else { return unchanged(.advisory, "unsupported_blocked") }
            guard !s.terminalBarrier else { return unchanged(.advisory, "terminal_barrier") }
            if s.phase == .blocked && d.source.rank < s.rank { return unchanged(.advisory, "lower_confidence") }
            if s.phase == .error && d.source.rank < s.rank { return unchanged(.advisory, "lower_confidence") }
            let requestReason: JournalReason = d.kind == .questionRequested ? .question : (d.kind == .planReviewRequested ? .planReview : .approval)
            if s.phase == .blocked && s.requestID == d.requestID && s.reason == requestReason {
                return duplicate("request_already_blocked")
            }
            s.phase = .blocked
            s.reason = requestReason
            s.requestID = d.requestID
            s.turnID = d.turnID ?? s.turnID
            s.turnOutcome = nil
        case .attentionResolved:
            guard supportsBlocked, s.phase == .blocked, d.source.rank >= s.rank,
                  let request = d.requestID, request == s.requestID else {
                return unchanged(.advisory, "resolution_not_correlated")
            }
            s.phase = d.resolution == .resumed ? .working : (d.resolution == .cancelled ? .idle : .unknown)
            s.requestID = nil
            s.reason = nil
            s.terminalBarrier = d.resolution == .cancelled
            s.terminalRank = s.terminalBarrier ? d.source.rank : 0
        case .turnCompleted, .idleObserved:
            // C11H-123: the composer showed that the Return which started the
            // turn now running submitted nothing. Only that turn, while no
            // stronger evidence has moved it, goes back to idle; a Return
            // never ends a turn Codex or hc reported.
            if d.adapter == .keypress {
                guard d.kind == .idleObserved, CodexTurnAuthority.isReturnStartedTurn(s) else {
                    return unchanged(.advisory, "unsupported_turn")
                }
                s.phase = .idle
                s.turnOutcome = nil
                s.terminalBarrier = true
                s.terminalRank = d.source.rank
                reason = "return_started_nothing"
                break
            }
            guard supportsTurn else { return unchanged(.advisory, "unsupported_turn") }
            // C11H-123: a Codex turn end no later than the last one this
            // journal holds ended an earlier turn (a second delivery over the
            // link) and must not idle the turn now running. Both times are on
            // the Codex's own machine; this machine's clock is never compared.
            if CodexTurnAuthority.isTurnSignal(d.adapter), s.phase == .working,
               let lastEnd = CodexTurnAuthority.turnEndMs(s), (d.occurredAtMs ?? d.emittedAtMs) <= lastEnd {
                return unchanged(.stale, "turn_end_not_after_last")
            }
            // Claude cannot emit Stop while its same-turn permission prompt is pending.
            // An absent/mismatched turn or another adapter is not continuation evidence.
            let resolvesClaudeApproval = d.kind == .turnCompleted && d.adapter == .claudeHook
                && d.source == .hook && d.source.rank >= s.rank && s.reason == .approval
                && d.turnID != nil && d.turnID == s.turnID
            if resolvesClaudeApproval, let limit = s.usageLimit, limit.turnID == s.turnID {
                // Stop ends the wait, not the failure recorded beside it.
                s.phase = .error
                s.reason = .usageLimit
                s.requestID = nil
                s.turnOutcome = "interrupted"
                s.terminalBarrier = true
                s.terminalRank = d.source.rank
                break
            }
            if let limit = s.usageLimit {
                // Idle/duplicate Stop for the failed turn is not recovery.
                guard d.kind == .turnCompleted, s.phase == .working || resolvesClaudeApproval,
                      let turnID = s.turnID, turnID != limit.turnID else {
                    return unchanged(.advisory, "limit_without_successful_retry")
                }
            }
            guard s.phase != .blocked || resolvesClaudeApproval else { return unchanged(.advisory, "unresolved_request") }
            if resolvesClaudeApproval { s.requestID = nil; s.reason = nil }
            guard s.phase != .error || d.source.rank >= s.rank else { return unchanged(.advisory, "lower_confidence") }
            if s.terminalBarrier && s.phase == .idle { return duplicate("turn_already_terminal") }
            s.phase = .idle
            s.usageLimit = nil
            s.reason = nil
            s.turnOutcome = d.kind == .turnCompleted ? "completed" : nil
            s.turnID = d.turnID ?? s.turnID
            s.terminalBarrier = true
            s.terminalRank = d.source.rank
            noteCodexTurnEnd(&s)
        case .turnInterrupted:
            guard caps.contains("interrupt") else { return unchanged(.advisory, "unsupported_interrupt") }
            // Claude's marker is read up to 10 s late. Only the prompt id ties it
            // to the turn it ended; without that tie it could idle a newer turn.
            if d.adapter == .claudeTranscript, d.turnID == nil || d.turnID != s.turnID {
                return unchanged(.stale, "interrupt_not_correlated")
            }
            if s.phase == .blocked {
                // Transcript interruption does not prove that a pending request was cancelled.
                s.confirmation = .unconfirmed
                s.health = .degraded
                preserveEvidence = true
                reason = "interrupt_with_unresolved_request"
            } else {
                if s.terminalBarrier && s.turnOutcome == "interrupted" { return unchanged(.duplicateEvidence, "turn_already_terminal") }
                guard s.phase == .working else { return unchanged(.advisory, "interrupt_without_working_turn") }
                s.phase = .idle
                s.turnOutcome = "interrupted"
                s.terminalBarrier = true
                s.terminalRank = d.source.rank
                noteCodexTurnEnd(&s)
            }
        case .errorReported:
            guard caps.contains("error"), [.sessionFailure, .usageLimit].contains(d.reasonCode) else { return unchanged(.observation, "tool_or_unsupported_error") }
            if d.reasonCode == .usageLimit {
                // An approved tool leaves the turn blocked until it ends, because no
                // hook reports the answer. A limit recorded after the prompt opened
                // is shown beside the wait: it cannot prove the prompt was answered,
                // since a background child's prompt can still be open.
                let beside = s.phase == .blocked && s.reason == .approval && (d.occurredAtMs ?? 0) > s.sinceMs
                guard let kind = d.usageLimit, let turnID = d.turnID, turnID == s.turnID,
                      d.adapter == .claudeTranscript, context.verifiedNativeClock,
                      [.working, .error].contains(s.phase) || beside else {
                    return unchanged(.stale, "limit_not_correlated")
                }
                if s.usageLimit?.turnID == turnID, s.usageLimit?.kind == kind {
                    return duplicate("limit_already_observed")
                }
                s.usageLimit = JournalUsageLimit(kind: kind, turnID: turnID, sinceMs: now)
                if beside {
                    preserveEvidence = true
                    reason = "limit_beside_wait"
                    break
                }
            } else if s.phase == .error {
                return duplicate("error_already_observed")
            }
            if s.phase == .blocked && d.source.rank < s.rank { return unchanged(.advisory, "lower_confidence") }
            s.phase = .error
            // A session failure that ends a wait is the limit already seen on this turn.
            s.reason = s.usageLimit.map { $0.turnID == s.turnID } == true ? .usageLimit : d.reasonCode
            if s.reason == .usageLimit { s.turnOutcome = "interrupted" }
            s.terminalBarrier = true
            s.terminalRank = d.source.rank
        case .stateChanged:
            switch d.signal {
            case .hcWorking, .hcBlocked, .hcIdle, .hcDone, .hcError:
                guard d.adapter == .hcStatus, context.hcStatusEvidence else {
                    return unchanged(.advisory, "unverified_hc_status")
                }
                // hc retains the current root word, not a log of provider turns.
                // Its counter also advances on blocked/idle/clear, so no counter
                // delta is translated into synthetic starts or completions.
                if let time = d.occurredAtMs, let prior = s.nativeWatermarks["hc-status"], time < prior {
                    return unchanged(.stale, "hc_status_older")
                }
                // C11H-123: once Codex's own signal has ended a turn, hc's
                // word is a hint dated by hc's time; otherwise rank decides.
                let word: String? = d.signal == .hcWorking ? "working" : (d.signal == .hcBlocked ? "blocked" : nil)
                if let turnEnd = CodexTurnAuthority.turnEndMs(s) {
                    if CodexTurnAuthority.hcWordIsStale(word, hcStampMs: d.occurredAtMs, turnEndMs: turnEnd) {
                        return unchanged(.stale, "hc_status_older_than_turn_end")
                    }
                } else if !RemoteClaudeTurnAuthority.hcEndsHookTurn(d, snapshot: s) {
                    guard s.adapter == .hcStatus || s.rank <= d.source.rank else {
                        return unchanged(.advisory, "lower_confidence")
                    }
                }
                let phase: JournalPhase
                switch d.signal {
                case .hcWorking: phase = .working
                case .hcBlocked: phase = .blocked
                case .hcError: phase = .error
                default: phase = .idle
                }
                // Same word and same hc turn is one status epoch (hc's counter
                // advances on every departure from working). A re-observation
                // without the owning host's time (stripped mirror, resnapshot,
                // relaunch) adds no evidence and must not erase a verified one.
                if d.occurredAtMs == nil, s.adapter == .hcStatus, s.phase == phase,
                   s.turnID == d.turnID, s.nativeWatermarks["hc-status"] != nil {
                    return duplicate("hc_status_unchanged")
                }
                let outcome = d.signal == .hcDone && d.occurredAtMs != nil ? "completed" : nil
                if s.adapter == .hcStatus, s.phase == phase, s.turnID == d.turnID,
                   s.turnOutcome == outcome, s.nativeWatermarks["hc-status"] == d.occurredAtMs {
                    return duplicate("hc_status_unchanged")
                }
                s.phase = phase
                s.reason = phase == .blocked || phase == .error ? .observation : nil
                s.requestID = nil // OSC state alone supplies no permission/request identity.
                s.turnID = d.turnID
                s.turnOutcome = outcome
                s.terminalBarrier = phase == .idle || phase == .error
                s.terminalRank = s.terminalBarrier ? d.source.rank : 0
                if let time = d.occurredAtMs { s.nativeWatermarks["hc-status"] = time }
                // Keep the host's retained time for Feed; never substitute the
                // reconnect time for a completed turn. Remote clocks are not
                // asserted to be synchronized with this machine.
                // A timeless report of the phase already shown keeps its time.
                s.sinceMs = d.occurredAtMs ?? (fromPhase == phase ? s.sinceMs : 0)
                reason = "hc_status_observed"
            case .toolActivity:
                guard supportsTurn, s.phase == .working, !s.terminalBarrier else { return unchanged(.advisory, "tool_cannot_start_turn") }
                evidenceOnly = true
                reason = "working_refreshed"
            case .connectionLost:
                guard d.source == .c11 else { return unchanged(.advisory, "unsupported_control") }
                s.connection = .disconnected
                s.confirmation = .unconfirmed
                preserveEvidence = true
                reason = "connection_lost"
            case .adapterGap, .adapterRecovered:
                guard d.source == .c11 else { return unchanged(.advisory, "unsupported_control") }
                s.health = d.signal == .adapterGap ? .degraded : .ok
                preserveEvidence = true
                reason = d.signal!.rawValue
            case .operatorResponse:
                guard d.source == .c11, let request = d.requestID, request == s.requestID else {
                    return unchanged(.advisory, "response_not_correlated")
                }
                // Q2 records a correlated response, but the agent still owns resolution.
                return unchanged(.observation, "operator_response")
            default: return unchanged(.observation, "nonsemantic_observation")
            }
        case .childSpawned, .childCompleted, .childFailed, .messagePublished:
            return unchanged(.observation, "diagnostic_only")
        }

        if d.adapter != .hcStatus && (fromPhase != s.phase || previous == nil || (d.kind == .turnStarted && s.turnID != previous?.turnID)
            || (s.phase == .blocked && (s.requestID != previous?.requestID || s.reason != previous?.reason))) {
            s.sinceMs = now
        }
        if !preserveEvidence {
            s.connection = context.historical ? .disconnected : .live
            s.confirmation = context.historical ? .unconfirmed : .confirmed
            if !evidenceOnly || d.source.rank >= s.rank {
                s.source = d.source
                s.adapter = d.adapter
                s.rank = d.source.rank
            }
        }
        if let nativeTime, let nativeClockKey {
            s.nativeWatermarks[nativeClockKey] = max(s.nativeWatermarks[nativeClockKey] ?? nativeTime, nativeTime)
        }
        RemoteClaudeTurnAuthority.noteHookEdge(d, in: &s)
        if d.timeQuality != .missing && !comparable { s.timingUncertain = true }
        if now < s.observedAtMs { s.timingUncertain = true; s.health = .degraded }
        s.observedAtMs = now
        s.observedTickNs = tick
        s.lastSequence = sequence
        s.appInstanceID = instanceID
        s.workspaceID = d.workspaceID
        s.modelID = context.modelID
        if !context.historical { s.lastLiveSequence = sequence; s.lastLiveEmittedAtMs = d.emittedAtMs }
        return JournalFoldResult(snapshot: s, effect: .applied, reason: reason,
                                 fromPhase: previous == nil ? nil : fromPhase, fromSinceMs: previous == nil ? nil : fromSince,
                                 fromReason: previous == nil ? nil : fromReason)
    }
}

/// C11H-123: a Codex panel's turn comes from Codex's own turn signal (its
/// notify turn-complete, or its rollout transcript), never from hc alone. hc
/// keeps the last OSC 7501 record a program sent, and Codex reports `working`
/// for as long as a background terminal runs, long after its turn ended. So
/// hc's word is a hint, dated by hc's own status time: a `working` or
/// `blocked` with no hc time, or with a time at or before Codex's last turn
/// end, is stale. hc's `idle` still applies. A panel with no Codex turn
/// signal has no turn end recorded here and keeps hc's word as before.
/// C11H-134: a Claude on another machine reports its turn edges through its
/// relayed hooks, attributed to the panel's hc owner, and they outrank hc.
/// Claude fires no hook when Escape interrupts a turn, and the transcript that
/// recovers a local Claude is not on this machine. So hc's `idle` (or `done`),
/// dated by hc's own time on that machine after the last hook edge (stamped on
/// the same machine when the hook ran), ends a turn the hooks left working.
/// Only a working turn: a blocked ask waits for its answer, and hc's
/// `working` or `blocked` never displaces a hook edge. Without an hc time, or
/// at or before the last hook edge, hc's word is stale. A local Claude, whose
/// owner is its own session, is untouched.
enum RemoteClaudeTurnAuthority {
    /// When a relayed hook last moved this panel, on the agent machine's clock.
    static let hookEdgeKey = "remote-claude-hook-edge"

    static func isRemoteClaude(_ owner: JournalOwner) -> Bool {
        owner.agentKind == "claude-code" && owner.sessionID.hasPrefix("hc-")
    }

    static func hookEdgeMs(_ snapshot: JournalSnapshot?) -> Int64? {
        guard let snapshot, isRemoteClaude(snapshot.owner) else { return nil }
        return snapshot.nativeWatermarks[hookEdgeKey]
    }

    static func noteHookEdge(_ draft: JournalDraft, in snapshot: inout JournalSnapshot) {
        guard draft.adapter == .claudeHook, isRemoteClaude(snapshot.owner) else { return }
        let at = draft.occurredAtMs ?? draft.emittedAtMs
        snapshot.nativeWatermarks[hookEdgeKey] = max(snapshot.nativeWatermarks[hookEdgeKey] ?? at, at)
    }

    /// Whether this verified hc report ends a turn the hooks left working.
    static func hcEndsHookTurn(_ draft: JournalDraft, snapshot: JournalSnapshot) -> Bool {
        guard draft.signal == .hcIdle || draft.signal == .hcDone, snapshot.phase == .working,
              snapshot.adapter == .claudeHook,
              let edge = hookEdgeMs(snapshot), let hcStamp = draft.occurredAtMs, hcStamp >= 0 else { return false }
        return hcStamp > edge
    }
}

enum CodexTurnAuthority {
    /// The journal watermark: when Codex's own signal last ended a turn, on
    /// the clock of the machine the Codex runs on (the same clock as hc's
    /// status time for that terminal).
    static let turnEndKey = "codex-turn-end"

    static func isTurnSignal(_ adapter: JournalAdapter) -> Bool {
        adapter == .codexNotify || adapter == .codexTranscript
    }

    /// When Codex's own signal last ended a turn in this snapshot, or nil.
    static func turnEndMs(_ snapshot: JournalSnapshot?) -> Int64? {
        guard let snapshot, snapshot.owner.agentKind == "codex" else { return nil }
        return snapshot.nativeWatermarks[turnEndKey]
    }

    /// A Return into a Codex on another machine, as the start of its next
    /// turn: that Codex reports its turn end (the relay shim) but no turn
    /// start, and while a background terminal runs hc keeps its old
    /// `working` with the old time, which is stale. Without this, the next
    /// turn would read idle and mail could be typed into it.
    static func submitStart(owner: JournalOwner, workspaceID: UUID, at: Date) -> JournalDraft {
        JournalDraft(kind: .turnStarted, emittedAtMs: Int64((at.timeIntervalSince1970 * 1000).rounded()),
                     panelID: owner.panelID, workspaceID: workspaceID, sessionID: owner.sessionID,
                     agentKind: owner.agentKind, source: .keypress, adapter: .keypress, nativeEvent: "UserPromptSubmit")
    }

    /// Whether the turn now running was started only by a Return
    /// (`submitStart`), with nothing stronger since: the one turn the
    /// composer can take back (`retractReturnStart`).
    static func isReturnStartedTurn(_ snapshot: JournalSnapshot?) -> Bool {
        guard let snapshot, !snapshot.isHistorical, snapshot.phase == .working,
              snapshot.adapter == .keypress else { return false }
        return turnEndMs(snapshot) != nil
    }

    /// The composer read after that Return shows it submitted nothing: a
    /// verdict on the same submit, so it carries the same native event.
    static func retractReturnStart(owner: JournalOwner, workspaceID: UUID, at: Date) -> JournalDraft {
        JournalDraft(kind: .idleObserved, emittedAtMs: Int64((at.timeIntervalSince1970 * 1000).rounded()),
                     panelID: owner.panelID, workspaceID: workspaceID, sessionID: owner.sessionID,
                     agentKind: owner.agentKind, source: .keypress, adapter: .keypress, nativeEvent: "UserPromptSubmit")
    }

    /// Whether hc's word must not move a Codex panel's turn.
    static func hcWordIsStale(_ word: String?, hcStampMs: Int64?, turnEndMs: Int64?) -> Bool {
        guard let turnEndMs, word == "working" || word == "blocked" else { return false }
        guard let hcStampMs, hcStampMs >= 0 else { return true }
        return hcStampMs <= turnEndMs
    }
}
