import Foundation

/// Single source of truth for one terminal coding agent c11 knows how to host.
///
/// Today (Phase 0) the manifest is **additive**: it carries the per-agent facts
/// that are currently re-declared across `DefaultAgentConfig`, `AgentDetector`,
/// `AgentChip`, `AgentRestartRegistry`, `SurfaceMetadataStore`, and the
/// conversation `StrategyRegistry`. The existing switches still drive behavior;
/// `AgentManifestTests` golden-locks each manifest field against those switches
/// so a later phase can delete a switch and read the manifest with zero
/// behavior change. See `docs/agent-registry-design.md`.
///
/// The manifest grows fields as each consumer is migrated (config roots,
/// reserved metadata keys, capture rails, runtime TOML decoding). It is kept
/// deliberately small in Phase 0 — only the facts the golden tests can pin
/// against an existing source of truth belong here yet.
struct AgentManifest: Sendable, Equatable, Identifiable {
    /// Canonical kind string. For launchable agents this equals
    /// `AgentType.rawValue` and the sidebar `terminal_type` (`"claude-code"`,
    /// `"opencode"`, …). The one string every subsystem keys on.
    let kind: String

    /// Bridge to the compile-time enum. Phase 0 keeps `AgentType`; a later
    /// phase may replace enum usages with registry-validated `kind` strings
    /// (design §11 Q2 — phased, enum-first).
    let agentType: AgentType

    /// English display label (picker, A-button tooltip, Settings subheading).
    /// Built-in agents keep their literal-key `String(localized:)` lookup in
    /// `AgentType.displayName` so xcstrings extraction still works; this field
    /// is the English source of truth and what runtime (TOML) agents use.
    let displayName: String

    /// Factory launch command (the operator-editable default).
    let factoryCommand: String

    /// Factory initial prompt typed after launch (empty for `custom`).
    let factoryInitialPrompt: String

    /// Exact `comm` names that classify a process as this agent
    /// (`AgentDetector.classify`).
    let detectComms: [String]

    /// `args` substrings that classify a node-wrapped process as this agent.
    let detectNodeArgsSubstrings: [String]

    /// Sidebar icon asset name (`"AgentIcons/<kind>"`), or `nil` for agents
    /// with no branded chip (e.g. `custom`).
    let iconAsset: String?

    /// SF Symbol shown until a real asset ships, or `nil` when unbranded.
    let sfSymbolFallback: String?

    /// How a snapshot/crash restart resumes this agent.
    let resume: ResumeSpec

    /// Launch-time composition facts (model/effort flag syntax, prompt
    /// delivery) consumed by `launch-agent` and `DefaultAgentResolver`.
    let launch: AgentLaunchTemplate

    /// Whether `kind` is a recognized `terminal_type`
    /// (`SurfaceMetadataKeys.canonicalTerminalTypes`). `custom` is not.
    let isCanonicalTerminalType: Bool

    /// Whether a `ConversationStrategy` is registered for `kind`
    /// (`ConversationStrategyRegistry.v1`).
    let hasConversationStrategy: Bool

    var id: String { kind }

    /// Reproduces the matching `AgentRestartRegistry.phase1` row for this agent.
    /// Pure; same belt-and-braces id/path re-validation as the existing rows so
    /// the synthesized string can never become a command-injection vector.
    func resumeCommand(sessionId: String?, metadata: [String: String]) -> String? {
        switch resume {
        case .none:
            return nil
        case .fixed(let command):
            return command
        case .uuidById(let command, let projectDirKey):
            guard let raw = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  isValidClaudeSessionId(raw) else { return nil }
            let resumeCmd = "\(command) \(raw)"
            if let key = projectDirKey,
               let dir = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dir.isEmpty,
               isValidClaudeSessionProjectDir(dir) {
                return "cd \(shellSingleQuote(dir)) && \(resumeCmd)\n"
            }
            return "\(resumeCmd)\n"
        }
    }
}

/// How a launch-time value (a model id, an effort tier) renders onto an
/// agent's command line. Data, not code: `launch-agent`, the resolver, and any
/// future launch surface consult this instead of growing per-agent switches.
enum AgentLaunchArgStyle: Sendable, Equatable {
    /// `.flag("--model")` → `--model <value>`.
    case flag(String)
    /// `.configKV("model_reasoning_effort")` → `-c model_reasoning_effort=<value>`
    /// (codex's config-override syntax).
    case configKV(String)

