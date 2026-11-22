import XCTest
import CryptoKit
import Darwin
import Security

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCLaunchPolicyTests: XCTestCase {
    func testOwnedTupleRejectsInheritedSocketAndXDGButPreservesOrdinaryEnvironment() throws {
        let inherited = ["HC_SOCKET": "/foreign.sock", "HC_SESSION": "default", "XDG_STATE_HOME": "/tenant/state",
                         "C11_PANEL_ID": "parent", "CMUX_SURFACE_ID": "parent", "CODEX_THREAD_ID": "parent",
                         "SSH_AUTH_SOCK": "/agent.sock", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: "c11-a", inherited: inherited)
        XCTAssertEqual(c.session, "c11-c11-a")
        XCTAssertEqual(c.socketURL.path, "/Users/test/.local/share/c11/run/c11-c11-a.sock")
        XCTAssertEqual(c.environment["HC_SOCKET"], c.socketURL.path)
        XCTAssertEqual(c.environment["HC_SESSION"], c.session)
        XCTAssertEqual(c.environment["HC_SPAWN_MS"], "10000")
        XCTAssertNil(c.environment["XDG_STATE_HOME"])
        XCTAssertNil(c.environment["C11_PANEL_ID"])
        XCTAssertNil(c.environment["CMUX_SURFACE_ID"])
        XCTAssertNil(c.environment["CODEX_THREAD_ID"])
        XCTAssertEqual(c.environment["SSH_AUTH_SOCK"], "/agent.sock")
        XCTAssertEqual(c.environment["PATH"], "/usr/bin")
    }

    func testCoreDropsInheritedTerminalOverridesButExplicitConfigRestoresThem() throws {
        let configuration = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil,
            inherited: ["VTE_VERSION": "inherited-vte", "GHOSTTY_LOG": "inherited-log"])
        XCTAssertNil(configuration.environment["VTE_VERSION"])
        XCTAssertNil(configuration.environment["GHOSTTY_LOG"])
        let overlay = HCLaunchPolicy.terminalEnvironment(managed: [:],
            configured: ["VTE_VERSION": "configured-vte", "GHOSTTY_LOG": "configured-log"], intendedXDG: [:])
        let terminal = configuration.environment.merging(overlay) { _, configured in configured }
        XCTAssertEqual(terminal["VTE_VERSION"], "configured-vte")
        XCTAssertEqual(terminal["GHOSTTY_LOG"], "configured-log")
    }

    /// C11H-41: an agent whose `c11` resolves to another build needs this build's CLI by
    /// absolute path. The panel exports it under both names; an hc terminal must keep both.
    func testHCTerminalKeepsThePathOfThisBuildsCLIUnderBothNames() {
        let cmux = "CMUX_BUNDLED_CLI_PATH"
        XCTAssertEqual(c11TwinKey(forCmuxKey: cmux), "C11_BUNDLED_CLI_PATH")
        let path = "/Applications/c11.app/Contents/Resources/bin/c11"
        let env = HCLaunchPolicy.terminalEnvironment(
            managed: [cmux: path, "C11_BUNDLED_CLI_PATH": path], configured: [:], intendedXDG: [:])
        XCTAssertEqual(env[cmux], path)
        XCTAssertEqual(env["C11_BUNDLED_CLI_PATH"], path)
    }

    func testTerminalOverlayCannotClearRuntimeIdentityAndRestoresXDG() {
        let env = HCLaunchPolicy.terminalEnvironment(managed: ["C11_PANEL_ID": "p", "TERM": "xterm-ghostty"],
            configured: ["HC_SOCKET": "", "HC_SCOPE": "other", "HC_SESSION": "default", "USER_VALUE": "kept"],
            intendedXDG: ["XDG_STATE_HOME": "/tenant/state"])
        XCTAssertFalse(env.keys.contains { $0.hasPrefix("HC_") })
        XCTAssertEqual(env["C11_PANEL_ID"], "p")
        XCTAssertEqual(env["XDG_STATE_HOME"], "/tenant/state")
        XCTAssertEqual(env["USER_VALUE"], "kept")
    }

    func testUnsafeOrOverlongTupleIsRejectedWithoutRelocation() {
        for tag in ["../default", "", "a/b", "a b", String(repeating: "a", count: 100)] {
            XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: tag, inherited: [:]))
        }
    }

    func testShimRequiresBothOwnedValues() throws {
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: [:])
        XCTAssertTrue(HCLaunchPolicy.shimTargetsOwnedCore(caller: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], configuration: c))
        XCTAssertFalse(HCLaunchPolicy.shimTargetsOwnedCore(caller: ["HC_SESSION": "default", "HC_SOCKET": c.socketURL.path], configuration: c))
        XCTAssertFalse(HCLaunchPolicy.shimTargetsOwnedCore(caller: ["HC_SESSION": c.session, "HC_SOCKET": "/foreign.sock"], configuration: c))
        XCTAssertFalse(HCLaunchPolicy.shimTargetsOwnedCore(caller: [:], configuration: c))
    }

    func testInfiniteHardLimitUsesFiniteKernelCapAndRequiresReread() throws {
        let plan = try HCFileLimitPlan(soft: 256, hard: .max, kernelCap: 245_760, infinity: .max)
        XCTAssertEqual(plan.targetSoft, 245_760)
        XCTAssertFalse(plan.verified(soft: 256, hard: .max))
        XCTAssertTrue(plan.verified(soft: 245_760, hard: .max))
        XCTAssertFalse(plan.verified(soft: 245_760, hard: 245_760))
        XCTAssertThrowsError(try HCFileLimitPlan(soft: 256, hard: 1024, kernelCap: 245_760, infinity: .max))
        let sufficient = try HCFileLimitPlan(soft: .max, hard: .max, kernelCap: 245_760, infinity: .max)
        XCTAssertEqual(sufficient.targetSoft, .max)
    }

    private func fixtureConfiguration() throws -> HCLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hc-verify-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let bytes = Data("immutable fixture".utf8)
        let binary = root.appendingPathComponent("fixture-binary")
        try bytes.write(to: binary)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let pin = HCPin(version: "fixture", archiveSHA256: "unused", executableSHA256: digest, protocolGeneration: 1)
        return HCLaunchConfiguration(executableURL: binary, session: "c11-unit", socketURL: root.appendingPathComponent("socket"),
            stateDirectory: root, intentDirectory: root.appendingPathComponent("intents"), environment: [:], pin: pin)
    }

    func testPinVerificationRejectsReplacedFileAfterHashCacheHit() async throws {
        let c = try fixtureConfiguration(), verifier = HCBuildVerifier()
        let first = try await verifier.verifyPin(c)
        let second = try await verifier.verifyPin(c)
        XCTAssertEqual(first, second)
        try Data("different fixture".utf8).write(to: c.executableURL, options: .atomic)
        do { _ = try await verifier.verifyPin(c); XCTFail("Cached hash authorized a replacement file") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch) }
    }

    func testPinVerificationRejectsSymlinksAndWritableFiles() async throws {
        let c = try fixtureConfiguration(), verifier = HCBuildVerifier()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: c.executableURL.path)
        do { _ = try await verifier.verifyPin(c); XCTFail("Writable executable authorized") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: c.executableURL.path)
        let target = c.executableURL.appendingPathExtension("target")
        try FileManager.default.moveItem(at: c.executableURL, to: target)
        try FileManager.default.createSymbolicLink(at: c.executableURL, withDestinationURL: target)
        do { _ = try await verifier.verifyPin(c); XCTFail("Symlink authorized") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch) }
    }

    func testRecoveryOwnedStateRequiresBothExactSocketAndCoreID() async throws {
        let c = try fixtureConfiguration(), verifier = HCBuildVerifier()
        try PrivateFileWriter.write(Data(c.socketURL.path.utf8), to: c.stateDirectory.appendingPathComponent("core.lock"))
        try PrivateFileWriter.write(Data(#"{"id":"owned"}"#.utf8), to: c.stateDirectory.appendingPathComponent("core.json"))
        try await verifier.validateOwnedState(c, coreID: "owned")
        do { try await verifier.validateOwnedState(c, coreID: "foreign"); XCTFail("Wrong core id authorized") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .foreignSession) }
        try PrivateFileWriter.write(Data("/other.socket".utf8), to: c.stateDirectory.appendingPathComponent("core.lock"))
        do { try await verifier.validateOwnedState(c, coreID: "owned"); XCTFail("Wrong socket authorized") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .foreignSession) }
    }

    func testProcessExitRequiresExactKernelIncarnation() async throws {
        let own = try HCBuildVerifier.processIdentity(getpid())
        XCTAssertGreaterThan(own.startTimeMicroseconds, 0)
        let observer = HCKernelProcessObserver()
        let live = await observer.hasExited(own)
        XCTAssertFalse(live)
        let recycled = await observer.hasExited(HCProcessIdentity(pid: own.pid, startTimeMicroseconds: own.startTimeMicroseconds - 1))
        XCTAssertTrue(recycled)
    }

    // MARK: the environment c11 hands a terminal (T2.4)

    /// A native terminal inherits c11's process environment; an hc terminal is
    /// spawned by a core whose environment is scrubbed of C11_*/CMUX_*/XDG_*, so
    /// the c11 launch settings must travel in the terminal's own environment.
    func testAnHcTerminalGetsTheC11LaunchSettingsANativeTerminalInherits() {
        let app = ["C11_DEBUG_LOG": "/tmp/c11-debug.log", "C11_QA_LAUNCH": "fresh", "CMUX_QA_LAUNCH": "fresh",
                   "CMUX_TAG": "t5", "XDG_STATE_HOME": "/x/state", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
        let base = HCLaunchPolicy.inheritedAppEnvironment(app)
        XCTAssertEqual(base["C11_DEBUG_LOG"], "/tmp/c11-debug.log")
        XCTAssertEqual(base["C11_QA_LAUNCH"], "fresh")
        XCTAssertEqual(base["CMUX_QA_LAUNCH"], "fresh")
        XCTAssertEqual(base["CMUX_TAG"], "t5")
        XCTAssertEqual(base["XDG_STATE_HOME"], "/x/state")
        XCTAssertNil(base["PATH"], "ordinary variables come from the core's own environment")
        XCTAssertNil(base["LANG"])

        let tuple = HCShellIntegration.launchTuple(command: nil, base: base, globalOverrides: [:],
            panel: ["C11_SOCKET_PATH": "/run/c11.sock", "CMUX_PANEL_ID": "P1", "C11_PANEL_ID": "P1"],
            mode: "none", configuration: nil)
        XCTAssertEqual(tuple.environment["C11_DEBUG_LOG"], "/tmp/c11-debug.log")
        XCTAssertEqual(tuple.environment["C11_QA_LAUNCH"], "fresh")
        XCTAssertEqual(tuple.environment["C11_SOCKET_PATH"], "/run/c11.sock")
    }

    func testPanelScopedAndHcIdentityVariablesAreNotInherited() {
        let app = ["C11_PANEL_ID": "parent", "CMUX_PANEL_ID": "parent", "C11_TAB_ID": "parent",
                   "CMUX_SURFACE_ID": "parent", "C11_WORKSPACE_ID": "parent", "CMUX_WORKSPACE_ID": "parent",
                   "C11_PANEL_NUM": "7", "C11_SURFACE_NUM": "7", "C11_AREA_ID": "a", "CMUX_PORT": "9100",
                   "CMUX_PORT_END": "9109", "CMUX_PORT_RANGE": "10",
                   "C11_HC_SESSION": "other", "C11_HC_SOCKET": "/other.sock", "HC_SESSION": "other",
                   "C11_DEBUG_LOG": "/tmp/log"]
        let base = HCLaunchPolicy.inheritedAppEnvironment(app)
        XCTAssertEqual(base, ["C11_DEBUG_LOG": "/tmp/log"],
                       "an inherited id would name another panel; hc owns its own identity")
    }

    func testWhatC11SetsForThePanelBeatsWhatItInherited() {
        let base = HCLaunchPolicy.inheritedAppEnvironment(["C11_SOCKET_PATH": "/stale.sock", "C11_DEBUG_LOG": "/tmp/log"])
        let tuple = HCShellIntegration.launchTuple(command: nil, base: base, globalOverrides: [:],
            panel: ["C11_SOCKET_PATH": "/live.sock"], mode: "none", configuration: nil)
        XCTAssertEqual(tuple.environment["C11_SOCKET_PATH"], "/live.sock")
        XCTAssertEqual(tuple.environment["C11_DEBUG_LOG"], "/tmp/log")
    }

    // MARK: C11H-34, c11's own launch environment

    private func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !HCLaunchEnvironmentScrub.namesToRemove(from: environment).contains($0.key) }
    }

    /// The reported launch: `open` from a c11 terminal that is itself inside an
    /// agent seat. Everything that names the host terminal or the launching
    /// agent goes; ordinary variables and c11's own launch settings stay.
    func testALaunchFromAC11TerminalCarriesNoHostIdentityOrAgentMarkersIntoTheApp() {
        let launch = [
            "C11_PANEL_ID": "P", "CMUX_PANEL_ID": "P", "C11_SURFACE_ID": "S", "CMUX_SURFACE_ID": "S",
            "C11_TAB_ID": "T", "C11_WORKSPACE_ID": "W", "CMUX_WORKSPACE_ID": "W", "C11_PANEL_NUM": "8",
            "C11_SOCKET_PATH": "/tmp/c11-debug-outer.sock", "CMUX_SOCKET_PATH": "/tmp/c11-debug-outer.sock",
            "C11_SHELL_INTEGRATION": "1", "CMUX_SHELL_INTEGRATION_DIR": "/app/shell", "CMUX_BUNDLED_CLI_PATH": "/app/c11",
            "C11_AGENT_TYPE": "claude-code", "CMUX_AGENT_MODEL": "m", "C11_CLAUDE_WRAPPER_REENTRY": "1",
            "C11_HC_SESSION": "outer", "C11_HC_SOCKET": "/outer.sock", "CMUX_PORT": "9100",
            "CLAUDE_ACCOUNT_HOME": "/acct", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDECODE": "1", "CODEX_THREAD_ID": "t", "CODEX_HOME": "/codex",
            "TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": "1.2",
            "PATH": "/usr/bin", "HOME": "/Users/a", "LANG": "en_US.UTF-8", "TERM": "xterm-ghostty",
            "C11_QA_LAUNCH": "fresh", "C11_DEBUG_LOG": "/tmp/log", "C11_TAG": "t5", "XDG_DATA_DIRS": "/x",
        ]
        XCTAssertEqual(scrubbed(launch), [
            "PATH": "/usr/bin", "HOME": "/Users/a", "LANG": "en_US.UTF-8", "TERM": "xterm-ghostty",
            "C11_QA_LAUNCH": "fresh", "C11_DEBUG_LOG": "/tmp/log", "C11_TAG": "t5", "XDG_DATA_DIRS": "/x",
        ])
    }

    /// The #63 interplay: the launch settings it hands on to hc terminals still
    /// reach the app, under both prefixes, and so does what UI tests set.
    func testTheLaunchSettingsNumberSixtyThreePassesOnSurviveTheScrub() {
        let launch = [
            "C11_QA_LAUNCH": "fresh", "C11_DEBUG_LOG": "/tmp/log", "C11_TAG": "t5", "C11_SOCKET_MODE": "automation",
            "C11_SOCKET_ENABLE": "1", "C11_REPO_ROOT": "/repo", "C11_HANG_MONITOR": "1",
            "CMUX_QA_LAUNCH": "fresh", "CMUX_TAG": "t5", "CMUX_DEBUG_LOG": "/tmp/log",
            "CMUX_UI_TEST_MODE": "1", "CMUX_DISABLE_SESSION_RESTORE": "1",
        ]
        XCTAssertEqual(scrubbed(launch), launch)
        XCTAssertEqual(HCLaunchPolicy.inheritedAppEnvironment(scrubbed(launch)), launch,
                       "what the scrub keeps is exactly what #63 hands to an hc terminal")
        XCTAssertEqual(scrubbed(["CMUX_FOCUS_DEBUG": "1", "CMUX_PANEL_ID": "P", "CMUX_COMMIT": "abc"]), [:],
                       "any other legacy CMUX name is not a launch setting")
    }

    /// A launch script or a UI test sets the socket with no panel beside it, and
    /// must keep it; an inherited one always arrives with the terminal's ids.
    func testASocketPathIsScrubbedOnlyWhenItArrivedWithATerminal() {
        let deliberate = ["CMUX_SOCKET_PATH": "/tmp/c11-debug-t.sock", "C11_SOCKET_PATH": "/tmp/c11-debug-t.sock",
                          "CMUX_SOCKET_MODE": "allowAll", "CMUX_SOCKET_ENABLE": "1"]
        XCTAssertEqual(scrubbed(deliberate), deliberate)

        var inherited = deliberate
        inherited["C11_PANEL_ID"] = "P"
        XCTAssertEqual(scrubbed(inherited), ["CMUX_SOCKET_MODE": "allowAll", "CMUX_SOCKET_ENABLE": "1"])

        var intended = inherited
        intended["C11_ALLOW_SOCKET_OVERRIDE"] = "1"
        XCTAssertEqual(scrubbed(intended)["C11_SOCKET_PATH"], "/tmp/c11-debug-t.sock",
                       "an explicit override opt-in keeps the path")
        XCTAssertNil(scrubbed(intended)["C11_PANEL_ID"])
    }

    func testScrubbingUnsetsTheLiveVariablesAndReportsNamesNotValues() {
        let probe = "CLAUDE_C11H34_PROBE"
        setenv(probe, "secret-value", 1)
        let names = HCLaunchEnvironmentScrub.scrubProcessEnvironment([probe: "secret-value", "PATH": "/usr/bin"])
        XCTAssertEqual(names, [probe])
        XCTAssertNil(getenv(probe), "the process environment is the thing the core and terminals inherit")
        XCTAssertFalse(names.joined().contains("secret-value"))
        XCTAssertEqual(HCLaunchEnvironmentScrub.scrubProcessEnvironment(["PATH": "/usr/bin"]), [])
    }

    /// C11H-415: `open -a` from a c11 terminal hands the app hc's marks on that
    /// terminal too. The token is the one hc ends the terminal's leftovers by.
    func testHcsMarksOnTheHostTerminalAreScrubbedFromALaunch() {
        let launch = ["HC_SCOPE": "1234-abcd", "HC_TERMINAL_ID": "t9", "HC_TERMINAL_SOCKET": "/run/c11-s1.sock",
                      "HC_SESSION": "c11-s1", "HC_SOCKET": "/run/c11-s1.sock", "HC_RUNTIME": "1",
                      "PATH": "/usr/bin", "C11_QA_LAUNCH": "fresh", "CMUX_TAG": "t5"]
        XCTAssertEqual(scrubbed(launch), ["PATH": "/usr/bin", "C11_QA_LAUNCH": "fresh", "CMUX_TAG": "t5"])
    }

    /// C11H-415: hc and `ps -E` read the environment the kernel recorded at
    /// exec, which `unsetenv` leaves in place. The scrubbed names are blanked
    /// there; every other string keeps its bytes and its place.
    func testTheExecTimeEnvironmentLosesExactlyTheScrubbedNames() {
        let block = ExecBlockFixture(arguments: ["/Applications/c11.app/Contents/MacOS/c11"], environment: [
            "HOME=/Users/a", "HC_SCOPE=1234-abcd", "PATH=/usr/bin", "C11_PANEL_ID=P", "HC_TERMINAL_ID=t9",
            "C11_QA_LAUNCH=fresh",
        ])
        let names = Set(HCLaunchEnvironmentScrub.namesToRemove(from: HCExecEnvironment.variables(block.procargs)))
        XCTAssertEqual(names, ["HC_SCOPE", "C11_PANEL_ID", "HC_TERMINAL_ID"])
        // After unsetenv, the live environment points only at what it kept.
        let outcome = HCLaunchEnvironmentScrub.blankExecEnvironment(
            names: names, procargs: block.procargs, arguments: block.arguments, live: block.live([0, 2, 5]))
        XCTAssertEqual(outcome, .init(blanked: ["C11_PANEL_ID", "HC_SCOPE", "HC_TERMINAL_ID"]))
        let now = block.current
        XCTAssertEqual(HCExecEnvironment.variables(now),
                       ["HOME": "/Users/a", "PATH": "/usr/bin", "C11_QA_LAUNCH": "fresh", "ptr_munge": ""])
        XCTAssertEqual(now.count, block.procargs.count)
        // hc's test: no NUL-separated entry is `HC_SCOPE=<token>`.
        XCTAssertFalse(now.split(separator: 0).contains { Array($0) == Array("HC_SCOPE=1234-abcd".utf8) })
        XCTAssertEqual(HCExecEnvironment.layout(now)?.strings, HCExecEnvironment.layout(block.procargs)?.strings)
    }

    /// C11H-415: nothing is written unless the kernel's copy locates the block,
    /// and a string is left alone while a live pointer names it or its bytes
    /// changed.
    func testTheExecBlockIsWrittenOnlyWhereTheKernelsCopyLocatesIt() {
        let environment = ["HOME=/Users/a", "HC_SCOPE=1234-abcd", "PATH=/usr/bin"]
        func run(_ block: ExecBlockFixture, live: [Int], arguments: [UnsafeMutablePointer<CChar>]? = nil)
            -> HCLaunchEnvironmentScrub.ExecBlockOutcome {
            HCLaunchEnvironmentScrub.blankExecEnvironment(names: ["HC_SCOPE"], procargs: block.procargs,
                arguments: arguments ?? block.arguments, live: block.live(live))
        }

        let stillLive = ExecBlockFixture(arguments: ["c11"], environment: environment)
        XCTAssertEqual(run(stillLive, live: [0, 1, 2]), .init(skipped: 1))
        XCTAssertEqual(stillLive.current, stillLive.procargs)

        let changed = ExecBlockFixture(arguments: ["c11"], environment: environment)
        changed.poke(environment: 1, at: 9, "X")
        XCTAssertEqual(run(changed, live: [0, 2]), .init(skipped: 1))

        let unconfirmed = ExecBlockFixture(arguments: ["c11"], environment: environment)
        XCTAssertEqual(run(unconfirmed, live: []), .init(refused: "unconfirmed"))
        XCTAssertEqual(unconfirmed.current, unconfirmed.procargs)

        let moved = ExecBlockFixture(arguments: ["c11", "-x"], environment: environment)
        let elsewhere = strdup("-x")!
        defer { free(elsewhere) }
        XCTAssertEqual(run(moved, live: [0, 2], arguments: [moved.arguments[0], elsewhere]), .init(refused: "arguments_moved"))
        XCTAssertEqual(run(moved, live: [0, 2], arguments: [moved.arguments[0]]), .init(refused: "arguments"))
        XCTAssertEqual(moved.current, moved.procargs)
    }

    /// C11H-415: the layout `blankOwnExecEnvironment` relies on holds in a real
    /// process: this test runner's arguments sit where its kernel copy says,
    /// and its live environment points into that block. Reads only.
    func testARealProcesssExecBlockIsLocatedFromItsKernelCopy() throws {
        let procargs = try XCTUnwrap(HCExecEnvironment.read(pid: getpid()))
        XCTAssertEqual(HCExecEnvironment.layout(procargs)?.arguments.count, Int(CommandLine.argc))
        XCTAssertNotNil(HCExecEnvironment.variables(procargs)["PATH"] ?? HCExecEnvironment.variables(procargs)["HOME"])
        let own = HCLaunchEnvironmentScrub.ownArgumentsAndEnvironment()
        switch HCLaunchEnvironmentScrub.locateExecBlock(procargs: procargs, arguments: own.arguments, live: own.live) {
        case .success: break
        case .failure(let refusal): XCTFail("the runner's exec block was not located: \(refusal)")
        }
    }

    /// Second line: a core started while the process environment still carried
    /// the markers (an update over a running session) does not pass them on.
    func testTheCoreEnvironmentCarriesNoAgentMarkers() throws {
        let inherited = ["CLAUDE_ACCOUNT_HOME": "/acct", "CLAUDE_CODE_CHILD_SESSION": "1", "CODEX_HOME": "/codex",
                         "TERM_PROGRAM": "Apple_Terminal", "TERM_PROGRAM_VERSION": "2", "PATH": "/usr/bin"]
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: inherited)
        XCTAssertEqual(c.environment["PATH"], "/usr/bin")
        for name in ["CLAUDE_ACCOUNT_HOME", "CLAUDE_CODE_CHILD_SESSION", "CODEX_HOME", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            XCTAssertNil(c.environment[name], name)
        }
    }

    /// The drift guard (C11H-34): everything the terminal builder stamps for a
    /// panel, under its C11_ and CMUX_ names, is something a launch from that
    /// terminal must not carry into the app. A new stamped variable is a new
    /// `ManagedTerminalEnvironmentKey` case and fails here until the scrub covers it.
    func testEveryVariableTheTerminalBuilderStampsIsScrubbedFromALaunchEnvironment() {
        for key in ManagedTerminalEnvironmentKey.allCases
        where !ManagedTerminalEnvironmentKey.notC11Namespace.contains(key) {
            var names = [key.rawValue]
            if let twin = c11TwinKey(forCmuxKey: key.rawValue) { names.append(twin) }
            var launch = Dictionary(uniqueKeysWithValues: names.map { ($0, "stamped") })
            launch["C11_PANEL_ID"] = "P"   // a terminal's own stamp: this launch came from one
            launch["C11_QA_LAUNCH"] = "fresh"
            let kept = scrubbed(launch)
            for name in names {
                XCTAssertNil(kept[name], "\(name) is stamped on every terminal and survives the launch scrub")
            }
            XCTAssertEqual(kept["C11_QA_LAUNCH"], "fresh")
        }
        XCTAssertEqual(ManagedTerminalEnvironmentKey.notC11Namespace.map(\.rawValue).sorted(),
                       ["PATH", "PROMPT_COMMAND", "ZDOTDIR"])
        XCTAssertEqual(scrubbed(["PATH": "/usr/bin", "ZDOTDIR": "/z", "PROMPT_COMMAND": "x"]).count, 3)
    }

    /// sol's blocking item on #71: the launching agent seat's wrapper exports,
    /// under both namespace spellings (c11 mirrors CMUX_ and C11_), are scrubbed
    /// from the app and are not handed to an hc terminal by #63 either.
    func testEveryVariableAnAgentWrapperExportsIsScrubbedAndNotHandedToHcTerminals() {
        for key in AgentWrapperEnvironmentKey.allCases {
            let raw = key.rawValue
            let twin = raw.hasPrefix("C11_") ? "CMUX_" + raw.dropFirst(4) : "C11_" + raw.dropFirst(5)
            let launch = [raw: "1", String(twin): "1", "C11_QA_LAUNCH": "fresh"]
            XCTAssertEqual(scrubbed(launch), ["C11_QA_LAUNCH": "fresh"], raw)
            XCTAssertEqual(HCLaunchPolicy.inheritedAppEnvironment(launch), ["C11_QA_LAUNCH": "fresh"],
                           "\(raw) must not reach an hc terminal through #63")
        }
        // A wrapper nobody has listed yet: its reentry marker is still a seat identity.
        XCTAssertEqual(scrubbed(["C11_GROK_WRAPPER_REENTRY": "1", "C11_TAG": "t"]), ["C11_TAG": "t"])
    }

    /// The operator's own ZDOTDIR stays; the host terminal's wrapper directory
    /// goes, and the operator's original, saved by that wrapper, comes back.
    func testZdotdirIsScrubbedOnlyWhenItPointsIntoAShellIntegrationDirectory() {
        let app = "/Applications/c11.app/Contents/Resources/shell-integration"
        XCTAssertEqual(scrubbed(["ZDOTDIR": "/Users/a/.config/zsh", "PATH": "/usr/bin"]),
                       ["ZDOTDIR": "/Users/a/.config/zsh", "PATH": "/usr/bin"], "an operator's own ZDOTDIR stays")
        XCTAssertEqual(scrubbed(["ZDOTDIR": "/ghostty/Resources/shell-integration/zsh"])["ZDOTDIR"],
                       "/ghostty/Resources/shell-integration/zsh", "Ghostty's own is not c11's stamp")
        XCTAssertNil(scrubbed(["ZDOTDIR": app])["ZDOTDIR"], "an installed bundle's integration directory")
        XCTAssertNil(scrubbed(["ZDOTDIR": "/build/tag/shell-integration", "CMUX_SHELL_INTEGRATION_DIR": "/build/tag/shell-integration"])["ZDOTDIR"],
                     "or whatever the terminal named as its integration directory")

        var restored: [String: String] = [:]
        var removed: [String] = []
        HCLaunchEnvironmentScrub.scrubProcessEnvironment(
            ["ZDOTDIR": app, "CMUX_ZSH_ZDOTDIR": "/Users/a/.config/zsh", "CMUX_SHELL_INTEGRATION": "1"],
            unset: { removed.append($0) }, set: { restored[$0] = $1 })
        XCTAssertEqual(restored, ["ZDOTDIR": "/Users/a/.config/zsh"], "the operator's original ZDOTDIR is put back")
        XCTAssertTrue(removed.contains("CMUX_ZSH_ZDOTDIR"))
        restored = [:]
        HCLaunchEnvironmentScrub.scrubProcessEnvironment(["ZDOTDIR": app], unset: { _ in }, set: { restored[$0] = $1 })
        XCTAssertEqual(restored, [:], "nothing saved: unset, never invent a value")
    }
}


