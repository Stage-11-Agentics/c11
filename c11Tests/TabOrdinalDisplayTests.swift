import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Coverage for the "Show surface IDs in tab titles" feature: the
/// `TabOrdinalDisplaySettings` resolver, eager `surface:N` ordinal minting,
/// the "N: title" prefix composition, and the ref field on the M7
/// title-bar socket payload.
@MainActor
final class TabOrdinalDisplayTests: XCTestCase {

    // MARK: - Settings resolver

    func testShowsSurfaceIdsDefaultsToFalseWhenUnset() {
        let suite = "TabOrdinalDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(TabOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))
    }

    func testShowsSurfaceIdsRespectsExplicitValues() {
        let suite = "TabOrdinalDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey)
        XCTAssertTrue(TabOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))

        defaults.set(false, forKey: TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey)
        XCTAssertFalse(TabOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))
    }

    // MARK: - Ordinal minting

    func testSurfaceOrdinalMintsSequentiallyAndIsStablePerSurface() {
        let controller = TerminalController.makeForTesting()
        let a = UUID()
        let b = UUID()

        let first = controller.surfaceOrdinal(forSurfaceUUID: a)
        let second = controller.surfaceOrdinal(forSurfaceUUID: b)

        XCTAssertEqual(first, 1, "A fresh controller numbers its first surface 1")
        XCTAssertEqual(second, 2, "Ordinals are minted in creation order")
        XCTAssertEqual(controller.surfaceOrdinal(forSurfaceUUID: a), first,
                       "Re-asking for a surface's ordinal must not re-mint")
        XCTAssertEqual(controller.surfaceRefOnly(forSurfaceUUID: a), "surface:\(first)",
                       "The displayed number is the N of the surface:N handle")
    }

    func testSurfaceOrdinalMatchesRefResolution() {
        let controller = TerminalController.makeForTesting()
        let uuid = UUID()
        let ordinal = controller.surfaceOrdinal(forSurfaceUUID: uuid)

        XCTAssertEqual(controller.v2ResolveHandleRef("surface:\(ordinal)"), uuid,
                       "The spoken number must resolve back to the same surface")
        XCTAssertEqual(controller.v2ResolveHandleRef("tab:\(ordinal)"), uuid,
                       "tab:N stays an alias for surface:N")
    }

    // MARK: - Prefix composition

    func testOrdinalPrefixedComposesOnlyWhenShownAndPresent() {
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: 7, title: "agent", show: true), "7: agent")
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: 7, title: "agent", show: false), "agent")
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: nil, title: "agent", show: true), "agent")
    }

    // MARK: - Workspace wiring

    func testNewWorkspaceTabCarriesItsSurfaceOrdinal() {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)

        let tabIds = workspace.bonsplitController.allTabIds
        XCTAssertFalse(tabIds.isEmpty, "A new workspace has an initial terminal tab")

        for tabId in tabIds {
            guard let panelId = workspace.panelIdFromSurfaceId(tabId) else {
                XCTFail("Tab \(tabId) has no panel mapping")
                continue
            }
            let expected = TerminalController.shared.surfaceOrdinal(forSurfaceUUID: panelId)
            XCTAssertEqual(workspace.bonsplitController.tab(tabId)?.displayOrdinal, expected,
                           "Every tab is numbered with its surface:N ordinal at creation")
        }
    }

    // MARK: - Live-toggle observer

    func testObserverFiresOnKeyChange() {
        let suite = "TabOrdinalDisplayTests.observer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fired = expectation(description: "onChange fired")
        let observer = TabOrdinalDisplayObserver(defaults: defaults) {
            fired.fulfill()
        }

        defaults.set(true, forKey: TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey)
        wait(for: [fired], timeout: 2.0)
        _ = observer
    }
}
