import Foundation

// MARK: - Agent launch picker: pure view-model (C11-181, tier 1)
//
// The UI-agnostic heart of the A-button launch popover. It turns the saved-config
// library (`AgentConfigLibraryFile`) into rendered shortlist rows, derives the
// display facets the manifest does not model (provider, cost — design §1.2/§5.6),
// and runs the keyboard-navigation state machine (↑↓/⏎/⌥⏎/1–9/esc).
//
// No AppKit / SwiftUI: every dependency is injected via `AgentPickerEnvironment`, so
// this whole file is exercised in `c11LogicTests` without constructing a Workspace or
// touching NSApp. The SwiftUI layer (`AgentPickerView`) only renders this and forwards
// key events; the presenter wires the real environment + action callbacks.
//
// Binding spec: `docs/design-prototypes/model-picker/index.html` (the `#popover`).

/// The system-prompt chip a row shows (design §1.4). `nil` on the row means the
/// config inherits (no chip). `blank` is the Gregorovich replace-empty case.
enum PickerSysChip: Equatable {
    /// `replace` mode with empty text — launches `--system-prompt ''`. Rendered `·blank·`.
    case blank
    /// A non-inherit mode carrying text, rendered `sys:append` / `sys:replace`.
    case mode(String)

    /// The gold chip label the view draws.
    var label: String {
        switch self {
        case .blank:
            return String(localized: "agentPicker.chip.blank", defaultValue: "·blank·")
        case .mode(let mode):
            return String(
                format: String(
                    localized: "agentPicker.chip.systemPrompt",
                    defaultValue: "sys:%@"
                ),
                mode
            )
        }
    }
}

/// One shortlist row — a full saved recipe (design §5.1 row anatomy). All display
/// strings are precomputed so the view is a dumb renderer.
struct AgentPickerRow: Equatable {
    /// The launch / pin target this row acts on.
    var config: SavedAgentConfig
    /// The recipe name (bold).
    var name: String
    /// `harness · provider · model` sub-line (lowercased harness, per prototype).
    var subLine: String
    /// Effort chip text, or `nil` when the config inherits effort.
    var effortChip: String?
    /// System-prompt chip, or `nil` when inheriting.
    var sysChip: PickerSysChip?
    /// `$in/$out` per-Mtok cost, or `nil` when the catalog is absent (§5.6).
    var cost: String?
    /// 1–9 launch-badge number (1-based).
    var keyBadge: Int
    /// The pinned default (● pin-dot, `default` tag).
    var isPinnedDefault: Bool
    /// Harness installed on PATH. `false` → dim + "NOT INSTALLED", still pinnable.
    var isInstalled: Bool
}

/// The full rendered content of the popover, independent of keyboard selection:
/// the saved-agent rows and nothing else (C11-203 B1/B4 retired the recent
/// section and the launch-stats headline).
struct AgentPickerContent: Equatable {
    var shortlist: [AgentPickerRow]
}

/// A key the popover reacts to — decoupled from `NSEvent` so the state machine is
/// unit-testable. The view translates real key events into these.
enum PickerKey: Equatable {
    case up
    case down
    case enter
    case escape
    case digit(Int) // 1...9
}

/// What a key/gesture resolves to. The presenter maps these onto the workspace.
enum PickerAction: Equatable {
    /// Launch this config now (row click / ⏎ / 1–9).
    case launch(SavedAgentConfig)
    /// Set this config as the pinned default without launching (pin glyph / ⌥-click / ⌥⏎).
    case pin(SavedAgentConfig)
    /// Open the tier-2 "Edit Launch Agents" sheet (C11-182 seam).
    case viewAll
    /// Dismiss the popover.
    case close
    /// A launch was requested for a harness that is not installed. The caller
    /// keeps the picker open and surfaces the refusal.
    case notInstalled(SavedAgentConfig)
    /// No-op (for example, a number key past the shortlist).
    case none
}

