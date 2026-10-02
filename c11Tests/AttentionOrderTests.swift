import XCTest
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class AttentionOrderTests: XCTestCase {
    private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private func row(_ tab: Int, workspace: Int = 99, time: Int64? = 10, flag: Int64? = nil, flagged: Bool = false,
                     kind: FeedKind? = .question) -> FeedRow {
        FeedRow(workspaceID: uuid(workspace), tabID: uuid(tab), kind: kind, prompt: nil, options: nil,
                promptAvailable: false, source: "hook", sourceRank: 4, openedAtMs: time,
                state: kind == .turnEnd ? nil : "open", requestID: "r", confirmation: "confirmed",
                blocking: kind == .turnEnd ? false : true,
                flag: flagged ? .init(reason: "synthetic", raisedAtMs: flag, callerTabID: nil) : nil)
    }

    func testFlagsThenOldestAsksThenTurnsWithMissingTimesLastAndTabFirstTies() {
        let rows = [row(9, time: 1), row(8, time: 80, flag: 20, flagged: true),
                    row(7, time: 0, flag: 10, flagged: true), row(3, workspace: 90, time: 30),
                    row(4, workspace: 1, time: 30), row(5, time: nil),
                    row(2, flag: nil, flagged: true), row(1, time: 0, kind: .turnEnd)]
        for offset in 0..<rows.count {
            let rotated = Array(rows.dropFirst(offset)) + rows.prefix(offset)
            XCTAssertEqual(AttentionOrder.ordered(rotated).map(\.tabID), [7, 8, 2, 9, 3, 4, 5, 1].map(uuid))
        }
        let sameTab = [row(6, workspace: 90), row(6, workspace: 1)]
        XCTAssertEqual(AttentionOrder.ordered(sameTab).map(\.workspaceID), [uuid(1), uuid(90)])
        let flags = [row(4, workspace: 1, flag: 10, flagged: true), row(3, workspace: 90, flag: 10, flagged: true)]
        XCTAssertEqual(AttentionOrder.ordered(flags).map(\.tabID), [uuid(3), uuid(4)])
    }

    func testUnreadTailIsOldestFirstDeterministicAndDeduplicatedAfterPrefix() {
        func fact(_ tab: Int, _ time: Double, _ id: Int, workspace: Int = 99) -> AttentionOrder.UnreadFact {
            .init(target: .init(workspaceID: uuid(workspace), tabID: uuid(tab)), notificationID: uuid(id),
                  createdAt: Date(timeIntervalSince1970: time))
        }
        let facts = [fact(5, 30, 100), fact(3, 20, 103, workspace: 90), fact(4, 20, 104, workspace: 1),
                     fact(5, 5, 105), fact(2, 1, 106), fact(5, 5, 102)]
        let tail = AttentionOrder.unreadTail(facts)
        XCTAssertEqual(tail.map(\.notificationID), [106, 102, 103, 104].map(uuid))
        XCTAssertEqual(AttentionOrder.unreadTail(facts.reversed()), tail)
        let prefix = AttentionOrder.ordered([row(2, flag: 20, flagged: true), row(3, workspace: 90, time: 2)])
        let candidates = AttentionOrder.candidates(rows: prefix, unreadTail: tail)
        XCTAssertEqual(candidates.map { $0.target.tabID }, [2, 3, 5, 4].map(uuid))
        XCTAssertNil(candidates[0].notificationID)
        XCTAssertNil(candidates[1].notificationID)
        var attempted: [AttentionOrder.Candidate] = []
        let opened = AttentionOrder.openFirst(candidates) { candidate in
            attempted.append(candidate)
            return candidate.target.tabID == self.uuid(3)
        }
        XCTAssertEqual(attempted, Array(candidates.prefix(2)))
        XCTAssertEqual(opened, candidates[1])
        XCTAssertNil(AttentionOrder.openFirst(candidates) { _ in false })
        XCTAssertEqual(AttentionOrder.candidates(rows: [row(1, kind: .turnEnd)], unreadTail: tail), tail)
    }

    private func ask(_ tab: Int, time: Int64) throws -> JournalSnapshot {
        var draft = JournalTestData.draft(.questionRequested)
        draft.tabID = uuid(tab)
        draft.workspaceID = uuid(99)
        draft.requestID = "synthetic-request-\(tab)"
        var snapshot = try XCTUnwrap(JournalTestData.fold(nil, draft, seq: 1).snapshot)
        snapshot.sinceMs = time
        return snapshot
    }

    func testSuppressionFlagOverrideAndLowerKeepAskAgeAndSeparateCounts() throws {
        let asks = try [ask(1, time: 10), ask(2, time: 20), ask(3, time: 30)]
        func fact(_ tab: Int, flagged: Bool) -> FeedAttentionFact {
            .init(workspaceID: uuid(99), tabID: uuid(tab), flagReason: flagged ? "synthetic" : nil,
                  flagRaisedAtMs: flagged ? 40 : nil, flagCallerTabID: nil, suppressed: true)
        }
        let rows = FeedProjector.project(journalRows: asks, attention: [fact(1, flagged: false), fact(3, flagged: true)], notes: [:], scope: .attention)
        XCTAssertEqual(rows.map(\.tabID), [uuid(3), uuid(2)])
        let snapshot = FeedProjectionSnapshot(rows: rows)
        XCTAssertEqual(snapshot.flagCount, 1)
        XCTAssertEqual(snapshot.openAskCount, 2) // Flag + ask is not a third ask.
        let lowered = FeedProjector.project(journalRows: asks, attention: [fact(1, flagged: false)], notes: [:], scope: .attention)
        XCTAssertEqual(lowered.map(\.tabID), [uuid(2), uuid(3)])
        XCTAssertEqual(lowered.last?.openedAtMs, 30)
        XCTAssertEqual(FeedProjectionSnapshot(rows: [.init(workspaceID: uuid(99), tabID: uuid(9), kind: nil,
            prompt: nil, options: nil, promptAvailable: false, source: nil, sourceRank: nil, openedAtMs: nil,
            state: nil, requestID: nil, confirmation: nil, blocking: nil,
            flag: .init(reason: "synthetic", raisedAtMs: nil, callerTabID: nil))]).openAskCount, 0)
        XCTAssertEqual(FeedProjectionSnapshot(rows: [row(4, kind: .turnEnd)]).openAskCount, 0)
    }

    func testBridgePublishesOnlyChangedProjectionAndRemovalRetiresCounts() throws {
        let bridge = FeedProjectionBridge()
        let changed = expectation(description: "ordered immutable snapshots")
        changed.expectedFulfillmentCount = 3 // initial, ask, removal; identical journal is deduped
        let subscription = bridge.snapshots.sink { _ in changed.fulfill() }
        let snapshot = try ask(1, time: 10)
        bridge.noteJournal(tabID: uuid(1), snapshot: snapshot)
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot().openAskCount, 1)
        bridge.noteJournal(tabID: uuid(1), snapshot: snapshot)
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot().openAskCount, 1)
        bridge.removeTab(workspaceID: uuid(99), tabID: uuid(1))
        _ = bridge.list(scope: .attention)
        XCTAssertEqual(bridge.snapshot(), .empty)
        wait(for: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testMenuCountsKeepAttentionAndUnreadSemanticsSeparate() {
        let flag = TabAttentionSnapshot(workspaceId: uuid(99), surfaceId: uuid(1), flagReason: "synthetic",
                                        flagRaisedAt: Date(), suppressed: true)
        let suppressed = TabAttentionSnapshot(workspaceId: uuid(99), surfaceId: uuid(2), flagReason: nil,
                                              flagRaisedAt: nil, suppressed: true)
        let notices = [1, 2, 3].map { tab in
            TerminalNotification(id: uuid(tab + 10), workspaceId: uuid(99), surfaceId: uuid(tab), title: "synthetic",
                subtitle: "", body: "", createdAt: Date(), isRead: false)
        }
        let menu = NotificationMenuSnapshotBuilder.make(notifications: notices, flags: [flag],
            attentionSnapshots: [flag.id: flag, suppressed.id: suppressed], openAskCount: 2)
        XCTAssertEqual(menu.flagCount, 1)
        XCTAssertEqual(menu.openAskCount, 2)
        XCTAssertEqual(menu.unreadCount, 2)
        XCTAssertEqual(menu.stateHintTitle, "1 flag · 2 open asks · 2 unread notifications")
        let zero = NotificationMenuSnapshotBuilder.make(notifications: [])
        XCTAssertEqual(zero.stateHintTitle, "No flags · no open asks · No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.attentionCountTitle(flags: 0, asks: 1), "0 flags · 1 open ask")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.attentionCountTitle(flags: 1, asks: 0), "1 flag · 0 open asks")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 12), "9+")
    }
}
