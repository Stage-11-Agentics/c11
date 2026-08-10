import Foundation

// MARK: - Model catalog: core types and merge (C11-203 Part D)
//
// The launch picker's Provider → Model → Effort → Harness axes read from this
// catalog. Nothing here is a hand-maintained model list: every entry either
// came out of a harness CLI that enumerates its own catalog (`opencode models`,
// `pi --list-models`, `omp models`, `kimi provider list --json`, `grok models`)
// or is a *declared* entry for a harness that has no enumeration command at all
// (Claude Code's four families, Codex's GPT-5.6 variants).
//
// The pipeline is one-way and has a single merge implementation, so live
// enumeration, the on-disk cache, and the compiled snapshot all produce the
// same shape:
//
//     [RawCatalogRecord]  →  ModelCatalogBuilder.build  →  ModelCatalogIndex
//
// A `RawCatalogRecord` is deliberately *pre-canonical*: it is one row exactly
// as one harness published it, including that harness's own model-flag spelling
// (`openrouter/~anthropic/claude-fable-latest` for pi, `k3` for kimi). Merging
// happens once, in `ModelCatalogBuilder`, so a future harness only needs a
// parser, not new merge rules.
//
// This file is Foundation-only and is a member of both the app and the CLI
// targets: no AppKit, no SwiftUI, no `AgentRegistry`.

// MARK: - Effort support

/// What a harness publishes about a model's reasoning-effort levels.
///
/// The distinction between `.unspecified` and `.none` is load-bearing. Kimi's
/// `provider list --json` carries `supportEfforts` on the two K3 aliases and
/// omits it on the two K2.7 aliases, which are `always_thinking`: K3 is
/// `.values(["low", "high", "max"])` and K2.7 is `.none` — an explicit "this
/// model has no effort control", not "we don't know". Collapsing both to an
/// empty array would let K2.7 inherit the harness-level effort values and
/// render a dead control.
enum ModelEffortSupport: Equatable {
    /// The harness publishes nothing; fall back to the harness's own values.
    case unspecified
    /// The harness publishes that this model has no effort levels.
    case none
    /// The harness publishes an explicit level set.
    case values([String])

    /// The level set, or `[]` for both `.unspecified` and `.none`. This is what
    /// `CatalogModel.supportedEfforts` carries, per the Part D contract
    /// ("empty = fall back to the harness's own effort values").
    var levels: [String] {
        if case .values(let v) = self { return v }
        return []
    }

    /// Encoded form used by both the compiled snapshot and the disk cache.
    fileprivate var encoded: String {
        switch self {
        case .unspecified: return "-"
        case .none:        return "0"
        case .values(let v): return v.joined(separator: ",")
        }
    }

    fileprivate static func decode(_ field: String) -> ModelEffortSupport {
        switch field {
        case "-", "":  return .unspecified
        case "0":      return .none
        default:
            let v = field.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
            return v.isEmpty ? .unspecified : .values(v)
        }
    }
}

// MARK: - Raw record

/// One model row exactly as one harness published it.
///
/// `rawID` is the value that harness's model flag takes — `k3` for kimi's
/// `-m`, `openai/gpt-5.6-sol` for opencode's `-m`, `gpt-5.6-sol` for codex's
/// `--model`. It is *not* comparable across harnesses; the canonical, harness
/// independent identity is derived in `ModelCatalogBuilder`.
struct RawCatalogRecord: Equatable, Codable {
    /// The harness that published (or declares) this row.
    var harness: String
    /// The exact value for that harness's model flag.
    var rawID: String
    /// Publisher-supplied display name, `""` when the harness publishes none.
    var displayName: String
    /// Context window in tokens. Exact where the harness publishes a number
    /// (kimi); approximate where it publishes an abbreviation (`262.1K`).
    var contextWindow: Int?
    /// What this harness says about the model's effort levels.
    var efforts: ModelEffortSupport
    /// The level this harness picks when the operator does not, `""` when the
    /// harness publishes none. Kimi and Codex both publish one, and they differ
    /// per model (Codex defaults Sol to `low` and Terra to `medium`).
    var defaultEffort: String
    /// Declared-but-unreleased (Codex's Astra). Dimmed, non-selectable.
    var isComingSoon: Bool
    /// The model the publisher says to move to, `""` when not deprecated.
    /// Codex ships this on `gpt-5.4` and `gpt-5.4-mini`.
    var upgradeTo: String
    /// The publisher's own deprecation copy, `""` when there is none. Vendor
    /// prose beats anything c11 would compose.
    var upgradeNote: String
    /// Where the publisher ranks this model in its own catalog, lower first.
    /// `nil` when the publisher does not rank. Today only codex publishes one
    /// (`priority`), but the column is source-agnostic: any parser can fill it
    /// and ranked models will float above unranked ones within their provider.
    var publisherRank: Int?
    /// Provider for rows whose `rawID` carries no namespace (`k3`, `opus`).
    /// Ignored when `rawID` is namespaced.
    var providerHint: String