/// Injected environment — real impls live in the presenter, stubs in tests.
struct AgentPickerEnvironment {
    /// Harness key → English display name (real: `AgentRegistry`/`AgentType.displayName`).
    var displayName: (String) -> String
    /// Derived provider facet (real: `AgentLaunchStats.provider`). `nil` when unknown.
    var provider: (String, String?) -> String?
    /// Cached PATH probe (real: `which` on the harness command). Absent = dim row.
    var isInstalled: (String) -> Bool
    /// Per-model cost lookup (real: token-cost catalog when it exists; today always
    /// `nil` → cost column omitted, design §5.6).
    var costFor: (String?) -> (inUSD: Double, outUSD: Double)?
}

/// The keyboard-navigable picker state. Value type: the view holds it in `@State`
/// and calls `handleKey`; arrows mutate `selectedIndex`, actions are returned.
struct AgentPickerModel {
    /// Shortlist configs in library `order` (the launch/pin targets, 1–9).
    let configs: [SavedAgentConfig]
    /// What ⏎ launches when nothing is keyboard-selected (design §5.1).
    let effectiveDefault: SavedAgentConfig
    /// Installed state for the effective default, which may be a recipe whose
    /// blank id cannot be found in the shortlist.
    private let effectiveDefaultIsInstalled: Bool
    /// Precomputed render content.
    let content: AgentPickerContent

    /// -1 = nothing focused (open state); 0..<configs.count = a shortlist row.
    var selectedIndex: Int = -1

    // MARK: Build

    init(library: AgentConfigLibraryFile, effectiveDefault: SavedAgentConfig, env: AgentPickerEnvironment) {
        // Sort defensively by `order` so 1–9 badges are stable even if the on-disk
        // array ever drifts from `order` (self-review F8).
        let sorted = library.configs.sorted { $0.order < $1.order }
        self.configs = sorted
        self.effectiveDefault = effectiveDefault
        self.effectiveDefaultIsInstalled = env.isInstalled(effectiveDefault.config.harness)

        let pinnedId = library.default.configId

        var rows: [AgentPickerRow] = []
        for (i, cfg) in sorted.enumerated() {
            rows.append(
                AgentPickerRow(
                    config: cfg,
                    name: cfg.name,
                    subLine: Self.subLine(for: cfg.config, env: env),
                    effortChip: AgentPickerModel.nonEmpty(cfg.config.effort),
                    sysChip: Self.sysChip(for: cfg.config.systemPrompt),
                    cost: Self.costString(cfg.config.model, env: env),
                    keyBadge: i + 1,
                    isPinnedDefault: pinnedId == cfg.id,
                    isInstalled: env.isInstalled(cfg.config.harness)
                )
            )
        }
        self.content = AgentPickerContent(shortlist: rows)
    }

    // MARK: Keyboard state machine

    /// The highest valid nav index (the last shortlist row).
    private var maxIndex: Int { configs.count - 1 }

    /// The config currently focused, or `nil` when nothing is (index -1).
    private var selectedConfig: SavedAgentConfig? {
        guard selectedIndex >= 0, selectedIndex < configs.count else { return nil }
        return configs[selectedIndex]
    }

    /// Apply a key. Arrows mutate `selectedIndex` and return `.none`; everything
    /// else resolves to a `PickerAction`. `option` = the ⌥ modifier (⌥⏎ = pin),
    /// `command` = the ⌘ modifier (⌘⏎ = View all, never launches).
    mutating func handleKey(_ key: PickerKey, option: Bool = false, command: Bool = false) -> PickerAction {
        switch key {
        case .down:
            guard maxIndex >= 0 else { return .none }
            selectedIndex = min(maxIndex, selectedIndex + 1)
            return .none
        case .up:
            // Clamp at 0; from -1 (nothing) the first Up selects row 0.
            selectedIndex = max(0, selectedIndex - 1)
            return .none
        case .escape:
            return .close
        case .digit(let n):
            guard n >= 1, n <= configs.count else { return .none }
            let cfg = configs[n - 1]
            return launchOrNoop(cfg) // installed → launch, else no-op (caller may hint)
        case .enter:
            // ⌘⏎ opens the tier-2 "Edit Launch Agents" sheet — never launches
            // (prototype: `if (e.metaKey){ openSheet(...); return; }`).
            if command { return .viewAll }
            // A shortlist row focused → pin (⌥) or launch it.
            if let cfg = selectedConfig {
                return option ? .pin(cfg) : launchOrNoop(cfg)
            }
            // Nothing focused → act on the effective default (⌥ pins it if it is a
            // real saved config; a transient effective default can't be pinned).
            if option {
                return effectiveDefault.id.isEmpty ? .none : .pin(effectiveDefault)
            }
            // Plain launch runs through the installed guard too, so an uninstalled
            // pinned default no-ops symmetrically with its 1–9 digit.
            return launchOrNoop(effectiveDefault)
        }
    }

