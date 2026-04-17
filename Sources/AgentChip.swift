import Foundation

/// Module 3 — Sidebar TUI identity chip.
///
/// An `AgentChip` is the precomputed display state rendered on each workspace
/// row's sidebar entry. The chip reflects the metadata of a workspace's
/// focused surface — specifically the canonical `terminal_type` and `model`
/// keys plus the non-canonical `model_label` display hint.
///
/// Spec: `docs/c11mux-module-3-and-6-sidebar-and-markdown-spec.md`.
struct AgentChip: Equatable {
    let terminalType: String          // canonical terminal_type, or "unknown"
    let model: String?                // canonical model, if set
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

        let hasTerminalType = rawTerminalType != nil && rawTerminalType != "unknown"
        if !hasTerminalType && model == nil {
            return nil
        }

        let terminalType = rawTerminalType ?? "unknown"
        let displayLabel: String? = {
            if let modelLabel { return modelLabel }
            return shortenModel(model)
        }()

        let iconAsset = iconAssetName(forTerminalType: terminalType)
        let terminalTypeSource = sources[MetadataKey.terminalType]?.rawValue
        let modelSource = sources[MetadataKey.model]?.rawValue

        // Winning source preference: declare > explicit > osc > heuristic, prefer terminal_type source
        // when both exist; otherwise fall back to model's source. This matches spec's
        // "source" field semantics.
        let source = terminalTypeSource ?? modelSource

        return AgentChip(
            terminalType: terminalType,
            model: model,
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
        "claude-opus-4-7": "Opus 4.7",
        "claude-opus-4-6": "Opus 4.6",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-haiku-4-5": "Haiku 4.5",
        "gpt-5.4-pro": "GPT-5.4 Pro",
        "gpt-5.4": "GPT-5.4",
        "kimi-k2-0711": "K2",
        "opencode-qwen-3-coder": "Qwen 3"
    ]

    /// Deterministic shortening rules per spec.
    static func shortenModel(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }

        if let alias = modelAliasTable[model] {
            return alias
        }

        // Versioned family: <family>-<variant>-<major>-<minor> → "<Variant> <major>.<minor>"
        let parts = model.split(separator: "-")
        if parts.count >= 4 {
            let variant = String(parts[parts.count - 3])
            let major = String(parts[parts.count - 2])
            let minor = String(parts[parts.count - 1])
            if Int(major) != nil, Int(minor) != nil, !variant.isEmpty {
                let titled = variant.prefix(1).uppercased() + variant.dropFirst()
                return "\(titled) \(major).\(minor)"
            }
        }

        // Pass-through, truncate to 10 chars with ellipsis.
        if model.count > 10 {
            return String(model.prefix(9)) + "…"
        }
        return model
    }

    /// Icon asset name per spec. Returns "AgentIcons/<type>" for known types; for now,
    /// M3 ships SF Symbol fallbacks via the "sf:<symbol>" sentinel.
    /// The view layer decides whether the bundled asset exists and falls back.
    static func iconAssetName(forTerminalType terminalType: String) -> String {
        switch terminalType {
        case "claude-code":
            return "AgentIcons/claude-code"
        case "codex":
            return "AgentIcons/codex"
        case "kimi":
            return "AgentIcons/kimi"
        case "opencode":
            return "AgentIcons/opencode"
        case "shell":
            return "AgentIcons/shell"
        case "unknown":
            return "AgentIcons/unknown"
        default:
            return "AgentIcons/\(terminalType)"
        }
    }

    /// SF Symbol fallback per spec's icon table. Returned when the bundled asset
    /// is missing at runtime.
    static func sfSymbolFallback(forTerminalType terminalType: String) -> String {
        switch terminalType {
        case "claude-code":  return "sparkles"
        case "codex":        return "chevron.left.forwardslash.chevron.right"
        case "kimi":         return "moon.stars"
        case "opencode":     return "curlybraces"
        case "shell":        return "terminal.fill"
        case "unknown":      return "questionmark.square.dashed"
        default:             return "questionmark.square.dashed"
        }
    }
}