    init(
        harness: String,
        rawID: String,
        displayName: String = "",
        contextWindow: Int? = nil,
        efforts: ModelEffortSupport = .unspecified,
        defaultEffort: String = "",
        isComingSoon: Bool = false,
        upgradeTo: String = "",
        upgradeNote: String = "",
        publisherRank: Int? = nil,
        providerHint: String = ""
    ) {
        self.harness = harness
        self.rawID = rawID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.isComingSoon = isComingSoon
        self.upgradeTo = upgradeTo
        self.upgradeNote = upgradeNote
        self.publisherRank = publisherRank
        self.providerHint = providerHint
    }

    // Hand-rolled so a record survives a partial/older encoding rather than
    // failing the whole decode: a corrupt cache must degrade, never throw into
    // a picker-open path.
    enum CodingKeys: String, CodingKey {
        case harness, rawID, displayName, contextWindow, efforts, defaultEffort
        case isComingSoon, upgradeTo, upgradeNote, publisherRank, providerHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harness = try c.decode(String.self, forKey: .harness)
        rawID = try c.decode(String.self, forKey: .rawID)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        contextWindow = try? c.decodeIfPresent(Int.self, forKey: .contextWindow)
        efforts = ModelEffortSupport.decode((try? c.decode(String.self, forKey: .efforts)) ?? "-")
        defaultEffort = (try? c.decode(String.self, forKey: .defaultEffort)) ?? ""
        isComingSoon = (try? c.decode(Bool.self, forKey: .isComingSoon)) ?? false
        upgradeTo = (try? c.decode(String.self, forKey: .upgradeTo)) ?? ""
        upgradeNote = (try? c.decode(String.self, forKey: .upgradeNote)) ?? ""
        publisherRank = try? c.decodeIfPresent(Int.self, forKey: .publisherRank)
        providerHint = (try? c.decode(String.self, forKey: .providerHint)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(harness, forKey: .harness)
        try c.encode(rawID, forKey: .rawID)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encode(efforts.encoded, forKey: .efforts)
        try c.encode(defaultEffort, forKey: .defaultEffort)
        try c.encode(isComingSoon, forKey: .isComingSoon)
        try c.encode(upgradeTo, forKey: .upgradeTo)
        try c.encode(upgradeNote, forKey: .upgradeNote)
        try c.encodeIfPresent(publisherRank, forKey: .publisherRank)
        try c.encode(providerHint, forKey: .providerHint)
    }
}

// MARK: - Catalog model (the Part D contract type)

/// One model as the picker offers it, after every harness's rows for it have
/// been merged.
///
/// **`id` is harness-independent.** It is the bare model id with the provider
/// namespace stripped (`gpt-5.6-sol`, `k3`, `gemini-3-pro-preview`), which is
/// what makes "the same model seen by four harnesses" collapse to one row. It
/// is also the literal model-flag value for every *default* harness in Part C
/// (codex, claude-code, kimi, grok, and pi, which accepts a bare id). For any
/// other harness — notably opencode, which requires `provider/model` — ask
/// `ModelCatalogStore.modelFlagValue(for:harness:)` rather than passing `id`
/// through.
struct CatalogModel: Equatable, Codable {
    /// Harness-independent model id (see the note above).
    let id: String
    let displayName: String
    /// Canonical provider key: `openai`, `anthropic`, `moonshot`, `xai`, …
    let provider: String
    /// The default (top-line) harness for this model — the Part C harness for
    /// its provider when that harness can serve it, otherwise the first
    /// harness that can.
    let harness: String
    let contextWindow: Int?
    /// Effort levels published by `harness` for this model. Empty means "fall
    /// back to the harness's own effort values"; use
    /// `ModelCatalogStore.effortSupport(for:harness:)` to tell an empty list
    /// apart from an explicit "no effort control" (Kimi's K2.7 aliases).
    let supportedEfforts: [String]
    /// Declared but not yet live (Codex's Astra): dimmed, non-selectable.
    let isComingSoon: Bool
}

// MARK: - The Part D provider contract

protocol ModelCatalogProviding {
    /// Canonical provider keys that have at least one model, in display order.
    func providers() -> [String]
    /// Models for a provider, merged across harnesses and deduped by id.
    func models(forProvider provider: String) -> [CatalogModel]
    /// Harnesses that can serve this model, default (top-line) harness first.
    func harnesses(forModel model: CatalogModel) -> [String]
    /// Re-enumerate the harness CLIs off-main. `completion` runs on the main
    /// queue once the index has been swapped (or left alone, on failure).
    func refresh(completion: @escaping () -> Void)
}

// MARK: - Providers

/// Canonical provider keys, the aliases that map onto them, and display order.
enum ModelCatalogProviders {

