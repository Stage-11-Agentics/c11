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
        // The factory pins Opus for claude-code and no longer seeds a launch
        // prompt, so the resolved command is just the launcher with `--model opus`.
        XCTAssertEqual(launch.command, "claude --dangerously-skip-permissions --model opus")
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
        XCTAssertEqual(launch.command, "kimi --auto")
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

    func testProjectConfigWithoutExplicitDefaultDoesNotOverrideUser() throws {
        // A v2 project file with per-agent entries but no `defaultAgent` key must
        // keep the user's Settings pick, not silently force the claude-code
        // fallback. Regression for the stale-~/.c11/agents.json A-button bug.
        let project = try JSONDecoder().decode(
            DefaultAgentConfig.self,
            from: Data(#"{"agents":{}}"#.utf8)
        )
        let (agent, _) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: DefaultAgentConfig(defaultAgent: .codex, agents: [:]),
            projectConfig: project
        )
        XCTAssertEqual(agent, .codex)
    }

    func testProjectConfigWithExplicitDefaultStillOverridesUser() throws {
        // The honored-override path must keep working after the fix.
        let project = try JSONDecoder().decode(
            DefaultAgentConfig.self,
            from: Data(#"{"defaultAgent":"kimi","agents":{}}"#.utf8)
        )
        let (agent, _) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: DefaultAgentConfig(defaultAgent: .codex, agents: [:]),
            projectConfig: project
        )
        XCTAssertEqual(agent, .kimi)
    }

    // MARK: - command builder

    func testBuildCommandClaudeAppendsInitialPromptAsPositional() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "You are inside c11 (a terminal multiplexer). A c11 skill covering panes, splits, and status is available if you need it.",
            envOverridesText: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions 'You are inside c11 (a terminal multiplexer). A c11 skill covering panes, splits, and status is available if you need it.'"
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
            initialPrompt: "You are inside c11 (a terminal multiplexer). A c11 skill covering panes, splits, and status is available if you need it.",
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

    // MARK: - model pinning

    func testBuildCommandInjectsPinnedModelBeforePrompt() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "go",
            envOverridesText: "",
            model: "opus"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus 'go'"
        )
    }

    func testBuildCommandInjectsPinnedModelWithoutPrompt() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "",
            envOverridesText: "",
            model: "fable"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model fable"
        )
    }

    func testBuildCommandEmptyModelInjectsNothing() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "",
            envOverridesText: "",
            model: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions"
        )
    }

    func testBuildCommandDoesNotDoubleModelWhenCommandAlreadyHasOne() {
        // Operator hardcoded a model in the command — their choice wins and we
        // must not pass --model twice.
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions --model sonnet",
            initialPrompt: "",
            envOverridesText: "",
            model: "opus"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model sonnet"
        )
    }

    func testBuildCommandInjectsModelForCodexViaTemplate() {
        // Flag injection is template-driven: codex's manifest declares
        // `--model`, so a pinned model now renders for it too.
        let cfg = AgentConfig(
            command: "codex --yolo",
            initialPrompt: "",
            envOverridesText: "",
            model: "gpt-5.2"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .codex, config: cfg),
            "codex --yolo --model gpt-5.2"
        )
    }

    func testBuildCommandDoesNotInjectModelForTemplatelessAgent() {
        // `custom` declares no model-flag syntax — a stray model value must be
        // ignored, not guessed into a flag.
        let cfg = AgentConfig(
            command: "myagent --go",
            initialPrompt: "",
            envOverridesText: "",
            model: "opus"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .custom, config: cfg),
            "myagent --go"
        )
    }

    func testLauncherCommandCarriesModelForBareExport() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "some prompt",
            envOverridesText: "",
            model: "opus"
        )
        // bareCommand / C11_DEFAULT_AGENT_LAUNCH carries the model but never the
        // positional prompt, so orchestrators can append their own.
        XCTAssertEqual(
            DefaultAgentResolver.launcherCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus"
        )
    }

    // MARK: - effort pinning

    func testBuildCommandInjectsPinnedEffortBeforePrompt() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "go",
            envOverridesText: "",
            effort: "high"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --effort high 'go'"
        )
    }

    func testBuildCommandInjectsBothModelAndEffort() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "go",
            envOverridesText: "",
            model: "opus",
            effort: "xhigh"
        )
        // model first, then effort, then the positional prompt stays last.
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus --effort xhigh 'go'"
        )
    }

    func testBuildCommandEmptyEffortInjectsNothing() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "",
            envOverridesText: "",
            model: "opus",
            effort: ""
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus"
        )
    }

    func testBuildCommandDoesNotDoubleEffortWhenCommandAlreadyHasOne() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions --effort low",
            initialPrompt: "",
            envOverridesText: "",
            effort: "max"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --effort low"
        )
    }

    func testBuildCommandInjectsEffortForCodexViaConfigKV() {
        // codex's effort syntax is the config-override form, rendered from its
        // template — not `--effort`.
        let cfg = AgentConfig(
            command: "codex --yolo",
            initialPrompt: "",
            envOverridesText: "",
            effort: "high"
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .codex, config: cfg),
            "codex --yolo -c model_reasoning_effort=high"
        )
    }

    func testBuildCommandDoesNotInjectEffortForTemplatelessAgent() {
        let cfg = AgentConfig(
            command: "grok --always-approve",
            initialPrompt: "",
            envOverridesText: "",
            effort: "high"
        )
        // grok's template declares a model flag but no effort axis.
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .grok, config: cfg),
            "grok --always-approve"
        )
    }

    func testLauncherCommandCarriesModelAndEffortForBareExport() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "some prompt",
            envOverridesText: "",
            model: "opus",
            effort: "high"
        )
        XCTAssertEqual(
            DefaultAgentResolver.launcherCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus --effort high"
        )
    }

    // MARK: - system-prompt axis

    private func claudeConfig(
        command: String = "claude --dangerously-skip-permissions",
        model: String = "",
        effort: String = "",
        systemPrompt: SystemPromptSetting? = nil
    ) -> AgentConfig {
        AgentConfig(command: command, initialPrompt: "", envOverridesText: "",
                    model: model, effort: effort, systemPrompt: systemPrompt)
    }

    func testSystemPromptAppendRendersBeforePositionalPrompt() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions", initialPrompt: "go",
            envOverridesText: "",
            systemPrompt: SystemPromptSetting(mode: .append, text: "Prefer terse answers.")
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --append-system-prompt 'Prefer terse answers.' 'go'"
        )
    }

    func testSystemPromptReplaceRenders() {
        let cfg = claudeConfig(systemPrompt: SystemPromptSetting(mode: .replace, text: "You are a shell."))
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --system-prompt 'You are a shell.'"
        )
    }

    func testSystemPromptReplaceEmptyIsBlankSlate() {
        // The Gregorovich blank slate: replace + "" still emits the flag with an
        // empty single-quoted value.
        let cfg = claudeConfig(systemPrompt: SystemPromptSetting(mode: .replace, text: ""))
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --system-prompt ''"
        )
    }

    func testSystemPromptInheritInjectsNothing() {
        let cfg = claudeConfig(systemPrompt: SystemPromptSetting(mode: .inherit, text: "ignored"))
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions"
        )
    }

    func testSystemPromptNilInjectsNothingByteIdentical() {
        // The AC's byte-identical regression: nil systemPrompt renders exactly
        // today's line (the default for every existing config).
        let cfg = claudeConfig(model: "opus", systemPrompt: nil)
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus"
        )
    }

    func testSystemPromptNotInjectedForAxislessHarness() {
        // codex has no system-prompt axis — a stray setting must be ignored,
        // never guessed into a flag.
        let cfg = AgentConfig(
            command: "codex --yolo", initialPrompt: "", envOverridesText: "",
            systemPrompt: SystemPromptSetting(mode: .replace, text: "nope")
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .codex, config: cfg),
            "codex --yolo"
        )
    }

    func testSystemPromptHardcodedReplaceFlagWins() {
        // Operator hardcoded --system-prompt — c11 injects nothing on top.
        let cfg = claudeConfig(
            command: "claude --dangerously-skip-permissions --system-prompt 'mine'",
            systemPrompt: SystemPromptSetting(mode: .append, text: "extra")
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --system-prompt 'mine'"
        )
    }

    func testSystemPromptHardcodedAppendFlagWins() {
        let cfg = claudeConfig(
            command: "claude --dangerously-skip-permissions --append-system-prompt 'mine'",
            systemPrompt: SystemPromptSetting(mode: .replace, text: "extra")
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --append-system-prompt 'mine'"
        )
    }

    func testSystemPromptOrdersAfterModelAndEffortBeforePrompt() {
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions", initialPrompt: "go",
            envOverridesText: "", model: "opus", effort: "high",
            systemPrompt: SystemPromptSetting(mode: .append, text: "hi")
        )
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus --effort high --append-system-prompt 'hi' 'go'"
        )
    }

    func testSystemPromptEscapesSingleQuote() {
        let cfg = claudeConfig(systemPrompt: SystemPromptSetting(mode: .replace, text: "don't"))
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            #"claude --dangerously-skip-permissions --system-prompt 'don'\''t'"#
        )
    }

    func testSystemPromptRidesLauncherForBareExport() {
        // The bare export (C11_DEFAULT_AGENT_LAUNCH) carries the system-prompt
        // flag but never the positional prompt.
        let cfg = AgentConfig(
            command: "claude --dangerously-skip-permissions", initialPrompt: "some prompt",
            envOverridesText: "",
            systemPrompt: SystemPromptSetting(mode: .append, text: "hi")
        )
        XCTAssertEqual(
            DefaultAgentResolver.launcherCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --append-system-prompt 'hi'"
        )
    }

    func testSystemPromptByteIdenticalThroughDecodedLegacyConfig() throws {
        // A config JSON written before the axis existed decodes systemPrompt=nil
        // → inherit → today's exact line.
        let cfg = try JSONDecoder().decode(
            AgentConfig.self,
            from: Data(#"{"command":"claude --dangerously-skip-permissions","initialPrompt":"","envOverridesText":"","model":"opus"}"#.utf8)
        )
        XCTAssertNil(cfg.systemPrompt)
        XCTAssertEqual(
            DefaultAgentResolver.buildCommand(agent: .claudeCode, config: cfg),
            "claude --dangerously-skip-permissions --model opus"
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

    // MARK: - bareCommand

    // The env-var export path uses bareCommand to avoid baking the operator's
    // configured seed prompt into the value callers compose into shell lines.
    // If bareCommand started picking up the seed, the C11_DEFAULT_AGENT_LAUNCH
    // shell-interpolation pattern in the c11 skill would silently drop any
    // caller-appended positional argument (claude takes only the first).

    func testBareCommandOmitsClaudeInitialPrompt() {
        // The factory no longer seeds a launch prompt, so configure one
        // explicitly to prove bareCommand strips it while command bakes it.
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.claudeCode] = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "orient the agent",
            envOverridesText: "",
            model: "opus"
        )
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        // The pinned model rides on the launcher (both bareCommand and the
        // baked command); only the positional prompt distinguishes them.
        XCTAssertEqual(launch.bareCommand, "claude --dangerously-skip-permissions --model opus")
        XCTAssertEqual(launch.initialPrompt, "orient the agent")
        // The baked form still ships on `command` for the A-button path.
        XCTAssertEqual(
            launch.command,
            "claude --dangerously-skip-permissions --model opus 'orient the agent'"
        )
    }

    func testBareCommandMatchesCommandWhenNoInitialPrompt() {
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.claudeCode] = AgentConfig(
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "",
            envOverridesText: ""
        )
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(launch.bareCommand, "claude --dangerously-skip-permissions")
        XCTAssertEqual(launch.command, "claude --dangerously-skip-permissions")
    }

    func testBareCommandForNonClaudeAgent() {
        // Non-claude agents never bake the prompt into `command`, so `command`
        // and `bareCommand` should match (modulo trimming). The factory no
        // longer seeds a prompt, so configure one to prove it is still surfaced
        // on `initialPrompt` for the post-ready delivery path.
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.codex] = AgentConfig(
            command: "codex --yolo",
            initialPrompt: "orient the agent",
            envOverridesText: ""
        )
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: .codex,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(launch.bareCommand, "codex --yolo")
        XCTAssertEqual(launch.command, "codex --yolo")
        // The prompt is still surfaced for non-claude agents — the launch
        // delivery path is what differs (post-ready sendText vs positional).
        XCTAssertEqual(launch.initialPrompt, "orient the agent")
    }

    func testBareCommandTrimsWhitespace() {
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.claudeCode] = AgentConfig(
            command: "  claude --dangerously-skip-permissions  ",
            initialPrompt: "",
            envOverridesText: ""
        )
        let user = DefaultAgentConfig(defaultAgent: .claudeCode, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(launch.bareCommand, "claude --dangerously-skip-permissions")
    }

    func testBareCommandEmptyForCustomWithNoCommand() {
        var userAgents = DefaultAgentConfig.factory.agents
        userAgents[.custom] = AgentConfig(command: "", initialPrompt: "", envOverridesText: "")
        let user = DefaultAgentConfig(defaultAgent: .custom, agents: userAgents)
        let (_, launch) = DefaultAgentResolver.resolve(
            explicitAgent: nil,
            userDefault: user,
            projectConfig: nil
        )
        XCTAssertEqual(launch.bareCommand, "")
        XCTAssertEqual(launch.command, "")
    }
}

