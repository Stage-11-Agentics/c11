import XCTest
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class SocketStartupReadinessTests: XCTestCase {
    private func request(_ method: String) -> String {
        "{\"id\":297,\"method\":\"\(method)\",\"params\":{\"tab_id\":\"tab:1\"}}"
    }

    private func assertNotReady(_ response: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], file: file, line: line)
        XCTAssertEqual(object["id"] as? Int, 297, file: file, line: line)
        XCTAssertEqual(object["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "not_ready", file: file, line: line)
    }

    func testPendingRestoreRejectsGraphAndWorkerCommandsBeforeTargetResolution() throws {
        let controller = TerminalController.makeForTesting()
        controller.setInitialSessionRestoreReady(false)
        // Worker sends, browser evaluation and async telemetry must not bypass
        // the same startup boundary as the main-actor tree/close handlers.
        for method in ["system.tree", "system.identify", "workspace.close", "tab.send_text", "surface.send_text", "browser.eval", "tab.set_metadata", "agent.launch"] {
            try assertNotReady(controller.processCommandUsingSocketExecutionPolicy(request(method)))
        }
        try assertNotReady(controller.processV2Command(request("system.tree")))
        if case .err(.err(let code, _, _)) = controller.resolveSurfaceSendTargets(params: [:]) {
            XCTAssertEqual(code, "not_ready")
        } else { XCTFail("Direct target resolution must reject an incomplete graph") }
    }

    func testPingStaysAvailableAndV1MutationIsNotAcknowledgedDuringRestore() {
        let controller = TerminalController.makeForTesting()
        controller.setInitialSessionRestoreReady(false)
        XCTAssertEqual(controller.processCommandUsingSocketExecutionPolicy("ping"), "PONG")
        XCTAssertTrue(controller.processCommandUsingSocketExecutionPolicy("report_pwd /tmp --tab=tab:1").hasPrefix("ERROR: not_ready:"))
        XCTAssertTrue(controller.processCommand("close_workspace").hasPrefix("ERROR: not_ready:"))
        for method in ["system.ping", "system.capabilities", "system.brand", "auth.login"] {
            XCTAssertNil(controller.startupNotReadyResponse(for: request(method)))
        }
        let ping = controller.processV2Command(request("system.ping"))
        XCTAssertTrue(ping.contains("\"pong\":true"))
    }

    func testPendingRestoreRetainsOnlyExplicitValidBundledReports() {
        let controller = TerminalController.makeForTesting()
        controller.setInitialSessionRestoreReady(false)
        let panel = UUID().uuidString
        let scope = "--tab=\(panel) --panel=\(panel)"
        for command in ["report_tty ttys297 \(scope)", "report_shell_state prompt \(scope)",
                        "report_shell_state running \(scope)", "report_tty ttys298 \(scope)"] {
            XCTAssertEqual(controller.processCommandUsingSocketExecutionPolicy(command), "OK")
        }
        XCTAssertEqual(controller.debugDeferredStartupReportCount, 2, "Coalesce each report kind by tab")
        for command in ["report_tty ttys297", "report_shell_state prompt --tab=tab:1",
                        "report_shell_state invalid \(scope)", "report_tty --tab=\(panel) --panel=\(panel)"] {
            XCTAssertTrue(controller.processCommandUsingSocketExecutionPolicy(command).hasPrefix("ERROR: not_ready:"))
        }
        controller.setInitialSessionRestoreReady(true)
        XCTAssertEqual(controller.debugDeferredStartupReportCount, 0, "Unknown/closed targets must also drain")
    }

    func testCompletedRestoreReleasesStartupRejectionWithoutAListenerSideEffect() {
        let controller = TerminalController.makeForTesting()
        controller.setInitialSessionRestoreReady(false)
        XCTAssertNotNil(controller.startupNotReadyResponse(for: request("system.tree")))
        controller.setInitialSessionRestoreReady(true)
        XCTAssertNil(controller.startupNotReadyResponse(for: request("system.tree")))
        XCTAssertNil(controller.startupNotReadyResponse(for: "report_pwd /tmp"))
        XCTAssertEqual(controller.socketPathSnapshot, "")
        XCTAssertFalse(controller.isListeningForStartupRestore)
    }
}

/// C11-105 regressions. Both checks are host-less and run inside the
/// `c11LogicTests` target so they can guard fast local iteration without
/// touching real sockets or the prod c11's bind file.
@MainActor
final class SocketControlSafetyTests: XCTestCase {

    /// Production bug: a fresh `TerminalController` defaulted `socketPath` to
    /// `SocketControlSettings.stableDefaultSocketPath`. A test whose setUp
    /// called `TerminalController.shared.stop()` would then `unlink()` the
    /// prod c11's bind path while its FD stayed live in-kernel, leaving every
    /// `c11 <cmd>` reporting "Socket not found". The fix initializes the
    /// field to "" and gates `stop()`'s unlink on a non-empty path.
    func testFreshControllerHasEmptySocketPath() {
        let controller = TerminalController.makeForTesting()
        XCTAssertEqual(
            controller.socketPathSnapshot,
            "",
            "A never-started TerminalController must not carry a shared "
            + "default socket path — stop() would unlink it. See C11-105."
        )
    }

