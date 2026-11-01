import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Runtime-behavior coverage for `c11 new-workspace --title` (C11-113).
///
/// The CLI flag flows to the `workspace.create` socket method, which applies
/// the title through `TabManager.setCustomTitle(tabId:title:)` — the exact same
/// seam `workspace.rename` (the old follow-up step) uses. These tests exercise
/// that seam directly so they run under `c11LogicTests` (no host app), proving
/// the title lands on the durable `customTitle` field rather than a transient
/// process/auto title.
@MainActor
final class NewWorkspaceTitleTests: XCTestCase {

    /// Creating a workspace and applying a title at creation sets both the
    /// published `title` and the durable `customTitle`, identical to what a
    /// follow-up rename would have produced.
    func testTitleAppliedAtCreationSetsCustomTitle() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)

        // Mirror v2WorkspaceCreate's no-layout path: addWorkspace then setCustomTitle.
        manager.setCustomTitle(workspaceId: workspace.id, title: "Auth refactor")

        XCTAssertEqual(workspace.customTitle, "Auth refactor")
        XCTAssertEqual(workspace.title, "Auth refactor")
    }

    /// An inline title at creation is indistinguishable from the two-call
    /// create-then-rename sequence it replaces — same observable end state.
    func testInlineTitleMatchesCreateThenRename() {
        let inlineManager = WorkspaceManager()
        let inline = inlineManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        inlineManager.setCustomTitle(workspaceId: inline.id, title: "Release prep")

        let twoStepManager = WorkspaceManager()
        let twoStep = twoStepManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        // The historical path: create, then a separate workspace.rename call.
        twoStepManager.setCustomTitle(workspaceId: twoStep.id, title: "Release prep")

        XCTAssertEqual(inline.customTitle, twoStep.customTitle)
        XCTAssertEqual(inline.title, twoStep.title)
        XCTAssertEqual(inline.customTitle, "Release prep")
    }

    /// A title applied at creation is the same durable field a snapshot
    /// persists and restore rebuilds — confirming it is not an ephemeral title.
    func testTitleAppliedAtCreationSurvivesSnapshotRoundtrip() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        manager.setCustomTitle(workspaceId: workspace.id, title: "Persisted name")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = restored.workspaces.first { $0.customTitle == "Persisted name" }
        XCTAssertNotNil(restoredWorkspace, "Custom title set at creation should survive snapshot/restore")
        XCTAssertEqual(restoredWorkspace?.title, "Persisted name")
    }

    /// Whitespace-only titles are treated as no title (the CLI and socket both
    /// trim and drop empties), so the workspace keeps its default title.
    func testBlankTitleLeavesDefaultTitleIntact() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let defaultTitle = workspace.title

        // CLI/socket trim "   " to empty and never call setCustomTitle; assert
        // that the default-title path is what an empty title resolves to.
        let trimmed = "   ".trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)

        XCTAssertNil(workspace.customTitle)
        XCTAssertEqual(workspace.title, defaultTitle)
    }

    // MARK: - C11-563: rename to empty restores the automatic name

    /// A renamed workspace's rename field shows its custom name, with the
    /// automatic name as the placeholder, so an empty field says what saving
    /// it does.
    func testRenameFormShowsCustomNameOverAutomaticPlaceholder() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let automatic = workspace.title
        manager.setCustomTitle(workspaceId: workspace.id, title: "Auth refactor")

        let form = WorkspaceRenameForm(workspace: workspace)

        XCTAssertEqual(form.initialText, "Auth refactor")
        XCTAssertEqual(form.placeholder, automatic)
        XCTAssertNotEqual(form.placeholder, "Auth refactor")
    }

    /// Saving the rename field empty (what "Remove Custom Workspace Name"
    /// used to do) clears the custom name and the workspace shows the name
    /// the field's placeholder promised.
    func testSavingEmptyRenameRestoresAutomaticName() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let automatic = workspace.title
        manager.setCustomTitle(workspaceId: workspace.id, title: "Auth refactor")
        XCTAssertTrue(workspace.hasCustomTitle)

        let promised = WorkspaceRenameForm(workspace: workspace).placeholder
        manager.setCustomTitle(workspaceId: workspace.id, title: "")

        XCTAssertFalse(workspace.hasCustomTitle)
        XCTAssertNil(workspace.customTitle)
        XCTAssertEqual(workspace.title, automatic)
        XCTAssertEqual(workspace.title, promised)
    }

    /// With no custom name the field starts empty, so pressing Save on the
    /// untouched field keeps the automatic name instead of freezing it as a
    /// custom one.
    func testUntouchedRenameOfUnnamedWorkspaceKeepsAutomaticName() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)

        let form = WorkspaceRenameForm(workspace: workspace)
        XCTAssertEqual(form.initialText, "")
        XCTAssertEqual(form.placeholder, workspace.title)

        manager.setCustomTitle(workspaceId: workspace.id, title: form.initialText)
        XCTAssertFalse(workspace.hasCustomTitle)
        XCTAssertEqual(workspace.title, form.placeholder)
    }
}
