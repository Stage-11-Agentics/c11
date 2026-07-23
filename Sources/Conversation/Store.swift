import Foundation
import Darwin

struct ConversationIdentity: Hashable, Sendable {
    let kind: String
    let id: String
}

enum ConversationLifecyclePayloadKey {
    static let invalidatedConversationID = "invalidated_conversation_id"
}

struct OwnershipAuditResult: Sendable, Equatable {
    let quarantinedSurfaceIds: [String]

    static let clean = OwnershipAuditResult(quarantinedSurfaceIds: [])
}

enum ConversationClaimResult: Sendable, Equatable {
    case accepted(ConversationRef)
    case expired
}

/// Durable, c11-owned evidence that the Codex wrapper crossed an interactive
/// process boundary before attempting the bounded socket claim. The marker is
/// retained even when the live Store acknowledges the claim: until a snapshot
/// containing the new lifecycle is durable, persistence/startup must not trust
/// an older exact owner on that surface.
struct CodexLaunchBoundaryMarker: Sendable, Equatable {
    let surfaceId: String
    let boundaryAt: Date
    let expectedResumeId: String?
}

enum CodexLaunchBoundaryMarkerStore {
    private static let socketRecordPrefix = "codex-launch-boundary-socket."

    static func directoryURL(socketPath: String) -> URL {
        URL(fileURLWithPath: socketPath + ".codex-launch-boundaries", isDirectory: true)
    }

    /// Read only c11-owned marker metadata: surface UUID, boundary timestamp,
    /// and optional expected resume UUID. No transcript content is involved.
    static func load(
        socketPath: String,
        allowedSurfaceIds: Set<String>? = nil,
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) -> [CodexLaunchBoundaryMarker] {
        let directory = directoryURL(socketPath: socketPath)
        guard isOwnedDirectory(
            atPath: directory.path,
            currentUserID: currentUserID
        ) else {
            return []
        }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            let surfaceId = url.lastPathComponent
            guard UUID(uuidString: surfaceId) != nil,
                  allowedSurfaceIds?.contains(surfaceId) != false,
                  isOwnedRegularFile(
                      atPath: url.path,
                      currentUserID: currentUserID
                  ),
                  let resourceValues = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .contentModificationDateKey,
                  ]),
                  resourceValues.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            let lines = text.components(separatedBy: .newlines)
            guard let rawEpoch = lines.first,
                  let epochSeconds = TimeInterval(rawEpoch) else {
                return nil
            }
            let rawExpected = lines.count > 1 ? String(lines[1]) : ""
            let expectedResumeId = UUID(uuidString: rawExpected) != nil
                ? rawExpected
                : nil
            return CodexLaunchBoundaryMarker(
                surfaceId: surfaceId,
                // The wrapper's portable `date +%s` payload is a readable
                // fallback only. APFS records the atomic marker write with
                // subsecond precision, which is required to order an exact
                // capture at second N + .1 before a launch at N + .9.
                boundaryAt: resourceValues.contentModificationDate
                    ?? Date(timeIntervalSince1970: epochSeconds),
                expectedResumeId: expectedResumeId
            )
        }
    }

    static func recordedSocketPathURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty,
            let stateDirectory = SocketControlSettings.stableSocketDirectoryURL(
                fileManager: fileManager
            ) else {
            return nil
        }
        let safeBundle = String(bundleIdentifier.unicodeScalars.map { scalar in
            let value = scalar.value
            let allowed = (value >= 48 && value <= 57)
                || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || scalar == "."
                || scalar == "-"
                || scalar == "_"
            return allowed ? Character(String(scalar)) : "-"
        })
        return stateDirectory.appendingPathComponent(
            socketRecordPrefix + safeBundle,
            isDirectory: false
        )
    }

    /// Persist the actual listener path after all collision/bind fallbacks.
    /// This bundle-scoped record lets the next process find markers before its
    /// own listener has started. It contains a socket path only.
    static func recordBoundSocketPath(
        _ socketPath: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        recordURL: URL? = nil
    ) {
        let trimmed = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.contains("\n"),
              trimmed.utf8.count <= 1_024,
              let recordURL = recordURL ?? recordedSocketPathURL(
                  bundleIdentifier: bundleIdentifier,
                  fileManager: fileManager
              ) else {
            return
        }
        try? fileManager.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? Data((trimmed + "\n").utf8).write(to: recordURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordURL.path
        )
    }

    /// At normal startup the listener has not bound yet, so
    /// `activeSocketPath(preferredPath:)` cannot reveal the prior process's
    /// fallback. Read markers from the preferred path and the prior actual
    /// bundle-scoped path, if present. A stale record is harmless: only UUID
    /// marker filenames and allowlisted marker metadata are read.
    static func loadForStartup(
        preferredSocketPath: String,
        allowedSurfaceIds: Set<String>,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        recordURL: URL? = nil,
        currentUserID: uid_t = getuid()
    ) -> [CodexLaunchBoundaryMarker] {
        var socketPaths = [preferredSocketPath]
        let resolvedRecordURL = recordURL ?? recordedSocketPathURL(
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        )
        if let resolvedRecordURL,
           isOwnedRegularFile(
               atPath: resolvedRecordURL.path,
               currentUserID: currentUserID
           ),
           let raw = try? String(contentsOf: resolvedRecordURL, encoding: .utf8),
           raw.utf8.count <= 1_025 {
            let recorded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if recorded.hasPrefix("/"),
               !recorded.contains("\n"),
               recorded.utf8.count <= 1_024,
               !socketPaths.contains(recorded) {
                socketPaths.append(recorded)
            }
        }
        return socketPaths.flatMap {
            load(
                socketPath: $0,
                allowedSurfaceIds: allowedSurfaceIds,
                fileManager: fileManager,
                currentUserID: currentUserID
            )
        }
    }

    private static func isOwnedDirectory(
        atPath path: String,
        currentUserID: uid_t
    ) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == currentUserID
            && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func isOwnedRegularFile(
        atPath path: String,
        currentUserID: uid_t
    ) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == currentUserID
            && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }
}

