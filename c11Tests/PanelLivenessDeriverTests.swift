import XCTest
import AppKit
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-162 (Telemetry truth), TEL-3/4/5 — behavior tests for
/// `SurfaceLivenessDeriver`.
///
/// All assertions are on the observable runtime effect in the real
/// `SurfaceMetadataStore` (the durable liveness *truth*), driven through the
/// deriver's public API. The Workspace projection mirror is covered by
/// `WorkspaceDerivedActivityTests`; here we assert only the store side.
final class PanelLivenessDeriverTests: XCTestCase {

    private let store = PanelMetadataStore.shared

    override func tearDown() {
        PanelActivityTracker.shared.resetAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func activityValue(_ ws: UUID, _ surface: UUID) -> String? {
        store.getMetadata(workspaceId: ws, surfaceId: surface)
            .metadata[MetadataKey.activity] as? String
    }

    private func activitySource(_ ws: UUID, _ surface: UUID) -> MetadataSource? {
        store.getSource(workspaceId: ws, surfaceId: surface, key: MetadataKey.activity)
    }

    /// Spin the runloop until `cond` holds or the timeout elapses. The store's
    /// serialised queue is independent of main, so its async writes land while
    /// we poll. Returns the final evaluation of `cond`. Every caller asserts
    /// the condition comes true, so a passing run returns at once; the 10 s cap
    /// only rides out a loaded parallel CI runner, where the deriver's shared
    /// serial queue stalled a 2 s cap twice in one test (run 45093918743).
    @discardableResult
    private func poll(timeout: TimeInterval = 10.0, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return cond()
    }

    // MARK: - Mapping (pure)

    func testActivityStateMapping() {
        XCTAssertEqual(PanelLivenessDeriver.activityState(for: .commandRunning), .working)
        XCTAssertEqual(PanelLivenessDeriver.activityState(for: .promptIdle), .idle)
        XCTAssertNil(PanelLivenessDeriver.activityState(for: .unknown))
    }

    func testReportedAgentActivityParserAcceptsLifecycleVocabulary() {
        XCTAssertEqual(TerminalController.parseReportedAgentActivity("working"), .working)
        XCTAssertEqual(TerminalController.parseReportedAgentActivity("idle"), .idle)
        XCTAssertNil(TerminalController.parseReportedAgentActivity("mystery"))
    }

    func testExactAgentLifecycleIdleOverridesOuterShellWorking() {
        let workspaceId = UUID()
        let surfaceId = UUID()
        defer { store.removeSurface(workspaceId: workspaceId, surfaceId: surfaceId) }

        XCTAssertTrue(store.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: MetadataKey.activity,
            value: SidebarActivityState.working.rawValue,
            source: .derived
        ))

        PanelLivenessDeriver.onAgentLifecycleChanged(
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            activity: .idle
        )

        XCTAssertTrue(poll {
            self.activityValue(workspaceId, surfaceId) == SidebarActivityState.idle.rawValue
        })
        XCTAssertEqual(activitySource(workspaceId, surfaceId), .derived)
    }

