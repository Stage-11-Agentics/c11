import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceReorderPlannerTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }
    private func entries() -> [WorkspaceOrderEntry] {
        ids.enumerated().map { WorkspaceOrderEntry(id: $1, isPinned: $0 < 2) }
    }

    func testPartialBatchKeepsPinSegmentsAndUntouchedRelativeOrder() throws {
        let plan = try WorkspaceReorderPlanner.batch(workspaces: entries(), orderedWorkspaceIds: [ids[4], ids[1], ids[3]])
        XCTAssertEqual(plan.finalWorkspaceIds, [ids[1], ids[0], ids[4], ids[3], ids[2], ids[5]])
        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.moves, [
            .init(workspaceId: ids[4], fromIndex: 4, toIndex: 2),
            .init(workspaceId: ids[1], fromIndex: 1, toIndex: 0),
            .init(workspaceId: ids[3], fromIndex: 3, toIndex: 3)
        ])
        let applied = plan.finalWorkspaceIds.map { id in entries().first { $0.id == id }! }
        XCTAssertFalse(try WorkspaceReorderPlanner.batch(workspaces: applied, orderedWorkspaceIds: [ids[4], ids[1], ids[3]]).changed)
    }

    func testBatchRejectsAllInvalidTargetsBeforeProducingPlan() {
        for (request, error) in [([], WorkspaceGroupOperationError.invalidParams),
                                 ([ids[0], ids[0]], .duplicateWorkspace),
                                 ([ids[0], UUID()], .workspaceNotFound)] {
            XCTAssertThrowsError(try WorkspaceReorderPlanner.batch(workspaces: entries(), orderedWorkspaceIds: request)) {
                XCTAssertEqual($0 as? WorkspaceGroupOperationError, error)
            }
        }
    }

    func testRelativeMoveResolvesIndexAfterSourceRemovalInBothDirections() throws {
        XCTAssertEqual(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[2], before: ids[5]).finalWorkspaceIds,
                       [ids[0], ids[1], ids[3], ids[4], ids[2], ids[5]])
        XCTAssertEqual(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[2], after: ids[4]).finalWorkspaceIds,
                       [ids[0], ids[1], ids[3], ids[4], ids[2], ids[5]])
        XCTAssertEqual(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[5], before: ids[2]).finalWorkspaceIds,
                       [ids[0], ids[1], ids[5], ids[2], ids[3], ids[4]])
        XCTAssertFalse(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[2], before: ids[2]).changed)
    }

    func testMoveClampsBothPinBoundariesWithoutChangingPins() throws {
        XCTAssertEqual(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[0], after: ids[5]).finalWorkspaceIds,
                       [ids[1], ids[0], ids[2], ids[3], ids[4], ids[5]])
        XCTAssertEqual(try WorkspaceReorderPlanner.move(workspaces: entries(), workspaceId: ids[5], before: ids[0]).finalWorkspaceIds,
                       [ids[0], ids[1], ids[5], ids[2], ids[3], ids[4]])
    }

    func testTransferPlacesMemberWithinDestinationSegment() throws {
        let group = UUID()
        var input = entries()
        input[0].groupId = group
        input[2].groupId = group
        input[4].groupId = group
        XCTAssertEqual(try WorkspaceReorderPlanner.transfer(workspaces: input, workspaceId: ids[3], groupId: group).finalWorkspaceIds,
                       [ids[0], ids[1], ids[2], ids[4], ids[3], ids[5]])
        // Dropping an unpinned member before a pinned member clamps to the first unpinned member.
        XCTAssertEqual(try WorkspaceReorderPlanner.transfer(workspaces: input, workspaceId: ids[5], groupId: group, before: ids[0]).finalWorkspaceIds,
                       [ids[0], ids[1], ids[5], ids[2], ids[3], ids[4]])
        XCTAssertThrowsError(try WorkspaceReorderPlanner.transfer(workspaces: input, workspaceId: ids[5], groupId: group, before: ids[3])) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .notMember)
        }
    }

    func testLargeReversedBatchIsDeterministicAndPreservesMembership() throws {
        let groups = (0..<6).map { _ in UUID() }
        let input = (0..<60).map { WorkspaceOrderEntry(id: UUID(), isPinned: $0 < 12, groupId: groups[$0 % 6]) }
        let plan = try WorkspaceReorderPlanner.batch(workspaces: input, orderedWorkspaceIds: input.reversed().map(\.id))
        XCTAssertEqual(plan.finalWorkspaceIds, input.prefix(12).reversed().map(\.id) + input.suffix(48).reversed().map(\.id))
        XCTAssertEqual(Set(plan.finalWorkspaceIds), Set(input.map(\.id)))
        XCTAssertEqual(input[0].groupId, groups[0])
    }
}
