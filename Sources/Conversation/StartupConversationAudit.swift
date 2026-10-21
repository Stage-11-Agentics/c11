import Foundation

/// One launch's conversation audit. Restored panels await the phase their own
/// resume decision needs, so a slow scrape for one panel never holds back an
/// exact causal ref on another.
///
/// Phases run as one chain of detached tasks:
/// - `seeded`: store seed, ownership audit and journal owners, in memory only.
/// - `classified`: Codex launch-boundary markers, the recovery policy (dirty:
///   check each transcript off the actor; no-resume: mark refs not
///   resumable; clean: nothing), and the panels whose decision still depends
///   on a scrape.
/// - one scrape per kind, collecting only the panels that need it, then its
///   commit and, in dirty mode, the transcript check of what it applied.
///
/// Nothing here writes state because a phase failed or ran long. A failure is
/// reported in the `conversation.startup_audit` event and in each affected
/// panel's skip reason; persisted refs stay as they were for the next launch.
final class StartupConversationAudit: @unchecked Sendable {
    enum ScrapeOutcome: Sendable, Equatable {
        case applied
        case failed(String)
    }

    struct ScrapeResult: Sendable, Equatable {
        let outcome: ScrapeOutcome
        let collectMs: Int
        let commitMs: Int
    }

    /// What `classified` hands a restored panel: the launch's mode, the
    /// panels whose decision waits on a scrape, and that scrape per kind.
    struct Classification: Sendable {
        let mode: ResumeRecoveryMode
        let scrapeKindBySurface: [String: String]
        let scrapes: [String: Task<ScrapeResult, Never>]

        func scrape(forSurface surfaceId: String) -> Task<ScrapeResult, Never>? {
            scrapeKindBySurface[surfaceId].flatMap { scrapes[$0] }
        }
    }

    struct Environment: Sendable {
        var store: ConversationStore
        var pipeline: ScrapeCapturePipeline
        var registry: ConversationStrategyRegistry
        var filesystem: ConversationFilesystem
        var loadLaunchBoundaries: @Sendable (Set<String>) -> [CodexLaunchBoundaryMarker]
        var refreshOwners: @Sendable () -> Void
        var classificationReady: @Sendable () -> Void
        var report: @Sendable (StartupConversationAuditReport) -> Void
        /// QA seams for a slow or failing scrape (DEBUG builds set them from
        /// `C11_DEBUG_STARTUP_SCRAPE_DELAY_SECONDS` / `_FAIL`).
        var injectedScrapeDelay: TimeInterval = 0
        var injectedScrapeFailure: String?
    }

    static let shared = StartupConversationAudit()

    private let lock = NSLock()
    private var currentMode: ResumeRecoveryMode = .clean
    private var seededTask: Task<Void, Never>?
    private var classifiedTask: Task<Classification, Never>?
    private var completedTask: Task<StartupConversationAuditReport, Never>?
    private var mainSeedWaitMs: Int?

    init() {}

    var mode: ResumeRecoveryMode {
        lock.lock()
        defer { lock.unlock() }
        return currentMode
    }

    /// A launch with nothing to audit (restore off, no snapshot, or the store
    /// kill switch). Every await returns at once with no scrape dependents.
    func beginWithoutAudit(mode: ResumeRecoveryMode) {
        lock.lock()
        currentMode = mode
        seededTask = nil
        classifiedTask = nil
        completedTask = nil
        mainSeedWaitMs = nil
        lock.unlock()
    }

    /// How long launch blocked main on `awaitSeeded`, carried in the report.
    func recordMainSeedWait(ms: Int) {
        lock.lock()
        mainSeedWaitMs = ms
        lock.unlock()
    }

