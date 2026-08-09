import Foundation

// MARK: - System prompt

/// An operator's system-prompt choice: which of the three modes (design §1.4),
/// and the prompt text. `inherit` keeps the harness default untouched, `append`
/// adds to it, `replace` swaps it — and `replace` with empty `text` is the
/// Gregorovich blank-slate case (strip the default to nothing).
///
/// This is the single canonical definition of the primitive, shared by the
/// launch/sysprompt axis (`AgentSystemPromptArg` in AgentManifest, which
/// consumes it) and this config-overlay store (which persists it on a saved
/// config). It lives in this file because this file is a member of **both** the
/// app and CLI targets, so the CLI-compiled store resolves the type without
/// pulling in app-only AgentManifest. Per-harness flag delivery is owned by the
/// sysprompt axis, not this store.
struct SystemPromptSetting: Codable, Equatable, Sendable {
    /// `inherit` leaves the harness default untouched (no flag injected);
    /// `append` adds `text` on top of the default; `replace` supplants the
    /// default with `text` (empty `text` = blank slate).
    enum Mode: String, Codable, Sendable, CaseIterable { case inherit, append, replace }
    var mode: Mode
    /// Ignored for `.inherit`. For `.replace`, an empty string is meaningful:
    /// it is the blank-slate prompt, not "unset".
    var text: String

    init(mode: Mode, text: String = "") {
        self.mode = mode
        self.text = text
    }
}

// MARK: - Launch recipe

/// The full launch recipe a saved config carries (design §1.3). Every field
/// except `harness` is optional; a `nil` field means *inherit the harness
/// base* (the per-harness Settings config, or factory). Composition/merge and
/// flag injection are owned by the launch-composition layer downstream; this
/// type is pure data.
///
/// `provider` is deliberately absent — it is a derived facet (fixed map or
/// model-id prefix, design §1.2) and is never persisted.
struct AgentLaunchConfig: Codable, Equatable {
    /// `AgentType.rawValue` (e.g. `"claude-code"`). Required; a recipe is
    /// always anchored to one harness. Stored as a `String` so this file stays
    /// free of the app-only `AgentType` and compiles into the CLI target.
    var harness: String
    /// `nil` = inherit the harness model.
    var model: String?
    /// `nil` = inherit the harness effort.
    var effort: String?
    /// `nil` = inherit; see `SystemPromptSetting`.
    var systemPrompt: SystemPromptSetting?
    /// `nil` = inherit the harness's configured/factory launch command.
    var command: String?
    /// `nil` = inherit the harness initial prompt.
    var initialPrompt: String?
    /// `nil` = inherit. Merged over the harness env downstream (config wins per
    /// key); this store only persists the overlay verbatim.
    var env: [String: String]?

    init(
        harness: String,
        model: String? = nil,
        effort: String? = nil,
        systemPrompt: SystemPromptSetting? = nil,
        command: String? = nil,
        initialPrompt: String? = nil,
        env: [String: String]? = nil
    ) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.command = command
        self.initialPrompt = initialPrompt
        self.env = env
    }

    /// The one harness kind whose factory command is empty by definition — the
    /// operator supplies the whole command line. Spelled here (not as
    /// `AgentType.custom`) because this file compiles into the CLI target,
    /// which does not link the app-only `AgentType`.
    static let customHarnessKey = "custom"

    /// Whether this recipe is unlaunchable *from the store's own vantage*
    /// (C11-203 A2). `custom` carries no factory command, so a `custom` recipe
    /// with no command of its own resolves to an empty shell command and can
    /// never launch — exactly the state that bricked the A button on the
    /// operator's machine.
    ///
    /// Deliberately conservative: every other harness inherits a
    /// manifest/Settings command this Foundation-only file cannot see, so it
    /// answers `false` for them and the resolver stays authoritative at launch
    /// time (where A1's visible decline covers whatever this misses).
    var isProvablyUnlaunchable: Bool {
        guard harness == AgentLaunchConfig.customHarnessKey else { return false }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
    }
}

