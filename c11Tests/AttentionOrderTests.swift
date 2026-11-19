import XCTest
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class AttentionOrderTests: XCTestCase {
    private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private func row(_ panel: Int, workspace: Int = 99, time: Int64? = 10, flag: Int64? = nil, flagged: Bool = false,
                     kind: FeedKind? = .question) -> FeedRow {
        FeedRow(workspaceID: uuid(workspace), panelID: uuid(panel), kind: kind, prompt: nil, options: nil,
                promptAvailable: false, source: "hook", sourceRank: 4, openedAtMs: time,
                state: kind == .turnEnd ? nil : "open", requestID: "r", confirmation: "confirmed",
                blocking: kind == .turnEnd ? false : true,
                flag: flagged ? .init(reason: "synthetic", raisedAtMs: flag, callerPanelID: nil) : nil)
    }

    func testFlagsThenOldestAsksThenTurnsWithMissingTimesLastAndTabFirstTies() {
        let rows = [row(9, time: 1), row(8, time: 80, flag: 20, flagged: true),
                    row(7, time: 0, flag: 10, flagged: true), row(3, workspace: 90, time: 30),
                    row(4, workspace: 1, time: 30), row(5, time: nil),
                    row(2, flag: nil, flagged: true), row(1, time: 0, kind: .turnEnd)]
        for offset in 0..<rows.count {
            let rotated = Array(rows.dropFirst(offset)) + rows.prefix(offset)
            XCTAssertEqual(AttentionOrder.ordered(rotated).map(\.panelID), [7, 8, 2, 9, 3, 4, 5, 1].map(uuid))
        }
        let samePanel = [row(6, workspace: 90), row(6, workspace: 1)]
        XCTAssertEqual(AttentionOrder.ordered(samePanel).map(\.workspaceID), [uuid(1), uuid(90)])
        let flags = [row(4, workspace: 1, flag: 10, flagged: true), row(3, workspace: 90, flag: 10, flagged: true)]
        XCTAssertEqual(AttentionOrder.ordered(flags).map(\.panelID), [uuid(3), uuid(4)])
    }

    // C11H-262: jump order is a cycle starting after the panel the operator is on.
    func testArrangedWorkspaceFirstClearsCurrentWorkspaceAndCyclesEveryWorkspace() {
        func candidate(_ panel: Int, _ workspace: Int) -> AttentionOrder.Candidate {
            .init(target: .init(workspaceID: uuid(workspace), panelID: uuid(panel)), notificationID: nil)
        }
        func panels(_ queue: [AttentionOrder.Candidate], _ order: AttentionJumpOrder, workspace: Int?, panel: Int?) -> [Int] {
            let position = AttentionOrder.Position(workspaceID: workspace.map(uuid), panelID: panel.map(uuid))
            return AttentionOrder.arranged(queue, order: order, at: position).map { candidate in
                (1...9).first { uuid($0) == candidate.target.panelID }!
            }
        }
        // Queue order, oldest first: panels 1 (ws 10), 2 (ws 20), 3 (ws 10), 4 (ws 30), 5 (ws 20).
        let queue = [candidate(1, 10), candidate(2, 20), candidate(3, 10), candidate(4, 30), candidate(5, 20)]
        // In ws 20 on a panel with nothing up: ws 20 first, then the workspaces after it, wrapping.
        XCTAssertEqual(panels(queue, .workspaceFirst, workspace: 20, panel: 9), [2, 5, 4, 1, 3])
        XCTAssertEqual(panels(queue, .chronological, workspace: 20, panel: 9), [1, 2, 3, 4, 5])
        // On panel 2 (a flag that stays up): the next in ws 20, then onward; the current panel last.
        XCTAssertEqual(panels(queue, .workspaceFirst, workspace: 20, panel: 2), [5, 4, 1, 3, 2])
        // On ws 20's last item: leave the workspace rather than bounce back to panel 2.
        XCTAssertEqual(panels(queue, .workspaceFirst, workspace: 20, panel: 5), [4, 1, 3, 2, 5])
        XCTAssertEqual(panels(queue, .chronological, workspace: 10, panel: 3), [4, 5, 1, 2, 3])
        // A workspace with nothing waiting goes to the oldest elsewhere.
        XCTAssertEqual(panels(queue, .workspaceFirst, workspace: 40, panel: 7), [1, 3, 2, 5, 4])
        XCTAssertEqual(panels(queue, .workspaceFirst, workspace: nil, panel: nil), [1, 3, 2, 5, 4])

        // One flag per workspace that stays up: repeated jumps visit A, B, C, A.
        let flags = [candidate(1, 10), candidate(2, 20), candidate(3, 30)]
        var at = (workspace: 10, panel: 1)
        var visited: [Int] = []
        for _ in 0..<3 {
            let next = panels(flags, .workspaceFirst, workspace: at.workspace, panel: at.panel)[0]
            visited.append(next)
            at = (workspace: [1: 10, 2: 20, 3: 30][next]!, panel: next)
        }
        XCTAssertEqual(visited, [2, 3, 1])
        // The only candidate is the current panel: the jump stays there.
        XCTAssertEqual(panels([candidate(1, 10)], .workspaceFirst, workspace: 10, panel: 1), [1])
    }

    func testJumpOrderSettingDefaultsToWorkspaceFirst() {
        let suite = "AttentionJumpOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AttentionJumpOrder.current(defaults: defaults), .workspaceFirst)
        defaults.set("chronological", forKey: AttentionJumpOrder.storageKey)
        XCTAssertEqual(AttentionJumpOrder.current(defaults: defaults), .chronological)
        defaults.set("bogus", forKey: AttentionJumpOrder.storageKey)
        XCTAssertEqual(AttentionJumpOrder.current(defaults: defaults), .workspaceFirst)
    }

    func testUnreadTailIsOldestFirstDeterministicAndDeduplicatedAfterPrefix() {
        func fact(_ panel: Int, _ time: Double, _ id: Int, workspace: Int = 99) -> AttentionOrder.UnreadFact {
            .init(target: .init(workspaceID: uuid(workspace), panelID: uuid(panel)), notificationID: uuid(id),
                  createdAt: Date(timeIntervalSince1970: time))
        }
        let facts = [fact(5, 30, 100), fact(3, 20, 103, workspace: 90), fact(4, 20, 104, workspace: 1),
                     fact(5, 5, 105), fact(2, 1, 106), fact(5, 5, 102)]
        let tail = AttentionOrder.unreadTail(facts)
        XCTAssertEqual(tail.map(\.notificationID), [106, 102, 103, 104].map(uuid))
        XCTAssertEqual(AttentionOrder.unreadTail(facts.reversed()), tail)
        let prefix = AttentionOrder.ordered([row(2, flag: 20, flagged: true), row(3, workspace: 90, time: 2)])
        let candidates = AttentionOrder.candidates(rows: prefix, unreadTail: tail)
        XCTAssertEqual(candidates.map { $0.target.panelID }, [2, 3, 5, 4].map(uuid))
        XCTAssertNil(candidates[0].notificationID)
        XCTAssertNil(candidates[1].notificationID)
        var attempted: [AttentionOrder.Candidate] = []
        let opened = AttentionOrder.openFirst(candidates) { candidate in
            attempted.append(candidate)
            return candidate.target.panelID == self.uuid(3)
        }
        XCTAssertEqual(attempted, Array(candidates.prefix(2)))
        XCTAssertEqual(opened, candidates[1])
        XCTAssertNil(AttentionOrder.openFirst(candidates) { _ in false })
        XCTAssertEqual(AttentionOrder.candidates(rows: [row(1, kind: .turnEnd)], unreadTail: tail), tail)
    }

    private func ask(_ panel: Int, time: Int64) throws -> JournalSnapshot {
        var draft = JournalTestData.draft(.questionRequested)
        draft.panelID = uuid(panel)
        draft.workspaceID = uuid(99)
        draft.requestID = "synthetic-request-\(panel)"
        var snapshot = try XCTUnwrap(JournalTestData.fold(nil, draft, seq: 1).snapshot)
        snapshot.sinceMs = time
        return snapshot
    }

    func testSuppressionFlagOverrideAndLowerKeepAskAgeAndSeparateCounts() throws {
        let asks = try [ask(1, time: 10), ask(2, time: 20), ask(3, time: 30)]
        func fact(_ panel: Int, flagged: Bool) -> FeedAttentionFact {
            .init(workspaceID: uuid(99), panelID: uuid(panel), flagReason: flagged ? "synthetic" : nil,
                  flagRaisedAtMs: flagged ? 40 : nil, flagCallerPanelID: nil, suppressed: true)
        }
        let rows = FeedProjector.project(journalRows: asks, attention: [fact(1, flagged: false), fact(3, flagged: true)], notes: [:], scope: .attention)
        XCTAssertEqual(rows.map(\.panelID), [uuid(3), uuid(2)])
        let snapshot = FeedProjectionSnapshot(rows: rows)
        XCTAssertEqual(snapshot.flagCount, 1)
        XCTAssertEqual(snapshot.openAskCount, 2) // Flag + ask is not a third ask.
        let lowered = FeedProjector.project(journalRows: asks, attention: [fact(1, flagged: false)], notes: [:], scope: .attention)
        XCTAssertEqual(lowered.map(\.panelID), [uuid(2), uuid(3)])
        XCTAssertEqual(lowered.last?.openedAtMs, 30)
        XCTAssertEqual(FeedProjectionSnapshot(rows: [.init(workspaceID: uuid(99), panelID: uuid(9), kind: nil,
            prompt: nil, options: nil, promptAvailable: false, source: nil, sourceRank: nil, openedAtMs: nil,
            state: nil, requestID: nil, confirmation: nil, blocking: nil,
            flag: .init(reason: "synthetic", raisedAtMs: nil, callerPanelID: nil))]).openAskCount, 0)
        XCTAssertEqual(FeedProjectionSnapshot(rows: [row(4, kind: .turnEnd)]).openAskCount, 0)
    }

    func testBridgePublishesOnlyChangedProjectionAndRemovalRetiresCounts() throws {
        let bridge = FeedProjectionBridge()
        let changed = expectation(description: "ordered immutable snapshots")
        changed.expectedFulfillmentCount = 3 // initial, ask, removal; identical journal is deduped
        let subscription = bridge.snapshots.sink { _ in changed.fulfill() }
        let snapshot = try ask(1, time: 10)
        bridge.noteJournal(panelID: uuid(1), snapshot: snapshot)
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot().openAskCount, 1)
        bridge.noteJournal(panelID: uuid(1), snapshot: snapshot)
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot().openAskCount, 1)
        bridge.removePanel(workspaceID: uuid(99), panelID: uuid(1))
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot(), .empty)
        wait(for: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testMenuCountsKeepAttentionAndUnreadSemanticsSeparate() {
        let flag = PanelAttentionSnapshot(workspaceId: uuid(99), surfaceId: uuid(1), flagReason: "synthetic",
                                        flagRaisedAt: Date(), suppressed: true)
        let suppressed = PanelAttentionSnapshot(workspaceId: uuid(99), surfaceId: uuid(2), flagReason: nil,
                                              flagRaisedAt: nil, suppressed: true)
        let notices = [1, 2, 3].map { panel in
            TerminalNotification(id: uuid(panel + 10), workspaceId: uuid(99), surfaceId: uuid(panel), title: "synthetic",
                subtitle: "", body: "", createdAt: Date(), isRead: false)
        }
        let menu = NotificationMenuSnapshotBuilder.make(notifications: notices, flags: [flag],
            attentionSnapshots: [flag.id: flag, suppressed.id: suppressed], openAskCount: 2)
        XCTAssertEqual(menu.flagCount, 1)
        XCTAssertEqual(menu.openAskCount, 2)
        XCTAssertEqual(menu.unreadCount, 2)
        XCTAssertEqual(menu.attentionStateHintTitle, "1 flag · 2 open asks · 2 unread notifications")
        let zero = NotificationMenuSnapshotBuilder.make(notifications: [])
        XCTAssertEqual(zero.attentionStateHintTitle, "No flags · no open asks · No unread notifications")
        XCTAssertEqual(zero.stateHintTitle, "No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.attentionCountTitle(flags: 0, asks: 1), "0 flags · 1 open ask")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.attentionCountTitle(flags: 1, asks: 0), "1 flag · 0 open asks")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 12), "9+")
    }
}

final class PanelCloseForGoodPolicyTests: XCTestCase {
    func testOnlyFinalNonDetachingCloseOutsideAppTerminationFires() {
        XCTAssertTrue(PanelCloseForGoodPolicy.shouldFire(isDetaching: false, isTerminatingApp: false))
        XCTAssertFalse(PanelCloseForGoodPolicy.shouldFire(isDetaching: true, isTerminatingApp: false))
        XCTAssertFalse(PanelCloseForGoodPolicy.shouldFire(isDetaching: false, isTerminatingApp: true))
        XCTAssertFalse(PanelCloseForGoodPolicy.shouldFire(isDetaching: true, isTerminatingApp: true))
    }
}

final class PanelLineageStoreTests: XCTestCase {
    private let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testReinsertingMovedPanelKeepsItsOriginalParent() throws {
        let root = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondRoot = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let child = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        var store = PanelLineageStore()
        _ = store.insert(panelId: root, creatorPanelId: nil, workspaceId: workspaceId, workspaceTitle: "Work", title: "A", type: "terminal", agentType: nil)
        _ = store.insert(panelId: secondRoot, creatorPanelId: nil, workspaceId: workspaceId, workspaceTitle: "Work", title: "B", type: "terminal", agentType: nil)
        _ = store.insert(panelId: child, creatorPanelId: root, workspaceId: workspaceId, workspaceTitle: "Work", title: "Child", type: "terminal", agentType: nil)

        _ = store.insert(panelId: child, creatorPanelId: secondRoot, workspaceId: workspaceId, workspaceTitle: "Moved", title: "Child", type: "terminal", agentType: nil)
        _ = store.insert(panelId: root, creatorPanelId: child, workspaceId: workspaceId, workspaceTitle: "Moved", title: "A", type: "terminal", agentType: nil)

        XCTAssertEqual(try XCTUnwrap(store.node(panelId: child)).parentPanelId, root)
        XCTAssertEqual(store.node(panelId: child)?.workspaceTitle, "Moved")
        XCTAssertNil(store.node(panelId: root)?.parentPanelId)
    }

    func testUnknownCreatorLeavesPanelAsRoot() {
        let missingCreator = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        let panel = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        var store = PanelLineageStore()

        let parentId = store.insert(
            panelId: panel,
            creatorPanelId: missingCreator,
            workspaceId: workspaceId,
            workspaceTitle: "Work",
            title: "Panel",
            type: "terminal",
            agentType: nil
        )

        XCTAssertNil(parentId)
        XCTAssertNil(store.node(panelId: panel)?.parentPanelId)
    }

    func testFamilyRetainsClosedAncestorsUntilLastLiveDescendantCloses() throws {
        let root = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let parent = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let child = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let sibling = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        let grandchild = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        var store = PanelLineageStore()
        _ = store.insert(panelId: root, creatorPanelId: nil, workspaceId: workspaceId, workspaceTitle: "Work", title: "A", type: "terminal", agentType: nil)
        _ = store.insert(panelId: parent, creatorPanelId: root, workspaceId: workspaceId, workspaceTitle: "Work", title: "B", type: "terminal", agentType: nil)
        _ = store.insert(panelId: child, creatorPanelId: parent, workspaceId: workspaceId, workspaceTitle: "Work", title: "C", type: "terminal", agentType: "codex")
        _ = store.insert(panelId: sibling, creatorPanelId: parent, workspaceId: workspaceId, workspaceTitle: "Work", title: "C2", type: "terminal", agentType: nil)
        _ = store.insert(panelId: grandchild, creatorPanelId: child, workspaceId: workspaceId, workspaceTitle: "Work", title: "D", type: "terminal", agentType: nil)

        store.close(panelId: root, at: Date(timeIntervalSince1970: 10))
        store.close(panelId: parent, at: Date(timeIntervalSince1970: 20))
        store.close(panelId: child, at: Date(timeIntervalSince1970: 25))

        let family = try XCTUnwrap(store.family(startingAt: grandchild))
        XCTAssertEqual(family.rootId, root)
        XCTAssertEqual(family.nodes.map(\.id), [root, parent, child, grandchild, sibling])
        XCTAssertTrue(try XCTUnwrap(store.node(panelId: parent)).isClosed)
        XCTAssertTrue(try XCTUnwrap(store.node(panelId: child)).isClosed)

        store.close(panelId: sibling, at: Date(timeIntervalSince1970: 30))
        store.close(panelId: grandchild, at: Date(timeIntervalSince1970: 40))
        XCTAssertNil(store.node(panelId: root))
        XCTAssertNil(store.node(panelId: parent))
        XCTAssertNil(store.node(panelId: child))
        XCTAssertNil(store.node(panelId: sibling))
        XCTAssertNil(store.node(panelId: grandchild))
    }

    func testLineageSnapshotRoundTripsAndRestorePrunesUnrestoredBranch() throws {
        let root = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        let child = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        let orphan = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        let orphanChild = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
        var original = PanelLineageStore()
        _ = original.insert(panelId: root, creatorPanelId: nil, workspaceId: workspaceId, workspaceTitle: "Work", title: "Root", type: "terminal", agentType: nil)
        _ = original.insert(panelId: child, creatorPanelId: root, workspaceId: workspaceId, workspaceTitle: "Work", title: "Child", type: "terminal", agentType: "claude")
        _ = original.insert(panelId: orphan, creatorPanelId: nil, workspaceId: workspaceId, workspaceTitle: "Other", title: "Orphan", type: "terminal", agentType: nil)
        _ = original.insert(panelId: orphanChild, creatorPanelId: orphan, workspaceId: workspaceId, workspaceTitle: "Other", title: "Orphan child", type: "terminal", agentType: nil)
        let data = try JSONEncoder().encode(original.snapshot())
        let restoredNodes = try JSONDecoder().decode([PanelLineageNode].self, from: data)
        var restored = PanelLineageStore(nodes: restoredNodes)

        restored.finishRestore(livePanelIds: [child], at: Date(timeIntervalSince1970: 40))

        XCTAssertEqual(restored.node(panelId: root)?.parentPanelId, nil)
        XCTAssertTrue(try XCTUnwrap(restored.node(panelId: root)).isClosed)
        XCTAssertEqual(restored.node(panelId: child)?.parentPanelId, root)
        XCTAssertEqual(restored.node(panelId: child)?.agentType, "claude")
        XCTAssertNil(restored.node(panelId: orphan))
        XCTAssertNil(restored.node(panelId: orphanChild))

        let childLineage = try XCTUnwrap(restored.node(panelId: child))
        let encodedLineage = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(childLineage)) as? [String: Any]
        )
        XCTAssertNil(encodedLineage[MetadataKey.delegated])
        XCTAssertNil(encodedLineage[MetadataKey.delegatedBy])
    }

    // MARK: C11H-260 origins

    func testNodesPersistedBeforeOriginsDecodeFromWhatWasObserved() throws {
        let root = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
        let child = UUID(uuidString: "00000000-0000-0000-0000-000000000082")!
        let legacy = """
        [{"id":"\(root.uuidString)","workspace_id":"\(workspaceId.uuidString)","workspace_title":"Work",
          "last_title":"Root","panel_type":"terminal"},
         {"id":"\(child.uuidString)","parent_panel_id":"\(root.uuidString)","workspace_id":"\(workspaceId.uuidString)",
          "workspace_title":"Work","last_title":"Child","panel_type":"terminal","agent_type":"claude"}]
        """
        let nodes = try JSONDecoder().decode([PanelLineageNode].self, from: Data(legacy.utf8))
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        // A null parent is not evidence of the operator: it reads unknown.
        XCTAssertEqual(byId[root]?.origin, .unknown)
        XCTAssertNil(byId[root]?.originDetail)
        // A recorded parent was observed: the child was made from it.
        XCTAssertEqual(byId[child]?.origin, .panel)

        let future = """
        {"id":"\(root.uuidString)","origin":"satellite","origin_detail":"x","workspace_id":"\(workspaceId.uuidString)",
         "workspace_title":"Work","last_title":"Root","panel_type":"terminal"}
        """
        let unknownValue = try JSONDecoder().decode(PanelLineageNode.self, from: Data(future.utf8))
        XCTAssertEqual(unknownValue.origin, .unknown)
        XCTAssertNil(unknownValue.originDetail)
    }

    func testInsertRecordsOriginOnceAndNeverInventsOne() throws {
        let root = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        let child = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        let restored = UUID(uuidString: "00000000-0000-0000-0000-000000000093")!
        let orphan = UUID(uuidString: "00000000-0000-0000-0000-000000000094")!
        let cli = UUID(uuidString: "00000000-0000-0000-0000-000000000095")!
        let lost = UUID(uuidString: "00000000-0000-0000-0000-000000000096")!
        var store = PanelLineageStore()
        func insert(_ id: UUID, creator: UUID? = nil, _ origin: PanelOriginRequest) {
            store.insert(panelId: id, creatorPanelId: creator, origin: origin, workspaceId: workspaceId,
                         workspaceTitle: "Work", title: "P", type: "terminal", agentType: nil)
        }
        insert(root, .operator)
        insert(child, creator: root, .operator)
        insert(restored, .app(PanelOriginRequest.AppReason.restore))
        insert(orphan, PanelOriginRequest(origin: .panel))
        insert(cli, .external)
        insert(lost, creator: UUID(), .operator)

        XCTAssertEqual(store.node(panelId: root)?.origin, .operator)
        XCTAssertNil(store.node(panelId: root)?.originDetail)
        // A creator panel decides over any scope around it.
        XCTAssertEqual(store.node(panelId: child)?.origin, .panel)
        XCTAssertEqual(store.node(panelId: child)?.parentPanelId, root)
        XCTAssertEqual(store.node(panelId: restored)?.origin, .app)
        XCTAssertEqual(store.node(panelId: restored)?.originDetail, "restore")
        // `panel` without a creator, or with one the graph never saw, is unknown.
        XCTAssertEqual(store.node(panelId: orphan)?.origin, .unknown)
        XCTAssertEqual(store.node(panelId: lost)?.origin, .unknown)
        XCTAssertNil(store.node(panelId: lost)?.parentPanelId)
        XCTAssertEqual(store.node(panelId: cli)?.origin, .external)

        // A move re-inserts: the first origin stays.
        insert(root, .external)
        insert(restored, .operator)
        XCTAssertEqual(store.node(panelId: root)?.origin, .operator)
        XCTAssertEqual(store.node(panelId: restored)?.originDetail, "restore")

        // Origins survive the session snapshot.
        let decoded = try JSONDecoder().decode(
            [PanelLineageNode].self, from: JSONEncoder().encode(store.snapshot())
        )
        XCTAssertEqual(PanelLineageStore(nodes: decoded), store)
    }

    func testCreatedAtIsStampedOnceAndOldNodesHaveNone() throws {
        let launch = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        var store = PanelLineageStore()
        let first = Date(timeIntervalSince1970: 1_000)
        store.insert(panelId: launch, creatorPanelId: nil, origin: .app(PanelOriginRequest.AppReason.launch), at: first,
                     workspaceId: workspaceId, workspaceTitle: "Work", title: "P", type: "terminal", agentType: nil)
        // A move re-inserts later: the first appearance stays.
        store.insert(panelId: launch, creatorPanelId: nil, origin: .operator, at: Date(timeIntervalSince1970: 2_000),
                     workspaceId: workspaceId, workspaceTitle: "Moved", title: "P", type: "terminal", agentType: nil)
        let node = try XCTUnwrap(store.node(panelId: launch))
        XCTAssertEqual(node.createdAt, first)
        XCTAssertEqual(node.originDetail, "launch")
        let decoded = try JSONDecoder().decode(PanelLineageNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded.createdAt, first)

        let legacy = """
        {"id":"\(launch.uuidString)","workspace_id":"\(workspaceId.uuidString)","workspace_title":"Work",
         "last_title":"Root","panel_type":"terminal"}
        """
        XCTAssertNil(try JSONDecoder().decode(PanelLineageNode.self, from: Data(legacy.utf8)).createdAt)

        // JSON carries a numeric local offset, never Z, and parses back to the same instant.
        let winter = Date(timeIntervalSince1970: 1_763_056_620) // 2025-11-13T17:57:00Z
        let summer = Date(timeIntervalSince1970: 1_752_429_420) // 2025-07-13T17:57:00Z
        let cases: [(String, Date, String)] = [
            ("Europe/London", winter, "2025-11-13T17:57:00+00:00"),
            ("Europe/London", summer, "2025-07-13T18:57:00+01:00"),
            ("America/Los_Angeles", winter, "2025-11-13T09:57:00-08:00"),
            ("America/Los_Angeles", summer, "2025-07-13T10:57:00-07:00"),
            ("Asia/Kolkata", winter, "2025-11-13T23:27:00+05:30"),
        ]
        for (zone, date, expected) in cases {
            let stamp = PanelLineageNode.localTimestamp(date, timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
            XCTAssertEqual(stamp, expected, zone)
            XCTAssertEqual(ISO8601DateFormatter().date(from: stamp), date, zone)
        }
    }

    func testOriginResolutionPrecedence() {
        let caller = UUID()
        func resolve(
            creator: UUID? = nil, socket: Bool = false, socketCaller: UUID? = nil, app: String? = nil,
            restoring: Bool = false, external: Bool = false, operatorScope: Bool = false
        ) -> (UUID?, PanelOriginRequest) {
            let r = PanelOriginRequest.resolve(
                creatorPanelId: creator, socketRequest: socketCaller, inSocketRequest: socket,
                appReason: app, restoringSession: restoring, externalScope: external, operatorScope: operatorScope)
            return (r.creatorPanelId, r.origin)
        }
        XCTAssertEqual(resolve().1, .unknown)
        XCTAssertEqual(resolve(operatorScope: true).1, .operator)
        XCTAssertEqual(resolve(external: true, operatorScope: true).1, .external)
        XCTAssertEqual(resolve(restoring: true, operatorScope: true).1, .app("restore"))
        XCTAssertEqual(resolve(app: "chaos", restoring: true, operatorScope: true).1, .app("chaos"))
        // Any socket request outranks every scope: no caller panel is external.
        XCTAssertEqual(resolve(socket: true, app: "chaos", operatorScope: true).1, .external)
        let viaSocket = resolve(socket: true, socketCaller: caller, operatorScope: true)
        XCTAssertEqual(viaSocket.0, caller)
        XCTAssertEqual(viaSocket.1.origin, .panel)
        XCTAssertEqual(resolve(creator: caller, socket: true).0, caller)
    }
}
