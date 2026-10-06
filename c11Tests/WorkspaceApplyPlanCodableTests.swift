import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Codable round-trip tests for the `WorkspaceApplyPlan` value types.
/// Phase 1 Snapshot capture and Phase 2 Blueprint parsing both serialize
/// through this schema; these tests lock the wire shape so either can land
/// without a compat layer.
final class WorkspaceApplyPlanCodableTests: XCTestCase {

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try JSONDecoder().decode(type, from: data)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encode(value)
        let decoded = try decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - WorkspaceSpec

    func testWorkspaceSpecRoundTripsFullyPopulated() throws {
        let spec = WorkspaceSpec(
            title: "Debug Auth",
            customColor: "#C0392B",
            workingDirectory: "/Users/op/repo",
            metadata: ["description": "auth module work", "icon": "shield"]
        )
        try roundTrip(spec)
    }

    func testWorkspaceSpecRoundTripsEmpty() throws {
        try roundTrip(WorkspaceSpec())
    }

    // MARK: - Area vocabulary keeps the pane wire shape

    func testAreaSpecAndPaneMetadataKeepTheirPaneWireKeys() throws {
        let layout = LayoutTreeSpec.split(LayoutTreeSpec.SplitSpec(
            orientation: .horizontal,
            dividerPosition: 0.5,
            first: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"], selectedIndex: 0)),
            second: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["b"]))
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encode(layout)) as? [String: Any])
        let split = try XCTUnwrap(object["split"] as? [String: Any])
        let first = try XCTUnwrap(split["first"] as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "pane")
        XCTAssertNotNil(first["pane"])
        XCTAssertNil(first["area"])

        // A plan written before the rename still decodes.
        let legacy = Data(#"{"type":"pane","pane":{"surfaceIds":["a"],"selectedIndex":0}}"#.utf8)
        XCTAssertEqual(try decode(LayoutTreeSpec.self, from: legacy),
                       .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"], selectedIndex: 0)))

        let panel = PanelSpec(id: "m", kind: .terminal, paneMetadata: ["k": .string("v")])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: try encode(panel)) as? [String: Any])
        XCTAssertNotNil(keys["paneMetadata"])
        XCTAssertNil(keys["areaMetadata"])
    }

    // MARK: - SurfaceSpec

    func testTabSpecTerminalRoundTrips() throws {
        let spec = PanelSpec(
            id: "main",
            kind: .terminal,
            title: "driver",
            description: "cc on auth",
            workingDirectory: "/Users/op/repo",
            command: "cc --resume abc123",
            metadata: [
                "role": .string("driver"),
                "status": .string("ready"),
                "model": .string("claude-opus-4-7")
            ],
            paneMetadata: [
                "mailbox.delivery": .string("stdin,watch"),
                "mailbox.subscribe": .string("build.*,deploy.green"),
                "mailbox.retention_days": .string("7")
            ]
        )
        try roundTrip(spec)
    }

    func testTabSpecBrowserRoundTrips() throws {
        let spec = PanelSpec(
            id: "docs",
            kind: .browser,
            title: "docs",
            url: "https://stage11.ai"
        )
        try roundTrip(spec)
    }

    func testTabSpecCompanionFieldsRoundTrip() throws {
        let browser = PanelSpec(
            id: "browser",
            kind: .browser,
            linkedAgentSurfacePlanId: "agent"
        )
        let agent = PanelSpec(
            id: "agent",
            kind: .terminal,
            declaredAgentKind: "codex"
        )
        try roundTrip(browser)
        try roundTrip(agent)
    }

    func testTabSpecDecodesPrefeatureShapeWithoutCompanionFields() throws {
        let legacyJSON = #"{"id":"t","kind":"terminal"}"#
        let decoded = try decode(PanelSpec.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.linkedAgentSurfacePlanId)
        XCTAssertNil(decoded.declaredAgentKind)
        XCTAssertFalse(decoded.submitCommand)
    }

    func testTabSpecMarkdownRoundTrips() throws {
        let spec = PanelSpec(
            id: "notes",
            kind: .markdown,
            title: "plan",
            filePath: "/Users/op/notes/plan.md"
        )
        try roundTrip(spec)
    }

    func testTabSpecPreservesMailboxStarKeysVerbatim() throws {
        // Per docs/c11-13-cmux-37-alignment.md: the mailbox.* namespace
        // round-trips without normalization. The string-value type guard
        // lives in the executor, not the Codable layer, so a non-string value
        // must still decode cleanly on the wire.
        let spec = PanelSpec(
            id: "watcher",
            kind: .terminal,
            paneMetadata: [
                "mailbox.delivery": .string("silent"),
                "mailbox.advertises": .array([.string("build.*"), .string("deploy.*")]),
                "mailbox.retention_days": .number(14)
            ]
        )
        let data = try encode(spec)
        let decoded = try decode(PanelSpec.self, from: data)
        XCTAssertEqual(decoded.paneMetadata?["mailbox.delivery"], .string("silent"))
        XCTAssertEqual(
            decoded.paneMetadata?["mailbox.advertises"],
            .array([.string("build.*"), .string("deploy.*")])
        )
        XCTAssertEqual(decoded.paneMetadata?["mailbox.retention_days"], .number(14))
    }

    // MARK: - SurfaceSpec.submitCommand (opt-in, back-compat)

    func testTabSpecSubmitCommandRoundTrips() throws {
        let spec = PanelSpec(
            id: "launcher",
            kind: .terminal,
            command: "python3 /path/position.py --watch",
            submitCommand: true
        )
        let decoded = try decode(PanelSpec.self, from: try encode(spec))
        XCTAssertTrue(decoded.submitCommand)
        XCTAssertEqual(decoded, spec)
    }

    /// An older plan/snapshot serialized before `submitCommand` existed has no
    /// such key. Swift's *synthesized* decoder would throw `keyNotFound`; the
    /// custom `init(from:)` must instead default it to `false`.
    func testTabSpecDecodesMissingSubmitCommandAsFalse() throws {
        let legacyJSON = #"{"id":"t","kind":"terminal","command":"ls"}"#
        let decoded = try decode(PanelSpec.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.submitCommand)
        XCTAssertEqual(decoded.command, "ls")
    }

    /// When `submitCommand` is `false` the encoder omits the key entirely, so
    /// serialized output for every pre-existing spec stays byte-identical.
    func testTabSpecOmitsSubmitCommandWhenFalse() throws {
        let spec = PanelSpec(id: "t", kind: .terminal, command: "ls")
        let json = String(data: try encode(spec), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("submitCommand"), "false must not serialize; got \(json)")
    }

    // MARK: - LayoutTreeSpec

    func testLayoutTreeSpecSinglePaneRoundTrips() throws {
        let tree = LayoutTreeSpec.pane(
            .init(surfaceIds: ["main"], selectedIndex: 0)
        )
        try roundTrip(tree)
    }

    func testLayoutTreeSpecNestedSplitRoundTrips() throws {
        let tree = LayoutTreeSpec.split(
            .init(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(.init(surfaceIds: ["tl"])),
                second: .split(
                    .init(
                        orientation: .vertical,
                        dividerPosition: 0.5,
                        first: .pane(.init(surfaceIds: ["tr"])),
                        second: .pane(.init(surfaceIds: ["br"], selectedIndex: 0))
                    )
                )
            )
        )
        try roundTrip(tree)
    }

    func testLayoutTreeSpecDiscriminatorIsTypeKey() throws {
        let tree = LayoutTreeSpec.pane(.init(surfaceIds: ["s"]))
        let data = try encode(tree)
        let string = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(string.contains("\"type\":\"pane\""))
    }

    func testLayoutTreeSpecRejectsUnknownType() throws {
        let bogus = Data("""
        {"type":"triple-pane","extra":{}}
        """.utf8)
        XCTAssertThrowsError(try decode(LayoutTreeSpec.self, from: bogus)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected .dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - Full plan

    func testWorkspaceApplyPlanRoundTripsMixedLayout() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(
                title: "Welcome Quad",
                workingDirectory: "/Users/op"
            ),
            layout: .split(
                .init(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .split(
                        .init(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(.init(surfaceIds: ["tl"])),
                            second: .pane(.init(surfaceIds: ["bl"]))
                        )
                    ),
                    second: .split(
                        .init(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(.init(surfaceIds: ["tr"])),
                            second: .pane(.init(surfaceIds: ["br"]))
                        )
                    )
                )
            ),
            surfaces: [
                PanelSpec(id: "tl", kind: .terminal, title: "driver", command: "c11 welcome\n"),
                PanelSpec(id: "tr", kind: .browser, title: "spike", url: "https://stage11.ai"),
                PanelSpec(id: "bl", kind: .markdown, title: "welcome", filePath: "/tmp/welcome.md"),
                PanelSpec(id: "br", kind: .terminal, title: "claude", command: "claude\n")
            ]
        )
        try roundTrip(plan)
    }

    // MARK: - ApplyOptions / ApplyResult

    func testApplyOptionsDefaultsRoundTrip() throws {
        try roundTrip(ApplyOptions())
        try roundTrip(ApplyOptions(select: false, perStepTimeoutMs: 0, autoWelcomeIfNeeded: true))
    }

    /// P3: two `ApplyOptions` with the same non-nil registry (matched by
    /// `AgentRestartRegistry.name`) must compare equal. The previous
    /// implementation treated any two non-nil registries as unequal, which
    /// prevented tests from asserting equality of options that shared a
    /// singleton.
    func testApplyOptionsEqualsTreatsSameNamedRegistryAsEqual() {
        let lhs = ApplyOptions(select: false, restartRegistry: .phase1)
        let rhs = ApplyOptions(select: false, restartRegistry: .phase1)
        XCTAssertEqual(lhs, rhs)
    }

    func testApplyOptionsEqualsTreatsDifferentNamedRegistriesAsUnequal() {
        let other = AgentRestartRegistry(name: "other", rows: [])
        let lhs = ApplyOptions(select: false, restartRegistry: .phase1)
        let rhs = ApplyOptions(select: false, restartRegistry: other)
        XCTAssertNotEqual(lhs, rhs)
    }

    func testApplyOptionsEqualsTreatsNilVsNonNilAsUnequal() {
        let lhs = ApplyOptions(select: false, restartRegistry: .phase1)
        let rhs = ApplyOptions(select: false, restartRegistry: nil)
        XCTAssertNotEqual(lhs, rhs)
        XCTAssertNotEqual(rhs, lhs)
    }

    func testApplyResultRoundTripsWithWarningsAndFailures() throws {
        let result = ApplyResult(
            workspaceRef: "workspace:1",
            surfaceRefs: ["main": "surface:1", "logs": "surface:2"],
            paneRefs: ["main": "pane:1", "logs": "pane:2"],
            timings: [
                StepTiming(step: "validate", durationMs: 0.3),
                StepTiming(step: "workspace.create", durationMs: 12.1),
                StepTiming(step: "total", durationMs: 180.5)
            ],
            warnings: ["mailbox.retention_days dropped: non-string value"],
            failures: [
                ApplyFailure(
                    code: "mailbox_non_string_value",
                    step: "metadata.pane[main].write",
                    message: "mailbox.retention_days must be a string in v1"
                )
            ],
            companionDiagnostics: [
                CompanionPlanDiagnostic(
                    code: .targetMissing,
                    severity: .error,
                    sourcePlanID: "browser",
                    targetPlanID: "agent"
                )
            ]
        )
        try roundTrip(result)
    }

    func testApplyResultDecodesLegacyShapeWithEmptyCompanionDiagnostics() throws {
        let legacyJSON = #"{"workspaceRef":"workspace:1","surfaceRefs":{},"paneRefs":{},"timings":[],"warnings":[],"failures":[]}"#
        let decoded = try decode(ApplyResult.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.companionDiagnostics.isEmpty)
    }

    // MARK: - C11-337 panel keys (legacy spellings accepted forever)

    private let legacyKeyPlanJSON = #"""
    {
      "version": 1,
      "workspace": {"title": "Fixture"},
      "layout": {
        "type": "split",
        "split": {
          "orientation": "horizontal",
          "dividerPosition": 0.5,
          "first": {"type": "pane", "pane": {"surfaceIds": ["agent"]}},
          "second": {"type": "pane", "pane": {"surfaceIds": ["docs", "notes"], "selectedIndex": 1}}
        }
      },
      "surfaces": [
        {"id": "agent", "kind": "terminal", "declaredAgentKind": "codex"},
        {"id": "docs", "kind": "browser", "url": "https://example.invalid/", "linkedAgentSurfacePlanId": "agent"},
        {"id": "notes", "kind": "markdown", "filePath": "/tmp/fixture-notes.md"}
      ]
    }
    """#

    private let panelKeyPlanJSON = #"""
    {
      "version": 1,
      "workspace": {"title": "Fixture"},
      "layout": {
        "type": "split",
        "split": {
          "orientation": "horizontal",
          "dividerPosition": 0.5,
          "first": {"type": "pane", "pane": {"panelIds": ["agent"]}},
          "second": {"type": "pane", "pane": {"panelIds": ["docs", "notes"], "selectedIndex": 1}}
        }
      },
      "panels": [
        {"id": "agent", "kind": "terminal", "declaredAgentKind": "codex"},
        {"id": "docs", "kind": "browser", "url": "https://example.invalid/", "linkedAgentPanelPlanId": "agent"},
        {"id": "notes", "kind": "markdown", "filePath": "/tmp/fixture-notes.md"}
      ]
    }
    """#

    func testPlanDecodesLegacyAndPanelKeysToTheSamePlan() throws {
        let legacy = try decode(WorkspaceApplyPlan.self, from: Data(legacyKeyPlanJSON.utf8))
        let current = try decode(WorkspaceApplyPlan.self, from: Data(panelKeyPlanJSON.utf8))
        XCTAssertEqual(legacy, current)
        XCTAssertEqual(current.surfaces.map(\.id), ["agent", "docs", "notes"])
        XCTAssertEqual(current.surfaces[1].linkedAgentSurfacePlanId, "agent")
        guard case .split(let split) = current.layout,
              case .pane(let second) = split.second else {
            return XCTFail("expected split layout with a pane on the second side")
        }
        XCTAssertEqual(second.surfaceIds, ["docs", "notes"])
        XCTAssertEqual(second.selectedIndex, 1)
    }

    func testPlanEncodesOnlyPanelKeys() throws {
        let plan = try decode(WorkspaceApplyPlan.self, from: Data(legacyKeyPlanJSON.utf8))
        let json = try XCTUnwrap(String(data: try encode(plan), encoding: .utf8))
        for key in ["\"panels\"", "\"panelIds\"", "\"linkedAgentPanelPlanId\""] {
            XCTAssertTrue(json.contains(key), "expected \(key) in \(json)")
        }
        for key in ["\"surfaces\"", "\"surfaceIds\"", "\"linkedAgentSurfacePlanId\""] {
            XCTAssertFalse(json.contains(key), "unexpected legacy \(key) in \(json)")
        }
        XCTAssertEqual(try decode(WorkspaceApplyPlan.self, from: Data(json.utf8)), plan)
    }

    func testPlanPrefersPanelKeysWhenBothSpellingsArePresent() throws {
        let json = #"""
        {
          "version": 1,
          "workspace": {},
          "layout": {"type": "pane", "pane": {"panelIds": ["new"], "surfaceIds": ["old"]}},
          "panels": [{"id": "new", "kind": "browser", "linkedAgentPanelPlanId": "newAgent", "linkedAgentSurfacePlanId": "oldAgent"}],
          "surfaces": [{"id": "old", "kind": "terminal"}]
        }
        """#
        let plan = try decode(WorkspaceApplyPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.surfaces.map(\.id), ["new"])
        XCTAssertEqual(plan.surfaces.first?.linkedAgentSurfacePlanId, "newAgent")
        XCTAssertEqual(plan.layout, .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["new"])))
    }

    func testCompanionDiagnosticCodeWritesPanelSpellingAndReadsLegacy() throws {
        let encoded = try XCTUnwrap(String(
            data: try encode([CompanionPlanDiagnosticCode.duplicateSurfaceID]),
            encoding: .utf8
        ))
        XCTAssertEqual(encoded, #"["blueprint_duplicate_panel_id"]"#)
        let legacy = Data(#"["blueprint_duplicate_surface_id","blueprint_duplicate_panel_id"]"#.utf8)
        XCTAssertEqual(
            try decode([CompanionPlanDiagnosticCode].self, from: legacy),
            [.duplicateSurfaceID, .duplicateSurfaceID]
        )
        XCTAssertThrowsError(
            try decode([CompanionPlanDiagnosticCode].self, from: Data(#"["not_a_code"]"#.utf8))
        )
    }

    // MARK: - Validation (review cycle 1 R6: I4a/I4b/I4d)

    /// Helper: build a plan with the minimum valid layout (one terminal).
    private func minimalPlan(
        version: Int = 1,
        surfaces: [PanelSpec]? = nil,
        layout: LayoutTreeSpec? = nil
    ) -> WorkspaceApplyPlan {
        let resolvedPanels = surfaces ?? [PanelSpec(id: "a", kind: .terminal)]
        let resolvedLayout = layout ?? .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"]))
        return WorkspaceApplyPlan(
            version: version,
            workspace: WorkspaceSpec(),
            layout: resolvedLayout,
            surfaces: resolvedPanels
        )
    }

    func testValidateAcceptsVersionOne() {
        XCTAssertNil(WorkspaceLayoutExecutor.validate(plan: minimalPlan(version: 1)))
    }

    func testValidateRejectsUnsupportedVersion() {
        let failure = WorkspaceLayoutExecutor.validate(plan: minimalPlan(version: 2))
        XCTAssertEqual(failure?.code, "unsupported_version")
        XCTAssertEqual(failure?.step, "validate")
    }

    func testValidateRejectsDuplicateTabId() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"])),
            surfaces: [
                PanelSpec(id: "a", kind: .terminal),
                PanelSpec(id: "a", kind: .terminal)
            ]
        )
        let failure = WorkspaceLayoutExecutor.validate(plan: plan)
        XCTAssertEqual(failure?.code, "duplicate_surface_id")
    }

    func testValidateRejectsDuplicateTabReferenceAcrossAreas() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .split(LayoutTreeSpec.SplitSpec(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"])),
                second: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"]))
            )),
            surfaces: [PanelSpec(id: "a", kind: .terminal)]
        )
        let failure = WorkspaceLayoutExecutor.validate(plan: plan)
        XCTAssertEqual(failure?.code, "duplicate_surface_reference")
    }

    func testValidateRejectsDuplicateTabReferenceWithinSingleArea() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a", "a"])),
            surfaces: [PanelSpec(id: "a", kind: .terminal)]
        )
        let failure = WorkspaceLayoutExecutor.validate(plan: plan)
        XCTAssertEqual(failure?.code, "duplicate_surface_reference")
    }

    func testValidateRejectsUnknownTabReference() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["ghost"])),
            surfaces: [PanelSpec(id: "a", kind: .terminal)]
        )
        let failure = WorkspaceLayoutExecutor.validate(plan: plan)
        XCTAssertEqual(failure?.code, "unknown_surface_ref")
    }

    func testValidateRejectsOutOfRangeSelectedIndex() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a"], selectedIndex: 5)),
            surfaces: [PanelSpec(id: "a", kind: .terminal)]
        )
        let failure = WorkspaceLayoutExecutor.validate(plan: plan)
        XCTAssertEqual(failure?.code, "validation_failed")
    }
}
