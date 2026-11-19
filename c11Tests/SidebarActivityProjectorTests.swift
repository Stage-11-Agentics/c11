import AppKit
import Combine
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

final class GhosttyOSCNotificationPolicyTests: XCTestCase {
    func testClaudeHookDoesNotSuppressGrokNotificationInSameWorkspace() {
        XCTAssertFalse(
            GhosttyOSCNotificationPolicy.shouldSuppress(
                hasActiveClaudeHookSession: true,
                sourceTerminalKind: "grok"
            )
        )
    }

    func testClaudeHookSuppressesOnlyClaudeSurfaceNotification() {
        XCTAssertTrue(
            GhosttyOSCNotificationPolicy.shouldSuppress(
                hasActiveClaudeHookSession: true,
                sourceTerminalKind: "  CLAUDE-CODE "
            )
        )
        XCTAssertFalse(
            GhosttyOSCNotificationPolicy.shouldSuppress(
                hasActiveClaudeHookSession: false,
                sourceTerminalKind: "claude-code"
            )
        )
        XCTAssertFalse(
            GhosttyOSCNotificationPolicy.shouldSuppress(
                hasActiveClaudeHookSession: true,
                sourceTerminalKind: nil
            )
        )
    }
}

final class WorkspacePulseDividerColorResolverTests: XCTestCase {
    func testUsesBrandGoldWhenWorkspaceHasNoColor() {
        XCTAssertEqual(
            WorkspacePulseDividerColorResolver.resolve(
                customHex: nil,
                colorScheme: .dark
            ).hexString(),
            BrandColors.goldHex.uppercased()
        )
    }

    func testUsesWorkspaceDisplayColorWhenSet() {
        let customHex = "#1565C0"
        let expected = WorkspaceColorSettings.displayNSColor(
            hex: customHex,
            colorScheme: .dark
        )

        XCTAssertEqual(
            WorkspacePulseDividerColorResolver.resolve(
                customHex: customHex,
                colorScheme: .dark
            ).hexString(),
            expected?.hexString()
        )
    }

    func testInvalidWorkspaceColorFallsBackToBrandGold() {
        XCTAssertEqual(
            WorkspacePulseDividerColorResolver.resolve(
                customHex: "not-a-color",
                colorScheme: .light
            ).hexString(),
            BrandColors.goldHex.uppercased()
        )
    }
}

/// C11H-278: the description's age, its buckets and the label's update gate.
final class DescriptionAgeTests: XCTestCase {
    private let edited = Date(timeIntervalSince1970: 1_800_000_000)

    private func age(_ seconds: TimeInterval) -> DescriptionAge {
        DescriptionAge(updatedAt: edited, now: edited.addingTimeInterval(seconds))
    }

    func testBuckets() {
        XCTAssertEqual(age(-30), .justNow, "a clock behind the edit reads just now")
        XCTAssertEqual(age(0), .justNow)
        XCTAssertEqual(age(59.9), .justNow)
        XCTAssertEqual(age(60), .minutes(1))
        XCTAssertEqual(age(12 * 60 + 59), .minutes(12))
        XCTAssertEqual(age(3599), .minutes(59))
        XCTAssertEqual(age(3600), .hours(1))
        XCTAssertEqual(age(3 * 3600 + 1800), .hours(3))
        XCTAssertEqual(age(86_399), .hours(23))
        XCTAssertEqual(age(86_400), .days(1))
        XCTAssertEqual(age(99 * 86_400 + 1), .days(99))
        XCTAssertEqual(age(100 * 86_400), .overNinetyNineDays, "past 99 days the age is bounded")
        XCTAssertEqual(age(400 * 86_400), .overNinetyNineDays)
    }

    func testTextCarriesTheCountInBothStyles() {
        for style in [DescriptionAge.Style.full, .compact] {
            XCTAssertTrue(DescriptionAge.minutes(12).text(style).contains("12"))
            XCTAssertTrue(DescriptionAge.hours(3).text(style).contains("3"))
            XCTAssertTrue(DescriptionAge.days(2).text(style).contains("2"))
            XCTAssertFalse(DescriptionAge.justNow.text(style).isEmpty)
        }
    }

