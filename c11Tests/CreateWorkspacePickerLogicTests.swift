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

    func testListRowsAreClampedBetweenEightAndSixteen() {
        XCTAssertEqual(CreateWorkspaceSheetMetrics.listRows(visibleHeight: 500), 8)
        XCTAssertEqual(CreateWorkspaceSheetMetrics.listRows(visibleHeight: 5000), 16)
        let mid = CreateWorkspaceSheetMetrics.listRows(visibleHeight: 1100)
        XCTAssertTrue((8...16).contains(mid))
        XCTAssertTrue(CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: 500))
        XCTAssertFalse(CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: 5000))
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
}
