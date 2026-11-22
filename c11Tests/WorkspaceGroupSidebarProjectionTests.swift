import XCTest
import Bonsplit
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceGroupSidebarProjectionTests: XCTestCase {
    func testTileRunsKeepFolderBoundariesAndCanonicalRowMajorOrder() {
        let group = WorkspaceGroup(name: "Three members")
        let empty = WorkspaceGroup(name: "Empty")
        let ids = (0..<6).map { _ in UUID() }
        let entries = ids.enumerated().map { index, id in
            WorkspaceOrderEntry(id: id, isPinned: false, groupId: index < 3 ? group.id : nil)
        }
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group, empty], workspaces: entries)
        let runs = WorkspaceSidebarTileRun.pack(projection.rows)
        XCTAssertEqual(runs.map { $0.rows.count }, [1, 3, 1, 3])
        XCTAssertEqual(runs.flatMap { $0.rows.map(\.id) }, projection.rows.map(\.id))
        XCTAssertEqual(Set(runs.map(\.id)).count, runs.count)
        var collapsed = group
        collapsed.isCollapsed = true
        let hidden = WorkspaceGroupSidebarProjection.make(groups: [collapsed, empty], workspaces: entries)
        XCTAssertEqual(WorkspaceSidebarTileRun.pack(hidden.rows).map { $0.rows.count }, [1, 1, 3])
        XCTAssertTrue(WorkspaceSidebarTileRun.pack([]).isEmpty)
    }

    func testTileRunLinesSplitRowMajorWithoutDroppingOrReorderingCards() {
        let entries = (0..<5).map { _ in WorkspaceOrderEntry(id: UUID(), isPinned: false) }
        let projection = WorkspaceGroupSidebarProjection.make(groups: [], workspaces: entries)
        let run = WorkspaceSidebarTileRun(rows: projection.rows)
        for (columns, expected) in [(2, [2, 2, 1]), (3, [3, 2]), (5, [5]), (8, [5]), (0, [1, 1, 1, 1, 1])] {
            let lines = run.lines(columns: columns)
            XCTAssertEqual(lines.map { $0.rows.count }, expected, "columns=\(columns)")
            XCTAssertEqual(lines.flatMap { $0.rows.map(\.id) }, projection.rows.map(\.id))
            XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
        }
        XCTAssertTrue(WorkspaceSidebarTileRun(rows: []).lines(columns: 2).isEmpty)
    }

    func testRootSegmentsUseGroupPinAndCanonicalMemberIndexes() {
        let pinned = WorkspaceGroup(name: "Pinned", isPinned: true)
        let unpinned = WorkspaceGroup(name: "Unpinned")
        let ids = (0..<5).map { _ in UUID() }
        let workspaces = [
            WorkspaceOrderEntry(id: ids[0], isPinned: true, groupId: unpinned.id),
            WorkspaceOrderEntry(id: ids[1], isPinned: true),
            WorkspaceOrderEntry(id: ids[2], isPinned: false, groupId: pinned.id),
            WorkspaceOrderEntry(id: ids[3], isPinned: false, groupId: unpinned.id),
            WorkspaceOrderEntry(id: ids[4], isPinned: false)
        ]
        let projection = WorkspaceGroupSidebarProjection.make(groups: [unpinned, pinned], workspaces: workspaces)
        XCTAssertEqual(projection.rows.map(\.id), [.group(pinned.id), .workspace(ids[2]), .workspace(ids[1]),
                                                   .group(unpinned.id), .workspace(ids[0]), .workspace(ids[3]), .workspace(ids[4])])
        let rows = projection.rows.compactMap { row -> WorkspaceGroupSidebarWorkspaceRow? in
            if case .workspace(let value) = row { return value }; return nil
        }
        XCTAssertEqual(rows.map(\.canonicalIndex), [2, 1, 0, 3, 4])
        XCTAssertEqual(projection.visibleWorkspaceIds, rows.map(\.workspaceId))
        XCTAssertEqual(rows[2].groupId, unpinned.id)
    }

    func testCollapseHidesOnlyMembersAndRetainsActiveHeaderAndCanonicalInput() {
        var group = WorkspaceGroup(name: "Work")
        let selected = UUID(), other = UUID()
        let workspaces = [WorkspaceOrderEntry(id: selected, isPinned: true, groupId: group.id),
                          WorkspaceOrderEntry(id: other, isPinned: false)]
        let expanded = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: workspaces,
                                                           selectedWorkspaceId: selected)
        group.isCollapsed = true
        let collapsed = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: workspaces,
                                                            selectedWorkspaceId: selected)
        XCTAssertEqual(expanded.visibleWorkspaceIds, [selected, other])
        XCTAssertEqual(collapsed.visibleWorkspaceIds, [other])
        XCTAssertEqual(collapsed.rows.map(\.id), [.group(group.id), .workspace(other)])
        XCTAssertEqual(collapsed.headersById[group.id]?.isActive, true)
        XCTAssertEqual(collapsed.headersById[group.id]?.summary.memberCount, 1)
        XCTAssertEqual(workspaces.map(\.id), [selected, other])
        XCTAssertEqual(workspaces[0].groupId, group.id)
    }

    func testEmptyFoldersAndNamespacedIdentitiesSurviveProjection() {
        let id = UUID()
        let group = WorkspaceGroup(id: id, name: "Empty", isCollapsed: true)
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group],
            workspaces: [WorkspaceOrderEntry(id: id, isPinned: false)])
        XCTAssertEqual(projection.rows.map(\.id), [.group(id), .workspace(id)])
        XCTAssertEqual(Set(projection.rows.map(\.id)).count, 2)
        XCTAssertEqual(projection.headersById[id]?.summary, .zero)
        XCTAssertEqual(projection.headersById[id]?.isActive, false)
    }

    func testFlagsIncludeSuppressedAndNonAgentTabsButWaitingHasNoUnreadFallback() {
        let member = WorkspaceGroupMemberAttention(panels: [
            .init(isFlagged: false, isWaiting: true, isSuppressed: false),
            .init(isFlagged: false, isWaiting: true, isSuppressed: true),
            .init(isFlagged: true, isWaiting: true, isSuppressed: true),
            // A plain/non-agent tab has no waiting state but still contributes its flag.
            .init(isFlagged: true, isWaiting: false, isSuppressed: false)
        ], unreadCount: 3)
        XCTAssertEqual(member.flaggedCount, 2)
        XCTAssertEqual(member.waitingCount, 1)
        XCTAssertEqual(member.unreadCount, 3)
        let onlyUnread = WorkspaceGroupMemberAttention(unreadCount: 7)
        XCTAssertEqual(onlyUnread.waitingCount, 0)
        XCTAssertEqual(onlyUnread.flaggedCount, 0)
    }

    func testCollapsedSummaryIncludesEveryMemberAndNotificationDemandOnce() {
        let group = WorkspaceGroup(name: "Collapsed", isCollapsed: true)
        let a = UUID(), b = UUID()
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: [
            WorkspaceOrderEntry(id: a, isPinned: false, groupId: group.id),
            WorkspaceOrderEntry(id: b, isPinned: false, groupId: group.id)
        ], attentionByWorkspace: [
            a: .init(panels: [.init(isFlagged: true, isWaiting: true, isSuppressed: true)], unreadCount: 2),
            b: .init(panels: [.init(isFlagged: false, isWaiting: true, isSuppressed: false)], unreadCount: 1)
        ])
        XCTAssertEqual(projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 2, flaggedCount: 1, waitingCount: 1, unreadCount: 3))
        XCTAssertTrue(projection.visibleWorkspaceIds.isEmpty)
    }

    func testMembershipTransferSubtractsOldHeaderAndAddsNewHeaderWithoutChangingRowIdentity() {
        let a = WorkspaceGroup(name: "A"), b = WorkspaceGroup(name: "B")
        let id = UUID()
        let attention: [UUID: WorkspaceGroupMemberAttention] = [id: .init(
            panels: [.init(isFlagged: true, isWaiting: true, isSuppressed: false)], unreadCount: 2)]
        let before = WorkspaceGroupSidebarProjection.make(groups: [a, b],
            workspaces: [.init(id: id, isPinned: false, groupId: a.id)], attentionByWorkspace: attention)
        let after = WorkspaceGroupSidebarProjection.make(groups: [a, b],
            workspaces: [.init(id: id, isPinned: false, groupId: b.id)], attentionByWorkspace: attention)
        XCTAssertEqual(after.headersById[a.id]?.summary, .zero)
        XCTAssertEqual(after.headersById[b.id]?.summary, before.headersById[a.id]?.summary)
        XCTAssertEqual(before.visibleWorkspaceIds, after.visibleWorkspaceIds)
        XCTAssertEqual(after.rows.last?.id, .workspace(id))
    }

    func testDeletedOrUnknownGroupLeavesMemberReachableUngrouped() {
        let id = UUID()
        let projection = WorkspaceGroupSidebarProjection.make(groups: [],
            workspaces: [.init(id: id, isPinned: false, groupId: UUID())])
        XCTAssertEqual(projection.visibleWorkspaceIds, [id])
        XCTAssertEqual(projection.rows, [.workspace(.init(workspaceId: id, groupId: nil, canonicalIndex: 0, isPinned: false))])
    }

    @MainActor
    func testCoordinatorCapturesPostPublishStateOnceAndDeduplicatesUnchangedAttention() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Collapsed", isCollapsed: true)
        let member = ObservedMember(groupId: group.id)
        let other = ObservedMember(groupId: group.id)
        fixture.groups = [group]; fixture.members = [member, other]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        XCTAssertEqual(member.captures, 1)
        member.changes.send() // Match objectWillChange: notification precedes storage mutation.
        member.panels = [.init(isFlagged: true, isWaiting: false, isSuppressed: true)]
        member.changes.send()
        member.changes.send()
        XCTAssertEqual(member.captures, 1)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.flaggedCount, 0)
        XCTAssertEqual(scheduler.pending.count, 1)
        scheduler.drain()
        XCTAssertEqual(member.captures, 2)
        XCTAssertEqual(other.captures, 1, "Unchanged member attention must stay cached")
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.flaggedCount, 1)
        XCTAssertEqual(publications, 1)
        member.changes.send() // A broad title/output event does not alter header truth.
        scheduler.drain()
        XCTAssertEqual(member.captures, 3)
        XCTAssertEqual(publications, 1)
        member.changes.send()
        member.panels = []
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.flaggedCount, 0)
        XCTAssertEqual(publications, 2)
    }

    @MainActor
    func testCoordinatorRepublishesWhenOnlyAnAgentLifecycleChanges() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Work")
        let member = ObservedMember(groupId: group.id)
        let ungrouped = ObservedMember(groupId: nil)
        fixture.groups = [group]; fixture.members = [member, ungrouped]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let panel = UUID()
        let revision = coordinator.projection.pulseRevision

        ungrouped.changes.send()
        ungrouped.lifecycle = [panel: .init(state: .idle, promptCacheExpired: false)]
        scheduler.drain()
        XCTAssertEqual(publications, 1, "a lifecycle edge with no header change still rebuilds row pulses")
        XCTAssertEqual(coordinator.projection.pulseRevision, revision + 1)

        ungrouped.changes.send()
        ungrouped.lifecycle = [panel: .init(state: .cold, promptCacheExpired: true)]
        scheduler.drain()
        XCTAssertEqual(publications, 2, "a cache-cold flip carries no notification")

        ungrouped.changes.send() // A title or output event leaves the pulse alone.
        scheduler.drain()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.waitingCount, 0)
    }

    /// C11H-296: a description write publishes only its workspace; the agent
    /// rows must still rebuild, at once when nothing published lately.
    @MainActor
    func testCoordinatorRepublishesWhenOnlyACardContextChanges() {
        let fixture = ObservationFixture()
        let member = ObservedMember(groupId: nil)
        fixture.members = [member]
        let scheduler = ManualScheduler(), clock = ManualClock()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule,
            scheduleAfter: clock.scheduleAfter, now: { clock.now })
        coordinator.attach(source: fixture.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let revision = coordinator.projection.pulseRevision

        clock.advance(by: 5)
        member.changes.send()
        member.cardContextRevision = 7
        scheduler.drain()
        XCTAssertEqual(publications, 1, "a description change alone rebuilds the rows")
        XCTAssertEqual(coordinator.projection.pulseRevision, revision + 1)
        XCTAssertTrue(clock.delayed.isEmpty, "a lone write waits for nothing")

        clock.advance(by: 5)
        member.changes.send() // The same text again leaves the revision where it was.
        scheduler.drain()
        clock.advance(by: 1)
        XCTAssertEqual(publications, 1)
    }

    /// A burst of description writes across panels and workspaces costs at
    /// most two list rebuilds per window: the first at once, the rest at the
    /// window's end.
    @MainActor
    func testCoordinatorCoalescesABurstOfCardContextChanges() {
        let fixture = ObservationFixture()
        let members = (0..<5).map { _ in ObservedMember(groupId: nil) }
        fixture.members = members
        let scheduler = ManualScheduler(), clock = ManualClock()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule,
            scheduleAfter: clock.scheduleAfter, now: { clock.now })
        coordinator.attach(source: fixture.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        clock.advance(by: 5)

        var revision: UInt64 = 0
        for write in 0..<20 { // 20 writes, 10 ms apart, each in its own main turn.
            let member = members[write % members.count]
            member.changes.send()
            revision += 1
            member.cardContextRevision = revision
            scheduler.drain()
            clock.advance(by: 0.01)
        }
        XCTAssertEqual(publications, 1, "the first write shows at once; the rest wait for the window")
        XCTAssertEqual(clock.delayed.count, 1, "one trailing publication for the whole burst")
        clock.advance(by: WorkspaceGroupSidebarCoordinator.cardContextWindow)
        XCTAssertEqual(publications, 2)
        clock.advance(by: 1)
        XCTAssertEqual(publications, 2)
    }

    /// Any other publication rebuilds the rows, so it carries a pending card
    /// context change and the trailing one then publishes nothing.
    @MainActor
    func testCoordinatorLifecyclePublicationCarriesAPendingCardContextChange() {
        let fixture = ObservationFixture()
        let member = ObservedMember(groupId: nil)
        fixture.members = [member]
        let scheduler = ManualScheduler(), clock = ManualClock()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule,
            scheduleAfter: clock.scheduleAfter, now: { clock.now })
        coordinator.attach(source: fixture.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        clock.advance(by: 5)

        member.changes.send(); member.cardContextRevision = 1; scheduler.drain()
        XCTAssertEqual(publications, 1)
        clock.advance(by: 0.05)
        member.changes.send(); member.cardContextRevision = 2; scheduler.drain()
        XCTAssertEqual(publications, 1, "inside the window: pending")
        clock.advance(by: 0.05)
        member.changes.send(); member.lifecycle = [UUID(): .init(state: .running, promptCacheExpired: false)]
        scheduler.drain()
        XCTAssertEqual(publications, 2, "a lifecycle edge publishes at once and carries the description")
        clock.advance(by: 1)
        XCTAssertEqual(publications, 2, "nothing left for the trailing publication")
    }

    /// A trailing card-context publication queued for one window's sources
    /// never fires into the next attachment, so it cannot publish that one's
    /// pending change before its own window ends.
    @MainActor
    func testCoordinatorReattachDropsAQueuedCardContextPublication() {
        let old = ObservationFixture(), new = ObservationFixture()
        let oldMember = ObservedMember(groupId: nil), newMember = ObservedMember(groupId: nil)
        old.members = [oldMember]; new.members = [newMember]
        let scheduler = ManualScheduler(), clock = ManualClock()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule,
            scheduleAfter: clock.scheduleAfter, now: { clock.now })
        coordinator.attach(source: old.source())
        clock.advance(by: 5)
        oldMember.changes.send(); oldMember.cardContextRevision = 1; scheduler.drain()
        clock.advance(by: 0.05)
        oldMember.changes.send(); oldMember.cardContextRevision = 2; scheduler.drain()
        XCTAssertEqual(clock.delayed.count, 1, "the old window queued its trailing publication")

        coordinator.detach()
        coordinator.attach(source: new.source())
        var publications = 0
        let subscription = coordinator.$projection.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        clock.advance(by: 0.1)
        newMember.changes.send(); newMember.cardContextRevision = 1; scheduler.drain()
        XCTAssertEqual(publications, 0, "inside the new window: pending")

        clock.advance(by: 0.12) // The old trailing time passes.
        XCTAssertEqual(publications, 0, "the old window's publication does not fire into the new one")
        clock.advance(by: 0.1) // The new window ends.
        XCTAssertEqual(publications, 1)
    }

    @MainActor
    func testCoordinatorNotificationInvalidationReadsUpdatedIndexesAndCoalescesWithMemberChange() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Work", isCollapsed: true)
        let member = ObservedMember(groupId: group.id)
        fixture.groups = [group]; fixture.members = [member]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        fixture.notifications.send()
        member.unread = 3
        member.changes.send()
        member.panels = [.init(isFlagged: false, isWaiting: true, isSuppressed: false)]
        scheduler.drain()
        XCTAssertEqual(member.captures, 2)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 1, flaggedCount: 0, waitingCount: 1, unreadCount: 3))
    }

    @MainActor
    func testCoordinatorRebindsStructureAndReusesAttentionForReorderAndSelection() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Work")
        let a = ObservedMember(groupId: group.id), b = ObservedMember(groupId: group.id)
        fixture.groups = [group]; fixture.members = [a, b]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        fixture.structure.send()
        fixture.members = [b, a]
        fixture.selection.send()
        fixture.selected = b.id
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.visibleWorkspaceIds, [b.id, a.id])
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.isActive, true)
        XCTAssertEqual([a.captures, b.captures], [1, 1])
        fixture.structure.send()
        fixture.groups[0].isCollapsed = true
        scheduler.drain()
        XCTAssertTrue(coordinator.projection.visibleWorkspaceIds.isEmpty)
        XCTAssertEqual([a.captures, b.captures], [1, 1])
        fixture.structure.send()
        fixture.members = [a]
        scheduler.drain()
        b.changes.send()
        XCTAssertTrue(scheduler.pending.isEmpty, "Removed member subscription must be cancelled")
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.memberCount, 1)
    }

    @MainActor
    func testCoordinatorMembershipTransferUpdatesBothHeadersAndSameUUIDReplacementRebinds() {
        let fixture = ObservationFixture()
        let a = WorkspaceGroup(name: "A"), b = WorkspaceGroup(name: "B")
        let member = ObservedMember(groupId: a.id)
        member.panels = [.init(isFlagged: true, isWaiting: false, isSuppressed: true)]
        fixture.groups = [a, b]; fixture.members = [member]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        member.changes.send()
        member.groupId = b.id
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[a.id]?.summary, .zero)
        XCTAssertEqual(coordinator.projection.headersById[b.id]?.summary.flaggedCount, 1)
        let replacement = ObservedMember(id: member.id, groupId: a.id)
        fixture.structure.send()
        fixture.members = [replacement]
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[b.id]?.summary, .zero)
        XCTAssertEqual(coordinator.projection.headersById[a.id]?.summary.memberCount, 1)
        member.changes.send()
        XCTAssertTrue(scheduler.pending.isEmpty)
        replacement.changes.send()
        replacement.unread = 4
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[a.id]?.summary.unreadCount, 4)
    }

    @MainActor
    func testCoordinatorWindowReplacementWithEmptySourceDropsOldRows() {
        let old = ObservationFixture(), empty = ObservationFixture()
        old.groups = [WorkspaceGroup(name: "Old")]
        old.members = [ObservedMember(groupId: nil)]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: old.source())
        old.structure.send()
        coordinator.attach(source: empty.source())
        XCTAssertEqual(coordinator.projection, .empty)
        scheduler.drain()
        XCTAssertEqual(coordinator.projection, .empty)
    }

    @MainActor
    func testSixtyCollapsedMembersStayObservableWithoutCreatingVisibleRows() {
        let fixture = ObservationFixture()
        fixture.groups = (0..<6).map { WorkspaceGroup(name: "Group \($0)", isCollapsed: true) }
        fixture.members = (0..<60).map { ObservedMember(groupId: fixture.groups[$0 % 6].id) }
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        XCTAssertEqual(coordinator.projection.rows.count, 6)
        XCTAssertTrue(coordinator.projection.visibleWorkspaceIds.isEmpty)
        XCTAssertTrue(coordinator.projection.headersById.values.allSatisfy { $0.summary.memberCount == 10 })
        let changed = fixture.members[59]
        changed.changes.send()
        changed.panels = [.init(isFlagged: true, isWaiting: true, isSuppressed: false)]
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[fixture.groups[5].id]?.summary.flaggedCount, 1)
        XCTAssertEqual(coordinator.projection.headersById[fixture.groups[5].id]?.summary.waitingCount, 1)
        XCTAssertEqual(fixture.members.map(\.captures).reduce(0, +), 61)
        XCTAssertEqual(coordinator.projection.rows.count, 6)
    }

    @MainActor
    func testCoordinatorDetachCancelsSubscriptionsAndQueuedWorkCannotPublishIntoNewWindow() {
        let old = ObservationFixture(), new = ObservationFixture()
        let oldGroup = WorkspaceGroup(name: "Old"), newGroup = WorkspaceGroup(name: "New")
        let member = ObservedMember(groupId: oldGroup.id)
        old.groups = [oldGroup]; old.members = [member]
        new.groups = [newGroup]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: old.source())
        member.changes.send()
        coordinator.detach()
        coordinator.attach(source: new.source())
        scheduler.drain()
        XCTAssertEqual(Set(coordinator.projection.headersById.keys), Set([newGroup.id]))
        member.changes.send(); old.structure.send(); old.notifications.send()
        XCTAssertTrue(scheduler.pending.isEmpty)
        coordinator.detach()
        XCTAssertEqual(coordinator.projection, .empty)
    }
}

