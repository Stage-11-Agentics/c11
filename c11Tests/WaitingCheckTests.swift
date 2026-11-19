import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-261: the waiting check's screen reader, Jev client and done indexes.
// The screens are a real idle Claude Code foot and variants of it, and Codex
// feet in the shape its TUI draws.
final class WaitingCheckTests: XCTestCase {
    private static let rule = String(repeating: "─", count: 72)

    private static let composer = [
        "",
        rule,
        "❯ ",
        rule,
        "  190k/$6.86   [opus-5.5 high]   60m ✗3   /Users/x/c11  ⎇ main ±5",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
    ]

    private static let codexComposer = [
        "",
        "› Implement {feature}",
        "",
        "  100% context left · ? for shortcuts",
    ]

    private static func screen(body: [String], foot: [String] = ["✻ Cooked for 2m 5s · done 11:36 AM"]) -> [String] {
        body + [""] + foot + composer
    }

    private static let report = [
        "⏺ I'm running the full c11LogicTests gate on Studio for C11H-260 (PR #274, head d8581f4e). I'll land it when it finishes.",
        "",
        "  - Review: the Codex re-review passed at 748aac93.",
        "  - Gate log: /tmp/gate-d8581f4e.log",
        "",
        "  Needs you: nothing.",
    ]

    private static let idle = screen(body: report)

    private func outcome(_ body: [String]) -> WaitingCheckVerdict.Outcome? {
        WaitingCheckScreen.convention(lines: Self.screen(body: body))?.outcome
    }

    // MARK: Strip, composer and latest message

    func testComposerBoxStatusLineAndBlankTailAreStripped() {
        let foot = WaitingCheckScreen.foot(lines: Self.idle + ["", "   "])
        XCTAssertTrue(foot.composerFound)
        XCTAssertEqual(foot.lines.last, "✻ Cooked for 2m 5s · done 11:36 AM")
        XCTAssertFalse(foot.lines.contains { $0.contains("bypass permissions") || $0.contains("190k/$6.86") })
        XCTAssertFalse(foot.lines.contains { $0.hasPrefix("❯") || $0.hasPrefix("───") })
    }

    func testLatestMessageRunsFromTheLastMarkerAndDropsTheTurnSummary() {
        let earlier = ["⏺ Bash(git status)", "  ⎿  clean", ""]
        let message = WaitingCheckScreen.latestMessage(lines: Self.screen(body: earlier + Self.report))
        XCTAssertEqual(message?.first, Self.report.first)
        XCTAssertEqual(message?.last, "  Needs you: nothing.")
        XCTAssertEqual(WaitingCheckScreen.lastMessageLine(lines: Self.idle), "Needs you: nothing.")
    }

    /// Fixed false done: a screen with no idle composer (an open permission
    /// dialog replaces it, or the read missed the foot) is never done.
    func testNoIdleComposerWithoutTheRulePairAroundThePrompt() {
        let dialog = Self.report + [
            "",
            "⏺ Bash(rm -rf build-remote/old)",
            "",
            Self.rule,
            " Bash command",
            "",
            "   rm -rf build-remote/old",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No, and tell Claude what to do differently (esc)",
        ]
        XCTAssertFalse(WaitingCheckScreen.hasIdleComposer(lines: dialog))
        XCTAssertTrue(WaitingCheckScreen.hasOpenChoicePrompt(lines: dialog))
        // A history echo of the prompt (`❯ text` with no rules) is not a composer.
        XCTAssertFalse(WaitingCheckScreen.hasIdleComposer(lines: Self.report + ["", "❯ fix the gate"]))
        XCTAssertTrue(WaitingCheckScreen.hasIdleComposer(lines: Self.idle))
        XCTAssertFalse(WaitingCheckScreen.hasOpenChoicePrompt(lines: Self.idle))
    }

