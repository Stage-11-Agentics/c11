import Foundation
import AppKit
import Bonsplit

/// Shared plan-capture logic used by both `LiveWorkspaceSnapshotSource` (Snapshots)
/// and `WorkspaceBlueprintExporter` (Blueprints). Walks AppKit / bonsplit state
/// on the main actor and returns a `WorkspaceApplyPlan` ready for serialization.
@MainActor
enum WorkspacePlanCapture {
    static func capture(workspace: Workspace) -> WorkspaceApplyPlan {
        var walker = Walker(workspace: workspace)
        let layout = walker.walk(workspace.bonsplitController.treeSnapshot())
        let spec = WorkspaceSpec(
            title: workspace.customTitle,
            customColor: workspace.customColor,
            workingDirectory: workspace.currentDirectory.isEmpty ? nil : workspace.currentDirectory,
            metadata: workspace.metadata.isEmpty ? nil : workspace.metadata
        )
        return WorkspaceApplyPlan(
            version: 1,
            workspace: spec,
            layout: layout,
            surfaces: walker.surfaces
        )
    }

    @MainActor
    private struct Walker {
        let workspace: Workspace
        var surfaces: [SurfaceSpec] = []
        private var nextIdCounter: Int = 1

        init(workspace: Workspace) {
            self.workspace = workspace
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
            for (index, tab) in pane.tabs.enumerated() {
                guard let panelId = panelID(forTabIDString: tab.id),
                      let panel = workspace.panels[panelId] else { continue }
                let planId = mintId()
                ids.append(planId)

                let isFirstInPane = ids.count == 1
                let kind = kind(for: panel)
                let title = workspace.panelCustomTitles[panelId]
                let metadata = surfaceMetadata(for: panelId)
                let paneMetaForSurface = isFirstInPane && !paneLevelMetadata.isEmpty
                    ? paneLevelMetadata
                    : [String: PersistedJSONValue]()
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
                    paneMetadata: paneMetaForSurface.isEmpty ? nil : paneMetaForSurface
                )
                surfaces.append(surface)

                if let selectedTabId = pane.selectedTabId, selectedTabId == tab.id {
                    selectedIndex = index
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

        private func surfaceMetadata(for panelId: UUID) -> [String: PersistedJSONValue] {
            let snapshot = SurfaceMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                surfaceId: panelId
            )
            guard !snapshot.metadata.isEmpty else { return [:] }
            return PersistedMetadataBridge.encodeValues(snapshot.metadata, surfaceIdForLog: panelId)
        }

        private func paneMetadata(for paneID: PaneID?) -> [String: PersistedJSONValue] {
            guard let paneID else { return [:] }
            let snapshot = PaneMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                paneId: paneID.id
            )
            guard !snapshot.metadata.isEmpty else { return [:] }
            return PersistedMetadataBridge.encodeValues(snapshot.metadata, surfaceIdForLog: paneID.id)
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
