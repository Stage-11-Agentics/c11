import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

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
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, notification in
            delivered.append(notification)
        }
        defer {
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            store.removeSurface(workspaceId: workspace, surfaceId: surface)
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

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.body, "Blocked on operator decision")
        XCTAssertEqual(notificationStore.notifications.count, originalHistoryCount)
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
