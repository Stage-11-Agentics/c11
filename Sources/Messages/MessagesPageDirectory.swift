import Foundation

/// Who the panels and workspaces behind the messages page are: titles,
/// mailbox addresses, and whether each is still open. The page's conversation
/// web needs this to name both ends of a message; the message records carry
/// only addresses and panel ids.
///
/// Read from the session snapshot file, which c11 autosaves every few seconds,
/// so the writer never touches window or workspace state from its utility
/// queue. Closed panels come from the snapshot's lineage nodes.
struct MessagesPageDirectory: Equatable {
    struct Panel: Equatable {
        var id: String
        var title: String?
        var workspace: String?
        var live: Bool
        var type: String?
        var agent: String?
        var address: String?
        var parent: String?

        var jsonObject: [String: Any] {
            var result: [String: Any] = ["id": id, "live": live]
            if let title { result["title"] = title }
            if let workspace { result["workspace"] = workspace }
            if let type { result["type"] = type }
            if let agent { result["agent"] = agent }
            if let address { result["address"] = address }
            if let parent { result["parent"] = parent }
            return result
        }
    }

    struct Workspace: Equatable {
        var id: String
        var title: String?
        var live: Bool

        var jsonObject: [String: Any] {
            var result: [String: Any] = ["id": id, "live": live]
            if let title { result["title"] = title }
            return result
        }
    }

    var panels: [Panel]
    var workspaces: [Workspace]

    static let empty = MessagesPageDirectory(panels: [], workspaces: [])

    /// A session file larger than this is not read; the page then names
    /// panels from the message records alone.
    static let maxSessionFileBytes = 32 * 1024 * 1024

    var jsonObject: [String: Any] {
        [
            "panels": panels.map(\.jsonObject),
            "workspaces": workspaces.map(\.jsonObject),
            "link_scheme": "c11",
        ]
    }

    static func load(sessionURL: URL?) -> MessagesPageDirectory {
        guard let sessionURL,
              let data = MessagesPageSource.boundedFileData(at: sessionURL, limit: maxSessionFileBytes),
              let snapshot = try? JSONDecoder().decode(AppSessionSnapshot.self, from: data) else {
            return .empty
        }
        return build(from: snapshot)
    }

    static func build(from snapshot: AppSessionSnapshot) -> MessagesPageDirectory {
        var panels: [String: Panel] = [:]
        var panelOrder: [String] = []
        var workspaces: [String: Workspace] = [:]
        var workspaceOrder: [String] = []

        func addWorkspace(_ workspace: Workspace) {
            if var existing = workspaces[workspace.id] {
                existing.title = existing.title ?? workspace.title
                existing.live = existing.live || workspace.live
                workspaces[workspace.id] = existing
            } else {
                workspaces[workspace.id] = workspace
                workspaceOrder.append(workspace.id)
            }
        }

        for window in snapshot.windows {
            for workspace in window.workspaceManager.workspaces {
                let workspaceID = workspace.id.uuidString
                addWorkspace(Workspace(
                    id: workspaceID,
                    title: nonEmpty(workspace.customTitle)
                        ?? nonEmpty(workspace.stableDefaultTitle)
                        ?? nonEmpty(workspace.processTitle),
                    live: true
                ))
                for panel in workspace.panels {
                    let id = panel.id.uuidString
                    let metadata = panel.metadata ?? [:]
                    if panels[id] == nil { panelOrder.append(id) }
                    panels[id] = Panel(
                        id: id,
                        title: nonEmpty(panel.customTitle)
                            ?? nonEmpty(metadata["title"]?.stringValue)
                            ?? nonEmpty(panel.title),
                        workspace: workspaceID,
                        live: true,
                        type: panel.type.rawValue,
                        agent: nonEmpty(metadata[MetadataKey.terminalType]?.stringValue),
                        address: nonEmpty(metadata["mailbox.address"]?.stringValue),
                        parent: nil
                    )
                }
            }
        }

        for node in snapshot.panelLineageNodes ?? [] {
            let id = node.id.uuidString
            let workspaceID = node.workspaceId.uuidString
            addWorkspace(Workspace(id: workspaceID, title: nonEmpty(node.workspaceTitle), live: false))
            if var existing = panels[id] {
                existing.parent = node.parentPanelId?.uuidString
                existing.agent = existing.agent ?? nonEmpty(node.agentType)
                panels[id] = existing
            } else {
                panelOrder.append(id)
                panels[id] = Panel(
                    id: id,
                    title: nonEmpty(node.lastTitle),
                    workspace: workspaceID,
                    live: false,
                    type: nonEmpty(node.panelType),
                    agent: nonEmpty(node.agentType),
                    address: nil,
                    parent: node.parentPanelId?.uuidString
                )
            }
        }

        return MessagesPageDirectory(
            panels: panelOrder.compactMap { panels[$0] },
            workspaces: workspaceOrder.compactMap { workspaces[$0] }
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension PersistedJSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
