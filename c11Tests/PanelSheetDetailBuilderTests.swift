import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure logic behind the tab sheet's per-tab detail: agent tag, type, status word,
/// subtitle fallbacks, clocks and the clock-order setting.
final class PanelSheetDetailBuilderTests: XCTestCase {
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
    ) -> PanelSheetDetailBuilder.Inputs {
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
            createdAt: t0.addingTimeInterval(-3600),
            activeAt: t0.addingTimeInterval(60)
        )
    }

    // MARK: Agent tag

    func testAgentLabelIsHarnessAndModel() {
        XCTAssertEqual(
            PanelSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: "claude-sonnet-4-6", modelLabel: nil),
            "Claude Code · Sonnet 4.6"
        )
    }

    func testAgentLabelPrefersModelLabelHint() {
        XCTAssertEqual(
            PanelSheetDetailBuilder.agentLabel(terminalKind: "codex", model: nil, modelLabel: "gpt-5.5"),
            "Codex · gpt-5.5"
        )
    }

    func testAgentLabelIsHarnessAloneWhenModelUnknown() {
        XCTAssertEqual(
            PanelSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: nil, modelLabel: nil),
            "Claude Code"
        )
        XCTAssertEqual(
            PanelSheetDetailBuilder.agentLabel(terminalKind: "claude-code", model: "  ", modelLabel: nil),
            "Claude Code"
        )
    }

    func testNoAgentMeansNoLabel() {
        XCTAssertNil(PanelSheetDetailBuilder.agentLabel(terminalKind: nil, model: "claude-opus-4-7", modelLabel: nil))
        XCTAssertNil(PanelSheetDetailBuilder.agentLabel(terminalKind: "shell", model: nil, modelLabel: nil))
        XCTAssertNil(PanelSheetDetailBuilder.agentLabel(terminalKind: "unknown", model: nil, modelLabel: nil))
    }

    // MARK: Type

    func testTypeLabelNamesThePanelKind() {
        XCTAssertEqual(PanelSheetDetailBuilder.build(inputs(panelType: .terminal)).typeLabel, "Terminal")
        XCTAssertEqual(PanelSheetDetailBuilder.build(inputs(panelType: .browser)).typeLabel, "Browser")
        XCTAssertEqual(PanelSheetDetailBuilder.build(inputs(panelType: .markdown)).typeLabel, "Markdown")
        let agent = PanelSheetDetailBuilder.build(inputs(terminalKind: "codex", modelLabel: "gpt-5.5"))
        XCTAssertEqual(agent.agentLabel, "Codex · gpt-5.5")
        XCTAssertEqual(agent.typeLabel, "Terminal")
    }

    func testAgentTintFollowsTheModelFamily() {
        func tint(_ kind: String?, _ model: String?, _ label: String? = nil) -> String? {
            PanelSheetDetailBuilder.agentTintHex(terminalKind: kind, model: model, modelLabel: label)
        }
        XCTAssertEqual(tint("claude-code", "claude-fable-5-1"), "#AF5FFF")
        XCTAssertEqual(tint("claude-code", "claude-opus-5-5"), "#FFFFFF")
        XCTAssertEqual(tint("claude-code", nil, "Sonnet 5.5"), "#5AA0FF")
        XCTAssertEqual(tint("claude-code", "claude-haiku-4-5-20251001"), "#FF80C8")
        XCTAssertEqual(tint("codex", "gpt-5.5"), "#5FD7D7")
        XCTAssertEqual(tint("claude-code", nil), "#5FD7D7")
        XCTAssertNil(tint(nil, "claude-opus-5-5"))
        XCTAssertEqual(PanelSheetDetailBuilder.build(inputs(terminalKind: "claude-code", model: "claude-opus-5-5")).agentTintHex, "#FFFFFF")
        XCTAssertNil(PanelSheetDetailBuilder.build(inputs(panelType: .browser)).agentTintHex)
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
        PanelSheetDetailBuilder.status(
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

    func testFirstSightingIsSeededFromWhatIsKnown() {
        let now = t0.addingTimeInterval(3 * 3600)
        let lastActivity = t0, exact = t0.addingTimeInterval(600)
        // An agent idle for three hours reads three hours after a relaunch.
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .idle, now: now, lastActivityAt: lastActivity, exactStart: nil), lastActivity)
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .working, now: now, lastActivityAt: lastActivity, exactStart: nil), lastActivity)
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .waiting, now: now, lastActivityAt: lastActivity, exactStart: exact), exact)
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .cold, now: now, lastActivityAt: lastActivity, exactStart: nil), lastActivity)
        // Nothing known: now. A future timestamp never runs the clock backwards.
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .idle, now: now, lastActivityAt: nil, exactStart: nil), now)
        XCTAssertEqual(PanelSheetDetailBuilder.seededEnteredAt(kind: .idle, now: now, lastActivityAt: now.addingTimeInterval(90), exactStart: nil), now)
    }

    func testNoActivityMeansNoStatus() {
        XCTAssertNil(status(nil, flagged: true, entered: t0, raised: t0))
        XCTAssertNil(PanelSheetDetailBuilder.baseKind(activity: nil))
        // The recorded kind ignores the flag: a flag toggle must not reset the clock.
        XCTAssertEqual(PanelSheetDetailBuilder.baseKind(activity: .waiting), .waiting)
        XCTAssertEqual(PanelSheetDetailBuilder.baseKind(activity: .running), .working)
        XCTAssertEqual(PanelSheetDetailBuilder.baseKind(activity: .idle), .idle)
        XCTAssertEqual(PanelSheetDetailBuilder.baseKind(activity: .cold), .cold)
    }

    // MARK: Subtitle

    func testDescriptionWinsAndFlattensToOneLine() {
        let detail = PanelSheetDetailBuilder.build(inputs(
            description: "Auditing retry admission.\n\nNext: verify cancellation.",
            directory: "/tmp/x"
        ))
        XCTAssertEqual(detail.subtitle, "Auditing retry admission. Next: verify cancellation.")
    }

    func testSubtitleFallsBackPerKind() {
        XCTAssertEqual(
            PanelSheetDetailBuilder.build(inputs(directory: NSHomeDirectory() + "/Projects/x")).subtitle,
            "~/Projects/x"
        )
        XCTAssertEqual(
            PanelSheetDetailBuilder.build(inputs(panelType: .browser, browserURL: URL(string: "http://localhost:8799/a/b"))).subtitle,
            "localhost"
        )
        XCTAssertEqual(
            PanelSheetDetailBuilder.build(inputs(panelType: .markdown, markdownPath: NSHomeDirectory() + "/notes/A.md")).subtitle,
            "~/notes/A.md"
        )
        XCTAssertNil(PanelSheetDetailBuilder.build(inputs()).subtitle)
    }

    // MARK: Title

    func testFullTitleIsKeptWhole() {
        let long = "Tests on Atlas with a deliberately   very long tab title that the tab strip shortens"
        XCTAssertEqual(
            PanelSheetDetailBuilder.build(inputs(title: long)).title,
            "Tests on Atlas with a deliberately very long tab title that the tab strip shortens"
        )
        XCTAssertNil(PanelSheetDetailBuilder.build(inputs(title: "  ")).title)
    }

    // MARK: Clocks

    func testBuildFillsActiveAndLaunchedAndLeavesSeenBlankWhenNeverSeen() {
        let detail = PanelSheetDetailBuilder.build(inputs())
        XCTAssertEqual(detail.clocks["active"], t0.addingTimeInterval(60))
        XCTAssertEqual(detail.clocks["launched"], t0.addingTimeInterval(-3600))
        XCTAssertNil(detail.clocks["seen"])
        XCTAssertNil(detail.clockTexts["seen"])
    }

    func testClockOrderAcceptsAnArrayToo() {
        let suite = UserDefaults(suiteName: "TabSheetDetailBuilderTests.\(UUID().uuidString)")!
        suite.set(["launched", "active"], forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["launched", "active"])
    }

    func testClockOrderSettingRoundTrips() {
        let suite = UserDefaults(suiteName: "TabSheetDetailBuilderTests.\(UUID().uuidString)")!
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["active", "seen", "launched"])
        suite.set("launched,active", forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["launched", "active"])
        suite.set("active, seen launched", forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["active", "seen", "launched"])
        suite.set("", forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["active", "seen", "launched"])
    }

    func testClockOrderFallsBackToTheOldKeyAndTheNewKeyWins() {
        let suite = UserDefaults(suiteName: "TabSheetDetailBuilderTests.\(UUID().uuidString)")!
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrderDefaultsKey, "c11.panelSheet.clocks")
        suite.set("launched,active", forKey: "c11.tabSheet.clocks")
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["launched", "active"])
        suite.set(["touched", "seen"], forKey: "c11.tabSheet.clocks")
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["touched", "seen"])

        suite.set("seen,launched", forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["seen", "launched"])
        // A set-but-empty new key still shadows the old one: back to the default order.
        suite.set("", forKey: PanelSheetDetailBuilder.clockOrderDefaultsKey)
        XCTAssertEqual(PanelSheetDetailBuilder.clockOrder(defaults: suite), ["active", "seen", "launched"])
    }

    func testIgnoringClocksComparesEverythingElse() {
        var a = PanelSheetDetailBuilder.build(inputs(description: "x"))
        var b = a
        b.clocks["active"] = t0.addingTimeInterval(999)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
        // A state's start time is stable, so a different one is a real change.
        a.status = .init(kind: .waiting, since: t0)
        b.status = .init(kind: .waiting, since: t0.addingTimeInterval(5))
        XCTAssertNotEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
        b.status = a.status
        XCTAssertEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
        a.subtitle = "changed"
        XCTAssertNotEqual(PanelSheetDetailBuilder.ignoringClocks(a), PanelSheetDetailBuilder.ignoringClocks(b))
    }

    func testTurnClockFreezesWhenTheTurnHasEnded() {
        var input = inputs(activity: .running)
        input.turnStartedAt = t0
        input.turnEndedAt = t0.addingTimeInterval(12)
        input.now = t0.addingTimeInterval(12)
        let early = PanelSheetDetailBuilder.build(input).clockTexts["turn"]
        input.now = t0.addingTimeInterval(90)
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).clockTexts["turn"], early)
        input.turnEndedAt = nil
        let later = PanelSheetDetailBuilder.build(input).clockTexts["turn"]
        input.now = t0.addingTimeInterval(12)
        XCTAssertNotEqual(PanelSheetDetailBuilder.build(input).clockTexts["turn"], later)
    }

    func testJournalPhaseSinceReplacesTheActivityClockAndCanStayBlank() {
        var input = inputs(activity: .running)
        input.journalPhaseSinceApplies = true
        input.journalPhaseSince = nil
        let blank = PanelSheetDetailBuilder.build(input).status
        XCTAssertEqual(blank?.kind, .working)
        XCTAssertNil(blank?.since)
        input.journalPhaseSince = t0.addingTimeInterval(5)
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).status?.since, t0.addingTimeInterval(5))
        input.activity = .idle
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).status?.since, t0.addingTimeInterval(5))
        input.isFlagged = true
        let flagged = PanelSheetDetailBuilder.build(input).status
        XCTAssertEqual(flagged?.kind, .flagged)
        XCTAssertEqual(flagged?.since, t0.addingTimeInterval(30))
        var waiting = inputs(activity: .waiting)
        waiting.journalPhaseSinceApplies = false
        waiting.journalPhaseSince = t0.addingTimeInterval(99)
        let unread = PanelSheetDetailBuilder.build(waiting).status
        XCTAssertEqual(unread?.kind, .waiting)
        XCTAssertEqual(unread?.since, t0)
    }

    func testUnconfirmedEvidenceNoteJoinsTheSubtitle() {
        var input = inputs(description: "synthetic")
        input.evidenceNote = "Unconfirmed"
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).subtitle, "synthetic · Unconfirmed")
    }


    // MARK: Cache clock

    func testCacheClockCountsDownWholeMinutesThenReadsCold() {
        let en = Locale(identifier: "en_US")
        let exact = PromptCacheObservation(requestAt: t0, basis: .ttl(3_600), promptTokens: 1_000)
        XCTAssertEqual(PanelSheetDetailBuilder.promptCacheClockText(exact, now: t0.addingTimeInterval(22 * 60 + 5), locale: en), "38m")
        XCTAssertEqual(PanelSheetDetailBuilder.promptCacheClockText(exact, now: t0.addingTimeInterval(3_600 - 20), locale: en), "<1m")
        XCTAssertEqual(PanelSheetDetailBuilder.promptCacheClockText(exact, now: t0.addingTimeInterval(3_600), locale: en), "cold")

        let estimate = PromptCacheObservation(requestAt: t0, basis: .estimate(7_200), promptTokens: nil)
        XCTAssertEqual(PanelSheetDetailBuilder.promptCacheClockText(estimate, now: t0.addingTimeInterval(30 * 60), locale: en), "~1h 30m")
    }

    func testCacheClockIsOptInAndOnlyForAgentsWithEvidence() {
        XCTAssertTrue(PanelSheetDetailBuilder.optInClocks.contains("cache"))
        XCTAssertFalse(PanelSheetDetailBuilder.defaultClockOrder.contains("cache"))
        XCTAssertEqual(PanelSheetDetailBuilder.clockTitle("cache"), "Cache")

        var input = inputs(terminalKind: "claude-code", activity: .idle)
        input.now = t0
        XCTAssertNil(PanelSheetDetailBuilder.build(input).clockTexts["cache"])
        input.promptCache = PromptCacheObservation(requestAt: t0.addingTimeInterval(-3_600), basis: .ttl(300), promptTokens: nil)
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).clockTexts["cache"], "cold")
    }

    func testAWaitingAgentsExpiredCacheJoinsTheSubtitle() {
        var input = inputs(terminalKind: "claude-code", description: "synthetic", activity: .waiting)
        input.now = t0
        input.promptCache = PromptCacheObservation(requestAt: t0.addingTimeInterval(-3_600), basis: .ttl(300), promptTokens: nil)
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).subtitle, "synthetic · cache expired")
        input.evidenceNote = "Unconfirmed"
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).subtitle, "synthetic · Unconfirmed · cache expired")
        input.evidenceNote = nil
        input.activity = .cold
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).subtitle, "synthetic", "a cold mark says it in blue")
        input.activity = .waiting
        input.promptCache = PromptCacheObservation(requestAt: t0, basis: .ttl(300), promptTokens: nil)
        XCTAssertEqual(PanelSheetDetailBuilder.build(input).subtitle, "synthetic", "a warm cache adds nothing")
    }
}

