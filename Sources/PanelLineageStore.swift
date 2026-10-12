import Foundation

/// App-level creation lineage for a panel UUID. It is projected into panel
/// APIs, but never written into panel metadata or a workspace snapshot.
struct PanelLineageNode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var parentPanelId: UUID?
    var workspaceId: UUID
    var workspaceTitle: String
    var lastTitle: String
    var panelType: String
    var agentType: String?
    var closedAt: Date?

    var isClosed: Bool { closedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentPanelId = "parent_panel_id"
        case workspaceId = "workspace_id"
        case workspaceTitle = "workspace_title"
        case lastTitle = "last_title"
        case panelType = "panel_type"
        case agentType = "agent_type"
        case closedAt = "closed_at"
    }
}

/// Pure graph operations, usable by c11-logic without constructing a workspace.
struct PanelLineageStore: Equatable, Sendable {
    private(set) var nodes: [UUID: PanelLineageNode]

    init(nodes: [PanelLineageNode] = []) {
        self.nodes = nodes.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    @discardableResult
    mutating func insert(
        panelId: UUID,
        creatorPanelId: UUID?,
        workspaceId: UUID,
        workspaceTitle: String,
        title: String,
        type: String,
        agentType: String?
    ) -> UUID? {
        let existing = nodes[panelId]
        let candidateParentId = existing?.parentPanelId ?? creatorPanelId
        let parentId = candidateParentId.flatMap { nodes[$0] == nil ? nil : $0 }
        nodes[panelId] = PanelLineageNode(
            id: panelId,
            parentPanelId: parentId == panelId ? nil : parentId,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            lastTitle: title,
            panelType: type,
            agentType: agentType,
            closedAt: nil
        )
        return nodes[panelId]?.parentPanelId
    }

    mutating func updateLiveState(
        panelId: UUID,
        workspaceId: UUID,
        workspaceTitle: String,
        title: String,
        type: String,
        agentType: String?
    ) {
        guard var node = nodes[panelId], !node.isClosed else { return }
        node.workspaceId = workspaceId
        node.workspaceTitle = workspaceTitle
        node.lastTitle = title
        node.panelType = type
        node.agentType = agentType
        nodes[panelId] = node
    }

    mutating func updateTitle(panelId: UUID, title: String) {
        guard var node = nodes[panelId], !node.isClosed else { return }
        node.lastTitle = title
        nodes[panelId] = node
    }

    mutating func close(panelId: UUID, at date: Date = Date()) {
        guard var node = nodes[panelId], !node.isClosed else { return }
        node.closedAt = date
        nodes[panelId] = node
        pruneClosedNodesWithoutLiveDescendants()
    }

    func node(panelId: UUID) -> PanelLineageNode? { nodes[panelId] }

    func family(startingAt panelId: UUID) -> (rootId: UUID, nodes: [PanelLineageNode])? {
        guard nodes[panelId] != nil else { return nil }
        var rootId = panelId
        var ancestorChain: Set<UUID> = [panelId]
        while let parentId = nodes[rootId]?.parentPanelId,
              nodes[parentId] != nil,
              ancestorChain.insert(parentId).inserted {
            rootId = parentId
        }

        var result: [PanelLineageNode] = []
        var visited: Set<UUID> = []
        func append(_ id: UUID) {
            guard visited.insert(id).inserted, let node = nodes[id] else { return }
            result.append(node)
            let children = nodes.values
                .filter { $0.parentPanelId == id }
                .sorted {
                    let left = $0.lastTitle.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    let right = $1.lastTitle.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    return left == right
                        ? $0.id.uuidString < $1.id.uuidString
                        : left < right
                }
            for child in children { append(child.id) }
        }
        append(rootId)
        guard visited.contains(panelId) else { return nil }
        return (rootId, result)
    }

    mutating func pruneClosedNodesWithoutLiveDescendants() {
        let liveIds = nodes.values.filter { !$0.isClosed }.map(\.id)
        let removable = nodes.values.filter { node in
            node.isClosed && !liveIds.contains(where: { isDescendant($0, of: node.id) })
        }.map(\.id)
        for id in removable { nodes.removeValue(forKey: id) }
    }

    mutating func replace(with restoredNodes: [PanelLineageNode]) {
        nodes = restoredNodes.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    mutating func finishRestore(livePanelIds: Set<UUID>, at date: Date = Date()) {
        for id in Array(nodes.keys) {
            guard var node = nodes[id], !node.isClosed, !livePanelIds.contains(id) else { continue }
            node.closedAt = date
            nodes[id] = node
        }
        pruneClosedNodesWithoutLiveDescendants()
    }

    func snapshot() -> [PanelLineageNode] {
        nodes.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func isDescendant(_ candidateId: UUID, of ancestorId: UUID) -> Bool {
        var currentId = candidateId
        var seen: Set<UUID> = []
        while seen.insert(currentId).inserted,
              let parentId = nodes[currentId]?.parentPanelId {
            if parentId == ancestorId { return true }
            currentId = parentId
        }
        return false
    }
}
