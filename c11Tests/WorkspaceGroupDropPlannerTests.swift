import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceGroupDropPlannerTests: XCTestCase {
    private typealias Planner = WorkspaceGroupDropPlanner
    private let window = UUID()
    private let ws = (0..<6).map { _ in UUID() }
    private let folders = (0..<4).map { _ in UUID() }

    private var groups: [WorkspaceGroup] {
        [WorkspaceGroup(id: folders[0], name: "Pinned", isPinned: true),
         WorkspaceGroup(id: folders[1], name: "Second"),
         WorkspaceGroup(id: folders[2], name: "Empty")]
    }

    private var entries: [WorkspaceOrderEntry] {
        [WorkspaceOrderEntry(id: ws[0], isPinned: true, groupId: folders[0]),
         WorkspaceOrderEntry(id: ws[1], isPinned: true),
         WorkspaceOrderEntry(id: ws[2], isPinned: false, groupId: folders[0]),
         WorkspaceOrderEntry(id: ws[3], isPinned: false, groupId: folders[0]),
         WorkspaceOrderEntry(id: ws[4], isPinned: false, groupId: folders[1]),
         WorkspaceOrderEntry(id: ws[5], isPinned: false)]
    }

    private func workspacePlan(_ index: Int, _ target: Planner.Target) throws -> Planner.Plan {
        try Planner.plan(windowId: window, groups: groups, workspaces: entries,
                         source: .workspace(id: ws[index], windowId: window), target: target)
    }

    /// Execute a returned command through the value seams the manager calls
    /// (W1's transfer into a group; the root planner at the root) and compare
    /// the preview. The stored root it leaves draws exactly the planned root.
    private func assertW1Parity(
        _ plan: Planner.Plan, workspaces: [WorkspaceOrderEntry], groups: [WorkspaceGroup],
        rootOrder: [UUID]? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var expectedWorkspaces = workspaces
        var expectedGroups = groups
        let originalRoot = WorkspaceRootOrder.resolve(stored: rootOrder, groups: groups, workspaces: workspaces)
        var expectedRoot = originalRoot
        switch plan.command {
        case .moveWorkspace(let id, let destination?, let before, let after):
            let order = try WorkspaceReorderPlanner.transfer(
                workspaces: workspaces, workspaceId: id, groupId: destination, before: before, after: after)
            let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
            expectedWorkspaces = order.finalWorkspaceIds.map {
                var entry = byId[$0]!
                if entry.id == id { entry.groupId = destination }
                return entry
            }
            expectedRoot = WorkspaceRootOrder.resolve(stored: originalRoot.map(\.id), groups: groups,
                                                      workspaces: expectedWorkspaces)
        case .moveWorkspace(let id, nil, let before, let after):
            let root = try WorkspaceRootOrder.moveWorkspaceToRoot(
                groups: groups, workspaces: workspaces, stored: rootOrder, workspaceId: id, before: before, after: after)
            expectedWorkspaces = root.finalWorkspaces
            expectedRoot = root.finalRoot
        case .moveGroup(let id, let before, let after):
            let root = try WorkspaceRootOrder.moveGroup(
                groups: groups, workspaces: workspaces, stored: rootOrder, groupId: id, before: before, after: after)
            expectedGroups = root.finalGroups
            expectedRoot = root.finalRoot
        }
        XCTAssertEqual(plan.finalWorkspaces, expectedWorkspaces, file: file, line: line)
        XCTAssertEqual(plan.finalGroups, expectedGroups, file: file, line: line)
        XCTAssertEqual(plan.finalRoot, expectedRoot, file: file, line: line)
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: plan.finalRoot.map(\.id), groups: plan.finalGroups,
                                                  workspaces: plan.finalWorkspaces), plan.finalRoot,
                       "the stored root redraws the plan", file: file, line: line)
        XCTAssertEqual(plan.changed, expectedWorkspaces != workspaces || expectedGroups != groups
                       || expectedRoot != originalRoot, file: file, line: line)
    }

    func testGroupBodyJoinsAfterLastMemberWithoutChangingOtherWorkspaces() throws {
        let plan = try workspacePlan(5, .groupBody(folders[0]))
        XCTAssertEqual(plan.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[2], ws[3], ws[5], ws[4]])
        XCTAssertEqual(plan.finalWorkspaces.first { $0.id == ws[5] }?.groupId, folders[0])
        XCTAssertEqual(plan.indicator, .memberEdge(workspaceId: ws[3], edge: .bottom))
        XCTAssertEqual(plan.finalGroups, groups)
        XCTAssertTrue(plan.changed)
        try assertW1Parity(plan, workspaces: entries, groups: groups)
    }

    func testMembershipOnlyTransferIsChangedEvenWhenCanonicalOrderDoesNotMove() throws {
        let plan = try workspacePlan(5, .groupBody(folders[2]))
        XCTAssertEqual(plan.finalWorkspaces.map(\.id), entries.map(\.id))
        XCTAssertEqual(plan.finalWorkspaces.last?.groupId, folders[2])
        XCTAssertEqual(plan.indicator, .groupBody(folders[2]))
        XCTAssertTrue(plan.changed)
        try assertW1Parity(plan, workspaces: entries, groups: groups)
    }

    func testOnlyWorkspaceCanJoinAndLeaveAnEmptyFolderWithoutAnOrderChange() throws {
        let original = [WorkspaceOrderEntry(id: ws[0], isPinned: true)]
        let joined = try Planner.plan(windowId: window, groups: groups, workspaces: original,
                                      source: .workspace(id: ws[0], windowId: window), target: .groupBody(folders[2]))
        XCTAssertTrue(joined.changed)
        XCTAssertEqual(joined.finalWorkspaces, [WorkspaceOrderEntry(id: ws[0], isPinned: true, groupId: folders[2])])
        XCTAssertEqual(joined.indicator, .groupBody(folders[2]))
        try assertW1Parity(joined, workspaces: original, groups: groups)
        let detached = try Planner.plan(windowId: window, groups: groups, workspaces: joined.finalWorkspaces,
                                        source: .workspace(id: ws[0], windowId: window),
                                        target: .ungroupedEdge(workspaceId: nil, edge: .bottom))
        XCTAssertTrue(detached.changed)
        XCTAssertEqual(detached.finalWorkspaces, original)
        XCTAssertEqual(detached.finalGroups, groups)
        try assertW1Parity(detached, workspaces: joined.finalWorkspaces, groups: groups)
    }

    func testCollapsedTargetStaysCollapsedAndIndicatorRemainsVisibleOnHeader() throws {
        var collapsed = groups
        collapsed[1].isCollapsed = true
        let plan = try Planner.plan(windowId: window, groups: collapsed, workspaces: entries,
                                    source: .workspace(id: ws[5], windowId: window), target: .groupBody(folders[1]))
        XCTAssertEqual(plan.finalGroups, collapsed)
        XCTAssertEqual(plan.indicator, .groupBody(folders[1]))
        XCTAssertEqual(plan.finalWorkspaces.filter { $0.groupId == folders[1] }.map(\.id), [ws[4], ws[5]])
        try assertW1Parity(plan, workspaces: entries, groups: collapsed)
    }

    func testMemberEdgesReorderInBothDirectionsAndTransferAcrossFolders() throws {
        for (source, target) in [(2, Planner.Target.memberEdge(workspaceId: ws[3], edge: .bottom)),
                                 (3, .memberEdge(workspaceId: ws[2], edge: .top))] {
            let plan = try workspacePlan(source, target)
            XCTAssertEqual(plan.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[3], ws[2], ws[4], ws[5]])
            try assertW1Parity(plan, workspaces: entries, groups: groups)
        }
        let transfer = try workspacePlan(4, .memberEdge(workspaceId: ws[2], edge: .top))
        XCTAssertEqual(transfer.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[4], ws[2], ws[3], ws[5]])
        XCTAssertEqual(transfer.finalWorkspaces.first { $0.id == ws[4] }?.groupId, folders[0])
        XCTAssertEqual(transfer.indicator, .memberEdge(workspaceId: ws[2], edge: .top))
        try assertW1Parity(transfer, workspaces: entries, groups: groups)
    }

    func testMemberPinClampsIndicatorToActualPlacementWithoutTogglingPins() throws {
        let unpinned = try workspacePlan(5, .memberEdge(workspaceId: ws[0], edge: .top))
        XCTAssertEqual(unpinned.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[5], ws[2], ws[3], ws[4]])
        XCTAssertEqual(unpinned.indicator, .memberEdge(workspaceId: ws[2], edge: .top))
        let pinned = try workspacePlan(1, .memberEdge(workspaceId: ws[3], edge: .bottom))
        XCTAssertEqual(pinned.finalWorkspaces.filter { $0.groupId == folders[0] }.map(\.id), [ws[0], ws[1], ws[2], ws[3]])
        XCTAssertEqual(pinned.indicator, .memberEdge(workspaceId: ws[2], edge: .top))
        for plan in [unpinned, pinned] {
            XCTAssertEqual(Set(plan.finalWorkspaces.filter(\.isPinned).map(\.id)), Set([ws[0], ws[1]]))
            try assertW1Parity(plan, workspaces: entries, groups: groups)
        }
    }

    func testUngroupedEdgesDetachAndDoNotUseGroupedRowsAsTargets() throws {
        let plan = try workspacePlan(2, .ungroupedEdge(workspaceId: ws[5], edge: .top))
        XCTAssertNil(plan.finalWorkspaces.first { $0.id == ws[2] }?.groupId)
        // Already right above ws[5] among the ungrouped: only membership changes.
        XCTAssertEqual(plan.finalWorkspaces.map(\.id), entries.map(\.id))
        XCTAssertEqual(plan.indicator, .ungroupedEdge(workspaceId: ws[5], edge: .top))
        try assertW1Parity(plan, workspaces: entries, groups: groups)
        XCTAssertThrowsError(try workspacePlan(2, .ungroupedEdge(workspaceId: ws[4], edge: .top))) {
            XCTAssertEqual($0 as? Planner.DropError, .invalidTarget)
        }
        XCTAssertThrowsError(try workspacePlan(2, .memberEdge(workspaceId: ws[5], edge: .top))) {
            XCTAssertEqual($0 as? Planner.DropError, .invalidTarget)
        }
    }

    func testRootLaneWorksWhenEveryWorkspaceIsGroupedAndRetainsPin() throws {
        var allGrouped = entries
        allGrouped[1].groupId = folders[0]
        allGrouped[5].groupId = folders[1]
        for index in [0, 5] {
            let plan = try Planner.plan(windowId: window, groups: groups, workspaces: allGrouped,
                                        source: .workspace(id: ws[index], windowId: window),
                                        target: .ungroupedEdge(workspaceId: nil, edge: .bottom))
            let member = try XCTUnwrap(plan.finalWorkspaces.first { $0.id == ws[index] })
            XCTAssertNil(member.groupId)
            XCTAssertEqual(member.isPinned, index == 0)
            // It lands at the end of its segment, under that segment's last group.
            XCTAssertEqual(plan.indicator, .groupEdge(groupId: index == 0 ? folders[0] : folders[2], edge: .bottom))
            XCTAssertEqual(plan.finalGroups, groups)
            try assertW1Parity(plan, workspaces: allGrouped, groups: groups)
        }
    }

    func testUngroupedPinClampDoesNotIndicateAcrossInterveningFolderBlock() throws {
        let plan = try workspacePlan(0, .ungroupedEdge(workspaceId: ws[5], edge: .bottom))
        XCTAssertEqual(plan.finalWorkspaces.prefix(2).map(\.id), [ws[1], ws[0]])
        XCTAssertEqual(plan.indicator, .ungroupedEdge(workspaceId: ws[1], edge: .bottom))
        try assertW1Parity(plan, workspaces: entries, groups: groups)
    }

    func testGroupHeaderMovesAreDistinctAndDoNotChangeCanonicalWorkspaces() throws {
        for (source, target, edge) in [(folders[1], folders[2], Planner.Edge.bottom),
                                      (folders[2], folders[1], .top)] {
            let plan = try Planner.plan(windowId: window, groups: groups, workspaces: entries,
                                        source: .group(id: source, windowId: window),
                                        target: .groupEdge(groupId: target, edge: edge))
            XCTAssertEqual(plan.finalGroups.map(\.id), [folders[0], folders[2], folders[1]])
            XCTAssertEqual(plan.finalWorkspaces, entries)
            try assertW1Parity(plan, workspaces: entries, groups: groups)
        }
        for target in [Planner.Target.groupBody(folders[1]), .memberEdge(workspaceId: ws[2], edge: .top)] {
            XCTAssertThrowsError(try Planner.plan(windowId: window, groups: groups, workspaces: entries,
                                                  source: .group(id: folders[0], windowId: window), target: target)) {
                XCTAssertEqual($0 as? Planner.DropError, .invalidTarget)
            }
        }
    }

    func testGroupPinClampIndicatorStaysInItsRootSegment() throws {
        let input = [groups[0], WorkspaceGroup(id: folders[3], name: "Other pinned", isPinned: true)] + Array(groups.dropFirst())
        let pinned = try Planner.plan(windowId: window, groups: input, workspaces: entries,
                                       source: .group(id: folders[0], windowId: window),
                                       target: .groupEdge(groupId: folders[2], edge: .bottom))
        XCTAssertEqual(pinned.finalGroups.map(\.id), [folders[3], folders[0], folders[1], folders[2]])
        // Clamped to the end of the pinned segment, past its ungrouped workspace.
        XCTAssertEqual(pinned.finalRoot.prefix(3).map(\.id), [folders[3], ws[1], folders[0]])
        XCTAssertEqual(pinned.indicator, .ungroupedEdge(workspaceId: ws[1], edge: .bottom))
        let unpinned = try Planner.plan(windowId: window, groups: input, workspaces: entries,
                                        source: .group(id: folders[2], windowId: window),
                                        target: .groupEdge(groupId: folders[0], edge: .top))
        XCTAssertEqual(unpinned.finalGroups.map(\.id), [folders[0], folders[3], folders[2], folders[1]])
        XCTAssertEqual(unpinned.indicator, .groupEdge(groupId: folders[1], edge: .top))
        for plan in [pinned, unpinned] { try assertW1Parity(plan, workspaces: entries, groups: input) }
    }

    func testSelfDropIsNoOpButDestinationDeletionInvalidatesPreview() throws {
        let selfDrop = try workspacePlan(2, .memberEdge(workspaceId: ws[2], edge: .top))
        XCTAssertFalse(selfDrop.changed)
        XCTAssertEqual(selfDrop.finalWorkspaces, entries)
        let preview = try workspacePlan(5, .groupBody(folders[2]))
        XCTAssertTrue(preview.changed)
        XCTAssertThrowsError(try Planner.plan(windowId: window, groups: Array(groups.dropLast()), workspaces: entries,
                                              source: .workspace(id: ws[5], windowId: window), target: .groupBody(folders[2]))) {
            XCTAssertEqual($0 as? Planner.DropError, .groupNotFound)
        }
        XCTAssertEqual(entries.last?.groupId, nil)
    }

    func testMissingSourceAndTargetAndForeignWindowAreRejected() {
        let missing = UUID()
        let cases: [(Planner.Source, Planner.Target, Planner.DropError)] = [
            (.workspace(id: ws[5], windowId: UUID()), .groupBody(folders[0]), .wrongWindow),
            (.group(id: folders[0], windowId: UUID()), .groupEdge(groupId: folders[1], edge: .top), .wrongWindow),
            (.workspace(id: missing, windowId: window), .groupBody(folders[0]), .workspaceNotFound),
            (.group(id: missing, windowId: window), .groupEdge(groupId: folders[1], edge: .top), .groupNotFound),
            (.workspace(id: ws[5], windowId: window), .memberEdge(workspaceId: missing, edge: .top), .workspaceNotFound),
            (.workspace(id: ws[5], windowId: window), .ungroupedEdge(workspaceId: missing, edge: .top), .workspaceNotFound),
            (.workspace(id: ws[5], windowId: window), .groupBody(missing), .groupNotFound),
            (.group(id: folders[0], windowId: window), .groupEdge(groupId: missing, edge: .top), .groupNotFound)
        ]
        let input = entries
        let originalGroups = groups
        for (source, target, error) in cases {
            XCTAssertThrowsError(try Planner.plan(windowId: window, groups: originalGroups, workspaces: input,
                                                  source: source, target: target)) {
                XCTAssertEqual($0 as? Planner.DropError, error)
            }
            XCTAssertEqual(input, entries)
            XCTAssertEqual(originalGroups, groups)
        }
    }

    /// C11H-207: a card from another window plans against this window's order
    /// with the card where attach puts it (ungrouped, end of its pin segment),
    /// and the commit (attach, then the command) lands where the preview showed.
    func testForeignWorkspaceIsAttachedAtItsPinSegmentEndAndLandsWhereThePreviewShows() throws {
        let foreignUnpinned = WorkspaceOrderEntry(id: UUID(), isPinned: false, groupId: UUID())
        let foreignPinned = WorkspaceOrderEntry(id: UUID(), isPinned: true)
        let attachedUnpinned = Planner.entries(entries, attaching: foreignUnpinned)
        XCTAssertEqual(attachedUnpinned.map(\.id), entries.map(\.id) + [foreignUnpinned.id])
        XCTAssertNil(attachedUnpinned.last?.groupId, "its old window's folder does not come along")
        let attachedPinned = Planner.entries(entries, attaching: foreignPinned)
        XCTAssertEqual(attachedPinned.map(\.id), [ws[0], ws[1], foreignPinned.id, ws[2], ws[3], ws[4], ws[5]])

        for (foreign, attached) in [(foreignUnpinned, attachedUnpinned), (foreignPinned, attachedPinned)] {
            for target: Planner.Target in [
                .ungroupedEdge(workspaceId: ws[5], edge: .top),
                .ungroupedEdge(workspaceId: ws[1], edge: .bottom),
                .memberEdge(workspaceId: ws[3], edge: .top),
                .groupBody(folders[1]),
                .ungroupedEdge(workspaceId: nil, edge: .bottom),
            ] {
                let plan = try Planner.plan(windowId: window, groups: groups, workspaces: attached,
                                            source: .workspace(id: foreign.id, windowId: window), target: target)
                try assertW1Parity(plan, workspaces: attached, groups: groups)
                let landed = try XCTUnwrap(plan.finalWorkspaces.first { $0.id == foreign.id })
                XCTAssertEqual(landed.isPinned, foreign.isPinned, "a move never toggles pin")
            }
        }
        // Dropped above ws[5] (ungrouped, unpinned): an unpinned card lands right there.
        let plan = try Planner.plan(windowId: window, groups: groups, workspaces: attachedUnpinned,
                                    source: .workspace(id: foreignUnpinned.id, windowId: window),
                                    target: .ungroupedEdge(workspaceId: ws[5], edge: .top))
        XCTAssertEqual(plan.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[2], ws[3], ws[4], foreignUnpinned.id, ws[5]])
        XCTAssertEqual(plan.command, .moveWorkspace(workspaceId: foreignUnpinned.id, groupId: nil, before: ws[5], after: nil))
    }

    func testDuplicateOrOrphanSnapshotIsRejectedBeforeW1DictionaryConstruction() {
        var orphan = entries
        orphan[0].groupId = UUID()
        for (input, folders) in [(entries + [entries[0]], groups), (entries, groups + [groups[0]]), (orphan, groups)] {
            XCTAssertThrowsError(try Planner.plan(windowId: window, groups: folders, workspaces: input,
                                                  source: .workspace(id: ws[5], windowId: window), target: .groupBody(self.folders[0]))) {
                XCTAssertEqual($0 as? Planner.DropError, .invalidSnapshot)
            }
        }
    }
}

