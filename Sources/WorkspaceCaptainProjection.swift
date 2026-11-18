import Foundation

/// A value projection of a workspace's declared address and its currently open
/// holders. Presence says that a panel holds the address, not that its harness
/// is running, idle, or reachable through a remote link.
struct WorkspaceCaptainSummary: Equatable, Sendable {
    enum State: String, Sendable { case unset, unheld, present, ambiguous }
    /// Where a resolved address came from: the workspace's own key (explicit
    /// or its C11.md default) or, when that is unset, its group's key.
    enum Scope: String, Sendable { case workspace, workspaceGroup = "workspace_group" }
    let address: String?
    let holders: [WorkspaceCaptainProjection.Holder]
    var scope: Scope? = nil
    /// The group whose key supplied the address (scope `workspaceGroup`), or
    /// the group a group-header summary describes.
    var groupID: UUID? = nil
    /// A member card leaves its slot empty when its group's header already
    /// shows this same address: one mark per group, never one per member.
    var shownByGroup: Bool = false

    static let unset = Self(address: nil, holders: [])
    var present: Bool { !holders.isEmpty }
    var state: State {
        guard address != nil else { return .unset }
        switch holders.count {
        case 0: return .unheld
        case 1: return .present
        default: return .ambiguous
        }
    }
    var title: String? { holders.count == 1 ? holders[0].title : nil }
    /// Whether a workspace card draws its own mark: a Captain is set and the
    /// group header is not already showing the same one.
    var cardShowsMark: Bool { address != nil && !shownByGroup }
    var panelIDs: [UUID] { holders.map(\.panelID) }
    var accessibilityDescription: String {
        guard let address else { return "" }
        if scope == .workspaceGroup {
            switch state {
            case .unset: return ""
            case .unheld:
                return String(format: String(localized: "sidebar.captain.group.absent", defaultValue: "Group captain absent: %@"), address)
            case .present:
                return String(format: String(localized: "sidebar.captain.group.present", defaultValue: "Group captain: %@ (%@)"), title ?? address, address)
            case .ambiguous:
                return String(format: String(localized: "sidebar.captain.group.ambiguous", defaultValue: "Group captain address %@ has multiple holders: %@"),
                              address, holders.map(\.title).joined(separator: ", "))
            }
        }
        switch state {
        case .unset: return ""
        case .unheld:
            return String(format: String(localized: "sidebar.captain.absent", defaultValue: "Captain absent: %@"), address)
        case .present:
            return String(format: String(localized: "sidebar.captain.present", defaultValue: "Captain: %@ (%@)"), title ?? address, address)
        case .ambiguous:
            return String(format: String(localized: "sidebar.captain.ambiguous", defaultValue: "Captain address %@ has multiple holders: %@"),
                          address, holders.map(\.title).joined(separator: ", "))
        }
    }

    /// The five presence fields, as on a workspace-group record.
    var presenceJSONObject: [String: Any] {
        [
            "captain": address as Any? ?? NSNull(),
            "captain_present": present,
            "captain_state": state.rawValue,
            "captain_panel_ids": panelIDs.map(\.uuidString),
            "captain_title": title as Any? ?? NSNull(),
        ]
    }

    /// A workspace's resolved Captain and where it came from.
    var jsonObject: [String: Any] {
        var object = presenceJSONObject
        object["captain_scope"] = scope?.rawValue as Any? ?? NSNull()
        object["captain_group_id"] = (scope == .workspaceGroup ? groupID?.uuidString : nil) as Any? ?? NSNull()
        return object
    }
}

/// The same global equality rule feeds tree, fleet, sidebar and panel frames.
/// Inputs include every workspace and every open panel, even non-agent panels.
/// Nothing persisted or authored can supply `is_captain` or presence directly.
struct WorkspaceCaptainProjection: Equatable, Sendable {
    /// A workspace's own effective key (explicit, else its C11.md default) and
    /// the window-local group it belongs to, if any.
    struct Declaration: Equatable, Sendable {
        let workspaceID: UUID
        let address: String?
        var groupID: UUID? = nil
    }
    /// A workspace group's own key. Groups have no root, so no file default.
    struct GroupDeclaration: Equatable, Sendable {
        let groupID: UUID
        let address: String?
    }
    struct Holder: Equatable, Sendable {
        let panelID: UUID
        let workspaceID: UUID
        let address: String?
        let title: String
        /// C11H-360: the panel's terminal runs on a linked machine. A linked
        /// panel never holds an address a panel on this Mac holds.
        var linked = false
    }

    let workspaces: [UUID: WorkspaceCaptainSummary]
    let groups: [UUID: WorkspaceCaptainSummary]
    let captainPanelIDs: Set<UUID>

