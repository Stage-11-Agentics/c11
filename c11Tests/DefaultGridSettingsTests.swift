import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `DefaultGridSettings` — the pure grid-construction helpers
/// that power the default 2×2 pane grid applied to every new workspace.
final class DefaultGridSettingsTests: XCTestCase {

    // MARK: - gridSplitOperations()

    func testGridOpsProducesThreeSplits() {
        let ops = DefaultGridSettings.gridSplitOperations()
        XCTAssertEqual(ops.count, 3)
    }

    func testGridOpsFirstSplitBuildsSecondColumn() {
        // Phase 1: one horizontal split to create column 1 beside the initial panel.
        let ops = DefaultGridSettings.gridSplitOperations()
        XCTAssertEqual(ops[0], DefaultGridSettings.SplitOp(column: 1, direction: .horizontalToNewColumn))
    }

    func testGridOpsRemainingSplitsStackEachColumn() {
        // Phase 2: one vertical split per column to fill the bottom row.
        let ops = DefaultGridSettings.gridSplitOperations()
        XCTAssertEqual(ops[1], DefaultGridSettings.SplitOp(column: 0, direction: .verticalDownInColumn))
        XCTAssertEqual(ops[2], DefaultGridSettings.SplitOp(column: 1, direction: .verticalDownInColumn))
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