/// C11H-342: groups and ungrouped workspaces share one root order per pin segment.
final class WorkspaceRootOrderDropTests: XCTestCase {
    private typealias Planner = WorkspaceGroupDropPlanner
    private let window = UUID()
    private let flagship = UUID(), a = UUID(), b = UUID(), member = UUID(), pinnedWs = UUID()
    private let g1 = WorkspaceGroup(name: "One"), g2 = WorkspaceGroup(name: "Two")

    /// Today's layout: groups first. g1 holds one member.
    private var groups: [WorkspaceGroup] { [g1, g2] }
    private var entries: [WorkspaceOrderEntry] {
        [WorkspaceOrderEntry(id: pinnedWs, isPinned: true),
         WorkspaceOrderEntry(id: flagship, isPinned: false),
         WorkspaceOrderEntry(id: member, isPinned: false, groupId: g1.id),
         WorkspaceOrderEntry(id: a, isPinned: false),
         WorkspaceOrderEntry(id: b, isPinned: false)]
    }

    private func root(_ stored: [UUID]?, groups: [WorkspaceGroup]? = nil,
                      workspaces: [WorkspaceOrderEntry]? = nil) -> [UUID] {
        WorkspaceRootOrder.resolve(stored: stored, groups: groups ?? self.groups,
                                   workspaces: workspaces ?? entries).map(\.id)
    }

