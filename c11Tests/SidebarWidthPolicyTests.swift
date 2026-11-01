import XCTest

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
    func testEveryStyleClearsSixControlsAtNarrowSidebarWidths() {
        let cases: [(TitlebarControlsStyle, CGFloat)] = [
            (.classic, 298), (.compact, 254), (.roomy, 342),
            (.pillGroup, 296), (.softButtons, 300)
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
            sidebarVisible: false, isFullScreen: false), 298)
        for (offset, expected): (Double, CGFloat) in [(-100, 294), (0, 294), (4, 298), (20, 314), (100, 314)] {
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