    /// Substring whose presence in the operator's configured command means the
    /// value is already hardcoded there — c11 must not inject it twice.
    var detectToken: String {
        switch self {
        case .flag(let name): return name
        case .configKV(let key): return key
        }
    }

    /// Render the argument for `value`, shell-quoting only when the value
    /// needs it so the common case stays byte-identical to the historical
    /// `--model opus` form.
    func render(_ value: String) -> String {
        let quoted = DefaultAgentResolver.shellQuoteIfNeeded(value)
        switch self {
        case .flag(let name): return "\(name) \(quoted)"
        case .configKV(let key): return "-c \(key)=\(quoted)"
        }
    }
}

// `SystemPromptSetting` (the operator's three-mode system-prompt choice) is
// defined in `AgentConfigLibraryStore.swift` — the single canonical home, a
// member of both the app and CLI targets so the config store resolves it
// without importing app-only AgentManifest. The launch/sysprompt axis
// (`AgentSystemPromptArg` below) and the config-overlay store share that one
// definition. (C11-176/C11-177 wave-1 reconciliation: both tickets landed the
// same design §1.4 primitive; the duplicate that lived here was removed.)

/// How a system-prompt override renders onto an agent's command line. Unlike
/// model/effort (one flag each), the system-prompt axis has two delivery flags —
/// append (adds to the harness default) and replace (supplants it) — so it is
/// its own arg style rather than an `AgentLaunchArgStyle`. `nil` on a template
/// means the axis is disabled for that harness (v1: only claude-code declares
/// it), the same gating pattern `effortArg == nil` uses.
struct AgentSystemPromptArg: Sendable, Equatable {
    /// Flag that appends to the harness default (claude `--append-system-prompt`),
    /// or `nil` when the CLI has no append form.
    let appendFlag: String?
    /// Flag that replaces the harness default (claude `--system-prompt`), or
    /// `nil` when the CLI has no replace form. An empty value is allowed — the
    /// blank-slate launch.
    let replaceFlag: String?

    /// The flag to render for a given mode, or `nil` when the mode is
    /// `.inherit` or the CLI has no form for it.
    func flag(for mode: SystemPromptSetting.Mode) -> String? {
        switch mode {
        case .inherit: return nil
        case .append: return appendFlag
        case .replace: return replaceFlag
        }
    }

    /// Substrings whose presence in the operator's configured command means a
    /// system prompt is already pinned there — c11 must not inject one on top.
    /// Both flags count: an operator who hardcoded either form owns the axis.
    var detectTokens: [String] {
        [appendFlag, replaceFlag].compactMap { $0 }
    }
}

/// How an initial prompt reaches the agent at launch.
enum AgentPromptDelivery: Sendable, Equatable {
    /// Appended to the launch argv as a single-quoted positional argument —
    /// one shot, no ready-state race (claude, codex, grok, pi, omp, and
    /// opencode's `run` form).
    case positional
    /// Appended as `<flag> '<prompt>'` for TUIs whose initial prompt only
    /// rides a named flag.
    case flag(String)
    /// Typed into the TUI after a fixed post-launch delay. Best-effort and
    /// racy by nature; used only for agents with no argv delivery.
    case postBoot
}

/// The per-kind launch facts `launch-agent` composes from: how model and
/// effort flags render, which effort values are legal, and how a prompt is
/// delivered. Seeded per built-in manifest; custom kinds decode the same
/// shape from `~/.config/c11/agents/<kind>.json` (`UserAgentLaunchTemplate`).
struct AgentLaunchTemplate: Sendable, Equatable {
    /// Model-flag syntax, or `nil` when the CLI has no model flag c11 knows —
    /// a `--model` request for such a kind errors instead of guessing.
    let modelArg: AgentLaunchArgStyle?
    /// Effort-flag syntax (claude `--effort`, codex reasoning-effort config
    /// key, pi/omp `--thinking`), or `nil` when the CLI has no effort axis.
    let effortArg: AgentLaunchArgStyle?
    /// Non-empty → `--effort` values are validated early with a friendly
    /// error; empty → passed through and the agent CLI enforces.
    let effortValues: [String]
    let promptDelivery: AgentPromptDelivery
    /// System-prompt flag syntax (append/replace), or `nil` when the CLI has no
    /// system-prompt axis c11 knows — a non-inherit system-prompt request for
    /// such a kind errors instead of guessing. v1 seeds this for claude-code
    /// only; every other built-in is `nil` (same gating shape as `effortArg`).
    let systemPromptArg: AgentSystemPromptArg?
}

