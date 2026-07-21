import Foundation

// Core for the `c11 config` command family (C11-180, design §6 / §2.4 / §5.6).
//
// Pure, testable: no argv parsing, no socket, no AppKit. The whole `config`
// runtime as functions over injected stores (`AgentConfigLibraryStore`,
// `AgentLaunchStatsStore?`) plus already-normalized inputs. Both the CLI shim
// (`CLI/c11.swift`) and the socket handlers (`SocketHandlers/ConfigHandlers`)
// call this, so the two surfaces behave identically and every branch is locked
// under `c11-logic`. This mirrors the `HealthCommandCore` pure-core pattern.
//
// Reads/mutations operate directly on the state-root files (app-down capable);
// `config launch` is NOT here — it needs the running app to spawn a surface —
// but its pure pieces (name→config resolution, the `AgentLaunchRequest`
// builder, and socket param parsing) live here so they are unit-locked too.

// MARK: - Errors

/// Friendly, machine-readable `config` failures. `.code` is the stable wire
/// code; `.message` is the human line the CLI/socket surfaces print.
enum ConfigCoreError: Error, Equatable, CustomStringConvertible {
    case configNotFound(query: String, available: [String])
    case ambiguousName(String, ids: [String])
    case noRecent
    case invalidHarness(String)
    case invalidEffort(value: String, allowed: [String])
    case effortUnsupported(harness: String)
    case invalidSystemPromptMode(String)
    case systemPromptUnsupported(harness: String)
    case invalidWindow(String)
    case invalidAxis(String)
    case indexOutOfRange(Int)
    case placementConflict
    case promptConflict
    case store(code: String, message: String)

    var code: String {
        switch self {
        case .configNotFound: return "config_not_found"
        case .ambiguousName: return "ambiguous_name"
        case .noRecent: return "no_recent"
        case .invalidHarness: return "invalid_harness"
        case .invalidEffort: return "invalid_effort"
        case .effortUnsupported: return "effort_flag_unsupported"
        case .invalidSystemPromptMode: return "invalid_system_prompt_mode"
        case .systemPromptUnsupported: return "system_prompt_unsupported"
        case .invalidWindow: return "invalid_window"
        case .invalidAxis: return "invalid_axis"
        case .indexOutOfRange: return "index_out_of_range"
        case .placementConflict: return "placement_conflict"
        case .promptConflict: return "prompt_conflict"
        case .store(let code, _): return code
        }
    }

    var message: String {
        switch self {
        case .configNotFound(let query, let available):
            let list = available.isEmpty ? "(no saved configs)" : available.joined(separator: ", ")
            return "no config matching '\(query)' — saved configs: \(list)"
        case .ambiguousName(let name, let ids):
            return "config name '\(name)' is ambiguous (\(ids.count) match) — use an id: \(ids.joined(separator: ", "))"
        case .noRecent:
            return "no most-recent launch recorded yet — launch an agent first, then pin-current"
        case .invalidHarness(let h):
            let builtIn = ConfigCommandCore.savableHarnesses.joined(separator: ", ")
            return "unknown harness '\(h)' — built-in: \(builtIn); or a custom kind with a ~/.config/c11/agents/<kind>.json template"
        case .invalidEffort(let value, let allowed):
            return "invalid effort '\(value)' — allowed: \(allowed.joined(separator: ", "))"
        case .effortUnsupported(let harness):
            return "harness '\(harness)' declares no effort-flag syntax; --effort is not supported for it"
        case .invalidSystemPromptMode(let m):
            return "invalid --system-prompt-mode '\(m)' — must be inherit, append, or replace"
        case .systemPromptUnsupported(let harness):
            return "harness '\(harness)' declares no system-prompt-flag syntax; --system-prompt-mode is not supported for it"
        case .invalidWindow(let w):
            return "invalid --window '\(w)' — must be today, all, or <N>d (e.g. 30d)"
        case .invalidAxis(let a):
            return "invalid --by '\(a)' — must be model, harness, or provider"
        case .indexOutOfRange(let i):
            return "reorder index \(i) out of range"
        case .placementConflict:
            return "--new-workspace is mutually exclusive with --pane/--workspace"
        case .promptConflict:
            return "--prompt and --prompt-file are mutually exclusive"
        case .store(_, let message):
            return message
        }
    }

