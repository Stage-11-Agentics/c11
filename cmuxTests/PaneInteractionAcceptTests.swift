import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for `TabManager.acceptActivePaneInteractionInKeyWorkspace` —
/// the Cmd+D dispatcher's accept path (plan §4.8).
@MainActor
final class PaneInteractionAcceptTests: XCTestCase {

    // MARK: - Important #2: selected-tab preference (hidden-tab safety)

    func testAcceptActiveRejectsDialogOnHiddenTab() {
        // Trident Important #2: `tabs(inPane:)` returns every tab in a pane,
        // selected or not. A dialog presented on a tab the user had focused —
        // and then switched away from — stays anchored on its (now hidden)
        // panel. The old iteration walked all tabs and accepted whichever
        // active interaction came first. If the hidden dialog was
        // destructive (e.g. "close without saving"), Cmd+D silently caused
        // data loss.
        //
        // Fix: prefer `selectedTab(inPane:)` in the iteration — the hidden
        // tab's dialog must not be accepted by Cmd+D on the active tab.
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let firstPanelId = workspace.focusedPanelId,
              let firstSurfaceId = workspace.surfaceIdFromPanelId(firstPanelId) else {
            XCTFail("Expected initial workspace with a focused panel")
            return
        }

        // Add a second terminal tab in the same pane. createReplacementTerminalPanel
        // creates the TerminalPanel + registers the surface-id → panel-id mapping
        // + adds a bonsplit tab via `createTab` (which uses focusedPaneId →
        // same pane as the first tab).
        let secondPanel = workspace.createReplacementTerminalPanel()
        guard let secondSurfaceId = workspace.surfaceIdFromPanelId(secondPanel.id) else {
            XCTFail("Expected surface ID for second panel")
            return
        }

        // Verify both tabs sit in a single pane.
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1,
                       "Both tabs should share the same pane")
        guard let paneId = workspace.bonsplitController.allPaneIds.first else {
            XCTFail("Expected one pane")
            return
        }
        let tabIds = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        XCTAssertEqual(Set(tabIds), Set([firstSurfaceId, secondSurfaceId]),
                       "Pane must host both surface tabs")

        // Explicitly select the FIRST tab so the second is hidden. Also
        // ensure focusedPanelId is the first panel (no dialog on it).
        workspace.bonsplitController.selectTab(firstSurfaceId)
        workspace.focusPanel(firstPanelId)
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)
        XCTAssertEqual(workspace.bonsplitController.selectedTab(inPane: paneId)?.id,
                       firstSurfaceId,
                       "First tab must be the pane's selected tab")

        // Present a destructive-looking confirm on the hidden (second) panel.
        var hiddenResult: ConfirmResult?
        let hiddenContent = ConfirmContent(
            title: "Close?", message: nil,
            confirmLabel: "Close", cancelLabel: "Cancel",
            role: .destructive, source: .local,
            completion: { hiddenResult = $0 }
        )
        workspace.paneInteractionRuntime.present(
            panelId: secondPanel.id,
            interaction: .confirm(hiddenContent)
        )

        // No dialog on the first (visible) panel.
        XCTAssertFalse(workspace.paneInteractionRuntime.hasActive(panelId: firstPanelId))
        XCTAssertTrue(workspace.paneInteractionRuntime.hasActive(panelId: secondPanel.id))

        // Cmd+D must refuse to accept the hidden-tab dialog.
        let accepted = manager.acceptActivePaneInteractionInKeyWorkspace()

        XCTAssertFalse(accepted,
                       "Cmd+D must not silently accept a dialog on a non-selected tab.")
        XCTAssertNil(hiddenResult,
                     "Hidden dialog's completion must not fire — it stays anchored "
                     + "until the user explicitly surfaces the tab.")
        XCTAssertTrue(
            workspace.paneInteractionRuntime.hasActive(panelId: secondPanel.id),
            "Hidden dialog must remain active — not resolved, not cancelled."
        )
    }

    // MARK: - T3: Workspace teardown integration

    func testWorkspaceTeardownAllPanelsDismissesActiveInteraction() {
        // T3 (Trident consensus): `Workspace.teardownAllPanels()` is the
        // workspace-close path and must deliver `.dismissed` to every
        // in-flight pane interaction's completion before freeing the
        // panels. Without this, continuations awaiting the runtime hang
        // indefinitely. Locks down R3 behavior at the Workspace boundary,
        // not just the runtime boundary.
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial workspace with a focused panel")
            return
        }

        // Present one confirm + one textInput + one queued confirm across
        // two panels to exercise both the active and queued dismissal paths.
        let secondPanel = workspace.createReplacementTerminalPanel()

        var firstActive: ConfirmResult?
        var firstQueued: ConfirmResult?
        var secondActive: TextInputResult?

        workspace.paneInteractionRuntime.present(
            panelId: firstPanelId,
            interaction: .confirm(ConfirmContent(
                title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
                role: .standard, source: .local,
                completion: { firstActive = $0 }
            ))
        )
        workspace.paneInteractionRuntime.present(
            panelId: firstPanelId,
            interaction: .confirm(ConfirmContent(
                title: "Q", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
                role: .standard, source: .local,
                completion: { firstQueued = $0 }
            ))
        )
        workspace.paneInteractionRuntime.present(
            panelId: secondPanel.id,
            interaction: .textInput(TextInputContent(
                title: "Rename", message: nil, placeholder: nil,
                defaultValue: "",
                confirmLabel: "OK", cancelLabel: "Cancel",
                validate: { _ in nil },
                source: .local,
                completion: { secondActive = $0 }
            ))
        )

        XCTAssertTrue(workspace.paneInteractionRuntime.hasAnyActive)

        workspace.teardownAllPanels()

        XCTAssertEqual(firstActive, .dismissed,
                       "Active interaction on panel 1 must be dismissed by teardown")
        XCTAssertEqual(firstQueued, .dismissed,
                       "Queued interaction on panel 1 must be dismissed by teardown")
        XCTAssertEqual(secondActive, .dismissed,
                       "Active interaction on panel 2 must be dismissed by teardown")
        XCTAssertFalse(
            workspace.paneInteractionRuntime.hasAnyActive,
            "Runtime must be empty post-teardown"
        )
    }

    func testAcceptActiveOnVisibleTabStillWorks() {
        // Sanity: the happy path — dialog on the currently selected tab —
        // still accepts. Locks in that the selected-tab preference fix
        // doesn't also break the common case.
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial workspace with a focused panel")
            return
        }

        var result: ConfirmResult?
        let content = ConfirmContent(
            title: "Close?", message: nil,
            confirmLabel: "Close", cancelLabel: "Cancel",
            role: .destructive, source: .local,
            completion: { result = $0 }
        )
        workspace.paneInteractionRuntime.present(
            panelId: firstPanelId,
            interaction: .confirm(content)
        )

        let accepted = manager.acceptActivePaneInteractionInKeyWorkspace()
        XCTAssertTrue(accepted)
        XCTAssertEqual(result, .confirmed,
                       "Dialog on the focused panel must still accept on Cmd+D")
    }
}
