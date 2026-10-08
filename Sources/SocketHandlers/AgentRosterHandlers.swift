import Foundation

extension TerminalController {
    /// Parse on the socket worker. One short main hop copies live rows; SQLite stays off main.
    /// This method does not focus a window, workspace, or tab.
    nonisolated func v2AgentsList(params: [String: Any]) -> V2CallResult {
        guard params.isEmpty else {
            return .err(code: "invalid_params", message: "agents.list takes no parameters", data: nil)
        }
        let live: [AgentRoster.LivePanel]
        if Thread.isMainThread {
            live = MainActor.assumeIsolated { agentsLiveCopy() }
        } else {
            live = DispatchQueue.main.sync { MainActor.assumeIsolated { agentsLiveCopy() } }
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return .ok(JournalCoordinator.shared.rosterDocument(live: live, now: now))
    }

    private func agentsLiveCopy() -> [AgentRoster.LivePanel] {
        guard let workspaces = AppDelegate.shared?.workspaceManager?.workspaces else { return [] }
        var seen = Set<UUID>()
        var rows: [AgentRoster.LivePanel] = []
        for workspace in workspaces {
            for panelId in workspace.panels.keys {
                seen.insert(panelId)
                rows.append(agentsLiveRow(panelID: panelId, workspaceID: workspace.id, workspace: workspace))
            }
        }
        for (panelID, workspaceID) in JournalCoordinator.shared.registeredTargets() where !seen.contains(panelID) {
            let workspace = workspaces.first { $0.id == workspaceID }
            rows.append(agentsLiveRow(panelID: panelID, workspaceID: workspaceID, workspace: workspace))
        }
        return rows
    }

    private func agentsLiveRow(panelID: UUID, workspaceID: UUID, workspace: Workspace?) -> AgentRoster.LivePanel {
        let attention = workspace?.attentionSnapshot(panelId: panelID)
        let owner = JournalCoordinator.shared.exactOwner(panelID: panelID)
        let snapshot = JournalCoordinator.shared.snapshot(panelID: panelID)
        let joined = snapshot?.owner == owner ? snapshot : nil
        return AgentRoster.LivePanel(
            panelID: panelID,
            workspaceID: workspaceID,
            sessionID: owner?.sessionID,
            kind: owner?.agentKind,
            snapshot: owner == nil ? nil : joined,
            turnStartedMs: owner == nil ? nil : JournalCoordinator.shared.cachedTurnStartedMs(panelID: panelID),
            flagged: attention?.isFlagged ?? false,
            suppressed: attention?.suppressed ?? false,
            lastSeenAt: PanelSeenTracker.shared.storedLastSeenAt(panelId: panelID)
        )
    }
}
