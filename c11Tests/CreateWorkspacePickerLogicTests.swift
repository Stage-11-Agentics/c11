import XCTest
@testable import c11

/// Pure-logic tests for the New Workspace picker (C11-240): fuzzy ranking, the
/// long-name tile layout on fixed fixtures, the parent-line fit, the pin grid
/// shape and the height budget.
final class CreateWorkspacePickerLogicTests: XCTestCase {
    private let home = "/Users/tester"

    private func entry(_ path: String, age: TimeInterval = 0) -> RecentDirectory {
        RecentDirectory(
            path: path,
            lastOpenedAt: Date(timeIntervalSince1970: 1_000_000 - age),
            openCount: 1,
            pinned: false
        )
    }

    // MARK: Fuzzy

    func testSubsequenceInNameBeatsSubstringElsewhereInPath() {
        let inName = RecentsFuzzy.match(query: "ace", displayPath: "~/Projects/acetate")
        let inPathOnly = RecentsFuzzy.match(query: "ace", displayPath: "~/spaces/other")
        XCTAssertNotNil(inName)
        XCTAssertNotNil(inPathOnly)
        XCTAssertGreaterThan(inName!.score, inPathOnly!.score)
    }

    func testOutsideTheNameOnlyAContiguousSubstringCounts() {
        // "gp" is a subsequence of the whole path but neither in the name nor contiguous.
        XCTAssertNil(RecentsFuzzy.match(query: "gp", displayPath: "~/Gregorovich/projects/zzz"))
        XCTAssertNotNil(RecentsFuzzy.match(query: "regor", displayPath: "~/Gregorovich/projects/zzz"))
    }

    func testPrefixOfTheNameOutranksAMidWordHit() {
        let hits = RecentsFuzzy.rank(
            query: "c11",
            entries: [
                entry("/Users/tester/code/abc11x", age: 1),
                entry("/Users/tester/code/c11", age: 2),
                entry("/Users/tester/code/c11-worktrees", age: 3),
            ],
            home: home
        )
        XCTAssertEqual(hits.first?.entry.path, "/Users/tester/code/c11")
        XCTAssertEqual(hits.count, 3)
    }

    func testWordBoundaryHitsBeatScatteredOnes() {
        let boundary = RecentsFuzzy.match(query: "gt", displayPath: "~/x/greenwood-tech")
        let scattered = RecentsFuzzy.match(query: "gt", displayPath: "~/x/gigantic")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(boundary!.score, scattered!.score)
    }

    func testMatchedIndicesPointAtTheNameInTheDisplayPath() throws {
        let path = "~/Projects/acetate"
        let m = try XCTUnwrap(RecentsFuzzy.match(query: "ace", displayPath: path))
        let chars = Array(path)
        XCTAssertEqual(m.indices.map { chars[$0] }, ["a", "c", "e"])
        XCTAssertTrue(m.indices.allSatisfy { $0 >= path.count - "acetate".count })
    }

    func testEqualScoresBreakTiesByMostRecent() {
        let hits = RecentsFuzzy.rank(
            query: "app",
            entries: [entry("/Users/tester/a/app", age: 100), entry("/Users/tester/b/app", age: 1)],
            home: home
        )
        XCTAssertEqual(hits.map(\.entry.path), ["/Users/tester/b/app", "/Users/tester/a/app"])
    }

    func testEmptyQueryMatchesEverythingAndSpacesAreIgnored() {
        XCTAssertNotNil(RecentsFuzzy.match(query: "", displayPath: "~/x"))
        XCTAssertNotNil(RecentsFuzzy.match(query: "a c e", displayPath: "~/Projects/acetate"))
    }