    private func plan(_ source: Planner.Source, _ target: Planner.Target, stored: [UUID]? = nil) throws -> Planner.Plan {
        let plan = try Planner.plan(windowId: window, groups: groups, workspaces: entries, rootOrder: stored,
                                    source: source, target: target)
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: plan.finalRoot.map(\.id), groups: plan.finalGroups,
                                                  workspaces: plan.finalWorkspaces), plan.finalRoot)
        return plan
    }

    func testNoStoredOrderDrawsGroupsFirstAsBefore() {
        XCTAssertEqual(root(nil), [pinnedWs, g1.id, g2.id, flagship, a, b])
        XCTAssertEqual(WorkspaceGroupProjection.items(groups: groups, workspaces: entries), [
            .workspace(pinnedWs), .group(g1, memberWorkspaceIds: [member]), .group(g2, memberWorkspaceIds: []),
            .workspace(flagship), .workspace(a), .workspace(b)])
    }

    func testFlagshipDropsAboveEveryGroup() throws {
        let plan = try plan(.workspace(id: flagship, windowId: window), .groupEdge(groupId: g1.id, edge: .top))
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, flagship, g1.id, g2.id, a, b])
        XCTAssertEqual(plan.command, .moveWorkspace(workspaceId: flagship, groupId: nil, before: g1.id, after: nil))
        XCTAssertEqual(plan.finalWorkspaces, entries, "already first of its ungrouped peers")
        XCTAssertEqual(plan.indicator, .groupEdge(groupId: g1.id, edge: .top))
        XCTAssertTrue(plan.changed)
    }

    func testGroupDropsBetweenTwoUngroupedWorkspacesAndAfterTheLast() throws {
        let stored = [pinnedWs, flagship, g1.id, g2.id, a, b]
        let between = try plan(.group(id: g2.id, windowId: window), .ungroupedEdge(workspaceId: a, edge: .bottom),
                               stored: stored)
        XCTAssertEqual(between.finalRoot.map(\.id), [pinnedWs, flagship, g1.id, a, g2.id, b])
        XCTAssertEqual(between.command, .moveGroup(groupId: g2.id, before: nil, after: a))
        XCTAssertEqual(between.indicator, .ungroupedEdge(workspaceId: b, edge: .top))
        XCTAssertEqual(between.finalWorkspaces, entries)
        let last = try plan(.group(id: g1.id, windowId: window), .ungroupedEdge(workspaceId: nil, edge: .bottom),
                            stored: stored)
        XCTAssertEqual(last.finalRoot.map(\.id), [pinnedWs, flagship, g2.id, a, b, g1.id])
        XCTAssertEqual(last.indicator, .ungroupedEdge(workspaceId: b, edge: .bottom))
    }

    /// The ungrouped edge of a workspace next to a group is a root position,
    /// not only a workspace-order position: W1 alone would leave b after g1.
    func testWorkspaceDropsBetweenAWorkspaceAndTheGroupAnchoredAfterIt() throws {
        let stored = [pinnedWs, flagship, g1.id, a, g2.id, b]
        let plan = try plan(.workspace(id: b, windowId: window), .ungroupedEdge(workspaceId: flagship, edge: .bottom),
                            stored: stored)
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, flagship, b, g1.id, a, g2.id])
        XCTAssertEqual(plan.indicator, .groupEdge(groupId: g1.id, edge: .top))
    }

    func testMemberLeavesItsGroupForTheRootBelowAnEmptyGroup() throws {
        let plan = try plan(.workspace(id: member, windowId: window), .groupEdge(groupId: g2.id, edge: .bottom))
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, g1.id, g2.id, member, flagship, a, b])
        XCTAssertNil(plan.finalWorkspaces.first { $0.id == member }?.groupId)
        XCTAssertEqual(plan.indicator, .ungroupedEdge(workspaceId: flagship, edge: .top))
    }

    func testMovesClampToTheMoversPinSegment() throws {
        let group = try plan(.group(id: g2.id, windowId: window), .ungroupedEdge(workspaceId: pinnedWs, edge: .top))
        XCTAssertEqual(group.finalRoot.map(\.id), [pinnedWs, g2.id, g1.id, flagship, a, b])
        XCTAssertEqual(group.finalGroups.map(\.isPinned), [false, false], "a move never pins")
        let workspace = try plan(.workspace(id: pinnedWs, windowId: window), .groupEdge(groupId: g2.id, edge: .bottom))
        XCTAssertEqual(workspace.finalRoot.map(\.id), root(nil))
        XCTAssertFalse(workspace.changed)
    }

    func testGroupStillCannotDropInsideAnotherGroup() {
        for target: Planner.Target in [.memberEdge(workspaceId: member, edge: .top), .groupBody(g1.id)] {
            XCTAssertThrowsError(try Planner.plan(windowId: window, groups: groups, workspaces: entries,
                                                  source: .group(id: g2.id, windowId: window), target: target)) {
                XCTAssertEqual($0 as? Planner.DropError, .invalidTarget)
            }
        }
    }

    func testHeaderTopAndClosedBottomPlaceBesideTheGroupAndTheRestJoins() {
        let id = g1.id
        XCTAssertEqual(Planner.headerTarget(groupId: id, locationY: 2, height: 30, showsMembers: true),
                       .groupEdge(groupId: id, edge: .top))
        XCTAssertEqual(Planner.headerTarget(groupId: id, locationY: 15, height: 30, showsMembers: true), .groupBody(id))
        XCTAssertEqual(Planner.headerTarget(groupId: id, locationY: 28, height: 30, showsMembers: true), .groupBody(id),
                       "an open group's bottom edge is its first member: joining")
        XCTAssertEqual(Planner.headerTarget(groupId: id, locationY: 28, height: 30, showsMembers: false),
                       .groupEdge(groupId: id, edge: .bottom))
        XCTAssertEqual(Planner.headerTarget(groupId: id, locationY: 15, height: 0, showsMembers: false), .groupBody(id))
    }

    // MARK: Model operations (the manager applies these plans as one unit)

    func testAnchorsSkipClosedAndRegroupedWorkspacesWithoutMovingAGroup() {
        let stored = [flagship, g1.id, a, g2.id, b]
        XCTAssertEqual(root(stored), [pinnedWs, flagship, g1.id, a, g2.id, b])
        let closed = entries.filter { $0.id != a }
        XCTAssertEqual(root(stored, workspaces: closed), [pinnedWs, flagship, g1.id, g2.id, b])
        var regrouped = entries
        regrouped[3].groupId = g1.id
        XCTAssertEqual(root(stored, workspaces: regrouped), [pinnedWs, flagship, g1.id, g2.id, b])
        let fresh = WorkspaceGroup(name: "New")
        XCTAssertEqual(root(stored, groups: groups + [fresh]), [pinnedWs, fresh.id, flagship, g1.id, a, g2.id, b],
                       "a group the list does not name sits at the top, as every group did before")
    }

    func testMoveGroupByIndexCountsGroupsAndSitsAtThatGroupsPlace() throws {
        let stored = [flagship, g1.id, a, g2.id, b]
        let plan = try WorkspaceRootOrder.moveGroup(groups: groups, workspaces: entries, stored: stored,
                                                    groupId: g2.id, toIndex: 0)
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, flagship, g2.id, g1.id, a, b])
        XCTAssertEqual(plan.finalGroups.map(\.id), [g2.id, g1.id])
        XCTAssertThrowsError(try WorkspaceRootOrder.moveGroup(groups: groups, workspaces: entries, stored: stored,
                                                              groupId: g2.id, before: member)) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .notRootItem)
        }
    }

    func testDissolvedGroupsMembersTakeItsPlace() throws {
        let second = UUID()
        var workspaces = entries
        workspaces.append(WorkspaceOrderEntry(id: second, isPinned: false, groupId: g1.id))
        let stored = [flagship, a, g1.id, b, g2.id]
        let plan = try WorkspaceRootOrder.dissolveGroup(groups: groups, workspaces: workspaces, stored: stored,
                                                        groupId: g1.id)
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, flagship, a, member, second, b, g2.id])
        XCTAssertEqual(plan.finalGroups, [g2])
        XCTAssertTrue(plan.finalWorkspaces.allSatisfy { $0.groupId == nil })
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: plan.finalRoot.map(\.id), groups: plan.finalGroups,
                                                  workspaces: plan.finalWorkspaces), plan.finalRoot)
    }

    /// Review finding (C11H-342): a flat reorder (a notification moving a
    /// workspace to the top, Move to Top, a batch) must move only the workspace
    /// it names. Before the mirror, g1 rode along with flagship to the top.
    func testFlatReorderMovesOnlyTheNamedWorkspaceNeverAGroup() throws {
        // Unpinned workspaces flagship, b, a; g1 sits after a; g2 is not named (top).
        let flat = [WorkspaceOrderEntry(id: pinnedWs, isPinned: true),
                    WorkspaceOrderEntry(id: flagship, isPinned: false),
                    WorkspaceOrderEntry(id: member, isPinned: false, groupId: g1.id),
                    WorkspaceOrderEntry(id: b, isPinned: false),
                    WorkspaceOrderEntry(id: a, isPinned: false)]
        let stored = [flagship, b, a, g1.id]
        XCTAssertEqual(root(stored, workspaces: flat), [pinnedWs, g2.id, flagship, b, a, g1.id])
        // A notification moves a to the top of the unpinned workspaces.
        let notified = [flat[0], flat[4], flat[1], flat[2], flat[3]]
        XCTAssertEqual(root(stored, workspaces: notified), [pinnedWs, g2.id, a, g1.id, flagship, b],
                       "unmirrored, g1 rides along with a: the bug this guards")
        let mirrored = try XCTUnwrap(WorkspaceRootOrder.mirrorFlatReorder(
            stored: stored, groups: groups, old: flat, new: notified, moved: [a]))
        XCTAssertEqual(mirrored.map(\.id), [pinnedWs, g2.id, a, flagship, b, g1.id], "only a moves")
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: mirrored.map(\.id), groups: groups, workspaces: notified),
                       mirrored, "the stored mirror redraws itself")
        // With no hint, the moved workspace is the one outside the longest kept run.
        XCTAssertEqual(WorkspaceRootOrder.mirrorFlatReorder(stored: stored, groups: groups, old: flat, new: notified),
                       mirrored)
        // A wrong hint (something else moved too) falls back to the kept run.
        XCTAssertEqual(WorkspaceRootOrder.mirrorFlatReorder(stored: stored, groups: groups, old: flat, new: notified,
                                                            moved: [b]), mirrored)
        XCTAssertNil(WorkspaceRootOrder.mirrorFlatReorder(stored: nil, groups: groups, old: flat, new: notified),
                     "no stored order: the draw is groups first either way")
        XCTAssertNil(WorkspaceRootOrder.mirrorFlatReorder(stored: stored, groups: groups, old: flat, new: flat))
    }

    /// Review finding (C11H-342): groups that come to share a place keep the
    /// stored order, so a later drop lands where its preview showed.
    func testGroupsSharingAPlaceKeepTheStoredOrderNotTheGroupList() throws {
        let stored = [flagship, g2.id, a, g1.id, b]
        XCTAssertEqual(root(stored), [pinnedWs, flagship, g2.id, a, g1.id, b])
        // a leaves the root: g1 joins g2 after flagship, still after it.
        var regrouped = entries
        regrouped[3].groupId = g2.id
        XCTAssertEqual(root(stored, workspaces: regrouped), [pinnedWs, flagship, g2.id, g1.id, b])
        let plan = try WorkspaceRootOrder.moveWorkspaceToRoot(groups: groups, workspaces: entries, stored: stored,
                                                               workspaceId: b, before: g2.id)
        XCTAssertEqual(plan.finalRoot.map(\.id), [pinnedWs, flagship, b, g2.id, a, g1.id])
        XCTAssertEqual(plan.finalGroups.map(\.id), [g2.id, g1.id], "the group list follows the drawn order")
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: plan.finalRoot.map(\.id), groups: groups,
                                                  workspaces: plan.finalWorkspaces), plan.finalRoot,
                       "even against the old group list")
    }

    /// REPAIR-1 (C11H-342): Move Up/Down's target and enablement come from the
    /// sidebar, not the flat index. A group is the only neighbour here: the flat
    /// list has a at index 0 (old Move Up disabled) and b last (old Move Down disabled).
    func testStepTargetPassesAGroupThatIsTheOnlyNeighbour() {
        let empty = WorkspaceGroup(name: "Empty")
        let flat = [WorkspaceOrderEntry(id: a, isPinned: false), WorkspaceOrderEntry(id: b, isPinned: false)]
        func target(_ id: UUID, _ delta: Int, _ stored: [UUID]?) -> UUID? {
            WorkspaceRootOrder.stepTarget(workspaceId: id, by: delta, groups: [empty], workspaces: flat, stored: stored)
        }
        // Drawn [Empty, a, b]: a's step up passes the group.
        XCTAssertEqual(target(a, -1, nil), empty.id)
        XCTAssertEqual(target(a, 1, nil), b)
        // Drawn [a, b, Empty]: b's step down passes the group.
        XCTAssertEqual(target(b, 1, [a, b, empty.id]), empty.id)
        XCTAssertNil(target(a, -1, [a, b, empty.id]), "the top of the segment")
        // A member steps only among its group's members; the root is not its peer list.
        XCTAssertNil(WorkspaceRootOrder.stepTarget(workspaceId: member, by: -1, groups: groups, workspaces: entries,
                                                   stored: nil))
        XCTAssertNil(target(UUID(), 1, nil))
        XCTAssertNil(target(a, 0, nil))
    }

    func testNewGroupFollowsTheLastGroupAndARepinnedOneEndsThePinnedSegment() {
        let fresh = WorkspaceGroup(name: "New")
        let stored = [flagship, g1.id, a, g2.id, b]
        XCTAssertEqual(WorkspaceRootOrder.placing(fresh.id, atPinBoundary: false, groups: groups + [fresh],
                                                  workspaces: entries, stored: stored).map(\.id),
                       [pinnedWs, flagship, g1.id, a, g2.id, fresh.id, b], "after the last group, as append did")
        var pinned = groups
        pinned[1].isPinned = true
        XCTAssertEqual(WorkspaceRootOrder.placing(g2.id, atPinBoundary: true, groups: pinned,
                                                  workspaces: entries, stored: stored).map(\.id),
                       [pinnedWs, g2.id, flagship, g1.id, a, b], "pinning ends the pinned segment")
    }
}

