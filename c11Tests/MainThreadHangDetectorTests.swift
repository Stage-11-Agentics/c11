import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure, in-process tests for `MainThreadHangDetector` — the stall/recovery
/// state machine behind `MainThreadHangMonitor`. Timestamps are injected, so
/// these exercise real decision behavior without threads or a wall clock.
final class MainThreadHangDetectorTests: XCTestCase {

    // Decisions carry Doubles derived from subtraction, so compare with
    // tolerance rather than exact equality.
    private func assertCapture(
        _ decision: MainThreadHangDetector.Decision,
        gapMs: Double, recapture: Bool,
        _ file: StaticString = #filePath, _ line: UInt = #line
    ) {
        guard case let .capture(actualGap, actualRecapture) = decision else {
            return XCTFail("expected .capture, got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(actualGap, gapMs, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actualRecapture, recapture, file: file, line: line)
    }

    private func assertRecovered(
        _ decision: MainThreadHangDetector.Decision,
        durationMs: Double,
        _ file: StaticString = #filePath, _ line: UInt = #line
    ) {
        guard case let .recovered(actual) = decision else {
            return XCTFail("expected .recovered, got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(actual, durationMs, accuracy: 0.5, file: file, line: line)
    }

    // MARK: - No hang

    func testHealthyHeartbeatsNeverFire() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Main acks ~250ms before each tick: gap stays ~250ms, well under threshold.
        var t = 100.0
        for _ in 0..<40 {
            XCTAssertEqual(d.evaluate(nowUptime: t, lastAckUptime: t - 0.25), .none)
            t += 0.25
        }
        XCTAssertFalse(d.isInEpisode)
    }

    func testGapBelowThresholdDoesNotFire() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // 1.9s gap — under the 2s threshold.
        XCTAssertEqual(d.evaluate(nowUptime: 110.0, lastAckUptime: 108.1), .none)
        XCTAssertFalse(d.isInEpisode)
    }

    // MARK: - Hang onset

    func testCrossingThresholdEmitsFirstCapture() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // ack frozen at t=100; by t=102.2 the gap is 2200ms.
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        XCTAssertTrue(d.isInEpisode)
    }

    func testFirstCaptureFiresExactlyOncePerEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        // Still hung, but not yet time to re-snapshot (< 5s since last capture).
        XCTAssertEqual(d.evaluate(nowUptime: 103.0, lastAckUptime: 100.0), .none)
        XCTAssertEqual(d.evaluate(nowUptime: 105.0, lastAckUptime: 100.0), .none)
    }

    // MARK: - Recapture while still hung

    func testRecaptureAfterIntervalWhileStillHung() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        // 5s after the first capture (t=107.2): re-snapshot.
        assertCapture(d.evaluate(nowUptime: 107.2, lastAckUptime: 100.0), gapMs: 7200, recapture: true)
    }

    // MARK: - Recovery

    func testRecoveryEmitsEpisodeDuration() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Episode starts: ack frozen at 100, detected at 102.2.
        _ = d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0)
        XCTAssertTrue(d.isInEpisode)
        // Main recovers: ack jumps to 104.0 (it drained the queued ping). The
        // episode lasted from 100.0 until now (104.05) ≈ 4050ms.
        assertRecovered(d.evaluate(nowUptime: 104.05, lastAckUptime: 104.0), durationMs: 4050)
        XCTAssertFalse(d.isInEpisode)
    }

    func testRecoveryThenSecondHangIsANewEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        _ = d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0)          // hang 1 begin
        _ = d.evaluate(nowUptime: 104.05, lastAckUptime: 104.0)         // hang 1 recover
        // New stall starting from a fresh frozen ack at 200.
        assertCapture(d.evaluate(nowUptime: 202.5, lastAckUptime: 200.0), gapMs: 2500, recapture: false)
    }

    func testNoRecoveredEventWithoutAPriorEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Healthy from the start — a small gap must not be reported as recovery.
        XCTAssertEqual(d.evaluate(nowUptime: 100.1, lastAckUptime: 100.0), .none)
    }
}