struct RuntimeEnvCaptureResult: Sendable, Equatable {
    enum Outcome: String, Sendable {
        case accepted
        case idempotent
        case quarantinedConflict
    }

    let outcome: Outcome
    let ref: ConversationRef
    let affectedSurfaceIds: [String]
}

struct AppliedConversationRef: Sendable, Equatable {
    let surfaceId: String
    let ref: ConversationRef
}

struct ScrapeCaptureCommitResult: Sendable, Equatable {
    let applied: [AppliedConversationRef]
    let quarantinedSurfaceIds: [String]
}

/// Lifecycle owner for `ConversationRef`s. Single source of truth in the
/// app process; held by `Workspace` (per-workspace store).
///
/// Reconciliation rule: evidence strength wins first (causal > inferred >
/// placeholder), then `capturedAt` and source priority resolve same-tier
/// candidates.
/// `wrapperClaim` is an atomic interactive-process boundary. Plain launches
/// invalidate prior exact ownership; an explicit expected resume id preserves
/// the existing ref only on an exact match. The target process's later causal
/// report remains authoritative.
///
/// Concurrency: the store is a Swift `actor`. All sync socket handlers
/// reach it via `Task { await … }` adapters (see CLI/c11.swift).
actor ConversationStore {
    /// Per-surface mapping. v1 uses one active ref + empty history.
    private var bySurface: [String: SurfaceConversations] = [:]

    init() {}

    /// Process-wide singleton. Held outside `Workspace` because:
    /// - the CLI dispatcher resolves surface IDs across all workspaces,
    /// - the snapshot store reads/writes refs without going through a
    ///   specific workspace,
    /// - per-workspace partitioning would require duplicate seed/snapshot
    ///   code paths for no isolation benefit (surface IDs are app-unique).
    static let shared = ConversationStore()
}

