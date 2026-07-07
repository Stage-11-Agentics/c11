import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-162 (Telemetry truth), TEL-4 — behavior tests for the workspace-model
/// bridge between the derived-liveness backend and the sidebar view:
/// `Workspace.setDerivedActivity(_:forSurface:)` and the
/// `aggregatedDerivedActivity` rollup.
///
/// These exercise the real `Workspace` API (no host injection, no source-shape
/// assertions) — set/overwrite/clear semantics on the per-surface map, and the
/// working-dominates-idle / nil-when-empty rollup contract.
final class WorkspaceDerivedActivityTests: XCTestCase {
    @MainActor
    func testSetDerivedActivityStoresPerSurfaceState() {
        let workspace = Workspace()
        let surface = UUID()

        XCTAssertNil(workspace.derivedActivityBySurface[surface])

        workspace.setDerivedActivity(.working, forSurface: surface)
        XCTAssertEqual(workspace.derivedActivityBySurface[surface], .working)
    }

    @MainActor
    func testSetDerivedActivityOverwritesExistingState() {
        let workspace = Workspace()
        let surface = UUID()

        workspace.setDerivedActivity(.working, forSurface: surface)
        XCTAssertEqual(workspace.derivedActivityBySurface[surface], .working)

        workspace.setDerivedActivity(.idle, forSurface: surface)
        XCTAssertEqual(workspace.derivedActivityBySurface[surface], .idle)
    }

    @MainActor
    func testSetDerivedActivityNilRemovesKey() {
        let workspace = Workspace()
        let surface = UUID()

        workspace.setDerivedActivity(.working, forSurface: surface)
        XCTAssertNotNil(workspace.derivedActivityBySurface[surface])

        workspace.setDerivedActivity(nil, forSurface: surface)
        XCTAssertNil(workspace.derivedActivityBySurface[surface])
        XCTAssertFalse(workspace.derivedActivityBySurface.keys.contains(surface))
    }

    @MainActor
    func testSetDerivedActivityIsPerSurfaceIndependent() {
        let workspace = Workspace()
        let surfaceA = UUID()
        let surfaceB = UUID()

        workspace.setDerivedActivity(.working, forSurface: surfaceA)
        workspace.setDerivedActivity(.idle, forSurface: surfaceB)

        XCTAssertEqual(workspace.derivedActivityBySurface[surfaceA], .working)
        XCTAssertEqual(workspace.derivedActivityBySurface[surfaceB], .idle)

        // Clearing one leaves the other untouched.
        workspace.setDerivedActivity(nil, forSurface: surfaceA)
        XCTAssertNil(workspace.derivedActivityBySurface[surfaceA])
        XCTAssertEqual(workspace.derivedActivityBySurface[surfaceB], .idle)
    }

    @MainActor
    func testAggregatedDerivedActivityIsNilWhenEmpty() {
        let workspace = Workspace()

        // A freshly seeded workspace has no derived signals for its surfaces.
        workspace.derivedActivityBySurface = [:]
        XCTAssertNil(workspace.aggregatedDerivedActivity)
    }

    @MainActor
    func testAggregatedDerivedActivityIsIdleWhenOnlyIdle() {
        let workspace = Workspace()

        workspace.setDerivedActivity(.idle, forSurface: UUID())
        workspace.setDerivedActivity(.idle, forSurface: UUID())

        XCTAssertEqual(workspace.aggregatedDerivedActivity, .idle)
    }

    @MainActor
    func testAggregatedDerivedActivityWorkingDominatesIdle() {
        let workspace = Workspace()

        workspace.setDerivedActivity(.idle, forSurface: UUID())
        workspace.setDerivedActivity(.working, forSurface: UUID())
        workspace.setDerivedActivity(.idle, forSurface: UUID())

        // Any working surface wins the rollup regardless of how many are idle.
        XCTAssertEqual(workspace.aggregatedDerivedActivity, .working)
    }

    @MainActor
    func testAggregatedDerivedActivityFallsBackAsSurfacesClear() {
        let workspace = Workspace()
        let workingSurface = UUID()
        let idleSurface = UUID()

        workspace.setDerivedActivity(.working, forSurface: workingSurface)
        workspace.setDerivedActivity(.idle, forSurface: idleSurface)
        XCTAssertEqual(workspace.aggregatedDerivedActivity, .working)

        // Remove the working surface: rollup drops to idle.
        workspace.setDerivedActivity(nil, forSurface: workingSurface)
        XCTAssertEqual(workspace.aggregatedDerivedActivity, .idle)

        // Remove the last surface: rollup becomes nil.
        workspace.setDerivedActivity(nil, forSurface: idleSurface)
        XCTAssertNil(workspace.aggregatedDerivedActivity)
    }
}