    /// Fixed false done: Codex's approval box draws `›` choices, which are
    /// not its composer.
    func testCodexApprovalChoicesAreNotTheComposer() {
        let approval = [
            "• Running the gate on Studio now.",
            "",
            "  Needs you: nothing.",
            "",
            "  Would you like to run the following command?",
            "",
            "  $ ./scripts/remote-build.sh --tag c11-261 --mode test",
            "",
            "› 1. Yes, proceed",
            "  2. Yes, and don't ask again for this command",
            "  3. No, and tell Codex what to do differently",
        ]
        XCTAssertFalse(WaitingCheckScreen.hasIdleComposer(lines: approval))
        XCTAssertTrue(WaitingCheckScreen.hasOpenChoicePrompt(lines: approval))

        let idle = ["• Gate passed and PR #274 merged.", "", "  Needs you: nothing."] + Self.codexComposer
        XCTAssertTrue(WaitingCheckScreen.hasIdleComposer(lines: idle))
        XCTAssertFalse(WaitingCheckScreen.hasOpenChoicePrompt(lines: idle))
        XCTAssertEqual(WaitingCheckScreen.convention(lines: idle)?.outcome, .done)
    }

    // MARK: Convention

    func testNeedsYouNothingAsTheLastLineIsDone() {
        let verdict = WaitingCheckScreen.convention(lines: Self.idle)
        XCTAssertEqual(verdict?.outcome, .done)
        XCTAssertEqual(verdict?.quote, "Needs you: nothing.")
    }

    func testNeedsYouNothingAsTheFirstLineIsDone() {
        XCTAssertEqual(outcome(["⏺ Needs you: nothing.", "", "  The gate is running on Studio; PR #274 lands when it passes."]), .done)
        XCTAssertEqual(outcome(["⏺ **Needs you:** nothing yet", "", "  Working through the queue."]), .done)
        XCTAssertEqual(outcome(["• Needs you: none", "", "  Shipped."]), .done)
        XCTAssertEqual(outcome(["⏺ Merged.", "", "  - **Needs you:** nothing for now!"]), .done)
        XCTAssertEqual(outcome(["⏺ Merged.", "", "  Needs you: N/A"]), .done)
    }

    func testNeedsYouWithNumberedQuestionsIsWaiting() {
        let body = [
            "⏺ The fix is ready on c11-261.",
            "",
            "  Needs you:",
            "  1. Merge now, or wait for the hourly backstop? I recommend now.",
        ]
        let verdict = WaitingCheckScreen.convention(lines: Self.screen(body: body))
        XCTAssertEqual(verdict?.outcome, .waiting)
        XCTAssertEqual(verdict?.quote, "Needs you:")
        XCTAssertEqual(outcome(["⏺ Done.", "", "  **Needs you:** a go on the release."]), .waiting)
        XCTAssertEqual(outcome(["⏺ Done.", "", "  Needs you: now, a decision on 1."]), .waiting)
    }

    /// Fixed false done: only the closed set reads as done. C11H-276: a
    /// remainder that opens with a nothing-word and says more is undecided,
    /// so Jev reads it when a key is set and the turn stays in Waiting when
    /// none is; it never reads as done, and never goes straight to Waiting.
    func testOnlyTheClosedSetAfterNeedsYouIsDone() {
        XCTAssertNil(outcome(["⏺ PR #274 is up.", "", "  Needs you: nothing urgent, but review PR #274 when you can."]))
        XCTAssertNil(outcome(["⏺ PR #274 is up.", "", "  Needs you: no blockers; one decision below."]))
        XCTAssertNil(outcome(["⏺ Merged.", "", "  Needs you: nothing. Want me to also tag the release?"]))
        XCTAssertNil(outcome(["⏺ Merged.", "", "  Needs you: nothing right now"]))
    }

    /// C11H-276: the replies that lit Waiting in staging (2026-11-13) and the
    /// shapes seats write every day. Jev scored the first one needs_human 0.12.
    func testANothingRemainderThatSaysMoreGoesToJev() {
        XCTAssertNil(outcome(["⏺ Needs you: nothing, unless you want another run.", "", "  Gate passed on the build host."]))
        XCTAssertNil(outcome(["⏺ Merged #356.", "", "  Needs you: nothing, unless you want another run."]))
        XCTAssertNil(outcome(["⏺ Merged #356.", "", "  **Needs you:** nothing beyond the PR review when it lands."]))
        XCTAssertNil(outcome(["⏺ Shipped.", "", "  Needs you: none; panel can close."]))
        XCTAssertNil(outcome(["• Gate passed.", "", "  Needs you: no action needed."]))
        XCTAssertNil(outcome(["⏺ Done.", "", "  - Needs you: N/A (all merged)"]))
    }