@MainActor
private final class ManualScheduler {
    var pending: [@MainActor () -> Void] = []
    func schedule(_ work: @escaping @MainActor () -> Void) { pending.append(work) }
    func drain() {
        let work = pending
        pending.removeAll()
        for action in work { action() }
    }
}

/// A clock and delayed work the test advances by hand.
@MainActor
private final class ManualClock {
    var now: TimeInterval = 100
    var delayed: [(at: TimeInterval, work: @MainActor () -> Void)] = []
    func scheduleAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        delayed.append((now + delay, work))
    }
    /// Moves the clock and runs the delayed work now due, in order.
    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = delayed.filter { $0.at <= now + 1e-9 }.sorted { $0.at < $1.at }
        delayed.removeAll { $0.at <= now + 1e-9 }
        for item in due { item.work() }
    }
}

@MainActor
private final class ObservedMember {
    let id: UUID
    let changes = PassthroughSubject<Void, Never>()
    var groupId: UUID?
    var isPinned = false
    var panels: [WorkspaceGroupPanelAttention] = []
    var unread = 0
    var lifecycle: [UUID: WorkspaceGroupPanelLifecycle] = [:]
    var cardContextRevision: UInt64 = 0
    var captures = 0

    init(id: UUID = UUID(), groupId: UUID?) { self.id = id; self.groupId = groupId }