/// The flag(s) that put an agent into its no-approval-prompt mode.
///
/// c11's contract is that an agent it launches never stops on a permission
/// prompt the operator did not ask for — and that **resuming** a session keeps
/// the same posture as launching one. Every rail that synthesizes a command
/// line for an agent (`factoryCommand` below, `ResumeSpec`, the conversation
/// strategies' `resume()`, `ResumeDecisionEngine`) composes from this one
/// table, so a resume can't silently drop the flag its launch carried.
/// `AgentAutoApproveCoverageTests` fails the build if a rail drifts.
///
/// A `nil`/absent entry means the CLI has no auto-approve-all flag c11 knows
/// of — that agent launches and resumes bare, and prompts. Adding one is a
/// one-line change here plus the manifest's `factoryCommand`.
enum AgentAutoApprove {
    /// kind → flag string, verified against each CLI's `--help` on
    /// 2026-07-27. Absent kinds have no such flag:
    /// - `pi` — `--approve` only trusts project-local *files*, not tool calls.
    /// - `custom` — the operator owns the whole command line.
    static let byKind: [String: String] = [
        "claude-code": "--dangerously-skip-permissions",
        // Hidden alias of `--dangerously-bypass-approvals-and-sandbox`;
        // accepted by the bare TUI *and* the `resume` subcommand.
        "codex": "--yolo",
        "grok": "--always-approve",
        // kimi-code has two tiers: `--yolo` / `--yes` / `-y` auto-approves tool
        // calls but still lets the agent stop to ask questions, while `--auto`
        // is the fully autonomous permission mode. c11 launches unattended
        // agents, so `--auto` is the posture (verified against
        // `kimi --help` 0.30.0, 2026-07-29).
        "kimi": "--auto",
        // The documented spelling, accepted by both the bare TUI
        // (`opencode [project]`, incl. `-s <id>`) and `opencode run`.
        "opencode": "--auto",
        "github-copilot": "--allow-all --autopilot",
        "omp": "--auto-approve",
    ]

    static func flags(forKind kind: String) -> String? { byKind[kind] }

    /// `"<command> <flags>"`, or `command` unchanged when the kind has no
    /// auto-approve flag or the command already carries it.
    static func applying(toCommand command: String, kind: String) -> String {
        guard let flags = byKind[kind], !command.contains(flags) else { return command }
        return "\(command) \(flags)"
    }
}

/// Launch commands that *earlier releases* shipped as a kind's factory default,
/// oldest first, never including the current one.
///
/// Why this has to exist: the launch rails don't compose from `factoryCommand`.
/// They compose from the operator's persisted per-agent command
/// (`DefaultAgentConfigStore`), and that entry is frozen the first time anything
/// calls `update(_:_:)` — which saves the *whole* config, so editing one agent
/// silently pickles every other agent's then-current factory command into
/// UserDefaults forever. Change a factory command after that and the operator
/// keeps launching the old line: no warning, no diff, every launch, until
/// somebody reads the plist. That is how `kimi` kept launching bare — with
/// approval prompts on — for two months after the manifest said otherwise.
///
/// A persisted command that *exactly* equals one of these strings was never a
/// deliberate choice; it is a previous release's default left behind. Those move
/// forward. Anything else — a hand-edited line, a wrapper, extra flags, a
/// different binary — is operator intent and is never touched.
///
/// **Changing a `factoryCommand` means appending the old string here, in the
/// same commit.** `AgentFactoryCommandHistoryTests` pins the current commands
/// so the change can't land unnoticed, and checks the rows stay honest (no row
/// equal to the current command, no row pointing at a different executable).
///
/// Kinds absent here have never changed their default (`claude-code`, `codex`,
/// `grok`, `github-copilot`, `pi`) or have no default to change (`custom` — the
/// operator owns the whole line). Codex and Copilot are absent *despite*
/// appearing in #384: that fix repaired the **resume** rail dropping a flag
/// their launch command already carried, and `codex --yolo` /
/// `copilot --allow-all --autopilot` have been constant since the day each was
/// introduced — verified across the full history of this file and of
/// `DefaultAgentConfig.swift`, which held the factory commands before the
/// registry existed.
enum AgentFactoryCommandHistory {
    static let byKind: [String: [String]] = [
        // Bare through 2026-07-27, then `--yolo` in v0.61.0 — which only
        // auto-approves tool calls and still stops to ask questions.
        "kimi": ["kimi", "kimi --yolo"],
        // `opencode run` is the headless subcommand (fixed in df535b35a), and
        // `--dangerously-skip-permissions` was never an opencode flag at all.
        "opencode": [
            "opencode",
            "opencode run --dangerously-skip-permissions",
            "opencode --dangerously-skip-permissions",
        ],
        // Bare through #384, which gave it `--auto-approve`.
        "omp": ["omp"],
    ]

