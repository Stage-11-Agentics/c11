import Foundation

/// Hardcoded enum-shaped registry of `ConversationScraper`s, mirroring
/// `ConversationStrategyRegistry`. We are not building a plugin system —
/// adding a new kind is one scraper file plus an entry in `v1`.
///
/// Stored as an immutable map keyed by `kind`; lookups are O(1). The
/// filesystem dependency is injected at construction so the production
/// registry uses `DefaultConversationFilesystem` and tests pass a mock.
struct ConversationScraperRegistry: Sendable {
    private let scrapers: [String: any ConversationScraper]

    init(scrapers: [any ConversationScraper]) {
        var map: [String: any ConversationScraper] = [:]
        for scraper in scrapers {
            map[scraper.kind] = scraper
        }
        self.scrapers = map
    }

    func scraper(forKind kind: String) -> (any ConversationScraper)? {
        scrapers[kind]
    }

    func contains(kind: String) -> Bool {
        scrapers[kind] != nil
    }

    var allKinds: [String] {
        Array(scrapers.keys).sorted()
    }

    /// Default registry: every built-in kind that keeps an on-disk session
    /// store the pull rail can read. claude-code (push-primary, scrape is the
    /// crash-recovery fallback) and codex (scrape-primary). Downstream kinds
    /// (pi, omp) append their scraper here — that single edit is all the
    /// scrape rail needs to light them up, given a matching strategy in
    /// `ConversationStrategyRegistry.v1`.
    static func v1(
        filesystem: ConversationFilesystem = DefaultConversationFilesystem()
    ) -> ConversationScraperRegistry {
        ConversationScraperRegistry(scrapers: [
            ClaudeCodeScraper(filesystem: filesystem),
            CodexScraper(filesystem: filesystem),
            PiScraper(filesystem: filesystem)
        ])
    }
}
