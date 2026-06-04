import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for `DefaultAgentLaunchComposition.plan(...)`, the pure seam
/// extracted from `launchInExistingSurface` (C11-121). It decides the exact
/// shell line typed into a surface's PTY for `default-agent launch --in-surface`
/// and whether a prompt must be delivered after the agent boots (non-claude
/// TUIs) versus riding the launch line as a positional (claude-code).
///
/// These run in `c11LogicTests` (no app host) because the composition is free of
/// TerminalController/AppKit state — same pattern as `CwdParamResolutionTests`.
final class DefaultAgentLaunchCompositionTests: XCTestCase {

    // MARK: - claude-code: prompt rides the launch line

    func testClaudeWithPromptAppendsQuotedPositionalAndNoDelayedPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude --dangerously-skip-permissions",
            cwd: nil,
            prompt: "do the thing"
        )
        XCTAssertEqual(plan.launchLine, "claude --dangerously-skip-permissions 'do the thing'")
        XCTAssertNil(plan.delayedPrompt, "claude prompt rides the launch line, not a delayed send")
    }

    func testClaudeWithPromptAndCwdPrefixesCdThenQuotedPositional() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude",
            cwd: "/tmp/work dir",
            prompt: "hi"
        )
        XCTAssertEqual(plan.launchLine, "cd '/tmp/work dir' && claude 'hi'")
        XCTAssertNil(plan.delayedPrompt)
    }

    func testClaudePromptWithSingleQuoteIsShellEscaped() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude",
            cwd: nil,
            prompt: "it's done"
        )
        // shellQuote wraps in single quotes and escapes embedded ' via '\'' .
        XCTAssertEqual(plan.launchLine, "claude 'it'\\''s done'")
        XCTAssertNil(plan.delayedPrompt)
    }

    func testClaudeWithoutPromptIsBareCommand() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude",
            cwd: nil,
            prompt: nil
        )
        XCTAssertEqual(plan.launchLine, "claude")
        XCTAssertNil(plan.delayedPrompt)
    }

    func testClaudeWithWhitespaceOnlyPromptIsTreatedAsNoPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude",
            cwd: nil,
            prompt: "   \n  "
        )
        XCTAssertEqual(plan.launchLine, "claude", "blank prompt must not append an empty quoted positional")
        XCTAssertNil(plan.delayedPrompt)
    }

    // MARK: - non-claude agents: prompt is delivered after boot

    func testCodexWithPromptDoesNotRideLineAndDefersPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .codex,
            bareCommand: "codex --yolo",
            cwd: nil,
            prompt: "review PR #42"
        )
        XCTAssertEqual(plan.launchLine, "codex --yolo", "codex cannot accept a positional prompt; line is bare")
        XCTAssertEqual(plan.delayedPrompt, "review PR #42")
    }

    func testCodexWithCwdAndPromptPrefixesCdAndDefersTrimmedPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .codex,
            bareCommand: "codex",
            cwd: "/repo",
            prompt: "  go  "
        )
        XCTAssertEqual(plan.launchLine, "cd '/repo' && codex")
        XCTAssertEqual(plan.delayedPrompt, "go", "delayed prompt is trimmed before delivery")
    }

    func testOpencodeWithoutPromptHasNoDelayedPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .opencode,
            bareCommand: "opencode",
            cwd: nil,
            prompt: nil
        )
        XCTAssertEqual(plan.launchLine, "opencode")
        XCTAssertNil(plan.delayedPrompt)
    }

    func testKimiWithBlankPromptHasNoDelayedPrompt() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .kimi,
            bareCommand: "kimi",
            cwd: nil,
            prompt: "  "
        )
        XCTAssertEqual(plan.launchLine, "kimi")
        XCTAssertNil(plan.delayedPrompt, "a blank prompt must not schedule a delayed empty send")
    }

    // MARK: - cwd prefix handling

    func testEmptyCwdDoesNotPrefixCd() {
        let plan = DefaultAgentLaunchComposition.plan(
            agent: .claudeCode,
            bareCommand: "claude",
            cwd: "   ",
            prompt: nil
        )
        XCTAssertEqual(plan.launchLine, "claude", "blank cwd must not emit a `cd  &&` prefix")
    }
}