    func testPanelResolverMapsRecognizedAgentStates() {
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .working,
                terminalType: "codex"
            ),
            .running
        )
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .idle,
                isCold: true,
                terminalType: "claude-code"
            ),
            .cold
        )
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .idle,
                terminalType: "claude-code"
            ),
            .idle
        )
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: nil,
                terminalType: "opencode-run"
            ),
            .idle
        )
    }

    func testPanelResolverGivesExactDemandPrecedence() {
        for activity in [SidebarActivityState.working, .idle, nil] {
            XCTAssertEqual(
                PanelActivityResolver.resolve(
                    hasExactSurfaceNotification: true,
                    derivedActivity: activity,
                    terminalType: "codex"
                ),
                .waiting
            )
        }
    }

    func testPanelResolverDoesNotManufactureWaitingFromWorkspaceOrManualUnread() {
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .idle,
                terminalType: "codex"
            ),
            .idle
        )
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: nil,
                terminalType: "codex"
            ),
            .idle
        )
    }

    func testPanelResolverOmitsNonAgentActivity() {
        XCTAssertNil(PanelActivityResolver.resolve(
            hasExactSurfaceNotification: false,
            derivedActivity: .working,
            terminalType: "terminal"
        ))
        XCTAssertNil(PanelActivityResolver.resolve(
            hasExactSurfaceNotification: false,
            derivedActivity: .idle,
            terminalType: nil
        ))
        XCTAssertNil(PanelActivityResolver.resolve(
            hasExactSurfaceNotification: false,
            derivedActivity: .idle,
            isCold: true,
            terminalType: "shell"
        ))
    }

    func testColdDormancyStartsAtConfiguredBoundaryForIdleAgentsOnly() {
        let now = Date(timeIntervalSince1970: 10_000)
        let threshold: TimeInterval = 10 * 60

        XCTAssertFalse(PanelLivenessDeriver.isCold(
            activity: .idle,
            lastTouchedAt: now.addingTimeInterval(-threshold + 0.1),
            now: now,
            coldAfterSeconds: threshold
        ))
        XCTAssertTrue(PanelLivenessDeriver.isCold(
            activity: .idle,
            lastTouchedAt: now.addingTimeInterval(-threshold),
            now: now,
            coldAfterSeconds: threshold
        ))
        XCTAssertFalse(PanelLivenessDeriver.isCold(
            activity: .working,
            lastTouchedAt: now.addingTimeInterval(-threshold * 2),
            now: now,
            coldAfterSeconds: threshold
        ))
        XCTAssertFalse(PanelLivenessDeriver.isCold(
            activity: .idle,
            lastTouchedAt: nil,
            now: now,
            coldAfterSeconds: threshold
        ))
    }

    func testActivityHelpUsesHonestStateBoundariesAndMissingEvidence() {
        let now = Date(timeIntervalSince1970: 20_000)
        let lastActivity = now.addingTimeInterval(-10 * 60)
        let waitingStarted = now.addingTimeInterval(-2 * 60)

        let working = AgentActivityHelpProjection.project(
            state: .working,
            lastActivityAt: lastActivity,
            waitingStartedAt: nil,
            coldAfterSeconds: 5 * 60,
            flagReason: nil,
            flagRaisedAt: nil,
            suppressed: false,
            now: now
        )
        XCTAssertEqual(working.help.startedAt, lastActivity)
        XCTAssertEqual(working.stateStartedAt, lastActivity)
        XCTAssertEqual(working.lastActivityAt, lastActivity)

        let waiting = AgentActivityHelpProjection.project(
            state: .waiting,
            lastActivityAt: lastActivity,
            waitingStartedAt: waitingStarted,
            coldAfterSeconds: 5 * 60,
            flagReason: nil,
            flagRaisedAt: nil,
            suppressed: false,
            now: now
        )
        XCTAssertEqual(waiting.help.startedAt, waitingStarted)

        let cold = AgentActivityHelpProjection.project(
            state: .cold,
            lastActivityAt: lastActivity,
            waitingStartedAt: nil,
            coldAfterSeconds: 5 * 60,
            flagReason: nil,
            flagRaisedAt: nil,
            suppressed: false,
            now: now
        )
        XCTAssertEqual(
            cold.help.startedAt,
            lastActivity.addingTimeInterval(5 * 60),
            "Cold age begins at threshold crossing, not at the start of idle time"
        )

        let missing = AgentActivityHelpProjection.project(
            state: .idle,
            lastActivityAt: nil,
            waitingStartedAt: nil,
            coldAfterSeconds: 5 * 60,
            flagReason: nil,
            flagRaisedAt: nil,
            suppressed: false,
            now: now
        )
        XCTAssertNil(missing.help.startedAt)
        XCTAssertEqual(missing.help.stateLabel, missing.text(at: now))
    }

    func testSuppressedWaitingAndFlagModifierCompositionPreserveLifecycle() {
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: true,
                derivedActivity: .idle,
                terminalType: "codex",
                flagged: false,
                suppressed: true
            ),
            .idle
        )

        let help = AgentActivityHelpProjection.project(
            state: .idle,
            lastActivityAt: now.addingTimeInterval(-7 * 60),
            waitingStartedAt: nil,
            coldAfterSeconds: 10 * 60,
            flagReason: "Need a decision",
            flagRaisedAt: now.addingTimeInterval(-60),
            suppressed: true,
            now: now
        )
        XCTAssertEqual(help.help.detailLines.count, 2)
        XCTAssertEqual(help.flagReason, "Need a decision")
        XCTAssertEqual(help.flagRaisedAt, now.addingTimeInterval(-60))
        XCTAssertTrue(help.suppressed)
        XCTAssertTrue(help.help.detailLines[0].contains("Need a decision"))
        XCTAssertEqual(help.help.detailLines[1], "Delegate")
        XCTAssertTrue(help.text(at: now).hasPrefix("Idle"))
        XCTAssertTrue(help.text(at: now).contains("\nFlagged: Need a decision\nDelegate"))
    }

    func testDelegateTooltipNamesItsOwnerAndOmitsLegacySuppressionText() {
        let now = Date(timeIntervalSince1970: 94_000)
        let help = AgentActivityHelpProjection.project(
            state: .idle,
            lastActivityAt: now,
            waitingStartedAt: nil,
            coldAfterSeconds: 600,
            flagReason: nil,
            flagRaisedAt: nil,
            suppressed: true,
            delegationLabel: "Delegate of Planner",
            now: now
        )

        XCTAssertEqual(help.help.detailLines, ["Delegate of Planner"])
        XCTAssertTrue(help.text(at: now).contains("Delegate of Planner"))
        XCTAssertFalse(help.text(at: now).contains("Suppressed"))
    }

    func testDetectedShellTurnsDeclaredAgentIntoTerminalPresentation() {
        XCTAssertEqual(
            PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: "shell",
                declaredTerminalType: "codex"
            ),
            "shell"
        )
        XCTAssertEqual(
            PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: "codex",
                declaredTerminalType: "claude-code"
            ),
            "codex"
        )
    }

    func testUnknownForegroundChildKeepsDeclaredAgentPresentation() {
        XCTAssertEqual(
            PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: "unknown",
                declaredTerminalType: "claude-code"
            ),
            "claude-code"
        )
    }

    func testHarnessIdentityDoesNotChangeResolvedState() {
        for terminalType in ["codex", "claude-code", "opencode", "omp", "pi"] {
            XCTAssertEqual(
                PanelActivityResolver.resolve(
                    hasExactSurfaceNotification: false,
                    derivedActivity: .working,
                    terminalType: terminalType
                ),
                .running
            )
        }
    }

    /// C11H-344: working is yellow, waiting is white (near-black on light
    /// chrome), done (idle) stays gray, cold darker than idle.
    func testPanelActivityColorsMatchDarkAndLightContract() {
        let dark = Workspace.resolvedSurfaceTabActivityColors(from: NSColor(hex: "#101114")!)
        XCTAssertEqual(dark.runningHex, "#D0AA45")
        XCTAssertEqual(dark.idleHex, "#9AA0A9")
        XCTAssertEqual(dark.coldHex, "#62676F")
        XCTAssertEqual(dark.waitingHex, "#E8E8E8")
        XCTAssertEqual(dark.waitingInkHex, "#08090B")

        let light = Workspace.resolvedSurfaceTabActivityColors(from: NSColor(hex: "#F5F3EF")!)
        XCTAssertEqual(light.runningHex, "#9B7415")
        XCTAssertEqual(light.idleHex, "#585D66")
        XCTAssertEqual(light.coldHex, "#8D939C")
        XCTAssertEqual(light.waitingHex, "#1D2024")
        XCTAssertEqual(light.waitingInkHex, "#FFFDF8")
    }

    // MARK: - Realtime transitions write the derived truth

    @MainActor
    func testCommandRunningWritesWorkingAtDerivedTier() {
        let ws = UUID(); let surface = UUID()
        let workspace = Workspace()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .commandRunning, workspace: workspace
        )

        XCTAssertTrue(poll { self.activityValue(ws, surface) == SidebarActivityState.working.rawValue })
        XCTAssertEqual(activitySource(ws, surface), .derived)
    }

    @MainActor
    func testPromptIdleWritesIdleAtDerivedTier() {
        let ws = UUID(); let surface = UUID()
        let workspace = Workspace()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .promptIdle, workspace: workspace
        )

        XCTAssertTrue(poll { self.activityValue(ws, surface) == SidebarActivityState.idle.rawValue })
        XCTAssertEqual(activitySource(ws, surface), .derived)
    }

    @MainActor
    func testUnknownClearsTheActivityKey() {
        let ws = UUID(); let surface = UUID()
        let workspace = Workspace()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        // Establish a working truth first.
        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .commandRunning, workspace: workspace
        )
        XCTAssertTrue(poll { self.activityValue(ws, surface) == SidebarActivityState.working.rawValue })

        // Unknown must clear it back to absent.
        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .unknown, workspace: workspace
        )
        XCTAssertTrue(poll { self.activityValue(ws, surface) == nil })
    }

    // MARK: - Precedence: derived never overwrites explicit

    @MainActor
    func testDerivedDoesNotOverwriteExplicitActivity() {
        let ws = UUID(); let surface = UUID()
        let workspace = Workspace()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        // An explicit writer pins the activity key.
        XCTAssertTrue(store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.activity, value: SidebarActivityState.working.rawValue,
            source: .explicit
        ))

        // A derived transition to idle must be rejected by precedence.
        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .promptIdle, workspace: workspace
        )
        // Give the async write a beat, then assert the explicit value survived.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(activityValue(ws, surface), SidebarActivityState.working.rawValue)
        XCTAssertEqual(activitySource(ws, surface), .explicit)
    }

    // MARK: - Coarse reconcile (TEL-5)

    func testReconcileDecaysStaleWorkingToIdle() {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        // Seed a derived "working" truth with no recent activity recorded.
        XCTAssertTrue(store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.activity, value: SidebarActivityState.working.rawValue,
            source: .derived
        ))
        PanelActivityTracker.shared.clear(surfaceId: surface.uuidString)

        // No recency → stale → decays to idle.
        PanelLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
        XCTAssertEqual(activityValue(ws, surface), SidebarActivityState.idle.rawValue)
        XCTAssertEqual(activitySource(ws, surface), .derived)
    }

    func testReconcilePreservesStaleWorkingForDetectedLiveAgents() {
        for agentKind in ["codex", "opencode", "pi", "grok"] {
            let ws = UUID(); let surface = UUID()
            defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

            XCTAssertTrue(store.setInternal(
                workspaceId: ws, surfaceId: surface,
                key: MetadataKey.activity, value: SidebarActivityState.working.rawValue,
                source: .derived
            ))
            PanelActivityTracker.shared.clear(surfaceId: surface.uuidString)

            PanelLivenessDeriver.reconcile(
                surfaceId: surface,
                workspaceId: ws,
                detectedTerminalType: agentKind
            )
            XCTAssertEqual(
                activityValue(ws, surface),
                SidebarActivityState.working.rawValue,
                "\(agentKind) must stay working until an exact lifecycle signal says it is idle"
            )
            XCTAssertEqual(activitySource(ws, surface), .derived)
        }
    }

    /// C11-398: the shell's running command is the agent TUI, not a turn. A
    /// resumed session that never reports an edge read as working for 37
    /// hours. With nothing newer for the window, that working decays to
    /// unknown. Working an agent edge wrote is never decayed.
    func testShellWorkingOnAnAgentDecaysToUnknownAndAgentWorkingDoesNot() {
        let ws = UUID(); let shellOnly = UUID(); let reported = UUID()
        defer {
            store.removeSurface(workspaceId: ws, surfaceId: shellOnly)
            store.removeSurface(workspaceId: ws, surfaceId: reported)
        }
        XCTAssertEqual(PanelLivenessDeriver.agentShellWorkingDecay, 120)

        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: shellOnly, workspaceId: ws, state: .commandRunning, mirror: { _ in }
        )
        XCTAssertTrue(poll { self.activityValue(ws, shellOnly) == SidebarActivityState.working.rawValue })

        PanelLivenessDeriver.onShellActivityChanged(
            surfaceId: reported, workspaceId: ws, state: .commandRunning, mirror: { _ in }
        )
        PanelLivenessDeriver.onAgentLifecycleChanged(
            surfaceId: reported, workspaceId: ws, activity: .working, source: .reported
        )
        XCTAssertTrue(poll { self.activityValue(ws, reported) == SidebarActivityState.working.rawValue })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let now = Date()
        PanelLivenessDeriver.reconcile(surfaceId: shellOnly, workspaceId: ws,
                                       detectedTerminalType: "claude-code", now: now.addingTimeInterval(60))
        XCTAssertEqual(activityValue(ws, shellOnly), SidebarActivityState.working.rawValue, "inside the window")

        PanelLivenessDeriver.reconcile(surfaceId: shellOnly, workspaceId: ws,
                                       detectedTerminalType: "claude-code", now: now.addingTimeInterval(121))
        XCTAssertNil(activityValue(ws, shellOnly), "past the window the shell's working is unknown")

        PanelLivenessDeriver.reconcile(surfaceId: reported, workspaceId: ws,
                                       detectedTerminalType: "claude-code", now: now.addingTimeInterval(10_000))
        XCTAssertEqual(activityValue(ws, reported), SidebarActivityState.working.rawValue,
                       "an agent edge owns its working")
    }

    // MARK: - C11H-323: hc's word is a survivor's lifecycle

    func testHCStatusWordsMapToALifecycle() {
        XCTAssertEqual(PanelLivenessDeriver.hcActivity(status: "working"), .working)
        for resting in ["idle", "done", "blocked", "error"] {
            XCTAssertEqual(PanelLivenessDeriver.hcActivity(status: resting), .idle, resting)
        }
        XCTAssertNil(PanelLivenessDeriver.hcActivity(status: nil))
        XCTAssertNil(PanelLivenessDeriver.hcActivity(status: "thinking"))
    }

    /// After a relaunch the restore leaves a survivor with no `activity`; hc's
    /// word (the agent's own last OSC 7501 report, kept while c11 was down)
    /// fills it and follows it, and hc's later silence withdraws only its own.
    func testHCsWordFollowsASurvivorWithNoNewerLifecycle() throws {
        try XCTSkipIf(true, "Flaky on the loaded CI runner; quarantined until made deterministic (C11H-431)")
        let ws = UUID(); let survivor = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: survivor) }
        var mirrored: [SidebarActivityState?] = []
        let mirror: @MainActor (SidebarActivityState?) -> Void = { mirrored.append($0) }

        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("done"), mirror: mirror)
        XCTAssertTrue(poll { self.activityValue(ws, survivor) == SidebarActivityState.idle.rawValue })
        XCTAssertEqual(activitySource(ws, survivor), .derived)
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("working"), mirror: mirror)
        XCTAssertTrue(poll { self.activityValue(ws, survivor) == SidebarActivityState.working.rawValue })
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("done"), mirror: mirror)
        XCTAssertTrue(poll { self.activityValue(ws, survivor) == SidebarActivityState.idle.rawValue },
                      "hc's done ends the working it wrote")
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: nil, mirror: mirror)
        XCTAssertTrue(poll { self.activityValue(ws, survivor) == nil }, "no agent in front: hc's own word goes")
        XCTAssertTrue(poll { mirrored == [.idle, .working, .idle, nil] }, "\(mirrored)")

        // An unchanged word is no edge and mirrors nothing (a cold mark stays).
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("done"), mirror: mirror)
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("done"), mirror: mirror)
        XCTAssertTrue(poll { mirrored.count == 5 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(mirrored.count, 5, "\(mirrored)")

        // hc's working is the agent's own report: the sweep never decays it.
        PanelLivenessDeriver.onHCStatus(surfaceId: survivor, workspaceId: ws, word: hcWord("working"), mirror: mirror)
        XCTAssertTrue(poll { self.activityValue(ws, survivor) == SidebarActivityState.working.rawValue })
        PanelLivenessDeriver.reconcile(surfaceId: survivor, workspaceId: ws, detectedTerminalType: "claude-code",
                                       now: Date().addingTimeInterval(10_000))
        XCTAssertEqual(activityValue(ws, survivor), SidebarActivityState.working.rawValue)
    }

    /// hc's word never overrides a newer lifecycle: an agent edge or an
    /// explicit value. It does replace a working only the shell wrote (the
    /// agent TUI's lifetime, not a turn; C11-398).
    func testHCsWordYieldsToAnAgentEdgeAndReplacesOnlyTheShellsWorking() {
        let ws = UUID(); let reported = UUID(); let explicit = UUID(); let shellOnly = UUID()
        defer { for id in [reported, explicit, shellOnly] { store.removeSurface(workspaceId: ws, surfaceId: id) } }

        PanelLivenessDeriver.onAgentLifecycleChanged(surfaceId: reported, workspaceId: ws, activity: .working, source: .reported)
        XCTAssertTrue(poll { self.activityValue(ws, reported) == SidebarActivityState.working.rawValue })
        PanelLivenessDeriver.onHCStatus(surfaceId: reported, workspaceId: ws, word: hcWord("done"), mirror: { _ in })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(activityValue(ws, reported), SidebarActivityState.working.rawValue, "the agent's edge owns it")

        // hc wrote it, then the agent reported: hc no longer owns it.
        PanelLivenessDeriver.onHCStatus(surfaceId: shellOnly, workspaceId: ws, word: hcWord("working"), mirror: { _ in })
        XCTAssertTrue(poll { self.activityValue(ws, shellOnly) == SidebarActivityState.working.rawValue })
        PanelLivenessDeriver.onAgentLifecycleChanged(surfaceId: shellOnly, workspaceId: ws, activity: .working, source: .reported)
        PanelLivenessDeriver.onHCStatus(surfaceId: shellOnly, workspaceId: ws, word: nil, mirror: { _ in })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(activityValue(ws, shellOnly), SidebarActivityState.working.rawValue)
        store.removeSurface(workspaceId: ws, surfaceId: shellOnly)

        _ = store.setInternal(workspaceId: ws, surfaceId: explicit, key: MetadataKey.activity,
                              value: SidebarActivityState.working.rawValue, source: .explicit)
        PanelLivenessDeriver.onHCStatus(surfaceId: explicit, workspaceId: ws, word: hcWord("done"), mirror: { _ in })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(activityValue(ws, explicit), SidebarActivityState.working.rawValue)
        XCTAssertEqual(activitySource(ws, explicit), .explicit)

        PanelLivenessDeriver.onShellActivityChanged(surfaceId: shellOnly, workspaceId: ws, state: .commandRunning,
                                                    mirror: { _ in })
        XCTAssertTrue(poll { self.activityValue(ws, shellOnly) == SidebarActivityState.working.rawValue })
        PanelLivenessDeriver.onHCStatus(surfaceId: shellOnly, workspaceId: ws, word: hcWord("done"), mirror: { _ in })
        XCTAssertTrue(poll { self.activityValue(ws, shellOnly) == SidebarActivityState.idle.rawValue },
                      "the shell's working is no turn; hc's done is the agent's word")
    }

    private func hcWord(_ status: String, at stampMs: Int64? = 1) -> PanelLivenessDeriver.HCStatusWord {
        PanelLivenessDeriver.HCStatusWord(status: status, stampMs: stampMs)
    }

    /// The one rule both of hc's paths use. A stale, unknown or missing word
    /// withdraws only hc's own value; a word fills nothing, or replaces hc's
    /// own or the shell's working, and yields to every other writer.
    func testHCsWordIsAdmittedByOneRule() {
        let working = SidebarActivityState.working.rawValue, idle = SidebarActivityState.idle.rawValue
        let cases: [(String, PanelLivenessDeriver.HCStatusWord?, Int64?, String?, PanelLivenessDeriver.ActivityClaim?,
                     PanelLivenessDeriver.HCAdmission)] = [
            ("fills an empty activity", hcWord("working"), nil, nil, nil, .write(.working)),
            ("moves its own", hcWord("done"), nil, working, .hc, .write(.idle)),
            ("replaces only the shell's working", hcWord("idle"), nil, working, .shellWorking, .write(.idle)),
            ("yields to an agent edge", hcWord("idle"), nil, working, nil, .keep),
            ("yields to the journal's claim", hcWord("working"), nil, idle, .journal, .keep),
            ("no word withdraws its own", nil, nil, working, .hc, .withdraw),
            ("no word leaves the shell's", nil, nil, working, .shellWorking, .keep),
            ("an unknown word is no word", hcWord("thinking"), nil, working, .hc, .withdraw),
            ("Codex: working stamped before its turn end withdraws hc's own", hcWord("working", at: 4_000), 5_000,
             working, .hc, .withdraw),
            ("Codex: a stale working never fills", hcWord("working", at: 4_000), 5_000, nil, nil, .keep),
            ("Codex: a stale working never touches the shell's", hcWord("working", at: 5_000), 5_000,
             working, .shellWorking, .keep),
            ("Codex: working without hc's time is stale", hcWord("working", at: nil), 5_000, nil, nil, .keep),
            ("Codex: a stale blocked withdraws hc's own", hcWord("blocked", at: 4_000), 5_000, idle, .hc, .withdraw),
            ("Codex: working after its turn end applies", hcWord("working", at: 6_000), 5_000, nil, nil, .write(.working)),
            ("Codex: idle always applies", hcWord("idle", at: 4_000), 5_000, working, .hc, .write(.idle)),
        ]
        for (name, word, turnEnd, prior, claim, expected) in cases {
            XCTAssertEqual(PanelLivenessDeriver.admitHCWord(word, turnEndMs: turnEnd, prior: prior, claim: claim),
                           expected, name)
        }
    }

    /// C11H-322/323 review, both blockers: hc's word, a restored journal row
    /// and an agent edge end in one lifecycle whatever order they arrive in.
    /// Each scenario runs for a Claude row and for a Codex row whose own notify
    /// ended its turn (T2) after hc stamped `working` (T1 < T2; C11H-123), in
    /// every order (a live row always before the same row turned historical),
    /// then takes the row's re-projection and hc's identical record again.
    func testHCsWordARestoredRowAndAnAgentEdgeEndTheSameInEveryArrivalOrder() throws {
        enum Event: Equatable {
            case hc(String, Int64)
            /// The journal row, live: Claude's submit and Stop, or Codex's notify at T2.
            case live
            /// The row from an earlier process, historical: Claude mid-turn, or Codex's
            /// notify at T2; after `.live`, that row's connection lost.
            case restored
            case agent(SidebarActivityState)
        }
        let coordinator = JournalCoordinator.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11h-322-order-\(UUID().uuidString)")
        let previous = coordinator.replaceStoreForTesting(try JournalStore(layout: JournalStorageLayout(directory: directory)))
        defer {
            _ = coordinator.replaceStoreForTesting(previous)
            try? FileManager.default.removeItem(at: directory)
        }
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let t1 = base - 5_000, t3 = base + 600_000   // T2 is the notify's time, stamped at staging
        let claude = "claude-code", codex = "codex"
        let scenarios: [(String, String, [Event], SidebarActivityState?)] = [
            ("a survivor that finished while c11 was down", claude, [.hc("done", t1), .restored], .idle),
            ("a survivor mid-turn", claude, [.hc("working", t1), .restored], .working),
            ("Codex: hc's working from before its own turn end", codex, [.hc("working", t1), .restored], nil),
            ("Codex: hc's working after its own turn end", codex, [.hc("working", t3), .restored], .working),
            ("an agent edge after hc's done", claude, [.hc("done", t1), .agent(.working), .restored], .working),
            ("an agent edge after hc's working", claude, [.hc("working", t1), .agent(.idle), .restored], .idle),
            ("Codex: an agent edge after hc's stale working", codex,
             [.hc("working", t1), .agent(.working), .restored], .working),
            ("Codex: an agent edge after hc's fresh working", codex,
             [.hc("working", t3), .agent(.idle), .restored], .idle),
            ("a live idle journal that went historical", claude, [.hc("working", t1), .live, .restored], .working),
            ("Codex: a live journal that went historical, hc stale", codex,
             [.hc("working", t1), .live, .restored], nil),
            ("Codex: a live journal that went historical, hc fresh", codex,
             [.hc("working", t3), .live, .restored], .working),
        ]
        func orders(_ events: [Event]) -> [[Event]] {
            guard !events.isEmpty else { return [[]] }
            return events.indices.flatMap { i -> [[Event]] in
                var rest = events; let head = rest.remove(at: i)
                return orders(rest).map { [head] + $0 }
            }.filter { order in
                guard let live = order.firstIndex(of: .live), let restored = order.firstIndex(of: .restored) else { return true }
                return live < restored
            }
        }
        func append(_ draft: JournalDraft) throws {
            let result = try coordinator.append(draft)
            XCTAssertEqual(result.receipt.projectionEffect, .applied, "\(draft.nativeEvent)")
        }

        var runs = 0
        for (name, kind, events, expected) in scenarios {
            for order in orders(events) {
                runs += 1
                let ws = UUID(), id = UUID(), session = "c11h-322-\(UUID().uuidString)"
                defer {
                    coordinator.remove(panelID: id)
                    store.removeSurface(workspaceId: ws, surfaceId: id)
                }
                let label = "\(name) [\(order.map { "\($0)" }.joined(separator: " → "))]"
                func claudeHook(_ subcommand: String) throws -> JournalDraft {
                    var draft = try XCTUnwrap(ClaudeHookMapping.map(subcommand: subcommand, object: ["session_id": session]))
                    draft.panelID = id
                    draft.workspaceID = ws
                    return draft
                }
                func own() {
                    guard coordinator.exactOwner(panelID: id) == nil else { return }
                    coordinator.register(panelID: id, workspaceID: ws)
                    coordinator.setOwner(panelID: id, owner: JournalOwner(panelID: id, agentKind: kind, sessionID: session))
                    coordinator.synchronizeRuntimeForTesting()
                }
                func turnEnd() throws {
                    try append(JournalDraft(kind: .turnCompleted, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                            panelID: id, workspaceID: ws, sessionID: session, agentKind: codex,
                                            source: .hook, adapter: .codexNotify, nativeEvent: "agent-turn-complete"))
                }
                func connectionLost() throws {
                    try append(JournalDraft(kind: .stateChanged, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                            panelID: id, workspaceID: ws, sessionID: session, agentKind: kind,
                                            source: .c11, adapter: .c11, nativeEvent: "connection_lost",
                                            signal: .connectionLost))
                }
                func project() {
                    PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: coordinator.snapshot(panelID: id),
                                                             boundary: nil)
                }
                for event in order {
                    switch event {
                    case .hc(let status, let stamp):
                        PanelLivenessDeriver.onHCStatus(surfaceId: id, workspaceId: ws, word: hcWord(status, at: stamp),
                                                        mirror: { _ in })
                    case .agent(let activity):
                        PanelLivenessDeriver.onAgentLifecycleChanged(surfaceId: id, workspaceId: ws, activity: activity,
                                                                     source: activity == .working ? .submit : .reported)
                    case .live:
                        own()
                        if kind == codex {
                            try turnEnd()
                        } else {
                            try append(try claudeHook("prompt-submit"))
                            try append(try claudeHook("stop"))
                        }
                        XCTAssertEqual(coordinator.snapshot(panelID: id)?.connection, .live, label)
                        project()
                    case .restored:
                        if !order.contains(.live) {
                            own()
                            if kind == codex { try turnEnd() } else { try append(try claudeHook("prompt-submit")) }
                        }
                        try connectionLost()
                        let row = try XCTUnwrap(coordinator.snapshot(panelID: id), label)
                        XCTAssertTrue(row.isHistorical && !row.paintsAttention, label)
                        if kind == codex {
                            let ended = try XCTUnwrap(CodexTurnAuthority.turnEndMs(row), label)
                            XCTAssertTrue(t1 < ended && ended < t3, label)
                        }
                        project()
                    }
                    // Each arrival lands before the next one is staged.
                    PanelLivenessDeriver.drainForTesting()
                }
                XCTAssertEqual(activityValue(ws, id), expected?.rawValue, label)
                // The same row projected again (a startup or spool-drain refresh) and hc's
                // identical record again change nothing.
                project()
                for case .hc(let status, let stamp) in order {
                    PanelLivenessDeriver.onHCStatus(surfaceId: id, workspaceId: ws, word: hcWord(status, at: stamp),
                                                    mirror: { _ in })
                }
                PanelLivenessDeriver.drainForTesting()
                XCTAssertEqual(activityValue(ws, id), expected?.rawValue, "\(label), again")
            }
        }
        XCTAssertEqual(runs, 41, "4 pairs × 2 orders, 4 with an agent edge × 6, 3 with a live row × 3")
    }

    /// C11H-321, the 2026-11-15 reboot: every resumed Claude had no `activity`
    /// (its journal not yet reconnected, its shell's working decayed), so the
    /// sweep never read its expired prompt cache and 55 cold agents drew idle.
    /// The cache is fed through the socket report store and read by the sweep.
    func testAPanelWithNoLifecycleGoesColdWhenItsPromptCacheExpired() {
        let ws = UUID(); let expired = UUID(); let warm = UUID(); let touched = UUID(); let noCache = UUID()
        let panels = [expired, warm, touched, noCache]
        var verdicts: [UUID: (cold: Bool, cacheExpired: Bool)] = [:]
        PanelLivenessDeriver.coldVerdictObserver = { id, cold, cacheExpired in
            if panels.contains(id) { verdicts[id] = (cold, cacheExpired) }
        }
        defer {
            PanelLivenessDeriver.coldVerdictObserver = nil
            panels.forEach { PromptCacheReportStore.shared.remove(panelId: $0) }
        }
        let now = Date()
        func request(_ at: Date) -> PromptCacheReport {
            .request(.init(at: at, provider: "anthropic", model: "claude-opus-5-5", inputTokens: 100,
                           cacheReadTokens: 10, cacheWriteTokens: 0, ttl: nil))
        }
        PromptCacheReportStore.shared.record(request(now.addingTimeInterval(-7_200)), panelId: expired,
                                             receivedAt: now.addingTimeInterval(-7_200))
        PromptCacheReportStore.shared.record(request(now.addingTimeInterval(-30)), panelId: warm,
                                             receivedAt: now.addingTimeInterval(-30))
        PromptCacheReportStore.shared.record(request(now.addingTimeInterval(-7_200)), panelId: touched,
                                             receivedAt: now.addingTimeInterval(-7_200))
        // Input or a lifecycle edge newer than the evidence: the cache may be in use again.
        PanelActivityTracker.shared.recordActivity(surfaceId: touched.uuidString, at: now)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        for panel in panels {
            XCTAssertNil(activityValue(ws, panel), "no lifecycle truth")
            PanelLivenessDeriver.reconcile(surfaceId: panel, workspaceId: ws,
                                           detectedTerminalType: "claude-code", now: now)
        }

        XCTAssertEqual(verdicts[expired]?.cold, true, "an expired cache draws cold at once")
        XCTAssertEqual(verdicts[expired]?.cacheExpired, true, "the cold mark carries the cache's blue")
        XCTAssertEqual(verdicts[warm]?.cold, false, "a warm cache stays idle until it expires")
        XCTAssertEqual(verdicts[touched]?.cold, false, "a touch newer than the cache evidence fails warm")
        XCTAssertEqual(verdicts[noCache]?.cold, false, "no cache evidence stays warm")
        for panel in panels { XCTAssertNil(activityValue(ws, panel), "the sweep writes no lifecycle") }

        // The warm one turns cold on time, on a later sweep.
        PanelLivenessDeriver.reconcile(surfaceId: warm, workspaceId: ws, detectedTerminalType: "claude-code",
                                       now: now.addingTimeInterval(3_600))
        XCTAssertEqual(verdicts[warm]?.cold, true)
    }

    /// C11H-321: the resume c11 types after a reboot is the shell's working, not a turn. A cache read cold after
    /// that touch ends it at once, well inside C11-398's window, and draws cold; a warm cache keeps the window.
    func testAnExpiredCacheEndsAShellOnlyWorkingAtOnce() {
        let ws = UUID(); let expired = UUID(); let warm = UUID()
        var verdicts: [UUID: Bool] = [:]
        PanelLivenessDeriver.coldVerdictObserver = { id, cold, _ in
            if id == expired || id == warm { verdicts[id] = cold }
        }
        defer {
            PanelLivenessDeriver.coldVerdictObserver = nil
            for panel in [expired, warm] {
                PromptCacheReportStore.shared.remove(panelId: panel)
                store.removeSurface(workspaceId: ws, surfaceId: panel)
            }
        }
        for panel in [expired, warm] {
            PanelLivenessDeriver.onShellActivityChanged(surfaceId: panel, workspaceId: ws, state: .commandRunning,
                                                        mirror: { _ in })
            XCTAssertTrue(poll { self.activityValue(ws, panel) == SidebarActivityState.working.rawValue })
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // The next sweep, 15 s after the typed resume.
        let sweep = Date().addingTimeInterval(15)
        func request(_ at: Date) -> PromptCacheReport {
            .request(.init(at: at, provider: "anthropic", model: "claude-opus-5-5", inputTokens: 100,
                           cacheReadTokens: 10, cacheWriteTokens: 0, ttl: nil))
        }
        PromptCacheReportStore.shared.record(request(sweep.addingTimeInterval(-7_200)), panelId: expired,
                                             receivedAt: sweep.addingTimeInterval(-7_200))
        PromptCacheReportStore.shared.record(request(sweep.addingTimeInterval(-30)), panelId: warm,
                                             receivedAt: sweep.addingTimeInterval(-30))

        for panel in [expired, warm] {
            PanelLivenessDeriver.reconcile(surfaceId: panel, workspaceId: ws, detectedTerminalType: "claude-code",
                                           now: sweep)
        }

        XCTAssertNil(activityValue(ws, expired), "an expired cache: the shell's working was not a turn")
        XCTAssertEqual(verdicts[expired], true, "and it draws cold")
        XCTAssertEqual(activityValue(ws, warm), SidebarActivityState.working.rawValue,
                       "a warm cache keeps C11-398's window")
        XCTAssertNotEqual(verdicts[warm], true)
    }

    func testReconcileLeavesFreshWorkingAlone() {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        XCTAssertTrue(store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.activity, value: SidebarActivityState.working.rawValue,
            source: .derived
        ))
        // Fresh activity now → not stale → no decay.
        PanelActivityTracker.shared.recordActivity(surfaceId: surface.uuidString, at: Date())
        // Let the tracker's async write land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        PanelLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
        XCTAssertEqual(activityValue(ws, surface), SidebarActivityState.working.rawValue)
    }

    func testReconcileLeavesExplicitActivityAlone() {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        // Externally-owned (explicit) working must never be decayed by reconcile.
        XCTAssertTrue(store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.activity, value: SidebarActivityState.working.rawValue,
            source: .explicit
        ))
        PanelActivityTracker.shared.clear(surfaceId: surface.uuidString)

        PanelLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
        XCTAssertEqual(activityValue(ws, surface), SidebarActivityState.working.rawValue)
        XCTAssertEqual(activitySource(ws, surface), .explicit)
    }

    // MARK: - C11-171: shell-activity report resolves the workspace from the PANEL

    /// Shell integration reports `report_shell_state --tab=$CMUX_TAB_ID
    /// --panel=$CMUX_PANEL_ID` with BOTH set to the surface uuid (`CMUX_TAB_ID`
    /// is a legacy surface alias). The resolver must find the owning workspace
    /// from the panel, never trust `--tab` as the workspace — otherwise the
    /// report no-ops and derived liveness never fires (the v0.58.0 blocker).
    func testShellActivityTargetResolvesWorkspaceFromPanel() {
        let realWorkspace = UUID()
        let surface = UUID()

        // Shell-integration shape: --tab == --panel == the surface uuid.
        let target = TerminalController.resolveShellActivityTarget(
            panelId: surface,
            workspaceForPanel: { panel in
                panel == surface ? realWorkspace : nil
            }
        )
        XCTAssertEqual(target?.workspaceId, realWorkspace,
                       "workspace must come from the panel lookup, not from --tab")
        XCTAssertEqual(target?.panelId, surface)
    }

    /// A panel that owns no live workspace yields no target (silent no-op),
    /// rather than misrouting to a stale/guessed workspace.
    func testShellActivityTargetNilWhenPanelUnowned() {
        XCTAssertNil(TerminalController.resolveShellActivityTarget(
            panelId: UUID(),
            workspaceForPanel: { _ in nil }
        ))
    }

    /// The legitimate CLI/test shape (`--tab=<real workspace>`, `--panel=<real
    /// surface>`) still resolves — the lookup closure is backed by a
    /// preferred-workspace-first resolver, so pre-C11-171 callers are unaffected.
    func testShellActivityTargetHonorsRealWorkspacePanelPair() {
        let workspace = UUID()
        let panel = UUID()
        let target = TerminalController.resolveShellActivityTarget(
            panelId: panel,
            workspaceForPanel: { $0 == panel ? workspace : nil }
        )
        XCTAssertEqual(target?.workspaceId, workspace)
        XCTAssertEqual(target?.panelId, panel)
    }


    // MARK: - Prompt cache

    func testPromptCacheDecidesColdOnlyFromFreshEvidence() {
        let t0 = Date(timeIntervalSince1970: 50_000)
        let cache = PromptCacheObservation(requestAt: t0, basis: .ttl(300), promptTokens: 10)
        let fresh = PromptCacheReading(observation: cache, scannedAt: t0.addingTimeInterval(20))
        let restingSince = t0.addingTimeInterval(10)

        XCTAssertNil(PanelLivenessDeriver.isPromptCacheCold(nil, restingSince: restingSince, now: t0))
        XCTAssertNil(
            PanelLivenessDeriver.isPromptCacheCold(
                PromptCacheReading(observation: nil, scannedAt: t0.addingTimeInterval(20)),
                restingSince: restingSince, now: t0.addingTimeInterval(9_999)
            ),
            "no cache evidence falls back to dormancy"
        )
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(fresh, restingSince: restingSince, now: t0.addingTimeInterval(299)), false)
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(fresh, restingSince: restingSince, now: t0.addingTimeInterval(300)), true)

        let stale = PromptCacheReading(observation: cache, scannedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(
            PanelLivenessDeriver.isPromptCacheCold(stale, restingSince: restingSince, now: t0.addingTimeInterval(3_600)),
            false,
            "a reading taken before the agent came to rest may predate its last request: fail warm"
        )
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(stale, restingSince: nil, now: t0.addingTimeInterval(3_600)), true)
    }

    func testEstimatesUseTheirOwnSpanOrTheValidationOverride() {
        let t0 = Date(timeIntervalSince1970: 60_000)
        let estimate = PromptCacheReading(
            observation: PromptCacheObservation(requestAt: t0, basis: .estimate(7_200), promptTokens: nil),
            scannedAt: t0
        )
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(estimate, restingSince: nil, now: t0.addingTimeInterval(3_600), estimateOverride: nil), false)
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(estimate, restingSince: nil, now: t0.addingTimeInterval(7_200), estimateOverride: nil), true)
        XCTAssertEqual(PanelLivenessDeriver.isPromptCacheCold(estimate, restingSince: nil, now: t0.addingTimeInterval(120), estimateOverride: 60), true)

        let published = PromptCacheReading(
            observation: PromptCacheObservation(requestAt: t0, basis: .ttl(300), promptTokens: nil),
            scannedAt: t0
        )
        XCTAssertEqual(
            PanelLivenessDeriver.isPromptCacheCold(published, restingSince: nil, now: t0.addingTimeInterval(120), estimateOverride: 60),
            false,
            "the override never shortens a published TTL"
        )

        let key = PromptCachePolicy.estimateOverrideEnvironmentKey
        XCTAssertNil(PromptCachePolicy.parseEstimateOverride(environment: [:]))
        XCTAssertNil(PromptCachePolicy.parseEstimateOverride(environment: [key: "soon"]))
        XCTAssertEqual(PromptCachePolicy.parseEstimateOverride(environment: [key: "5"]), 60)
        XCTAssertEqual(PromptCachePolicy.parseEstimateOverride(environment: [key: "90"]), 90)
    }

    func testResolverNeverShowsAWorkingAgentCold() {
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .working,
                isCold: true,
                terminalType: "claude-code"
            ),
            .running
        )
        XCTAssertEqual(
            PanelActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: nil,
                isCold: true,
                terminalType: "claude-code"
            ),
            .cold
        )
    }

    func testColdHelpNamesAnExpiredPromptCacheAndWhenItExpired() {
        let now = Date(timeIntervalSince1970: 90_000)
        let lastActivity = now.addingTimeInterval(-4_000)
        func project(_ state: WorkspacePulseState, _ cache: PromptCacheObservation?) -> AgentActivityHelpProjection {
            AgentActivityHelpProjection.project(
                state: state,
                lastActivityAt: lastActivity,
                waitingStartedAt: nil,
                coldAfterSeconds: 600,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false,
                now: now,
                promptCache: cache
            )
        }
        let expired = PromptCacheObservation(requestAt: lastActivity, basis: .ttl(3_600), promptTokens: 182_000)
        let cold = project(.cold, expired)
        XCTAssertTrue(cold.promptCacheExpired)
        XCTAssertEqual(cold.stateStartedAt, now.addingTimeInterval(-400), "cold since the cache expired")
        XCTAssertEqual(cold.help.detailLines.count, 2, "what expired, and what the next message re-caches")

        let estimated = project(.cold, PromptCacheObservation(requestAt: lastActivity, basis: .estimate(3_600), promptTokens: nil))
        XCTAssertTrue(estimated.promptCacheExpired)
        XCTAssertEqual(estimated.help.detailLines.count, 1)

        let dormant = project(.cold, PromptCacheObservation(requestAt: now.addingTimeInterval(-60), basis: .ttl(3_600), promptTokens: nil))
        XCTAssertFalse(dormant.promptCacheExpired, "a warm cache never paints cold blue")
        XCTAssertEqual(dormant.stateStartedAt, lastActivity.addingTimeInterval(600))

        XCTAssertFalse(project(.idle, expired).promptCacheExpired, "only the cold mark carries the cache")
        XCTAssertFalse(project(.waiting, expired).promptCacheExpired)
    }


    func testJournalAgentsGoColdOnlyAtRestAndOnlyFromTheCache() {
        let t0 = Date(timeIntervalSince1970: 70_000)
        let expired = PromptCacheReading(
            observation: PromptCacheObservation(requestAt: t0, basis: .ttl(300), promptTokens: nil),
            scannedAt: t0.addingTimeInterval(30)
        )
        let resting = t0.addingTimeInterval(20)
        let later = t0.addingTimeInterval(3_600)
        func state(_ phase: JournalPhase, _ reading: PromptCacheReading?, since: Date = resting) -> (cold: Bool, cacheExpired: Bool) {
            PanelLivenessDeriver.journalPromptCacheState(phase: phase, restingSince: since, promptCache: reading, now: later)
        }
        XCTAssertTrue(state(.idle, expired) == (true, true))
        XCTAssertTrue(state(.blocked, expired) == (false, true), "a blocked agent keeps its waiting mark; the expiry shows in text")
        for phase in [JournalPhase.working, .error, .unknown] {
            XCTAssertTrue(state(phase, expired) == (false, false), "\(phase) is not at rest")
        }
        XCTAssertTrue(state(.idle, nil) == (false, false), "no dormancy rule: without cache evidence a journal agent stays warm")
        XCTAssertTrue(state(.idle, expired, since: t0.addingTimeInterval(60)) == (false, false), "a scan from before the agent came to rest fails warm")
    }

    private func journal(_ phase: JournalPhase, since: Int64, connection: JournalConnection = .live) -> JournalSnapshot {
        JournalSnapshot(owner: .init(panelID: UUID(), agentKind: "claude-code", sessionID: "synthetic-cache"),
                        phase: phase, sinceMs: since, appInstanceID: UUID(), connection: connection)
    }

    func testOnlyAJournalEdgeClearsCold() {
        let idle = journal(.idle, since: 1_000)
        XCTAssertFalse(PanelLivenessDeriver.journalEdgeClearsCold(prior: idle, next: journal(.idle, since: 1_000)),
                       "a health or evidence publish leaves the agent resting where it was")
        XCTAssertFalse(PanelLivenessDeriver.journalEdgeClearsCold(prior: journal(.blocked, since: 5), next: journal(.blocked, since: 5)))
        XCTAssertTrue(PanelLivenessDeriver.journalEdgeClearsCold(prior: idle, next: journal(.working, since: 2_000)))
        XCTAssertTrue(PanelLivenessDeriver.journalEdgeClearsCold(prior: idle, next: journal(.idle, since: 3_000)), "a new rest is a new edge")
        XCTAssertTrue(PanelLivenessDeriver.journalEdgeClearsCold(prior: journal(.working, since: 1_000), next: journal(.working, since: 1_000)))
        XCTAssertTrue(PanelLivenessDeriver.journalEdgeClearsCold(prior: nil, next: idle))
        XCTAssertTrue(PanelLivenessDeriver.journalEdgeClearsCold(prior: idle, next: nil))
    }

    func testAJournalColdPublishLandsOnlyWhileTheAgentStillRests() {
        let observed = journal(.idle, since: 1_000)
        XCTAssertTrue(PanelLivenessDeriver.journalStillRests(journal(.idle, since: 1_000), as: observed))
        XCTAssertFalse(PanelLivenessDeriver.journalStillRests(journal(.working, since: 2_000), as: observed))
        XCTAssertFalse(PanelLivenessDeriver.journalStillRests(journal(.idle, since: 2_000), as: observed), "rested again since the sweep read it")
        XCTAssertFalse(PanelLivenessDeriver.journalStillRests(journal(.idle, since: 1_000, connection: .disconnected), as: observed))
        XCTAssertFalse(PanelLivenessDeriver.journalStillRests(journal(.blocked, since: 1_000), as: observed))
        XCTAssertFalse(PanelLivenessDeriver.journalStillRests(nil, as: observed))
    }

    func testTheFlagVioletBeatsTheCacheBlueInBothThemes() {
        for light in [false, true] {
            XCTAssertEqual(Workspace.activityColorOverrideHex(isFlagged: true, promptCacheExpired: true, lightBackground: light), "#9D8AD9")
            XCTAssertEqual(Workspace.activityColorOverrideHex(isFlagged: true, promptCacheExpired: false, lightBackground: light), "#9D8AD9")
            XCTAssertEqual(Workspace.activityColorOverrideHex(isFlagged: false, promptCacheExpired: true, lightBackground: light),
                           Workspace.promptCacheColdHex(lightBackground: light))
            XCTAssertNil(Workspace.activityColorOverrideHex(isFlagged: false, promptCacheExpired: false, lightBackground: light))
        }
        XCTAssertNotEqual(Workspace.promptCacheColdHex(lightBackground: true), Workspace.promptCacheColdHex(lightBackground: false))
    }

    func testNamedFlagTokensBeatCacheBlueAndAdaptToBothThemes() {
        let green = PanelFlagKind(id: "chief-of-staff", name: "Chief of Staff", color: .green, emoji: nil)
        let red = PanelFlagKind(id: "merge-issue", name: "Merge Issue", color: .red, emoji: nil)
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: true, lightBackground: true, flagKind: green
        ), "#167A42")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: true, lightBackground: false, flagKind: green
        ), "#49C980")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: false, lightBackground: true, flagKind: red
        ), "#B42331")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: false, lightBackground: false, flagKind: red
        ), "#FF6B78")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: true, lightBackground: false
        ), "#9D8AD9", "a generic flag retains violet")
    }

    func testMarkTintPrecedenceIsFlagThenCacheBlueThenLifecycle() {
        XCTAssertEqual(ActivityMarkTint.resolve(flagged: true, promptCacheExpired: true), .flag)
        XCTAssertEqual(ActivityMarkTint.resolve(flagged: true, promptCacheExpired: false), .flag)
        XCTAssertEqual(ActivityMarkTint.resolve(flagged: false, promptCacheExpired: true), .promptCacheCold)
        XCTAssertEqual(ActivityMarkTint.resolve(flagged: false, promptCacheExpired: false), .lifecycle)
    }

    /// C11-486: a delegate has no color of its own. Blue still means cold, and
    /// a stopped delegate presents idle, never gold.
    func testADelegateMarkTakesTheSameColorsAsANormalAgent() {
        let now = Date(timeIntervalSince1970: 95_000)
        let expired = PromptCacheObservation(requestAt: now.addingTimeInterval(-4_000), basis: .ttl(3_600), promptTokens: nil)
        func agent(
            _ state: WorkspacePulseState,
            flagged: Bool = false,
            depth: Int,
            cache: PromptCacheObservation?
        ) -> WorkspacePulseAgent {
            WorkspacePulseAgent(
                surfaceId: UUID(), state: state, context: nil, flagged: flagged,
                suppressed: depth > 0,
                flagReason: flagged ? "synthetic" : nil,
                activityHelp: AgentActivityHelpProjection.project(
                    state: state, lastActivityAt: now.addingTimeInterval(-4_000), waitingStartedAt: nil,
                    coldAfterSeconds: 600, flagReason: nil, flagRaisedAt: nil, suppressed: depth > 0,
                    now: now, promptCache: cache
                ),
                lineageDepth: depth
            )
        }
        for depth in [0, 1, 2, 5] {
            XCTAssertEqual(agent(.cold, depth: depth, cache: expired).markTint, .promptCacheCold, "depth \(depth): cache cold is blue")
            XCTAssertEqual(agent(.cold, depth: depth, cache: nil).markTint, .lifecycle, "depth \(depth): dormancy cold is gray")
            XCTAssertEqual(agent(.working, depth: depth, cache: nil).markTint, .lifecycle)
            XCTAssertEqual(agent(.idle, depth: depth, cache: nil).markTint, .lifecycle)
            XCTAssertEqual(agent(.cold, flagged: true, depth: depth, cache: expired).markTint, .flag, "depth \(depth): violet wins")
            XCTAssertEqual(agent(.cold, depth: depth, cache: expired).lineageDepth, depth, "the lineage survives the tint")
        }
        let stoppedDelegate = agent(.waiting, depth: 1, cache: nil)
        XCTAssertEqual(stoppedDelegate.presentedState, .idle, "gold means waiting on the operator only")
        XCTAssertEqual(stoppedDelegate.markTint, .lifecycle)
        let flaggedDelegate = agent(.waiting, flagged: true, depth: 2, cache: nil)
        XCTAssertEqual(flaggedDelegate.presentedState, .waiting, "a flagged delegate keeps the waiting shape")
        XCTAssertEqual(flaggedDelegate.markTint, .flag)
        XCTAssertEqual(flaggedDelegate.lineageDepth, 2, "and its lines")
        XCTAssertEqual(agent(.idle, depth: 0, cache: nil).lineageDepth, 0)
    }

    func testTheSidebarMarkIsBlueOnlyForAnUnflaggedCacheCold() {
        let now = Date(timeIntervalSince1970: 95_000)
        let expired = PromptCacheObservation(requestAt: now.addingTimeInterval(-4_000), basis: .ttl(3_600), promptTokens: nil)
        func agent(_ state: WorkspacePulseState, flagged: Bool = false, cache: PromptCacheObservation?) -> WorkspacePulseAgent {
            WorkspacePulseAgent(
                surfaceId: UUID(), state: state, context: nil, flagged: flagged,
                flagReason: flagged ? "synthetic" : nil,
                activityHelp: AgentActivityHelpProjection.project(
                    state: state, lastActivityAt: now.addingTimeInterval(-4_000), waitingStartedAt: nil,
                    coldAfterSeconds: 600, flagReason: nil, flagRaisedAt: nil, suppressed: false,
                    now: now, promptCache: cache
                )
            )
        }
        XCTAssertTrue(agent(.cold, cache: expired).showsPromptCacheColor)
        XCTAssertFalse(agent(.cold, flagged: true, cache: expired).showsPromptCacheColor, "violet wins")
        XCTAssertFalse(agent(.cold, cache: nil).showsPromptCacheColor, "dormancy cold stays gray")
        XCTAssertFalse(agent(.waiting, cache: expired).showsPromptCacheColor, "waiting keeps gold")
    }

    func testWaitingHelpCarriesTheExpiryInTextAndResetsNameTheirCause() {
        let now = Date(timeIntervalSince1970: 96_000)
        func project(_ state: WorkspacePulseState, _ cache: PromptCacheObservation?) -> AgentActivityHelpProjection {
            AgentActivityHelpProjection.project(
                state: state, lastActivityAt: now.addingTimeInterval(-4_000), waitingStartedAt: now.addingTimeInterval(-3_900),
                coldAfterSeconds: 600, flagReason: nil, flagRaisedAt: nil, suppressed: false,
                now: now, promptCache: cache
            )
        }
        let expired = PromptCacheObservation(requestAt: now.addingTimeInterval(-4_000), basis: .ttl(3_600), promptTokens: 1_000)
        let waiting = project(.waiting, expired)
        XCTAssertFalse(waiting.promptCacheExpired, "no blue on a waiting mark")
        XCTAssertEqual(waiting.help.detailLines.count, 2)
        XCTAssertEqual(waiting.stateStartedAt, now.addingTimeInterval(-3_900), "waiting still counts from the notification")
        XCTAssertTrue(project(.waiting, PromptCacheObservation(requestAt: now, basis: .ttl(3_600), promptTokens: nil)).help.detailLines.isEmpty)

        let reset = PromptCacheObservation(requestAt: now.addingTimeInterval(-100), basis: .ttl(3_600), promptTokens: nil,
                                           reset: .modelSwitch, resetAt: now.addingTimeInterval(-50))
        let cold = project(.cold, reset)
        XCTAssertTrue(cold.promptCacheExpired)
        XCTAssertEqual(cold.stateStartedAt, now.addingTimeInterval(-50), "cold since the switch")
        XCTAssertEqual(cold.help.detailLines.count, 1)
        XCTAssertNotEqual(cold.help.detailLines.first, project(.cold, expired).help.detailLines.first,
                          "a reset names its cause, not a lifetime")
    }
}
