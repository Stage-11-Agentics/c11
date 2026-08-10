import Foundation

// MARK: - Agent-config editor model (C11-182, re-shaped by C11-203 Part C/E)
//
// Pure, view-model-free logic for the Saved Configs editor (tier 2 of the
// model picker). Everything here derives from `AgentRegistry.shared` (the
// manifest source of truth) plus the live model catalog (`ModelCatalogStore`,
// Part D); nothing touches SwiftUI, AppKit, or `NSApp`, so it is unit-tested
// directly in `c11-logic` with a stub catalog.
//
// **The axes are provider-first: Provider → Model → Effort → Harness.** Pick
// the brain, pick how hard it thinks, then decide which shell runs it. Harness
// is the last question, and it is filtered by what can actually serve the
// chosen model (Part C2), so the cross-product stays reachable — an Anthropic
// model inside opencode is legitimate, it just is not the default.
//
// Provider is editor-only state: `agent-configs.json` stores harness/model and
// nothing else, so provider is derived from the recipe on load
// (`derivedProvider`) and carried in `AgentConfigAxisSelection` while editing.

// MARK: Axis descriptors

/// How the effort control renders for a harness, as the manifest declares it.
/// Intersected with the *model's* published levels by `effortOptions`.
enum EffortAxis: Equatable {
    /// The harness declares no effort flag (grok/kimi/opencode/copilot/custom).
    /// Kimi still has an effort axis — it rides the environment, not a flag —
    /// so `.none` here is not the same as "no effort control"; see
    /// `effortOptions`.
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

// MARK: - Catalog seam

/// What the editor needs from the model catalog, on top of the Part D
/// `ModelCatalogProviding` contract. `ModelCatalogStore` already implements
/// every member; declaring the wider protocol here (rather than widening Part
/// D's) keeps the catalog module's contract narrow and still lets the editor's
/// tests inject a stub that never shells out.
protocol EditorModelCatalog: ModelCatalogProviding {
    /// Substring search over id and display name, prefix matches first.
    func search(_ query: String, provider: String?, limit: Int) -> [CatalogModel]
    /// The exact value to hand `harness`'s model flag — **not** `model.id`,
    /// which is harness-independent and wrong for opencode (`provider/model`).
    func modelFlagValue(for model: CatalogModel, harness: String) -> String
    /// What `harness` publishes about this model's effort levels.
    func effortSupport(for model: CatalogModel, harness: String) -> ModelEffortSupport
    /// The level the harness itself picks for this model when the operator
    /// does not. Codex defaults Sol to `low` and Terra to `medium`.
    func publishedDefaultEffort(for model: CatalogModel, harness: String) -> String?
    /// The model the publisher says to move to, for one it is deprecating.
    func publishedUpgradeTarget(for model: CatalogModel) -> String?
    /// The publisher's own deprecation copy, which beats anything c11 would
    /// compose. Shown as the row's tooltip.
    func publishedUpgradeNote(for model: CatalogModel) -> String?
    /// Direct lookup by canonical identity.
    func model(provider: String, id: String) -> CatalogModel?
}

extension ModelCatalogStore: EditorModelCatalog {
    // The index answers both; the store surfaces them under editor-facing
    // names so the catalog module keeps its own naming freedom.
    func publishedDefaultEffort(for model: CatalogModel, harness: String) -> String? {
        index.defaultEffort(for: model, harness: harness)
    }

    func publishedUpgradeTarget(for model: CatalogModel) -> String? {
        index.upgradeTarget(for: model)
    }

    func publishedUpgradeNote(for model: CatalogModel) -> String? {
        index.upgradeNote(for: model)
    }
}

// MARK: - Axis selection

/// The four-axis state the editor edits: the chosen provider plus the recipe.
///
/// `provider` is `nil` for the "Inherit" row — no provider chosen, the harness
/// launches whatever its own config selects. That row is also the escape hatch
/// to the harnesses no catalog enumerates (Custom, GitHub Copilot): with no
/// model pinned, every harness can serve the recipe.
struct AgentConfigAxisSelection: Equatable {
    var provider: String?
    var config: AgentLaunchConfig

