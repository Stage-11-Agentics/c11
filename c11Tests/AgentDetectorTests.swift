import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Covers `AgentDetector.classify(comm:args:)` — the pure classifier exposed
/// for tests so we can exercise the binary-match table without a live ps scan.
final class AgentDetectorTests: XCTestCase {

    // MARK: - Direct comm matches

    func testClassifyClaudeReturnsClaudeCode() {
        XCTAssertEqual(AgentDetector.classify(comm: "claude", args: ""), "claude-code")
        XCTAssertEqual(AgentDetector.classify(comm: "claude-code", args: ""), "claude-code")
    }

    func testClassifyCopilotReturnsGitHubCopilot() {
        XCTAssertEqual(AgentDetector.classify(comm: "copilot", args: ""), "github-copilot")
    }

    func testClassifyCodexReturnsCodex() {
        XCTAssertEqual(AgentDetector.classify(comm: "codex", args: ""), "codex")
    }

    /// Darwin can truncate a long executable path in `ps`'s `comm` column
    /// while retaining the complete argv[0]. This is the exact staging
    /// failure that left live Claude processes classified as `unknown`.
    func testClassifyTruncatedCommUsesArgvZeroExecutable() {
        XCTAssertEqual(
            AgentDetector.classify(
                comm: "/Users/atin/.loc",
                args: "/Users/atin/.local/bin/claude --dangerously-skip-permissions --model opus"
            ),
            "claude-code"
        )
    }

    func testClassifyArgvZeroDoesNotMatchLaterUserArguments() {
        XCTAssertEqual(
            AgentDetector.classify(
                comm: "/Users/atin/.loc",
                args: "/Users/atin/bin/report --label claude"
            ),
            "unknown"
        )
    }

    // MARK: - Node-wrapped matches via args substring

    func testClassifyNodeWrappedCopilotBinPathReturnsGitHubCopilot() {
        let args = "node /Users/me/.nvm/versions/node/v24.11.1/bin/copilot --allow-all --autopilot"
        XCTAssertEqual(AgentDetector.classify(comm: "node", args: args), "github-copilot")
    }

    func testClassifyNodeWrappedGitHubCopilotPackagePathReturnsGitHubCopilot() {
        let args = "node /Users/me/.nvm/versions/node/v24.11.1/lib/node_modules/@github/copilot/dist/main.js"
        XCTAssertEqual(AgentDetector.classify(comm: "node", args: args), "github-copilot")
    }

    func testClassifyNodeWrappedClaudeCodeReturnsClaudeCode() {
        let args = "node /Users/me/.npm/global/lib/node_modules/@anthropic-ai/claude-code/dist/cli.js"
        XCTAssertEqual(AgentDetector.classify(comm: "node", args: args), "claude-code")
    }

    // MARK: - Negative cases

    func testClassifyUnrelatedNodeProcessReturnsUnknown() {
        let args = "node /Users/me/project/server.js"
        XCTAssertEqual(AgentDetector.classify(comm: "node", args: args), "unknown")
    }

    func testClassifyZshReturnsShell() {
        XCTAssertEqual(AgentDetector.classify(comm: "zsh", args: ""), "shell")
        XCTAssertEqual(AgentDetector.classify(comm: "-zsh", args: ""), "shell")
    }

    // MARK: - Runtime shim invocations (C11-155: bun / node-symlink installs)

    /// omp ships as a `#!/usr/bin/env bun` shim → runs as `comm=bun` with the
    /// named binary in argv. The bun runtime branch + script-basename match it.
    func testClassifyBunShimOmpReturnsOmp() {
        XCTAssertEqual(
            AgentDetector.classify(comm: "bun", args: "bun /Users/atin/.bun/bin/omp"),
            "omp")
    }

    /// pi ships as a `#!/usr/bin/env node` shim; a node-shebang symlink reports
    /// the symlink path in argv (not the module path), so the org-path substring
    /// misses and the basename match is what classifies it.
    func testClassifyNodeShimPiReturnsPi() {
        XCTAssertEqual(
            AgentDetector.classify(comm: "node", args: "node /Users/atin/.bun/bin/pi"),
            "pi")
    }

