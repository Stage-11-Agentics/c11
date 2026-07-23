import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `SidebarActivityProjector.project(...)` — the pure decision
/// reconciling an explicit agent-claimed status against derived-activity
/// fallback. C11-162 (Telemetry truth).
final class SidebarActivityProjectorTests: XCTestCase {

    private let stale: Double = 300
    private let expiry: Double = 900

    private var workingText: String { SidebarActivityProjector.derivedText(.working) }
    private var idleText: String { SidebarActivityProjector.derivedText(.idle) }

    // MARK: - No explicit status → derived takeover (or nothing)

    func testNoExplicitWithDerivedShowsDerivedPill() {
        let pill = SidebarActivityProjector.project(
            explicitText: nil, explicitAgeSeconds: nil, derived: .working,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: workingText, stage: .fresh, isDerived: true))
    }

    func testNoExplicitNoDerivedReturnsNil() {
        let pill = SidebarActivityProjector.project(
            explicitText: nil, explicitAgeSeconds: nil, derived: nil,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertNil(pill)
    }

    func testEmptyExplicitTreatedAsNoExplicit() {
        let pill = SidebarActivityProjector.project(
            explicitText: "", explicitAgeSeconds: 5, derived: .idle,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: idleText, stage: .fresh, isDerived: true))
    }

    // MARK: - Explicit within expiry → explicit pill

    func testFreshExplicitShowsExplicitFresh() {
        let pill = SidebarActivityProjector.project(
            explicitText: "Building", explicitAgeSeconds: 10, derived: .working,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: "Building", stage: .fresh, isDerived: false))
    }

    func testStaleExplicitShowsExplicitStale() {
        let pill = SidebarActivityProjector.project(
            explicitText: "Building", explicitAgeSeconds: 400, derived: .working,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: "Building", stage: .stale, isDerived: false))
    }

    // MARK: - Explicit past expiry → derived takeover, else expired explicit

    func testExpiredExplicitWithDerivedHandsOffToDerived() {
        let pill = SidebarActivityProjector.project(
            explicitText: "Building", explicitAgeSeconds: 1000, derived: .idle,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: idleText, stage: .fresh, isDerived: true))
    }

    func testExpiredExplicitWithoutDerivedShowsExpiredExplicit() {
        let pill = SidebarActivityProjector.project(
            explicitText: "Building", explicitAgeSeconds: 1000, derived: nil,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill, SidebarVisiblePill(text: "Building", stage: .expired, isDerived: false))
    }

    // MARK: - Boundary: exactly at expiry hands off

    func testExplicitExactlyAtExpiryHandsOff() {
        let pill = SidebarActivityProjector.project(
            explicitText: "Building", explicitAgeSeconds: 900, derived: .working,
            staleSeconds: stale, expirySeconds: expiry
        )
        XCTAssertEqual(pill?.isDerived, true)
    }

    // MARK: - Workspace Pulse rollup

    func testWorkspacePulsePreservesCountsAndUsesDemandPrecedence() {
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            surfaceStates: [.waiting, .working, .working, .idle, .cold]
        )

        XCTAssertEqual(summary.dominant, .waiting)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.workingCount, 2)
        XCTAssertEqual(summary.idleCount, 1)
        XCTAssertEqual(summary.coldCount, 1)
    }

    func testWorkspacePulseRepresentsSurfaceLessDemandWithoutInventingAgentCounts() {
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            surfaceStates: [.working, .idle]
        )

        XCTAssertEqual(summary.dominant, .waiting)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.workingCount, 1)
        XCTAssertEqual(summary.idleCount, 1)
        XCTAssertEqual(summary.coldCount, 0)
    }

    func testWorkspacePulseFallsThroughWorkingIdleAndCold() {
        XCTAssertEqual(
            WorkspacePulseProjector.project(
                hasWorkspaceDemand: false,
                surfaceStates: [.working, .idle, .cold]
            ).dominant,
            .working
        )
        XCTAssertEqual(
            WorkspacePulseProjector.project(
                hasWorkspaceDemand: false,
                surfaceStates: [.idle, .cold]
            ).dominant,
            .idle
        )
        XCTAssertEqual(
            WorkspacePulseProjector.project(
                hasWorkspaceDemand: false,
                surfaceStates: []
            ).dominant,
            .cold
        )
    }
}
