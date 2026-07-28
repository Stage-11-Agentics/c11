import Foundation

extension TerminalController {
    /// Worker-owned attention methods. Parsing and validation happen here;
    /// the only main hop resolves the live surface and commits the already
    /// validated mutation. The semaphore guarantees commit-before-response.
    nonisolated func v2FlagWorker(method: String, params: [String: Any]) -> V2CallResult {
        if method == "flag.list" {
            return v2FlagListWorker()
        }

        guard let rawSurface = params["surface_id"] as? String else {
            return .err(
                code: params["surface_id"] == nil ? "missing_ref" : "invalid_params",
                message: "surface_id is required and must be a UUID",
                data: nil
            )
        }
        let trimmedSurface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSurface.isEmpty else {
            return .err(code: "empty_ref", message: "surface_id must not be empty", data: nil)
        }
        let actor: SurfaceAttentionActor
        if let rawActor = params["by"] as? String {
            guard let parsed = SurfaceAttentionActor(rawValue: rawActor) else {
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
        if method == "flag.raise" {
            switch SurfaceAttentionReason.validate(params["reason"]) {
            case .success(let reason):
                validatedReason = reason
            case .failure(let error):
                return .err(code: "invalid_params", message: error.message, data: error.detailData)
            }
        }

        let commit = FailClosedCommitGate<V2CallResult> {
            MainActor.assumeIsolated {
                guard let surfaceId = self.v2UUIDAny(trimmedSurface) else {
                    return .err(
                        code: "invalid_params",
                        message: "surface_id must be a UUID or surface ref",
                        data: nil
                    )
                }
                let preferredWorkspaceId = self.v2UUIDAny(params["workspace_id"])
                guard let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: surfaceId,
                    preferredWorkspaceId: preferredWorkspaceId
                ) else {
                    return .err(code: "surface_not_found", message: "Surface not found", data: nil)
                }
                let workspace = located.workspace
                do {
                    let write: SurfaceMetadataStore.WriteResult
                    switch method {
                    case "flag.raise":
                        write = try SurfaceAttentionService.shared.raise(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            reason: validatedReason!,
                            title: workspace.panelTitle(panelId: surfaceId)
                                ?? workspace.panels[surfaceId]?.displayTitle
                        )
                    case "flag.lower":
                        write = try SurfaceAttentionService.shared.lower(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                    case "flag.suppress":
                        write = try SurfaceAttentionService.shared.suppress(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                    case "flag.unsuppress":
                        write = try SurfaceAttentionService.shared.unsuppress(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                    default:
                        return .err(code: "method_not_found", message: "Unknown method", data: nil)
                    }
                    let snapshot = SurfaceMetadataStore.shared.attentionSnapshot(
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
                        "suppressed": snapshot.suppressed,
                        "applied": write.applied
                    ])
                } catch let error as SurfaceMetadataStore.WriteError {
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
                let flags = SurfaceAttentionIndex.shared.oldestFlags.map { snapshot in
                    [
                        "workspace_id": snapshot.workspaceId.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: snapshot.workspaceId),
                        "surface_id": snapshot.surfaceId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: snapshot.surfaceId),
                        "reason": snapshot.flagReason ?? "",
                        "raised_at": snapshot.flagRaisedAt.map(EventEnvelope.formatTimestamp) ?? "",
                        "suppressed": snapshot.suppressed
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
