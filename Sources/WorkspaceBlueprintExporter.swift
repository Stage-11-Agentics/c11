import Foundation
import AppKit

/// Converts a live workspace into a `WorkspaceBlueprintFile`.
///
/// Delegates the walk to `WorkspacePlanCapture.capture(workspace:)` — the
/// same shared helper used by `LiveWorkspaceSnapshotSource` — so Blueprints
/// and Snapshots always serialise surface state with identical fidelity.
@MainActor
struct WorkspaceBlueprintExporter {
    let tabManager: TabManager

    /// Capture the live workspace identified by `workspaceId` and wrap it in a
    /// `WorkspaceBlueprintFile` with the given name and optional description.
    /// Returns nil if the workspace cannot be located.
    func export(
        workspaceId: UUID,
        name: String,
        description: String? = nil
    ) -> WorkspaceBlueprintFile? {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        let plan = WorkspacePlanCapture.capture(workspace: workspace)
        return WorkspaceBlueprintFile(
            version: 1,
            name: name,
            description: description,
            plan: plan
        )
    }
}