    /// Module-path invocation still matches via the substring rail (here bun).
    func testClassifyBunModulePathOmpReturnsOmp() {
        let args = "bun /Users/atin/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
        XCTAssertEqual(AgentDetector.classify(comm: "bun", args: args), "omp")
    }

    /// Basename match keys on the LAST path component only, so a comm-named
    /// mid-path directory ("pi" here) is not a false positive.
    func testClassifyRuntimeBasenameIgnoresMidPathDirNames() {
        XCTAssertEqual(
            AgentDetector.classify(comm: "node", args: "node /Users/me/pi/app/server.js"),
            "unknown")
    }

    // MARK: - Python-shebang shims

    /// kimi installs as a pipx/venv console script whose shebang points at the
    /// venv python, so the kernel execs the interpreter: comm=`python` with the
    /// script path in argv. The Python interpreter branch + `/kimi` substring
    /// (and the basename rail) classify it — previously it fell through to
    /// `unknown` because only node/bun/deno were treated as interpreters.
    func testClassifyPythonShimKimiReturnsKimi() {
        XCTAssertEqual(
            AgentDetector.classify(comm: "python", args: "python /Users/atin/.local/bin/kimi"),
            "kimi")
    }

    /// Versioned interpreter comm (`python3.13`, a venv symlink) still counts as
    /// a Python runtime via the `python` prefix match.
    func testClassifyVersionedPythonShimKimiReturnsKimi() {
        XCTAssertEqual(
            AgentDetector.classify(
                comm: "python3.13",
                args: "python3.13 /Users/atin/.local/pipx/venvs/kimi-cli/bin/kimi"),
            "kimi")
    }

    /// An unrelated Python process must not be misclassified as an agent.
    func testClassifyUnrelatedPythonProcessReturnsUnknown() {
        XCTAssertEqual(
            AgentDetector.classify(comm: "python", args: "python /Users/me/project/manage.py runserver"),
            "unknown")
    }

    // MARK: - Native binary comms for wrapper-less agents

    /// grok / opencode ship as native binaries (no runtime wrapper), so the
    /// foreground comm is the agent name itself and the direct comm table
    /// classifies them. These are the agents whose detection depended on the
    /// TTY reaching AgentDetector (fixed in the report_tty workspace resolution).
    func testClassifyNativeGrokAndOpencode() {
        XCTAssertEqual(AgentDetector.classify(comm: "grok", args: "grok --always-approve"), "grok")
        XCTAssertEqual(AgentDetector.classify(comm: "opencode", args: "opencode"), "opencode")
    }

    // MARK: - Long argv0 (C11-246)

    /// `/tmp/fb/claude` is 13 characters, so it fits in the 16-column comm
    /// field and the basename still matches.
    func testClassifyShortAbsolutePath() throws {
        XCTAssertEqual(
            AgentDetector.classify(comm: "/tmp/fb/claude", args: "/tmp/fb/claude"),
            "claude-code"
        )
        let line = "22769 22744 ??          0 /tmp/fb/claude /tmp/fb/claude"
        let info = try XCTUnwrap(AgentDetector.parsePSLine(line))
        XCTAssertEqual(info.comm, "/tmp/fb/claude")
        XCTAssertEqual(
            AgentDetector.classify(comm: info.comm, args: info.args),
            "claude-code"
        )
    }

    /// Live `ps` line: comm is a 16-character clip of the path, and the tty
    /// column is padded. The full argv0 still ends in `claude`.
    func testClassifyLongDirectoryPath() throws {
        let line = "22771 22744 ??          0 /tmp/c11-246-psp /tmp/c11-246-psprobe/dir-claude-501-Users-atin-Projects-Stage11-code-c11-0bb5b2bc-702c-4390-a904-scratchpad-worktrees-very-long-component-name/claude"
        let info = try XCTUnwrap(AgentDetector.parsePSLine(line))
        XCTAssertEqual(info.comm, "/tmp/c11-246-psp")
        XCTAssertEqual(
            AgentDetector.classify(comm: info.comm, args: info.args),
            "claude-code"
        )
        // Same identity when the argv line was sliced down to `tpgid` and
        // only proc_pidpath still has the path.
        let path = "/private/tmp/claude-501/Users-atin-Projects-Stage11-code-c11/0bb5b2bc-702c-4390-a904-79405ad6efdd/scratchpad/claude"
        XCTAssertGreaterThan(path.count, 16)
        XCTAssertEqual(
            AgentDetector.classify(AgentDetector.ProcessFacts(
                comm: String(path.prefix(16)),
                args: "0 \(String(path.prefix(16)))",
                executablePath: path
            )),
            "claude-code"
        )
    }