    func observation() -> WorkspaceGroupSidebarObservedWorkspace {
        WorkspaceGroupSidebarObservedWorkspace(identity: ObjectIdentifier(self), id: id,
            changes: changes.eraseToAnyPublisher(),
            orderEntry: { .init(id: self.id, isPinned: self.isPinned, groupId: self.groupId) },
            attention: {
                self.captures += 1
                return .init(panels: self.panels, unreadCount: self.unread, lifecycleByPanel: self.lifecycle,
                             cardContextRevision: self.cardContextRevision)
            })
    }
}

@MainActor
private final class ObservationFixture {
    let structure = PassthroughSubject<Void, Never>()
    let selection = PassthroughSubject<Void, Never>()
    let notifications = PassthroughSubject<Void, Never>()
    var groups: [WorkspaceGroup] = []
    var members: [ObservedMember] = []
    var selected: UUID?
    var captains: [UUID: WorkspaceCaptainSummary] = [:]
    var rootOrder: [UUID]?

    func source() -> WorkspaceGroupSidebarObservationSource {
        .init(structureChanges: structure.eraseToAnyPublisher(), selectionChanges: selection.eraseToAnyPublisher(),
              notificationChanges: notifications.eraseToAnyPublisher(), groups: { self.groups },
              workspaces: { self.members.map { $0.observation() } }, selectedWorkspaceId: { self.selected },
              groupCaptains: { self.captains }, rootOrder: { self.rootOrder })
    }
}

