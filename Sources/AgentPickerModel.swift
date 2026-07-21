import Foundation

// MARK: - Agent launch picker: pure view-model (C11-181, tier 1)
//
// The UI-agnostic heart of the A-button launch popover. It turns the saved-config
// library (`AgentConfigLibraryFile`) into rendered shortlist + recent rows, derives
// the display facets the manifest does not model (provider, live-ness, cost — design
// §1.2/§8.4/§5.6), and runs the keyboard-navigation state machine (↑↓/⏎/⌥⏎/1–9/esc).
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
        case .blank: return "·blank·"
        case .mode(let m): return "sys:\(m)"
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
    /// Marked when follow-recent resolves the effective default to this row
    /// (`recent→default` tag).
    var isRecentDefault: Bool
    /// Harness installed on PATH. `false` → dim + "NOT INSTALLED", still pinnable.
    var isInstalled: Bool
}

/// The RECENT row (design §5.1 / §8.4). `nil` config = ad-hoc launch with no saved id.
struct AgentPickerRecentRow: Equatable {
    /// The saved config the recent launch resolved to, or `nil` (ad-hoc).
    var config: SavedAgentConfig?
    /// Display name (config name, or "Ad-hoc").
    var name: String
    /// Relative time, e.g. "just now" / "2m ago".
    var relativeTime: String
    /// `harness · model[ · effort]` sub-line.
    var subLine: String
    /// Cost, or `nil` when the catalog is absent.
    var cost: String?
    /// Show the quiet ⓘ "does not report live model" hint — every non-claude-code
    /// harness (design §8.4: only claude-code reports live).
    var showLiveHint: Bool
    /// Harness display name for the ⓘ tooltip.
    var harnessDisplayName: String
    /// Installed on PATH (dims the row when false).
    var isInstalled: Bool
}

/// The full rendered content of the popover, independent of keyboard selection.
struct AgentPickerContent: Equatable {
    var shortlist: [AgentPickerRow]
    var recent: AgentPickerRecentRow?
    /// `follow-recent` mode is on (header shows "◉ following recent", footer checkbox on).
    var followRecent: Bool
    /// Inline "N% Model · M launches" headline on the Launch-stats row, or `nil`
    /// when the stats store is unavailable / empty (degrade).
    var statsHeadline: String?
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
    /// Flip the default's follow-recent mode.
    case toggleFollowRecent
    /// Open the tier-2 configure sheet (C11-182 seam).
    case viewAll
    /// Open the stats view (C11-182 seam).
    case stats
    /// Dismiss the popover.
    case close
    /// No-op (e.g. a number key past the shortlist, or a plain launch of a
    /// not-installed harness — the caller may surface the shell-error hint).
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
    /// "Now" for relative-time formatting (injectable for deterministic tests).
    var now: Date
    /// Inline stats headline, precomputed by the caller from `AgentLaunchStatsStore`
    /// (kept out of the pure model so it stays store-free). `nil` = omit.
    var statsHeadline: String?
}

/// The keyboard-navigable picker state. Value type: the view holds it in `@State`
/// and calls `handleKey`; arrows mutate `selectedIndex`, actions are returned.
struct AgentPickerModel {
    /// Shortlist configs in library `order` (the launch/pin targets, 1–9).
    let configs: [SavedAgentConfig]
    /// The recent launch's resolved config, if any (nav index == configs.count).
    let recentConfig: SavedAgentConfig?
    /// What ⏎ launches when nothing is keyboard-selected (design §5.1).
    let effectiveDefault: SavedAgentConfig
    /// Precomputed render content.
    let content: AgentPickerContent

    /// -1 = nothing focused (open state); 0..<configs.count = a shortlist row;
    /// configs.count = the recent row.
    var selectedIndex: Int = -1

    // MARK: Build

    init(library: AgentConfigLibraryFile, effectiveDefault: SavedAgentConfig, env: AgentPickerEnvironment) {
        // Sort defensively by `order` so 1–9 badges are stable even if the on-disk
        // array ever drifts from `order` (self-review F8).
        let sorted = library.configs.sorted { $0.order < $1.order }
        self.configs = sorted
        self.effectiveDefault = effectiveDefault

        let followRecent = library.default.mode == .followRecent
        let pinnedId = library.default.mode == .pinned ? library.default.configId : nil
        let recentCfgId = library.recent?.configId

        var rows: [AgentPickerRow] = []
        for (i, cfg) in sorted.enumerated() {
            let isPinned = pinnedId == cfg.id
            let isRecentDefault = followRecent && recentCfgId != nil && recentCfgId == cfg.id
            rows.append(
                AgentPickerRow(
                    config: cfg,
                    name: cfg.name,
                    subLine: Self.subLine(for: cfg.config, env: env),
                    effortChip: AgentPickerModel.nonEmpty(cfg.config.effort),
                    sysChip: Self.sysChip(for: cfg.config.systemPrompt),
                    cost: Self.costString(cfg.config.model, env: env),
                    keyBadge: i + 1,
                    isPinnedDefault: isPinned,
                    isRecentDefault: isRecentDefault,
                    isInstalled: env.isInstalled(cfg.config.harness)
                )
            )
        }
        self.content = AgentPickerContent(
            shortlist: rows,
            recent: Self.recentRow(from: library.recent, configs: sorted, env: env),
            followRecent: followRecent,
            statsHeadline: env.statsHeadline
        )
        // The recent nav target is the resolved saved config (ad-hoc = nil).
        if let rid = recentCfgId, let match = sorted.first(where: { $0.id == rid }) {
            self.recentConfig = match
        } else {
            self.recentConfig = nil
        }
    }

