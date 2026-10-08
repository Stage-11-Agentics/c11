import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Injected dates exercise seen transitions and navigation without a timer or UI host.
final class FocusHistoryModelTests: XCTestCase {
    private let workspace = UUID()
    private let otherWorkspace = UUID()
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func see(_ model: inout FocusHistoryModel, _ panel: UUID?, at seconds: TimeInterval) {
        model.noteSeen(workspaceId: panel == nil ? nil : workspace, panelId: panel, at: date(seconds))
    }

    private func recorded(_ panels: [UUID]) -> FocusHistoryModel {
        var model = FocusHistoryModel()
        for (offset, panel) in panels.enumerated() {
            see(&model, panel, at: Double(offset * 2))
        }
        see(&model, nil, at: Double(panels.count * 2))
        return model
    }

    private func entry(_ panel: UUID, at seconds: TimeInterval, dwell: TimeInterval = 2) -> FocusHistoryEntry {
        FocusHistoryEntry(workspaceId: workspace, panelId: panel, seenAt: date(seconds), dwell: dwell)
    }

    func testOnlyThresholdQualifiedVisitsAreRecorded() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        see(&model, b, at: 2)
        see(&model, c, at: 2.2)
        see(&model, nil, at: 4.2)

        XCTAssertEqual(model.entries.map(\.panelId), [a, c])
        XCTAssertEqual(model.entries[0].seenAt, date(0))
        XCTAssertEqual(model.entries[0].dwell, 2)
        XCTAssertEqual(model.entries[1].seenAt, date(2.2))
        XCTAssertEqual(model.entries[1].dwell, 2, accuracy: 0.000001)
        XCTAssertEqual(model.index, 1)
    }

    func testThresholdIsInclusiveAndClampedToSafeRange() {
        XCTAssertEqual(FocusHistoryModel(threshold: 0).threshold, 0.2)
        XCTAssertEqual(FocusHistoryModel(threshold: 100).threshold, 30)
        XCTAssertEqual(FocusHistoryModel(threshold: .nan).threshold, 1)
        XCTAssertEqual(FocusHistoryModel(threshold: .infinity).threshold, 1)
        var model = FocusHistoryModel(threshold: 2)
        see(&model, a, at: 0)
        see(&model, b, at: 2)
        see(&model, nil, at: 3.99)
        XCTAssertEqual(model.entries, [entry(a, at: 0)])
    }

    func testDuplicateSeenObservationsDoNotRestartDwell() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        see(&model, a, at: 0.5)
        see(&model, a, at: 0.9)
        see(&model, nil, at: 1)
        XCTAssertEqual(model.entries, [entry(a, at: 0, dwell: 1)])
    }

    func testSamePanelMovedWhileSeenRecordsItsNewWorkspace() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        model.noteSeen(workspaceId: otherWorkspace, panelId: a, at: date(0.5))
        see(&model, nil, at: 2)
        XCTAssertEqual(model.entries.first?.workspaceId, otherWorkspace)
        XCTAssertEqual(model.entries.first?.dwell, 2)
    }

    func testOrdinaryQualifiedRelookUpdatesCurrentRowWithoutDuplicating() {
        var model = recorded([a])
        see(&model, a, at: 3)
        see(&model, nil, at: 6)
        XCTAssertEqual(model.entries, [entry(a, at: 3, dwell: 3)])
        XCTAssertEqual(model.index, 0)
    }

    func testSuppressedRelooksPreserveCurrentRowAndForwardBranch() {
        var model = recorded([a, b, c])
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
        // First visit is the traversal landing; its original row stays intact.
        see(&model, b, at: 6)
        see(&model, nil, at: 8)
        let original = model.snapshot()
        XCTAssertEqual(model.entries[1], entry(b, at: 2))
        // Suppression remains until a different qualified visit branches history.
        see(&model, b, at: 9)
        see(&model, nil, at: 12)
        XCTAssertEqual(model.snapshot(), original)
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, c)
    }

    func testRepeatedNavigationLandingsKeepOriginalEntriesAndForwardBranch() {
        var model = recorded([a, b, c])
        let original = model.entries
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
        see(&model, b, at: 6)
        model.prepareForNavigation(at: date(9))
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, a)
        see(&model, a, at: 9)
        model.prepareForNavigation(at: date(12))
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, b)
        see(&model, b, at: 12)
        model.prepareForNavigation(at: date(15))
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, c)
        XCTAssertEqual(model.entries, original)
        XCTAssertEqual(model.index, 2)
    }

    func testQualifiedNewVisitAfterBackReplacesForwardBranch() {
        var model = recorded([a, b, c])
        let original = model.entries
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
        see(&model, b, at: 6)
        model.prepareForNavigation(at: date(8))
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, c)
        see(&model, c, at: 8)
        model.prepareForNavigation(at: date(10))
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
        XCTAssertEqual(model.entries, original)
        see(&model, b, at: 10)
        see(&model, d, at: 12)
        see(&model, nil, at: 14)
        XCTAssertEqual(model.entries.map(\.panelId), [a, b, d])
        XCTAssertEqual(model.index, 2)
        XCTAssertNil(model.forward(isLive: { _ in true }))
    }

    func testBoundaryNoOpThenQualifiedNewVisitReplacesForwardBranch() {
        var model = recorded([a, b, c])
        _ = model.back(isLive: { _ in true })
        _ = model.back(isLive: { _ in true })
        see(&model, a, at: 6)
        model.prepareForNavigation(at: date(8))
        XCTAssertNil(model.back(isLive: { _ in true }))
        XCTAssertEqual(model.index, 0)
        see(&model, d, at: 10)
        see(&model, nil, at: 12)
        XCTAssertEqual(model.entries.map(\.panelId), [a, d])
        XCTAssertEqual(model.index, 1)
    }

    func testNavigationFinalizesSourceAndDoesNotCountItTwice() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        see(&model, b, at: 2)
        model.prepareForNavigation(at: date(4))
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, a)
        see(&model, a, at: 4)
        see(&model, nil, at: 6)
        XCTAssertEqual(model.entries, [entry(a, at: 0), entry(b, at: 2)])
    }

    func testBoundaryNavigationRestartsOpenVisitAtBoundaryTime() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        model.prepareForNavigation(at: date(2))
        XCTAssertNil(model.back(isLive: { _ in true }))
        see(&model, b, at: 5)
        XCTAssertEqual(model.entries, [entry(a, at: 2, dwell: 3)])
    }

    func testNilSeenGapDoesNotBecomeDwell() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        see(&model, nil, at: 0.5)
        see(&model, a, at: 100)
        see(&model, nil, at: 100.75)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.index)
        see(&model, b, at: 101)
        see(&model, nil, at: 103)
        XCTAssertEqual(model.entries, [entry(b, at: 101)])
    }

    func testMissingWorkspaceOrPanelCannotOpenAVisit() {
        var model = FocusHistoryModel()
        model.noteSeen(workspaceId: nil, panelId: a, at: date(0))
        model.noteSeen(workspaceId: workspace, panelId: nil, at: date(2))
        see(&model, nil, at: 4)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testMissingWorkspaceWithSamePanelEndsVisitAndStartsNoUnnamedVisit() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        model.noteSeen(workspaceId: nil, panelId: a, at: date(0.4))
        see(&model, a, at: 100)
        see(&model, nil, at: 100.4)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.index)
    }

    func testLockAfterQualifiedVisitRecordsOnlyPreLockDwell() {
        var model = FocusHistoryModel()
        see(&model, a, at: 0)
        see(&model, nil, at: 2)
        see(&model, nil, at: 100)
        XCTAssertEqual(model.entries, [entry(a, at: 0)])
    }

    func testHistoryEvictsOldestRowsAtCap() {
        let panels = (0..<(FocusHistoryModel.cap + 5)).map { _ in UUID() }
        let model = recorded(panels)
        XCTAssertEqual(model.entries.count, FocusHistoryModel.cap)
        XCTAssertEqual(model.entries.map(\.panelId), Array(panels.suffix(FocusHistoryModel.cap)))
        XCTAssertEqual(model.index, FocusHistoryModel.cap - 1)
    }

    func testPruneClosedOpenVisitPreventsItFromBeingCommitted() {
        var model = recorded([a])
        see(&model, b, at: 2)
        model.prune(panelId: b)
        see(&model, nil, at: 10)
        XCTAssertEqual(model.entries.map(\.panelId), [a])
        XCTAssertEqual(model.index, 0)
    }

    func testPruneEarlierRowKeepsCursorOnSameSurvivingTarget() {
        var model = recorded([a, b, c])
        model.prune(panelId: a)
        XCTAssertEqual(model.entries.map(\.panelId), [b, c])
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
    }

    func testPruneCurrentRowSelectsPriorSurvivorThenHandlesEmptyHistory() {
        var model = recorded([a, b, c])
        _ = model.back(isLive: { _ in true })
        model.prune(panelId: b)
        XCTAssertEqual(model.entries.map(\.panelId), [a, c])
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, c)
        model.prune(panelId: c)
        model.prune(panelId: a)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.index)
        XCTAssertNil(model.back(isLive: { _ in true }))
        XCTAssertNil(model.forward(isLive: { _ in true }))
    }

    func testPruneFirstCurrentRowClampsCursorToFirstSurvivor() {
        var model = recorded([a, b, c])
        _ = model.back(isLive: { _ in true })
        _ = model.back(isLive: { _ in true })
        model.prune(panelId: a)
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.entries[0].panelId, b)
    }

    func testReconcileRepairsMovedUUIDAndRemovesClosedRowsKeepingCursor() {
        var model = recorded([a, b, c])
        model.reconcile { item in
            if item.panelId == a { return nil }
            return item.panelId == c ? otherWorkspace : workspace
        }
        XCTAssertEqual(model.entries.map(\.panelId), [b, c])
        XCTAssertEqual(model.entries[1].workspaceId, otherWorkspace)
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.back(isLive: { _ in true })?.panelId, b)
        XCTAssertEqual(model.forward(isLive: { _ in true })?.workspaceId, otherWorkspace)
    }

    func testNavigationSkipsClosedTargets() {
        var model = recorded([a, b, c])
        XCTAssertEqual(model.back(isLive: { $0 != self.b })?.panelId, a)
        XCTAssertEqual(model.entries.map(\.panelId), [a, c])
        XCTAssertEqual(model.forward(isLive: { _ in true })?.panelId, c)
    }

    func testSnapshotCodableRoundTripRestoresCursorAndIgnoresOldOpenVisit() throws {
        var source = recorded([a, b, c])
        _ = source.back(isLive: { _ in true })
        let encoded = try JSONEncoder().encode(source.snapshot())
        let decoded = try JSONDecoder().decode(FocusHistorySnapshot.self, from: encoded)
        var restored = FocusHistoryModel()
        see(&restored, d, at: 0)
        restored.restore(decoded)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        see(&restored, nil, at: 100)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        XCTAssertEqual(restored.forward(isLive: { _ in true })?.panelId, c)
    }

    func testRestoreClampsInvalidCursorAndDefaultsMissingCursorToNewest() {
        let rows = [entry(a, at: 0), entry(b, at: 2)]
        var model = FocusHistoryModel()
        model.restore(FocusHistorySnapshot(entries: rows, index: -50))
        XCTAssertEqual(model.index, 0)
        model.restore(FocusHistorySnapshot(entries: rows, index: 50))
        XCTAssertEqual(model.index, 1)
        model.restore(FocusHistorySnapshot(entries: rows, index: nil))
        XCTAssertEqual(model.index, 1)
        model.restore(FocusHistorySnapshot(entries: [], index: 10))
        XCTAssertNil(model.index)
    }

    func testRestoreDropsInvalidRowsAndMapsCursorToPriorSurvivor() {
        let rows = [entry(a, at: 0), entry(b, at: 2, dwell: -0.5),
                    entry(d, at: 4, dwell: .nan), entry(d, at: .infinity),
                    entry(d, at: 4, dwell: .infinity), entry(c, at: 6)]
        var model = FocusHistoryModel()
        model.restore(FocusHistorySnapshot(entries: rows, index: 2))
        XCTAssertEqual(model.entries.map(\.panelId), [a, c])
        XCTAssertEqual(model.index, 0)
    }

    func testChangingThresholdDoesNotRequalifySavedVisits() {
        let saved = recorded([a, b]).snapshot()
        var model = FocusHistoryModel(threshold: 3)
        model.restore(saved)
        XCTAssertEqual(model.snapshot(), saved)
    }

    func testAppSnapshotAcceptsAbsentHistoryAndRoundTripsUUIDs() throws {
        let legacy = Data("{\"version\":1,\"createdAt\":0,\"windows\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AppSessionSnapshot.self, from: legacy).focusHistory)
        let history = recorded([a, b]).snapshot()
        let app = AppSessionSnapshot(version: 1, createdAt: 0, windows: [], focusHistory: history)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded.focusHistory, history)
    }

    @MainActor
    func testResumeSelectionPreservesHistoryForUUIDPruningAfterRestore() throws {
        let workspaceSnapshot = SessionWorkspaceSnapshot(
            id: workspace, processTitle: "Example", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: "/tmp",
            focusedPanelId: a,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [a], selectedPanelId: a)),
            panels: [], statusEntries: [], logEntries: [], progress: nil,
            gitBranch: nil, metadata: nil)
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspaceSnapshot]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240))
        let history = recorded([a, b]).snapshot()
        let app = AppSessionSnapshot(version: 1, createdAt: 0, windows: [window], focusHistory: history)
        let filtered = try XCTUnwrap(LaunchResumePicker.filtered(snapshot: app, keep: [workspace]))
        XCTAssertEqual(filtered.focusHistory, history)
    }

    func testRestoreOversizedSnapshotRetainsNewestRowsAndAdjustsCursor() {
        let panels = (0..<(FocusHistoryModel.cap + 10)).map { _ in UUID() }
        let rows = panels.enumerated().map { entry($0.element, at: Double($0.offset * 2)) }
        var model = FocusHistoryModel()
        model.restore(FocusHistorySnapshot(entries: rows, index: 15))
        XCTAssertEqual(model.entries.map(\.panelId), Array(panels.suffix(FocusHistoryModel.cap)))
        XCTAssertEqual(model.index, 5)
        model.restore(FocusHistorySnapshot(entries: rows, index: 2))
        XCTAssertEqual(model.index, 0)
    }

    func testLimitParserAcceptsOnlyBoundedIntegersAndDefaultsOmission() throws {
        XCTAssertEqual(FocusHistoryLimit.parse(nil), 50)
        let values = try JSONSerialization.jsonObject(with: Data("[1,50,200]".utf8)) as! [Any]
        XCTAssertEqual(values.map { FocusHistoryLimit.parse($0) }, [1, 50, 200])
        XCTAssertNil(FocusHistoryLimit.parse(NSNumber(value: UInt64.max)))
        XCTAssertNil(FocusHistoryLimit.parse(NSNumber(value: Int64.max)))
    }

    func testLimitParserRejectsExplicitNullBooleansFloatsStringsAndOutOfRange() throws {
        let values = try JSONSerialization.jsonObject(
            with: Data("[null,true,false,1.0,1.5,0,-1,201,\"50\",{},[]]".utf8)
        ) as! [Any]
        for value in values {
            XCTAssertNil(FocusHistoryLimit.parse(value), "Unexpected accepted limit: \(value)")
        }
    }
}