/// Architecture-level kill switch (`CMUX_DISABLE_CONVERSATION_STORE=1`).
/// When set in the app's launch environment, c11 falls back to the
/// legacy `claude.session_id` reserved-metadata path (the bridge
/// already understands it); the new wrapper-claim/push/scrape paths
/// no-op.
///
/// **Removed in 0.46.0 / v1.1** alongside the legacy metadata bridge.
/// Tracked TODO marker.
enum ConversationStorePolicy {
    /// True iff the env var is set to a truthy value.
    static var isDisabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_DISABLE_CONVERSATION_STORE"] else {
            return false
        }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}

extension ConversationStore {
    // MARK: - Read

    func conversations(for surfaceId: String) -> SurfaceConversations {
        bySurface[surfaceId] ?? .empty
    }

    func active(for surfaceId: String) -> ConversationRef? {
        bySurface[surfaceId]?.active
    }

    func snapshot() -> [String: SurfaceConversations] {
        bySurface
    }

    /// Fail-close any unacknowledged Codex launch boundary before scrape,
    /// suspension, or persistence can trust an owner from the prior process.
    ///
    /// A newer target runtime capture wins by timestamp. An exact explicit
    /// resume intent may preserve the same prior id. Plain or mismatched
    /// intent replaces every older owner with a real placeholder, matching
    /// the acknowledged `claim` path without permitting a late claim to
    /// regress the target that already started.
    @discardableResult
    func applyCodexLaunchBoundaries(
        _ markers: [CodexLaunchBoundaryMarker]
    ) -> [String] {
        var applied: [String] = []
        for marker in markers.sorted(by: {
            if $0.boundaryAt == $1.boundaryAt {
                return $0.surfaceId < $1.surfaceId
            }
            return $0.boundaryAt < $1.boundaryAt
        }) {
            let existing = bySurface[marker.surfaceId]?.active
            if let existing, existing.capturedAt >= marker.boundaryAt {
                continue
            }
            if let expectedResumeId = marker.expectedResumeId,
               let existing,
               existing.kind == "codex",
               !existing.placeholder,
               existing.id == expectedResumeId {
                continue
            }

            var payload: [String: PersistedJSONValue]? = nil
            if let existing, !existing.placeholder, !existing.id.isEmpty {
                payload = [
                    ConversationLifecyclePayloadKey.invalidatedConversationID: .string(existing.id)
                ]
            }
            let placeholder = ConversationRef(
                kind: "codex",
                id: "wrapper-claim:\(marker.surfaceId):durable-boundary",
                placeholder: true,
                cwd: existing?.cwd,
                capturedAt: marker.boundaryAt,
                capturedVia: .wrapperClaim,
                state: .unknown,
                diagnosticReason: "Codex launch boundary newer than durable owner",
                payload: payload
            )
            var conversations = bySurface[marker.surfaceId] ?? .empty
            conversations.active = placeholder
            bySurface[marker.surfaceId] = conversations
            applied.append(marker.surfaceId)
        }
        _ = auditGlobalOwnership()
        return applied
    }

    // MARK: - Bulk seed (used by snapshot restore)

    /// Replace the entire store contents in one shot. Called once on
    /// snapshot restore to seed from `SessionPanelSnapshot.surfaceConversations`.
    @discardableResult
    func seed(from records: [String: SurfaceConversations]) -> OwnershipAuditResult {
        bySurface = records
        return auditGlobalOwnership()
    }

    // MARK: - Write