/// A named launch recipe in the library. On disk the recipe fields are
/// **flat** — `id`/`name`/`order` sit alongside `harness`/`model`/… in one
/// object (design §2.1), not nested under a `config` key — so `Codable` is
/// custom to flatten the inner `AgentLaunchConfig`.
///
/// `id` is a `String` (ULID-shaped), not a `UUID`: the §2.1 examples use
/// ULID-style ids and `default.config_id` / `recent.config_id` cross-reference
/// them, so a `String` round-trips the on-disk shape faithfully and matches
/// the repo's ULID convention.
struct SavedAgentConfig: Codable, Equatable {
    var id: String
    var name: String
    var order: Int
    var config: AgentLaunchConfig

    init(id: String, name: String, order: Int, config: AgentLaunchConfig) {
        self.id = id
        self.name = name
        self.order = order
        self.config = config
    }

    // Flat on-disk shape. `systemPrompt` is intentionally camelCase — it is the
    // one camelCase key in the §2.1 `configs[]` example and the doc is the
    // schema contract; every other key is snake/kebab. Unset optionals are
    // omitted (absent = inherit).
    private enum CodingKeys: String, CodingKey {
        case id, name, order
        case harness, model, effort
        case systemPrompt
        case command
        case initialPrompt = "initial_prompt"
        case env
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.order = try c.decode(Int.self, forKey: .order)
        self.config = AgentLaunchConfig(
            harness: try c.decode(String.self, forKey: .harness),
            model: try c.decodeIfPresent(String.self, forKey: .model),
            effort: try c.decodeIfPresent(String.self, forKey: .effort),
            systemPrompt: try c.decodeIfPresent(SystemPromptSetting.self, forKey: .systemPrompt),
            command: try c.decodeIfPresent(String.self, forKey: .command),
            initialPrompt: try c.decodeIfPresent(String.self, forKey: .initialPrompt),
            env: try c.decodeIfPresent([String: String].self, forKey: .env)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(order, forKey: .order)
        try c.encode(config.harness, forKey: .harness)
        try c.encodeIfPresent(config.model, forKey: .model)
        try c.encodeIfPresent(config.effort, forKey: .effort)
        try c.encodeIfPresent(config.systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(config.command, forKey: .command)
        try c.encodeIfPresent(config.initialPrompt, forKey: .initialPrompt)
        try c.encodeIfPresent(config.env, forKey: .env)
    }
}

// MARK: - Default pointer + mode

/// The default pointer (design §2.2). `config_id` is always a saved config's
/// id, and a plain left-click launches it.
struct AgentConfigDefault: Codable, Equatable {
    /// The only resolution mode. A single case rather than a dropped field:
    /// `mode` stays in the on-disk schema (so `c11 config list --json` and any
    /// older build reading the file still see a value they understand), it just
    /// has one legal value now.
    enum Mode: String, Codable {
        /// Left-click launches the explicitly chosen config.
        case pinned
    }

    var mode: Mode
    var configId: String

    private enum CodingKeys: String, CodingKey {
        case mode
        case configId = "config_id"
    }

    init(mode: Mode = .pinned, configId: String) {
        self.mode = mode
        self.configId = configId
    }

    /// Migrate legacy pointers on read (C11-203 B2). Files written before
    /// follow-recent was retired carry `"mode": "follow-recent"`; a synthesized
    /// `Codable` would throw on that value, failing the *whole file* decode and
    /// healing the operator's library to factory — silent data loss. Any mode
    /// this build does not know (legacy or future) resolves to `pinned`, and
    /// `config_id` — the part that actually names the operator's choice — is
    /// preserved verbatim.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.configId = try c.decode(String.self, forKey: .configId)
        let raw = try c.decodeIfPresent(String.self, forKey: .mode)
        self.mode = raw.flatMap(Mode.init(rawValue:)) ?? .pinned
    }
}

// MARK: - Most-recent

/// The most-recent observed launch (design §2.3), persisted across relaunch.
/// Carries `field_sources` so a reader can distinguish live-observed from
/// launch-captured fields (§4).
///
/// Durable telemetry only: nothing in the resolution path reads it. This store
/// persists and returns `recent`; it never *produces* it — the
/// launch-composition layer calls `recordRecent` with a resolved observation.
struct RecentAgentConfig: Codable, Equatable {
    var configId: String?
    var harness: String?
    var model: String?
    var effort: String?
    var observedAt: Date?
    /// `launch` | `sessionHook` | `scrape` (design §4.4), free-form here.
    var source: String?
    /// Per-field provenance, e.g. `{ "model": "launch", "effort": "launch" }`.
    var fieldSources: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case configId = "config_id"
        case harness, model, effort
        case observedAt = "observed_at"
        case source
        case fieldSources = "field_sources"
    }

