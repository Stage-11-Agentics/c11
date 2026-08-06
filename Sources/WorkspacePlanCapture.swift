import Foundation
import AppKit
import Bonsplit

/// A deliberately narrow bridge for the ACB-06 integration lane. Persistence
/// can compile before Workspace/BrowserPanel expose their companion APIs; the
/// integrator supplies live link and identity reads without changing capture.
@MainActor
struct WorkspacePlanCompanionCaptureBridge {
    var linkedAgentForBrowser: @MainActor (UUID) -> AgentSurfaceLink?
    var declaredAgentKindForTerminal: @MainActor (UUID) -> String?

    static let none = WorkspacePlanCompanionCaptureBridge(
        linkedAgentForBrowser: { _ in nil },
        declaredAgentKindForTerminal: { _ in nil }
    )

    static func live(workspace: AgentCompanionWorkspaceAccess) -> Self {
        WorkspacePlanCompanionCaptureBridge(
            linkedAgentForBrowser: { browserID in
                switch workspace.companionPresentation(for: browserID) {
                case .unlinked:
                    return nil
                case .linkedNoContext(let linked),
                     .aligned(let linked),
                     .veiled(let linked, _),
                     .revealed(let linked, _):
                    return AgentSurfaceLink(
                        surfaceID: linked.identity.surfaceID,
                        lastKnownName: linked.identity.displayName
                    )
                case .orphaned(let link), .orphanedRevealed(let link):
                    return link
                }
            },
            declaredAgentKindForTerminal: { terminalID in
                workspace.liveAgentDescriptors.first {
                    $0.identity.surfaceID == terminalID
                }?.terminalKind
            }
        )
    }
}

struct WorkspacePlanCaptureResult: Equatable, Sendable {
    var plan: WorkspaceApplyPlan
    var warnings: [CompanionPlanDiagnostic]
}

