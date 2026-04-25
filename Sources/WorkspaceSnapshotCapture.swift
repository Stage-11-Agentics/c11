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
        let plan = WorkspacePlanCapture.capture(workspace: workspace)
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
    nonisolated static func defaultVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(short)+\(build)"
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