    init(
        configId: String? = nil,
        harness: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        observedAt: Date? = nil,
        source: String? = nil,
        fieldSources: [String: String]? = nil
    ) {
        self.configId = configId
        self.harness = harness
        self.model = model
        self.effort = effort
        self.observedAt = observedAt
        self.source = source
        self.fieldSources = fieldSources
    }
}

// MARK: - The file

/// The whole `agent-configs.json` document: the library, the default pointer,
/// and the persisted most-recent (design §2.1).
struct AgentConfigLibraryFile: Codable, Equatable {
    /// The only schema version this store reads/writes. A file carrying any
    /// other value is treated as corrupt and heals to `.factory` (see
    /// `AgentConfigLibraryStore.current`); a refuse-to-overwrite-newer guard is
    /// deferred until a v2 schema actually exists.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var configs: [SavedAgentConfig]
    var `default`: AgentConfigDefault
    var recent: RecentAgentConfig?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case configs
        case `default`
        case recent
    }

    init(
        schemaVersion: Int = AgentConfigLibraryFile.currentSchemaVersion,
        configs: [SavedAgentConfig],
        default: AgentConfigDefault,
        recent: RecentAgentConfig? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.configs = configs
        self.default = `default`
        self.recent = recent
    }

    // MARK: Factory seed

    /// Stable id for the seeded config: a fixed 26-char sentinel (readable, not
    /// a generated ULID) so the factory file is byte-deterministic across
    /// processes and the default pointer always resolves. 26 chars to match the
    /// `AgentConfigID` id width.
    static let factorySeedConfigId = "0000000000AGENTOPUSDEEP001"

    /// Factory shape: one pinned config, `Opus deep`, seeded **model=opus with
    /// effort UNSET** so it is byte-identical to today's pin (claude-code with
    /// `--model opus` and no `--effort` flag). This deviates from design §2.2's
    /// literal example (which shows `effort: high`): the governing intent is the
    /// §2.2 "(matching today's pin)" parenthetical plus C11-179's
    /// byte-identical-launch regression AC, and today's pin injects no effort
    /// flag. `effort: nil` = inherit → no `--effort` at launch. No recent yet.
    static let factory = AgentConfigLibraryFile(
        schemaVersion: currentSchemaVersion,
        configs: [
            SavedAgentConfig(
                id: factorySeedConfigId,
                name: "Opus deep",
                order: 0,
                config: AgentLaunchConfig(harness: "claude-code", model: "opus")
            )
        ],
        default: AgentConfigDefault(mode: .pinned, configId: factorySeedConfigId),
        recent: nil
    )

    /// Whether this file is internally coherent enough to trust. A file whose
    /// pinned `config_id` names no existing config is not fatal (resolution
    /// heals), but a wrong schema version is treated as corrupt upstream.
    var hasResolvablePinnedDefault: Bool {
        configs.contains { $0.id == `default`.configId }
    }

    // MARK: Corruption healing (C11-203 A2)

    /// The lowest-ordered config that is not provably unlaunchable, or `nil`
    /// when every saved config is broken.
    var firstLaunchableConfig: SavedAgentConfig? {
        configs
            .filter { !$0.config.isProvablyUnlaunchable }
            .min { $0.order < $1.order }
    }

    /// Repair the two corruption classes this file can detect on its own, so a
    /// drifted library can never brick the A button (C11-203 A2). Pure: the
    /// store applies it on read, and the next write persists the result.
    ///
    /// 1. **The factory seed drifted to an unlaunchable recipe.**
    ///    `factorySeedConfigId` is c11's own row, not the operator's — the
    ///    observed specimen had it rewritten to `harness: "custom"` with the
    ///    model dropped. Restore the seed *recipe*; the operator's `name` and
    ///    `order` for that row are theirs and are preserved.
    /// 2. **The pinned default names an unlaunchable config.**
    ///    Operator-authored recipes are never rewritten — they stay in the
    ///    library, editable. Only the pointer moves, to the lowest-ordered
    ///    launchable config. If nothing is launchable the pointer is left alone
    ///    and the launch path surfaces a visible decline (A1).
    ///
    /// A *dangling* pointer is deliberately not healed here: `pinnedConfig`
    /// already answers it with the factory seed, and rewriting the operator's
    /// pointer to some unrelated row would be a louder change than the read
    /// fallback it already has.
    func healed() -> AgentConfigLibraryFile {
        var file = self
        if let i = file.configs.firstIndex(where: { $0.id == Self.factorySeedConfigId }),
           file.configs[i].config.isProvablyUnlaunchable {
            file.configs[i].config = Self.factory.configs[0].config
        }
        if let pinned = file.configs.first(where: { $0.id == file.default.configId }),
           pinned.config.isProvablyUnlaunchable,
           let fallback = file.firstLaunchableConfig {
            file.default = AgentConfigDefault(mode: .pinned, configId: fallback.id)
        }
        return file
    }
}