extension WorkspaceGroupSidebarProjectionTests {
    func testStableSelectionAnchorAfterMenuReorderExcludesHiddenMembers() {
        let a = UUID(), b = UUID(), c = UUID(), hidden = UUID()
        // Canonical [B,C,A] after moving A into C's folder renders [C,A,B].
        XCTAssertEqual(WorkspaceGroupSidebarProjection.selectionRange(
            anchor: a, target: c, visibleWorkspaceIds: [c, a, b]), [c, a])
        XCTAssertNil(WorkspaceGroupSidebarProjection.selectionRange(
            anchor: hidden, target: c, visibleWorkspaceIds: [c, a, b]))
        XCTAssertEqual(WorkspaceGroupSidebarProjection.selectionRange(
            anchor: b, target: c, visibleWorkspaceIds: [c, a, b]), [c, a, b])
    }

    func testDisplayedMoveNeighborsSkipInterleavedGroupsAndRespectMemberPins() {
        let group = WorkspaceGroup(name: "Group")
        let a = UUID(), b = UUID(), c = UUID(), pinned = UUID()
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: [
            WorkspaceOrderEntry(id: pinned, isPinned: true, groupId: group.id),
            WorkspaceOrderEntry(id: a, isPinned: false, groupId: group.id),
            WorkspaceOrderEntry(id: b, isPinned: false),
            WorkspaceOrderEntry(id: c, isPinned: false, groupId: group.id)
        ])
        let rows = projection.rows.compactMap { row -> WorkspaceGroupSidebarWorkspaceRow? in
            if case .workspace(let value) = row { return value }; return nil
        }
        XCTAssertEqual(rows.map(\.workspaceId), [pinned, a, c, b])
        XCTAssertNil(rows[0].moveDownTarget)
        XCTAssertNil(rows[1].moveUpTarget)
        XCTAssertEqual(rows[1].moveDownTarget, c)
        XCTAssertEqual(rows[2].moveUpTarget, a)
        XCTAssertNil(rows[2].moveDownTarget)
        XCTAssertEqual(rows.filter(\.isLastGroupMember).map(\.workspaceId), [c])
    }
}