    /// The current factory command when `command` is a stale shipped default for
    /// `kind`, otherwise `nil` (leave it alone).
    static func upgrading(_ command: String, forKind kind: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let history = byKind[kind], history.contains(trimmed),
              let current = AgentRegistry.shared.manifest(forKind: kind)?.factoryCommand,
              current != trimmed
        else { return nil }
        return current
    }
}

/// How a captured session is resumed on restart. Mirrors today's
/// `AgentRestartRegistry.phase1` rows as data.
enum ResumeSpec: Sendable, Equatable {
    /// No resume row — restart launches fresh via the normal launch path
    /// (`github-copilot`, `custom`).
    case none
    /// A fixed best-effort command, independent of session id (`codex`,
    /// `grok`, `opencode`, `kimi`). Trailing `\n` preserved to match the rows.
    case fixed(String)
    /// Resume a specific UUID session, optionally `cd`-ing into a recorded
    /// project dir first. Reproduces the `claude-code` row.
    case uuidById(command: String, projectDirKey: String?)
}

/// Immutable, kind-keyed registry of built-in agent manifests. Adding an agent
/// is one manifest here (plus, until the consumers are migrated, the existing
/// switches the golden tests pin against).
struct AgentRegistry: Sendable {
    private let byKind: [String: AgentManifest]

    /// Every built-in manifest, in `AgentType.allCases` order.
    let all: [AgentManifest]

    init(_ manifests: [AgentManifest]) {
        self.all = manifests
        var map: [String: AgentManifest] = [:]
        for m in manifests { map[m.kind] = m }
        self.byKind = map
    }

    func manifest(forKind kind: String) -> AgentManifest? { byKind[kind] }

    func manifest(for agent: AgentType) -> AgentManifest? { byKind[agent.rawValue] }

    func contains(kind: String) -> Bool { byKind[kind] != nil }

