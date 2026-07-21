import Foundation

// MARK: - Agent-config editor model (C11-182, design §1.2)
//
// Pure, view-model-free logic for the Saved Configs editor (tier 2 of the
// model picker). Everything here derives from `AgentRegistry.shared` (the
// manifest source of truth) plus a few static seed catalogs; nothing touches
// SwiftUI, AppKit, or `NSApp`, so it is unit-tested directly in `c11-logic`.
//
// The prototype's `HARNESSES` map is mock data; these functions compute the
// same axes from the real manifest, so a manifest change flows through without
// a parallel table to keep in sync.

// MARK: Axis descriptors (design §1.2)

/// How the model control renders for a harness. Provider is a *derived* facet,
/// never a stored field: fixed harnesses carry a constant, router harnesses
/// take the model-id prefix (design §1.2 / §8.7).
enum ModelAxis: Equatable {
    /// No `--model` flag (custom): the harness launches whatever its own config selects.
    case none
    /// Claude family aliases, picked from a list with an explicit Inherit row.
    case families([ClaudeModelFamily])
    /// A single fixed provider (codex/grok/kimi/github-copilot): freeform id + suggestion chips.
    case freeform(providerLabel: String)
    /// OpenRouter family (opencode/pi/omp): a filterable list grouped by provider prefix.
    case router
}

/// How the effort control renders for a harness.
enum EffortAxis: Equatable {
    /// No effort flag (grok/kimi/opencode/github-copilot/custom).
    case none
    /// A closed set of tiers validated early (claude, pi, omp).
    case tiers([String])
    /// A flag whose values pass through to the CLI (codex's `-c model_reasoning_effort=`).
    case passthrough
}

/// Whether the system-prompt control is available for a harness (design §1.4).
enum SystemPromptAxis: Equatable {
    /// The CLI has no system-prompt flag c11 knows — control disabled.
    case none
    /// Supported; carries the append/replace flag names for the blank-slate note.
    case supported(appendFlag: String?, replaceFlag: String?)
}

/// The provider-identity class of a harness (design §1.2). Drives the harness
/// card's provider sub-line and whether provider is a label (fixed) or lives in
/// the model prefix (router).
enum AgentProviderClass: Equatable {
    /// One provider, shown as a label (never a control). Carries the brand name.
    case fixed(label: String)
    /// OpenRouter family: provider rides the model-id prefix.
    case router
    /// Operator-defined custom kind: no provider identity.
    case custom
}

/// Namespace of pure derivations over the agent registry + static seeds.
enum AgentConfigAxes {

    // MARK: Provider identity (static map, design §1.2)

    /// Brand label for a fixed-provider harness (proper noun, not localized).
    /// Router → "OpenRouter"; custom/unknown → "".
    static func providerDisplayLabel(forHarness harness: String) -> String {
        switch harness {
        case "claude-code":    return "Anthropic"
        case "codex":          return "OpenAI"
        case "grok":           return "xAI"
        case "kimi":           return "Moonshot"
        case "github-copilot": return "GitHub"
        case "opencode", "pi", "omp": return "OpenRouter"
        default:               return ""
        }
    }

    static func providerClass(forHarness harness: String) -> AgentProviderClass {
        switch harness {
        case "opencode", "pi", "omp":
            return .router
        case "custom":
            return .custom
        default:
            // Fixed provider iff we know a brand label; unknown custom kinds → .custom.
            let label = providerDisplayLabel(forHarness: harness)
            return label.isEmpty ? .custom : .fixed(label: label)
        }
    }

    // MARK: Model axis (derived from the manifest)