    // MARK: Keyboard state machine

    /// Whether the recent row participates in ↑↓ navigation.
    private var hasRecent: Bool { content.recent != nil }

    /// The highest valid nav index (recent row is one past the shortlist).
    private var maxIndex: Int { configs.count - 1 + (hasRecent ? 1 : 0) }

    /// The config currently focused, or `nil` when nothing is (index -1) or the
    /// recent row (handled separately).
    private var selectedConfig: SavedAgentConfig? {
        guard selectedIndex >= 0, selectedIndex < configs.count else { return nil }
        return configs[selectedIndex]
    }

    /// Apply a key. Arrows mutate `selectedIndex` and return `.none`; everything
    /// else resolves to a `PickerAction`. `option` = the ⌥ modifier (⌥⏎ = pin).
    mutating func handleKey(_ key: PickerKey, option: Bool = false) -> PickerAction {
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
            // Recent row focused → launch the recent config.
            if hasRecent, selectedIndex == configs.count {
                if let rc = recentConfig { return .launch(rc) }
                return .none
            }
            // A shortlist row focused → pin (⌥) or launch it.
            if let cfg = selectedConfig {
                return option ? .pin(cfg) : launchOrNoop(cfg)
            }
            // Nothing focused → act on the effective default (⌥ pins it if it is a
            // real saved config; a transient effective default can't be pinned).
            if option {
                return effectiveDefault.id.isEmpty ? .none : .pin(effectiveDefault)
            }
            return .launch(effectiveDefault)
        }
    }

    /// Launch iff installed; a plain launch of a not-installed harness is a no-op
    /// the caller may turn into the "not installed" hint. Pin paths bypass this.
    private func launchOrNoop(_ cfg: SavedAgentConfig) -> PickerAction {
        if content.shortlist.first(where: { $0.config.id == cfg.id })?.isInstalled == false {
            return .none
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
        guard let m = nonEmpty(model) else { return "inherit" }
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
        case "opencode", "pi", "omp": return "router"
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

    static func recentRow(from recent: RecentAgentConfig?, configs: [SavedAgentConfig], env: AgentPickerEnvironment) -> AgentPickerRecentRow? {
        guard let recent, let harness = nonEmpty(recent.harness) else { return nil }
        let cfg = recent.configId.flatMap { id in configs.first(where: { $0.id == id }) }
        var subParts = [env.displayName(harness).lowercased(), modelLabel(recent.model)]
        if let effort = nonEmpty(recent.effort) { subParts.append(effort) }
        return AgentPickerRecentRow(
            config: cfg,
            name: cfg?.name ?? String(localized: "agentPicker.recent.adhoc", defaultValue: "Ad-hoc"),
            relativeTime: relativeTime(from: recent.observedAt, now: env.now),
            subLine: subParts.joined(separator: " · "),
            cost: costString(recent.model, env: env),
            showLiveHint: harness != AgentType.claudeCode.rawValue,
            harnessDisplayName: env.displayName(harness),
            isInstalled: env.isInstalled(harness)
        )
    }

    /// "just now" (<45s) · "Nm ago" (<60m) · "Nh ago" (<24h) · "Nd ago". `nil`
    /// observation → "just now".
    static func relativeTime(from date: Date?, now: Date) -> String {
        guard let date else { return String(localized: "agentPicker.recent.justNow", defaultValue: "just now") }
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 45 { return String(localized: "agentPicker.recent.justNow", defaultValue: "just now") }
        if secs < 3600 {
            let m = Int((secs / 60).rounded())
            return String(localized: "agentPicker.recent.minutesAgo", defaultValue: "\(m)m ago")
        }
        if secs < 86_400 {
            let h = Int((secs / 3600).rounded())
            return String(localized: "agentPicker.recent.hoursAgo", defaultValue: "\(h)h ago")
        }
        let d = Int((secs / 86_400).rounded())
        return String(localized: "agentPicker.recent.daysAgo", defaultValue: "\(d)d ago")
    }
}
