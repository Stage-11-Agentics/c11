import XCTest
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceGroupSidebarProjectionTests: XCTestCase {
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
        let member = WorkspaceGroupMemberAttention(tabs: [
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
            a: .init(tabs: [.init(isFlagged: true, isWaiting: true, isSuppressed: true)], unreadCount: 2),
            b: .init(tabs: [.init(isFlagged: false, isWaiting: true, isSuppressed: false)], unreadCount: 1)
        ])
        XCTAssertEqual(projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 2, flaggedCount: 1, waitingCount: 1, unreadCount: 3))
        XCTAssertTrue(projection.visibleWorkspaceIds.isEmpty)
    }

    func testMembershipTransferSubtractsOldHeaderAndAddsNewHeaderWithoutChangingRowIdentity() {
        let a = WorkspaceGroup(name: "A"), b = WorkspaceGroup(name: "B")
        let id = UUID()
        let attention: [UUID: WorkspaceGroupMemberAttention] = [id: .init(
            tabs: [.init(isFlagged: true, isWaiting: true, isSuppressed: false)], unreadCount: 2)]
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
        member.tabs = [.init(isFlagged: true, isWaiting: false, isSuppressed: true)]
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
        member.tabs = []
        scheduler.drain()
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.flaggedCount, 0)
        XCTAssertEqual(publications, 2)
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
        member.tabs = [.init(isFlagged: false, isWaiting: true, isSuppressed: false)]
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
        member.tabs = [.init(isFlagged: true, isWaiting: false, isSuppressed: true)]
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
        changed.tabs = [.init(isFlagged: true, isWaiting: true, isSuppressed: false)]
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

@MainActor
private final class ObservedMember {
    let id: UUID
    let changes = PassthroughSubject<Void, Never>()
    var groupId: UUID?
    var isPinned = false
    var tabs: [WorkspaceGroupTabAttention] = []
    var unread = 0
    var captures = 0

    init(id: UUID = UUID(), groupId: UUID?) { self.id = id; self.groupId = groupId }

    func observation() -> WorkspaceGroupSidebarObservedWorkspace {
        WorkspaceGroupSidebarObservedWorkspace(identity: ObjectIdentifier(self), id: id,
            changes: changes.eraseToAnyPublisher(),
            orderEntry: { .init(id: self.id, isPinned: self.isPinned, groupId: self.groupId) },
            attention: {
                self.captures += 1
                return .init(tabs: self.tabs, unreadCount: self.unread)
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

    func source() -> WorkspaceGroupSidebarObservationSource {
        .init(structureChanges: structure.eraseToAnyPublisher(), selectionChanges: selection.eraseToAnyPublisher(),
              notificationChanges: notifications.eraseToAnyPublisher(), groups: { self.groups },
              workspaces: { self.members.map { $0.observation() } }, selectedWorkspaceId: { self.selected })
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
