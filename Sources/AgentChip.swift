import Foundation

/// Sidebar TUI identity chip.
///
/// An `AgentChip` is the precomputed display state rendered on each workspace
/// row's sidebar entry. The chip reflects the metadata of a workspace's
/// focused surface — specifically the canonical `terminal_type` and `model`
/// keys plus the non-canonical `model_label` display hint.
struct AgentChip: Equatable {
    let terminalType: String          // canonical terminal_type, or "unknown"
    let model: String?                // canonical model, if set
    let detectedModel: String?        // raw model id read from the harness's session files, if detected
    let modelLabel: String?           // non-canonical display hint, if set (trimmed, ≤16 chars)
    let displayLabel: String?         // final resolved label (post-shortening), may be nil
    let iconAsset: String             // "AgentIcons/<type>" or "sf:<symbol>" fallback
    let sourceSurfaceId: UUID
    let source: String?               // winning source for the chip (declare/explicit/heuristic/osc)
    let terminalTypeSource: String?   // per-key sidecar source for terminal_type
    let modelSource: String?          // per-key sidecar source for model
}

enum AgentChipResolver {
    /// Resolve the chip display state from raw canonical keys + per-key sources.
    /// Returns nil if both `terminal_type` is absent/unknown AND `model` is absent.
    static func resolve(
        focusedSurfaceId: UUID,
        metadata: [String: Any],
        sources: [String: MetadataSource]
    ) -> AgentChip? {
        let rawTerminalType = metadata[MetadataKey.terminalType] as? String
        let model = metadata[MetadataKey.model] as? String
        let modelLabel = normalizedModelLabel(metadata[MetadataKey.modelLabel])
        // C11 live detection: the model read from the harness's own session
        // files. Declared/explicit `model`/`model_label` win; this wins over nothing.
        let detectedModel = (metadata[AgentModelDetector.MetadataKeys.detected] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        let normalizedTerminalType = AgentIdentityPolicy.normalizedKind(rawTerminalType)
        let hasTerminalType = normalizedTerminalType != nil && normalizedTerminalType != "unknown"
        if !hasTerminalType && model == nil && detectedModel == nil {
            return nil
        }

        let terminalType = normalizedTerminalType ?? "unknown"
        // Agent-declared > detected > launch stamp (`AgentModelPrecedence`).
        let effective = AgentModelPrecedence.effective(
            model: model, modelSource: sources[MetadataKey.model],
            modelLabel: modelLabel, labelSource: sources[MetadataKey.modelLabel],
            detected: detectedModel
        )
        let displayLabel: String? = {
            if let label = effective.label { return label }
            return shortenModel(effective.model)
        }()

        let iconAsset = iconAssetName(forTerminalType: terminalType)
        let terminalTypeSource = sources[MetadataKey.terminalType]?.rawValue
        let modelSource = sources[MetadataKey.model]?.rawValue
            ?? (detectedModel != nil ? sources[AgentModelDetector.MetadataKeys.detected]?.rawValue : nil)

        // Winning source preference: declare > explicit > osc > heuristic, prefer terminal_type source
        // when both exist; otherwise fall back to model's source. This matches spec's
        // "source" field semantics.
        let source = terminalTypeSource ?? modelSource

        return AgentChip(
            terminalType: terminalType,
            model: model,
            detectedModel: detectedModel,
            modelLabel: modelLabel,
            displayLabel: displayLabel,
            iconAsset: iconAsset,
            sourceSurfaceId: focusedSurfaceId,
            source: source,
            terminalTypeSource: terminalTypeSource,
            modelSource: modelSource
        )
    }

    /// Non-canonical `model_label` hint: coerced to string, trimmed, ≤16 chars; nil-out empty.
    static func normalizedModelLabel(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 16 {
            return String(trimmed.prefix(16))
        }
        return trimmed
    }

    /// Registered alias table — maps known model IDs to short display labels.
    private static let modelAliasTable: [String: String] = [
        "kimi-k2-0711": "K2",
        "opencode-qwen-3-coder": "Qwen 3"
    ]

    /// Anthropic model ids: `claude-<family>-<major>[-<minor>]` and the legacy
    /// `claude-<major>[-<minor>]-<family>`; a trailing `-YYYYMMDD` snapshot is
    /// stripped before matching.
    private static let claudeModernPattern = try! NSRegularExpression(
        pattern: "^claude-(opus|sonnet|haiku|fable)-(\\d+)(?:-(\\d+))?$"
    )
    private static let claudeLegacyPattern = try! NSRegularExpression(
        pattern: "^claude-(\\d+)(?:-(\\d+))?-(opus|sonnet|haiku|fable)$"
    )

    private static let datedSuffixPattern = try! NSRegularExpression(pattern: "-\\d{8}$")

    /// Deterministic shortening rules, shared by the sidebar chip and the tab
    /// sheet. Claude ids become `Opus 5.5`; other ids stay as the vendor wrote
    /// them (`gpt-5.5`), minus provider prefixes, `[1m]`-style suffixes and
    /// dated snapshot suffixes.
    static func shortenModel(_ model: String?) -> String? {
        guard var id = model?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }

        // `claude-opus-4-7[1m]` → `claude-opus-4-7`.
        if let bracket = id.firstIndex(of: "["), id.hasSuffix("]") {
            id = String(id[..<bracket])
        }
        // `openrouter/~x-ai/grok-latest` → `grok-latest`.
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        // `claude-haiku-4-5-20251001` → `claude-haiku-4-5`.
        let full = NSRange(id.startIndex..., in: id)
        if let m = datedSuffixPattern.firstMatch(in: id, range: full), let r = Range(m.range, in: id) {
            id = String(id[..<r.lowerBound])
        }
        guard !id.isEmpty else { return nil }

        if let alias = modelAliasTable[id] {
            return alias
        }

        let range = NSRange(id.startIndex..., in: id)
        func group(_ m: NSTextCheckingResult, _ n: Int) -> String? {
            guard n < m.numberOfRanges, let r = Range(m.range(at: n), in: id) else { return nil }
            return String(id[r])
        }
        func titled(_ family: String) -> String {
            family.prefix(1).uppercased() + family.dropFirst()
        }
        if let m = claudeModernPattern.firstMatch(in: id, range: range), let family = group(m, 1), let major = group(m, 2) {
            let version = group(m, 3).map { "\(major).\($0)" } ?? major
            return "\(titled(family)) \(version)"
        }
        if let m = claudeLegacyPattern.firstMatch(in: id, range: range), let major = group(m, 1), let family = group(m, 3) {
            let version = group(m, 2).map { "\(major).\($0)" } ?? major
            return "\(titled(family)) \(version)"
        }

        // Pass-through, truncate to 14 chars with ellipsis.
        if id.count > 14 {
            return String(id.prefix(13)) + "…"
        }
        return id
    }