// MARK: - Id generation

/// Self-contained ULID-shaped id generator for saved configs. Mirrors the
/// repo's `WorkspaceSnapshotID` layout (26 chars, Crockford base32,
/// time-ordered prefix) but is defined here so this file stays Foundation-only
/// and free of any app-only coupling — it compiles into the CLI target
/// unchanged. Not a full ULID; sufficient for unique, sortable config ids.
enum AgentConfigID {
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(
        now: Date = Date(),
        random: () -> UInt64 = AgentConfigID.defaultRandom
    ) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        var out = ""
        out.reserveCapacity(26)
        var t = millis
        var timeChars = Array(repeating: Character("0"), count: 10)
        for i in (0..<10).reversed() {
            timeChars[i] = alphabet[Int(t & 0x1F)]
            t >>= 5
        }
        for c in timeChars { out.append(c) }
        // 80 bits of random across two 40-bit halves so no shift exceeds range.
        let r1 = random()
        let r2 = random()
        let upper40: UInt64 = r1 >> 24
        let lower40: UInt64 = ((r1 & 0xFFFFFF) << 16) | (r2 >> 48)
        var randChars = Array(repeating: Character("0"), count: 16)
        var accLower = lower40
        for i in (8..<16).reversed() {
            randChars[i] = alphabet[Int(accLower & 0x1F)]
            accLower >>= 5
        }
        var accUpper = upper40
        for i in (0..<8).reversed() {
            randChars[i] = alphabet[Int(accUpper & 0x1F)]
            accUpper >>= 5
        }
        for c in randChars { out.append(c) }
        return out
    }

    private static func defaultRandom() -> UInt64 {
        var rng = SystemRandomNumberGenerator()
        return rng.next()
    }
}

// MARK: - Store

/// File-backed store for `agent-configs.json` at the c11 state root.
///
/// **Shape.** A `Sendable` value type over an injected `directory` (the
/// `WorkspaceSnapshotStore` template), with a computed `current` that
/// recomputes from disk on every access (the `DefaultAgentConfigStore`
/// recompute-on-access ergonomic) so socket-driven writes from another path
/// propagate without any in-memory cache to invalidate. `static let shared`
/// on a `Sendable` value type is concurrency-safe with no `@unchecked` escape.
///
/// **Persistence.** Atomic writes (`Data.write(to:options:.atomic)`), state
/// directory created on demand, typed `StoreError` modeled on
/// `WorkspaceSnapshotStore` (a stable `code` plus a human `description`).
/// Foundation-only, not `@MainActor`; safe to call off the main thread. The
/// file is the contract — every reader/writer goes through this one path, and
/// the CLI reads it with the app down.
///
/// **Concurrency contract.** Mutators are load → mutate → atomic-save with **no
/// cross-mutator serialization**: the contract is **last-writer-wins**, exactly
/// as `WorkspaceSnapshotStore` / `DefaultAgentConfigStore`. Two concurrent
/// mutators can lose one update; v1 accepts this.
///
/// **Corruption.** A missing, unreadable, malformed, or wrong-`schema_version`
/// file resolves to `AgentConfigLibraryFile.factory` (design §5.6) — reads
/// never throw into a launch path.
struct AgentConfigLibraryStore: Sendable {

    /// Filename at the state root.
    static let fileName = "agent-configs.json"

    private let directory: URL
    private let fileManager: FileManager

