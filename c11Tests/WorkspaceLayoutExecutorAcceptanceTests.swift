import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Acceptance fixture for `WorkspaceLayoutExecutor`. Runs each of five
/// `WorkspaceApplyPlan` JSON fixtures through the executor on a real
/// `TabManager` and verifies three things:
///
/// 1. Every plan-local surface id appears in `result.surfaceRefs` and
///    `result.paneRefs`.
/// 2. The live bonsplit tree shape — split orientations, divider positions,
///    pane tab ordering, selected tab — matches the fixture's `LayoutTreeSpec`.
///    Without this assertion, a broken layout walker can produce malformed
///    geometry and still satisfy surface-ref coverage (review cycle 1 B1/B2).
/// 3. Every `SurfaceSpec.metadata` / `SurfaceSpec.paneMetadata` entry in the
///    fixture round-trips through `SurfaceMetadataStore` / `PaneMetadataStore`.
///
/// Per `CLAUDE.md`, tests are never run locally by the impl agent; this file
/// is committed and exercised only in CI.
@MainActor
final class WorkspaceLayoutExecutorAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    /// Budget per fixture in milliseconds. Matches `ApplyOptions.perStepTimeoutMs`
    /// default and the plan's acceptance target.
    private static let perFixtureBudgetMs: Double = 2_000

    /// Divider positions are floating-point; allow a small tolerance when
    /// comparing plan value vs. live bonsplit value.
    private static let dividerTolerance: Double = 0.001

    // MARK: - Setup

    private var tabManager: TabManager!

    override func setUp() {
        super.setUp()
        tabManager = TabManager()
    }

    override func tearDown() {
        tabManager = nil
        super.tearDown()
    }

    // MARK: - Per-fixture tests

    func testAppliesWelcomeQuadFixture() throws {
        try runFixture(named: "welcome-quad", expectedSurfaceIds: ["tl", "tr", "bl", "br"])
    }

    func testAppliesDefaultGridFixture() throws {
        try runFixture(named: "default-grid", expectedSurfaceIds: ["tl", "tr", "bl", "br"])
    }

    func testAppliesSingleLargeWithMetadataFixture() throws {
        try runFixture(
            named: "single-large-with-metadata",
            expectedSurfaceIds: ["main"]
        )
    }

    func testAppliesMixedBrowserMarkdownFixture() throws {
        try runFixture(
            named: "mixed-browser-markdown",
            expectedSurfaceIds: ["docs", "notes", "tests", "build"]
        )
    }

    func testAppliesDeepNestedSplitsFixture() throws {
        try runFixture(
            named: "deep-nested-splits",
            expectedSurfaceIds: ["a", "b", "c", "d", "e"]
        )
    }

    // MARK: - Harness

    @discardableResult
    private func runFixture(
        named name: String,
        expectedSurfaceIds: [String]
    ) throws -> ApplyResult {
        let plan = try loadFixture(named: name)
        let deps = WorkspaceLayoutExecutorDependencies(
            tabManager: tabManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: true),
            dependencies: deps
        )

        // 1. Surface / pane ref coverage.
        XCTAssertFalse(result.workspaceRef.isEmpty, "workspaceRef populated for \(name)")
        XCTAssertEqual(
            Set(result.surfaceRefs.keys),
            Set(expectedSurfaceIds),
            "surfaceRefs cover all expected plan surface ids for \(name)"
        )
        XCTAssertEqual(
            Set(result.paneRefs.keys),
            Set(expectedSurfaceIds),
            "paneRefs cover all expected plan surface ids for \(name)"
        )
        XCTAssertTrue(
            result.failures.allSatisfy { $0.code != "validation_failed" },
            "no validation_failed entries in \(name): \(result.failures)"
        )

        let workspace = try XCTUnwrap(
            resolveWorkspace(from: result.workspaceRef),
            "workspaceRef \(result.workspaceRef) resolves to a live Workspace"
        )

        // 2. Structural assertion against bonsplit treeSnapshot.
        let liveTree = workspace.bonsplitController.treeSnapshot()
        let planSurfaceIdToPanelUUID = Dictionary(uniqueKeysWithValues: result.surfaceRefs
            .compactMap { (planId, ref) -> (String, UUID)? in
                guard let uuid = parseUUIDSuffix(ref) else { return nil }
                return (planId, uuid)
            })
        compareStructure(
            fixtureName: name,
            path: "layout",
            plan: plan.layout,
            live: liveTree,
            planSurfaceIdToPanelUUID: planSurfaceIdToPanelUUID,
            workspace: workspace
        )

        // 3. Metadata round-trip for every fixture that declares metadata.
        assertMetadataRoundTrip(
            fixtureName: name,
            plan: plan,
            result: result,
            workspace: workspace
        )

        // 3b. Terminal working-directory plumb — explicit cwd on a
        //     split-created terminal should either land on the panel
        //     (requestedWorkingDirectory matches) or emit a typed
        //     working_directory_not_applied failure. Silent drop is the
        //     bug review cycle 1 I1 flagged.
        assertWorkingDirectoriesApplied(
            fixtureName: name,
            plan: plan,
            result: result,
            workspace: workspace
        )

        // 4. Timing budget.
        let totalMs = result.timings.first { $0.step == "total" }?.durationMs ?? .infinity
        XCTAssertLessThan(
            totalMs,
            Self.perFixtureBudgetMs,
            "fixture \(name) exceeded \(Self.perFixtureBudgetMs) ms budget; total=\(totalMs)"
        )
        return result
    }

    private func loadFixture(named name: String) throws -> WorkspaceApplyPlan {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("workspace-apply-plans")
            .appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(WorkspaceApplyPlan.self, from: data)
    }

    // MARK: - Workspace lookup

    private func resolveWorkspace(from ref: String) -> Workspace? {
        guard let uuid = parseUUIDSuffix(ref) else { return nil }
        return tabManager.tabs.first { $0.id == uuid }
    }

    private func parseUUIDSuffix(_ ref: String?) -> UUID? {
        guard let ref = ref,
              let uuidString = ref.split(separator: ":").last else {
            return nil
        }
        return UUID(uuidString: String(uuidString))
    }

    // MARK: - Structural comparison

    /// Walk plan and live trees in lockstep. Every divergence (shape,
    /// orientation, divider position, tab order, selected tab) fails the
    /// test with a fixture-and-path-qualified message so breakage points at
    /// the specific subtree that disagrees.
    private func compareStructure(
        fixtureName: String,
        path: String,
        plan: LayoutTreeSpec,
        live: ExternalTreeNode,
        planSurfaceIdToPanelUUID: [String: UUID],
        workspace: Workspace
    ) {
        switch (plan, live) {
        case (.split(let planSplit), .split(let liveSplit)):
            XCTAssertEqual(
                planSplit.orientation.rawValue,
                liveSplit.orientation,
                "[\(fixtureName) @ \(path)] split orientation mismatch"
            )
            XCTAssertEqual(
                planSplit.dividerPosition,
                liveSplit.dividerPosition,
                accuracy: Self.dividerTolerance,
                "[\(fixtureName) @ \(path)] dividerPosition mismatch"
            )
            compareStructure(
                fixtureName: fixtureName,
                path: "\(path).first",
                plan: planSplit.first,
                live: liveSplit.first,
                planSurfaceIdToPanelUUID: planSurfaceIdToPanelUUID,
                workspace: workspace
            )
            compareStructure(
                fixtureName: fixtureName,
                path: "\(path).second",
                plan: planSplit.second,
                live: liveSplit.second,
                planSurfaceIdToPanelUUID: planSurfaceIdToPanelUUID,
                workspace: workspace
            )
        case (.pane(let planPane), .pane(let livePane)):
            comparePane(
                fixtureName: fixtureName,
                path: path,
                planPane: planPane,
                livePane: livePane,
                planSurfaceIdToPanelUUID: planSurfaceIdToPanelUUID,
                workspace: workspace
            )
        case (.split, .pane):
            XCTFail("[\(fixtureName) @ \(path)] plan expected split, live is pane")
        case (.pane, .split):
            XCTFail("[\(fixtureName) @ \(path)] plan expected pane, live is split")
        }
    }

    private func comparePane(
        fixtureName: String,
        path: String,
        planPane: LayoutTreeSpec.PaneSpec,
        livePane: ExternalPaneNode,
        planSurfaceIdToPanelUUID: [String: UUID],
        workspace: Workspace
    ) {
        // Resolve the bonsplit tab ids back to plan-local surface ids so the
        // assertion compares like for like. Tabs whose panel id doesn't
        // resolve to a plan surface are surfaced as "unknown" in the
        // assertion message — they indicate a stray seed or leaked panel.
        let panelUUIDToPlanId = Dictionary(
            uniqueKeysWithValues: planSurfaceIdToPanelUUID.map { ($0.value, $0.key) }
        )
        let livePlanIds: [String] = livePane.tabs.map { tab in
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                  let planId = panelUUIDToPlanId[panelId] else {
                return "unknown(\(tab.id))"
            }
            return planId
        }
        XCTAssertEqual(
            livePlanIds,
            planPane.surfaceIds,
            "[\(fixtureName) @ \(path)] pane tab ordering mismatch"
        )

        let expectedSelectedIndex = planPane.selectedIndex ?? 0
        if expectedSelectedIndex >= 0, expectedSelectedIndex < planPane.surfaceIds.count {
            let expectedSurfaceId = planPane.surfaceIds[expectedSelectedIndex]
            guard let expectedPanelId = planSurfaceIdToPanelUUID[expectedSurfaceId],
                  let expectedTabId = workspace.surfaceIdFromPanelId(expectedPanelId) else {
                XCTFail("[\(fixtureName) @ \(path)] could not resolve expected selected surface \(expectedSurfaceId)")
                return
            }
            XCTAssertEqual(
                livePane.selectedTabId,
                expectedTabId,
                "[\(fixtureName) @ \(path)] selectedTabId mismatch (expected surface \(expectedSurfaceId))"
            )
        }
    }

    // MARK: - Working directory

    /// For each terminal `SurfaceSpec` that declares a `workingDirectory`,
    /// assert it either landed on the live panel or emitted a typed
    /// `working_directory_not_applied` failure. Silent drop (pre-rework B1/I1)
    /// now fails the test.
    private func assertWorkingDirectoriesApplied(
        fixtureName: String,
        plan: WorkspaceApplyPlan,
        result: ApplyResult,
        workspace: Workspace
    ) {
        for spec in plan.surfaces {
            guard spec.kind == .terminal,
                  let expectedCwd = spec.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedCwd.isEmpty else {
                continue
            }
            guard let panelId = parseUUIDSuffix(result.surfaceRefs[spec.id]),
                  let terminalPanel = workspace.panels[panelId] as? TerminalPanel else {
                XCTFail("[\(fixtureName)] terminal surface[\(spec.id)] with workingDirectory did not produce a resolvable panel")
                continue
            }
            let landed = terminalPanel.requestedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if landed == expectedCwd {
                continue
            }
            let reported = result.failures.contains {
                $0.code == "working_directory_not_applied"
                    && $0.message.contains("surface[\(spec.id)]")
            }
            XCTAssertTrue(
                reported,
                "[\(fixtureName)] surface[\(spec.id)] workingDirectory='\(expectedCwd)' neither landed ('\(landed)') nor emitted working_directory_not_applied ApplyFailure"
            )
        }
    }

    // MARK: - Metadata round-trip

    /// For every `SurfaceSpec` in the plan, verify that declared surface and
    /// pane metadata landed in the respective stores. Absent metadata is a
    /// no-op — fixtures don't need entries they don't care about.
    private func assertMetadataRoundTrip(
        fixtureName: String,
        plan: WorkspaceApplyPlan,
        result: ApplyResult,
        workspace: Workspace
    ) {
        // Workspace-level metadata.
        if let entries = plan.workspace.metadata {
            for (key, expected) in entries {
                XCTAssertEqual(
                    workspace.metadata[key],
                    expected,
                    "[\(fixtureName)] workspace.metadata[\"\(key)\"] round-trip"
                )
            }
        }
        if let expectedTitle = plan.workspace.title {
            XCTAssertEqual(
                workspace.customTitle,
                expectedTitle,
                "[\(fixtureName)] workspace customTitle matches plan.workspace.title"
            )
        }

        for surfaceSpec in plan.surfaces {
            guard let panelId = parseUUIDSuffix(result.surfaceRefs[surfaceSpec.id]) else {
                continue
            }
            let paneUUID = workspace.paneIdForPanel(panelId)?.id

            // Surface-level metadata.
            let (surfaceMetadata, _) = SurfaceMetadataStore.shared.getMetadata(
                workspaceId: workspace.id,
                surfaceId: panelId
            )
            if let title = surfaceSpec.title {
                XCTAssertEqual(
                    surfaceMetadata["title"] as? String,
                    title,
                    "[\(fixtureName)] surface[\(surfaceSpec.id)] title in SurfaceMetadataStore"
                )
            }
            if let description = surfaceSpec.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                XCTAssertEqual(
                    surfaceMetadata["description"] as? String,
                    description,
                    "[\(fixtureName)] surface[\(surfaceSpec.id)] description in SurfaceMetadataStore"
                )
            }
            if let metadata = surfaceSpec.metadata {
                for (key, expected) in metadata {
                    assertMetadataValueMatches(
                        fixtureName: fixtureName,
                        storeName: "SurfaceMetadataStore",
                        surfaceId: surfaceSpec.id,
                        key: key,
                        expected: expected,
                        actual: surfaceMetadata[key]
                    )
                }
            }

            // Pane-level metadata (including the reserved `mailbox.*` namespace).
            if let paneMetadata = surfaceSpec.paneMetadata,
               !paneMetadata.isEmpty,
               let paneUUID {
                let (livePaneMetadata, _) = PaneMetadataStore.shared.getMetadata(
                    workspaceId: workspace.id,
                    paneId: paneUUID
                )
                for (key, expected) in paneMetadata {
                    // v1 strings-only: non-string values on `mailbox.*` are
                    // intentionally dropped with an ApplyFailure. The round-trip
                    // assertion skips those; presence of the matching failure
                    // is verified separately.
                    if key.hasPrefix("mailbox."), case .string = expected {
                        // fall through to the assertion
                    } else if key.hasPrefix("mailbox.") {
                        XCTAssertTrue(
                            result.failures.contains {
                                $0.code == "mailbox_non_string_value"
                                    && $0.message.contains("[\(key)")
                            },
                            "[\(fixtureName)] surface[\(surfaceSpec.id)] non-string mailbox.\(key) emits ApplyFailure"
                        )
                        XCTAssertNil(
                            livePaneMetadata[key],
                            "[\(fixtureName)] surface[\(surfaceSpec.id)] non-string mailbox.\(key) dropped from store"
                        )
                        continue
                    }
                    assertMetadataValueMatches(
                        fixtureName: fixtureName,
                        storeName: "PaneMetadataStore",
                        surfaceId: surfaceSpec.id,
                        key: key,
                        expected: expected,
                        actual: livePaneMetadata[key]
                    )
                }
            }
        }
    }

    /// Compare a `PersistedJSONValue` expected value to whatever the store
    /// returned (the store speaks `[String: Any]`). Scalars are matched
    /// directly; containers are normalized through JSON to avoid leaking
    /// Swift-specific equality rules into the assertion.
    private func assertMetadataValueMatches(
        fixtureName: String,
        storeName: String,
        surfaceId: String,
        key: String,
        expected: PersistedJSONValue,
        actual: Any?
    ) {
        let qualifier = "[\(fixtureName)] \(storeName) surface[\(surfaceId)] \(key)"
        switch expected {
        case .string(let value):
            XCTAssertEqual(actual as? String, value, "\(qualifier): string")
        case .bool(let value):
            XCTAssertEqual(actual as? Bool, value, "\(qualifier): bool")
        case .number(let value):
            if let actualDouble = (actual as? NSNumber)?.doubleValue ?? (actual as? Double) {
                XCTAssertEqual(actualDouble, value, accuracy: 0.0001, "\(qualifier): number")
            } else {
                XCTFail("\(qualifier): expected number \(value), got \(String(describing: actual))")
            }
        case .null:
            XCTAssertNil(actual, "\(qualifier): null")
        case .array, .object:
            // Containers: compare JSON round-trips. This keeps the assertion
            // honest without enumerating every container layout.
            guard let actual = actual,
                  let expectedData = try? JSONEncoder().encode(expected),
                  let actualData = try? JSONSerialization.data(withJSONObject: actual),
                  let expectedJSON = try? JSONSerialization.jsonObject(with: expectedData),
                  let actualJSON = try? JSONSerialization.jsonObject(with: actualData) else {
                XCTFail("\(qualifier): container comparison failed; expected=\(expected), actual=\(String(describing: actual))")
                return
            }
            XCTAssertEqual(
                String(describing: actualJSON),
                String(describing: expectedJSON),
                "\(qualifier): container round-trip"
            )
        }
    }
}