    /// The fixed slot holds every sample, so no age is wider than its slot.
    func testSlotHoldsEveryAge() {
        for style in [DescriptionAge.Style.full, .compact] {
            let slot = DescriptionAgeMetrics.slotWidth(style: style, fontSize: 11)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let longLived = DescriptionAge(updatedAt: edited, now: edited.addingTimeInterval(400 * 86_400))
            for sample in [DescriptionAge.justNow, .minutes(1), .minutes(47), .hours(9), .days(30), longLived] {
                let width = (sample.text(style) as NSString).size(withAttributes: [.font: font]).width
                XCTAssertLessThanOrEqual(width, slot + 0.5, "\(sample) overflows the \(style) slot")
            }
        }
    }

    /// A tick re-renders the label only when its text would change: a minute
    /// of 30 s ticks moves "just now" once, and an hour-old age not at all.
    func testLabelAdvancesOnlyWhenItsTextChanges() {
        let shown = edited
        XCTAssertFalse(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: shown, tick: edited.addingTimeInterval(30)))
        XCTAssertTrue(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: shown, tick: edited.addingTimeInterval(60)))
        let hourOld = edited.addingTimeInterval(-3 * 3600 - 60)
        XCTAssertFalse(DescriptionAgeLabel.shouldAdvance(updatedAt: hourOld, shown: shown, tick: edited.addingTimeInterval(30)))
        XCTAssertFalse(DescriptionAgeLabel.shouldAdvance(updatedAt: nil, shown: shown, tick: edited.addingTimeInterval(600)))
        XCTAssertFalse(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: edited.addingTimeInterval(20),
                                                         tick: edited.addingTimeInterval(5)),
                       "a backward tick that reads the same moves nothing")
    }

    /// A clock set back moves the label at once ("12 min" to "2 min"), and
    /// later ticks age it from there, as the socket's age does.
    func testAClockSetBackMovesTheLabelAndAgingResumes() {
        var shown = edited.addingTimeInterval(12 * 60 + 5)
        XCTAssertEqual(DescriptionAge(updatedAt: edited, now: shown), .minutes(12))
        let corrected = edited.addingTimeInterval(2 * 60 + 5)
        XCTAssertTrue(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: shown, tick: corrected))
        shown = corrected
        XCTAssertEqual(DescriptionAge(updatedAt: edited, now: shown), .minutes(2))
        XCTAssertFalse(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: shown, tick: corrected.addingTimeInterval(30)))
        XCTAssertTrue(DescriptionAgeLabel.shouldAdvance(updatedAt: edited, shown: shown, tick: corrected.addingTimeInterval(60)),
                      "after the correction the label ages again")
    }

    /// The label's ticks skip the clock's replayed current value (up to a
    /// tick stale) and deliver every fresh one.
    func testLabelTicksSkipTheReplayedValue() {
        let clock = SidebarDecayClock(interval: 3600)
        var received: [Date] = []
        let subscription = DescriptionAgeLabel.ticks(of: clock).sink { received.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(received.isEmpty, "subscribing replays nothing")
        clock.isPaused = true
        clock.isPaused = false
        XCTAssertEqual(received.count, 1, "a resume publishes one fresh time")
    }

    /// The edit time rides the sidebar context only while the description shows.
    func testPulseContextCarriesTheEditTimeOnlyWithTheDescription() {
        let shown = WorkspacePulseAgentContextProjector.project(title: "Owner", subtitle: "Building", descriptionUpdatedAt: edited)
        XCTAssertEqual(shown?.descriptionUpdatedAt, edited)
        let standIn = WorkspacePulseAgentContextProjector.project(title: nil, subtitle: "Building", descriptionUpdatedAt: edited)
        XCTAssertEqual(standIn?.title, "Building")
        XCTAssertEqual(standIn?.descriptionUpdatedAt, edited, "a description standing in for the title keeps its age")
        let hidden = WorkspacePulseAgentContextProjector.project(title: "Owner", subtitle: nil, descriptionUpdatedAt: edited)
        XCTAssertNil(hidden?.descriptionUpdatedAt, "no description shown, no age")
    }
}