    /// Canonicalize a raw namespace segment. Strips OpenRouter's `~` "latest
    /// alias" marker, lowercases, and folds the vendor spellings the five
    /// catalogs disagree about (`x-ai`/`xai`, `kimi`/`moonshotai`, …).
    static func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        while s.hasPrefix("~") { s.removeFirst() }
        switch s {
        case "openai", "azure", "azure-openai", "openai-chat":     return "openai"
        case "anthropic", "claude":                                return "anthropic"
        case "google", "google-vertex", "googleai", "gemini",
             "google-ai-studio", "vertex":                         return "google"
        case "kimi", "moonshot", "moonshotai", "moonshot-ai":      return "moonshot"
        case "x-ai", "xai":                                        return "xai"
        case "meta-llama", "meta", "llama":                        return "meta"
        case "mistralai", "mistral":                               return "mistral"
        case "z-ai", "zai", "zhipuai", "zhipu":                    return "zai"
        case "qwen", "alibaba", "qwen3":                           return "qwen"
        case "deepseek", "deepseek-ai":                            return "deepseek"
        case "":                                                   return "unknown"
        default:                                                   return s
        }
    }

    /// Providers we put at the head of the list, in this order. Everything else
    /// follows alphabetically, so a provider that appears in a future catalog
    /// still lands somewhere deterministic.
    static let leadingOrder: [String] = [
        "openai", "anthropic", "google", "moonshot", "xai",
        "deepseek", "qwen", "mistral", "meta", "zai", "opencode",
    ]

    static func sorted(_ providers: some Sequence<String>) -> [String] {
        let unique = Set(providers)
        let lead = leadingOrder.filter(unique.contains)
        let rest = unique.subtracting(lead).sorted()
        return lead + rest
    }