    /// Apply a wrapper launch boundary. Codex plain/mismatched launches
    /// invalidate prior exact ownership; exact Codex resume intent may
    /// preserve the same id while the target process starts. Other kinds keep
    /// the conservative wrapper rule: a claim never displaces exact evidence.
    @discardableResult
    func claim(
        surfaceId: String,
        kind: String,
        cwd: String?,
        placeholderId: String,
        capturedAt: Date = Date(),
        diagnosticReason: String? = nil,
        expectedResumeId: String? = nil
    ) -> ConversationRef {
        switch claim(
            surfaceId: surfaceId,
            kind: kind,
            cwd: cwd,
            placeholderId: placeholderId,
            capturedAt: capturedAt,
            diagnosticReason: diagnosticReason,
            expectedResumeId: expectedResumeId,
            expiresAt: nil
        ) {
        case .accepted(let ref):
            return ref
        case .expired:
            // `nil` never expires; retain an exhaustive fallback so the
            // legacy return shape stays total if the implementation changes.
            return bySurface[surfaceId]?.active ?? ConversationRef(
                kind: kind,
                id: placeholderId,
                placeholder: true,
                cwd: cwd,
                capturedAt: capturedAt,
                capturedVia: .wrapperClaim,
                state: .unknown,
                diagnosticReason: diagnosticReason ?? "wrapper-claim placeholder"
            )
        }
    }

    /// Expiring wrapper claim used by the launch handshake. Expiry is checked
    /// inside the actor immediately before mutation; a request that timed out
    /// in the wrapper cannot land later after the real Codex process starts.
    @discardableResult
    func claim(
        surfaceId: String,
        kind: String,
        cwd: String?,
        placeholderId: String,
        capturedAt: Date = Date(),
        diagnosticReason: String? = nil,
        expectedResumeId: String? = nil,
        expiresAt: Date?
    ) -> ConversationClaimResult {
        if let expiresAt, expiresAt <= Date() {
            return .expired
        }

        let existing = bySurface[surfaceId]?.active

        var payload: [String: PersistedJSONValue]? = nil
        if kind == "codex" {
            // An exact `codex resume <uuid>` argv is lifecycle intent, not new
            // causal identity. Preserve only an exact match. Plain launches
            // and mismatched manual resumes atomically replace the old
            // lifecycle with a placeholder until runtimeEnv or safe scrape
            // evidence identifies it.
            if let expectedResumeId,
               let existing,
               existing.kind == kind,
               !existing.placeholder,
               existing.id == expectedResumeId {
                return .accepted(existing)
            }

            if let existing,
               existing.kind == kind,
               !existing.placeholder,
               !existing.id.isEmpty {
                payload = [
                    ConversationLifecyclePayloadKey.invalidatedConversationID: .string(existing.id)
                ]
            } else if case .string(let invalidatedId)? = existing?.payload?[
                ConversationLifecyclePayloadKey.invalidatedConversationID
            ] {
                payload = [
                    ConversationLifecyclePayloadKey.invalidatedConversationID: .string(invalidatedId)
                ]
            }
        } else if let existing, existing.capturedVia != .wrapperClaim {
            // Claude's wrapper claim is intentionally backgrounded; its
            // SessionStart hook can win the race and land first. Retain all
            // exact non-wrapper evidence so a delayed claim cannot regress it.
            return .accepted(existing)
        }

        let claim = ConversationRef(
            kind: kind,
            id: placeholderId,
            placeholder: true,
            cwd: cwd,
            capturedAt: capturedAt,
            capturedVia: .wrapperClaim,
            state: .unknown,
            diagnosticReason: diagnosticReason ?? "wrapper-claim placeholder",
            payload: payload
        )

        if let existing, existing.capturedVia == .wrapperClaim {
            // Duplicate delivery of the same launch boundary is idempotent;
            // a later boundary refreshes the placeholder/activity floor.
            if existing.capturedAt >= capturedAt {
                return .accepted(existing)
            }
        }
        var snap = bySurface[surfaceId] ?? .empty
        snap.active = claim
        bySurface[surfaceId] = snap
        return .accepted(claim)
    }

