import Foundation

/// Scrape-primary strategy for pi. pi exposes no SessionStart hook and no
/// session-id injection flag, so the wrapper never mints a placeholder; the
/// `PiScraper` resolves the real id from `~/.pi/agent/sessions/**/<ts>_<uuid>.jsonl`
/// filtered by cwd, mtime ≥ wrapper-claim time, and mtime ≥ surface
/// `lastActivityTimestamp`. (In production pi has no claim rail, so the
/// empty-candidates branch returns the absent `wrapperClaim` — i.e. `nil` —
/// and capture is driven entirely by the scrape rail.)
///
/// Ambiguity policy (mirrors `CodexStrategy`): when more than one candidate
/// matches the surface filter, return ref with `state = .unknown`,
/// `placeholder = false`, `id = most-plausible-candidate`, and a
/// diagnosticReason like `"ambiguous: 3 candidates; chose newest"`. `resume()`
/// returns `.skip(reason: "ambiguous")` for state=.unknown so neither pane
/// resumes the other's session and the operator is asked to disambiguate via
/// `c11 conversation clear --surface <id>`.
///
/// Id grammar: UUID (pi session filenames carry a UUIDv7 after the last `_`;
/// `isValidConversationUUID` accepts the 8-4-4-4-12 hex shape).
struct PiStrategy: ConversationStrategy {
    let kind: String = "pi"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        // Filter the candidates by what we know about the surface.
        let activityFloor = inputs.lastActivityTimestamp
        let claimTime = inputs.wrapperClaim?.capturedAt
        let cwd = inputs.cwd

        let filtered = inputs.scrapeCandidates.filter { candidate in
            // cwd must match the surface's cwd if both are known.
            if let cwd, let candCwd = candidate.cwd, cwd != candCwd {
                return false
            }
            if let claimTime, candidate.mtime < claimTime {
                return false
            }
            if let activityFloor, candidate.mtime < activityFloor {
                return false
            }
            return isValidConversationUUID(candidate.id)
        }

        if filtered.isEmpty {
            // No live signal. pi has no wrapper-claim rail, so this is `nil`
            // in production; return it for parity with the codex mirror.
            return inputs.wrapperClaim
        }
        // Sort newest-first; deterministic within the strategy.
        let sorted = filtered.sorted { $0.mtime > $1.mtime }
        let chosen = sorted[0]
        if sorted.count > 1 {
            return ConversationRef(
                kind: kind,
                id: chosen.id,
                placeholder: false,
                cwd: chosen.cwd ?? cwd,
                capturedAt: chosen.mtime,
                capturedVia: .scrape,
                state: .unknown,
                diagnosticReason: "ambiguous: \(sorted.count) candidates; chose newest"
            )
        }
        return ConversationRef(
            kind: kind,
            id: chosen.id,
            placeholder: false,
            cwd: chosen.cwd ?? cwd,
            capturedAt: chosen.mtime,
            capturedVia: .scrape,
            state: .alive,
            diagnosticReason: "matched cwd + mtime after claim"
        )
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        guard !ref.placeholder else {
            return .skip(reason: "placeholder; no pi session resolved yet")
        }
        switch ref.state {
        case .unknown:
            return .skip(reason: "ambiguous")
        case .tombstoned, .unsupported:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        case .alive, .suspended:
            break
        }
        guard isValidConversationUUID(ref.id) else {
            return .skip(reason: "invalid id grammar")
        }
        let quoted = conversationShellQuote(ref.id)
        // Specific id, not `pi -c`. Exact-session resume is the whole point.
        let text = "pi --session \(quoted)"
        return .typeCommand(text: text, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    /// Crash-recovery verification (stat-only): does a session file for
    /// `ref.id` still exist on disk? Without this, `reclassifyAfterCrash`
    /// forces the ref to `.unknown` (the protocol default returns nil) and
    /// resume skips after a crash — the path that matters most for resume.
    /// Reuses the cwd-scoped `PiScraper`; never opens transcript bytes.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return false }
        return PiScraper(filesystem: filesystem)
            .candidates(cwd: ref.cwd)
            .contains { $0.id == ref.id }
    }
}