    /// Resolution: the workspace's own key first, then its group's. A group
    /// never overrides a member that declares its own Captain.
    init(workspaces declarations: [Declaration], groups groupDeclarations: [GroupDeclaration] = [], panels: [Holder]) {
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        var groupAddresses: [UUID: String] = [:]
        for group in groupDeclarations {
            if let address = nonEmpty(group.address) { groupAddresses[group.groupID] = address }
        }
        struct Resolved { let address: String; let scope: WorkspaceCaptainSummary.Scope; let groupID: UUID?; let shown: Bool }
        var resolved: [UUID: Resolved] = [:]
        for declaration in declarations {
            let inherited = declaration.groupID.flatMap { groupAddresses[$0] }
            if let own = nonEmpty(declaration.address) {
                resolved[declaration.workspaceID] = .init(address: own, scope: .workspace,
                    groupID: declaration.groupID, shown: inherited == own)
            } else if let inherited, let groupID = declaration.groupID {
                resolved[declaration.workspaceID] = .init(address: inherited, scope: .workspaceGroup,
                    groupID: groupID, shown: true)
            }
        }
        let addresses = Set(resolved.values.map(\.address)).union(groupAddresses.values)
        var holdersByAddress: [String: [Holder]] = [:]
        for panel in panels {
            guard let address = panel.address, addresses.contains(address) else { continue }
            holdersByAddress[address, default: []].append(panel)
        }
        var captainPanelIDs: Set<UUID> = []
        for address in holdersByAddress.keys {
            // C11H-360: the L5 rule on the Captain route. Where a panel on
            // this Mac holds the address, linked holders do not count.
            if holdersByAddress[address]?.contains(where: { !$0.linked }) == true {
                holdersByAddress[address]?.removeAll(where: \.linked)
            }
            holdersByAddress[address]?.sort { $0.panelID.uuidString < $1.panelID.uuidString }
            captainPanelIDs.formUnion(holdersByAddress[address]?.map(\.panelID) ?? [])
        }
        var summaries: [UUID: WorkspaceCaptainSummary] = [:]
        for declaration in declarations {
            guard let value = resolved[declaration.workspaceID] else {
                summaries[declaration.workspaceID] = .unset
                continue
            }
            summaries[declaration.workspaceID] = .init(address: value.address, holders: holdersByAddress[value.address] ?? [],
                scope: value.scope, groupID: value.groupID, shownByGroup: value.shown)
        }
        var groupSummaries: [UUID: WorkspaceCaptainSummary] = [:]
        for group in groupDeclarations {
            guard let address = groupAddresses[group.groupID] else {
                groupSummaries[group.groupID] = .unset
                continue
            }
            groupSummaries[group.groupID] = .init(address: address, holders: holdersByAddress[address] ?? [],
                scope: .workspaceGroup, groupID: group.groupID)
        }
        self.workspaces = summaries
        self.groups = groupSummaries
        self.captainPanelIDs = captainPanelIDs
    }

    /// Presence for one window's group records (C11H-301). Group summaries
    /// depend only on the groups' own keys, so no workspace is resolved, and
    /// `holders` (a walk of every open panel, since a holder may be in any
    /// window) runs only when one of these groups declares a Captain.
    static func groupPresence(groups: [WorkspaceGroup],
                              groupMetadata: WorkspaceMetadataStore.ReadSnapshot,
                              holders: () -> [Holder]) -> WorkspaceCaptainProjection {
        let declarations = groups.map { group in
            GroupDeclaration(groupID: group.id,
                             address: groupMetadata.metadata[group.id]?[WorkspaceMetadataKey.captain] as? String)
        }
        guard declarations.contains(where: { !($0.address ?? "").isEmpty }) else {
            return WorkspaceCaptainProjection(workspaces: [], groups: declarations, panels: [])
        }
        return WorkspaceCaptainProjection(workspaces: [], groups: declarations, panels: holders())
    }

    func summary(for workspaceID: UUID) -> WorkspaceCaptainSummary { workspaces[workspaceID] ?? .unset }
    func groupSummary(for groupID: UUID) -> WorkspaceCaptainSummary { groups[groupID] ?? .unset }
    func isCaptain(_ panelID: UUID) -> Bool { captainPanelIDs.contains(panelID) }
    var hasDeclarations: Bool {
        workspaces.values.contains { $0.address != nil } || groups.values.contains { $0.address != nil }
    }
}

/// Change-driven publication. It is never queried by a draw, hit test, keystroke
/// or activity timer. Identity and topology changes collapse into one main turn,
/// and only changed value summaries invalidate their Workspace views.
@MainActor
final class WorkspaceCaptainCoordinator {
    static let shared = WorkspaceCaptainCoordinator()
    private var pending = false
    private var hasDeclarations = false
    private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private let refreshProjection: () -> WorkspaceCaptainProjection