    /// Apply a generic hook, scrape, or manual push. Runtime-environment
    /// capture and wrapper claims are reserved to their dedicated mutation
    /// seams and return `nil` without touching the store.
    ///
    /// Causal hooks are sticky against inferred sources. State defaults to
    /// `.alive`; callers pass `.tombstoned` or other states explicitly when
    /// warranted.
    @discardableResult
    func push(
        surfaceId: String,
        kind: String,
        id: String,
        source: CaptureSource,
        cwd: String? = nil,
        capturedAt: Date = Date(),
        state: ConversationState = .alive,
        diagnosticReason: String? = nil,
        payload: [String: PersistedJSONValue]? = nil
    ) -> ConversationRef? {
        guard source == .hook || source == .scrape || source == .manual else {
            return nil
        }
        let ref = ConversationRef(
            kind: kind,
            id: id,
            placeholder: false,
            cwd: cwd,
            capturedAt: capturedAt,
            capturedVia: source,
            state: state,
            diagnosticReason: diagnosticReason,
            payload: payload
        )
        _ = reconcile(surfaceId: surfaceId, candidate: ref)
        _ = auditGlobalOwnership()
        return bySurface[surfaceId]?.active ?? ref
    }

    /// Apply exact identity read by the target Codex subprocess. This is a
    /// separate mutation seam because causal lifecycle changes must not be
    /// subjected to inferred timestamp tiebreaking.
    @discardableResult
    func captureRuntimeEnv(
        surfaceId: String,
        id: String,
        cwd: String?,
        capturedAt: Date = Date()
    ) -> RuntimeEnvCaptureResult {
        let existing = bySurface[surfaceId]?.active
        let isIdempotent = existing?.kind == "codex"
            && existing?.id == id
            && existing?.capturedVia == .runtimeEnv
            && existing?.quarantineReason == nil

        if isIdempotent, let existing {
            return RuntimeEnvCaptureResult(
                outcome: .idempotent,
                ref: existing,
                affectedSurfaceIds: []
            )
        }

        let ref = ConversationRef(
            kind: "codex",
            id: id,
            placeholder: false,
            cwd: cwd,
            capturedAt: capturedAt,
            capturedVia: .runtimeEnv,
            state: .alive,
            diagnosticReason: "exact id captured from target runtime environment"
        )
        var snap = bySurface[surfaceId] ?? .empty
        // A new runtime id on this same live surface is a new causal lifecycle
        // event. Replace the prior active id before the global ownership audit;
        // the audit will quarantine conflicts rather than timestamp-winning.
        snap.active = ref
        bySurface[surfaceId] = snap

        let audit = auditGlobalOwnership()
        let stored = bySurface[surfaceId]?.active ?? ref
        return RuntimeEnvCaptureResult(
            outcome: stored.isQuarantined ? .quarantinedConflict : .accepted,
            ref: stored,
            affectedSurfaceIds: audit.quarantinedSurfaceIds
        )
    }

    /// Apply a scrape result. Same reconciliation rule as `push`. This is
    /// the canonical write entry for the live scrape-capture pipeline and the
    /// name downstream kinds (pi, omp) build against.
    @discardableResult
    func applyScrape(
        surfaceId: String,
        ref: ConversationRef
    ) -> ConversationRef {
        _ = reconcile(surfaceId: surfaceId, candidate: ref)
        _ = auditGlobalOwnership()
        return bySurface[surfaceId]?.active ?? ref
    }

    /// Live scrape-capture driver. Runs the pure `ScrapeCapturePipeline`
    /// against the current store contents (so claim-time / push filters see
    /// the seeded refs), then applies each scrape-derived ref under actor
    /// isolation. Returns what was applied, for diagnostics.
    ///
    /// This is the runtime call the architecture finding identified as
    /// missing: it is the single place that connects scrapers → strategies →
    /// store at restore, lighting up codex (and future pi/omp) resume.
    @discardableResult
    func runScrapeCapture(
        contexts: [ScrapeCaptureContext],
        pipeline: ScrapeCapturePipeline
    ) async throws -> ScrapeCaptureCommitResult {
        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        return applyScrapeBatch(batch, pipeline: pipeline)
    }