    func testTheHomeDirectoryIsMatchedAsTilde() {
        // The absolute prefix must not make every row match "tester".
        let hits = RecentsFuzzy.rank(query: "tester", entries: [entry("/Users/tester/code/c11")], home: home)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: Path helpers

    func testDisplayPathParentAndLastComponent() {
        XCTAssertEqual(RecentsPath.displayPath("/Users/tester/code", home: home), "~/code")
        XCTAssertEqual(RecentsPath.displayPath("/Users/tester", home: home), "~")
        XCTAssertEqual(RecentsPath.displayPath("/opt/x", home: home), "/opt/x")
        XCTAssertEqual(RecentsPath.lastComponent("~/code/c11"), "c11")
        XCTAssertEqual(RecentsPath.parent("~/code/c11"), "~/code")
        XCTAssertEqual(RecentsPath.parent("/opt"), "")
        XCTAssertEqual(RecentsPath.parent("~"), "")
    }

    // MARK: Seams

    func testSeamSegments() {
        XCTAssertEqual(PinTileNameLayout.segments(of: "founders-and-fractionals"), ["founders-", "and-", "fractionals"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "ReplaceSessionBoard"), ["Replace", "Session", "Board"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "100percentHuman"), ["100percent", "Human"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "Sekhem_Prime"), ["Sekhem_", "Prime"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "euchre2go"), ["euchre", "2go"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "Supercalifragilisticexpialidocious"),
                       ["Supercalifragilisticexpialidocious"])
        XCTAssertEqual(PinTileNameLayout.segments(of: "v1.2.3"), ["v", "1.", "2.", "3"])
    }

    // MARK: Tile name layout (fixed-width measure so the fixtures are stable)

    /// 7 pt per character at 14 pt, scaled with the font size.
    private let measure: PinTileNameLayout.Measure = { text, size in
        CGFloat(text.count) * size * 0.5
    }
    private let width: CGFloat = 104

    func testShortNameIsOneLineAtFullSize() {
        let l = PinTileNameLayout.layout(name: "c11", width: width, measure: measure)
        XCTAssertEqual(l, PinTileNameLayout(lines: ["c11"], fontSize: 14, ellipsized: false))
    }

    func testLongNameWrapsOnlyAtSeamsInTwoLines() {
        let l = PinTileNameLayout.layout(name: "founders-and-fractionals", width: width, measure: measure)
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines.joined(), "founders-and-fractionals")
        XCTAssertFalse(l.ellipsized)
        XCTAssertEqual(l.lines, ["founders-and-", "fractionals"])
        for line in l.lines { XCTAssertLessThanOrEqual(measure(line, l.fontSize), width) }
    }

    func testCamelCaseNameWrapsAtACaseSeam() {
        let l = PinTileNameLayout.layout(name: "ReplaceSessionBoard", width: width, measure: measure)
        XCTAssertEqual(l.lines.joined(), "ReplaceSessionBoard")
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertFalse(l.ellipsized)
    }

    func testNameThatNeedsASmallerFontDropsTowardEleven() {
        // Longest segment is 16 chars: 16 * 14 * 0.5 = 112 > 104 at 14 pt, and
        // 16 * 11.5 * 0.5 = 92 fits at 11.5 pt.
        let l = PinTileNameLayout.layout(name: "abcdefghijklmnop", width: width, measure: measure)
        XCTAssertFalse(l.ellipsized)
        XCTAssertEqual(l.lines, ["abcdefghijklmnop"])
        XCTAssertLessThan(l.fontSize, 14)
        XCTAssertGreaterThanOrEqual(l.fontSize, 11.5)
        XCTAssertLessThanOrEqual(measure(l.lines[0], l.fontSize), width)
    }

    func testOneUnbreakableSegmentTooWideGoesOnOneLineWithAMiddleEllipsis() {
        let name = "Supercalifragilisticexpialidocious"
        let l = PinTileNameLayout.layout(name: name, width: width, measure: measure)
        XCTAssertTrue(l.ellipsized)
        XCTAssertEqual(l.lines.count, 1)
        XCTAssertEqual(l.fontSize, 11.5)
        XCTAssertTrue(l.lines[0].contains("…"))
        XCTAssertTrue(l.lines[0].hasPrefix("Super"))
        XCTAssertTrue(l.lines[0].hasSuffix("docious"))
        XCTAssertLessThanOrEqual(measure(l.lines[0], 11.5), width)
        // Never a mid-word wrap.
        XCTAssertFalse(l.lines[0].contains("\n"))
    }

    func testDefaultMeasureUsesRealFontMetrics() {
        let l = PinTileNameLayout.layout(name: "c11", width: 104)
        XCTAssertEqual(l.lines, ["c11"])
        let long = PinTileNameLayout.layout(name: "Supercalifragilisticexpialidocious", width: 104)
        XCTAssertTrue(long.ellipsized)
    }

    // MARK: Parent line

