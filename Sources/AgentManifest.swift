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
            resume: .fixed("codex resume --last\n"),
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
            resume: .fixed("grok --always-approve --resume\n"),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "kimi",
            agentType: .kimi,
            displayName: "Kimi",
            factoryCommand: "kimi",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["kimi", "kimi-cli"],
            detectNodeArgsSubstrings: ["kimi-cli", "moonshot/kimi", "/kimi"],
            iconAsset: "AgentIcons/kimi",
            sfSymbolFallback: "moon.stars",
            resume: .fixed("kimi\n"),
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "opencode",
            agentType: .opencode,
            displayName: "OpenCode",
            factoryCommand: "opencode run --dangerously-skip-permissions",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["opencode", "opencode-cli"],
            detectNodeArgsSubstrings: ["opencode-cli", "sst/opencode", "/opencode"],
            iconAsset: "AgentIcons/opencode",
            sfSymbolFallback: "curlybraces",
            resume: .fixed("opencode run --dangerously-skip-permissions\n"),
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
            isCanonicalTerminalType: true,
            hasConversationStrategy: true
        ),
        AgentManifest(
            kind: "pi",
            agentType: .pi,
            displayName: "Pi",
            // No documented auto-approve flag — launches bare (documented
            // degradation, same as opencode/kimi historically).
            factoryCommand: "pi",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["pi"],
            detectNodeArgsSubstrings: ["@earendil-works/pi"],
            iconAsset: nil,
            sfSymbolFallback: "p.circle",
            // `pi -c` continues the most recent session in cwd (best-effort,
            // same shape as codex --last). Exact-session resume via a JSONL
            // scraper (~/.pi/agent/sessions/) is a tracked follow-up.
            resume: .fixed("pi -c\n"),
            isCanonicalTerminalType: true,
            hasConversationStrategy: false
        ),
        AgentManifest(
            kind: "omp",
            agentType: .omp,
            displayName: "oh-my-pi",
            factoryCommand: "omp",
            factoryInitialPrompt: c11OrientPrompt,
            detectComms: ["omp"],
            detectNodeArgsSubstrings: ["@oh-my-pi/"],
            iconAsset: nil,
            sfSymbolFallback: "o.circle",
            // No confirmed resume flag (TUI `/resume` only); launches fresh.
            // Exact-session resume via a JSONL scraper (~/.omp/agent/sessions/)
            // is a tracked follow-up.
            resume: .none,
            isCanonicalTerminalType: true,
            hasConversationStrategy: false
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
            isCanonicalTerminalType: false,
            hasConversationStrategy: false
        )
    ])
}

/// The orientation prompt typed into a freshly launched agent. Mirrors
/// `AgentType.factoryInitialPrompt` for non-custom agents.
let c11OrientPrompt = "you are operating inside a c11 workspace. load the skill."