    /// C11H-276: the exact-nothing fast path and plain asks are unchanged; a
    /// word that only starts like a nothing-word is an ask.
    func testExactNothingStaysDoneAndAsksStayWaiting() {
        XCTAssertEqual(outcome(["⏺ Merged #356.", "", "  Needs you: nothing."]), .done)
        XCTAssertEqual(outcome(["⏺ Merged #356.", "", "  Needs you: **None**"]), .done)
        XCTAssertEqual(outcome(["⏺ Done.", "", "  Needs you: now, a decision on 1."]), .waiting)
        XCTAssertEqual(outcome(["⏺ Done.", "", "  Needs you: nope, kidding: a go on the release."]), .waiting)
        XCTAssertEqual(outcome(["⏺ Done.", "", "  Needs you: notes on the draft by Friday."]), .waiting)
        XCTAssertEqual(outcome(["⏺ Done.", "", "  Needs you: a go on the release."]), .waiting)
        XCTAssertTrue(WaitingCheckScreen.startsWithNothingWord("**nothing**, unless"))
        XCTAssertTrue(WaitingCheckScreen.startsWithNothingWord("n/a (merged)"))
        XCTAssertFalse(WaitingCheckScreen.startsWithNothingWord("nothingness"))
        XCTAssertFalse(WaitingCheckScreen.startsWithNothingWord(""))
    }

    /// A question after `Needs you: nothing` leaves the reply undecided; a
    /// numbered item does only after a closing Needs line.
    func testAQuestionOrNumberedItemAfterNothingIsUndecided() {
        XCTAssertNil(outcome(["⏺ Needs you: nothing.", "", "  Gate passed. Want me to tag 1.8.1-h16 too?"]))
        XCTAssertNil(outcome(["⏺ Gate passed.", "", "  The log is at /tmp/gate.log.", "", "  Needs you: nothing.", "",
                              "  Open questions:", "  1. Keep the old flag or drop it"]))
        XCTAssertEqual(outcome(["⏺ Needs you: nothing.", "", "  Gate passed (why did it take 9 min? the cold cache)."]), .done)
    }

    /// The skill's report: `Needs you: nothing` first, then numbered changes.
    func testAnOpeningNeedsLineFollowedByNumberedChangesIsDone() {
        XCTAssertEqual(outcome([
            "⏺ Needs you: nothing.",
            "",
            "  1. Fixed the settle cap so an unsettled screen is never judged.",
            "  2. Codex approval choices no longer read as the composer.",
        ]), .done)
        XCTAssertEqual(outcome([
            "⏺ C11H-261 review fixes are in.",
            "",
            "  Needs you: nothing",
            "  1. markUnread drops every verdict in the workspace.",
        ]), .done)
        XCTAssertNil(outcome([
            "⏺ Needs you: nothing.",
            "",
            "  1. Landed the fix. Should I also cut 1.8.1-h16?",
        ]))
    }

    /// Fixed false done: a wrapped continuation after "nothing".
    func testAWrappedContinuationAfterNothingIsUndecided() {
        XCTAssertNil(outcome([
            "⏺ The release branch is ready.",
            "",
            "  Needs you: nothing",
            "  except approving the release in the Sparkle dashboard.",
        ]))
        XCTAssertNil(outcome(["⏺ Needs you: nothing", "  except the go on the merge.", "", "  Gate passed."]))
    }

    /// Fixed false done: a `Needs you: nothing` that is not the agent's own
    /// line (quoted, tool output, a box) does not decide.
    func testNeedsYouInsideQuotesToolOutputOrBoxesIsIgnored() {
        XCTAssertNil(outcome(["⏺ Read the brief.", "", "  > Needs you: nothing", "", "  Starting the build."]))
        XCTAssertNil(outcome(["⏺ Bash(grep -n 'Needs you' skills/c11/SKILL.md)", "  ⎿  Needs you: nothing"]))
        XCTAssertNil(outcome(["⏺ Here is the template:", "", "  ╭──────────────────────╮", "  │ Needs you: nothing   │", "  ╰──────────────────────╯"]))
        XCTAssertNil(outcome(["⏺ The convention:", "", "      Needs you: nothing"]))
    }