/// Pure, in-process tests for `MainThreadHangSignature` — the grouping key the
/// watchdog attaches to every outbound hang report.
///
/// Fixtures are verbatim `backtrace_symbols` lines from real production reports
/// on `com.stage11.c11@0.58.0+116`, so these exercise the parser against the
/// exact text it will see rather than a tidied-up approximation.
final class MainThreadHangSignatureTests: XCTestCase {

    private func describe(_ stack: [String], ownModule: String = "c11") -> MainThreadHangDescriptor {
        MainThreadHangSignature.describe(stack: stack, ownModule: ownModule)
    }

    // MARK: - Frame parsing

    func testParseDropsFrameIndexAddressAndOffset() {
        let frame = MainThreadHangSignature.parse(
            "9   AppKit                              0x000000018c43c35c _DPSBlockUntilNextEventMatchingListInMode + 228"
        )
        XCTAssertEqual(frame, MainThreadHangSignature.Frame(
            module: "AppKit", symbol: "_DPSBlockUntilNextEventMatchingListInMode"
        ))
    }

    func testParseKeepsSymbolsThatCarryNoOffset() {
        let frame = MainThreadHangSignature.parse("0   c11   0x0000000100371b98 main")
        XCTAssertEqual(frame, MainThreadHangSignature.Frame(module: "c11", symbol: "main"))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(MainThreadHangSignature.parse(""))
        XCTAssertNil(MainThreadHangSignature.parse("   "))
        // Module with no symbol column carries nothing worth grouping on.
        XCTAssertNil(MainThreadHangSignature.parse("3   SwiftUI   0x00000001b6d4ad7c"))
    }

    // MARK: - Cause classification

    func testSynchronousXPCWaitOutranksTheLibraryThatAskedForIt() {
        // Main is parked in mach_msg, but the reason is a blocking XPC round
        // trip to LaunchServices — grouping it as "idle in mach_msg" would hide
        // the real defect.
        let d = describe([
            "0   libsystem_kernel.dylib   0x0000000180e03c34 mach_msg2_trap + 8",
            "1   libsystem_kernel.dylib   0x0000000180e0c9c0 mach_msg_overwrite + 480",
            "2   libsystem_kernel.dylib   0x0000000180e03fc0 mach_msg + 24",
            "3   libdispatch.dylib   0x0000000180ca7c64 _dispatch_mach_send_and_wait_for_reply + 548",
            "4   libdispatch.dylib   0x0000000180ca8004 dispatch_mach_send_with_result_and_wait_for_reply + 60",
            "5   libxpc.dylib   0x0000000180b21eb0 xpc_connection_send_message_with_reply_sync + 284",
            "6   LaunchServices   0x00000001813ec0b4 _ZN26LSClientToServerConnection13sendWithReplyEPv + 68",
        ])
        XCTAssertEqual(d.cause, "xpc-sync-wait")
        XCTAssertNil(d.phase)
        XCTAssertEqual(d.label, "xpc-sync-wait")
    }

    func testGenericMetadataInstantiationIsItsOwnCause() {
        // The stack C11-192 was filed on: the Swift runtime building metadata
        // for an opaque `some View` under SwiftUI.Button.body.
        let d = describe([
            "0   libswiftCore.dylib   0x0000000194571728 _ZL24_gatherGenericParametersPKN5swift23TargetContextDescriptorINS_9InProcessEEE + 1548",
            "1   libswiftCore.dylib   0x000000019457e5a4 _ZNK12_GLOBAL__N_122DecodedMetadataBuilder22createBoundGenericTypeE + 264",
            "6   libswiftCore.dylib   0x000000019456d874 swift_getTypeByMangledName + 336",
            "7   libswiftCore.dylib   0x0000000194570604 _ZL31swift_getOpaqueTypeMetadataImplN5swift15MetadataRequestE + 384",
            "8   SwiftUI   0x00000001b6d4ad7c $s7SwiftUI6ButtonV4bodyQrvg + 304",
            "9   SwiftUICore   0x000000022d9b1aa8 $s7SwiftUI16ViewBodyAccessorV06updateD02of7changedyx_SbtFyyScMYcXEfU_ + 1152",
        ])
        // SwiftUI frames are present and would otherwise win; the runtime work
        // is the actionable classification, so it has to outrank them.
        XCTAssertEqual(d.cause, "generic-metadata")
        XCTAssertNil(d.phase, "phase only narrows the swiftui-update bucket")
        XCTAssertTrue(d.topSymbol?.hasPrefix("_ZL24_gatherGenericParameters") == true)
    }