    static func modelAxis(forHarness harness: String) -> ModelAxis {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harness) else {
            return .none
        }
        guard manifest.launch.modelArg != nil else { return .none }
        if harness == "claude-code" {
            return .families(ClaudeModelFamily.allCases)
        }
        switch providerClass(forHarness: harness) {
        case .router:
            return .router
        case .fixed(let label):
            return .freeform(providerLabel: label)
        case .custom:
            // A custom kind that nonetheless declares a model flag: freeform, unlabeled.
            return .freeform(providerLabel: "")
        }
    }

    // MARK: Effort axis (derived from the manifest)

    static func effortAxis(forHarness harness: String) -> EffortAxis {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harness),
              manifest.launch.effortArg != nil else {
            return .none
        }
        let values = manifest.launch.effortValues
        return values.isEmpty ? .passthrough : .tiers(values)
    }

    /// The chip values shown for the effort control: the tier set for `.tiers`,
    /// a small suggestion set for `.passthrough` (codex accepts these, and the
    /// value is stored free-form so exotic values remain reachable via CLI),
    /// and `[]` for `.none` (no chips rendered).
    static func effortChipValues(forHarness harness: String) -> [String] {
        switch effortAxis(forHarness: harness) {
        case .tiers(let values):
            return values
        case .passthrough:
            return passthroughEffortSuggestions(forHarness: harness)
        case .none:
            return []
        }
    }

    private static func passthroughEffortSuggestions(forHarness harness: String) -> [String] {
        switch harness {
        case "codex": return ["low", "medium", "high"]
        default:      return []
        }
    }

    // MARK: System-prompt axis (derived from the manifest)

    static func systemPromptAxis(forHarness harness: String) -> SystemPromptAxis {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harness),
              let arg = manifest.launch.systemPromptArg else {
            return .none
        }
        return .supported(appendFlag: arg.appendFlag, replaceFlag: arg.replaceFlag)
    }

    // MARK: Static seed catalogs (v1 — pending the real OpenRouter catalog)

    /// Router model list grouped by provider prefix (design §5.4). A curated v1
    /// seed mirroring the binding prototype; superseded when the sibling
    /// token-cost / model catalog lands. Order is stable for deterministic UI.
    static let routerModelCatalog: [(provider: String, models: [String])] = [
        ("anthropic",  ["anthropic/claude-fable-5", "anthropic/claude-opus-4-8", "anthropic/claude-sonnet-5"]),
        ("openai",     ["openai/gpt-5.2", "openai/gpt-5.2-codex", "openai/gpt-5.2-mini"]),
        ("deepseek",   ["deepseek/deepseek-chat-v3.1", "deepseek/deepseek-r1"]),
        ("moonshotai", ["moonshotai/kimi-k2"]),
        ("google",     ["google/gemini-3-pro"]),
        ("x-ai",       ["x-ai/grok-4"]),
    ]

    /// Suggestion chips for freeform-model harnesses (design §5.4). Static v1 seed.
    static func freeformSuggestions(forHarness harness: String) -> [String] {
        switch harness {
        case "codex":          return ["gpt-5.2", "gpt-5.2-codex", "gpt-5.2-mini"]
        case "grok":           return ["grok-4", "grok-4-fast"]
        case "kimi":           return ["kimi-k2"]
        case "github-copilot": return ["gpt-5.2", "claude-sonnet-5"]
        default:               return []
        }
    }

    // MARK: Harness-switch reconciliation (prototype index.html:1042-1053)

    /// When the operator picks a different harness, null out any recipe fields
    /// that no longer make sense for the new harness's axes (model incompatible
    /// with the new model axis, effort outside the new tier set, system-prompt
    /// unsupported). Mirrors the prototype's reconciliation exactly.
    static func reconcileHarnessSwitch(_ config: AgentLaunchConfig, to newHarness: String) -> AgentLaunchConfig {
        var c = config
        c.harness = newHarness

        switch modelAxis(forHarness: newHarness) {
        case .none:
            c.model = nil
        case .families(let families):
            if let m = c.model, !families.map(\.rawValue).contains(m) { c.model = nil }
        case .router:
            if let m = c.model, !m.contains("/") { c.model = nil }
        case .freeform:
            if let m = c.model, m.contains("/") { c.model = nil }
        }

        switch effortAxis(forHarness: newHarness) {
        case .none:
            c.effort = nil
        case .tiers(let tiers):
            if let e = c.effort, !tiers.contains(e) { c.effort = nil }
        case .passthrough:
            break // passthrough accepts arbitrary values — keep whatever is set
        }

        switch systemPromptAxis(forHarness: newHarness) {
        case .none:
            c.systemPrompt = nil
        case .supported:
            // Leave as-is: nil is the true "inherit" (C11-179 contract: nil =
            // inherit the base). The editor renders `?? .inherit` for display, so
            // seeding a non-nil `.inherit` here would clobber a configured base
            // system prompt through mergeOverlay.
            break
        }

        return c
    }

    /// Normalize a recipe for persistence so it faithfully round-trips the
    /// nil=inherit contract: an explicit `.inherit` system-prompt setting (a
    /// transient editor working state) collapses to `nil`, so a saved "inherit"
    /// config never overrides a configured base system prompt at launch.
    static func normalizedForPersistence(_ config: AgentLaunchConfig) -> AgentLaunchConfig {
        var c = config
        if c.systemPrompt?.mode == .inherit { c.systemPrompt = nil }
        return c
    }

    // MARK: Naming + description (prototype autoName / describe)

    /// The short model label: `nil` model → "inherit"; a `provider/model` id →
    /// its suffix; otherwise the raw model string.
    static func modelLabel(_ config: AgentLaunchConfig) -> String {
        guard let m = config.model, !m.isEmpty else { return "inherit" }
        if let slash = m.firstIndex(of: "/") { return String(m[m.index(after: slash)...]) }
        return m
    }

    /// A generated fallback name when the operator leaves the name blank —
    /// `<first word of display name> <model label>` (e.g. "Claude opus"),
    /// falling back to the display name alone.
    static func autoName(for config: AgentLaunchConfig) -> String {
        let display = AgentRegistry.shared.manifest(forKind: config.harness)?.displayName
            ?? config.harness
        let firstWord = display.split(separator: " ").first.map(String.init) ?? display
        let label = modelLabel(config)
        let composed = (label == "inherit") ? firstWord : "\(firstWord) \(label)"
        let trimmed = composed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? display : trimmed
    }

    /// The "harness · model · effort" sub-line (prototype `describe`). Harness is
    /// rendered kind-style (lowercased, spaces → hyphens) to match the prototype.
    static func describe(_ config: AgentLaunchConfig) -> String {
        let display = AgentRegistry.shared.manifest(forKind: config.harness)?.displayName
            ?? config.harness
        let kind = display.lowercased().replacingOccurrences(of: " ", with: "-")
        var bits = [kind, modelLabel(config)]
        if let e = config.effort, !e.isEmpty { bits.append(e) }
        return bits.joined(separator: " · ")
    }

    /// Whether this recipe is the Gregorovich blank-slate case (system prompt
    /// `.replace` with empty text). Drives the gold `·blank·` chip.
    static func isBlankSlate(_ config: AgentLaunchConfig) -> Bool {
        guard let sp = config.systemPrompt else { return false }
        return sp.mode == .replace && sp.text.isEmpty
    }

    /// The library row sub-line: `describe` plus a ` · ·blank·` suffix for the
    /// blank-slate case. The single source of truth for both the sheet's rail
    /// and the Settings subsection row.
    static func subline(_ config: AgentLaunchConfig) -> String {
        isBlankSlate(config) ? "\(describe(config)) · ·blank·" : describe(config)
    }

    /// The model a `.families` harness inherits when its recipe model is unset —
    /// the harness's per-harness Settings base, defaulting to `opus` for
    /// claude-code (matching the factory pin). `nil` when there is no base.
    /// Pure: the base config is injected so this is unit-testable.
    static func inheritedModelBase(forHarness harness: String, from base: DefaultAgentConfig) -> String? {
        guard let agent = AgentType(rawValue: harness) else { return nil }
        let model = base.config(for: agent).model
        if !model.isEmpty { return model }
        return harness == "claude-code" ? ClaudeModelFamily.opus.rawValue : nil
    }

    // MARK: Installed-probe core

    /// The binary name a harness command launches — the first whitespace token
    /// of the command. `nil` for an empty command (custom). This is the pure
    /// core; the actual PATH lookup (login-shell, cached, degrade-to-installed)
    /// lives app-side in `AgentInstalledProbe`.
    static func firstBinaryToken(_ command: String) -> String? {
        for token in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let t = String(token)
            // Skip a leading `KEY=value` env assignment or an `env` shim.
            if t == "env" { continue }
            if t.contains("=") && !t.hasPrefix("-") { continue }
            return t
        }
        return nil
    }
}

// MARK: - Stats bars (design §5.5)

/// One horizontal bar in the launch-stats view. `widthOfMax` drives the bar
/// fill (the leader is full width); `shareOfTotal` drives the "N%" label.
struct StatsBarRow: Equatable {
    let label: String
    let count: Int
    /// Fraction of the window total, for the percentage label (0…1).
    let shareOfTotal: Double
    /// Fraction of the leader's count, for the bar width (0…1).
    let widthOfMax: Double
    /// The top row (drawn with the gold gradient).
    let isLeader: Bool
}

enum LaunchStatsBars {
    /// Turn a windowed query result into sorted bar rows (descending by count,
    /// ties broken by label for determinism). Empty tally → `[]`.
    static func statsBars(from result: LaunchStatsResult) -> [StatsBarRow] {
        let total = result.count
        let sorted = result.tally.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        let maxCount = sorted.first?.value ?? 0
        return sorted.enumerated().map { index, entry in
            StatsBarRow(
                label: entry.key,
                count: entry.value,
                shareOfTotal: total > 0 ? Double(entry.value) / Double(total) : 0,
                widthOfMax: maxCount > 0 ? Double(entry.value) / Double(maxCount) : 0,
                isLeader: index == 0
            )
        }
    }
}
