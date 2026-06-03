import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `Workspace.applyChromeScale(_:to:)` — the pure helper that
/// translates `ChromeScaleTokens` into `BonsplitConfiguration.Appearance`
/// values. Decoupled from `GhosttyApp.shared` per the v3 plan
/// (Workspace-Apply-ChromeScale section). (C11-6)
@MainActor
final class WorkspaceApplyChromeScaleTests: XCTestCase {

    func testStandardTokensProduceDefaultAppearanceFields() {
        var appearance = BonsplitConfiguration.Appearance()
        Workspace.applyChromeScale(.standard, to: &appearance)

        // Every routed knob equals its scaled-from-default token at 1.00×.
        XCTAssertEqual(appearance.tabBarHeight,             30.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabTitleFontSize,         11.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMinWidth,             112.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMaxWidth,             220.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabIconSize,              15.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabItemHeight,            30.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabHorizontalPadding,      6.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabCloseIconSize,          9.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabContentSpacing,         6.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabDirtyIndicatorSize,     8.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabNotificationBadgeSize,  6.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabActiveIndicatorHeight,  3.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarButtonIconSize,  12.0, accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarButtonFrameSize, 22.0, accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarSeparatorHeight, 18.0, accuracy: 0.001)
    }

    func testLargeTokensScaleEveryRoutedField() {
        var appearance = BonsplitConfiguration.Appearance()
        Workspace.applyChromeScale(ChromeScaleTokens(multiplier: 1.12), to: &appearance)

        XCTAssertEqual(appearance.tabBarHeight,             30.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabTitleFontSize,         11.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMinWidth,             112.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMaxWidth,             220.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabIconSize,              15.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabItemHeight,            30.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabHorizontalPadding,      6.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabCloseIconSize,          9.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabContentSpacing,         6.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabDirtyIndicatorSize,     8.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabNotificationBadgeSize,  6.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabActiveIndicatorHeight,  3.0 * 1.12,  accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarButtonIconSize,  12.0 * 1.12, accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarButtonFrameSize, 22.0 * 1.12, accuracy: 0.001)
        XCTAssertEqual(appearance.splitToolbarSeparatorHeight, 18.0 * 1.12, accuracy: 0.001)
    }

    func testCompactScalesDown() {
        var appearance = BonsplitConfiguration.Appearance()
        Workspace.applyChromeScale(ChromeScaleTokens(multiplier: 0.90), to: &appearance)
        XCTAssertEqual(appearance.tabBarHeight, 30.0 * 0.90, accuracy: 0.001)
        XCTAssertEqual(appearance.tabTitleFontSize, 11.0 * 0.90, accuracy: 0.001)
    }

    func testExtraLargeScalesUp() {
        var appearance = BonsplitConfiguration.Appearance()
        Workspace.applyChromeScale(ChromeScaleTokens(multiplier: 1.25), to: &appearance)
        XCTAssertEqual(appearance.tabBarHeight, 30.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(appearance.tabIconSize, 15.0 * 1.25, accuracy: 0.001)
    }

    func testApplyIsIdempotent() {
        var appearance = BonsplitConfiguration.Appearance()
        Workspace.applyChromeScale(.standard, to: &appearance)
        let snapshot = (
            appearance.tabBarHeight,
            appearance.tabTitleFontSize,
            appearance.tabMinWidth,
            appearance.tabMaxWidth,
            appearance.tabIconSize,
            appearance.tabItemHeight,
            appearance.tabHorizontalPadding,
            appearance.tabCloseIconSize,
            appearance.tabContentSpacing,
            appearance.tabDirtyIndicatorSize,
            appearance.tabNotificationBadgeSize,
            appearance.tabActiveIndicatorHeight
        )
        Workspace.applyChromeScale(.standard, to: &appearance)
        XCTAssertEqual(appearance.tabBarHeight,             snapshot.0,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabTitleFontSize,         snapshot.1,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMinWidth,              snapshot.2,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabMaxWidth,              snapshot.3,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabIconSize,              snapshot.4,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabItemHeight,            snapshot.5,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabHorizontalPadding,     snapshot.6,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabCloseIconSize,         snapshot.7,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabContentSpacing,        snapshot.8,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabDirtyIndicatorSize,    snapshot.9,  accuracy: 0.001)
        XCTAssertEqual(appearance.tabNotificationBadgeSize, snapshot.10, accuracy: 0.001)
        XCTAssertEqual(appearance.tabActiveIndicatorHeight, snapshot.11, accuracy: 0.001)
    }
}
