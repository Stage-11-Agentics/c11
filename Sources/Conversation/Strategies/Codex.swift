import Foundation

/// Runtime-primary strategy for Codex. This design intentionally does not
/// depend on optional hook injection or trusting tenant configuration: the
/// bundled wrapper captures `CODEX_THREAD_ID` from the target process as
/// causal evidence. A bounded scrape of `~/.codex/sessions/*.jsonl`, filtered
/// by cwd and activity floors, remains the crash/legacy fallback.
///
/// Ambiguity policy (the bug this primitive exists to fix): when more than
/// one candidate matches the surface filter, return ref with
/// `state = .unknown`, `placeholder = false`, `id = most-plausible-candidate`,
/// and a diagnosticReason like `"ambiguous: 3 candidates; chose newest"`.
/// `resume()` returns `.skip(reason: "ambiguous")` for state=.unknown so
/// neither pane resumes the other's session and the operator is asked to
/// disambiguate via `c11 conversation clear --surface <id>`.
///
/// Id grammar: UUID v4 (codex session filenames are `<uuid>.jsonl`).
struct CodexStrategy: ConversationStrategy {
    let kind: String = "codex"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        let filtered = eligibleCandidates(inputs: inputs)

        if filtered.isEmpty {
            // No live signal. Return wrapper-claim placeholder if we have it.
            return inputs.wrapperClaim
        }
        // Sort newest-first; deterministic within the strategy.
        let sorted = filtered.sorted {
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.id < $1.id
        }
        let chosen = sorted[0]
        if sorted.count > 1 {
            var ref = scrapeRef(candidate: chosen, fallbackCwd: inputs.cwd)
            ref.state = .unknown
            ref.quarantineReason = .ambiguousGlobalAssignment
            ref.diagnosticReason = "ambiguous: \(sorted.count) candidates; chose newest"
            return ref
        }
        return scrapeRef(candidate: chosen, fallbackCwd: inputs.cwd)
    }

    /// Exclusion-only candidate filter shared by per-surface compatibility
    /// capture and the global consuming assignment pipeline.
    func eligibleCandidates(inputs: ConversationStrategyInputs) -> [ScrapeCandidate] {
        // Filter the candidates by what we know about the surface.
        let activityFloor = inputs.lastActivityTimestamp
        let claimTime = inputs.wrapperClaim?.capturedAt
        let cwd = inputs.cwd

        return inputs.scrapeCandidates.filter { candidate in
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
    }

    func scrapeRef(
        candidate: ScrapeCandidate,
        fallbackCwd: String?
    ) -> ConversationRef {
        return ConversationRef(
            kind: kind,
            id: candidate.id,
            placeholder: false,
            cwd: candidate.cwd ?? fallbackCwd,
            capturedAt: candidate.mtime,
            capturedVia: .scrape,
            state: .alive,
            diagnosticReason: "matched cwd + mtime after claim"
        )
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        guard !ref.placeholder else {
            return .skip(reason: "placeholder; no codex session resolved yet")
        }
        if let quarantineReason = ref.quarantineReason {
            return .skip(reason: "quarantined:\(quarantineReason.rawValue)")
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
        // Specific id, not `--last`. The plan motivates this directly.
        let text = "codex resume \(quoted)"
        return .typeCommand(text: text, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    /// Crash-recovery verification (stat-only): does a `rollout-<ts>-<uuid>.jsonl`
    /// for `ref.id` still exist on disk? Without this, `reclassifyAfterCrash`
    /// forces the ref to `.unknown` (the protocol default returns nil) and codex
    /// resume skips after a crash. Codex filenames are date-nested with an
    /// unknown timestamp, so an exact-path stat isn't constructable; reuse the
    /// `CodexScraper` (which extracts the trailing UUID) and check membership.
    /// Never opens transcript bytes.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return false }
        // Id-membership only — skip the per-candidate cwd head reads (G3), which
        // this check discards anyway.
        // Verification is exact-id membership, not candidate assignment. Use
        // the bounded many-tab cap rather than the legacy newest-16 default so
        // an older still-live ref remains verifiable at realistic scale.
        return CodexScraper(
            filesystem: filesystem,
            maxCandidates: CodexScraper.maximumBatchCandidates
        )
            .candidates(cwd: nil, recoverCwd: false)
            .contains { $0.id == ref.id }
    }
}
