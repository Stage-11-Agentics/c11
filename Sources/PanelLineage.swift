import Foundation

/// One lifecycle seam for panels that are permanently closed. Part B wires
/// mailbox delivery to these observers; moves and app termination do not fire it.
@MainActor
final class PanelLineage {
    static let shared = PanelLineage()

    private var panelClosedForGoodObservers: [(Set<UUID>) -> Void] = []
    private var didInstallConversationStoreCloseObserver = false
    private(set) var store = PanelLineageStore()
    private var creatorPanelId: UUID?
    private var closedPanelIds: Set<UUID> = []
    private var closeBatchDepth = 0
    private var batchedClosedPanelIds: Set<UUID> = []

    func addPanelClosedForGoodObserver(_ body: @escaping (Set<UUID>) -> Void) {
        panelClosedForGoodObservers.append(body)
    }

    func installConversationStoreCloseObserver() {
        guard !didInstallConversationStoreCloseObserver else { return }
        didInstallConversationStoreCloseObserver = true
        addPanelClosedForGoodObserver { panelIds in
            Task.detached(priority: .utility) {
                let store = ConversationStore.shared
                for panelId in panelIds {
                    await store.clear(surfaceId: panelId.uuidString)
                }
            }
        }
    }

    func withCreator<T>(_ panelId: UUID?, operation: () throws -> T) rethrows -> T {
        let previous = creatorPanelId
        creatorPanelId = panelId
        defer { creatorPanelId = previous }
        return try operation()
    }

    @discardableResult
    func panelInserted(_ panel: any Panel, in workspace: Workspace) -> UUID? {
        let metadata = PanelMetadataStore.shared.getMetadata(
            workspaceId: workspace.id,
            surfaceId: panel.id
        ).metadata
        closedPanelIds.remove(panel.id)
        return store.insert(
            panelId: panel.id,
            creatorPanelId: creatorPanelId,
            workspaceId: workspace.id,
            workspaceTitle: workspace.title,
            title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
            type: panel.panelType.rawValue,
            agentType: metadata[MetadataKey.terminalType] as? String
        )
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
        for panelId in panelIds {
            refreshLiveNode(panelId)
            guard store.node(panelId: panelId)?.isClosed != true,
                  closedPanelIds.insert(panelId).inserted else { continue }
            newlyClosed.insert(panelId)
        }
        guard !newlyClosed.isEmpty else { return }
        store.close(panelIds: newlyClosed)

        if closeBatchDepth > 0 {
            batchedClosedPanelIds.formUnion(newlyClosed)
            return
        }

        notifyPanelClosedForGoodObservers(newlyClosed)
    }

    /// Collects panels that actually close during a synchronous operation and
    /// publishes them as one batch after per-panel cleanup completes. Nested
    /// batches share the outer batch so observers see the full teardown set.
    func withCloseBatch<T>(_ operation: () throws -> T) rethrows -> T {
        closeBatchDepth += 1
        defer {
            closeBatchDepth -= 1
            if closeBatchDepth == 0, !batchedClosedPanelIds.isEmpty {
                let closedPanelIds = batchedClosedPanelIds
                batchedClosedPanelIds.removeAll(keepingCapacity: true)
                notifyPanelClosedForGoodObservers(closedPanelIds)
            }
        }
        return try operation()
    }

    private func notifyPanelClosedForGoodObservers(_ panelIds: Set<UUID>) {
        for observer in panelClosedForGoodObservers {
            observer(panelIds)
        }
    }

    /// Refreshes final panel identity from a workspace that is already known
    /// to the close path. Call before removing panels/caches or unregistering
    /// the owning window, when global workspace lookup may no longer find it.
    func captureFinalIdentity(_ panelIds: Set<UUID>, in workspace: Workspace) {
        for panelId in panelIds {
            guard let existing = store.node(panelId: panelId), !existing.isClosed,
                  let panel = workspace.panels[panelId] else { continue }
            let metadata = PanelMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                surfaceId: panelId
            ).metadata
            store.updateLiveState(
                panelId: panelId,
                workspaceId: workspace.id,
                workspaceTitle: workspace.title,
                title: workspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
                type: panel.panelType.rawValue,
                agentType: metadata[MetadataKey.terminalType] as? String
            )
        }
    }

    func updateTitle(panelId: UUID, title: String) { store.updateTitle(panelId: panelId, title: title) }

    func node(panelId: UUID) -> PanelLineageNode? {
        refreshLiveNode(panelId)
        return store.node(panelId: panelId)
    }

    /// Parent links are fixed at insertion; reading one needs no identity refresh.
    func parentPanelId(panelId: UUID) -> UUID? {
        store.node(panelId: panelId)?.parentPanelId
    }

    func family(startingAt panelId: UUID) -> (rootId: UUID, nodes: [PanelLineageNode])? {
        for node in store.snapshot() where !node.isClosed { refreshLiveNode(node.id) }
        return store.family(startingAt: panelId)
    }

    func restore(_ nodes: [PanelLineageNode]) {
        closedPanelIds.removeAll()
        store.replace(with: nodes)
    }

    func finishRestore(livePanelIds: Set<UUID>) { store.finishRestore(livePanelIds: livePanelIds) }

    func snapshot() -> [PanelLineageNode] {
        for node in store.snapshot() where !node.isClosed { refreshLiveNode(node.id) }
        return store.snapshot()
    }

    private func refreshLiveNode(_ panelId: UUID) {
        guard let existing = store.node(panelId: panelId), !existing.isClosed,
              let located = AppDelegate.shared?.workspaceContainingPanel(
                panelId: panelId,
                preferredWorkspaceId: existing.workspaceId
              ) else { return }
        captureFinalIdentity([panelId], in: located.workspace)
    }
}