    /// Commit a previously collected batch in one non-suspending actor turn.
    /// Runtime causal reports that landed while collection was in flight are
    /// read from current `bySurface` here and cannot be overwritten by a stale
    /// inferred proposal.
    @discardableResult
    func applyScrapeBatch(
        _ batch: ScrapeCandidateBatch,
        pipeline: ScrapeCapturePipeline
    ) -> ScrapeCaptureCommitResult {
        var working = bySurface
        let plan = pipeline.reconcileBatch(batch, existing: working)
        var appliedSurfaceIds = Set<String>()

        for (surfaceId, reason) in plan.quarantineReasonsBySurface {
            Self.quarantine(
                surfaceId: surfaceId,
                reason: reason,
                records: &working
            )
        }

        for (surfaceId, ref) in plan.refsBySurface {
            var conversations = working[surfaceId] ?? .empty
            if let existing = conversations.active,
               !Self._testShouldReplace(existing: existing, candidate: ref) {
                continue
            }
            conversations.active = ref
            working[surfaceId] = conversations
            appliedSurfaceIds.insert(surfaceId)
        }

        let audit = Self.auditGlobalOwnership(records: &working)
        bySurface = working
        let applied = appliedSurfaceIds.sorted().compactMap { surfaceId in
            bySurface[surfaceId]?.active.map {
                AppliedConversationRef(surfaceId: surfaceId, ref: $0)
            }
        }
        let quarantined = Set(audit.quarantinedSurfaceIds)
            .union(plan.quarantineReasonsBySurface.keys)
            .sorted()
        return ScrapeCaptureCommitResult(
            applied: applied,
            quarantinedSurfaceIds: quarantined
        )
    }

    /// Mark the surface's active ref as tombstoned. Operator-initiated
    /// (`c11 conversation tombstone`) or strategy-confirmed (Claude with
    /// hook history + missing session file).
    func tombstone(
        surfaceId: String,
        reason: String?,
        at: Date = Date()
    ) {
        guard var snap = bySurface[surfaceId], var active = snap.active else { return }
        active.state = .tombstoned
        active.capturedAt = at
        active.diagnosticReason = reason ?? "tombstoned"
        snap.active = active
        bySurface[surfaceId] = snap
    }

    /// Bulk-suspend all alive refs. Called from `applicationWillTerminate`
    /// before the snapshot is written so resume on next launch is gated
    /// on `state = .suspended`.
    func suspendAllAlive(at: Date = Date()) {
        for (key, var snap) in bySurface {
            if var active = snap.active, active.state == .alive {
                active.state = .suspended
                active.capturedAt = at
                snap.active = active
                bySurface[key] = snap
            }
        }
    }

    /// Bulk-transition all active refs to `.unknown`. A blunt primitive
    /// retained for tests that model "no on-disk evidence available."
    /// Production crash recovery uses `reclassifyAfterCrash`, which verifies
    /// each ref against its transcript before deciding.
    func markAllUnknown(at: Date = Date(), reason: String = "crash recovery (dirty sentinel)") {
        for (key, var snap) in bySurface {
            if var active = snap.active {
                active.state = .unknown
                active.capturedAt = at
                active.diagnosticReason = reason
                snap.active = active
                bySurface[key] = snap
            }
        }
    }

