import AppKit
import Bonsplit
import SwiftUI
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// A SwiftUI colour as `#RRGGBB` (sRGB, rounded).
private func hex(_ color: Color) -> String? {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
}

/// Schema 2 on the panel strip, titlebar and state colours (C11H-144, -145,
/// -147, -148). Unset values must leave every surface exactly as today.
final class ThemeStripStyleTests: XCTestCase {
    private let darkBackground = NSColor(hex: "#101114")!
    private let lightBackground = NSColor(hex: "#F5F3EF")!

    // MARK: States

    func testUnsetStatesKeepTodaysActivityRamp() {
        for background in [darkBackground, lightBackground] {
            let today = Workspace.resolvedSurfaceTabActivityColors(from: background)
            let unset = Workspace.resolvedSurfaceTabActivityColors(from: background, states: .unset)
            XCTAssertEqual(unset.runningHex, today.runningHex)
            XCTAssertEqual(unset.idleHex, today.idleHex)
            XCTAssertEqual(unset.coldHex, today.coldHex)
            XCTAssertEqual(unset.waitingHex, today.waitingHex)
            XCTAssertEqual(unset.waitingInkHex, today.waitingInkHex)
        }
        XCTAssertEqual(Workspace.resolvedSurfaceTabActivityColors(from: darkBackground).waitingHex, "#E8E8E8")
    }

    func testThemeStatesReplaceTheRampColourByColour() {
        var states = ThemeStatePalette.unset
        states.waiting = "#FF4F1F"
        states.running = "#FFFFFFEB"
        let colors = Workspace.resolvedSurfaceTabActivityColors(from: darkBackground, states: states)
        XCTAssertEqual(colors.waitingHex, "#FF4F1F")
        XCTAssertEqual(colors.runningHex, "#FFFFFFEB")
        // Unset states keep c11's; the dormant gray is never a theme's `cold`.
        XCTAssertEqual(colors.idleHex, "#9AA0A9")
        XCTAssertEqual(colors.waitingInkHex, "#08090B")
        states.cold = "#2B3A56"
        XCTAssertEqual(Workspace.resolvedSurfaceTabActivityColors(from: darkBackground, states: states).coldHex, "#62676F")
    }

    // MARK: Waiting pill and unread badge (C11H-344)

    func testDefaultWaitingPillLightsWhiteNotBrandGoldInBothSlots() {
        let dark = SidebarWaitingPillColors.resolve(states: .unset, lightSlot: false, themedPill: false)
        XCTAssertEqual(dark.fillHex, "#E8E8E8")
        XCTAssertEqual(dark.inkHex, "#08090B")
        XCTAssertEqual(dark.edgeHex, "#E8E8E8")

        // c11's pill is void in the Light slot too: still white, with a
        // near-black edge so it keeps its outline on a light sidebar.
        let light = SidebarWaitingPillColors.resolve(states: .unset, lightSlot: true, themedPill: false)
        XCTAssertEqual(light.fillHex, "#E8E8E8")
        XCTAssertEqual(light.inkHex, "#08090B")
        XCTAssertEqual(light.edgeHex, "#1D2024")

        for colors in [dark, light] {
            XCTAssertNotEqual(colors.fillHex.lowercased(), BrandColors.goldHex.lowercased())
            XCTAssertNotEqual(colors.edgeHex.lowercased(), BrandColors.goldHex.lowercased())
        }
    }

    func testThemedWaitingPillFallsBackToTheSlotsWaitingColour() {
        let light = SidebarWaitingPillColors.resolve(states: .unset, lightSlot: true, themedPill: true)
        XCTAssertEqual(light.fillHex, "#1D2024")
        XCTAssertEqual(light.inkHex, "#FFFDF8")
        XCTAssertEqual(light.edgeHex, "#1D2024")
    }

    func testThemeStatesWaitingWinsOnTheWaitingPill() {
        var states = ThemeStatePalette.unset
        states.waiting = "#FF4F1F"
        states.waitingInk = "#111214"
        for lightSlot in [false, true] {
            for themedPill in [false, true] {
                let colors = SidebarWaitingPillColors.resolve(states: states, lightSlot: lightSlot, themedPill: themedPill)
                XCTAssertEqual(colors.fillHex, "#FF4F1F")
                XCTAssertEqual(colors.inkHex, "#111214")
                XCTAssertEqual(colors.edgeHex, "#FF4F1F")
            }
        }
    }

    func testUnreadBadgeTakesTheWaitingColourUnlessTheThemeSetsNotification() {
        let dark = TitlebarControlTheme.unset.badgeColors(lightSlot: false)
        XCTAssertEqual(hex(dark.fill), "#E8E8E8")
        XCTAssertEqual(hex(dark.ink), "#08090B")
        let light = TitlebarControlTheme.unset.badgeColors(lightSlot: true)
        XCTAssertEqual(hex(light.fill), "#1D2024")
        XCTAssertEqual(hex(light.ink), "#FFFDF8")

        var themed = TitlebarControlTheme.unset
        themed.badge = NSColor(hex: "#E0B35A")
        XCTAssertEqual(hex(themed.badgeColors(lightSlot: false).fill), "#E0B35A")
    }

