import Foundation

/// The fully-resolved decision for launching an agent into a terminal panel.
/// `command` is what gets typed into the shell once the panel is ready;
/// `initialPrompt` (if non-empty) is delivered after launch via a second
/// `sendText`; `envOverrides` are passed at panel construction.
struct ResolvedAgentLaunch: Equatable {
    let command: String
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
        let agent = explicitAgent
            ?? projectConfig?.defaultAgent
            ?? userDefault.defaultAgent

        // Project-level per-agent config beats user-level for the chosen agent.
        let chosenConfig: AgentConfig =
            projectConfig?.agents[agent]
            ?? userDefault.config(for: agent)

        let command = buildCommand(agent: agent, config: chosenConfig)
        return (agent, ResolvedAgentLaunch(
            command: command,
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
        let base = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        if agent == .claudeCode {
            let prompt = config.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                return "\(base) \(shellQuote(prompt))"
            }
        }
        return base
    }

    /// Single-quote a value for /bin/sh, escaping embedded single quotes via
    /// the standard `'\''` close-reopen trick. Visible for testing.
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