/// Shared plan-capture logic used by both `LiveWorkspaceSnapshotSource` (Snapshots)
/// and `WorkspaceBlueprintExporter` (Blueprints). Walks AppKit / bonsplit state
/// on the main actor and returns a plan plus structured capture warnings.
@MainActor
enum WorkspacePlanCapture {
    static func capture(
        workspace: Workspace,
        companionBridge: WorkspacePlanCompanionCaptureBridge? = nil
    ) -> WorkspacePlanCaptureResult {
        let tree = workspace.bonsplitController.treeSnapshot()
        let resolvedCompanionBridge = companionBridge ?? .live(workspace: workspace)
        var walker = Walker(
            workspace: workspace,
            companionBridge: resolvedCompanionBridge
        )
        // Pass 1 reserves every plan-local id in Bonsplit pane/tab order.
        // Pass 2 may therefore encode browser-before-agent forward links.
        walker.reservePlanIDs(in: tree)
        let layout = walker.walk(tree)
        let spec = WorkspaceSpec(
            title: workspace.customTitle,
            customColor: workspace.customColor,
            workingDirectory: workspace.rootDirectory
                ?? (workspace.currentDirectory.isEmpty ? nil : workspace.currentDirectory),
            metadata: workspace.metadata.isEmpty ? nil : workspace.metadata
        )
        return WorkspacePlanCaptureResult(
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: spec,
                layout: layout,
                surfaces: walker.surfaces
            ),
            warnings: walker.warnings
        )
    }

    @MainActor
    private struct Walker {
        let workspace: Workspace
        let companionBridge: WorkspacePlanCompanionCaptureBridge
        var surfaces: [SurfaceSpec] = []
        var warnings: [CompanionPlanDiagnostic] = []
        private var planIDByPanelID: [UUID: String] = [:]
        private var nextIdCounter: Int = 1

        init(workspace: Workspace, companionBridge: WorkspacePlanCompanionCaptureBridge) {
            self.workspace = workspace
            self.companionBridge = companionBridge
        }

        mutating func reservePlanIDs(in node: ExternalTreeNode) {
            switch node {
            case .pane(let pane):
                for tab in pane.tabs {
                    guard let panelID = panelID(forTabIDString: tab.id),
                          workspace.panels[panelID] != nil,
                          planIDByPanelID[panelID] == nil else { continue }
                    planIDByPanelID[panelID] = mintId()
                }
            case .split(let split):
                reservePlanIDs(in: split.first)
                reservePlanIDs(in: split.second)
            }
        }

        mutating func walk(_ node: ExternalTreeNode) -> LayoutTreeSpec {
            switch node {
            case .pane(let paneNode):
                return .pane(walkPane(paneNode))
            case .split(let splitNode):
                let orientation: LayoutTreeSpec.SplitSpec.Orientation =
                    splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal
                return .split(LayoutTreeSpec.SplitSpec(
                    orientation: orientation,
                    dividerPosition: splitNode.dividerPosition,
                    first: walk(splitNode.first),
                    second: walk(splitNode.second)
                ))
            }
        }

        private mutating func walkPane(_ pane: ExternalPaneNode) -> LayoutTreeSpec.PaneSpec {
            // Resolve the live bonsplit PaneID for this node so we can read
            // pane metadata. `treeSnapshot` pane ids are string forms of a
            // UUID; we match by uuidString against `allPaneIds`.
            let paneID = resolvePaneID(for: pane.id)

            // Read pane metadata once per pane and attach it to the FIRST
            // surface in the pane. The executor's step 7 writes paneMetadata
            // through `PaneMetadataStore` keyed by the surface's pane — one
            // write per pane is sufficient for a faithful round-trip.
            let paneLevelMetadata = paneMetadata(for: paneID)

            var ids: [String] = []
            var selectedIndex: Int? = nil
            for tab in pane.tabs {
                guard let panelId = panelID(forTabIDString: tab.id),
                      let panel = workspace.panels[panelId],
                      let planId = planIDByPanelID[panelId] else { continue }
                ids.append(planId)

                let isFirstInPane = ids.count == 1
                let kind = kind(for: panel)
                let title = workspace.panelCustomTitles[panelId]
                let metadata = strippingRedundantCanonicalFields(
                    surfaceMetadata(for: panelId),
                    title: title,
                    description: nil
                )
                let paneMetaForSurface = isFirstInPane && !paneLevelMetadata.isEmpty
                    ? paneLevelMetadata
                    : [String: PersistedJSONValue]()
                var linkedAgentSurfacePlanId: String?
                if kind == .browser,
                   let linkedAgent = companionBridge.linkedAgentForBrowser(panelId) {
                    let targetPlanID = planIDByPanelID[linkedAgent.surfaceID]
                    if let targetPlanID,
                       workspace.panels[linkedAgent.surfaceID] is TerminalPanel,
                       AgentIdentityPolicy.isAgentKind(
                           companionBridge.declaredAgentKindForTerminal(linkedAgent.surfaceID)
                       ) {
                        linkedAgentSurfacePlanId = targetPlanID
                    } else {
                        // Never serialize a stale UUID into a portable plan.
                        // Omit the link and make the data loss machine-visible.
                        warnings.append(CompanionPlanDiagnostic(
                            code: .orphanOmitted,
                            severity: .warning,
                            sourcePlanID: planId,
                            targetPlanID: targetPlanID
                        ))
                    }
                }
                let declaredAgentKind = companionBridge
                    .declaredAgentKindForTerminal(panelId)
                    .flatMap { kind == .terminal && AgentIdentityPolicy.isAgentKind($0)
                        ? AgentIdentityPolicy.normalizedKind($0)
                        : nil
                    }
                let surface = SurfaceSpec(
                    id: planId,
                    kind: kind,
                    title: title,
                    description: nil,   // description flows via metadata; no separate setter
                    workingDirectory: workingDirectory(for: panel),
                    command: nil,       // executor synthesises via registry at restore
                    url: url(for: panel),
                    filePath: filePath(for: panel),
                    metadata: metadata.isEmpty ? nil : metadata,
                    paneMetadata: paneMetaForSurface.isEmpty ? nil : paneMetaForSurface,
                    linkedAgentSurfacePlanId: linkedAgentSurfacePlanId,
                    declaredAgentKind: declaredAgentKind
                )
                surfaces.append(surface)

                if let selectedTabId = pane.selectedTabId, selectedTabId == tab.id {
                    selectedIndex = ids.count - 1
                }
            }
            return LayoutTreeSpec.PaneSpec(
                surfaceIds: ids,
                selectedIndex: selectedIndex
            )
        }

        private mutating func mintId() -> String {
            defer { nextIdCounter += 1 }
            return "s\(nextIdCounter)"
        }

        // MARK: Kind + panel accessors

        private func kind(for panel: any Panel) -> SurfaceSpecKind {
            switch panel.panelType {
            case .terminal: return .terminal
            case .browser:  return .browser
            case .markdown: return .markdown
            }
        }

        private func workingDirectory(for panel: any Panel) -> String? {
            guard let terminal = panel as? TerminalPanel else { return nil }
            let requested = terminal.requestedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (requested?.isEmpty == false) ? requested : nil
        }

        private func url(for panel: any Panel) -> String? {
            guard let browser = panel as? BrowserPanel else { return nil }
            return browser.currentURL?.absoluteString
        }

        private func filePath(for panel: any Panel) -> String? {
            guard let markdown = panel as? MarkdownPanel else { return nil }
            return markdown.filePath
        }

        // MARK: Metadata reads

        /// Drop `metadata["title"]` / `metadata["description"]` when their
        /// values match the canonical SurfaceSpec fields the executor will
        /// write through dedicated setters. Without this, every clean
        /// round-trip through capture → restore re-emits the dup and the
        /// executor fires a `metadata_override` warning even though the
        /// values agree (CMUX-37 workstream 3, capture-side fix).
        ///
        /// Strip only on exact value match: a divergent metadata value
        /// (operator wrote `set-metadata --key title --value "Foo"` separate
        /// from `set-title "Bar"`) is a real conflict and still warrants the
        /// override warning.
        private func strippingRedundantCanonicalFields(
            _ metadata: [String: PersistedJSONValue],
            title: String?,
            description: String?
        ) -> [String: PersistedJSONValue] {
            var result = metadata
            if let title,
               case .string(let metaTitle) = result["title"],
               metaTitle == title {
                result.removeValue(forKey: "title")
            }
            if let description,
               case .string(let metaDesc) = result["description"],
               metaDesc == description {
                result.removeValue(forKey: "description")
            }
            return result
        }

        private func surfaceMetadata(for panelId: UUID) -> [String: PersistedJSONValue] {
            let snapshot = SurfaceMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                surfaceId: panelId
            )
            guard !snapshot.metadata.isEmpty else { return [:] }
            return PersistedMetadataBridge.encodeValues(
                snapshot.metadata,
                surfaceIdForLog: panelId,
                sources: snapshot.sources
            )
        }

        private func paneMetadata(for paneID: PaneID?) -> [String: PersistedJSONValue] {
            guard let paneID else { return [:] }
            let snapshot = PaneMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                paneId: paneID.id
            )
            guard !snapshot.metadata.isEmpty else { return [:] }
            return PersistedMetadataBridge.encodeValues(
                snapshot.metadata,
                surfaceIdForLog: paneID.id,
                sources: snapshot.sources
            )
        }

        // MARK: Pane / tab lookup

        private func resolvePaneID(for paneIDString: String) -> PaneID? {
            guard let uuid = UUID(uuidString: paneIDString) else { return nil }
            return workspace.bonsplitController.allPaneIds.first { $0.id == uuid }
        }

        private func panelID(forTabIDString tabIDString: String) -> UUID? {
            guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
            return workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID))
        }
    }
}
