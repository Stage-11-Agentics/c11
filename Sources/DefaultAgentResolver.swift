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

    // MARK: - Saved-config overlay (C11-179, design §1.3)

    /// Resolve a launch from a saved-config **overlay** (`AgentConfigLibraryStore`)
    /// layered over the harness Settings base. This is what the A-button
    /// left-click launches (`effectiveDefault()`); the `resolve(explicitAgent:…)`
    /// path above stays the raw-harness launcher used by the right-click "launch
    /// this kind" affordance and the CLI.
    ///
    /// The overlay is applied by **flattening it onto the harness-base
    /// `AgentConfig`** and then reusing `buildCommand`/`launcherCommand`
    /// unchanged — so a pure-inherit overlay (every field `nil`) yields a merged
    /// config identical to the base, hence a launch command byte-identical to
    /// today's (the regression AC), and the existing per-field flag injection
    /// (model/effort/system-prompt, with hardcoded-in-command detection) applies
    /// to the overlaid values for free.
    ///
    /// Returns `nil` when the saved config's `harness` is not a built-in
    /// `AgentType` (a custom kebab kind); the caller falls back to the
    /// raw-harness `resolve` path (graceful degradation, design §5.6). The
    /// returned `mergedConfig` exposes the overlay-resolved model/effort/
    /// system-prompt scalars so the caller can stamp identity and record stats
    /// without re-deriving them.
    ///
    /// - Important: the overlay-merged env lives ONLY in the returned
    ///   `ResolvedAgentLaunch.envOverrides`; `mergedConfig.envMap` reflects the
    ///   base env, NOT the overlay merge (see `mergeOverlay`). No caller may read
    ///   `mergedConfig.envMap` for the resolved env.
    static func resolveOverlay(
        savedConfig: SavedAgentConfig,
        userDefault: DefaultAgentConfig,
        projectConfig: DefaultAgentConfig?
    ) -> (agent: AgentType, mergedConfig: AgentConfig, launch: ResolvedAgentLaunch)? {
        guard let agent = AgentType(rawValue: savedConfig.config.harness) else { return nil }
        // Same per-agent base pick as `resolve` / the A button: project entry
        // beats user Settings, factory fills the gaps. This base already equals
        // `factory ◁ settings` (factory env is always empty).
        let base = projectConfig?.agents[agent] ?? userDefault.config(for: agent)
        let (merged, env) = mergeOverlay(savedConfig.config, onto: base)
        let command = buildCommand(agent: agent, config: merged)
        let bare = launcherCommand(agent: agent, config: merged)
        return (agent, merged, ResolvedAgentLaunch(
            command: command,
            bareCommand: bare,
            initialPrompt: merged.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            envOverrides: env
        ))
    }

    /// Flatten a saved-config overlay onto a harness-base `AgentConfig` (design
    /// §1.3 ladder), overlay winning per field; an unset (`nil`) overlay field
    /// inherits the base. Pure — no store/AppKit dependency — so the ladder is
    /// unit-locked field-by-field.
    ///
    /// Env is returned as a **separate merged dict** (`base.envMap` then
    /// `overlay.env` per key, overlay wins → `factory ◁ settings ◁ config`, since
    /// the base already folds factory under settings and factory env is empty).
    /// It is deliberately NOT written back into the merged config's
    /// `envOverridesText` — round-tripping a dict through that line-oriented text
    /// is lossy — so `mergedConfig.envMap` is base-only and must not be read for
    /// the resolved env. The resolved env is the second tuple element.
    static func mergeOverlay(
        _ overlay: AgentLaunchConfig,
        onto base: AgentConfig
    ) -> (config: AgentConfig, env: [String: String]) {
        var env = base.envMap
        if let overlayEnv = overlay.env {
            for (key, value) in overlayEnv { env[key] = value }
        }
        let merged = AgentConfig(
            command: overlay.command ?? base.command,
            initialPrompt: overlay.initialPrompt ?? base.initialPrompt,
            // Base env text is carried verbatim; the resolved env is the dict
            // above, NOT this text (see doc comment). Do not read merged.envMap.
            envOverridesText: base.envOverridesText,
            model: overlay.model ?? base.model,
            effort: overlay.effort ?? base.effort,
            systemPrompt: overlay.systemPrompt ?? base.systemPrompt
        )
        return (merged, env)
    }

    /// The at-a-glance tooltip string for the A button (design §5.3 v1): the
    /// resolved default config's `name · model · effort`, empty segments
    /// omitted. Pure — visible for testing. `model`/`effort` are the
    /// overlay-resolved values (what actually launches); `model` is mapped to
    /// its Claude family display name when it matches, else shown verbatim.
    static func formatAgentTooltip(name: String, model: String, effort: String) -> String {
        let modelLabel = ClaudeModelFamily(rawValue: model)?.displayName ?? model
        let segments = [name, modelLabel, effort]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let detail = segments.joined(separator: " · ")
        let template = String(
            localized: "workspace.tooltip.newAgent.resolved",
            defaultValue: "Launch Agent — %@"
        )
        return String(format: template, locale: Locale.current, detail)
    }

    /// Resolve the A-button tooltip from the saved-config library: read
    /// `effectiveDefault()`, resolve its overlay for the display model/effort,
    /// and format. Falls back to the config's own name/harness when the harness
    /// is a custom kind the overlay resolver can't materialize. Project config is
    /// intentionally not consulted here — the tooltip is a workspace-agnostic
    /// at-a-glance hint, and the library (name) is user-global; a project
    /// override to the harness base affects the launch, not this hint (v1).
    static func resolvedDefaultTooltip(
        library: AgentConfigLibraryStore = .shared,
        userDefault: DefaultAgentConfig
    ) -> String {
        let saved = library.effectiveDefault()
        if let resolved = resolveOverlay(savedConfig: saved, userDefault: userDefault, projectConfig: nil) {
            return formatAgentTooltip(
                name: saved.name,
                model: resolved.mergedConfig.model,
                effort: resolved.mergedConfig.effort
            )
        }
        // Custom/unknown harness: show the saved axes directly.
        return formatAgentTooltip(
            name: saved.name,
            model: saved.config.model ?? "",
            effort: saved.config.effort ?? ""
        )
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
        // System-prompt flag rides after model/effort but before claude-code's
        // positional prompt (baked later in buildCommand), matching the launch
        // line the planner composes.
        if let flag = systemPromptFlag(agent: agent, config: config, command: result) {
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

    /// Whether c11 injects a system-prompt flag for this agent kind — driven by
    /// the kind's launch template (`AgentManifest.launch.systemPromptArg`), the
    /// same data-gated shape as `supportsModelFlag`/`supportsEffortFlag`.
    static func supportsSystemPromptFlag(_ agent: AgentType) -> Bool {
        AgentRegistry.shared.manifest(for: agent)?.launch.systemPromptArg != nil
    }

    /// The system-prompt flag to append for a launch, or `nil` when none should
    /// be injected: the agent declares no system-prompt syntax, the setting is
    /// `nil`/`.inherit`, the CLI has no flag for the requested mode, or the
    /// operator already put a system-prompt flag in the command (their choice
    /// wins, and we must not pass one on top). `replace` with empty text still
    /// emits the flag with an empty value — the intentional blank-slate launch.
    /// Visible for testing.
    static func systemPromptFlag(agent: AgentType, config: AgentConfig, command: String) -> String? {
        renderSystemPromptFlag(
            AgentRegistry.shared.manifest(for: agent)?.launch.systemPromptArg,
            setting: config.systemPrompt,
            command: command
        )
    }

    /// Template-based core of system-prompt injection, shared by the resolver
    /// (`AgentType`-keyed) and the planner (`AgentLaunchTemplate`-keyed, so it
    /// serves custom kebab kinds too). Pure; visible for testing.
    static func renderSystemPromptFlag(
        _ arg: AgentSystemPromptArg?,
        setting: SystemPromptSetting?,
        command: String
    ) -> String? {
        guard let arg,
              let setting,
              setting.mode != .inherit,
              let flag = arg.flag(for: setting.mode) else { return nil }
        // An operator who hardcoded *either* system-prompt flag owns the axis —
        // c11 injects nothing on top (mirrors model/effort hardcoded detection).
        let lower = command.lowercased()
        if arg.detectTokens.contains(where: { lower.contains($0.lowercased()) }) { return nil }
        // System-prompt text is free-form prose, so it is always single-quoted —
        // the same treatment as the positional initial prompt (`shellQuote`),
        // not the constrained-flag-value `shellQuoteIfNeeded`. `.replace` + ""
        // therefore renders `--system-prompt ''`, the intended blank slate.
        return "\(flag) \(shellQuote(setting.text))"
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
    /// The caller's system-prompt choice (`--system-prompt-mode` + text on
    /// `launch-agent`), or `nil` to fall back to the pinned Settings base (which
    /// is itself `nil`/inherit by default). A non-inherit mode on a kind whose
    /// template declares no system-prompt axis fails `system_prompt_unsupported`,
    /// mirroring `--model`/`--effort` on an unsupported kind.
    var systemPrompt: SystemPromptSetting?
    var extraEnv: [String: String] = [:]
    /// Full launch-command override (C11-180 `config launch`, design §1.3
    /// advanced tier). When non-empty it replaces the harness Settings base
    /// command as the line flags inject onto — so a saved config's `command`
    /// recipe field is honored while model/effort/system-prompt flag injection
    /// and hardcoded-detection still run over it. `nil`/empty = inherit the
    /// harness base (byte-identical to today). The A-button overlay path reaches
    /// the equivalent merge via `mergeOverlay`; this is its planner-path twin so
    /// `config launch` stays a thin client over `AgentLaunchPlanner`.
    var commandOverride: String? = nil
}

/// Structured planning failures — each maps 1:1 onto a wire error code so the
/// CLI/socket surface stays machine-readable (docs/launch-agent-reference.md).
enum AgentLaunchPlanError: Error, Equatable {
    case unknownAgentType(String)
    case emptyCommand(String)
    case modelFlagUnsupported(String)
    case effortFlagUnsupported(String)
    case systemPromptUnsupported(String)
    case invalidEffort(value: String, allowed: [String])

    var code: String {
        switch self {
        case .unknownAgentType: return "unknown_agent_type"
        case .emptyCommand: return "empty_command"
        case .modelFlagUnsupported: return "model_flag_unsupported"
        case .effortFlagUnsupported: return "effort_flag_unsupported"
        case .systemPromptUnsupported: return "system_prompt_unsupported"
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
        case .systemPromptUnsupported(let kind):
            return "agent '\(kind)' declares no system-prompt-flag syntax; --system-prompt-mode is not supported for it"
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
        var baseCommand: String
        let baseEnv: [String: String]
        let pinnedModel: String
        let pinnedEffort: String
        let pinnedSystemPrompt: SystemPromptSetting?

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
            pinnedSystemPrompt = config.systemPrompt
        } else if let userTemplate {
            template = userTemplate.template
            baseCommand = userTemplate.command.trimmingCharacters(in: .whitespacesAndNewlines)
            baseEnv = userTemplate.env ?? [:]
            pinnedModel = ""
            pinnedEffort = ""
            pinnedSystemPrompt = nil
        } else {
            return .failure(.unknownAgentType(kind))
        }

        // C11-180: a saved config's full-command override (`config launch`)
        // replaces the harness base before flag injection / hardcoded-detection,
        // so model/effort/system-prompt still compose over the overridden line.
        if let override = request.commandOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            baseCommand = override
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

        // System prompt: same precedence + hardcoded-wins ladder as model/effort.
        // A caller-requested non-inherit mode on a kind with no system-prompt
        // axis errors (parity with --model/--effort); a silent pinned base on
        // such a kind never errors. The flag rides after model/effort, before
        // the positional prompt below.
        let requestedSystemPrompt = request.systemPrompt
        if let requested = requestedSystemPrompt, requested.mode != .inherit, template.systemPromptArg == nil {
            return .failure(.systemPromptUnsupported(kind))
        }
        if let arg = template.systemPromptArg {
            let hardcoded = arg.detectTokens.contains { baseCommand.lowercased().contains($0.lowercased()) }
            if hardcoded {
                if let requested = requestedSystemPrompt, requested.mode != .inherit {
                    warnings.append("configured command already pins a system prompt; --system-prompt-mode \(requested.mode.rawValue) ignored")
                }
            } else if let flag = DefaultAgentResolver.renderSystemPromptFlag(
                arg, setting: requestedSystemPrompt ?? pinnedSystemPrompt, command: baseCommand
            ) {
                line += " \(flag)"
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