    init(provider: String? = nil, config: AgentLaunchConfig) {
        self.provider = provider
        self.config = config
    }
}

/// Why a draft may not be saved (C11-203 C4).
enum AgentConfigSaveRefusal: Equatable {
    /// A Custom-harness recipe with no command of its own. `custom` carries no
    /// factory command, so this resolves to an empty shell command and can
    /// never launch — the exact state that left the A button silently dead.
    case customCommandEmpty

    /// One operator-facing sentence: what is wrong, and the next move.
    var message: String {
        switch self {
        case .customCommandEmpty:
            return String(
                localized: "agentConfigEditor.refusal.customCommandEmpty",
                defaultValue: "A Custom config needs a launch command — open Advanced and give it one, or pick a harness that ships its own."
            )
        }
    }
}

/// Namespace of pure derivations over the agent registry + the model catalog.
enum AgentConfigAxes {

    /// The harness whose effort is delivered through the launch environment
    /// rather than a CLI flag (C11-203 E2).
    static let kimiHarnessKey = "kimi"

    /// The variable the kimi binary reads for its reasoning effort. c11 injects
    /// it into the launch environment via `AgentLaunchConfig.env`; it is never
    /// written to `~/.kimi-code/` (CLAUDE.md: c11 does not write tenant config).
    static let kimiEffortEnvKey = "KIMI_MODEL_THINKING_EFFORT"

    // MARK: Provider axis (Part C1)

    /// The provider control's two tiers: the providers worth a card, and the
    /// long tail behind a menu.
    ///
    /// `prominent` is `ModelCatalogProviders.leadingOrder` intersected with the
    /// catalog, so it stays around a dozen entries no matter how large the
    /// catalog grows (today: 628 models across 57 providers, forty of which
    /// publish five models or fewer). A provider the recipe already names is
    /// promoted into `prominent` so the current selection is always visible.
    static func providerOptions(
        selected: String?,
        catalog: ModelCatalogProviding
    ) -> (prominent: [String], overflow: [String]) {
        let all = catalog.providers()
        var prominent = ModelCatalogProviders.leadingOrder.filter(all.contains)
        if let selected, all.contains(selected), !prominent.contains(selected) {
            prominent.append(selected)
        }
        let overflow = all.filter { !prominent.contains($0) }
        return (prominent, overflow)
    }

    /// The provider a stored recipe belongs to, for seeding the editor when a
    /// saved config is selected. `nil` when the recipe pins no model (the
    /// Inherit row) or names a model no catalog knows.
    static func derivedProvider(for config: AgentLaunchConfig, catalog: EditorModelCatalog) -> String? {
        resolveCatalogModel(config.model, harness: config.harness, providerHint: nil, catalog: catalog)?.provider
    }

    // MARK: Model axis (Part C, sourced from the live catalog)

    /// The models offered for the current provider, filtered by `query`.
    ///
    /// Search is not a nicety here: OpenAI alone publishes 176 models through
    /// the five catalogs, so an unfiltered list is unusable. An empty query
    /// returns the provider's models in catalog order.
    static func modelOptions(
        provider: String?,
        query: String,
        catalog: EditorModelCatalog,
        limit: Int = 200
    ) -> [CatalogModel] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard let provider else {
            // No provider chosen: only a query can produce a sensible list —
            // otherwise the Inherit row is the whole control.
            return needle.isEmpty ? [] : catalog.search(needle, provider: nil, limit: limit)
        }
        if needle.isEmpty {
            return Array(catalog.models(forProvider: provider).prefix(limit))
        }
        return catalog.search(needle, provider: provider, limit: limit)
    }

