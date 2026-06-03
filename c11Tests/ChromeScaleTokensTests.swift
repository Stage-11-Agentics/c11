import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `ChromeScaleTokens` — the value-typed bag of computed point
/// sizes that drives sidebar/surface chrome scaling. (C11-6)
final class ChromeScaleTokensTests: XCTestCase {

    // MARK: - Default (1.00×) byte-exactness

    func testStandardEqualsLiteralDefaults() {
        let tokens = ChromeScaleTokens.standard
        XCTAssertEqual(tokens.sidebarWorkspaceTitle,         12.5,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceDetail,        10.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceMetadata,      10.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceAccessory,      9.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceProgressLabel,  9.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceLogIcon,        8.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceBranchDot,      3.0,  accuracy: 0.001)

        XCTAssertEqual(tokens.surfaceTabTitle,                  11.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabIcon,                   15.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabBarHeight,              30.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabItemHeight,             30.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabHorizontalPadding,       6.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabMinWidth,              112.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabMaxWidth,              220.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabCloseIconSize,           9.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabContentSpacing,          6.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabDirtyIndicatorSize,      8.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabNotificationBadgeSize,   6.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabActiveIndicatorHeight,   3.0,  accuracy: 0.001)

        XCTAssertEqual(tokens.splitToolbarButtonIcon,           12.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.splitToolbarButtonFrame,          22.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.splitToolbarSeparatorHeight,      18.0,  accuracy: 0.001)

        XCTAssertEqual(tokens.surfaceTitleBarTitle,             12.0,  accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTitleBarAccessory,         10.0,  accuracy: 0.001)
    }

    // MARK: - Multiplier scaling

    func testLargeMultipliesEveryToken() {
        let tokens = ChromeScaleTokens(multiplier: 1.25)
        XCTAssertEqual(tokens.sidebarWorkspaceTitle,    12.5 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceDetail,   10.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabTitle,          11.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabIcon,           15.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabBarHeight,      30.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabMinWidth,      112.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabMaxWidth,      220.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabCloseIconSize,   9.0 * 1.25, accuracy: 0.001)
    }

    func testCompactScalesDown() {
        let tokens = ChromeScaleTokens(multiplier: 0.85)
        XCTAssertEqual(tokens.surfaceTabBarHeight,      30.0 * 0.85, accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceTitle,    12.5 * 0.85, accuracy: 0.001)
    }

    func testExtraLargeScalesUp() {
        let tokens = ChromeScaleTokens(multiplier: 1.55)
        XCTAssertEqual(tokens.surfaceTabBarHeight,      30.0 * 1.55, accuracy: 0.001)
        XCTAssertEqual(tokens.sidebarWorkspaceTitle,    12.5 * 1.55, accuracy: 0.001)
        XCTAssertEqual(tokens.surfaceTabIcon,           15.0 * 1.55, accuracy: 0.001)
    }

    // MARK: - Active-indicator floor

    func testActiveIndicatorFloorAtTwo() {
        // At the four ship presets the floor is inert (3*0.85 = 2.55 ≥ 2.0).
        // The floor protects Custom-multiplier values ≤ 0.66.
        XCTAssertEqual(ChromeScaleTokens(multiplier: 0.85).surfaceTabActiveIndicatorHeight, 3.0 * 0.85, accuracy: 0.001)
        XCTAssertEqual(ChromeScaleTokens(multiplier: 0.50).surfaceTabActiveIndicatorHeight, 2.0,        accuracy: 0.001)
        XCTAssertEqual(ChromeScaleTokens(multiplier: 0.66).surfaceTabActiveIndicatorHeight, 2.0,        accuracy: 0.001)
    }

    // MARK: - Equatable

    func testStandardEqualsExplicitMultiplierOne() {
        XCTAssertEqual(ChromeScaleTokens.standard, ChromeScaleTokens(multiplier: 1.0))
    }

    func testTokensEqualWhenMultipliersMatch() {
        XCTAssertEqual(ChromeScaleTokens(multiplier: 0.85), ChromeScaleTokens(multiplier: 0.85))
        XCTAssertNotEqual(ChromeScaleTokens(multiplier: 0.85), ChromeScaleTokens(multiplier: 1.0))
    }

    // MARK: - resolved(from:)

    func testResolvedFromUserDefaults() {
        let suite = "ChromeScaleTokensTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ChromeScaleTokens.resolved(from: defaults).multiplier, 1.0, accuracy: 0.001)

        defaults.set("compact", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleTokens.resolved(from: defaults).multiplier, 0.85, accuracy: 0.001)

        defaults.set("extraLarge", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleTokens.resolved(from: defaults).multiplier, 1.55, accuracy: 0.001)

        defaults.set("custom", forKey: ChromeScaleSettings.presetKey)
        defaults.set(1.80, forKey: ChromeScaleSettings.customMultiplierKey)
        XCTAssertEqual(ChromeScaleTokens.resolved(from: defaults).multiplier, 1.80, accuracy: 0.001)
    }
}