    /// Brand label for a canonical key. Not localized: these are proper nouns.
    static func displayName(_ canonicalKey: String) -> String {
        switch canonicalKey {
        case "openai":     return "OpenAI"
        case "anthropic":  return "Anthropic"
        case "google":     return "Google"
        case "moonshot":   return "Moonshot"
        case "xai":        return "xAI"
        case "deepseek":   return "DeepSeek"
        case "qwen":       return "Qwen"
        case "mistral":    return "Mistral"
        case "meta":       return "Meta"
        case "zai":        return "Z.ai"
        case "opencode":   return "OpenCode"
        case "openrouter": return "OpenRouter"
        case "unknown":    return "Other"
        default:
            return canonicalKey.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

// MARK: - Harness ordering (ticket Part C)

enum ModelCatalogHarnesses {

    /// Part C's "default (top-line) harness" column.
    static func partCDefault(forProvider provider: String) -> String {
        switch provider {
        case "openai":    return "codex"
        case "anthropic": return "claude-code"
        case "moonshot":  return "kimi"
        case "xai":       return "grok"
        default:          return "pi"
        }
    }

    /// Part C's "also available" column: the router harnesses, in the order the
    /// ticket lists them, minus whichever one is already the default.
    static let alternates: [String] = ["opencode", "pi", "omp"]

    /// Full Part C preference order for a provider.
    static func preferenceOrder(forProvider provider: String) -> [String] {
        let head = partCDefault(forProvider: provider)
        return [head] + alternates.filter { $0 != head }
    }

    /// Merge precedence when several harnesses describe the same model. The
    /// provider's own harness wins outright: omp publishes `--thinking` levels
    /// for `kimi-for-coding` because *omp* can thin-slice it, while kimi itself
    /// publishes none because the model is `always_thinking`. For a Moonshot
    /// model, kimi's answer is the one the picker must show.
    static func mergeRank(harness: String, provider: String) -> Int {
        if harness == partCDefault(forProvider: provider) { return 0 }
        switch harness {
        case "claude-code": return 1
        case "codex":       return 2
        case "grok":        return 3
        case "kimi":        return 4
        case "omp":         return 5
        case "pi":          return 6
        case "opencode":    return 7
        default:            return 8
        }
    }
}

// MARK: - Identity

enum ModelCatalogIdentity {

    /// Split a harness's raw model id into `(canonical provider, bare id)`.
    ///
    /// - `openrouter/<provider>/<model>` (opencode, pi, omp) flattens to the
    ///   real provider: OpenRouter is a gateway, not a model vendor, so a model
    ///   reached through it must land on the same provider row as the direct
    ///   one.
    /// - A leading `~` marks OpenRouter's floating "latest" aliases
    ///   (`~anthropic/claude-opus-latest`) and is not part of the provider.
    /// - A two-segment `openrouter/auto` keeps `openrouter` as its provider —
    ///   it really is an OpenRouter-owned pseudo-model.
    /// - An unnamespaced id (`k3`, `opus`, `grok-4.5`) takes `providerHint`.
    static func split(rawID: String, providerHint: String) -> (provider: String, id: String) {
        var segments = rawID.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count > 1 else {
            return (ModelCatalogProviders.canonical(providerHint), rawID)
        }
        if segments[0].lowercased() == "openrouter" && segments.count >= 3 {
            segments.removeFirst()
        }
        let provider = ModelCatalogProviders.canonical(segments.removeFirst())
        let id = segments.joined(separator: "/")
        guard !id.isEmpty else {
            return (ModelCatalogProviders.canonical(providerHint), rawID)
        }
        return (provider, id)
    }

    /// Index key for a canonical model. Uses a control character so no provider
    /// or model id can forge a collision.
    static func key(provider: String, id: String) -> String { provider + "\u{1}" + id }
}

// MARK: - The built index

/// An immutable, queryable catalog. Built once per record set; swapped
/// wholesale by the store so readers never see a half-updated catalog.
struct ModelCatalogIndex: Equatable {
    /// Where this index came from, for diagnostics.
    enum Source: String, Equatable { case snapshot, cache, live, empty }

    let source: Source
    let generatedAt: Date?
    let providers: [String]

    private let modelsByProvider: [String: [CatalogModel]]
    private let harnessesByKey: [String: [String]]
    private let flagValuesByKey: [String: [String: String]]
    private let effortsByKey: [String: [String: ModelEffortSupport]]
    private let defaultEffortsByKey: [String: [String: String]]
    private let upgradeByKey: [String: String]
    private let upgradeNoteByKey: [String: String]
    private let publisherRankByKey: [String: Int]

    static let empty = ModelCatalogIndex(
        source: .empty, generatedAt: nil, providers: [],
        modelsByProvider: [:], harnessesByKey: [:], flagValuesByKey: [:], effortsByKey: [:],
        defaultEffortsByKey: [:], upgradeByKey: [:], upgradeNoteByKey: [:], publisherRankByKey: [:]
    )

    fileprivate init(
        source: Source,
        generatedAt: Date?,
        providers: [String],
        modelsByProvider: [String: [CatalogModel]],
        harnessesByKey: [String: [String]],
        flagValuesByKey: [String: [String: String]],
        effortsByKey: [String: [String: ModelEffortSupport]],
        defaultEffortsByKey: [String: [String: String]],
        upgradeByKey: [String: String],
        upgradeNoteByKey: [String: String],
        publisherRankByKey: [String: Int]
    ) {
        self.source = source
        self.generatedAt = generatedAt
        self.providers = providers
        self.modelsByProvider = modelsByProvider
        self.harnessesByKey = harnessesByKey
        self.flagValuesByKey = flagValuesByKey
        self.effortsByKey = effortsByKey
        self.defaultEffortsByKey = defaultEffortsByKey
        self.upgradeByKey = upgradeByKey
        self.upgradeNoteByKey = upgradeNoteByKey
        self.publisherRankByKey = publisherRankByKey
    }

    var isEmpty: Bool { providers.isEmpty }

    var allModels: [CatalogModel] { providers.flatMap { modelsByProvider[$0] ?? [] } }

    func models(forProvider provider: String) -> [CatalogModel] {
        modelsByProvider[ModelCatalogProviders.canonical(provider)] ?? []
    }

    func harnesses(forModel model: CatalogModel) -> [String] {
        harnessesByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)] ?? [model.harness]
    }

    /// The exact value to hand `harness`'s model flag for this model, or `nil`
    /// when that harness never published it.
    func modelFlagValue(for model: CatalogModel, harness: String) -> String? {
        flagValuesByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]?[harness]
    }