    func testAnEarlierMessagesConventionDoesNotDecideALaterMessage() {
        XCTAssertNil(outcome(Self.report + ["", "⏺ Now checking the gate log for the slow class."]))
        XCTAssertNil(outcome(["⏺ All four tickets merged."]))
    }

    /// A reply taller than a short panel has its marker scrolled off: the
    /// visible lines above the idle composer are the tail of that last block
    /// (C11H-261 sandbox proof, a 15-row panel).
    func testAMarkerScrolledOffLeavesTheVisibleTailAsTheLatestMessage() {
        let lines = ["11H-260 (PR #274, head d8581f4e). I'll land it when it finishes.", "",
                     "  - Gate log: /tmp/gate.log", "", "  Needs you: nothing.", ""] + Self.composer
        XCTAssertEqual(WaitingCheckScreen.latestBlock(lines: lines)?.hasMarker, false)
        XCTAssertEqual(WaitingCheckScreen.convention(lines: lines)?.outcome, .done)
        XCTAssertEqual(WaitingCheckScreen.conventionHarnesses, ["claude-code", "codex"])
        // Without the marker nothing is known to open the message, so a
        // numbered item after the Needs line leaves it undecided.
        let listed = ["  Needs you: nothing.", "  1. Merged #280."] + Self.composer
        XCTAssertNil(WaitingCheckScreen.convention(lines: listed))
        // A prompt echo with no reply after it is never a message.
        let prompt = ["> Needs you: nothing. Paste of an old report", ""] + Self.composer
        XCTAssertNil(WaitingCheckScreen.convention(lines: prompt))
        XCTAssertNil(WaitingCheckScreen.convention(lines: [""] + Self.composer))
    }

    /// After an opening Needs line only the first numbered run is the list
    /// of changes; a second run under a heading may be asks.
    func testASecondNumberedRunAfterAnOpeningNeedsLineIsUndecided() {
        XCTAssertEqual(outcome(["⏺ Needs you: nothing.", "", "  1. Merged #280.", "  2. Synced the skill."]), .done)
        XCTAssertNil(outcome(["⏺ Needs you: nothing.", "", "  Changes:", "  1. Merged #280.", "",
                              "  Decisions for you:", "  1. Pick A or B"]))
    }

    /// The operator's Mark as Unread is final: that notification is never
    /// judged done again, even by a judgment already in flight.
    func testOperatorMarkedUnreadIsNeverHidden() {
        WaitingCheckJudge.resetForTesting()
        defer { WaitingCheckJudge.resetForTesting() }
        let id = UUID()
        XCTAssertFalse(WaitingCheckJudge.isOperatorUnread(id))
        WaitingCheckJudge.operatorMarkedUnread([id], live: [id])
        XCTAssertTrue(WaitingCheckJudge.isOperatorUnread(id))
        // Pruned once its notification is gone.
        WaitingCheckJudge.operatorMarkedUnread([], live: [])
        XCTAssertFalse(WaitingCheckJudge.isOperatorUnread(id))
    }

    /// Fixed false done: a prompt the agent has not answered yet, or an
    /// interrupted turn, ends the latest message.
    func testAPromptEchoOrInterruptionAfterTheLastMessageEndsIt() {
        XCTAssertNil(WaitingCheckScreen.convention(lines: Self.screen(
            body: Self.report + ["", "> also bump the version and cut 1.8.1-h16"], foot: [])))
        XCTAssertNil(WaitingCheckScreen.convention(lines: Self.screen(
            body: Self.report + ["", "⏺ Bash(./scripts/remote-build.sh --tag c11-261)", "  ⎿  Interrupted · What should Claude do instead?"],
            foot: [])))
        let codex = ["• Needs you: nothing.", "", "› ship it", "", "■ Conversation interrupted - tell the model what to do differently"]
            + Self.codexComposer
        XCTAssertNil(WaitingCheckScreen.convention(lines: codex))
    }

    // MARK: Busy

    func testALiveTurnIsBusy() {
        let busy = Self.screen(body: Self.report + ["", "⏺ Running 1 shell command…"],
                               foot: ["✻ Reticulating… (15s · ↓ 1.2k tokens)"])
        XCTAssertTrue(WaitingCheckScreen.isBusy(lines: busy))
        XCTAssertTrue(WaitingCheckScreen.isBusy(lines: Self.screen(body: Self.report, foot: ["✶ Thinking…"])))
        XCTAssertTrue(WaitingCheckScreen.isBusy(lines: ["• Working (5s • esc to interrupt)", "", "› "]))
    }

