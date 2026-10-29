import Foundation
import Darwin

struct ConversationIdentity: Hashable, Sendable {
    let kind: String
    let id: String
}

enum ConversationLifecyclePayloadKey {
    static let invalidatedConversationID = "invalidated_conversation_id"
    static let expectedResumeID = "expected_resume_id"
    static let resumeExpiresAtEpochMs = "resume_expires_at_epoch_ms"
    static let openCodeTuiPID = "opencode_tui_pid"
    static let openCodeRecoveryContextVersion = OpencodeRecoveryStoreContextKey.version
    static let openCodeRecoveryHome = OpencodeRecoveryStoreContextKey.home
    static let openCodeRecoveryXDGDataHome = OpencodeRecoveryStoreContextKey.xdgDataHome
    static let openCodeRecoveryDatabaseOverride = OpencodeRecoveryStoreContextKey.databaseOverride

    /// These fields are written only by the authenticated wrapper-claim seam.
    /// A generic hook payload must never mint or replace them.
    static let genericPushReservedKeys: Set<String> = [
        openCodeTuiPID,
        openCodeRecoveryContextVersion,
        openCodeRecoveryHome,
        openCodeRecoveryXDGDataHome,
        openCodeRecoveryDatabaseOverride,
    ]
}

struct OwnershipAuditResult: Sendable, Equatable {
    let quarantinedSurfaceIds: [String]

    static let clean = OwnershipAuditResult(quarantinedSurfaceIds: [])
}

enum ConversationClaimResult: Sendable, Equatable {
    case accepted(ConversationRef)
    case expired
}

enum DisplayedOpenCodeCaptureResult: Sendable, Equatable {
    case accepted(ConversationRef)
    case conflict(ownerSurfaceIds: [String], preservedRef: ConversationRef?)
    case unauthorized
}

enum OpenCodeUnboundRouteResult: Sendable, Equatable {
    case accepted(ConversationRef)
    case unauthorized
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

/// Whether a ref's transcript exists (`nil`: its kind cannot verify), and the
/// id it was computed for.
struct CrashTranscriptVerdict: Sendable, Equatable {
    let id: String
    let exists: Bool?
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
    private var bySurface: [String: PanelConversations] = [:] {
        didSet {
            guard self === Self.shared, !ConversationStorePolicy.isDisabled else { return }
            for key in Set(oldValue.keys).union(bySurface.keys) {
                guard oldValue[key]?.active != bySurface[key]?.active, let panelID = UUID(uuidString: key) else { continue }
                let ref = bySurface[key]?.active
                let owner = ref.flatMap { $0.isEligibleCausalOwner
                    ? JournalOwner(panelID: panelID, agentKind: $0.kind, sessionID: $0.id) : nil }
                JournalCoordinator.shared.setOwner(panelID: panelID, owner: owner)
            }
        }
    }

    /// Socket-authenticated wrapper claims only. Persisted PID metadata marks
    /// a v2 ref for conservative routing after restart, but it is not proof
    /// that the current socket peer is still that TUI process.
    private var authenticatedOpenCodeTuiPIDBySurface: [String: Int32] = [:]

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

    func conversations(for surfaceId: String) -> PanelConversations {
        bySurface[surfaceId] ?? .empty
    }

    func active(for surfaceId: String) -> ConversationRef? {
        bySurface[surfaceId]?.active
    }

