import Foundation

/// Per-surface restore context the scrape-capture pipeline consumes. Built
/// from the session snapshot at launch (`contexts(from:)`); one entry per
/// terminal panel whose `terminal_type` metadata declares an agent kind.
struct ScrapeCaptureContext: Sendable, Equatable {
    /// `panel.id.uuidString` — the surface id the store keys on.
    let surfaceId: String
    /// The agent kind, from the panel's `terminal_type` metadata. Pairs the
    /// surface with a scraper + strategy of the same `kind`.
    let kind: String
    /// The panel's working directory, used by cwd-filtering strategies.
    let cwd: String?
    /// Optional mtime floor. Nil at a cold restore (the snapshot doesn't
    /// carry live activity); present when a caller knows the last activity.
    let lastActivityTimestamp: Date?

    init(
        surfaceId: String,
        kind: String,
        cwd: String? = nil,
        lastActivityTimestamp: Date? = nil
    ) {
        self.surfaceId = surfaceId
        self.kind = kind
        self.cwd = cwd
        self.lastActivityTimestamp = lastActivityTimestamp
    }

    /// Build contexts from a loaded session snapshot. Walks every terminal
    /// panel across all windows/workspaces; keeps only those whose
    /// `terminal_type` metadata resolves to a non-empty kind (nothing else
    /// has a scraper to run). `directory` becomes `cwd`.
    static func contexts(from snapshot: AppSessionSnapshot) -> [ScrapeCaptureContext] {
        var result: [ScrapeCaptureContext] = []
        for window in snapshot.windows {
            for ws in window.tabManager.workspaces {
                for panel in ws.panels {
                    guard panel.type == .terminal else { continue }
                    guard let kind = terminalType(of: panel), !kind.isEmpty else { continue }
                    let cwd = panel.directory.flatMap { $0.isEmpty ? nil : $0 }
                    result.append(ScrapeCaptureContext(
                        surfaceId: panel.id.uuidString,
                        kind: kind,
                        cwd: cwd,
                        // C11-164 (RES-2): thread the persisted activity floor
                        // into the restore-time scrape. Without this the floor
                        // is nil at cold restore and the Codex/pi/omp candidate
                        // filter can no longer exclude stale sessions, producing
                        // spurious ambiguity. `nil` (pre-C11-164 snapshot)
                        // preserves the prior no-floor behaviour.
                        lastActivityTimestamp: panel.lastActivityAt
                    ))
                }
            }
        }
        return result
    }

    /// Read the panel's declared `terminal_type` metadata value (a `.string`).
    private static func terminalType(of panel: SessionPanelSnapshot) -> String? {
        guard let metadata = panel.metadata else { return nil }
        guard case .string(let raw)? = metadata[SurfaceMetadataKeyName.terminalType] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The live scrape-capture pipeline — the connective tissue between the
/// pull rail (`ConversationScraper`) and the per-kind `ConversationStrategy`.
///
/// This is the seam the architecture finding identified as missing: scrapers
/// produce `[ScrapeCandidate]`, strategies know how to `capture` candidates
/// into a `ConversationRef`, but nothing connected the two at runtime, so
/// codex (and any future scrape-primary kind: pi, omp) never resolved a real
/// session id at restore. The pipeline closes that gap.
///
/// Pure by design: it performs no store mutation and no I/O of its own beyond
/// invoking the injected scrapers (whose filesystem is itself injected). The
/// actor-isolated apply step lives on `ConversationStore.runScrapeCapture`.
struct ScrapeCapturePipeline: Sendable {
    let scrapers: ConversationScraperRegistry
    let strategies: ConversationStrategyRegistry

    init(
        scrapers: ConversationScraperRegistry,
        strategies: ConversationStrategyRegistry = .v1
    ) {
        self.scrapers = scrapers
        self.strategies = strategies
    }

    /// For each context, run its kind's scraper, hand the candidates (plus the
    /// surface's existing wrapper-claim / push, so claim-time + cwd filters
    /// keep working) to the strategy's `capture`, and collect the result IFF
    /// it is a genuinely scrape-derived ref (`capturedVia == .scrape`).
    ///
    /// Forwarding only `.scrape` provenance is the safety property: a strategy
    /// that merely echoes back the wrapper-claim placeholder (no disk match)
    /// or returns a hook-sourced ref produces nothing to apply, so the store
    /// is never written with a placeholder — or a regression — via the scrape
    /// path. Pure: never touches the store. Results are in input order.
    func captureRefs(
        contexts: [ScrapeCaptureContext],
        existing: [String: SurfaceConversations]
    ) -> [(surfaceId: String, ref: ConversationRef)] {
        var result: [(surfaceId: String, ref: ConversationRef)] = []
        for context in contexts {
            guard let scraper = scrapers.scraper(forKind: context.kind) else { continue }
            guard let strategy = strategies.strategy(forKind: context.kind) else { continue }

            let candidates = scraper.candidates(cwd: context.cwd)

            // Route the existing active ref into the right input slot so the
            // strategy's filters (claim-time floor, push-wins) behave exactly
            // as they do on the live path.
            let active = existing[context.surfaceId]?.active
            let wrapperClaim = active?.capturedVia == .wrapperClaim ? active : nil
            let push = (active != nil && active?.capturedVia != .wrapperClaim) ? active : nil

            let inputs = ConversationStrategyInputs(
                surfaceId: context.surfaceId,
                cwd: context.cwd,
                lastActivityTimestamp: context.lastActivityTimestamp,
                wrapperClaim: wrapperClaim,
                push: push,
                scrapeCandidates: candidates
            )

            guard let ref = strategy.capture(inputs: inputs) else { continue }
            // Only apply genuinely scrape-derived refs (see doc comment).
            guard ref.capturedVia == .scrape else { continue }
            result.append((surfaceId: context.surfaceId, ref: ref))
        }
        return result
    }
}
