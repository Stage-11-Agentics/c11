import Foundation

extension TerminalController {
    // Worker-only. Parses off main and does not move focus.
    nonisolated func v2FeedList(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        let raw = (params["scope"] as? String) ?? FeedScope.attention.rawValue
        guard let scope = FeedScope(rawValue: raw) else {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        return .ok(FeedProjectionBridge.shared.list(scope: scope))
    }

    // Worker-only. A failed note never changes the journal append receipt.
    nonisolated func v2FeedNoteDisplay(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        guard let workspaceRaw = params["workspace_id"] as? String, let workspaceID = UUID(uuidString: workspaceRaw),
              let tabRaw = params["tab_id"] as? String, let tabID = UUID(uuidString: tabRaw),
              let eventRaw = params["event_id"] as? String, let eventID = UUID(uuidString: eventRaw),
              let agentKind = params["agent_kind"] as? String, !agentKind.isEmpty,
              let sessionID = params["session_id"] as? String, !sessionID.isEmpty else {
            return .err(code: FeedNoteError.unmatched.rawValue, message: FeedNoteError.unmatched.rawValue, data: nil)
        }
        let requestID = params["request_id"] as? String
        let prompt = params["prompt"] as? String
        let options = params["options"] as? [String]
        if params["options"] != nil && options == nil {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        guard let owner = JournalCoordinator.shared.exactOwner(tabID: tabID),
              owner.agentKind == agentKind, owner.sessionID == sessionID, owner.tabID == tabID,
              JournalCoordinator.shared.target(tabID: tabID) == workspaceID else {
            return .err(code: FeedNoteError.unmatched.rawValue, message: FeedNoteError.unmatched.rawValue, data: nil)
        }
        if let code = FeedProjectionBridge.shared.acceptNote(
            tabID: tabID,
            workspaceID: workspaceID,
            agentKind: agentKind,
            sessionID: sessionID,
            eventID: eventID,
            requestID: requestID,
            prompt: prompt,
            options: options
        ) {
            return .err(code: code, message: code, data: nil)
        }
        return .ok(["accepted": true])
    }

    /// Focus intent. Validates both UUIDs before selection. `selectWorkspace` does not activate
    /// the app; `focusWorkspace` does, so this path does not call it.
    func v2FeedOpen(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        guard let workspaceID = v2UUID(params, "workspace_id"), let tabID = v2UUID(params, "tab_id") else {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        return v2MainSync {
            guard AppDelegate.shared?.selectFeedTarget(.init(workspaceID: workspaceID, tabID: tabID)) == true else {
                return .err(code: "unavailable", message: "unavailable", data: nil)
            }
            return .ok(["workspace_id": workspaceID.uuidString, "tab_id": tabID.uuidString])
        }
    }
}
