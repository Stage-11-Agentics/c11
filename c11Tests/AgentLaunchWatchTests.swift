import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// Pathfinder (2026-11-03): the launch watch's signature matcher and verdict rules.
// The screens are the ones Atin's two failed launches showed.
final class AgentLaunchWatchTests: XCTestCase {
    private func cause(_ screen: String, binary: String? = "claude", started: Bool = false) -> AgentLaunchWatch.Cause? {
        AgentLaunchWatch.scan(screen, binary: binary, agentStarted: started)?.cause
    }

    func testAMissingAgentCommandIsNotInstalledOnlyWhenItNamesTheAgent() {
        XCTAssertEqual(cause("demo@linuxbox:~$ claude --model sonnet\nbash: claude: command not found\n"), .notInstalled)
        XCTAssertEqual(cause("% claude\nzsh: command not found: claude"), .notInstalled)
        XCTAssertEqual(cause("Error: claude not found in PATH"), .notInstalled)
        XCTAssertEqual(AgentLaunchWatch.scan("Error: claude not found in PATH\nadmin@vm ~ %", binary: "claude", agentStarted: false)?.line,
                       "Error: claude not found in PATH")
        // Shell-startup noise about another command is not this launch failing.
        XCTAssertNil(cause("zsh: command not found: compdef\n% claude"))
        XCTAssertEqual(cause("sh: compdef: command not found", binary: nil), .notInstalled)
        // Once the agent runs, a tool's output saying the same is not a failed launch.
        XCTAssertNil(cause("bash: claude: command not found", started: true))
    }

    func testAgentLevelSignatures() {
        XCTAssertEqual(cause("⏺ You've hit your weekly limit · resets Nov 6, 4pm"), .usageLimit)
        XCTAssertEqual(cause("⏺ You’ve hit your usage limit", started: true), .usageLimit)
        XCTAssertEqual(cause("Login expired · Please run /login"), .notLoggedIn)
        XCTAssertEqual(cause("Not logged in · Run /login"), .notLoggedIn)
        XCTAssertEqual(cause("⎿ API Error: 500 {\"type\":\"error\"}"), .apiError)
        // Claude retrying on its own is not a failure yet.
        XCTAssertNil(cause("⎿ API Error (529 overloaded) · Retrying in 5 seconds… (attempt 1/10)"))
        // Claude wraps a long line; the halves are joined before matching.
        XCTAssertEqual(cause("⏺ You've hit your weekly\n  limit · resets 4pm", started: true), .usageLimit)
    }

    /// Prose that mentions a signature, or shell noise that resembles one, is
    /// not a failed launch: only the forms Claude and the shell draw count,
    /// anchored at a line's start, and after a turn starts only behind Claude's marker.
    func testProseAndShellNoiseAreNotFailures() {
        XCTAssertNil(cause("⏺ Let me check the API error in the proxy logs.", started: true))
        XCTAssertNil(cause("  the API Error: 500 we saw earlier came from the proxy", started: true))
        XCTAssertNil(cause("API Error: 500", started: true))
        XCTAssertNil(cause("You've hit your weekly limit", started: true))
        XCTAssertNil(cause("⏺ I am not logged in to that service, so I used the cache.", started: true))
        XCTAssertNil(cause("warning: not logged into gh; run gh auth login"))
        XCTAssertNil(cause("Not logged into GitHub Copilot"))
        XCTAssertNil(cause("Not logged in to npm"))
        XCTAssertNil(cause("Last login: Tue Nov  3 22:10:04 on ttys003"))
        XCTAssertNil(cause("echo 'You've hit your limit' is a test string"))
        XCTAssertNil(cause("⏺ Is this a project you created or one you trust? is a question Claude asks", started: true))
    }