/// C11H-299: the group's Captain is drawn once, on its header.
extension WorkspaceGroupSidebarProjectionTests {
    func testHeaderCarriesItsGroupCaptainAndMembersDoNot() {
        let group = WorkspaceGroup(name: "Acme")
        let member = UUID()
        let captain = WorkspaceCaptainSummary(address: "acme-captain", holders: [], scope: .workspaceGroup, groupID: group.id)
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group],
            workspaces: [.init(id: member, isPinned: false, groupId: group.id)], captainByGroup: [group.id: captain])
        XCTAssertEqual(projection.headersById[group.id]?.captain, captain)
        let plain = WorkspaceGroupSidebarProjection.make(groups: [group],
            workspaces: [.init(id: member, isPinned: false, groupId: group.id)])
        XCTAssertEqual(plain.headersById[group.id]?.captain, .unset)
        XCTAssertNotEqual(projection, plain, "a Captain change republishes the header")
        XCTAssertEqual(projection.rows.count, plain.rows.count, "the mark adds no row")
    }

    @MainActor
    func testCoordinatorRepublishesHeaderWhenOnlyTheGroupCaptainChanges() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Acme")
        let member = ObservedMember(groupId: group.id)
        fixture.groups = [group]; fixture.members = [member]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.captain, .unset)
        let held = WorkspaceCaptainSummary(address: "acme-captain",
            holders: [.init(panelID: UUID(), workspaceID: UUID(), address: "acme-captain", title: "Acme Captain")],
            scope: .workspaceGroup, groupID: group.id)
        fixture.captains = [group.id: held]
        fixture.structure.send()
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.captain, held)
        // Attention updates rebuild headers incrementally and must keep the mark.
        member.changes.send()
        member.panels = [.init(isFlagged: true, isWaiting: false, isSuppressed: false)]
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.flaggedCount, 1)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.captain, held)
        fixture.selected = member.id
        fixture.selection.send()
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.captain, held)
        fixture.captains = [:]
        fixture.structure.send()
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.captain, .unset)
    }

    func testHeaderRedrawsWhenOnlyItsCaptainChanges() {
        let group = WorkspaceGroup(name: "Acme")
        func header(_ captain: WorkspaceCaptainSummary) -> WorkspaceGroupHeaderView {
            WorkspaceGroupHeaderView(group: group, summary: .zero, isActive: false, captain: captain,
                onToggleCollapse: { _ in }, onFocus: { _ in }, onRename: { _, _ in }, onSetColor: { _, _ in },
                onSetIcon: { _, _ in }, onTogglePin: { _ in }, onUngroup: { _ in }, onDelete: { _ in })
        }
        let unheld = WorkspaceCaptainSummary(address: "acme-captain", holders: [], scope: .workspaceGroup, groupID: group.id)
        XCTAssertFalse(header(.unset) == header(unheld), "the header redraws when its Captain changes")
        XCTAssertTrue(header(unheld) == header(unheld))
    }
}

