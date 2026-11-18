import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-320: the facts `c11 fleet --json` reports so a watcher needs no
/// screen read: a blocked reason, the login, the last message, input state.
final class FleetObservabilityTests: XCTestCase {
    // MARK: - Screens

    /// Recorded with `c11 read-screen` from a live c11h panel on 2026-11-15
    /// (Claude Code 2.1.325, 164 columns): the session was resumed after a
    /// restart and Claude stopped on its resume dialog. `input-state` said
    /// `unknown` and fleet said `idle`. Row text as drawn, trailing padding
    /// dropped; the cursor is hidden, so it sits outside these rows.
    private let recordedResumeRows = [
        "",
        "\u{273B} Cooked for 2m 55s \u{00B7} done Saturday 11:41 PM",
        "",
        String(repeating: "\u{2500}", count: 164),
        "  Resume this conversation?",
        "",
        "  This conversation has been inactive for 11h 50m and is 535.5k tokens long. Resuming it will use about 7% of your 5-hour usage limit.",
        "",
        "  \u{276F} 1. Resume",
        "    2. Start a new conversation  Claude can look this one up if you refer to it later",
        "",
        "  Enter to confirm \u{00B7} Esc to resume",
    ]

    /// Claude Code 2.1.325's rate-limit options menu. No live capture exists
    /// yet (no seat was on it while this was written); the rows are the
    /// shipped binary's own strings (`tengu_rate_limit_options_menu`: title
    /// `What do you want to do?`, option labels, Select footer) in the layout
    /// of the recorded resume dialog above, which uses the same components.
    private let usageLimitMenuRows = [
        "\u{23FA} Usage limit reached",
        "  \u{23BF}  You've hit your 5-hour limit \u{00B7} resets 12:20pm (America/Los_Angeles)",
        "",
        String(repeating: "\u{2500}", count: 120),
        "  What do you want to do?",
        "",
        "  \u{276F} 1. Stop and wait for limit to reset",
        "    2. Add funds to continue with usage credits",
        "    3. Upgrade your plan",
        "",
        "  Enter to confirm \u{00B7} Esc to cancel",
    ]

    /// Recorded by `read-screen` from two Claude seats at a real 5-hour limit
    /// (2026-11, Claude Code 2.1.3xx): the bottom of the auto-continue wait.
    /// The banner replaces the composer until the reset.
    private let recordedAutoContinueRows = [
        "\u{23FA} Background command \"Wait for run B fill\" completed (exit code 0)",
        "  \u{23BF}  You've hit your 5-hour limit \u{00B7} resets 8:10am (America/Los_Angeles)",
        "",
        "\u{23FA} Usage limit reached \u{00B7} continuing automatically at 8:10am \u{00B7} esc to cancel",
        "",
        "",
        "  \u{26A0} Usage limit reached \u{00B7} limit resets 8:10am",
        "    Continuing automatically at 8:10am \u{00B7} Esc to cancel \u{00B7} /usage-credits to continue now",
    ]

    private let idleComposerRows = [
        String(repeating: "\u{2500}", count: 80),
        "\u{276F}\u{00A0} ",
        String(repeating: "\u{2500}", count: 80),
        "  ? for shortcuts",
    ]

    func testRecordedClaudeResumeDialogIsADialogNamedResume() {
        let screen = hiddenCursorScreen(bottom: recordedResumeRows)
        let classification = PromptInputClassifier.classify(screen, harness: "claude-code")
        XCTAssertEqual(classification.state, .dialog)
        XCTAssertEqual(classification.dialogKind, "resume")
        let fields = PromptInputObservation.activeScreen(screen, harness: "claude-code").responseFields
        XCTAssertEqual(fields["input_state"] as? String, "dialog")
        XCTAssertEqual(fields["dialog_kind"] as? String, "resume")
        // Mail, `send` and feed answers already refuse every dialog.
        XCTAssertEqual(SendInputGuard.decide(state: classification.state, allowUnguarded: false), .refuse(reason: "dialog"))
    }

    func testRecordedResumeDialogAtTheCursorIsTheResumeChooser() {
        // A narrow panel whose cursor window holds the dialog, cursor on the
        // selected option, as Claude's other choosers are recorded.
        let screen = snapshot(recordedResumeRows, cursorY: 8)
        XCTAssertEqual(PromptInputClassifier.classify(screen, harness: "claude-code").state, .dialog)
        XCTAssertEqual(PromptInputClassifier.chooserKind(screen, harness: "claude-code"), .resume)
        XCTAssertEqual(PromptInputObservation.activeScreen(screen, harness: "claude-code").responseFields["dialog_kind"] as? String, "resume")
    }

    func testUsageLimitMenuIsADialogNamedUsageLimit() {
        let screen = hiddenCursorScreen(bottom: usageLimitMenuRows)
        let classification = PromptInputClassifier.classify(screen, harness: "claude-code")
        XCTAssertEqual(classification.state, .dialog)
        XCTAssertEqual(classification.dialogKind, "usage_limit")
    }