/// REPAIR-2 (C11H-342): the command palette's Move Up/Down through the seam the
/// palette calls for its enablement and its registered actions, against a model
/// of the manager's order API built from the same pure functions it uses.
@MainActor
final class WorkspaceSidebarStepPaletteTests: XCTestCase {
    private typealias Palette = WorkspaceSidebarStepPalette

    private final class Model: WorkspaceSidebarStepModel {
        var groups: [WorkspaceGroup]
        var workspaceOrderEntries: [WorkspaceOrderEntry]
        var stored: [UUID]?
        var selectedWorkspaceId: UUID?

        init(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry], stored: [UUID]? = nil, selected: UUID) {
            self.groups = groups
            workspaceOrderEntries = workspaces
            self.stored = stored
            selectedWorkspaceId = selected
        }

        var drawn: [UUID] {
            WorkspaceRootOrder.resolve(stored: stored, groups: groups, workspaces: workspaceOrderEntries).map(\.id)
        }

        private func target(_ id: UUID, _ delta: Int) -> UUID? {
            WorkspaceRootOrder.stepTarget(workspaceId: id, by: delta, groups: groups,
                                          workspaces: workspaceOrderEntries, stored: stored)
        }

        func canStepWorkspaceInSidebar(_ workspaceId: UUID, by delta: Int) -> Bool { target(workspaceId, delta) != nil }