    func testIdleRunLoopIsSeparatedFromAWedgeInCompute() {
        // Verbatim shape of every `runloop-idle` report Sentry has received: the
        // mach_msg leaf is reached from the app's own outermost event loop.
        let d = describe([
            "0   libsystem_kernel.dylib   0x0000000187861c34 mach_msg2_trap + 8",
            "1   libsystem_kernel.dylib   0x000000018786a9c0 mach_msg_overwrite + 480",
            "2   libsystem_kernel.dylib   0x0000000187861fc0 mach_msg + 24",
            "3   CoreFoundation   0x00000001879630d8 __CFRunLoopServiceMachPort + 160",
            "4   CoreFoundation   0x00000001879619c4 __CFRunLoopRun + 1188",
            "9   AppKit   0x000000018c43c35c _DPSBlockUntilNextEventMatchingListInMode + 228",
            "13   AppKit   0x000000019391713c -[NSApplication run] + 368",
        ])
        XCTAssertEqual(d.cause, "runloop-idle")
    }

    /// A run loop we entered *inside* a callback is a real block, not a late
    /// heartbeat, so it must not land in the bucket that never reports.
    func testANestedRunLoopIsNotClassifiedAsIdle() {
        // c11's socket handler spinning CFRunLoopRun on main while it waits for
        // a WKWebView callback: 70 episodes across 12 pids in the local log.
        let socketCommand = describe([
            "0   libsystem_kernel.dylib   0x0000000187861c34 mach_msg2_trap + 8",
            "1   libsystem_kernel.dylib   0x000000018786a9c0 mach_msg_overwrite + 480",
            "2   libsystem_kernel.dylib   0x0000000187861fc0 mach_msg + 24",
            "3   CoreFoundation   0x00000001879630d8 __CFRunLoopServiceMachPort + 160",
            "4   CoreFoundation   0x00000001879619c4 __CFRunLoopRun + 1188",
            "6   CoreFoundation   0x00000001879c81c4 CFRunLoopRun + 64",
            "7   c11   0x0000000102a1cbd4 $s3c1118TerminalControllerC15v2AwaitCallback + 92",
            "8   c11   0x0000000102a1cc00 $s3c1118TerminalControllerC15v2RunJavaScript + 40",
        ])
        XCTAssertNotEqual(socketCommand.cause, "runloop-idle")
        XCTAssertTrue(MainThreadHangMonitor.isWorthReporting(cause: socketCommand.cause))
        XCTAssertEqual(
            socketCommand.culprit,
            "$s3c1118TerminalControllerC15v2AwaitCallback",
            "the c11 frame that entered the nested loop is what names this block"
        )

        // A modal alert's nested loop: 4,747 captures in the local log, up to
        // 6.8 hours each, previously filed as benign idle.
        let modalAlert = describe([
            "0   libsystem_kernel.dylib   0x0000000187861c34 mach_msg2_trap + 8",
            "1   libsystem_kernel.dylib   0x000000018786a9c0 mach_msg_overwrite + 480",
            "2   libsystem_kernel.dylib   0x0000000187861fc0 mach_msg + 24",
            "3   CoreFoundation   0x00000001879630d8 __CFRunLoopServiceMachPort + 160",
            "4   CoreFoundation   0x00000001879619c4 __CFRunLoopRun + 1188",
            "6   HIToolbox   0x000000019c2db560 RunCurrentEventLoopInMode + 320",
            "9   AppKit   0x000000018c43c35c -[NSApplication _doModalLoop:peek:] + 228",
            "11   c11   0x0000000102a1cbd4 $s3c1112BrowserPanelC24presentInsecureHTTPAlert + 64",
        ])
        XCTAssertNotEqual(modalAlert.cause, "runloop-idle")
        XCTAssertTrue(MainThreadHangMonitor.isWorthReporting(cause: modalAlert.cause))
    }

