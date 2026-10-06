import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The tab sheet's `active`, `touched`, `turn`, `tools` and `tokens` clocks:
/// scrollback-growth filtering, text formatting, clock assembly and order.
final class TabActivitySignalsTests: XCTestCase {

    // MARK: - Scrollback growth (plain terminals)

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func later(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFirstEventOnlySetsTheBaseline() {
        var tracker = ScrollbackGrowthTracker()
        XCTAssertFalse(tracker.observe(total: 50, len: 24, at: t0))
        XCTAssertTrue(tracker.observe(total: 55, len: 24, at: later(1)), "history grew from 26 to 31")
    }

    func testRepaintsThatDoNotChangeHistoryAreNotOutput() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 50, len: 24, at: t0)
        XCTAssertFalse(tracker.observe(total: 50, len: 24, at: later(1)))
        XCTAssertFalse(tracker.observe(total: 50, len: 24, at: later(2)))
    }

    func testDecreasesLowerTheBaselineWithoutStamping() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 500, len: 24, at: t0)
        XCTAssertFalse(tracker.observe(total: 24, len: 24, at: later(1)), "clear or scrollback pruning")
        XCTAssertTrue(tracker.observe(total: 30, len: 24, at: later(2)), "new output after a clear counts")
    }

    func testEventsInsideTheSettleWindowAfterResizeOrRevealAreNotOutput() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 50, len: 24, at: t0)
        tracker.noteResized(at: later(10))
        XCTAssertFalse(tracker.observe(total: 80, len: 30, at: later(10.1)), "reflow moved the count")
        XCTAssertTrue(tracker.observe(total: 85, len: 30, at: later(11)))

        tracker.noteVisibilityChanged(at: later(20))
        XCTAssertFalse(tracker.observe(total: 400, len: 30, at: later(20.1)), "catch-up delta after a hidden stretch")
    }

    func testFirstRealOutputAfterARevealStillCounts() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 50, len: 24, at: t0)
        tracker.noteVisibilityChanged(at: later(10))
        // Nothing changed while hidden, so no catch-up event arrives; the next
        // event, after the settle window, is real output.
        XCTAssertTrue(tracker.observe(total: 51, len: 24, at: later(10) + ScrollbackGrowthTracker.settleWindow + 0.1))
    }

    func testLeavingAnAltScreenAppDoesNotStampTheRestoredHistory() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 24, len: 24, at: t0)
        for i in 1...4 { XCTAssertFalse(tracker.observe(total: 24, len: 24, at: later(Double(i)))) }
        // Exit: the primary screen's 300 rows of history come back at once.
        XCTAssertFalse(tracker.observe(total: 324, len: 24, at: later(10)))
        XCTAssertTrue(tracker.observe(total: 326, len: 24, at: later(11)))
    }

    func testAFewLinesOfFirstOutputOnAFreshTerminalStillCount() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 24, len: 24, at: t0)
        XCTAssertTrue(tracker.observe(total: 27, len: 24, at: later(1)))
    }

    // MARK: - Text

    private let en = Locale(identifier: "en_US")

    func testDurationText() {
        XCTAssertEqual(PanelSheetClockText.duration(0, locale: en), "0s")
        XCTAssertEqual(PanelSheetClockText.duration(42, locale: en), "42s")
        XCTAssertEqual(PanelSheetClockText.duration(252, locale: en), "4m 12s")
        XCTAssertEqual(PanelSheetClockText.duration(3900, locale: en), "1h 5m")
        XCTAssertEqual(PanelSheetClockText.duration(-5, locale: en), "0s")
    }

    func testCountText() {
        XCTAssertEqual(PanelSheetClockText.count(0, locale: en), "0")
        XCTAssertEqual(PanelSheetClockText.count(999, locale: en), "999")
        XCTAssertTrue(PanelSheetClockText.count(48_200, locale: en).hasPrefix("48"))
        XCTAssertEqual(PanelSheetClockText.count(1_250_000, locale: en), "1.2M")
    }

    func testTextFollowsTheGivenLocaleNotTheRegion() {
        XCTAssertNotEqual(PanelSheetClockText.duration(252, locale: Locale(identifier: "ru")), "4m 12s")
        XCTAssertNotEqual(PanelSheetClockText.count(1_250_000, locale: Locale(identifier: "de")), "1.2M")
    }

    // MARK: - Terminal Active

    func testTerminalActiveNeverIncludesOperatorInput() {
        let output = later(10), edge = later(20), agent = later(5)
        XCTAssertEqual(PanelSheetDetailBuilder.terminalActiveAt(agentLastEventAt: nil, outputGrowthAt: output, commandEdgeAt: edge), edge)
        XCTAssertEqual(PanelSheetDetailBuilder.terminalActiveAt(agentLastEventAt: agent, outputGrowthAt: output, commandEdgeAt: edge), agent)
        // An agent whose files say nothing (Kimi, Copilot, no transcript yet) falls
        // through to the plain-terminal computation; with no signal at all: nil.
        XCTAssertEqual(PanelSheetDetailBuilder.terminalActiveAt(agentLastEventAt: nil, outputGrowthAt: output, commandEdgeAt: nil), output)
        XCTAssertNil(PanelSheetDetailBuilder.terminalActiveAt(agentLastEventAt: nil, outputGrowthAt: nil, commandEdgeAt: nil))
    }

    // MARK: - Clock assembly

    private func inputs(
        activity: BonsplitTabActivityState? = .idle,
        configure: (inout PanelSheetDetailBuilder.Inputs) -> Void = { _ in }
    ) -> PanelSheetDetailBuilder.Inputs {
        var input = PanelSheetDetailBuilder.Inputs(
            panelType: .terminal, title: nil, terminalKind: "claude-code", model: nil, modelLabel: nil,
            description: nil, directory: nil, browserURL: nil, markdownPath: nil,
            activity: activity, isFlagged: false, stateEnteredAt: nil, stateStartedAt: nil,
            flagRaisedAt: nil, lastActivityAt: nil, createdAt: nil
        )
        input.locale = Locale(identifier: "en_US")
        configure(&input)
        return input
    }

    func testClocksAndTextsAreBuiltFromTheSignals() {
        let now = Date(timeIntervalSince1970: 10_000)
        let detail = PanelSheetDetailBuilder.build(inputs(activity: .idle) {
            $0.now = now
            $0.activeAt = now.addingTimeInterval(-30)
            $0.touchedAt = now.addingTimeInterval(-90)
            $0.turnStartedAt = now.addingTimeInterval(-600)
            $0.lastAgentEventAt = now.addingTimeInterval(-300)
            $0.turnToolCalls = 7
            $0.tokens = 48_200
        })
        XCTAssertEqual(detail.clocks["active"], now.addingTimeInterval(-30))
        XCTAssertEqual(detail.clocks["touched"], now.addingTimeInterval(-90))
        XCTAssertEqual(detail.clockTexts["turn"], "5m", "an idle agent's turn is fixed: start to last event")
        XCTAssertEqual(detail.clockTexts["tools"], "7")
        XCTAssertTrue(detail.clockTexts["tokens"]?.hasPrefix("48") == true)
    }

    func testAWorkingTurnKeepsCounting() {
        let now = Date(timeIntervalSince1970: 10_000)
        let detail = PanelSheetDetailBuilder.build(inputs(activity: .running) {
            $0.now = now
            $0.turnStartedAt = now.addingTimeInterval(-125)
            $0.lastAgentEventAt = now.addingTimeInterval(-100)
        })
        XCTAssertEqual(detail.clockTexts["turn"], "2m 5s")
    }

    func testClocksWithoutSignalsAreAbsent() {
        let detail = PanelSheetDetailBuilder.build(inputs())
        XCTAssertTrue(detail.clocks.isEmpty)
        XCTAssertTrue(detail.clockTexts.isEmpty)
    }

    func testIgnoringClocksAlsoIgnoresClockTexts() {
        var a = PanelSheetDetailBuilder.build(inputs())
        var b = a
        b.clockTexts["tokens"] = "9K"
        b.clocks["active"] = Date()
        XCTAssertEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
        a.title = "x"
        XCTAssertNotEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
    }

    func testDefaultOrderExcludesTheOptInClocksButTheSettingCanAddThem() {
        XCTAssertEqual(PanelSheetDetailBuilder.defaultClockOrder, ["active", "seen", "launched"])
        XCTAssertEqual(PanelSheetDetailBuilder.parseClockOrder("active,touched,turn,tools,tokens"),
                       ["active", "touched", "turn", "tools", "tokens"])
        for name in PanelSheetDetailBuilder.optInClocks {
            XCTAssertNotNil(PanelSheetDetailBuilder.clockTitle(name), name)
        }
        XCTAssertNil(PanelSheetDetailBuilder.clockTitle("active"), "bonsplit's built-in titles cover the rest")
    }

    func testSeenShowsTheStoredStampOrNowWhileBeingLookedAt() {
        let stamp = Date(timeIntervalSince1970: 9_000)
        let away = PanelSheetDetailBuilder.build(inputs { $0.seenAt = stamp })
        XCTAssertEqual(away.clocks["seen"], stamp)
        XCTAssertNil(away.clockTexts["seen"])

        // While being seen the stored stamp is stale: show "now", not an age.
        let looking = PanelSheetDetailBuilder.build(inputs { $0.seenAt = stamp; $0.isBeingSeen = true })
        XCTAssertNil(looking.clocks["seen"])
        XCTAssertEqual(looking.clockTexts["seen"], "now")

        // Looked-at for the first time: nothing stored yet, still "now".
        XCTAssertEqual(PanelSheetDetailBuilder.build(inputs { $0.isBeingSeen = true }).clockTexts["seen"], "now")
    }
}
