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
    func testWorkspacePulseAgentContextUsesTitleThenSubtitle() {
        XCTAssertEqual(
            WorkspacePulseAgentContextProjector.project(
                title: "Review agent",
                subtitle: "Lineage: primary → review\nChecking the sidebar"
            ),
            WorkspacePulseAgentContext(
                title: "Review agent",
                subtitle: "Lineage: primary → review Checking the sidebar"
            )
        )
    }

    func testWorkspacePulseAgentContextDoesNotInventMissingIdentity() {
        XCTAssertNil(WorkspacePulseAgentContextProjector.project(title: "  ", subtitle: nil))
    }

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

    func testWorkspacePulseCarriesRosterTerminalCountAndPrecedenceOrder() {
        let idleId = UUID()
        let waitingId = UUID()
        let workingId = UUID()
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            agents: [
                WorkspacePulseAgent(
                    surfaceId: idleId,
                    state: .idle,
                    context: WorkspacePulseAgentContext(title: "Docs", subtitle: "ready")
                ),
                WorkspacePulseAgent(
                    surfaceId: waitingId,
                    state: .waiting,
                    context: WorkspacePulseAgentContext(title: "Release gate", subtitle: "review requested")
                ),
                WorkspacePulseAgent(
                    surfaceId: workingId,
                    state: .working,
                    context: WorkspacePulseAgentContext(title: "Build", subtitle: "verifying push")
                ),
            ],
            terminalCount: 3
        )

        XCTAssertEqual(summary.agents.count, 3)
        XCTAssertEqual(summary.terminalCount, 3)
        XCTAssertEqual(summary.agentCount(for: .waiting), 1)
        XCTAssertEqual(summary.relevantAgents.map(\.surfaceId), [waitingId, workingId, idleId])
    }

    func testWorkspacePulseWorkspaceDemandDoesNotCreateRosterAgent() {
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            agents: [],
            terminalCount: 2
        )

        XCTAssertEqual(summary.dominant, .waiting)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertTrue(summary.agents.isEmpty)
        XCTAssertEqual(summary.terminalCount, 2)
    }

    func testWorkspacePulseSuppressesUnflaggedWaitingIntoIdle() {
        let agent = WorkspacePulseAgent(
            surfaceId: UUID(),
            state: .waiting,
            context: nil,
            suppressed: true
        )

        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: false,
            agents: [agent],
            terminalCount: 1
        )

        XCTAssertEqual(agent.state, .waiting, "The source lifecycle remains available to C11-184")
        XCTAssertEqual(agent.presentedState, .idle)
        XCTAssertEqual(summary.waitingCount, 0)
        XCTAssertEqual(summary.idleCount, 1)
        XCTAssertEqual(summary.relevantAgents.map(\.presentedState), [.idle])
    }

    func testWorkspacePulseFlagOverridesSuppression() {
        let agent = WorkspacePulseAgent(
            surfaceId: UUID(),
            state: .waiting,
            context: nil,
            flagged: true,
            suppressed: true
        )

        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: false,
            agents: [agent],
            terminalCount: 1
        )

        XCTAssertEqual(agent.presentedState, .waiting)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.idleCount, 0)
        XCTAssertEqual(summary.relevantAgents.map(\.presentedState), [.waiting])
    }

    func testFlaggedAgentsLeadDominantDetailsRegardlessOfLifecycle() {
        let waitingA = WorkspacePulseAgent(surfaceId: UUID(), state: .waiting, context: nil)
        let waitingB = WorkspacePulseAgent(surfaceId: UUID(), state: .waiting, context: nil)
        let flaggedWorking = WorkspacePulseAgent(
            surfaceId: UUID(),
            state: .working,
            context: nil,
            flagged: true,
            flagReason: "Needs operator decision"
        )
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            agents: [waitingA, waitingB, flaggedWorking],
            terminalCount: 3
        )

        XCTAssertEqual(summary.flaggedCount, 1)
        XCTAssertEqual(summary.relevantAgents.first?.surfaceId, flaggedWorking.surfaceId)
        XCTAssertTrue(summary.relevantAgents.prefix(2).contains(where: \.flagged))
    }

    func testWaitingOverflowSubtractsPresentedVisibleWaitingOnly() {
        let visibleSuppressedRawWaiting = WorkspacePulseAgent(
            surfaceId: UUID(),
            state: .waiting,
            context: nil,
            suppressed: true
        )
        let realWaitingA = WorkspacePulseAgent(surfaceId: UUID(), state: .waiting, context: nil)
        let realWaitingB = WorkspacePulseAgent(surfaceId: UUID(), state: .waiting, context: nil)
        let summary = WorkspacePulseProjector.project(
            hasWorkspaceDemand: true,
            agents: [visibleSuppressedRawWaiting, realWaitingA, realWaitingB],
            terminalCount: 3
        )

        XCTAssertEqual(
            summary.visibleWaitingOverflow(
                visibleAgents: [visibleSuppressedRawWaiting, realWaitingA]
            ),
            1,
            "A suppressed raw-waiting mark presents idle and must not hide real waiting overflow"
        )
    }

    func testWorkspacePulseModifierDefaultsPreserveLifecycle() {
        let agent = WorkspacePulseAgent(
            surfaceId: UUID(),
            state: .working,
            context: nil
        )

        XCTAssertFalse(agent.flagged)
        XCTAssertFalse(agent.suppressed)
        XCTAssertEqual(agent.presentedState, .working)
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
