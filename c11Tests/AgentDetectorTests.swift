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
}
