import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure logic behind the tab sheet's per-tab detail: agent tag, status word,
/// subtitle fallbacks, clocks and the clock-order setting.
final class TabSheetDetailBuilderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        panelType: PanelType = .terminal,
        title: String? = nil,
        terminalKind: String? = nil,
        model: String? = nil,
        modelLabel: String? = nil,
        description: String? = nil,
        directory: String? = nil,
        browserURL: URL? = nil,
        markdownPath: String? = nil,
        activity: BonsplitTabActivityState? = nil,
        isFlagged: Bool = false
    ) -> TabSheetDetailBuilder.Inputs {
        .init(
            panelType: panelType,
            title: title,
            terminalKind: terminalKind,
            model: model,
            modelLabel: modelLabel,
            description: description,
            directory: directory,
            browserURL: browserURL,
            markdownPath: markdownPath,
            activity: activity,
            isFlagged: isFlagged,
            stateEnteredAt: t0.addingTimeInterval(10),
            stateStartedAt: t0,
            flagRaisedAt: t0.addingTimeInterval(30),
            lastActivityAt: t0.addingTimeInterval(60),
            createdAt: t0.addingTimeInterval(-3600)
        )
    }

    // MARK: Agent tag

    func testAgentLabelIsHarnessAndModel() {
        XCTAssertEqual(
            TabSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: "claude-sonnet-4-6", modelLabel: nil),
            "Claude Code · Sonnet 4.6"
        )
    }

    func testAgentLabelPrefersModelLabelHint() {
        XCTAssertEqual(
            TabSheetDetailBuilder.agentLabel(terminalKind: "codex", model: nil, modelLabel: "gpt-5.5"),
            "Codex · gpt-5.5"
        )
    }

    func testAgentLabelIsHarnessAloneWhenModelUnknown() {
        XCTAssertEqual(
            TabSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: nil, modelLabel: nil),
            "Claude Code"
        )
        XCTAssertEqual(
            TabSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: "  ", modelLabel: nil),
            "Claude Code"
        )
    }

    func testNoAgentMeansNoLabel() {
        XCTAssertNil(TabSheetDetailBuilder.agentLabel(terminalKind: nil, model: "claude-opus-4-7", modelLabel: nil))
        XCTAssertNil(TabSheetDetailBuilder.agentLabel(terminalKind: "shell", model: nil, modelLabel: nil))
        XCTAssertNil(TabSheetDetailBuilder.agentLabel(terminalKind: "unknown", model: nil, modelLabel: nil))
    }

    // MARK: Status

    private func status(
        _ activity: BonsplitTabActivityState?,
        flagged: Bool = false,
        entered: Date? = nil,
        started: Date? = nil,
        raised: Date? = nil,
        lastActivity: Date? = nil
    ) -> BonsplitTabDetail.Status? {
        TabSheetDetailBuilder.status(
            activity: activity, isFlagged: flagged, enteredAt: entered,
            stateStartedAt: started, flagRaisedAt: raised, lastActivityAt: lastActivity
        )
    }

    func testStatusCountsFromWhenTheStateWasEntered() {
        let entered = t0, lastActivity = t0.addingTimeInterval(500)
        // Working and idle hold since the transition, not since the last output.
        XCTAssertEqual(status(.running, entered: entered, lastActivity: lastActivity), .init(kind: .working, since: entered))
        XCTAssertEqual(status(.idle, entered: entered, lastActivity: lastActivity), .init(kind: .idle, since: entered))
        // Without a recorded transition they fall back to the last activity.
        XCTAssertEqual(status(.running, lastActivity: lastActivity)?.since, lastActivity)
    }

    func testWaitingColdAndFlaggedPreferTheirExactEventTimes() {
        let entered = t0, exact = t0.addingTimeInterval(100), raised = t0.addingTimeInterval(200)
        XCTAssertEqual(status(.waiting, entered: entered, started: exact), .init(kind: .waiting, since: exact))
        XCTAssertEqual(status(.waiting, entered: entered), .init(kind: .waiting, since: entered))
        XCTAssertEqual(status(.cold, entered: entered, started: exact), .init(kind: .cold, since: exact))
        // A flag wins over the base state and counts from the raise.
        XCTAssertEqual(status(.waiting, flagged: true, entered: entered, started: exact, raised: raised), .init(kind: .flagged, since: raised))
        XCTAssertEqual(status(.running, flagged: true, entered: entered)?.since, entered)
    }

    func testNoActivityMeansNoStatus() {
        XCTAssertNil(status(nil, flagged: true, entered: t0, raised: t0))
        XCTAssertNil(TabSheetDetailBuilder.statusKind(activity: nil, isFlagged: true))
        XCTAssertEqual(TabSheetDetailBuilder.statusKind(activity: .waiting, isFlagged: true), .flagged)
        XCTAssertEqual(TabSheetDetailBuilder.statusKind(activity: .running, isFlagged: false), .working)
    }

    // MARK: Subtitle

    func testDescriptionWinsAndFlattensToOneLine() {
        let detail = TabSheetDetailBuilder.build(inputs(
            description: "Auditing retry admission.\n\nNext: verify cancellation.",
            directory: "/tmp/x"
        ))
        XCTAssertEqual(detail.subtitle, "Auditing retry admission. Next: verify cancellation.")
    }

    func testSubtitleFallsBackPerKind() {
        XCTAssertEqual(
            TabSheetDetailBuilder.build(inputs(directory: NSHomeDirectory() + "/Projects/x")).subtitle,
            "~/Projects/x"
        )
        XCTAssertEqual(
            TabSheetDetailBuilder.build(inputs(panelType: .browser, browserURL: URL(string: "http://localhost:8799/a/b"))).subtitle,
            "localhost"
        )
        XCTAssertEqual(
            TabSheetDetailBuilder.build(inputs(panelType: .markdown, markdownPath: NSHomeDirectory() + "/notes/A.md")).subtitle,
            "~/notes/A.md"
        )
        XCTAssertNil(TabSheetDetailBuilder.build(inputs()).subtitle)
    }

    // MARK: Title

    func testFullTitleIsKeptWhole() {
        let long = "Tests on Atlas with a deliberately   very long tab title that the tab strip shortens"
        XCTAssertEqual(
            TabSheetDetailBuilder.build(inputs(title: long)).title,
            "Tests on Atlas with a deliberately very long tab title that the tab strip shortens"
        )
        XCTAssertNil(TabSheetDetailBuilder.build(inputs(title: "  ")).title)
    }

    // MARK: Clocks

    func testBuildFillsActiveAndLaunchedButNeverSeen() {
        let detail = TabSheetDetailBuilder.build(inputs())
        XCTAssertEqual(detail.clocks["active"], t0.addingTimeInterval(60))
        XCTAssertEqual(detail.clocks["launched"], t0.addingTimeInterval(-3600))
        XCTAssertNil(detail.clocks["seen"])
    }

    func testClockOrderAcceptsAnArrayToo() {
        let suite = UserDefaults(suiteName: "TabSheetDetailBuilderTests.\(UUID().uuidString)")!
        suite.set(["launched", "active"], forKey: TabSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(TabSheetDetailBuilder.clockOrder(defaults: suite), ["launched", "active"])
    }

    func testClockOrderSettingRoundTrips() {
        let suite = UserDefaults(suiteName: "TabSheetDetailBuilderTests.\(UUID().uuidString)")!
        XCTAssertEqual(TabSheetDetailBuilder.clockOrder(defaults: suite), ["active", "launched"])
        suite.set("launched,active", forKey: TabSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(TabSheetDetailBuilder.clockOrder(defaults: suite), ["launched", "active"])
        suite.set("active, seen launched", forKey: TabSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(TabSheetDetailBuilder.clockOrder(defaults: suite), ["active", "seen", "launched"])
        suite.set("", forKey: TabSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(TabSheetDetailBuilder.clockOrder(defaults: suite), ["active", "launched"])
    }

    func testIgnoringClocksComparesEverythingElse() {
        var a = TabSheetDetailBuilder.build(inputs(description: "x"))
        var b = a
        b.clocks["active"] = t0.addingTimeInterval(999)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
        // A state's start time is stable, so a different one is a real change.
        a.status = .init(kind: .waiting, since: t0)
        b.status = .init(kind: .waiting, since: t0.addingTimeInterval(5))
        XCTAssertNotEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
        b.status = a.status
        XCTAssertEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
        a.subtitle = "changed"
        XCTAssertNotEqual(TabSheetDetailBuilder.ignoringClocks(a), TabSheetDetailBuilder.ignoringClocks(b))
    }
}
