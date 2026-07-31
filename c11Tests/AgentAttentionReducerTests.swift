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

    func testClaudeApprovalRequiresStructuredNotificationType() {
        XCTAssertEqual(
            ClaudeHookAttentionClassifier.reason(
                from: ["notification_type": "permission_prompt"]
            ),
            .approval
        )
        XCTAssertEqual(
            ClaudeHookAttentionClassifier.reason(
                from: [
                    "notification": [
                        "type": "permission_request",
                        "message": "arbitrary content",
                    ],
                ]
            ),
            .approval
        )
    }

    func testClaudeContentCannotClaimApprovalAuthority() {
        XCTAssertEqual(
            ClaudeHookAttentionClassifier.reason(
                from: [
                    "type": "notification",
                    "message": "Please approve this permission",
                ]
            ),
            .userInput
        )
        XCTAssertEqual(
            ClaudeHookAttentionClassifier.reason(from: nil),
            .userInput
        )
    }

    func testCodexIngressClassifiesOwnedRootChildMismatchStaleAndUnknown() throws {
        let coordinator = AgentAttentionCoordinator.shared
        let epoch = UUID()
        let staleEpoch = UUID()
        let root = UUID().uuidString.lowercased()
        let child = UUID().uuidString.lowercased()

        func ownership(workspace: UUID, surface: UUID, root: String?) -> AgentAttentionOwnershipSnapshot {
            AgentAttentionOwnershipSnapshot(
                workspaceID: workspace,
                surfaceID: surface,
                launchEpoch: epoch,
                rootThreadID: root
            )
        }

        func payload(thread: String?, turn: String? = UUID().uuidString) throws -> Data {
            var object: [String: Any] = [
                "version": 1,
                "type": "agent-turn-complete",
            ]
            object["thread-id"] = thread
            object["turn-id"] = turn
            return try JSONSerialization.data(withJSONObject: object)
        }

        let exactWorkspace = UUID()
        let exactSurface = UUID()
        let exact = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root, turn: "turn-exact"),
            ownership: ownership(workspace: exactWorkspace, surface: exactSurface, root: root),
            markerLaunchEpoch: epoch,
            workspaceID: exactWorkspace,
            surfaceID: exactSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(exact.ownership, .root)
        XCTAssertTrue(exact.shouldCreateSignalNotification)

        let childWorkspace = UUID()
        let childSurface = UUID()
        let childResult = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: child),
            ownership: ownership(workspace: childWorkspace, surface: childSurface, root: root),
            markerLaunchEpoch: epoch,
            workspaceID: childWorkspace,
            surfaceID: childSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(childResult.ownership, .child)
        XCTAssertFalse(childResult.shouldCreateSignalNotification)
        XCTAssertFalse(childResult.shouldCreateHistoryOnlyNotification)

        let mismatchWorkspace = UUID()
        let mismatchSurface = UUID()
        let mismatch = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root),
            ownership: ownership(workspace: UUID(), surface: mismatchSurface, root: root),
            markerLaunchEpoch: epoch,
            workspaceID: mismatchWorkspace,
            surfaceID: mismatchSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(mismatch.ownership, .mismatched)
        XCTAssertFalse(mismatch.shouldPublishLifecycle)
        XCTAssertFalse(mismatch.shouldCreateSignalNotification)

        let markerMismatchWorkspace = UUID()
        let markerMismatchSurface = UUID()
        let markerMismatch = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root),
            ownership: ownership(
                workspace: markerMismatchWorkspace,
                surface: markerMismatchSurface,
                root: root
            ),
            markerLaunchEpoch: staleEpoch,
            workspaceID: markerMismatchWorkspace,
            surfaceID: markerMismatchSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(markerMismatch.ownership, .staleEpoch)
        XCTAssertFalse(markerMismatch.shouldPublishLifecycle)
        XCTAssertFalse(markerMismatch.shouldCreateSignalNotification)

        let missingMarkerWorkspace = UUID()
        let missingMarkerSurface = UUID()
        let missingMarker = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root),
            ownership: ownership(
                workspace: missingMarkerWorkspace,
                surface: missingMarkerSurface,
                root: root
            ),
            markerLaunchEpoch: nil,
            workspaceID: missingMarkerWorkspace,
            surfaceID: missingMarkerSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(missingMarker.ownership, .staleEpoch)
        XCTAssertFalse(missingMarker.shouldPublishLifecycle)

        let missingRootWorkspace = UUID()
        let missingRootSurface = UUID()
        let missingRoot = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root, turn: "turn-missing-root"),
            ownership: ownership(
                workspace: missingRootWorkspace,
                surface: missingRootSurface,
                root: nil
            ),
            markerLaunchEpoch: epoch,
            workspaceID: missingRootWorkspace,
            surfaceID: missingRootSurface,
            launchEpoch: epoch
        )
        XCTAssertEqual(missingRoot.ownership, .unknown)
        XCTAssertFalse(missingRoot.shouldPublishLifecycle)
        XCTAssertTrue(missingRoot.shouldCreateHistoryOnlyNotification)

        XCTAssertFalse(markerMismatch.shouldCreateHistoryOnlyNotification)

        let staleWorkspace = UUID()
        let staleSurface = UUID()
        let stale = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root),
            ownership: ownership(workspace: staleWorkspace, surface: staleSurface, root: root),
            markerLaunchEpoch: epoch,
            workspaceID: staleWorkspace,
            surfaceID: staleSurface,
            launchEpoch: staleEpoch
        )
        XCTAssertEqual(stale.ownership, .staleEpoch)
        XCTAssertFalse(stale.shouldCreateSignalNotification)
        XCTAssertFalse(stale.shouldCreateHistoryOnlyNotification)

        let incompleteEvents: [(String?, String?)] = [
            (nil, UUID().uuidString),
            (root, nil),
        ]
        for (thread, turn) in incompleteEvents {
            let unknownWorkspace = UUID()
            let unknownSurface = UUID()
            let unknown = try coordinator.ingestLegacyCodex(
                rawPayload: payload(thread: thread, turn: turn),
                ownership: ownership(
                    workspace: unknownWorkspace,
                    surface: unknownSurface,
                    root: root
                ),
                markerLaunchEpoch: epoch,
                workspaceID: unknownWorkspace,
                surfaceID: unknownSurface,
                launchEpoch: epoch
            )
            XCTAssertEqual(unknown.ownership, .unknown)
            XCTAssertFalse(unknown.shouldCreateSignalNotification)
            XCTAssertTrue(unknown.shouldCreateHistoryOnlyNotification)
        }
    }

    func testCodexIngressDeduplicatesTurnsAndCompatibilityLifecycleReusesLaunchEpoch() throws {
        let coordinator = AgentAttentionCoordinator.shared
        let workspace = UUID()
        let surface = UUID()
        let epoch = UUID()
        let root = UUID().uuidString.lowercased()
        let firstPayload = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "type": "agent-turn-complete",
                "thread-id": root,
                "turn-id": "turn-1",
                "last-assistant-message": "First structured result",
            ]
        )
        let ownership = AgentAttentionOwnershipSnapshot(
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch,
            rootThreadID: root
        )

        let first = try coordinator.ingestLegacyCodex(
            rawPayload: firstPayload,
            ownership: ownership,
            markerLaunchEpoch: epoch,
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch
        )
        let duplicate = try coordinator.ingestLegacyCodex(
            rawPayload: firstPayload,
            ownership: ownership,
            markerLaunchEpoch: epoch,
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch
        )
        XCTAssertTrue(first.shouldCreateSignalNotification)
        XCTAssertEqual(first.notificationBody, "First structured result")
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertFalse(duplicate.shouldCreateSignalNotification)

        let resumed = coordinator.applyCompatibilityLifecycle(
            provider: .codex,
            workspaceID: workspace,
            surfaceID: surface,
            activity: .working
        )
        XCTAssertEqual(resumed.runState, .working)
        XCTAssertNil(resumed.episode)

        let secondPayload = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "type": "agent-turn-complete",
                "thread-id": root,
                "turn-id": "turn-2",
                "last-assistant-message": "Second structured result",
            ]
        )
        let second = try coordinator.ingestLegacyCodex(
            rawPayload: secondPayload,
            ownership: ownership,
            markerLaunchEpoch: epoch,
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch
        )
        XCTAssertTrue(second.shouldCreateSignalNotification)
        XCTAssertEqual(second.snapshot.episode?.reason, .resultReady)
        XCTAssertEqual(second.notificationBody, "Second structured result")
    }

    func testClaudeAndOpenCodeUseTurnScopedIdempotencyAcrossTwoEpisodes() {
        let coordinator = AgentAttentionCoordinator.shared

        for provider in [AgentProvider.claude, .opencode] {
            let workspace = UUID()
            let surface = UUID()
            let stableOccurrence = "root-session:\(provider.rawValue):result-ready"

            _ = coordinator.applyCompatibilityLifecycle(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                activity: .working
            )
            let first = coordinator.applyOwnedAttention(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                reason: .resultReady,
                eventID: stableOccurrence,
                notificationSubtitle: "Completed",
                notificationBody: "First episode"
            )
            let firstDuplicate = coordinator.applyOwnedAttention(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                reason: .resultReady,
                eventID: stableOccurrence,
                notificationSubtitle: "Completed",
                notificationBody: "First episode"
            )
            XCTAssertTrue(first.shouldCreateSignalNotification, provider.rawValue)
            XCTAssertEqual(firstDuplicate.disposition, .duplicate, provider.rawValue)
            XCTAssertFalse(firstDuplicate.shouldPublishLifecycle, provider.rawValue)

            let resumed = coordinator.applyCompatibilityLifecycle(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                activity: .working
            )
            XCTAssertNil(resumed.episode, provider.rawValue)

            let second = coordinator.applyOwnedAttention(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                reason: .resultReady,
                eventID: stableOccurrence,
                notificationSubtitle: "Completed",
                notificationBody: "Second episode"
            )
            let secondDuplicate = coordinator.applyOwnedAttention(
                provider: provider,
                workspaceID: workspace,
                surfaceID: surface,
                reason: .resultReady,
                eventID: stableOccurrence,
                notificationSubtitle: "Completed",
                notificationBody: "Second episode"
            )
            XCTAssertTrue(second.shouldCreateSignalNotification, provider.rawValue)
            XCTAssertEqual(secondDuplicate.disposition, .duplicate, provider.rawValue)
            XCTAssertFalse(secondDuplicate.shouldCreateSignalNotification, provider.rawValue)
        }
    }

    func testCanonicalWaitingEdgesCarryExactSurfaceReasonAndEpisode() {
        let coordinator = AgentAttentionCoordinator.shared
        let workspace = UUID()
        let surface = UUID()
        var edges: [AgentWaitingEdge] = []
        coordinator.configureWaitingEdgeHandlerForTesting { edge in
            if edge.workspaceID == workspace, edge.surfaceID == surface {
                edges.append(edge)
            }
        }
        defer { coordinator.resetWaitingEdgeHandlerForTesting() }

        _ = coordinator.applyCompatibilityLifecycle(
            provider: .claude,
            workspaceID: workspace,
            surfaceID: surface,
            activity: .working
        )
        let attention = coordinator.applyOwnedAttention(
            provider: .claude,
            workspaceID: workspace,
            surfaceID: surface,
            reason: .approval,
            eventID: "permission-1",
            notificationSubtitle: "Permission",
            notificationBody: "Claude Code needs approval."
        )
        _ = coordinator.applyCompatibilityLifecycle(
            provider: .claude,
            workspaceID: workspace,
            surfaceID: surface,
            activity: .working
        )

        let episodeID = attention.snapshot.episode?.id
        XCTAssertNotNil(episodeID)
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges.map(\.entered), [true, false])
        XCTAssertEqual(edges.map(\.workspaceID), [workspace, workspace])
        XCTAssertEqual(edges.map(\.surfaceID), [surface, surface])
        XCTAssertEqual(edges.map(\.episode.reason), [.approval, .approval])
        XCTAssertEqual(
            edges.map(\.episode.id),
            Array(repeating: episodeID ?? "", count: 2)
        )
    }

    func testGAF13ChildCallbacksPublishNoLifecycleNotificationOrWaitingEdges() throws {
        let coordinator = AgentAttentionCoordinator.shared
        let workspace = UUID()
        let surface = UUID()
        let epoch = UUID()
        let root = UUID().uuidString.lowercased()
        let ownership = AgentAttentionOwnershipSnapshot(
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch,
            rootThreadID: root
        )
        func payload(thread: String, turn: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "version": 1,
                    "type": "agent-turn-complete",
                    "thread-id": thread,
                    "turn-id": turn,
                ]
            )
        }

        _ = try coordinator.ingestLegacyCodex(
            rawPayload: payload(thread: root, turn: "setup-root"),
            ownership: ownership,
            markerLaunchEpoch: epoch,
            workspaceID: workspace,
            surfaceID: surface,
            launchEpoch: epoch
        )
        _ = coordinator.applyCompatibilityLifecycle(
            provider: .codex,
            workspaceID: workspace,
            surfaceID: surface,
            activity: .working
        )

        var childEdges: [AgentWaitingEdge] = []
        coordinator.configureWaitingEdgeHandlerForTesting { edge in
            if edge.workspaceID == workspace, edge.surfaceID == surface {
                childEdges.append(edge)
            }
        }
        defer { coordinator.resetWaitingEdgeHandlerForTesting() }

        for index in 0..<4 {
            let child = UUID().uuidString.lowercased()
            let result = try coordinator.ingestLegacyCodex(
                rawPayload: payload(thread: child, turn: "child-\(index)"),
                ownership: ownership,
                markerLaunchEpoch: epoch,
                workspaceID: workspace,
                surfaceID: surface,
                launchEpoch: epoch
            )
            XCTAssertEqual(result.ownership, .child)
            XCTAssertFalse(result.shouldPublishLifecycle)
            XCTAssertFalse(result.shouldCreateSignalNotification)
            XCTAssertFalse(result.shouldCreateHistoryOnlyNotification)
        }
        XCTAssertTrue(childEdges.isEmpty)
        XCTAssertEqual(
            coordinator.snapshot(workspaceID: workspace, surfaceID: surface)?.runState,
            .working
        )
        XCTAssertNil(
            coordinator.snapshot(workspaceID: workspace, surfaceID: surface)?.episode
        )
    }

    func testSocketIngestReturnsOnlyAfterHistoryCommitIsObservable() async {
        let workspace = UUID()
        let surface = UUID()
        let controller = TerminalController.shared
        let originalNotifications = await MainActor.run {
            let original = TerminalNotificationStore.shared.notifications
            TerminalNotificationStore.shared.replaceNotificationsForTesting([])
            AppFocusState.overrideIsFocused = false
            return original
        }

        let response = await Task.detached {
            controller.v2AgentIngest(params: [
                "version": 1,
                "provider": "claude",
                "workspace_id": workspace.uuidString,
                "surface_id": surface.uuidString,
                "event": "result-ready",
                "actor_thread_id": "claude-root",
                "notification_subtitle": "Completed",
                "notification_body": "Committed before response",
            ])
        }.value

        switch response {
        case .ok:
            break
        case .err(let code, let message, _):
            XCTFail("unexpected socket error \(code): \(message)")
        }

        let committed = await MainActor.run {
            TerminalNotificationStore.shared.notifications.first {
                $0.tabId == workspace && $0.surfaceId == surface
            }
        }
        XCTAssertEqual(committed?.body, "Committed before response")
        XCTAssertTrue(committed?.attentionEligible == true)

        await MainActor.run {
            TerminalNotificationStore.shared.replaceNotificationsForTesting(
                originalNotifications
            )
            AppFocusState.overrideIsFocused = nil
        }
    }
}