    private convenience init() {
        self.init(schedule: { action in DispatchQueue.main.async { action() } },
                  refreshProjection: Self.refreshLiveProjection)
    }

    /// The production scheduling/notification path with a value-only capture
    /// seam. Logic tests can count captures and drain a turn without NSApp.
    init(notificationCenter: NotificationCenter = .default,
         schedule: @escaping (@escaping @MainActor () -> Void) -> Void,
         refreshProjection: @escaping () -> WorkspaceCaptainProjection) {
        self.notificationCenter = notificationCenter
        self.schedule = schedule
        self.refreshProjection = refreshProjection
        for name in [WorkspaceMetadataStore.didChangeNotification, PanelMetadataStore.identityDidChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if name == WorkspaceMetadataStore.didChangeNotification {
                        // Unrelated workspace JSON cannot change the declaration.
                        if let keys = note.userInfo?["changedKeys"] as? [String],
                           let removed = note.userInfo?["removedKeys"] as? [String],
                           !keys.contains(WorkspaceMetadataKey.captain), !removed.contains(WorkspaceMetadataKey.captain) {
                            return
                        }
                        self?.invalidate()
                    } else if let keys = note.userInfo?["changedKeys"] as? [String],
                              !keys.contains(MetadataKey.mailboxAddress) {
                        self?.invalidateTitle()
                    } else {
                        self?.invalidate()
                    }
                }
            })
        }
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    /// A cached negative avoids even queuing work for OSC/title churn. A newly
    /// declared captain has its own unconditional invalidation, so dropping a
    /// title while that notification is pending cannot hide the declaration.
    func invalidateTitle() {
        guard hasDeclarations else { return }
        invalidate()
    }

    /// Declaration/address/topology changes always refresh, including removal
    /// of the final declaration: the resulting empty projection erases old ink.
    func invalidate() {
        guard !pending else { return }
        pending = true
        schedule { [weak self] in
            guard let self else { return }
            self.pending = false
            let projection = self.refreshProjection()
            self.hasDeclarations = projection.hasDeclarations
        }
    }

    private static func refreshLiveProjection() -> WorkspaceCaptainProjection {
        let managers = AppDelegate.shared?.fleetWorkspaceManagers() ?? []
        let workspaces = managers.flatMap { windowId, manager in manager.workspaces.map { (windowId: windowId, workspace: $0) } }
        let groups = managers.flatMap { windowId, manager in manager.workspaceGroups.map { (windowId: windowId, group: $0) } }
        let projection = Self.capture(workspaces: workspaces, groups: groups)
        for (_, workspace) in workspaces {
            let summary = projection.summary(for: workspace.id)
            if workspace.captainSummary != summary { workspace.captainSummary = summary }
            let panels: Set<UUID> = projection.captainPanelIDs.isEmpty
                ? [] : Set(workspace.panels.keys).intersection(projection.captainPanelIDs)
            if workspace.captainPanelIDs != panels { workspace.captainPanelIDs = panels }
        }
        for (_, manager) in managers {
            var summaries: [UUID: WorkspaceCaptainSummary] = [:]
            for group in manager.workspaceGroups {
                let summary = projection.groupSummary(for: group.id)
                if summary.address != nil { summaries[group.id] = summary }
            }
            let board = manager.workspaceGroupCaptainBoard
            if board.summaries != summaries { board.summaries = summaries }
        }
        return projection
    }

    /// One immutable panel metadata copy accompanies the live topology. Caller
    /// supplies it when already capturing fleet; no per-panel store reads.
    /// `groups` nil reads every window's live groups.
    static func capture(
        workspaces: [(windowId: UUID, workspace: Workspace)],
        groups: [(windowId: UUID, group: WorkspaceGroup)]? = nil,
        metadata: PanelMetadataStore.ReadSnapshot? = nil,
        workspaceMetadata: WorkspaceMetadataStore.ReadSnapshot? = nil,
        groupMetadata: WorkspaceMetadataStore.ReadSnapshot? = nil
    ) -> WorkspaceCaptainProjection {
        let workspaceMetadata = workspaceMetadata ?? WorkspaceMetadataStore.shared.readSnapshot()
        let groups = groups ?? AppDelegate.shared?.fleetWorkspaceGroups() ?? []
        let groupMetadata = groupMetadata ?? WorkspaceMetadataStore.groups.readSnapshot()
        let groupDeclarations = groups.map { _, group in
            WorkspaceCaptainProjection.GroupDeclaration(groupID: group.id,
                address: groupMetadata.metadata[group.id]?[WorkspaceMetadataKey.captain] as? String)
        }
        let liveGroups = Set(groups.map(\.group.id))
        let declarations = workspaces.map { _, workspace in
            WorkspaceCaptainProjection.Declaration(workspaceID: workspace.id,
                address: workspaceMetadata.metadata[workspace.id]?[WorkspaceMetadataKey.captain] as? String,
                groupID: workspace.groupId.flatMap { liveGroups.contains($0) ? $0 : nil })
        }
        // No panel metadata copy or panel enumeration until a declaration needs
        // holders. This still returns each workspace so stale UI can be cleared.
        guard declarations.contains(where: { !($0.address ?? "").isEmpty })
            || groupDeclarations.contains(where: { !($0.address ?? "").isEmpty }) else {
            return WorkspaceCaptainProjection(workspaces: declarations, groups: groupDeclarations, panels: [])
        }
        return WorkspaceCaptainProjection(workspaces: declarations, groups: groupDeclarations,
                                          panels: holders(in: workspaces, metadata: metadata))
    }

    /// Every open panel in `workspaces` as a possible holder, read from one
    /// immutable panel metadata copy (the caller's, else a fresh one).
    static func holders(in workspaces: [(windowId: UUID, workspace: Workspace)],
                        metadata: PanelMetadataStore.ReadSnapshot? = nil) -> [WorkspaceCaptainProjection.Holder] {
        let metadata = metadata ?? PanelMetadataStore.shared.readSnapshot()
        var panels: [WorkspaceCaptainProjection.Holder] = []
        for (_, workspace) in workspaces {
            for panel in workspace.panels.values {
                panels.append(.init(
                    panelID: panel.id, workspaceID: workspace.id,
                    address: metadata.metadata[workspace.id]?[panel.id]?[MetadataKey.mailboxAddress] as? String,
                    title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    linked: (panel as? TerminalPanel)?.hcRemoteTarget != nil
                ))
            }
        }
        return panels
    }

    static func captureCurrent() -> WorkspaceCaptainProjection {
        capture(workspaces: AppDelegate.shared?.fleetWorkspaces() ?? [])
    }
}

