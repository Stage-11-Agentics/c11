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

/// C11H-221: full cards while they fit, compact cards once they would scroll.
final class SidebarDensityPolicyTests: XCTestCase {
    private func density(_ current: SidebarDensity, available: Double, cardsAvailable: Double? = nil,
                         shown: Double = 0, estimate: Double? = nil,
                         setting: SidebarDensitySetting = .automatic) -> SidebarDensity {
        SidebarDensityPolicy.density(setting: setting, current: current, available: available,
                                     cardsAvailable: cardsAvailable ?? available,
                                     shownHeight: shown, estimatedCardsHeight: estimate)
    }

    func testCardsStayWhileTheyFitAndTurnCompactTheMomentTheyWouldScroll() {
        XCTAssertEqual(density(.cards, available: 700, shown: 700), .cards)
        XCTAssertEqual(density(.cards, available: 700, shown: 701), .compact)
    }

    func testCompactReturnsToCardsOnlyWithTheMarginToSpare() {
        XCTAssertEqual(density(.compact, available: 700, estimate: 690), .compact)
        XCTAssertEqual(density(.compact, available: 700, estimate: 676), .cards)
    }

    func testCompactJudgesTheCardsAgainstTheFullChromesRoom() {
        // Compact chrome leaves 740; the full chrome would leave 700 (8 pt New
        // Group, a footer 32 pt taller). Cards of 690 must stay compact.
        let full = SidebarDensityPolicy.fullFooterHeight(measuredHeight: 96, measuredKinds: 1, kinds: 1,
                                                         denseHeight: 64)
        let room = SidebarDensityPolicy.cardsAvailable(compactAvailable: 740, denseFooterHeight: 64,
                                                       fullFooterHeight: full)
        XCTAssertEqual(room, 700)
        XCTAssertEqual(density(.compact, available: 740, cardsAvailable: room, estimate: 690), .compact)
        XCTAssertEqual(density(.compact, available: 740, cardsAvailable: room, estimate: 670), .cards)
    }

    func testAFlagRaisedAtTheEdgeDoesNotFlap() {
        // Cards fit with 20 pt to spare; a flag grows the full footer by 50.
        XCTAssertEqual(density(.cards, available: 650, shown: 680), .compact)
        // Compact: its footer grew less, but the cards are judged against the full chrome.
        let full = SidebarDensityPolicy.fullFooterHeight(measuredHeight: 46, measuredKinds: 0, kinds: 1,
                                                         denseHeight: 64)
        let room = SidebarDensityPolicy.cardsAvailable(compactAvailable: 690, denseFooterHeight: 64,
                                                       fullFooterHeight: full)
        XCTAssertEqual(room, 650)
        XCTAssertEqual(density(.compact, available: 690, cardsAvailable: room, estimate: 680), .compact)
    }

    func testEstimateFollowsTheViewsLinesAndTheMeanForUnmeasuredCards() {
        // One header, then a line of one tall card, then an unmeasured card (mean 250).
        let estimate = SidebarDensityPolicy.estimatedCardsHeight(
            lines: [.header, .cards([400]), .cards([100]), .cards([nil])],
            headerHeight: 52, spacing: 4, padding: 16)
        XCTAssertEqual(estimate, 830)  // 52 + 400 + 100 + 250 + three gaps + padding
        // Tiles: a line takes its taller card; a folder's odd card is its own line.
        XCTAssertEqual(SidebarDensityPolicy.estimatedCardsHeight(
            lines: [.cards([400, 100]), .header, .cards([200])],
            headerHeight: 52, spacing: 4, padding: 16), 676)
        XCTAssertNil(SidebarDensityPolicy.estimatedCardsHeight(
            lines: [.cards([nil, nil])], headerHeight: 52, spacing: 4, padding: 16))
        XCTAssertEqual(SidebarDensityPolicy.estimatedCardsHeight(
            lines: [.cards([nil]), .cards([nil])], headerHeight: 52, spacing: 4, padding: 16,
            fallbackCardHeight: 200), 420)
    }

    func testCompactWithoutAnEstimateTriesCardsOnce() {
        XCTAssertEqual(density(.compact, available: 700, estimate: nil), .cards)
    }

    func testTheSettingPinsEitherMode() {
        XCTAssertEqual(density(.cards, available: 700, shown: 100, setting: .compact), .compact)
        XCTAssertEqual(density(.cards, available: 100, shown: 900, setting: .cards), .cards)
        XCTAssertEqual(SidebarDensitySetting.resolve("nonsense"), .automatic)
        XCTAssertEqual(SidebarDensitySetting.resolve(nil), .automatic)
    }
}

/// C11H-221: the compact card's marks, in the order that keeps attention visible.
final class WorkspacePulseSignalTests: XCTestCase {
    private func agent(_ state: WorkspacePulseState, flagged: Bool = false,
                       delegate: Bool = false) -> WorkspacePulseAgent {
        WorkspacePulseAgent(surfaceId: UUID(), state: state, context: nil,
                            flagged: flagged, suppressed: delegate, lineageDepth: delegate ? 1 : 0)
    }

    func testSignalOrderIsFlagWaitingWorkingIdleColdWithDelegatesLast() {
        let cold = agent(.cold)
        let idleDelegate = agent(.idle, delegate: true)
        let idle = agent(.idle)
        let working = agent(.working)
        let waiting = agent(.waiting)
        let flagged = agent(.working, flagged: true)
        let summary = WorkspacePulseSummary(waitingCount: 1, workingCount: 2, idleCount: 2, coldCount: 1,
                                            agents: [cold, idleDelegate, idle, working, waiting, flagged])
        XCTAssertEqual(summary.signalAgents.map(\.id),
                       [flagged, waiting, working, idle, idleDelegate, cold].map(\.id))
        XCTAssertEqual(summary.bandFlagAgent?.id, flagged.id)
    }

    func testAStoppedDelegateIsNotWaitingOnTheOperator() {
        let summary = WorkspacePulseSummary(waitingCount: 1, workingCount: 0, idleCount: 0, coldCount: 0,
                                            agents: [agent(.waiting), agent(.waiting, delegate: true)],
                                            terminalCount: 2, browserCount: 1, documentCount: 1)
        XCTAssertEqual(summary.waitingOnOperatorCount, 1)
        XCTAssertEqual(summary.nonAgentPanelCount, 4)
        XCTAssertNil(summary.bandFlagAgent)
    }

    func testOverflowKeepsAsManyMarksAsFitBesideTheTail() {
        // 20 marks at 9 + 3 need 237 pt.
        XCTAssertEqual(WorkspacePulseSignalLayout.visibleCount(total: 20, availableWidth: 237), 20)
        // 120 pt: (120 - 24 + 3) / 12 = 8 marks, then "+12".
        XCTAssertEqual(WorkspacePulseSignalLayout.visibleCount(total: 20, availableWidth: 120), 8)
        XCTAssertEqual(WorkspacePulseSignalLayout.visibleCount(total: 20, availableWidth: 0), 20)
        XCTAssertEqual(WorkspacePulseSignalLayout.visibleCount(total: 0, availableWidth: 100), 0)
        XCTAssertEqual(WorkspacePulseSignalLayout.countText(7), "7")
        XCTAssertEqual(WorkspacePulseSignalLayout.countText(140), "99+")
    }
}