    /// Rename hygiene: `.cmuxOnly` was renamed to `.c11Only`. Persisted
    /// `UserDefaults` values from pre-rename builds must still migrate
    /// forward, and the new canonical raw value must parse as well. The
    /// `migrateMode` normalizer is case-insensitive and strips `-`/`_`.
    func testParseAcceptsLegacyAndCanonicalC11OnlyValues() {
        // New canonical raw value (what migrateMode writes back).
        XCTAssertEqual(SocketControlSettings.migrateMode("c11Only"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("c11-only"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("c11_only"), .c11Only)

        // Legacy raw value persisted by pre-rename builds.
        XCTAssertEqual(SocketControlSettings.migrateMode("cmuxOnly"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("cmux-only"), .c11Only)
    }
}

/// Shared "is this a local dev build?" gate used to suppress launch-time
/// auto-dialogs (Agent Skills onboarding, resume picker) for the person
/// rebuilding c11. `isDebugBuild` is injected so the env branch is exercised
/// even though the logic-test target itself compiles DEBUG.
final class SocketControlIsLocalDevBuildTests: XCTestCase {
    func testTaggedReleaseBuildIsDev() {
        XCTAssertTrue(SocketControlSettings.isLocalDevBuild(
            environment: ["CMUX_TAG": "feat-foo"], isDebugBuild: false))
    }

    func testUntaggedReleaseBuildIsNotDev() {
        XCTAssertFalse(SocketControlSettings.isLocalDevBuild(
            environment: [:], isDebugBuild: false))
    }

    func testWhitespaceTagIsNotDev() {
        XCTAssertFalse(SocketControlSettings.isLocalDevBuild(
            environment: ["CMUX_TAG": "   "], isDebugBuild: false))
    }

    func testDebugBuildIsAlwaysDev() {
        XCTAssertTrue(SocketControlSettings.isLocalDevBuild(
            environment: [:], isDebugBuild: true))
    }
}

/// C11H-38: resume is the default and nothing blocks. A launch holds or skips
/// the resume of ended conversations only by an explicit choice (Option held,
/// or "On launch" set in Settings), and `C11_QA_LAUNCH` beats both.
final class LaunchResumeGateTests: XCTestCase {
    private func decide(_ qa: QALaunchPolicy = .off, _ persisted: LaunchResumePolicy = .always,
                        option: Bool = false) -> LaunchResumeDecision {
        LaunchResumePicker.decide(qa: qa, persisted: persisted, optionHeld: option)
    }

    func testResumeIsTheDefault() {
        XCTAssertEqual(decide(), .resume)
        XCTAssertTrue(decide().resumesConversations)
        XCTAssertTrue(decide().restoresSession)
    }

    func testOptionHeldOffersTheChoiceForThisLaunchWhateverTheSetting() {
        XCTAssertEqual(decide(option: true), .ask(.optionHeld))
        XCTAssertEqual(decide(.off, .never, option: true), .ask(.optionHeld))
        XCTAssertFalse(decide(option: true).resumesConversations, "nothing resumes until the operator answers")
        XCTAssertTrue(decide(option: true).restoresSession, "asking never holds back restore or live terminals")
    }

    func testTheSettingsMapToTheThreeWords() {
        XCTAssertEqual(decide(.off, .always), .resume)
        XCTAssertEqual(decide(.off, .ask), .ask(.setting))
        XCTAssertEqual(decide(.off, .never), .startFresh(.setting))
    }

    func testQALaunchBeatsOptionAndTheSetting() {
        XCTAssertEqual(decide(.on(.resume), .never, option: true), .resume)
        XCTAssertEqual(decide(.on(.fresh), .always, option: true), .startFresh(.qaLaunch))
        XCTAssertFalse(decide(.on(.fresh)).restoresSession, "a QA fresh launch restores nothing, as before")
    }

    func testStartFreshAppliesNoSnapshotSoRunningTerminalsGoToRecovered() {
        XCTAssertFalse(decide(.off, .never).restoresSession)
        XCTAssertFalse(decide(.off, .never).resumesConversations, "start fresh never resumes ended conversations")
    }

    func testOptionAndShiftTogetherStartFreshForThisLaunch() {
        let both = LaunchResumePicker.decide(qa: .off, persisted: .always, optionHeld: true, shiftHeld: true)
        XCTAssertEqual(both, .startFresh(.optionShiftHeld))
        XCTAssertEqual(LaunchResumePicker.decide(qa: .off, persisted: .always, optionHeld: false, shiftHeld: true),
                       .resume, "Shift alone does nothing")
        XCTAssertEqual(LaunchResumePicker.decide(qa: .on(.resume), persisted: .never, optionHeld: true, shiftHeld: true),
                       .resume, "QA still wins")
    }

    func testStoredValuesReadAsTheSameThreeWordsAsC11() {
        let suite = "c11h38.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LaunchResumePolicy.current(defaults: defaults), .always, "unset resumes")
        for stored in ["", "  ", "banana"] {
            defaults.set(stored, forKey: LaunchResumePolicy.defaultsKey)
            XCTAssertEqual(LaunchResumePolicy.current(defaults: defaults), .always, "stored '\(stored)'")
        }
        defaults.set(" Never ", forKey: LaunchResumePolicy.defaultsKey)
        XCTAssertEqual(LaunchResumePolicy.current(defaults: defaults), .never)
        defaults.set("ask", forKey: LaunchResumePolicy.defaultsKey)
        XCTAssertEqual(LaunchResumePolicy.current(defaults: defaults),
                       LaunchResumePolicy.offersAskOption ? .ask : .always)
        XCTAssertEqual(LaunchResumePolicy.defaultsKey, "c11.launch.resumePolicy")
    }
}

/// Parking the resume of ended conversations while the operator chooses.
@MainActor
final class LaunchResumeParkingTests: XCTestCase {
    private func gate(asking: Bool) -> LaunchResumeGate {
        let gate = LaunchResumeGate()
        gate.releaseStagger = 0
        gate.begin(asking: asking)
        return gate
    }

    private func park(_ gate: LaunchResumeGate, _ id: UUID, ran: XCTestExpectation? = nil,
                      _ log: @escaping (UUID) -> Void = { _ in }) -> Bool {
        gate.intercept(panelID: id, workspaceTitle: "W", panelTitle: id.uuidString) {
            log(id); ran?.fulfill()
        }
    }

    func testANonAskingLaunchNeverParksAnything() {
        let gate = gate(asking: false)
        XCTAssertFalse(park(gate, UUID()))
        XCTAssertTrue(gate.held.isEmpty)
    }

    /// The real entry a launch resume takes before it types, with a recording
    /// sink standing in for the typing.
    private func submit(_ gate: LaunchResumeGate, _ id: UUID = UUID(), scoped: Bool = true,
                        record: @escaping () -> Void) async {
        await gate.submit(panelID: id, workspaceTitle: "W", panelTitle: "P", launchScoped: scoped) { record() }
    }

    func testALaunchResumeIsNotTypedWhileAskingAndTypedOnceAfterAnAffirmativeChoice() async {
        let gate = gate(asking: true)
        var typed = 0
        let typedOnce = expectation(description: "typed once")
        await submit(gate) { typed += 1; typedOnce.fulfill() }
        XCTAssertEqual(typed, 0, "nothing is typed before the operator chooses")
        XCTAssertEqual(gate.held.count, 1)
        gate.resumeAll()
        await fulfillment(of: [typedOnce], timeout: 5)
        XCTAssertEqual(typed, 1)
    }

    func testALaunchResumeIsNeverTypedAfterNotNow() async {
        let gate = gate(asking: true)
        var typed = 0
        await submit(gate) { typed += 1 }
        gate.decline()
        await submit(gate) { typed += 1 }
        XCTAssertEqual(typed, 0, "not now drops what was parked and what arrives later")
    }

    func testAManualResumeIsNeverParked() async {
        let gate = gate(asking: true)
        var typed = 0
        await submit(gate, scoped: false) { typed += 1 }
        XCTAssertEqual(typed, 1, "a manual resume runs even while the launch is asking")
        XCTAssertTrue(gate.held.isEmpty)
    }

    func testAStartupRecoveryStaysSubjectToTheAnswerWhateverTheElapsedTime() async {
        let gate = gate(asking: true)
        var typed = 0
        await submit(gate) { typed += 1 }
        XCTAssertEqual(typed, 0, "unanswered: parked, with no timer to let it through")
        XCTAssertEqual(gate.held.count, 1)

        gate.decline()
        // Nothing in the gate reads a clock; a recovery that finishes minutes
        // or hours after the question is still dropped.
        await submit(gate) { typed += 1 }
        XCTAssertEqual(typed, 0, "declined: a late startup recovery is still dropped")
    }

    func testAMarkedTerminalsResolutionIsLaunchScopedUntilItsRecoveryIsSettled() {
        var marks = LaunchRestoreMarks()
        let restored = UUID(), fresh = UUID()
        marks.mark(restored)

        XCTAssertFalse(marks.isStartupResolution(restored, resolved: false), "still unresolved: not its resolution yet")
        XCTAssertTrue(marks.isStartupResolution(restored, resolved: true), "however late the backend answers")
        XCTAssertTrue(marks.isStartupResolution(restored, resolved: true), "reading it spends nothing")
        XCTAssertFalse(marks.isStartupResolution(fresh, resolved: true), "a terminal the launch did not restore")
    }

    func testAPlanReleasedToBeRetriedKeepsItsStartupScope() {
        // The replacement could not attach yet (no launch spec or window), so
        // the plan is released and made again when the panel attaches.
        var marks = LaunchRestoreMarks()
        let id = UUID()
        marks.mark(id)

        marks.consume(id)                                  // planned
        marks.planReleased(id, wasStartup: true)           // could not attach: released
        XCTAssertTrue(marks.isStartupResolution(id, resolved: true), "the retry is still this launch's")

        marks.consume(id)                                  // planned again, and this time it holds
        XCTAssertFalse(marks.isStartupResolution(id, resolved: true),
                       "a genuine end later in the session is ordinary recovery")
    }

    func testAReleasedPlanThatWasNotStartupDoesNotBecomeOne() {
        var marks = LaunchRestoreMarks()
        let id = UUID()
        marks.planReleased(id, wasStartup: false)          // a mid-session end that could not attach yet
        XCTAssertFalse(marks.isStartupResolution(id, resolved: true))
    }

    func testASurvivorsMarkIsSpentSoALaterEndIsNotScoped() {
        var marks = LaunchRestoreMarks()
        let id = UUID()
        marks.mark(id)
        marks.consume(id)       // resolved live: no recovery needed
        XCTAssertFalse(marks.isStartupResolution(id, resolved: true), "its later end is not this launch's")
    }

    func testAnAskingLaunchParksUntilTheOperatorAnswers() {
        let gate = gate(asking: true)
        let a = UUID(), b = UUID()
        XCTAssertTrue(park(gate, a))
        XCTAssertTrue(park(gate, a), "the same panel is held once")
        XCTAssertTrue(park(gate, b))
        XCTAssertEqual(Set(gate.held.map(\.id)), [a, b])
        XCTAssertEqual(gate.held.count, 2)
    }

    func testResumeAllRunsEverythingHeldAndLetsLaterOnesThrough() async {
        let gate = gate(asking: true)
        let ran = expectation(description: "both resumed"); ran.expectedFulfillmentCount = 2
        XCTAssertTrue(park(gate, UUID(), ran: ran))
        XCTAssertTrue(park(gate, UUID(), ran: ran))
        gate.resumeAll()
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertTrue(gate.held.isEmpty)
        XCTAssertEqual(gate.phase, .resumeAll)
        XCTAssertFalse(park(gate, UUID()), "a later arrival after Resume all resumes as it comes")
    }

    func testChoosingResumesOnlyThoseAndLeavesTheRestAndLaterOnesAlone() async {
        let gate = gate(asking: true)
        let keep = UUID(), skip = UUID()
        var resumed: [UUID] = []
        let ran = expectation(description: "chosen resumed")
        XCTAssertTrue(park(gate, keep, ran: ran) { resumed.append($0) })
        XCTAssertTrue(park(gate, skip) { resumed.append($0) })
        gate.resume(only: [keep])
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertEqual(resumed, [keep])
        XCTAssertTrue(park(gate, UUID()), "after choosing, later arrivals are not resumed")
    }

    func testNotNowResumesNothingNowOrLater() {
        let gate = gate(asking: true)
        var resumed = 0
        XCTAssertTrue(park(gate, UUID()) { _ in resumed += 1 })
        gate.decline()
        XCTAssertTrue(gate.held.isEmpty)
        XCTAssertTrue(park(gate, UUID()) { _ in resumed += 1 })
        XCTAssertEqual(resumed, 0)
        XCTAssertEqual(gate.phase, .declined)
    }
}

/// What the banner says, from what the launch did. It reports; it decides nothing.
@MainActor
final class LaunchResumeReportTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)

    private func makeReport() -> LaunchResumeReport {
        LaunchResumeReport(clock: { [unowned self] in self.now })
    }

    private func skip(_ why: String = "no transcript") -> LaunchResumeReport.Outcome {
        .skipped(workspaceTitle: "Reviews", panelTitle: "Codex", reason: why)
    }

    func testNothingResumedMeansNoBanner() {
        let report = makeReport()
        XCTAssertNil(report.headline, "before launch decides")
        report.begin(.resume)
        XCTAssertNil(report.headline, "a clean launch with nothing ended says nothing")
    }

    func testCountsEachResumedPanelOnceAndSaysSoInSingularAndPlural() {
        let report = makeReport()
        report.begin(.resume)
        let a = UUID(), b = UUID(), c = UUID()
        report.record(panelID: a, outcome: .resumed)
        XCTAssertEqual(report.headline, "Resumed 1 session.")
        report.record(panelID: a, outcome: .resumed)
        report.record(panelID: b, outcome: .resumed)
        report.record(panelID: c, outcome: .resumed)
        XCTAssertEqual(report.headline, "Resumed 3 sessions.")
    }

    func testSkippedPanelsAreReportedAndNeverCountedAsResumed() {
        let report = makeReport()
        report.begin(.resume)
        report.record(panelID: UUID(), outcome: .resumed)
        report.record(panelID: UUID(), outcome: .resumed)
        let skipped = UUID()
        report.record(panelID: skipped, outcome: skip())
        XCTAssertEqual(report.headline, "Resumed 2 sessions. 1 session was not resumed.")
        XCTAssertEqual(report.skipped.map(\.reason), ["no transcript"])

        report.record(panelID: UUID(), outcome: skip("panel in use"))
        XCTAssertEqual(report.headline, "Resumed 2 sessions. 2 sessions were not resumed.")

        // A later retry that succeeds moves the panel from skipped to resumed.
        report.record(panelID: skipped, outcome: .resumed)
        XCTAssertEqual(report.headline, "Resumed 3 sessions. 1 session was not resumed.")
    }

    /// C11H-99: after an in-place update every agent kept running. None is a
    /// skip, so the banner never says "not resumed" for them.
    func testAgentsThatKeptRunningAreNeverReportedAsNotResumed() {
        let report = makeReport()
        report.begin(.resume)
        let kept = (0..<12).map { _ in UUID() }
        for panel in kept { report.record(panelID: panel, outcome: .kept) }
        XCTAssertEqual(report.headline, "12 agents kept running.")
        XCTAssertEqual(report.keptCount, 12)
        XCTAssertEqual(report.resumedCount, 0)
        XCTAssertTrue(report.skipped.isEmpty, "no Details list of skips")
        XCTAssertFalse(report.headline?.contains("not resumed") ?? true)
    }

    /// A panel skipped before hc said its agent was still running ends as
    /// kept, and the counts stay separate from real resumes and skips.
    func testAKeptAgentReplacesAnEarlierSkipAndCountsApart() {
        let report = makeReport()
        report.begin(.resume)
        let codex = UUID()
        report.record(panelID: codex, outcome: skip("transcript unverified"))
        XCTAssertEqual(report.headline, "1 session was not resumed.")
        report.record(panelID: codex, outcome: .kept)
        XCTAssertEqual(report.headline, "1 agent kept running.")
        XCTAssertTrue(report.skipped.isEmpty)
        report.record(panelID: UUID(), outcome: .resumed)
        report.record(panelID: UUID(), outcome: skip())
        report.record(panelID: UUID(), outcome: .kept)
        XCTAssertEqual(report.headline, "Resumed 1 session. 1 session was not resumed. 2 agents kept running.")
        XCTAssertEqual(LaunchResumeReport.headline(mode: .resumed, resumed: 0, skipped: 0, kept: 0), nil)
    }

    func testOnlySkipsStillReports() {
        let report = makeReport()
        report.begin(.resume)
        report.record(panelID: UUID(), outcome: skip())
        XCTAssertEqual(report.headline, "1 session was not resumed.")
    }

    func testOutcomesAfterTheLaunchWindowAreNotThisLaunchs() {
        let report = makeReport()
        report.begin(.resume)
        now = now.addingTimeInterval(LaunchResumeReport.launchWindow + 1)
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertNil(report.headline, "a manual resume an hour later is not part of the launch report")
    }

    /// C11H-99 on an Ask launch: one agent kept running and one session ended.
    /// The keep is recorded once, while the ask strip waits; choosing to
    /// resume (Resume all, or Choose…) counts it with what is resumed.
    func testAnAgentKeptWhileAskingIsCountedOnceTheOperatorChoosesToResume() {
        let report = makeReport()
        report.begin(.ask(.optionHeld))
        let kept = UUID()
        report.record(panelID: kept, outcome: .kept)
        XCTAssertNil(report.headline, "the ask strip owns the line while asking")
        report.startCounting()
        XCTAssertEqual(report.headline, "1 agent kept running.")
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertEqual(report.headline, "Resumed 1 session. 1 agent kept running.")
        XCTAssertEqual(report.keptCount, 1)
        XCTAssertTrue(report.skipped.isEmpty)
    }

    /// Only this launch's ask carries: a later launch, or a resume launch that
    /// never asked, starts with nothing kept.
    func testKeptAgentsCarryOnlyFromThisLaunchsAsk() {
        let report = makeReport()
        report.begin(.ask(.optionHeld))
        report.record(panelID: UUID(), outcome: .kept)
        report.begin(.resume)
        XCTAssertEqual(report.keptCount, 0)
        XCTAssertNil(report.headline)
        report.startCounting()
        XCTAssertEqual(report.keptCount, 0, "a second startCounting does not invent kept agents")
    }

    func testAskCountsOnlyAfterTheOperatorChoosesToResume() {
        let report = makeReport()
        report.begin(.ask(.optionHeld))
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertNil(report.headline, "the ask banner belongs to the gate")
        report.startCounting()
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertEqual(report.headline, "Resumed 1 session.")
        XCTAssertEqual(LaunchResumeReport.askHeadline(count: 1), "1 session ended while c11 was closed.")
        XCTAssertEqual(LaunchResumeReport.askHeadline(count: 4), "4 sessions ended while c11 was closed.")
        XCTAssertNil(LaunchResumeReport.askHeadline(count: 0))
    }

    func testStartFreshCountsTheRunningTerminalsThatWentToRecovered() {
        let report = makeReport()
        report.begin(.startFresh(.setting))
        XCTAssertEqual(report.headline, "Started fresh.")
        let a = UUID()
        report.noteRecovered(panelID: a)
        XCTAssertEqual(report.headline, "Started fresh. 1 running terminal is in the Recovered workspace.")
        report.noteRecovered(panelID: a)
        report.noteRecovered(panelID: UUID())
        report.noteRecovered(panelID: UUID())
        XCTAssertEqual(report.headline, "Started fresh. 3 running terminals are in the Recovered workspace.")
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertEqual(report.headline, "Started fresh. 3 running terminals are in the Recovered workspace.",
                       "a start-fresh launch ignores resume outcomes")
    }

    func testStartFreshSaysNothingWithoutASessionToSkipOrATerminalToRecover() {
        let report = makeReport()
        report.begin(.startFresh(.setting), hadPreviousSession: false)
        XCTAssertNil(report.headline, "first launch, nothing recovered")
        report.noteRecovered(panelID: UUID())
        XCTAssertNotNil(report.headline, "a running terminal that went to Recovered is always worth saying")
        report.begin(.startFresh(.qaLaunch))
        report.noteRecovered(panelID: UUID())
        XCTAssertNil(report.headline, "automation is never told")
    }

    func testRecoveredTerminalsAreOnlyCountedOnAStartFreshLaunch() {
        let report = makeReport()
        report.begin(.resume)
        report.noteRecovered(panelID: UUID())
        XCTAssertEqual(report.recoveredCount, 0)
    }

    func testDismissHidesItAndABeginStartsOver() {
        let report = makeReport()
        report.begin(.resume)
        report.record(panelID: UUID(), outcome: .resumed)
        report.dismiss()
        XCTAssertNil(report.headline)
        report.record(panelID: UUID(), outcome: .resumed)
        XCTAssertNil(report.headline, "a dismissed banner stays dismissed")
        report.begin(.resume)
        XCTAssertEqual(report.resumedCount, 0)
        XCTAssertTrue(report.skipped.isEmpty)
    }
}

// MARK: - C11-155: bind-time socket stomp

/// The incident: a staging/debug build launched from a prod c11 pane inherits
/// prod's `CMUX_SOCKET_PATH` and would bind (unlinking) prod's *live* socket.
/// These tests cover the resolution-layer guard (don't adopt a foreign channel's
/// shared default) and the per-bundle namespacing defense-in-depth.
final class SocketCollisionResolutionTests: XCTestCase {

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testStagingDoesNotAdoptInheritedProdSocketPath() {
        // A staging bundle launched beside c11h inherits c11h's socket. It must
        // bind staging's own path, never c11h's, even when the path is c11h's
        // Application Support socket.
        let foreign = "/tmp/c11h.sock"
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": foreign],
            bundleIdentifier: "com.stage11.c11.staging",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, C11Identity.stagingSocketPath)
        XCTAssertNotEqual(path, foreign)
    }
    // c11-2.0:end-keep

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testDebugDoesNotAdoptInheritedStagingSharedSocketPath() {
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/c11h-staging.sock"],
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, C11Identity.debugSocketPath)
    }
    // c11-2.0:end-keep

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testExplicitOptInStillRefusesAForeignPath() {
        let foreign = "/tmp/c11h.sock"
        let refused = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": foreign,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.stage11.c11.staging",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(refused, C11Identity.stagingSocketPath)

        let own = "/tmp/c11-custom.sock"
        let adopted = SocketControlSettings.socketPath(
            environment: [
                "C11_SOCKET_PATH": own,
                "C11_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.stage11.c11.staging",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(adopted, own)
    }
    // c11-2.0:end-keep

    func testTaggedStagingOverrideStillHonored() {
        let own = "/tmp/c11-staging-my-tag.sock"
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": own],
            bundleIdentifier: "com.stage11.c11.staging.my-tag",
            isDebugBuild: false
        )
        XCTAssertEqual(path, own)
    }

    // c11-2.0:begin-keep (the retired c11h line is the foreign one here)
    func testForeignSharedDefaultDetection() {
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath(
            SocketControlSettings.stableDefaultSocketPath))
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-debug.sock"))
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-staging-my-tag.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h-staging.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h-debug.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h-nightly.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h-staging-my-tag.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h-debug-feat-x.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11h.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/cmux.sock"))
    }
    // c11-2.0:end-keep

    func testNonProdStableBundleGetsBundleScopedSocket() {
        // A non-prod bundle that still falls through to the stable default (e.g.
        // release-probe) must never resolve to prod's shared path.
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.stage11.c11.release-probe",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertNotEqual(path, SocketControlSettings.stableDefaultSocketPath)
        XCTAssertEqual(
            path,
            SocketControlSettings.bundleScopedStableSocketPath(
                bundleIdentifier: "com.stage11.c11.release-probe"))
        XCTAssertTrue(path.hasSuffix(".sock"))
    }

    func testProdBundleKeepsCanonicalStableSocket() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: SocketControlSettings.prodBundleIdentifier,
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }
}

