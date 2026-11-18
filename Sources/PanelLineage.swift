import Foundation

/// An open origin scope; close it with `PanelLineage.exitOrigin`.
struct PanelOriginScope {
    fileprivate let depth: Int
}

/// What a creation path observed, carried across a main-queue hop so the
/// panel created on the far side records the same origin (C11H-260).
struct PanelCreationCapture {
    fileprivate let creatorPanelId: UUID?
    fileprivate let origin: PanelOriginRequest
}

/// One lifecycle seam for panels that are permanently closed. Part B wires
/// mailbox delivery to these observers; moves and app termination do not fire it.
@MainActor
final class PanelLineage {
    static let shared = PanelLineage()

    private var panelClosedForGoodObservers: [(token: UUID, body: (Set<UUID>) -> Void)] = []
    private var didInstallConversationStoreCloseObserver = false
    private(set) var store = PanelLineageStore()
    private var creatorPanelId: UUID?
    /// A socket request whose `SocketCommandContext` stayed on its worker
    /// thread (agent.launch commits on a main-queue hop); it ranks as one.
    private var socketRequestDepth = 0
    /// Open origin scopes, each with the run-loop mode it was opened in. A
    /// scope counts only in that mode, so work a nested run loop (a modal, a
    /// menu track) runs while an operator action is on the stack is never
    /// taken for that action.
    private var originScopes: [(origin: PanelOriginRequest, mode: CFRunLoopMode?)] = []
    private var closedPanelIds: Set<UUID> = []
    private var closeBatchDepth = 0
    private var batchedClosedPanelIds: Set<UUID> = []

    /// Returns a token that `removePanelClosedForGoodObserver` takes.
    @discardableResult
    func addPanelClosedForGoodObserver(_ body: @escaping (Set<UUID>) -> Void) -> UUID {
        let token = UUID()
        panelClosedForGoodObservers.append((token, body))
        return token
    }

    func removePanelClosedForGoodObserver(_ token: UUID) {
        panelClosedForGoodObservers.removeAll { $0.token == token }
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

    /// A socket path creating panels on behalf of `panelId`, the caller panel.
    /// `socketRequest` marks work for a socket request whose context did not
    /// cross to this thread: with no caller it records external. Otherwise
    /// the origin comes from the socket context, then `fallback` or an
    /// enclosing origin scope.
    func withCreator<T>(
        _ panelId: UUID?,
        socketRequest: Bool = false,
        fallback: PanelOriginRequest? = nil,
        operation: () throws -> T
    ) rethrows -> T {
        let previous = creatorPanelId
        creatorPanelId = panelId
        if socketRequest { socketRequestDepth += 1 }
        defer {
            creatorPanelId = previous
            if socketRequest { socketRequestDepth -= 1 }
        }
        guard let fallback else { return try operation() }
        return try withOrigin(fallback, operation: operation)
    }

    /// Marks panels created synchronously inside `operation` with an origin.
    /// Wrap operator UI actions in `.operator`, c11's own creation in
    /// `.app(reason)`, and callers outside c11 with no panel in `.external`.
    /// A caller panel or a socket request still wins, and the scopes rank by
    /// kind, not nesting: app over external over operator, so an operator
    /// scope inside c11's own work never relabels it. Work that crosses a
    /// main-queue hop takes `captureCreation()` with it instead.
    func withOrigin<T>(_ origin: PanelOriginRequest, operation: () throws -> T) rethrows -> T {
        let scope = enterOrigin(origin)
        defer { exitOrigin(scope) }
        return try operation()
    }

    /// `withOrigin` for a whole function body:
    /// `let scope = PanelLineage.shared.enterOrigin(.operator); defer { PanelLineage.shared.exitOrigin(scope) }`.
    func enterOrigin(_ origin: PanelOriginRequest) -> PanelOriginScope {
        originScopes.append((origin, CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent())))
        return PanelOriginScope(depth: originScopes.count)
    }

