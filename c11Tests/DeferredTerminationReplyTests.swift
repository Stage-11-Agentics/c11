import CoreServices
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class DeferredTerminationReplyTests: XCTestCase {
    func testUpdateRestartRepliesOnceDespiteSheetDismissalReentry() async {
        await MainActor.run {
            var events: [String] = []
            let pending = DeferredTerminationReply { events.append("reply:\($0)") }
            XCTAssertTrue(pending.resolve(true) {
                events.append("dismiss")
                XCTAssertFalse(pending.resolve(false), "A sheet completion cannot cancel an accepted restart")
            })
            XCTAssertFalse(pending.resolve(true), "A second updater notification must not reply again")
            XCTAssertEqual(events, ["dismiss", "reply:true"])
        }
    }

    func testVanishedWindowCancelsOnceAndLateCallbackCannotQuit() async {
        await MainActor.run {
            var replies: [Bool] = []
            let pending = DeferredTerminationReply { replies.append($0) }
            XCTAssertTrue(pending.resolve(false))
            XCTAssertFalse(pending.resolve(true))
            XCTAssertEqual(replies, [false])
        }
    }

    func testOldSheetCompletionCannotConsumeNextQuitRequest() async {
        await MainActor.run {
            var replies: [Bool] = []
            let old = DeferredTerminationReply { replies.append($0) }
            old.resolve(false)
            let next = DeferredTerminationReply { replies.append($0) }
            XCTAssertFalse(old.resolve(true))
            XCTAssertTrue(next.resolve(true))
            XCTAssertEqual(replies, [false, true])
        }
    }

    // MARK: C11H-267, Keep Terminals After Quit off

    /// The stop replies once when its work returns; a second Quit (or an
    /// update relaunch's terminate) during it joins and starts nothing.
    @MainActor
    func testQuitStopRepliesOnceAndASecondQuitJoins() async {
        let stop = QuitTerminalStop()
        var works = 0
        var replies: [String] = []
        let done = expectation(description: "reply")
        let gate = AsyncGate()
        XCTAssertTrue(stop.begin(seconds: 5, work: { works += 1; await gate.wait(); return "ends=2" },
                                 onFinish: { summary, timedOut in replies.append("\(summary ?? "-") \(timedOut)"); done.fulfill() }))
        XCTAssertEqual(stop.state, .stopping)
        XCTAssertFalse(stop.begin(seconds: 5, work: { works += 1; return "second" },
                                  onFinish: { _, _ in replies.append("second") }), "a second Quit joins the stop in flight")
        await gate.open()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(works, 1)
        XCTAssertEqual(replies, ["ends=2 false"])
        XCTAssertEqual(stop.state, .finished)
        XCTAssertFalse(stop.begin(seconds: 5, work: { "late" }, onFinish: { _, _ in replies.append("late") }))
    }

    /// A core that never answers: the Quit still replies at the bound, and
    /// main keeps running other work while it waits.
    @MainActor
    func testQuitStopRepliesAtTheBoundWhenACoreNeverAnswersAndMainStaysFree() async {
        let stop = QuitTerminalStop()
        var order: [String] = []
        let done = expectation(description: "reply")
        stop.begin(seconds: 0.3, work: { await AsyncGate().wait(); return "never" },
                   onFinish: { summary, timedOut in
            order.append("reply timedOut=\(timedOut) summary=\(summary ?? "nil")")
            done.fulfill()
        })
        DispatchQueue.main.async { order.append("main ran") }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(order, ["main ran", "reply timedOut=true summary=nil"])
    }

    /// A clean restart carries its intent into the quit decision, so the
    /// switch being off does not end terminals; the next ordinary quit does.
    func testCleanRestartKeepsTerminalsWithTheSwitchOff() {
        let name = "QuitTerminalsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: QuitTerminalsSettings.keepTerminalsKey)
        _ = QuitConfirmationPolicy.consumeBypass()

        QuitConfirmationPolicy.armForCleanRestart()
        let restart = QuitTerminalsSettings.decide(defaults: defaults, quitReason: nil, terminationSignal: false)
        XCTAssertEqual(restart, .init(bypassArmed: true, endsTerminals: false))

        let quit = QuitTerminalsSettings.decide(defaults: defaults, quitReason: nil, terminationSignal: false)
        XCTAssertEqual(quit, .init(bypassArmed: false, endsTerminals: true), "the restart's bypass is spent")
        XCTAssertFalse(QuitTerminalsSettings.decide(defaults: defaults, quitReason: nil, terminationSignal: true).endsTerminals)
        XCTAssertFalse(QuitTerminalsSettings.decide(defaults: defaults, quitReason: OSType(kAEShutDown),
                                                    terminationSignal: false).endsTerminals)
        defaults.set(true, forKey: QuitTerminalsSettings.keepTerminalsKey)
        XCTAssertFalse(QuitTerminalsSettings.decide(defaults: defaults, quitReason: nil, terminationSignal: false).endsTerminals)
    }

    /// End All's selection runs first: this install's local and linked-machine
    /// terminals get an end, another install's do not; only then do this
    /// app's own local cores stop.
    @MainActor
    func testQuitEndsOwnLocalAndRemoteTerminalsBeforeStoppingLocalCores() async {
        let mine = "mine-install", theirs = "other-install"
        let ownLocal = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "local-core", localAddress: "t1"), state: .running,
            labels: [HCOwnerLabels.app: mine])
        let ownRemote = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "studio", localAddress: "t2"), state: .running,
            labels: [HCOwnerLabels.app: mine], machineName: "studio", machineAvailability: .connected)
        let otherLocal = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "local-core", localAddress: "t3"), state: .running,
            labels: [HCOwnerLabels.app: theirs])
        let otherRemote = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "studio", localAddress: "t4"), state: .running,
            labels: [HCOwnerLabels.app: theirs], machineName: "studio", machineAvailability: .connected)
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let snapshot = HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: Dictionary(uniqueKeysWithValues: [ownLocal, ownRemote, otherLocal, otherRemote].map { ($0.key, $0) }))
        var steps: [String] = []
        var ended: Set<HCTerminalKey> = []
        let ender = QuitTerminalEnder(
            identities: { HCEndAllTargets.identities(panels: [], inventory: snapshot, appInstallID: mine) },
            requestEnd: { identities in
                steps.append("end")
                ended.formUnion(identities.compactMap(\.key))
            },
            awaitEnds: { _, _ in steps.append("await"); return true },
            stopLocalCores: { _ in steps.append("stop cores"); return [0: .stopped, 1: .notRunning] })
        let summary = await ender.run(deadline: HCMonotonic.deadline(after: 2))
        XCTAssertEqual(ended, [ownLocal.key, ownRemote.key])
        XCTAssertEqual(steps, ["end", "await", "stop cores"])
        XCTAssertEqual(summary, "ends=2 settled=1 s0=stopped s1=not_running")
    }
}

