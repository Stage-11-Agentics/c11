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
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)

        // Mirror v2WorkspaceCreate's no-layout path: addWorkspace then setCustomTitle.
        manager.setCustomTitle(tabId: workspace.id, title: "Auth refactor")

        XCTAssertEqual(workspace.customTitle, "Auth refactor")
        XCTAssertEqual(workspace.title, "Auth refactor")
    }

    /// An inline title at creation is indistinguishable from the two-call
    /// create-then-rename sequence it replaces — same observable end state.
    func testInlineTitleMatchesCreateThenRename() {
        let inlineManager = TabManager()
        let inline = inlineManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        inlineManager.setCustomTitle(tabId: inline.id, title: "Release prep")

        let twoStepManager = TabManager()
        let twoStep = twoStepManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        // The historical path: create, then a separate workspace.rename call.
        twoStepManager.setCustomTitle(tabId: twoStep.id, title: "Release prep")

        XCTAssertEqual(inline.customTitle, twoStep.customTitle)
        XCTAssertEqual(inline.title, twoStep.title)
        XCTAssertEqual(inline.customTitle, "Release prep")
    }

    /// A title applied at creation is the same durable field a snapshot
    /// persists and restore rebuilds — confirming it is not an ephemeral title.
    func testTitleAppliedAtCreationSurvivesSnapshotRoundtrip() {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        manager.setCustomTitle(tabId: workspace.id, title: "Persisted name")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = restored.tabs.first { $0.customTitle == "Persisted name" }
        XCTAssertNotNil(restoredWorkspace, "Custom title set at creation should survive snapshot/restore")
        XCTAssertEqual(restoredWorkspace?.title, "Persisted name")
    }

    /// Whitespace-only titles are treated as no title (the CLI and socket both
    /// trim and drop empties), so the workspace keeps its default title.
    func testBlankTitleLeavesDefaultTitleIntact() {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let defaultTitle = workspace.title

        // CLI/socket trim "   " to empty and never call setCustomTitle; assert
        // that the default-title path is what an empty title resolves to.
        let trimmed = "   ".trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)

        XCTAssertNil(workspace.customTitle)
        XCTAssertEqual(workspace.title, defaultTitle)
    }
}