/// The `--to-captain` decision for a caller's workspace, from a fresh capture.
/// Every failure is reported before an envelope exists; only `.holder` may
/// lead to a write. A workspace with no Captain of its own uses its group's.
enum WorkspaceCaptainMailRoute {
    case failure(code: String, message: String, data: [String: Any]?)
    case holder(address: String, holder: WorkspaceCaptainProjection.Holder, scope: [String: Any])

    static func route(_ summary: WorkspaceCaptainSummary, workspaceGroupID: UUID?) -> Self {
        let grouped = summary.scope == .workspaceGroup
        var scope: [String: Any] = [
            "captain_scope": summary.scope?.rawValue as Any? ?? NSNull(),
            "captain_group_id": (grouped ? summary.groupID?.uuidString : nil) as Any? ?? NSNull(),
        ]
        switch summary.state {
        case .unset:
            if workspaceGroupID != nil {
                return .failure(code: "captain_unset", message: String(localized: "mailbox.captain.unsetWithGroup",
                    defaultValue: "Neither this workspace nor its group has a captain address; no envelope was written."), data: scope)
            }
            return .failure(code: "captain_unset", message: String(localized: "mailbox.captain.unset",
                defaultValue: "This workspace has no captain address; no envelope was written."), data: scope)
        case .unheld:
            scope["captain"] = summary.address ?? ""
            return .failure(code: "captain_unheld", message: grouped
                ? String(localized: "mailbox.captain.group.unheld",
                    defaultValue: "No open panel holds this workspace group's captain address; no envelope was written.")
                : String(localized: "mailbox.captain.unheld",
                    defaultValue: "No open panel holds this workspace's captain address; no envelope was written."),
                data: scope)
        case .ambiguous:
            scope["captain"] = summary.address ?? ""
            scope["panel_ids"] = summary.panelIDs.map(\.uuidString)
            return .failure(code: "captain_ambiguous", message: grouped
                ? String(localized: "mailbox.captain.group.ambiguous",
                    defaultValue: "More than one open panel holds this workspace group's captain address; no envelope was written.")
                : String(localized: "mailbox.captain.ambiguous",
                    defaultValue: "More than one open panel holds this workspace's captain address; no envelope was written."),
                data: scope)
        case .present:
            guard let address = summary.address, let holder = summary.holders.first else {
                return .failure(code: "captain_unheld", message: String(localized: "mailbox.captain.unheld",
                    defaultValue: "No open panel holds this workspace's captain address; no envelope was written."), data: nil)
            }
            return .holder(address: address, holder: holder, scope: scope)
        }
    }
}
