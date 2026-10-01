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
        var area = SessionAreaLayoutSnapshot(panelIds: [UUID()], selectedPanelId: nil)
        area.railOpen = true
        let data = try JSONEncoder().encode(area)
        XCTAssertEqual(try JSONDecoder().decode(SessionAreaLayoutSnapshot.self, from: data).railOpen, true)

        // A snapshot written before the rail existed has no key: closed.
        let legacy = try JSONEncoder().encode(SessionAreaLayoutSnapshot(panelIds: [], selectedPanelId: nil))
        XCTAssertNil(try JSONDecoder().decode(SessionAreaLayoutSnapshot.self, from: legacy).railOpen)
    }
}
