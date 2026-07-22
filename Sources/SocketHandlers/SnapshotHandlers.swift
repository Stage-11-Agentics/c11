import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `snapshot.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchSnapshot(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "snapshot.create":
            return v2Result(id: id, self.v2SnapshotCreate(params: params))
        case "snapshot.restore":
            return v2Result(id: id, self.v2SnapshotRestore(params: params))
        case "snapshot.restore_set":
            return v2Result(id: id, self.v2SnapshotRestoreSet(params: params))
        case "snapshot.list":
            return v2Result(id: id, self.v2SnapshotList(params: params))
        case "snapshot.list_sets":
            return v2Result(id: id, self.v2SnapshotListSets(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// `snapshot.create`: capture the live workspace to a `WorkspaceSnapshotFile`
    /// on disk. Params: `workspace_id` / `surface_id` (defaults to current).
    /// Returns `{snapshot_id, path, surface_count, workspace_ref}`.
    ///
    /// Socket-initiated captures **always** land in
    /// `WorkspaceSnapshotStore.defaultDirectory()` — any caller-supplied
    /// `params["path"]` is rejected with `invalid_params`. The CLI's
    /// `c11 snapshot --out <path>` path is fine because the CLI process
    /// holds the caller's real permissions; the threat here is an agent
    /// with only socket access turning `snapshot.create` into an
    /// arbitrary-file-write primitive (overwriting
    /// `~/.claude/settings.json` etc.).
    private func v2SnapshotCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let rawPath = params["path"] as? String,
           !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(
                code: "invalid_params",
                message: "socket-initiated snapshot.create does not accept 'path'; "
                    + "use 'c11 snapshot --out <path>' from the CLI instead",
                data: nil
            )
        }
        let originRaw = (params["origin"] as? String) ?? "manual"
        let origin: WorkspaceSnapshotFile.Origin =
            (originRaw == "auto-restart") ? .autoRestart : .manual

        // --all: capture every open workspace, write per-workspace files
        // AND a manifest under `~/.c11-snapshots/sets/<set_id>.json` that
        // points at the inner ids. The manifest is the discoverable handle
        // for `c11 restore <set_id>` — it carries no plan data of its own,
        // so each inner snapshot stays independently restorable.
        let captureAll = (params["all"] as? Bool) == true
        if captureAll {
            var snapshots: [(
                envelope: WorkspaceSnapshotFile,
                ref: String,
                isSelected: Bool,
                warnings: [CompanionPlanDiagnostic]
            )] = []
            v2MainSync {
                let source = LiveWorkspaceSnapshotSource(tabManager: tabManager)
                let selectedId = tabManager.selectedWorkspace?.id
                for ws in tabManager.tabs {
                    if let capture = source.captureResult(
                        workspaceId: ws.id, origin: origin, clock: { Date() }
                    ) {
                        let ref = self.v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                        snapshots.append((
                            capture.snapshot,
                            ref,
                            ws.id == selectedId,
                            capture.warnings
                        ))
                    }
                }
            }
            let store = WorkspaceSnapshotStore()
            var results: [[String: Any]] = []
            var entries: [WorkspaceSnapshotSetFile.Entry] = []
            var selectedIndex: Int?
            var anyWriteFailed = false
            for (offset, item) in snapshots.enumerated() {
                let (envelope, ref, isSelected, captureWarnings) = item
                do {
                    let path = try store.writeToDefaultDirectory(envelope)
                    var row: [String: Any] = [
                        "snapshot_id": envelope.snapshotId,
                        "path": path.path,
                        "surface_count": envelope.plan.surfaces.count,
                        "workspace_ref": ref,
                        "warnings": captureWarnings.map(Self.companionDiagnosticPayload)
                    ]
                    if isSelected { row["selected"] = true }
                    results.append(row)
                    entries.append(WorkspaceSnapshotSetFile.Entry(
                        workspaceRef: ref,
                        snapshotId: envelope.snapshotId,
                        order: offset,
                        selected: isSelected
                    ))
                    if isSelected { selectedIndex = entries.count - 1 }
                } catch {
                    results.append([
                        "snapshot_id": envelope.snapshotId,
                        "error": "\(error)",
                        "workspace_ref": ref,
                        "warnings": captureWarnings.map(Self.companionDiagnosticPayload)
                    ])
                    anyWriteFailed = true
                }
            }
            // Build the manifest only when at least one inner snapshot
            // wrote successfully — an all-failed run has nothing to point
            // at. When some inner writes failed but others succeeded the
            // manifest still ships, listing only the successful entries
            // (the failed entries are visible via the per-snapshot result
            // rows).
            var payload: [String: Any] = ["snapshots": results]
            if !entries.isEmpty {
                let setId = WorkspaceSnapshotID.generate()
                let manifest = WorkspaceSnapshotSetFile(
                    version: 1,
                    setId: setId,
                    createdAt: Date(),
                    c11Version: LiveWorkspaceSnapshotSource.defaultVersionString(),
                    selectedWorkspaceIndex: selectedIndex,
                    snapshots: entries
                )
                do {
                    let setPath = try store.writeSet(manifest)
                    payload["set_id"] = setId
                    payload["set_path"] = setPath.path
                } catch {
                    // Surface the manifest-write failure but keep the
                    // per-workspace data the caller already has.
                    payload["set_error"] = "\(error)"
                }
            } else if anyWriteFailed {
                payload["set_error"] = "no inner snapshots wrote successfully"
            }
            return .ok(payload)
        }

        var captureResult: WorkspaceSnapshotCaptureResult?
        var workspaceRef = ""
        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let source = LiveWorkspaceSnapshotSource(tabManager: tabManager)
            captureResult = source.captureResult(
                workspaceId: workspace.id,
                origin: origin,
                clock: { Date() }
            )
            workspaceRef = self.v2EnsureHandleRef(kind: .workspace, uuid: workspace.id)
        }
        guard let captureResult else {
            return .err(code: "not_found", message: "Workspace not found for snapshot.create", data: nil)
        }
        let envelope = captureResult.snapshot
        let store = WorkspaceSnapshotStore()
        let path: URL
        do {
            path = try store.writeToDefaultDirectory(envelope)
        } catch let err as WorkspaceSnapshotStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "snapshot_write_failed", message: "\(error)", data: nil)
        }
        let payload: [String: Any] = [
            "snapshot_id": envelope.snapshotId,
            "path": path.path,
            "surface_count": envelope.plan.surfaces.count,
            "workspace_ref": workspaceRef,
            "warnings": captureResult.warnings.map(Self.companionDiagnosticPayload)
        ]
        return .ok(payload)
    }

    private nonisolated static func companionDiagnosticPayload(
        _ diagnostic: CompanionPlanDiagnostic
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "code": diagnostic.code.rawValue,
            "severity": diagnostic.severity.rawValue,
            "source_plan_id": diagnostic.sourcePlanID
        ]
        if let target = diagnostic.targetPlanID {
            payload["target_plan_id"] = target
        }
        return payload
    }

    /// `snapshot.restore`: read a snapshot by id, run the embedded plan
    /// through `WorkspaceLayoutExecutor`, optionally threading a named
    /// restart registry (`"phase1"` → `AgentRestartRegistry.phase1`) so cc
    /// terminals resume via `cc --resume <session-id>`. Returns the same
    /// `ApplyResult` shape `workspace.apply` returns.
    ///
    /// Socket-initiated restores resolve `snapshot_id` through
    /// `WorkspaceSnapshotStore.resolvePath(byId:)`, which validates the id
    /// grammar and asserts the resolved realpath lives under a configured
    /// snapshot root. Caller-supplied `params["path"]` is rejected with
    /// `invalid_params`: an agent with socket access must not be able to
    /// coerce the restore path-reader into parsing arbitrary files
    /// (`/etc/passwd.json`, say) — parser errors can leak file contents.
    /// The CLI's `c11 restore <path-or-id>` classifies locally before
    /// sending and always submits via `snapshot_id`.
    private func v2SnapshotRestore(params: [String: Any]) -> V2CallResult {
        if let rawPath = params["path"] as? String,
           !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(
                code: "invalid_params",
                message: "socket-initiated snapshot.restore does not accept 'path'; "
                    + "use 'snapshot_id' (resolved against the snapshot roots) instead",
                data: nil
            )
        }
        let rawId = (params["snapshot_id"] as? String).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let store = WorkspaceSnapshotStore()
        let envelope: WorkspaceSnapshotFile
        do {
            if let id = rawId, !id.isEmpty {
                envelope = try store.read(byId: id)
            } else {
                return .err(
                    code: "invalid_params",
                    message: "snapshot.restore requires 'snapshot_id'",
                    data: nil
                )
            }
        } catch let err as WorkspaceSnapshotStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "snapshot_read_failed", message: "\(error)", data: nil)
        }

        // Envelope → plan, off-main.
        let planResult = WorkspaceSnapshotConverter.applyPlan(from: envelope)
        let plan: WorkspaceApplyPlan
        switch planResult {
        case .success(let p): plan = p
        case .failure(let err):
            return .err(code: err.code, message: err.message, data: nil)
        }
        if let validationFailure = WorkspaceLayoutExecutor.validate(plan: plan) {
            let data: [String: Any] = [
                "failure": [
                    "code": validationFailure.code,
                    "step": validationFailure.step,
                    "message": validationFailure.message
                ]
            ]
            return .err(
                code: "invalid_params",
                message: "snapshot plan validation failed: \(validationFailure.message)",
                data: data
            )
        }

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        // Build options: select is subject to the focus policy; the restart
        // registry is resolved by name on the wire so snapshot files stay
        // forward-compatible with future Phase 5 rows.
        var options = ApplyOptions()
        if let selectValue = params["select"] as? Bool {
            options.select = selectValue
        }
        if options.select && !v2FocusAllowed(requested: true) {
            options.select = false
        }
        // Pre-apply warnings surfaced through ApplyResult.warnings below so
        // operators see them in both JSON and the CLI's `warnings:` block.
        var preApplyWarnings: [String] = []
        if let registryName = params["restart_registry"] as? String {
            let resolved = AgentRestartRegistry.named(registryName)
            options.restartRegistry = resolved
            if resolved == nil {
                // Unknown wire name → fall back to Phase 0 (no synthesis) but
                // make the silent degradation visible. Reject is the
                // tempting alternative, but the registry is designed for
                // Phase 5 forward compatibility — an operator submitting
                // "phase5" against an older c11 binary should still land
                // their restore, just without restart synthesis.
                preApplyWarnings.append(
                    "unknown restart_registry '\(registryName)': falling back to no-op (no cc --resume synthesis)"
                )
            }
        }

        // In-place restore (I2): resolve the target workspace UUID either
        // from the `target_workspace_id` param or from the focus-policy
        // default. When the target doesn't resolve the executor surfaces
        // `invalid_params` via ApplyResult.failures.
        let inPlace = (params["in_place"] as? Bool) == true
        let inPlaceTarget: UUID? = {
            guard inPlace else { return nil }
            if let raw = params["target_workspace_id"] as? String,
               let uuid = UUID(uuidString: raw) {
                return uuid
            }
            return nil
        }()

        var result: ApplyResult?
        v2MainSync {
            let deps = WorkspaceLayoutExecutorDependencies(
                tabManager: tabManager,
                workspaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .workspace, uuid: uuid) ?? "workspace:\(uuid.uuidString)"
                },
                surfaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .surface, uuid: uuid) ?? "surface:\(uuid.uuidString)"
                },
                paneRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .pane, uuid: uuid) ?? "pane:\(uuid.uuidString)"
                }
            )
            if inPlace, let target = inPlaceTarget {
                result = WorkspaceLayoutExecutor.applyToExistingWorkspace(
                    plan,
                    options: options,
                    dependencies: deps,
                    existingWorkspaceId: target
                )
            } else if inPlace {
                // Requested in_place but no target resolver succeeded.
                // Synthesise the same invalid_params failure the executor
                // would emit so callers see a consistent shape.
                result = ApplyResult(
                    workspaceRef: "",
                    surfaceRefs: [:],
                    paneRefs: [:],
                    timings: [],
                    warnings: ["in_place restore requires a resolvable target_workspace_id"],
                    failures: [ApplyFailure(
                        code: "invalid_params",
                        step: "validate",
                        message: "in_place restore requires 'target_workspace_id' as a UUID string"
                    )]
                )
            } else {
                result = WorkspaceLayoutExecutor.apply(plan, options: options, dependencies: deps)
            }
        }
        guard var applyResult = result else {
            return .err(code: "internal_error", message: "Executor returned no result", data: nil)
        }
        if !preApplyWarnings.isEmpty {
            applyResult.warnings = preApplyWarnings + applyResult.warnings
        }
        do {
            let encoded = try JSONEncoder().encode(applyResult)
            let asAny = try JSONSerialization.jsonObject(with: encoded, options: [])
            return .ok(asAny)
        } catch {
            return .err(code: "internal_error", message: "Failed to encode ApplyResult: \(error)", data: nil)
        }
    }

    /// `snapshot.restore_set`: rehydrate every per-workspace snapshot
    /// referenced by a `WorkspaceSnapshotSetFile` manifest. Required
    /// param: `set_id` (resolved against
    /// `~/.c11-snapshots/sets/<set_id>.json` only — never a
    /// caller-supplied path). Optional: `restart_registry` (passes
    /// through to each inner restore), `select` (best-effort focus on
    /// the entry the manifest marked as selected, subject to the same
    /// focus policy `snapshot.restore` honors).
    ///
    /// `in_place` is rejected here: a set restore creates several fresh
    /// workspaces, and there is no single target workspace to replace.
    /// The CLI catches this earlier; the v2 method validates again so
    /// programmatic callers cannot trip the executor.
    private func v2SnapshotRestoreSet(params: [String: Any]) -> V2CallResult {
        if let rawPath = params["path"] as? String,
           !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(
                code: "invalid_params",
                message: "socket-initiated snapshot.restore_set does not accept 'path'; "
                    + "use 'set_id' instead",
                data: nil
            )
        }
        if (params["in_place"] as? Bool) == true {
            return .err(
                code: "invalid_params",
                message: "snapshot.restore_set does not support in_place; a set restore creates fresh workspaces",
                data: nil
            )
        }
        guard let rawId = (params["set_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawId.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "snapshot.restore_set requires 'set_id'",
                data: nil
            )
        }
        let store = WorkspaceSnapshotStore()
        let manifest: WorkspaceSnapshotSetFile
        do {
            manifest = try store.readSet(byId: rawId)
        } catch let err as WorkspaceSnapshotStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "snapshot_set_read_failed", message: "\(error)", data: nil)
        }

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        // Resolve restart registry once for the whole set; missing names
        // degrade to no-op with a per-set warning (matches snapshot.restore).
        var preApplyWarnings: [String] = []
        var optionsTemplate = ApplyOptions()
        optionsTemplate.select = false  // each apply runs unselect; we re-establish at the end
        if let registryName = params["restart_registry"] as? String {
            let resolved = AgentRestartRegistry.named(registryName)
            optionsTemplate.restartRegistry = resolved
            if resolved == nil {
                preApplyWarnings.append(
                    "unknown restart_registry '\(registryName)': falling back to no-op (no cc --resume synthesis)"
                )
            }
        }

        let allowFocus = v2FocusAllowed(requested: (params["select"] as? Bool) ?? true)

        var workspaceResults: [[String: Any]] = []
        var selectedWorkspaceRef: String?

        // Apply each inner snapshot sequentially. Order is taken from the
        // manifest's `order` field as written; we sort defensively here so
        // a future hand-edited manifest with shuffled keys still applies
        // in capture-time order.
        let sortedEntries = manifest.snapshots.sorted { $0.order < $1.order }
        for entry in sortedEntries {
            let envelope: WorkspaceSnapshotFile
            do {
                envelope = try store.read(byId: entry.snapshotId)
            } catch let err as WorkspaceSnapshotStore.StoreError {
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": "\(err)",
                    "code": err.code
                ])
                continue
            } catch {
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": "\(error)"
                ])
                continue
            }
            let planResult = WorkspaceSnapshotConverter.applyPlan(from: envelope)
            let plan: WorkspaceApplyPlan
            switch planResult {
            case .success(let p): plan = p
            case .failure(let err):
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": err.message,
                    "code": err.code
                ])
                continue
            }
            if let validationFailure = WorkspaceLayoutExecutor.validate(plan: plan) {
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": validationFailure.message,
                    "code": validationFailure.code
                ])
                continue
            }

            var result: ApplyResult?
            v2MainSync {
                let deps = WorkspaceLayoutExecutorDependencies(
                    tabManager: tabManager,
                    workspaceRefMinter: { [weak self] uuid in
                        self?.v2EnsureHandleRef(kind: .workspace, uuid: uuid) ?? "workspace:\(uuid.uuidString)"
                    },
                    surfaceRefMinter: { [weak self] uuid in
                        self?.v2EnsureHandleRef(kind: .surface, uuid: uuid) ?? "surface:\(uuid.uuidString)"
                    },
                    paneRefMinter: { [weak self] uuid in
                        self?.v2EnsureHandleRef(kind: .pane, uuid: uuid) ?? "pane:\(uuid.uuidString)"
                    }
                )
                result = WorkspaceLayoutExecutor.apply(plan, options: optionsTemplate, dependencies: deps)
            }
            guard let applyResult = result else {
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": "executor returned no result"
                ])
                continue
            }
            do {
                let encoded = try JSONEncoder().encode(applyResult)
                if let asAny = try JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any] {
                    var row = asAny
                    row["snapshot_id"] = entry.snapshotId
                    row["original_workspace_ref"] = entry.workspaceRef
                    if entry.selected { row["selected"] = true }
                    workspaceResults.append(row)
                    if entry.selected, !applyResult.workspaceRef.isEmpty {
                        selectedWorkspaceRef = applyResult.workspaceRef
                    }
                }
            } catch {
                workspaceResults.append([
                    "snapshot_id": entry.snapshotId,
                    "workspace_ref": entry.workspaceRef,
                    "error": "encode failed: \(error)"
                ])
            }
        }

        // Re-establish selection on a best-effort basis, subject to the
        // socket focus policy. Convert the ref back to a UUID via the
        // existing handle table, then look up the live workspace.
        if allowFocus, let targetRef = selectedWorkspaceRef,
           let uuid = self.v2ResolveHandleRef(targetRef) {
            v2MainSync {
                if let ws = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectWorkspace(ws)
                }
            }
        }

        var payload: [String: Any] = [
            "set_id": manifest.setId,
            "workspaces": workspaceResults,
            "warnings": preApplyWarnings
        ]
        if let ref = selectedWorkspaceRef {
            payload["selected_workspace_ref"] = ref
        }
        return .ok(payload)
    }

    /// `snapshot.list_sets`: enumerate manifests under
    /// `~/.c11-snapshots/sets/`. Returns rows sorted newest-first.
    private func v2SnapshotListSets(params: [String: Any]) -> V2CallResult {
        let store = WorkspaceSnapshotStore()
        let entries: [WorkspaceSnapshotSetIndex]
        do {
            entries = try store.listSets()
        } catch let err as WorkspaceSnapshotStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "snapshot_list_sets_failed", message: "\(error)", data: nil)
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(workspaceSnapshotDateFormatter.string(from: date))
            }
            let encoded = try encoder.encode(entries)
            let asAny = try JSONSerialization.jsonObject(with: encoded, options: [])
            return .ok(["sets": asAny])
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    /// `snapshot.list`: enumerate `~/.c11-snapshots/` + `~/.cmux-snapshots/`
    /// and return entries sorted newest-first. Pure filesystem; runs
    /// off-main.
    private func v2SnapshotList(params: [String: Any]) -> V2CallResult {
        let store = WorkspaceSnapshotStore()
        let entries: [WorkspaceSnapshotIndex]
        do {
            entries = try store.list()
        } catch let err as WorkspaceSnapshotStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "snapshot_list_failed", message: "\(error)", data: nil)
        }
        do {
            let encoder = JSONEncoder()
            // Match the store's write-side formatter (fractional seconds)
            // so a timestamp written by `WorkspaceSnapshotStore.write` and
            // re-read into a `snapshot.list` response round-trips
            // bit-for-bit. The default `.iso8601` strategy drops subsecond
            // precision and creates a write-vs-read mismatch.
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(workspaceSnapshotDateFormatter.string(from: date))
            }
            let encoded = try encoder.encode(entries)
            let asAny = try JSONSerialization.jsonObject(with: encoded, options: [])
            return .ok(["snapshots": asAny])
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }
}
