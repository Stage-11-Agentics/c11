import Foundation

extension TerminalController {
    private static let historyTimestampFormatter = ISO8601DateFormatter()

    /// Parse on the socket worker; only bounded live state copying runs on main.
    nonisolated func v2HistoryList(params: [String: Any]) -> V2CallResult {
        guard let limit = FocusHistoryLimit.parse(params["limit"]) else {
            return .err(code: "invalid_params", message: FocusHistoryLimit.error, data: nil)
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { v2HistorySnapshot(limit: limit) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { v2HistorySnapshot(limit: limit) }
        }
    }

    private func v2HistorySnapshot(limit: Int) -> V2CallResult {
        let store = FocusHistoryStore.shared
        store.reconcile()
        v2RefreshKnownRefs()
        let snapshot = store.snapshot()
        let start = max(0, snapshot.entries.count - limit)
        let rows = snapshot.entries.enumerated().dropFirst(start).compactMap { offset, entry in
            v2HistoryEntry(entry, current: offset == snapshot.index)
        }
        return .ok([
            "threshold_seconds": store.model.threshold,
            "cap": FocusHistoryModel.cap,
            "total": snapshot.entries.count,
            "position": v2OrNull(snapshot.index),
            "back_count": snapshot.index ?? 0,
            "forward_count": snapshot.index.map { snapshot.entries.count - $0 - 1 } ?? 0,
            "entries": rows
        ])
    }

    func v2DispatchHistory(_ method: String, id: Any?, params: [String: Any]) -> String {
        guard method == "history.back" || method == "history.forward" else {
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        guard params["limit"] == nil else {
            return v2Error(id: id, code: "invalid_params", message: "limit applies to history listing")
        }
        // Main is necessary: navigation explicitly mutates window/workspace/tab selection.
        // Policy helpers preserve macOS activation while permitting in-app focus intent.
        let store = FocusHistoryStore.shared
        guard store.navigate(back: method == "history.back", focus: { manager, workspace, panelId in
            self.v2MaybeFocusWindow(for: manager)
            self.v2MaybeSelectWorkspace(manager, workspace: workspace)
            guard manager.selectedWorkspaceId == workspace.id else { return }
            workspace.focusPanel(panelId)
        }), let index = store.model.index,
           var result = v2HistoryEntry(store.model.entries[index], current: true) else {
            return v2Error(id: id, code: "not_found", message:
                method == "history.back" ? "No earlier focus history entry" : "No later focus history entry")
        }
        v2RefreshKnownRefs()
        result["position"] = index
        return v2Ok(id: id, result: result)
    }

    private func v2HistoryEntry(_ entry: FocusHistoryEntry, current: Bool) -> [String: Any]? {
        guard let location = AppDelegate.shared?.locateSurface(surfaceId: entry.panelId),
              let workspace = location.workspaceManager.workspaces.first(where: { $0.id == location.workspaceId }),
              let panel = workspace.panels[entry.panelId] else { return nil }
        return [
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "workspace_title": workspace.title,
            "tab_id": entry.panelId.uuidString,
            "tab_ref": v2Ref(kind: .surface, uuid: entry.panelId),
            "title": workspace.tabTitle(panelId: entry.panelId) ?? panel.displayTitle,
            "type": panel.panelType.rawValue,
            "seen_at": Self.historyTimestampFormatter.string(from: entry.seenAt),
            "dwell_seconds": (entry.dwell * 1000).rounded() / 1000,
            "current": current
        ]
    }
}