/// The bind-layer guarantee (C11-155): never unlink a socket a live peer serves.
final class SocketLivenessProbeTests: XCTestCase {

    /// Bind+listen a real unix socket at `path`; caller closes the returned fd.
    private func makeLiveListener(at path: String) -> Int32 {
        Darwin.unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let dstRaw = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                strncpy(dstRaw, src, sunPathCapacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        return fd
    }

    func testLiveListenerIsDetected() {
        let path = "/tmp/c11-test-live-\(getpid()).sock"
        let fd = makeLiveListener(at: path)
        defer { Darwin.close(fd); Darwin.unlink(path) }
        XCTAssertTrue(TerminalController.socketHasLiveListener(path: path))
    }

    func testMissingPathIsNotLive() {
        XCTAssertFalse(TerminalController.socketHasLiveListener(
            path: "/tmp/c11-test-absent-\(getpid()).sock"))
    }

    func testRegularFileIsNotLive() {
        let path = "/tmp/c11-test-regular-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { Darwin.unlink(path) }
        XCTAssertFalse(TerminalController.socketHasLiveListener(path: path))
    }

    func testStaleSocketFileIsNotLive() {
        // A socket file with no live acceptor (closed listener) is replaceable.
        let path = "/tmp/c11-test-stale-\(getpid()).sock"
        let fd = makeLiveListener(at: path)
        Darwin.close(fd) // file remains on disk, but nobody is accepting
        defer { Darwin.unlink(path) }
        XCTAssertFalse(TerminalController.socketHasLiveListener(path: path))
    }

    func testSafeAlternateForProdPathIsUserScoped() {
        XCTAssertEqual(
            TerminalController.safeAlternateSocketPath(
                afterPeerAliveAt: SocketControlSettings.stableDefaultSocketPath,
                currentUserID: 501),
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testSafeAlternateForOtherPathIsPidStampedSibling() {
        let alt = TerminalController.safeAlternateSocketPath(
            afterPeerAliveAt: "/tmp/c11-staging.sock",
            currentUserID: 501,
            processIdentifier: 4242)
        XCTAssertEqual(alt, "/tmp/c11-staging-4242.sock")
    }
}

/// Pure launch arbitration and executable-identity fixtures; no app, socket,
/// termination, or Launch Services registration is needed by these tests.
final class SingleInstancePolicyTests: XCTestCase {
    private let bundleID = "com.stage11.c11.debug.single-instance-policy"

    private func process(
        _ pid: pid_t,
        bundleIdentifier: String? = "com.stage11.c11.debug.single-instance-policy",
        launchDate: Date? = Date(timeIntervalSince1970: 20),
        terminated: Bool = false,
        finished: Bool = false,
        actual: URL? = URL(fileURLWithPath: "/Applications/c11.app/Contents/MacOS/c11"),
        declared: URL? = URL(fileURLWithPath: "/Applications/c11.app/Contents/MacOS/c11")
    ) -> SingleInstancePolicy.ProcessDescriptor {
        .init(pid: pid, bundleIdentifier: bundleIdentifier, launchDate: launchDate,
              isTerminated: terminated, isFinishedLaunching: finished,
              executableURL: actual, bundleExecutableURL: declared)
    }

    func testOldestRealApplicationWinsRegardlessOfScanOrder() {
        let current = process(300, launchDate: Date(timeIntervalSince1970: 30))
        let oldest = process(200, launchDate: Date(timeIntervalSince1970: 10))
        let intermediate = process(100, launchDate: Date(timeIntervalSince1970: 20))
        for running in [[oldest, intermediate], [intermediate, oldest]] {
            XCTAssertEqual(SingleInstancePolicy.incumbent(current: current, running: running)?.pid, oldest.pid)
        }
        XCTAssertNil(SingleInstancePolicy.incumbent(current: oldest, running: [current, intermediate]))
    }

    func testEqualLaunchDatesChooseOneDeterministicWinner() {
        let lowerPID = process(101)
        let higherPID = process(102)
        XCTAssertNil(SingleInstancePolicy.incumbent(current: lowerPID, running: [higherPID]))
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: higherPID, running: [lowerPID])?.pid, lowerPID.pid)
    }

    func testCurrentPIDTerminatedAppsAndDifferentTagsDoNotConflict() {
        let current = process(100)
        let running = [
            process(100, launchDate: nil, finished: true),
            process(101, terminated: true, finished: true),
            process(102, bundleIdentifier: "com.stage11.c11", finished: true),
            process(103, bundleIdentifier: "com.stage11.c11.debug.other-tag", finished: true)
        ]
        XCTAssertNil(SingleInstancePolicy.incumbent(current: current, running: running))
    }

    func testMissingRequiredIdentityMetadataAndNonFileURLsAreIgnored() {
        let current = process(200)
        let incomplete = [
            process(1, bundleIdentifier: nil),
            process(2, bundleIdentifier: ""),
            process(3, actual: nil),
            process(4, declared: nil),
            process(5, actual: URL(string: "https://example.invalid/c11")),
            process(6, declared: URL(string: "https://example.invalid/c11")),
            process(0), process(-1)
        ]
        for candidate in incomplete {
            XCTAssertFalse(SingleInstancePolicy.isRealMainApplication(candidate, matchingBundleIdentifier: bundleID))
        }
        XCTAssertNil(SingleInstancePolicy.incumbent(current: current, running: incomplete))
    }

    func testHelpersAndEmbeddedCLIAreNeverIncumbents() {
        let current = process(200)
        let helper = process(1, actual: URL(fileURLWithPath: "/Applications/c11.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
        let cliURL = URL(fileURLWithPath: "/Applications/c11.app/Contents/Resources/bin/c11")
        let legacyCLIURL = URL(fileURLWithPath: "/Applications/c11.app/Contents/Resources/bin/cmux")
        let candidates = [
            helper,
            process(2, actual: cliURL),
            process(3, actual: cliURL, declared: cliURL),
            process(4, actual: legacyCLIURL, declared: legacyCLIURL)
        ]
        XCTAssertNil(SingleInstancePolicy.incumbent(current: current, running: candidates))
        for candidate in candidates {
            XCTAssertFalse(SingleInstancePolicy.isRealMainApplication(candidate, matchingBundleIdentifier: bundleID))
        }
    }

    func testFinishedIncumbentWinsWhenLaunchDatesAreMissing() {
        let newcomer = process(100, launchDate: nil)
        let established = process(200, launchDate: nil, finished: true)
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: newcomer, running: [established])?.pid, established.pid)
        XCTAssertNil(SingleInstancePolicy.incumbent(current: established, running: [newcomer]))
    }

    func testFinishedIncumbentTakesPrecedenceOverOlderUnfinishedProcess() {
        let olderUnfinished = process(100, launchDate: Date(timeIntervalSince1970: 10))
        let established = process(200, launchDate: Date(timeIntervalSince1970: 20), finished: true)
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: olderUnfinished, running: [established])?.pid, established.pid)
        XCTAssertNil(SingleInstancePolicy.incumbent(current: established, running: [olderUnfinished]))
    }

    func testUnknownLaunchDateIsConservativelyOldestWithinTheSameCompletionState() {
        let unknown = process(200, launchDate: nil)
        let known = process(100, launchDate: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: known, running: [unknown])?.pid, unknown.pid)
        XCTAssertNil(SingleInstancePolicy.incumbent(current: unknown, running: [known]))
    }

    func testTwoUnknownDateContendersCannotBothYield() {
        let first = process(100, launchDate: nil)
        let second = process(101, launchDate: nil)
        XCTAssertNil(SingleInstancePolicy.incumbent(current: first, running: [second]))
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: second, running: [first])?.pid, first.pid)
    }

    func testCopiedAppAndSymlinkedBundleUseTheirOwnDeclaredMainExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c11-single-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeBundle(at: root.appendingPathComponent("Original.app"))
        let copied = root.appendingPathComponent("Copied.app")
        try FileManager.default.copyItem(at: original, to: copied)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: copied)
        let originalExecutable = try XCTUnwrap(Bundle(url: original)?.executableURL)
        let copiedExecutable = try XCTUnwrap(Bundle(url: copied)?.executableURL)
        let symlinkExecutable = alias.appendingPathComponent("Contents/MacOS/c11")
        let current = process(200, actual: originalExecutable, declared: originalExecutable)
        let copy = process(100, actual: copiedExecutable, declared: copiedExecutable)
        XCTAssertNotEqual(copiedExecutable, originalExecutable)
        XCTAssertEqual(SingleInstancePolicy.incumbent(current: current, running: [copy])?.pid, copy.pid)
        XCTAssertTrue(SingleInstancePolicy.isRealMainApplication(
            process(101, actual: symlinkExecutable, declared: copiedExecutable), matchingBundleIdentifier: bundleID))
        XCTAssertTrue(SingleInstancePolicy.isRealMainApplication(
            process(102, actual: copiedExecutable, declared: symlinkExecutable), matchingBundleIdentifier: bundleID))
        XCTAssertFalse(SingleInstancePolicy.isRealMainApplication(
            process(103, actual: copiedExecutable, declared: originalExecutable), matchingBundleIdentifier: bundleID))
    }

    private func makeBundle(at url: URL) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/c11")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable identity only".utf8).write(to: executable)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "c11",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}

