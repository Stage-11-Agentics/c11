import AppKit
import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
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
/// Runs in the no-host `c11LogicTests` process both locally and in CI.
@MainActor
final class WorkspaceLayoutExecutorAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    /// Divider positions are floating-point; allow a small tolerance when
    /// comparing plan value vs. live bonsplit value.
    private static let dividerTolerance: Double = 0.001

    // MARK: - Setup

    private var workspaceManager: WorkspaceManager!

    override func setUp() {
        super.setUp()
        // The logic-test runner has no host application, but constructing a
        // TabManager reaches Ghostty setup that reads NSApp. Create AppKit's
        // process singleton without launching or hosting the c11 application.
        _ = NSApplication.shared
        workspaceManager = WorkspaceManager()
    }

    override func tearDown() {
        workspaceManager = nil
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

    // MARK: - Agent companion persistence/remapping

    func testBrowserBeforeAgentLinkResolvesAfterAllTabsMaterialize() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "browser before agent"),
            layout: .pane(.init(surfaceIds: ["browser", "agent"])),
            surfaces: [
                PanelSpec(
                    id: "browser",
                    kind: .browser,
                    url: "https://example.com",
                    linkedAgentSurfacePlanId: "agent"
                ),
                PanelSpec(
                    id: "agent",
                    kind: .terminal,
                    declaredAgentKind: "codex"
                )
            ]
        )
        var applied: [(browser: UUID, agent: UUID)] = []
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" },
            applyCompanionLink: { _, browserID, agentID in
                applied.append((browserID, agentID))
            }
        )

        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false),
            dependencies: deps
        )
        XCTAssertTrue(result.companionDiagnostics.isEmpty)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.browser, parseUUIDSuffix(result.surfaceRefs["browser"]))
        XCTAssertEqual(applied.first?.agent, parseUUIDSuffix(result.surfaceRefs["agent"]))
    }

    func testCompanionApplyRejectsUndeclaredAgentWithStructuredDiagnostic() {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "invalid target"),
            layout: .pane(.init(surfaceIds: ["browser", "terminal"])),
            surfaces: [
                PanelSpec(
                    id: "browser",
                    kind: .browser,
                    linkedAgentSurfacePlanId: "terminal"
                ),
                PanelSpec(id: "terminal", kind: .terminal)
            ]
        )
        var mutationCount = 0
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" },
            applyCompanionLink: { _, _, _ in mutationCount += 1 }
        )

        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false),
            dependencies: deps
        )
        XCTAssertEqual(mutationCount, 0)
        XCTAssertEqual(result.companionDiagnostics, [
            CompanionPlanDiagnostic(
                code: .targetNotAgent,
                severity: .error,
                sourcePlanID: "browser",
                targetPlanID: "terminal"
            )
        ])
        let expectedMessage = CompanionPlanDiagnosticMessage.localized(
            code: .targetNotAgent,
            sourcePlanID: "browser",
            targetPlanID: "terminal"
        )
        XCTAssertTrue(expectedMessage.contains("browser"))
        XCTAssertTrue(expectedMessage.contains("terminal"))
        XCTAssertTrue(result.warnings.contains(expectedMessage))
        XCTAssertTrue(result.failures.contains {
            $0.code == "companion_link_target_not_agent"
                && $0.message == expectedMessage
        })
    }

    func testTwoPassCaptureRemapsLinkAndOmitsOrphanWithWarning() throws {
        let seedPlan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "capture remap"),
            layout: .pane(.init(surfaceIds: ["browser", "agent"])),
            surfaces: [
                PanelSpec(id: "browser", kind: .browser, url: "https://example.com"),
                PanelSpec(id: "agent", kind: .terminal)
            ]
        )
        let seed = WorkspaceLayoutExecutor.apply(
            seedPlan,
            options: ApplyOptions(select: false),
            dependencies: WorkspaceLayoutExecutorDependencies(
                workspaceManager: workspaceManager,
                workspaceRefMinter: { "workspace:\($0.uuidString)" },
                surfaceRefMinter: { "surface:\($0.uuidString)" },
                paneRefMinter: { "pane:\($0.uuidString)" }
            )
        )
        let workspace = try XCTUnwrap(resolveWorkspace(from: seed.workspaceRef))
        let browserID = try XCTUnwrap(parseUUIDSuffix(seed.surfaceRefs["browser"]))
        let agentID = try XCTUnwrap(parseUUIDSuffix(seed.surfaceRefs["agent"]))
        _ = try PanelMetadataStore.shared.mutateAttention(
            workspaceId: workspace.id,
            surfaceId: agentID,
            delegation: .delegate(ownerPanelId: UUID())
        )

        let captured = WorkspacePlanCapture.capture(
            workspace: workspace,
            companionBridge: WorkspacePlanCompanionCaptureBridge(
                linkedAgentForBrowser: { id in
                    id == browserID ? AgentPanelLink(
                        surfaceID: agentID,
                        lastKnownName: "Agent"
                    ) : nil
                },
                declaredAgentKindForTerminal: { id in id == agentID ? "codex" : nil }
            )
        )
        XCTAssertEqual(captured.plan.surfaces.map(\.id), ["s1", "s2"])
        XCTAssertEqual(captured.plan.surfaces[0].linkedAgentSurfacePlanId, "s2")
        XCTAssertEqual(captured.plan.surfaces[1].declaredAgentKind, "codex")
        XCTAssertNil(captured.plan.surfaces[1].metadata?[MetadataKey.delegatedBy])
        XCTAssertNil(captured.plan.surfaces[1].metadata?[MetadataKey.suppressed])
        XCTAssertTrue(captured.warnings.isEmpty)

        let missingAgentID = UUID()
        let orphanBridge = WorkspacePlanCompanionCaptureBridge(
            linkedAgentForBrowser: { id in
                id == browserID ? AgentPanelLink(
                    surfaceID: missingAgentID,
                    lastKnownName: "Gone"
                ) : nil
            },
            declaredAgentKindForTerminal: { id in id == agentID ? "codex" : nil }
        )
        let orphaned = WorkspacePlanCapture.capture(
            workspace: workspace,
            companionBridge: orphanBridge
        )
        XCTAssertNil(orphaned.plan.surfaces[0].linkedAgentSurfacePlanId)
        XCTAssertEqual(orphaned.warnings, [
            CompanionPlanDiagnostic(
                code: .orphanOmitted,
                severity: .warning,
                sourcePlanID: "s1",
                targetPlanID: nil
            )
        ])

        let declassifiedBridge = WorkspacePlanCompanionCaptureBridge(
            linkedAgentForBrowser: { id in
                id == browserID ? AgentPanelLink(
                    surfaceID: agentID,
                    lastKnownName: "Former Agent"
                ) : nil
            },
            declaredAgentKindForTerminal: { _ in nil }
        )
        let declassified = WorkspacePlanCapture.capture(
            workspace: workspace,
            companionBridge: declassifiedBridge
        )
        XCTAssertNil(declassified.plan.surfaces[0].linkedAgentSurfacePlanId)
        XCTAssertEqual(declassified.warnings, [
            CompanionPlanDiagnostic(
                code: .orphanOmitted,
                severity: .warning,
                sourcePlanID: "s1",
                targetPlanID: "s2"
            )
        ])

        let snapshot = try XCTUnwrap(LiveWorkspaceSnapshotSource(
            workspaceManager: workspaceManager,
            c11Version: "companion-test+0"
        ).captureResult(
            workspaceId: workspace.id,
            origin: .manual,
            clock: { Date(timeIntervalSince1970: 1_745_000_000) },
            companionBridge: orphanBridge
        ))
        XCTAssertEqual(snapshot.warnings, orphaned.warnings)
        XCTAssertNil(snapshot.snapshot.plan.surfaces[0].linkedAgentSurfacePlanId)

        let blueprint = try XCTUnwrap(WorkspaceBlueprintExporter(
            workspaceManager: workspaceManager
        ).exportWithDiagnostics(
            workspaceId: workspace.id,
            name: "Orphan capture",
            companionBridge: orphanBridge
        ))
        XCTAssertEqual(blueprint.warnings, orphaned.warnings)
        XCTAssertNil(blueprint.file.plan.surfaces[0].linkedAgentSurfacePlanId)
    }

    // MARK: - Phase 0 parity: whitespace-only command (B4)

    /// Phase 0 sent `SurfaceSpec.command` to the terminal verbatim as long
    /// as it was non-nil. A command of `" "` (single space) reached the
    /// terminal as a single space. Phase 1's registry wiring used to trim
    /// the explicit command before the presence check, which routed
    /// whitespace-only commands into the registry — and the registry
    /// returns `nil` — so the space was silently dropped. B4 restores
    /// the pre-registry behaviour: only a genuinely `nil` command
    /// delegates to the registry.
    func testWhitespaceOnlyCommandIsSentVerbatimAndBypassesRegistry() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "b4 whitespace"),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["t"])),
            surfaces: [
                PanelSpec(
                    id: "t",
                    kind: .terminal,
                    title: "whitespace terminal",
                    command: " ",
                    metadata: [
                        // Metadata that *would* match the registry. The
                        // registry must NOT be consulted when a plan
                        // declares any command, whitespace included.
                        "terminal_type": .string("claude-code"),
                        "claude.session_id": .string("aaaaaaaa-1111-2222-3333-444455556666")
                    ]
                )
            ]
        )
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false, restartRegistry: .phase1),
            dependencies: deps
        )
        XCTAssertFalse(result.workspaceRef.isEmpty)
        XCTAssertTrue(
            result.failures.allSatisfy { $0.code != "restart_registry_declined" },
            "whitespace command must not consult the registry: \(result.failures)"
        )
        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        guard let panelId = parseUUIDSuffix(result.surfaceRefs["t"]),
              let terminal = workspace.panels[panelId] as? TerminalPanel else {
            return XCTFail("terminal panel not resolvable")
        }
        #if DEBUG
        let sent = terminal.surface.pendingInitialInputForTests ?? ""
        XCTAssertEqual(
            sent,
            " ",
            "Phase 0 whitespace command must reach sendText verbatim"
        )
        #endif
    }

    // MARK: - C11H-365 (L4): a linked machine's terminal

    /// A snapshot's terminal that ran on a linked machine is restored on that
    /// machine, never as a local terminal, and the restart registry is never
    /// asked for it: the agent metadata that would choose a resume line came
    /// from that machine. Capture keeps the machine, so the round trip holds.
    func testLinkedMachineTerminalRestoresOnItsMachineWithNoSynthesizedRestart() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "l4 linked machine"),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["r"])),
            surfaces: [
                PanelSpec(
                    id: "r",
                    kind: .terminal,
                    title: "remote agent",
                    workingDirectory: "/Users/peer/project",
                    metadata: [
                        // What the registry would turn into a local
                        // `claude --dangerously-skip-permissions --resume <id>`.
                        "terminal_type": .string("claude-code"),
                        "claude.session_id": .string("aaaaaaaa-1111-2222-3333-444455556666")
                    ],
                    machine: "studio"
                )
            ]
        )
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false, restartRegistry: .phase1),
            dependencies: deps
        )
        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let panelId = try XCTUnwrap(parseUUIDSuffix(result.surfaceRefs["r"]))
        let terminal = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        XCTAssertEqual(terminal.hcRemoteTarget?.machine, "studio",
                       "the linked machine's terminal must not be restored as a local terminal")
        XCTAssertEqual(terminal.hcRemoteTarget?.cwd, "/Users/peer/project")
        XCTAssertEqual(workspace.panels.values.compactMap { $0 as? TerminalPanel }.filter { $0.hcRemoteTarget == nil }.count, 0,
                       "the local seed terminal must not stay in place of the remote one")
        #if DEBUG
        XCTAssertEqual(terminal.surface.pendingInitialInputForTests, "",
                       "no resume line may be synthesized for a terminal that is not local")
        #endif

        let captured = WorkspacePlanCapture.capture(workspace: workspace, companionBridge: .none)
        let spec = try XCTUnwrap(captured.plan.surfaces.first { $0.kind == .terminal })
        XCTAssertEqual(spec.machine, "studio", "capture must record the panel's machine")
        XCTAssertEqual(spec.workingDirectory, "/Users/peer/project")
    }

    /// C11H-396: a plan's terminal on a machine whose routed link c11 won't
    /// use is a new terminal there, so it is refused up front like `--on`:
    /// no panel, and the failure carries `machine_link_unusable` with the
    /// message `--on` gives, through the split path and the in-area path.
    /// The local leaf beside it is still made.
    func testAPlannedTerminalOnAnUnusablyLinkedMachineIsRefusedWithItsReason() throws {
        defer { MachinePicker.unusableOverride = nil }
        MachinePicker.unusableOverride = { ["far"] }
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "c11h-396 refused leaf"),
            layout: .split(LayoutTreeSpec.SplitSpec(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["l", "r2"])),
                second: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["r"]))
            )),
            surfaces: [
                PanelSpec(id: "l", kind: .terminal),
                PanelSpec(id: "r", kind: .terminal, workingDirectory: "/srv/far", machine: "far"),
                PanelSpec(id: "r2", kind: .terminal, machine: "far")
            ]
        )
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let result = WorkspaceLayoutExecutor.apply(plan, options: ApplyOptions(select: false, perStepTimeoutMs: 0),
                                                   dependencies: deps)
        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let refused = result.failures.filter { $0.code == "machine_link_unusable" }
        XCTAssertEqual(refused.count, 2, "the split leaf and the in-area leaf: \(result.failures)")
        XCTAssertTrue(refused.allSatisfy { $0.message == HCMachineTargetError.linkUnusable("far").message }, "\(refused)")
        XCTAssertNil(result.surfaceRefs["r"])
        XCTAssertNil(result.surfaceRefs["r2"])
        XCTAssertNotNil(result.surfaceRefs["l"], "the local leaf is made")
        XCTAssertTrue(workspace.panels.values.compactMap { $0 as? TerminalPanel }.allSatisfy { $0.hcRemoteTarget == nil },
                      "no terminal on far, blank or otherwise")

        MachinePicker.unusableOverride = { [] }
        let usable = WorkspaceLayoutExecutor.apply(plan, options: ApplyOptions(select: false, perStepTimeoutMs: 0),
                                                   dependencies: deps)
        XCTAssertFalse(usable.failures.contains { $0.code == "machine_link_unusable" }, "\(usable.failures)")
        let made = try XCTUnwrap(resolveWorkspace(from: usable.workspaceRef))
        let remote = try XCTUnwrap(parseUUIDSuffix(usable.surfaceRefs["r"]).flatMap { made.panels[$0] as? TerminalPanel })
        XCTAssertEqual(remote.hcRemoteTarget, HCRemoteTarget(machine: "far", cwd: "/srv/far"), "placed as the plan gives it")
    }

    /// C11H-396 (Opus 1, Astra 2 on #390): a refused remote leaf leaves the
    /// plan before the walk, so it never starts an area or seeds a split:
    /// only it fails, every other leaf is made, and no panel the plan didn't
    /// ask for stays. A snapshot captured while far's agent ran, restored
    /// after the switch: far first beside notes, far first beside a local
    /// terminal, and far starting a nested split.
    func testARefusedRemoteLeafLeavesThePlanAndEveryOtherLeafIsMade() throws {
        defer { MachinePicker.unusableOverride = nil }
        MachinePicker.unusableOverride = { ["far"] }
        func split(_ first: LayoutTreeSpec, _ second: LayoutTreeSpec) -> LayoutTreeSpec {
            .split(LayoutTreeSpec.SplitSpec(orientation: .horizontal, dividerPosition: 0.5, first: first, second: second))
        }
        func pane(_ ids: String...) -> LayoutTreeSpec { .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ids)) }
        let surfaces = [
            PanelSpec(id: "local", kind: .terminal),
            PanelSpec(id: "local2", kind: .terminal, title: "second"),
            PanelSpec(id: "far", kind: .terminal, machine: "far"),
            PanelSpec(id: "md", kind: .markdown, title: "notes", filePath: "/tmp/c11h-396-notes.md")
        ]
        let shapes: [(String, LayoutTreeSpec, made: [String], areas: Int)] = [
            ("far seeds a split side", split(pane("local"), pane("far", "md")), ["local", "md"], 2),
            ("far is first in its area", split(pane("far", "local2"), pane("local")), ["local2", "local"], 2),
            ("far starts a nested split", split(pane("local"), split(pane("far"), pane("md", "local2"))), ["local", "md", "local2"], 2)
        ]
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        for (shape, layout, made, areas) in shapes {
            let plan = WorkspaceApplyPlan(version: 1, workspace: WorkspaceSpec(title: shape), layout: layout,
                                          surfaces: surfaces.filter { WorkspaceLayoutExecutorAcceptanceTests.ids(layout).contains($0.id) })
            let result = WorkspaceLayoutExecutor.apply(plan, options: ApplyOptions(select: false, perStepTimeoutMs: 0),
                                                       dependencies: deps)
            let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef), shape)
            XCTAssertEqual(result.failures, [ApplyFailure(code: "machine_link_unusable", step: "surface[far].create",
                                                          message: HCMachineTargetError.linkUnusable("far").message)],
                           "\(shape): only far fails")
            XCTAssertEqual(Set(result.surfaceRefs.keys), Set(made), "\(shape): every other leaf is made")
            XCTAssertEqual(workspace.panels.count, made.count, "\(shape): no panel the plan didn't ask for")
            XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, areas, "\(shape): far's area goes, its split collapses")
            for id in made {
                let panel = try XCTUnwrap(parseUUIDSuffix(result.surfaceRefs[id]).flatMap { workspace.panels[$0] }, "\(shape): \(id)")
                XCTAssertNil((panel as? TerminalPanel)?.hcRemoteTarget, "\(shape): \(id) is this Mac's")
            }
            if let local2 = parseUUIDSuffix(result.surfaceRefs["local2"]) {
                XCTAssertEqual(workspace.panelCustomTitles[local2], "second", "\(shape): local2 is made as planned")
            }
        }
    }

    /// C11H-396: a plan whose every leaf is refused makes nothing: the apply
    /// fails before any workspace exists, with each leaf's reason, so an
    /// in-place restore keeps the workspace it would have replaced.
    func testAPlanOfOnlyRefusedRemoteLeavesFailsBeforeAnyWorkspaceExists() throws {
        defer { MachinePicker.unusableOverride = nil }
        MachinePicker.unusableOverride = { ["far"] }
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "c11h-396 only far"),
            layout: .split(LayoutTreeSpec.SplitSpec(orientation: .vertical, dividerPosition: 0.5,
                                                   first: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["a", "b"])),
                                                   second: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["c"])))),
            surfaces: ["a", "b", "c"].map { PanelSpec(id: $0, kind: .terminal, machine: "far") }
        )
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let before = workspaceManager.workspaces.map(\.id)
        let result = WorkspaceLayoutExecutor.apply(plan, options: ApplyOptions(select: false, perStepTimeoutMs: 0),
                                                   dependencies: deps)
        XCTAssertEqual(result.workspaceRef, "")
        XCTAssertEqual(workspaceManager.workspaces.map(\.id), before, "no workspace is made")
        XCTAssertEqual(result.failures.map(\.step), ["surface[a].create", "surface[b].create", "surface[c].create"])
        XCTAssertTrue(result.failures.allSatisfy { $0.code == "machine_link_unusable" }, "\(result.failures)")
    }

    private static func ids(_ node: LayoutTreeSpec) -> [String] {
        switch node {
        case .pane(let area): return area.surfaceIds
        case .split(let split): return ids(split.first) + ids(split.second)
        }
    }

    // MARK: - Opt-in submit (blueprint `submit: true`)

    /// Shared driver: apply a single-terminal plan carrying `command` and the
    /// given `submitCommand`, then return the freshly created (not-yet-attached)
    /// terminal surface so the caller can inspect what was queued.
    private func applySingleTerminal(
        command: String,
        submitCommand: Bool
    ) throws -> TerminalSurface {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "submit opt-in"),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["t"])),
            surfaces: [
                PanelSpec(
                    id: "t",
                    kind: .terminal,
                    title: "launcher",
                    command: command,
                    submitCommand: submitCommand
                )
            ]
        )
        let deps = WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false),
            dependencies: deps
        )
        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let panelId = try XCTUnwrap(parseUUIDSuffix(result.surfaceRefs["t"]))
        let terminal = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        return terminal.surface
    }

    /// `submit: true` routes an explicit command through `sendSubmitFormText`,
    /// which on a not-yet-attached surface queues the bytes AND arms a Return
    /// to fire on flush. Both the command text and the armed submit are
    /// observable.
    func testSubmitTrueArmsReturnOnFlush() throws {
        let surface = try applySingleTerminal(
            command: "python3 /path/position.py --watch",
            submitCommand: true
        )
        #if DEBUG
        XCTAssertEqual(
            surface.pendingInitialInputForTests,
            "python3 /path/position.py --watch",
            "submit:true still delivers the command bytes"
        )
        XCTAssertTrue(
            surface.pendingSubmitOnFlushForTests,
            "submit:true must arm a synthetic Return via sendSubmitFormText"
        )
        #endif
    }

    /// Default (`submit` absent / false) preserves Phase 0 parity: the command
    /// is typed via `sendText` but no Return is armed, so it sits at the prompt.
    func testSubmitFalseDoesNotArmReturn() throws {
        let surface = try applySingleTerminal(
            command: "python3 /path/position.py --watch",
            submitCommand: false
        )
        #if DEBUG
        XCTAssertEqual(
            surface.pendingInitialInputForTests,
            "python3 /path/position.py --watch",
            "default path still delivers the command bytes"
        )
        XCTAssertFalse(
            surface.pendingSubmitOnFlushForTests,
            "default must not submit — sendText leaves the line at the prompt"
        )
        #endif
    }

    // MARK: - In-place restore (I2)

    /// BL-1 regression: with a single workspace in the window, in-place
    /// restore must produce exactly one workspace (the replacement), not
    /// duplicate. The pre-fix order called `closeWorkspace` first, which
    /// silently no-ops when `tabs.count <= 1`; `apply` then created a
    /// second workspace alongside the untouched first. The fix flips
    /// order (apply first, close second): at the moment of close, tab
    /// count is 2, so the guard passes.
    func testInPlaceRestoreReplacesSingleWorkspaceWithoutDuplicating() throws {
        let existing = try XCTUnwrap(workspaceManager.selectedWorkspace)
        XCTAssertEqual(workspaceManager.workspaces.count, 1, "test seeded with exactly one workspace")
        let existingId = existing.id

        let plan = makeTrivialInPlacePlan(title: "replacement-1")
        let result = WorkspaceLayoutExecutor.applyToExistingWorkspace(
            plan,
            options: ApplyOptions(select: false),
            dependencies: makeInPlaceDeps(),
            existingWorkspaceId: existingId
        )

        XCTAssertFalse(result.workspaceRef.isEmpty, "result carries a usable workspaceRef")
        XCTAssertTrue(
            result.failures.allSatisfy { $0.code != "invalid_params" },
            "no invalid_params failure: \(result.failures)"
        )
        XCTAssertEqual(
            workspaceManager.workspaces.count,
            1,
            "exactly one workspace after in-place restore (single-workspace regression)"
        )
        XCTAssertFalse(
            workspaceManager.workspaces.contains(where: { $0.id == existingId }),
            "original workspace closed"
        )
        let newId = parseUUIDSuffix(result.workspaceRef)
        XCTAssertNotEqual(newId, existingId, "replacement has a new UUID (F4 preserves it)")
        XCTAssertTrue(
            result.warnings.contains(where: { $0.contains("workspace_uuid_changed") }),
            "workspace_uuid_changed warning surfaced: \(result.warnings)"
        )
    }

    /// Multi-workspace case: target is replaced, sibling is untouched,
    /// and the overall tab count is stable.
    func testInPlaceRestoreReplacesTargetAndLeavesSiblingIntact() throws {
        let target = try XCTUnwrap(workspaceManager.selectedWorkspace)
        let sibling = workspaceManager.addWorkspace()
        XCTAssertEqual(workspaceManager.workspaces.count, 2)
        let targetId = target.id
        let siblingId = sibling.id

        let plan = makeTrivialInPlacePlan(title: "replacement-2")
        let result = WorkspaceLayoutExecutor.applyToExistingWorkspace(
            plan,
            options: ApplyOptions(select: false),
            dependencies: makeInPlaceDeps(),
            existingWorkspaceId: targetId
        )

        XCTAssertFalse(result.workspaceRef.isEmpty)
        XCTAssertEqual(workspaceManager.workspaces.count, 2, "tab count stable: sibling plus replacement")
        XCTAssertFalse(
            workspaceManager.workspaces.contains(where: { $0.id == targetId }),
            "target workspace closed"
        )
        XCTAssertTrue(
            workspaceManager.workspaces.contains(where: { $0.id == siblingId }),
            "sibling workspace intact"
        )
    }

    /// A missing target UUID surfaces `invalid_params` without touching
    /// any existing workspace (non-destructive failure).
    func testInPlaceRestoreMissingTargetReturnsInvalidParams() throws {
        let existing = try XCTUnwrap(workspaceManager.selectedWorkspace)
        let existingId = existing.id
        let bogusId = UUID()
        XCTAssertNotEqual(bogusId, existingId)

        let plan = makeTrivialInPlacePlan(title: "replacement-3")
        let result = WorkspaceLayoutExecutor.applyToExistingWorkspace(
            plan,
            options: ApplyOptions(select: false),
            dependencies: makeInPlaceDeps(),
            existingWorkspaceId: bogusId
        )

        XCTAssertEqual(result.workspaceRef, "")
        XCTAssertTrue(
            result.failures.contains(where: { $0.code == "invalid_params" }),
            "invalid_params failure recorded: \(result.failures)"
        )
        XCTAssertEqual(workspaceManager.workspaces.count, 1, "no workspace created or closed on failure")
        XCTAssertTrue(
            workspaceManager.workspaces.contains(where: { $0.id == existingId }),
            "existing workspace untouched"
        )
    }

    /// A plan with an unsupported version short-circuits in `validate`
    /// before touching any workspace. The target stays intact.
    func testInPlaceRestoreValidationFailureLeavesTargetIntact() throws {
        let existing = try XCTUnwrap(workspaceManager.selectedWorkspace)
        let existingId = existing.id

        let plan = WorkspaceApplyPlan(
            version: 99,
            workspace: WorkspaceSpec(title: "bad-version"),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["s"])),
            surfaces: [PanelSpec(id: "s", kind: .terminal)]
        )
        let result = WorkspaceLayoutExecutor.applyToExistingWorkspace(
            plan,
            options: ApplyOptions(select: false),
            dependencies: makeInPlaceDeps(),
            existingWorkspaceId: existingId
        )

        XCTAssertEqual(result.workspaceRef, "")
        XCTAssertFalse(result.failures.isEmpty, "validation failure recorded")
        XCTAssertEqual(workspaceManager.workspaces.count, 1, "no workspace created or closed on failure")
        XCTAssertTrue(
            workspaceManager.workspaces.contains(where: { $0.id == existingId }),
            "target untouched on validation failure"
        )
    }

    private func makeTrivialInPlacePlan(title: String) -> WorkspaceApplyPlan {
        WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: title),
            layout: .pane(LayoutTreeSpec.AreaSpec(surfaceIds: ["s"])),
            surfaces: [PanelSpec(id: "s", kind: .terminal, title: title)]
        )
    }

    private func makeInPlaceDeps() -> WorkspaceLayoutExecutorDependencies {
        WorkspaceLayoutExecutorDependencies(
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
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
            workspaceManager: workspaceManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
        // The per-step wall-clock guard is off: these fixtures assert the
        // applied layout and metadata, and a loaded test host must not turn
        // a slow step into a `per_step_timeout_exceeded` failure here. Speed
        // is not asserted here; it will be measured by
        // the layout-apply perf-lane benchmark (ticket to follow).
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: true, perStepTimeoutMs: 0),
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

        // 4. Bound on work. The executor records one timing per unit of work
        //    (validate, workspace, each split, each surface and its metadata,
        //    each command, refs, total). Each must appear exactly once, in
        //    walk order, so a retry or poll loop that records an attempt per
        //    iteration, or a second walk, turns the fixture red. Durations are
        //    wall-clock and not asserted here; speed will be measured by
        //    the layout-apply perf-lane benchmark (ticket to follow).
        XCTAssertEqual(
            result.timings.map(\.step),
            expectedTimingSteps(for: plan),
            "fixture \(name) records each expected step exactly once, in walk order"
        )
        return result
    }

    /// The step names `WorkspaceLayoutExecutor.apply` records, in order, for
    /// a plan that applies cleanly with no restart registry. Mirrors the
    /// executor's walk: splits pre-order, then first and second subtrees;
    /// per surface its create and surface-metadata write, plus a pane-metadata
    /// write for the first surface in an area that declares one; then one
    /// enqueue per terminal with a non-empty command, refs, total.
    private func expectedTimingSteps(for plan: WorkspaceApplyPlan) -> [String] {
        let surfacesById = Dictionary(uniqueKeysWithValues: plan.surfaces.map { ($0.id, $0) })
        var steps = ["validate", "workspace.create"]
        if let metadata = plan.workspace.metadata, !metadata.isEmpty {
            steps.append("metadata.workspace.write")
        }
        var splitIndex = 0
        func walk(_ node: LayoutTreeSpec) {
            switch node {
            case .split(let split):
                steps.append("layout.split[\(splitIndex)].create")
                splitIndex += 1
                walk(split.first)
                walk(split.second)
            case .pane(let area):
                var paneMetadataWritten = false
                for id in area.surfaceIds {
                    steps.append("surface[\(id)].create")
                    steps.append("metadata.surface[\(id)].write")
                    if !paneMetadataWritten,
                       let paneMetadata = surfacesById[id]?.paneMetadata,
                       !paneMetadata.isEmpty {
                        steps.append("metadata.pane[\(id)].write")
                        paneMetadataWritten = true
                    }
                }
            }
        }
        walk(plan.layout)
        for spec in plan.surfaces where spec.kind == .terminal {
            if let command = spec.command, !command.isEmpty {
                steps.append("surface[\(spec.id)].command.enqueue")
            }
        }
        steps.append(contentsOf: ["refs.assemble", "total"])
        return steps
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
        return workspaceManager.workspaces.first { $0.id == uuid }
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
        planPane planArea: LayoutTreeSpec.AreaSpec,
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
        // `ExternalTab.id` is a stringified UUID (bonsplit's external view),
        // but `Workspace.panelIdFromSurfaceId(_:)` is typed on the opaque
        // `TabID` wrapper. Parse the string back to UUID and wrap before
        // looking up — same conversion `WorkspacePlanCapture.panelID(forTabIDString:)`
        // does at the v2 socket boundary.
        let livePlanIds: [String] = livePane.tabs.map { bonsplitTab in
            guard let bonsplitTabUUID = UUID(uuidString: bonsplitTab.id),
                  let panelId = workspace.tabIdFromBonsplitTabId(TabID(uuid: bonsplitTabUUID)),
                  let planId = panelUUIDToPlanId[panelId] else {
                return "unknown(\(bonsplitTab.id))"
            }
            return planId
        }
        XCTAssertEqual(
            livePlanIds,
            planArea.surfaceIds,
            "[\(fixtureName) @ \(path)] pane tab ordering mismatch"
        )

        let expectedSelectedIndex = planArea.selectedIndex ?? 0
        if expectedSelectedIndex >= 0, expectedSelectedIndex < planArea.surfaceIds.count {
            let expectedSurfaceId = planArea.surfaceIds[expectedSelectedIndex]
            guard let expectedPanelId = planSurfaceIdToPanelUUID[expectedSurfaceId],
                  let expectedBonsplitTabId = workspace.bonsplitTabIdFromTabId(expectedPanelId) else {
                XCTFail("[\(fixtureName) @ \(path)] could not resolve expected selected surface \(expectedSurfaceId)")
                return
            }
            // `livePane.selectedTabId` is `String?` (bonsplit's external
            // view); `expectedTabId` is `TabID`. Project the wrapper to
            // its canonical UUID-string form so the comparison stays in
            // the same value space.
            XCTAssertEqual(
                livePane.selectedTabId,
                expectedBonsplitTabId.uuid.uuidString,
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
                    PersistedMetadataBridge.encodeValues(WorkspaceMetadataStore.shared.getMetadata(workspaceId: workspace.id).metadata)[key],
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
            let (surfaceMetadata, _) = PanelMetadataStore.shared.getMetadata(
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
                let (livePaneMetadata, _) = AreaMetadataStore.shared.getMetadata(
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
                        // Executor emits: `... pane metadata["<key>"] dropped ...`.
                        // The `["<key>"]` substring is distinctive enough to scope
                        // the assertion to the right key without false positives
                        // from other failures sharing the same code.
                        let keyMatch = "[\"\(key)\"]"
                        XCTAssertTrue(
                            result.failures.contains {
                                $0.code == "mailbox_non_string_value"
                                    && $0.message.contains(keyMatch)
                            },
                            "[\(fixtureName)] surface[\(surfaceSpec.id)] non-string mailbox.\(key) emits ApplyFailure (looking for '\(keyMatch)' in failure messages)"
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

final class WorkspaceColorResolutionTests: XCTestCase {
    func testResolveColorToHexAcceptsValidHex() {
        XCTAssertEqual(
            WorkspaceLayoutExecutor.resolveColorToHex("#1565C0"),
            "#1565C0"
        )
    }

    func testResolveColorToHexNormalizesHexCase() {
        XCTAssertEqual(
            WorkspaceLayoutExecutor.resolveColorToHex("1565c0"),
            "#1565C0"
        )
    }

    func testResolveColorToHexResolvesNamedColor() {
        // "Red" is in the default palette as #C0392B
        let result = WorkspaceLayoutExecutor.resolveColorToHex("Red")
        XCTAssertNotNil(result, "Named palette color 'Red' must resolve to a hex")
        XCTAssertEqual(result, "#C0392B")
    }

    func testResolveColorToHexResolvesNamedColorCaseInsensitive() {
        let lower = WorkspaceLayoutExecutor.resolveColorToHex("red")
        let upper = WorkspaceLayoutExecutor.resolveColorToHex("RED")
        XCTAssertNotNil(lower)
        XCTAssertEqual(lower, upper)
    }

    func testResolveColorToHexReturnsNilForUnknownName() {
        XCTAssertNil(
            WorkspaceLayoutExecutor.resolveColorToHex("NotAColorName"),
            "Unknown color name must return nil"
        )
    }
}