    func testTheTrustDialogNeedsTheOperatorAndAFailureOutranksIt() {
        let trust = """
         Accessing workspace:
         /Users/demo/Projects/Stage11/code/platform
         Quick safety check: Is this a project you created or one you trust?
         ❯ 1. Yes, I trust this folder
           2. No, exit
        """
        XCTAssertEqual(cause(trust), .trustFolder)
        XCTAssertEqual(AgentLaunchWatch.Cause.trustFolder.verdict, .needsOperator)
        XCTAssertEqual(cause(trust + "\nYou've hit your weekly limit"), .usageLimit)
        XCTAssertEqual(AgentLaunchWatch.Cause.usageLimit.verdict, .failed)
        XCTAssertNil(cause("╭───╮\n│ > │\n╰───╯\n  ? for shortcuts"))
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func evaluate(_ screen: String? = nil, composer: Bool = false, turnStarted: TimeInterval? = nil,
                          turnEnded: TimeInterval? = nil, at seconds: TimeInterval, prompted: Bool = true) -> AgentLaunchWatch.Outcome? {
        let rules = AgentLaunchWatch.Rules(binary: "claude", hasPrompt: prompted, startedAt: start,
                                           deadline: start.addingTimeInterval(AgentLaunchWatch.window))
        let observation = AgentLaunchWatch.Observation(
            screen: screen, composerReady: composer,
            turnStartedAt: turnStarted.map { start.addingTimeInterval($0) },
            turnEndedAt: turnEnded.map { start.addingTimeInterval($0) },
            now: start.addingTimeInterval(seconds))
        return AgentLaunchWatch.evaluate(observation, rules: rules)
    }

    func testVerdictRules() {
        XCTAssertNil(evaluate("% claude", at: 2))
        XCTAssertEqual(evaluate("bash: claude: command not found", at: 2)?.verdict, .failed)
        XCTAssertEqual(evaluate(turnStarted: 2, turnEnded: 6, at: 7)?.evidence, "turn_ended")
        // A prompted agent's ready composer is not proof: the limit shows after its first submit.
        XCTAssertNil(evaluate(composer: true, turnStarted: 3, at: 5))
        XCTAssertEqual(evaluate(composer: true, turnStarted: 3, at: 11)?.evidence, "working")
        XCTAssertEqual(evaluate(composer: true, at: 4, prompted: false)?.evidence, "composer_ready")
        XCTAssertEqual(evaluate("⏺ You've hit your weekly limit", composer: true, turnStarted: 3, at: 4)?.verdict, .failed)
        XCTAssertNil(evaluate("⏺ Let me look at the API error.", turnStarted: 3, at: 4))
        // A turn edge from before this launch (a reused panel) is not this agent's.
        XCTAssertNil(evaluate(turnEnded: -30, at: 3))
        XCTAssertEqual(evaluate(at: 60)?.verdict, .quiet)
    }

    func testTheSentenceNamesTheMachineAndCause() {
        XCTAssertEqual(AgentLaunchWatch.sentence(for: .notInstalled, agent: "Claude Code", machine: "Linuxbox", binary: "claude", folder: nil),
                       "Claude Code on Linuxbox didn't start: claude is not installed there.")
        XCTAssertEqual(AgentLaunchWatch.sentence(for: .trustFolder, agent: "Claude Code", machine: "Studio", binary: "claude",
                                                 folder: "~/Projects/x"),
                       "Claude Code on Studio is waiting for you to trust ~/Projects/x.")
    }

    func testLaunchLineBinaryAndFolderAbbreviation() {
        XCTAssertEqual(AgentLaunchWatch.binary(ofLaunchLine: "claude --model sonnet"), "claude")
        XCTAssertEqual(AgentLaunchWatch.binary(ofLaunchLine: "C11_MISSION_FILE=/tmp/m claude --x"), "claude")
        XCTAssertEqual(AgentLaunchWatch.binary(ofLaunchLine: "'/opt/homebrew/bin/codex' -m x"), "codex")
        XCTAssertEqual(AgentLaunchWatch.abbreviate("/Users/a/Projects/x", home: "/Users/a"), "~/Projects/x")
        XCTAssertEqual(AgentLaunchWatch.abbreviate("/Users/ab/x", home: "/Users/a"), "/Users/ab/x")
        XCTAssertEqual(AgentLaunchWatch.abbreviate("/Users/a", home: "/Users/a/"), "~")
    }
}