/// C11H-342: the sidebar draws groups and ungrouped workspaces in one root order.
extension WorkspaceGroupSidebarProjectionTests {
    func testRowsFollowTheRootOrderAndUngroupedMovesStepPastGroups() {
        let group = WorkspaceGroup(name: "Group")
        let flagship = UUID(), member = UUID(), other = UUID()
        let workspaces = [WorkspaceOrderEntry(id: flagship, isPinned: false),
                          WorkspaceOrderEntry(id: member, isPinned: false, groupId: group.id),
                          WorkspaceOrderEntry(id: other, isPinned: false)]
        let legacy = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: workspaces)
        XCTAssertEqual(legacy.rows.map(\.id), [.group(group.id), .workspace(member), .workspace(flagship), .workspace(other)])
        let projection = WorkspaceGroupSidebarProjection.make(groups: [group], workspaces: workspaces,
                                                             rootOrder: [flagship, group.id, other])
        XCTAssertEqual(projection.rows.map(\.id),
                       [.workspace(flagship), .group(group.id), .workspace(member), .workspace(other)])
        XCTAssertEqual(projection.visibleWorkspaceIds, [flagship, member, other])
        let rows = projection.rows.compactMap { row -> WorkspaceGroupSidebarWorkspaceRow? in
            if case .workspace(let value) = row { return value }; return nil
        }
        XCTAssertNil(rows[0].moveUpTarget)
        XCTAssertEqual(rows[0].moveDownTarget, group.id, "one step down passes the group")
        XCTAssertEqual(rows[2].moveUpTarget, group.id)
        XCTAssertEqual(WorkspaceSidebarTileRun.pack(projection.rows).map(\.rows.count), [1, 1, 1, 1])
    }

    @MainActor
    func testCoordinatorRepublishesWhenOnlyTheRootOrderChanges() {
        let fixture = ObservationFixture()
        let group = WorkspaceGroup(name: "Group")
        let flagship = ObservedMember(groupId: nil)
        fixture.groups = [group]; fixture.members = [flagship]
        let scheduler = ManualScheduler()
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: scheduler.schedule)
        coordinator.attach(source: fixture.source())
        XCTAssertEqual(coordinator.projection.rows.map(\.id), [.group(group.id), .workspace(flagship.id)])
        fixture.rootOrder = [flagship.id, group.id]
        fixture.structure.send()
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.rows.map(\.id), [.workspace(flagship.id), .group(group.id)])
    }
}

