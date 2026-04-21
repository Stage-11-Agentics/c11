import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tier 1 persistence, Phase 1 — stable panel UUIDs via restore-time ID injection.
///
/// These tests exercise the contract: after snapshotting a workspace and
/// restoring it into a fresh workspace, each panel's UUID matches the UUID it
/// had in the snapshot. External consumers (Lattice, CLI, socket tests) cache
/// panel IDs, so the restore path must preserve them — not mint fresh UUIDs and
/// remap them internally the way pre-Phase-1 code did.
final class PanelIdentityRestoreTests: XCTestCase {
    @MainActor
    func testTerminalPanelIdIsStableAcrossRoundTrip() throws {
        let workspace = Workspace()
        let originalPanelIds = Set(workspace.panels.keys)
        XCTAssertEqual(originalPanelIds.count, 1, "Workspace() should seed exactly one terminal panel")

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let snapshotPanelIds = Set(snapshot.panels.map(\.id))
        XCTAssertEqual(snapshotPanelIds, originalPanelIds)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelIds = Set(restored.panels.keys)
        XCTAssertEqual(
            restoredPanelIds,
            snapshotPanelIds,
            "Restored terminal panels should keep the UUIDs from the snapshot"
        )
    }

    @MainActor
    func testMarkdownPanelIdIsStableAcrossRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownURL = root.appendingPathComponent("note.md")
        try "# hello\n".write(to: markdownURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let markdownPanel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: markdownURL.path, focus: true)
        )
        let expectedIds = Set(workspace.panels.keys)
        XCTAssertTrue(expectedIds.contains(markdownPanel.id))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredIds = Set(restored.panels.keys)
        XCTAssertEqual(restoredIds, expectedIds)
        XCTAssertNotNil(
            restored.markdownPanel(for: markdownPanel.id),
            "Markdown panel UUID should round-trip and resolve on the restored workspace"
        )
    }

    @MainActor
    func testBrowserPanelIdIsStableAcrossRoundTrip() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "https://example.com"),
                focus: false
            )
        )
        let expectedIds = Set(workspace.panels.keys)
        XCTAssertTrue(expectedIds.contains(browserPanel.id))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredIds = Set(restored.panels.keys)
        XCTAssertEqual(restoredIds, expectedIds)
    }

    @MainActor
    func testMixedPanelTypesAllSurviveRoundTripWithSameIds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-identity-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownURL = root.appendingPathComponent("mixed.md")
        try "mixed\n".write(to: markdownURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let terminalPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "https://example.com"),
                focus: false
            )
        )
        let markdownPanel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: markdownURL.path, focus: false)
        )

        let expected = Set(workspace.panels.keys)
        XCTAssertTrue(expected.contains(terminalPanel.id))
        XCTAssertTrue(expected.contains(browserPanel.id))
        XCTAssertTrue(expected.contains(markdownPanel.id))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(Set(restored.panels.keys), expected)
    }

    @MainActor
    func testStablePanelIdsPolicyIsOnByDefault() {
        XCTAssertTrue(
            SessionPersistencePolicy.stablePanelIdsEnabled,
            "Phase 1 default: panel IDs are stable across restarts unless CMUX_DISABLE_STABLE_PANEL_IDS is set"
        )
    }
}
