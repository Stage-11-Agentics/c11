import Foundation

/// One lifecycle seam for panels that are permanently closed. Part B wires
/// mailbox delivery to these observers; moves and app termination do not fire it.
@MainActor
final class PanelLineage {
    static let shared = PanelLineage()

    private var panelClosedForGoodObservers: [(Set<UUID>) -> Void] = []
    private var closedPanelIds: Set<UUID> = []

    func addPanelClosedForGoodObserver(_ body: @escaping (Set<UUID>) -> Void) {
        panelClosedForGoodObservers.append(body)
    }

    func panelClosedForGood(_ panelId: UUID, isDetaching: Bool = false) {
        panelsClosedForGood([panelId], isDetaching: isDetaching)
    }

    func panelsClosedForGood(_ panelIds: Set<UUID>, isDetaching: Bool = false) {
        guard PanelCloseForGoodPolicy.shouldFire(
            isDetaching: isDetaching,
            isTerminatingApp: AppDelegate.shared?.isTerminatingApp ?? false
        ), !panelIds.isEmpty else { return }

        var newlyClosed: Set<UUID> = []
        for panelId in panelIds where closedPanelIds.insert(panelId).inserted {
            newlyClosed.insert(panelId)
        }
        guard !newlyClosed.isEmpty else { return }

        for observer in panelClosedForGoodObservers {
            observer(newlyClosed)
        }
    }

    func panelBecameLive(_ panelId: UUID) {
        closedPanelIds.remove(panelId)
    }
}
