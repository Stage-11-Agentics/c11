import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The Tab layout setting (Tabs | Rail) and the per-area rail memory.
final class TabLayoutSettingsTests: XCTestCase {
    func testDefaultIsTabs() {
        let suite = UserDefaults(suiteName: "TabLayoutSettingsTests.\(UUID().uuidString)")!
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .tabs)
        XCTAssertEqual(TabLayoutSettings.bonsplitLayout(.tabs), .tabs)
    }

    func testRailAndUnknownValues() {
        let suite = UserDefaults(suiteName: "TabLayoutSettingsTests.\(UUID().uuidString)")!
        suite.set("rail", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
        XCTAssertEqual(TabLayoutSettings.bonsplitLayout(.rail), .rail)
        suite.set("  RAIL ", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
        suite.set("sideways", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .tabs)
    }

    func testRailOpenSurvivesTheSnapshotAndOldSnapshotsDecodeClosed() throws {
        var pane = SessionPaneLayoutSnapshot(panelIds: [UUID()], selectedPanelId: nil)
        pane.railOpen = true
        let data = try JSONEncoder().encode(pane)
        XCTAssertEqual(try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: data).railOpen, true)

        // A snapshot written before the rail existed has no key: closed.
        let legacy = try JSONEncoder().encode(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
        XCTAssertNil(try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: legacy).railOpen)
    }
}
