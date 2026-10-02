import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

private enum LegacyCodexNotifyGuard {
    static let payloadKey = "legacy_codex_notify_payload_b64"
}

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    private func shouldDeliverLegacyCodexNotification(
        params: [String: Any],
        surfaceId: UUID
    ) -> Bool {
        guard let payloadB64 = params[LegacyCodexNotifyGuard.payloadKey] as? String else {
            return true
        }

        let capturedRootThreadId: String?? = conversationStoreSync { store in
            guard let active = await store.active(for: surfaceId.uuidString),
                  active.kind == "codex",
                  active.capturedVia == .runtimeEnv,
                  active.state == .alive,
                  !active.placeholder else {
                return nil
            }
            return active.id
        }
        guard let capturedRootThreadId else { return true }
        guard let rootThreadId = capturedRootThreadId else { return true }
        guard let payloadData = Data(base64Encoded: payloadB64),
              let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let callbackThreadId = (payloadObject["thread-id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !callbackThreadId.isEmpty else {
            return false
        }
        return callbackThreadId == rootThreadId
    }

    private func appendLegacyCodexCompletion(params: [String: Any], tabID: UUID, workspaceID: UUID) -> Bool {
        guard let encoded = params[LegacyCodexNotifyGuard.payloadKey] as? String,
              let data = Data(base64Encoded: encoded),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["type"] as? String == "agent-turn-complete" else { return false }
        let callbackID = input["thread-id"] as? String
        let owner = JournalCoordinator.shared.exactOwner(tabID: tabID)
        let matches = owner?.agentKind == "codex" && owner?.sessionID == callbackID
        let draft = JournalDraft(kind: .turnCompleted, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            tabID: tabID, workspaceID: workspaceID, sessionID: matches ? callbackID : nil,
            agentKind: "codex", source: .hook, adapter: .codexNotify, nativeEvent: "agent-turn-complete")
        let pid = (params["agent_pid"] as? Int).flatMap { Int32(exactly: $0) }.flatMap { $0 > 1 ? $0 : nil }
        DispatchQueue.global(qos: .utility).async { _ = try? JournalCoordinator.shared.append(draft, interactivePID: pid) }
        return matches
    }

    /// v2 dispatch slice for the `notification.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchNotification(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_tab":
            return v2Result(id: id, self.v2NotificationCreateForSurface(params: params))
        case "notification.create_for_target":
            return v2Result(id: id, self.v2NotificationCreateForTarget(params: params))
        case "notification.list":
            return v2Ok(id: id, result: self.v2NotificationList())
        case "notification.clear":
            return v2Result(id: id, self.v2NotificationClear())
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = ws.focusedPanelId
            if let surfaceId,
               !shouldDeliverLegacyCodexNotification(params: params, surfaceId: surfaceId) {
                result = .ok(["workspace_id": ws.id.uuidString, "surface_id": surfaceId.uuidString])
                return
            }
            if let surfaceId { _ = appendLegacyCodexCompletion(params: params, tabID: surfaceId, workspaceID: ws.id) }
            TerminalNotificationStore.shared.addNotification(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "surface_id": v2OrNull(surfaceId?.uuidString)])
        }
        return result
    }

    private func v2NotificationCreateForSurface(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            if !shouldDeliverLegacyCodexNotification(params: params, surfaceId: surfaceId) {
                result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
                return
            }
            // Codex's notify callback fires only on a completed agent turn, so
            // this is an explicit prompt edge for the mailbox stdin gate. It
            // goes through the deriver queue like every other lifecycle edge,
            // so a Return typed just before it is applied first.
            if !appendLegacyCodexCompletion(params: params, tabID: surfaceId, workspaceID: ws.id),
               params[LegacyCodexNotifyGuard.payloadKey] != nil,
               let agentPid = (params["agent_pid"] as? Int).flatMap({ pid_t(exactly: $0) }), agentPid > 1 {
                TabLivenessDeriver.onAgentLifecycleChanged(
                    surfaceId: surfaceId,
                    workspaceId: ws.id,
                    activity: .idle,
                    source: .reported,
                    agentPid: agentPid
                )
            }
            TerminalNotificationStore.shared.addNotification(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
        }
        return result
    }

    private func v2NotificationCreateForTarget(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = workspaceManager.workspaces.first(where: { $0.id == wsId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            if !shouldDeliverLegacyCodexNotification(params: params, surfaceId: surfaceId) {
                result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
                return
            }
            // Codex's notify callback fires only on a completed agent turn, so
            // this is an explicit prompt edge for the mailbox stdin gate. It
            // goes through the deriver queue like every other lifecycle edge,
            // so a Return typed just before it is applied first.
            if !appendLegacyCodexCompletion(params: params, tabID: surfaceId, workspaceID: ws.id),
               params[LegacyCodexNotifyGuard.payloadKey] != nil,
               let agentPid = (params["agent_pid"] as? Int).flatMap({ pid_t(exactly: $0) }), agentPid > 1 {
                TabLivenessDeriver.onAgentLifecycleChanged(
                    surfaceId: surfaceId,
                    workspaceId: ws.id,
                    activity: .idle,
                    source: .reported,
                    agentPid: agentPid
                )
            }
            TerminalNotificationStore.shared.addNotification(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
        }
        return result
    }

    private func v2NotificationList() -> [String: Any] {
        var items: [[String: Any]] = []
        v2MainSync {
            items = TerminalNotificationStore.shared.notifications.map { n in
                return [
                    "id": n.id.uuidString,
                    "workspace_id": n.workspaceId.uuidString,
                    "surface_id": v2OrNull(n.surfaceId?.uuidString),
                    "is_read": n.isRead,
                    "title": n.title,
                    "subtitle": n.subtitle,
                    "body": n.body
                ]
            }
        }
        return ["notifications": items]
    }

    private func v2NotificationClear() -> V2CallResult {
        v2MainSync {
            TerminalNotificationStore.shared.clearAll()
        }
        return .ok([:])
    }
}