    var description: String { message }
}

// MARK: - Inputs

/// The optional recipe flags shared by `save` / `edit`. Each `nil` means "not
/// supplied" (edit leaves the field untouched; save inherits). An explicit
/// empty string clears a field back to inherit (`nil` on disk) — the
/// clear-to-inherit convention documented in `--help` and the skill.
struct ConfigFields: Equatable {
    var harness: String?
    var model: String?
    var effort: String?
    var systemPromptMode: String?     // inherit|append|replace
    var systemPromptText: String?
    var command: String?
    var initialPrompt: String?
    var env: [String: String]?

    init(
        harness: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        systemPromptMode: String? = nil,
        systemPromptText: String? = nil,
        command: String? = nil,
        initialPrompt: String? = nil,
        env: [String: String]? = nil
    ) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.systemPromptMode = systemPromptMode
        self.systemPromptText = systemPromptText
        self.command = command
        self.initialPrompt = initialPrompt
        self.env = env
    }
}

/// Normalized `config launch` inputs, produced once by `parseLaunchInputs` and
/// shared by the CLI shim and the `config.launch` socket handler so the param
/// names, mutual-exclusion, and prompt precedence are single-sourced + tested.
struct ConfigLaunchInputs: Equatable {
    enum Placement: Equatable {
        case defaultPlacement           // focused pane of the current/target workspace
        case pane(String)
        case workspace(String)
        case newWorkspace
    }
    var nameOrId: String
    var placement: Placement
    var cwd: String?
    var prompt: String?
    var json: Bool
}

// MARK: - Results

struct ConfigListResult {
    let file: AgentConfigLibraryFile
}

struct ConfigRecentResult {
    let recent: RecentAgentConfig?
}

struct ConfigStatsResult {
    let window: StatsWindow
    let axis: StatsAxis
    /// Descending by count, ties broken by key for stable output.
    let tally: [(key: String, count: Int)]
    let count: Int
    let lastTs: Date?
}

// MARK: - Core

/// File-backed `config` runtime over injected stores.
struct ConfigCommandCore {
    let library: AgentConfigLibraryStore
    let stats: AgentLaunchStatsStore?

    init(library: AgentConfigLibraryStore = .shared, stats: AgentLaunchStatsStore? = AgentLaunchStatsStore.shared) {
        self.library = library
        self.stats = stats
    }

    /// CLI-safe mirror of the built-in harness launch capabilities the parent
    /// keeps in `AgentRegistry` (`Sources/AgentManifest.swift`). This core
    /// compiles into the **CLI target too**, which — by the parent's deliberate
    /// design — does NOT link `AgentType`/`AgentRegistry` (the store uses `String`
    /// harnesses to keep that boundary). So `config save/edit` gets eager,
    /// friendly effort/system-prompt validation app-down without pulling the
    /// whole agent-manifest graph across the boundary.
    ///
    /// AgentRegistry is the source of truth; this mirror covers only what
    /// validation reads (effort axis + values, system-prompt support). If it ever
    /// drifts, the launch path (`AgentLaunchPlanner`, app-side) is authoritative
    /// and re-validates, so a stale mirror degrades to "not rejected until
    /// launch", never to a wrong launch.
    struct HarnessCapability {
        /// Allowed effort values; `nil` = no effort axis (effort unsupported);
        /// `[]` = effort axis with free-form values (any non-empty accepted).
        let effortValues: [String]?
        let supportsSystemPrompt: Bool
    }

    static let builtInHarnesses: [String: HarnessCapability] = [
        "claude-code": HarnessCapability(effortValues: ["low", "medium", "high", "xhigh", "max"], supportsSystemPrompt: true),
        "codex": HarnessCapability(effortValues: [], supportsSystemPrompt: false),
        "grok": HarnessCapability(effortValues: nil, supportsSystemPrompt: false),
        "kimi": HarnessCapability(effortValues: nil, supportsSystemPrompt: false),
        "opencode": HarnessCapability(effortValues: nil, supportsSystemPrompt: false),
        "github-copilot": HarnessCapability(effortValues: nil, supportsSystemPrompt: false),
        "pi": HarnessCapability(effortValues: ["off", "minimal", "low", "medium", "high", "xhigh"], supportsSystemPrompt: false),
        "omp": HarnessCapability(effortValues: ["off", "minimal", "low", "medium", "high", "xhigh"], supportsSystemPrompt: false),
    ]

