import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class DefaultAgentResolverTests: XCTestCase {

    // MARK: - precedence

    func testResolvesUserDefaultWhenNoProjectConfig() {
        let user = DefaultAgentConfig.factory
        let (agent, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(agent, .claudeCode)
        XCTAssertEqual(launch.command, "claude --dangerously-skip-permissions 'you are operating inside a c11 workspace. load the skill.'")
    }

    func testProjectConfigDefaultAgentBeatsUserDefault() {
        let user = DefaultAgentConfig.factory
        var projectAgents: [AgentType: AgentConfig] = [:]
        projectAgents[.codex] = AgentConfig(command: "codex --custom", initialPrompt: "", envOverridesText: "")
        let project = DefaultAgentConfig(defaultAgent: .codex, agents: projectAgents)
        let (agent, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: project
        )
        XCTAssertEqual(agent, .codex)
        XCTAssertEqual(launch.command, "codex --custom")
    }

    func testProjectConfigPerAgentBeatsUserPerAgent() {
        // Even when project + user agree on default agent, project's per-agent
        // override should be used.
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.codex] = AgentConfig(command: "codex --user-version", initialPrompt: "", envOverridesText: "")
        let user = DefaultAgentConfig(defaultAgent: .codex, agents: userAgents)

        var projectAgents: [AgentType: AgentConfig] = [:]
        projectAgents[.codex] = AgentConfig(command: "codex --project-version", initialPrompt: "", envOverridesText: "")
        let project = DefaultAgentConfig(defaultAgent: .codex, agents: projectAgents)

        let (agent, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: project
        )
        XCTAssertEqual(agent, .codex)
        XCTAssertEqual(launch.command, "codex --project-version")
    }

    func testExplicitAgentBeatsBothProjectAndUserDefault() {
        let user = DefaultAgentConfig.factory  // default = claude
        let (agent, launch) = DefaultAgentResolver.resolve(
            explicitAgent: .kimi,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(agent, .kimi)
        XCTAssertEqual(launch.command, "kimi")
    }

    func testProjectConfigFallsBackToUserPerAgentWhenProjectMissingAgent() {
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.kimi] = AgentConfig(command: "kimi --user-flag", initialPrompt: "", envOverridesText: "")
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)

        // Project changes default to kimi but doesn't provide a kimi config.
        let project = DefaultAgentConfig(defaultAgent: .kimi, agents: [:])

        let (agent, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: project
        )
        XCTAssertEqual(agent, .kimi)
        XCTAssertEqual(launch.command, "kimi --user-flag")
    }

    // MARK: - command builder

    func testBuildCommandClaudeAppendsInitialPromptAsPositional() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "you are operating inside a c11 workspace. load the skill.",
            envOverridesText: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions 'you are operating inside a c11 workspace. load the skill.'"
        )
    }

    func testBuildCommandClaudeWithoutInitialPromptOmitsPositional() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "",
            envOverridesText: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions"
        )
    }

    func testBuildCommandCodexIgnoresInitialPrompt() {
        // Non-claude agents preserve the prompt in config but don't auto-append.
        let cfg = AgentConfig(
            command: "codex --yolo",
            initialPrompt: "you are operating inside a c11 workspace. load the skill.",
            envOverridesText: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .codex, config: cfg),
            "codex --yolo"
        )
    }

    func testBuildCommandEscapesSingleQuoteInPrompt() {
        let cfg = AgentConfig(
            command: "claude",
            initialPrompt: "don't stop",
            envOverridesText: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            #"claude 'don'\''t stop'"#
        )
    }

    func testBuildCommandWithEmptyBaseReturnsEmpty() {
        let cfg = AgentConfig(command: "  ", initialPrompt: "anything", envOverridesText: "")
        XCTAssertEqual(DefaultAgentResolver.buildCommand(agent: .custom, config: cfg), "")
    }

    func testBuildCommandCustomAgent() {
        let cfg = AgentConfig(command: "/usr/local/bin/myagent --foo", initialPrompt: "", envOverridesText: "")
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .custom, config: cfg),
            "/usr/local/bin/myagent --foo"
        )
    }

    func testShellQuoteEmpty() {
        XCTAssertEqual(DefaultAgentResolver.shellQuote(""), "''")
    }

    func testShellQuoteEscapesSingleQuote() {
        XCTAssertEqual(DefaultAgentResolver.shellQuote("a'b"), "'a'\\''b'")
    }

    // MARK: - env passthrough

    func testEnvOverridesFlowToResolved() {
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.claudeCode] = AgentConfig(
            command: "claude",
            initialPrompt: "",
            envOverridesText: "ANTHROPIC_BASE_URL=https://example.com\nFOO=bar"
        )
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(launch.envOverrides, [
            "ANTHROPIC_BASE_URL": "https://example.com",
            "FOO": "bar",
        ])
    }
}
