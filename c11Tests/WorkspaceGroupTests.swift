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
