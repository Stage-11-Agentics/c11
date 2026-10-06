import Foundation

/// Lives on the same actor as the event-driven seen tracker. No I/O or per-key work.
@MainActor
final class FocusHistoryStore {
    static let shared = FocusHistoryStore()
    private(set) var model: FocusHistoryModel
    private let now: () -> Date

    init(threshold: TimeInterval? = nil, now: @escaping () -> Date = { Date() }) {
        let configured = threshold ?? (UserDefaults.standard.object(forKey: "focusHistory.dwellSeconds") as? Double)
            ?? FocusHistoryModel.defaultThreshold
        model = FocusHistoryModel(threshold: configured)
        self.now = now
    }

    func noteTransition(panelId: UUID?, at date: Date) {
        let location = panelId.flatMap { AppDelegate.shared?.locateSurface(surfaceId: $0) }
        model.noteSeen(workspaceId: location?.workspaceId, panelId: location == nil ? nil : panelId, at: date)
    }

    func prune(panelId: UUID) { model.prune(panelId: panelId) }

    func reconcile() {
        model.reconcile { AppDelegate.shared?.locateSurface(surfaceId: $0.panelId)?.workspaceId }
    }

    func snapshot() -> FocusHistorySnapshot { model.snapshot() }

    func restore(_ snapshot: FocusHistorySnapshot?) {
        guard let snapshot else { return }
        model.restore(snapshot)
        reconcile()
        // The seen tracker may already be observing this tab, so its next refresh
        // would be a no-op. Start a fresh post-restore visit without restoring dwell.
        if let panelId = AppDelegate.shared?.operatorSeenPanelId(),
           PanelSeenTracker.shared.isBeingSeen(panelId: panelId) {
            noteTransition(panelId: panelId, at: now())
        }
    }

    /// Focus commands need AppKit selection on main. Socket callers provide the
    /// existing focus-policy helpers; menu callers use their explicit UI intent.
    @discardableResult
    func navigate(back: Bool, focus: ((WorkspaceManager, Workspace, UUID) -> Void)? = nil) -> Bool {
        reconcile()
        let priorModel = model
        let date = now()
        model.prepareForNavigation(at: date)
        let entry = back ? model.back(isLive: { _ in true }) : model.forward(isLive: { _ in true })
        guard let entry,
              let location = AppDelegate.shared?.locateSurface(surfaceId: entry.panelId),
              let workspace = location.workspaceManager.workspaces.first(where: { $0.id == location.workspaceId }) else {
            return false
        }
        if let focus {
            focus(location.workspaceManager, workspace, entry.panelId)
        } else {
            _ = AppDelegate.shared?.focusMainWindow(windowId: location.windowId)
            if location.workspaceManager.selectedWorkspaceId != workspace.id {
                location.workspaceManager.selectWorkspace(workspace)
            }
            guard location.workspaceManager.selectedWorkspaceId == workspace.id else {
                model = priorModel
                return false
            }
            workspace.focusPanel(entry.panelId)
        }
        // A refused socket switch must not consume an operator history step.
        guard location.workspaceManager.selectedWorkspaceId == workspace.id else {
            model = priorModel
            return false
        }
        PanelSeenTracker.shared.refresh()
        // Two visits may resolve to the same live tab after intermediate tabs close.
        // In that case refresh is unchanged, but the landing still needs an open visit.
        if PanelSeenTracker.shared.isBeingSeen(panelId: entry.panelId) {
            noteTransition(panelId: entry.panelId, at: now())
        }
        return true
    }
}
