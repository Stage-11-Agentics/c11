import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-197: display refs, window placement math, window names, and the
/// window fields the session snapshot keeps. Geometry is Atin's real layout:
/// two DELL P2715Qs left of a built-in Retina, in top-left global points.
final class WindowPlacementTests: XCTestCase {
    private let builtin = DisplayGeometry(
        uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", displayID: 1, name: "Built-in Retina Display",
        isMain: true, isBuiltin: true,
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 39, width: 1800, height: 1065), scale: 2, index: 0)
    private let dellTwo = DisplayGeometry(
        uuid: "E5DA5470-FB23-473E-810F-3DC1DA0421C2", displayID: 2, name: "DELL P2715Q (2)",
        isMain: false, isBuiltin: false,
        frame: CGRect(x: -5120, y: -271, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -5120, y: -271, width: 2560, height: 1440), scale: 2, index: 0)
    private let dellOne = DisplayGeometry(
        uuid: "DBDAE43B-1551-4262-90B2-74C254A7C815", displayID: 4, name: "DELL P2715Q (1)",
        isMain: false, isBuiltin: false,
        frame: CGRect(x: -2560, y: -271, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: -271, width: 2560, height: 1440), scale: 2, index: 0)

    private var displays: [DisplayGeometry] { DisplayArrangement.ordered([builtin, dellOne, dellTwo]) }

    // MARK: Coordinates

    func testAppKitAndTopLeftConvertBothWays() {
        // AppKit's frame for DELL P2715Q (2) is (-5120, 0, 2560, 1440); the main display is 1169 tall.
        let appKit = CGRect(x: -5120, y: 0, width: 2560, height: 1440)
        let topLeft = DisplayArrangement.topLeft(fromAppKit: appKit, mainScreenHeight: 1169)
        XCTAssertEqual(topLeft, CGRect(x: -5120, y: -271, width: 2560, height: 1440))
        XCTAssertEqual(DisplayArrangement.appKit(fromTopLeft: topLeft, mainScreenHeight: 1169), appKit)
    }

    func testDisplaysAreNumberedLeftToRight() {
        XCTAssertEqual(displays.map(\.name), ["DELL P2715Q (2)", "DELL P2715Q (1)", "Built-in Retina Display"])
        XCTAssertEqual(displays.map(\.ref), ["display:1", "display:2", "display:3"])
    }

    // MARK: Display refs

    func testDisplayRefsResolveByIndexUUIDNameAndKeyword() throws {
        XCTAssertEqual(try DisplayArrangement.resolve("display:1", in: displays).get().displayID, 2)
        XCTAssertEqual(try DisplayArrangement.resolve("3", in: displays).get().displayID, 1)
        XCTAssertEqual(try DisplayArrangement.resolve("dbdae43b-1551-4262-90b2-74c254a7c815", in: displays).get().displayID, 4)
        XCTAssertEqual(try DisplayArrangement.resolve("dell p2715q (1)", in: displays).get().displayID, 4)
        XCTAssertEqual(try DisplayArrangement.resolve("main", in: displays).get().displayID, 1)
        XCTAssertEqual(try DisplayArrangement.resolve("builtin", in: displays).get().displayID, 1)
    }

    func testSharedModelNameIsAmbiguousAndUnknownIsNotFound() {
        XCTAssertEqual(DisplayArrangement.resolve("DELL P2715Q", in: displays),
                       .failure(.ambiguous("DELL P2715Q", candidates: ["display:1", "display:2"])))
        XCTAssertEqual(DisplayArrangement.resolve("display:9", in: displays), .failure(.notFound("display:9")))
        XCTAssertEqual(DisplayArrangement.resolve("LG UltraFine", in: displays), .failure(.notFound("LG UltraFine")))
    }

    // MARK: Which display, how much of it

    func testWindowBelongsToTheDisplayHoldingMostOfIt() {
        let straddling = CGRect(x: -300, y: 100, width: 1000, height: 600)  // 300 on DELL (1), 700 on built-in
        XCTAssertEqual(DisplayArrangement.display(for: straddling, in: displays)?.displayID, 1)
        let offScreen = CGRect(x: -9000, y: 0, width: 400, height: 400)
        XCTAssertEqual(DisplayArrangement.display(for: offScreen, in: displays)?.displayID, 2)
    }

    func testVisibleFractionAndFrameOnDisplay() {
        let leftHalf = CGRect(x: -5120, y: -271, width: 1280, height: 1440)
        XCTAssertEqual(DisplayArrangement.visibleFraction(of: leftHalf, on: displays[0]), 0.5)
        XCTAssertEqual(DisplayArrangement.frameOnDisplay(leftHalf, display: displays[0]),
                       CGRect(x: 0, y: 0, width: 1280, height: 1440))
    }

    // MARK: Placement

    private let minSize = CGSize(width: 480, height: 320)

    func testFrameIsGlobalAloneAndDisplayRelativeWithADisplay() {
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        let global = WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                              frame: CGRect(x: -5120, y: -271, width: 1280, height: 1440),
                                              preset: nil, minSize: minSize)
        XCTAssertEqual(global, .success(CGRect(x: -5120, y: -271, width: 1280, height: 1440)))
        let relative = WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: displays[1],
                                                frame: CGRect(x: 0, y: 0, width: 1280, height: 1440),
                                                preset: nil, minSize: minSize)
        XCTAssertEqual(relative, .success(CGRect(x: -2560, y: -271, width: 1280, height: 1440)))
    }

    func testPresetsUseTheVisibleFrameOfTheTargetOrCurrentDisplay() {
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                                frame: nil, preset: .fill, minSize: minSize),
                       .success(builtin.visibleFrame))
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: displays[0],
                                                frame: nil, preset: .rightHalf, minSize: minSize),
                       .success(CGRect(x: -3840, y: -271, width: 1280, height: 1440)))
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                                frame: nil, preset: .leftHalf, minSize: minSize),
                       .success(CGRect(x: 0, y: 39, width: 900, height: 1065)))
    }

    func testDisplayAloneKeepsSizeAndOffsetInsideTheNewDisplay() {
        // 100 right of and 61 below the built-in's visible corner.
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: displays[0],
                                                frame: nil, preset: nil, minSize: minSize),
                       .success(CGRect(x: -5020, y: -210, width: 800, height: 600)))
        // Too big for the built-in: shrunk to its visible frame and kept inside it.
        let big = CGRect(x: -5120, y: -271, width: 2560, height: 1440)
        XCTAssertEqual(WindowPlacementPlan.plan(current: big, currentDisplay: displays[0], targetDisplay: displays[2],
                                                frame: nil, preset: nil, minSize: minSize),
                       .success(builtin.visibleFrame))
    }

    func testPlacementRefusals() {
        let current = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                                frame: nil, preset: nil, minSize: minSize), .failure(.nothingToDo))
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                                frame: CGRect(x: 0, y: 0, width: 10, height: 10), preset: .fill,
                                                minSize: minSize), .failure(.conflicting))
        XCTAssertEqual(WindowPlacementPlan.plan(current: current, currentDisplay: displays[2], targetDisplay: nil,
                                                frame: CGRect(x: 0, y: 0, width: 0, height: 10), preset: nil,
                                                minSize: minSize), .failure(.invalidFrame))
    }

    func testSocketFrameParsingRejectsBooleansAndMissingKeys() {
        XCTAssertEqual(TerminalController.windowMoveRect(["x": 1, "y": 2, "width": 300, "height": 400]),
                       CGRect(x: 1, y: 2, width: 300, height: 400))
        XCTAssertNil(TerminalController.windowMoveRect(["x": true, "y": 2, "width": 300, "height": 400]))
        XCTAssertNil(TerminalController.windowMoveRect(["x": 1, "y": 2, "width": 300]))
    }

    // MARK: Names

    func testNamePolicyAcceptsWordsAndRefusesRefsDuplicatesAndBlanks() {
        let other = UUID()
        XCTAssertEqual(try WindowNamePolicy.validate("  c11 Lab ", others: [:]).get(), "c11 Lab")
        for refLike in ["2", "window:2", "Display:1", UUID().uuidString] {
            XCTAssertEqual(WindowNamePolicy.validate(refLike, others: [:]),
                           .failure(.init(.looksLikeRef)), refLike)
        }
        XCTAssertEqual(WindowNamePolicy.validate("   ", others: [:]), .failure(.init(.empty)))
        XCTAssertEqual(WindowNamePolicy.validate(String(repeating: "x", count: 65), others: [:]),
                       .failure(.init(.tooLong)))
        XCTAssertEqual(WindowNamePolicy.validate("C11 LAB", others: [other: "c11 Lab"]),
                       .failure(.init(.inUse(windowId: other))))
    }

    func testNamesAreOneLineAndSelfIsARef() {
        XCTAssertEqual(try WindowNamePolicy.validate("c11\nLab\t  two", others: [:]).get(), "c11 Lab two")
        XCTAssertEqual(WindowNamePolicy.validate("Self", others: [:]), .failure(.init(.looksLikeRef)))
        XCTAssertEqual(WindowNamePolicy.validate("\n\t", others: [:]), .failure(.init(.empty)))
    }

    func testRestoreMovesThePrimaryWindowsOwnEntryFirst() {
        func entry(_ id: UUID?, _ name: String) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil, display: nil,
                workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 200),
                windowId: id?.uuidString, name: name)
        }
        let (a, b, c) = (UUID(), UUID(), UUID())
        let snapshot = AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion, createdAt: 1,
                                          windows: [entry(a, "A"), entry(nil, "legacy"), entry(b, "B")])
        XCTAssertEqual(snapshot.primaryFirst(windowId: b).windows.map(\.name), ["B", "A", "legacy"])
        XCTAssertEqual(snapshot.primaryFirst(windowId: a).windows.map(\.name), ["A", "legacy", "B"])
        XCTAssertEqual(snapshot.primaryFirst(windowId: c).windows.map(\.name), ["A", "legacy", "B"],
                       "no entry of its own: the first entry restores onto it")
    }

    @MainActor
    func testStoreLooksUpNamesIgnoringCaseAndClearsOnBlank() {
        let store = WindowAttributesStore()
        let window = UUID()
        store.setName("c11 Lab", for: window)
        store.setThemeName("nocturne", for: window)
        XCTAssertEqual(store.windowId(named: "C11 lab"), window)
        store.setName("  ", for: window)
        XCTAssertNil(store.name(for: window))
        XCTAssertEqual(store.themeName(for: window), "nocturne")
        store.forget(windowId: window)
        XCTAssertNil(store.themeName(for: window))
    }

    // MARK: Session snapshot

    func testWindowSnapshotKeepsIdNameAndThemeAndOlderSnapshotsStillDecode() throws {
        let id = UUID().uuidString
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 200),
            windowId: id, name: "c11 Lab", theme: "outrun-horizon")
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(SessionWindowSnapshot.self, from: data)
        XCTAssertEqual(decoded.windowId, id)
        XCTAssertEqual(decoded.name, "c11 Lab")
        XCTAssertEqual(decoded.theme, "outrun-horizon")

        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        older.removeValue(forKey: "window_id")
        older.removeValue(forKey: "name")
        older.removeValue(forKey: "theme")
        let legacy = try JSONDecoder().decode(
            SessionWindowSnapshot.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(legacy.windowId)
        XCTAssertNil(legacy.name)
        XCTAssertNil(legacy.theme)
    }

    func testPrimaryWindowIdIsRememberedAcrossLaunches() throws {
        let suite = "c11.tests.primaryWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PrimaryWindowIdentity.launchWindowId(defaults: defaults)
        XCTAssertNotEqual(first, PrimaryWindowIdentity.launchWindowId(defaults: defaults), "nothing saved yet")
        let saved = UUID()
        PrimaryWindowIdentity.remember(saved.uuidString, defaults: defaults)
        XCTAssertEqual(PrimaryWindowIdentity.launchWindowId(defaults: defaults), saved)
        PrimaryWindowIdentity.remember("not a uuid", defaults: defaults)
        XCTAssertEqual(PrimaryWindowIdentity.launchWindowId(defaults: defaults), saved)
    }
}