    /// Crash-recovery reclassification. Replaces the blanket `markAllUnknown`
    /// on the dirty-sentinel path: instead of forcing every ref to
    /// `.unknown` (which made `resume()` skip the very case it exists for),
    /// verify each resumable ref against on-disk evidence via its strategy.
    ///
    /// For each active ref currently `.alive` or `.suspended`:
    /// - strategy confirms the transcript on disk → `.suspended`
    ///   ("crash recovery: transcript verified on disk"), so the resume
    ///   strategy will type `claude … --resume <id>` on next restore.
    /// - strategy reports missing → `.unknown`
    ///   ("crash recovery: transcript not found").
    /// - strategy cannot verify → `.unknown`
    ///   ("crash recovery: transcript verification unavailable").
    ///
    /// Refs already `.unknown`, `.tombstoned`, or `.unsupported` are left
    /// untouched. This preserves the `/exit`-no-resume contract (a SessionEnd
    /// tombstone stays a tombstone) and keeps unsupported kinds resumable by
    /// a future binary.
    ///
    /// Verification routes through the strategy seam
    /// (`ConversationStrategy.transcriptExists`) so other TUI kinds can add
    /// their own checks later. The filesystem is injectable for tests;
    /// production passes `DefaultConversationFilesystem`. Stat only — never
    /// opens transcript bytes.
    func reclassifyAfterCrash(
        registry: ConversationStrategyRegistry,
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        at: Date = Date()
    ) {
        for (key, var snap) in bySurface {
            guard var active = snap.active else { continue }
            guard active.state == .alive || active.state == .suspended else { continue }
            let verification = registry
                .strategy(forKind: active.kind)?
                .transcriptExists(for: active, filesystem: filesystem)
            switch verification {
            case .some(let exists):
                if exists {
                    active.state = .suspended
                    active.diagnosticReason = "crash recovery: transcript verified on disk"
                } else {
                    active.state = .unknown
                    active.diagnosticReason = "crash recovery: transcript not found"
                }
            case .none:
                active.state = .unknown
                active.diagnosticReason = "crash recovery: transcript verification unavailable"
            }
            active.capturedAt = at
            snap.active = active
            bySurface[key] = snap
        }
    }

    /// Wipe a surface's conversations. Operator escape hatch
    /// (`c11 conversation clear`).
    func clear(surfaceId: String) {
        bySurface.removeValue(forKey: surfaceId)
    }

    /// Process-wide ownership audit. Called after snapshot seed and every
    /// exact-id mutation; no observer can see a newly duplicated resumable id
    /// or a noncausal Codex owner in a repeated normalized cwd.
    @discardableResult
    func auditGlobalOwnership() -> OwnershipAuditResult {
        Self.auditGlobalOwnership(records: &bySurface)
    }

    // MARK: - Reconciliation

    /// Apply the reconciliation rule. Returns the chosen winner (`nil` if
    /// the candidate lost outright). The store always contains the winner
    /// after this call; the return value is the same ref the caller passed
    /// in iff the candidate won.
    @discardableResult
    private func reconcile(
        surfaceId: String,
        candidate: ConversationRef
    ) -> ConversationRef? {
        var snap = bySurface[surfaceId] ?? .empty
        guard let existing = snap.active else {
            snap.active = candidate
            bySurface[surfaceId] = snap
            return candidate
        }
        if shouldReplace(existing: existing, candidate: candidate) {
            snap.active = candidate
            bySurface[surfaceId] = snap
            return candidate
        }
        return nil
    }

