import Foundation

enum ScrapeCollectionFailure: String, Codable, Sendable, Equatable {
    case unavailable
    case unreadable
    case cancelled
    case injectedFailure
}

enum ScrapeCandidateCollectionResult: Sendable, Equatable {
    case success([ScrapeCandidate])
    case failure(ScrapeCollectionFailure)
}

/// A per-kind, bounded, metadata-only session scraper.
///
/// Conformers walk a TUI's on-disk session store and return the most-recent
/// candidates by mtime. They are the **pull rail** half of the live
/// scrape-capture pipeline (`ScrapeCapturePipeline`): the scraper produces
/// `[ScrapeCandidate]`, the per-kind `ConversationStrategy.capture` turns
/// those into a resolved `ConversationRef`.
///
/// **Privacy contract** (see the architecture doc §"Privacy contract for
/// scrape"): conformers read metadata only — filename + mtime + size. The
/// filename carries the session id. Transcript bytes are never opened,
/// copied, or logged.
///
/// `ClaudeCodeScraper` and `CodexScraper` are the built-in conformers;
/// downstream kinds (pi, omp) add their own scraper and register it in
/// `ConversationScraperRegistry.v1`.
protocol ConversationScraper: Sendable {
    /// Stable kind identifier. Matches `ConversationStrategy.kind` and
    /// `ConversationRef.kind` (e.g. `"claude-code"`, `"codex"`, `"pi"`,
    /// `"omp"`). The pipeline uses this to pair a scraper with its strategy.
    var kind: String { get }

    /// Bounded top-N candidates, newest-first by mtime. When `cwd` is
    /// provided it is stamped onto each returned candidate so the strategy's
    /// cwd filter (e.g. `CodexStrategy.capture`) can apply. Returns an empty
    /// array when the kind's session store doesn't exist on this machine.
    func candidates(cwd: String?) -> [ScrapeCandidate]

    /// One bounded collection for every live context of this kind. The
    /// pipeline calls this exactly once per kind, off the conversation-store
    /// actor. Scrapers whose stores are cwd-partitioned inherit the default
    /// deduplicating implementation; global stores such as Codex override it
    /// to enumerate only once.
    func batchCandidates(
        contexts: [ScrapeCaptureContext],
        maxCandidates: Int
    ) -> [ScrapeCandidate]

    /// Typed batch outcome. Missing stores remain a successful empty result;
    /// implementations that can distinguish unreadable/unavailable I/O (and
    /// test doubles) return failure so startup/clean persistence can fail
    /// closed instead of treating an error as "no sessions".
    func collectBatchCandidates(
        contexts: [ScrapeCaptureContext],
        maxCandidates: Int
    ) -> ScrapeCandidateCollectionResult
}

extension ConversationScraper {
    func collectBatchCandidates(
        contexts: [ScrapeCaptureContext],
        maxCandidates: Int
    ) -> ScrapeCandidateCollectionResult {
        .success(batchCandidates(contexts: contexts, maxCandidates: maxCandidates))
    }

    func batchCandidates(
        contexts: [ScrapeCaptureContext],
        maxCandidates: Int
    ) -> [ScrapeCandidate] {
        guard maxCandidates > 0 else { return [] }
        var seenCwds = Set<String>()
        var includesNilCwd = false
        var mergedByPath: [String: ScrapeCandidate] = [:]

        for context in contexts {
            if let cwd = context.cwd {
                guard seenCwds.insert(cwd).inserted else { continue }
                for candidate in candidates(cwd: cwd) {
                    mergedByPath[candidate.filePath] = candidate
                }
            } else if !includesNilCwd {
                includesNilCwd = true
                for candidate in candidates(cwd: nil) {
                    mergedByPath[candidate.filePath] = candidate
                }
            }
        }

        return mergedByPath.values
            .sorted {
                if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                return $0.filePath < $1.filePath
            }
            .prefix(maxCandidates)
            .map { $0 }
    }
}
