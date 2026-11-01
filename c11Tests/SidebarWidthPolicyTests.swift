import XCTest
import SwiftUI

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampAllowsNarrowSidebarBelowLegacyMinimum() {
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            184,
            accuracy: 0.001
        )
    }
}

final class TitlebarTitleReserveTests: XCTestCase {
    func testEveryStyleClearsFiveControlsAndTheirBackdropAtNarrowSidebarWidths() {
        let cases: [(TitlebarControlsStyle, CGFloat)] = [
            (.classic, 276), (.compact, 240), (.roomy, 312),
            (.pillGroup, 268), (.softButtons, 278)
        ]
        for (style, expectedTitleOrigin) in cases {
            for width: CGFloat in [180, 200] {
                let padding = style.config.titleLeadingPadding(sidebarWidth: width,
                    sidebarVisible: true, isFullScreen: false)
                XCTAssertEqual(width + padding, expectedTitleOrigin, accuracy: 0.001,
                               "\(style) at sidebar width \(width)")
            }
        }
    }

    func testReserveIncludesTheBackdropPadding() {
        let backdrop = TitlebarControlsStyleConfig.backdropInsets
        XCTAssertGreaterThan(backdrop.leading, 0)
        XCTAssertGreaterThan(backdrop.trailing, 0)
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            // The painted backdrop is the padded content, so its insets are the group padding.
            XCTAssertEqual(config.groupPadding.leading, backdrop.leading, "\(style)")
            XCTAssertEqual(config.groupPadding.trailing, backdrop.trailing, "\(style)")
            let controls = 5 * config.buttonSize + 4 * config.spacing
            XCTAssertEqual(config.titlebarRowWidth, controls + backdrop.leading + backdrop.trailing,
                           accuracy: 0.001, "\(style)")
            let reserved = 180 + config.titleLeadingPadding(sidebarWidth: 180,
                sidebarVisible: true, isFullScreen: false)
            let backdropRightEdge = TitlebarControlsStyleConfig.trafficLightInset
                + TitlebarControlsStyleConfig.leadingPadding + controls + backdrop.leading + backdrop.trailing
            XCTAssertGreaterThanOrEqual(reserved, backdropRightEdge, "\(style)")
        }
    }

    func testWideAndHiddenSidebarUseTheirOwnContentOrigin() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            XCTAssertEqual(config.titleLeadingPadding(sidebarWidth: 400,
                sidebarVisible: true, isFullScreen: false), 12)
            XCTAssertEqual(config.titleLeadingPadding(sidebarWidth: 200,
                sidebarVisible: false, isFullScreen: false),
                config.titleLeadingPadding(sidebarWidth: 180,
                    sidebarVisible: true, isFullScreen: false) + 180)
        }
    }

    func testHiddenSidebarClearsTheFullAccessoryClickAreaAndHintOffset() {
        let config = TitlebarControlsStyle.classic.config
        XCTAssertEqual(config.titleLeadingPadding(sidebarWidth: 200,
            sidebarVisible: false, isFullScreen: false), 276)
        for (offset, expected): (Double, CGFloat) in [(-100, 272), (0, 272), (4, 276), (20, 292), (100, 292)] {
            XCTAssertEqual(config.titleLeadingPadding(sidebarWidth: 200,
                sidebarVisible: false, isFullScreen: false, hintXOffset: offset), expected)
        }
    }

    func testFullscreenDoesNotReserveTheNativeAccessory() {
        for style in TitlebarControlsStyle.allCases {
            XCTAssertEqual(style.config.titleLeadingPadding(sidebarWidth: 180,
                sidebarVisible: true, isFullScreen: true), 12)
            XCTAssertEqual(style.config.titleLeadingPadding(sidebarWidth: 180,
                sidebarVisible: false, isFullScreen: true), 8)
        }
    }
}

final class TitlebarControlContrastTests: XCTestCase {
    func testControlsOnTheBackdropUseTheTitlebarForeground() {
        for style in TitlebarControlsStyle.allCases where style != .softButtons {
            for foreground in [Color.white.opacity(0.82), Color.black.opacity(0.78)] {
                XCTAssertEqual(style.config.controlForeground(customTitlebarForeground: foreground), foreground)
            }
        }
        XCTAssertEqual(TitlebarControlsStyle.softButtons.config.controlForeground(
            customTitlebarForeground: .red), .primary)
    }

    func testBackdropIsOpaqueAndDistinctFromLightAndDarkTitlebars() throws {
        let dark = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.85)
        let light = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1)
        for (background, isDark) in [(dark, true), (light, false)] {
            let colors = TitlebarControlsColors(titlebarBackground: background)
            let backdrop = try XCTUnwrap(colors.backdropNSColor.usingColorSpace(.sRGB))
            XCTAssertEqual(backdrop.alphaComponent, 1, accuracy: 0.001)
            let delta = backdrop.luminance - background.luminance
            // Moved toward the foreground: lighter on dark titlebars, darker on light ones.
            XCTAssertGreaterThan(isDark ? delta : -delta, 0.05, "\(background)")
            XCTAssertEqual(colors.foreground, isDark ? Color.white.opacity(0.82) : Color.black.opacity(0.78))
            // Icons keep contrast: the backdrop stays on the background's side of mid-gray.
            XCTAssertEqual(backdrop.isLightColor, !isDark)
        }
    }
}
