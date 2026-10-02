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

    /// Execute a returned command through W1's value seam and compare the preview.
    /// The UI calls the manager methods wrapping these same W1 operations.
    private func assertW1Parity(
        _ plan: Planner.Plan, workspaces: [WorkspaceOrderEntry], groups: [WorkspaceGroup],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var expectedWorkspaces = workspaces
        var expectedGroups = groups
        switch plan.command {
        case .moveWorkspace(let id, let destination, let before, let after):
            let order = try WorkspaceReorderPlanner.transfer(
                workspaces: workspaces, workspaceId: id, groupId: destination, before: before, after: after)
            let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
            expectedWorkspaces = order.finalWorkspaceIds.map {
                var entry = byId[$0]!
                if entry.id == id { entry.groupId = destination }
                return entry
            }
        case .moveGroup(let id, let before, let after):
            let order = try WorkspaceReorderPlanner.move(
                workspaces: groups.map { WorkspaceOrderEntry(id: $0.id, isPinned: $0.isPinned) },
                workspaceId: id, before: before, after: after)
            let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            expectedGroups = order.finalWorkspaceIds.map { byId[$0]! }
        }
        XCTAssertEqual(plan.finalWorkspaces, expectedWorkspaces, file: file, line: line)
        XCTAssertEqual(plan.finalGroups, expectedGroups, file: file, line: line)
        XCTAssertEqual(plan.changed, expectedWorkspaces != workspaces || expectedGroups != groups, file: file, line: line)
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
        XCTAssertEqual(plan.finalWorkspaces.map(\.id), [ws[0], ws[1], ws[3], ws[4], ws[2], ws[5]])
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
            XCTAssertEqual(plan.indicator, .ungroupedEdge(workspaceId: nil, edge: index == 0 ? .top : .bottom))
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
        XCTAssertThrowsError(try workspacePlan(5, .groupEdge(groupId: folders[0], edge: .top))) {
            XCTAssertEqual($0 as? Planner.DropError, .invalidTarget)
        }
        for target in [Planner.Target.groupBody(folders[1]), .memberEdge(workspaceId: ws[2], edge: .top),
                       .ungroupedEdge(workspaceId: nil, edge: .bottom)] {
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
        XCTAssertEqual(pinned.indicator, .groupEdge(groupId: folders[3], edge: .bottom))
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
