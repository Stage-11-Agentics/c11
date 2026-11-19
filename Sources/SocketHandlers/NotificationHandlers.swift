import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit
import UserNotifications

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

    private func appendLegacyCodexCompletion(params: [String: Any], panelID: UUID, workspaceID: UUID) -> Bool {
        guard let encoded = params[LegacyCodexNotifyGuard.payloadKey] as? String,
              let data = Data(base64Encoded: encoded),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["type"] as? String == "agent-turn-complete" else { return false }
        let callbackID = input["thread-id"] as? String
        let owner = JournalCoordinator.shared.exactOwner(panelID: panelID)
        let matches = owner?.agentKind == "codex" && owner?.sessionID == callbackID
        let draft = JournalDraft(kind: .turnCompleted, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            panelID: panelID, workspaceID: workspaceID, sessionID: matches ? callbackID : nil,
            agentKind: "codex", source: .hook, adapter: .codexNotify, nativeEvent: "agent-turn-complete")
        let pid = (params["agent_pid"] as? Int).flatMap { Int32(exactly: $0) }.flatMap { $0 > 1 ? $0 : nil }
        DispatchQueue.global(qos: .utility).async { _ = try? JournalCoordinator.shared.append(draft, interactivePID: pid) }
        return matches
    }

    /// C11H-319: a caller may mark a notification `needs_you` (it stopped on
    /// the operator), which plays the needs-you sound. Nothing else is
    /// caller-settable: a turn end also feeds the waiting check, so only c11's
    /// own hooks mark one.
    private func callerOrigin(params: [String: Any]) -> TerminalNotificationOrigin? {
        let raw = (params["origin"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return raw == TerminalNotificationOrigin.needsYou.rawValue ? .needsYou : nil
    }

    /// C11H-261: a panel-targeted notification carrying Codex's own
    /// `agent-turn-complete` callback payload (sent only by the bundled codex
    /// wrapper) is a turn end the waiting check judges. Anything else,
    /// including `notification.create`, is `.other` (or `.needsYou` when the
    /// caller says so).
    private func legacyCodexNotificationOrigin(params: [String: Any]) -> TerminalNotificationOrigin {
        guard let encoded = params[LegacyCodexNotifyGuard.payloadKey] as? String,
              let data = Data(base64Encoded: encoded),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["type"] as? String == "agent-turn-complete" else { return .other }
        return .turnEnd
    }

    /// v2 dispatch slice for the `notification.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchNotification(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "notification.create":
            return v2Result(id: id, self.v2NotificationCreate(params: params))
        case "notification.create_for_panel":
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
            if let surfaceId { _ = appendLegacyCodexCompletion(params: params, panelID: surfaceId, workspaceID: ws.id) }
            TerminalNotificationStore.shared.addNotification(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                origin: callerOrigin(params: params) ?? .other
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
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
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
                result = .err(code: "not_found", message: "Panel not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            if !shouldDeliverLegacyCodexNotification(params: params, surfaceId: surfaceId) {
                result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
                return
            }
            // Codex's notify callback fires only on a completed agent turn, so
            // this is an explicit prompt edge for the mailbox stdin gate. It
            // goes through the deriver queue like every other lifecycle edge,
            // so a Return typed just before it is applied first. A callback the
            // journal did not attribute to its live owner (another thread, such
            // as a sub-agent) stays off that panel's gate (C11-365).
            if !appendLegacyCodexCompletion(params: params, panelID: surfaceId, workspaceID: ws.id),
               params[LegacyCodexNotifyGuard.payloadKey] != nil,
               JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live,
               let agentPid = (params["agent_pid"] as? Int).flatMap({ pid_t(exactly: $0) }), agentPid > 1 {
                PanelLivenessDeriver.onAgentLifecycleChanged(
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
                body: body,
                origin: callerOrigin(params: params) ?? legacyCodexNotificationOrigin(params: params)
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
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
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
                result = .err(code: "not_found", message: "Panel not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            if !shouldDeliverLegacyCodexNotification(params: params, surfaceId: surfaceId) {
                result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
                return
            }
            // Codex's notify callback fires only on a completed agent turn, so
            // this is an explicit prompt edge for the mailbox stdin gate. It
            // goes through the deriver queue like every other lifecycle edge,
            // so a Return typed just before it is applied first. A callback the
            // journal did not attribute to its live owner (another thread, such
            // as a sub-agent) stays off that panel's gate (C11-365).
            if !appendLegacyCodexCompletion(params: params, panelID: surfaceId, workspaceID: ws.id),
               params[LegacyCodexNotifyGuard.payloadKey] != nil,
               JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live,
               let agentPid = (params["agent_pid"] as? Int).flatMap({ pid_t(exactly: $0) }), agentPid > 1 {
                PanelLivenessDeriver.onAgentLifecycleChanged(
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
                body: body,
                origin: callerOrigin(params: params) ?? legacyCodexNotificationOrigin(params: params)
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

// C11H-246: the routine notification dial. Worker-owned: the read and the
// validation run off main; the set's one main hop is the UserDefaults write
// (AGENTS.md: write UserDefaults on main only), committed before the reply.
extension TerminalController {
    nonisolated static func v2NotificationLevel(
        method: String,
        params: [String: Any],
        defaults: UserDefaults = .standard
    ) -> V2CallResult {
        switch method {
        case "notification.level.get":
            return .ok(notificationLevelPayload(NotificationLevel.current(defaults: defaults)))
        case "notification.level.set":
            guard let raw = (params["level"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let level = NotificationLevel(rawValue: raw) else {
                return .err(
                    code: "invalid_params",
                    message: "level must be one of: silent, quiet, normal, chatty",
                    data: nil
                )
            }
            let commit = FailClosedCommitGate<V2CallResult> {
                defaults.set(level.rawValue, forKey: NotificationLevel.key)
                NSLog("notification.level set=%@", level.rawValue)
                return .ok(notificationLevelPayload(level))
            }
            commit.enqueueOnMain()
            return commit.wait(timeout: 8) ?? .err(
                code: "main_thread_timeout",
                message: "main thread did not begin the notification level write before the deadline",
                data: nil
            )
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    nonisolated static func notificationLevelPayload(_ level: NotificationLevel) -> [String: Any] {
        [
            "level": level.rawValue,
            "levels": NotificationLevel.allCases.map(\.rawValue),
            // A flag is never dialed: it always posts at time-sensitive with
            // the flag sound.
            "flags": "always",
        ]
    }
}

// C11H-319: the three sound channels. Worker-owned like the dial: parsing,
// validation and any file import run off main; the set's one main hop is the
// UserDefaults write, committed before the reply. The operator owns these.
extension TerminalController {
    nonisolated static func v2NotificationSound(
        method: String,
        params: [String: Any],
        defaults: UserDefaults = .standard,
        store: CustomNotificationSoundStore = .shared
    ) -> V2CallResult {
        switch method {
        case "notification.sound.get":
            return .ok(notificationSoundPayload(defaults: defaults, store: store))
        case "notification.sound.set":
            let channelNames = NotificationSoundChannel.allCases.map(\.cliName).joined(separator: ", ")
            guard let rawChannel = params["channel"] as? String,
                  let channel = NotificationSoundChannel(cliName: rawChannel) else {
                return .err(code: "invalid_params", message: "channel must be one of: \(channelNames)", data: nil)
            }
            guard let value = params["sound"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "sound is required", data: nil)
            }
            let choice: NotificationSoundChoice
            switch NotificationSoundInput.choice(from: value, allowsNone: channel.allowsNone, store: store) {
            case .success(let parsed): choice = parsed
            case .failure(let failure):
                return .err(code: "invalid_params", message: failure.message, data: nil)
            }
            let commit = FailClosedCommitGate<V2CallResult> {
                defaults.set(choice.rawValue, forKey: channel.defaultsKey)
                NSLog("notification.sound set channel=%@ sound=%@", channel.rawValue, choice.rawValue)
                return .ok(notificationSoundPayload(defaults: defaults, store: store))
            }
            commit.enqueueOnMain()
            guard let committed = commit.wait(timeout: 8) else {
                return .err(
                    code: "main_thread_timeout",
                    message: "main thread did not begin the notification sound write before the deadline",
                    data: nil
                )
            }
            // Playback copies follow the sounds in use (off main, here).
            NotificationSoundPlayback.sync(defaults: defaults, registry: .shared, store: store)
            return committed
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    nonisolated static func notificationSoundPayload(
        defaults: UserDefaults,
        store: CustomNotificationSoundStore
    ) -> [String: Any] {
        let channels = NotificationSoundChannel.allCases.map { channel -> [String: Any] in
            let choice = channel.choice(defaults: defaults)
            var object: [String: Any] = [
                "channel": channel.cliName,
                "sound": choice.rawValue,
                "label": NotificationSoundCatalog.label(for: choice, store: store),
                "default": channel.shippedDefault.rawValue,
                "dialed": channel != .flag,
            ]
            if case .file(let id) = choice {
                object["file"] = store.url(for: id).path
            }
            return object
        }
        return [
            "channels": channels,
            "named": NotificationSoundCatalog.namedValues,
        ]
    }
}

// C11H-246: guest proof. What Notification Center holds now, read off main
// (`getDeliveredNotifications` is an XPC round trip). Debug builds only.
extension TerminalController {
    nonisolated static func v2DebugDeliveredNotifications() -> V2CallResult {
#if DEBUG
        // UNUserNotificationCenter needs an application bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return .err(code: "unavailable", message: "no notification center in this process", data: nil)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeliveredNotificationsBox()
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            box.rows = delivered.map { notification in
                let content = notification.request.content
                return [
                    "identifier": notification.request.identifier,
                    "title": content.title,
                    "subtitle": content.subtitle,
                    "flag": content.userInfo[FlagNotificationSpec.userInfoFlagKey] as? Bool ?? false,
                    "interruption_level": Self.interruptionLevelName(content.interruptionLevel),
                    "has_sound": content.sound != nil,
                    "delivered_at": EventEnvelope.formatTimestamp(notification.date),
                ] as [String: Any]
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            return .err(code: "timeout", message: "Notification Center did not answer within 5 s", data: nil)
        }
        return .ok(["delivered": box.rows, "count": box.rows.count])
#else
        return .err(code: "method_not_found", message: "Unknown method", data: nil)
#endif
    }

    nonisolated static func interruptionLevelName(_ level: UNNotificationInterruptionLevel) -> String {
        switch level {
        case .passive: return "passive"
        case .active: return "active"
        case .timeSensitive: return "time_sensitive"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

private final class DeliveredNotificationsBox: @unchecked Sendable {
    var rows: [[String: Any]] = []
}