/// The close-workspace card's scale line and live-state counts.
final class WorkspaceCloseInventoryTests: XCTestCase {
    private func row(
        _ title: String,
        agentTint: String? = nil,
        status: BonsplitTabDetail.StatusKind? = nil
    ) -> WorkspaceCloseInventory.Row {
        WorkspaceCloseInventory.Row(
            id: UUID(),
            ordinal: nil,
            title: title,
            kindLabel: agentTint == nil ? "Terminal" : "Claude Code · Opus",
            agentTintHex: agentTint,
            subtitle: nil,
            status: status
        )
    }

    func testCountsPanelsAndAgentsAcrossWorkspaces() {
        let inventory = WorkspaceCloseInventory(groups: [
            .init(id: UUID(), title: "Alpha", rows: [
                row("shell"),
                row("builder", agentTint: "#FFFFFF", status: .working),
                row("reviewer", agentTint: "#5AA0FF", status: .waiting),
            ]),
            .init(id: UUID(), title: "Beta", rows: [
                row("planner", agentTint: "#AF5FFF", status: .flagged),
                row("tester", agentTint: "#FFFFFF", status: .working),
            ]),
        ])

        XCTAssertEqual(inventory.panelCount, 5)
        XCTAssertEqual(inventory.agentCount, 4)
        XCTAssertEqual(inventory.scaleSummary, "5 panels · 4 agents")
        XCTAssertEqual(inventory.liveStateCounts.map(\.kind), [.flagged, .waiting, .working])
        XCTAssertEqual(inventory.liveStateCounts.map(\.count), [1, 1, 2])
        XCTAssertEqual(WorkspaceCloseInventory.stateCount(.working, 2), "2 working")
    }

    func testSinglePanelWithoutAgentsOmitsAgentsAndLiveStates() {
        let inventory = WorkspaceCloseInventory(groups: [
            .init(id: UUID(), title: "Alpha", rows: [row("shell", status: .idle)]),
        ])

        XCTAssertEqual(inventory.scaleSummary, "1 panel")
        XCTAssertTrue(inventory.liveStateCounts.isEmpty, "idle and cold are not live work")
    }
}