    func testAFinishedTurnSummaryIsNotBusy() {
        XCTAssertFalse(WaitingCheckScreen.isBusy(lines: Self.idle))
    }

    // MARK: Jev payload

    func testWithheldTermsReplaceTheWholeLineAndTheScreenIsClipped() {
        let screen = WaitingCheckScreen.preparedScreen(
            lines: Self.idle, withheldTerms: ["GATE-D8581F4E", ""], maxCharacters: 3500)
        XCTAssertTrue(screen.contains(WaitingCheckScreen.withheldPlaceholder))
        XCTAssertFalse(screen.lowercased().contains("gate-d8581f4e"))
        XCTAssertFalse(screen.contains("bypass permissions"))
        let clipped = WaitingCheckScreen.preparedScreen(lines: Self.idle, withheldTerms: [], maxCharacters: 40)
        XCTAssertEqual(clipped.count, 40)
        XCTAssertTrue(clipped.hasSuffix("done 11:36 AM"))
    }

    func testAWithheldTermWrappedAcrossTwoLinesWithholdsBothAndTheTitle() {
        let body = [
            "⏺ Deployed to the client's staging box for Project",
            "  Bluebird; smoke test passed.",
            "",
            "  Needs you: nothing.",
        ]
        let screen = WaitingCheckScreen.preparedScreen(
            lines: Self.screen(body: body), withheldTerms: ["project bluebird"], maxCharacters: 3500)
        XCTAssertFalse(screen.lowercased().contains("bluebird"))
        XCTAssertFalse(screen.contains("staging box"))
        XCTAssertEqual(screen.components(separatedBy: WaitingCheckScreen.withheldPlaceholder).count - 1, 2)
        XCTAssertTrue(screen.contains("Needs you: nothing."))
        XCTAssertEqual(WaitingCheckScreen.preparedTitle("Bluebird deploy", withheldTerms: ["bluebird"]),
                       WaitingCheckScreen.withheldPlaceholder)
        XCTAssertEqual(WaitingCheckScreen.preparedTitle("C11H-261", withheldTerms: ["bluebird"]), "C11H-261")
    }

