import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The Panel layout setting (Strip | Rail) and the per-area rail memory.
final class TabLayoutSettingsTests: XCTestCase {
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "TabLayoutSettingsTests.\(UUID().uuidString)")!
    }

    func testDefaultIsStrip() {
        let suite = makeSuite()
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
        XCTAssertEqual(TabLayoutSettings.Mode.strip.rawValue, "strip")
        XCTAssertEqual(TabLayoutSettings.bonsplitLayout(.strip), .tabs)
    }

    func testRailAndUnknownValues() {
        let suite = makeSuite()
        suite.set("rail", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
        XCTAssertEqual(TabLayoutSettings.bonsplitLayout(.rail), .rail)
        suite.set("  RAIL ", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
        suite.set("sideways", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
    }

    func testTabsStillReadsAsStripFromEitherKey() {
        let suite = makeSuite()
        suite.set("tabs", forKey: TabLayoutSettings.legacyModeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
        suite.set("tabs", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
        XCTAssertEqual(TabLayoutSettings.mode(for: " Tabs "), .strip)
    }

    func testOldKeyIsHonoredWhenTheNewKeyIsAbsent() {
        let suite = makeSuite()
        suite.set("rail", forKey: "tabLayoutMode")
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
    }

    func testNewKeyWinsOverTheOldKey() {
        let suite = makeSuite()
        suite.set("rail", forKey: TabLayoutSettings.legacyModeKey)
        suite.set("strip", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
        suite.set("tabs", forKey: TabLayoutSettings.legacyModeKey)
        suite.set("rail", forKey: TabLayoutSettings.modeKey)
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .rail)
    }

    func testSetModeWritesTheNewKeyAndLeavesTheOldOneAlone() {
        let suite = makeSuite()
        suite.set("tabs", forKey: TabLayoutSettings.legacyModeKey)
        TabLayoutSettings.setMode(.rail, defaults: suite)
        XCTAssertEqual(suite.string(forKey: "panelLayoutMode"), "rail")
        XCTAssertEqual(suite.string(forKey: "tabLayoutMode"), "tabs")
        TabLayoutSettings.setMode(.strip, defaults: suite)
        XCTAssertEqual(suite.string(forKey: "panelLayoutMode"), "strip")
        XCTAssertEqual(suite.string(forKey: "tabLayoutMode"), "tabs")
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
    }

    func testMigrationCopiesTheOldKeyForwardAndIsIdempotent() {
        let suite = makeSuite()
        suite.set("rail", forKey: TabLayoutSettings.legacyModeKey)
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: TabLayoutSettings.modeKey), "rail")
        XCTAssertEqual(suite.string(forKey: TabLayoutSettings.legacyModeKey), "rail", "The old key is never deleted")

        // A later choice in the new key is not overwritten by another pass.
        TabLayoutSettings.setMode(.strip, defaults: suite)
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: TabLayoutSettings.modeKey), "strip")
        XCTAssertEqual(TabLayoutSettings.mode(defaults: suite), .strip)
    }

    func testMigrationMapsTabsToStripAndSkipsMissingOrUnreadableValues() {
        let suite = makeSuite()
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertNil(suite.object(forKey: TabLayoutSettings.modeKey))

        suite.set("sideways", forKey: TabLayoutSettings.legacyModeKey)
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertNil(suite.object(forKey: TabLayoutSettings.modeKey))

        suite.set("tabs", forKey: TabLayoutSettings.legacyModeKey)
        TabLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: TabLayoutSettings.modeKey), "strip")
        XCTAssertEqual(suite.string(forKey: TabLayoutSettings.legacyModeKey), "tabs")
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