    /// The shared, app-wide registry. One manifest per `AgentType.allCases`
    /// (the coverage golden test fails if a new enum case lacks a manifest).
    static let shared = AgentRegistry([
        AgentManifest(
            kind: "claude-code",
            agentType: .claudeCode,
            displayName: "Claude Code",
            factoryCommand: "claude --dangerously-skip-permissions",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["claude", "claude-code"],
            detectNodeArgsSubstrings: ["claude-code", "anthropic-ai/claude-code", "/claude"],
            iconAsset: "AgentIcons/claude-code",
            sfSymbolFallback: "sparkles",
            resume: .uuidById(
                command: "claude --dangerously-skip-permissions --resume",
                projectDirKey: SurfaceMetadataKeyName.claudeSessionProjectDir
            ),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: .flag("--effort"),
                effortValues: ["low", "medium", "high", "xhigh", "max"],
                promptDelivery: .positional,
                // The only harness with a system-prompt axis in v1: append adds
                // to the c11/Claude default, replace supplants it (empty text =
                // the Gregorovich blank slate).
                systemPromptArg: AgentSystemPromptArg(
                    appendFlag: "--append-system-prompt",
                    replaceFlag: "--system-prompt"
                )
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "codex",
            agentType: .codex,
            displayName: "Codex",
            factoryCommand: "codex --yolo",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["codex", "codex-cli"],
            detectNodeArgsSubstrings: ["codex-cli", "openai/codex", "/codex"],
            iconAsset: "AgentIcons/codex",
            sfSymbolFallback: "chevron.left.forwardslash.chevron.right",
            resume: .fixed("codex resume --yolo --last\n"),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
            // Codex has no --effort flag; reasoning effort rides the
            // config-override syntax. Values pass through (codex enforces).
                effortArg: .configKV("model_reasoning_effort"),
                effortValues: [],
                promptDelivery: .positional,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "grok",
            agentType: .grok,
            displayName: "Grok Build",
            factoryCommand: "grok --always-approve",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["grok", "grok-cli", "grok-pager"],
            detectNodeArgsSubstrings: [],
            iconAsset: "AgentIcons/grok",
            sfSymbolFallback: "bolt.fill",
            // Resources/bin/grok injects a UUID but publishes it only after
            // the first message creates a durable session directory. The
            // conversation strategy then resumes that exact UUID. Keep this
            // no-id command only for the legacy disabled-store path.
            resume: .fixed("grok --always-approve --resume\n"),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: nil,
                effortValues: [],
                promptDelivery: .positional,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "kimi",
            agentType: .kimi,
            displayName: "Kimi",
            factoryCommand: "kimi --auto",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["kimi", "kimi-cli"],
            detectNodeArgsSubstrings: ["kimi-cli", "moonshot/kimi", "/kimi"],
            iconAsset: "AgentIcons/kimi",
            sfSymbolFallback: "moon.stars",
            resume: .fixed("kimi --auto\n"),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
            // kimi's --thinking is boolean, not tiered — no effort axis.
                effortArg: nil,
                effortValues: [],
                promptDelivery: .postBoot,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "opencode",
            agentType: .opencode,
            displayName: "OpenCode",
            factoryCommand: "opencode --auto",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["opencode", "opencode-cli"],
            detectNodeArgsSubstrings: ["opencode-cli", "sst/opencode", "/opencode"],
            iconAsset: "AgentIcons/opencode",
            sfSymbolFallback: "curlybraces",
            resume: .fixed("opencode --auto\n"),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: nil,
                effortValues: [],
            // `--prompt` because the factory command is the bare TUI, whose
            // sole positional is `[project]` — a path, not a message. A
            // positional prompt there would be read as a directory. The
            // one-shot `opencode run` form takes its message positionally;
            // an operator who rebases the command onto it owns that.
                promptDelivery: .flag("--prompt"),
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "github-copilot",
            agentType: .githubCopilot,
            displayName: "GitHub Copilot",
            factoryCommand: "copilot --allow-all --autopilot",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["copilot"],
            detectNodeArgsSubstrings: ["@github/copilot", "/copilot"],
            iconAsset: "AgentIcons/github-copilot",
            sfSymbolFallback: "paperplane.fill",
            // No phase1 row today → fresh launch via the normal path.
            resume: .none,
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: nil,
                effortValues: [],
                promptDelivery: .postBoot,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "pi",
            agentType: .pi,
            displayName: "Pi",
            // No auto-approve-all flag: pi's `--approve` trusts project-local
            // *files* for the run, not tool calls. Launches (and resumes) bare
            // — a documented degradation, not an oversight.
            factoryCommand: "pi",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["pi"],
            detectNodeArgsSubstrings: ["@earendil-works/pi"],
            iconAsset: nil,
            sfSymbolFallback: "p.circle",
            // `pi -c` continues the most recent session in cwd (best-effort
            // phase-1 fallback, same shape as codex --last). Exact-session
            // resume is handled by the scrape rail: the pi wrapper
            // (`Resources/bin/pi`) mints a wrapper-claim whose time floor lets
            // `PiScraper` + `PiStrategy` resolve a specific
            // `~/.pi/agent/sessions/` id and type `pi --session '<id>'` even
            // when the cwd holds several sessions.
            resume: .fixed("pi -c\n"),
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: .flag("--thinking"),
                effortValues: ["off", "minimal", "low", "medium", "high", "xhigh"],
                promptDelivery: .positional,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "omp",
            agentType: .omp,
            displayName: "oh-my-pi",
            factoryCommand: "omp --auto-approve",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["omp"],
            detectNodeArgsSubstrings: ["@oh-my-pi/"],
            iconAsset: nil,
            sfSymbolFallback: "o.circle",
            // Exact-session resume via the conversation rail: after the first
            // message persists, Resources/bin/omp reads OMP's tty pointer and
            // pushes the exact JSONL path + UUID to OmpStrategy, which emits
            // `omp --resume='<id>'`. Empty sessions remain placeholders.
            resume: .none,
            launch: AgentLaunchTemplate(
                modelArg: .flag("--model"),
                effortArg: .flag("--thinking"),
                effortValues: ["off", "minimal", "low", "medium", "high", "xhigh"],
                promptDelivery: .positional,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "custom",
            agentType: .custom,
            displayName: "Custom",
            factoryCommand: "",
            factoryInitialPrompt: "",
            detectComms: [],
            detectNodeArgsSubstrings: [],
            iconAsset: nil,
            sfSymbolFallback: nil,
            resume: .none,
            launch: AgentLaunchTemplate(
                modelArg: nil,
                effortArg: nil,
                effortValues: [],
                promptDelivery: .postBoot,
                systemPromptArg: nil
            ),
            isCanonicalTerminalType: false,
            hasConversationStrategy: false
        )
    ])
}

/// The factory initial prompt for c11-launched agents — empty by design.
/// A freshly launched agent boots straight to ready with no orientation
/// turn, so there is no dead-time before the operator can give it a task.
/// c11 supplies the identity the sidebar needs itself: the agent type comes
/// from `AgentDetector` (process inspection) and the pinned model plus a
/// placeholder title are stamped at launch in `Workspace.launchAgentSurface`.
/// The c11 skill loads on demand — when a task actually drives the workspace.
/// Mirrors `AgentType.factoryInitialPrompt` for non-custom agents; an
/// operator who wants a launch prompt can still set one per-agent in
/// Default Agent settings.
let c11OrientPrompt = ""

/// Launch template for a kebab-case custom agent kind, decoded from
/// `~/.config/c11/agents/<kind>.json`. This file is the launch-template
/// subset of the planned runtime agent manifest (docs/agent-registry-design.md
/// §7); when full runtime manifests land they subsume it. Only `command` is
/// required:
///
/// ```json
/// { "command": "aider --yes-always",
///   "modelFlag": "--model",
///   "effortFlag": null,
///   "effortValues": [],
///   "promptDelivery": "post-boot",
///   "env": { "AIDER_ANALYTICS": "false" } }
/// ```
///
/// `promptDelivery` accepts `"positional"`, `"post-boot"`, or a flag name
/// (any string starting with `-`), e.g. `"--prompt"`.
struct UserAgentLaunchTemplate: Codable, Equatable {
    var command: String
    var modelFlag: String?
    var effortFlag: String?
    var effortValues: [String]?
    var promptDelivery: String?
    var env: [String: String]?