    func testSwiftUIGraphWorkIsNarrowedByHostPhase() {
        let layout = describe([
            "0   AttributeGraph   0x00000001b73c6384 _ZN2AG5Graph11UpdateStack6updateEv + 496",
            "1   AttributeGraph   0x00000001b73c6aec _ZN2AG5Graph16update_attributeE + 352",
            "2   SwiftUICore   0x000000022e87ed7c $s7SwiftUI25ViewGraphRootValueUpdaterPAAE6render8interval + 872",
            "3   SwiftUI   0x00000001b64e46b0 $s7SwiftUI13NSHostingViewC6layoutyyF + 480",
        ])
        XCTAssertEqual(layout.cause, "swiftui-update")
        XCTAssertEqual(layout.phase, "hosting-layout")
        XCTAssertEqual(layout.label, "swiftui-update/hosting-layout")

        let transaction = describe([
            "0   AttributeGraph   0x00000001b73c6384 _ZN2AG8Subgraph6updateEj + 668",
            "1   SwiftUICore   0x0000000236eb37a0 $s7SwiftUI9GraphHostC17flushTransactionsyyF + 180",
            "2   SwiftUI   0x00000001bf07a2dc $s7SwiftUI13NSHostingViewC16beginTransactionyyFyycfU_ + 24",
        ])
        XCTAssertEqual(transaction.phase, "hosting-begin-transaction")

        // The two must not collapse together — they are different bugs.
        XCTAssertNotEqual(layout.fingerprint, transaction.fingerprint)
    }

    func testUnrelatedCausesNeverShareAFingerprint() {
        let stacks: [[String]] = [
            ["0   libsystem_kernel.dylib   0x1 mach_msg2_trap + 8",
             "3   libdispatch.dylib   0x2 _dispatch_mach_send_and_wait_for_reply + 548"],
            ["0   libswiftCore.dylib   0x3 swift_getTypeByMangledName + 336"],
            ["0   libsystem_kernel.dylib   0x4 psynch_mutexwait + 8"],
            ["0   CoreText   0x5 _ZN5TFont8SetFlagsEjPK18__CTFontDescriptor + 380",
             "1   AppKit   0x6 -[NSView layout] + 96"],
            ["0   libsystem_kernel.dylib   0x7 mach_msg2_trap + 8",
             "3   CoreFoundation   0x8 __CFRunLoopServiceMachPort + 160"],
        ]
        let fingerprints = stacks.map { describe($0).fingerprint }
        XCTAssertEqual(Set(fingerprints.map { $0.joined(separator: "|") }).count, stacks.count)
        // Every fingerprint stays namespaced so hang issues are recognizable.
        for fingerprint in fingerprints {
            XCTAssertEqual(fingerprint.first, "main-thread-hang")
        }
    }

    // MARK: - Culprit

    func testCulpritIsTheDeepestOwnedFrameAndSkipsMain() {
        let d = describe([
            "0   libobjc.A.dylib   0x0000000197145844 objc_msgSend + 68",
            "1   CoreText   0x000000019a47b798 _ZN5TFont8SetFlagsEj + 380",
            "2   c11   0x0000000101728028 $s8Bonsplit11TabItemViewV17shortcutHintWidth + 1136",
            "3   c11   0x000000010171fc20 $s8Bonsplit11TabItemViewV4bodyQrvg + 3892",
            "4   c11   0x0000000100371b98 main + 64",
        ])
        XCTAssertEqual(d.culprit, "$s8Bonsplit11TabItemViewV17shortcutHintWidth")
    }

