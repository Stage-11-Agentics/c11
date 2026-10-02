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

/// `LaunchResumePicker.resolveEffectivePolicy` — QA launch overrides win; a
/// local dev build replaces the default `.ask` picker with silent `.always`
/// restore; an explicit operator policy is always honored.
final class LaunchResumeGateTests: XCTestCase {
    func testQAResumeForcesAlways() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .on(.resume), persisted: .ask, isLocalDevBuild: false),
            .always)
    }

    func testQAFreshForcesNever() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .on(.fresh), persisted: .ask, isLocalDevBuild: false),
            .never)
    }

    func testDevBuildTurnsAskIntoSilentAlways() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .ask, isLocalDevBuild: true),
            .always)
    }

    func testReleaseBuildKeepsAskPicker() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .ask, isLocalDevBuild: false),
            .ask)
    }

    func testExplicitNeverHonoredEvenOnDevBuild() {
        // A dev build must not resurrect a session the operator opted out of.
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .never, isLocalDevBuild: true),
            .never)
    }

    func testExplicitAlwaysHonored() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .always, isLocalDevBuild: false),
            .always)
    }
}

// MARK: - C11-155: bind-time socket stomp

/// The incident: a staging/debug build launched from a prod c11 pane inherits
/// prod's `CMUX_SOCKET_PATH` and would bind (unlinking) prod's *live* socket.
/// These tests cover the resolution-layer guard (don't adopt a foreign channel's
/// shared default) and the per-bundle namespacing defense-in-depth.
final class SocketCollisionResolutionTests: XCTestCase {

    func testStagingDoesNotAdoptInheritedProdSocketPath() {
        // The exact incident: staging bundle, ambient CMUX_SOCKET_PATH == prod's
        // shared socket. Must fall through to staging's own default, never prod's.
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath],
            bundleIdentifier: "com.stage11.c11.staging.rel.v0.54.0",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, "/tmp/c11-staging.sock")
        XCTAssertNotEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testDebugDoesNotAdoptInheritedStagingSharedSocketPath() {
        // Cross-channel inheritance the other direction (debug from a staging pane).
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/c11-staging.sock"],
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, "/tmp/c11-debug.sock")
    }

    func testExplicitOptInStillAdoptsForeignPath() {
        // CMUX_ALLOW_SOCKET_OVERRIDE is the intentional escape hatch (used by
        // scripts/test-unit-local.sh) and must still win.
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.stage11.c11.staging",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testTaggedStagingOverrideStillHonored() {
        // A tag-specific override path is launch-script intent, not inheritance,
        // and is not a shared default — the tagged-build workflow is unaffected.
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/c11-staging-my-tag.sock"],
            bundleIdentifier: "com.stage11.c11.staging.my-tag",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/c11-staging-my-tag.sock")
    }

    func testForeignSharedDefaultDetection() {
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath(
            SocketControlSettings.stableDefaultSocketPath))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-staging.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-debug.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-nightly.sock"))
        // Tag-specific paths are NOT shared defaults.
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-staging-my-tag.sock"))
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-debug-feat-x.sock"))
    }

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
