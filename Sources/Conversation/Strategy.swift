import Foundation

/// Per-surface inputs handed to a strategy at capture or resume time.
/// Wrapper-claim values, hook pushes, and scraper signals are all surfaced
/// here so strategies stay deterministic given collected signals — they do
/// not perform I/O directly.
struct ConversationStrategyInputs: Sendable {
    let surfaceId: String
    let cwd: String?
    let lastActivityTimestamp: Date?
    /// The most recent wrapper-claim ref the store has seen for this
    /// surface (placeholder), if any.
    let wrapperClaim: ConversationRef?
    /// The most recent push (hook or manual) the store has seen, if any.
    let push: ConversationRef?
    /// Bounded scraper signals, sorted newest-first by mtime.
    let scrapeCandidates: [ScrapeCandidate]

    init(
        surfaceId: String,
        cwd: String? = nil,
        lastActivityTimestamp: Date? = nil,
        wrapperClaim: ConversationRef? = nil,
        push: ConversationRef? = nil,
        scrapeCandidates: [ScrapeCandidate] = []
    ) {
        self.surfaceId = surfaceId
        self.cwd = cwd
        self.lastActivityTimestamp = lastActivityTimestamp
        self.wrapperClaim = wrapperClaim
        self.push = push
        self.scrapeCandidates = scrapeCandidates
    }
}

/// Bounded metadata produced by per-kind scrapers. Filename + mtime + size
/// only — never transcript content (privacy contract; see the architecture
/// doc §"Privacy contract for scrape").
struct ScrapeCandidate: Sendable, Equatable {
    let id: String
    let filePath: String
    let mtime: Date
    let size: Int64
    let cwd: String?

    init(id: String, filePath: String, mtime: Date, size: Int64, cwd: String? = nil) {
        self.id = id
        self.filePath = filePath
        self.mtime = mtime
        self.size = size
        self.cwd = cwd
    }
}

/// Per-kind strategy contract. Strategies are deterministic given
/// collected signals; they do not perform I/O directly. The store hands
/// a strategy a snapshot of inputs and applies the result under actor
/// isolation.
///
/// Strategies must document their id grammar and apply explicit
/// shell-quoting before interpolation in any `typeCommand` text. See each
/// concrete strategy for the per-kind grammar.
protocol ConversationStrategy: Sendable {
    /// Stable kind identifier. Matches `ConversationRef.kind`. Examples:
    /// `"claude-code"`, `"codex"`, `"opencode"`, `"kimi"`. Flat strings;
    /// namespacing deferred per S5.
    var kind: String { get }

    /// Given collected signals, return the active ref for this surface or
    /// `nil` if the strategy has no signal to act on.
    ///
    /// Strategies merge wrapper-claim, push, and scrape signals and produce
    /// the canonical ref. Reconciliation across signal sources is the store's
    /// job; this entry point produces the strategy's view of "what the ref
    /// should be given these inputs."
    func capture(inputs: ConversationStrategyInputs) -> ConversationRef?

    /// Given a captured ref, return the action that resumes it.
    ///
    /// Strategies MUST validate `ref.id` and return `.skip(reason:)` for
    /// placeholders, invalid ids, or ambiguous states (`state == .unknown`).
    func resume(ref: ConversationRef) -> ResumeAction

    /// Validate an id against the strategy's grammar. Returns false for
    /// empty/malformed ids. Used by the CLI on `c11 conversation push --id`
    /// before the value reaches the store.
    func isValidId(_ id: String) -> Bool

    /// Crash-recovery verification seam. Given a captured ref and an
    /// injectable filesystem, return whether on-disk evidence confirms the
    /// conversation is still resumable.
    ///
    /// - `true`: the strategy located the ref's on-disk transcript →
    ///   `reclassifyAfterCrash` promotes the ref to `.suspended`.
    /// - `false`: the strategy checked and found nothing → demote to
    ///   `.unknown`.
    /// - `nil`: this kind has no on-disk transcript concept (or lacks the
    ///   inputs to compute the path) → caller treats it conservatively as
    ///   not-resumable (`.unknown`), matching the prior `markAllUnknown`
    ///   behavior for kinds that cannot verify.
    ///
    /// MUST be stat-only — never open transcript bytes (privacy contract).
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool?
}

extension ConversationStrategy {
    /// Default: trim whitespace and reject empty. Strategies override for
    /// stricter grammars (e.g. UUID v4 for Claude/Codex).
    func isValidId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// Default: no on-disk transcript concept. Kinds that keep transcripts
    /// (Claude Code) override this; everything else returns `nil` so the
    /// crash-recovery pass leaves the ref `.unknown`.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        nil
    }
}

/// Shell-quoting helper for `typeCommand` interpolation. Single-quotes the
/// argument and escapes embedded single quotes.
///
/// The strategies in this module never call this directly with untrusted
/// input — they validate ids against documented grammars (UUID v4) before
/// interpolation, which means the id is already a safe set of characters.
/// This helper exists as a defence-in-depth seam: any future change that
/// forgets the grammar check still cannot inject shell metacharacters.
func conversationShellQuote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

/// UUID v4 grammar shared by Claude Code and Codex strategies. Anchored
/// 8-4-4-4-12 hex with dashes; case-insensitive. Mirrors the existing
/// `claudeSessionIdUUIDPattern` in `AgentRestartRegistry.swift`.
let conversationUUIDPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        options: []
    )
}()

func isValidConversationUUID(_ candidate: String) -> Bool {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
    let range = NSRange(location: 0, length: (trimmed as NSString).length)
    return conversationUUIDPattern.firstMatch(in: trimmed, options: [], range: range) != nil
}