/// Holds a test's work until opened.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// C11H-288: every launch shows a window. With Keep Terminals After Quit off,
/// an operator's quit ends every terminal; a TERM quit (the update path) of
/// the next launch saves those ended panels again, and the launch after it
/// restores only terminals that ended before it began. Their ends must not
/// close the last window.
final class ChildExitClosePolicyTests: XCTestCase {
    private enum Quit { case appleEvent, termSignal }

    /// Whether the terminals a launch restores are running when it starts:
    /// they are when the previous quit kept them and they were running then.
    private func restoredTerminalsRun(keepTerminals: Bool, quit: Quit, runningBeforeQuit: Bool) -> Bool {
        let ends = QuitTerminalsSettings.endsTerminals(keepTerminals: keepTerminals, relaunchBypass: false,
            quitReason: nil, terminationSignal: quit == .termSignal)
        return runningBeforeQuit && !ends
    }

    /// The last restored panel's end, in the launch's only workspace and window.
    private func lastEnd(terminalWasLiveThisRun: Bool) -> ChildExitClosePolicy.Scope {
        ChildExitClosePolicy.scope(panelCount: 1, workspaceCount: 1, isLastMainWindow: true,
                                   terminalWasLiveThisRun: terminalWasLiveThisRun)
    }

    func testSwitchOffQuitThenTermQuitKeepsAWindowOnTheNextLaunch() {
        // Operator quit with the switch off: the next launch finds every terminal ended.
        let afterOperatorQuit = restoredTerminalsRun(keepTerminals: false, quit: .appleEvent, runningBeforeQuit: true)
        XCTAssertFalse(afterOperatorQuit)
        XCTAssertEqual(lastEnd(terminalWasLiveThisRun: afterOperatorQuit), .freshWorkspace)
        // That launch is quit by TERM: its panels were already ended, so the launch after it finds them ended too.
        let afterTerm = restoredTerminalsRun(keepTerminals: false, quit: .termSignal, runningBeforeQuit: afterOperatorQuit)
        XCTAssertFalse(afterTerm)
        XCTAssertEqual(lastEnd(terminalWasLiveThisRun: afterTerm), .freshWorkspace,
                       "the launch after the TERM quit shows a window")
    }

    func testAShellExitTheOperatorSawStillClosesTheWindow() {
        // The terminals kept running across the quit, and a shell exits later in this run.
        for (keep, quit) in [(true, Quit.appleEvent), (true, .termSignal), (false, .termSignal)] {
            XCTAssertTrue(restoredTerminalsRun(keepTerminals: keep, quit: quit, runningBeforeQuit: true))
            XCTAssertEqual(lastEnd(terminalWasLiveThisRun: true), .window)
        }
    }

    func testEarlierEndsCloseOnlyTheirPanelOrWorkspace() {
        for live in [true, false] {
            XCTAssertEqual(ChildExitClosePolicy.scope(panelCount: 2, workspaceCount: 1, isLastMainWindow: true,
                                                      terminalWasLiveThisRun: live), .panel)
            XCTAssertEqual(ChildExitClosePolicy.scope(panelCount: 1, workspaceCount: 2, isLastMainWindow: true,
                                                      terminalWasLiveThisRun: live), .workspace)
            XCTAssertEqual(ChildExitClosePolicy.scope(panelCount: 1, workspaceCount: 1, isLastMainWindow: false,
                                                      terminalWasLiveThisRun: live), .window,
                           "another window still shows")
        }
    }
}