    func testRecordedAutoContinueWaitIsAUsageLimitWithItsResetTime() throws {
        let screen = hiddenCursorScreen(bottom: recordedAutoContinueRows)
        let classification = PromptInputClassifier.classify(screen, harness: "claude-code")
        XCTAssertEqual(classification.state, .dialog, "mail must not be typed into the wait")
        XCTAssertEqual(classification.dialogKind, "usage_limit")
        // 06:00 PST; the transcript line names the zone: 8:10 PST is 16:10Z.
        XCTAssertEqual(PromptInputClassifier.claudeLimitResetsAt(rows(recordedAutoContinueRows), now: try date("2026-11-15T14:00:00Z")),
                       try date("2026-11-15T16:10:00Z"))
        // Without the transcript line, the banner's zoneless time is local.
        let bannerOnly = Array(recordedAutoContinueRows.suffix(2))
        let local = try XCTUnwrap(PromptInputClassifier.claudeLimitResetsAt(rows(bannerOnly), now: Date()))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.component(.hour, from: local), 8)
        XCTAssertEqual(calendar.component(.minute, from: local), 10)
        // Once the wait ends, the transcript line alone above a composer is not a wait.
        let after = Array((recordedAutoContinueRows.prefix(4) + idleComposerRows).suffix(PromptInputClassifier.maxRows))
        XCTAssertNil(PromptInputClassifier.claudeBlockingDialog(rows(after)))
    }

    func testAutoContinueBannerWrappedOnANarrowPanelIsStillAUsageLimit() throws {
        // A 70-column split wraps the banner's second line; its last row is a continuation.
        let footer = "    Continuing automatically at 8:10am \u{00B7} Esc to cancel \u{00B7} /usage-credits to continue now"
        let split = footer.index(footer.startIndex, offsetBy: 70)
        let narrow = Array(recordedAutoContinueRows.dropLast()) + [String(footer[..<split]), String(footer[split...])]
        let wrapped = rows(narrow, softWrapped: [narrow.count - 2])
        XCTAssertEqual(PromptInputClassifier.claudeBlockingDialog(wrapped), .usageLimit)
        XCTAssertEqual(PromptInputClassifier.claudeLimitResetsAt(wrapped, now: try date("2026-11-15T14:00:00Z")),
                       try date("2026-11-15T16:10:00Z"))
        // The same rows with a cleared composer below them are not a wait.
        let cleared = narrow + idleComposerRows
        XCTAssertNil(PromptInputClassifier.claudeBlockingDialog(rows(Array(cleared.suffix(PromptInputClassifier.maxRows)),
                                                                     softWrapped: [narrow.count - 2 - max(0, cleared.count - PromptInputClassifier.maxRows)])))
    }

    func testABlockingDialogAboveALiveComposerIsNotADialog() {
        // The same rows quoted in a transcript, with Claude's composer below.
        for dialog in [recordedResumeRows, usageLimitMenuRows] {
            let bottom = Array((dialog + idleComposerRows).suffix(PromptInputClassifier.maxRows))
            XCTAssertNil(PromptInputClassifier.claudeBlockingDialog(rows(bottom)))
            XCTAssertNotEqual(PromptInputClassifier.classify(hiddenCursorScreen(bottom: bottom), harness: "claude-code").dialogKind, "resume")
        }
        // Another harness's screen is never read for Claude's dialogs.
        XCTAssertNotEqual(PromptInputClassifier.classify(hiddenCursorScreen(bottom: recordedResumeRows), harness: "codex").state, .dialog)
    }

    @MainActor
    func testAClaudeCaptureAlsoReadsTheBottomRows() {
        var reads: [TerminalController.PromptRegionAnchor] = []
        let transcript = snapshot(["Some transcript text the cursor is parked on"], cursorY: 0)
        let bottom = snapshot(recordedResumeRows, cursorY: 99)
        let captured = TerminalController.capturePromptInputRegion(harness: "claude-code", forSupervisor: false) { anchor in
            reads.append(anchor)
            return anchor == .cursor ? transcript : bottom
        }
        XCTAssertEqual(reads, [.cursor, .bottom])
        XCTAssertEqual(captured.flatMap { PromptInputClassifier.classify($0, harness: "claude-code").dialogKind }, "resume")

        // Even over an idle composer: deciding to skip it would mean classifying on main.
        reads = []
        let idle = snapshot(idleComposerRows, cursorY: 1)
        _ = TerminalController.capturePromptInputRegion(harness: "claude-code", forSupervisor: false) { anchor in
            reads.append(anchor)
            return idle
        }
        XCTAssertEqual(reads, [.cursor, .bottom])
        reads = []
        _ = TerminalController.capturePromptInputRegion(harness: "codex", forSupervisor: false) { anchor in
            reads.append(anchor)
            return idle
        }
        XCTAssertEqual(reads, [.cursor], "other harnesses keep the single read")
    }

    // MARK: - Hook report parsing

    func testResetTimeIsTheNextOccurrenceInClaudesZone() throws {
        let text = "You've hit your 5-hour limit \u{00B7} resets 12:20pm (America/Los_Angeles)"
        // 09:15 PST on 2026-11-15 is 17:15Z; the reset is 12:20 PST, 20:20Z.
        let morning = try date("2026-11-15T17:15:00Z")
        XCTAssertEqual(ClaudeAgentReport.resetsAt(text, now: morning), try date("2026-11-15T20:20:00Z"))
        // After 12:20 the same sentence means tomorrow.
        XCTAssertEqual(ClaudeAgentReport.resetsAt(text, now: try date("2026-11-15T21:00:00Z")),
                       try date("2026-11-16T20:20:00Z"))
        XCTAssertEqual(ClaudeAgentReport.resetsAt("resets 3pm (America/New_York)", now: morning),
                       try date("2026-11-15T20:00:00Z"))
        XCTAssertEqual(ClaudeAgentReport.resetsAt("You've hit your weekly limit \u{00B7} resets Nov 18, 3pm (America/Los_Angeles)", now: morning),
                       try date("2026-11-18T23:00:00Z"))
        XCTAssertNil(ClaudeAgentReport.resetsAt("resets 12:20pm (Mars/Olympus)", now: morning))
        XCTAssertNil(ClaudeAgentReport.resetsAt("You've hit your 5-hour limit", now: morning))
        XCTAssertNil(ClaudeAgentReport.resetsAt(nil, now: morning))
    }

    func testLimitKindComesFromClaudesLimitSentenceOnly() {
        XCTAssertEqual(ClaudeAgentReport.usageLimitKind("You've hit your 5-hour limit \u{00B7} resets 12:20pm (America/Los_Angeles)"), "five_hour")
        XCTAssertEqual(ClaudeAgentReport.usageLimitKind("You've hit your session limit"), "five_hour")
        XCTAssertEqual(ClaudeAgentReport.usageLimitKind("You've hit your weekly limit \u{00B7} resets Nov 18, 3pm (UTC)"), "weekly")
        XCTAssertEqual(ClaudeAgentReport.usageLimitKind("You've hit your monthly spend limit."), "monthly_spend")
        XCTAssertEqual(ClaudeAgentReport.usageLimitKind("You've hit your Fable limit"), "other")
        XCTAssertNil(ClaudeAgentReport.usageLimitKind("API Error: Your computer went to sleep mid-response"))
        XCTAssertNil(ClaudeAgentReport.usageLimitKind("I think you've hit your 5-hour limit"))
    }

    func testAccountIsTheLaunchersNameElseTheConfigDirectory() {
        XCTAssertNil(ClaudeAgentReport.account(environment: [:]))
        let named = ClaudeAgentReport.account(environment: ["C11_AGENT_ACCOUNT": "Echo", "CLAUDE_CONFIG_DIR": "/u/.claude-profiles/foxtrot"])
        XCTAssertEqual(named?.name, "Echo")
        XCTAssertEqual(named?.source, "env")
        let profile = ClaudeAgentReport.account(environment: ["CLAUDE_CONFIG_DIR": "/u/.claude-profiles/foxtrot/"])
        XCTAssertEqual(profile?.name, "foxtrot")
        XCTAssertEqual(profile?.source, "claude_config_dir")
        XCTAssertEqual(ClaudeAgentReport.account(environment: ["CLAUDE_CONFIG_DIR": "/u/.claude-gregorovich"])?.name, "claude-gregorovich")
        // A name with a slash is refused, and the config directory decides.
        XCTAssertEqual(ClaudeAgentReport.account(environment: ["C11_AGENT_ACCOUNT": "a/b", "CLAUDE_CONFIG_DIR": "/u/.claude-profiles/echo"])?.name, "echo")
        // Naming the default home explicitly is still the default home.
        XCTAssertNil(ClaudeAgentReport.account(environment: ["HOME": "/u", "CLAUDE_CONFIG_DIR": "/u/.claude"]))
        XCTAssertNil(ClaudeAgentReport.account(environment: ["HOME": "/u", "CLAUDE_CONFIG_DIR": "/u/.claude/"]))
    }

    func testLastMessageIsOneBoundedLine() {
        XCTAssertNil(ClaudeAgentReport.lastMessage("  \n "))
        XCTAssertEqual(ClaudeAgentReport.lastMessage("Needs you: nothing.\n\n  PR #12 is open."), "Needs you: nothing. PR #12 is open.")
        let long = ClaudeAgentReport.lastMessage(String(repeating: "word ", count: 200))
        XCTAssertEqual(long?.count, ClaudeAgentReport.lastMessageMaxLength)
        XCTAssertEqual(long?.last, "\u{2026}")
    }

    func testStopFailureHookReportKeepsCodesAndTimesNotProse() throws {
        let fields = ClaudeAgentReport.stopFailureFields([
            "error": "rate_limit",
            "last_assistant_message": "You've hit your 5-hour limit \u{00B7} resets 12:20pm (America/Los_Angeles)",
        ], now: try date("2026-11-15T17:15:00Z"))
        XCTAssertEqual(fields["failure_code"] as? String, "rate_limit")
        XCTAssertEqual(fields["limit"] as? String, "five_hour")
        XCTAssertEqual(fields["resets_at_ms"] as? Int64, Int64(try date("2026-11-15T20:20:00Z").timeIntervalSince1970 * 1000))
        let server = ClaudeAgentReport.stopFailureFields(["error": "server_error", "last_assistant_message": "API Error: 529 overloaded"], now: Date())
        XCTAssertEqual(server["failure_code"] as? String, "server_error")
        XCTAssertNil(server["limit"])
        XCTAssertNil(ClaudeAgentReport.stopFailureFields(["error": "Rate Limit!"], now: Date())["failure_code"])
    }

    // MARK: - Report store

    func testReportStoreFoldsSessionStopAndFailure() throws {
        let panel = UUID()
        let store = AgentReportStore()
        let start = try date("2026-11-15T17:00:00Z")
        store.record(.init(panelId: panel, event: .sessionStart, account: "echo", accountSource: "claude_config_dir"), now: start, keepText: true)
        store.record(.init(panelId: panel, event: .stop, lastMessage: "Needs you: nothing."), now: start.addingTimeInterval(60), keepText: true)
        store.record(.init(panelId: panel, event: .stopFailure, failureCode: "rate_limit", limit: "five_hour",
                           resetsAt: start.addingTimeInterval(3600), failureText: "You've hit your 5-hour limit"),
                     now: start.addingTimeInterval(120), keepText: true)
        var entry = try XCTUnwrap(store.entry(forPanel: panel))
        XCTAssertEqual(entry.account, "echo")
        XCTAssertEqual(entry.lastMessage?.text, "Needs you: nothing.", "a failure keeps the last real message")
        XCTAssertEqual(entry.failure?.isUsageLimit, true)
        XCTAssertEqual(entry.failure?.resetsAt, start.addingTimeInterval(3600))

        store.record(.init(panelId: panel, event: .stop, lastMessage: "Resumed and done."), now: start.addingTimeInterval(4000), keepText: true)
        entry = try XCTUnwrap(store.entry(forPanel: panel))
        XCTAssertNil(entry.failure, "a completed turn ends the failure")
        XCTAssertEqual(entry.lastMessage?.text, "Resumed and done.")

        store.record(.init(panelId: panel, event: .sessionStart), now: start.addingTimeInterval(5000), keepText: true)
        XCTAssertNil(store.entry(forPanel: panel)?.account, "a new session in the default home names no account")
        store.retain(livePanels: [])
        XCTAssertNil(store.entry(forPanel: panel))
    }

    func testReportStoreKeepsNoTextWhenTextRecordingIsOff() {
        let panel = UUID()
        let entry = AgentReportStore().record(.init(panelId: panel, event: .stop, lastMessage: "Secret plan"), keepText: false)
        XCTAssertNil(entry.lastMessage?.text)
        XCTAssertEqual(entry.lastMessage?.chars, 11)
        XCTAssertEqual(entry.lastMessage?.textRecorded, false)
    }

    func testAgentReportSocketValidatesItsParams() {
        let panel = UUID()
        let store = AgentReportStore()
        func call(_ params: [String: Any]) -> TerminalController.V2CallResult {
            TerminalController.agentReportResult(params: params, store: store, now: Date(), keepText: true)
        }
        if case .ok = call(["panel_id": panel.uuidString, "event": "stop", "last_message": "hi", "account": "echo", "account_source": "env"]) {} else { XCTFail("valid report refused") }
        XCTAssertEqual(store.entry(forPanel: panel)?.account, "echo")
        for bad: [String: Any] in [
            ["event": "stop"],
            ["panel_id": panel.uuidString, "event": "launch"],
            ["panel_id": panel.uuidString, "event": "stop", "account": "a/b", "account_source": "env"],
            ["panel_id": panel.uuidString, "event": "stop", "account": "echo", "account_source": "keychain"],
            ["panel_id": panel.uuidString, "event": "stop_failure", "failure_code": "Rate Limit"],
            ["panel_id": panel.uuidString, "event": "stop_failure", "limit": "hourly"],
            ["panel_id": panel.uuidString, "event": "stop_failure", "resets_at_ms": -1],
        ] {
            if case .ok = call(bad) { XCTFail("accepted \(bad)") }
        }
    }

    // MARK: - Blocked

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// One window for every synthetic row, so a rebuilt snapshot changes only what a test changes.
    private let window = UUID()
    /// What `agentPanel` declares per workspace and per row; `fleet` attaches it, as the main copy does.
    private var facts: [UUID: FleetSnapshot.WorkspaceFacts] = [:]
    private var refs: [UUID: String] = [:]

    private func look(_ state: PromptInputState, _ kind: String? = nil, age: TimeInterval = 5) -> FleetScreenLook {
        FleetScreenLook(state: state, draftLength: nil, dialogKind: kind,
                        observedAt: now.addingTimeInterval(-age), since: now.addingTimeInterval(-120))
    }

    private func limitFailure() -> AgentReportStore.Failure {
        .init(code: "rate_limit", limit: "five_hour", resetsAt: now.addingTimeInterval(3600),
              text: "You've hit your 5-hour limit", chars: 28, at: now.addingTimeInterval(-600))
    }

    func testEachLiveDialogIsItsOwnBlockedReason() {
        let idle = FleetAgentState.Journal(phase: .idle, turnOutcome: "completed")
        let cases: [(String, String, String?)] = [
            ("resume", "resume_dialog", nil), ("usage_limit", "usage_limit", nil),
            ("permission", "permission_prompt", nil), ("trust", "question_dialog", "trust"),
        ]
        for (kind, reason, detail) in cases {
            let blocked = FleetAgentState.blocked(journal: idle, wait: nil, look: look(.dialog, kind), failure: nil, now: now)
            XCTAssertEqual(blocked?.reason, reason, kind)
            XCTAssertEqual(blocked?.source, "screen")
            XCTAssertEqual(blocked?.detail, detail)
            XCTAssertEqual(blocked?.since, now.addingTimeInterval(-120))
        }
        let menu = FleetAgentState.blocked(journal: idle, wait: nil, look: look(.dialog, "usage_limit"), failure: limitFailure(), now: now)
        XCTAssertEqual(menu?.resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(menu?.detail, "five_hour")
        // After a restart no hook has reported; the screen's printed reset stands.
        var printed = look(.dialog, "usage_limit")
        printed.resetsAt = now.addingTimeInterval(1800)
        XCTAssertEqual(FleetAgentState.blocked(journal: nil, wait: nil, look: printed, failure: nil, now: now)?.resetsAt,
                       now.addingTimeInterval(1800))
    }

    func testAMerelyIdleAgentIsNotBlockedAndAClearedScreenClears() {
        let idle = FleetAgentState.Journal(phase: .idle, turnOutcome: "completed")
        XCTAssertNil(FleetAgentState.blocked(journal: idle, wait: nil, look: look(.empty), failure: nil, now: now))
        XCTAssertNil(FleetAgentState.blocked(journal: idle, wait: nil, look: nil, failure: nil, now: now))
        XCTAssertNil(FleetAgentState.blocked(journal: nil, wait: nil, look: look(.suggestion), failure: nil, now: now))
        // A dialog seen long ago, or under a working journal, is not current.
        XCTAssertNil(FleetAgentState.blocked(journal: idle, wait: nil, look: look(.dialog, "resume", age: 600), failure: nil, now: now))
        XCTAssertNil(FleetAgentState.blocked(journal: .init(phase: .working), wait: nil, look: look(.dialog, "resume"),
                                             failure: limitFailure(), now: now))
    }

    func testJournalWaitsAndFailedTurnsAreBlockedReasons() {
        let blockedJournal = FleetAgentState.Journal(phase: .blocked, reason: .approval, sinceMs: 1_799_999_000_000)
        let permission = FleetAgentState.blocked(journal: blockedJournal, wait: .init(kind: "permission", source: "journal", sinceMs: 1_799_999_000_000),
                                                 look: nil, failure: nil, now: now)
        XCTAssertEqual(permission?.reason, "permission_prompt")
        XCTAssertEqual(permission?.source, "journal")
        XCTAssertEqual(FleetAgentState.blocked(journal: blockedJournal, wait: .init(kind: "question"), look: nil, failure: nil, now: now)?.detail, "question")

        let failed = FleetAgentState.Journal(phase: .error, reason: .sessionFailure, sinceMs: 1_799_999_400_000)
        let limited = FleetAgentState.blocked(journal: failed, wait: nil, look: look(.empty), failure: limitFailure(), now: now)
        XCTAssertEqual(limited?.reason, "usage_limit")
        XCTAssertEqual(limited?.source, "hook")
        XCTAssertEqual(limited?.detail, "five_hour")
        XCTAssertEqual(limited?.resetsAt, now.addingTimeInterval(3600))

        let api = FleetAgentState.blocked(journal: failed, wait: nil, look: nil, failure: nil, now: now)
        XCTAssertEqual(api?.reason, "api_error")
        XCTAssertEqual(api?.source, "journal")
        let transcriptLimit = FleetAgentState.Journal(phase: .error, reason: .usageLimit, usageLimit: .monthlySpend)
        XCTAssertEqual(FleetAgentState.blocked(journal: transcriptLimit, wait: nil, look: nil, failure: nil, now: now)?.detail, "monthly_spend")
        // A finished turn after the failure is not blocked.
        XCTAssertNil(FleetAgentState.blocked(journal: .init(phase: .idle, turnOutcome: "completed"), wait: nil, look: nil,
                                             failure: limitFailure(), now: now))
    }

    func testPlanAlternatesPriorityPanelsWithTheWalk() {
        let ids = (0..<4).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let candidates = ids.map { FleetScreenMonitor.Candidate(workspaceId: UUID(), panelId: $0, kind: "claude-code") }
        let looks: [UUID: FleetScreenLook] = [ids[3]: look(.dialog, "resume", age: 5)]
        let plan = FleetScreenMonitor.plan(candidates, looks: looks, suspects: [ids[2]], after: nil, walkFirst: false)
        // Dialog, walk, suspect, walk: each panel once.
        XCTAssertEqual(plan.map(\.candidate.panelId), [ids[3], ids[0], ids[2], ids[1]])
        XCTAssertEqual(plan.map(\.walk), [false, true, false, true])
        // The walk resumes after the last panel it looked at.
        let resumed = FleetScreenMonitor.plan(candidates, looks: [:], after: ids[1], walkFirst: true)
        XCTAssertEqual(resumed.map(\.candidate.panelId), [ids[2], ids[3], ids[0], ids[1]])
    }

    /// Many persistent dialogs and a fleet of suspects (every seat after a
    /// restart) never starve the rest: each panel is looked at within
    /// 2·⌈N/L⌉ sweeps for L looks per sweep, including L = 1.
    func testPersistentDialogsCannotStarveTheWalk() {
        let ids = (0..<64).map { _ in UUID() }
        let candidates = ids.map { FleetScreenMonitor.Candidate(workspaceId: UUID(), panelId: $0, kind: "claude-code") }
        for (perSweep, dialogs) in [(5, 6), (5, 20), (1, 6), (2, 63)] {
            var looks: [UUID: FleetScreenLook] = [:]
            for id in ids.prefix(dialogs) { looks[id] = look(.dialog, "usage_limit", age: 1) }
            var cursor: UUID?
            var seen = Set<UUID>()
            let bound = 2 * Int((Double(ids.count) / Double(perSweep)).rounded(.up))
            for sweep in 0..<bound {
                let plan = FleetScreenMonitor.plan(candidates, looks: looks, suspects: Set(ids),
                                                   after: cursor, walkFirst: sweep % 2 == 1)
                let looked = Array(plan.prefix(perSweep))
                for planned in looked {
                    seen.insert(planned.candidate.panelId)
                    let id = planned.candidate.panelId
                    looks[id] = ids.prefix(dialogs).contains(id) ? look(.dialog, "usage_limit", age: 0) : look(.empty, age: 0)
                }
                cursor = FleetScreenMonitor.advance(cursor, looked: looked)
            }
            XCTAssertEqual(seen.count, ids.count, "\(perSweep) looks per sweep, \(dialogs) dialogs: \(ids.count - seen.count) never looked at")
        }
    }

    func testAnAgentKeepsItsFirstReportWhenItsShellBecomesAnAgent() {
        // Recorded in the guest: SessionStart reported, then the detector's
        // next scan turned the panel from shell to claude-code and wiped it.
        XCTAssertFalse(AgentDetector.endsAgentReports(from: "shell", to: "claude-code"))
        XCTAssertFalse(AgentDetector.endsAgentReports(from: nil, to: "claude-code"))
        XCTAssertTrue(AgentDetector.endsAgentReports(from: "claude-code", to: "shell"))
        XCTAssertTrue(AgentDetector.endsAgentReports(from: "claude-code", to: "codex"))
        XCTAssertFalse(AgentDetector.endsAgentReports(from: "claude-code", to: "claude-code"))
        // An editor or tool the agent opened holds the foreground for a moment.
        XCTAssertFalse(AgentDetector.endsAgentReports(from: "claude-code", to: "unknown"))
        XCTAssertFalse(AgentDetector.endsAgentReports(from: "unknown", to: "shell"))
    }

    func testAgentReportRunsOnTheSocketWorker() {
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "agent.report"), .socketWorker)
    }

    // MARK: - C11H-328: remote seats

    /// A terminal on another machine has no local TTY. It still reaches the
    /// fleet sweep (screen look, report retention, edges) and nothing looks
    /// up a model or process for it.
    func testARemotePanelJoinsTheFleetSweepWithNoLocalTerminal() {
        let workspace = UUID(), remote = UUID()
        // Two sweeps, so the first one's model step has run when the test reads.
        let swept = expectation(description: "two sweeps hand the fleet the remote panel")
        swept.expectedFulfillmentCount = 2
        swept.assertForOverFulfill = false
        let lock = NSLock()
        var modelSweeps = 0
        let detector = AgentDetector(scan: { _ in [:] }, sweepModels: { _, _ in
            lock.lock(); modelSweeps += 1; lock.unlock()
        }, sweepInterval: 0.05, fleetSweep: { sweep in
            guard sweep.candidates.contains(.init(workspaceId: workspace, panelId: remote, kind: "claude-code")),
                  sweep.livePanels.contains(remote) else { return }
            swept.fulfill()
        })
        detector.noteRemote(workspaceId: workspace, panelId: remote, kind: "claude-code")
        wait(for: [swept], timeout: 2)
        // No model lookup runs for a remote panel, not even an empty one.
        lock.lock(); XCTAssertEqual(modelSweeps, 0); lock.unlock()
        detector.unregister(workspaceId: workspace, panelId: remote)
    }

    /// Settles the detector's queue and a 0.05 s retire grace.
    private func settleDetector() {
        let settled = expectation(description: "the detector's queue and grace ran")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// A move slower than the grace retires the panel; noting it again in its
    /// new workspace takes its reports and looks again.
    func testARemotePanelNotedAgainAfterItsGraceReportsAgain() {
        let panel = UUID()
        let detector = AgentDetector(scan: { _ in [:] }, sweepModels: { _, _ in }, retireGrace: 0.05)
        let screen = PromptInputObservation(classification: .init(state: .empty, draftLength: nil),
                                            source: "active_screen", observedAtMs: nil)
        let first = UUID()
        detector.noteRemote(workspaceId: first, panelId: panel, kind: "claude-code")
        settleDetector()
        detector.unregister(workspaceId: first, panelId: panel)
        settleDetector()
        AgentReportStore.shared.record(.init(panelId: panel, event: .stop, lastMessage: "retired"), keepText: true)
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: panel))
        let moved = UUID()
        detector.noteRemote(workspaceId: moved, panelId: panel, kind: "claude-code")
        settleDetector()
        AgentReportStore.shared.record(.init(panelId: panel, event: .stop, lastMessage: "back"), keepText: true)
        FleetScreenMonitor.shared.record(screen, panelId: panel)
        XCTAssertEqual(AgentReportStore.shared.entry(forPanel: panel)?.lastMessage?.text, "back")
        XCTAssertNotNil(FleetScreenMonitor.shared.look(forPanel: panel))
        detector.unregister(workspaceId: moved, panelId: panel)
    }

    func testClosingARemotePanelRetiresItsReportAndAMoveKeepsIt() {
        let workspace = UUID(), newWorkspace = UUID(), closed = UUID(), moved = UUID()
        let detector = AgentDetector(scan: { _ in [:] }, sweepModels: { _, _ in }, retireGrace: 0.05)
        func settle() {
            let settled = expectation(description: "the detector's queue and grace ran")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
        }
        for id in [closed, moved] {
            detector.noteRemote(workspaceId: workspace, panelId: id, kind: "claude-code")
        }
        settle()
        for id in [closed, moved] {
            AgentReportStore.shared.record(.init(panelId: id, event: .stop, lastMessage: "kept"), keepText: true)
        }
        detector.unregister(workspaceId: workspace, panelId: closed)
        // A move leaves one workspace and is noted in the next within the grace.
        detector.unregister(workspaceId: workspace, panelId: moved)
        detector.noteRemote(workspaceId: newWorkspace, panelId: moved, kind: "claude-code")
        settle()
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: closed))
        AgentReportStore.shared.record(.init(panelId: closed, event: .stop, lastMessage: "late"), keepText: true)
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: closed))
        XCTAssertEqual(AgentReportStore.shared.entry(forPanel: moved)?.lastMessage?.text, "kept")
        // The agent leaving the remote terminal takes its report with it.
        detector.noteRemote(workspaceId: newWorkspace, panelId: moved, kind: "shell")
        settle()
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: moved))
        detector.unregister(workspaceId: newWorkspace, panelId: moved)
    }

    func testClosingTheLastPanelRetiresItsReportAndRefusesALateCapture() {
        let workspace = UUID(), panel = UUID(), moved = UUID(), newWorkspace = UUID()
        let detector = AgentDetector(scan: { _ in [:] }, sweepModels: { _, _ in }, retireGrace: 0.05)
        let screen = PromptInputObservation(classification: .init(state: .empty, draftLength: nil),
                                            source: "active_screen", observedAtMs: nil)
        for id in [panel, moved] {
            detector.registerTTY(workspaceId: workspace, panelId: id, ttyName: "ttys9\(id == panel ? 1 : 2)")
            AgentReportStore.shared.record(.init(panelId: id, event: .stop, lastMessage: "secret"), keepText: true)
            FleetScreenMonitor.shared.record(screen, panelId: id)
        }
        detector.unregister(workspaceId: workspace, panelId: panel)
        // A move unregisters and registers again within the grace: it keeps its report.
        detector.unregister(workspaceId: workspace, panelId: moved)
        detector.registerTTY(workspaceId: newWorkspace, panelId: moved, ttyName: "ttys92")
        let retired = expectation(description: "the closed panel's report and look are retired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { retired.fulfill() }
        wait(for: [retired], timeout: 2)
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: panel))
        XCTAssertNil(FleetScreenMonitor.shared.look(forPanel: panel))
        // A capture or hook that was in flight when it closed does not bring it back.
        FleetScreenMonitor.shared.record(screen, panelId: panel)
        AgentReportStore.shared.record(.init(panelId: panel, event: .stop, lastMessage: "late"), keepText: true)
        XCTAssertNil(FleetScreenMonitor.shared.look(forPanel: panel))
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: panel))
        XCTAssertEqual(AgentReportStore.shared.entry(forPanel: moved)?.lastMessage?.text, "secret")
        XCTAssertNotNil(FleetScreenMonitor.shared.look(forPanel: moved))
        detector.unregister(workspaceId: newWorkspace, panelId: moved)
    }

    func testSwitchingTextOffHidesAndScrubsKeptText() throws {
        let window = UUID(), workspace = UUID(), seat = UUID()
        let store = AgentReportStore()
        store.record(.init(panelId: seat, event: .stop, lastMessage: "Kept before the switch"), now: now, keepText: true)
        store.record(.init(panelId: seat, event: .stopFailure, failureCode: "rate_limit", limit: "five_hour",
                           failureText: "You've hit your 5-hour limit"), now: now, keepText: true)
        let snapshot = FleetSnapshot(capturedAt: now,
            metadata: .init(metadata: [workspace: [seat: [MetadataKey.terminalType: "claude-code"]]], sources: [:]),
            panels: [FleetSnapshot.Panel(windowId: window, workspaceId: workspace, workspaceTitle: "Ship",
                panelId: seat, panelTitle: "Seat", detectedKind: "claude-code", activity: nil,
                cold: false, unreadNotification: false, journalAttention: false, parentPanelId: nil,
                lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false, unreadMail: nil,
                lastSeenAt: nil, beingSeen: false, journal: .init(phase: .error, reason: .sessionFailure))],
            workspaceCount: 1, windowCount: 1, mainCopyDurationMs: 0)
        var sources = FleetSnapshot.ObservationSources()
        sources.report = { store.entry(forPanel: $0) }
        sources.look = { _ in nil }
        sources.wait = { _ in nil }
        sources.keepText = { false }
        let row = try XCTUnwrap((snapshot.document(observations: sources)["panels"] as? [[String: Any]])?.first)
        let message = try XCTUnwrap(row["last_message"] as? [String: Any])
        XCTAssertTrue(message["text"] is NSNull, "switched off: shown at once as no text")
        XCTAssertEqual(message["text_recorded"] as? Bool, false)
        XCTAssertEqual(message["chars"] as? Int, 22)
        XCTAssertTrue((row["last_turn_stop"] as? [String: Any])?["text"] is NSNull)

        // The switch itself drops kept text from memory, keeping the counts.
        let shared = UUID()
        AgentReportStore.shared.record(.init(panelId: shared, event: .stop, lastMessage: "Kept"), keepText: true)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: false))
        defer { EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true)) }
        XCTAssertNil(AgentReportStore.shared.entry(forPanel: shared)?.lastMessage?.text)
        XCTAssertEqual(AgentReportStore.shared.entry(forPanel: shared)?.lastMessage?.chars, 4)
        store.scrubText()
        XCTAssertNil(store.entry(forPanel: seat)?.failure?.text)
        XCTAssertEqual(store.entry(forPanel: seat)?.failure?.chars, 28)
    }

    func testLastTurnStopNamesHowTheTurnEnded() {
        XCTAssertEqual(FleetAgentState.lastTurnStop(journal: .init(phase: .idle, turnOutcome: "completed"), failure: nil)?.reason, "done")
        XCTAssertEqual(FleetAgentState.lastTurnStop(journal: .init(phase: .idle, turnOutcome: "interrupted"), failure: nil)?.reason, "interrupted")
        let limited = FleetAgentState.lastTurnStop(journal: .init(phase: .error, reason: .sessionFailure), failure: limitFailure())
        XCTAssertEqual(limited?.reason, "usage_limit")
        XCTAssertEqual(limited?.text, "You've hit your 5-hour limit")
        XCTAssertEqual(FleetAgentState.lastTurnStop(journal: .init(phase: .error, reason: .sessionFailure), failure: nil)?.reason, "api_error")
        XCTAssertNil(FleetAgentState.lastTurnStop(journal: .init(phase: .working), failure: limitFailure()))
        XCTAssertNil(FleetAgentState.lastTurnStop(journal: nil, failure: nil))
    }

    // MARK: - Fleet rows

    func testFleetRowsCarryBlockedAccountAndLastMessageAndNullWhenUnknown() throws {
        let window = UUID(), workspace = UUID(), seen = UUID(), quiet = UUID()
        func panel(_ id: UUID, journal: FleetAgentState.Journal?) -> FleetSnapshot.Panel {
            FleetSnapshot.Panel(windowId: window, workspaceId: workspace, workspaceTitle: "Ship",
                panelId: id, panelTitle: "Seat", detectedKind: "claude-code", activity: nil,
                cold: false, unreadNotification: false, journalAttention: false, parentPanelId: nil,
                lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false, unreadMail: nil,
                lastSeenAt: nil, beingSeen: false, journal: journal)
        }
        let snapshot = FleetSnapshot(capturedAt: now,
            metadata: .init(metadata: [workspace: [seen: [MetadataKey.terminalType: "claude-code"],
                                                   quiet: [MetadataKey.terminalType: "claude-code"]]], sources: [:]),
            panels: [panel(seen, journal: .init(phase: .error, reason: .sessionFailure)), panel(quiet, journal: nil)],
            workspaceCount: 1, windowCount: 1, mainCopyDurationMs: 0)
        let entry = AgentReportStore.Entry(
            account: "echo", accountSource: "claude_config_dir",
            lastMessage: .init(text: "Needs you: nothing.", chars: 19, at: now), failure: limitFailure(), updatedAt: now)
        var sources = FleetSnapshot.ObservationSources()
        sources.report = { $0 == seen ? entry : nil }
        sources.look = { [self] in $0 == seen ? look(.dialog, "usage_limit") : nil }
        sources.wait = { _ in nil }
        let rows = try XCTUnwrap(snapshot.document(observations: sources)["panels"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["panel_id"] as? String == seen.uuidString })
        let blocked = try XCTUnwrap(row["blocked"] as? [String: Any])
        XCTAssertEqual(blocked["reason"] as? String, "usage_limit")
        XCTAssertEqual(blocked["account"] as? String, "echo")
        XCTAssertNotNil(blocked["resets_at"] as? String)
        XCTAssertEqual(row["account"] as? String, "echo")
        XCTAssertEqual((row["last_message"] as? [String: Any])?["text"] as? String, "Needs you: nothing.")
        XCTAssertEqual((row["input"] as? [String: Any])?["dialog_kind"] as? String, "usage_limit")
        XCTAssertEqual((row["last_turn_stop"] as? [String: Any])?["reason"] as? String, "usage_limit")

        let other = try XCTUnwrap(rows.first { $0["panel_id"] as? String == quiet.uuidString })
        for key in ["blocked", "input", "account", "account_source", "last_message", "last_turn_stop"] {
            XCTAssertTrue(other[key] is NSNull, "\(key) is null when unknown")
        }
    }

    func testFleetDocumentStaysCheapAtSixtyFourAgents() {
        let window = UUID(), workspace = UUID()
        let ids = (0..<64).map { _ in UUID() }
        let panels = ids.map { id in
            FleetSnapshot.Panel(windowId: window, workspaceId: workspace, workspaceTitle: "Ship",
                panelId: id, panelTitle: "Seat", detectedKind: "claude-code", activity: nil,
                cold: false, unreadNotification: false, journalAttention: false, parentPanelId: nil,
                lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false, unreadMail: nil,
                lastSeenAt: nil, beingSeen: false, journal: .init(phase: .idle, turnOutcome: "completed"))
        }
        var metadata: [UUID: [String: Any]] = [:]
        for id in ids { metadata[id] = [MetadataKey.terminalType: "claude-code"] }
        let snapshot = FleetSnapshot(capturedAt: now, metadata: .init(metadata: [workspace: metadata], sources: [:]),
                                     panels: panels, workspaceCount: 1, windowCount: 1, mainCopyDurationMs: 0)
        let entry = AgentReportStore.Entry(account: "echo", accountSource: "env",
            lastMessage: .init(text: String(repeating: "x", count: 300), chars: 300, at: now), failure: nil, updatedAt: now)
        var sources = FleetSnapshot.ObservationSources()
        sources.report = { _ in entry }
        sources.look = { [self] _ in look(.empty) }
        sources.wait = { _ in nil }
        let started = Date()
        for _ in 0..<10 { _ = snapshot.document(observations: sources) }
        let perCallMs = Date().timeIntervalSince(started) * 100
        XCTAssertLessThan(perCallMs, 50, "64 agent rows take \(perCallMs) ms per document")
    }

    // MARK: - PR 2: grouping, filters, deltas

    private func agentPanel(_ id: UUID, workspace: UUID, journal: FleetAgentState.Journal? = .init(phase: .idle, turnOutcome: "completed"),
                            parent: UUID? = nil, group: (UUID, String)? = nil, captain: String? = nil) -> FleetSnapshot.Panel {
        let panel = FleetSnapshot.Panel(windowId: window, workspaceId: workspace, workspaceTitle: "Ship",
            panelId: id, panelTitle: "Seat", detectedKind: "claude-code", activity: nil,
            cold: false, unreadNotification: false, journalAttention: false, parentPanelId: parent,
            lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false, unreadMail: nil,
            lastSeenAt: nil, beingSeen: false, journal: journal)
        refs[id] = "panel:\(id.uuidString.prefix(4))"
        if group != nil || captain != nil || facts[workspace] == nil {
            facts[workspace] = .init(ref: "workspace:\(workspace.uuidString.prefix(4))", groupId: group?.0, groupName: group?.1,
                                     captain: captain, captainPresent: captain != nil)
        }
        return panel
    }

    private func fleet(_ panels: [FleetSnapshot.Panel], flags: [UUID: String] = [:]) -> FleetSnapshot {
        var metadata: [UUID: [UUID: [String: Any]]] = [:]
        for panel in panels {
            var values: [String: Any] = [MetadataKey.terminalType: "claude-code"]
            if let flag = flags[panel.panelId] { values[MetadataKey.flag] = flag }
            metadata[panel.workspaceId, default: [:]][panel.panelId] = values
        }
        var snapshot = FleetSnapshot(capturedAt: now, metadata: .init(metadata: metadata, sources: [:]), panels: panels,
                                     workspaceCount: 2, windowCount: 1, mainCopyDurationMs: 0)
        snapshot.workspaceFacts = facts
        snapshot.panelRefs = refs
        return snapshot
    }

    private var quietSources: FleetSnapshot.ObservationSources {
        var sources = FleetSnapshot.ObservationSources()
        sources.report = { _ in nil }
        sources.look = { _ in nil }
        sources.wait = { _ in nil }
        sources.sweep = { nil }
        sources.stall = { _ in nil }
        sources.turnStartedMs = { _ in nil }
        sources.stallThreshold = { 600 }
        sources.contextWindow = { _ in nil }
        sources.transcriptModel = { _ in nil }
        sources.catalogLimit = { _, _ in nil }
        sources.edges = { nil }
        return sources
    }

    private func rows(_ document: [String: Any]) -> [[String: Any]] { document["panels"] as? [[String: Any]] ?? [] }

    func testRowsCarryGroupCaptainAndRefs() throws {
        let ws = UUID(), seat = UUID(), group = UUID()
        let row = try XCTUnwrap(rows(fleet([agentPanel(seat, workspace: ws, group: (group, "The Raft"), captain: "raft-captain")])
            .document(observations: quietSources, delta: nil)).first)
        XCTAssertEqual(row["workspace_group_id"] as? String, group.uuidString)
        XCTAssertEqual(row["workspace_group_name"] as? String, "The Raft")
        XCTAssertEqual(row["workspace_captain"] as? String, "raft-captain")
        XCTAssertEqual(row["workspace_captain_present"] as? Bool, true)
        XCTAssertEqual(row["panel_ref"] as? String, "panel:\(seat.uuidString.prefix(4))")
        XCTAssertNotNil(row["workspace_ref"] as? String)
        let loose = try XCTUnwrap(rows(fleet([agentPanel(UUID(), workspace: UUID())]).document(observations: quietSources, delta: nil)).first)
        XCTAssertTrue(loose["workspace_group_id"] is NSNull)
        XCTAssertTrue(loose["workspace_captain"] is NSNull)
    }

    func testFleetQueryParsesItsFiltersAndRefusesBadOnes() {
        guard case .success(let query) = FleetQuery.parse(["workspace": "workspace:3", "group": "The Raft",
                                                          "lifecycle": ["idle", "waiting"], "flagged": true,
                                                          "blocked": false, "parent": "panel:12", "since": 41]) else {
            return XCTFail("valid filters refused")
        }
        XCTAssertEqual(query.lifecycles, ["idle", "waiting"])
        XCTAssertEqual(query.since, .seq(41))
        if case .success(let byTime) = FleetQuery.parse(["since": "2026-11-15T20:00:00Z"]) {
            XCTAssertEqual(byTime.since, .time(try! date("2026-11-15T20:00:00Z")))
        } else { XCTFail("ISO since refused") }
        for bad: [String: Any] in [["lifecycle": ["sleeping"]], ["flagged": "yes"], ["since": -1], ["since": "soon"],
                                    ["window": "window:1"], ["workspace": ""]] {
            if case .success = FleetQuery.parse(bad) { XCTFail("accepted \(bad)") }
        }
    }

    func testFiltersNarrowRowsAndAndTogether() throws {
        let shipA = UUID(), shipB = UUID(), raft = UUID(), captain = UUID()
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        let snapshot = fleet([
            agentPanel(a1, workspace: shipA, parent: captain, group: (raft, "The Raft")),
            agentPanel(a2, workspace: shipA, journal: .init(phase: .error, reason: .sessionFailure)),
            agentPanel(b1, workspace: shipB, parent: captain),
        ], flags: [a2: "needs a decision"])
        func ids(_ query: FleetQuery) -> Set<UUID> {
            var copy = snapshot
            copy.query = query
            return Set(rows(copy.document(observations: quietSources, delta: nil)).compactMap {
                ($0["panel_id"] as? String).flatMap(UUID.init(uuidString:))
            })
        }
        XCTAssertEqual(ids(FleetQuery(workspaceId: shipA)), [a1, a2])
        XCTAssertEqual(ids(FleetQuery(groupIds: [raft])), [a1, a2], "Ship A is in The Raft")
        XCTAssertEqual(ids(FleetQuery(groupIds: [UUID()])), [], "a live group with no agents is empty")
        XCTAssertEqual(ids(FleetQuery(flagged: true)), [a2])
        XCTAssertEqual(ids(FleetQuery(blocked: true)), [a2], "a failed turn is blocked (api_error)")
        XCTAssertEqual(ids(FleetQuery(blocked: false)), [a1, b1])
        XCTAssertEqual(ids(FleetQuery(parentId: captain)), [a1, b1])
        XCTAssertEqual(ids(FleetQuery(workspaceId: shipA, parentId: captain)), [a1], "filters AND together")
        XCTAssertEqual(ids(FleetQuery()), [a1, a2, b1])
    }

    func testDeltaSeesChangesNotClocks() {
        let tracker = FleetDeltaTracker(base: 0)
        let a = UUID(), b = UUID()
        func row(_ lifecycle: String, seen: String, age: Int) -> [String: Any] {
            ["lifecycle": lifecycle, "last_seen_at": seen, "input": ["state": "empty", "observed_at": seen],
             "mailbox_unread": ["count": 1, "oldest_age_seconds": age]]
        }
        let first = tracker.observe([a: row("idle", seen: "t1", age: 5), b: row("idle", seen: "t1", age: 5)], now: now)
        XCTAssertEqual(first.seq, 1)
        let clocks = tracker.observe([a: row("idle", seen: "t2", age: 65), b: row("idle", seen: "t2", age: 65)],
                                     now: now.addingTimeInterval(60))
        XCTAssertEqual(clocks.seq, 1, "clocks alone are not a change")
        let changed = tracker.observe([a: row("idle", seen: "t3", age: 70), b: row("waiting", seen: "t3", age: 70)],
                                      now: now.addingTimeInterval(70))
        XCTAssertEqual(changed.seq, 2)
        XCTAssertEqual(changed.changes[a]?.seq, 1)
        XCTAssertEqual(changed.changes[b]?.seq, 2)
        let removed = tracker.observe([b: row("waiting", seen: "t4", age: 80)], now: now.addingTimeInterval(80))
        XCTAssertEqual(removed.seq, 3)
        XCTAssertEqual(removed.removed.map(\.panelId), [a])
        // a's agent comes back in the same panel: a row again, no longer a removal.
        let back = tracker.observe([a: row("idle", seen: "t5", age: 0), b: row("waiting", seen: "t5", age: 0)],
                                   now: now.addingTimeInterval(90))
        XCTAssertEqual(back.changes[a]?.seq, 4)
        XCTAssertTrue(back.removed.isEmpty)
    }

    func testSinceReturnsOnlyChangedRowsAndRemovals() throws {
        let ws = UUID(), a = UUID(), b = UUID()
        let tracker = FleetDeltaTracker(base: 0)
        var snapshot = fleet([agentPanel(a, workspace: ws), agentPanel(b, workspace: ws)])
        let start = snapshot.document(observations: quietSources, delta: tracker)
        let seq = try XCTUnwrap(start["fleet_seq"] as? Int)
        XCTAssertEqual(rows(start).count, 2)
        // b's turn fails; a is gone.
        snapshot = fleet([agentPanel(b, workspace: ws, journal: .init(phase: .error, reason: .sessionFailure))])
        snapshot.query.since = .seq(seq)
        let delta = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertEqual(rows(delta).map { $0["panel_id"] as? String }, [b.uuidString])
        XCTAssertEqual(delta["removed_panel_ids"] as? [String], [a.uuidString])
        XCTAssertEqual(delta["full"] as? Bool, false)
        // Nothing changed since: no rows.
        snapshot.query.since = .seq(try XCTUnwrap(delta["fleet_seq"] as? Int))
        XCTAssertTrue(rows(snapshot.document(observations: quietSources, delta: tracker)).isEmpty)
        // A cursor this run never handed out (above fleet_seq) gets everything.
        snapshot.query.since = .seq(10_000)
        let ahead = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertEqual(ahead["full"] as? Bool, true)
        XCTAssertEqual(rows(ahead).count, 1)
    }

    /// A watcher reading one ship, or only blocked seats, with `--since` must
    /// learn when a row leaves that set, or it keeps it forever.
    func testAFilteredDeltaListsRowsThatLeftTheFilters() throws {
        let shipA = UUID(), shipB = UUID(), seat = UUID(), other = UUID()
        let tracker = FleetDeltaTracker(base: 0)
        let failed = FleetAgentState.Journal(phase: .error, reason: .sessionFailure)
        var snapshot = fleet([agentPanel(seat, workspace: shipA, journal: failed), agentPanel(other, workspace: shipA)])
        snapshot.query = FleetQuery(blocked: true)
        let first = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertEqual(rows(first).map { $0["panel_id"] as? String }, [seat.uuidString])
        // The seat's failed turn is over: it is no longer blocked.
        snapshot = fleet([agentPanel(seat, workspace: shipA), agentPanel(other, workspace: shipA)])
        snapshot.query = FleetQuery(blocked: true, since: .seq(try XCTUnwrap(first["fleet_seq"] as? Int)))
        let cleared = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertTrue(rows(cleared).isEmpty)
        XCTAssertEqual(cleared["removed_panel_ids"] as? [String], [seat.uuidString])
        XCTAssertEqual(cleared["full"] as? Bool, false)

        // The operator moves the seat to Ship B while a watcher reads Ship A.
        snapshot.query = FleetQuery(workspaceId: shipA)
        let ship = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertEqual(Set(rows(ship).compactMap { $0["panel_id"] as? String }), [seat.uuidString, other.uuidString])
        snapshot = fleet([agentPanel(seat, workspace: shipB), agentPanel(other, workspace: shipA)])
        snapshot.query = FleetQuery(since: .seq(try XCTUnwrap(ship["fleet_seq"] as? Int)), workspaceId: shipA)
        let moved = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertTrue(rows(moved).isEmpty)
        XCTAssertEqual(moved["removed_panel_ids"] as? [String], [seat.uuidString])
        // Without filters nothing leaves: the moved seat is a changed row.
        snapshot.query = FleetQuery(since: .seq(try XCTUnwrap(ship["fleet_seq"] as? Int)))
        let unfiltered = snapshot.document(observations: quietSources, delta: tracker)
        XCTAssertEqual(rows(unfiltered).map { $0["panel_id"] as? String }, [seat.uuidString])
        XCTAssertEqual(unfiltered["removed_panel_ids"] as? [String], [])
    }

    /// A heartbeat's cursor from before c11 restarted must never read as a
    /// delta of the new run, however far the new run has counted.
    func testACursorFromAnEarlierRunReadsEveryRow() throws {
        let ws = UUID(), a = UUID(), b = UUID(), c = UUID()
        let earlier = FleetDeltaTracker(base: 1_000_000)
        var snapshot = fleet([agentPanel(a, workspace: ws), agentPanel(b, workspace: ws)])
        _ = snapshot.document(observations: quietSources, delta: earlier)
        snapshot = fleet([agentPanel(a, workspace: ws), agentPanel(b, workspace: ws, journal: .init(phase: .error, reason: .sessionFailure))])
        let cursor = try XCTUnwrap(snapshot.document(observations: quietSources, delta: earlier)["fleet_seq"] as? Int)

        // c11 restarts; a closed across it, c joined, and other readers moved the new run on.
        let later = FleetDeltaTracker(base: 1_000_000 + 60_000)
        for flag in ["needs a look", "needs a decision"] {
            snapshot = fleet([agentPanel(b, workspace: ws), agentPanel(c, workspace: ws)], flags: [c: flag])
            _ = snapshot.document(observations: quietSources, delta: later)
        }
        snapshot.query.since = .seq(cursor)
        let read = snapshot.document(observations: quietSources, delta: later)
        XCTAssertGreaterThan(try XCTUnwrap(read["fleet_seq"] as? Int), cursor)
        XCTAssertEqual(read["full"] as? Bool, true, "a removal across the restart is unknowable")
        XCTAssertEqual(Set(rows(read).compactMap { $0["panel_id"] as? String }), [b.uuidString, c.uuidString])
        XCTAssertEqual(read["removed_panel_ids"] as? [String], [])

        // A time before this run's first read is just as unanswerable; one after it is a delta.
        snapshot.query.since = .time(now.addingTimeInterval(-60))
        XCTAssertEqual(snapshot.document(observations: quietSources, delta: later)["full"] as? Bool, true)
        snapshot.query.since = .time(now)
        let byTime = snapshot.document(observations: quietSources, delta: later)
        XCTAssertEqual(byTime["full"] as? Bool, false)
        XCTAssertTrue(rows(byTime).isEmpty)
        // A time after this read (a skewed clock) cannot be answered either.
        snapshot.query.since = .time(now.addingTimeInterval(3600))
        XCTAssertEqual(snapshot.document(observations: quietSources, delta: later)["full"] as? Bool, true)
    }

    /// Removals are kept up to a bound; a cursor older than the newest one
    /// dropped could miss it, so it reads every row.
    func testACursorOlderThanTheRemovalsKeptReadsEveryRow() {
        let tracker = FleetDeltaTracker(base: 0)
        let first = tracker.observe([UUID(): ["lifecycle": "idle"]], now: now)
        var last = first
        for step in 0...FleetDeltaTracker.removedCapacity {
            last = tracker.observe([UUID(): ["lifecycle": "idle"]], now: now.addingTimeInterval(Double(step + 1)))
        }
        XCTAssertEqual(last.removed.count, FleetDeltaTracker.removedCapacity)
        XCTAssertTrue(last.isFull(.seq(first.seq)), "the first removal was dropped")
        XCTAssertFalse(last.isFull(.seq(last.seq - 1)))
        XCTAssertTrue(last.isFull(.time(now)))
    }

    /// After a restore most seats are headless, read from hc's paint a few
    /// per sweep. A walked headless seat past those reads holds the walk, so
    /// the walk starts there next sweep instead of skipping it.
    func testHeadlessSeatsPastTheSweepsReadsHoldTheWalk() {
        let ids = (0..<40).map { _ in UUID() }
        let candidates = ids.map { FleetScreenMonitor.Candidate(workspaceId: UUID(), panelId: $0, kind: "claude-code") }
        let room = FleetScreenMonitor.headlessReadsPerSweep
        for suspects in [Set<UUID>(), Set(ids.prefix(20))] {
            var looks: [UUID: FleetScreenLook] = [:]
            var cursor: UUID?
            var read = Set<UUID>()
            let bound = 2 * Int((Double(ids.count) / Double(room)).rounded(.up))
            for sweep in 0..<bound {
                // Headless lookups cost main almost nothing: one hop takes the whole plan.
                let plan = FleetScreenMonitor.plan(candidates, looks: looks, suspects: suspects,
                                                   after: cursor, walkFirst: sweep % 2 == 1)
                let reads = plan.prefix(room).map(\.candidate.panelId)
                for id in reads {
                    read.insert(id)
                    looks[id] = look(.empty, age: Double(-sweep))
                }
                let waiting = Set(plan.dropFirst(room).map(\.candidate.panelId))
                cursor = FleetScreenMonitor.advance(cursor, looked: plan, waiting: waiting)
            }
            XCTAssertEqual(read.count, ids.count, "\(suspects.count) suspects: \(ids.count - read.count) headless seats never read")
        }
    }

    func testTheDeltaTrackerKeepsNoRowText() {
        let secret = "Needs you: the deploy key is in the vault"
        let print = FleetDeltaTracker.fingerprint(["last_message": ["text": secret], "flag_reason": secret])
        XCTAssertEqual(print.count, 32)
        XCTAssertNil(print.range(of: Data("deploy".utf8)))
        XCTAssertNotEqual(print, FleetDeltaTracker.fingerprint(["last_message": ["text": secret + "."], "flag_reason": secret]))
    }

    func testAFingerprintNeverTrapsOnAValueJSONCannotHold() {
        let print = FleetDeltaTracker.fingerprint(["panel_title": "Seat", "score": Double.nan])
        XCTAssertEqual(print.count, 32)
        XCTAssertEqual(print, FleetDeltaTracker.fingerprint(["panel_title": "Seat", "score": Double.nan]))
    }

    func testATitlesStatusGlyphIsNotAChange() {
        let thinking = FleetDeltaTracker.fingerprint(["panel_title": "\u{2802} Fix the parser"])
        XCTAssertEqual(thinking, FleetDeltaTracker.fingerprint(["panel_title": "\u{2810} Fix the parser"]))
        XCTAssertEqual(thinking, FleetDeltaTracker.fingerprint(["panel_title": "\u{2733} Fix the parser"]))
        XCTAssertNotEqual(thinking, FleetDeltaTracker.fingerprint(["panel_title": "\u{2733} Fix the lexer"]))
    }

    func testTheFirstFleetReadAfterAQuietSpellStartsASweep() {
        // The queued sweeps really start (each reaches the monitor queue).
        let monitor = FleetScreenMonitor()
        let candidates = [FleetScreenMonitor.Candidate(workspaceId: UUID(), panelId: UUID(), kind: "claude-code")]
        monitor.sweep(candidates)
        XCTAssertEqual(monitor.sweepRunsForTesting, 0, "no fleet read yet: the detector's sweep looks at nothing")
        XCTAssertTrue(monitor.noteFleetRead(now: Date()), "the first read starts a sweep at once")
        XCTAssertEqual(monitor.sweepRunsForTesting, 1)
        monitor.sweep(candidates)
        XCTAssertEqual(monitor.sweepRunsForTesting, 2, "while fleet is read, the detector's sweep runs")
        XCTAssertFalse(monitor.noteFleetRead(now: Date()))
        XCTAssertEqual(monitor.sweepRunsForTesting, 2, "a read inside the window starts nothing extra")

        // The window itself, on a fixed clock.
        let clocked = FleetScreenMonitor()
        XCTAssertFalse(clocked.sweepIsActive(now: now))
        XCTAssertTrue(clocked.noteFleetRead(now: now))
        XCTAssertFalse(clocked.noteFleetRead(now: now.addingTimeInterval(60)))
        XCTAssertTrue(clocked.sweepIsActive(now: now.addingTimeInterval(60 + 30 * 60)), "a 30-minute heartbeat keeps it on")
        let quiet = now.addingTimeInterval(60 + 46 * 60)
        XCTAssertFalse(clocked.sweepIsActive(now: quiet))
        XCTAssertTrue(clocked.noteFleetRead(now: quiet), "a read after a quiet spell starts one again")
        XCTAssertTrue(clocked.sweepIsActive(now: quiet))
    }

    func testFleetAdvertisesItsFiltersAsVersionThree() {
        let fleet = CapabilityFeatures.current.payload.first { $0["id"] as? String == CapabilityFeatures.ID.fleet.rawValue }
        XCTAssertEqual(fleet?["version"] as? Int, 3, "a client checks version 3 before passing stalled")
    }

    func testFilterRefsMustNameSomethingLiveOfTheirKind() {
        let ship = UUID(), closed = UUID(), captain = UUID(), raft = UUID(), empty = UUID(), twin = UUID()
        let handles = ["workspace:3": ship, "workspace:7": closed, "panel:12": captain, "workspace_group:1": raft]
        let groups = [(id: raft, name: "The Raft"), (id: empty, name: "Empty"), (id: twin, name: "the raft")]
        func resolved(_ query: FleetQuery) -> FleetQuery {
            var query = query
            // `v2ResolveHandleRef` folds old aliases (`surface:N`) onto their handle.
            TerminalController.resolveFleetRefs(&query, workspaces: [ship], groups: groups) {
                handles[LegacyWireAliases.canonicalHandle($0)]
            }
            return query
        }
        XCTAssertEqual(resolved(FleetQuery(workspace: "workspace:3")).workspaceId, ship)
        XCTAssertEqual(resolved(FleetQuery(workspace: ship.uuidString)).workspaceId, ship)
        XCTAssertEqual(resolved(FleetQuery(workspace: "workspace:7")).notFound, "No workspace workspace:7", "closed")
        XCTAssertEqual(resolved(FleetQuery(workspace: closed.uuidString)).notFound, "No workspace \(closed.uuidString)")
        XCTAssertEqual(resolved(FleetQuery(workspace: "workspace:99")).notFound, "No workspace workspace:99")
        XCTAssertEqual(resolved(FleetQuery(workspace: "panel:12")).notFound, "panel:12 is not a workspace")

        XCTAssertEqual(resolved(FleetQuery(group: "workspace_group:1")).groupIds, [raft])
        XCTAssertEqual(resolved(FleetQuery(group: raft.uuidString)).groupIds, [raft])
        XCTAssertEqual(resolved(FleetQuery(group: "THE RAFT")).groupIds, [raft, twin], "a shared name selects both")
        XCTAssertNil(resolved(FleetQuery(group: "Empty")).notFound, "a live group with no agents is a success")
        XCTAssertEqual(resolved(FleetQuery(group: "The Rafts")).notFound, "No workspace group The Rafts")
        XCTAssertEqual(resolved(FleetQuery(group: ship.uuidString)).notFound, "No workspace group \(ship.uuidString)")

        XCTAssertEqual(resolved(FleetQuery(parent: "panel:12")).parentId, captain)
        XCTAssertEqual(resolved(FleetQuery(parent: "surface:12")).parentId, captain)
        XCTAssertEqual(resolved(FleetQuery(parent: captain.uuidString)).parentId, captain)
        let gone = UUID()
        XCTAssertEqual(resolved(FleetQuery(parent: gone.uuidString)).parentId, gone, "a closed Captain still names its crew")
        XCTAssertEqual(resolved(FleetQuery(parent: "workspace:3")).notFound, "workspace:3 is not a panel")
        XCTAssertEqual(resolved(FleetQuery(parent: "panel:404")).notFound, "No panel panel:404")
        if case .success(let fractional) = FleetQuery.parse(["since": "2026-11-15T20:00:00.250Z"]) {
            XCTAssertEqual(fractional.since, .time(try! date("2026-11-15T20:00:00Z").addingTimeInterval(0.25)))
        } else { XCTFail("fractional ISO since refused") }
    }

    /// Claude's auto-continue banner, as each source hands its rows over: a
    /// surface keeping soft-wrap flags, hc's paint read directly, and hc's
    /// paint fed into a surface (restore, show, reattach), whose rows carry no
    /// flags. At 35 columns the warning wraps inside `resets` and the footer
    /// takes three rows; at 45 the warning fills its row exactly and the
    /// footer wraps at a space; at 70 it wraps mid-word; at 120 nothing wraps.
    private let bannerWarning = "  \u{26A0} Usage limit reached \u{00B7} limit resets 8:10am"
    private let bannerFooter = "    Continuing automatically at 8:10am \u{00B7} Esc to cancel \u{00B7} /usage-credits to continue now"

    /// `lines` cut at `width` as a terminal wraps them, with the rows a
    /// surface marks soft-wrapped (every row of a line but its last).
    private func wrapped(_ lines: [String], width: Int) -> (rows: [String], softWrapped: Set<Int>) {
        var rows: [String] = []
        var soft = Set<Int>()
        for line in lines {
            var rest = Substring(line)
            repeat {
                rows.append(String(rest.prefix(width)))
                rest = rest.dropFirst(width)
                if !rest.isEmpty { soft.insert(rows.count - 1) }
            } while !rest.isEmpty
        }
        return (rows, soft)
    }

    private func bannerRows(width: Int) -> (rows: [String], softWrapped: Set<Int>) {
        wrapped(["\u{23FA} Usage limit reached", "", bannerWarning, bannerFooter], width: width)
    }

    /// The reset time a limit screen prints, in this machine's zone (no zone is printed).
    private func assertResetsAtEightTen(_ bottom: PromptRegionRows?, _ message: String) {
        guard let bottom, let resets = PromptInputClassifier.claudeLimitResetsAt(bottom, now: Date()) else {
            return XCTFail("no reset time: \(message)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.component(.hour, from: resets), 8, message)
        XCTAssertEqual(calendar.component(.minute, from: resets), 10, message)
    }

    /// A native read of these rows: through `PromptRegionNativeImport`, wrap flags as given.
    private func nativeImport(_ region: PromptRegionSnapshot) -> PromptRegionSnapshot? {
        var native = ghostty_prompt_region_s()
        native.cursor_x = numericCast(region.cursorX)
        native.cursor_y = numericCast(region.cursorY)
        native.cursor_pending_wrap = region.cursorPendingWrap
        native.complete = region.complete
        native.row_count = numericCast(region.rows.count)
        native.cell_count = numericCast(region.cells.count)
        native.text_len = numericCast(region.text.count)
        let rows = region.rows.map { row -> ghostty_prompt_region_row_s in
            var out = ghostty_prompt_region_row_s()
            out.screen_y = numericCast(row.screenY)
            out.cell_start = numericCast(row.cellRange.lowerBound)
            out.cell_count = numericCast(row.cellRange.count)
            out.soft_wrap = row.softWrap
            out.wrap_continuation = row.wrapContinuation
            return out
        }
        let cells = region.cells.map { cell -> ghostty_prompt_region_cell_s in
            var out = ghostty_prompt_region_cell_s()
            out.text_offset = numericCast(cell.textOffset)
            out.text_len = numericCast(cell.textLength)
            out.faint = cell.faint
            return out
        }
        return PromptRegionNativeImport.snapshot(native: native, rows: rows, cells: cells,
                                                 text: region.text.map { CChar(bitPattern: $0) })
    }

    func testTheLimitBannerIsAUsageLimitFromEverySourceAtEveryWidth() throws {
        XCTAssertEqual(bannerWarning.count, 45)
        for width in [35, 45, 70, 120] {
            let (screen, soft) = bannerRows(width: width)
            let rule = String(repeating: "\u{2500}", count: width)
            // A surface with its soft-wrap flags.
            let surface = rows(screen, softWrapped: soft)
            XCTAssertEqual(PromptInputClassifier.claudeBlockingDialog(surface), .usageLimit, "surface, \(width) columns")
            assertResetsAtEightTen(surface, "surface, \(width) columns")
            XCTAssertNil(PromptInputClassifier.claudeBlockingDialog(rows(screen + [rule, "\u{276F}\u{00A0} ", rule],
                                                                         softWrapped: soft)),
                         "surface, \(width) columns, cleared")

            // hc's paint, read directly and fed into a surface.
            for cleared in [false, true] {
                // The banner ends at row 21; cleared, Claude's composer sits below it.
                var painted: [Int: String] = [:]
                let end = cleared ? 19 : 21
                for (offset, text) in screen.enumerated() { painted[end - screen.count + 1 + offset] = text }
                if cleared {
                    painted[22] = rule
                    painted[23] = "\u{276F}\u{00A0}"
                }
                let paint = HCPaintScreenTests.paint(painted, cursor: (23, 0), columns: width, rows: 24)
                let hc = try XCTUnwrap(HCPaintScreen.replay(paint.bytes, columns: width, rows: 24))
                XCTAssertTrue(hc.isComplete, hc.incompleteReason ?? "")
                let direct = try XCTUnwrap(hc.promptRegion(harness: "claude-code"))
                let imported = try XCTUnwrap(TerminalController.capturePromptInputRegion(harness: "claude-code", forSupervisor: false) {
                    hc.region($0).flatMap(self.nativeImport)
                })
                XCTAssertFalse(imported.screenBottom?.rows.contains(where: \.softWrap) ?? true, "a surface fed hc's paint has no wrap flags")
                for (source, region) in [("hc paint", direct), ("surface fed hc paint", imported)] {
                    let classification = PromptInputClassifier.classify(region, harness: "claude-code")
                    if cleared {
                        XCTAssertNotEqual(classification.state, .dialog, "\(source), \(width) columns, cleared")
                    } else {
                        XCTAssertEqual(classification.dialogKind, "usage_limit", "\(source), \(width) columns")
                        assertResetsAtEightTen(region.screenBottom, "\(source), \(width) columns")
                    }
                }
            }
        }
    }

    /// The rate-limit options menu on a 35-column panel read from hc's paint:
    /// its option rows wrap, and without wrap flags only the paint join keeps
    /// `Stop and wait for limit to reset` whole.
    func testTheLimitMenuOnANarrowPanelInHCPaintIsAUsageLimit() throws {
        let width = 35
        let screen = wrapped([String(repeating: "\u{2500}", count: width)] + Array(usageLimitMenuRows.dropFirst(4)), width: width).rows
        XCTAssertTrue(screen.contains("eset"), "the first option wraps inside its label")
        func classify(_ rows: [String], cleared: Bool) throws -> PromptInputClassification {
            var painted: [Int: String] = [:]
            let bottom = cleared ? 20 : 23
            for (offset, text) in rows.enumerated() { painted[bottom - rows.count + 1 + offset] = text }
            if cleared {
                painted[22] = String(repeating: "\u{2500}", count: width)
                painted[23] = "\u{276F}\u{00A0}"
            }
            let paint = HCPaintScreenTests.paint(painted, cursor: (cleared ? 23 : 0, 0), columns: width, rows: 24)
            let hc = try XCTUnwrap(HCPaintScreen.replay(paint.bytes, columns: width, rows: 24))
            XCTAssertTrue(hc.isComplete, hc.incompleteReason ?? "")
            return PromptInputClassifier.classify(try XCTUnwrap(hc.promptRegion(harness: "claude-code")), harness: "claude-code")
        }
        let menu = try classify(screen, cleared: false)
        XCTAssertEqual(menu.state, .dialog)
        XCTAssertEqual(menu.dialogKind, "usage_limit")
        XCTAssertNotEqual(try classify(screen, cleared: true).state, .dialog)
    }

    func testBackgroundTasksAreACountFromStop() throws {
        let panel = UUID()
        let store = AgentReportStore()
        if case .ok = TerminalController.agentReportResult(params: ["panel_id": panel.uuidString, "event": "stop", "background_tasks": 2],
                                                          store: store, now: now, keepText: true) {} else { XCTFail("refused") }
        XCTAssertEqual(store.entry(forPanel: panel)?.background?.count, 2)
        if case .ok = TerminalController.agentReportResult(params: ["panel_id": panel.uuidString, "event": "stop_failure", "background_tasks": 1],
                                                          store: store, now: now, keepText: true) { XCTFail("accepted on stop_failure") }
        var sources = quietSources
        sources.report = { store.entry(forPanel: $0) }
        let row = try XCTUnwrap(rows(fleet([agentPanel(panel, workspace: UUID())]).document(observations: sources, delta: nil)).first)
        XCTAssertEqual((row["background_tasks"] as? [String: Any])?["count"] as? Int, 2)
        // A later Stop without the list (an older Claude) leaves no stale count.
        if case .ok = TerminalController.agentReportResult(params: ["panel_id": panel.uuidString, "event": "stop"],
                                                          store: store, now: now, keepText: true) {} else { XCTFail("refused") }
        XCTAssertNil(store.entry(forPanel: panel)?.background)
    }

    /// Socket params arrive through `JSONSerialization`: every number and
    /// Boolean is an `NSNumber`, and 0 and 1 also cast to `Bool`.
    func testWireCountsAndCursorsAreWholeNumbersNotBooleans() throws {
        func wire(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let panel = UUID()
        for (raw, count) in [("0", 0), ("1", 1), ("2", 2)] {
            let store = AgentReportStore()
            let params = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop","last_message":"Done.","background_tasks":\#(raw)}"#)
            guard case .ok = TerminalController.agentReportResult(params: params, store: store, now: now, keepText: true) else {
                XCTFail("a Stop with \(raw) background tasks was refused"); continue
            }
            XCTAssertEqual(store.entry(forPanel: panel)?.background?.count, count)
            XCTAssertEqual(store.entry(forPanel: panel)?.lastMessage?.text, "Done.", "the whole report lands")
        }
        for raw in ["true", "false", "2.5", "-1", #""2""#] {
            let params = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop","background_tasks":\#(raw)}"#)
            if case .ok = TerminalController.agentReportResult(params: params, store: AgentReportStore(), now: now, keepText: true) {
                XCTFail("background_tasks \(raw) accepted")
            }
        }
        for (raw, seq) in [("0", 0), ("1", 1), ("1794785342365", 1_794_785_342_365)] {
            guard case .success(let query) = FleetQuery.parse(try wire(#"{"since":\#(raw)}"#)) else {
                XCTFail("since \(raw) refused"); continue
            }
            XCTAssertEqual(query.since, .seq(seq))
        }
        for raw in ["true", "2.5", "-1"] {
            if case .success = FleetQuery.parse(try wire(#"{"since":\#(raw)}"#)) { XCTFail("since \(raw) accepted") }
        }
        if case .success = FleetQuery.parse(try wire(#"{"flagged":1}"#)) { XCTFail("flagged 1 accepted as true") }
        guard case .success(let flagged) = FleetQuery.parse(try wire(#"{"flagged":true,"blocked":false}"#)) else {
            return XCTFail("JSON Booleans refused")
        }
        XCTAssertEqual(flagged.flagged, true)
        XCTAssertEqual(flagged.blocked, false)
    }

    func testDatesFormatOncePerInstant() {
        final class Counting: ISO8601DateFormatter, @unchecked Sendable {
            var calls = 0
            override func string(from date: Date) -> String { calls += 1; return super.string(from: date) }
        }
        let formatter = Counting()
        let dates = FleetDateText(formatter)
        for _ in 0..<64 { _ = dates.string(now) }
        _ = dates.value(now.addingTimeInterval(1))
        XCTAssertEqual(formatter.calls, 2)
    }

    func testSweepRunsOnlyWhileFleetIsRead() {
        XCTAssertFalse(FleetScreenMonitor.isActive(lastRead: nil, now: now))
        XCTAssertTrue(FleetScreenMonitor.isActive(lastRead: now.addingTimeInterval(-30 * 60), now: now), "a 30-minute heartbeat keeps it on")
        XCTAssertFalse(FleetScreenMonitor.isActive(lastRead: now.addingTimeInterval(-46 * 60), now: now))
    }

    func testStopHookReadsTheTranscriptAtMostOnce() {
        var reads = 0
        let hook = ClaudeStopTranscript.StopText.read(hookMessage: "Needs you: nothing.\n\nDone.", transcriptPath: "/t.jsonl") { _ in
            reads += 1; return nil
        }
        XCTAssertEqual(reads, 0, "Claude's own message needs no transcript read")
        XCTAssertEqual(hook.report, "Needs you: nothing. Done.")
        XCTAssertEqual(hook.notification, "Needs you: nothing. Done.")
        let older = ClaudeStopTranscript.StopText.read(hookMessage: nil, transcriptPath: "/t.jsonl") { _ in
            reads += 1
            return ClaudeStopTranscript.ReadResult(lastAssistantMessage: "short", bytesRead: 10, lastAssistantReport: "long")
        }
        XCTAssertEqual(reads, 1, "one read serves the notification and the report")
        XCTAssertEqual(older.notification, "short")
        XCTAssertEqual(older.report, "long")
    }

    // MARK: - Helpers

    // MARK: - PR 3: agent edges, stalls, context, restore

    func testAnnouncedWorkIsTheAgentsOwnNextStepNeverAWaitOrAReport() {
        func announced(_ message: String?, background: Int = 0, crons: Int = 0) -> String? {
            ClaudeAgentReport.announcedWork(message: message, backgroundTasks: background, sessionCrons: crons)
        }
        for message in ["Let me run the tests.",
                        "I've updated the file.\n\nNow I'll rebuild on the build host.",
                        "Built clean. Now running the suite:",
                        "**Next, let me check the log.**",
                        "- I\u{2019}ll push the branch next.",
                        "Moving on to the skill pages."] {
            XCTAssertEqual(announced(message), "next_step", message)
        }
        for message in ["Let me know if you want changes.", "I'll wait for your review.", "Should I merge it?",
                        "Done. PR #340 is open.", "Let me run the tests.\n\nNeeds you: nothing",
                        "**Needs you:** nothing\n\nI'll start PR 4 next.", "", "I'll be here."] {
            XCTAssertNil(announced(message), message)
        }
        XCTAssertEqual(announced("Done.", background: 2), "background_tasks")
        XCTAssertNil(announced("Needs you: nothing", background: 2), "a turn that reported waits on nobody")
        XCTAssertNil(announced("Let me run it.", crons: 1), "a scheduled wake is its own follow-up")
        XCTAssertNil(announced(nil))
    }

    func testAStopCarriesItsAnnouncementAsACodeOnly() throws {
        func wire(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let panel = UUID()
        let store = AgentReportStore()
        let stop = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop","announces_work":"next_step"}"#)
        guard case .ok = TerminalController.agentReportResult(params: stop, store: store, now: now, keepText: false) else {
            return XCTFail("a Stop announcing its next step was refused")
        }
        XCTAssertEqual(store.entry(forPanel: panel)?.stop, .init(at: now, announced: "next_step"))
        for raw in ["true", "1", "0", #""later""#] {
            let params = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop","announces_work":\#(raw)}"#)
            if case .ok = TerminalController.agentReportResult(params: params, store: AgentReportStore(), now: now, keepText: true) {
                XCTFail("announces_work \(raw) accepted")
            }
        }
        let onFailure = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop_failure","announces_work":"next_step"}"#)
        if case .ok = TerminalController.agentReportResult(params: onFailure, store: AgentReportStore(), now: now, keepText: true) {
            XCTFail("announces_work on a StopFailure accepted")
        }
        // A turn start ends the mark: the announced work was followed.
        let turn = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"turn_start"}"#)
        guard case .ok = TerminalController.agentReportResult(params: turn, store: store, now: now.addingTimeInterval(30), keepText: true) else {
            return XCTFail("turn_start was refused")
        }
        XCTAssertNil(store.entry(forPanel: panel)?.stop)
        // A plain Stop replaces the mark; a failed turn ends it.
        let plain = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop"}"#)
        _ = TerminalController.agentReportResult(params: plain, store: store, now: now.addingTimeInterval(60), keepText: true)
        XCTAssertEqual(store.entry(forPanel: panel)?.stop, .init(at: now.addingTimeInterval(60), announced: nil))
        _ = TerminalController.agentReportResult(params: stop, store: store, now: now.addingTimeInterval(90), keepText: true)
        let failure = try wire(#"{"panel_id":"\#(panel.uuidString)","event":"stop_failure","failure_code":"server_error"}"#)
        _ = TerminalController.agentReportResult(params: failure, store: store, now: now.addingTimeInterval(120), keepText: true)
        XCTAssertNil(store.entry(forPanel: panel)?.stop)
        XCTAssertNotNil(store.entry(forPanel: panel)?.failure)
        _ = TerminalController.agentReportResult(params: turn, store: store, now: now.addingTimeInterval(150), keepText: true)
        XCTAssertNil(store.entry(forPanel: panel)?.failure, "a new turn ends the failed one")
    }

    func testAnAgentStallsOnNoProgressOrOnWorkItAnnouncedAndNeverStarted() {
        let threshold: TimeInterval = 600
        let idle = FleetAgentState.Journal(phase: .idle, turnOutcome: "completed")
        let stopAt = now.addingTimeInterval(-900)
        let stopMs = Int64(stopAt.timeIntervalSince1970 * 1000)
        let announced = AgentReportStore.StopMark(at: stopAt, announced: "next_step")
        func stalled(_ journal: FleetAgentState.Journal? = nil, supervisor: FleetAgentState.SupervisorStall? = nil,
                     stop: AgentReportStore.StopMark? = nil, started: Int64? = nil,
                     blocked: FleetAgentState.Blocked? = nil, at time: Date? = nil) -> FleetAgentState.Stalled? {
            FleetAgentState.stalled(journal: journal ?? idle, supervisor: supervisor, stop: stop ?? announced,
                                    turnStartedMs: started, blocked: blocked, now: time ?? now, threshold: threshold)
        }
        let late = stalled(started: stopMs - 60_000)
        XCTAssertEqual(late?.reason, "announced_work")
        XCTAssertEqual(late?.detail, "next_step")
        XCTAssertEqual(late?.since, stopAt.addingTimeInterval(threshold))
        XCTAssertEqual(late?.turnEndedAt, stopAt)
        XCTAssertNil(stalled(at: stopAt.addingTimeInterval(threshold - 1)), "not before the threshold")
        XCTAssertNil(stalled(started: stopMs + 1), "a turn that started after the Stop followed it")
        XCTAssertNil(stalled(FleetAgentState.Journal(phase: .working)), "a running turn is not a silent stop")
        XCTAssertEqual(stalled(FleetAgentState.Journal(phase: .idle, live: false))?.reason, "announced_work",
                       "the hook's own Stop counts without a live journal")
        XCTAssertNil(stalled(FleetAgentState.Journal(phase: .error)), "a failed turn is not a silent stop")
        XCTAssertNil(stalled(stop: AgentReportStore.StopMark(at: stopAt, announced: nil)), "a Stop that announced nothing")
        XCTAssertNil(stalled(blocked: .init(reason: "usage_limit", since: stopAt, source: "hook", detail: nil, resetsAt: nil)),
                     "a blocked agent is not also stalled")
        let quiet = stalled(FleetAgentState.Journal(phase: .working),
                            supervisor: .init(sinceMs: stopMs, lastProgressAtMs: stopMs - 600_000))
        XCTAssertEqual(quiet?.reason, "no_progress")
        XCTAssertEqual(quiet?.since, Date(timeIntervalSince1970: Double(stopMs) / 1000))
        XCTAssertEqual(FleetAgentState.SupervisorStall(readback: ["stalled": true, "stall_since_ms": NSNumber(value: stopMs)])?.sinceMs,
                       stopMs)
        XCTAssertNil(FleetAgentState.SupervisorStall(readback: ["stalled": false, "stall_since_ms": NSNumber(value: stopMs)]))
    }

    func testABlockIsAnnouncedOnceAndEndsOnlyOnEvidence() throws {
        let ws = UUID()
        var state: AgentEdgeState?
        func step(_ blocked: FleetAgentState.Blocked?, _ evidence: AgentEdges.Evidence = .init()) -> [AgentEdges.Edge] {
            let result = AgentEdges.step(prior: state, workspaceId: ws, agent: "claude-code", blocked: blocked,
                                         stalled: nil, evidence: evidence)
            state = result.state
            return result.edges
        }
        let resume = FleetAgentState.Blocked(reason: "resume_dialog", since: now, source: "screen", detail: nil, resetsAt: nil)
        var edges = step(resume, .init(blockedFromLook: true))
        XCTAssertEqual(edges.map(\.type), [.agentBlocked])
        XCTAssertEqual(edges.first?.payload["reason"] as? String, "resume_dialog")
        XCTAssertTrue(edges.first?.payload["previous_reason"] is NSNull)
        XCTAssertTrue(step(resume, .init(blockedFromLook: true)).isEmpty, "the same block is announced once")
        // The screen sweep paused, so the look went stale: that is not an answer.
        XCTAssertTrue(step(nil).isEmpty, "a stale look holds a block read from the screen")
        XCTAssertEqual(state?.blocked?.reason, "resume_dialog")
        edges = step(nil, .init(composerSeen: true))
        XCTAssertEqual(edges.map(\.type), [.agentUnblocked])
        XCTAssertEqual(edges.first?.payload["cleared_by"] as? String, "screen_cleared")
        XCTAssertNil(state?.blocked)

        let permission = FleetAgentState.Blocked(reason: "permission_prompt", since: now, source: "journal", detail: nil, resetsAt: nil)
        let resets = now.addingTimeInterval(3600)
        let limit = FleetAgentState.Blocked(reason: "usage_limit", since: now, source: "hook", detail: "five_hour", resetsAt: resets)
        XCTAssertEqual(step(permission).map(\.type), [.agentBlocked])
        edges = step(limit)
        XCTAssertEqual(edges.map(\.type), [.agentBlocked], "a new reason is a new block")
        XCTAssertEqual(edges.first?.payload["previous_reason"] as? String, "permission_prompt")
        XCTAssertEqual(edges.first?.payload["resets_at_ms"] as? Int64, Int64(resets.timeIntervalSince1970 * 1000))
        XCTAssertEqual(step(nil).first?.payload["cleared_by"] as? String, "cleared", "a hook's block ends when its source does")
        _ = step(limit)
        XCTAssertEqual(step(nil, .init(working: true)).first?.payload["cleared_by"] as? String, "turn_started")
        _ = step(limit)
        let gone = AgentEdges.gone(try XCTUnwrap(state))
        XCTAssertEqual(gone.map(\.type), [.agentUnblocked])
        XCTAssertEqual(gone.first?.payload["cleared_by"] as? String, "gone")
    }

    func testAStallIsAnnouncedAndEndsWithWhatEndedIt() {
        let ws = UUID()
        var state: AgentEdgeState?
        func step(_ stalled: FleetAgentState.Stalled?, blocked: FleetAgentState.Blocked? = nil,
                  _ evidence: AgentEdges.Evidence = .init()) -> [AgentEdges.Edge] {
            let result = AgentEdges.step(prior: state, workspaceId: ws, agent: "claude-code", blocked: blocked,
                                         stalled: stalled, evidence: evidence)
            state = result.state
            return result.edges
        }
        let quiet = FleetAgentState.Stalled(reason: "no_progress", since: now, detail: nil, thresholdSeconds: 600,
                                            lastProgressAt: now.addingTimeInterval(-600), turnEndedAt: nil)
        let announced = FleetAgentState.Stalled(reason: "announced_work", since: now, detail: "background_tasks",
                                                thresholdSeconds: 600, lastProgressAt: nil, turnEndedAt: now.addingTimeInterval(-600))
        var edges = step(quiet, .init(working: true))
        XCTAssertEqual(edges.map(\.type), [.agentStalled])
        XCTAssertEqual(edges.first?.payload["threshold_seconds"] as? Double, 600)
        XCTAssertTrue(step(quiet, .init(working: true)).isEmpty, "announced once")
        XCTAssertEqual(step(nil, .init(working: true)).first?.payload["cleared_by"] as? String, "progress")
        _ = step(quiet, .init(working: true))
        XCTAssertEqual(step(nil).first?.payload["cleared_by"] as? String, "turn_ended")
        edges = step(announced)
        XCTAssertEqual(edges.first?.payload["detail"] as? String, "background_tasks")
        XCTAssertEqual(step(nil).first?.payload["cleared_by"] as? String, "turn_started")
        _ = step(announced)
        let limit = FleetAgentState.Blocked(reason: "usage_limit", since: now, source: "hook", detail: nil, resetsAt: nil)
        edges = step(announced, blocked: limit)
        XCTAssertEqual(edges.map(\.type), [.agentBlocked, .agentUnstalled], "a block replaces the stall")
        XCTAssertEqual(edges.last?.payload["cleared_by"] as? String, "blocked")
    }

    func testTheEdgeMonitorReadsFleetsVerdictsAndEndsWhatWentAway() {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var edges: [(type: EventEnvelope.EventType, panel: UUID, reason: String?)] = []
        }
        let ws = UUID(), seat = UUID(), shell = UUID()
        let dialog = look(.dialog, "resume")
        var inputs = AgentEdgeMonitor.Inputs()
        inputs.journal = { _ in FleetAgentState.Journal(phase: .idle, turnOutcome: "completed") }
        inputs.readback = { _ in [:] }
        // The shell shows the same dialog: only an agent's verdict counts.
        inputs.look = { _ in dialog }
        inputs.report = { _ in nil }
        inputs.turnStartedMs = { _ in nil }
        inputs.threshold = { 600 }
        inputs.declaredKind = { _, _ in nil }
        let log = Log()
        let monitor = AgentEdgeMonitor(inputs: inputs) { type, _, panel, payload in
            log.lock.lock(); log.edges.append((type, panel, payload["reason"] as? String)); log.lock.unlock()
        }
        let candidate = FleetScreenMonitor.Candidate(workspaceId: ws, panelId: seat, kind: "claude-code")
        monitor.evaluate([candidate, .init(workspaceId: ws, panelId: shell, kind: "shell")], now: now)
        monitor.evaluate([candidate], now: now.addingTimeInterval(10))
        monitor.drainForTesting()
        XCTAssertEqual(log.edges.map(\.type), [.agentBlocked], "once, and a shell is no agent")
        XCTAssertEqual(log.edges.first?.panel, seat)
        XCTAssertEqual(log.edges.first?.reason, "resume_dialog")
        monitor.evaluate([], now: now.addingTimeInterval(20))
        monitor.drainForTesting()
        XCTAssertEqual(log.edges.map(\.type), [.agentBlocked, .agentUnblocked], "a closed panel ends its block")
        XCTAssertEqual(monitor.lastRunStats?.agents, 0)
    }

    /// The detector hands the monitor raw detected kinds, as its sweep does.
    private final class EdgeRig: @unchecked Sendable {
        let lock = NSLock()
        var edges: [(type: String, by: String?)] = []
        var declared: String?
        var look: FleetScreenLook?
        var report: AgentReportStore.Entry?
        var monitor: AgentEdgeMonitor!

        init(journal: FleetAgentState.Journal?) {
            var inputs = AgentEdgeMonitor.Inputs()
            inputs.journal = { _ in journal }
            inputs.readback = { _ in [:] }
            inputs.turnStartedMs = { _ in nil }
            inputs.threshold = { 600 }
            inputs.look = { [unowned self] _ in look }
            inputs.report = { [unowned self] _ in report }
            inputs.declaredKind = { [unowned self] _, _ in declared }
            monitor = AgentEdgeMonitor(inputs: inputs) { [unowned self] type, _, _, payload in
                lock.lock(); edges.append((type.rawValue, payload["cleared_by"] as? String)); lock.unlock()
            }
        }

        func run(_ kind: String, _ ws: UUID, _ panel: UUID, at now: Date) -> [String] {
            let before = edges.count
            monitor.evaluate([.init(workspaceId: ws, panelId: panel, kind: kind)], now: now)
            monitor.drainForTesting()
            return edges[before...].map { $0.type + ($0.by.map { ":" + $0 } ?? "") }
        }
    }

    func testAnEditorInTheForegroundIsNotGoneButAShellIs() {
        let ws = UUID(), seat = UUID()
        let rig = EdgeRig(journal: nil)
        rig.report = AgentReportStore.Entry(account: nil, accountSource: nil, lastMessage: nil, failure: limitFailure(), updatedAt: now)
        XCTAssertEqual(rig.run("claude-code", ws, seat, at: now), ["agent.blocked"])
        // Claude opened an editor: the foreground is unknown and nothing is declared.
        XCTAssertEqual(rig.run("unknown", ws, seat, at: now.addingTimeInterval(10)), [], "the agent has not left")
        XCTAssertEqual(rig.monitor.lastRunStats?.agents, 1, "its edge is held")
        // Declared as Claude, as fleet resolves it: still the same block.
        rig.declared = "claude-code"
        XCTAssertEqual(rig.run("unknown", ws, seat, at: now.addingTimeInterval(20)), [])
        XCTAssertEqual(rig.run("shell", ws, seat, at: now.addingTimeInterval(30)), ["agent.unblocked:gone"], "back at the shell, it is gone")

        // A declared seat is still evaluated while its editor is in front.
        let other = UUID()
        XCTAssertEqual(rig.run("claude-code", ws, other, at: now.addingTimeInterval(40)), ["agent.blocked"])
        rig.report = nil
        XCTAssertEqual(rig.run("unknown", ws, other, at: now.addingTimeInterval(50)), ["agent.unblocked:cleared"])
    }

    func testTheMonitorHoldsAScreenBlockThroughAStaleLookAndClearsOnAComposer() {
        let ws = UUID(), seat = UUID()
        let rig = EdgeRig(journal: FleetAgentState.Journal(phase: .idle, turnOutcome: "completed"))
        rig.look = look(.dialog, "resume")
        XCTAssertEqual(rig.run("claude-code", ws, seat, at: now), ["agent.blocked"])
        rig.look = look(.dialog, "resume", age: FleetScreenMonitor.freshness + 60)
        XCTAssertEqual(rig.run("claude-code", ws, seat, at: now), [], "a stale look is not an answer")
        rig.look = look(.unknown, age: 5)
        XCTAssertEqual(rig.run("claude-code", ws, seat, at: now), [], "nor is an unreadable one")
        rig.look = look(.empty, age: 5)
        XCTAssertEqual(rig.run("claude-code", ws, seat, at: now), ["agent.unblocked:screen_cleared"])
    }

    func testAQuestionOrAWaitIsNeverAnnouncedWorkWhateverRunsInTheBackground() {
        func announced(_ message: String, background: Int) -> String? {
            ClaudeAgentReport.announcedWork(message: message, backgroundTasks: background, sessionCrons: 0)
        }
        for message in ["Should I merge it?", "I'll wait for your review.", "I'll wait for your review:",
                        "Let me know if you want changes.", "Waiting for your go-ahead.", "**I'll wait** for the Captain."] {
            for background in [0, 1, 3] { XCTAssertNil(announced(message, background: background), "\(message) with \(background)") }
        }
        XCTAssertEqual(announced("Started the long build.", background: 1), "background_tasks")
        XCTAssertEqual(announced("Now running the suite:", background: 0), "next_step")
        XCTAssertEqual(announced("Now running the suite:", background: 2), "background_tasks")
    }

    func testEventsTailFiltersIntersectAndRefuseWhatNamesNothing() throws {
        let ws = UUID(), other = UUID(), seat = UUID()
        func line(_ type: EventEnvelope.EventType, _ workspace: UUID, _ panel: UUID, seq: UInt64 = 1, at: Date? = nil) -> String {
            EventEnvelope(type: type, instance: "test", ts: at ?? now, workspace: workspace.uuidString, surface: panel.uuidString,
                          payload: ["agent": "claude-code"]).serialize(seq: seq)
        }
        func filter(_ values: [String]) throws -> EventEnvelope.TailFilter {
            switch EventEnvelope.TailFilter.parse(values) {
            case .success(let parsed): return parsed
            case .failure(let error): throw error
            }
        }
        let agent = try filter(["agent"])
        XCTAssertTrue(agent.matches(line: line(.agentBlocked, ws, seat)))
        XCTAssertTrue(agent.matches(line: line(.agentRestoreNeedsOperator, ws, seat)))
        XCTAssertFalse(agent.matches(line: line(.supervisorStalled, ws, seat)))
        // Every filter must pass: a set and an exact type narrow to that type.
        let stalls = try filter(["agent", "type=agent.stalled"])
        XCTAssertTrue(stalls.matches(line: line(.agentStalled, ws, seat)))
        XCTAssertFalse(stalls.matches(line: line(.agentBlocked, ws, seat)), "the exact type narrows the set")
        XCTAssertFalse(try filter(["agent", "supervisor"]).matches(line: line(.supervisorStalled, ws, seat)), "two sets intersect")
        let ship = try filter(["agent", "workspace=\(ws.uuidString.lowercased())"])
        XCTAssertTrue(ship.matches(line: line(.agentBlocked, ws, seat)))
        XCTAssertFalse(ship.matches(line: line(.agentBlocked, other, seat)), "another ship's edge")
        XCTAssertFalse(ship.matches(line: line(.surfaceClosed, ws, seat)), "a subject does not widen the types")
        XCTAssertFalse(try filter(["workspace=\(ws.uuidString)", "workspace=\(other.uuidString)"]).matches(line: line(.agentBlocked, ws, seat)),
                       "repeated subjects intersect")
        XCTAssertTrue(try filter(["panel=\(seat.uuidString)", "workspace=\(other.uuidString)"]).matches(line: line(.surfaceClosed, other, seat)))
        XCTAssertTrue(try filter(["type=surface.closed"]).matches(line: line(.surfaceClosed, ws, seat)), "v1 spellings still match")
        XCTAssertTrue(try filter(["panel.closed"]).matches(line: line(.surfaceClosed, ws, seat)), "a bare type, as before")
        XCTAssertTrue(try filter([]).matches(line: line(.flagRaised, ws, seat)))
        for bad in ["workspace=workspace:3", "panel=12", "agents", "type=", "kind=agent", "type=agent.staled", "agent.staled", "type=unknown"] {
            if case .success = EventEnvelope.TailFilter.parse([bad]) { XCTFail("--filter \(bad) accepted") }
        }
        // With --since: the seq floor and the time floor apply with the filters.
        let early = line(.agentStalled, ws, seat, seq: 2, at: now.addingTimeInterval(-600))
        let late = line(.agentStalled, ws, seat, seq: 9, at: now)
        let other9 = line(.agentBlocked, ws, seat, seq: 10, at: now)
        XCTAssertEqual([early, late, other9].filter { stalls.admits(line: $0, sinceSeq: 5) }, [late])
        XCTAssertEqual([early, late, other9].filter { stalls.admits(line: $0, sinceDate: now.addingTimeInterval(-60)) }, [late])
        XCTAssertEqual([early, late, other9].filter { ship.admits(line: $0, sinceSeq: 5) }, [late, other9])
    }


    func testStalledRowsFilterAndLeaveAFilteredDelta() throws {
        let ws = UUID(), seat = UUID(), calm = UUID()
        var filtered = fleet([agentPanel(seat, workspace: ws), agentPanel(calm, workspace: ws)])
        var stall: FleetAgentState.SupervisorStall? = .init(sinceMs: Int64(now.timeIntervalSince1970 * 1000) - 60_000)
        var sources = quietSources
        sources.stall = { $0 == seat ? stall : nil }
        let delta = FleetDeltaTracker(base: 0)
        var query = FleetQuery()
        query.stalled = true
        filtered.query = query
        let first = filtered.document(observations: sources, delta: delta)
        XCTAssertEqual(rows(first).map { $0["panel_id"] as? String }, [seat.uuidString])
        let row = try XCTUnwrap(rows(first).first)
        XCTAssertEqual((row["stalled"] as? [String: Any])?["reason"] as? String, "no_progress")
        let cursor = try XCTUnwrap(first["fleet_seq"] as? Int)
        stall = nil
        query.since = .seq(cursor)
        filtered.query = query
        let second = filtered.document(observations: sources, delta: delta)
        XCTAssertTrue(rows(second).isEmpty)
        XCTAssertEqual(second["removed_panel_ids"] as? [String], [seat.uuidString], "a row that stopped stalling leaves the filter")
        func wire(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        guard case .success(let parsed) = FleetQuery.parse(try wire(#"{"stalled":true}"#)) else { return XCTFail("stalled refused") }
        XCTAssertEqual(parsed.stalled, true)
        if case .success = FleetQuery.parse(try wire(#"{"stalled":1}"#)) { XCTFail("stalled 1 accepted as true") }
    }

    func testContextIsTheHarnessesOwnWindowForItsModelElseItsOwnCatalogRoute() throws {
        let ws = UUID(), reported = UUID(), codexOwn = UUID(), stale = UUID(), switched = UUID(), cataloged = UUID(), twin = UUID(),
            claude = UUID(), blank = UUID()
        let window_ = window
        let kinds: [UUID: String] = [codexOwn: "codex", cataloged: "codex", twin: "codex"]
        func panel(_ id: UUID, tokens: Int?, window: Int? = nil, reset: Date? = nil) -> FleetSnapshot.Panel {
            var cache = tokens.map { PromptCacheObservation(requestAt: now.addingTimeInterval(-300), basis: .ttl(300), promptTokens: $0) }
            cache?.contextWindow = window
            if let reset { cache?.reset = .modelSwitch; cache?.resetAt = reset }
            return FleetSnapshot.Panel(windowId: window_, workspaceId: ws, workspaceTitle: "Ship", panelId: id, panelTitle: "Seat",
                detectedKind: kinds[id] ?? "claude-code", activity: nil, cold: false, unreadNotification: false, journalAttention: false,
                parentPanelId: nil, lastTurnEndedMs: nil, promptCache: cache,
                promptCacheUnknown: false, unreadMail: nil, lastSeenAt: nil, beingSeen: false, journal: nil)
        }
        let models = [reported: "claude-opus-5-5", codexOwn: "gpt-5.6-sol", stale: "claude-opus-5-5", switched: "claude-opus-5-5",
                      cataloged: "gpt-5.6-sol", twin: "gpt-5.6-sol", claude: "claude-opus-5"]
        var metadata: [UUID: [String: Any]] = [:]
        for id in [reported, codexOwn, stale, switched, cataloged, twin, claude, blank] {
            var values: [String: Any] = [MetadataKey.terminalType: kinds[id] ?? "claude-code"]
            if let model = models[id] { values[MetadataKey.model] = model }
            metadata[id] = values
        }
        let snapshot = FleetSnapshot(capturedAt: now, metadata: .init(metadata: [ws: metadata], sources: [:]),
            panels: [panel(reported, tokens: 150_000), panel(codexOwn, tokens: 129_000, window: 258_000),
                     panel(stale, tokens: 90_000), panel(switched, tokens: 90_000, reset: now.addingTimeInterval(-60)),
                     panel(cataloged, tokens: 68_000), panel(twin, tokens: 136_000), panel(claude, tokens: 90_000),
                     panel(blank, tokens: nil)],
            workspaceCount: 1, windowCount: 1, mainCopyDurationMs: 0)
        let limits = FleetContextLimits(records: { ModelCatalogSnapshot.records }, stamp: { "snapshot" })
        var sources = quietSources
        sources.contextWindow = { id in
            switch id {
            case reported: return .init(tokens: 200_000, model: "claude-opus-5-5[1m]", epoch: 0, at: self.now.addingTimeInterval(-120))
            case codexOwn: return .init(tokens: 400_000, model: "gpt-5.6-sol", epoch: 0, at: self.now)
            case stale: return .init(tokens: 200_000, model: "claude-sonnet-5-5", epoch: 0, at: self.now.addingTimeInterval(-120))
            case switched: return .init(tokens: 200_000, model: "claude-opus-5-5", epoch: 0, at: self.now.addingTimeInterval(-120))
            case claude: return .init(tokens: 200_000, model: nil, epoch: nil, at: self.now.addingTimeInterval(-120))
            default: return nil
            }
        }
        // The transcript's model and epoch now: the switched seat changed model and back.
        sources.transcriptModel = { id in
            switch id {
            case reported, stale: return .init(model: "claude-opus-5-5", epoch: 0)
            case switched: return .init(model: "claude-opus-5-5", epoch: 2)
            default: return nil
            }
        }
        var lookups = 0
        sources.catalogLimit = { lookups += 1; return limits.limit(forModel: $0, agent: $1) }
        let document = snapshot.document(observations: sources, delta: nil)
        func context(_ id: UUID) -> [String: Any]? {
            rows(document).first { $0["panel_id"] as? String == id.uuidString }?["context"] as? [String: Any]
        }
        XCTAssertEqual(context(reported)?["limit"] as? Int, 200_000, "a window for this model, whatever its suffix")
        XCTAssertEqual(context(reported)?["limit_source"] as? String, "harness")
        XCTAssertEqual(context(reported)?["fraction"] as? Double, 0.75)
        XCTAssertEqual(context(codexOwn)?["limit"] as? Int, 258_000, "Codex's own rollout number comes first")
        XCTAssertEqual(context(codexOwn)?["fraction"] as? Double, 0.5)
        XCTAssertTrue(context(stale)?["limit"] is NSNull, "a window reported for another model is not this one's")
        XCTAssertTrue(context(switched)?["limit"] is NSNull, "a model change since the window ends it for good")
        XCTAssertEqual(context(cataloged)?["limit"] as? Int, 272_000)
        XCTAssertEqual(context(cataloged)?["limit_source"] as? String, "catalog")
        XCTAssertEqual(context(twin)?["fraction"] as? Double, 0.5)
        XCTAssertTrue(context(claude)?["limit"] is NSNull,
                      "a window bound to no model is unused; Claude Code publishes none; another harness's is not taken")
        XCTAssertEqual(context(claude)?["prompt_tokens"] as? Int, 90_000)
        XCTAssertNil(context(blank), "nothing known is null")
        XCTAssertEqual(lookups, 3, "one catalog lookup per harness and model per document (stale, switched, claude: one)")
    }


    func testCatalogWindowsComeOnlyFromTheRowsOwnHarnessAndRoute() {
        // The compiled catalog itself, through the records the builder reads.
        let limits = FleetContextLimits(records: { ModelCatalogSnapshot.records }, stamp: { "snapshot" })
        XCTAssertEqual(limits.limit(forModel: "gpt-5.6-sol", agent: "codex"), 272_000, "Codex's own list")
        XCTAssertNil(limits.limit(forModel: "claude-opus-5", agent: "claude-code"), "OpenRouter's listing is not Claude Code's")
        XCTAssertEqual(limits.limit(forModel: "openrouter/openai/gpt-5.6-sol", agent: "omp"), 1_100_000, "an exact route")
        XCTAssertNil(limits.limit(forModel: "gpt-5.6-sol", agent: "omp"), "a bare id over routes that disagree")
        XCTAssertEqual(limits.limit(forModel: "K3", agent: "kimi"), 1_048_576, "case does not matter")
        XCTAssertNil(limits.limit(forModel: "gpt-5.6", agent: "codex"), "no prefix match")
        let two = FleetContextLimits(records: {
            [RawCatalogRecord(harness: "pi", rawID: "acme/m1", contextWindow: 100_000),
             RawCatalogRecord(harness: "pi", rawID: "gateway/acme/m1", contextWindow: 100_000),
             RawCatalogRecord(harness: "pi", rawID: "acme/m2", contextWindow: 100_000),
             RawCatalogRecord(harness: "pi", rawID: "gateway/acme/m2", contextWindow: 400_000)]
        }, stamp: { "two" })
        XCTAssertEqual(two.limit(forModel: "m1", agent: "pi"), 100_000, "routes that agree")
        XCTAssertNil(two.limit(forModel: "m2", agent: "pi"), "routes that disagree")
        XCTAssertNil(two.limit(forModel: "m1", agent: "codex"), "another harness")
    }

    func testCodexsOwnContextWindowIsAWholeNumberAndEndsWithItsModel() throws {
        func window(_ raw: String) -> Int? {
            let line = #"{"timestamp":"2026-11-15T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":5},"total_token_usage":{"total_tokens":1005},"model_context_window":\#(raw)}}}"#
            return AgentModelProbe.parseLine(kind: "codex", line: Data(line.utf8)).promptCache?.contextWindow
        }
        XCTAssertNil(window("0"))
        XCTAssertEqual(window("1"), 1)
        XCTAssertEqual(window("2"), 2)
        XCTAssertEqual(window("258400"), 258_400)
        for raw in ["true", "false", "2.5", "-1", #""258400""#, "null", "1e12"] { XCTAssertNil(window(raw), raw) }
        var signals = TranscriptSignals()
        let usage = try XCTUnwrap(AgentModelProbe.parseLine(kind: "codex", line: Data(#"{"timestamp":"2026-11-15T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":5},"total_token_usage":{"total_tokens":1005},"model_context_window":258400}}}"#.utf8)).promptCache)
        signals.notePromptCache(usage)
        XCTAssertNil(signals.promptCache?.contextWindow, "no model named yet: the window is nobody's")
        signals.noteModel("gpt-5.6-sol")
        var named = usage
        named.at = usage.at?.addingTimeInterval(30)
        named.requestKey = "total:1500"
        signals.notePromptCache(named)
        XCTAssertEqual(signals.promptCache?.contextWindow, 258_400)
        var next = usage
        next.at = usage.at?.addingTimeInterval(60)
        next.requestKey = "total:2000"
        next.contextWindow = nil
        signals.notePromptCache(next)
        XCTAssertEqual(signals.promptCache?.contextWindow, 258_400, "a line without it keeps the model's window")
        signals.noteModel("gpt-5.3-codex-spark")
        XCTAssertNil(signals.promptCache?.contextWindow, "another model ends it")
        XCTAssertEqual(signals.modelEpoch, 1)
    }


    @MainActor
    func testASeatNeedingTheOperatorAfterARestoreIsAnnouncedOncePerEnd() throws {
        let progress = HCRestoreProgress()
        var announced: [(panel: UUID, payload: [String: Any])] = []
        progress.announce = { panel, _, status, carried in
            announced.append((panel, HCRestoreProgress.needsOperatorPayload(status, carried: carried)))
        }
        let seat = UUID(), ws = UUID()
        func end(_ phase: HCHostEndStatus.Phase, _ address: String = "t1") -> HCHostEndStatus {
            HCHostEndStatus(endedKey: HCTerminalKey(owningCoreID: "core", localAddress: address), cause: .restart(at: now),
                            phase: phase, conversation: ConversationRef(kind: "claude-code", id: "s1", placeholder: false,
                                                                        capturedVia: .wrapperClaim, state: .alive))
        }
        progress.update(panelID: seat, workspaceID: ws, status: end(.deciding))
        XCTAssertTrue(announced.isEmpty, "deciding needs nobody yet")
        progress.update(panelID: seat, workspaceID: ws, status: end(.notResumed(reason: "agent resume is off")), carried: true)
        progress.update(panelID: seat, workspaceID: ws, status: end(.failed(reason: "no fresh terminal")))
        XCTAssertEqual(announced.count, 1, "once per end")
        let payload = try XCTUnwrap(announced.first?.payload)
        XCTAssertEqual(payload["agent"] as? String, "claude-code")
        XCTAssertEqual(payload["phase"] as? String, "not_resumed")
        XCTAssertEqual(payload["offers_resume"] as? Bool, true)
        XCTAssertEqual(payload["carried"] as? Bool, true)
        XCTAssertEqual(payload["ended_at_ms"] as? Int64, Int64(now.timeIntervalSince1970 * 1000))
        progress.update(panelID: seat, workspaceID: ws, status: end(.resumed, "t2"))
        XCTAssertEqual(announced.count, 1, "a resumed seat needs nobody")
        progress.update(panelID: seat, workspaceID: ws, status: end(.notResumed(reason: "r"), "t3"))
        XCTAssertEqual(announced.count, 2, "a later end is its own")
        progress.remove(panelID: seat)
    }

    func testARestoredSeatShowsItsOutcomeAndOneThatDidNotComeBackKeepsItsRow() throws {
        let ws = UUID(), waiting = UUID(), back = UUID(), plain = UUID()
        func end(_ phase: HCHostEndStatus.Phase, conversation: Bool = true) -> HCHostEndStatus {
            HCHostEndStatus(endedKey: HCTerminalKey(owningCoreID: "core", localAddress: "t1"), cause: .restart(at: now),
                            phase: phase,
                            conversation: conversation ? ConversationRef(kind: "claude-code", id: "s1", placeholder: false,
                                                                         capturedVia: .wrapperClaim, state: .alive) : nil)
        }
        XCTAssertEqual(FleetSnapshot.Restore(end(.notResumed(reason: "agent resume is off"))).outcome, "needs_operator")
        XCTAssertEqual(FleetSnapshot.Restore(end(.failed(reason: "no fresh terminal"))).outcome, "needs_operator")
        XCTAssertEqual(FleetSnapshot.Restore(end(.queued)).outcome, "resuming")
        XCTAssertEqual(FleetSnapshot.Restore(end(.resumed)).outcome, "resumed")
        XCTAssertEqual(FleetSnapshot.Restore(end(.kept(reason: "an agent is running"))).outcome, "skipped")
        XCTAssertEqual(FleetSnapshot.Restore(end(.failed(reason: "x"), conversation: false)).outcome, "skipped")

        func shellPanel(_ id: UUID, _ restore: FleetSnapshot.Restore?) -> FleetSnapshot.Panel {
            var panel = FleetSnapshot.Panel(windowId: window, workspaceId: ws, workspaceTitle: "Ship",
                panelId: id, panelTitle: "Seat", detectedKind: "shell", activity: nil, cold: false, unreadNotification: false,
                journalAttention: false, parentPanelId: nil, lastTurnEndedMs: nil, promptCache: nil, promptCacheUnknown: false,
                unreadMail: nil, lastSeenAt: nil, beingSeen: false, journal: nil)
            panel.restore = restore
            return panel
        }
        var snapshot = fleet([shellPanel(waiting, .init(end(.notResumed(reason: "agent resume is off")))),
                              shellPanel(back, .init(end(.resumed))), shellPanel(plain, nil)])
        snapshot.restoreSummary = HCRestoreProgress.summary([end(.notResumed(reason: "r")), end(.resumed)])
        let document = snapshot.document(observations: quietSources, delta: nil)
        let shown = rows(document)
        XCTAssertEqual(shown.map { $0["panel_id"] as? String }, [waiting.uuidString], "only the seat still waiting keeps its row")
        let row = try XCTUnwrap(shown.first)
        XCTAssertEqual(row["agent_type"] as? String, "claude-code")
        let restore = try XCTUnwrap(row["restore"] as? [String: Any])
        XCTAssertEqual(restore["outcome"] as? String, "needs_operator")
        XCTAssertEqual(restore["state"] as? String, "skipped")
        XCTAssertEqual(restore["phase"] as? String, "not_resumed")
        XCTAssertEqual(restore["offers_resume"] as? Bool, true)
        XCTAssertEqual(restore["conversation_kind"] as? String, "claude-code")
        XCTAssertEqual(restore["cause"] as? String, "restart")
        let local = ISO8601DateFormatter()
        local.timeZone = .current
        XCTAssertEqual(restore["ended_at"] as? String, local.string(from: now), "the Mac's zone, as restore status writes it")
        let summary = try XCTUnwrap(document["restore_summary"] as? [String: Any])
        XCTAssertEqual(summary["need_you"] as? Int, 1)
        XCTAssertEqual(summary["resumed"] as? Int, 1)
        XCTAssertEqual(summary["finished"] as? Bool, true)
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func snapshot(_ texts: [String], cursorY: Int, cursorX: Int? = nil) -> PromptRegionSnapshot {
        let built = rows(texts)
        let cursorRow = texts.indices.contains(cursorY) ? texts[cursorY].unicodeScalars.count : 0
        return PromptRegionSnapshot(cursorX: cursorX ?? cursorRow, cursorY: cursorY, cursorPendingWrap: false,
                                    complete: true, rows: built.rows, cells: built.cells, text: built.text)
    }

    /// A screen whose cursor read sits on an unrelated, unclassifiable row and
    /// whose bottom window holds `bottom`.
    private func hiddenCursorScreen(bottom: [String]) -> PromptRegionSnapshot {
        var screen = snapshot(["Some transcript text"], cursorY: 0)
        screen.screenBottom = rows(bottom)
        return screen
    }

    private func rows(_ texts: [String], softWrapped: Set<Int> = []) -> PromptRegionRows {
        var bytes = Data()
        var cells: [PromptRegionCell] = []
        var rows: [PromptRegionRow] = []
        for (y, text) in texts.enumerated() {
            let start = cells.count
            for scalar in text.unicodeScalars {
                let encoded = Array(String(scalar).utf8)
                cells.append(PromptRegionCell(textOffset: bytes.count, textLength: encoded.count, faint: false))
                bytes.append(contentsOf: encoded)
            }
            rows.append(PromptRegionRow(screenY: y, cellRange: start..<cells.count, softWrap: softWrapped.contains(y),
                                        wrapContinuation: softWrapped.contains(y - 1)))
        }
        return PromptRegionRows(complete: true, rows: rows, cells: cells, text: bytes)
    }
}
