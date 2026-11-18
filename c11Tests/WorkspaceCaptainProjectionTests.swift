import AppKit
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceCaptainProjectionTests: XCTestCase {
    private let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let panelA = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let panelB = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    func testGlobalExactAddressMatchIncludesHolderInAnotherWorkspace() {
        let projection = WorkspaceCaptainProjection(workspaces: [
            .init(workspaceID: workspaceA, address: "captain"),
            .init(workspaceID: workspaceB, address: nil)
        ], panels: [
            .init(panelID: panelA, workspaceID: workspaceB, address: "captain", title: "Remote captain"),
            .init(panelID: panelB, workspaceID: workspaceA, address: "Captain", title: "Same-looking title")
        ])
        XCTAssertTrue(projection.isCaptain(panelA))
        XCTAssertFalse(projection.isCaptain(panelB), "address equality is exact, with no title or local preference")
        let summary = projection.summary(for: workspaceA)
        XCTAssertEqual(summary.state, .present)
        XCTAssertEqual(summary.title, "Remote captain")
        XCTAssertEqual(summary.panelIDs, [panelA])
        XCTAssertEqual(projection.summary(for: workspaceB), .unset)
    }

    func testDuplicateHoldersAreAllCaptainsAndNeverChooseTheLocalOne() {
        let panels: [WorkspaceCaptainProjection.Holder] = [
            .init(panelID: panelB, workspaceID: workspaceB, address: "captain", title: "B"),
            .init(panelID: panelA, workspaceID: workspaceA, address: "captain", title: "A")
        ]
        let declarations = [WorkspaceCaptainProjection.Declaration(workspaceID: workspaceA, address: "captain")]
        let projection = WorkspaceCaptainProjection(workspaces: declarations, panels: panels)
        let summary = projection.summary(for: workspaceA)
        XCTAssertEqual(summary.state, .ambiguous)
        XCTAssertTrue(summary.present)
        XCTAssertNil(summary.title)
        XCTAssertEqual(summary.panelIDs, [panelA, panelB], "holder ordering is stable across topology enumeration")
        XCTAssertEqual(projection.captainPanelIDs, Set([panelA, panelB]))
        XCTAssertEqual(projection, WorkspaceCaptainProjection(workspaces: declarations, panels: Array(panels.reversed())))
    }

    /// C11H-360: a panel on this Mac holding the Captain address wins over a
    /// linked panel holding it too; a linked holder alone stays the holder.
    func testLocalHolderOutranksALinkedHolderOfTheCaptainAddress() {
        let declarations = [WorkspaceCaptainProjection.Declaration(workspaceID: workspaceA, address: "ship-captain")]
        let both = WorkspaceCaptainProjection(workspaces: declarations, panels: [
            .init(panelID: panelA, workspaceID: workspaceB, address: "ship-captain", title: "Remote", linked: true),
            .init(panelID: panelB, workspaceID: workspaceA, address: "ship-captain", title: "Local"),
        ])
        XCTAssertEqual(both.summary(for: workspaceA).panelIDs, [panelB])
        XCTAssertEqual(both.captainPanelIDs, [panelB])
        let linkedAlone = WorkspaceCaptainProjection(workspaces: declarations, panels: [
            .init(panelID: panelA, workspaceID: workspaceB, address: "ship-captain", title: "Remote", linked: true),
        ])
        XCTAssertEqual(linkedAlone.summary(for: workspaceA).panelIDs, [panelA])
        XCTAssertEqual(linkedAlone.captainPanelIDs, [panelA])
    }

    func testCloseRecreateAndAddressReassignmentRecomputePresence() {
        let declarations = [WorkspaceCaptainProjection.Declaration(workspaceID: workspaceA, address: "captain")]
        let absent = WorkspaceCaptainProjection(workspaces: declarations, panels: [])
        XCTAssertEqual(absent.summary(for: workspaceA).state, .unheld)
        XCTAssertFalse(absent.summary(for: workspaceA).present)
        let reopened = WorkspaceCaptainProjection(workspaces: declarations, panels: [
            .init(panelID: panelB, workspaceID: workspaceB, address: "captain", title: "Recreated")
        ])
        XCTAssertEqual(reopened.summary(for: workspaceA).panelIDs, [panelB])
        let reassigned = WorkspaceCaptainProjection(workspaces: declarations, panels: [
            .init(panelID: panelB, workspaceID: workspaceB, address: "other", title: "Recreated")
        ])
        XCTAssertEqual(reassigned.summary(for: workspaceA), absent.summary(for: workspaceA))
        XCTAssertTrue(reassigned.captainPanelIDs.isEmpty)
    }

    func testMultipleDeclarationsShareHolderAndClearingLastDeclarationRemovesMark() {
        let panels = [WorkspaceCaptainProjection.Holder(panelID: panelA, workspaceID: workspaceB,
                                                        address: "captain", title: "Captain")]
        let shared = WorkspaceCaptainProjection(workspaces: [
            .init(workspaceID: workspaceA, address: "captain"),
            .init(workspaceID: workspaceB, address: "captain")
        ], panels: panels)
        XCTAssertEqual(shared.summary(for: workspaceA), shared.summary(for: workspaceB))
        let cleared = WorkspaceCaptainProjection(workspaces: [
            .init(workspaceID: workspaceA, address: nil), .init(workspaceID: workspaceB, address: nil)
        ], panels: panels)
        XCTAssertTrue(cleared.captainPanelIDs.isEmpty)
        XCTAssertEqual(cleared.summary(for: workspaceA).state, .unset)
    }

    func testFleetRetainsEmptyWorkspacesAndExplicitAbsentState() throws {
        let summary = WorkspaceCaptainSummary(address: "captain", holders: [])
        let snapshot = FleetSnapshot(capturedAt: Date(timeIntervalSince1970: 100),
            metadata: .init(metadata: [:], sources: [:]), panels: [], workspaceCount: 2,
            windowCount: 1, mainCopyDurationMs: 0, workspaces: [
                .init(windowId: workspaceA, id: workspaceA, title: "Empty", captain: summary),
                .init(windowId: workspaceA, id: workspaceB, title: "Unset", captain: .unset)
            ])
        let document = snapshot.document()
        XCTAssertEqual((document["panels"] as? [[String: Any]])?.count, 0)
        let workspaces = try XCTUnwrap(document["workspaces"] as? [[String: Any]])
        XCTAssertEqual(workspaces.count, 2)
        XCTAssertEqual(workspaces[0]["captain"] as? String, "captain")
        XCTAssertEqual(workspaces[0]["captain_present"] as? Bool, false)
        XCTAssertEqual(workspaces[0]["captain_state"] as? String, "unheld")
        XCTAssertEqual(workspaces[0]["captain_panel_ids"] as? [String], [])
        XCTAssertTrue(workspaces[0]["captain_title"] is NSNull)
        XCTAssertTrue(workspaces[1]["captain"] is NSNull)
    }

    func testCaptainRingIsSeparateOnAllFourEdgesAndSupportsFramelessThemes() throws {
        let area = NSRect(x: 10, y: 20, width: 300, height: 180)
        let inner = try XCTUnwrap(AreaFrameGeometry.captainRect(in: area, outerThickness: 2))
        XCTAssertEqual(inner, area.insetBy(dx: 3, dy: 3))
        let ring = AreaFrameGeometry.ringPath(rect: inner, thickness: 1, radii: .init(0))
        XCTAssertTrue(ring.contains(NSPoint(x: inner.minX + 0.5, y: inner.midY)))
        XCTAssertTrue(ring.contains(NSPoint(x: inner.maxX - 0.5, y: inner.midY)))
        XCTAssertTrue(ring.contains(NSPoint(x: inner.midX, y: inner.minY + 0.5)))
        XCTAssertTrue(ring.contains(NSPoint(x: inner.midX, y: inner.maxY - 0.5)))
        XCTAssertFalse(ring.contains(NSPoint(x: area.minX + 1, y: area.midY)), "outer focus/waiting ink stays separate")
        XCTAssertFalse(ring.contains(NSPoint(x: inner.midX, y: inner.midY)))
        XCTAssertEqual(AreaFrameGeometry.captainRect(in: area, outerThickness: 0), area.insetBy(dx: 1, dy: 1))
        XCTAssertNil(AreaFrameGeometry.captainRect(in: NSRect(x: 0, y: 0, width: 4, height: 4), outerThickness: 1))
    }
    func testAuthoredCaptainFieldCannotSpoofFleetDerivedSibling() throws {
        let metadata: [String: Any] = ["is_captain": true, MetadataKey.terminalType: "claude-code"]
        let panel = FleetSnapshot.Panel(windowId: workspaceA, workspaceId: workspaceA, workspaceTitle: "Fixture",
            panelId: panelA, panelTitle: "Not captain", detectedKind: "claude-code", activity: nil,
            cold: false, unreadNotification: false, journalAttention: false, parentPanelId: nil,
            lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false, unreadMail: nil,
            lastSeenAt: nil, beingSeen: false, isCaptain: false)
        let snapshot = FleetSnapshot(capturedAt: Date(timeIntervalSince1970: 100),
            metadata: .init(metadata: [workspaceA: [panelA: metadata]], sources: [:]),
            panels: [panel], workspaceCount: 1, windowCount: 1, mainCopyDurationMs: 0)
        let rows = try XCTUnwrap(snapshot.document()["panels"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["is_captain"] as? Bool, false)
    }
    func testOnlyActualIdentityChangesNotifyAcrossWriteRestoreAndRemovePaths() throws {
        let store = PanelMetadataStore()
        let changed = expectation(description: "six actual identity changes")
        changed.expectedFulfillmentCount = 6
        changed.assertForOverFulfill = true
        let token = NotificationCenter.default.addObserver(
            forName: PanelMetadataStore.identityDidChangeNotification, object: store, queue: .main
        ) { note in
            let keys = note.userInfo?["changedKeys"] as? [String]
            XCTAssertNotNil(keys)
            XCTAssertFalse(keys?.isEmpty ?? true)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try store.setMetadata(workspaceId: workspaceA, surfaceId: panelA,
            partial: [MetadataKey.mailboxAddress: "captain"], mode: .merge, source: .explicit)
        _ = try store.setMetadata(workspaceId: workspaceA, surfaceId: panelA,
            partial: [MetadataKey.mailboxAddress: "captain", "status": "working"], mode: .merge, source: .explicit)
        XCTAssertTrue(store.setInternal(workspaceId: workspaceA, surfaceId: panelA,
            key: MetadataKey.title, value: "Captain", source: .heuristic))
        _ = try store.clearMetadata(workspaceId: workspaceA, surfaceId: panelA,
            keys: [MetadataKey.mailboxAddress], source: .explicit)
        _ = try store.setMetadata(workspaceId: workspaceA, surfaceId: panelA,
            partial: ["status": "idle"], mode: .replace, source: .explicit)
        store.restoreFromSnapshot(workspaceId: workspaceA, surfaceId: panelA,
            values: [MetadataKey.mailboxAddress: "captain"], sources: [:])
        store.removeSurface(workspaceId: workspaceA, surfaceId: panelA)
        let drained = expectation(description: "notification queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [changed, drained], timeout: 1)
    }

    @MainActor
    func testTitleBurstWithoutDeclarationsDoesNotCapture() {
        let fixture = CaptainRefreshFixture()
        // Even before initial topology capture, a title cannot create a captain.
        fixture.coordinator.invalidateTitle()
        XCTAssertTrue(fixture.scheduled.isEmpty)
        fixture.declarations = [.init(workspaceID: workspaceA, address: nil)]
        fixture.coordinator.invalidate()
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 1)
        for _ in 0..<100 {
            fixture.coordinator.invalidateTitle()
            fixture.panelIdentityChanged([MetadataKey.title])
        }
        fixture.workspaceMetadataChanged(keys: [WorkspaceMetadataKey.description])
        XCTAssertTrue(fixture.scheduled.isEmpty, "title-only churn must not even schedule a projection capture")
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 1)
    }

    @MainActor
    func testTitleBurstWithCaptainCoalescesAndCapturesFinalTitle() {
        let fixture = CaptainRefreshFixture()
        fixture.declarations = [.init(workspaceID: workspaceA, address: "captain")]
        fixture.holders = [.init(panelID: panelA, workspaceID: workspaceB, address: "captain", title: "Before")]
        fixture.coordinator.invalidate()
        fixture.drain()
        for index in 0..<100 {
            fixture.holders = [.init(panelID: panelA, workspaceID: workspaceB,
                                     address: "captain", title: "Title \(index)")]
            fixture.coordinator.invalidateTitle()
            fixture.panelIdentityChanged([MetadataKey.title])
        }
        XCTAssertEqual(fixture.scheduled.count, 1, "direct and metadata title signals share the same pending turn")
        XCTAssertEqual(fixture.captureCount, 1)
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 2)
        XCTAssertEqual(fixture.published?.summary(for: workspaceA).title, "Title 99")
    }

    @MainActor
    func testDeclarationNotificationDiscoversNewCaptainAndClearsLastCaptain() {
        let fixture = CaptainRefreshFixture()
        fixture.declarations = [.init(workspaceID: workspaceA, address: nil)]
        fixture.coordinator.invalidate()
        fixture.drain()
        fixture.declarations = [.init(workspaceID: workspaceA, address: "captain")]
        fixture.holders = [.init(panelID: panelA, workspaceID: workspaceB, address: "captain", title: "New captain")]
        fixture.workspaceMetadataChanged(keys: [WorkspaceMetadataKey.captain])
        // The old cached false must not cancel the forced declaration capture.
        fixture.coordinator.invalidateTitle()
        fixture.panelIdentityChanged([MetadataKey.title])
        XCTAssertEqual(fixture.scheduled.count, 1)
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 2)
        XCTAssertEqual(fixture.published?.captainPanelIDs, Set([panelA]))
        XCTAssertEqual(fixture.published?.summary(for: workspaceA).title, "New captain")

        fixture.declarations = [.init(workspaceID: workspaceA, address: nil)]
        fixture.workspaceMetadataChanged(keys: [], removed: [WorkspaceMetadataKey.captain])
        fixture.coordinator.invalidateTitle()
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 3)
        XCTAssertEqual(fixture.published?.summary(for: workspaceA), .unset)
        XCTAssertEqual(fixture.published?.captainPanelIDs, Set<UUID>())
        for _ in 0..<100 { fixture.coordinator.invalidateTitle() }
        fixture.panelIdentityChanged([MetadataKey.title])
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 3, "clearing the last declaration re-arms the negative title fast path")
    }

    @MainActor
    func testAddressAndTopologyChangesAlwaysRefreshPresence() {
        let fixture = CaptainRefreshFixture()
        fixture.declarations = [.init(workspaceID: workspaceA, address: "captain")]
        fixture.holders = [.init(panelID: panelA, workspaceID: workspaceB, address: "captain", title: "Captain")]
        fixture.coordinator.invalidate()
        fixture.drain()
        fixture.holders = [.init(panelID: panelA, workspaceID: workspaceB, address: "other", title: "Renamed")]
        fixture.panelIdentityChanged([MetadataKey.title, MetadataKey.mailboxAddress])
        fixture.drain()
        XCTAssertEqual(fixture.published?.summary(for: workspaceA).state, .unheld)
        fixture.holders = [.init(panelID: panelB, workspaceID: workspaceB, address: "captain", title: "Recreated")]
        fixture.coordinator.invalidate()
        fixture.coordinator.invalidate()
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 3)
        XCTAssertEqual(fixture.published?.summary(for: workspaceA).panelIDs, [panelB])
        fixture.holders = []
        fixture.coordinator.invalidate()
        fixture.drain()
        XCTAssertEqual(fixture.captureCount, 4)
        XCTAssertEqual(fixture.published?.summary(for: workspaceA).state, .unheld)
    }

}


