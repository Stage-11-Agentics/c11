import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class TipMemoryStore: TabRailTipStoring {
    var stringsByKey: [String: [String]] = [:]
    var stringByKey: [String: String] = [:]
    var boolByKey: [String: Bool] = [:]

    func strings(forKey key: String) -> [String] { stringsByKey[key] ?? [] }
    func setStrings(_ values: [String], forKey key: String) { stringsByKey[key] = values }
    func string(forKey key: String) -> String? { stringByKey[key] }
    func setString(_ value: String?, forKey key: String) {
        if let value { stringByKey[key] = value } else { stringByKey.removeValue(forKey: key) }
    }
    func bool(forKey key: String) -> Bool { boolByKey[key] ?? false }
    func setBool(_ value: Bool, forKey key: String) { boolByKey[key] = value }
}

/// C11-249: the rail tip's Undo and count-cell paths on a real workspace, with
/// the front area named directly (no window, popover or app state).
@MainActor
final class TabRailTipCenterTests: XCTestCase {
    private struct Rig {
        let manager: WorkspaceManager
        let workspace: Workspace
        let paneId: PaneID
        let center: TabRailTipCenter
        let store: TipMemoryStore
        let defaults: UserDefaults
        let suite: String
    }

    private func makeRig() throws -> Rig {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let suite = "c11.tabRailTip.center.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = TipMemoryStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let center = TabRailTipCenter(policy: TabRailTipPolicy(calendar: calendar, store: store), defaults: defaults)
        center.frontAreaOverride = { [weak workspace] in workspace.map { ($0, paneId) } }
        // Registers the area's slot; the strip is not overflowing.
        center.noteOverflow(workspace: workspace, paneId: paneId, overflowing: false)
        return Rig(manager: manager, workspace: workspace, paneId: paneId, center: center,
                   store: store, defaults: defaults, suite: suite)
    }

    func testUndoRemovesThePreviewedAreasRailBitAndReturnsToTabs() throws {
        let rig = try makeRig()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        var toggles: [Bool] = []
        rig.workspace.bonsplitController.onRailToggled = { _, open in toggles.append(open) }

        rig.center.performTryRail()
        XCTAssertEqual(TabLayoutSettings.mode(defaults: rig.defaults), .rail)
        XCTAssertTrue(rig.workspace.bonsplitController.railOpenPaneIds.contains(rig.paneId))

        rig.center.performUndo()

        XCTAssertEqual(TabLayoutSettings.mode(defaults: rig.defaults), .tabs)
        XCTAssertFalse(rig.workspace.bonsplitController.railOpenPaneIds.contains(rig.paneId),
                       "Undo must not leave the area in the set session autosave persists")
        XCTAssertEqual(toggles, [true, false], "The host is told the rail closed so autosave rewrites it")
        XCTAssertNil(rig.store.stringByKey[TabRailTipPolicy.dismissedKey], "Undo is not a dismissal")
    }

    func testCountCellTapDuringTeachingOpensTheListAndKeepsTheOffer() throws {
        let rig = try makeRig()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let controller = rig.workspace.bonsplitController
        rig.center.beginLiveOfferForTesting()

        let consumed = rig.center.performShowListFromCountCell(workspace: rig.workspace, paneId: rig.paneId)

        XCTAssertTrue(consumed, "The teaching action is consumed so the bar does not also toggle the sheet")
        XCTAssertEqual(controller.tabSheetRequest?.paneId, rig.paneId)
        XCTAssertEqual(controller.tabSheetRequest?.open, true)
        XCTAssertTrue(rig.center.isOfferLiveForTesting, "The offer returns after the list; it is not ended")
        XCTAssertNil(rig.store.stringByKey[TabRailTipPolicy.lastOfferedKey], "No 30-day wait is recorded by the tap")
    }

    func testCountCellTapOutsideTheTeachingOfferIsLeftToTheBar() throws {
        let rig = try makeRig()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let controller = rig.workspace.bonsplitController

        // No offer on screen.
        XCTAssertFalse(rig.center.performShowListFromCountCell(workspace: rig.workspace, paneId: rig.paneId))
        XCTAssertNil(controller.tabSheetRequest)

        // The sheet is already open on that area: the next tap closes it.
        rig.center.beginLiveOfferForTesting()
        rig.center.noteSheet(workspace: rig.workspace, paneId: rig.paneId, open: true)
        XCTAssertFalse(rig.center.performShowListFromCountCell(workspace: rig.workspace, paneId: rig.paneId))
        XCTAssertNil(controller.tabSheetRequest)

        // The Undo tip is up (Rail layout).
        rig.center.noteSheet(workspace: rig.workspace, paneId: rig.paneId, open: false)
        rig.center.performTryRail()
        XCTAssertFalse(rig.center.performShowListFromCountCell(workspace: rig.workspace, paneId: rig.paneId))
        XCTAssertNil(controller.tabSheetRequest)
    }
}
