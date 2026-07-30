import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class AttentionTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@MainActor
final class AttentionModelTests: XCTestCase {
    private let store = SurfaceMetadataStore.shared

    func testFlagReasonValidationAcceptsExactBoundAndRejectsMalformedReasons() {
        XCTAssertNil(
            SurfaceMetadataStore.validateReservedKey(
                MetadataKey.flag,
                String(repeating: "x", count: SurfaceAttentionReason.maxLength)
            )
        )
        for invalid: Any in [
            "",
            " ",
            " leading",
            "trailing ",
            "two\nlines",
            "two\rlines",
            String(repeating: "x", count: SurfaceAttentionReason.maxLength + 1),
            true,
        ] {
            XCTAssertNotNil(
                SurfaceMetadataStore.validateReservedKey(MetadataKey.flag, invalid),
                "must reject \(invalid)"
            )
        }
    }

    func testAttentionTransactionIsStickyAtomicAndPreservesFlagEpoch() throws {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let raisedAt = Date(timeIntervalSince1970: 1_000)

        let raised = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .raise("Needs review"),
            suppression: .suppress,
            now: raisedAt
        )
        XCTAssertEqual(raised.after.flagReason, "Needs review")
        XCTAssertEqual(raised.after.flagRaisedAt, raisedAt)
        XCTAssertTrue(raised.after.suppressed)
        XCTAssertEqual(raised.result.applied[MetadataKey.flag], true)
        XCTAssertEqual(raised.result.applied[MetadataKey.suppressed], true)

        let revised = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .raise("Needs operator decision"),
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(revised.after.flagReason, "Needs operator decision")
        XCTAssertEqual(revised.after.flagRaisedAt, raisedAt)
        XCTAssertTrue(revised.after.suppressed)

