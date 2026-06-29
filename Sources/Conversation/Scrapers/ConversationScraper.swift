import Foundation

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
}
