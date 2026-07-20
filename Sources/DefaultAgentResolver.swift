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
        var result = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if let flag = modelFlag(agent: agent, config: config, command: result) {
            result += " \(flag)"
        }
        if let flag = effortFlag(agent: agent, config: config, command: result) {
            result += " \(flag)"
        }
        return result
    }

    /// Whether c11 injects a model flag for this agent kind — driven by the
    /// kind's launch template (`AgentManifest.launch.modelArg`), so an agent
    /// opts in by declaring its flag syntax as data, not by editing call sites.
    static func supportsModelFlag(_ agent: AgentType) -> Bool {
        AgentRegistry.shared.manifest(for: agent)?.launch.modelArg != nil
    }

    /// The model flag to append for a launch (rendered per the kind's launch
    /// template), or `nil` when none should be injected: the agent's template
    /// declares no model syntax, no model is pinned, or the operator already
    /// put a model in the command themselves (their explicit choice wins, and
    /// we must not pass the flag twice). Visible for testing.
    static func modelFlag(agent: AgentType, config: AgentConfig, command: String) -> String? {
        guard let arg = AgentRegistry.shared.manifest(for: agent)?.launch.modelArg else { return nil }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        guard !command.lowercased().contains(arg.detectToken) else { return nil }
        return arg.render(model)
    }

    /// Whether c11 injects an effort flag for this agent kind — like
    /// `supportsModelFlag`, driven by the kind's launch template.
    static func supportsEffortFlag(_ agent: AgentType) -> Bool {
        AgentRegistry.shared.manifest(for: agent)?.launch.effortArg != nil
    }

    /// The effort flag to append for a launch (rendered per the kind's launch
    /// template — `--effort` for claude, `-c model_reasoning_effort=` for
    /// codex, `--thinking` for pi/omp), or `nil` when none should be injected.
    /// Visible for testing.
    static func effortFlag(agent: AgentType, config: AgentConfig, command: String) -> String? {
        guard let arg = AgentRegistry.shared.manifest(for: agent)?.launch.effortArg else { return nil }
        let effort = config.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effort.isEmpty else { return nil }
        guard !command.lowercased().contains(arg.detectToken) else { return nil }
        return arg.render(effort)
    }

    /// Single-quote a value for /bin/sh, escaping embedded single quotes via
    /// the standard `'\''` close-reopen trick. Visible for testing.
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Quote only when the value needs it, so the common flag values stay
    /// byte-identical to their historical bare form (`--model opus`) while
    /// anything with shell-significant characters is safely single-quoted.
    static func shellQuoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-", "/", ":", ",", "@", "+", "=", "%":
                return true
            default:
                return false
            }
        }
        return safe ? value : shellQuote(value)
    }
}

// MARK: - launch-agent planning

/// The caller's request for `agent.launch` / `c11 launch-agent`, normalized.
/// The tab title is not part of this request — it never influences command
/// composition, so the handler threads it straight to the metadata stamp.
struct AgentLaunchRequest: Equatable {
    var kind: String
    var model: String?
    var effort: String?
    var task: String?
    var prompt: String?
    var extraEnv: [String: String] = [:]
}

/// Structured planning failures — each maps 1:1 onto a wire error code so the
/// CLI/socket surface stays machine-readable (docs/launch-agent-reference.md).
enum AgentLaunchPlanError: Error, Equatable {
    case unknownAgentType(String)
    case emptyCommand(String)
    case modelFlagUnsupported(String)
    case effortFlagUnsupported(String)
    case invalidEffort(value: String, allowed: [String])

    var code: String {
        switch self {
        case .unknownAgentType: return "unknown_agent_type"
        case .emptyCommand: return "empty_command"
        case .modelFlagUnsupported: return "model_flag_unsupported"
        case .effortFlagUnsupported: return "effort_flag_unsupported"
        case .invalidEffort: return "invalid_effort"
        }
    }

    var message: String {
        switch self {
        case .unknownAgentType(let kind):
            let builtIn = AgentType.allCases.map(\.rawValue).joined(separator: ", ")
            return "unknown agent type '\(kind)' — built-in types: \(builtIn); custom kinds need \(UserAgentLaunchTemplate.templateURL(kind: kind).path)"
        case .emptyCommand(let kind):
            return "agent '\(kind)' resolved to an empty launch command (configure it in Settings → Agents & Automation)"
        case .modelFlagUnsupported(let kind):
            return "agent '\(kind)' declares no model-flag syntax; --model is not supported for it"
        case .effortFlagUnsupported(let kind):
            return "agent '\(kind)' declares no effort-flag syntax; --effort is not supported for it"
        case .invalidEffort(let value, let allowed):
            return "invalid effort '\(value)' — allowed: \(allowed.joined(separator: ", "))"
        }
    }
}

/// A fully composed launch: the line to type, the env to spawn with, the
/// identity to stamp, and any prompt that must follow post-boot.
struct AgentLaunchPlan: Equatable {
    let kind: String
    /// `nil` for custom kebab kinds that only exist as a user template.
    let agentType: AgentType?
    /// The full line typed into the new PTY (launcher + flags [+ prompt]).
    let launchLine: String
    /// Non-nil when the kind's template delivers prompts post-boot.
    let delayedPrompt: String?
    /// Spawn environment: operator env overrides, then the launch identity
    /// (`C11_AGENT_TYPE/MODEL/TASK` + `CMUX_*` aliases), then caller extras.
    let env: [String: String]
    /// The resolved model pin ("" = inherit the agent's ambient default).
    let model: String
    let effort: String
    let warnings: [String]
}

