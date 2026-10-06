import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The Panel layout setting (Strip | Rail) and the per-area rail memory.
final class PanelLayoutSettingsTests: XCTestCase {
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "TabLayoutSettingsTests.\(UUID().uuidString)")!
    }

    func testDefaultIsStrip() {
        let suite = makeSuite()
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
        XCTAssertEqual(PanelLayoutSettings.Mode.strip.rawValue, "strip")
        XCTAssertEqual(PanelLayoutSettings.bonsplitLayout(.strip), .tabs)
    }

    func testRailAndUnknownValues() {
        let suite = makeSuite()
        suite.set("rail", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)
        XCTAssertEqual(PanelLayoutSettings.bonsplitLayout(.rail), .rail)
        suite.set("  RAIL ", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)
        suite.set("sideways", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
    }

    func testTabsStillReadsAsStripFromEitherKey() {
        let suite = makeSuite()
        suite.set("tabs", forKey: PanelLayoutSettings.legacyModeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
        suite.set("tabs", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
        XCTAssertEqual(PanelLayoutSettings.mode(for: " Tabs "), .strip)
    }

    func testOldKeyIsHonoredWhenTheNewKeyIsAbsent() {
        let suite = makeSuite()
        suite.set("rail", forKey: "tabLayoutMode")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)
    }

    func testNewKeyWinsOverTheOldKey() {
        let suite = makeSuite()
        suite.set("rail", forKey: PanelLayoutSettings.legacyModeKey)
        suite.set("strip", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
        suite.set("tabs", forKey: PanelLayoutSettings.legacyModeKey)
        suite.set("rail", forKey: PanelLayoutSettings.modeKey)
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)
    }

    func testSetModeWritesTheNewKeyAndLeavesTheOldOneAlone() {
        let suite = makeSuite()
        suite.set("tabs", forKey: PanelLayoutSettings.legacyModeKey)
        PanelLayoutSettings.setMode(.rail, defaults: suite)
        XCTAssertEqual(suite.string(forKey: "panelLayoutMode"), "rail")
        XCTAssertEqual(suite.string(forKey: "tabLayoutMode"), "tabs")
        PanelLayoutSettings.setMode(.strip, defaults: suite)
        XCTAssertEqual(suite.string(forKey: "panelLayoutMode"), "strip")
        XCTAssertEqual(suite.string(forKey: "tabLayoutMode"), "tabs")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
    }

    func testMigrationCopiesTheOldKeyForwardAndIsIdempotent() {
        let suite = makeSuite()
        suite.set("rail", forKey: PanelLayoutSettings.legacyModeKey)
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.modeKey), "rail")
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.legacyModeKey), "rail", "The old key is never deleted")

        // A later choice in the new key is not overwritten by another pass.
        PanelLayoutSettings.setMode(.strip, defaults: suite)
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.modeKey), "strip")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .strip)
    }

    func testMigrationMapsTabsToStripAndSkipsMissingOrUnreadableValues() {
        let suite = makeSuite()
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertNil(suite.object(forKey: PanelLayoutSettings.modeKey))

        suite.set("sideways", forKey: PanelLayoutSettings.legacyModeKey)
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertNil(suite.object(forKey: PanelLayoutSettings.modeKey))

        suite.set("tabs", forKey: PanelLayoutSettings.legacyModeKey)
        PanelLayoutSettings.migrateLegacyKeys(defaults: suite)
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.modeKey), "strip")
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.legacyModeKey), "tabs")
    }

    func testRuntimeWriteToTheOldKeyCarriesForwardToTheNewKey() {
        let suiteName = "TabLayoutSettingsTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let observer = PanelLayoutObserver(defaults: suite) {}

        // New key unset: an old-key write is copied forward, so Settings and the live layout agree.
        suite.set("rail", forKey: PanelLayoutSettings.legacyModeKey)
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.modeKey), "rail")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)

        // New key set: it keeps winning over later old-key writes.
        suite.set("tabs", forKey: PanelLayoutSettings.legacyModeKey)
        XCTAssertEqual(suite.string(forKey: PanelLayoutSettings.modeKey), "rail")
        XCTAssertEqual(PanelLayoutSettings.mode(defaults: suite), .rail)
        withExtendedLifetime(observer) {}
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