/// Runs the real coordinator's notification routing and scheduler, with no
/// Workspace/AppDelegate/NSApp. Each refresh captures the current value inputs.
@MainActor
private final class CaptainRefreshFixture {
    var declarations: [WorkspaceCaptainProjection.Declaration] = []
    var holders: [WorkspaceCaptainProjection.Holder] = []
    var scheduled: [@MainActor () -> Void] = []
    var captureCount = 0
    var published: WorkspaceCaptainProjection?
    let center = NotificationCenter()
    lazy var coordinator = WorkspaceCaptainCoordinator(notificationCenter: center,
        schedule: { [unowned self] in self.scheduled.append($0) },
        refreshProjection: { [unowned self] in
            self.captureCount += 1
            let projection = WorkspaceCaptainProjection(workspaces: self.declarations, panels: self.holders)
            self.published = projection
            return projection
        })

    func drain() {
        let callbacks = scheduled
        scheduled.removeAll()
        for callback in callbacks { callback() }
    }

    func panelIdentityChanged(_ keys: [String]) {
        center.post(name: PanelMetadataStore.identityDidChangeNotification, object: nil,
                    userInfo: ["changedKeys": keys])
    }

    func workspaceMetadataChanged(keys: [String], removed: [String] = []) {
        center.post(name: WorkspaceMetadataStore.didChangeNotification, object: nil,
                    userInfo: ["changedKeys": keys, "removedKeys": removed])
    }
}