    func testCulpritIsAbsentWhenTheCaptureNeverReachesOurCode() {
        let d = describe([
            "0   libsystem_kernel.dylib   0x1 mach_msg2_trap + 8",
            "1   CoreFoundation   0x2 __CFRunLoopServiceMachPort + 160",
        ])
        XCTAssertNil(d.culprit)
    }

    func testOwnModuleTracksTheRunningExecutableName() {
        let stack = ["0   c11 DEV   0x1 $s3c1110TabManagerC26sessionAutosaveFingerprintSiyF + 12"]
        XCTAssertNil(describe(stack, ownModule: "c11").culprit)
        // A DEV build's image name differs; the caller supplies it so the
        // culprit tag keeps working outside the shipped bundle.
        XCTAssertEqual(
            describe(stack, ownModule: "c11 DEV").culprit,
            "$s3c1110TabManagerC26sessionAutosaveFingerprintSiyF"
        )
    }

    // MARK: - Degenerate input

    func testEmptyOrUnparseableCaptureStillYieldsAStableFingerprint() {
        for stack in [[], ["<no frames captured>"], ["<thread_suspend failed>"]] as [[String]] {
            let d = describe(stack)
            XCTAssertFalse(d.fingerprint.isEmpty)
            XCTAssertEqual(d.fingerprint.first, "main-thread-hang")
        }
        XCTAssertEqual(describe([]).cause, "unknown")
    }

    // MARK: - What rides along in the payload

    /// A 96-frame capture whose own-module frames all sit below the top window —
    /// the shape 73% of one 1,231-event production sample arrived in, every frame
    /// a system frame and the hang consequently unattributable.
    private func deepSwiftUIStack() -> [String] {
        var stack = (0..<40).map { "\($0)   SwiftUICore   0x\($0) $s7SwiftUI9GraphHostC16updatePreferencesyyF + \($0)" }
        stack.append("40   c11   0xaa $s3c1119VerticalTabsSidebarV4bodyQrvg + 12")
        stack += (41..<60).map { "\($0)   AppKit   0x\($0) -[NSView _layoutSubtreeWithOldSize:] + \($0)" }
        stack.append("60   c11   0xbb $s3c1111ContentViewV4bodyQrvg + 44")
        stack.append("61   c11   0xcc main + 64")
        return stack
    }

    func testReportedStackCarriesOwnFramesFromBelowTheTopWindow() {
        let reported = MainThreadHangSignature.reportedStack(deepSwiftUIStack(), ownModule: "c11")
        XCTAssertTrue(
            reported.contains { $0.contains("VerticalTabsSidebar") },
            "the frame that names the workload sits at index 40 and is the whole point of the report"
        )
        XCTAssertTrue(reported.contains { $0.contains("ContentView") })
        XCTAssertTrue(reported.contains { $0.contains("main + 64") })
        // Nothing from the elided middle rides along.
        XCTAssertFalse(reported.contains { $0.contains("_layoutSubtreeWithOldSize") })
    }

    func testReportedStackKeepsTrueIndicesAndMarksTheGap() {
        let reported = MainThreadHangSignature.reportedStack(deepSwiftUIStack(), ownModule: "c11")
        XCTAssertEqual(reported.prefix(24).count, 24)
        XCTAssertTrue(reported[0].hasPrefix("0\t"))
        XCTAssertTrue(reported[23].hasPrefix("23\t"))
        guard let gap = reported.firstIndex(where: { $0.hasPrefix("\u{2026}\t") }) else {
            return XCTFail("an elided run must be marked, or the two halves read as contiguous")
        }
        // 62 frames total, 24 kept up top, 3 own frames kept below.
        XCTAssertEqual(reported[gap], "\u{2026}\t35 frames elided")
        XCTAssertTrue(reported[gap + 1].hasPrefix("40\t"), "kept frames keep their capture index")
    }

