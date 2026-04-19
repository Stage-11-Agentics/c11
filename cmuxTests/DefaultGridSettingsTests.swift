import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for `DefaultGridSettings` — the pure classification and
/// grid-construction helpers that power the default monitor-sized pane grid.
final class DefaultGridSettingsTests: XCTestCase {

    // MARK: - classify()

    func testClassify4KProducesThreeByThree() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 3840, height: 2160))
        XCTAssertEqual(cols, 3)
        XCTAssertEqual(rows, 3)
    }

    func testClassifyAboveFourKProducesThreeByThree() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 5120, height: 2880))
        XCTAssertEqual(cols, 3)
        XCTAssertEqual(rows, 3)
    }

    func testClassifyQHDProducesTwoByThree() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(cols, 2)
        XCTAssertEqual(rows, 3)
    }

    func testClassifyBetweenQHDAndFourKProducesTwoByThree() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 3440, height: 1440))
        XCTAssertEqual(cols, 2)
        XCTAssertEqual(rows, 3)
    }

    func testClassifyLaptopProducesTwoByTwo() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(cols, 2)
        XCTAssertEqual(rows, 2)
    }

    func testClassifySmallProducesTwoByTwo() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        XCTAssertEqual(cols, 2)
        XCTAssertEqual(rows, 2)
    }

    func testClassifyZeroRectProducesOneByOneFallback() {
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: .zero)
        XCTAssertEqual(cols, 1)
        XCTAssertEqual(rows, 1)
    }

    func testClassifyFourKWidthButSubQHDHeightFallsToQHDClass() {
        // 3840 wide but only 1600 tall: width alone is insufficient — the
        // height check gates the 4K bucket, so classification lands at QHD.
        let (cols, rows) = DefaultGridSettings.classify(screenFrame: NSRect(x: 0, y: 0, width: 3840, height: 1600))
        XCTAssertEqual(cols, 2)
        XCTAssertEqual(rows, 3)
    }

    // MARK: - gridSplitOperations()

    func testGridOpsOneByOneProducesNoSplits() {
        XCTAssertEqual(DefaultGridSettings.gridSplitOperations(cols: 1, rows: 1), [])
    }

    func testGridOpsTwoByTwoProducesThreeSplits() {
        let ops = DefaultGridSettings.gridSplitOperations(cols: 2, rows: 2)
        XCTAssertEqual(ops.count, 3)
        // Phase 1: one horizontal split to build column 1.
        XCTAssertEqual(ops[0], DefaultGridSettings.SplitOp(column: 1, direction: .horizontalToNewColumn))
        // Phase 2: one vertical split per column.
        XCTAssertEqual(ops[1], DefaultGridSettings.SplitOp(column: 0, direction: .verticalDownInColumn))
        XCTAssertEqual(ops[2], DefaultGridSettings.SplitOp(column: 1, direction: .verticalDownInColumn))
    }

    func testGridOpsTwoByThreeProducesFiveSplits() {
        let ops = DefaultGridSettings.gridSplitOperations(cols: 2, rows: 3)
        XCTAssertEqual(ops.count, 5)
        XCTAssertEqual(ops[0], DefaultGridSettings.SplitOp(column: 1, direction: .horizontalToNewColumn))
        // Column 0 gets two vertical splits, then column 1 gets two.
        XCTAssertEqual(ops[1], DefaultGridSettings.SplitOp(column: 0, direction: .verticalDownInColumn))
        XCTAssertEqual(ops[2], DefaultGridSettings.SplitOp(column: 0, direction: .verticalDownInColumn))
        XCTAssertEqual(ops[3], DefaultGridSettings.SplitOp(column: 1, direction: .verticalDownInColumn))
        XCTAssertEqual(ops[4], DefaultGridSettings.SplitOp(column: 1, direction: .verticalDownInColumn))
    }

    func testGridOpsThreeByThreeProducesEightSplits() {
        let ops = DefaultGridSettings.gridSplitOperations(cols: 3, rows: 3)
        XCTAssertEqual(ops.count, 8)
        // Phase 1: two horizontal splits in column-order to build columns 1 and 2.
        XCTAssertEqual(ops[0].direction, .horizontalToNewColumn)
        XCTAssertEqual(ops[0].column, 1)
        XCTAssertEqual(ops[1].direction, .horizontalToNewColumn)
        XCTAssertEqual(ops[1].column, 2)
        // Phase 2: six vertical splits, two per column.
        let verticalOps = ops.dropFirst(2)
        XCTAssertTrue(verticalOps.allSatisfy { $0.direction == .verticalDownInColumn })
        let columnCounts = Dictionary(grouping: verticalOps, by: { $0.column }).mapValues { $0.count }
        XCTAssertEqual(columnCounts[0], 2)
        XCTAssertEqual(columnCounts[1], 2)
        XCTAssertEqual(columnCounts[2], 2)
    }

    func testGridOpsTotalMatchesColsTimesRowsMinusOne() {
        for cols in 1...4 {
            for rows in 1...4 {
                let ops = DefaultGridSettings.gridSplitOperations(cols: cols, rows: rows)
                XCTAssertEqual(ops.count, cols * rows - 1, "cols=\(cols) rows=\(rows)")
            }
        }
    }

    // MARK: - isEnabled()

    func testIsEnabledDefaultsTrueWhenKeyUnset() {
        let defaults = UserDefaults(suiteName: "DefaultGridSettingsTests.\(UUID().uuidString)")!
        defaults.removeObject(forKey: DefaultGridSettings.enabledKey)
        XCTAssertTrue(DefaultGridSettings.isEnabled(defaults: defaults))
    }

    func testIsEnabledReturnsFalseWhenKeyFalse() {
        let defaults = UserDefaults(suiteName: "DefaultGridSettingsTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: DefaultGridSettings.enabledKey)
        XCTAssertFalse(DefaultGridSettings.isEnabled(defaults: defaults))
    }

    func testIsEnabledReturnsTrueWhenKeyTrue() {
        let defaults = UserDefaults(suiteName: "DefaultGridSettingsTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: DefaultGridSettings.enabledKey)
        XCTAssertTrue(DefaultGridSettings.isEnabled(defaults: defaults))
    }
}
