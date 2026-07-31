import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class AgentAttentionReducerTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let surface = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let epoch = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let staleEpoch = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let root = "019fb4ec-8060-7b21-8938-8055d34c3825"
    private let child = "019fb4ec-8060-7b21-8938-8055d34c3999"
    private let baseDate = Date(timeIntervalSince1970: 10_000)

    private func state(claimed: Bool = true) -> AgentAttentionState {
        var state = AgentAttentionState(
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch
        )
        if claimed {
            XCTAssertTrue(state.bindRootThread(root))
        }
        return state
    }

    private func event(
        _ id: String,
        kind: AgentLifecycleEventKind,
        actor: String? = nil,
        parent: String? = nil,
        rootThread: String? = nil,
        epoch eventEpoch: UUID? = nil,
        authority: AgentEvidenceAuthority = .structuredProvider,
        sequence: Int64? = nil,
        offset: TimeInterval = 0
    ) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(
            eventID: id,
            workspaceID: workspace,
            surfaceID: surface,
            provider: .codex,
            launchEpoch: eventEpoch ?? epoch,
            rootThreadID: rootThread,
            actorThreadID: actor,
            parentThreadID: parent,
            turnID: id,
            kind: kind,
            authority: authority,
            providerSequence: sequence,
            occurredAt: baseDate.addingTimeInterval(offset)
        )
    }

    @discardableResult
    private func apply(
        _ envelope: AgentLifecycleEnvelope,
        to state: inout AgentAttentionState
    ) -> AgentAttentionReduction {
        let reduction = AgentAttentionReducer.reduce(state: state, envelope: envelope)
        state = reduction.state
        return reduction
    }

    func testPreClaimLifecycleSeedsAndRootBindsLater() {
        var state = state(claimed: false)
        XCTAssertEqual(
            apply(
                event(
                    "seed",
                    kind: .launchSeedIdle,
                    authority: .launchSeed
                ),
                to: &state
            ).disposition,
            .applied
        )
        XCTAssertEqual(
            apply(
                event(
                    "submit",
                    kind: .runStarted(resumesAttention: false),
                    authority: .terminalSubmission,
                    offset: 1
                ),
                to: &state
            ).state.runState,
            .working
        )
        XCTAssertNil(state.rootThreadID)

        let completion = apply(
            event(
                "root-complete",
                kind: .rootResultReady,
                actor: root,
                rootThread: root,
                authority: .exactRootCompletion,
                offset: 2
            ),
            to: &state
        )
        XCTAssertEqual(completion.ownership, .root)
        XCTAssertEqual(state.rootThreadID, root)
        XCTAssertEqual(state.attentionEpisode?.reason, .resultReady)
    }

    func testAttentionCreationFailsClosedBeforeClaim() {
        var state = state(claimed: false)
        let result = apply(
            event(
                "unowned",
                kind: .rootResultReady,
                actor: child,
                authority: .exactRootCompletion
            ),
            to: &state
        )
        XCTAssertEqual(result.ownership, .unknown)
        XCTAssertEqual(result.disposition, .ignoredUnknown)
        XCTAssertNil(state.attentionEpisode)
        XCTAssertEqual(state.runState, .idle)
    }

    func testRecordedGAF13ChildrenNeverIdleWaitOrEnterAttention() {
        var state = state()
        _ = apply(
            event(
                "working",
                kind: .runStarted(resumesAttention: false),
                actor: root,
                authority: .providerLifecycle
            ),
            to: &state
        )

        for index in 0..<4 {
            let result = apply(
                event(
                    "child-final-\(index)",
                    kind: .rootResultReady,
                    actor: "\(child)-\(index)",
                    parent: root,
                    authority: .exactRootCompletion,
                    offset: TimeInterval(index + 1)
                ),
                to: &state
            )
            XCTAssertEqual(result.ownership, .child)
            XCTAssertEqual(result.disposition, .ignoredChild)
            XCTAssertFalse(result.enteredAttention)
            XCTAssertEqual(state.runState, .working)
            XCTAssertNil(state.attentionEpisode)
        }
    }

    func testExactRootCompletionCreatesOneStableEpisode() {
        var state = state()
        let envelope = event(
            "final",
            kind: .rootResultReady,
            actor: root,
            authority: .exactRootCompletion
        )
        let first = apply(envelope, to: &state)
        let episode = state.attentionEpisode
        let duplicate = apply(envelope, to: &state)

        XCTAssertTrue(first.enteredAttention)
        XCTAssertEqual(episode?.reason, .resultReady)
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(state.attentionEpisode, episode)
    }

    func testStaleMismatchAndReorderedCompletionCannotReplaceEpisode() {
        var state = state()
        _ = apply(
            event(
                "final",
                kind: .rootResultReady,
                actor: root,
                authority: .exactRootCompletion,
                sequence: 10,
                offset: 10
            ),
            to: &state
        )
        let episode = state.attentionEpisode

        XCTAssertEqual(
            apply(
                event(
                    "stale",
                    kind: .rootResultReady,
                    actor: root,
                    epoch: staleEpoch,
                    authority: .exactRootCompletion,
                    offset: 20
                ),
                to: &state
            ).disposition,
            .ignoredStaleEpoch
        )
        XCTAssertEqual(
            apply(
                event(
                    "mismatch",
                    kind: .rootResultReady,
                    actor: child,
                    authority: .exactRootCompletion,
                    offset: 20
                ),
                to: &state
            ).disposition,
            .ignoredMismatch
        )
        XCTAssertEqual(
            apply(
                event(
                    "old-sequence",
                    kind: .rootResultReady,
                    actor: root,
                    authority: .exactRootCompletion,
                    sequence: 9,
                    offset: 20
                ),
                to: &state
            ).disposition,
            .outOfOrder
        )
        XCTAssertEqual(state.attentionEpisode, episode)
    }

    func testChildOverlapOnlyMutatesChildSet() {
        var state = state()
        let started = apply(
            event(
                "child-start",
                kind: .childStarted,
                actor: child,
                parent: root
            ),
            to: &state
        )
        XCTAssertEqual(started.ownership, .child)
        XCTAssertEqual(state.activeChildThreadIDs, [child])
        XCTAssertNil(state.attentionEpisode)

        let stopped = apply(
            event(
                "child-stop",
                kind: .childStopped,
                actor: child,
                parent: root,
                offset: 1
            ),
            to: &state
        )
        XCTAssertEqual(stopped.ownership, .child)
        XCTAssertTrue(state.activeChildThreadIDs.isEmpty)
        XCTAssertNil(state.attentionEpisode)
    }

    func testApprovalAndInputWaitRequireExplicitResume() {
        var state = state()
        _ = apply(
            event(
                "approval",
                kind: .rootWaiting(.approval),
                actor: root
            ),
            to: &state
        )
        XCTAssertEqual(state.attentionEpisode?.reason, .approval)

        _ = apply(
            event(
                "activity-hint",
                kind: .runStarted(resumesAttention: false),
                actor: root,
                authority: .terminalSubmission,
                offset: 1
            ),
            to: &state
        )
        XCTAssertEqual(state.attentionEpisode?.reason, .approval)

        _ = apply(
            event(
                "approval-answered",
                kind: .runStarted(resumesAttention: true),
                actor: root,
                authority: .structuredProvider,
                offset: 2
            ),
            to: &state
        )
        XCTAssertNil(state.attentionEpisode)
        XCTAssertEqual(state.runState, .working)

        _ = apply(
            event(
                "input",
                kind: .rootWaiting(.userInput),
                actor: root,
                offset: 3
            ),
            to: &state
        )
        XCTAssertEqual(state.attentionEpisode?.reason, .userInput)
    }

    func testRunStartedClearsResultWithoutReadingHistory() {
        var state = state()
        _ = apply(
            event(
                "final",
                kind: .rootResultReady,
                actor: root,
                authority: .exactRootCompletion
            ),
            to: &state
        )
        let result = apply(
            event(
                "continued",
                kind: .runStarted(resumesAttention: false),
                actor: root,
                authority: .providerLifecycle,
                offset: 1
            ),
            to: &state
        )
        XCTAssertTrue(result.leftAttention)
        XCTAssertNil(state.attentionEpisode)
        XCTAssertEqual(state.runState, .working)
    }

    func testActiveGoalDefersCompletionUntilGoalCompletes() {
        var state = state()
        _ = apply(
            event("goal-active", kind: .goalChanged(.active), actor: root),
            to: &state
        )
        _ = apply(
            event(
                "turn-finished",
                kind: .rootResultReady,
                actor: root,
                authority: .exactRootCompletion,
                offset: 1
            ),
            to: &state
        )
        XCTAssertEqual(state.runState, .working)
        XCTAssertTrue(state.pendingResultDuringGoal)
        XCTAssertNil(state.attentionEpisode)

        _ = apply(
            event(
                "goal-complete",
                kind: .goalChanged(.completed),
                actor: root,
                offset: 2
            ),
            to: &state
        )
        XCTAssertEqual(state.attentionEpisode?.reason, .resultReady)
        XCTAssertEqual(state.attentionEpisode?.startedAt, baseDate.addingTimeInterval(2))
    }

    func testGoalBlockedAndLimitsCarryCanonicalReasons() {
        let cases: [(AgentGoalStatus, AgentAttentionReason)] = [
            (.blocked, .goalBlocked),
            (.usageLimited, .usageLimited),
            (.budgetLimited, .budgetLimited),
        ]
        for (index, item) in cases.enumerated() {
            var state = state()
            _ = apply(
                event(
                    "goal-\(index)",
                    kind: .goalChanged(item.0),
                    actor: root
                ),
                to: &state
            )
            XCTAssertEqual(state.attentionEpisode?.reason, item.1)
        }
    }

    func testWeakerOlderLifecycleCannotOverwriteStructuredWait() {
        var state = state()
        _ = apply(
            event(
                "wait",
                kind: .rootWaiting(.userInput),
                actor: root,
                authority: .structuredProvider,
                offset: 10
            ),
            to: &state
        )
        let result = apply(
            event(
                "late-idle",
                kind: .runBecameIdle,
                actor: root,
                authority: .providerLifecycle,
                offset: 5
            ),
            to: &state
        )
        XCTAssertEqual(result.disposition, .outOfOrder)
        XCTAssertEqual(state.attentionEpisode?.reason, .userInput)
    }
}