    /// What `harness` publishes about this model's effort levels. `.unspecified`
    /// when the harness says nothing (or does not serve the model), so callers
    /// can fall back to the harness manifest's own values.
    func effortSupport(for model: CatalogModel, harness: String) -> ModelEffortSupport {
        effortsByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]?[harness] ?? .unspecified
    }

    /// The effort level `harness` itself picks for this model when the operator
    /// does not — Codex defaults Sol to `low` and Terra to `medium`, Kimi
    /// defaults both K3 aliases to `high`. `nil` when the harness publishes no
    /// default; the caller then falls back to the harness manifest.
    func defaultEffort(for model: CatalogModel, harness: String) -> String? {
        let value = defaultEffortsByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]?[harness]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// The model the publisher says to move to, for a model it is deprecating
    /// (`gpt-5.4` → `gpt-5.6-terra`). `nil` for everything current.
    func upgradeTarget(for model: CatalogModel) -> String? {
        let value = upgradeByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// The publisher's own deprecation copy, ready to show verbatim. `nil` when
    /// the model is current or the publisher wrote none.
    func upgradeNote(for model: CatalogModel) -> String? {
        let value = upgradeNoteByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Where the publisher ranks this model in its own catalog, lower first.
    /// `nil` when no source ranked it — those sort after every ranked model.
    func publisherRank(for model: CatalogModel) -> Int? {
        publisherRankByKey[ModelCatalogIdentity.key(provider: model.provider, id: model.id)]
    }

    func model(provider: String, id: String) -> CatalogModel? {
        let canonical = ModelCatalogProviders.canonical(provider)
        return modelsByProvider[canonical]?.first { $0.id == id }
    }
}

// MARK: - Builder

enum ModelCatalogBuilder {

    static func build(
        records: [RawCatalogRecord],
        source: ModelCatalogIndex.Source,
        generatedAt: Date? = nil
    ) -> ModelCatalogIndex {
        guard !records.isEmpty else { return .empty }

        // Group by canonical identity.
        var groups: [String: [RawCatalogRecord]] = [:]
        var identity: [String: (provider: String, id: String)] = [:]
        for record in records {
            let trimmed = record.rawID.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (provider, id) = ModelCatalogIdentity.split(rawID: trimmed, providerHint: record.providerHint)
            guard !id.isEmpty else { continue }
            let key = ModelCatalogIdentity.key(provider: provider, id: id)
            groups[key, default: []].append(record)
            identity[key] = (provider, id)
        }

        var modelsByProvider: [String: [CatalogModel]] = [:]
        var harnessesByKey: [String: [String]] = [:]
        var flagValuesByKey: [String: [String: String]] = [:]
        var effortsByKey: [String: [String: ModelEffortSupport]] = [:]
        var defaultEffortsByKey: [String: [String: String]] = [:]
        var upgradeByKey: [String: String] = [:]
        var upgradeNoteByKey: [String: String] = [:]
        var publisherRankByKey: [String: Int] = [:]

        for (key, rawGroup) in groups {
            guard let (provider, id) = identity[key] else { continue }

            let group = rawGroup.sorted {
                let l = ModelCatalogHarnesses.mergeRank(harness: $0.harness, provider: provider)
                let r = ModelCatalogHarnesses.mergeRank(harness: $1.harness, provider: provider)
                if l != r { return l < r }
                // Within a harness, its direct route to the provider beats its
                // OpenRouter route: same model, but the direct listing is the
                // one whose numbers and levels describe the harness's own path.
                let lg = isGatewayRoute($0.rawID), rg = isGatewayRoute($1.rawID)
                if lg != rg { return !lg }
                return $0.rawID < $1.rawID
            }

            // Per-harness flag value + effort declaration. When one harness
            // publishes the same model twice (opencode lists both
            // `openai/gpt-5.6-sol` and `openrouter/openai/gpt-5.6-sol`), keep
            // the shallower spelling: it is the direct route, not the gateway.
            var flagValues: [String: String] = [:]
            var efforts: [String: ModelEffortSupport] = [:]
            var defaultEfforts: [String: String] = [:]
            for record in group {
                let existing = flagValues[record.harness]
                if existing == nil || segmentCount(record.rawID) < segmentCount(existing!) {
                    flagValues[record.harness] = record.rawID
                }
                if efforts[record.harness] == nil || efforts[record.harness] == .unspecified {
                    efforts[record.harness] = record.efforts
                }
                if !record.defaultEffort.isEmpty, (defaultEfforts[record.harness] ?? "").isEmpty {
                    defaultEfforts[record.harness] = record.defaultEffort
                }
                if !record.upgradeTo.isEmpty, (upgradeByKey[key] ?? "").isEmpty {
                    upgradeByKey[key] = record.upgradeTo
                }
                if !record.upgradeNote.isEmpty, (upgradeNoteByKey[key] ?? "").isEmpty {
                    upgradeNoteByKey[key] = record.upgradeNote
                }
                if let rank = record.publisherRank, publisherRankByKey[key] == nil {
                    publisherRankByKey[key] = rank
                }
            }

            let evidence = Set(group.map(\.harness))
            let ordered = orderedHarnesses(evidence: evidence, provider: provider)
            let topLine = ordered.first ?? group[0].harness

            let displayName = group.first { !$0.displayName.isEmpty }?.displayName ?? id
            // Context comes from whoever publishes a number, preferring direct
            // routes: OpenRouter advertises its own (larger) window for models
            // the vendor's own listing reports smaller, and the vendor route is
            // the honest one for a picker sub-line.
            let contextWindow = group.first { !isGatewayRoute($0.rawID) && $0.contextWindow != nil }?.contextWindow
                ?? group.first { $0.contextWindow != nil }?.contextWindow
            let isComingSoon = group.contains { $0.isComingSoon }

            let model = CatalogModel(
                id: id,
                displayName: displayName,
                provider: provider,
                harness: topLine,
                contextWindow: contextWindow,
                supportedEfforts: (efforts[topLine] ?? .unspecified).levels,
                isComingSoon: isComingSoon
            )

            modelsByProvider[provider, default: []].append(model)
            harnessesByKey[key] = ordered
            flagValuesByKey[key] = flagValues
            effortsByKey[key] = efforts
            defaultEffortsByKey[key] = defaultEfforts
        }

        // Publisher rank first, then alphabetical. A vendor that ranks its own
        // catalog knows better than we do which models the operator reaches
        // for: codex ranks Sol 1, Terra 2, Luna 3 and its retiring 5.x line
        // 16-26, whereas plain alphabetical order floats `gpt-5.3-codex-spark`
        // and `gpt-5.4` above the entire GPT-5.6 family. Unranked models keep
        // alphabetical order below the ranked block.
        for (provider, models) in modelsByProvider {
            modelsByProvider[provider] = models.sorted { lhs, rhs in
                let lk = ModelCatalogIdentity.key(provider: lhs.provider, id: lhs.id)
                let rk = ModelCatalogIdentity.key(provider: rhs.provider, id: rhs.id)
                let lr = publisherRankByKey[lk], rr = publisherRankByKey[rk]
                if let lr, let rr, lr != rr { return lr < rr }
                if (lr == nil) != (rr == nil) { return lr != nil }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
        }

        return ModelCatalogIndex(
            source: source,
            generatedAt: generatedAt,
            providers: ModelCatalogProviders.sorted(modelsByProvider.keys),
            modelsByProvider: modelsByProvider,
            harnessesByKey: harnessesByKey,
            flagValuesByKey: flagValuesByKey,
            effortsByKey: effortsByKey,
            defaultEffortsByKey: defaultEffortsByKey,
            upgradeByKey: upgradeByKey,
            upgradeNoteByKey: upgradeNoteByKey,
            publisherRankByKey: publisherRankByKey
        )
    }

    /// Harnesses that can serve a model, Part C order, default first.
    ///
    /// Evidence-based: a harness appears only if it published (or declares) the
    /// model. That keeps the cross-product real — an Anthropic model that
    /// opencode carries is offered under opencode — without inventing pairs
    /// that would fail at launch, and it makes "exactly one harness can serve
    /// this" (Claude Code's families) fall out naturally.
    static func orderedHarnesses(evidence: Set<String>, provider: String) -> [String] {
        let preference = ModelCatalogHarnesses.preferenceOrder(forProvider: provider)
        let ranked = preference.filter(evidence.contains)
        let rest = evidence.subtracting(preference).sorted()
        return ranked + rest
    }

    private static func segmentCount(_ id: String) -> Int {
        id.reduce(1) { $1 == "/" ? $0 + 1 : $0 }
    }

    /// `openrouter/<provider>/<model>` is the gateway route to a model some
    /// harness also lists directly. `openrouter/auto` is not: two segments
    /// means OpenRouter is the vendor, not the intermediary.
    static func isGatewayRoute(_ rawID: String) -> Bool {
        rawID.lowercased().hasPrefix("openrouter/") && segmentCount(rawID) >= 3
    }
}

// MARK: - Record codec (compiled snapshot + on-disk cache)

/// Tab-separated codec shared by the compiled snapshot and the disk cache, so
/// the two can never drift into different shapes. One record per line:
///
///     harness, rawID, displayName, context, efforts, flags, providerHint,
///     defaultEffort, upgradeTo, publisherRank, upgradeNote
///
/// `efforts` is `-` (unspecified), `0` (explicitly none), or a comma list.
/// `flags` is empty or `soon`. Trailing columns are optional, so a cache
/// written by an older build still decodes. Blank lines and `#` comments are
/// skipped, so a generated file can carry a provenance header.
///
/// Fields are backslash-escaped for tab, newline and carriage return, because
/// publisher prose (codex's `migration_markdown`) is multi-line and a
/// line-based format cannot carry it raw. Escaping is a no-op for every field
/// that contains none of those, so it does not churn the committed snapshot.
enum ModelCatalogRecordCodec {

    static func encode(_ records: [RawCatalogRecord]) -> String {
        records.map { r in
            var fields = [
                r.harness,
                r.rawID,
                r.displayName,
                r.contextWindow.map(String.init) ?? "",
                r.efforts.encoded,
                r.isComingSoon ? "soon" : "",
                r.providerHint,
                r.defaultEffort,
                r.upgradeTo,
                r.publisherRank.map(String.init) ?? "",
                escape(r.upgradeNote),
            ]
            // Trailing empties are dropped. Decode treats a missing trailing
            // column as its default, so this is lossless — and it keeps a
            // schema addition from rewriting all ~1,400 lines of the committed
            // snapshot, which is the difference between a reviewable diff and
            // an unreadable one.
            while fields.count > 2, fields[fields.count - 1].isEmpty { fields.removeLast() }
            return fields.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [RawCatalogRecord] {
        var out: [RawCatalogRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty, !f[1].isEmpty else { continue }
            out.append(RawCatalogRecord(
                harness: f[0],
                rawID: f[1],
                displayName: f.count > 2 ? f[2] : "",
                contextWindow: f.count > 3 ? Int(f[3]) : nil,
                efforts: ModelEffortSupport.decode(f.count > 4 ? f[4] : "-"),
                defaultEffort: f.count > 7 ? f[7] : "",
                isComingSoon: f.count > 5 && f[5] == "soon",
                upgradeTo: f.count > 8 ? f[8] : "",
                upgradeNote: f.count > 10 ? unescape(f[10]) : "",
                publisherRank: f.count > 9 ? Int(f[9]) : nil,
                providerHint: f.count > 6 ? f[6] : ""
            ))
        }
        return out
    }

    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        var out = ""
        out.reserveCapacity(value.count + 8)
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:   out.append(character)
            }
        }
        return out
    }

    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        out.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { out.append(character); continue }
            switch iterator.next() {
            case "n":  out.append("\n")
            case "t":  out.append("\t")
            case "r":  out.append("\r")
            case "\\": out.append("\\")
            // An unknown escape keeps both characters rather than eating them:
            // a decoder must never silently mangle content it does not know.
            case let other?: out.append("\\"); out.append(other)
            case nil:  out.append("\\")
            }
        }
        return out
    }
}