    func begin(
        mode: ResumeRecoveryMode,
        snapshot: AppSessionSnapshot,
        environment env: Environment
    ) {
        let scope = ConversationSnapshotCaptureScope(snapshot: snapshot)
        let records = WorkspaceSnapshotConversationBridge.records(from: snapshot)
        let startedAt = DispatchTime.now().uptimeNanoseconds

        // In memory only: launch blocks main on this phase.
        let seeded = Task.detached(priority: .userInitiated) { () -> Int in
            let seedStart = DispatchTime.now().uptimeNanoseconds
            _ = await env.store.seed(from: records)
            env.refreshOwners()
            return Self.elapsedMs(since: seedStart)
        }

        let classified = Task.detached(priority: .userInitiated) { () -> (Classification, markersMs: Int, classifyMs: Int, tiers: [String: Int]) in
            _ = await seeded.value
            let markersStart = DispatchTime.now().uptimeNanoseconds
            let markers = env.loadLaunchBoundaries(scope.markerSurfaceIds)
            _ = await env.store.applyCodexLaunchBoundaries(markers)
            let markersMs = Self.elapsedMs(since: markersStart)
            let classifyStart = DispatchTime.now().uptimeNanoseconds
            switch mode {
            case .dirty:
                await Self.verifyTranscripts(env: env, surfaceIds: nil)
            case .noResume:
                await env.store.markAllUnknown(reason: "app restart --no-resume")
            case .clean:
                break
            }
            _ = await env.store.auditGlobalOwnership()
            let conversations = await env.store.snapshot()
            let classifyMs = Self.elapsedMs(since: classifyStart)
            env.classificationReady()

            let scoped = mode == .noResume
                ? [:]
                : ScrapeCaptureContext.scoped(scope.scrapeContexts, to: conversations)
                    .filter { env.pipeline.scrapers.contains(kind: $0.key) }
            var scrapeKindBySurface: [String: String] = [:]
            for (kind, contexts) in scoped {
                for context in contexts
                where ScrapeCaptureContext.needsScrape(conversations[context.surfaceId]?.active) {
                    scrapeKindBySurface[context.surfaceId] = kind
                }
            }
            var scrapes: [String: Task<ScrapeResult, Never>] = [:]
            for (kind, contexts) in scoped {
                scrapes[kind] = Task.detached(priority: .utility) {
                    await Self.scrape(kind: kind, contexts: contexts, mode: mode, env: env)
                }
            }
            let tiers = Self.tierCounts(
                scope.scrapeContexts.filter { env.registry.contains(kind: $0.kind) },
                conversations
            )
            return (
                Classification(mode: mode, scrapeKindBySurface: scrapeKindBySurface, scrapes: scrapes),
                markersMs,
                classifyMs,
                tiers
            )
        }

        let completed = Task.detached(priority: .utility) { () -> StartupConversationAuditReport in
            let seedMs = await seeded.value
            let (classification, markersMs, classifyMs, tiers) = await classified.value
            var collectMs: [String: Int] = [:]
            var commitMs: [String: Int] = [:]
            var failures: [String: String] = [:]
            for (kind, task) in classification.scrapes {
                let result = await task.value
                collectMs[kind] = result.collectMs
                commitMs[kind] = result.commitMs
                if case .failed(let reason) = result.outcome {
                    failures[kind] = reason
                }
            }
            let report = StartupConversationAuditReport(
                mode: mode,
                seedMs: seedMs,
                markersMs: markersMs,
                classifyMs: classifyMs,
                collectMsByKind: collectMs,
                commitMsByKind: commitMs,
                totalMs: Self.elapsedMs(since: startedAt),
                mainSeedWaitMs: self.recordedMainSeedWait(),
                panelsByTier: tiers,
                scrapeDependentPanels: classification.scrapeKindBySurface.count,
                scrapeFailuresByKind: failures
            )
            env.report(report)
            return report
        }

        lock.lock()
        currentMode = mode
        mainSeedWaitMs = nil
        // Detached: launch blocks main on `awaitSeeded`, so these must not
        // inherit the caller's main-actor isolation.
        seededTask = Task.detached { _ = await seeded.value }
        classifiedTask = Task.detached { await classified.value.0 }
        completedTask = completed
        lock.unlock()
    }

