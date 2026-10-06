import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
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
    func testDuplicateRecordsAndLayoutReferencesRestoreOnceAndSurviveSecondRestore() throws {
        let workspace = Workspace()
        let a = try XCTUnwrap(workspace.panels.keys.first)
        let firstPane = try XCTUnwrap(workspace.paneId(forPanelId: a))
        let b = try XCTUnwrap(workspace.newTerminalSurface(inPane: firstPane, focus: false)).id
        let c = try XCTUnwrap(workspace.newTerminalSplit(
            from: a, orientation: .horizontal, insertFirst: false, focus: false
        )).id
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let index = try XCTUnwrap(snapshot.panels.firstIndex { $0.id == a })
        snapshot.panels[index].metadata = ["fixture": .string("first")]
        var duplicate = snapshot.panels[index]
        duplicate.metadata = ["fixture": .string("discarded")]
        snapshot.panels.insert(duplicate, at: index + 1)
        snapshot.layout = .split(SessionSplitLayoutSnapshot(
            orientation: .horizontal, dividerPosition: 0.4,
            first: .pane(SessionAreaLayoutSnapshot(panelIds: [a, a, b], selectedPanelId: b)),
            second: .pane(SessionAreaLayoutSnapshot(panelIds: [a, c], selectedPanelId: a))
        ))
        snapshot.focusedPanelId = c

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(Set(restored.panels.keys), Set([a, b, c]))
        XCTAssertEqual(restored.paneId(forPanelId: a), restored.paneId(forPanelId: b))
        XCTAssertNotEqual(restored.paneId(forPanelId: a), restored.paneId(forPanelId: c))
        let metadata = PanelMetadataStore.shared.getMetadata(workspaceId: restored.id, surfaceId: a)
        XCTAssertEqual(metadata.metadata["fixture"] as? String, "first")
        XCTAssertEqual(restored.focusedPanelId, c)

        let saved = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertTrue(SessionRestoreNormalization.normalize(saved).drops.isEmpty)
        guard case .split(let split) = saved.layout,
              case .pane(let left) = split.first,
              case .pane(let right) = split.second else { return XCTFail("restored split") }
        XCTAssertEqual(left.panelIds, [a, b])
        XCTAssertEqual(left.selectedPanelId, b)
        XCTAssertEqual(right.panelIds, [c])
        XCTAssertEqual(right.selectedPanelId, c)

        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(saved))
        let relaunched = Workspace()
        relaunched.restoreSessionSnapshot(decoded)
        XCTAssertEqual(Set(relaunched.panels.keys), Set([a, b, c]))
        XCTAssertEqual(relaunched.focusedPanelId, c)
        XCTAssertEqual(PanelMetadataStore.shared.getMetadata(
            workspaceId: relaunched.id, surfaceId: a
        ).metadata["fixture"] as? String, "first")
    }

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
            workspace.newMarkdownPanel(inPane: paneId, filePath: markdownURL.path, focus: true)
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
        let initialPanelId = try XCTUnwrap(workspace.panels.keys.first)
        let terminalPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: initialPanelId, orientation: .horizontal, insertFirst: false, focus: false
        ))
        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "about:blank"),
                focus: false
            )
        )
        let markdownPanel = try XCTUnwrap(
            workspace.newMarkdownPanel(inPane: paneId, filePath: markdownURL.path, focus: false)
        )

        let expected = Set(workspace.panels.keys)
        XCTAssertTrue(expected.contains(terminalPanel.id))
        XCTAssertTrue(expected.contains(browserPanel.id))
        XCTAssertTrue(expected.contains(markdownPanel.id))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(Set(restored.panels.keys), expected)
        XCTAssertEqual(restored.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(restored.paneId(forPanelId: initialPanelId), restored.paneId(forPanelId: markdownPanel.id))
        XCTAssertEqual(restored.paneId(forPanelId: initialPanelId), restored.paneId(forPanelId: browserPanel.id))
        XCTAssertNotEqual(restored.paneId(forPanelId: initialPanelId), restored.paneId(forPanelId: terminalPanel.id))
        XCTAssertEqual(restored.focusedPanelId, snapshot.focusedPanelId)
    }
}