    /// Default instance rooted at the resolved c11 state root
    /// (`EventLogLayout.defaultStateURL`, which already runs
    /// `StateDirectoryMigration.ensureMigrated`). Falls back to the app-support
    /// path directly if the resolver throws so `shared` is always usable.
    static let shared = AgentConfigLibraryStore()

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = AgentConfigLibraryStore.defaultDirectory(fileManager: fileManager)
        }
        self.fileManager = fileManager
    }

    /// Resolve the state root the same way the events tree does, so
    /// `agent-configs.json` lands beside the mailbox/events trees under the
    /// migration latch.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        if let url = try? EventLogLayout.defaultStateURL(fileManager: fileManager) {
            return url
        }
        // Extremely defensive fallback; `defaultStateURL` only throws when
        // application-support is unavailable, which effectively never happens
        // on a real macOS session.
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base.appendingPathComponent(EventLogLayout.stateDirectoryName, isDirectory: true)
    }

    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: Errors

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case createDirectoryFailed(String, underlying: String)
        case encodeFailed(String)
        case writeFailed(String, underlying: String)
        case configNotFound(String)
        case indexOutOfRange(Int)
        /// The config cannot launch as written, so it may not become the pinned
        /// default (C11-203 A2 — an unlaunchable pin is what killed the A button).
        case configUnlaunchable(String)

        var code: String {
            switch self {
            case .createDirectoryFailed: return "agent_config_dir_create_failed"
            case .encodeFailed:          return "agent_config_encode_failed"
            case .writeFailed:           return "agent_config_write_failed"
            case .configNotFound:        return "agent_config_not_found"
            case .indexOutOfRange:       return "agent_config_index_out_of_range"
            case .configUnlaunchable:    return "agent_config_unlaunchable"
            }
        }

        var description: String {
            switch self {
            case .createDirectoryFailed(let path, let err):
                return "agent-configs dir create failed at \(path): \(err)"
            case .encodeFailed(let detail):
                return "agent-configs encode failed: \(detail)"
            case .writeFailed(let path, let err):
                return "agent-configs write failed at \(path): \(err)"
            case .configNotFound(let id):
                return "agent config '\(id)' not found"
            case .indexOutOfRange(let index):
                return "reorder index \(index) out of range"
            case .configUnlaunchable(let id):
                return "agent config '\(id)' cannot launch as written (custom harness with no command) and cannot be the default"
            }
        }
    }

    // MARK: Codec

    /// ISO-8601 with fractional seconds. A local copy of the
    /// `workspaceSnapshotDateFormatter` idiom so this file carries no coupling
    /// to the snapshot store (which is app-target-only).
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.dateFormatter.date(from: raw) { return date }
            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            if let date = legacy.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date string, got '\(raw)'"
            )
        }
        return decoder
    }

    // MARK: Read

    /// The current library, recomputed from disk on every access and passed
    /// through `healed()` (C11-203 A2) so a drifted factory seed or an
    /// unlaunchable pin can never reach a launch path. A missing, unreadable,
    /// malformed, or wrong-`schema_version` file heals to `.factory` — this
    /// never throws (design §5.6).
    ///
    /// Healing is read-only: mutators load through `current`, so the repair
    /// persists on the next write rather than turning a getter into a writer.
    var current: AgentConfigLibraryFile {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .factory
        }
        guard let file = try? Self.makeDecoder().decode(AgentConfigLibraryFile.self, from: data),
              file.schemaVersion == AgentConfigLibraryFile.currentSchemaVersion else {
            return .factory
        }
        return file.healed()
    }

    /// The config a plain left-click launches (design §3, as narrowed by
    /// C11-203 B2): always the pinned config. The config whose id equals
    /// `default.config_id`; if that id names no config, the factory seed (never
    /// crash).
    func effectiveDefault() -> SavedAgentConfig {
        pinnedConfig(in: current)
    }

    /// The pinned config, or the factory seed if the pointer dangles. Also
    /// falls back when the pointed-to config is provably unlaunchable and a
    /// launchable sibling exists — `current` already heals that case, but this
    /// keeps the fallback correct for a caller that composed a file by hand
    /// (C11-203 A2).
    private func pinnedConfig(in file: AgentConfigLibraryFile) -> SavedAgentConfig {
        if let match = file.configs.first(where: { $0.id == file.default.configId }) {
            guard match.config.isProvablyUnlaunchable else { return match }
            return file.firstLaunchableConfig ?? match
        }
        return AgentConfigLibraryFile.factory.configs[0]
    }

    // MARK: Write

    private func save(_ file: AgentConfigLibraryFile) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.createDirectoryFailed(directory.path, underlying: "\(error)")
        }
        let data: Data
        do {
            data = try Self.makeEncoder().encode(file)
        } catch {
            throw StoreError.encodeFailed("\(error)")
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(fileURL.path, underlying: "\(error)")
        }
    }

    /// Overwrite the whole file. Exposed for callers that compose a full
    /// document; mutators below are the ergonomic path.
    func write(_ file: AgentConfigLibraryFile) throws {
        try save(file)
    }

    // MARK: Mutators (load → mutate → atomic-save; last-writer-wins)

    /// Append a config. If `config.id` is empty a fresh ULID-shaped id is
    /// assigned; `order` is set to the next free slot. Returns the stored
    /// config (with its resolved id/order).
    @discardableResult
    func add(_ config: SavedAgentConfig) throws -> SavedAgentConfig {
        var file = current
        var stored = config
        if stored.id.isEmpty {
            stored.id = AgentConfigID.generate()
        }
        let nextOrder = (file.configs.map { $0.order }.max() ?? -1) + 1
        stored.order = nextOrder
        file.configs.append(stored)
        try save(file)
        return stored
    }

    /// Remove a config by id. Throws `.configNotFound` if absent. Reindexes the
    /// remaining configs to keep `order` dense (0-based). If the removed config
    /// was the pinned default, the pointer is repointed at the lowest-ordered
    /// surviving config (or the factory seed if the library becomes empty).
    func remove(id: String) throws {
        var file = current
        guard file.configs.contains(where: { $0.id == id }) else {
            throw StoreError.configNotFound(id)
        }
        file.configs.removeAll { $0.id == id }
        reindex(&file.configs)
        if file.configs.isEmpty {
            // Library emptied (reachable via a `write()`-composed document even
            // when the removed id wasn't the pinned one): reseed the factory
            // config so the pointer always resolves.
            let seed = AgentConfigLibraryFile.factory.configs[0]
            file.configs = [seed]
            file.default = AgentConfigDefault(mode: file.default.mode, configId: seed.id)
        } else if file.default.configId == id {
            // Removed the pinned config: repoint at the lowest-ordered survivor.
            if let first = file.configs.min(by: { $0.order < $1.order }) {
                file.default.configId = first.id
            }
        }
        try save(file)
    }

    /// Move a config to a new position and reindex `order` to match the new
    /// sequence. Valid range is `[0, count-1]`; an out-of-range `index` throws
    /// `.indexOutOfRange` (no clamping).
    func reorder(id: String, to index: Int) throws {
        var file = current
        var ordered = file.configs.sorted { $0.order < $1.order }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else {
            throw StoreError.configNotFound(id)
        }
        guard index >= 0 && index <= ordered.count - 1 else {
            throw StoreError.indexOutOfRange(index)
        }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: index)
        reindex(&ordered)
        file.configs = ordered
        try save(file)
    }

    /// Pin a config as the default. Throws if the id names no config, or if the
    /// config is provably unlaunchable (C11-203 A2): pinning a recipe that
    /// resolves to an empty command is exactly the state that left the A button
    /// silently dead, so the store refuses it at the write rather than healing
    /// it back on every subsequent read.
    func setDefault(configId: String) throws {
        var file = current
        guard let target = file.configs.first(where: { $0.id == configId }) else {
            throw StoreError.configNotFound(configId)
        }
        guard !target.config.isProvablyUnlaunchable else {
            throw StoreError.configUnlaunchable(configId)
        }
        file.default = AgentConfigDefault(mode: .pinned, configId: configId)
        try save(file)
    }

    /// Persist the most-recent observation (design §2.3/§4). Durable telemetry:
    /// nothing reads it back for resolution. The launch-composition layer calls
    /// this with a resolved observation; the store only writes it.
    func recordRecent(_ recent: RecentAgentConfig) throws {
        var file = current
        file.recent = recent
        try save(file)
    }

    /// Re-densify `order` to 0-based sequence following array order.
    private func reindex(_ configs: inout [SavedAgentConfig]) {
        for i in configs.indices {
            configs[i].order = i
        }
    }
}