    /// Launch iff installed; a plain launch of a not-installed harness returns an
    /// explicit refusal so every input path can surface the same feedback. Pin
    /// paths bypass this.
    private func launchOrNoop(_ cfg: SavedAgentConfig) -> PickerAction {
        launchOrNotInstalled(cfg)
    }

    private func launchOrNotInstalled(_ cfg: SavedAgentConfig) -> PickerAction {
        let shortlistInstalled = content.shortlist.first(where: {
            !$0.config.id.isEmpty && $0.config.id == cfg.id
        })?.isInstalled
        let isInstalled = shortlistInstalled
            ?? (cfg == effectiveDefault ? effectiveDefaultIsInstalled : true)
        if !isInstalled {
            return .notInstalled(cfg)
        }
        return .launch(cfg)
    }

    // MARK: Derivation helpers (pure)

    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// `deepseek/deepseek-chat-v3.1` → `deepseek-chat-v3.1`; `opus` → `opus`;
    /// `nil` → `inherit`.
    static func modelLabel(_ model: String?) -> String {
        guard let m = nonEmpty(model) else {
            return String(localized: "agentPicker.model.inherit", defaultValue: "inherit")
        }
        if let slash = m.firstIndex(of: "/") { return String(m[m.index(after: slash)...]) }
        return m
    }

    /// Display provider: the central `AgentLaunchStats.provider` result, capitalized
    /// for the fixed harnesses, with a `router` fallback for router harnesses whose
    /// model carries no `provider/` prefix, and "" for custom/unknown (prototype).
    static func providerLabel(harness: String, model: String?, env: AgentPickerEnvironment) -> String {
        if let p = env.provider(harness, model), !p.isEmpty {
            return p.prefix(1).uppercased() + p.dropFirst()
        }
        // No derived provider. Router harnesses still read as "router"; everything
        // else (custom / unknown) shows nothing.
        switch harness {
        case "opencode", "pi", "omp":
            return String(localized: "agentPicker.provider.router", defaultValue: "router")
        default: return ""
        }
    }

    /// `harness · provider · model` (lowercased harness display, per the prototype).
    static func subLine(for cfg: AgentLaunchConfig, env: AgentPickerEnvironment) -> String {
        let harness = env.displayName(cfg.harness).lowercased()
        let provider = providerLabel(harness: cfg.harness, model: cfg.model, env: env)
        let model = modelLabel(cfg.model)
        var parts = [harness]
        if !provider.isEmpty { parts.append(provider) }
        parts.append(model)
        return parts.joined(separator: " · ")
    }

    static func sysChip(for setting: SystemPromptSetting?) -> PickerSysChip? {
        guard let s = setting, s.mode != .inherit else { return nil }
        if s.mode == .replace, s.text.isEmpty { return .blank }
        return .mode(s.mode.rawValue)
    }

    static func costString(_ model: String?, env: AgentPickerEnvironment) -> String? {
        guard let c = env.costFor(model) else { return nil }
        return "$\(fmt(c.inUSD))/$\(fmt(c.outUSD))"
    }

    /// Prototype `fmt`: ≥1 drops a trailing zero on the .x0 case, <1 keeps two places.
    static func fmt(_ n: Double) -> String {
        if n >= 1 {
            if n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(n)) }
            let two = String(format: "%.2f", n)
            return two.hasSuffix("0") ? String(two.dropLast()) : two
        }
        return String(format: "%.2f", n)
    }
}
