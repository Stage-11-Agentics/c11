import Foundation

extension TerminalController {
    /// Worker-owned attention methods. Parsing and validation happen here;
    /// the only main hop resolves the live surface and commits the already
    /// validated mutation. The semaphore guarantees commit-before-response.
    nonisolated func v2FlagWorker(
        method: String,
        params: [String: Any],
        legacyMethod: String? = nil
    ) -> V2CallResult {
        if method == "flag.list" {
            return v2FlagListWorker()
        }
        let tracksDelegateOwner = method == "flag.delegate"
        let isLegacyOwnerlessSuppression = legacyMethod == "flag.suppress"

        guard let rawSurface = params["surface_id"] as? String else {
            return .err(
                code: params["surface_id"] == nil ? "missing_ref" : "invalid_params",
                message: "panel_id is required and must be a UUID",
                data: nil
            )
        }
        let trimmedSurface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSurface.isEmpty else {
            return .err(code: "empty_ref", message: "panel_id must not be empty", data: nil)
        }
        let actor: PanelAttentionActor
        if let rawActor = params["by"] as? String {
            guard rawActor == "operator" || rawActor == "agent",
                  let parsed = PanelAttentionActor(rawValue: rawActor) else {
                return .err(
                    code: "invalid_params",
                    message: "by must be one of: operator, agent",
                    data: nil
                )
            }
            actor = parsed
        } else {
            actor = .agent
        }

        var validatedReason: String?
        var callerPanelId: UUID?
        if method == "flag.raise" || tracksDelegateOwner {
            if method == "flag.raise" {
                switch PanelAttentionReason.validate(params["reason"]) {
                case .success(let reason):
                    validatedReason = reason
                case .failure(let error):
                    return .err(code: "invalid_params", message: error.message, data: error.detailData)
                }
            }
            if let rawCaller = params["caller_surface_id"] as? String {
                let trimmedCaller = rawCaller.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCaller.isEmpty, let parsed = UUID(uuidString: trimmedCaller) else {
                    return .err(
                        code: "invalid_params",
                        message: "caller_panel_id must be a UUID",
                        data: nil
                    )
                }
                callerPanelId = parsed
            } else if params["caller_surface_id"] != nil {
                return .err(
                    code: "invalid_params",
                    message: "caller_panel_id must be a UUID",
                    data: nil
                )
            }
            if PanelAttentionDelegationPolicy.requiresCaller(
                actor: actor,
                callerPanelId: callerPanelId,
                isLegacyOwnerlessSuppression: isLegacyOwnerlessSuppression
            ) {
                return .err(
                    code: "missing_caller_surface",
                    message: tracksDelegateOwner
                        ? "agent delegation requires caller_panel_id"
                        : "agent-raised flags require caller_panel_id",
                    data: nil
                )
            }
        }

        let commit = FailClosedCommitGate<V2CallResult> {
            MainActor.assumeIsolated {
                guard let surfaceId = self.v2UUIDAny(trimmedSurface) else {
                    return .err(
                        code: "invalid_params",
                        message: "panel_id must be a UUID or panel ref",
                        data: nil
                    )
                }
                let preferredWorkspaceId = self.v2UUIDAny(params["workspace_id"])
                if let callerPanelId,
                   AppDelegate.shared?.workspaceContainingPanel(
                       panelId: callerPanelId,
                       preferredWorkspaceId: nil
                   ) == nil {
                    return .err(
                        code: "caller_surface_not_found",
                        message: "Calling panel not found",
                        data: nil
                    )
                }
                if tracksDelegateOwner,
                   PanelAttentionDelegationPolicy.isSelfDelegation(
                       callerPanelId: callerPanelId,
                       targetPanelId: surfaceId
                   ) {
                    return .err(
                        code: "self_delegation",
                        message: "A panel cannot delegate itself",
                        data: nil
                    )
                }
                guard let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: surfaceId,
                    preferredWorkspaceId: preferredWorkspaceId
                ) else {
                    return .err(code: "surface_not_found", message: "Panel not found", data: nil)
                }
                let workspace = located.workspace
                do {
                    let write: PanelMetadataStore.WriteResult
                    switch method {
                    case "flag.raise":
                        write = try PanelAttentionService.shared.raise(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            reason: validatedReason!,
                            callerPanelId: callerPanelId,
                            by: actor,
                            title: workspace.panelTitle(panelId: surfaceId)
                                ?? workspace.panels[surfaceId]?.displayTitle
                        )
                    case "flag.lower":
                        write = try PanelAttentionService.shared.lower(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                        workspace.recheckMailboxDoorbellAfterFlagLower(surfaceId: surfaceId)
                    case "flag.undelegate":
                        write = try PanelAttentionService.shared.undelegate(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                    case "flag.delegate":
                        write = try PanelAttentionService.shared.delegate(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            ownerPanelId: tracksDelegateOwner ? callerPanelId : nil,
                            by: actor
                        )
                    default:
                        return .err(code: "method_not_found", message: "Unknown method", data: nil)
                    }
                    let snapshot = PanelMetadataStore.shared.attentionSnapshot(
                        workspaceId: workspace.id,
                        surfaceId: surfaceId
                    )
                    return .ok([
                        "workspace_id": workspace.id.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspace.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceId),
                        "flag": self.v2OrNull(snapshot.flagReason),
                        "flag_raised_at": self.v2OrNull(snapshot.flagRaisedAt.map(EventEnvelope.formatTimestamp)),
                        "caller_surface_id": self.v2OrNull(
                            snapshot.flagCallerPanelId?.uuidString
                        ),
                        "delegated": snapshot.delegated,
                        "delegated_by": self.v2OrNull(snapshot.delegatedBy?.uuidString),
                        "suppressed": snapshot.delegated,
                        "applied": write.applied
                    ])
                } catch let error as PanelMetadataStore.WriteError {
                    return .err(code: "invalid_params", message: error.message, data: error.detailData)
                } catch {
                    return .err(code: "internal_error", message: "\(error)", data: nil)
                }
            }
        }
        commit.enqueueOnMain()
        return commit.wait(timeout: 8) ?? .err(
            code: "main_thread_timeout",
            message: "main thread did not begin the attention mutation before the deadline",
            data: nil
        )
    }

    nonisolated private func v2FlagListWorker() -> V2CallResult {
        let commit = FailClosedCommitGate<V2CallResult> {
            MainActor.assumeIsolated {
                let flags = PanelAttentionIndex.shared.oldestFlags.map { snapshot in
                    [
                        "workspace_id": snapshot.workspaceId.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: snapshot.workspaceId),
                        "surface_id": snapshot.surfaceId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: snapshot.surfaceId),
                        "reason": snapshot.flagReason ?? "",
                        "raised_at": snapshot.flagRaisedAt.map(EventEnvelope.formatTimestamp) ?? "",
                        "caller_surface_id": self.v2OrNull(
                            snapshot.flagCallerPanelId?.uuidString
                        ),
                        "delegated": snapshot.delegated,
                        "delegated_by": self.v2OrNull(snapshot.delegatedBy?.uuidString),
                        "suppressed": snapshot.delegated
                    ]
                }
                return .ok(["flags": flags, "count": flags.count])
            }
        }
        commit.enqueueOnMain()
        return commit.wait(timeout: 8) ?? .err(
            code: "main_thread_timeout",
            message: "main thread did not begin the attention read before the deadline",
            data: nil
        )
    }
}
