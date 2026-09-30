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

    func testFirstEventOnlySetsTheBaseline() {
        var tracker = ScrollbackGrowthTracker()
        XCTAssertFalse(tracker.observe(total: 50, len: 24))
        XCTAssertTrue(tracker.observe(total: 55, len: 24), "history grew from 26 to 31")
    }

    func testRepaintsThatDoNotChangeHistoryAreNotOutput() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 50, len: 24)
        XCTAssertFalse(tracker.observe(total: 50, len: 24))
        // The viewport size changing without history moving is not growth either.
        XCTAssertFalse(tracker.observe(total: 50, len: 24))
    }

    func testDecreasesLowerTheBaselineWithoutStamping() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 500, len: 24)
        XCTAssertFalse(tracker.observe(total: 24, len: 24), "clear or scrollback pruning")
        XCTAssertTrue(tracker.observe(total: 30, len: 24), "new output after a clear counts")
    }

    func testResizeAndVisibilityRebaselineTheNextEvent() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 50, len: 24)
        tracker.noteResized()
        XCTAssertFalse(tracker.observe(total: 80, len: 30), "reflow moved the count")
        XCTAssertTrue(tracker.observe(total: 85, len: 30))

        tracker.noteVisibilityChanged()
        XCTAssertFalse(tracker.observe(total: 400, len: 30), "catch-up delta after a hidden stretch")
        XCTAssertTrue(tracker.observe(total: 401, len: 30))
    }

    func testAltScreenNeverGrows() {
        var tracker = ScrollbackGrowthTracker()
        _ = tracker.observe(total: 24, len: 24)
        // A full-screen TUI repaints: total stays == len.
        for _ in 0..<5 { XCTAssertFalse(tracker.observe(total: 24, len: 24)) }
    }

    // MARK: - Text

    func testDurationText() {
        XCTAssertEqual(TabSheetClockText.duration(0), "0s")
        XCTAssertEqual(TabSheetClockText.duration(42), "42s")
        XCTAssertEqual(TabSheetClockText.duration(252), "4m 12s")
        XCTAssertEqual(TabSheetClockText.duration(3900), "1h 5m")
        XCTAssertEqual(TabSheetClockText.duration(-5), "0s")
    }

    func testCountText() {
        XCTAssertEqual(TabSheetClockText.count(0), "0")
        XCTAssertEqual(TabSheetClockText.count(999), "999")
        XCTAssertTrue(TabSheetClockText.count(48_200).hasPrefix("48"))
        XCTAssertTrue(TabSheetClockText.count(1_250_000).hasPrefix("1.2"))
    }

    // MARK: - Clock assembly

    private func inputs(
        activity: BonsplitTabActivityState? = .idle,
        configure: (inout TabSheetDetailBuilder.Inputs) -> Void = { _ in }
    ) -> TabSheetDetailBuilder.Inputs {
        var input = TabSheetDetailBuilder.Inputs(
            panelType: .terminal, title: nil, terminalKind: "claude-code", model: nil, modelLabel: nil,
            description: nil, directory: nil, browserURL: nil, markdownPath: nil,
            activity: activity, isFlagged: false, stateEnteredAt: nil, stateStartedAt: nil,
            flagRaisedAt: nil, lastActivityAt: nil, createdAt: nil
        )
        configure(&input)
        return input
    }

    func testClocksAndTextsAreBuiltFromTheSignals() {
        let now = Date(timeIntervalSince1970: 10_000)
        let detail = TabSheetDetailBuilder.build(inputs(activity: .idle) {
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
        let detail = TabSheetDetailBuilder.build(inputs(activity: .running) {
            $0.now = now
            $0.turnStartedAt = now.addingTimeInterval(-125)
            $0.lastAgentEventAt = now.addingTimeInterval(-100)
        })
        XCTAssertEqual(detail.clockTexts["turn"], "2m 5s")
    }

    func testClocksWithoutSignalsAreAbsent() {
        let detail = TabSheetDetailBuilder.build(inputs())
        XCTAssertTrue(detail.clocks.isEmpty)
        XCTAssertTrue(detail.clockTexts.isEmpty)
    }

    func testIgnoringClocksAlsoIgnoresClockTexts() {
        var a = TabSheetDetailBuilder.build(inputs())
        var b = a
        b.clockTexts["tokens"] = "9K"
        b.clocks["active"] = Date()
        XCTAssertEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
        a.title = "x"
        XCTAssertNotEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
    }

    func testDefaultOrderExcludesTheOptInClocksButTheSettingCanAddThem() {
        XCTAssertEqual(TabSheetDetailBuilder.defaultClockOrder, ["active", "seen", "launched"])
        XCTAssertEqual(TabSheetDetailBuilder.parseClockOrder("active,touched,turn,tools,tokens"),
                       ["active", "touched", "turn", "tools", "tokens"])
        for name in TabSheetDetailBuilder.optInClocks {
            XCTAssertNotNil(TabSheetDetailBuilder.clockTitle(name), name)
        }
        XCTAssertNil(TabSheetDetailBuilder.clockTitle("active"), "bonsplit's built-in titles cover the rest")
    }
}
