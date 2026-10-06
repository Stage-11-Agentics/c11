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
    /// we poll. Returns the final evaluation of `cond`.
    @discardableResult
    private func poll(timeout: TimeInterval = 2.0, _ cond: () -> Bool) -> Bool {
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
        XCTAssertEqual(help.help.detailLines[1], "Suppressed")
        XCTAssertTrue(help.text(at: now).hasPrefix("Idle"))
        XCTAssertTrue(help.text(at: now).contains("\nFlagged: Need a decision\nSuppressed"))
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

    func testPanelActivityColorsMatchDarkAndLightContract() {
        let dark = Workspace.resolvedSurfaceTabActivityColors(from: NSColor(hex: "#101114")!)
        XCTAssertEqual(dark.runningHex, "#E8E8E8")
        XCTAssertEqual(dark.idleHex, "#9AA0A9")
        XCTAssertEqual(dark.coldHex, "#62676F")
        XCTAssertEqual(dark.waitingHex, "#D0AA45")
        XCTAssertEqual(dark.waitingInkHex, "#08090B")

        let light = Workspace.resolvedSurfaceTabActivityColors(from: NSColor(hex: "#F5F3EF")!)
        XCTAssertEqual(light.runningHex, "#1D2024")
        XCTAssertEqual(light.idleHex, "#585D66")
        XCTAssertEqual(light.coldHex, "#8D939C")
        XCTAssertEqual(light.waitingHex, "#9B7415")
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
            XCTAssertEqual(Workspace.activityColorOverrideHex(isFlagged: false, promptCacheExpired: true, lightBackground: light),
                           Workspace.promptCacheColdHex(lightBackground: light))
            XCTAssertNil(Workspace.activityColorOverrideHex(isFlagged: false, promptCacheExpired: false, lightBackground: light))
        }
        XCTAssertNotEqual(Workspace.promptCacheColdHex(lightBackground: true), Workspace.promptCacheColdHex(lightBackground: false))
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
