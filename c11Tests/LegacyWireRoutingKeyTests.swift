import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class LegacyWireRoutingKeyTests: XCTestCase {
    func testRoutingVariantsNameCanonicalSelectors() {
        let cases = [
            ("surfaceId", "tab_id"), ("tabRef", "tab_ref"),
            ("panelId", "tab_id"), ("paneId", "area_id"),
            ("workspaceId", "workspace_id"), ("windowId", "window_id"),
            ("targetSurfaceRef", "target_tab_ref"), ("sourcePaneId", "source_area_id"),
            ("focusedPanelRef", "focused_tab_ref"), ("affectedSurfaceIds", "affected_tab_ids"),
            ("tab__id", "tab_id"), ("AREA_ID", "area_id"), ("Pane", "area"),
            ("TabRefs", "tab_refs")
        ]
        for (key, canonical) in cases {
            let params = LegacyWireAliases.canonicalParams([key: "tab:1"])
            let rejection = LegacyWireAliases.unsupportedRoutingKey(params)
            XCTAssertEqual(rejection?.key, key)
            XCTAssertEqual(rejection?.canonical, canonical)
            XCTAssertEqual(rejection?.code, "invalid_params")
            XCTAssertTrue(rejection?.message.contains(key) == true)
            XCTAssertTrue(rejection?.message.contains(canonical) == true)
        }
    }

    func testCanonicalAndListedAliasesRemainAccepted() {
        for key in ["tab_id", "surface_id", "pane_id", "panel_id", "area_id", "workspace_id", "window_id",
                    "tab_ref", "panel_ref", "surface_ref", "area_ref", "pane_ref", "pane", "area",
                    "target_tab_ref", "source_pane_id", "focused_panel_ref", "tabRefs", "surfaceRefs"] {
            XCTAssertNil(LegacyWireAliases.unsupportedRoutingKey(
                LegacyWireAliases.canonicalParams([key: "tab:1"])
            ), key)
        }
        let canonicalAndAlias = LegacyWireAliases.canonicalParams(["tab_id": "tab:1", "surface_id": "tab:2"])
        XCTAssertNil(LegacyWireAliases.unsupportedRoutingKey(canonicalAndAlias))
        XCTAssertEqual(canonicalAndAlias["surface_id"] as? String, "tab:2")
        XCTAssertEqual(canonicalAndAlias["tab_id"] as? String, "tab:1")
    }

    func testNestedBlobsNonSelectorsAndCharacterTyposAreOutsideCheck() {
        XCTAssertNil(LegacyWireAliases.unsupportedRoutingKey([
            "metadata": ["surfaceId": "x"], "payload": ["tabRef": "x"],
            "plan": ["workspaceId": "x"], "title": "fixture", "text": "hello",
            "surfce_id": "tab:1", "surfaceTitle": "fixture", "tab_type": "terminal"
        ]))
    }

    func testBadKeyIsRejectedEvenAlongsideValidTarget() {
        let rejection = LegacyWireAliases.unsupportedRoutingKey(
            LegacyWireAliases.canonicalParams(["tab_id": "tab:1", "surfaceId": "tab:2"])
        )
        XCTAssertEqual(rejection?.key, "surfaceId")
        XCTAssertEqual(rejection?.canonical, "tab_id")
    }
}
