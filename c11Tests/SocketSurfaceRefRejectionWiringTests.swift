import XCTest
@testable import c11

/// C11-165 COR-1 — the *wiring* half of COR-4. The pure seam
/// (`SocketSurfaceRefValidator`) is covered in `c11LogicTests`; this
/// host-target test proves a real v2 write handler actually INVOKES that
/// seam, so a future handler that forgets the guard is caught in CI (the
/// `c11-unit` scheme runs host tests). It drives `processV2Command`
/// end-to-end (dispatch → per-domain handler → validator) — the same entry
/// the socket accept loop calls. An empty/absent `surface_id` is rejected by
/// the validator *before* any surface resolution, so no live surface is
/// required.
///
/// Host target (not `c11LogicTests`): `processV2Command` is a
/// `@MainActor` method on the app's `TerminalController`; per CLAUDE.md /
/// C11-105 the shared controller must not be touched from a `c11LogicTests`
/// member. This test never calls `stop()`, so it does not disturb the
/// per-PID host socket.
@MainActor
final class SocketSurfaceRefRejectionWiringTests: XCTestCase {

    private func responseCode(for json: String) -> String {
        let response = TerminalController.shared.processV2Command(json)
        guard let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let code = error["code"] as? String else {
            return "<no-error:\(response)>"
        }
        return code
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
}