    func testRequestCarriesTheKeyModelStateAndBothQuestions() throws {
        let request = JevClient.makeRequest(key: "k-test", panelTitle: "C11H-261", harness: "claude-code", screen: "s")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, JevClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["panel_title"] as? String, "C11H-261")
        XCTAssertEqual(state["harness"] as? String, "claude-code")
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual((questions["needs_human"] as? [String: Any])?["type"] as? String, "noul")
        let stopKind = try XCTUnwrap(questions["stop_kind"] as? [String: Any])
        XCTAssertEqual((stopKind["criteria"] as? [String: Any])?.count, 7)
    }

    // MARK: Jev verdicts (fake transport)

    private func answerBody(needsHuman: Double, stopKind: String) -> Data {
        Data("""
        {"model":"jev-1","answers":{"needs_human":{"type":"noul","noul":\(needsHuman)},\
        "stop_kind":{"type":"choice","choice":"\(stopKind)","confidence":0.9,"probabilities":{}}}}
        """.utf8)
    }

    private func judge(_ responses: [Result<JevHTTPResponse, Error>]) -> (Result<JevAnswer, JevError>, Int) {
        var queue = responses
        var calls = 0
        var client = JevClient(key: "k-test")
        client.retryDelay = 0
        client.transport = { _, completion in
            calls += 1
            completion(queue.removeFirst())
        }
        var outcome: Result<JevAnswer, JevError>?
        client.judge(panelTitle: "t", harness: "claude-code", screen: "s") { outcome = $0 }
        return (outcome ?? .failure(.malformed), calls)
    }

    func testLowNeedsHumanAndDoneIsDone() throws {
        let (result, calls) = judge([.success(.init(status: 200, body: answerBody(needsHuman: 0.04, stopKind: "done")))])
        let answer = try result.get()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(answer.stopKind, "done")
        XCTAssertEqual(JevClient.outcome(for: answer), .done)
        XCTAssertEqual(JevClient.outcome(for: JevAnswer(model: nil, needsHuman: 0.1, stopKind: "waiting_on_agent",
                                                        stopKindConfidence: nil)), .done)
    }

    func testHighNeedsHumanOrAnAskIsWaiting() throws {
        let (result, _) = judge([.success(.init(status: 200, body: answerBody(needsHuman: 0.92, stopKind: "done")))])
        XCTAssertEqual(JevClient.outcome(for: try result.get()), .waiting)
        XCTAssertEqual(JevClient.outcome(for: JevAnswer(model: nil, needsHuman: 0.05, stopKind: "asks_human",
                                                        stopKindConfidence: nil)), .waiting)
        XCTAssertEqual(JevClient.outcome(for: JevAnswer(model: nil, needsHuman: 0.05, stopKind: "error_state",
                                                        stopKindConfidence: nil)), .waiting)
    }

    func testUnauthorizedFailsWithoutARetry() {
        let (result, calls) = judge([.success(.init(status: 401, body: Data()))])
        XCTAssertEqual(calls, 1)
        guard case .failure(let error) = result else { return XCTFail("401 must fail") }
        XCTAssertEqual(error, .auth(status: 401))
        XCTAssertEqual(error.errorClass, "auth_401")
    }

    func testMalformedResponseFails() {
        let (result, calls) = judge([.success(.init(status: 200, body: Data(#"{"model":"jev-1"}"#.utf8)))])
        XCTAssertEqual(calls, 1)
        guard case .failure(let error) = result else { return XCTFail("missing answers must fail") }
        XCTAssertEqual(error, .malformed)
    }

    func testATransientFailureIsRetriedOnce() throws {
        let (recovered, calls) = judge([
            .failure(URLError(.timedOut)),
            .success(.init(status: 200, body: answerBody(needsHuman: 0.1, stopKind: "offering"))),
        ])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(JevClient.outcome(for: try recovered.get()), .done)
        let (failed, failedCalls) = judge([
            .success(.init(status: 503, body: Data())),
            .success(.init(status: 502, body: Data())),
        ])
        XCTAssertEqual(failedCalls, 2)
        guard case .failure(let error) = failed else { return XCTFail("two 5xx must fail") }
        XCTAssertEqual(error, .http(status: 502))
    }

    // MARK: Indexes and verdicts

    @MainActor
    func testADoneNotificationMovesFromUnreadToDone() {
        let workspace = UUID()
        let finished = notification(workspace: workspace, surface: UUID(), age: 60)
        let asking = notification(workspace: workspace, surface: UUID(), age: 0)
        let indexes = TerminalNotificationStore.buildIndexes(
            for: [asking, finished],
            signalEligible: { _ in true },
            isDone: { $0.id == finished.id }
        )
        XCTAssertEqual(indexes.rawUnreadCount, 2)
        XCTAssertEqual(indexes.unreadCount, 1)
        XCTAssertEqual(indexes.unreadCountByWorkspaceId[workspace], 1)
        XCTAssertEqual(indexes.doneUnreadCount, 1)
        XCTAssertEqual(indexes.doneUnread.map(\.id), [finished.id])
        XCTAssertTrue(indexes.doneUnreadByWorkspaceSurface.contains(
            .init(workspaceId: workspace, surfaceId: finished.surfaceId)))
        XCTAssertFalse(indexes.unreadByWorkspaceSurface.contains(
            .init(workspaceId: workspace, surfaceId: finished.surfaceId)))

        // A suppressed notification is neither waiting nor done.
        let suppressed = TerminalNotificationStore.buildIndexes(
            for: [finished], signalEligible: { _ in false }, isDone: { _ in true })
        XCTAssertEqual(suppressed.unreadCount, 0)
        XCTAssertEqual(suppressed.doneUnreadCount, 0)
    }

    func testVerdictTableAnswersByNotificationAndPanelAndMarkUnreadDropsIt() {
        WaitingCheckJudge.resetForTesting()
        defer { WaitingCheckJudge.resetForTesting() }
        let panel = UUID()
        let verdict = WaitingCheckVerdict(
            notificationID: UUID(), workspaceID: UUID(), panelID: panel, outcome: .done, source: .convention,
            needsHuman: nil, stopKind: nil, quote: "Needs you: nothing.", judgedAt: Date())
        WaitingCheckJudge.recordForTesting(verdict)
        XCTAssertEqual(WaitingCheckJudge.verdict(forNotificationID: verdict.notificationID), verdict)
        XCTAssertEqual(WaitingCheckJudge.latestVerdict(panelID: panel), verdict)
        XCTAssertEqual(WaitingCheckJudge.isDone(verdict.notificationID), WaitingCheckSettings.isEnabled())
        XCTAssertFalse(WaitingCheckJudge.isDone(UUID()))
        XCTAssertEqual(verdict.jsonObject["outcome"] as? String, "done")
        XCTAssertTrue(verdict.jsonObject["needs_human"] is NSNull)

        XCTAssertTrue(WaitingCheckJudge.dropVerdicts(forNotificationIDs: [verdict.notificationID]))
        XCTAssertFalse(WaitingCheckJudge.dropVerdicts(forNotificationIDs: [verdict.notificationID]))
        XCTAssertNil(WaitingCheckJudge.verdict(forNotificationID: verdict.notificationID))
        XCTAssertNil(WaitingCheckJudge.latestVerdict(panelID: panel))
        XCTAssertFalse(WaitingCheckJudge.isDone(verdict.notificationID))
    }

    /// A done verdict on a panel that has since been flagged or asked ends.
    func testDoneVerdictsUnderAttentionAreSelectedByPanel() {
        let asked = UUID(), quiet = UUID()
        let onAsked = WaitingCheckVerdict(
            notificationID: UUID(), workspaceID: UUID(), panelID: asked, outcome: .done, source: .convention,
            needsHuman: nil, stopKind: nil, quote: nil, judgedAt: Date())
        let onQuiet = WaitingCheckVerdict(
            notificationID: UUID(), workspaceID: UUID(), panelID: quiet, outcome: .done, source: .jev,
            needsHuman: 0.1, stopKind: "done", quote: nil, judgedAt: Date())
        XCTAssertEqual(WaitingCheckJudge.doneVerdictsUnderAttention([onAsked, onQuiet], attentionPanels: [asked]),
                       [onAsked.notificationID])
        XCTAssertTrue(WaitingCheckJudge.doneVerdictsUnderAttention([onQuiet], attentionPanels: [asked]).isEmpty)
    }

    /// Claude's idle reminder is a turn end seen again; permission and other
    /// notification types are not.
    func testClaudeIdlePromptIsRecognisedByTypeOrIdleText() {
        XCTAssertTrue(ClaudeIdlePromptNotification.matches(rawInput: #"{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#))
        XCTAssertTrue(ClaudeIdlePromptNotification.matches(rawInput: #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#))
        XCTAssertFalse(ClaudeIdlePromptNotification.matches(rawInput: #"{"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#))
        XCTAssertFalse(ClaudeIdlePromptNotification.matches(rawInput: #"{"message":"Claude is waiting for your input","notification_type":"elicitation_dialog"}"#))
        XCTAssertFalse(ClaudeIdlePromptNotification.matches(rawInput: #"{"message":"Claude needs your permission to use Bash"}"#))
        XCTAssertFalse(ClaudeIdlePromptNotification.matches(rawInput: ""))
    }

    /// Fixed false done: only an agent's own turn end is judged; every other
    /// notification defaults to `.other`.
    func testNotificationsDefaultToOtherOrigin() {
        XCTAssertEqual(notification(workspace: UUID(), surface: UUID(), age: 0).origin, .other)
        let turnEnd = TerminalNotification(
            id: UUID(), workspaceId: UUID(), surfaceId: UUID(), title: "Claude Code", subtitle: "", body: "",
            createdAt: Date(), isRead: false, origin: .turnEnd)
        XCTAssertEqual(turnEnd.origin, .turnEnd)
    }

    private func notification(workspace: UUID, surface: UUID, age: TimeInterval) -> TerminalNotification {
        TerminalNotification(
            id: UUID(), workspaceId: workspace, surfaceId: surface, title: "Turn ended", subtitle: "", body: "",
            createdAt: Date().addingTimeInterval(-age), isRead: false)
    }
}
