import Foundation

/// The agent kinds c11 knows how to launch. `bash` is intentionally absent —
/// terminals are the bash path; agents are the agent path. One way to do a
/// given action.
enum AgentType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case kimi
    case opencode
    case custom

    var id: String { rawValue }

    /// Human-readable label for the picker, the A-button tooltip, and the
    /// per-agent subheading in Settings. Localized at the call site.
    var displayName: String {
        switch self {
        case .claudeCode:
            return String(localized: "agentType.claudeCode", defaultValue: "Claude Code")
        case .codex:
            return String(localized: "agentType.codex", defaultValue: "Codex")
        case .kimi:
            return String(localized: "agentType.kimi", defaultValue: "Kimi")
        case .opencode:
            return String(localized: "agentType.opencode", defaultValue: "OpenCode")
        case .custom:
            return String(localized: "agentType.custom", defaultValue: "Custom")
        }
    }

    /// The launch command an operator sees as the factory default. Editable
    /// in Settings; persisted per-agent so flipping the picker doesn't wipe
    /// values for the other agents.
    var factoryCommand: String {
        switch self {
        case .claudeCode: return "claude --dangerously-skip-permissions"
        case .codex:      return "codex --yolo"
        case .kimi:       return "kimi"
        case .opencode:   return "opencode run --dangerously-skip-permissions"
        case .custom:     return ""
        }
    }

    /// Factory default for the optional initial prompt that gets typed into
    /// the agent after launch. Empty for `custom` (operator authors their
    /// own); identical for the four built-ins.
    var factoryInitialPrompt: String {
        switch self {
        case .custom: return ""
        default:      return "you are operating inside a c11 workspace. load the skill."
        }
    }
}

/// Per-agent configuration: command typed into the shell to launch this agent,
/// optional initial prompt to send after launch, and free-text env overrides.
struct AgentConfig: Codable, Equatable {
    /// Shell command line that runs when this agent is launched.
    var command: String
    /// Optional initial prompt. For claude-code it appends as a single-quoted
    /// positional argument; other TUIs ignore it unless the operator wires it
    /// into `command` themselves (different TUI delivery contracts).
    var initialPrompt: String
    /// Multi-line `KEY=value` text, one entry per line. Parsed at use time;
    /// keeps the UI to a single text editor instead of a row-editor list.
    var envOverridesText: String

    init(command: String, initialPrompt: String, envOverridesText: String) {
        self.command = command
        self.initialPrompt = initialPrompt
        self.envOverridesText = envOverridesText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.command = (try? c.decode(String.self, forKey: .command)) ?? ""
        self.initialPrompt = (try? c.decode(String.self, forKey: .initialPrompt)) ?? ""
        self.envOverridesText = (try? c.decode(String.self, forKey: .envOverridesText)) ?? ""
    }

    /// Factory defaults for a given agent type.
    static func factory(for agent: AgentType) -> AgentConfig {
        AgentConfig(
            command: agent.factoryCommand,
            initialPrompt: agent.factoryInitialPrompt,
            envOverridesText: ""
        )
    }

    /// Parse `envOverridesText` into a `[String: String]` map. Lines that are
    /// blank, start with `#`, or have no `=` are skipped. Whitespace around
    /// the key is trimmed; the value keeps its trailing whitespace stripped
    /// but interior spaces preserved.
    var envMap: [String: String] {
        var out: [String: String] = [:]
        for raw in envOverridesText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                out[key] = String(value)
            }
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case command, initialPrompt, envOverridesText
    }
}

/// User-configurable defaults for the agent that launches when the operator
/// clicks the "A" button (or any equivalent socket / menu path). Terminals
/// remain bash; this struct never speaks to the T button.
///
/// Persisted at the user level via UserDefaults (`defaultsKey`) and optionally
/// overridden per project via `.c11/agents.json` (see `DefaultAgentProjectConfig`).
struct DefaultAgentConfig: Codable, Equatable {
    /// Which agent the A button launches.
    var defaultAgent: AgentType
    /// Per-agent saved configuration. Each key has an entry; missing entries
    /// fall back to factory defaults at use time.
    var agents: [AgentType: AgentConfig]

    /// Whether `defaultAgent` was explicitly specified by the source this
    /// config was decoded from. `true` for programmatically-built configs and
    /// for JSON that carries a `defaultAgent` key; `false` only when a decoded
    /// blob omits the key (and `defaultAgent` therefore holds the fallback).
    ///
    /// Project-level overrides key off this: a `.c11/agents.json` that doesn't
    /// state a `defaultAgent` must NOT silently force the fallback over the
    /// user's Settings pick (see `overrideDefaultAgent`). Excluded from
    /// `Equatable` so value comparisons stay shape-based.
    var hasExplicitDefaultAgent: Bool = true

