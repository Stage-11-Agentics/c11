import Foundation

/// The fully-resolved decision for launching an agent into a terminal panel.
/// `command` is what gets typed into the shell once the panel is ready;
/// `bareCommand` is the same launcher with no initial-prompt baking, suitable
/// for export as `C11_DEFAULT_AGENT_LAUNCH` so callers can append their own
/// prompts without colliding with the operator's configured seed;
/// `initialPrompt` (if non-empty) is delivered after launch via a second
/// `sendText`; `envOverrides` are passed at panel construction.
struct ResolvedAgentLaunch: Equatable {
    let command: String
    let bareCommand: String
    let initialPrompt: String
    let envOverrides: [String: String]
}

/// Pure resolver. No I/O; callers pass in the merged user default + project
/// config and the resolver picks the right per-agent entry, then materializes
/// the launch command (with optional positional-arg prompt for claude-code).
enum DefaultAgentResolver {

    /// Resolve the launch shape for a specific agent. Project config (if any)
    /// wins over user default for that agent's entry; the chosen `defaultAgent`
    /// at the project level wins over the user-level pick when nothing is
    /// passed explicitly.
    ///
    /// `explicitAgent` is the override knob used by the A-button right-click
    /// menu and the socket CLI: pass `nil` to honor the configured default,
    /// or a specific type to launch that one.
    static func resolve(
        explicitAgent: AgentType?,
        userDefault: DefaultAgentConfig,
        projectConfig: DefaultAgentConfig?
    ) -> (agent: AgentType, launch: ResolvedAgentLaunch) {
        // A project config only overrides the agent selection when it actually
        // states a `defaultAgent`; a file that omits the key (or a legacy file
        // that no longer decodes) must not displace the user's Settings pick.
        let projectDefault: AgentType? = projectConfig?.overrideDefaultAgent ?? nil
        let agent = explicitAgent
            ?? projectDefault
            ?? userDefault.defaultAgent

        // Project-level per-agent config beats user-level for the chosen agent.
        let chosenConfig: AgentConfig =
            projectConfig?.agents[agent]
            ?? userDefault.config(for: agent)

        let command = buildCommand(agent: agent, config: chosenConfig)
        let bare = launcherCommand(agent: agent, config: chosenConfig)
        return (agent, ResolvedAgentLaunch(
            command: command,
            bareCommand: bare,
            initialPrompt: chosenConfig.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            envOverrides: chosenConfig.envMap
        ))
    }

    /// Build the shell command line for an agent's config. For claude-code, an
    /// initial prompt is appended as a single-quoted positional argument
    /// (claude accepts that). For other agents the prompt is delivered via a
    /// separate post-launch sendText so each TUI's input contract is honored.
    /// Visible for testing.
    static func buildCommand(agent: AgentType, config: AgentConfig) -> String {
        let launcher = launcherCommand(agent: agent, config: config)
        guard !launcher.isEmpty else { return "" }
        if agent == .claudeCode {
            let prompt = config.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                return "\(launcher) \(shellQuote(prompt))"
            }
        }
        return launcher
    }

    /// The launcher: the operator's `command` with the pinned model flag
    /// applied, but no positional prompt baked in. This is what feeds
    /// `bareCommand` / the `C11_DEFAULT_AGENT_LAUNCH` export, so an orchestrator
    /// that composes its own prompt still inherits the pinned model. The
    /// model flag must precede claude-code's positional prompt (which stays
    /// last), so it's applied here rather than after prompt-baking.
    /// Visible for testing.
    static func launcherCommand(agent: AgentType, config: AgentConfig) -> String {
        let base = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        if let flag = modelFlag(agent: agent, config: config, command: base) {
            return "\(base) \(flag)"
        }
        return base
    }

    /// Whether c11 injects a `--model` flag for this agent kind. Only agents
    /// whose CLI accepts `--model <family-alias>` qualify; today that's Claude
    /// Code. Kept as a seam so codex (also `--model`) can opt in later.
    static func supportsModelFlag(_ agent: AgentType) -> Bool {
        agent == .claudeCode
    }

    /// The `--model <family>` flag to append for a launch, or `nil` when none
    /// should be injected: the agent doesn't support it, no family is pinned,
    /// or the operator already put a model in the command themselves (their
    /// explicit choice wins, and we must not pass `--model` twice).
    /// Visible for testing.
    static func modelFlag(agent: AgentType, config: AgentConfig, command: String) -> String? {
        guard supportsModelFlag(agent) else { return nil }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        guard !command.lowercased().contains("--model") else { return nil }
        return "--model \(model)"
    }

    /// Single-quote a value for /bin/sh, escaping embedded single quotes via
    /// the standard `'\''` close-reopen trick. Visible for testing.
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