// MARK: - launch-agent planning (docs/launch-agent-reference.md)

final class AgentLaunchPlannerTests: XCTestCase {

    private func userDefault(
        _ agent: AgentType = .claudeCode,
        command: String? = nil,
        model: String = "",
        effort: String = "",
        env: String = ""
    ) -> DefaultAgentConfig {
        var cfg = DefaultAgentConfig.factory
        cfg.agents[agent] = AgentConfig(
            command: command ?? agent.factoryCommand,
            initialPrompt: "",
            envOverridesText: env,
            model: model,
            effort: effort
        )
        return cfg
    }

    private func plan(
        _ request: AgentLaunchRequest,
        userDefault: DefaultAgentConfig = .factory,
        projectConfig: DefaultAgentConfig? = nil,
        userTemplate: UserAgentLaunchTemplate? = nil
    ) -> Result<AgentLaunchPlan, AgentLaunchPlanError> {
        AgentLaunchPlanner.plan(
            request: request,
            userDefault: userDefault,
            projectConfig: projectConfig,
            userTemplate: userTemplate
        )
    }

    // MARK: composition per kind

    func testClaudeModelEffortAndPositionalPrompt() throws {
        let result = plan(AgentLaunchRequest(
            kind: "claude-code", model: "opus", effort: "high", prompt: "do the thing"
        ))
        let p = try result.get()
        XCTAssertEqual(
            p.launchLine,
            "claude --dangerously-skip-permissions --model opus --effort high 'do the thing'"
        )
        XCTAssertNil(p.delayedPrompt)
        XCTAssertEqual(p.agentType, .claudeCode)
    }