    /// The agent this config should impose on a *consumer* that already has its
    /// own default (i.e. project config overriding the user default). `nil` when
    /// the default was never explicitly stated, so the consumer keeps its own.
    var overrideDefaultAgent: AgentType? {
        hasExplicitDefaultAgent ? defaultAgent : nil
    }

    /// Returns the config for `agent`, falling back to factory if the operator
    /// never edited that one.
    func config(for agent: AgentType) -> AgentConfig {
        agents[agent] ?? .factory(for: agent)
    }

    // Shape-based equality: `hasExplicitDefaultAgent` is provenance metadata,
    // not part of the config's value, so two configs with the same selection
    // and per-agent entries compare equal regardless of how they were built.
    static func == (lhs: DefaultAgentConfig, rhs: DefaultAgentConfig) -> Bool {
        lhs.defaultAgent == rhs.defaultAgent && lhs.agents == rhs.agents
    }

    /// Factory shape: claude-code is the default, every agent pre-filled with
    /// its built-in command + the c11-orientation prompt.
    static let factory: DefaultAgentConfig = {
        var agents: [AgentType: AgentConfig] = [:]
        for type in AgentType.allCases {
            agents[type] = .factory(for: type)
        }
        return DefaultAgentConfig(defaultAgent: .claudeCode, agents: agents)
    }()

    init(defaultAgent: AgentType, agents: [AgentType: AgentConfig]) {
        self.defaultAgent = defaultAgent
        self.agents = agents
        self.hasExplicitDefaultAgent = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Track explicit presence so an omitted `defaultAgent` doesn't read as
        // a deliberate "launch claude-code" override when this config is used at
        // the project level. A present-but-corrupt value (e.g. an unknown agent
        // name) is treated like the user-level store has always treated it:
        // fall back to claude-code, and — since the stated value was unusable —
        // do NOT count it as an explicit override.
        if let decoded = try? c.decode(AgentType.self, forKey: .defaultAgent) {
            self.defaultAgent = decoded
            self.hasExplicitDefaultAgent = true
        } else {
            self.defaultAgent = .claudeCode
            self.hasExplicitDefaultAgent = false
        }
        // `agents` must be the v2 dict shape when present. A legacy pre-v0.48
        // file (an *array* of {id,displayName,command}) must NOT silently decode
        // to an empty dict and let this whole config masquerade as a valid
        // override — that's the bug where a stale ~/.c11/agents.json pinned the
        // A button to claude-code regardless of Settings. Throwing here makes
        // `DefaultAgentProjectConfig.find`'s `try?` reject the file outright so
        // resolution falls through to the user's Settings default.
        if c.contains(.agents) {
            let agentsByRaw = try c.decode([String: AgentConfig].self, forKey: .agents)
            var byType: [AgentType: AgentConfig] = [:]
            for (raw, cfg) in agentsByRaw {
                if let t = AgentType(rawValue: raw) { byType[t] = cfg }
            }
            self.agents = byType
        } else {
            self.agents = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(defaultAgent, forKey: .defaultAgent)
        var byRaw: [String: AgentConfig] = [:]
        for (type, cfg) in agents { byRaw[type.rawValue] = cfg }
        try c.encode(byRaw, forKey: .agents)
    }

    private enum CodingKeys: String, CodingKey {
        case defaultAgent, agents
    }
}

/// UserDefaults-backed singleton store. `current` is recomputed on each access
/// so changes from another process or socket-driven writes propagate without
/// a full app restart.
final class DefaultAgentConfigStore {
    static let shared = DefaultAgentConfigStore(defaults: .standard)

    /// v2 because the v1 shape (single agentType + flat fields) was reshaped
    /// in C11-14 PR review. We don't migrate v1 → v2: the feature has only
    /// been live for a day on this branch and was never released.
    static let defaultsKey = "defaultTerminalAgentConfig.v2"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var current: DefaultAgentConfig {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let cfg = try? JSONDecoder().decode(DefaultAgentConfig.self, from: data) else {
            return .factory
        }
        // Ensure every agent type has at least the factory defaults filled in;
        // covers older blobs and operator-cleared individual entries.
        var filled = cfg
        for type in AgentType.allCases where filled.agents[type] == nil {
            filled.agents[type] = .factory(for: type)
        }
        return filled
    }

    func save(_ cfg: DefaultAgentConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Update one agent's configuration in place; other agents and the
    /// default-agent selection are untouched.
    func update(_ agent: AgentType, _ mutate: (inout AgentConfig) -> Void) {
        var cfg = current
        var entry = cfg.config(for: agent)
        mutate(&entry)
        cfg.agents[agent] = entry
        save(cfg)
    }

    /// Update the default-agent selection without touching per-agent configs.
    func setDefaultAgent(_ agent: AgentType) {
        var cfg = current
        cfg.defaultAgent = agent
        save(cfg)
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
