import Foundation

/// Pull-primary strategy for oh-my-pi (`omp`). Like codex, omp exposes no
/// session-id injection flag and no SessionStart hook, so the c11 omp wrapper
/// (`Resources/bin/omp`) mints a placeholder wrapper-claim at launch; the
/// scraper resolves the real id from
/// `~/.omp/agent/sessions/<cwd-slug>/<ts>_<uuid>.jsonl` (id = the trailing
/// UUIDv7), filtered by cwd, mtime ≥ wrapper-claim time, and mtime ≥ surface
/// `lastActivityTimestamp`. The claim time floors out the older sessions a
/// cwd accumulates so resume resolves this pane's session instead of going
/// `.unknown` (the same latent bug pi hit; see `Resources/bin/omp`).
///
/// Ambiguity policy (mirrors `CodexStrategy`): when more than one candidate
/// matches the surface filter, return a ref with `state = .unknown`,
/// `placeholder = false`, `id = most-plausible-candidate`, and a
/// diagnosticReason like `"ambiguous: 3 candidates; chose newest"`.
/// `resume()` returns `.skip(reason: "ambiguous")` for state=.unknown so
/// neither pane resumes the other's session and the operator is asked to
/// disambiguate via `c11 conversation clear --surface <id>`.
///
/// Id grammar: UUIDv7 (8-4-4-4-12 hex; the scraper parses it out of the
/// `<ts>_<uuid>.jsonl` filename, so `resume`/`capture` receive a clean id).
struct OmpStrategy: ConversationStrategy {
    let kind: String = "omp"

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
            // No live signal. Return wrapper-claim placeholder if we have it.
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
            return .skip(reason: "placeholder; no omp session resolved yet")
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
        // Specific id, not a `--last`-style flag — the whole point of the
        // exact-resume rail is restoring *this* surface's session.
        let text = "omp --resume=\(quoted)"
        return .typeCommand(text: text, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    /// Crash-recovery verification (stat-only): does a session file for
    /// `ref.id` still exist on disk? Without this, `reclassifyAfterCrash`
    /// forces the ref to `.unknown` (the protocol default returns nil) and
    /// resume skips after a crash — the path that matters most for resume.
    /// Reuses the cwd-scoped `OmpScraper`; never opens transcript bytes.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return false }
        return OmpScraper(filesystem: filesystem)
            .candidates(cwd: ref.cwd)
            .contains { $0.id == ref.id }
    }
}
