import Foundation
import Combine

/// Lives on the same actor as the event-driven seen tracker. No I/O or per-key work.
@MainActor
final class FocusHistoryStore: ObservableObject {
    static let shared = FocusHistoryStore()
    private(set) var model: FocusHistoryModel
    @Published private(set) var navigationState = FocusHistoryNavigationState()
    private let now: () -> Date
    private let currentLocation: @MainActor () -> FocusHistoryLocation?
    private let workspaceForPanel: @MainActor (UUID) -> UUID?
    private var recordingJump = false
    private var navigating = false

    init(threshold: TimeInterval? = nil, now: @escaping () -> Date = { Date() },
         currentLocation: @escaping @MainActor () -> FocusHistoryLocation? = {
             guard let panelId = AppDelegate.shared?.operatorSeenPanelId(),
                   let location = AppDelegate.shared?.locateSurface(surfaceId: panelId) else { return nil }
             return FocusHistoryLocation(workspaceId: location.workspaceId, panelId: panelId)
         },
         workspaceForPanel: @escaping @MainActor (UUID) -> UUID? = {
             AppDelegate.shared?.locateSurface(surfaceId: $0)?.workspaceId
         }) {
        let configured = threshold ?? (UserDefaults.standard.object(forKey: "focusHistory.dwellSeconds") as? Double)
            ?? FocusHistoryModel.defaultThreshold
        model = FocusHistoryModel(threshold: configured)
        self.now = now
        self.currentLocation = currentLocation
        self.workspaceForPanel = workspaceForPanel
    }

    func noteTransition(panelId: UUID?, at date: Date) {
        guard !recordingJump, !navigating else { return }
        let workspaceId = panelId.flatMap { workspaceForPanel($0) }
        model.noteSeen(workspaceId: workspaceId, panelId: workspaceId == nil ? nil : panelId, at: date)
        refreshNavigationState()
    }

    func prune(panelId: UUID) {
        model.prune(panelId: panelId)
        refreshNavigationState()
    }

    func reconcile() {
        model.reconcile { workspaceForPanel($0.panelId) }
        refreshNavigationState()
    }

    private func refreshNavigationState() {
        let state = model.navigationState(at: now()) { workspaceForPanel($0.panelId) }
        if navigationState != state { navigationState = state }
    }

    /// Only explicit native jump routes call this. It grants no focus privilege:
    /// socket requests run their existing policy-bound action without checkpoints.
    /// Nesting coalesces window/workspace/panel changes into the two real endpoints.
    func withExplicitJump<T>(_ operation: () throws -> T) rethrows -> T {
        guard SocketCommandContext.current == nil, !recordingJump, !navigating else {
            return try operation()
        }
        let source = currentLocation()
        let departedAt = now()
        recordingJump = true
        defer {
            recordingJump = false
            noteTransition(panelId: currentLocation()?.panelId, at: now())
        }
        let result = try operation()
        if let destination = currentLocation() {
            model.recordExplicitJump(from: source, to: destination, departedAt: departedAt, arrivedAt: now())
        }
        return result
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
        // A socket-triggered menu/key event is not an operator click. The CLI
        // history route supplies its own policy-bound focus closure below.
        guard focus != nil || SocketCommandContext.current == nil else { return false }
        navigating = true
        defer {
            navigating = false
            // Window activation and workspace selection can briefly expose an
            // intermediate panel. Only the settled landing starts a seen visit.
            noteTransition(panelId: currentLocation()?.panelId, at: now())
        }
        reconcile()
        let priorModel = model
        let date = now()
        model.prepareForNavigation(at: date, checkpoint: focus == nil)
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
        return true
    }
}
