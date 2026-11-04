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
        /// The panel's subtitle (`c11 set-description`) as it is now, or as
        /// it last was before the panel closed.
        var description: String? = nil
        /// Its subtitles over time, oldest first: what the panel said it was
        /// doing, which the web shows as the panel's story.
        var notes: [MessagesPagePanelHistory.Note] = []
        var created: String? = nil
        var closed: String? = nil

        var jsonObject: [String: Any] {
            var result: [String: Any] = ["id": id, "live": live]
            if let title { result["title"] = title }
            if let workspace { result["workspace"] = workspace }
            if let type { result["type"] = type }
            if let agent { result["agent"] = agent }
            if let address { result["address"] = address }
            if let parent { result["parent"] = parent }
            if let description { result["description"] = description }
            if !notes.isEmpty { result["notes"] = notes.map { ["at": $0.at, "text": $0.text] } }
            if let created { result["created"] = created }
            if let closed { result["closed"] = closed }
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
                        parent: nil,
                        description: nonEmpty(metadata[MetadataKey.description]?.stringValue)
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

    /// The part of the directory the page can use: open panels (any of them
    /// may be the one the operator centres on), panels the messages name by
    /// id or by an `id:<uuid>` address, and the ancestors of those. Closed
    /// panels nothing refers to are dropped, so a long session's lineage does
    /// not grow the page.
    func relevant(to messages: [MessagesPageRecord]) -> MessagesPageDirectory {
        var referenced = Set<String>()
        func idAddress(_ value: String?) -> String? {
            guard let value, value.lowercased().hasPrefix("id:") else { return nil }
            return String(value.dropFirst(3))
        }
        for message in messages {
            let named = [message.surface, message.senderID, idAddress(message.sender), idAddress(message.recipient)]
            for id in named.compactMap({ $0 }) + message.recipientPanelIDs {
                if let uuid = UUID(uuidString: id) { referenced.insert(uuid.uuidString) }
            }
        }
        let byID = Dictionary(panels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keep = Set(panels.filter { $0.live || referenced.contains($0.id) }.map(\.id))
        var frontier = Array(keep)
        while let id = frontier.popLast() {
            if let parent = byID[id]?.parent, !keep.contains(parent), byID[parent] != nil {
                keep.insert(parent)
                frontier.append(parent)
            }
        }
        let keptPanels = panels.filter { keep.contains($0.id) }
        let keptWorkspaces = Set(keptPanels.compactMap(\.workspace))
        return MessagesPageDirectory(
            panels: keptPanels,
            workspaces: workspaces.filter { $0.live || keptWorkspaces.contains($0.id) }
        )
    }

    /// The directory with live panel facts laid over it: titles, addresses
    /// and workspaces read from the running app at one moment. The overlay
    /// is the whole set of open panels, so any panel it omits is closed.
    func overlaying(live: [Panel]) -> MessagesPageDirectory {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = panels.map { panel -> Panel in
            var panel = panel
            if let fresh = liveByID[panel.id] {
                panel.title = fresh.title ?? panel.title
                panel.address = fresh.address
                panel.workspace = fresh.workspace ?? panel.workspace
                panel.description = fresh.description ?? panel.description
                panel.live = true
                panel.closed = nil
            } else {
                panel.live = false
            }
            return panel
        }
        let known = Set(panels.map(\.id))
        merged.append(contentsOf: live.filter { !known.contains($0.id) })
        var result = workspaces
        let knownWorkspaces = Set(workspaces.map(\.id))
        for id in Set(live.compactMap(\.workspace)) where !knownWorkspaces.contains(id) {
            result.append(Workspace(id: id, title: nil, live: true))
        }
        return MessagesPageDirectory(panels: merged, workspaces: result)
    }

    /// The directory with what the event log remembers laid under it: a
    /// title, subtitle and workspace for panels the session no longer knows
    /// (closed, their lineage pruned), every panel's subtitle history, and
    /// names for closed workspaces. What the session says wins.
    func adding(history: MessagesPagePanelHistory) -> MessagesPageDirectory {
        var merged = panels.map { panel -> Panel in
            var panel = panel
            guard let entry = history.panels[panel.id] else { return panel }
            if panel.title == nil || (!panel.live && MessagesPagePanelHistory.isGeneric(panel.title)) {
                panel.title = entry.title ?? panel.title
            }
            // A live panel's subtitle is what the session says, even empty:
            // a cleared subtitle must not come back from history.
            if !panel.live { panel.description = panel.description ?? entry.description }
            panel.workspace = panel.workspace ?? entry.workspace
            panel.type = panel.type ?? entry.kind
            panel.notes = entry.notes
            panel.created = entry.created
            panel.closed = panel.live ? nil : entry.closed
            return panel
        }
        let known = Set(panels.map(\.id))
        for id in history.order where !known.contains(id) {
            guard let entry = history.panels[id] else { continue }
            merged.append(Panel(
                id: id, title: entry.title, workspace: entry.workspace, live: false,
                type: entry.kind, agent: nil, address: nil, parent: entry.parent,
                description: entry.description, notes: entry.notes,
                created: entry.created, closed: entry.closed
            ))
        }
        var mergedWorkspaces = workspaces.map { workspace -> Workspace in
            var workspace = workspace
            workspace.title = workspace.title ?? history.workspaceTitles[workspace.id]
            return workspace
        }
        let knownWorkspaces = Set(workspaces.map(\.id))
        for id in Set(merged.compactMap(\.workspace)).sorted() where !knownWorkspaces.contains(id) {
            mergedWorkspaces.append(Workspace(id: id, title: history.workspaceTitles[id], live: false))
        }
        return MessagesPageDirectory(panels: merged, workspaces: mergedWorkspaces)
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

/// What the event log remembers about panels and workspaces: each panel's
/// chosen title, subtitles over time, kind, workspace, and when it opened and
/// closed. Terminal-set (OSC) titles are ignored: they name the running
/// command, not the panel.
struct MessagesPagePanelHistory: Equatable {
    struct Note: Equatable {
        var at: String
        var text: String
    }

    struct Entry: Equatable {
        var title: String?
        /// The subtitle as it last stood: nil once it was cleared.
        var description: String?
        var notes: [Note] = []
        var kind: String?
        var workspace: String?
        var parent: String?
        var created: String?
        var closed: String?
    }

    /// The newest subtitles kept per panel, and the longest kept.
    static let maxNotes = 12
    static let maxNoteLength = 240
    static let genericTitles: Set<String> = ["Terminal", "Shell", "zsh", "bash", "Browser", "Markdown", "~"]

    var panels: [String: Entry] = [:]
    /// Panel ids in first-seen order, so the page is stable across rebuilds.
    var order: [String] = []
    var workspaceTitles: [String: String] = [:]

    static let empty = MessagesPagePanelHistory()

    static func isGeneric(_ title: String?) -> Bool {
        guard let title else { return true }
        return genericTitles.contains(title)
    }

    /// Whether the page keeps this event for the history (and so caches it).
    static func consumes(_ event: MessagesPageEvent) -> Bool {
        switch event.type {
        case EventEnvelope.EventType.metadataChanged.rawValue:
            // v1 logs spell the panel scope "surface".
            guard event.surface != nil,
                  ["panel", "surface"].contains(event.payload["scope"] as? String ?? ""),
                  let key = event.payload["key"] as? String else { return false }
            if key == MetadataKey.description { return true }
            return key == MetadataKey.title && event.payload["source"] as? String != "osc"
        case EventEnvelope.EventType.surfaceCreated.rawValue, EventEnvelope.EventType.surfaceClosed.rawValue:
            return event.surface != nil
        case EventEnvelope.EventType.workspaceCreated.rawValue, EventEnvelope.EventType.workspaceRenamed.rawValue:
            return event.workspace != nil
        default:
            return false
        }
    }

    static func build(events: [MessagesPageEvent]) -> MessagesPagePanelHistory {
        var result = MessagesPagePanelHistory()
        let relevant = events.filter(consumes).enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        func canonical(_ value: String?) -> String? {
            value.flatMap(UUID.init(uuidString:))?.uuidString
        }
        for event in relevant {
            let workspace = canonical(event.workspace)
            if event.type == EventEnvelope.EventType.workspaceCreated.rawValue
                || event.type == EventEnvelope.EventType.workspaceRenamed.rawValue {
                if let workspace, let title = trimmed(event.payload["title"] as? String) {
                    result.workspaceTitles[workspace] = title
                }
                continue
            }
            guard let id = canonical(event.surface) else { continue }
            if result.panels[id] == nil {
                result.panels[id] = Entry()
                result.order.append(id)
            }
            var entry = result.panels[id]!
            if let workspace { entry.workspace = workspace }
            switch event.type {
            case EventEnvelope.EventType.surfaceCreated.rawValue:
                entry.created = entry.created ?? event.timestamp
                entry.kind = entry.kind ?? trimmed(event.payload["kind"] as? String)
                entry.parent = entry.parent ?? canonical(event.payload["parent_panel_id"] as? String)
                // The creation title is not used: after a relaunch it can be a
                // restored OSC title (the last command run), not a chosen name.
                entry.closed = nil
            case EventEnvelope.EventType.surfaceClosed.rawValue:
                entry.closed = event.timestamp
            default:
                let key = event.payload["key"] as? String
                let value = trimmed(event.payload["value"] as? String)
                if key == MetadataKey.title {
                    if let value { entry.title = value }
                } else if let value {
                    let text = value.count > maxNoteLength ? String(value.prefix(maxNoteLength - 1)) + "…" : value
                    entry.description = text
                    if entry.notes.last?.text != text {
                        entry.notes.append(Note(at: event.timestamp, text: text))
                        if entry.notes.count > maxNotes { entry.notes.removeFirst(entry.notes.count - maxNotes) }
                    }
                } else {
                    entry.description = nil
                }
            }
            result.panels[id] = entry
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