    private static func auditGlobalOwnership(
        records: inout [String: SurfaceConversations]
    ) -> OwnershipAuditResult {
        var grouped: [ConversationIdentity: [(surfaceId: String, ref: ConversationRef)]] = [:]
        for (surfaceId, conversations) in records {
            guard let ref = conversations.active,
                  !ref.placeholder,
                  !ref.id.isEmpty,
                  ref.state != .tombstoned,
                  ref.state != .unsupported else { continue }
            grouped[ConversationIdentity(kind: ref.kind, id: ref.id), default: []]
                .append((surfaceId, ref))
        }

        var affected = Set<String>()
        for entries in grouped.values where entries.count > 1 {
            let causal = entries.filter { $0.ref.hasCausalExactEvidence }
            if causal.count == 1, let causalSurface = causal.first?.surfaceId {
                for entry in entries where entry.surfaceId != causalSurface {
                    quarantine(
                        surfaceId: entry.surfaceId,
                        reason: .displacedByCausalOwner,
                        records: &records
                    )
                    affected.insert(entry.surfaceId)
                }
            } else {
                let reason: ConversationQuarantineReason = causal.count > 1
                    ? .conflictingCausalIdentity
                    : .duplicateInferredIdentity
                for entry in entries {
                    quarantine(
                        surfaceId: entry.surfaceId,
                        reason: reason,
                        records: &records
                    )
                    affected.insert(entry.surfaceId)
                }
            }
        }

        // Same cwd is exclusion-only for inferred Codex ownership. Run this
        // from the Store rather than only from typed scrape contexts: snapshot
        // seeding intentionally accepts persisted refs from terminal panels
        // whose terminal_type metadata is missing or empty.
        let codexCwdGroups = Dictionary(
            grouping: records.compactMap {
                (surfaceId, conversations) -> (
                    cwd: String,
                    surfaceId: String,
                    ref: ConversationRef
                )? in
                guard let ref = conversations.active,
                      ref.kind == "codex",
                      ref.state != .tombstoned,
                      ref.state != .unsupported,
                      let cwd = normalizedCodexOwnershipCwd(ref.cwd) else {
                    return nil
                }
                return (cwd, surfaceId, ref)
            },
            by: { $0.cwd }
        )
        for entries in codexCwdGroups.values where entries.count > 1 {
            for entry in entries
                where !entry.ref.isEligibleCausalOwner
                    && entry.ref.quarantineReason == nil {
                quarantine(
                    surfaceId: entry.surfaceId,
                    reason: .sameCwdWithoutCausalIdentity,
                    records: &records
                )
                affected.insert(entry.surfaceId)
            }
        }
        return OwnershipAuditResult(quarantinedSurfaceIds: affected.sorted())
    }

    private static func normalizedCodexOwnershipCwd(_ cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private static func quarantine(
        surfaceId: String,
        reason: ConversationQuarantineReason,
        records: inout [String: SurfaceConversations]
    ) {
        var conversations = records[surfaceId] ?? .empty
        var ref = conversations.active ?? ConversationRef(
            kind: "codex",
            id: "quarantine:\(surfaceId)",
            placeholder: true,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        ref.state = .unknown
        ref.quarantineReason = reason
        ref.diagnosticReason = "quarantined:\(reason.rawValue)"
        conversations.active = ref
        records[surfaceId] = conversations
    }

    /// The reconciliation rule. Evidence strength wins first. Within one
    /// tier, latest `capturedAt` wins; source priority breaks close ties.
    /// Wrapper-claim remains conservative and never displaces stronger
    /// evidence regardless of timestamp.
    ///
    /// C11-24 review (M2): single source of truth. The actor calls
    /// through to the nonisolated static so the rule cannot drift between
    /// the production path and the test predicate.
    private static let closeTimeWindow: TimeInterval = 0.5

    func shouldReplace(existing: ConversationRef, candidate: ConversationRef) -> Bool {
        return Self._testShouldReplace(existing: existing, candidate: candidate)
    }
}

extension ConversationStore {
    /// Synchronous reconciliation predicate. Reused by the actor's
    /// `shouldReplace` and exposed for state-machine unit tests so
    /// neither side has to construct an actor or duplicate the rule.
    static func _testShouldReplace(
        existing: ConversationRef,
        candidate: ConversationRef
    ) -> Bool {
        // Evidence strength is sticky across time. A scrape/manual write can
        // never displace a causal runtime/hook ref, and causal evidence always
        // replaces an inferred or placeholder ref on the same surface.
        if candidate.capturedVia.evidenceTier != existing.capturedVia.evidenceTier {
            return candidate.capturedVia.evidenceTier > existing.capturedVia.evidenceTier
        }
        // Wrapper-claim never replaces non-wrapperClaim sources.
        if candidate.capturedVia == .wrapperClaim, existing.capturedVia != .wrapperClaim {
            return false
        }
        let dt = candidate.capturedAt.timeIntervalSince(existing.capturedAt)
        if dt > closeTimeWindow {
            return true
        }
        if dt < -closeTimeWindow {
            return false
        }
        // Within the close-time window: source priority wins.
        return candidate.capturedVia.priority > existing.capturedVia.priority
    }
}
