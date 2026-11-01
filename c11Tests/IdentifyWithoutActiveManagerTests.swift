import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-537: `system.identify` returns a caller panel that
/// `workspaceContainingPanel` can locate even when no active workspace
/// manager exists. On main, before the fix, the locatable-caller case
/// fails because `caller` is null.
@MainActor
final class IdentifyWithoutActiveManagerTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let app: AppDelegate
        let manager: WorkspaceManager
        let window: NSWindow
        let workspace: Workspace
        let panelId: UUID
        let controller: TerminalController
        let previousDelegate: AppDelegate?

        func identify(caller: [String: Any]) throws -> [String: Any] {
            let response = controller.v2DispatchSystem(
                "system.identify",
                id: 537,
                params: ["caller": caller]
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                response
            )
            XCTAssertEqual(object["ok"] as? Bool, true, response)
            return try XCTUnwrap(object["result"] as? [String: Any], response)
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) throws -> Void) throws {
        _ = NSApplication.shared
        let previousDelegate = AppDelegate.shared
        let app = AppDelegate()
        // registerMainWindow autosaves. Skip that write for this process.
        app.resignSnapshotWriterOverrideForTesting = {}
        defer { AppDelegate.shared = previousDelegate }

        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer {
            app.debugUnregisterMainWindow(window)
            window.close()
        }
        app.registerMainWindow(
            window,
            windowId: windowId,
            workspaceManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        let controller = TerminalController.makeForTesting()
        XCTAssertNil(controller.workspaceManager)
        try body(Fixture(
            app: app,
            manager: manager,
            window: window,
            workspace: workspace,
            panelId: panelId,
            controller: controller,
            previousDelegate: previousDelegate
        ))
    }

    func testLocatedCallerWhenNoActiveManager() throws {
        try withFixture { fixture in
            for hint in [UUID().uuidString, nil] {
                var caller = ["panel_id": fixture.panelId.uuidString]
                if let hint { caller["workspace_id"] = hint }
                let result = try fixture.identify(caller: caller)
                let resolved = try XCTUnwrap(
                    result["caller"] as? [String: Any],
                    "hint \(String(describing: hint)) caller was \(String(describing: result["caller"]))"
                )
                XCTAssertEqual(resolved["workspace_id"] as? String, fixture.workspace.id.uuidString)
                XCTAssertEqual(resolved["panel_id"] as? String, fixture.panelId.uuidString)
                XCTAssertTrue(result["focused"] is NSNull, "\(result)")
            }
        }
    }

    func testUnlocatableCallerStaysNullWhenNoActiveManager() throws {
        try withFixture { fixture in
            let unknownPanel = UUID().uuidString
            let cases: [[String: Any]] = [
                ["panel_id": unknownPanel],
                ["panel_id": unknownPanel, "workspace_id": fixture.workspace.id.uuidString],
                [:],
            ]
            for caller in cases {
                let result = try fixture.identify(caller: caller)
                XCTAssertTrue(result["caller"] is NSNull, "\(caller) -> \(result)")
                XCTAssertTrue(result["focused"] is NSNull, "\(caller) -> \(result)")
            }
        }
    }

    func testActiveManagerKeepsFocusedWorkspaceAndHintOnlyCaller() throws {
        try withFixture { fixture in
            fixture.controller.workspaceManager = fixture.manager
            let located = try fixture.identify(caller: ["panel_id": fixture.panelId.uuidString])
            let locatedCaller = try XCTUnwrap(located["caller"] as? [String: Any], "\(located)")
            let focused = try XCTUnwrap(located["focused"] as? [String: Any], "\(located)")
            XCTAssertEqual(locatedCaller["workspace_id"] as? String, fixture.workspace.id.uuidString)
            XCTAssertEqual(locatedCaller["panel_id"] as? String, fixture.panelId.uuidString)
            XCTAssertEqual(focused["workspace_id"] as? String, fixture.workspace.id.uuidString)

            let hinted = try fixture.identify(caller: [
                "panel_id": UUID().uuidString,
                "workspace_id": fixture.workspace.id.uuidString,
            ])
            let hintedCaller = try XCTUnwrap(hinted["caller"] as? [String: Any], "\(hinted)")
            XCTAssertEqual(hintedCaller["workspace_id"] as? String, fixture.workspace.id.uuidString)
            XCTAssertTrue(hintedCaller["panel_id"] is NSNull, "\(hinted)")
            XCTAssertEqual(
                (hinted["focused"] as? [String: Any])?["workspace_id"] as? String,
                fixture.workspace.id.uuidString
            )
        }
    }
}
