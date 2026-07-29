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
}