/// C11-347: socket password mode through the connection loop `handleClient`
/// runs, over a real socketpair. Each conversation is written in full and the
/// client half-closes before the loop starts, so the loop serves every line and
/// stops at EOF on the test thread: no listener, no second thread, no waiting.
/// Every controller is a fresh one that reads only the password the test gives it.
@MainActor
final class SocketPasswordModeTests: XCTestCase {
    private let authRequired = "ERROR: Authentication required — send auth <password> first"
    private var tempDir: URL!

    /// Counts Keychain reads; only touched on the test thread.
    private final class KeychainStub: @unchecked Sendable {
        let password: String?
        var reads = 0
        init(_ password: String?) { self.password = password }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The lazy Keychain fallback is cached once per process.
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-socket-password-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    func testUnauthenticatedCommandsAreRejectedAndNeverExecuted() throws {
        let controller = try makeController(filePassword: "hunter2")
        let session = try converse(controller, [
            "ping",
            #"{"id":7,"method":"system.ping","params":{}}"#,
            "new_workspace",
            #"{"id":8,"method":"workspace.create","params":{}}"#,
        ])
        XCTAssertEqual(session.executed, [])
        XCTAssertEqual(session.responses.count, 4)
        XCTAssertEqual(session.responses.first, authRequired)
        try assertV2Error(session.responses[1], id: 7, code: "auth_required")
        XCTAssertEqual(session.responses[2], authRequired)
        try assertV2Error(session.responses[3], id: 8, code: "auth_required")
    }