    /// The surfaces C11H-344 moved onto the palette keep a theme's `[states]`:
    /// datasheet-mono's orange waiting and ink-white working stay put.
    func testMovedSurfacesTakeTheThemesStates() {
        var states = ThemeStatePalette.unset
        states.waiting = "#FF4F1F"
        states.running = "#FFFFFF"

        for scheme in [ColorScheme.dark, .light] {
            XCTAssertEqual(hex(WorkspaceGroupHeaderView.waitingTint(colorScheme: scheme, states: states)), "#FF4F1F")
        }
        XCTAssertEqual(hex(WorkspaceGroupHeaderView.waitingTint(colorScheme: .dark, states: .unset)), "#E8E8E8")

        var theme = TitlebarControlTheme.unset
        theme.waiting = NSColor(hex: "#FF4F1F")
        theme.waitingInk = NSColor(hex: "#111214")
        let badge = theme.badgeColors(lightSlot: false)
        XCTAssertEqual(hex(badge.fill), "#FF4F1F")
        XCTAssertEqual(hex(badge.ink), "#111214")

        let tip = TipPalette.resolve(.dark, states: states)
        XCTAssertEqual(hex(tip.waiting), "#FF4F1F")
        XCTAssertEqual(hex(tip.working), "#FFFFFF")
        XCTAssertEqual(hex(TipPalette.resolve(.dark).working), "#D0AA45")
        XCTAssertEqual(hex(TipPalette.resolve(.light).waiting), "#1D2024")

        XCTAssertEqual(hex(WorkspaceCloseInventoryView.statusColor(.waiting, states: states)), "#FF4F1F")
        XCTAssertEqual(hex(WorkspaceCloseInventoryView.statusColor(.working, states: states)), "#FFFFFF")
        XCTAssertEqual(hex(WorkspaceCloseInventoryView.statusColor(.working)), "#D0AA45")
        XCTAssertEqual(hex(WorkspaceCloseInventoryView.statusColor(.waiting)), "#E8E8E8")
    }

    /// The badge reads light or dark from an opaque theme fill, else from the
    /// titlebar behind a clear one, never from the forced-dark colour scheme.
    func testBadgeLightnessFollowsAnOpaqueFillElseTheTitlebar() {
        XCTAssertTrue(TitlebarControlTheme.badgeSitsOnLight(fill: nil, titlebarIsLight: true))
        XCTAssertFalse(TitlebarControlTheme.badgeSitsOnLight(fill: nil, titlebarIsLight: false))
        XCTAssertTrue(TitlebarControlTheme.badgeSitsOnLight(fill: NSColor(white: 0, alpha: 0), titlebarIsLight: true))
        XCTAssertFalse(TitlebarControlTheme.badgeSitsOnLight(fill: NSColor(hex: "#202020"), titlebarIsLight: true))
        XCTAssertTrue(TitlebarControlTheme.badgeSitsOnLight(fill: NSColor(hex: "#F0F0F0"), titlebarIsLight: false))
    }