    /// The composed launch-template view over the decoded fields.
    var template: AgentLaunchTemplate {
        AgentLaunchTemplate(
            modelArg: modelFlag.flatMap { $0.isEmpty ? nil : .flag($0) },
            effortArg: effortFlag.flatMap { $0.isEmpty ? nil : .flag($0) },
            effortValues: effortValues ?? [],
            promptDelivery: {
                switch promptDelivery {
                case .some("positional"): return .positional
                case .some(let s) where s.hasPrefix("-"): return .flag(s)
                default: return .postBoot
                }
            }(),
            // Custom kinds have no system-prompt axis in v1 (the axis is
            // claude-code-only; other harnesses land in v2).
            systemPromptArg: nil
        )
    }

    /// Kind grammar shared with the sidebar's `terminal_type` metadata key:
    /// lowercase kebab, ≤ 32 chars.
    static func isValidKind(_ kind: String) -> Bool {
        guard !kind.isEmpty, kind.count <= 32 else { return false }
        return kind.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
    }

    static func templateURL(kind: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/c11/agents", isDirectory: true)
            .appendingPathComponent("\(kind).json")
    }

    /// Load the template for a custom kind, or `nil` when no file exists or
    /// it fails to decode. Callers treat `nil` as "unknown agent type".
    static func load(kind: String) -> UserAgentLaunchTemplate? {
        guard isValidKind(kind) else { return nil }
        let url = templateURL(kind: kind)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(UserAgentLaunchTemplate.self, from: data),
              !decoded.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return decoded
    }
}
