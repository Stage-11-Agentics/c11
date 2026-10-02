import Foundation

struct JournalFoldResult {
    let snapshot: JournalSnapshot?
    let effect: JournalEffect
    let reason: String
    let fromPhase: JournalPhase?
    let fromSinceMs: Int64?
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
        guard d.nativeEvent != "other" else { return unchanged(.observation, "unknown_native_event") }
        var s = previous ?? JournalSnapshot(owner: owner, workspaceID: d.workspaceID, appInstanceID: instanceID)
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
           d.kind != .turnStarted && d.kind != .sessionStarted {
            return unchanged(.stale, "different_turn")
        }
        let caps = d.adapter.capabilities
        let supportsTurn = caps.contains("turn")
        let supportsBlocked = caps.contains("blocked")
        let transcript = d.source == .transcript
        let fromPhase = s.phase
        let fromSince = s.sinceMs
        var reason = "state_transition"
        var preserveEvidence = false
        var evidenceOnly = false
        func duplicate(_ reason: String) -> JournalFoldResult {
            guard !context.historical, d.source.rank >= s.rank else { return unchanged(.duplicateEvidence, reason) }
            var refreshed = s
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
            guard previous == nil else { return unchanged(.observation, "session_already_known") }
            guard caps.contains("session") else { return unchanged(.advisory, "unsupported_session") }
            reason = "session_observed"
        case .sessionEnded:
            guard caps.contains("session") else { return unchanged(.advisory, "unsupported_session") }
            s.connection = .disconnected
            s.confirmation = .unconfirmed
            preserveEvidence = true
            reason = "session_disconnected"
        case .turnStarted:
            guard supportsTurn else { return unchanged(.advisory, "unsupported_turn") }
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
            guard supportsTurn else { return unchanged(.advisory, "unsupported_turn") }
            // Claude cannot emit Stop while its same-turn permission prompt is pending.
            // An absent/mismatched turn or another adapter is not continuation evidence.
            let resolvesClaudeApproval = d.kind == .turnCompleted && d.adapter == .claudeHook
                && d.source == .hook && d.source.rank >= s.rank && s.reason == .approval
                && d.turnID != nil && d.turnID == s.turnID
            guard s.phase != .blocked || resolvesClaudeApproval else { return unchanged(.advisory, "unresolved_request") }
            if resolvesClaudeApproval { s.requestID = nil; s.reason = nil }
            guard s.phase != .error || d.source.rank >= s.rank else { return unchanged(.advisory, "lower_confidence") }
            if s.terminalBarrier && s.phase == .idle { return duplicate("turn_already_terminal") }
            s.phase = .idle
            s.turnOutcome = d.kind == .turnCompleted ? "completed" : nil
            s.turnID = d.turnID ?? s.turnID
            s.terminalBarrier = true
            s.terminalRank = d.source.rank
        case .turnInterrupted:
            guard caps.contains("interrupt") else { return unchanged(.advisory, "unsupported_interrupt") }
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
            }
        case .errorReported:
            guard caps.contains("error"), d.reasonCode == .sessionFailure else { return unchanged(.observation, "tool_or_unsupported_error") }
            if s.phase == .error { return duplicate("error_already_observed") }
            if s.phase == .blocked && d.source.rank < s.rank { return unchanged(.advisory, "lower_confidence") }
            s.phase = .error
            s.reason = .sessionFailure
            s.terminalBarrier = true
            s.terminalRank = d.source.rank
        case .stateChanged:
            switch d.signal {
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

        if fromPhase != s.phase || previous == nil || (d.kind == .turnStarted && s.turnID != previous?.turnID)
            || (s.phase == .blocked && (s.requestID != previous?.requestID || s.reason != previous?.reason)) {
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
                                 fromPhase: previous == nil ? nil : fromPhase, fromSinceMs: previous == nil ? nil : fromSince)
    }
}