        let noOp = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .raise("Needs operator decision"),
            suppression: .suppress
        )
        XCTAssertEqual(noOp.result.applied[MetadataKey.flag], false)
        XCTAssertEqual(noOp.result.applied[MetadataKey.suppressed], false)

        let lowered = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .lower,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertNil(lowered.after.flagRaisedAt)
        let reraised = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .raise("New epoch"),
            now: Date(timeIntervalSince1970: 4_000)
        )
        XCTAssertEqual(reraised.after.flagRaisedAt, Date(timeIntervalSince1970: 4_000))
        XCTAssertNotEqual(
            TerminalNotificationStore.flagNotificationIdentifier(
                workspaceId: workspace,
                surfaceId: surface,
                flagRaisedAt: raisedAt
            ),
            TerminalNotificationStore.flagNotificationIdentifier(
                workspaceId: workspace,
                surfaceId: surface,
                flagRaisedAt: reraised.after.flagRaisedAt!
            )
        )
    }

    func testAttentionMutationRejectsPayloadOverCapWithoutPartialCommitOrRevision() throws {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let reason = "Needs review"

        var paddingCount = SurfaceMetadataStore.payloadCapBytes
        var base: [String: Any] = [:]
        while paddingCount > 0 {
            let candidate: [String: Any] = [
                "padding": String(repeating: "x", count: paddingCount),
            ]
            let withFlag = candidate.merging([MetadataKey.flag: reason]) { _, new in new }
            let baseSize = try JSONSerialization.data(withJSONObject: candidate).count
            let flaggedSize = try JSONSerialization.data(withJSONObject: withFlag).count
            if baseSize <= SurfaceMetadataStore.payloadCapBytes,
               flaggedSize > SurfaceMetadataStore.payloadCapBytes {
                base = candidate
                break
            }
            paddingCount -= 1
        }
        XCTAssertFalse(base.isEmpty, "test fixture must straddle the encoded payload cap")
        _ = try store.setMetadata(
            workspaceId: workspace,
            surfaceId: surface,
            partial: base,
            mode: .merge,
            source: .explicit
        )
        let before = store.getMetadata(workspaceId: workspace, surfaceId: surface)
        let beforeRevision = store.currentRevision()
        let beforeMetadata = try JSONSerialization.data(
            withJSONObject: before.metadata,
            options: [.sortedKeys]
        )
        let beforeSources = try JSONSerialization.data(
            withJSONObject: before.sources,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try store.mutateAttention(
                workspaceId: workspace,
                surfaceId: surface,
                flag: .raise(reason)
            )
        ) {
            XCTAssertEqual(($0 as? SurfaceMetadataStore.WriteError)?.code, "payload_too_large")
        }

        let after = store.getMetadata(workspaceId: workspace, surfaceId: surface)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: after.metadata, options: [.sortedKeys]),
            beforeMetadata
        )
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: after.sources, options: [.sortedKeys]),
            beforeSources
        )
        XCTAssertEqual(store.currentRevision(), beforeRevision)
        XCTAssertNil(store.attentionSnapshot(workspaceId: workspace, surfaceId: surface).flagReason)
        XCTAssertNil(store.getSource(workspaceId: workspace, surfaceId: surface, key: MetadataKey.flag))
    }

    func testSnapshotRestorePreservesAttentionReasonSuppressionAndRaiseTimestamp() {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let raisedAt: Double = 1_725_000_123

        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: surface,
            values: [
                MetadataKey.flag: "Need a deployment decision",
                MetadataKey.suppressed: true,
            ],
            sources: [
                MetadataKey.flag: .init(source: .explicit, ts: raisedAt),
                MetadataKey.suppressed: .init(source: .explicit, ts: raisedAt + 1),
            ]
        )
        let snapshot = store.attentionSnapshot(workspaceId: workspace, surfaceId: surface)
        XCTAssertEqual(snapshot.flagReason, "Need a deployment decision")
        XCTAssertTrue(snapshot.suppressed)
        XCTAssertEqual(snapshot.flagRaisedAt?.timeIntervalSince1970, raisedAt)
        XCTAssertEqual(
            store.getSource(workspaceId: workspace, surfaceId: surface, key: MetadataKey.flag),
            .explicit
        )
        XCTAssertEqual(
            store.getSource(workspaceId: workspace, surfaceId: surface, key: MetadataKey.suppressed),
            .explicit
        )
    }

    func testSnapshotRestoreCanonicalizesAttentionSourcesAndRejectsAdversarialValues() {
        let workspace = UUID()
        let validSurface = UUID()
        let invalidSurface = UUID()
        defer {
            store.removeSurface(workspaceId: workspace, surfaceId: validSurface)
            store.removeSurface(workspaceId: workspace, surfaceId: invalidSurface)
        }
        let epoch: Double = 1_725_000_999

        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: validSurface,
            values: [
                MetadataKey.flag: "Need operator approval",
                MetadataKey.suppressed: true,
                "opaque": "preserved",
            ],
            sources: [
                MetadataKey.flag: .init(source: .heuristic, ts: epoch),
                MetadataKey.suppressed: .init(source: .osc, ts: .infinity),
                "opaque": .init(source: .declare, ts: 12),
            ]
        )
        let valid = store.attentionSnapshot(workspaceId: workspace, surfaceId: validSurface)
        XCTAssertEqual(valid.flagReason, "Need operator approval")
        XCTAssertEqual(valid.flagRaisedAt?.timeIntervalSince1970, epoch)
        XCTAssertTrue(valid.suppressed)
        XCTAssertEqual(
            store.getSource(workspaceId: workspace, surfaceId: validSurface, key: MetadataKey.flag),
            .explicit
        )
        XCTAssertEqual(
            store.getSource(workspaceId: workspace, surfaceId: validSurface, key: MetadataKey.suppressed),
            .explicit
        )
        XCTAssertEqual(
            store.getMetadata(workspaceId: workspace, surfaceId: validSurface)
                .metadata["opaque"] as? String,
            "preserved"
        )

        store.restoreFromSnapshot(
            workspaceId: workspace,
            surfaceId: invalidSurface,
            values: [
                MetadataKey.flag: " two lines\n",
                MetadataKey.suppressed: "true",
            ],
            sources: [
                MetadataKey.flag: .init(source: .explicit, ts: .nan),
                MetadataKey.suppressed: .init(source: .explicit, ts: -1),
            ]
        )
        let invalid = store.attentionSnapshot(workspaceId: workspace, surfaceId: invalidSurface)
        XCTAssertNil(invalid.flagReason)
        XCTAssertNil(invalid.flagRaisedAt)
        XCTAssertFalse(invalid.suppressed)
        XCTAssertNil(
            store.getSource(workspaceId: workspace, surfaceId: invalidSurface, key: MetadataKey.flag)
        )
        XCTAssertNil(
            store.getSource(
                workspaceId: workspace,
                surfaceId: invalidSurface,
                key: MetadataKey.suppressed
            )
        )
    }

    func testFlagOverridesSuppressionWithoutChangingRawLifecycle() {
        XCTAssertEqual(
            SurfaceAttentionSnapshot.presentedState(.waiting, flagged: false, suppressed: true),
            .idle
        )
        XCTAssertEqual(
            SurfaceAttentionSnapshot.presentedState(.waiting, flagged: true, suppressed: true),
            .waiting
        )
        XCTAssertEqual(
            SurfaceAttentionSnapshot.presentedState(.working, flagged: false, suppressed: true),
            .working
        )
    }

    func testEveryLifecycleFlagSuppressionCombination() {
        for state in WorkspacePulseState.allCases {
            for flagged in [false, true] {
                for suppressed in [false, true] {
                    let expected: WorkspacePulseState =
                        state == .waiting && suppressed && !flagged ? .idle : state
                    XCTAssertEqual(
                        SurfaceAttentionSnapshot.presentedState(
                            state,
                            flagged: flagged,
                            suppressed: suppressed
                        ),
                        expected,
                        "\(state) flagged=\(flagged) suppressed=\(suppressed)"
                    )
                }
            }
        }
    }

    func testSurfaceTabResolverUsesSuppressionOnlyForExactUnreadDemand() {
        XCTAssertEqual(
            SurfaceTabActivityResolver.resolve(
                hasExactSurfaceNotification: true,
                derivedActivity: .working,
                terminalType: "codex",
                flagged: false,
                suppressed: true
            ),
            .idle
        )
        XCTAssertEqual(
            SurfaceTabActivityResolver.resolve(
                hasExactSurfaceNotification: true,
                derivedActivity: .idle,
                terminalType: "codex",
                flagged: true,
                suppressed: true
            ),
            .waiting
        )
        XCTAssertEqual(
            SurfaceTabActivityResolver.resolve(
                hasExactSurfaceNotification: false,
                derivedActivity: .working,
                terminalType: "codex",
                flagged: false,
                suppressed: true
            ),
            .running
        )
    }

    func testOldestFlagOrderingUsesStableTieBreaks() {
        let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let surfaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let older = SurfaceAttentionSnapshot(
            workspaceId: workspaceB,
            surfaceId: surfaceB,
            flagReason: "older",
            flagRaisedAt: Date(timeIntervalSince1970: 10),
            suppressed: true
        )
        let tiedA = SurfaceAttentionSnapshot(
            workspaceId: workspaceA,
            surfaceId: surfaceA,
            flagReason: "tie A",
            flagRaisedAt: Date(timeIntervalSince1970: 20),
            suppressed: false
        )
        let tiedB = SurfaceAttentionSnapshot(
            workspaceId: workspaceB,
            surfaceId: surfaceA,
            flagReason: "tie B",
            flagRaisedAt: Date(timeIntervalSince1970: 20),
            suppressed: false
        )
        XCTAssertEqual(
            AttentionJumpSelector.orderedFlags([tiedB, older, tiedA]).map(\.flagReason),
            ["older", "tie A", "tie B"]
        )
    }

    func testFailClosedCommitGateCancelsPendingMutationAfterTimeout() {
        let mutationCount = AttentionTestBox(0)
        let scheduled = AttentionTestBox<(@Sendable () -> Void)?>(nil)
        let gate = FailClosedCommitGate<Int> {
            mutationCount.set(mutationCount.get() + 1)
            return 7
        }
        gate.enqueue { work in
            scheduled.set(work)
        }

        XCTAssertNil(gate.wait(timeout: 0.001))
        scheduled.get()?()
        XCTAssertEqual(mutationCount.get(), 0, "Timed-out pending work must be a permanent no-op")
    }

    func testFailClosedCommitGateWaitsThroughRunningCommitBeforeResponse() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let order = AttentionTestBox<[String]>([])
        let gate = FailClosedCommitGate<Int> {
            order.set(order.get() + ["commit.started"])
            started.signal()
            release.wait()
            order.set(order.get() + ["commit.finished"])
            return 9
        }
        gate.enqueue { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            release.signal()
        }

        XCTAssertEqual(gate.wait(timeout: 0.001), 9)
        order.set(order.get() + ["response"])
        XCTAssertEqual(order.get(), ["commit.started", "commit.finished", "response"])
    }

    func testFlagListSocketMethodReturnsOldestFirstWithCanonicalFields() {
        let workspace = UUID()
        let olderSurface = UUID()
        let newerSurface = UUID()
        let controller = TerminalController.shared
        SurfaceAttentionIndex.shared.publish(
            SurfaceAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: newerSurface,
                flagReason: "newer",
                flagRaisedAt: Date(timeIntervalSince1970: 20),
                suppressed: false
            )
        )
        SurfaceAttentionIndex.shared.publish(
            SurfaceAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: olderSurface,
                flagReason: "older",
                flagRaisedAt: Date(timeIntervalSince1970: 10),
                suppressed: true
            )
        )
        defer {
            SurfaceAttentionIndex.shared.remove(workspaceId: workspace, surfaceId: olderSurface)
            SurfaceAttentionIndex.shared.remove(workspaceId: workspace, surfaceId: newerSurface)
        }

        let response = AttentionTestBox<String?>(nil)
        let completed = expectation(description: "flag.list worker response")
        DispatchQueue.global(qos: .userInitiated).async {
            response.set(
                controller.socketWorkerV2Response(
                    TerminalController.V2SocketRequest(id: 17, method: "flag.list", params: [:])
                )
            )
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        let data = try! XCTUnwrap(response.get()?.data(using: .utf8))
        let object = try! XCTUnwrap(
            try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        let result = try! XCTUnwrap(object["result"] as? [String: Any])
        let flags = try! XCTUnwrap(result["flags"] as? [[String: Any]])
        XCTAssertEqual(result["count"] as? Int, 2)
        XCTAssertEqual(flags.compactMap { $0["reason"] as? String }, ["older", "newer"])
        XCTAssertEqual(flags.first?["suppressed"] as? Bool, true)
        XCTAssertEqual(flags.first?["workspace_id"] as? String, workspace.uuidString)
        XCTAssertEqual(flags.first?["surface_id"] as? String, olderSurface.uuidString)
    }

    func testLaunchSequencerStampsIdentityAndAttentionBeforeSendingCommand() {
        var order: [String] = []
        AgentLaunchAttentionSequencer.stampThenSend(
            stampIdentity: { order.append("identity") },
            stampSuppression: { order.append("suppression") },
            stampFlag: { order.append("flag") },
            sendCommand: { order.append("command") }
        )
        XCTAssertEqual(order, ["identity", "suppression", "flag", "command"])
    }

    func testNotificationIndexesRetainSuppressedHistoryButExcludeItsSignal() {
        let workspace = UUID()
        let suppressedSurface = UUID()
        let visibleSurface = UUID()
        let suppressed = notification(workspace: workspace, surface: suppressedSurface)
        let visible = notification(workspace: workspace, surface: visibleSurface)

        let indexes = TerminalNotificationStore.buildIndexes(
            for: [visible, suppressed],
            signalEligible: { $0.surfaceId != suppressedSurface }
        )
        XCTAssertEqual(indexes.rawUnreadCount, 2)
        XCTAssertEqual(indexes.unreadCount, 1)
        XCTAssertTrue(
            indexes.rawUnreadByTabSurface.contains(
                .init(tabId: workspace, surfaceId: suppressedSurface)
            )
        )
        XCTAssertFalse(
            indexes.unreadByTabSurface.contains(
                .init(tabId: workspace, surfaceId: suppressedSurface)
            )
        )
    }

    func testLowerIfFlaggedNoopsWhenUnflaggedAndLowersRaisedFlag() throws {
        let workspace = UUID()
        let surface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.configureDirectFlagAuthorizationHandlerForTesting { completion in
            completion(true)
        }
        notificationStore.configureDirectFlagAddHandlerForTesting { _, _ in }
        defer {
            notificationStore.resetDirectFlagDeliveryHandlersForTesting()
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }

        XCTAssertNil(
            try SurfaceAttentionService.shared.lowerIfFlagged(
                workspaceId: workspace,
                surfaceId: surface,
                by: .operator
            ),
            "lowerIfFlagged must be a no-op when nothing is raised (typing hot path)"
        )

        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Need operator input",
            title: nil
        )
        XCTAssertTrue(
            SurfaceAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged
        )

        XCTAssertNotNil(
            try SurfaceAttentionService.shared.lowerIfFlagged(
                workspaceId: workspace,
                surfaceId: surface,
                by: .operator
            )
        )
        XCTAssertFalse(
            SurfaceAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged
        )
    }

    func testSuppressionEdgesRetainRawHistoryWhileTogglingSignalDemand() throws {
        let workspace = UUID()
        let surface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        let originalNotifications = notificationStore.notifications
        var edges: [Bool] = []
        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureWaitingEdgeHandlerForTesting { entered, tabId in
            if tabId == workspace { edges.append(entered) }
        }
        defer {
            notificationStore.resetWaitingEdgeHandlerForTesting()
            notificationStore.replaceNotificationsForTesting(originalNotifications)
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }

        notificationStore.replaceNotificationsForTesting([
            notification(workspace: workspace, surface: surface)
        ])
        _ = try SurfaceAttentionService.shared.suppress(
            workspaceId: workspace,
            surfaceId: surface,
            by: .operator
        )
        XCTAssertEqual(notificationStore.rawUnreadCount, 1)
        XCTAssertEqual(notificationStore.unreadCount, 0)
        _ = try SurfaceAttentionService.shared.unsuppress(
            workspaceId: workspace,
            surfaceId: surface,
            by: .operator
        )
        XCTAssertEqual(notificationStore.rawUnreadCount, 1)
        XCTAssertEqual(notificationStore.unreadCount, 1)
        XCTAssertEqual(edges, [true, false, true])
    }

    func testRemoveAndPruneClearHistoryBeforeDroppingSuppressionProjection() {
        let workspace = UUID()
        let removedSurface = UUID()
        let prunedSurface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        let originalNotifications = notificationStore.notifications
        var edges: [Bool] = []
        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureWaitingEdgeHandlerForTesting { entered, tabId in
            if tabId == workspace { edges.append(entered) }
        }
        defer {
            notificationStore.resetWaitingEdgeHandlerForTesting()
            notificationStore.replaceNotificationsForTesting(originalNotifications)
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: removedSurface)
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: prunedSurface)
        }

        SurfaceAttentionService.shared.restore(
            SurfaceAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: removedSurface,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: true
            )
        )
        notificationStore.replaceNotificationsForTesting([
            notification(workspace: workspace, surface: removedSurface)
        ])
        XCTAssertEqual(notificationStore.rawUnreadCount, 1)
        XCTAssertEqual(notificationStore.unreadCount, 0)
        edges.removeAll()

        SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: removedSurface)
        XCTAssertEqual(notificationStore.rawUnreadCount, 0)
        XCTAssertEqual(notificationStore.unreadCount, 0)
        XCTAssertTrue(edges.isEmpty, "Close must not manufacture waiting.entered/left edges")
        XCTAssertFalse(
            SurfaceAttentionIndex.shared.snapshot(
                workspaceId: workspace,
                surfaceId: removedSurface
            ).suppressed
        )

        SurfaceAttentionService.shared.restore(
            SurfaceAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: prunedSurface,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: true
            )
        )
        notificationStore.replaceNotificationsForTesting([
            notification(workspace: workspace, surface: prunedSurface)
        ])
        edges.removeAll()
        SurfaceAttentionService.shared.prune(workspaceId: workspace, validSurfaceIds: [])
        XCTAssertEqual(notificationStore.rawUnreadCount, 0)
        XCTAssertTrue(edges.isEmpty, "Prune must not expose invalid-surface demand transiently")
        XCTAssertFalse(
            SurfaceAttentionIndex.shared.snapshot(
                workspaceId: workspace,
                surfaceId: prunedSurface
            ).suppressed
        )
    }

    func testGenericMetadataMutationCannotBypassAttentionService() throws {
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }

        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                partial: [MetadataKey.flag: "Bypass"],
                mode: .merge,
                source: .explicit
            )
        ) {
            XCTAssertEqual(($0 as? SurfaceMetadataStore.WriteError)?.code, "attention_requires_service")
        }
        XCTAssertFalse(
            store.setInternal(
                workspaceId: workspace,
                surfaceId: surface,
                key: MetadataKey.suppressed,
                value: true,
                source: .explicit
            )
        )
        _ = try store.mutateAttention(
            workspaceId: workspace,
            surfaceId: surface,
            flag: .raise("Canonical")
        )
        XCTAssertThrowsError(
            try store.clearMetadata(
                workspaceId: workspace,
                surfaceId: surface,
                keys: nil,
                source: .explicit
            )
        ) {
            XCTAssertEqual(($0 as? SurfaceMetadataStore.WriteError)?.code, "attention_requires_service")
        }
    }

    func testDirectFlagDeliveryPiercesSuppressionWithoutCreatingHistoryRecord() throws {
        let workspace = UUID()
        let surface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        let originalHistoryCount = notificationStore.notifications.count
        var delivered: [TerminalNotification] = []
        var replacementOrder: [String] = []
        notificationStore.configureFlagNotificationReplacementHandlerForTesting {
            identifier,
            add in
            replacementOrder.append("remove:\(identifier)")
            add()
        }
        notificationStore.configureDirectFlagAuthorizationHandlerForTesting { completion in
            completion(true)
        }
        notificationStore.configureDirectFlagAddHandlerForTesting { notification, _ in
            replacementOrder.append("add:\(notification.systemIdentifier ?? "")")
            delivered.append(notification)
        }
        defer {
            notificationStore.resetFlagNotificationReplacementHandlerForTesting()
            notificationStore.resetDirectFlagDeliveryHandlersForTesting()
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }

        _ = try SurfaceAttentionService.shared.suppress(
            workspaceId: workspace,
            surfaceId: surface,
            by: .operator
        )
        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Blocked on operator decision",
            title: "Build agent"
        )
        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Blocked on revised operator decision",
            title: "Build agent"
        )

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.last?.body, "Blocked on revised operator decision")
        XCTAssertEqual(delivered[0].systemIdentifier, delivered[1].systemIdentifier)
        XCTAssertEqual(
            replacementOrder,
            delivered.flatMap { notification in
                let identifier = notification.systemIdentifier ?? ""
                return ["remove:\(identifier)", "add:\(identifier)"]
            },
            "Each active-epoch revision must finish removal before scheduling its replacement"
        )
        XCTAssertEqual(notificationStore.notifications.count, originalHistoryCount)

        _ = try SurfaceAttentionService.shared.lower(
            workspaceId: workspace,
            surfaceId: surface,
            by: .operator
        )
        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "New active epoch",
            title: "Build agent"
        )
        XCTAssertEqual(delivered.count, 3)
        XCTAssertNotEqual(delivered[1].systemIdentifier, delivered[2].systemIdentifier)
    }

    func testLowerInvalidatesPendingDirectFlagAuthorizationBeforeExternalAdd() throws {
        let workspace = UUID()
        let surface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        var authorizationCompletions: [(Bool) -> Void] = []
        var added: [TerminalNotification] = []
        var customCommands: [TerminalNotification] = []
        notificationStore.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        notificationStore.configureDirectFlagAuthorizationHandlerForTesting { completion in
            authorizationCompletions.append(completion)
        }
        notificationStore.configureDirectFlagAddHandlerForTesting { notification, _ in
            added.append(notification)
        }
        notificationStore.configureDirectFlagCustomCommandHandlerForTesting {
            customCommands.append($0)
        }
        defer {
            notificationStore.resetFlagNotificationReplacementHandlerForTesting()
            notificationStore.resetDirectFlagDeliveryHandlersForTesting()
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }

        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Waiting for operator",
            title: "Build agent"
        )
        XCTAssertEqual(authorizationCompletions.count, 1)
        _ = try SurfaceAttentionService.shared.lower(
            workspaceId: workspace,
            surfaceId: surface,
            by: .operator
        )

        authorizationCompletions[0](true)
        XCTAssertTrue(added.isEmpty, "lowered flag must not resume a stale direct add")
        XCTAssertTrue(customCommands.isEmpty)
    }

    func testReasonRevisionSupersedesStaleAuthorizationAndAddCompletion() throws {
        let workspace = UUID()
        let surface = UUID()
        let notificationStore = TerminalNotificationStore.shared
        var authorizationCompletions: [(Bool) -> Void] = []
        var added: [TerminalNotification] = []
        var addCompletions: [(Error?) -> Void] = []
        var customCommands: [TerminalNotification] = []
        let customCommandRan = expectation(description: "latest direct flag custom command")
        notificationStore.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        notificationStore.configureDirectFlagAuthorizationHandlerForTesting { completion in
            authorizationCompletions.append(completion)
        }
        notificationStore.configureDirectFlagAddHandlerForTesting { notification, completion in
            added.append(notification)
            addCompletions.append(completion)
        }
        notificationStore.configureDirectFlagCustomCommandHandlerForTesting { notification in
            customCommands.append(notification)
            customCommandRan.fulfill()
        }
        defer {
            notificationStore.resetFlagNotificationReplacementHandlerForTesting()
            notificationStore.resetDirectFlagDeliveryHandlersForTesting()
            SurfaceAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }

        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "First reason",
            title: "Build agent"
        )
        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Second reason",
            title: "Build agent"
        )
        XCTAssertEqual(authorizationCompletions.count, 2)

        authorizationCompletions[0](true)
        XCTAssertTrue(added.isEmpty, "superseded authorization must not add stale content")
        authorizationCompletions[1](true)
        XCTAssertEqual(added.map(\.body), ["Second reason"])
        XCTAssertEqual(addCompletions.count, 1)

        _ = try SurfaceAttentionService.shared.raise(
            workspaceId: workspace,
            surfaceId: surface,
            reason: "Latest reason",
            title: "Build agent"
        )
        XCTAssertEqual(authorizationCompletions.count, 3)
        authorizationCompletions[2](true)
        XCTAssertEqual(added.map(\.body), ["Second reason", "Latest reason"])
        XCTAssertEqual(added[0].systemIdentifier, added[1].systemIdentifier)
        XCTAssertEqual(addCompletions.count, 2)

        addCompletions[0](nil)
        addCompletions[1](nil)
        wait(for: [customCommandRan], timeout: 1)
        XCTAssertEqual(customCommands.map(\.body), ["Latest reason"])
        XCTAssertEqual(added.last?.body, "Latest reason", "newest same-epoch delivery must survive")
    }

    private func notification(workspace: UUID, surface: UUID) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspace,
            surfaceId: surface,
            title: "Waiting",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
    }
}