/// C11H-410: a group header gives its name the width. What yields, and when,
/// depends only on the width, the scale and what the operator configured.
extension WorkspaceGroupSidebarProjectionTests {
    private typealias Layout = WorkspaceGroupHeaderLayout
    /// The narrowest sidebar (180 pt) less the header's 6 pt inset on each side.
    private static let narrowestHeader = CGFloat(SessionPersistencePolicy.minimumSidebarWidth) - 12

    private func shown(_ layout: Layout) -> [String] {
        [("pin", layout.showsPin), ("glyph", layout.showsAttentionGlyph),
         ("icon", layout.showsIcon), ("captain", layout.showsCaptain)].filter(\.1).map(\.0)
    }

    func testPartsYieldToTheNameInOrderAsTheHeaderNarrows() {
        for scale: CGFloat in [1, 1.25, 1.55] {
            var hiddenOrder: [String] = []
            var previous = shown(Layout.resolve(width: 600, scale: scale, hasIcon: true, hasCaptain: true, isPinned: true))
            XCTAssertEqual(previous, ["pin", "glyph", "icon", "captain"], "everything shows at a wide sidebar")
            for width in stride(from: CGFloat(599), through: 60, by: -1) {
                let now = shown(Layout.resolve(width: width, scale: scale, hasIcon: true, hasCaptain: true, isPinned: true))
                XCTAssertTrue(Set(now).isSubset(of: Set(previous)), "a part never returns as the header narrows (\(width) pt at \(scale)x)")
                hiddenOrder += previous.filter { !now.contains($0) }
                previous = now
            }
            XCTAssertEqual(hiddenOrder, ["pin", "glyph", "icon", "captain"], "yield order at \(scale)x")
        }
    }

    func testTheNameKeepsItsFloorAtTheNarrowestSidebar() {
        for scale: CGFloat in [0.9, 1, 1.25, 1.55] {
            for (icon, captain, pinned) in [(false, false, false), (true, true, true), (false, true, false)] {
                let layout = Layout.resolve(width: Self.narrowestHeader, scale: scale,
                                            hasIcon: icon, hasCaptain: captain, isPinned: pinned)
                if layout.nameWidth < Layout.nameFloor * scale {
                    XCTAssertEqual(shown(layout), [], "below the floor only once every part has yielded (\(scale)x)")
                }
            }
        }
        // Atin's sidebar on 2026-11-18: 180 pt at Large. h18 left the name about 10 pt ("Th...").
        let large = Layout.resolve(width: Self.narrowestHeader, scale: 1.25, hasIcon: false, hasCaptain: false, isPinned: false)
        XCTAssertGreaterThanOrEqual(large.nameWidth, 90)
    }

    func testTheDecorationsYieldSoAWholeNameFits() {
        // "Swarm Research", pinned, at Large: where dropping the pin and the count's glyph lets the
        // whole name fit, they give way. Wide enough, they stay.
        var swarm = WorkspaceGroup(name: "Swarm Research")
        swarm.isPinned = true
        let needed = WorkspaceGroupHeaderView.nameWidth(swarm.name, scale: 1.25)
        // The header width at which the name fits only once both decorations are gone.
        let fixed = (Layout.tabLeading + Layout.chevronWidth + Layout.tabTrailing + 2 * Layout.chipInset
                     + Layout.slotCountWidth) * 1.25
        let tight = ceil(needed + fixed)
        XCTAssertLessThan(tight - fixed - (Layout.slotGlyphWidth + Layout.pinWidth) * 1.25, needed,
                          "with both decorations the name would be cut off")
        let narrow = WorkspaceGroupHeaderView.layout(group: swarm, icon: nil, captain: .unset,
                                                     width: tight, scale: 1.25)
        XCTAssertFalse(narrow.showsPin)
        XCTAssertFalse(narrow.showsAttentionGlyph)
        XCTAssertGreaterThanOrEqual(narrow.nameWidth, needed, "the whole name fits")
        let wide = WorkspaceGroupHeaderView.layout(group: swarm, icon: nil, captain: .unset, width: 300, scale: 1.25)
        XCTAssertTrue(wide.showsPin)
        XCTAssertTrue(wide.showsAttentionGlyph)
    }

    func testWhatYieldsAtLargeScaleFollowsTheWidth() {
        func row(_ width: CGFloat) -> [String] {
            shown(Layout.resolve(width: width, scale: 1.25, hasIcon: true, hasCaptain: true, isPinned: true))
        }
        // Width table at 1.25x with an icon, a Captain and a pin, for a long name: the
        // decorations yield below 150 pt of name, the identity marks below 90 pt.
        XCTAssertEqual(row(274), ["pin", "glyph", "icon", "captain"])
        XCTAssertEqual(row(273), ["glyph", "icon", "captain"])
        XCTAssertEqual(row(261), ["icon", "captain"])
        XCTAssertEqual(row(187), ["icon", "captain"])
        XCTAssertEqual(row(186), ["captain"])
        XCTAssertEqual(row(Self.narrowestHeader), ["captain"])
        XCTAssertEqual(row(120), [])
        let slot = Layout.resolve(width: 120, scale: 1.25, hasIcon: false, hasCaptain: false, isPinned: false).slotWidth
        XCTAssertEqual(slot, Layout.slotCountWidth * 1.25, "the attention slot never yields: it holds the actions menu on hover")
    }