    func testThemeStatesRecolorFlagUsageLimitAndCacheCold() {
        var states = ThemeStatePalette.unset
        states.flag = "#B08CFF"
        states.usageLimit = "#FF0000"
        states.cold = "#2B3A56"

        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: true, lightBackground: false, states: states), "#B08CFF")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: false, promptCacheExpired: false, lightBackground: false, usageLimited: true, states: states), "#FF0000")
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: false, promptCacheExpired: true, lightBackground: false, states: states), "#2B3A56")
        XCTAssertNil(Workspace.activityColorOverrideHex(
            isFlagged: false, promptCacheExpired: false, lightBackground: false, states: states))

        // Unset states are today's colours.
        XCTAssertEqual(Workspace.activityColorOverrideHex(
            isFlagged: true, promptCacheExpired: false, lightBackground: true, states: .unset), "#9D8AD9")
        XCTAssertEqual(Workspace.promptCacheColdHex(lightBackground: true, states: .unset),
                       Workspace.promptCacheColdHex(lightBackground: true))
    }

    // MARK: Strip

    func testEveryTabSelectionChoiceMapsAndUnsetIsTodaysIndicator() {
        for choice in ThemeStyleRoleRegistry.tabSelectionChoices {
            XCTAssertEqual(ThemeStripStyle.selection(from: choice).rawValue, choice)
        }
        XCTAssertEqual(ThemeStripStyle.selection(from: nil), .indicator)
        XCTAssertEqual(ThemeStripStyle.selection(from: "sideways"), .indicator)
    }

    func testEveryWeightChoiceMapsToABonsplitWeight() {
        for choice in ThemeStyleRoleRegistry.weightChoices {
            XCTAssertNotNil(BonsplitFontWeight(rawValue: choice), choice)
        }
    }

    func testTabTextStyleMapsTheThemeStyle() {
        XCTAssertEqual(ThemeStripStyle.tabTextStyle(from: .unset, isAvailable: { _ in true }), .unset)

        var style = ThemeTextStyle.unset
        style.familyName = "JetBrains Mono"
        style.scale = 0.84
        style.weight = "medium"
        style.uppercase = true
        style.tracking = 0.05
        let installed = ThemeStripStyle.tabTextStyle(from: style, isAvailable: { _ in true })
        XCTAssertEqual(installed.familyName, "JetBrains Mono")
        XCTAssertEqual(Double(installed.scale ?? 0), 0.84, accuracy: 0.0001)
        XCTAssertEqual(installed.weight, .medium)
        XCTAssertTrue(installed.uppercase)
        XCTAssertEqual(Double(installed.trackingEm ?? 0), 0.05, accuracy: 0.0001)

        // A missing mono family falls back to SF Mono, any other to the system font.
        XCTAssertEqual(ThemeStripStyle.tabTextStyle(from: style, isAvailable: { _ in false }).familyName, "system-mono")
        style.familyName = "Iowan Old Style"
        XCTAssertNil(ThemeStripStyle.tabTextStyle(from: style, isAvailable: { _ in false }).familyName)
    }

    func testUnsetStripLeavesADefaultAppearanceUntouched() {
        var appearance = BonsplitConfiguration.Appearance()
        XCTAssertEqual(ThemeStripStyle(appearance: appearance), .unset)
        ThemeStripStyle.unset.apply(to: &appearance)
        XCTAssertEqual(ThemeStripStyle(appearance: appearance), .unset)
        XCTAssertNil(appearance.chromeColors.activeFillHex)
        XCTAssertNil(appearance.chromeScanlinesOpacity)
        XCTAssertEqual(appearance.tabSelectionStyle, .indicator)
        XCTAssertTrue(appearance.tabTextStyle.isUnset)
    }

    func testStripStyleRoundTripsThroughTheAppearance() {
        var strip = ThemeStripStyle.unset
        strip.textColors = .init(textHex: "#C8C8C4", textSecondaryHex: "#77787A", activeTextHex: "#111214", numberHex: nil)
        strip.textStyle = .init(familyName: "system-mono", scale: 0.84, weight: nil, uppercase: true, trackingEm: 0.05)
        strip.selection = .invert
        strip.activeFillHex = "#FFFFFF"
        strip.hoverBrackets = true
        strip.scanlinesOpacity = 0.14

        var appearance = BonsplitConfiguration.Appearance()
        strip.apply(to: &appearance)
        XCTAssertEqual(ThemeStripStyle(appearance: appearance), strip)
        // The strip never changes the bar's geometry.
        let defaults = BonsplitConfiguration.Appearance()
        XCTAssertEqual(appearance.tabBarHeight, defaults.tabBarHeight)
        XCTAssertEqual(appearance.tabItemHeight, defaults.tabItemHeight)
        XCTAssertEqual(appearance.tabMinWidth, defaults.tabMinWidth)
        XCTAssertEqual(appearance.tabMaxWidth, defaults.tabMaxWidth)
    }

    // MARK: Ornaments and titlebar

    func testScanlinesOpacityIsOffUnlessPositive() {
        XCTAssertNil(ThemeOrnaments.scanlinesOpacity(nil as Double?))
        XCTAssertNil(ThemeOrnaments.scanlinesOpacity(0))
        XCTAssertNil(ThemeOrnaments.scanlinesOpacity(-0.5))
        XCTAssertEqual(ThemeOrnaments.scanlinesOpacity(0.14), 0.14)
        XCTAssertEqual(ThemeOrnaments.scanlinesOpacity(3), 1)
    }

    func testTitlebarClockShowsTwentyFourHourTimeAndZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-11-03 02:58:30 UTC is 18:58:30 PST on 2026-11-02.
        let date = Date(timeIntervalSince1970: 1_793_674_710)
        XCTAssertEqual(ThemeTitlebarClock.timeText(date, timeZone: zone), "18:58:30")
        XCTAssertEqual(ThemeTitlebarClock.zoneText(date, timeZone: zone), "PST")
        XCTAssertEqual(ThemeTitlebarClock.timeText(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!), "00:00:00")
    }

    func testControlRadiusKeepsThePresetUnlessTheThemeSetsOne() {
        let config = TitlebarControlsStyle.classic.config
        XCTAssertEqual(TitlebarControlTheme.unset.buttonRadius(config), config.buttonCornerRadius)
        XCTAssertEqual(TitlebarControlTheme.unset.backdropRadius(config), config.backdropCornerRadius)

        var square = TitlebarControlTheme.unset
        square.radius = 0
        XCTAssertEqual(square.buttonRadius(config), 0)
        XCTAssertEqual(square.backdropRadius(config), 0)

        var rounded = TitlebarControlTheme.unset
        rounded.radius = 3
        XCTAssertEqual(rounded.buttonRadius(config), 3)
        XCTAssertEqual(rounded.backdropRadius(config), 3 + TitlebarControlsStyleConfig.backdropInsets.top)
    }
}
