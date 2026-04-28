import Foundation

/// Lifecycle owner for `ConversationRef`s. Single source of truth in the
/// app process; held by `Workspace` (per-workspace store).
///
/// Reconciliation rule: latest `capturedAt` wins, with source-priority
/// tiebreaker (`hook > scrape > manual > wrapperClaim`) on close timestamps.
/// `wrapperClaim` is idempotent and conservative: it only writes if the
/// existing ref is older AND of equal-or-lower provenance, so an operator
/// who types `claude` twice in the same surface cannot regress a real id
/// back to a placeholder.
///
/// Concurrency: the store is a Swift `actor`. All sync socket handlers
/// reach it via `Task { await … }` adapters (see CLI/c11.swift).
public actor ConversationStore {
    /// Per-surface mapping. v1 uses one active ref + empty history.
    private var bySurface: [String: SurfaceConversations] = [:]

    public init() {}

    /// Process-wide singleton. Held outside `Workspace` because:
    /// - the CLI dispatcher resolves surface IDs across all workspaces,
    /// - the snapshot store reads/writes refs without going through a
    ///   specific workspace,
    /// - per-workspace partitioning would require duplicate seed/snapshot
    ///   code paths for no isolation benefit (surface IDs are app-unique).
    public static let shared = ConversationStore()
}

/// Architecture-level kill switch (`CMUX_DISABLE_CONVERSATION_STORE=1`).
/// When set in the app's launch environment, c11 falls back to the
/// legacy `claude.session_id` reserved-metadata path (the bridge
/// already understands it); the new wrapper-claim/push/scrape paths
/// no-op.
///
/// **Removed in 0.46.0 / v1.1** alongside the legacy metadata bridge.
/// Tracked TODO marker.
public enum ConversationStorePolicy {
    /// True iff the env var is set to a truthy value.
    public static var isDisabled: Bool {
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

    public func conversations(for surfaceId: String) -> SurfaceConversations {
        bySurface[surfaceId] ?? .empty
    }

    public func active(for surfaceId: String) -> ConversationRef? {
        bySurface[surfaceId]?.active
    }

    public func snapshot() -> [String: SurfaceConversations] {
        bySurface
    }

    // MARK: - Bulk seed (used by snapshot restore)

    /// Replace the entire store contents in one shot. Called once on
    /// snapshot restore to seed from `SessionPanelSnapshot.surfaceConversations`.
    public func seed(from records: [String: SurfaceConversations]) {
        bySurface = records
    }

    // MARK: - Write

    /// Apply a wrapper-claim. Conservative: only writes if the existing
    /// ref is older AND of equal-or-lower provenance. Hooks and scrapes
    /// always win regardless of timestamp.
    @discardableResult
    public func claim(
        surfaceId: String,
        kind: String,
        cwd: String?,
        placeholderId: String,
        capturedAt: Date = Date(),
        diagnosticReason: String? = nil
    ) -> ConversationRef {
        let claim = ConversationRef(
            kind: kind,
            id: placeholderId,
            placeholder: true,
            cwd: cwd,
            capturedAt: capturedAt,
            capturedVia: .wrapperClaim,
            state: .unknown,
            diagnosticReason: diagnosticReason ?? "wrapper-claim placeholder"
        )

        let existing = bySurface[surfaceId]?.active
        if let existing {
            // Idempotent: a second wrapper-claim cannot regress a real id.
            // Hooks/scrapes/manual always win over wrapperClaim regardless
            // of timestamp.
            if existing.capturedVia != .wrapperClaim {
                return existing
            }
            // Same source: keep the newer timestamp.
            if existing.capturedAt >= capturedAt {
                return existing
            }
        }
        var snap = bySurface[surfaceId] ?? .empty
        snap.active = claim
        bySurface[surfaceId] = snap
        return claim
    }

    /// Apply a push (hook or manual). Hooks outrank everything except a
    /// strictly newer push or scrape. State defaults to `.alive`; callers
    /// pass `.tombstoned` or other states explicitly when warranted.
    @discardableResult
    public func push(
        surfaceId: String,
        kind: String,
        id: String,
        source: CaptureSource,
        cwd: String? = nil,
        capturedAt: Date = Date(),
        state: ConversationState = .alive,
        diagnosticReason: String? = nil,
        payload: [String: PersistedJSONValue]? = nil
    ) -> ConversationRef {
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
        return reconcile(surfaceId: surfaceId, candidate: ref) ?? ref
    }

    /// Apply a scrape result. Same reconciliation rule as `push`.
    @discardableResult
    public func recordScrape(
        surfaceId: String,
        ref: ConversationRef
    ) -> ConversationRef {
        return reconcile(surfaceId: surfaceId, candidate: ref) ?? ref
    }

    /// Mark the surface's active ref as tombstoned. Operator-initiated
    /// (`c11 conversation tombstone`) or strategy-confirmed (Claude with
    /// hook history + missing session file).
    public func tombstone(
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
    public func suspendAllAlive(at: Date = Date()) {
        for (key, var snap) in bySurface {
            if var active = snap.active, active.state == .alive {
                active.state = .suspended
                active.capturedAt = at
                snap.active = active
                bySurface[key] = snap
            }
        }
    }

    /// Bulk-transition all active refs to `.unknown`. Called on crash
    /// recovery before the forced pull-scrape pass classifies them.
    public func markAllUnknown(at: Date = Date(), reason: String = "crash recovery") {
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

    /// Wipe a surface's conversations. Operator escape hatch
    /// (`c11 conversation clear`).
    public func clear(surfaceId: String) {
        bySurface.removeValue(forKey: surfaceId)
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

    /// The reconciliation rule. Latest `capturedAt` wins; on close
    /// timestamps, source priority (`hook > scrape > manual > wrapperClaim`)
    /// breaks the tie. Wrapper-claim is conservative: never displaces a
    /// non-wrapperClaim source regardless of timestamp.
    private static let closeTimeWindow: TimeInterval = 0.5

    func shouldReplace(existing: ConversationRef, candidate: ConversationRef) -> Bool {
        // Wrapper-claim never replaces non-wrapperClaim sources.
        if candidate.capturedVia == .wrapperClaim, existing.capturedVia != .wrapperClaim {
            return false
        }
        let dt = candidate.capturedAt.timeIntervalSince(existing.capturedAt)
        if dt > Self.closeTimeWindow {
            return true
        }
        if dt < -Self.closeTimeWindow {
            return false
        }
        // Within the close-time window: source priority wins.
        return candidate.capturedVia.priority > existing.capturedVia.priority
    }
}

extension ConversationStore {
    /// Test-only synchronous reconciliation predicate. Same logic as
    /// `shouldReplace(existing:candidate:)` but exposed as a static so
    /// state-machine unit tests don't have to construct an actor.
    public static func _testShouldReplace(
        existing: ConversationRef,
        candidate: ConversationRef
    ) -> Bool {
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
        return candidate.capturedVia.priority > existing.capturedVia.priority
    }
}