    func testCountsAndCaptainPresenceNeverMoveTheHeader() {
        let group = WorkspaceGroup(name: "The Constellation Bus")
        let unheld = WorkspaceCaptainSummary(address: "bus-captain", holders: [], scope: .workspaceGroup, groupID: group.id)
        let held = WorkspaceCaptainSummary(
            address: "bus-captain",
            holders: [WorkspaceCaptainProjection.Holder(panelID: UUID(), workspaceID: UUID(), address: "bus-captain", title: "Bus Captain")],
            scope: .workspaceGroup, groupID: group.id)
        for width: CGFloat in [120, Self.narrowestHeader, 220, 400] {
            let before = WorkspaceGroupHeaderView.layout(group: group, icon: nil, captain: unheld, width: width, scale: 1.25)
            XCTAssertEqual(WorkspaceGroupHeaderView.layout(group: group, icon: nil, captain: held, width: width, scale: 1.25),
                           before, "a Captain arriving moves nothing at \(width) pt")
        }
        let none = WorkspaceGroupHeaderView.layout(group: group, icon: nil, captain: .unset, width: 400, scale: 1)
        XCTAssertFalse(none.showsCaptain, "a group with no Captain address reserves no mark slot")
    }

    func testAShortNameKeepsItsIconAtTheNarrowestSidebar() {
        // Large scale, 180 pt: "Ops" needs about 25 pt, so its icon stays; a long name takes it.
        var ops = WorkspaceGroup(name: "Ops")
        ops.icon = "🚀"
        let icon = SidebarIconGlyph.forGroupIcon(ops.icon)
        XCTAssertNotNil(icon)
        let short = WorkspaceGroupHeaderView.layout(group: ops, icon: icon, captain: .unset,
                                                    width: Self.narrowestHeader, scale: 1.25)
        XCTAssertTrue(short.showsIcon)
        XCTAssertTrue(short.showsAttentionGlyph)
        var long = ops
        long.name = "Stage 11 Deployments and Client Work"
        let longLayout = WorkspaceGroupHeaderView.layout(group: long, icon: icon, captain: .unset,
                                                         width: Self.narrowestHeader, scale: 1.25)
        XCTAssertFalse(longLayout.showsIcon)
        XCTAssertGreaterThanOrEqual(longLayout.nameWidth, Layout.nameFloor * 1.25)
    }

    func testTheNameFrameIsTheSameSelectedOrNot() {
        // A heavier weight for the selected group moved the tab's edge 2 to 7 pt (review of #394).
        for name in ["Swarm Research", "Stage 11 Deployments and Client Work", "Ops"] {
            for scale: CGFloat in [1, 1.25, 1.55] {
                var group = WorkspaceGroup(name: name)
                group.isPinned = true
                for width in [Self.narrowestHeader, 300] {
                    let layout = WorkspaceGroupHeaderView.layout(group: group, icon: nil, captain: .unset,
                                                                 width: width, scale: scale)
                    XCTAssertEqual(
                        WorkspaceGroupHeaderView.nameFrameWidth(name, scale: scale, isActive: true, layout: layout),
                        WorkspaceGroupHeaderView.nameFrameWidth(name, scale: scale, isActive: false, layout: layout),
                        "\(name) at \(scale)x, \(width) pt")
                }
            }
        }
    }

    func testTheCountSlotHolds99PlusAtEveryScale() {
        for scale: CGFloat in [1, 1.25, 1.55] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10 * scale, weight: .semibold)
            let text = ("99+" as NSString).size(withAttributes: [.font: font]).width + 2 * scale
            XCTAssertLessThanOrEqual(text, Layout.slotCountWidth * scale, "\"99+\" alone at \(scale)x")
            let config = NSImage.SymbolConfiguration(pointSize: 8 * scale, weight: .regular)
            for symbol in ["flag.fill", "hourglass"] {
                let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)?.size.width ?? .infinity
                XCTAssertLessThanOrEqual(glyph + 2 * scale + text, (Layout.slotCountWidth + Layout.slotGlyphWidth) * scale,
                                         "\(symbol) and \"99+\" at \(scale)x")
            }
        }
    }

    func testHeaderRedrawsWhenItsWidthOrThemeChanges() {
        let group = WorkspaceGroup(name: "Acme")
        func header(width: CGFloat, style: SidebarThemeStyle = .unset) -> WorkspaceGroupHeaderView {
            WorkspaceGroupHeaderView(group: group, summary: .zero, isActive: false, style: style, availableWidth: width,
                onToggleCollapse: { _ in }, onFocus: { _ in }, onRename: { _, _ in }, onSetColor: { _, _ in },
                onSetIcon: { _, _ in }, onTogglePin: { _ in }, onUngroup: { _ in }, onDelete: { _ in })
        }
        XCTAssertTrue(header(width: 168) == header(width: 168))
        XCTAssertFalse(header(width: 168) == header(width: 240))
        var themed = SidebarThemeStyle()
        themed.stamp = 7
        XCTAssertFalse(header(width: 168) == header(width: 168, style: themed))
    }
}