    /// The basename itself is longer than the 16-column comm field. The clip
    /// is not a registered name, and a longer name that only starts with one
    /// (`claude-code`) must not classify. A registered basename that arrives
    /// only on the executable path still does.
    func testClassifyBasenameLongerThanSixteenCharacters() throws {
        let line = "22770 22744 ??          0 /tmp/c11-246-psp /tmp/c11-246-psprobe/short/claude-code-extra-bin"
        let info = try XCTUnwrap(AgentDetector.parsePSLine(line))
        XCTAssertTrue(info.args.hasPrefix("/tmp/c11-246-psprobe/short/claude-code-extra-bin"))
        XCTAssertEqual(
            AgentDetector.classify(comm: info.comm, args: info.args),
            "unknown"
        )
        let registered = "/opt/homebrew/Cellar/opencode/1.18.30_2/bin/opencode-cli"
        XCTAssertEqual(
            AgentDetector.classify(AgentDetector.ProcessFacts(
                comm: String(registered.prefix(16)),
                args: "0 \(String(registered.prefix(16)))",
                executablePath: registered
            )),
            "opencode"
        )
    }

    /// A long runtime path is clipped in comm (`/opt/homebrew/bin/node` is 22
    /// characters). The script basename is still the agent.
    func testClassifyLongRuntimePathUsesScriptBasename() {
        let node = "/opt/homebrew/bin/node"
        XCTAssertGreaterThan(node.count, 16)
        let args = "\(node) /Users/me/.nvm/versions/node/v24.11.1/bin/copilot --allow-all"
        XCTAssertEqual(
            AgentDetector.classify(AgentDetector.ProcessFacts(
                comm: String(node.prefix(16)),
                args: args
            )),
            "github-copilot"
        )
    }

    /// `runPS` always passes `-t`, so live lines carry `ttysNNN` and the tty
    /// column's two-space pad. Captured from `ps -t ttys001`. The 16-character
    /// comm clip is not the agent; the full argv0 is.
    func testParsePSLineTTYTwoSpacePadUsesFullArgv0() throws {
        let line = "62387 62165 ttys001  62387 /Users/atin/.gro /Users/atin/.grok/bin/grok --always-approve"
        let info = try XCTUnwrap(AgentDetector.parsePSLine(line))
        XCTAssertEqual(info.tty, "ttys001")
        XCTAssertEqual(info.comm, "/Users/atin/.gro")
        XCTAssertEqual(info.args, "/Users/atin/.grok/bin/grok --always-approve")
        XCTAssertEqual(AgentDetector.classify(comm: info.comm, args: info.args), "grok")
    }

    /// The scan's path lookup, pointed at this process, is the executable
    /// dyld reports for it.
    func testExecutablePathReturnsThisProcess() throws {
        var size = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(size))
        XCTAssertEqual(_NSGetExecutablePath(&buffer, &size), 0)
        let expected = URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath().path
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let got = try XCTUnwrap(AgentDetector.executablePath(for: pid))
        XCTAssertEqual(URL(fileURLWithPath: got).resolvingSymlinksInPath().path, expected)
    }

    /// `~/.local/bin/claude` resolves to a versioned file (`2.1.286`). The
    /// invoked argv0 basename is what classifies; the resolved basename does
    /// not hide it.
    func testClassifySymlinkTargetDoesNotHideArgv0() {
        XCTAssertEqual(
            AgentDetector.classify(AgentDetector.ProcessFacts(
                comm: "/Users/atin/.loc",
                args: "/Users/atin/.local/bin/claude --dangerously-skip-permissions",
                executablePath: "/Users/atin/.local/share/claude/versions/2.1.286"
            )),
            "claude-code"
        )
    }
}