    func testCodexEffortRendersConfigKV() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "codex", model: "gpt-5.2", effort: "high"
        )).get()
        XCTAssertEqual(p.launchLine, "codex --yolo --model gpt-5.2 -c model_reasoning_effort=high")
    }

    func testPiEffortRendersThinkingFlag() throws {
        let p = try plan(AgentLaunchRequest(kind: "pi", effort: "xhigh")).get()
        XCTAssertEqual(p.launchLine, "pi --thinking xhigh")
    }

    func testOpencodeModelWithSlashStaysUnquoted() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "opencode", model: "anthropic/claude-sonnet-4-5"
        )).get()
        XCTAssertEqual(
            p.launchLine,
            "opencode --auto --model anthropic/claude-sonnet-4-5"
        )
    }

    func testKimiPromptGoesPostBoot() throws {
        let p = try plan(AgentLaunchRequest(kind: "kimi", prompt: "hello")).get()
        XCTAssertEqual(p.launchLine, "kimi --auto")
        XCTAssertEqual(p.delayedPrompt, "hello")
    }

    // MARK: precedence

    func testRequestModelBeatsSettingsPin() throws {
        let cfg = userDefault(.claudeCode, model: "opus")
        let p = try plan(
            AgentLaunchRequest(kind: "claude-code", model: "sonnet"),
            userDefault: cfg
        ).get()
        XCTAssertTrue(p.launchLine.contains("--model sonnet"))
        XCTAssertFalse(p.launchLine.contains("opus"))
        XCTAssertEqual(p.model, "sonnet")
    }

    func testSettingsPinAppliesWhenRequestOmitsModel() throws {
        let cfg = userDefault(.claudeCode, model: "opus")
        let p = try plan(AgentLaunchRequest(kind: "claude-code"), userDefault: cfg).get()
        XCTAssertTrue(p.launchLine.contains("--model opus"))
        XCTAssertEqual(p.model, "opus")
    }

    func testHardcodedModelInCommandWinsWithWarning() throws {
        let cfg = userDefault(.claudeCode, command: "claude --dangerously-skip-permissions --model haiku")
        let p = try plan(
            AgentLaunchRequest(kind: "claude-code", model: "opus"),
            userDefault: cfg
        ).get()
        XCTAssertFalse(p.launchLine.contains("--model opus"))
        XCTAssertEqual(p.warnings.count, 1)
        XCTAssertEqual(p.model, "")
    }

    // MARK: errors

    func testUnknownKindFails() {
        guard case .failure(let err) = plan(AgentLaunchRequest(kind: "not-a-real-agent")) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err.code, "unknown_agent_type")
    }

    func testEffortUnsupportedFails() {
        guard case .failure(let err) = plan(AgentLaunchRequest(kind: "grok", effort: "high")) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err.code, "effort_flag_unsupported")
    }

    func testInvalidEffortValueFails() {
        guard case .failure(let err) = plan(AgentLaunchRequest(kind: "claude-code", effort: "warp")) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err.code, "invalid_effort")
    }

    // MARK: identity env

    func testEnvCarriesIdentityInBothPrefixes() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "codex", model: "gpt-5.2", task: "sekhem-42"
        )).get()
        XCTAssertEqual(p.env["C11_AGENT_TYPE"], "codex")
        XCTAssertEqual(p.env["CMUX_AGENT_TYPE"], "codex")
        XCTAssertEqual(p.env["C11_AGENT_MODEL"], "gpt-5.2")
        XCTAssertEqual(p.env["CMUX_AGENT_MODEL"], "gpt-5.2")
        XCTAssertEqual(p.env["C11_AGENT_TASK"], "sekhem-42")
        XCTAssertEqual(p.env["CMUX_AGENT_TASK"], "sekhem-42")
    }

    func testCallerExtraEnvWinsOverOperatorEnv() throws {
        let cfg = userDefault(.claudeCode, env: "FOO=operator\nBAR=kept")
        let p = try plan(
            AgentLaunchRequest(kind: "claude-code", extraEnv: ["FOO": "caller"]),
            userDefault: cfg
        ).get()
        XCTAssertEqual(p.env["FOO"], "caller")
        XCTAssertEqual(p.env["BAR"], "kept")
    }

    // MARK: custom kinds

    func testCustomKindUsesUserTemplate() throws {
        let template = UserAgentLaunchTemplate(
            command: "aider --yes-always",
            modelFlag: "--model",
            effortFlag: nil,
            effortValues: nil,
            promptDelivery: "post-boot",
            env: ["AIDER_ANALYTICS": "false"]
        )
        let p = try plan(
            AgentLaunchRequest(kind: "aider", model: "gpt-5.2", prompt: "fix it"),
            userTemplate: template
        ).get()
        XCTAssertEqual(p.launchLine, "aider --yes-always --model gpt-5.2")
        XCTAssertEqual(p.delayedPrompt, "fix it")
        XCTAssertEqual(p.env["AIDER_ANALYTICS"], "false")
        XCTAssertEqual(p.env["C11_AGENT_TYPE"], "aider")
        XCTAssertNil(p.agentType)
    }

    func testCustomKindPromptFlagDelivery() throws {
        let template = UserAgentLaunchTemplate(
            command: "someagent",
            modelFlag: nil,
            effortFlag: nil,
            effortValues: nil,
            promptDelivery: "--prompt",
            env: nil
        )
        let p = try plan(
            AgentLaunchRequest(kind: "someagent", prompt: "go"),
            userTemplate: template
        ).get()
        XCTAssertEqual(p.launchLine, "someagent --prompt 'go'")
        XCTAssertNil(p.delayedPrompt)
    }

    func testUserTemplateKindValidation() {
        XCTAssertTrue(UserAgentLaunchTemplate.isValidKind("my-agent-2"))
        XCTAssertFalse(UserAgentLaunchTemplate.isValidKind("My-Agent"))
        XCTAssertFalse(UserAgentLaunchTemplate.isValidKind("-bad"))
        XCTAssertFalse(UserAgentLaunchTemplate.isValidKind(""))
        XCTAssertFalse(UserAgentLaunchTemplate.isValidKind(String(repeating: "a", count: 33)))
    }

    // MARK: system-prompt axis

    func testPlannerSystemPromptAppendRenders() throws {
        // The factory pins claude-code to --model opus; the system-prompt flag
        // renders after it.
        let p = try plan(AgentLaunchRequest(
            kind: "claude-code",
            systemPrompt: SystemPromptSetting(mode: .append, text: "be terse")
        )).get()
        XCTAssertEqual(
            p.launchLine,
            "claude --dangerously-skip-permissions --model opus --append-system-prompt 'be terse'"
        )
    }

    func testPlannerSystemPromptReplaceBlankSlate() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "claude-code",
            systemPrompt: SystemPromptSetting(mode: .replace, text: "")
        )).get()
        XCTAssertEqual(p.launchLine, "claude --dangerously-skip-permissions --model opus --system-prompt ''")
    }

    func testPlannerSystemPromptRidesAfterModelEffortBeforePrompt() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "claude-code", model: "opus", effort: "high", prompt: "do it",
            systemPrompt: SystemPromptSetting(mode: .append, text: "hi")
        )).get()
        XCTAssertEqual(
            p.launchLine,
            "claude --dangerously-skip-permissions --model opus --effort high --append-system-prompt 'hi' 'do it'"
        )
    }

    func testPlannerSystemPromptInheritInjectsNothing() throws {
        let p = try plan(AgentLaunchRequest(
            kind: "claude-code",
            systemPrompt: SystemPromptSetting(mode: .inherit, text: "ignored")
        )).get()
        // inherit adds no system-prompt flag; the factory model pin still rides.
        XCTAssertEqual(p.launchLine, "claude --dangerously-skip-permissions --model opus")
    }

    func testPlannerSystemPromptUnsupportedFails() {
        guard case .failure(let err) = plan(AgentLaunchRequest(
            kind: "grok",
            systemPrompt: SystemPromptSetting(mode: .replace, text: "x")
        )) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err.code, "system_prompt_unsupported")
    }

    func testPlannerSystemPromptInheritOnAxislessHarnessSucceeds() throws {
        // An explicit inherit is a no-op even on a harness with no axis — only a
        // non-inherit request errors.
        let p = try plan(AgentLaunchRequest(
            kind: "grok",
            systemPrompt: SystemPromptSetting(mode: .inherit, text: "")
        )).get()
        XCTAssertEqual(p.launchLine, "grok --always-approve")
    }

    func testPlannerRequestSystemPromptBeatsPinnedBase() throws {
        var cfg = DefaultAgentConfig.factory
        cfg.agents[.claudeCode] = AgentConfig(
            command: "claude --dangerously-skip-permissions", initialPrompt: "",
            envOverridesText: "",
            systemPrompt: SystemPromptSetting(mode: .append, text: "pinned")
        )
        let p = try plan(
            AgentLaunchRequest(
                kind: "claude-code",
                systemPrompt: SystemPromptSetting(mode: .replace, text: "requested")
            ),
            userDefault: cfg
        ).get()
        XCTAssertEqual(
            p.launchLine,
            "claude --dangerously-skip-permissions --system-prompt 'requested'"
        )
    }

    func testPlannerPinnedSystemPromptAppliesWhenRequestOmits() throws {
        var cfg = DefaultAgentConfig.factory
        cfg.agents[.claudeCode] = AgentConfig(
            command: "claude --dangerously-skip-permissions", initialPrompt: "",
            envOverridesText: "",
            systemPrompt: SystemPromptSetting(mode: .append, text: "pinned")
        )
        let p = try plan(AgentLaunchRequest(kind: "claude-code"), userDefault: cfg).get()
        XCTAssertEqual(
            p.launchLine,
            "claude --dangerously-skip-permissions --append-system-prompt 'pinned'"
        )
    }

    func testPlannerHardcodedSystemPromptWinsWithWarning() throws {
        var cfg = DefaultAgentConfig.factory
        cfg.agents[.claudeCode] = AgentConfig(
            command: "claude --dangerously-skip-permissions --system-prompt 'mine'",
            initialPrompt: "", envOverridesText: ""
        )
        let p = try plan(
            AgentLaunchRequest(
                kind: "claude-code",
                systemPrompt: SystemPromptSetting(mode: .append, text: "extra")
            ),
            userDefault: cfg
        ).get()
        XCTAssertFalse(p.launchLine.contains("extra"))
        XCTAssertEqual(p.launchLine, "claude --dangerously-skip-permissions --system-prompt 'mine'")
        XCTAssertEqual(p.warnings.count, 1)
    }

    func testPlannerCustomKindRejectsSystemPrompt() {
        // Custom kinds have no system-prompt axis in v1 → a non-inherit request
        // errors rather than silently dropping.
        let template = UserAgentLaunchTemplate(
            command: "aider --yes-always", modelFlag: "--model", effortFlag: nil,
            effortValues: nil, promptDelivery: "post-boot", env: nil
        )
        guard case .failure(let err) = plan(
            AgentLaunchRequest(
                kind: "aider",
                systemPrompt: SystemPromptSetting(mode: .replace, text: "x")
            ),
            userTemplate: template
        ) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err.code, "system_prompt_unsupported")
    }

    // MARK: quoting

    func testShellQuoteIfNeededBareForSafeValues() {
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded("opus"), "opus")
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded("gpt-5.2"), "gpt-5.2")
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded("a/b:c,d@e+f=g%h"), "a/b:c,d@e+f=g%h")
    }

    func testShellQuoteIfNeededQuotesShellSignificantValues() {
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded("a b"), "'a b'")
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded("x;rm -rf"), "'x;rm -rf'")
        XCTAssertEqual(DefaultAgentResolver.shellQuoteIfNeeded(""), "''")
    }
}