    func testParentLineKeepsTwoFoldersWhenTheyFit() {
        let text = PinTileParentLine.fit(parentPath: "~/Projects/Stage11", width: 200, measure: { t, _ in CGFloat(t.count) * 6 })
        XCTAssertEqual(text, "…/Projects/Stage11")
    }

    func testParentLineDropsToOneFolderBeforeTruncating() {
        let measure: PinTileParentLine.Measure = { t, _ in CGFloat(t.count) * 6 }
        // "…/deployments/greenwood-tech" is 28 chars = 168 > 104; "…/greenwood-tech" is 16 = 96.
        let text = PinTileParentLine.fit(parentPath: "~/Projects/Stage11/deployments/greenwood-tech", width: 104, measure: measure)
        XCTAssertEqual(text, "…/greenwood-tech")
    }

    func testParentLineOfAShortParentHasNoEllipsis() {
        let measure: PinTileParentLine.Measure = { t, _ in CGFloat(t.count) * 6 }
        XCTAssertEqual(PinTileParentLine.fit(parentPath: "~/Projects", width: 104, measure: measure), "~/Projects")
        XCTAssertEqual(PinTileParentLine.fit(parentPath: "/opt/homebrew", width: 200, measure: measure), "/opt/homebrew")
        XCTAssertEqual(PinTileParentLine.fit(parentPath: "", width: 104, measure: measure), "")
    }

    // MARK: Pin grid

    func testPinGridFillsRowByRowThenScrollsHorizontally() {
        XCTAssertEqual((0...12).map { PinGridShape.columns(forPinCount: $0) },
                       [0, 1, 2, 3, 4, 5, 5, 5, 5, 5, 5, 6, 6])
        XCTAssertEqual((0...12).map { PinGridShape.rows(forPinCount: $0) },
                       [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2])
        let pins = (1...7).map { "p\($0)" }
        XCTAssertEqual(PinGridShape.rowsOfPins(pins), [["p1", "p2", "p3", "p4", "p5"], ["p6", "p7"]])
        XCTAssertEqual(PinGridShape.rowsOfPins((1...12).map { "p\($0)" }).map(\.count), [6, 6])
    }

    // MARK: Height budget

