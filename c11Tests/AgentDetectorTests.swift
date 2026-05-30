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
}
