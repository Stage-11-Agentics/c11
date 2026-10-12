import Foundation

/// One lifecycle seam for panels that are permanently closed. Part B wires
/// mailbox delivery to this callback; moves and app termination do not fire it.
@MainActor
final class PanelLineage {
    static let shared = PanelLineage()

    var onPanelClosedForGood: ((UUID) -> Void)?
    private var closedPanelIds: Set<UUID> = []

    func panelClosedForGood(_ panelId: UUID, isDetaching: Bool = false) {
        guard PanelCloseForGoodPolicy.shouldFire(
            isDetaching: isDetaching,
            isTerminatingApp: AppDelegate.shared?.isTerminatingApp ?? false
        ) else { return }
        guard closedPanelIds.insert(panelId).inserted else { return }
        onPanelClosedForGood?(panelId)
    }

    func panelBecameLive(_ panelId: UUID) {
        closedPanelIds.remove(panelId)
    }
}