    func testListRowsAreClampedBetweenFiveAndSixteen() {
        XCTAssertEqual(CreateWorkspaceSheetMetrics.listRows(visibleHeight: 500), 5)
        XCTAssertEqual(CreateWorkspaceSheetMetrics.listRows(visibleHeight: 5000), 16)
        XCTAssertTrue(CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: 500))
        XCTAssertFalse(CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: 5000))
    }

    /// The 14-inch MacBook Pro at its default 1512 x 982: the menu bar leaves
    /// 945 pt, a visible Dock leaves about 875 to 883. The list is sized for
    /// two rows of pins (the most the grid shows), so the whole sheet fits with
    /// any number of pins, now or after pins are added mid-use.
    func testSheetFitsA982PointScreenWithAndWithoutTheDockAtEveryPinCount() {
        for (visible, expectedRows) in [(CGFloat(945), 7), (883, 5), (875, 5)] {
            let rows = CreateWorkspaceSheetMetrics.listRows(visibleHeight: visible)
            XCTAssertEqual(rows, expectedRows, "visibleFrame \(visible)")
            XCTAssertFalse(CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: visible))
            for pinRows in 0...2 {
                XCTAssertLessThanOrEqual(
                    CreateWorkspaceSheetMetrics.windowHeight(rows: rows, pinRows: pinRows),
                    visible,
                    "pin rows \(pinRows) must fit visibleFrame \(visible)"
                )
            }
        }
    }

    func testTheListIsAlwaysSizedForTwoPinRows() {
        XCTAssertEqual(CreateWorkspaceSheetMetrics.budgetPinRows, 2)
        XCTAssertEqual(
            CreateWorkspaceSheetMetrics.listRows(visibleHeight: 945),
            Int(((945 - CreateWorkspaceSheetMetrics.windowChrome - CreateWorkspaceSheetMetrics.screenMargin
                  - CreateWorkspaceSheetMetrics.fixedHeight(pinRows: 2)) / CreateWorkspaceSheetMetrics.rowHeight).rounded(.down))
        )
    }

    func testWindowOriginIsClampedAtTheTopAndTheBottom() {
        // Plenty of room: the wanted top edge is kept.
        XCTAssertEqual(CreateWorkspaceSheetMetrics.originY(desiredTop: 900, height: 500, minY: 0, maxY: 1000), 400)
        // The wanted top is above the screen: pulled down so the window is inside.
        XCTAssertEqual(CreateWorkspaceSheetMetrics.originY(desiredTop: 1200, height: 500, minY: 0, maxY: 1000), 500)
        // The window would sink under the Dock: pulled up to the bottom edge.
        XCTAssertEqual(CreateWorkspaceSheetMetrics.originY(desiredTop: 300, height: 500, minY: 60, maxY: 1000), 60)
        // Taller than the span: sits on the top edge (scrolling mode prevents this in practice).
        XCTAssertEqual(CreateWorkspaceSheetMetrics.originY(desiredTop: 900, height: 1200, minY: 0, maxY: 1000), -200)
    }

    func testSizingRecomputesForAnotherScreen() {
        let sizing = CreateWorkspaceSizing(visibleHeight: 945)
        XCTAssertEqual(sizing.listRows, 7)
        XCTAssertNil(sizing.maxContentHeight)
        sizing.update(visibleHeight: 700)
        XCTAssertEqual(sizing.listRows, 5)
        XCTAssertNotNil(sizing.maxContentHeight)
        sizing.update(visibleHeight: 5000)
        XCTAssertEqual(sizing.listRows, 16)
        XCTAssertNil(sizing.maxContentHeight)
    }

    // MARK: Relative time

    func testRelativeTimeLabels() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func label(_ secondsAgo: TimeInterval) -> String {
            RecentsRelativeTime.label(since: now.addingTimeInterval(-secondsAgo), now: now, justNow: "just now")
        }
        XCTAssertEqual(label(5), "just now")
        XCTAssertEqual(label(5 * 60), "5m ago")
        XCTAssertEqual(label(3 * 3600), "3h ago")
        XCTAssertEqual(label(2 * 86400), "2d ago")
        XCTAssertEqual(label(15 * 86400), "2w ago")
        XCTAssertEqual(label(90 * 86400), "3mo ago")
    }

    // MARK: Path mode (phase 2)

    func testPathQueryDetection() {
        XCTAssertTrue(RecentsPathMode.isPathQuery("~"))
        XCTAssertTrue(RecentsPathMode.isPathQuery("~/Projects"))
        XCTAssertTrue(RecentsPathMode.isPathQuery("/tmp"))
        XCTAssertTrue(RecentsPathMode.isPathQuery("  /tmp"))
        XCTAssertFalse(RecentsPathMode.isPathQuery("ace"))
        XCTAssertFalse(RecentsPathMode.isPathQuery(""))
    }

    func testPathResolutionListsTheParentForAPartialNameAndTheDirectoryForATrailingSlash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            RecentsPathMode.resolve(query: "/tmp/c11-x/Pro"),
            .init(typedPath: "/tmp/c11-x/Pro", listDirectory: "/tmp/c11-x", namePrefix: "Pro")
        )
        XCTAssertEqual(
            RecentsPathMode.resolve(query: "/tmp/c11-x/"),
            .init(typedPath: "/tmp/c11-x", listDirectory: "/tmp/c11-x", namePrefix: "")
        )
        XCTAssertEqual(
            RecentsPathMode.resolve(query: "~/Pro"),
            .init(typedPath: home + "/Pro", listDirectory: home, namePrefix: "Pro")
        )
        XCTAssertEqual(
            RecentsPathMode.resolve(query: "~"),
            .init(typedPath: home, listDirectory: home, namePrefix: "")
        )
        XCTAssertEqual(
            RecentsPathMode.resolve(query: "/Us"),
            .init(typedPath: "/Us", listDirectory: "/", namePrefix: "Us")
        )
    }

    func testPathModeRowsPutTheTypedPathFirstThenMergeChildrenAndRecents() {
        let res = RecentsPathMode.resolve(query: "/w/proj/")
        let recents = [entry("/w/proj/beta"), entry("/w/proj/zeta/deep"), entry("/w/other/x")]
        let rows = RecentsPathMode.rows(
            resolution: res,
            children: ["/w/proj/alpha", "/w/proj/beta"],
            recents: recents
        )
        XCTAssertEqual(rows.map(\.path), ["/w/proj", "/w/proj/alpha", "/w/proj/beta", "/w/proj/zeta/deep"])
        XCTAssertEqual(rows.first?.kind, .typed)
        XCTAssertEqual(rows.map(\.isRecent), [false, false, true, true])
    }

    func testPathModeRowsFilterRecentsByThePartialName() {
        let res = RecentsPathMode.resolve(query: "/w/proj/al")
        let rows = RecentsPathMode.rows(
            resolution: res,
            children: ["/w/proj/alpha"],
            recents: [entry("/w/proj/beta"), entry("/w/proj/alto")]
        )
        XCTAssertEqual(rows.map(\.path), ["/w/proj/al", "/w/proj/alpha", "/w/proj/alto"])
    }

    func testTabCompletionKeepsTildeAndAddsATrailingSlash() {
        let home = "/Users/tester"
        XCTAssertEqual(
            RecentsPathMode.completion(of: "/Users/tester/Projects/site", forQuery: "~/Proj", home: home),
            "~/Projects/site/"
        )
        XCTAssertEqual(
            RecentsPathMode.completion(of: "/opt/homebrew", forQuery: "/op", home: home),
            "/opt/homebrew/"
        )
    }

    func testListChildrenReturnsOnlyMatchingNonHiddenDirectories() throws {
        let root = NSTemporaryDirectory() + "c11-pathmode-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["alpha", "Alps", "beta", ".hidden", "file-not-dir"] where d != "file-not-dir" {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: root + "/file-not-dir", contents: Data())
        defer { try? fm.removeItem(atPath: root) }

        XCTAssertEqual(
            RecentsPathMode.listChildren(of: root, prefix: "").map { ($0 as NSString).lastPathComponent },
            ["alpha", "Alps", "beta"]
        )
        XCTAssertEqual(
            RecentsPathMode.listChildren(of: root, prefix: "al").map { ($0 as NSString).lastPathComponent },
            ["alpha", "Alps"]
        )
        XCTAssertEqual(
            RecentsPathMode.listChildren(of: root, prefix: ".").map { ($0 as NSString).lastPathComponent },
            [".hidden"]
        )
        XCTAssertTrue(RecentsPathMode.listChildren(of: root + "/nope", prefix: "").isEmpty)
    }

    // MARK: Query resolution for the CLI (phase 2)

    func testResolverTreatsPathLikeQueriesAsPaths() {
        let r = { (q: String) in
            RecentsQueryResolver.resolve(query: q, entries: [], home: "/Users/tester", cwd: "/work/here")
        }
        XCTAssertEqual(r("/tmp/x/"), .path("/tmp/x"))
        XCTAssertEqual(r("./sub"), .path("/work/here/sub"))
        XCTAssertEqual(r("../up"), .path("/work/up"))
        XCTAssertEqual(r("~/x"), .path(FileManager.default.homeDirectoryForCurrentUser.path + "/x"))
        XCTAssertEqual(r(""), .none)
    }

    func testResolverPicksTheTopRankedRecentUsingThePickersRanking() {
        let entries = [entry("/Users/tester/code/abc11x"), entry("/Users/tester/code/c11")]
        let outcome = RecentsQueryResolver.resolve(query: "c11", entries: entries, home: "/Users/tester", cwd: "/")
        XCTAssertEqual(outcome, .match("/Users/tester/code/c11"))
    }

    func testAnExactNameBeatsALongerNameThatStartsWithIt() {
        let entries = [entry("/Users/tester/code/c11-worktrees"), entry("/Users/tester/code/c11")]
        XCTAssertEqual(
            RecentsQueryResolver.resolve(query: "c11", entries: entries, home: "/Users/tester", cwd: "/"),
            .match("/Users/tester/code/c11")
        )
    }

    func testResolverFailsLoudlyWhenTheTopTwoTie() {
        let entries = [entry("/Users/tester/a/app", age: 1), entry("/Users/tester/b/app", age: 2), entry("/Users/tester/c/zzz")]
        let outcome = RecentsQueryResolver.resolve(query: "app", entries: entries, home: "/Users/tester", cwd: "/")
        XCTAssertEqual(outcome, .ambiguous(["/Users/tester/a/app", "/Users/tester/b/app"]))
    }

    func testResolverReportsNoMatch() {
        XCTAssertEqual(
            RecentsQueryResolver.resolve(query: "qqq", entries: [entry("/Users/tester/code/c11")], home: "/Users/tester", cwd: "/"),
            .none
        )
    }

    // MARK: Key policy

    func testArrowKeysCarryNumericPadAndFunctionFlagsAndStillCount() {
        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        XCTAssertEqual(PickerShortcutPolicy.effectiveFlags(arrowFlags), [])
        XCTAssertEqual(PickerShortcutPolicy.effectiveFlags([.numericPad, .function, .capsLock, .shift]), .shift)
        XCTAssertEqual(PickerShortcutPolicy.arrowDelta(keyCode: 125, flags: arrowFlags), +1)
        XCTAssertEqual(PickerShortcutPolicy.arrowDelta(keyCode: 126, flags: arrowFlags), -1)
        XCTAssertEqual(PickerShortcutPolicy.arrowDelta(keyCode: 125, flags: [.numericPad, .function, .shift]), +1)
        XCTAssertNil(PickerShortcutPolicy.arrowDelta(keyCode: 125, flags: [.numericPad, .function, .command]))
        XCTAssertNil(PickerShortcutPolicy.arrowDelta(keyCode: 125, flags: [.option]))
        XCTAssertNil(PickerShortcutPolicy.arrowDelta(keyCode: 123, flags: arrowFlags))
    }

    func testPickerOwnsCommandDigitsFAndW() {
        for d in 1...9 {
            XCTAssertEqual(PickerShortcutPolicy.action(flags: .command, chars: "\(d)"), .pin(d))
        }
        XCTAssertEqual(PickerShortcutPolicy.action(flags: .command, chars: "f"), .focusSearch)
        XCTAssertEqual(PickerShortcutPolicy.action(flags: .command, chars: "F"), .focusSearch)
        XCTAssertEqual(PickerShortcutPolicy.action(flags: .command, chars: "w"), .close)
        XCTAssertEqual(PickerShortcutPolicy.action(flags: [.command, .capsLock], chars: "w"), .close)
    }

    func testTheAppHandlerStandsAsideOnlyForThosePickerChords() {
        XCTAssertTrue(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "2"))
        XCTAssertTrue(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "w"))
        XCTAssertTrue(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "f"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "0"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "n"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: .command, chars: "q"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: [.command, .shift], chars: "w"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: [.command, .option], chars: "1"))
        XCTAssertFalse(PickerShortcutPolicy.appShouldStandAside(flags: [], chars: "w"))
    }

    func testTypeToSearchTakesPlainPrintableTextOnly() {
        XCTAssertEqual(PickerShortcutPolicy.typeToSearchText(flags: [], characters: "a"), "a")
        XCTAssertEqual(PickerShortcutPolicy.typeToSearchText(flags: .shift, characters: "A"), "A")
        XCTAssertNil(PickerShortcutPolicy.typeToSearchText(flags: .command, characters: "a"))
        XCTAssertNil(PickerShortcutPolicy.typeToSearchText(flags: .control, characters: "a"))
        XCTAssertNil(PickerShortcutPolicy.typeToSearchText(flags: [], characters: " "))
        XCTAssertNil(PickerShortcutPolicy.typeToSearchText(flags: [], characters: "\r"))
        XCTAssertNil(PickerShortcutPolicy.typeToSearchText(flags: [.numericPad, .function], characters: "\u{F701}"))
    }

    func testAPinDragIsOursOnlyWhenThePasteboardCarriesThatPin() {
        let payload = PinReorderDropDelegate.payload(for: "/p/a")
        XCTAssertTrue(PinReorderDropDelegate.carries(payload, pin: "/p/a"))
        XCTAssertFalse(PinReorderDropDelegate.carries(payload, pin: "/p/b"))
        XCTAssertFalse(PinReorderDropDelegate.carries("/p/a", pin: "/p/a"))
        XCTAssertFalse(PinReorderDropDelegate.carries(nil, pin: "/p/a"))
        XCTAssertFalse(PinReorderDropDelegate.carries(payload, pin: nil))
    }

    // MARK: Slash queries and cwd (CLI)

    func testAQueryWithASlashPrefersASuffixAtAFolderBoundary() {
        let entries = [
            entry("/Users/tester/deployments/greenwood-tech/site-old", age: 1),
            entry("/Users/tester/deployments/greenwood-tech/site", age: 50),
            entry("/Users/tester/other/greenwood-tech/sitemap/x", age: 2),
        ]
        let outcome = RecentsQueryResolver.resolve(query: "greenwood-tech/site", entries: entries, home: "/Users/tester", cwd: "/")
        XCTAssertEqual(outcome, .match("/Users/tester/deployments/greenwood-tech/site"))
    }

    func testSlashQueryScoresStayBelowNameMatches() {
        let viaName = RecentsFuzzy.match(query: "site", displayPath: "~/x/site")
        let viaPath = RecentsFuzzy.match(query: "tech/site", displayPath: "~/greenwood-tech/site")
        XCTAssertNotNil(viaName)
        XCTAssertNotNil(viaPath)
        XCTAssertGreaterThan(viaName!.score, viaPath!.score)
    }

    func testCwdCandidateOnlyForBareQueries() {
        XCTAssertEqual(RecentsQueryResolver.cwdCandidate(query: "sub/dir", cwd: "/work"), "/work/sub/dir")
        XCTAssertEqual(RecentsQueryResolver.cwdCandidate(query: " site ", cwd: "/work/"), "/work/site")
        XCTAssertNil(RecentsQueryResolver.cwdCandidate(query: "~/x", cwd: "/work"))
        XCTAssertNil(RecentsQueryResolver.cwdCandidate(query: "/x", cwd: "/work"))
        XCTAssertNil(RecentsQueryResolver.cwdCandidate(query: "./x", cwd: "/work"))
        XCTAssertNil(RecentsQueryResolver.cwdCandidate(query: "", cwd: "/work"))
        XCTAssertNil(RecentsQueryResolver.cwdCandidate(query: "x", cwd: ""))
    }

    // MARK: Directory probe

    func testAHungPathTimesOutAndItsMountIsNotProbedAgain() {
        var statCalls = [String]()
        let lock = NSLock()
        let probe = DirectoryProbe(width: 2, stat: { path in
            lock.lock(); statCalls.append(path); lock.unlock()
            if path.hasPrefix("/Volumes/hung") { Thread.sleep(forTimeInterval: 3) }
            return true
        })
        let first = expectation(description: "hung path times out")
        probe.check("/Volumes/hung/a", timeout: 0.15) { result in
            XCTAssertEqual(result, .timedOut)
            first.fulfill()
        }
        wait(for: [first], timeout: 2)
        XCTAssertTrue(probe.isUnderHungRoot("/Volumes/hung/b"))

        let second = expectation(description: "sibling on the hung mount is skipped")
        probe.check("/Volumes/hung/b", timeout: 0.15) { result in
            XCTAssertEqual(result, .timedOut)
            second.fulfill()
        }
        let healthy = expectation(description: "other paths still answer")
        probe.check("/tmp/fine", timeout: 1) { result in
            XCTAssertEqual(result, .exists)
            healthy.fulfill()
        }
        wait(for: [second, healthy], timeout: 2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertFalse(statCalls.contains("/Volumes/hung/b"), "no stat is issued under a hung mount")
    }

    func testTheSamePathIsStatedOnceAndPoolWidthIsBounded() {
        var inFlight = 0, peak = 0, calls = 0
        let lock = NSLock()
        let probe = DirectoryProbe(width: 2, stat: { _ in
            lock.lock(); inFlight += 1; peak = max(peak, inFlight); calls += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); inFlight -= 1; lock.unlock()
            return false
        })
        let done = expectation(description: "all answered")
        let paths = (0..<12).map { "/tmp/p\($0)" }
        done.expectedFulfillmentCount = paths.count + 5
        for p in paths {
            probe.check(p, timeout: 5) { XCTAssertEqual($0, .missing); done.fulfill() }
        }
        // Five more askers for a path that is already running or queued.
        for _ in 0..<5 {
            probe.check("/tmp/p0", timeout: 5) { XCTAssertEqual($0, .missing); done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(calls, paths.count, "one stat per distinct path")
    }

    func testHangRootIsTheMountForVolumesAndTheParentOtherwise() {
        XCTAssertEqual(DirectoryProbe.hangRoot(of: "/Volumes/share/a/b"), "/Volumes/share")
        XCTAssertEqual(DirectoryProbe.hangRoot(of: "/net/host/x"), "/net/host")
        XCTAssertEqual(DirectoryProbe.hangRoot(of: "/srv/data/x"), "/srv/data")
    }
}