    private func recordedMainSeedWait() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return mainSeedWaitMs
    }

    /// Returns once the store holds this launch's seed. Readers that persist
    /// the store (autosave) await this so they never write an unseeded store.
    func awaitSeeded() async {
        lock.lock()
        let task = seededTask
        lock.unlock()
        await task?.value
    }

    func awaitClassification() async -> Classification {
        lock.lock()
        let task = classifiedTask
        let mode = currentMode
        lock.unlock()
        guard let task else {
            return Classification(mode: mode, scrapeKindBySurface: [:], scrapes: [:])
        }
        return await task.value
    }

    /// The finished report, for tests and diagnostics. Nil without an audit.
    func awaitReport() async -> StartupConversationAuditReport? {
        lock.lock()
        let task = completedTask
        lock.unlock()
        return await task?.value
    }

    private static func scrape(
        kind: String,
        contexts: [ScrapeCaptureContext],
        mode: ResumeRecoveryMode,
        env: Environment
    ) async -> ScrapeResult {
        let collectStart = DispatchTime.now().uptimeNanoseconds
        if env.injectedScrapeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(env.injectedScrapeDelay * 1_000_000_000))
        }
        if let failure = env.injectedScrapeFailure {
            return ScrapeResult(
                outcome: .failed("startup scrape for \(kind) failed: \(failure)"),
                collectMs: elapsedMs(since: collectStart),
                commitMs: 0
            )
        }
        let batch: ScrapeCandidateBatch
        do {
            batch = try await env.pipeline.collectCandidateBatch(contexts: contexts)
        } catch {
            return ScrapeResult(
                outcome: .failed("startup scrape for \(kind) failed: \(error)"),
                collectMs: elapsedMs(since: collectStart),
                commitMs: 0
            )
        }
        let collectMs = elapsedMs(since: collectStart)
        let commitStart = DispatchTime.now().uptimeNanoseconds
        let commit = await env.store.applyScrapeBatch(batch, pipeline: env.pipeline)
        if mode == .dirty, !commit.applied.isEmpty {
            await verifyTranscripts(env: env, surfaceIds: Set(commit.applied.map(\.surfaceId)))
        }
        _ = await env.store.auditGlobalOwnership()
        return ScrapeResult(
            outcome: .applied,
            collectMs: collectMs,
            commitMs: elapsedMs(since: commitStart)
        )
    }

    /// Dirty-launch transcript check: stat off the actor, one walk per
    /// recursive store, then commit in one actor turn.
    private static func verifyTranscripts(env: Environment, surfaceIds: Set<String>?) async {
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await env.store.snapshot(),
            registry: env.registry,
            filesystem: SessionNameIndexFilesystem(base: env.filesystem),
            surfaceIds: surfaceIds
        )
        await env.store.applyCrashTranscriptVerdicts(verdicts)
    }

    private static func tierCounts(
        _ contexts: [ScrapeCaptureContext],
        _ conversations: [String: PanelConversations]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for context in contexts {
            let tier: String
            switch conversations[context.surfaceId]?.active {
            case nil: tier = "none"
            case let ref? where ref.placeholder: tier = "placeholder"
            case let ref? where ref.capturedVia.isCausal: tier = "causal"
            default: tier = "inferred"
            }
            counts[tier, default: 0] += 1
        }
        return counts
    }

    private static func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}

/// The `conversation.startup_audit` payload: where one launch's audit spent
/// its time, and what it found.
struct StartupConversationAuditReport: Sendable, Equatable {
    let mode: ResumeRecoveryMode
    let seedMs: Int
    let markersMs: Int
    let classifyMs: Int
    /// Per kind: collecting candidates, then committing them (including the
    /// dirty-mode transcript check of the refs the scrape applied).
    let collectMsByKind: [String: Int]
    let commitMsByKind: [String: Int]
    let totalMs: Int
    /// Main-thread wait at launch; nil when the report finished first.
    let mainSeedWaitMs: Int?
    /// Typed agent panels by the store's evidence after classification:
    /// `causal`, `inferred`, `placeholder`, `none`.
    let panelsByTier: [String: Int]
    let scrapeDependentPanels: Int
    let scrapeFailuresByKind: [String: String]

    var outcome: String {
        scrapeFailuresByKind.isEmpty ? "complete" : "scrape_failed"
    }
}
