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

struct ScrapeCandidateBatch: Sendable, Equatable {
    let contexts: [ScrapeCaptureContext]
    let candidatesByKind: [String: [ScrapeCandidate]]
}

struct ScrapeCandidateBatchCollectionError: Error, Sendable, Equatable {
    let failuresByKind: [String: ScrapeCollectionFailure]
}

struct ScrapeReconciliationPlan: Sendable, Equatable {
    let refsBySurface: [String: ConversationRef]
    let quarantineReasonsBySurface: [String: ConversationQuarantineReason]
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
    static let candidateHeadroomMultiplier = 4
    static let defaultCandidateFloor = 16

    let scrapers: ConversationScraperRegistry
    let strategies: ConversationStrategyRegistry

    init(
        scrapers: ConversationScraperRegistry,
        strategies: ConversationStrategyRegistry = .v1
    ) {
        self.scrapers = scrapers
        self.strategies = strategies
    }

    static func candidateBudget(kind: String, liveContextCount: Int) -> Int {
        guard liveContextCount > 0 else { return 0 }
        let cap = CodexScraper.maximumBatchCandidates
        let (scaled, overflow) = liveContextCount.multipliedReportingOverflow(
            by: candidateHeadroomMultiplier
        )
        let requested = overflow ? cap : max(defaultCandidateFloor, scaled)
        return min(cap, requested)
    }

    /// Collect every kind once on a detached task. No `ConversationStore`
    /// actor state is captured here; a runtime-env report may therefore land
    /// while filesystem enumeration is in flight, and the later actor commit
    /// reconciles against the then-current store.
    func collectCandidateBatch(
        contexts: [ScrapeCaptureContext]
    ) async throws -> ScrapeCandidateBatch {
        try Task.checkCancellation()
        let result = await Task.detached(priority: .utility) { [self, contexts] in
            Result { try collectCandidateBatchSynchronously(contexts: contexts) }
        }.value
        try Task.checkCancellation()
        return try result.get()
    }

    /// Package-visible deterministic collector for logic tests. Production
    /// must call the async wrapper above so scraper I/O never runs on the
    /// conversation-store actor.
    func collectCandidateBatchSynchronously(
        contexts: [ScrapeCaptureContext]
    ) throws -> ScrapeCandidateBatch {
        let grouped = Dictionary(grouping: contexts, by: \.kind)
        var candidatesByKind: [String: [ScrapeCandidate]] = [:]
        var failuresByKind: [String: ScrapeCollectionFailure] = [:]
        for kind in grouped.keys.sorted() {
            guard let kindContexts = grouped[kind],
                  let scraper = scrapers.scraper(forKind: kind) else { continue }
            let budget = Self.candidateBudget(
                kind: kind,
                liveContextCount: kindContexts.count
            )
            switch scraper.collectBatchCandidates(
                contexts: kindContexts,
                maxCandidates: budget
            ) {
            case .success(let candidates):
                candidatesByKind[kind] = candidates
            case .failure(let failure):
                failuresByKind[kind] = failure
            }
        }
        if !failuresByKind.isEmpty {
            throw ScrapeCandidateBatchCollectionError(
                failuresByKind: failuresByKind
            )
        }
        return ScrapeCandidateBatch(
            contexts: contexts,
            candidatesByKind: candidatesByKind
        )
    }

    /// Pure global assignment. Cwd and timestamps only remove impossible
    /// edges; they never choose between multiple same-cwd Codex surfaces.
    func reconcileBatch(
        _ batch: ScrapeCandidateBatch,
        existing: [String: SurfaceConversations]
    ) -> ScrapeReconciliationPlan {
        var refsBySurface: [String: ConversationRef] = [:]
        var quarantineReasons: [String: ConversationQuarantineReason] = [:]
        let contextsByKind = Dictionary(grouping: batch.contexts, by: \.kind)

        for kind in contextsByKind.keys.sorted() {
            guard let contexts = contextsByKind[kind] else { continue }
            let candidates = batch.candidatesByKind[kind] ?? []
            if kind == "codex" {
                reconcileCodex(
                    contexts: contexts,
                    candidates: candidates,
                    existing: existing,
                    refsBySurface: &refsBySurface,
                    quarantineReasons: &quarantineReasons
                )
                continue
            }

            // Preserve existing kind-specific behavior while consuming a
            // scrape identity at most once across the batch.
            guard let strategy = strategies.strategy(forKind: kind) else { continue }
            var consumed = Set<ConversationIdentity>()
            for context in contexts {
                let active = existing[context.surfaceId]?.active
                let inputs = ConversationStrategyInputs(
                    surfaceId: context.surfaceId,
                    cwd: context.cwd,
                    lastActivityTimestamp: context.lastActivityTimestamp,
                    wrapperClaim: active?.capturedVia == .wrapperClaim ? active : nil,
                    push: (active != nil && active?.capturedVia != .wrapperClaim) ? active : nil,
                    scrapeCandidates: candidates
                )
                guard let ref = strategy.capture(inputs: inputs),
                      ref.capturedVia == .scrape else { continue }
                let identity = ConversationIdentity(kind: ref.kind, id: ref.id)
                if consumed.insert(identity).inserted {
                    refsBySurface[context.surfaceId] = ref
                } else {
                    quarantineReasons[context.surfaceId] = .duplicateInferredIdentity
                }
            }
        }

        return ScrapeReconciliationPlan(
            refsBySurface: refsBySurface,
            quarantineReasonsBySurface: quarantineReasons
        )
    }

