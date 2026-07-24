import XCTest
@testable import c11

/// C11-165 COR-1 — the *wiring* half of COR-4. The pure seam
/// (`SocketSurfaceRefValidator`) is covered in `c11LogicTests`; this
/// host-target test proves a real v2 write handler actually INVOKES that
/// seam, so a future handler that forgets the guard is caught in CI (the
/// `c11-unit` scheme runs host tests). It drives `processV2Command`
/// end-to-end (dispatch → per-domain handler → validator) — the same entry
/// the socket accept loop calls. The close/tab-action cases install a real
/// two-surface workspace and assert the resulting mutation (or lack of one),
/// covering the destructive fallback that a response-code-only test misses.
///
/// Host target (not `c11LogicTests`): `processV2Command` is a
/// `@MainActor` method on the app's `TerminalController`; per CLAUDE.md /
/// C11-105 the shared controller must not be touched from a `c11LogicTests`
/// member. This test never calls `stop()`, so it does not disturb the
/// per-PID host socket.
@MainActor
final class SocketSurfaceRefRejectionWiringTests: XCTestCase {

    private func responseObject(for json: String) -> [String: Any]? {
        let response = TerminalController.shared.processV2Command(json)
        guard let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a JSON response, got: \(response)")
            return nil
        }
        return obj
    }

    private func responseCode(for json: String) -> String {
        guard let obj = responseObject(for: json) else {
            return "<invalid-response>"
        }
        guard let error = obj["error"] as? [String: Any],
              let code = error["code"] as? String else {
            return "<no-error:\(String(describing: obj))>"
        }
        return code
    }

    private func makeTwoSurfaceFixture()
        throws -> (manager: TabManager, workspace: Workspace, focusedSurfaceId: UUID, otherSurfaceId: UUID) {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedSurfaceId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let otherSurfaceId = try XCTUnwrap(
            workspace.newTerminalSurface(inPane: paneId, focus: false)?.id
        )
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertEqual(workspace.focusedPanelId, focusedSurfaceId)
        return (manager, workspace, focusedSurfaceId, otherSurfaceId)
    }

    func testSurfaceSetMetadataRejectsEmptySurfaceRef() {
        // Valid metadata/mode/source so dispatch reaches the ref guard, then an
        // explicitly-empty surface_id → empty_ref (never the focused surface).
        let code = responseCode(for: """
        {"method":"surface.set_metadata","params":{"metadata":{"k":"v"},"surface_id":""}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "surface.set_metadata with an empty surface_id must be rejected, not defaulted to focus")
    }

    func testSurfaceSetMetadataRejectsAbsentSurfaceRef() {
        let code = responseCode(for: """
        {"method":"surface.set_metadata","params":{"metadata":{"k":"v"}}}
        """)
        XCTAssertEqual(code, "missing_ref",
                       "surface.set_metadata with no surface target must be rejected, not defaulted to focus")
    }

    func testSurfaceTriggerFlashRejectsEmptySurfaceRef() {
        let code = responseCode(for: """
        {"method":"surface.trigger_flash","params":{"surface_id":"  "}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "trigger-flash with a whitespace surface_id must be rejected")
    }

    func testPaneSetMetadataRejectsAbsentPaneRef() {
        let code = responseCode(for: """
        {"method":"pane.set_metadata","params":{"metadata":{"k":"v"}}}
        """)
        XCTAssertEqual(code, "missing_ref",
                       "pane.set_metadata with no pane target must be rejected")
    }

    func testRenameRejectsEmptyRef() {
        let code = responseCode(for: """
        {"method":"surface.action","params":{"action":"rename","title":"x","surface_id":""}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "rename with an empty surface_id must be rejected")
    }

    func testSurfaceCloseRejectsStaleNamedRefWithoutClosingFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let panelIdsBefore = Set(fixture.workspace.panels.keys)
        let code = responseCode(for: """
        {"method":"surface.close","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","surface_id":"surface:999999999"}}
        """)

        XCTAssertEqual(code, "not_found")
        XCTAssertEqual(
            Set(fixture.workspace.panels.keys),
            panelIdsBefore,
            "an unresolved named surface must not close any surface"
        )
        XCTAssertEqual(
            fixture.workspace.focusedPanelId,
            fixture.focusedSurfaceId,
            "an unresolved named surface must not change caller focus"
        )
    }

    func testSurfaceCloseRejectsEmptyNamedRefWithoutClosingFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let panelIdsBefore = Set(fixture.workspace.panels.keys)
        let code = responseCode(for: """
        {"method":"surface.close","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","surface_id":"  "}}
        """)

        XCTAssertEqual(code, "empty_ref")
        XCTAssertEqual(Set(fixture.workspace.panels.keys), panelIdsBefore)
        XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
    }

    func testSurfaceCloseRejectsCaseMismatchedLiveRefWithoutClosingFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let liveRef = controller.surfaceRefOnly(forSurfaceUUID: fixture.otherSurfaceId)
        let panelIdsBefore = Set(fixture.workspace.panels.keys)
        let code = responseCode(for: """
        {"method":"surface.close","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","surface_id":"\(liveRef.uppercased())"}}
        """)

        XCTAssertEqual(code, "not_found")
        XCTAssertEqual(Set(fixture.workspace.panels.keys), panelIdsBefore)
        XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
    }

    func testSurfaceCloseWithLiveNamedRefClosesNamedSurfaceNotFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let liveRef = controller.surfaceRefOnly(forSurfaceUUID: fixture.otherSurfaceId)
        let response = responseObject(for: """
        {"method":"surface.close","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","surface_id":"\(liveRef)"}}
        """)

        XCTAssertNil(response?["error"])
        XCTAssertNil(fixture.workspace.panels[fixture.otherSurfaceId])
        XCTAssertNotNil(
            fixture.workspace.panels[fixture.focusedSurfaceId],
            "an explicit live ref must close its named surface, not the focused surface"
        )
        XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
    }

    func testSurfaceCloseWithoutNamedRefStillClosesFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let response = responseObject(for: """
        {"method":"surface.close","params":{"workspace_id":"\(fixture.workspace.id.uuidString)"}}
        """)

        XCTAssertNil(response?["error"], "an absent surface ref must retain the focused-surface fallback")
        XCTAssertEqual(fixture.workspace.panels.count, 1)
        XCTAssertNil(
            fixture.workspace.panels[fixture.focusedSurfaceId],
            "the focused surface should close when no surface ref was named"
        )
    }

    func testTabActionWithoutExplicitPinStillUsesFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let response = responseObject(for: """
        {"method":"tab.action","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","action":"pin"}}
        """)

        XCTAssertNil(response?["error"])
        XCTAssertTrue(fixture.workspace.isPanelPinned(fixture.focusedSurfaceId))
        XCTAssertFalse(fixture.workspace.isPanelPinned(fixture.otherSurfaceId))
        XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
    }

    func testTabActionLiveSurfaceAndTabPinsMutateNamedSurfaceNotFocusedSurface() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let surfaceRef = controller.surfaceRefOnly(forSurfaceUUID: fixture.otherSurfaceId)
        let targets = [
            ("surface_id", surfaceRef),
            ("tab_id", surfaceRef.replacingOccurrences(of: "surface:", with: "tab:"))
        ]

        for (targetKey, targetRef) in targets {
            let response = responseObject(for: """
            {"method":"tab.action","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","action":"pin","\(targetKey)":"\(targetRef)"}}
            """)

            XCTAssertNil(response?["error"], "live \(targetKey) should resolve")
            XCTAssertTrue(fixture.workspace.isPanelPinned(fixture.otherSurfaceId))
            XCTAssertFalse(
                fixture.workspace.isPanelPinned(fixture.focusedSurfaceId),
                "live \(targetKey) must not fall back to the focused surface"
            )
            fixture.workspace.setPanelPinned(panelId: fixture.otherSurfaceId, pinned: false)
        }
    }

    func testTabActionRejectsInvalidExplicitPinsBeforeDestructiveAction() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let liveRef = controller.surfaceRefOnly(forSurfaceUUID: fixture.otherSurfaceId)
        let cases = [
            (targetKey: "surface_id", targetRef: "surface:999999999", expectedCode: "not_found"),
            (targetKey: "tab_id", targetRef: "tab:999999999", expectedCode: "not_found"),
            (targetKey: "surface_id", targetRef: liveRef.uppercased(), expectedCode: "not_found"),
            (targetKey: "surface_id", targetRef: " ", expectedCode: "empty_ref"),
            (targetKey: "tab_id", targetRef: " ", expectedCode: "empty_ref")
        ]
        let panelIdsBefore = Set(fixture.workspace.panels.keys)

        for testCase in cases {
            let code = responseCode(for: """
            {"method":"tab.action","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","action":"close_others","\(testCase.targetKey)":"\(testCase.targetRef)"}}
            """)

            XCTAssertEqual(code, testCase.expectedCode, "unexpected result for \(testCase.targetKey)=\(testCase.targetRef)")
            XCTAssertEqual(
                Set(fixture.workspace.panels.keys),
                panelIdsBefore,
                "a rejected \(testCase.targetKey) must not let close_others mutate the workspace"
            )
            XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
        }
    }

    func testEveryTabActionFamilyRejectsStaleExplicitPinBeforeMutation() throws {
        let controller = TerminalController.shared
        let previousManager = controller.tabManager
        let fixture = try makeTwoSurfaceFixture()
        controller.setActiveTabManager(fixture.manager)
        defer { controller.setActiveTabManager(previousManager) }

        let actions = [
            "rename", "clear_name",
            "pin", "unpin",
            "mark_read", "mark_unread",
            "reload", "duplicate",
            "new_terminal_right", "new_browser_right",
            "close_left", "close_right", "close_others"
        ]
        let panelIdsBefore = Set(fixture.workspace.panels.keys)

        for action in actions {
            let code = responseCode(for: """
            {"method":"tab.action","params":{"workspace_id":"\(fixture.workspace.id.uuidString)","action":"\(action)","title":"renamed","surface_id":"surface:999999999"}}
            """)

            XCTAssertEqual(code, "not_found", "\(action) must reject a stale explicit pin")
            XCTAssertEqual(
                Set(fixture.workspace.panels.keys),
                panelIdsBefore,
                "\(action) must not mutate surfaces after explicit-pin rejection"
            )
            XCTAssertFalse(fixture.workspace.isPanelPinned(fixture.focusedSurfaceId))
            XCTAssertFalse(fixture.workspace.isPanelPinned(fixture.otherSurfaceId))
            XCTAssertEqual(fixture.workspace.focusedPanelId, fixture.focusedSurfaceId)
        }
    }
}