    func snapshot() -> [String: PanelConversations] {
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
    func seed(from records: [String: PanelConversations]) -> OwnershipAuditResult {
        bySurface = records
        authenticatedOpenCodeTuiPIDBySurface.removeAll()
        return auditGlobalOwnership()
    }

    // MARK: - Write

    /// Apply a wrapper launch boundary. Codex plain/mismatched launches
    /// invalidate prior exact ownership; exact Codex resume intent may
    /// preserve the same id while the target process starts. OpenCode stores
    /// an exact resumed ID as a reservation until that panel's TUI confirms
    /// its displayed root. Other kinds keep their existing wrapper rule.
    @discardableResult
    func claim(
        surfaceId: String,
        kind: String,
        cwd: String?,
        placeholderId: String,
        capturedAt: Date = Date(),
        diagnosticReason: String? = nil,
        expectedResumeId: String? = nil,
        interactivePID: Int32? = nil,
        openCodeRecoveryPayload: [String: PersistedJSONValue]? = nil
    ) -> ConversationRef {
        switch claim(
            surfaceId: surfaceId,
            kind: kind,
            cwd: cwd,
            placeholderId: placeholderId,
            capturedAt: capturedAt,
            diagnosticReason: diagnosticReason,
            expectedResumeId: expectedResumeId,
            interactivePID: interactivePID,
            openCodeRecoveryPayload: openCodeRecoveryPayload,
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
        interactivePID: Int32? = nil,
        openCodeRecoveryPayload: [String: PersistedJSONValue]? = nil,
        expiresAt: Date?
    ) -> ConversationClaimResult {
        if let expiresAt, expiresAt <= Date() {
            return .expired
        }

        authenticatedOpenCodeTuiPIDBySurface.removeValue(forKey: surfaceId)
        if kind == "opencode" {
            if let interactivePID, interactivePID > 0 {
                authenticatedOpenCodeTuiPIDBySurface[surfaceId] = interactivePID
            }
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
        } else if kind == "opencode" {
            if let expectedResumeId,
               let existing,
               existing.kind == kind,
               !existing.placeholder,
               existing.id == expectedResumeId {
                let refreshed = openCodeTuiClaim(
                    existing,
                    interactivePID: interactivePID,
                    recoveryPayload: openCodeRecoveryPayload
                )
                var snap = bySurface[surfaceId] ?? .empty
                snap.active = refreshed
                bySurface[surfaceId] = snap
                return .accepted(refreshed)
            }
            if let existing,
               existing.kind == kind,
               existing.placeholder,
               expectedOpenCodeResumeID(in: existing) == expectedResumeId,
               existing.capturedAt >= capturedAt {
                let refreshed = openCodeTuiClaim(
                    existing,
                    interactivePID: interactivePID,
                    recoveryPayload: openCodeRecoveryPayload
                )
                var snap = bySurface[surfaceId] ?? .empty
                snap.active = refreshed
                bySurface[surfaceId] = snap
                return .accepted(refreshed)
            }
            if let existing, existing.kind == kind, !existing.placeholder, !existing.id.isEmpty {
                payload = [ConversationLifecyclePayloadKey.invalidatedConversationID: .string(existing.id)]
            }
            if let expectedResumeId, let expiresAt,
               displayedOpenCodeOwners(for: expectedResumeId, excluding: surfaceId).isEmpty {
                payload = (payload ?? [:]).merging([
                    ConversationLifecyclePayloadKey.expectedResumeID: .string(expectedResumeId),
                    ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs: .number(
                        (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)
                    )
                ]) { _, new in new }
            }
            if let interactivePID, interactivePID > 0 {
                payload = (payload ?? [:]).merging([
                    ConversationLifecyclePayloadKey.openCodeTuiPID: .number(Double(interactivePID))
                ]) { _, new in new }
            }
            if let openCodeRecoveryPayload, let interactivePID, interactivePID > 0 {
                payload = (payload ?? [:]).merging(openCodeRecoveryPayload) { _, new in new }
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
        guard payload?.keys.allSatisfy({ !ConversationLifecyclePayloadKey.genericPushReservedKeys.contains($0) }) ?? true else {
            return nil
        }
        if let current = bySurface[surfaceId]?.active,
           current.kind == "opencode",
           (current.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID] != nil
                || current.payload?[ConversationLifecyclePayloadKey.openCodeRecoveryContextVersion] != nil) {
            // OpenCode v2 routes are mutated only through the authenticated
            // displayed-root/unbound-route or wrapper-claim seams. A generic
            // push of any kind can neither replace the route nor erase its
            // ownership marker.
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

    /// Capture the root displayed by one OpenCode TUI. The check and write
    /// are one actor mutation: another panel's exact ref or pre-capture
    /// `-s` reservation rejects the candidate without changing ownership.
    @discardableResult
    func captureDisplayedOpenCodeRoot(
        surfaceId: String,
        id: String,
        cwd: String?,
        callerPID: Int32?,
        capturedAt: Date = Date()
    ) -> DisplayedOpenCodeCaptureResult {
        guard let callerPID, callerPID > 0,
              authenticatedOpenCodeTuiPIDBySurface[surfaceId] == callerPID,
              let current = bySurface[surfaceId]?.active,
              expectedOpenCodeTuiPID(in: current) == callerPID else {
            return .unauthorized
        }
        let owners = displayedOpenCodeOwners(for: id, excluding: surfaceId)
        if !owners.isEmpty {
            var snap = bySurface[surfaceId] ?? .empty
            if var existing = snap.active {
                existing.state = .unknown
                existing.diagnosticReason = "OpenCode displayed route \(id) conflicts with a session owned by panel(s): \(owners.joined(separator: ","))"
                snap.active = existing
            } else {
                snap.active = ConversationRef(
                    kind: "opencode",
                    id: "wrapper-claim:\(surfaceId):displayed-route-conflict",
                    placeholder: true,
                    cwd: cwd,
                    capturedAt: capturedAt,
                    capturedVia: .wrapperClaim,
                    state: .unknown,
                    diagnosticReason: "OpenCode displayed route \(id) conflicts with panel(s): \(owners.joined(separator: ",")), TUI PID \(callerPID)",
                    payload: current.payload
                )
            }
            bySurface[surfaceId] = snap
            return .conflict(ownerSurfaceIds: owners, preservedRef: snap.active)
        }

        var payload = current.payload ?? [:]
        payload.removeValue(forKey: ConversationLifecyclePayloadKey.expectedResumeID)
        payload.removeValue(forKey: ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs)
        let ref = ConversationRef(
            kind: "opencode",
            id: id,
            placeholder: false,
            cwd: cwd,
            capturedAt: capturedAt,
            capturedVia: .hook,
            state: .alive,
            diagnosticReason: "displayed root captured by this OpenCode TUI",
            payload: payload.isEmpty ? nil : payload
        )
        var snap = bySurface[surfaceId] ?? .empty
        snap.active = ref
        bySurface[surfaceId] = snap
        _ = auditGlobalOwnership()
        return .accepted(bySurface[surfaceId]?.active ?? ref)
    }

    /// Mark a route as pending or child before it can receive typed fallback.
    /// Exact ownership is removed unless the requested route is already the
    /// same exact root or the wrapper has reserved this exact resume ID.
    @discardableResult
    func markDisplayedOpenCodeRouteUnbound(
        surfaceId: String,
        id: String,
        cwd: String?,
        routeState: String,
        callerPID: Int32?,
        capturedAt: Date = Date()
    ) -> OpenCodeUnboundRouteResult {
        guard (["pending", "child", "no-route"].contains(routeState)),
              isValidOpencodeSessionId(id),
              let callerPID, callerPID > 0,
              authenticatedOpenCodeTuiPIDBySurface[surfaceId] == callerPID,
              let current = bySurface[surfaceId]?.active,
              expectedOpenCodeTuiPID(in: current) == callerPID else {
            return .unauthorized
        }
        if routeState == "pending", !current.placeholder, current.id == id {
            return .accepted(current)
        }
        let reservedID = expectedOpenCodeResumeID(in: current)
        if routeState == "pending", reservedID == id {
            return .accepted(current)
        }

        var payload = current.payload ?? [:]
        payload.removeValue(forKey: ConversationLifecyclePayloadKey.expectedResumeID)
        payload.removeValue(forKey: ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs)
        if !current.placeholder, !current.id.isEmpty {
            payload[ConversationLifecyclePayloadKey.invalidatedConversationID] = .string(current.id)
        }
        let detail: String
        switch routeState {
        case "child": detail = "is a child session"
        case "no-route": detail = "has no displayed session"
        default: detail = "is awaiting root verification"
        }
        let ref = ConversationRef(
            kind: "opencode",
            id: "wrapper-claim:\(surfaceId):unbound-route",
            placeholder: true,
            cwd: cwd ?? current.cwd,
            capturedAt: capturedAt,
            capturedVia: .hook,
            state: .unknown,
            diagnosticReason: "OpenCode displayed route \(id) \(detail); no root binding",
            payload: payload.isEmpty ? nil : payload
        )
        var snap = bySurface[surfaceId] ?? .empty
        snap.active = ref
        bySurface[surfaceId] = snap
        _ = auditGlobalOwnership()
        return .accepted(bySurface[surfaceId]?.active ?? ref)
    }

    private func expectedOpenCodeResumeID(in ref: ConversationRef, now: Date = Date()) -> String? {
        guard ref.kind == "opencode", ref.placeholder,
              case .string(let expectedID)? = ref.payload?[ConversationLifecyclePayloadKey.expectedResumeID],
              case .number(let expiresAtMs)? = ref.payload?[ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs],
              expiresAtMs.isFinite,
              expiresAtMs > now.timeIntervalSince1970 * 1_000 else {
            return nil
        }
        return expectedID
    }

    private func expectedOpenCodeTuiPID(in ref: ConversationRef) -> Int32? {
        guard ref.kind == "opencode",
              case .number(let raw)? = ref.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID],
              raw.isFinite, raw > 0, raw <= Double(Int32.max), raw.rounded(.towardZero) == raw else {
            return nil
        }
        return Int32(raw)
    }

    private func openCodeTuiClaim(
        _ ref: ConversationRef,
        interactivePID: Int32?,
        recoveryPayload: [String: PersistedJSONValue]?
    ) -> ConversationRef {
        guard let interactivePID, interactivePID > 0 else { return ref }
        var refreshed = ref
        var payload = ref.payload ?? [:]
        for key in [
            ConversationLifecyclePayloadKey.openCodeRecoveryContextVersion,
            ConversationLifecyclePayloadKey.openCodeRecoveryHome,
            ConversationLifecyclePayloadKey.openCodeRecoveryXDGDataHome,
            ConversationLifecyclePayloadKey.openCodeRecoveryDatabaseOverride,
        ] {
            payload.removeValue(forKey: key)
        }
        payload[ConversationLifecyclePayloadKey.openCodeTuiPID] = .number(Double(interactivePID))
        if let recoveryPayload {
            payload.merge(recoveryPayload) { _, new in new }
        }
        refreshed.payload = payload
        return refreshed
    }

    private func displayedOpenCodeOwners(for id: String, excluding surfaceId: String, now: Date = Date()) -> [String] {
        bySurface.compactMap { ownerSurfaceId, conversations in
            guard ownerSurfaceId != surfaceId,
                  let ref = conversations.active,
                  ref.kind == "opencode",
                  ref.state != .tombstoned,
                  ref.state != .unsupported else { return nil }
            if (!ref.placeholder && ref.id == id) || expectedOpenCodeResumeID(in: ref, now: now) == id {
                return ownerSurfaceId
            }
            return nil
        }.sorted()
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
        // A same-id report on a ref that is not `.alive` is the live agent
        // proving its identity again; it heals rather than no-ops.
        let isIdempotent = existing?.kind == "codex"
            && existing?.id == id
            && existing?.capturedVia == .runtimeEnv
            && existing?.quarantineReason == nil
            && existing?.state == .alive

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

    /// Bulk-transition all active refs to `.unknown`. Production uses it only
    /// for the `app restart --no-resume` policy, so the restarted layout's
    /// old conversations stay down on later launches too. A failed or slow
    /// audit never calls it: failure is reported, never written.
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
    /// opens transcript bytes. `surfaceIds` limits the pass to those
    /// surfaces (refs a late scrape just applied).
    func reclassifyAfterCrash(
        registry: ConversationStrategyRegistry,
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        at: Date = Date(),
        surfaceIds: Set<String>? = nil
    ) {
        applyCrashTranscriptVerdicts(
            Self.crashTranscriptVerdicts(
                for: bySurface,
                registry: registry,
                filesystem: filesystem,
                surfaceIds: surfaceIds
            ),
            at: at
        )
    }

    /// The disk half of `reclassifyAfterCrash`, pure and nonisolated so
    /// startup stats transcripts off the actor (a Codex check walks
    /// `~/.codex/sessions`) while socket calls keep reaching the store.
    nonisolated static func crashTranscriptVerdicts(
        for records: [String: PanelConversations],
        registry: ConversationStrategyRegistry,
        filesystem: ConversationFilesystem,
        surfaceIds: Set<String>? = nil
    ) -> [String: CrashTranscriptVerdict] {
        var verdicts: [String: CrashTranscriptVerdict] = [:]
        for (key, conversations) in records {
            if let surfaceIds, !surfaceIds.contains(key) { continue }
            guard let active = conversations.active,
                  active.state == .alive || active.state == .suspended else { continue }
            verdicts[key] = CrashTranscriptVerdict(
                id: active.id,
                exists: registry.strategy(forKind: active.kind)?
                    .transcriptExists(for: active, filesystem: filesystem)
            )
        }
        return verdicts
    }

    /// Commit verdicts in one actor turn. A ref that changed while they were
    /// computed (another id, or no longer `.alive`/`.suspended`) keeps its
    /// newer state.
    func applyCrashTranscriptVerdicts(
        _ verdicts: [String: CrashTranscriptVerdict],
        at: Date = Date()
    ) {
        for (key, verdict) in verdicts {
            guard var snap = bySurface[key], var active = snap.active,
                  active.id == verdict.id,
                  active.state == .alive || active.state == .suspended else { continue }
            switch verdict.exists {
            case .some(true):
                active.state = .suspended
                active.diagnosticReason = "crash recovery: transcript verified on disk"
            case .some(false):
                active.state = .unknown
                active.diagnosticReason = "crash recovery: transcript not found"
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
        authenticatedOpenCodeTuiPIDBySurface.removeValue(forKey: surfaceId)
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
        records: inout [String: PanelConversations]
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
        records: inout [String: PanelConversations]
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