    /// Icon asset name per spec. Returns "AgentIcons/<type>" for known types; for now,
    /// M3 ships SF Symbol fallbacks via the "sf:<symbol>" sentinel.
    /// The view layer decides whether the bundled asset exists and falls back.
    static func iconAssetName(forTerminalType terminalType: String) -> String {
        // Branded agents resolve through the same identity policy used for
        // companion links and pane sizing. Non-agent terminal types keep the
        // existing conventional fallback that makes shell chips intentional.
        let normalized = AgentIdentityPolicy.normalizedKind(terminalType) ?? terminalType
        if AgentIdentityPolicy.isAgentKind(normalized),
           let asset = AgentIdentityPolicy.fallbackManifest(for: normalized)?.iconAsset {
            return asset
        }
        return "AgentIcons/\(normalized)"
    }

    /// SF Symbol fallback per spec's icon table. Returned when the bundled asset
    /// is missing at runtime.
    static func sfSymbolFallback(forTerminalType terminalType: String) -> String {
        let normalized = AgentIdentityPolicy.normalizedKind(terminalType) ?? terminalType
        if AgentIdentityPolicy.isAgentKind(normalized),
           let symbol = AgentIdentityPolicy.fallbackManifest(for: normalized)?.sfSymbolFallback {
            return symbol
        }
        // shell is the only non-agent type with a distinct glyph; everything
        // else (unknown, custom, unrecognized) gets the question-mark.
        return normalized == "shell" ? "terminal.fill" : "questionmark.square.dashed"
    }
}
