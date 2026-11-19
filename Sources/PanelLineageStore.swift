import Foundation

/// Who made a panel, recorded once when it first appears and kept across
/// moves and relaunches. Only what was observed at creation is recorded:
/// nodes from before origins existed, and creators that could not be
/// resolved, are `unknown`, never a guess.
enum PanelOrigin: String, Codable, CaseIterable, Sendable {
    /// An operator UI action: click, shortcut, menu, sidebar.
    case `operator`
    /// A socket call made from a panel (`parent_panel_id` names it).
    case panel
    /// c11 itself; `origin_detail` names the reason (`launch`, `restore`,
    /// `chaos`; `config` is reserved for a saved config c11 opens at launch).
    case app
    /// A socket or CLI call with no caller panel (cron, LaunchAgent, bare shell).
    case external
    /// Not recorded: persisted before origins existed, or the creator was lost.
    case unknown
}

/// The origin a creation path asks for. `PanelLineageStore.insert` turns it
/// into the node's recorded origin.
struct PanelOriginRequest: Equatable, Sendable {
    var origin: PanelOrigin
    var detail: String?

    static let `operator` = PanelOriginRequest(origin: .operator)
    static let external = PanelOriginRequest(origin: .external)
    static let unknown = PanelOriginRequest(origin: .unknown)
    static func app(_ reason: String) -> PanelOriginRequest { .init(origin: .app, detail: reason) }

    /// The app reasons c11 records.
    enum AppReason {
        /// The workspace c11 opens when it starts with no session to restore,
        /// and the welcome or default grid it fills that workspace with.
        static let launch = "launch"
        static let restore = "restore"
        static let chaos = "chaos"
        static let config = "config"
    }

    /// Picks what a new panel records from what its creation path observed.
    /// Precedence: a caller panel, then a socket request (its caller panel,
    /// else external), then an app scope, then the startup session restore,
    /// then an external scope, then an operator scope; otherwise unknown.
    static func resolve(
        creatorPanelId: UUID?,
        socketRequest socketCallerPanelId: UUID?,
        inSocketRequest: Bool,
        appReason: String?,
        restoringSession: Bool,
        externalScope: Bool,
        operatorScope: Bool
    ) -> (creatorPanelId: UUID?, origin: PanelOriginRequest) {
        if let creatorPanelId { return (creatorPanelId, PanelOriginRequest(origin: .panel)) }
        if inSocketRequest {
            if let socketCallerPanelId { return (socketCallerPanelId, PanelOriginRequest(origin: .panel)) }
            return (nil, .external)
        }
        if let appReason { return (nil, .app(appReason)) }
        if restoringSession { return (nil, .app(AppReason.restore)) }
        if externalScope { return (nil, .external) }
        if operatorScope { return (nil, .operator) }
        return (nil, .unknown)
    }
}

/// App-level creation lineage for a panel UUID. It is projected into panel
/// APIs, but never written into panel metadata or a workspace snapshot.
struct PanelLineageNode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var parentPanelId: UUID?
    var origin: PanelOrigin = .unknown
    var originDetail: String?
    /// When the panel first appeared; nil for nodes recorded before C11H-260's launch origin.
    var createdAt: Date?
    var workspaceId: UUID
    var workspaceTitle: String
    var lastTitle: String
    var panelType: String
    var agentType: String?
    var closedAt: Date?

    var isClosed: Bool { closedAt != nil }

    /// ISO 8601 with the local numeric offset (`2026-11-13T10:57:04-08:00`,
    /// `+00:00` at zero), never `Z`.
    static func localTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        // `xxxxx` writes +00:00 where `XXXXX` (and ISO8601DateFormatter) write Z.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return formatter.string(from: date)
    }

    init(
        id: UUID,
        parentPanelId: UUID?,
        origin: PanelOrigin = .unknown,
        originDetail: String? = nil,
        createdAt: Date? = nil,
        workspaceId: UUID,
        workspaceTitle: String,
        lastTitle: String,
        panelType: String,
        agentType: String?,
        closedAt: Date?
    ) {
        self.id = id
        self.parentPanelId = parentPanelId
        self.origin = origin
        self.originDetail = originDetail
        self.createdAt = createdAt
        self.workspaceId = workspaceId
        self.workspaceTitle = workspaceTitle
        self.lastTitle = lastTitle
        self.panelType = panelType
        self.agentType = agentType
        self.closedAt = closedAt
    }

    /// Nodes persisted before origins existed carry no `origin`. One with a
    /// parent was made from that panel (the parent was observed); every other
    /// reads as `unknown`, as does a value this build does not know.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentPanelId = try container.decodeIfPresent(UUID.self, forKey: .parentPanelId)
        if let rawOrigin = try container.decodeIfPresent(String.self, forKey: .origin) {
            origin = PanelOrigin(rawValue: rawOrigin) ?? .unknown
        } else {
            origin = parentPanelId == nil ? .unknown : .panel
        }
        originDetail = origin == .unknown
            ? nil
            : try container.decodeIfPresent(String.self, forKey: .originDetail)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
        workspaceTitle = try container.decode(String.self, forKey: .workspaceTitle)
        lastTitle = try container.decode(String.self, forKey: .lastTitle)
        panelType = try container.decode(String.self, forKey: .panelType)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentPanelId = "parent_panel_id"
        case origin
        case originDetail = "origin_detail"
        case createdAt = "created_at"
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

    /// Records a panel's first appearance, or refreshes a known node (a move
    /// re-inserts it). A known node keeps its parent and origin. A new node
    /// with a creator panel is `panel` when that creator has a node; a
    /// creator the store has never seen is `unknown`, never `operator`.
    @discardableResult
    mutating func insert(
        panelId: UUID,
        creatorPanelId: UUID?,
        origin requested: PanelOriginRequest = .unknown,
        at date: Date = Date(),
        workspaceId: UUID,
        workspaceTitle: String,
        title: String,
        type: String,
        agentType: String?
    ) -> UUID? {
        let existing = nodes[panelId]
        let candidateParentId: UUID?
        if let existing {
            candidateParentId = existing.parentPanelId
        } else {
            candidateParentId = creatorPanelId
        }
        let resolvedParentId = candidateParentId.flatMap { nodes[$0] == nil ? nil : $0 }
        let parentId = resolvedParentId == panelId ? nil : resolvedParentId
        let origin: PanelOrigin
        let originDetail: String?
        if let existing {
            // A child whose creator is gone from the graph has lost its creator.
            origin = existing.origin == .panel && parentId == nil ? .unknown : existing.origin
            originDetail = origin == existing.origin ? existing.originDetail : nil
        } else if creatorPanelId != nil {
            origin = parentId == nil ? .unknown : .panel
            originDetail = nil
        } else {
            // `panel` needs a creator; a request for it without one is not an observation.
            origin = requested.origin == .panel ? .unknown : requested.origin
            originDetail = origin == .app ? requested.detail : nil
        }
        nodes[panelId] = PanelLineageNode(
            id: panelId,
            parentPanelId: parentId,
            origin: origin,
            originDetail: originDetail,
            createdAt: existing == nil ? date : existing?.createdAt,
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
        close(panelIds: [panelId], at: date)
    }

    mutating func close(panelIds: Set<UUID>, at date: Date = Date()) {
        var didCloseAny = false
        for panelId in panelIds {
            guard var node = nodes[panelId], !node.isClosed else { continue }
            node.closedAt = date
            nodes[panelId] = node
            didCloseAny = true
        }
        guard didCloseAny else { return }
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