/// C11H-66, contract Amendment 1: the bundled core. Every launcher test runs a
/// fake `serve` script that ends by itself; nothing is ever signalled.
final class HCBundledCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Short: the production socket path must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/hcb\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: launch environment

    func testTheCoreGainsExactlyTheThreeBundledCoreValues() throws {
        let inherited = ["PATH": "/usr/bin", "XDG_CONFIG_HOME": "/agent/config", "XDG_DATA_HOME": "/agent/data",
                         "SSH_CONNECTION": "10.0.0.1 1 10.0.0.2 22", "HC_LAUNCHD_DIRECT": "1"]
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: inherited,
                                                 binary: .external(home: URL(fileURLWithPath: "/Users/test"), pin: HCCoreBinary.externalPin),
                                                 launcherPID: 4242)
        XCTAssertEqual(Set(c.environment.keys), ["PATH", "HOME", "HC_SESSION", "HC_SOCKET", "HC_SPAWN_MS",
                                                 "XDG_CONFIG_HOME", "HC_LAUNCHD_DIRECT", "SSH_CONNECTION"])
        XCTAssertEqual(c.environment["XDG_CONFIG_HOME"], "/Users/test/.local/share/c11/config")
        XCTAssertEqual(c.configDirectory?.path, "/Users/test/.local/share/c11/config")
        XCTAssertEqual(c.environment["HC_LAUNCHD_DIRECT"], "4242")
        XCTAssertEqual(c.environment["SSH_CONNECTION"], "c11 0 c11 0")
        let defaulted = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: [:])
        XCTAssertEqual(defaulted.environment["HC_LAUNCHD_DIRECT"], String(getpid()), "the launching process is the default parent")
    }

    // MARK: the bundled binary

    private func makeBundle(helper: Data? = Data("signed helper".utf8), manifest: String?) throws -> URL {
        let bundle = root.appendingPathComponent("c11.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        if let helper { try helper.write(to: HCCoreBinary.helperURL(bundle: bundle)) }
        if let manifest { try Data(manifest.utf8).write(to: HCCoreBinary.manifestURL(bundle: bundle)) }
        return bundle
    }

    private func manifestJSON(executable: String, source: String = String(repeating: "5", count: 64)) -> String {
        #"{"version":"0.1.16","protocolGeneration":1,"sourceSHA256":"\#(source)","executableSHA256":"\#(executable)"}"#
    }

    func testABundledHelperIsTheOnlyLaunchBinaryAndTheExternalPinIsAcceptedOnlyAsServing() throws {
        let helperHash = sha(Data("signed helper".utf8))
        let bundle = try makeBundle(manifest: manifestJSON(executable: helperHash))
        let binary = try XCTUnwrap(try HCCoreBinary.bundled(in: bundle))
        XCTAssertEqual(binary.origin, .bundled)
        XCTAssertEqual(binary.executableURL.path, bundle.path + "/Contents/Helpers/herdr-core")
        XCTAssertEqual(binary.pin.executableSHA256, helperHash)
        XCTAssertEqual(binary.pin.version, "0.1.16")
        let home = URL(fileURLWithPath: "/Users/test")
        let c = try HCLaunchPolicy.configuration(home: home, tag: nil, inherited: [:], binary: binary)
        XCTAssertEqual(c.executableURL, binary.executableURL, "a new core always starts from Helpers")
        XCTAssertEqual(c.pin, binary.pin)
        XCTAssertEqual(c.servingBinaries.map(\.executableURL.path),
                       [binary.executableURL.path, "/Users/test/.local/share/c11/hc/0.1.16/herdr-core"])
        XCTAssertEqual(c.servingBinaries.last?.pin, HCCoreBinary.externalPin)
        let external = try HCLaunchPolicy.configuration(home: home, tag: nil, inherited: [:],
                                                        binary: .external(home: home, pin: HCCoreBinary.externalPin))
        XCTAssertEqual(external.servingBinaries.count, 1, "without a bundle only the external pin serves")
    }

    /// `c11-core` execs the bundled CLI, whose `Bundle.main` is `Contents/Resources/bin`,
    /// not the app: it must still find the app's helper, or it would refuse the core
    /// the app started from Helpers as "not c11's pin".
    func testTheBundledCLIFindsTheSameHelperAsTheAppEvenThroughASymlink() throws {
        let helperHash = sha(Data("signed helper".utf8))
        let bundle = try makeBundle(manifest: manifestJSON(executable: helperHash))
        let bin = bundle.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("c11")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        let link = root.appendingPathComponent("c11-on-path")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

        let fromCLI = try XCTUnwrap(HCCoreBinary.appBundle(main: root, executable: link))
        XCTAssertEqual(fromCLI.resolvingSymlinksInPath().path, bundle.resolvingSymlinksInPath().path)
        XCTAssertEqual(try HCCoreBinary.bundled(in: fromCLI)?.pin.executableSHA256, helperHash)
        let appMain = bundle.appendingPathComponent("Contents/MacOS/c11")
        XCTAssertEqual(HCCoreBinary.appBundle(main: bundle, executable: appMain), bundle)
        XCTAssertNil(HCCoreBinary.appBundle(main: root, executable: root.appendingPathComponent("loose/c11")),
                     "outside an app there is no bundled helper")
    }

    func testHalfABundleOrABadManifestRefusesInsteadOfFallingBackToTheExternalPin() throws {
        XCTAssertNil(try HCCoreBinary.bundled(in: root.appendingPathComponent("empty.app")))
        let good = manifestJSON(executable: String(repeating: "a", count: 64))
        let cases: [(String, Data?, String?)] = [
            ("helper without manifest", Data("x".utf8), nil),
            ("manifest without helper", nil, good),
            ("short hash", Data("x".utf8), manifestJSON(executable: "abc")),
            ("upper-case hash", Data("x".utf8), manifestJSON(executable: String(repeating: "A", count: 64))),
            ("bad source hash", Data("x".utf8), manifestJSON(executable: String(repeating: "a", count: 64), source: "zz")),
            ("bad version", Data("x".utf8), good.replacingOccurrences(of: "0.1.16", with: "../x")),
            ("not json", Data("x".utf8), "headless"),
        ]
        for (name, helper, manifest) in cases {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("c11.app"))
            let bundle = try makeBundle(helper: helper, manifest: manifest)
            XCTAssertThrowsError(try HCCoreBinary.bundled(in: bundle), name) { error in
                XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch, name)
            }
        }
    }

    // MARK: L2 with the transition

    /// The serving peer is this test process: its own executable stands in for
    /// a core already running from M1's external pin.
    private func servingFixture() throws -> (HCLaunchConfiguration, HCPeerEvidence, URL, String, HCServingBinary) {
        let launchBytes = Data("bundled helper".utf8)
        let launch = root.appendingPathComponent("herdr-core")
        try launchBytes.write(to: launch)
        let launchPin = HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: sha(launchBytes), protocolGeneration: 1)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = root.appendingPathComponent("s.sock")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socket.path.utf8); $0[socket.path.utf8.count] = 0 }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        Darwin.close(fd)
        try PrivateFileWriter.write(Data(socket.path.utf8), to: state.appendingPathComponent("core.lock"))
        try PrivateFileWriter.write(Data(#"{"id":"core"}"#.utf8), to: state.appendingPathComponent("core.json"))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(getpid(), &path, UInt32(path.count)), 0)
        let serving = URL(fileURLWithPath: String(cString: path))
        let servingHash = sha(try Data(contentsOf: serving))
        let accepted = HCServingBinary(executableURL: serving,
            pin: HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: servingHash, protocolGeneration: 1))
        let c = HCLaunchConfiguration(executableURL: launch, session: "c11-unit", socketURL: socket, stateDirectory: state,
            intentDirectory: root.appendingPathComponent("intents"), environment: [:], pin: launchPin)
        let peer = HCPeerEvidence(uid: getuid(), pid: getpid(), statusPID: getpid(), coreID: "core", version: "0.1.16",
            protocolGeneration: 1, methods: ["server.restart", "terminal.run", "terminal.attach", "events.subscribe"],
            features: ["framed"])
        return (c, peer, serving, servingHash, accepted)
    }

    func testACoreAlreadyServingFromTheExternalPinIsAdoptedAsPinnedDuringTheTransition() async throws {
        let fixture = try servingFixture()
        var c = fixture.0
        let (peer, serving, servingHash, accepted) = (fixture.1, fixture.2, fixture.3, fixture.4)
        let launchOnly = try await HCBuildVerifier().verify(peer, configuration: c)
        XCTAssertFalse(launchOnly.isPinnedBuild, "without the transition entry the external core is a foreign build")
        c.acceptedServing = [HCServingBinary(executableURL: c.executableURL, pin: c.pin), accepted]
        let adopted = try await HCBuildVerifier().verify(peer, configuration: c)
        XCTAssertTrue(adopted.isPinnedBuild)
        XCTAssertEqual(adopted.identity.pin.executableSHA256, servingHash)
        XCTAssertEqual(adopted.identity.executablePath, serving.path)
        let otherVersion = HCPeerEvidence(uid: peer.uid, pid: peer.pid, statusPID: peer.statusPID, coreID: "core",
            version: "0.1.17", protocolGeneration: 1, methods: peer.methods, features: peer.features)
        let refused = try await HCBuildVerifier().verify(otherVersion, configuration: c)
        XCTAssertFalse(refused.isPinnedBuild, "the same file reporting another version is not the pin")
    }

    /// sol's blocker on #118: an update deletes the old app, and with it the file a
    /// running core executes, so `proc_pidpath` fails and the new app cannot verify
    /// (or recover) that core. The helper goes through the installer's steps: the
    /// app is renamed aside, the new one is put in place, and the old app is
    /// renamed whole into the retained root instead of being deleted. The new
    /// app's tuple still adopts the core serving from that retained path and hash.
    ///
    /// No code runs on the host. Gatekeeper terminates ad hoc code an xctest
    /// launches, at random, and a stand-in must never look like a real core; so
    /// the peer is this test process, the verifier is told its executable path
    /// is the retained helper (the kernel's own answer for a live core, shown by
    /// the installer test), and the file there is really hashed. The helper is a
    /// signed copy of cat named `c11-test-core-<rand>`, never executed.
    func testACoreOfTheReplacedAppIsStillVerifiedFromItsRetainedHelper() async throws {
        // proc_pidpath reports the real path (/private/tmp), as an installed app's is.
        root = root.resolvingSymlinksInPath()
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let name = "c11-test-core-\(suffix)"
        let bundle = root.appendingPathComponent("c11-test-\(suffix)", isDirectory: true)
        func makeApp(helperBytes: Data?) throws {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            if let helperBytes { try helperBytes.write(to: HCCoreBinary.helperURL(bundle: bundle, name: name)) }
        }
        try makeApp(helperBytes: nil)
        let helper = HCCoreBinary.helperURL(bundle: bundle, name: name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: helper)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", helper.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let oldHash = sha(try Data(contentsOf: helper))
        try Data(manifestJSON(executable: oldHash).utf8).write(to: HCCoreBinary.manifestURL(bundle: bundle))

        // The installer's swap, in its order.
        let previous = root.appendingPathComponent("c11-test-\(suffix).previous.1")
        try FileManager.default.moveItem(at: bundle, to: previous)
        let nextBytes = Data("next signed helper".utf8)
        try makeApp(helperBytes: nextBytes)
        let retainedRoot = HCCoreBinary.retainedRootURL(bundle: bundle)
        try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: true)
        let retained = retainedRoot.appendingPathComponent("\(oldHash.prefix(12)).x")
        try FileManager.default.moveItem(at: previous, to: retained)

        let next = HCCoreBinary(executableURL: HCCoreBinary.helperURL(bundle: bundle, name: name),
            pin: HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: sha(nextBytes), protocolGeneration: 1),
            origin: .bundled, retainedRoot: retainedRoot)
        // C11H-108: the entry is vouched for by a shipped pin (the ad hoc helper
        // here has no team signature); a forged entry is checked below.
        let shipped = HCRetainedTrust(shipped: [oldHash], team: nil, satisfies: { _, _ in false })
        let tuple = try HCLaunchPolicy.configuration(home: root, tag: nil, inherited: [:], binary: next, retainedTrust: shipped)
        XCTAssertEqual(tuple.executableURL, next.executableURL, "a new core still starts from the new app's helper")
        let retainedHelper = HCCoreBinary.helperURL(bundle: retained, name: name).resolvingSymlinksInPath().path
        XCTAssertEqual(tuple.servingBinaries.last.map { $0.executableURL.resolvingSymlinksInPath().path }, retainedHelper)

        // The serving peer is this test process (real uid and start-time checks);
        // the kernel's executable path for it is the retained helper, as the
        // installer test and a live core show (rename keeps the vnode). No ad hoc
        // code is run on the host: Gatekeeper terminates it there at random.
        var c = try servingFixture().0
        c.acceptedServing = tuple.acceptedServing
        let peer = HCPeerEvidence(uid: getuid(), pid: getpid(), statusPID: getpid(), coreID: "core",
            version: "0.1.16", protocolGeneration: 1,
            methods: ["server.restart", "terminal.run", "terminal.attach", "events.subscribe"], features: ["framed"])
        let servedFrom = HCBuildVerifier(executablePath: { [retainedHelper] _ in retainedHelper })
        let verified = try await servedFrom.verify(peer, configuration: c)
        XCTAssertTrue(verified.isPinnedBuild, "the replaced app's live core is adopted, not a foreign build")
        XCTAssertEqual(URL(fileURLWithPath: verified.identity.executablePath).resolvingSymlinksInPath().path, retainedHelper)
        XCTAssertEqual(verified.identity.pin.executableSHA256, oldHash)

        // The same entry on its own word (C11H-108): self-consistent, ad hoc
        // signed, under an app with a team. The real evaluator refuses it, so the
        // core it serves is a foreign build, not an adopted one.
        let teamOnly = HCRetainedTrust(shipped: [], team: "ABCDE12345", satisfies: { HCCodeSignature.satisfies($0, $1) })
        let forged = try HCLaunchPolicy.configuration(home: root, tag: nil, inherited: [:], binary: next, retainedTrust: teamOnly)
        XCTAssertFalse(forged.servingBinaries.contains { $0.executableURL.resolvingSymlinksInPath().path == retainedHelper },
                       "a forged self-consistent entry is not accepted as serving")
        c.acceptedServing = forged.acceptedServing
        let refused = try await servedFrom.verify(peer, configuration: c)
        XCTAssertFalse(refused.isPinnedBuild, "a core run from a forged entry is a foreign build")

        // A retained entry is accepted only with a valid manifest and its helper.
        for (entryName, helperBytes, manifest) in [("bad", Data("x".utf8), "headless"), ("lone", nil, manifestJSON(executable: oldHash))] {
            let entry = retainedRoot.appendingPathComponent(entryName)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            if let helperBytes { try helperBytes.write(to: HCCoreBinary.helperURL(bundle: entry, name: name)) }
            try Data(manifest.utf8).write(to: HCCoreBinary.manifestURL(bundle: entry))
        }
        XCTAssertEqual(HCCoreBinary.retainedServing(in: retainedRoot, helperName: name, trust: shipped).map(\.pin.executableSHA256), [oldHash])
    }

    /// C11H-108: an entry is admitted by a shipped pin or by c11's own
    /// signature (anchored at Apple, c11's team, the helper's identifier), never
    /// by its manifest alone. No team-signed helper exists on CI, so the signature
    /// answer is injected here; the real evaluator is tested below.
    /// h5's helper is admitted from a retained app by the shipped list alone: an
    /// app with no team (ad hoc, or signed by another identity) still adopts the
    /// core h5's retained app runs. A hash no release shipped is not.
    func testAnH5RetainedHelperIsAdmittedByTheShippedListAlone() throws {
        let h5 = "dd9b39ae3bc0da8950f1f0dfbe5a34614b7cbe82214c3700ad86315b6454161d"
        let retainedRoot = root.appendingPathComponent(".c11.app-helpers", isDirectory: true)
        for (name, hash) in [("h5", h5), ("other", String(repeating: "e", count: 64))] {
            let entry = retainedRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data("retained helper".utf8).write(to: HCCoreBinary.helperURL(bundle: entry))
            try Data(manifestJSON(executable: hash).utf8).write(to: HCCoreBinary.manifestURL(bundle: entry))
        }
        let noTeam = HCRetainedTrust(shipped: HCCoreBinary.shippedHelperSHA256, team: nil, satisfies: { _, _ in false })
        let admitted = HCCoreBinary.retainedServing(in: retainedRoot, trust: noTeam)
        XCTAssertEqual(admitted.map(\.pin.executableSHA256), [h5], "only the hash a release shipped is admitted")
        XCTAssertEqual(admitted.first?.executableURL.deletingLastPathComponent().deletingLastPathComponent()
                           .deletingLastPathComponent().lastPathComponent, "h5")
        XCTAssertEqual(HCRetainedTrust.current.shipped, HCCoreBinary.shippedHelperSHA256, "the app's trust reads the shipped list")
    }

    func testARetainedEntryNeedsAShippedPinOrC11hsSignature() throws {
        let helper = root.appendingPathComponent("entry/Contents/Helpers/c11-test-core")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("retained helper".utf8)
        try bytes.write(to: helper)
        let pin = HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: sha(bytes), protocolGeneration: 1)
        let wanted = HCRetainedTrust.requirement(team: "ABCDE12345")
        XCTAssertTrue(wanted.contains(#"identifier "com.stage11.c11.herdr-core""#))
        XCTAssertTrue(wanted.contains("anchor apple generic"), "a self-signed certificate can claim any team")
        XCTAssertTrue(wanted.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        let signedByC11h: @Sendable (URL, String) -> Bool = { url, requirement in url == helper && requirement == wanted }

        XCTAssertTrue(HCRetainedTrust(shipped: [], team: "ABCDE12345", satisfies: signedByC11h).admits(helper: helper, pin: pin),
                      "a codesign-valid entry is accepted")
        XCTAssertTrue(HCRetainedTrust(shipped: [pin.executableSHA256], team: nil, satisfies: { _, _ in false }).admits(helper: helper, pin: pin),
                      "a shipped pin is accepted whatever signed it")
        XCTAssertFalse(HCRetainedTrust(shipped: [], team: "ABCDE12345", satisfies: { _, _ in false }).admits(helper: helper, pin: pin),
                       "its own manifest is not enough")
        XCTAssertFalse(HCRetainedTrust(shipped: [], team: "ZZZZZ99999", satisfies: signedByC11h).admits(helper: helper, pin: pin),
                       "another team's signature is not c11's")
        XCTAssertFalse(HCRetainedTrust(shipped: [], team: nil, satisfies: { _, _ in true }).admits(helper: helper, pin: pin),
                       "an app without a team has only the shipped list")
        XCTAssertFalse(HCRetainedTrust(shipped: [], team: #"X" or true or "Y"#, satisfies: { _, _ in true }).admits(helper: helper, pin: pin),
                       "a malformed team never reaches a requirement")
    }

    /// C11H-394: c11h signed its helper `com.stage11.c11h.herdr-core`, so a
    /// team-signed 2.0 adopts a c11h core only if the one requirement takes
    /// either identifier. No team-signed helper exists on a test host: the seam
    /// grants exactly the anchor and team clauses and leaves the identifier to
    /// Security, checked on a real ad hoc signature of each identifier.
    func testATeamSignedHelperWithEitherIdentifierIsAdmittedAndNoOther() throws {
        let team = "ABCDE12345"
        let teamClauses = #" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
        let grantsAnchorAndTeam: @Sendable (URL, String) -> Bool = { url, requirement in
            guard requirement.hasSuffix(teamClauses) else { return false }
            return HCCodeSignature.satisfies(url, String(requirement.dropLast(teamClauses.count)))
        }
        let trust = HCRetainedTrust(shipped: [], team: team, satisfies: grantsAnchorAndTeam)
        let cases = [("com.stage11.c11.herdr-core", true), ("com.stage11.c11h.herdr-core", true),
                     ("com.stage11.c11x.herdr-core", false), ("com.example.herdr-core", false)]
        for (identifier, admitted) in cases {
            let helper = root.appendingPathComponent("signed-\(identifier)/c11-test-core")
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, helper.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0)
            let pin = HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: sha(try Data(contentsOf: helper)), protocolGeneration: 1)
            XCTAssertEqual(trust.admits(helper: helper, pin: pin), admitted, "a team-signed helper named \(identifier)")
            XCTAssertFalse(HCRetainedTrust(shipped: [], team: team, satisfies: { HCCodeSignature.satisfies($0, $1) }).admits(helper: helper, pin: pin),
                           "the real requirement still needs our team at an Apple anchor: \(identifier) is only ad hoc")
        }
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(HCRetainedTrust.requirement(team: team) as CFString, [], &parsed), errSecSuccess,
                       "the one requirement compiles")
    }

    /// C11H-394: a Debug or ad hoc 2.0 (no team, what the guest runs) adopts the
    /// cores of every c11h build Atin may switch from by the shipped list alone.
    /// Each hash is the signed helper of that build's app (h15 was already listed).
    func testTheHelperOfEveryC11hBuildFromH15ToH22IsAdmittedWithNoTeam() throws {
        let builds = [
            ("h15", "3f1b58dca952f6a35272111854f8d455324255fe5d56dccc5420a4b8f040d5bc"),
            ("h16", "03339dce9273efa37f9cbb0402e3220e2cf7b3a0890c408149f46e8693f65030"),
            ("h17", "6d852295b9ddd43ed713c5be48248c6707564538778c20de206efbcba52db4cd"),
            ("h18", "d073bd1a241c7b126c2c3ef0184509c844084a48cf573efe44fe9c13c6b99e0d"),
            ("h19", "9351840eacff0fdabdff75e8d9be4c7e26b215293c06b98be02968db30e66896"),
            ("h20", "0df3a843035dd82772880f963d92020c09084e812f58f5a01b918ce58f14f193"),
            ("h21", "32a9aaeae71878a70a72f94ea3fcf90db935f78b5d30e283aa2e4a981177bb23"),
            ("h22", "1e294d6c047cc58de008f9fecd9053892d032820ecb674e17f413693c7aac1ff"),
            ("unlisted", String(repeating: "e", count: 64)),
        ]
        let retainedRoot = root.appendingPathComponent(".c11h.app-helpers", isDirectory: true)
        for (name, hash) in builds {
            let entry = retainedRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data("c11h helper".utf8).write(to: HCCoreBinary.helperURL(bundle: entry))
            try Data(manifestJSON(executable: hash).utf8).write(to: HCCoreBinary.manifestURL(bundle: entry))
        }
        let noTeam = HCRetainedTrust(shipped: HCCoreBinary.shippedHelperSHA256, team: nil, satisfies: { _, _ in false })
        let admitted = HCCoreBinary.retainedServing(in: retainedRoot, trust: noTeam)
        XCTAssertEqual(admitted.map { $0.executableURL.deletingLastPathComponent().deletingLastPathComponent()
                           .deletingLastPathComponent().lastPathComponent },
                       ["h15", "h16", "h17", "h18", "h19", "h20", "h21", "h22"], "every listed c11h helper is serving; an unlisted hash is not")
        let h18 = retainedRoot.appendingPathComponent("h18", isDirectory: true)
        XCTAssertEqual(HCCoreBinary.servingEntry(bundle: h18, trust: noTeam)?.pin.executableSHA256, builds[3].1,
                       "the c11h app a migration adopts is read the same way")
    }

    func testTheSignatureEvaluatorChecksTheFileAndTheRequirement() throws {
        let copy = root.appendingPathComponent("ls")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        XCTAssertTrue(HCCodeSignature.satisfies(copy, #"anchor apple and identifier "com.apple.ls""#))
        XCTAssertFalse(HCCodeSignature.satisfies(copy, HCRetainedTrust.requirement(team: "ABCDE12345")), "Apple's ls is not c11's helper")
        var bytes = try Data(contentsOf: copy)
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: copy)
        XCTAssertFalse(HCCodeSignature.satisfies(copy, #"anchor apple and identifier "com.apple.ls""#), "a changed file fails")

        let adhoc = root.appendingPathComponent("c11-test-adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: adhoc)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", HCRetainedTrust.helperIdentifier, adhoc.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        XCTAssertTrue(HCCodeSignature.satisfies(adhoc, #"identifier "com.stage11.c11.herdr-core""#), "the identifier alone is forgeable")
        XCTAssertFalse(HCCodeSignature.satisfies(adhoc, HCRetainedTrust.requirement(team: "ABCDE12345")),
                       "an ad hoc helper with c11's identifier is not signed by c11")
    }

    /// sol on #144: a signature vouches only for the bytes it was checked on. The
    /// helper's path is swapped from a "signed" A to an unsigned B before, during
    /// and after admission; B is never adopted. The signature answer for A is
    /// injected (no team-signed helper exists on CI); the swap, the digests and
    /// the adoption hash are real. No code is run.
    func testASignatureVouchesOnlyForTheBytesItWasCheckedOn() async throws {
        root = root.resolvingSymlinksInPath()
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let name = "c11-test-core-\(suffix)"
        let retainedRoot = root.appendingPathComponent(".c11-test-\(suffix)-helpers", isDirectory: true)
        let entry = retainedRoot.appendingPathComponent("entry", isDirectory: true)
        let helper = HCCoreBinary.helperURL(bundle: entry, name: name)
        let a = root.appendingPathComponent("a/\(name)"), b = root.appendingPathComponent("b/\(name)")
        for (url, text) in [(a, "helper A, the signed one"), (b, "helper B, unsigned")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let hashA = sha(try Data(contentsOf: a)), hashB = sha(try Data(contentsOf: b))
        XCTAssertNotEqual(hashA, hashB)
        func place(_ source: URL) throws {
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = helper.deletingLastPathComponent().appendingPathComponent(".staged")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            _ = try FileManager.default.replaceItemAt(helper, withItemAt: staged)
        }
        func pin(_ hash: String) -> HCPin { HCPin(version: "0.1.16", archiveSHA256: "", executableSHA256: hash, protocolGeneration: 1) }
        let signsA: @Sendable (URL, String) -> Bool = { _, _ in true }
        let trust = HCRetainedTrust(shipped: [], team: "ABCDE12345", satisfies: signsA)

        try place(a)
        XCTAssertTrue(trust.admits(helper: helper, pin: pin(hashA)), "control: A's signature vouches for A's digest")
        XCTAssertFalse(trust.admits(helper: helper, pin: pin(hashB)), "A's signature never vouches for B's digest")
        let swapDuring = HCRetainedTrust(shipped: [], team: "ABCDE12345", satisfies: { [helper, b] _, _ in
            let staged = helper.deletingLastPathComponent().appendingPathComponent(".staged")
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.copyItem(at: b, to: staged)
            _ = try? FileManager.default.replaceItemAt(helper, withItemAt: staged)
            return true
        })
        XCTAssertFalse(swapDuring.admits(helper: helper, pin: pin(hashA)), "a file swapped in during the check is refused")

        // After admission: the entry is admitted with A's digest, then B takes the path and serves.
        try place(a)
        try FileManager.default.createDirectory(at: entry.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data(manifestJSON(executable: hashA).utf8).write(to: HCCoreBinary.manifestURL(bundle: entry))
        let admitted = HCCoreBinary.retainedServing(in: retainedRoot, helperName: name, trust: trust)
        XCTAssertEqual(admitted.map(\.pin.executableSHA256), [hashA])
        try place(b)
        // B now serves from the admitted path: the peer is this test process, whose
        // executable path the verifier is told is that path; it hashes the real file.
        var c = try servingFixture().0
        c.acceptedServing = [HCServingBinary(executableURL: c.executableURL, pin: c.pin)] + admitted
        let peer = HCPeerEvidence(uid: getuid(), pid: getpid(), statusPID: getpid(), coreID: "core",
            version: "0.1.16", protocolGeneration: 1,
            methods: ["server.restart", "terminal.run", "terminal.attach", "events.subscribe"], features: ["framed"])
        let servingPath = helper.resolvingSymlinksInPath().path
        let served = try await HCBuildVerifier(executablePath: { [servingPath] _ in servingPath }).verify(peer, configuration: c)
        XCTAssertFalse(served.isPinnedBuild, "B swapped in after admission is a foreign build")
        XCTAssertEqual(served.identity.pin.executableSHA256, hashB)
    }

    /// sol on #144: strict validation and every architecture, each shown by a
    /// fixture only that flag rejects. /bin/ls is universal: a corrupt non-native
    /// slice passes a native-only check, and bytes after the signature pass a
    /// non-strict one.
    func testTheEvaluatorChecksEveryArchitectureAndValidatesStrictly() throws {
        let requirement = #"anchor apple and identifier "com.apple.ls""#
        let source = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        func be32(_ offset: Int) -> UInt32 { source[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        guard source.count > 8, be32(0) == 0xCAFEBABE else { throw XCTSkip("/bin/ls is not a universal binary here") }
        #if arch(arm64)
        let native: UInt32 = 0x0100000C
        #else
        let native: UInt32 = 0x01000007
        #endif
        let slices = (0..<Int(be32(4))).map { i -> (cpu: UInt32, offset: Int, size: Int) in
            let at = 8 + i * 20
            return (be32(at), Int(be32(at + 8)), Int(be32(at + 12)))
        }
        guard let foreign = slices.first(where: { $0.cpu != native }) else { throw XCTSkip("/bin/ls has no non-native slice") }

        let intact = root.appendingPathComponent("ls-intact")
        try source.write(to: intact)
        XCTAssertTrue(HCCodeSignature.satisfies(intact, requirement), "control: Apple's ls passes")

        var corrupt = source
        corrupt[foreign.offset + foreign.size / 3] ^= 0xff
        let otherSlice = root.appendingPathComponent("ls-foreign-slice")
        try corrupt.write(to: otherSlice)
        XCTAssertFalse(HCCodeSignature.satisfies(otherSlice, requirement), "every architecture is checked, not only this one")

        var padded = source
        padded.append(Data(count: 4096))
        let trailing = root.appendingPathComponent("ls-trailing")
        try padded.write(to: trailing)
        XCTAssertFalse(HCCodeSignature.satisfies(trailing, requirement), "strict validation refuses bytes after the signature")
    }

    // MARK: config.toml

    func testTheCoreConfigIsWrittenPrivatelyAndOnlyWhenItChanges() throws {
        let directory = root.appendingPathComponent("config", isDirectory: true)
        XCTAssertTrue(try HCCoreConfigFile.ensure(in: directory))
        let file = HCCoreConfigFile.fileURL(in: directory)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "headless = \"200x120\"\n")
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let inode = info.st_ino
        _ = lstat(file.path, &info); let fileInode = info.st_ino
        XCTAssertFalse(try HCCoreConfigFile.ensure(in: directory), "unchanged contents are not rewritten")
        _ = lstat(file.path, &info); XCTAssertEqual(info.st_ino, fileInode)
        XCTAssertTrue(try HCCoreConfigFile.ensure(in: directory, contents: "headless = \"100x30\"\n"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "headless = \"100x30\"\n")
        _ = lstat(file.deletingLastPathComponent().path, &info); XCTAssertEqual(info.st_ino, inode)
    }

    // MARK: spawning `serve` (fake script, ends by itself)

    private let fakeVersion = "9.9.9"

    private static let fakeCore = """
    #!/bin/sh
    o="$HCS_OUT"
    echo x >> "$o/spawns"
    printf '%s\\n' "$$" > "$o/pid"
    printf '%s\\n' "$PPID" > "$o/ppid"
    /bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ' > "$o/pgid"
    /usr/bin/env > "$o/env"
    printf '%s\\n' "$*" > "$o/argv"
    echo "fake core stderr" >&2
    echo "fake core stdout"
    case "$HCS_MODE" in
      listen) exec /usr/bin/nc -lU "$HC_SOCKET" ;;
      stale) /bin/sleep 0.3; /bin/rm -f "$HC_SOCKET"; exec /usr/bin/nc -lU "$HC_SOCKET" ;;
      lose) exit 0 ;;
      fail) exit 3 ;;
      hold) i=0; while [ -d "$o" ] && [ ! -e "$o/release" ] && [ $i -lt 200 ]; do /bin/sleep 0.05; i=$((i+1)); done
            echo done > "$o/finished"; exit 0 ;;
    esac
    """

    private func fakeConfiguration(mode: String) throws -> (HCLaunchConfiguration, URL) {
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let script = Data(Self.fakeCore.utf8)
        let pin = HCPin(version: fakeVersion, archiveSHA256: "", executableSHA256: sha(script), protocolGeneration: 1)
        let c = try HCLaunchPolicy.configuration(home: root, tag: "t", inherited: ["HCS_OUT": out.path, "HCS_MODE": mode], pin: pin)
        try FileManager.default.createDirectory(at: c.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: c.executableURL)
        XCTAssertEqual(chmod(c.executableURL.path, 0o755), 0)
        // A listener that never got a connection ends on this one.
        addTeardownBlock { _ = HCCoreSpawn.answers(c.socketURL) }
        return (c, out)
    }

    private func read(_ out: URL, _ name: String) -> String {
        ((try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func launch(_ c: HCLaunchConfiguration, seconds: Double = 5) async -> Error? {
        do { _ = try await HCLauncher(verifier: HCBuildVerifier()).start(c, deadlineUptimeNanoseconds: HCMonotonic.deadline(after: seconds)); return nil }
        catch { return error }
    }

    private func waitUntilGone(_ pid: pid_t, seconds: Double = 3) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }

    func testServeIsThisProcesssDirectChildInItsOwnSessionWithTheBundledCoreEnvironment() async throws {
        let (c, out) = try fakeConfiguration(mode: "listen")
        let error = await launch(c)
        XCTAssertNil(error)
        let pid = try XCTUnwrap(pid_t(read(out, "pid")))
        XCTAssertEqual(read(out, "ppid"), String(getpid()), "the core's parent is the launching process (C7)")
        XCTAssertEqual(read(out, "pgid"), String(pid), "setsid: the core leads its own session and group")
        XCTAssertEqual(read(out, "argv"), "serve")
        let env = Set(read(out, "env").split(separator: "\n").map(String.init))
        XCTAssertTrue(env.contains("HC_LAUNCHD_DIRECT=\(getpid())"), "HC_LAUNCHD_DIRECT names the real parent")
        XCTAssertTrue(env.contains("SSH_CONNECTION=c11 0 c11 0"))
        XCTAssertTrue(env.contains("XDG_CONFIG_HOME=\(root.path)/.local/share/c11/config"))
        XCTAssertTrue(env.contains("HC_RUNTIME=1"))
        XCTAssertTrue(env.contains("HC_SESSION=c11-t"))
        XCTAssertFalse(env.contains { $0.hasPrefix("HC_SCOPE=") })
        let log = try String(contentsOf: c.stateDirectory.appendingPathComponent("core.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("fake core stderr"), "stderr goes to core.log")
        XCTAssertFalse(log.contains("fake core stdout"), "stdout goes to /dev/null")
        XCTAssertEqual(try String(contentsOf: HCCoreConfigFile.fileURL(in: c.configDirectory!), encoding: .utf8),
                       HCCoreConfigFile.contents, "config.toml is written before the core starts")
        XCTAssertTrue(waitUntilGone(pid), "the reaper collects the core when it exits: no zombie")
    }

    func testACoreThatFailsBeforeAnsweringFailsTheStartAtOnce() async throws {
        let (c, out) = try fakeConfiguration(mode: "fail")
        let started = Date()
        let error = await launch(c, seconds: 10)
        XCTAssertEqual(error as? HCUnavailableReason, .coreUnreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a nonzero exit is not waited out to the deadline")
        XCTAssertEqual(read(out, "spawns"), "x")
    }

    /// `serve` exits 0 when another core holds core.lock. That is a lost race,
    /// not a failure, and the serving core is used: one spawn, no second core.
    /// The serving core binds on the launch's own poll that saw the spawned core's zero
    /// exit, so that exit comes before the answer on every run and `spawns` is read after
    /// the child wrote it. A fixed-time bind left both to the host's load (C11H-346).
    func testACoreThatLosesTheLockToAServingCoreUsesTheServingOne() async throws {
        let (c, out) = try fakeConfiguration(mode: "lose")
        try FileManager.default.createDirectory(at: c.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(c.socketURL.path) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: c.socketURL.path.utf8); $0[c.socketURL.path.utf8.count] = 0 }
        let bindNow = {
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            _ = Darwin.listen(listener, 8)
        }
        let socket = c.socketURL
        let sawZeroExit = expectation(description: "the launch saw the spawned core's zero exit and kept waiting")
        sawZeroExit.assertForOverFulfill = false
        HCCoreSpawn.waitPollForTesting = { polled, status in
            guard polled == socket, status == 0 else { return }
            bindNow()   // the next poll answers
            sawZeroExit.fulfill()
        }
        addTeardownBlock { HCCoreSpawn.waitPollForTesting = nil }
        let error = await launch(c)
        XCTAssertNil(error, "a zero exit is a lost race: the launch waits for the serving core")
        await fulfillment(of: [sawZeroExit], timeout: 1)
        XCTAssertEqual(read(out, "spawns"), "x", "exactly one spawn")
    }

    /// The lost-race branch with no child: a recorded zero exit keeps the launch waiting for
    /// a serving core's socket until its deadline; any other exit fails at once.
    func testAZeroExitWaitsForTheServingSocketAndAnyOtherExitFails() throws {
        let socket = root.appendingPathComponent("absent.sock")
        let lost = HCServeExit()
        lost.record(0)
        XCTAssertThrowsError(try HCCoreSpawn.waitUntilAnswering(socket, exit: lost,
                                                                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: 0.1))) {
            XCTAssertEqual($0 as? HCUnavailableReason, .deadlineExceeded, "a zero exit is a lost race, not a failure")
        }
        let failed = HCServeExit()
        failed.record(3 << 8)
        XCTAssertThrowsError(try HCCoreSpawn.waitUntilAnswering(socket, exit: failed,
                                                                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: 5))) {
            XCTAssertEqual($0 as? HCUnavailableReason, .coreUnreachable, "a failed core is not waited on")
        }
    }

    func testAStaleSocketFileIsNotMistakenForACore() async throws {
        let (c, out) = try fakeConfiguration(mode: "stale")
        try FileManager.default.createDirectory(at: c.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: c.socketURL.path.utf8); $0[c.socketURL.path.utf8.count] = 0 }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        Darwin.close(fd)  // the file stays; nothing listens
        XCTAssertFalse(HCCoreSpawn.answers(c.socketURL))
        let started = Date()
        let error = await launch(c)
        XCTAssertNil(error)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "returned only once the new core bound")
        XCTAssertEqual(read(out, "spawns"), "x")
    }

    /// Polls for a file the fake core writes. Its first `sh` start in a test
    /// process can take longer than the launch deadline on a loaded host
    /// (C11H-324: 460 ms after spawn on the build host at load 34).
    private func waitForFile(_ out: URL, _ name: String, seconds: Double = 5) -> String {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let value = read(out, name)
            if !value.isEmpty { return value }
            usleep(20_000)
        }
        return read(out, name)
    }

    /// The `hold` core runs until the test releases it, so whether it was
    /// signalled at the deadline does not depend on how fast it starts.
    func testTheDeadlineSignalsNothing() async throws {
        let (c, out) = try fakeConfiguration(mode: "hold")
        let error = await launch(c, seconds: 1)
        XCTAssertEqual(error as? HCUnavailableReason, .deadlineExceeded)
        let pid = try XCTUnwrap(pid_t(waitForFile(out, "pid")), "the core was spawned")
        XCTAssertEqual(kill(pid, 0), 0, "still running after the deadline: not signalled")
        FileManager.default.createFile(atPath: out.appendingPathComponent("release").path, contents: nil)
        XCTAssertEqual(waitForFile(out, "finished"), "done", "it ran to its own end: not signalled")
        XCTAssertTrue(waitUntilGone(pid), "it ended by itself and was reaped")
    }
}

/// C11H-415: an exec-time block laid out as the kernel returns it
/// (`KERN_PROCARGS2`: argc, the executable path and its padding, the arguments,
/// the environment, a kernel string), and the same strings in writable memory
/// at the same offsets from the first argument, as they sit atop a stack.
private final class ExecBlockFixture {
    let procargs: [UInt8]
    let arguments: [UnsafeMutablePointer<CChar>]
    private let memory: UnsafeMutableRawPointer
    private let origin: Int
    private let length: Int
    private let environmentOffsets: [Int]

    init(arguments: [String], environment: [String]) {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array("/Applications/c11.app/Contents/MacOS/c11".utf8) + [0, 0, 0, 0]
        let origin = bytes.count
        var argumentOffsets: [Int] = []
        for argument in arguments { argumentOffsets.append(bytes.count); bytes += Array(argument.utf8) + [0] }
        var environmentOffsets: [Int] = []
        for entry in environment { environmentOffsets.append(bytes.count); bytes += Array(entry.utf8) + [0] }
        bytes += Array("ptr_munge=".utf8) + [0]
        let length = bytes.count - origin
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        bytes[origin...].withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: length) }
        self.procargs = bytes
        self.origin = origin
        self.length = length
        self.memory = memory
        self.environmentOffsets = environmentOffsets
        self.arguments = argumentOffsets.map { (memory + ($0 - origin)).assumingMemoryBound(to: CChar.self) }
    }

    deinit { memory.deallocate() }

    /// Live environment pointers at these environment entries.
    func live(_ indices: [Int]) -> [UnsafeMutablePointer<CChar>] {
        indices.map { (memory + (environmentOffsets[$0] - origin)).assumingMemoryBound(to: CChar.self) }
    }

    /// Changes one byte of an environment entry in memory, as a write since exec would.
    func poke(environment index: Int, at offset: Int, _ character: Character) {
        memory.storeBytes(of: character.asciiValue!, toByteOffset: environmentOffsets[index] - origin + offset, as: UInt8.self)
    }

    /// What the kernel would return now: the copy's head, then memory as it is.
    var current: [UInt8] { Array(procargs[..<origin]) + Array(UnsafeRawBufferPointer(start: memory, count: length)) }
}