/// C11H-299: a ship may be a workspace group. A workspace resolves its own
/// Captain first, then its group's; every surface reads that one rule.
final class WorkspaceGroupCaptainTests: XCTestCase {
    private let member = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
    private let elsewhere = UUID(uuidString: "00000000-0000-0000-0000-0000000000a3")!
    private let group = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
    private let holder = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!

    private func captainPanel(_ id: UUID, address: String, in workspace: UUID) -> WorkspaceCaptainProjection.Holder {
        .init(panelID: id, workspaceID: workspace, address: address, title: "Acme Captain")
    }

    func testMemberWithoutOwnKeyResolvesGroupCaptainHeldInAnotherWorkspace() {
        let projection = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group),
                         .init(workspaceID: other, address: nil)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere)])
        let summary = projection.summary(for: member)
        XCTAssertEqual(summary.address, "acme-captain")
        XCTAssertEqual(summary.state, .present)
        XCTAssertEqual(summary.scope, .workspaceGroup)
        XCTAssertEqual(summary.groupID, group)
        XCTAssertEqual(summary.panelIDs, [holder])
        XCTAssertTrue(summary.shownByGroup)
        XCTAssertFalse(summary.cardShowsMark, "the group header carries the mark, never the member card")
        XCTAssertEqual(projection.summary(for: other), .unset, "an ungrouped workspace inherits nothing")
        XCTAssertTrue(projection.isCaptain(holder))
        XCTAssertEqual(projection.groupSummary(for: group).state, .present)
        XCTAssertEqual(projection.groupSummary(for: group).scope, .workspaceGroup)
    }

    func testWorkspaceKeyWinsOverGroupAndSameAddressDefersToHeader() {
        let projection = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: "repo-captain", groupID: group),
                         .init(workspaceID: other, address: "acme-captain", groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere)])
        let own = projection.summary(for: member)
        XCTAssertEqual(own.address, "repo-captain", "a member's own key (explicit or C11.md) is never overridden")
        XCTAssertEqual(own.scope, .workspace)
        XCTAssertEqual(own.state, .unheld)
        XCTAssertTrue(own.cardShowsMark, "a different Captain of its own still shows on the card")
        let same = projection.summary(for: other)
        XCTAssertEqual(same.scope, .workspace)
        XCTAssertTrue(same.shownByGroup)
        XCTAssertFalse(same.cardShowsMark, "the same address as the header is drawn once")
    }

    func testLeavingOrDeletingTheGroupFallsBackToTheWorkspaceKey() {
        let panels = [captainPanel(holder, address: "acme-captain", in: elsewhere)]
        let groups = [WorkspaceCaptainProjection.GroupDeclaration(groupID: group, address: "acme-captain")]
        let left = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: nil)], groups: groups, panels: panels)
        XCTAssertEqual(left.summary(for: member), .unset)
        let deleted = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: "repo-captain", groupID: group)], groups: [], panels: panels)
        XCTAssertEqual(deleted.summary(for: member).address, "repo-captain")
        XCTAssertFalse(deleted.summary(for: member).shownByGroup)
        XCTAssertFalse(deleted.isCaptain(holder), "a deleted group's address marks no one")
        let cleared = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: nil)], panels: panels)
        XCTAssertEqual(cleared.summary(for: member), .unset)
        XCTAssertEqual(cleared.groupSummary(for: group), .unset)
    }

    func testEmptyGroupStillMarksItsHolderAndReportsAbsenceAndAmbiguity() {
        let empty = WorkspaceCaptainProjection(workspaces: [], groups: [.init(groupID: group, address: "acme-captain")],
                                               panels: [captainPanel(holder, address: "acme-captain", in: elsewhere)])
        XCTAssertTrue(empty.isCaptain(holder))
        XCTAssertTrue(empty.hasDeclarations)
        let absent = WorkspaceCaptainProjection(workspaces: [], groups: [.init(groupID: group, address: "acme-captain")], panels: [])
        XCTAssertEqual(absent.groupSummary(for: group).state, .unheld)
        let ambiguous = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere),
                     captainPanel(second, address: "acme-captain", in: member)])
        XCTAssertEqual(ambiguous.summary(for: member).state, .ambiguous)
        XCTAssertEqual(ambiguous.groupSummary(for: group).panelIDs, [holder, second])
    }

    func testJSONNamesWhereTheCaptainCameFrom() throws {
        let projection = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group),
                         .init(workspaceID: other, address: "repo-captain", groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")], panels: [])
        let inherited = projection.summary(for: member).jsonObject
        XCTAssertEqual(inherited["captain"] as? String, "acme-captain")
        XCTAssertEqual(inherited["captain_scope"] as? String, "workspace_group")
        XCTAssertEqual(inherited["captain_group_id"] as? String, group.uuidString)
        let own = projection.summary(for: other).jsonObject
        XCTAssertEqual(own["captain_scope"] as? String, "workspace")
        XCTAssertTrue(own["captain_group_id"] is NSNull, "a member's own Captain names no group")
        XCTAssertTrue(WorkspaceCaptainSummary.unset.jsonObject["captain_scope"] is NSNull)
        let record = projection.groupSummary(for: group).presenceJSONObject
        XCTAssertEqual(record["captain_state"] as? String, "unheld")
        XCTAssertNil(record["captain_scope"])
    }

    func testFleetListsGroupsWithTheirCaptainPresence() throws {
        let projection = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere)])
        let snapshot = FleetSnapshot(capturedAt: Date(timeIntervalSince1970: 100),
            metadata: .init(metadata: [:], sources: [:]), panels: [], workspaceCount: 1,
            windowCount: 1, mainCopyDurationMs: 0,
            workspaces: [.init(windowId: elsewhere, id: member, title: "Acme web", captain: projection.summary(for: member))],
            workspaceGroups: [.init(windowId: elsewhere, id: group, name: "Acme", memberWorkspaceIds: [member],
                                    captain: projection.groupSummary(for: group))])
        let document = snapshot.document()
        let groups = try XCTUnwrap(document["workspace_groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["name"] as? String, "Acme")
        XCTAssertEqual(groups[0]["captain"] as? String, "acme-captain")
        XCTAssertEqual(groups[0]["captain_present"] as? Bool, true)
        XCTAssertEqual(groups[0]["captain_panel_ids"] as? [String], [holder.uuidString])
        XCTAssertEqual(groups[0]["member_workspace_ids"] as? [String], [member.uuidString])
        let rows = try XCTUnwrap(document["workspaces"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["captain_scope"] as? String, "workspace_group")
    }

    func testToCaptainFromAGroupedWorkspaceReachesTheGroupCaptainOrFailsBeforeWriting() throws {
        let present = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere)])
        guard case .holder(let address, let target, let scope) =
                WorkspaceCaptainMailRoute.route(present.summary(for: member), workspaceGroupID: group) else {
            return XCTFail("a grouped workspace with no Captain of its own must reach the group's")
        }
        XCTAssertEqual(address, "acme-captain")
        XCTAssertEqual(target.panelID, holder)
        XCTAssertEqual(scope["captain_scope"] as? String, "workspace_group")
        XCTAssertEqual(scope["captain_group_id"] as? String, group.uuidString)

        func failure(_ summary: WorkspaceCaptainSummary, grouped: UUID?) -> (String, String, [String: Any]?)? {
            if case .failure(let code, let message, let data) = WorkspaceCaptainMailRoute.route(summary, workspaceGroupID: grouped) {
                return (code, message, data)
            }
            return nil
        }
        let unset = try XCTUnwrap(failure(.unset, grouped: group))
        XCTAssertEqual(unset.0, "captain_unset")
        XCTAssertTrue(unset.1.contains("group"), unset.1)
        XCTAssertTrue(unset.1.contains("no envelope was written"))
        let ungroupedUnset = try XCTUnwrap(failure(.unset, grouped: nil))
        XCTAssertEqual(ungroupedUnset.0, "captain_unset")
        // C11H-301: every captain error carries the same scope fields; unset names neither.
        for data in [unset.2, ungroupedUnset.2] {
            let fields = try XCTUnwrap(data, "captain_unset must carry captain_scope and captain_group_id")
            XCTAssertTrue(fields["captain_scope"] is NSNull)
            XCTAssertTrue(fields["captain_group_id"] is NSNull)
        }
        let unheld = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")], panels: [])
        let noHolder = try XCTUnwrap(failure(unheld.summary(for: member), grouped: group))
        XCTAssertEqual(noHolder.0, "captain_unheld")
        XCTAssertEqual(noHolder.2?["captain_scope"] as? String, "workspace_group")
        XCTAssertEqual(noHolder.2?["captain"] as? String, "acme-captain")
        let two = WorkspaceCaptainProjection(
            workspaces: [.init(workspaceID: member, address: nil, groupID: group)],
            groups: [.init(groupID: group, address: "acme-captain")],
            panels: [captainPanel(holder, address: "acme-captain", in: elsewhere),
                     captainPanel(second, address: "acme-captain", in: other)])
        let several = try XCTUnwrap(failure(two.summary(for: member), grouped: group))
        XCTAssertEqual(several.0, "captain_ambiguous")
        XCTAssertEqual(several.2?["panel_ids"] as? [String], [holder.uuidString, second.uuidString])
    }

    /// C11H-301: a workspace-group command builds its records from this
    /// window's groups and walks the open panels only when one of them
    /// declares a Captain, never because some workspace elsewhere has one.
    func testGroupRecordsWalkPanelsOnlyWhenAGroupInTheWindowDeclaresACaptain() {
        let quiet = WorkspaceGroup(id: group, name: "Acme")
        let declared = WorkspaceGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!, name: "Ops")
        let fleet = [captainPanel(holder, address: "ops-captain", in: elsewhere),
                     captainPanel(second, address: "repo-captain", in: member)]
        var walks = 0
        var walked = 0
        func holders() -> [WorkspaceCaptainProjection.Holder] {
            walks += 1
            walked += fleet.count
            return fleet
        }
        func groupMetadata(_ metadata: [UUID: [String: Any]]) -> WorkspaceMetadataStore.ReadSnapshot {
            .init(metadata: metadata, sources: [:], revision: 1)
        }

        let none = WorkspaceCaptainProjection.groupPresence(groups: [quiet], groupMetadata: groupMetadata([:]), holders: holders)
        XCTAssertEqual(none.groupSummary(for: group), .unset)
        let blank = WorkspaceCaptainProjection.groupPresence(
            groups: [quiet], groupMetadata: groupMetadata([group: [WorkspaceMetadataKey.captain: ""]]), holders: holders)
        XCTAssertEqual(blank.groupSummary(for: group), .unset)
        let otherWindow = WorkspaceCaptainProjection.groupPresence(
            groups: [quiet], groupMetadata: groupMetadata([declared.id: [WorkspaceMetadataKey.captain: "ops-captain"]]),
            holders: holders)
        XCTAssertEqual(otherWindow.groupSummary(for: group), .unset)
        XCTAssertEqual(walks, 0, "no group in this window declares a Captain, so no panel is walked")
        XCTAssertEqual(walked, 0)

        let present = WorkspaceCaptainProjection.groupPresence(
            groups: [quiet, declared], groupMetadata: groupMetadata([declared.id: [WorkspaceMetadataKey.captain: "ops-captain"]]),
            holders: holders)
        XCTAssertEqual(walks, 1, "one walk per command when a group here declares a Captain")
        XCTAssertEqual(walked, fleet.count)
        XCTAssertEqual(present.groupSummary(for: declared.id).state, .present)
        XCTAssertEqual(present.groupSummary(for: declared.id).panelIDs, [holder], "presence is instance-wide")
        XCTAssertEqual(present.groupSummary(for: group), .unset)
        XCTAssertFalse(present.isCaptain(second), "a workspace's own Captain is not a group record's concern")
    }
}