    func exitOrigin(_ scope: PanelOriginScope) {
        assert(originScopes.count == scope.depth, "origin scopes must close innermost first")
        if !originScopes.isEmpty { originScopes.removeLast() }
    }

    /// The origin a panel inserted now records when it is new to the graph.
    /// Precedence: a caller panel (`withCreator`), then a socket request (its
    /// caller panel, else external), then an app scope, then the startup
    /// session restore, then an external scope, then an operator scope;
    /// otherwise unknown.
    func currentCreation() -> (creatorPanelId: UUID?, origin: PanelOriginRequest) {
        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent())
        var appReason: String?
        var externalScope = false
        var operatorScope = false
        for scope in originScopes where Self.sameMode(scope.mode, mode) {
            switch scope.origin.origin {
            case .app: appReason = scope.origin.detail ?? ""
            case .external: externalScope = true
            case .operator: operatorScope = true
            case .panel, .unknown: break
            }
        }
        let context = SocketCommandContext.current
        return PanelOriginRequest.resolve(
            creatorPanelId: creatorPanelId,
            socketRequest: context?.callerPanelId,
            inSocketRequest: context != nil || socketRequestDepth > 0,
            appReason: appReason,
            restoringSession: AppDelegate.shared?.isApplyingStartupSessionRestore == true,
            externalScope: externalScope,
            operatorScope: operatorScope
        )
    }

    /// What a panel created now would record, to replay after a main-queue
    /// hop (a palette command that defers until the palette closes).
    func captureCreation() -> PanelCreationCapture {
        let creation = currentCreation()
        return PanelCreationCapture(creatorPanelId: creation.creatorPanelId, origin: creation.origin)
    }

    /// Runs `operation` so a panel it creates records what `capture` saw.
    func replay<T>(_ capture: PanelCreationCapture, operation: () throws -> T) rethrows -> T {
        switch capture.origin.origin {
        case .panel:
            return try withCreator(capture.creatorPanelId, socketRequest: true, operation: operation)
        case .external:
            return try withCreator(nil, socketRequest: true, operation: operation)
        case .app, .operator:
            return try withOrigin(capture.origin, operation: operation)
        case .unknown:
            return try operation()
        }
    }

    private static func sameMode(_ lhs: CFRunLoopMode?, _ rhs: CFRunLoopMode?) -> Bool {
        lhs == rhs
    }

    /// Records the panel in the graph and returns its node: its parent and
    /// its origin, kept from an earlier insertion when the panel moved.
    @discardableResult
    func panelInserted(_ panel: any Panel, in workspace: Workspace) -> PanelLineageNode? {
        let metadata = PanelMetadataStore.shared.getMetadata(
            workspaceId: workspace.id,
            surfaceId: panel.id
        ).metadata
        closedPanelIds.remove(panel.id)
        let creation = currentCreation()
        store.insert(
            panelId: panel.id,
            creatorPanelId: creation.creatorPanelId,
            origin: creation.origin,
            workspaceId: workspace.id,
            workspaceTitle: workspace.title,
            title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
            type: panel.panelType.rawValue,
            agentType: metadata[MetadataKey.terminalType] as? String
        )
        return store.node(panelId: panel.id)
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
            observer.body(panelIds)
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

    /// Origins are fixed at insertion; reading one needs no identity refresh.
    func origin(panelId: UUID) -> (origin: PanelOrigin, detail: String?)? {
        store.node(panelId: panelId).map { ($0.origin, $0.originDetail) }
    }

    /// Panels c11 adds to its launch workspace later (the welcome or default
    /// grid, after the first terminal is ready) are part of the launch.
    func inheritingLaunchOrigin<T>(from seedPanelId: UUID, operation: () throws -> T) rethrows -> T {
        guard let seed = store.node(panelId: seedPanelId), seed.origin == .app,
              seed.originDetail == PanelOriginRequest.AppReason.launch else { return try operation() }
        return try withOrigin(.app(PanelOriginRequest.AppReason.launch), operation: operation)
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
