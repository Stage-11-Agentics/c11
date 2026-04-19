import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tier 1 Phase 3 coverage for `statusEntries` persistence across app
/// restarts. Verifies the wire-format fields (url, priority, format,
/// staleFromRestart) round-trip, the restore path stamps each entry
/// `staleFromRestart = true`, and the dedupe predicate in
/// `TerminalController.shouldReplaceStatusEntry` clears the stale flag
/// on the first fresh write even if the payload is byte-identical.
@MainActor
final class StatusEntryPersistenceTests: XCTestCase {

    // MARK: - Snapshot wire format (JSON round-trip)

    func testSnapshotRoundTripsAllFields() throws {
        let original = SessionStatusEntrySnapshot(
            key: "claude_code",
            value: "Running",
            icon: "sf:sparkles",
            color: "#FF8800",
            timestamp: 1_700_000_000,
            url: "https://example.com/session/1",
            priority: 42,
            format: "markdown",
            staleFromRestart: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionStatusEntrySnapshot.self, from: data)
        XCTAssertEqual(decoded.key, original.key)
        XCTAssertEqual(decoded.value, original.value)
        XCTAssertEqual(decoded.icon, original.icon)
        XCTAssertEqual(decoded.color, original.color)
        XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 1e-9)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.format, original.format)
        XCTAssertEqual(decoded.staleFromRestart, true)
    }

    func testSnapshotDecodesPrePhase3Payload() throws {
        // Legacy snapshots predate the Phase 3 fields. They must still
        // decode cleanly with the new optionals defaulting to nil.
        let legacy = """
        {
            "key": "agent.progress",
            "value": "85%",
            "icon": null,
            "color": null,
            "timestamp": 1700000000
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionStatusEntrySnapshot.self, from: legacy)
        XCTAssertEqual(decoded.key, "agent.progress")
        XCTAssertEqual(decoded.value, "85%")
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.priority)
        XCTAssertNil(decoded.format)
        XCTAssertNil(decoded.staleFromRestart)
    }

    func testWorkspaceSnapshotOmitsDefaultFields() throws {
        // A plain-format, zero-priority, non-stale, URL-less entry should
        // serialize without the Phase 3 fields so old readers (and
        // diff-minimizing tests) aren't affected by the schema bump.
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Running"
        )
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let statusSnapshots = snapshot.workspaces[0].statusEntries
        XCTAssertEqual(statusSnapshots.count, 1)
        let only = statusSnapshots[0]
        XCTAssertNil(only.url, "plain url should be omitted")
        XCTAssertNil(only.priority, "zero priority should be omitted")
        XCTAssertNil(only.format, "plain format should be omitted")
        XCTAssertNil(only.staleFromRestart, "fresh entry should not serialize stale flag")
    }

    // MARK: - Restore path

    func testRestorePopulatesStatusEntriesWithStaleFlag() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "sf:sparkles",
            color: "#FF8800",
            url: URL(string: "https://example.com/session/1"),
            priority: 7,
            format: .markdown,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        guard let restoredWorkspace = restored.tabs.first else {
            XCTFail("Expected restored workspace")
            return
        }
        let entry = restoredWorkspace.statusEntries["claude_code"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.value, "Running")
        XCTAssertEqual(entry?.icon, "sf:sparkles")
        XCTAssertEqual(entry?.color, "#FF8800")
        XCTAssertEqual(entry?.url?.absoluteString, "https://example.com/session/1")
        XCTAssertEqual(entry?.priority, 7)
        XCTAssertEqual(entry?.format, .markdown)
        XCTAssertEqual(entry?.staleFromRestart, true,
            "Restored entries must carry the staleFromRestart marker.")
    }

    func testRestoreResetsStaleFlagOnNextAutosave() {
        // Once restored with stale=true, the flag must serialize back out
        // on the subsequent save. Without this, a crash before any agent
        // writes would silently drop the stale marker.
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.statusEntries["k"] = SidebarStatusEntry(
            key: "k",
            value: "v"
        )
        let first = manager.sessionSnapshot(includeScrollback: false)
        let restored = TabManager()
        restored.restoreSessionSnapshot(first)
        let second = restored.sessionSnapshot(includeScrollback: false)
        let entry = second.workspaces[0].statusEntries.first { $0.key == "k" }
        XCTAssertEqual(entry?.staleFromRestart, true,
            "Stale flag must persist across subsequent saves until cleared.")
    }

    // MARK: - shouldReplaceStatusEntry dedupe

    func testShouldReplaceReturnsTrueWhenCurrentIsNil() {
        XCTAssertTrue(TerminalController.shouldReplaceStatusEntry(
            current: nil,
            key: "k",
            value: "v",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain
        ))
    }

    func testShouldReplaceReturnsFalseForIdenticalNonStaleEntry() {
        let current = SidebarStatusEntry(
            key: "k",
            value: "v",
            icon: "sf:gear",
            color: "#AAAAAA",
            url: URL(string: "https://example.com/"),
            priority: 3,
            format: .markdown,
            staleFromRestart: false
        )
        XCTAssertFalse(TerminalController.shouldReplaceStatusEntry(
            current: current,
            key: "k",
            value: "v",
            icon: "sf:gear",
            color: "#AAAAAA",
            url: URL(string: "https://example.com/"),
            priority: 3,
            format: .markdown
        ))
    }

    func testShouldReplaceReturnsTrueWhenPayloadDiffers() {
        let current = SidebarStatusEntry(
            key: "k",
            value: "v",
            staleFromRestart: false
        )
        XCTAssertTrue(TerminalController.shouldReplaceStatusEntry(
            current: current,
            key: "k",
            value: "v-updated",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain
        ))
    }

    func testShouldReplaceClearsStaleEvenWithIdenticalPayload() {
        // This is the Phase 3 guard: without the stale override, an agent
        // that re-announces the same status post-restart would never clear
        // the stale flag because the dedupe would skip the rewrite.
        let current = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "sf:sparkles",
            color: "#FF8800",
            url: URL(string: "https://example.com/session/1"),
            priority: 7,
            format: .markdown,
            staleFromRestart: true
        )
        XCTAssertTrue(TerminalController.shouldReplaceStatusEntry(
            current: current,
            key: "claude_code",
            value: "Running",
            icon: "sf:sparkles",
            color: "#FF8800",
            url: URL(string: "https://example.com/session/1"),
            priority: 7,
            format: .markdown
        ), "Stale→live transition must always replace, even with identical payload.")
    }

    // MARK: - SidebarStatusEntry init default

    func testSidebarStatusEntryDefaultsStaleFalse() {
        let entry = SidebarStatusEntry(key: "k", value: "v")
        XCTAssertFalse(entry.staleFromRestart,
            "Fresh entries must default to staleFromRestart = false.")
    }
}