    func testReportedStackIsUnchangedWhenTheCaptureFitsTheWindow() {
        let stack = (0..<10).map { "\($0)   SwiftUI   0x\($0) frame\($0)" }
        let reported = MainThreadHangSignature.reportedStack(stack, ownModule: "c11")
        XCTAssertEqual(reported.count, 10)
        XCTAssertFalse(reported.contains { $0.hasPrefix("\u{2026}") })
        XCTAssertEqual(reported.last, "9\t\(stack[9])")
    }

    func testReportedStackBoundsHowManyOwnFramesItAppends() {
        var stack = (0..<24).map { "\($0)   SwiftUI   0x\($0) frame\($0)" }
        stack += (24..<44).map { "\($0)   c11   0x\($0) $s3c11deep\($0)" }
        let reported = MainThreadHangSignature.reportedStack(stack, ownModule: "c11", ownFrames: 8)
        XCTAssertEqual(reported.count, 24 + 1 + 8)
        XCTAssertEqual(reported.last, "31\t\(stack[31])", "the own frames nearest the leaf are the useful ones")
    }
}

/// The run-loop-idle reporting rule.
///
/// `runloop-idle` means main is parked in `-[NSApplication run]` waiting for the
/// next event: an app ready to serve the user, not a wedge. It was 46.5% of 5,311
/// local episodes and the largest single slice of the aggregate Sentry hang issue,
/// and it carries no frame of ours, no phase and no culprit, so no report derived
/// from it can name a cause. It never reports; the local hang log and PostHog keep
/// the whole population.
final class MainThreadHangReportingRuleTests: XCTestCase {

    func testAnIdleRunLoopIsNeverWorthReporting() {
        XCTAssertFalse(MainThreadHangMonitor.isWorthReporting(
            cause: MainThreadHangSignature.runLoopIdleCause
        ))
    }

    func testEveryOtherCauseReports() {
        for cause in ["swiftui-update", "appkit", "lock-wait", "xpc-sync-wait", "generic-metadata", "other", "unknown"] {
            XCTAssertTrue(MainThreadHangMonitor.isWorthReporting(cause: cause), cause)
        }
    }
}

/// Pure, in-process tests for `SentryEventBudget` — the client-side ceiling on
/// outbound Sentry events. The org's error quota is shared across projects and
/// this plan offers no server-side per-key rate limits, so this policy is the
/// only fence; it is worth testing as behavior rather than trusting by reading.
final class SentryEventBudgetTests: XCTestCase {

    func testCrashesAreNeverThrottled() {
        var budget = SentryEventBudget(
            globalPerHour: 1, globalPerDay: 1, hangsPerHour: 1, hangsPerDay: 1
        )
        // Burn the whole non-crash budget first.
        XCTAssertTrue(budget.allow(.other, now: 100))
        XCTAssertFalse(budget.allow(.other, now: 101))
        // Crashes still get through, unbounded, and cost no budget.
        for i in 0..<50 {
            XCTAssertTrue(budget.allow(.crash, now: 102 + Double(i)))
        }
        XCTAssertEqual(budget.droppedTotal, 1)
    }

    func testHangStormIsCappedPerHour() {
        var budget = SentryEventBudget(
            globalPerHour: 100, globalPerDay: 500, hangsPerHour: 3, hangsPerDay: 15
        )
        // A wedged app recaptures every 5s: 60 attempts inside one hour.
        var allowed = 0
        for i in 0..<60 where budget.allow(.hang, now: 100 + Double(i) * 5) {
            allowed += 1
        }
        XCTAssertEqual(allowed, 3)
        XCTAssertEqual(budget.droppedHangs, 57)
    }

    func testHangBudgetRefillsAfterTheWindowSlides() {
        var budget = SentryEventBudget(
            globalPerHour: 100, globalPerDay: 500, hangsPerHour: 2, hangsPerDay: 15
        )
        XCTAssertTrue(budget.allow(.hang, now: 100))
        XCTAssertTrue(budget.allow(.hang, now: 200))
        XCTAssertFalse(budget.allow(.hang, now: 300))
        // Just past an hour after the first two, capacity is back.
        XCTAssertTrue(budget.allow(.hang, now: 3701))
    }