    /// The catalog model a selection currently names, or `nil` for Inherit.
    static func resolvedModel(
        for selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> CatalogModel? {
        resolveCatalogModel(
            selection.config.model,
            harness: selection.config.harness,
            providerHint: selection.provider,
            catalog: catalog
        )
    }

    /// Reverse-resolve a stored model string back to its catalog row.
    ///
    /// The stored value is whatever the recipe's harness takes for its model
    /// flag, so it may be a bare id (`opus`, `k3`), a namespaced one
    /// (`openai/gpt-5.6-sol` for opencode), or a spelling only one harness
    /// uses. Cheap paths first (the provider hint, then the namespace split);
    /// the full scan is the last resort and only runs when a config is
    /// selected, never on a render pass.
    static func resolveCatalogModel(
        _ raw: String?,
        harness: String,
        providerHint: String?,
        catalog: EditorModelCatalog
    ) -> CatalogModel? {
        guard let raw, !raw.isEmpty else { return nil }
        if let providerHint,
           let hit = catalog.models(forProvider: providerHint).first(where: { matches($0, raw: raw, harness: harness, catalog: catalog) }) {
            return hit
        }
        let (provider, id) = ModelCatalogIdentity.split(rawID: raw, providerHint: "")
        if let hit = catalog.model(provider: provider, id: id) { return hit }
        for provider in catalog.providers() {
            if let hit = catalog.models(forProvider: provider).first(where: {
                matches($0, raw: raw, harness: harness, catalog: catalog)
            }) {
                return hit
            }
        }
        return nil
    }

    private static func matches(
        _ model: CatalogModel,
        raw: String,
        harness: String,
        catalog: EditorModelCatalog
    ) -> Bool {
        model.id == raw || catalog.modelFlagValue(for: model, harness: harness) == raw
    }

    // MARK: Harness axis (Part C2)

    /// The harnesses offered for the current selection, default (top-line)
    /// first.
    ///
    /// With a model pinned this is the catalog's evidence-based answer — only
    /// harnesses that actually published the model, so a pair the picker offers
    /// can always launch. With no model pinned every harness is reachable,
    /// which is how Custom and any harness that publishes no catalog stay
    /// selectable.
    static func harnessOptions(
        for selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> [String] {
        guard let model = resolvedModel(for: selection, catalog: catalog) else {
            return AgentType.allCases.map(\.rawValue)
        }
        let served = catalog.harnesses(forModel: model)
        return served.isEmpty ? [model.harness] : served
    }

    // MARK: Effort axis (Part E1)

    /// The manifest's own effort shape for a harness.
    static func effortAxis(forHarness harness: String) -> EffortAxis {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harness),
              manifest.launch.effortArg != nil else {
            return .none
        }
        let values = manifest.launch.effortValues
        return values.isEmpty ? .passthrough : .tiers(values)
    }

    /// The effort values the current (model, harness) pair accepts, or `nil`
    /// when the pair has no effort control at all and the row must not render.
    ///
    /// Two sources, and the order matters:
    ///
    /// 1. **What the harness publishes for this model.** Asked per pair via
    ///    `effortSupport(for:harness:)`, never read off
    ///    `CatalogModel.supportedEfforts` — that field carries the *default*
    ///    harness's answer, and the harnesses disagree. omp claims
    ///    `minimal,low,medium,high` for `kimi-for-coding` because omp's own
    ///    `--thinking` can slice it; kimi publishes nothing for the same model
    ///    because it is `always_thinking`. Under the kimi harness the operator
    ///    must see no control; under omp they must see four levels.
    /// 2. **What the manifest declares for the harness.**
    ///
    /// Where the manifest declares a **closed tier set** (`.tiers`, i.e.
    /// claude-code/pi/omp) the intersection wins: `AgentLaunchPlanner` rejects
    /// an effort outside that set, so offering one would only produce a launch
    /// that fails. Where the manifest is **passthrough** (codex, whose CLI
    /// validates the value itself) the model's ladder wins outright — the
    /// publisher knows and c11 is guessing. That difference matters: codex
    /// ladders run past c11's own vocabulary (Sol, Sol-WM and Terra all accept
    /// `ultra`; Luna caps at `max`; the 5.x line caps at `xhigh`), and a
    /// hardcoded suggestion list would under-offer every one of them.
    ///
    /// `.none` from the catalog is an explicit "this model has no effort
    /// control" and short-circuits everything: it is why Kimi's K2.7 aliases
    /// render no control while its K3 aliases render low/high/max.
    static func effortOptions(
        for selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> [String]? {
        let harness = selection.config.harness
        let manifestAxis = effortAxis(forHarness: harness)
        let published = resolvedModel(for: selection, catalog: catalog)
            .map { catalog.effortSupport(for: $0, harness: harness) } ?? .unspecified

        if case .none = published { return nil }

        if case .values(let declared) = published {
            switch manifestAxis {
            case .tiers(let tiers):
                let intersection = tiers.filter(declared.contains)
                return nonEmpty(intersection.isEmpty ? tiers : intersection)
            case .passthrough:
                return nonEmpty(declared)
            case .none:
                // No effort *flag*, but kimi delivers effort through the launch
                // environment (E2), so its published levels are still offerable.
                return harness == kimiHarnessKey ? nonEmpty(declared) : nil
            }
        }

        switch manifestAxis {
        case .tiers(let tiers): return nonEmpty(tiers)
        case .passthrough:      return nonEmpty(passthroughEffortSuggestions(forHarness: harness))
        case .none:             return nil
        }
    }

    private static func nonEmpty(_ values: [String]) -> [String]? {
        values.isEmpty ? nil : values
    }

    /// Suggestions for a passthrough effort flag when **no model is pinned**,
    /// so there is no published ladder to read. Deliberately conservative: with
    /// the model unknown the top of the ladder is unknown too (Sol goes to
    /// `ultra`, Luna stops at `max`, the 5.x line stops at `xhigh`), and
    /// offering a level the chosen model rejects would be a launch that fails.
    /// The value is stored free-form, so anything codex accepts stays reachable
    /// from `c11 config`.
    private static func passthroughEffortSuggestions(forHarness harness: String) -> [String] {
        switch harness {
        case "codex": return ["low", "medium", "high", "xhigh"]
        default:      return []
        }
    }

    /// What "inherit" actually resolves to for the current pair, for the label
    /// beside the inherit chip — the harness's Settings effort when the
    /// operator pinned one, otherwise the level the publisher says this model
    /// runs at (codex: Sol `low`, Terra `medium`; kimi: both K3 aliases
    /// `high`). `nil` when nothing is known.
    ///
    /// Deliberately a *label*, never a seed. Writing the default into the
    /// recipe would turn every new config into an explicit override and break
    /// the nil=inherit contract the whole overlay ladder rests on (C11-179).
    static func inheritedEffortLabel(
        for selection: AgentConfigAxisSelection,
        from base: DefaultAgentConfig,
        catalog: EditorModelCatalog
    ) -> String? {
        if let agent = AgentType(rawValue: selection.config.harness) {
            let settings = base.config(for: agent).effort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !settings.isEmpty { return settings }
        }
        guard let model = resolvedModel(for: selection, catalog: catalog) else { return nil }
        return catalog.publishedDefaultEffort(for: model, harness: selection.config.harness)
    }

    // MARK: System-prompt axis (derived from the manifest)

    static func systemPromptAxis(forHarness harness: String) -> SystemPromptAxis {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harness),
              let arg = manifest.launch.systemPromptArg else {
            return .none
        }
        return .supported(appendFlag: arg.appendFlag, replaceFlag: arg.replaceFlag)
    }

    /// Whether the harness takes a model flag at all. `custom` does not: it
    /// launches exactly the command line the operator wrote.
    static func acceptsModel(forHarness harness: String) -> Bool {
        AgentRegistry.shared.manifest(forKind: harness)?.launch.modelArg != nil
    }

    // MARK: Provider-first cascade (Part C3)

    /// Choose a provider. Downward cascade: the model is invalidated (it
    /// belonged to the old provider), the harness snaps to the provider's Part
    /// C default so the common path needs no second click, and the effort and
    /// system prompt are reconciled against whatever survived.
    ///
    /// The Inherit row (`provider == nil`) is deliberately gentler: it drops
    /// the model but keeps the harness, because choosing it *is* the operator
    /// going harness-first on purpose (Custom, or a copilot-style harness no
    /// catalog enumerates).
    static func selectingProvider(
        _ provider: String?,
        in selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> AgentConfigAxisSelection {
        var next = selection
        next.provider = provider
        next.config.model = nil
        if let provider {
            next.config.harness = ModelCatalogHarnesses.partCDefault(forProvider: provider)
        }
        return reconciled(next, from: selection, catalog: catalog)
    }

    /// Choose a model. The harness is re-filtered: the current one survives if
    /// it can serve the model, otherwise the model's default (top-line) harness
    /// is auto-selected. The stored value is always the *chosen harness's* flag
    /// spelling, never the harness-independent `CatalogModel.id`.
    static func selectingModel(
        _ model: CatalogModel?,
        in selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> AgentConfigAxisSelection {
        var next = selection
        guard let model else {
            next.config.model = nil
            return reconciled(next, from: selection, catalog: catalog)
        }
        guard !model.isComingSoon else { return selection }

        next.provider = model.provider
        let served = catalog.harnesses(forModel: model)
        let harness = served.contains(selection.config.harness)
            ? selection.config.harness
            : (served.first ?? model.harness)
        next.config.harness = harness
        next.config.model = catalog.modelFlagValue(for: model, harness: harness)
        return reconciled(next, from: selection, catalog: catalog)
    }

    /// Choose a harness. The model is re-spelled for the new harness's flag; a
    /// harness that cannot serve the model (Custom, which takes no model flag
    /// at all) drops it rather than carrying a value that would never launch.
    static func selectingHarness(
        _ harness: String,
        in selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> AgentConfigAxisSelection {
        var next = selection
        next.config.harness = harness
        if let model = resolvedModel(for: selection, catalog: catalog) {
            let served = catalog.harnesses(forModel: model)
            next.config.model = (served.contains(harness) && acceptsModel(forHarness: harness))
                ? catalog.modelFlagValue(for: model, harness: harness)
                : nil
        } else if !acceptsModel(forHarness: harness) {
            next.config.model = nil
        }
        return reconciled(next, from: selection, catalog: catalog)
    }

    /// Choose an effort (`nil` = inherit the harness's own).
    static func selectingEffort(
        _ effort: String?,
        in selection: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> AgentConfigAxisSelection {
        var next = selection
        next.config.effort = effort
        next.config = applyingEffortDelivery(next.config)
        return next
    }

    /// The shared downward pass every axis change ends with: drop an effort the
    /// new pair cannot express, drop a system prompt the new harness has no
    /// flag for, and re-apply the environment-delivered effort.
    ///
    /// `previous` is only consulted for the harness comparison — the
    /// system-prompt drop is a harness-change consequence, not something to
    /// re-evaluate on every model click.
    private static func reconciled(
        _ selection: AgentConfigAxisSelection,
        from previous: AgentConfigAxisSelection,
        catalog: EditorModelCatalog
    ) -> AgentConfigAxisSelection {
        var next = selection

        if let effort = next.config.effort {
            let allowed = effortOptions(for: next, catalog: catalog)
            if allowed == nil || !(allowed?.contains(effort) ?? false) { next.config.effort = nil }
        }

        if next.config.harness != previous.config.harness,
           case .none = systemPromptAxis(forHarness: next.config.harness) {
            // Leave a supported harness's `nil` alone: nil is the true
            // "inherit" (C11-179), and seeding an explicit `.inherit` here
            // would clobber a configured base system prompt via mergeOverlay.
            next.config.systemPrompt = nil
        }

        next.config = applyingEffortDelivery(next.config)
        return next
    }

    // MARK: Environment-delivered effort (Part E2)

    /// Deliver a kimi effort through the launch environment.
    ///
    /// The kimi CLI has no effort flag, but the binary reads
    /// `KIMI_MODEL_THINKING_EFFORT`, and `AgentLaunchConfig.env` already flows
    /// to `ResolvedAgentLaunch.envOverrides` at spawn
    /// (`DefaultAgentResolver.mergeOverlay`). Writing the variable into the
    /// recipe's env overlay is therefore the whole delivery path — and it shows
    /// up in the editor's Advanced env box, so the operator can see what will
    /// actually be exported.
    ///
    /// The effort axis owns the key outright: it is written when the recipe is
    /// on kimi with an effort set, and removed in every other case, so
    /// switching harness or falling back to "inherit" can never leave a stale
    /// override exported into the next launch. Idempotent, so it is safe to run
    /// on every axis change and again at save.
    static func applyingEffortDelivery(_ config: AgentLaunchConfig) -> AgentLaunchConfig {
        var c = config
        var env = c.env ?? [:]
        let onKimi = c.harness == kimiHarnessKey
        let effort = c.effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if onKimi, !effort.isEmpty {
            env[kimiEffortEnvKey] = effort
        } else {
            // Off kimi the variable is meaningless, and on kimi an unset effort
            // means "inherit"; either way a previously-injected value must not
            // survive as a stale override.
            env.removeValue(forKey: kimiEffortEnvKey)
        }
        c.env = env.isEmpty ? nil : env
        return c
    }

    // MARK: Save guard (Part C4)

    /// Why this recipe may not be saved, or `nil` when it may.
    ///
    /// Custom with no command is the write-side half of the A-button outage:
    /// the read side now heals a drifted factory seed and refuses to pin an
    /// unlaunchable config (`AgentConfigLibraryStore`), but nothing stopped the
    /// editor from writing `{harness: "custom", model: nil, command: nil}` over
    /// a working recipe in the first place. Same predicate as the store's
    /// `isProvablyUnlaunchable`, so the two verdicts cannot drift.
    static func saveRefusal(for config: AgentLaunchConfig) -> AgentConfigSaveRefusal? {
        config.isProvablyUnlaunchable ? .customCommandEmpty : nil
    }

    /// Normalize a recipe for persistence so it faithfully round-trips the
    /// nil=inherit contract: an explicit `.inherit` system-prompt setting (a
    /// transient editor working state) collapses to `nil`, so a saved "inherit"
    /// config never overrides a configured base system prompt at launch. The
    /// environment-delivered effort is re-applied here too, so a recipe written
    /// by any path (editor, `c11 config`) carries the same env overlay.
    static func normalizedForPersistence(_ config: AgentLaunchConfig) -> AgentLaunchConfig {
        var c = config
        if c.systemPrompt?.mode == .inherit { c.systemPrompt = nil }
        return applyingEffortDelivery(c)
    }

    // MARK: Naming + description (prototype autoName / describe)

    /// The short model label: `nil` model → "inherit"; a `provider/model` id →
    /// its suffix; otherwise the raw model string.
    static func modelLabel(_ config: AgentLaunchConfig) -> String {
        guard let m = config.model, !m.isEmpty else { return "inherit" }
        if let slash = m.lastIndex(of: "/") { return String(m[m.index(after: slash)...]) }
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

    /// The model a claude-code recipe inherits when its model is unset — the
    /// harness's per-harness Settings base, defaulting to `opus` (matching the
    /// factory pin). `nil` when there is no base. Pure: the base config is
    /// injected so this is unit-testable.
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
