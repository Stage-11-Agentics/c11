import Foundation
import AppKit
import Bonsplit

/// Protocol seam for `c11 snapshot`. Production code uses
/// `LiveWorkspaceSnapshotSource`, which walks `TabManager` / `Workspace` /
/// `SurfaceMetadataStore` / `PaneMetadataStore` on the main actor. Tests
/// supply a `FakeWorkspaceSnapshotSource` (see `WorkspaceSnapshotCaptureTests`)
/// that returns a canned envelope so the store + CLI boundaries can be
/// exercised without AppKit. Same pattern Phase 0 used for
/// `WorkspaceLayoutExecutorDependencies`.
@MainActor
protocol WorkspaceSnapshotSource {
    /// Capture the live workspace identified by `workspaceId`. Returns `nil`
    /// if the workspace cannot be located. Origin lets the caller tag
    /// `manual` vs `auto-restart`; Phase 1 currently always supplies
    /// `.manual`, but the seam is ready for Phase 3's restart-loop driver.
    func capture(
        workspaceId: UUID,
        origin: WorkspaceSnapshotFile.Origin,
        clock: () -> Date
    ) -> WorkspaceSnapshotFile?
}

/// Production capture. Runs on the main actor because AppKit / bonsplit /
/// the metadata stores expect it. The walk is O(surfaces) + O(panes²) (the
/// second term from an `allPaneIds` linear scan per tree node, which is
/// negligible at the single-digit pane counts c11 sees in the field).
///
/// Invariants the walker honours, enforced by `WorkspaceSnapshotCaptureTests`:
/// - Surface `title` is the exact `panelCustomTitles[panelId]` at capture
///   time (falls back to the live `displayTitle` when the operator has
///   never set a custom title).
/// - `mailbox.*` pane-metadata keys copy through unmodified. The walker
///   does not read-through, decode, or rewrite keys or values.
/// - `claude.session_id` lives on *surface* metadata, not pane. Surface
///   metadata carries the full string-valued map as-is; non-string values
///   serialise through `PersistedMetadataBridge.encodeValues`.
/// - `SurfaceSpec.id` is re-minted at capture time (`"s1"`, `"s2"`, …) and
///   exists only within a single snapshot file's lifetime; live refs are
///   never persisted.
@MainActor
struct LiveWorkspaceSnapshotSource: WorkspaceSnapshotSource {
    let tabManager: TabManager
    let c11Version: String

    init(tabManager: TabManager, c11Version: String = LiveWorkspaceSnapshotSource.defaultVersionString()) {
        self.tabManager = tabManager
        self.c11Version = c11Version
    }

    func capture(
        workspaceId: UUID,
        origin: WorkspaceSnapshotFile.Origin,
        clock: () -> Date = { Date() }
    ) -> WorkspaceSnapshotFile? {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        let plan = capturePlan(workspace: workspace)
        return WorkspaceSnapshotFile(
            version: 1,
            snapshotId: WorkspaceSnapshotID.generate(now: clock()),
            createdAt: clock(),
            c11Version: c11Version,
            origin: origin,
            plan: plan
        )
    }

    /// Default bundle version + build number, e.g. `"0.01.123+42"`. Lives on
    /// the type so tests can inject a deterministic string.
    static func defaultVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(short)+\(build)"
    }

    // MARK: - Walker

    private func capturePlan(workspace: Workspace) -> WorkspaceApplyPlan {
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

    /// Stateful walker threaded through the tree-snapshot recursion. Owns
    /// the plan-local id counter and the accumulated `SurfaceSpec` list.
    /// All heavy lifting (metadata reads, kind resolution, title lookup)
    /// happens here so the plan shape above stays a flat list + tree.
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

                // Mark selected tab by index.
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

        /// Read the full surface metadata map through `SurfaceMetadataStore`,
        /// then bridge through `PersistedMetadataBridge.encodeValues` so the
        /// `[String: Any]` output lands as `[String: PersistedJSONValue]`
        /// matching the plan schema. Reserved keys (`title`, `description`,
        /// `status`, etc.) flow through unchanged — capture doesn't know or
        /// care about the reserved set.
        private func surfaceMetadata(for panelId: UUID) -> [String: PersistedJSONValue] {
            let snapshot = SurfaceMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                surfaceId: panelId
            )
            guard !snapshot.metadata.isEmpty else { return [:] }
            return PersistedMetadataBridge.encodeValues(snapshot.metadata, surfaceIdForLog: panelId)
        }

        /// Read the full pane-metadata map through `PaneMetadataStore`.
        /// Keys are preserved verbatim — mailbox.* addressing depends on
        /// byte-for-byte fidelity.
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

        /// Map a treeSnapshot `pane.id` (String form of a UUID) to the live
        /// `PaneID`. Linear in `allPaneIds` count; panes are single-digit.
        private func resolvePaneID(for paneIDString: String) -> PaneID? {
            guard let uuid = UUID(uuidString: paneIDString) else { return nil }
            return workspace.bonsplitController.allPaneIds.first { $0.id == uuid }
        }

        /// Map a treeSnapshot tab id (String form of a UUID) to the panel
        /// UUID. Mirrors the private `Workspace.sessionPanelID` lookup.
        private func panelID(forTabIDString tabIDString: String) -> UUID? {
            guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
            return workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID))
        }
    }
}

/// Test fake. Returns whatever the test hands it without touching AppKit or
/// the stores. Reused by `WorkspaceSnapshotCaptureTests` and the store
/// round-trip tests.
@MainActor
struct FakeWorkspaceSnapshotSource: WorkspaceSnapshotSource {
    let canned: WorkspaceSnapshotFile?

    func capture(
        workspaceId: UUID,
        origin: WorkspaceSnapshotFile.Origin,
        clock: () -> Date = { Date() }
    ) -> WorkspaceSnapshotFile? {
        canned
    }
}