    func testDailyCapBoundsAWholeDayOfHourlyRefills() {
        var budget = SentryEventBudget(
            globalPerHour: 100, globalPerDay: 500, hangsPerHour: 3, hangsPerDay: 15
        )
        // One attempt per minute for 24h — hourly capacity keeps refilling, so
        // only the daily cap can bound the total.
        var allowed = 0
        for minute in 0..<(24 * 60) where budget.allow(.hang, now: Double(minute) * 60) {
            allowed += 1
        }
        XCTAssertEqual(allowed, 15)
    }

    func testHangsAlsoConsumeTheGlobalBudget() {
        var budget = SentryEventBudget(
            globalPerHour: 2, globalPerDay: 100, hangsPerHour: 10, hangsPerDay: 100
        )
        XCTAssertTrue(budget.allow(.hang, now: 100))
        XCTAssertTrue(budget.allow(.hang, now: 110))
        // Hang budget still has room, but the global ceiling is spent — and it
        // must apply to every kind, or one category could starve the others.
        XCTAssertFalse(budget.allow(.hang, now: 120))
        XCTAssertFalse(budget.allow(.other, now: 130))
    }

    func testClassificationDrivesWhichAllowanceAnEventSpends() {
        // `beforeSend` sees only the level and the tags, so the whole policy
        // rests on this mapping being right.
        XCTAssertEqual(
            SentryEventBudget.Kind.classify(isFatal: true, categoryTag: nil), .crash
        )
        // A fatal event stays exempt whatever else it is tagged as.
        XCTAssertEqual(
            SentryEventBudget.Kind.classify(isFatal: true, categoryTag: sentryHangCategory), .crash
        )
        XCTAssertEqual(
            SentryEventBudget.Kind.classify(isFatal: false, categoryTag: sentryHangCategory), .hang
        )
        XCTAssertEqual(
            SentryEventBudget.Kind.classify(isFatal: false, categoryTag: "socket"), .other
        )
        XCTAssertEqual(
            SentryEventBudget.Kind.classify(isFatal: false, categoryTag: nil), .other
        )
    }

    func testAHangReportSpendsExactlyOneSlotOfTheGlobalAllowance() {
        // Regression for a double-charge found by running the real app (C11-190):
        // the hang watchdog consulted the budget and then `beforeSend` consulted
        // it again for the same event, so three hang reports quietly cost six of
        // the twenty hourly slots and the ceiling behaved as 17.
        var budget = SentryEventBudget(
            globalPerHour: 20, globalPerDay: 100, hangsPerHour: 3, hangsPerDay: 15
        )
        var allowed = 0
        // Three hangs, then non-hang events until the global ceiling refuses one.
        for i in 0..<3 where budget.allow(.hang, now: Double(i)) { allowed += 1 }
        XCTAssertEqual(allowed, 3)
        for i in 0..<17 {
            XCTAssertTrue(
                budget.allow(.other, now: Double(100 + i)),
                "global allowance exhausted early at event \(allowed + i + 1) of 20"
            )
        }
        XCTAssertFalse(budget.allow(.other, now: 200))
    }

    func testDeniedEventsDoNotConsumeBudget() {
        var budget = SentryEventBudget(
            globalPerHour: 10, globalPerDay: 100, hangsPerHour: 1, hangsPerDay: 1
        )
        XCTAssertTrue(budget.allow(.hang, now: 100))
        // The hang allowance is now spent. Ten further hang attempts are denied,
        // and those denials must not spend the global allowance — otherwise a
        // storm in one category silently starves every other event kind.
        for i in 0..<10 { XCTAssertFalse(budget.allow(.hang, now: 200 + Double(i))) }
        for i in 0..<9 { XCTAssertTrue(budget.allow(.other, now: 300 + Double(i))) }
        XCTAssertFalse(budget.allow(.other, now: 400))
    }
}
