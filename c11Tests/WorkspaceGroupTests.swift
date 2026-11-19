import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceGroupTests: XCTestCase {
    func testGroupRoundtripRetainsAllPropertiesIncludingEmptyFolder() throws {
        let groups = [WorkspaceGroup(name: "Empty"),
                      WorkspaceGroup(name: "Services", color: "#123456", icon: "folder.fill", isCollapsed: true, isPinned: true)]
        let snapshot = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [], workspaceGroups: groups)
        let restored = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.workspaceGroups, groups)
        XCTAssertTrue(restored.workspaces.isEmpty)
    }

    func testOldManagerSnapshotDecodesWithoutGroups() throws {
        let restored = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self,
                                               from: Data(#"{"workspaces":[]}"#.utf8))
        XCTAssertNil(restored.workspaceGroups)
        XCTAssertEqual(WorkspaceGroupProjection.restoredGroups(restored.workspaceGroups), [])
    }

    /// C11H-342: a session saved by a build without the root order (every
    /// build before this one) has no `workspaceRootOrder` key and restores
    /// exactly as it drew: groups first, then ungrouped workspaces.
    func testSnapshotWithoutRootOrderRestoresGroupsFirstAndInterleavedOrderRoundTrips() throws {
        let group = WorkspaceGroup(name: "Fleet")
        let flagship = UUID(), member = UUID()
        let entries = [WorkspaceOrderEntry(id: flagship, isPinned: false),
                       WorkspaceOrderEntry(id: member, isPinned: false, groupId: group.id)]
        let groupJSON = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
        let old = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: Data(
            #"{"selectedWorkspaceIndex":0,"workspaces":[],"workspaceGroups":[\#(groupJSON)]}"#.utf8))
        XCTAssertNil(old.workspaceRootOrder)
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: old.workspaceRootOrder, groups: old.workspaceGroups ?? [],
                                                  workspaces: entries).map(\.id), [group.id, flagship])
        let unsaved = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [], workspaceGroups: [group])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(unsaved), as: UTF8.self).contains("workspaceRootOrder"),
                       "no order, no key: the saved shape stays as before")
        let saved = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [], workspaceGroups: [group],
                                                    workspaceRootOrder: [flagship, group.id])
        let restored = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(WorkspaceRootOrder.resolve(stored: restored.workspaceRootOrder, groups: [group],
                                                  workspaces: entries).map(\.id), [flagship, group.id])
    }

    func testCorruptGroupRestoreKeepsFirstDuplicateAndNormalizesPinOrder() {
        let first = WorkspaceGroup(name: "First")
        var duplicate = first
        duplicate.name = "Discarded"
        let pinned = WorkspaceGroup(name: "Pinned", isPinned: true)
        XCTAssertEqual(WorkspaceGroupProjection.restoredGroups([first, duplicate, pinned]), [pinned, first])
    }

    func testProjectionKeepsPinnedMembersInsideUnpinnedFolderAndRetainsEmptyFolder() {
        let unpinned = WorkspaceGroup(name: "Work", isCollapsed: true)
        let pinned = WorkspaceGroup(name: "Empty", isPinned: true)
        let ids = (0..<4).map { _ in UUID() }
        let entries = [WorkspaceOrderEntry(id: ids[0], isPinned: true, groupId: unpinned.id),
                       WorkspaceOrderEntry(id: ids[1], isPinned: true),
                       WorkspaceOrderEntry(id: ids[2], isPinned: false, groupId: unpinned.id),
                       WorkspaceOrderEntry(id: ids[3], isPinned: false)]
        XCTAssertEqual(WorkspaceGroupProjection.items(groups: [unpinned, pinned], workspaces: entries), [
            .group(pinned, memberWorkspaceIds: []), .workspace(ids[1]),
            .group(unpinned, memberWorkspaceIds: [ids[0], ids[2]]), .workspace(ids[3])
        ])
    }

    func testPaletteHexResolvesToPaletteName() {
        let palette = WorkspaceColorSettings.defaultPalette
        for entry in palette {
            XCTAssertEqual(WorkspaceColorSettings.paletteName(forHex: entry.hex, in: palette), entry.name)
        }
        XCTAssertEqual(WorkspaceColorSettings.paletteName(forHex: "1565c0", in: palette), "Blue")
        XCTAssertEqual(WorkspaceColorSettings.paletteName(forHex: " #c0392b ", in: palette), "Red")
    }

    func testUnknownHexHasNoPaletteNameAndDisplaysAsHex() {
        let palette = WorkspaceColorSettings.defaultPalette
        XCTAssertNil(WorkspaceColorSettings.paletteName(forHex: "#123456", in: palette))
        XCTAssertNil(WorkspaceColorSettings.paletteName(forHex: "not-a-color", in: palette))
        XCTAssertEqual(WorkspaceColorSettings.displayLabel(forHex: "#123456", in: palette), "#123456")
    }

    func testDisplayLabelNeverShowsHexForPaletteColor() {
        let palette = WorkspaceColorSettings.defaultPalette
        for entry in palette {
            let label = WorkspaceColorSettings.displayLabel(forHex: entry.hex, in: palette)
            XCTAssertFalse(label.hasPrefix("#"), "\(entry.name) rendered as \(label)")
        }
    }
}