    func testWrongOrMissingPasswordIsRejectedAndLeavesTheConnectionLocked() throws {
        let controller = try makeController(filePassword: "hunter2")
        let session = try converse(controller, [
            "auth not-the-password",
            "auth HUNTER2",
            "auth",
            "ping",
            #"{"id":3,"method":"auth.login","params":{"password":"hunter"}}"#,
            #"{"id":4,"method":"auth.login","params":{}}"#,
            #"{"id":5,"method":"system.ping","params":{}}"#,
        ])
        XCTAssertEqual(session.executed, [])
        XCTAssertEqual(session.responses.count, 7)
        XCTAssertEqual(Array(session.responses.prefix(4)), [
            "ERROR: Invalid password",
            "ERROR: Invalid password",
            "ERROR: Missing password. Usage: auth <password>",
            authRequired,
        ])
        try assertV2Error(session.responses[4], id: 3, code: "auth_failed")
        try assertV2Error(session.responses[5], id: 4, code: "invalid_params")
        try assertV2Error(session.responses[6], id: 5, code: "auth_required")
    }

    func testCorrectPasswordAuthenticatesTheRestOfTheConnection() throws {
        let controller = try makeController(filePassword: "hunter2")

        let v1 = try converse(controller, ["auth hunter2", "ping"])
        XCTAssertEqual(v1.responses, ["OK: Authenticated", "PONG"])
        XCTAssertEqual(v1.executed, ["ping"])

        let ping = #"{"id":2,"method":"system.ping","params":{}}"#
        let v2 = try converse(controller, [#"{"id":1,"method":"auth.login","params":{"password":"hunter2"}}"#, ping])
        XCTAssertEqual(v2.executed, [ping])
        XCTAssertEqual(v2.responses.count, 2)
        let login = try jsonObject(v2.responses.first ?? "")
        XCTAssertEqual(login["id"] as? Int, 1)
        XCTAssertEqual(login["ok"] as? Bool, true)
        XCTAssertEqual((login["result"] as? [String: Any])?["authenticated"] as? Bool, true)
        let pong = try jsonObject(v2.responses[1])
        XCTAssertEqual(pong["ok"] as? Bool, true, v2.responses[1])
        XCTAssertEqual((pong["result"] as? [String: Any])?["pong"] as? Bool, true, v2.responses[1])
    }

    func testAuthenticationEndsWithItsConnection() throws {
        let controller = try makeController(filePassword: "hunter2")
        XCTAssertEqual(try converse(controller, ["auth hunter2", "ping"]).responses, ["OK: Authenticated", "PONG"])

        let next = try converse(controller, ["ping"])
        XCTAssertEqual(next.responses, [authRequired])
        XCTAssertEqual(next.executed, [])
    }

    func testPasswordModeWithoutAPasswordRejectsEveryLogin() throws {
        let keychain = KeychainStub(nil)
        let controller = try makeController(keychain: keychain)
        let session = try converse(controller, [
            "auth anything",
            #"{"id":6,"method":"auth.login","params":{"password":"anything"}}"#,
            "ping",
        ])
        XCTAssertEqual(session.executed, [])
        XCTAssertEqual(session.responses.count, 3)
        XCTAssertEqual(session.responses.first, "ERROR: Password mode is enabled but no socket password is configured in Settings.")
        try assertV2Error(session.responses[1], id: 6, code: "auth_unconfigured")
        XCTAssertEqual(session.responses[2], authRequired)
        XCTAssertEqual(keychain.reads, 1, "the legacy Keychain item is read once, then cached")
    }

    /// The shipped order: environment, then password file, then legacy Keychain.
    func testExpectedPasswordFollowsTheShippedSourceOrder() throws {
        let unusedKeychain = KeychainStub("keychain-secret")
        let envFirst = try makeController(
            environment: [SocketControlSettings.socketPasswordEnvKey: "env-secret"],
            filePassword: "file-secret",
            keychain: unusedKeychain
        )
        XCTAssertEqual(
            try converse(envFirst, ["auth file-secret", "auth keychain-secret", "auth env-secret"]).responses,
            ["ERROR: Invalid password", "ERROR: Invalid password", "OK: Authenticated"]
        )

        let fileSecond = try makeController(filePassword: "file-secret", keychain: unusedKeychain)
        XCTAssertEqual(
            try converse(fileSecond, ["auth keychain-secret", "auth file-secret"]).responses,
            ["ERROR: Invalid password", "OK: Authenticated"]
        )
        XCTAssertEqual(unusedKeychain.reads, 0, "a configured environment or file never reaches the Keychain")

        let keychain = KeychainStub("keychain-secret")
        let keychainLast = try makeController(keychain: keychain)
        XCTAssertEqual(
            try converse(keychainLast, ["auth file-secret", "auth keychain-secret", "ping"]).responses,
            ["ERROR: Invalid password", "OK: Authenticated", "PONG"]
        )
        XCTAssertEqual(keychain.reads, 1)
    }

    func testSwitchingToPasswordModeLocksAnOpenConnection() throws {
        let controller = try makeController(mode: .automation, filePassword: "hunter2")
        let session = try converse(controller, ["ping", "ping"]) { _ in
            // The operator picks password mode while this connection is open.
            controller.accessMode = .password
        }
        XCTAssertEqual(session.responses, ["PONG", authRequired])
        XCTAssertEqual(session.executed, ["ping"])
    }

    func testUnauthenticatedMarkdownWatchStreamIsRejectedAndEndsTheConnection() throws {
        let controller = try makeController(filePassword: "hunter2")
        let session = try converse(controller, [
            #"{"id":9,"method":"markdown.visible","params":{"watch":true}}"#,
            "auth hunter2",
        ])
        // The stream bypasses `execute`; the auth_required reply is the check.
        XCTAssertEqual(session.responses.count, 1, "a refused stream closes the connection: \(session.responses)")
        try assertV2Error(session.responses.first ?? "", id: 9, code: "auth_required")
    }

    // MARK: - Harness

    private func makeController(
        mode: SocketControlMode = .password,
        environment: [String: String] = [:],
        filePassword: String? = nil,
        keychain: KeychainStub = KeychainStub(nil)
    ) throws -> TerminalController {
        let fileURL = tempDir.appendingPathComponent("socket-control-password-\(UUID().uuidString)", isDirectory: false)
        if let filePassword {
            try SocketControlPasswordStore.savePassword(filePassword, fileURL: fileURL)
        }
        let controller = TerminalController.makeForTesting(socketPasswordSource: .init(
            environment: { environment },
            fileURL: fileURL,
            loadKeychainPassword: {
                keychain.reads += 1
                return keychain.password
            }
        ))
        controller.accessMode = mode
        return controller
    }

    /// One connection: sends `commands`, half-closes, serves to EOF, and returns
    /// each response line plus every command that reached the real executor.
    private func converse(
        _ controller: TerminalController,
        _ commands: [String],
        onExecute: ((String) -> Void)? = nil
    ) throws -> (responses: [String], executed: [String]) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw posixError("socketpair") }
        let client = fds[0]
        let server = fds[1]
        defer { close(client) }

        let request = Array(commands.map { $0 + "\n" }.joined().utf8)
        guard write(client, request, request.count) == request.count, shutdown(client, SHUT_WR) == 0 else {
            close(server)
            throw posixError("write")
        }

        var executed: [String] = []
        controller.serveClientCommandLines(
            socket: server,
            callerTTYDevice: nil,
            shouldContinue: { true },
            execute: { command in
                executed.append(command)
                let response = controller.processCommandUsingSocketExecutionPolicy(command)
                onExecute?(command)
                return response
            }
        )
        close(server)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count < 0 { throw posixError("read") }
            if count == 0 { break }
            output.append(contentsOf: buffer[0..<count])
        }
        var lines = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "", "every response ends with a newline")
        lines.removeLast()
        return (lines, executed)
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
    }

    private func assertV2Error(_ line: String, id: Int, code: String, file: StaticString = #filePath, line sourceLine: UInt = #line) throws {
        let object = try jsonObject(line)
        XCTAssertEqual(object["id"] as? Int, id, line, file: file, line: sourceLine)
        XCTAssertEqual(object["ok"] as? Bool, false, line, file: file, line: sourceLine)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, code, line, file: file, line: sourceLine)
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"
        ])
    }
}