        /// The manager's step for a workspace in no group (these fixtures have no members).
        func stepWorkspaceInSidebar(_ workspaceId: UUID, by delta: Int) -> Bool {
            guard let target = target(workspaceId, delta),
                  let plan = try? WorkspaceRootOrder.moveWorkspaceToRoot(
                    groups: groups, workspaces: workspaceOrderEntries, stored: stored, workspaceId: workspaceId,
                    before: delta < 0 ? target : nil, after: delta > 0 ? target : nil) else { return false }
            workspaceOrderEntries = plan.finalWorkspaces
            groups = plan.finalGroups
            stored = plan.finalRoot.map(\.id)
            return true
        }

        /// The manager's flat reorder, mirrored into the root order as its `workspaces` didSet does.
        func reorderWorkspace(workspaceId: UUID, toIndex targetIndex: Int) -> Bool {
            guard let plan = try? WorkspaceReorderPlanner.move(
                workspaces: workspaceOrderEntries, workspaceId: workspaceId, toIndex: targetIndex) else { return false }
            let old = workspaceOrderEntries
            let byId = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            workspaceOrderEntries = plan.finalWorkspaceIds.map { byId[$0]! }
            if let mirrored = WorkspaceRootOrder.mirrorFlatReorder(stored: stored, groups: groups, old: old,
                                                                   new: workspaceOrderEntries, moved: [workspaceId]) {
                stored = mirrored.map(\.id)
            }
            return true
        }
    }

    private let a = UUID(), b = UUID()
    private let group = WorkspaceGroup(name: "Fleet")

    private func enablement(_ model: Model) -> [Bool] {
        let context = Palette.context(model)
        return [context[Palette.hasAboveKey] ?? false, context[Palette.hasBelowKey] ?? false]
    }

    /// A group is the selected workspace's only neighbour, above and then below.
    /// The flat index (0 of 1) would disable both.
    func testAGroupAsTheOnlyNeighbourEnablesAndTakesTheStepBothWays() {
        let model = Model(groups: [group], workspaces: [.init(id: a, isPinned: false)], selected: a)
        XCTAssertEqual(model.drawn, [group.id, a])
        XCTAssertEqual(enablement(model), [true, false], "[Fleet, A]: Move Up on, Move Down off")
        XCTAssertNil(Palette.perform(Palette.moveDownCommandId, on: model))
        XCTAssertEqual(Palette.perform(Palette.moveUpCommandId, on: model), a)
        XCTAssertEqual(model.drawn, [a, group.id])
        XCTAssertEqual(enablement(model), [false, true], "[A, Fleet]: Move Up off, Move Down on")
        XCTAssertEqual(Palette.perform(Palette.moveDownCommandId, on: model), a)
        XCTAssertEqual(model.drawn, [group.id, a])
    }

    /// [A, Fleet, B]: Move Up on B passes only the group, to [A, B, Fleet].
    /// The flat move would put B above A: [B, A, Fleet].
    func testMoveUpBelowAGroupStepsPastOnlyTheGroup() {
        let model = Model(groups: [group], workspaces: [.init(id: a, isPinned: false), .init(id: b, isPinned: false)],
                          stored: [a, group.id, b], selected: b)
        XCTAssertEqual(model.drawn, [a, group.id, b])
        XCTAssertEqual(enablement(model), [true, false])
        XCTAssertEqual(Palette.perform(Palette.moveUpCommandId, on: model), b)
        XCTAssertEqual(model.drawn, [a, b, group.id])
        XCTAssertEqual(Palette.perform(Palette.moveDownCommandId, on: model), b)
        XCTAssertEqual(model.drawn, [a, group.id, b], "Move Down undoes it")
        XCTAssertNil(Palette.perform("palette.moveWorkspaceToTop", on: model), "only Move Up/Down are this seam's")
        XCTAssertEqual(Palette.commands.map(\.commandId), ["palette.moveWorkspaceUp", "palette.moveWorkspaceDown"],
                       "the ids the palette registers and enables")
    }
}
