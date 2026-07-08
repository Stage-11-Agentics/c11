import XCTest

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
final class SurfaceLivenessDeriverTests: XCTestCase {

    private let store = SurfaceMetadataStore.shared

    override func tearDown() {
        SurfaceActivityTracker.shared.resetAll()
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
        XCTAssertEqual(SurfaceLivenessDeriver.activityState(for: .commandRunning), .working)
        XCTAssertEqual(SurfaceLivenessDeriver.activityState(for: .promptIdle), .idle)
        XCTAssertNil(SurfaceLivenessDeriver.activityState(for: .unknown))
    }

    // MARK: - Realtime transitions write the derived truth

    @MainActor
    func testCommandRunningWritesWorkingAtDerivedTier() {
        let ws = UUID(); let surface = UUID()
        let workspace = Workspace()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        SurfaceLivenessDeriver.onShellActivityChanged(
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

        SurfaceLivenessDeriver.onShellActivityChanged(
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
        SurfaceLivenessDeriver.onShellActivityChanged(
            surfaceId: surface, workspaceId: ws, state: .commandRunning, workspace: workspace
        )
        XCTAssertTrue(poll { self.activityValue(ws, surface) == SidebarActivityState.working.rawValue })

        // Unknown must clear it back to absent.
        SurfaceLivenessDeriver.onShellActivityChanged(
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
        SurfaceLivenessDeriver.onShellActivityChanged(
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
        SurfaceActivityTracker.shared.clear(surfaceId: surface.uuidString)

        // No recency → stale → decays to idle.
        SurfaceLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
        XCTAssertEqual(activityValue(ws, surface), SidebarActivityState.idle.rawValue)
        XCTAssertEqual(activitySource(ws, surface), .derived)
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
        SurfaceActivityTracker.shared.recordActivity(surfaceId: surface.uuidString, at: Date())
        // Let the tracker's async write land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        SurfaceLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
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
        SurfaceActivityTracker.shared.clear(surfaceId: surface.uuidString)

        SurfaceLivenessDeriver.reconcile(surfaceId: surface, workspaceId: ws)
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
}
