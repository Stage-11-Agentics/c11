import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class LegacyWireRoutingKeyTests: XCTestCase {
    func testRoutingVariantsNameCanonicalSelectors() {
        let cases = [
            ("surfaceId", "panel_id"), ("tabRef", "panel_ref"),
            ("panelId", "panel_id"), ("paneId", "area_id"), ("PANEL_ID", "panel_id"),
            ("workspaceId", "workspace_id"), ("windowId", "window_id"),
            ("targetSurfaceRef", "target_panel_ref"), ("sourcePaneId", "source_area_id"),
            ("focusedPanelRef", "focused_panel_ref"), ("affectedSurfaceIds", "affected_panel_ids"),
            ("callerPanelId", "caller_panel_id"), ("beforeTabId", "before_panel_id"),
            ("tab__id", "panel_id"), ("AREA_ID", "area_id"), ("Pane", "area"),
            ("TabRefs", "panel_refs")
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
        for key in ["panel_id", "tab_id", "surface_id", "pane_id", "area_id", "workspace_id", "window_id",
                    "panel_ref", "tab_ref", "surface_ref", "area_ref", "pane_ref", "pane", "area",
                    "target_panel_ref", "target_tab_ref", "source_pane_id", "focused_panel_ref",
                    "caller_panel_id", "caller_tab_id", "before_panel_id", "after_panel_id",
                    "panelRefs", "tabRefs", "surfaceRefs"] {
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
        XCTAssertEqual(rejection?.canonical, "panel_id")
    }
}

/// C11-337: the panel wire contract. Methods, refs and params accept every
/// spelling; results carry `panel_*` beside `tab_*` and `area_*` alone.
final class LegacyWireCompletionTests: XCTestCase {
    private func complete(_ value: [String: Any]) -> [String: Any] {
        LegacyWireAliases.completeResult(value) as? [String: Any] ?? [:]
    }

    func testMethodsCanonicalizeToPanel() {
        let cases = [
            ("tab.list", "panel.list"), ("surface.list", "panel.list"), ("panel.list", "panel.list"),
            ("tab.action", "panel.action"), ("surface.send_text", "panel.send_text"),
            ("tab.set_titlebar_collapsed", "panel.set_titlebar_collapsed"),
            ("area.tabs", "area.panels"), ("pane.surfaces", "area.panels"), ("area.panels", "area.panels"),
            ("pane.list", "area.list"), ("area.confirm", "area.confirm"),
            ("notification.create_for_tab", "notification.create_for_panel"),
            ("notification.create_for_surface", "notification.create_for_panel"),
            ("browser.tab.list", "browser.panel.list"), ("browser.panel.new", "browser.panel.new"),
            ("debug.tab_snapshot", "debug.panel_snapshot"),
            ("debug.tab_snapshot.reset", "debug.panel_snapshot.reset"),
            ("debug.panel_snapshot", "debug.panel_snapshot"),
            ("debug.command_palette.rename_tab.open", "debug.command_palette.rename_panel.open"),
            ("debug.tab_sheet.detail", "debug.panel_sheet.detail"),
            ("debug.tab_rail.open", "debug.panel_rail.open"),
            ("debug.tab_strip.scroll", "debug.panel_strip.scroll"),
            // "panel" here is the Empty Area view, never the c11 leaf.
            ("debug.empty_panel.count", "debug.empty_area.count"),
            ("workspace.list", "workspace.list"), ("system.capabilities", "system.capabilities"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(LegacyWireAliases.canonicalMethod(input), expected, input)
        }
    }

    func testHandlesCanonicalizeToPanel() {
        XCTAssertEqual(LegacyWireAliases.canonicalHandle("tab:3"), "panel:3")
        XCTAssertEqual(LegacyWireAliases.canonicalHandle("surface:3"), "panel:3")
        XCTAssertEqual(LegacyWireAliases.canonicalHandle(" TAB:3 "), "panel:3")
        XCTAssertEqual(LegacyWireAliases.canonicalHandle("Panel:3"), "panel:3")
        XCTAssertEqual(LegacyWireAliases.canonicalHandle("pane:2"), "area:2")
        XCTAssertEqual(LegacyWireAliases.canonicalHandle("workspace:1"), "workspace:1")
        XCTAssertEqual(LegacyWireAliases.legacyHandle("panel:3"), "tab:3")
        XCTAssertEqual(LegacyWireAliases.legacyHandle("surface:3"), "tab:3")
        XCTAssertEqual(LegacyWireAliases.legacyHandle("area:2"), "area:2")
    }

    func testEveryPanelPairEmitsPanelAndTabButNotSurface() {
        let panelPairs = LegacyWireAliases.legacyKeyPairs.filter(\.emitOld)
        XCTAssertEqual(panelPairs.count, 37)
        for pair in panelPairs {
            XCTAssertTrue(pair.new.lowercased().contains("panel"), pair.new)
            XCTAssertTrue(pair.old.lowercased().contains("tab"), pair.old)
            // The legacy surface spelling, given alone, completes to both
            // emitted spellings and is itself dropped.
            for input in [pair.old] + pair.extraOld {
                let value: Any = pair.isRef ? "surface:4" : "fixture"
                let out = complete([input: value])
                XCTAssertNotNil(out[pair.new], "\(input) -> \(pair.new)")
                XCTAssertNotNil(out[pair.old], "\(input) -> \(pair.old)")
                for extra in pair.extraOld {
                    XCTAssertNil(out[extra], "\(extra) must not be emitted")
                }
                if pair.isRef {
                    XCTAssertEqual(out[pair.new] as? String, "panel:4", pair.new)
                    XCTAssertEqual(out[pair.old] as? String, "tab:4", pair.old)
                }
            }
        }
    }

    func testEveryAreaPairEmitsAreaOnly() {
        let areaPairs = LegacyWireAliases.legacyKeyPairs.filter { !$0.emitOld }
        XCTAssertEqual(areaPairs.count, 10)
        for pair in areaPairs {
            XCTAssertTrue(pair.old.lowercased().contains("pane"), pair.old)
            let out = complete([pair.old: pair.isRef ? "pane:2" : "fixture"])
            XCTAssertNotNil(out[pair.new], pair.new)
            XCTAssertNil(out[pair.old], "\(pair.old) must not be emitted")
            if pair.isRef { XCTAssertEqual(out[pair.new] as? String, "area:2") }
        }
    }

    func testHandlerResultCompletesNestedAndArrays() {
        let out = complete([
            "surface_id": "fixture-uuid",
            "surface_ref": "panel:7",
            "pane_ref": "area:3",
            "tabs": [["surface_ref": "panel:8", "tab_ref": "panel:8", "surface_type": "terminal"]],
            "surface_refs": ["panel:1", "panel:2"],
        ])
        XCTAssertEqual(out["panel_id"] as? String, "fixture-uuid")
        XCTAssertEqual(out["tab_id"] as? String, "fixture-uuid")
        XCTAssertEqual(out["panel_ref"] as? String, "panel:7")
        XCTAssertEqual(out["tab_ref"] as? String, "tab:7")
        XCTAssertEqual(out["area_ref"] as? String, "area:3")
        XCTAssertEqual(out["panel_refs"] as? [String], ["panel:1", "panel:2"])
        XCTAssertEqual(out["tab_refs"] as? [String], ["tab:1", "tab:2"])
        for gone in ["surface_id", "surface_ref", "pane_ref", "surface_refs"] {
            XCTAssertNil(out[gone], gone)
        }
        let item = (out["tabs"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(item["panel_ref"] as? String, "panel:8")
        XCTAssertEqual(item["tab_ref"] as? String, "tab:8")
        XCTAssertEqual(item["panel_type"] as? String, "terminal")
        XCTAssertEqual(item["tab_type"] as? String, "terminal")
        XCTAssertNil(item["surface_ref"])
        XCTAssertNil(item["surface_type"])
    }

    func testCanonicalValueWinsAndNullsPass() {
        let out = complete(["panel_id": "a", "tab_id": "b", "selected_surface_ref": NSNull()])
        XCTAssertEqual(out["panel_id"] as? String, "a")
        XCTAssertEqual(out["tab_id"] as? String, "b")
        XCTAssertTrue(out["selected_panel_ref"] is NSNull)
        XCTAssertTrue(out["selected_tab_ref"] is NSNull)
    }

    func testCamelCaseApplyMapsAndInvertedTerminalPair() {
        let out = complete([
            "surfaceRefs": ["plan-a": "panel:5"],
            "paneRefs": ["plan-b": "area:6"],
            "terminal_tabs": 2,
        ])
        XCTAssertEqual(out["panelRefs"] as? [String: String], ["plan-a": "panel:5"])
        XCTAssertEqual(out["tabRefs"] as? [String: String], ["plan-a": "tab:5"])
        XCTAssertEqual(out["areaRefs"] as? [String: String], ["plan-b": "area:6"])
        XCTAssertNil(out["surfaceRefs"])
        XCTAssertNil(out["paneRefs"])
        XCTAssertEqual(out["terminal_panels"] as? Int, 2)
        XCTAssertEqual(out["terminal_tabs"] as? Int, 2)
    }

    func testOpaqueSubtreesAreUntouched() {
        let out = complete(["metadata": ["surface_id": "user-data"], "value": ["pane_ref": "x"]])
        XCTAssertEqual((out["metadata"] as? [String: Any])?["surface_id"] as? String, "user-data")
        XCTAssertNil((out["metadata"] as? [String: Any])?["panel_id"])
        XCTAssertEqual((out["value"] as? [String: Any])?["pane_ref"] as? String, "x")
    }

    func testParamsResolveEverySpellingOntoHandlerKeys() {
        for key in ["panel_id", "panel_ref", "tab_id", "tab_ref", "surface_ref"] {
            let params = LegacyWireAliases.canonicalParams([key: "panel:3"])
            XCTAssertEqual(params["surface_id"] as? String, "panel:3", key)
        }
        let params = LegacyWireAliases.canonicalParams([
            "target_panel_id": "t", "source_panel_ref": "s", "before_panel_id": "b",
            "after_panel_id": "a", "caller_panel_id": "c", "area_id": "r",
        ])
        XCTAssertEqual(params["target_surface_id"] as? String, "t")
        XCTAssertEqual(params["source_surface_id"] as? String, "s")
        XCTAssertEqual(params["before_surface_id"] as? String, "b")
        XCTAssertEqual(params["after_surface_id"] as? String, "a")
        XCTAssertEqual(params["caller_surface_id"] as? String, "c")
        XCTAssertEqual(params["pane_id"] as? String, "r")
        // `tab_id` is not back-filled: browser panel switch/close read it as an
        // explicit target ahead of `index`, so the context panel must not leak in.
        XCTAssertNil(LegacyWireAliases.canonicalParams(["surface_id": "ctx", "index": 2])["tab_id"])
    }

    func testOldSpellingRequestsGetGenericRefsInTheirSpelling() throws {
        XCTAssertEqual(LegacyWireAliases.legacyRefPrefix(forRawMethod: "tab.list"), "tab:")
        XCTAssertEqual(LegacyWireAliases.legacyRefPrefix(forRawMethod: "area.tabs"), "tab:")
        XCTAssertEqual(LegacyWireAliases.legacyRefPrefix(forRawMethod: "surface.list"), "surface:")
        XCTAssertNil(LegacyWireAliases.legacyRefPrefix(forRawMethod: "panel.list"))
        XCTAssertNil(LegacyWireAliases.legacyRefPrefix(forRawMethod: "system.tree"))
        // system.tree / system.identify kept their names: a v0.67 CLI shows in its caller block.
        XCTAssertEqual(LegacyWireAliases.legacyRefPrefix(
            forRawMethod: "system.tree", params: ["caller": ["workspace_id": "w", "tab_id": "t"]]), "tab:")
        XCTAssertEqual(LegacyWireAliases.legacyRefPrefix(
            forRawMethod: "system.identify", params: ["caller": ["surface_id": "t"]]), "surface:")
        XCTAssertNil(LegacyWireAliases.legacyRefPrefix(
            forRawMethod: "system.tree", params: ["caller": ["panel_id": "t", "tab_id": "t"]]))
        XCTAssertNil(LegacyWireAliases.legacyRefPrefix(
            forRawMethod: "workspace.list", params: ["caller": ["tab_id": "t"]]))

        let response = #"{"id":7,"ok":true,"result":{"panels":[{"ref":"panel:3","panel_ref":"panel:3","tab_ref":"tab:3"}],"workspace_ref":"workspace:1","metadata":{"ref":"panel:9"}}}"#
        let echoed = LegacyWireAliases.echoLegacyRefs(response, prefix: "tab:")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(echoed.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 7)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let row = try XCTUnwrap((result["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["ref"] as? String, "tab:3")
        XCTAssertEqual(row["panel_ref"] as? String, "panel:3", "paired keys keep their own spelling")
        XCTAssertEqual(row["tab_ref"] as? String, "tab:3")
        XCTAssertEqual(result["workspace_ref"] as? String, "workspace:1")
        XCTAssertEqual((result["metadata"] as? [String: Any])?["ref"] as? String, "panel:9", "user data is untouched")
        // Errors and responses with nothing to echo pass through byte-for-byte.
        let error = #"{"id":1,"ok":false,"error":{"code":"not_found","message":"Panel not found"}}"#
        XCTAssertEqual(LegacyWireAliases.echoLegacyRefs(error, prefix: "tab:"), error)
    }

    func testCapabilityFeatureIdsSayPanel() {
        let ids = Set(CapabilityFeatures.current.payload.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("vocabulary.workspace_area_panel"))
        XCTAssertTrue(ids.contains("send.explicit_panel"))
        XCTAssertFalse(ids.contains("vocabulary.workspace_area_tab"))
        XCTAssertFalse(ids.contains("send.explicit_tab"))
    }
}