    /// Built-in harnesses a config may target, in a stable display order.
    static let savableHarnesses: [String] = [
        "claude-code", "codex", "grok", "kimi", "opencode", "github-copilot", "pi", "omp",
    ]

    /// The custom-kind template path (mirrors `UserAgentLaunchTemplate.templateURL`,
    /// which is app-only). CLI-safe: a plain file-existence check.
    static func customTemplateExists(kind: String) -> Bool {
        guard kind.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, kind.count <= 32 else {
            return false
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/c11/agents", isDirectory: true)
            .appendingPathComponent("\(kind).json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Reads

    func list() -> ConfigListResult {
        ConfigListResult(file: library.current)
    }

    func recent() -> ConfigRecentResult {
        ConfigRecentResult(recent: library.current.recent)
    }

    func statsView(window: StatsWindow, by axis: StatsAxis, now: Date? = nil) -> ConfigStatsResult {
        guard let stats else {
            return ConfigStatsResult(window: window, axis: axis, tally: [], count: 0, lastTs: nil)
        }
        let result = stats.stats(window: window, by: axis, now: now)
        let ordered = result.tally
            .map { (key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
        return ConfigStatsResult(
            window: window, axis: axis, tally: ordered, count: result.count, lastTs: result.lastTs
        )
    }

    // MARK: Mutations

    /// Create a new saved config. Validates the harness/effort/system-prompt
    /// eagerly so a bad recipe fails before any write.
    func save(name: String, fields: ConfigFields) throws -> SavedAgentConfig {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let harness = fields.harness?.trimmingCharacters(in: .whitespacesAndNewlines),
              !harness.isEmpty else {
            throw ConfigCoreError.invalidHarness("")
        }
        try Self.validate(fields: fields, harness: harness)
        let config = Self.makeLaunchConfig(harness: harness, fields: fields, base: nil)
        let saved = SavedAgentConfig(id: "", name: trimmedName, order: 0, config: config)
        do {
            return try library.add(saved)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
    }

    /// Edit an existing config: only supplied fields change; id/order preserved.
    func edit(nameOrId: String, fields: ConfigFields) throws -> SavedAgentConfig {
        var file = library.current
        let target = try Self.resolve(nameOrId: nameOrId, in: file.configs)
        // Validate against the effective post-edit harness.
        let effectiveHarness = fields.harness?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? target.config.harness
        try Self.validate(fields: fields, harness: effectiveHarness)
        let merged = Self.makeLaunchConfig(harness: effectiveHarness, fields: fields, base: target.config)
        guard let idx = file.configs.firstIndex(where: { $0.id == target.id }) else {
            throw ConfigCoreError.configNotFound(query: nameOrId, available: Self.availableLabels(file.configs))
        }
        file.configs[idx] = SavedAgentConfig(
            id: target.id, name: target.name, order: target.order, config: merged
        )
        do {
            try library.write(file)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
        return file.configs[idx]
    }

    @discardableResult
    func remove(nameOrId: String) throws -> SavedAgentConfig {
        let target = try Self.resolve(nameOrId: nameOrId, in: library.current.configs)
        do {
            try library.remove(id: target.id)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
        return target
    }

    @discardableResult
    func reorder(nameOrId: String, to index: Int) throws -> SavedAgentConfig {
        let target = try Self.resolve(nameOrId: nameOrId, in: library.current.configs)
        do {
            try library.reorder(id: target.id, to: index)
        } catch AgentConfigLibraryStore.StoreError.indexOutOfRange(let i) {
            throw ConfigCoreError.indexOutOfRange(i)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
        return target
    }

    @discardableResult
    func setDefault(nameOrId: String) throws -> SavedAgentConfig {
        let target = try Self.resolve(nameOrId: nameOrId, in: library.current.configs)
        do {
            try library.setDefault(configId: target.id)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
        return target
    }

    func setFollowRecent() throws {
        do {
            try library.setMode(.followRecent)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
    }

    /// Snapshot the most-recent observation into a new saved config and pin it
    /// (design §2.2 "pin current creates/updates one"; §6 `--pin-current`).
    /// `name` overrides the auto-generated `"Current: <model|harness>"` label.
    func pinCurrent(name: String? = nil) throws -> SavedAgentConfig {
        guard let recent = library.current.recent, let harness = recent.harness?.nonEmpty else {
            throw ConfigCoreError.noRecent
        }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Current: \(recent.model?.nonEmpty ?? harness)"
        let config = AgentLaunchConfig(
            harness: harness,
            model: recent.model?.nonEmpty,
            effort: recent.effort?.nonEmpty
        )
        let saved: SavedAgentConfig
        do {
            saved = try library.add(SavedAgentConfig(id: "", name: label, order: 0, config: config))
            try library.setDefault(configId: saved.id)
        } catch let e as AgentConfigLibraryStore.StoreError {
            throw ConfigCoreError.store(code: e.code, message: e.description)
        }
        return saved
    }

    // MARK: Launch (pure pieces; surface creation lives in the socket handler)

    /// Resolve a saved config by name or id, throwing a friendly error.
    func resolveConfig(nameOrId: String) throws -> SavedAgentConfig {
        try Self.resolve(nameOrId: nameOrId, in: library.current.configs)
    }

    // `buildLaunchRequest` (SavedAgentConfig → AgentLaunchRequest) lives in the
    // app-only `ConfigHandlers.swift`: `AgentLaunchRequest` is defined in
    // `DefaultAgentResolver.swift` (c11 target only), and this core compiles into
    // the CLI target too. Keeping the request builder out of here preserves the
    // parent's deliberate CLI/app type boundary.

    /// Parse a normalized param dict (socket) into `ConfigLaunchInputs`. The CLI
    /// shim builds the same dict from argv, so both surfaces share this one
    /// mutual-exclusion + prompt-precedence path.
    static func parseLaunchInputs(
        nameOrId: String,
        pane: String?,
        workspace: String?,
        newWorkspace: Bool,
        cwd: String?,
        prompt: String?,
        promptFile: String?,
        promptFileContents: String?,
        json: Bool
    ) throws -> ConfigLaunchInputs {
        if newWorkspace && (pane != nil || workspace != nil) {
            throw ConfigCoreError.placementConflict
        }
        if prompt != nil && promptFile != nil {
            throw ConfigCoreError.promptConflict
        }
        let placement: ConfigLaunchInputs.Placement
        if newWorkspace {
            placement = .newWorkspace
        } else if let pane = pane?.nonEmpty {
            placement = .pane(pane)
        } else if let ws = workspace?.nonEmpty {
            placement = .workspace(ws)
        } else {
            placement = .defaultPlacement
        }
        let resolvedPrompt = prompt?.nonEmpty ?? promptFileContents?.nonEmpty
        return ConfigLaunchInputs(
            nameOrId: nameOrId,
            placement: placement,
            cwd: cwd?.nonEmpty,
            prompt: resolvedPrompt,
            json: json
        )
    }

    // MARK: Validation

    /// Validate a recipe against its harness: harness must be launchable, and
    /// any supplied effort/system-prompt-mode must be legal for that harness.
    /// Uses the CLI-safe capability mirror; the launch-time planner (app-side)
    /// remains the authority and re-validates.
    static func validate(fields: ConfigFields, harness: String) throws {
        let harness = harness.trimmingCharacters(in: .whitespacesAndNewlines)
        let capability = builtInHarnesses[harness]
        let isCustom = capability == nil && customTemplateExists(kind: harness)
        guard capability != nil || isCustom else {
            throw ConfigCoreError.invalidHarness(harness)
        }
        // system-prompt-mode syntactic check (applies to any harness).
        if let modeRaw = fields.systemPromptMode?.nonEmpty {
            guard SystemPromptSetting.Mode(rawValue: modeRaw.lowercased()) != nil else {
                throw ConfigCoreError.invalidSystemPromptMode(modeRaw)
            }
        }
        // Effort + system-prompt axis checks apply to built-in harnesses only;
        // custom kinds carry their own template, so the planner validates them at
        // launch (mirror the planner's per-harness capability gates here).
        guard let capability else { return }
        if let effort = fields.effort?.nonEmpty {
            guard let allowed = capability.effortValues else {
                throw ConfigCoreError.effortUnsupported(harness: harness)
            }
            if !allowed.isEmpty, !allowed.contains(effort) {
                throw ConfigCoreError.invalidEffort(value: effort, allowed: allowed)
            }
        }
        if let modeRaw = fields.systemPromptMode?.nonEmpty,
           let mode = SystemPromptSetting.Mode(rawValue: modeRaw.lowercased()),
           mode != .inherit,
           !capability.supportsSystemPrompt {
            throw ConfigCoreError.systemPromptUnsupported(harness: harness)
        }
    }

    // MARK: Internals

    /// Build an `AgentLaunchConfig` from fields. When `base` is non-nil (edit),
    /// unsupplied fields (`nil`) inherit the base; a supplied empty string
    /// clears to `nil` (inherit). When `base` is nil (save), unsupplied fields
    /// are simply absent.
    static func makeLaunchConfig(
        harness: String,
        fields: ConfigFields,
        base: AgentLaunchConfig?
    ) -> AgentLaunchConfig {
        func merge(_ supplied: String?, _ baseValue: String?) -> String? {
            guard let supplied else { return baseValue }      // not supplied → keep base
            let trimmed = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed            // empty → clear to inherit
        }
        // System prompt: mode drives it. Supplying a mode (re)builds the setting;
        // clearing the mode to "" or "inherit" drops it to nil.
        let systemPrompt: SystemPromptSetting?
        if let modeRaw = fields.systemPromptMode {
            let trimmed = modeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "inherit" {
                systemPrompt = nil
            } else if let mode = SystemPromptSetting.Mode(rawValue: trimmed) {
                systemPrompt = SystemPromptSetting(mode: mode, text: fields.systemPromptText ?? base?.systemPrompt?.text ?? "")
            } else {
                systemPrompt = base?.systemPrompt
            }
        } else if let text = fields.systemPromptText, let baseMode = base?.systemPrompt?.mode {
            // Text supplied without a mode on edit: keep the base mode, swap text.
            systemPrompt = SystemPromptSetting(mode: baseMode, text: text)
        } else {
            systemPrompt = base?.systemPrompt
        }
        // Env: nil supplied → keep base; supplied dict replaces wholesale
        // (per-key merge is the launch-time overlay's job, not storage).
        let env = fields.env ?? base?.env
        return AgentLaunchConfig(
            harness: harness,
            model: merge(fields.model, base?.model),
            effort: merge(fields.effort, base?.effort),
            systemPrompt: systemPrompt,
            command: merge(fields.command, base?.command),
            initialPrompt: merge(fields.initialPrompt, base?.initialPrompt),
            env: env
        )
    }

    static func availableLabels(_ configs: [SavedAgentConfig]) -> [String] {
        configs.sorted { $0.order < $1.order }.map { "\($0.name) (\($0.id))" }
    }

    /// Resolve a name-or-id: id-exact first, then name-exact. A name matching
    /// more than one config is ambiguous.
    static func resolve(nameOrId: String, in configs: [SavedAgentConfig]) throws -> SavedAgentConfig {
        let query = nameOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byId = configs.first(where: { $0.id == query }) {
            return byId
        }
        let byName = configs.filter { $0.name == query }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw ConfigCoreError.ambiguousName(query, ids: byName.map(\.id))
        }
        throw ConfigCoreError.configNotFound(query: query, available: availableLabels(configs))
    }

    // MARK: Window/axis parsing (shared with CLI + socket)

    static func parseWindow(_ raw: String?) throws -> StatsWindow {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .all
        }
        switch raw {
        case "today": return .today
        case "all": return .all
        default:
            if raw.hasSuffix("d"), let n = Int(raw.dropLast()), n > 0 {
                return .days(n)
            }
            throw ConfigCoreError.invalidWindow(raw)
        }
    }

    static func parseAxis(_ raw: String?) throws -> StatsAxis {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .model
        }
        guard let axis = StatsAxis(rawValue: raw) else {
            throw ConfigCoreError.invalidAxis(raw)
        }
        return axis
    }
}

// MARK: - Rendering (shared by CLI + socket; JSON shape unit-locked)

/// ISO-8601 with fractional seconds, matching the store/stats on-disk date form.
enum ConfigRenderDate {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}

extension ConfigListResult {
    /// The full `agent-configs.json` document as a JSON object (§2.1 keys),
    /// produced by encoding the model so the shape can never drift from disk.
    func jsonObject() -> [String: Any] {
        (try? ConfigJSON.object(from: file)) ?? [:]
    }

    func humanText() -> String {
        var lines: [String] = []
        let configs = file.configs.sorted { $0.order < $1.order }
        if configs.isEmpty {
            lines.append("(no saved configs)")
        } else {
            lines.append("Saved configs:")
            for c in configs {
                let pin = c.id == file.default.configId ? "●" : "○"
                var parts = ["\(pin) \(c.name)", c.config.harness]
                if let m = c.config.model, !m.isEmpty { parts.append(m) }
                if let e = c.config.effort, !e.isEmpty { parts.append(e) }
                if let sp = c.config.systemPrompt {
                    parts.append(sp.mode == .replace && sp.text.isEmpty ? "sys:blank" : "sys:\(sp.mode.rawValue)")
                }
                if let prov = AgentLaunchStats.provider(harness: c.config.harness, model: c.config.model) {
                    parts.append(prov)
                }
                lines.append("  " + parts.joined(separator: "  ") + "   [\(c.id)]")
            }
        }
        let mode = file.default.mode == .followRecent ? "follow-recent" : "pinned"
        let defName = configs.first(where: { $0.id == file.default.configId })?.name ?? file.default.configId
        lines.append("Default: \(defName) (\(mode))")
        if let r = file.recent {
            let axes = [r.model, r.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("Most recent: \(r.harness ?? "—")\(axes.isEmpty ? "" : " · \(axes)")")
        }
        return lines.joined(separator: "\n")
    }
}

extension ConfigRecentResult {
    func jsonObject() -> [String: Any] {
        guard let recent else { return ["recent": NSNull()] }
        return ["recent": (try? ConfigJSON.object(from: recent)) ?? [:]]
    }

    func humanText() -> String {
        guard let r = recent else { return "no most-recent launch recorded yet" }
        var parts: [String] = []
        if let h = r.harness { parts.append("harness=\(h)") }
        if let m = r.model, !m.isEmpty { parts.append("model=\(m)") }
        if let e = r.effort, !e.isEmpty { parts.append("effort=\(e)") }
        if let src = r.source { parts.append("source=\(src)") }
        if let at = r.observedAt { parts.append("observed=\(ConfigRenderDate.string(at))") }
        if let fs = r.fieldSources, !fs.isEmpty {
            let rendered = fs.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            parts.append("field_sources=[\(rendered)]")
        }
        return "Most recent: " + parts.joined(separator: "  ")
    }
}

extension ConfigStatsResult {
    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "window": Self.windowToken(window),
            "by": axis.rawValue,
            "count": count,
            "tally": tally.map { ["key": $0.key, "count": $0.count] }
        ]
        if let lastTs { obj["last_ts"] = ConfigRenderDate.string(lastTs) }
        return obj
    }

    func humanText() -> String {
        if count == 0 { return "no launches recorded for window '\(Self.windowToken(window))'" }
        var lines = ["Launch stats (\(Self.windowToken(window)), by \(axis.rawValue)) — \(count) launch\(count == 1 ? "" : "es"):"]
        for row in tally {
            let pct = count > 0 ? Int((Double(row.count) / Double(count) * 100).rounded()) : 0
            lines.append("  \(row.key)  \(pct)% (\(row.count))")
        }
        if let lastTs { lines.append("Last: \(ConfigRenderDate.string(lastTs))") }
        return lines.joined(separator: "\n")
    }

    static func windowToken(_ w: StatsWindow) -> String {
        switch w {
        case .today: return "today"
        case .all: return "all"
        case .days(let n): return "\(n)d"
        }
    }
}

/// Encode a `Codable` to a `[String: Any]` JSON object with the store's date
/// convention, so rendered JSON matches the on-disk schema exactly.
enum ConfigJSON {
    static func object(from value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ConfigRenderDate.string(date))
        }
        let data = try encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Small helper

extension String {
    /// `nil` when empty/whitespace-only, else the trimmed value.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