    private func reconcileCodex(
        contexts: [ScrapeCaptureContext],
        candidates: [ScrapeCandidate],
        existing: [String: SurfaceConversations],
        refsBySurface: inout [String: ConversationRef],
        quarantineReasons: inout [String: ConversationQuarantineReason]
    ) {
        let strategy = CodexStrategy()
        let contextsBySurface = Dictionary(
            uniqueKeysWithValues: contexts.map { ($0.surfaceId, $0) }
        )
        let causalSurfaces = Set(contexts.compactMap { context -> String? in
            existing[context.surfaceId]?.active?.isEligibleCausalOwner == true
                ? context.surfaceId
                : nil
        })
        let reservedIds = Set(causalSurfaces.compactMap {
            existing[$0]?.active.map { ConversationIdentity(kind: $0.kind, id: $0.id) }
        })

        // Same cwd is an exclusion-only signal. Every non-causal surface in a
        // repeated cwd set is quarantined even if mtimes appear to form a
        // unique matching.
        let cwdGroups = Dictionary(grouping: contexts.compactMap { context -> (String, String)? in
            guard let cwd = normalizedCwd(context.cwd) else { return nil }
            return (cwd, context.surfaceId)
        }, by: { $0.0 })
        for group in cwdGroups.values where group.count > 1 {
            for (_, surfaceId) in group where !causalSurfaces.contains(surfaceId) {
                quarantineReasons[surfaceId] = .sameCwdWithoutCausalIdentity
            }
        }

        var unresolved = Set(contexts.map(\.surfaceId))
            .subtracting(causalSurfaces)
            .subtracting(quarantineReasons.keys)
        var availableByIdentity: [ConversationIdentity: ScrapeCandidate] = [:]
        for candidate in candidates {
            let identity = ConversationIdentity(kind: "codex", id: candidate.id)
            guard !reservedIds.contains(identity) else { continue }
            if let existingCandidate = availableByIdentity[identity] {
                if candidate.mtime > existingCandidate.mtime
                    || (candidate.mtime == existingCandidate.mtime
                        && candidate.filePath < existingCandidate.filePath) {
                    availableByIdentity[identity] = candidate
                }
            } else {
                availableByIdentity[identity] = candidate
            }
        }

        var consumed = Set<ConversationIdentity>()
        while !unresolved.isEmpty {
            var edges: [String: [ConversationIdentity]] = [:]
            var owners: [ConversationIdentity: Set<String>] = [:]
            for surfaceId in unresolved.sorted() {
                guard let context = contextsBySurface[surfaceId] else { continue }
                let active = existing[surfaceId]?.active
                let inputs = ConversationStrategyInputs(
                    surfaceId: surfaceId,
                    cwd: context.cwd,
                    lastActivityTimestamp: context.lastActivityTimestamp,
                    wrapperClaim: active?.capturedVia == .wrapperClaim ? active : nil,
                    push: nil,
                    scrapeCandidates: availableByIdentity.compactMap { identity, candidate in
                        consumed.contains(identity) ? nil : candidate
                    }
                )
                let eligible = strategy.eligibleCandidates(inputs: inputs)
                    .map { ConversationIdentity(kind: "codex", id: $0.id) }
                    .filter { !consumed.contains($0) }
                edges[surfaceId] = eligible
                for identity in eligible {
                    owners[identity, default: []].insert(surfaceId)
                }
            }

            let uniquePairs = edges.compactMap { surfaceId, identities
                -> (String, ConversationIdentity)? in
                guard identities.count == 1,
                      let identity = identities.first,
                      owners[identity]?.count == 1 else { return nil }
                return (surfaceId, identity)
            }
            guard !uniquePairs.isEmpty else { break }

            for (surfaceId, identity) in uniquePairs.sorted(by: { $0.0 < $1.0 }) {
                guard let context = contextsBySurface[surfaceId],
                      let candidate = availableByIdentity[identity] else { continue }
                refsBySurface[surfaceId] = strategy.scrapeRef(
                    candidate: candidate,
                    fallbackCwd: context.cwd
                )
                consumed.insert(identity)
                unresolved.remove(surfaceId)
            }
        }

        // A non-empty edge set that cannot be uniquely consumed is honest
        // ambiguity. Zero candidates leave the existing placeholder untouched.
        for surfaceId in unresolved {
            guard let context = contextsBySurface[surfaceId] else { continue }
            let active = existing[surfaceId]?.active
            let inputs = ConversationStrategyInputs(
                surfaceId: surfaceId,
                cwd: context.cwd,
                lastActivityTimestamp: context.lastActivityTimestamp,
                wrapperClaim: active?.capturedVia == .wrapperClaim ? active : nil,
                push: nil,
                scrapeCandidates: availableByIdentity.compactMap { identity, candidate in
                    consumed.contains(identity) ? nil : candidate
                }
            )
            if !strategy.eligibleCandidates(inputs: inputs).isEmpty {
                quarantineReasons[surfaceId] = .ambiguousGlobalAssignment
            }
        }
    }

    private func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
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
        guard let batch = try? collectCandidateBatchSynchronously(contexts: contexts) else {
            return []
        }
        return reconcileBatch(batch, existing: existing).refsBySurface
            .sorted { $0.key < $1.key }
            .map { (surfaceId: $0.key, ref: $0.value) }
    }
}