/// Pure composer for `agent.launch`. No I/O — callers pass the merged configs
/// and (for custom kinds) the pre-loaded user template, so the whole planning
/// path is exercisable from `c11LogicTests`.
enum AgentLaunchPlanner {

    static func plan(
        request: AgentLaunchRequest,
        userDefault: DefaultAgentConfig,
        projectConfig: DefaultAgentConfig?,
        userTemplate: UserAgentLaunchTemplate?
    ) -> Result<AgentLaunchPlan, AgentLaunchPlanError> {
        let kind = request.kind.trimmingCharacters(in: .whitespacesAndNewlines)

        let agentType = AgentType(rawValue: kind)
        let template: AgentLaunchTemplate
        let baseCommand: String
        let baseEnv: [String: String]
        let pinnedModel: String
        let pinnedEffort: String

        if let agentType {
            guard let manifest = AgentRegistry.shared.manifest(for: agentType) else {
                return .failure(.unknownAgentType(kind))
            }
            // Same per-agent config pick as the A button: project entry beats
            // user Settings, factory fills the gaps.
            let config = projectConfig?.agents[agentType] ?? userDefault.config(for: agentType)
            template = manifest.launch
            baseCommand = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
            baseEnv = config.envMap
            pinnedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            pinnedEffort = config.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let userTemplate {
            template = userTemplate.template
            baseCommand = userTemplate.command.trimmingCharacters(in: .whitespacesAndNewlines)
            baseEnv = userTemplate.env ?? [:]
            pinnedModel = ""
            pinnedEffort = ""
        } else {
            return .failure(.unknownAgentType(kind))
        }

        guard !baseCommand.isEmpty else {
            return .failure(.emptyCommand(kind))
        }

        var warnings: [String] = []
        var line = baseCommand

        // Model: an operator-hardcoded flag in the command always wins; then
        // the caller's --model; then the Settings/project pin; then nothing.
        let requestedModel = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedModel, !requestedModel.isEmpty, template.modelArg == nil {
            return .failure(.modelFlagUnsupported(kind))
        }
        var resolvedModel = ""
        if let arg = template.modelArg {
            let hardcoded = baseCommand.lowercased().contains(arg.detectToken)
            let value = (requestedModel?.isEmpty == false) ? requestedModel! : pinnedModel
            if hardcoded {
                if requestedModel?.isEmpty == false {
                    warnings.append("configured command already pins a model; --model \(requestedModel!) ignored")
                }
            } else if !value.isEmpty {
                line += " \(arg.render(value))"
                resolvedModel = value
            }
        }

        // Effort: same precedence ladder as model.
        let requestedEffort = request.effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedEffort, !requestedEffort.isEmpty, template.effortArg == nil {
            return .failure(.effortFlagUnsupported(kind))
        }
        var resolvedEffort = ""
        if let arg = template.effortArg {
            let hardcoded = baseCommand.lowercased().contains(arg.detectToken)
            let value = (requestedEffort?.isEmpty == false) ? requestedEffort! : pinnedEffort
            if hardcoded {
                if requestedEffort?.isEmpty == false {
                    warnings.append("configured command already pins an effort; --effort \(requestedEffort!) ignored")
                }
            } else if !value.isEmpty {
                if !template.effortValues.isEmpty, !template.effortValues.contains(value) {
                    return .failure(.invalidEffort(value: value, allowed: template.effortValues))
                }
                line += " \(arg.render(value))"
                resolvedEffort = value
            }
        }

        // Prompt: one-shot argv where the template supports it; post-boot send
        // otherwise.
        var delayedPrompt: String?
        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt, !prompt.isEmpty {
            switch template.promptDelivery {
            case .positional:
                line += " \(DefaultAgentResolver.shellQuote(prompt))"
            case .flag(let flagName):
                line += " \(flagName) \(DefaultAgentResolver.shellQuote(prompt))"
            case .postBoot:
                delayedPrompt = prompt
            }
        }

        // Spawn env: operator/template env first, then the launch identity,
        // then caller extras (caller wins on collision). Both C11_* and the
        // legacy CMUX_* names are set — the PATH-shim wrappers read CMUX_*.
        var env = baseEnv
        var identity: [String: String] = [
            "C11_AGENT_TYPE": kind,
            "CMUX_AGENT_TYPE": kind
        ]
        if !resolvedModel.isEmpty {
            identity["C11_AGENT_MODEL"] = resolvedModel
            identity["CMUX_AGENT_MODEL"] = resolvedModel
        }
        if let task = request.task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            identity["C11_AGENT_TASK"] = task
            identity["CMUX_AGENT_TASK"] = task
        }
        env.merge(identity) { _, new in new }
        env.merge(request.extraEnv) { _, new in new }

        return .success(AgentLaunchPlan(
            kind: kind,
            agentType: agentType,
            launchLine: line,
            delayedPrompt: delayedPrompt,
            env: env,
            model: resolvedModel,
            effort: resolvedEffort,
            warnings: warnings
        ))
    }
}
