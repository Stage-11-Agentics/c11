import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Executable parity checks for the hc launch tuple against Ghostty's native
/// shell-integration setup. File probes are injected: no shell or file is touched.
final class HCShellIntegrationTests: XCTestCase {
    private let resources = "/res"
    private func probe(directories: Set<String> = ["/res/shell-integration", "/res/shell-integration/zsh"],
                       files: Set<String> = ["/res/shell-integration/bash/ghostty.bash"],
                       home: String? = "/home/u") -> HCShellIntegration.Probe {
        HCShellIntegration.Probe(isDirectory: { directories.contains($0) }, isReadableFile: { files.contains($0) },
                                 homeDirectory: { home })
    }
    private func apply(_ command: HCNativeLaunchSnapshot.Command?, env: [String: String] = [:], mode: String = "detect",
                       resources: String? = "/res", probe: HCShellIntegration.Probe? = nil) -> HCShellIntegration.Result {
        HCShellIntegration.apply(command: command, environment: env, mode: mode, resourcesDir: resources,
                                 probe: probe ?? self.probe())
    }

    func testFishAndElvishPrependIntegrationDirectoryToXDGDataDirs() {
        for name in ["fish", "/opt/bin/fish", "elvish"] {
            let result = apply(.shell(name), env: ["XDG_DATA_DIRS": "/a:/b"])
            XCTAssertEqual(result.shell, name.hasSuffix("fish") ? .fish : .elvish)
            XCTAssertEqual(result.command, .shell(name), "fish/elvish keep their command")
            XCTAssertEqual(result.environment["XDG_DATA_DIRS"], "/res/shell-integration:/a:/b")
            XCTAssertEqual(result.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"], "/res/shell-integration")
        }
        let unset = apply(.shell("fish"))
        XCTAssertEqual(unset.environment["XDG_DATA_DIRS"], "/res/shell-integration:/usr/local/share:/usr/share")
        XCTAssertEqual(apply(.shell("fish"), env: ["XDG_DATA_DIRS": ""]).environment["XDG_DATA_DIRS"],
                       "/res/shell-integration")
    }

    func testZshRedirectsZDOTDIRAndPreservesTheUsersValue() {
        let plain = apply(.shell("zsh"))
        XCTAssertEqual(plain.shell, .zsh)
        XCTAssertEqual(plain.environment["ZDOTDIR"], "/res/shell-integration/zsh")
        XCTAssertNil(plain.environment["GHOSTTY_ZSH_ZDOTDIR"])
        let custom = apply(.shell("zsh"), env: ["ZDOTDIR": "/home/u/.config/zsh"])
        XCTAssertEqual(custom.environment["GHOSTTY_ZSH_ZDOTDIR"], "/home/u/.config/zsh")
        XCTAssertNil(apply(.shell("zsh"), probe: probe(directories: [])).shell, "missing resources: no integration")
    }

    func testBashIsRelaunchedInPosixModeWithInjectFlagsAndSupportedOptionsOnly() {
        let result = apply(.shell("bash --norc -l"), env: ["ENV": "/old"])
        XCTAssertEqual(result.shell, .bash)
        XCTAssertEqual(result.command, .shell("bash --posix -l"))
        XCTAssertEqual(result.environment["ENV"], "/res/shell-integration/bash/ghostty.bash")
        XCTAssertEqual(result.environment["GHOSTTY_BASH_ENV"], "/old")
        XCTAssertEqual(result.environment["GHOSTTY_BASH_INJECT"], "1 --norc")
        XCTAssertEqual(result.environment["HISTFILE"], "/home/u/.bash_history")
        XCTAssertEqual(result.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"], "1")
        let rc = apply(.shell("bash --rcfile my.sh"))
        XCTAssertEqual(rc.environment["GHOSTTY_BASH_RCFILE"], "my.sh")
        for unsupported in ["bash --posix", "bash -c script.sh", "bash -ic script.sh"] {
            let denied = apply(.shell(unsupported))
            XCTAssertNil(denied.shell, unsupported)
            XCTAssertEqual(denied.command, .shell(unsupported))
            XCTAssertNil(denied.environment["ENV"])
        }
        XCTAssertNil(apply(.shell("/bin/bash")).shell, "Apple's /bin/bash 3.2 cannot use the ENV startup path")
        XCTAssertEqual(apply(.direct(["/opt/bash", "-l"])).command, .shell("/opt/bash --posix -l"))
    }

    func testNushellLoadsTheModuleAndKeepsAutoloadWhenLaterChecksAbort() {
        let result = apply(.shell("nu"))
        XCTAssertEqual(result.shell, .nushell)
        XCTAssertEqual(result.command, .shell("nu --execute 'use ghostty *'"))
        XCTAssertTrue(result.environment["XDG_DATA_DIRS"]?.hasPrefix("/res/shell-integration") == true)
        let aborted = apply(.shell("nu -c cmd"))
        XCTAssertNil(aborted.shell)
        XCTAssertEqual(aborted.command, .shell("nu -c cmd"))
        XCTAssertTrue(aborted.environment["XDG_DATA_DIRS"]?.hasPrefix("/res/shell-integration") == true,
                      "native setup adds the autoload directory before it can abort")
        XCTAssertNil(apply(.shell("nu --lsp")).shell)
    }

    func testDisabledMissingResourcesAndUnknownShellsLeaveTheLaunchUntouched() {
        for result in [apply(.shell("fish"), mode: "none"), apply(.shell("fish"), resources: nil),
                       apply(.shell("sh")), apply(.shell("/usr/bin/tcsh"))] {
            XCTAssertNil(result.shell)
            XCTAssertEqual(result.environment, [:])
        }
        XCTAssertEqual(apply(.shell("sh"), mode: "fish").shell, .fish, "forced shell wins over detection")
    }

    func testShellLineSplittingFollowsGhosttyQuoting() {
        XCTAssertEqual(HCShellIntegration.splitShellLine("bash -c 'command'"), ["bash", "-c", "'command'"])
        XCTAssertEqual(HCShellIntegration.splitShellLine("\"/a b/bash\" -l"), ["/a b/bash", "-l"])
        XCTAssertEqual(HCShellIntegration.detect(.shell("\"/a b/bash\"")), .bash)
        XCTAssertNil(HCShellIntegration.detect(.shell("   ")))
    }

    /// C11H-232: the root is the login shell itself (bash execs it at once), never `/usr/bin/login`, whose
    /// `-flp ... --noprofile` argv a stray `pkill -f <x> -n` matched. A direct command runs as given.
    func testIntegratedCommandIsWhatTheRootExecsAsALoginShell() {
        let snapshot = HCNativeLaunchSnapshot(command: .shell("bash"), environment: [:], overrides: [:],
                                              workingDirectory: nil)
        let integrated = apply(snapshot.effectiveCommand(override: nil)).command
        XCTAssertEqual(snapshot.argv(command: integrated),
            ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l bash --posix"])
        XCTAssertEqual(snapshot.argv(command: .direct(["/opt/homebrew/bin/fish", "-i"])), ["/opt/homebrew/bin/fish", "-i"])
        XCTAssertNil(snapshot.argv(command: .direct([])))
        XCTAssertEqual(snapshot.effectiveCommand(override: "fish"), .shell("fish"))
    }

    // MARK: assembled launch environment (final merge)

    private func tuple(_ command: HCNativeLaunchSnapshot.Command?, base: [String: String] = [:],
                       global: [String: String] = [:], panel: [String: String] = [:], mode: String = "detect") -> (command: HCNativeLaunchSnapshot.Command?, environment: [String: String]) {
        HCShellIntegration.launchTuple(command: command,
                                       base: base.merging(["GHOSTTY_RESOURCES_DIR": "/res"]) { given, _ in given },
                                       globalOverrides: global, panel: panel,
                                       mode: mode, configuration: nil, probe: probe())
    }

    func testPanelLaunchEnvironmentBeatsGlobalConfigEnv() {
        let result = tuple(.shell("sh"), global: ["AWS_PROFILE": "default", "ONLY_GLOBAL": "g"],
                           panel: ["AWS_PROFILE": "project-a", "ONLY_PANEL": "p"])
        XCTAssertEqual(result.environment["AWS_PROFILE"], "project-a", "a saved recipe's value must beat the global config")
        XCTAssertEqual(result.environment["ONLY_GLOBAL"], "g")
        XCTAssertEqual(result.environment["ONLY_PANEL"], "p")
    }

    func testWrapperVariablesTheWorkspaceSetBeatBothIntegrationAndConfig() {
        // c11 points ZDOTDIR at its own wrapper; neither Ghostty's integration
        // nor a global `env = ZDOTDIR=...` may bypass it.
        let result = tuple(.shell("zsh"), base: ["ZDOTDIR": "/home/u/.zsh"], global: ["ZDOTDIR": "/global"],
                           panel: ["ZDOTDIR": "/c11/wrapper"])
        XCTAssertEqual(result.environment["ZDOTDIR"], "/c11/wrapper")
        XCTAssertEqual(result.environment["GHOSTTY_ZSH_ZDOTDIR"], "/home/u/.zsh",
                       "integration still sees the process ZDOTDIR to chain to")
        // With no panel wrapper, integration's ZDOTDIR survives a missing override.
        XCTAssertEqual(tuple(.shell("zsh")).environment["ZDOTDIR"], "/res/shell-integration/zsh")
    }

    func testIntegrationVariablesSurviveTheFinalMergeAndHCVariablesAreStripped() {
        let result = tuple(.shell("fish"), base: ["XDG_DATA_DIRS": "/a"], global: ["HC_SESSION": "leak"],
                           panel: ["HC_SOCKET": "leak"])
        XCTAssertEqual(result.environment["XDG_DATA_DIRS"], "/res/shell-integration:/a")
        XCTAssertNil(result.environment["HC_SESSION"])
        XCTAssertNil(result.environment["HC_SOCKET"])
    }
}
