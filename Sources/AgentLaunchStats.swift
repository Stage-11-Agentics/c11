// AgentLaunchStats.swift
//
// The launch-stats rail (C11-178, design §2.4 / §4.1 / §4.4 / §1.2).
//
// One `recordLaunch(resolved, source)` sink that, for every launch c11 itself
// performs (rail 1), (a) appends one line to `agent-launches.jsonl`, (b) bumps
// the `agent-launch-stats.json` aggregate, and (c) updates a source-ranked
// "most-recent" observation. Windowed queries scan the jsonl; the aggregate
// answers all-time in O(1). The log stores only resolved axes + system-prompt
// mode — NEVER prompt or command text — so it stays lean and non-sensitive.
//
// Files live at the c11 state root (`EventLogLayout.defaultStateURL()`), are
// written atomically, and are readable by the CLI with the app down (this file
// is compiled into both the `c11` app and `c11-cli` targets, mirroring
// `EventLogLayout`; it takes no app-only dependency).
//
// Coordination (C11-178 ↔ C11-176): the design homes `recent` inside
// `agent-configs.json`, which C11-176 owns. To keep this ticket's writes off
// that shared file, `recent` lives here in `agent-launch-stats.json`. The
// overlay ticket C11-179 reconciles the two homes.

import Foundation

// MARK: - Axis / source vocabulary

/// The call-site tag written to each jsonl line's `source` field (design §2.4).
public enum AgentLaunchSource: String, Codable, Sendable, CaseIterable {
    case aButton = "a-button"
    case launchAgent = "launch-agent"
    case socket
    case blueprint
    case fader
}

/// The ingestion rail that produced a most-recent observation. Used only for
/// the recency tiebreak (design §4.4): a fresh launch is never clobbered by a
/// lagging scrape. Rail 1 (this ticket) only ever emits `.launch`; the
/// `.sessionHook` / `.scrape` cases are the seam Rails 2/3 use in v2.
public enum RecentObservationSource: String, Codable, Sendable {
    case launch
    case sessionHook
    case scrape

    /// Higher wins a genuine timestamp tie. `launch ≥ sessionHook ≥ scrape`.
    var rank: Int {
        switch self {
        case .launch: return 3
        case .sessionHook: return 2
        case .scrape: return 1
        }
    }
}

// MARK: - Input to the sink

/// The resolved launch axes known at a rail-1 launch site. `provider` is derived
/// inside the sink (never passed in), so a call site supplies only what it holds.
/// Blank strings are normalized to nil so the aggregate never gains a `""` key.
public struct ResolvedLaunch: Equatable, Sendable {
    public var harness: String
    public var model: String?
    public var effort: String?
    public var systemPromptMode: String?   // inherit|append|replace; nil in v1 (no per-launch selection yet)
    public var configId: String?           // OPTIONAL — ad-hoc launches carry none

    public init(
        harness: String,
        model: String? = nil,
        effort: String? = nil,
        systemPromptMode: String? = nil,
        configId: String? = nil
    ) {
        self.harness = harness
        self.model = AgentLaunchStats.nilIfBlank(model)
        self.effort = AgentLaunchStats.nilIfBlank(effort)
        self.systemPromptMode = AgentLaunchStats.nilIfBlank(systemPromptMode)
        self.configId = AgentLaunchStats.nilIfBlank(configId)
    }
}

// MARK: - Persisted record shapes

/// One line in `agent-launches.jsonl`. Resolved axes only; no prompt/command text.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var ts: Date
    public var harness: String
    public var model: String?
    public var effort: String?
    public var provider: String?
    public var configId: String?
    public var systemPromptMode: String?
    public var source: String

    enum CodingKeys: String, CodingKey {
        case ts, harness, model, effort, provider
        case configId = "config_id"
        case systemPromptMode = "system_prompt_mode"
        case source
    }
}

/// The most-recent observation. Homed in `agent-launch-stats.json` for this
/// ticket (see coordination note above).
public struct RecentObservation: Codable, Equatable, Sendable {
    public var configId: String?
    public var harness: String
    public var model: String?
    public var effort: String?
    public var provider: String?
    public var systemPromptMode: String?
    public var observedAt: Date
    public var source: String   // RecentObservationSource.rawValue
    public var fieldSources: [String: String]?

    enum CodingKeys: String, CodingKey {
        case configId = "config_id"
        case harness, model, effort, provider
        case systemPromptMode = "system_prompt_mode"
        case observedAt = "observed_at"
        case source
        case fieldSources = "field_sources"
    }
}

/// The three all-time tallies, nested under `totals` to match design §2.4 verbatim
/// (C11-179's `c11 config stats` reader consumes this exact shape).
public struct AggregateTotals: Codable, Equatable, Sendable {
    public var byModel: [String: Int]
    public var byHarness: [String: Int]
    public var byProvider: [String: Int]

    enum CodingKeys: String, CodingKey {
        case byModel = "by_model"
        case byHarness = "by_harness"
        case byProvider = "by_provider"
    }

    public static let empty = AggregateTotals(byModel: [:], byHarness: [:], byProvider: [:])
}

/// `agent-launch-stats.json` — the rolled-up aggregate for O(1) all-time queries,
/// plus this ticket's home for `recent`.
public struct AgentLaunchStatsAggregate: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var since: Date?
    public var totals: AggregateTotals
    public var count: Int
    public var lastTs: Date?
    public var recent: RecentObservation?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case since
        case totals
        case count
        case lastTs = "last_ts"
        case recent
    }

    public static let currentSchemaVersion = 1

    public static var empty: AgentLaunchStatsAggregate {
        AgentLaunchStatsAggregate(
            schemaVersion: currentSchemaVersion,
            since: nil,
            totals: .empty,
            count: 0,
            lastTs: nil,
            recent: nil
        )
    }
}

// MARK: - Windowed query result

public enum StatsWindow: Equatable, Sendable {
    case today
    case days(Int)
    case all
}

public enum StatsAxis: String, Sendable {
    case model
    case harness
    case provider
}

/// The answer to a windowed query.
public struct LaunchStatsResult: Equatable, Sendable {
    public var window: StatsWindow
    public var axis: StatsAxis
    public var tally: [String: Int]
    public var count: Int
    public var lastTs: Date?
}

// MARK: - Provider derivation + shared helpers (design §1.2)

public enum AgentLaunchStats {
    /// `nil` for empty/whitespace-only strings, else the trimmed value. Keeps the
    /// aggregate free of `""` keys and normalizes inherit-blank axes to absent.
    static func nilIfBlank(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Derive the provider facet from the harness (design §1.2). Fixed harnesses
    /// map to a constant; router harnesses (opencode/pi/omp) take the model-id
    /// prefix before the first `/`. Unknown/no-slash → nil (never wrong-but-confident).
    public static func provider(harness: String, model: String?) -> String? {
        switch harness {
        case "claude-code": return "anthropic"
        case "codex": return "openai"
        case "grok": return "xai"
        case "kimi": return "moonshot"
        case "github-copilot": return "github"
        case "opencode", "pi", "omp":
            guard let m = nilIfBlank(model), let slash = m.firstIndex(of: "/") else { return nil }
            let prefix = String(m[..<slash])
            return nilIfBlank(prefix)
        default:
            return nil
        }
    }
}

// MARK: - ISO8601 coding

/// Fractional-second ISO8601, matching `WorkspaceSnapshotStore`'s human/CLI-readable
/// date convention. Encodes with `Z`; decodes with or without fractional seconds.
enum AgentLaunchStatsDate {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(string(from: date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = AgentLaunchStatsDate.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO8601 date: \(s)")
            }
            return date
        }
        return d
    }
}

// MARK: - Errors

public enum LaunchStatsStoreError: Error, Equatable, CustomStringConvertible {
    case stateDirectoryUnavailable
    case createDirectoryFailed(String)
    case encodeFailed(String)
    case writeFailed(String)

    public var code: String {
        switch self {
        case .stateDirectoryUnavailable: return "launch_stats_state_dir_unavailable"
        case .createDirectoryFailed: return "launch_stats_create_dir_failed"
        case .encodeFailed: return "launch_stats_encode_failed"
        case .writeFailed: return "launch_stats_write_failed"
        }
    }

    public var description: String {
        switch self {
        case .stateDirectoryUnavailable: return "launch stats: state directory unavailable"
        case .createDirectoryFailed(let p): return "launch stats: failed to create directory \(p)"
        case .encodeFailed(let e): return "launch stats: encode failed: \(e)"
        case .writeFailed(let p): return "launch stats: write failed: \(p)"
        }
    }
}

// MARK: - The store / sink

/// Owns the two files and the record → append + aggregate + recent pipeline.
/// A single private serial queue serializes all three mutations so the jsonl
/// line, the aggregate bump, and the recent update never tear against each other.
///
/// Safe to call off-main. Reads tolerate missing files (fresh install → empty).
public final class AgentLaunchStatsStore: @unchecked Sendable {
    public static let jsonlName = "agent-launches.jsonl"
    public static let aggregateName = "agent-launch-stats.json"

    private let directory: URL
    private let clock: () -> Date
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "com.stage11.c11.agent-launch-stats")
    private var appendHandle: FileHandle?

    /// - Parameters:
    ///   - directory: state root holding the two files. Defaults to
    ///     `EventLogLayout.defaultStateURL()` (the c11 state root).
    ///   - clock: injectable time source (tests pin it).
    ///   - calendar: calendar for the `.today` day boundary. Defaults to
    ///     `.current` (the operator's local day); tests inject a fixed-timezone
    ///     calendar so the boundary is deterministic.
    public init(directory: URL, clock: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.directory = directory
        self.clock = clock
        self.calendar = calendar
    }

    /// Process-wide store rooted at the c11 state directory. `nil` only if the
    /// state directory is unresolvable (e.g. sandboxed test host with no app
    /// support dir); rail-1 call sites no-op through the optional in that case.
    public static let shared: AgentLaunchStatsStore? = try? makeDefault()

    /// Production convenience: resolve the c11 state root. Throws if unavailable.
    public static func makeDefault(clock: @escaping () -> Date = { Date() }) throws -> AgentLaunchStatsStore {
        let root: URL
        do {
            root = try EventLogLayout.defaultStateURL()
        } catch {
            throw LaunchStatsStoreError.stateDirectoryUnavailable
        }
        return AgentLaunchStatsStore(directory: root, clock: clock)
    }

    private var jsonlURL: URL { directory.appendingPathComponent(Self.jsonlName) }
    private var aggregateURL: URL { directory.appendingPathComponent(Self.aggregateName) }

    // MARK: Sink

    /// The one sink every rail-1 launch calls. Appends a jsonl line, bumps the
    /// aggregate, and updates `recent` (source `.launch`, so it outranks any
    /// lagging scrape). Best-effort: append/aggregate failures are swallowed so a
    /// telemetry hiccup never fails a launch; the two are still consistent within
    /// a successful call because both run under the serial queue.
    public func recordLaunch(_ resolved: ResolvedLaunch, source: AgentLaunchSource) {
        let ts = clock()
        let provider = AgentLaunchStats.provider(harness: resolved.harness, model: resolved.model)
        let record = LaunchRecord(
            ts: ts,
            harness: resolved.harness,
            model: resolved.model,
            effort: resolved.effort,
            provider: provider,
            configId: resolved.configId,
            systemPromptMode: resolved.systemPromptMode,
            source: source.rawValue
        )
        let observation = RecentObservation(
            configId: resolved.configId,
            harness: resolved.harness,
            model: resolved.model,
            effort: resolved.effort,
            provider: provider,
            systemPromptMode: resolved.systemPromptMode,
            observedAt: ts,
            source: RecentObservationSource.launch.rawValue,
            fieldSources: nil
        )
        queue.sync {
            appendLineLocked(record)
            var agg = loadAggregateLocked()
            bumpLocked(&agg, with: record)
            applyRecentLocked(&agg, incoming: observation)
            try? writeAggregateLocked(agg)
        }
    }

    /// Source-ranked update of `recent`. Also the seam Rails 2/3 use in v2.
    /// Returns true if the stored observation was replaced.
    @discardableResult
    public func updateRecent(_ incoming: RecentObservation) -> Bool {
        queue.sync {
            var agg = loadAggregateLocked()
            let replaced = applyRecentLocked(&agg, incoming: incoming)
            if replaced { try? writeAggregateLocked(agg) }
            return replaced
        }
    }

    /// Should `incoming` replace `stored`? Recency dominates; rank breaks a
    /// genuine timestamp tie. A stale (older) observation never wins — so a
    /// lagging scrape can never clobber a newer launch (design §4.4).
    static func shouldReplace(stored: RecentObservation?, incoming: RecentObservation) -> Bool {
        guard let stored = stored else { return true }
        if incoming.observedAt > stored.observedAt { return true }
        if incoming.observedAt == stored.observedAt {
            let incomingRank = RecentObservationSource(rawValue: incoming.source)?.rank ?? 0
            let storedRank = RecentObservationSource(rawValue: stored.source)?.rank ?? 0
            return incomingRank >= storedRank
        }
        return false
    }

    // MARK: Queries

    /// Load the current aggregate (all-time O(1) source of truth).
    public func aggregate() -> AgentLaunchStatsAggregate {
        queue.sync { loadAggregateLocked() }
    }

    /// The current most-recent observation, if any.
    public func recent() -> RecentObservation? {
        queue.sync { loadAggregateLocked().recent }
    }

    /// Windowed query. `.all` reads the aggregate (no scan); `.today`/`.days`
    /// scan the jsonl and tally by the chosen axis. `now` is injectable for tests.
    public func stats(window: StatsWindow, by axis: StatsAxis, now: Date? = nil) -> LaunchStatsResult {
        queue.sync {
            let reference = now ?? clock()
            switch window {
            case .all:
                let agg = loadAggregateLocked()
                return LaunchStatsResult(
                    window: .all,
                    axis: axis,
                    tally: tally(from: agg.totals, axis: axis),
                    count: agg.count,
                    lastTs: agg.lastTs
                )
            case .today, .days:
                let cutoff = cutoffDate(window: window, now: reference)
                let records = scanRecordsLocked().filter { $0.ts >= cutoff }
                var tally: [String: Int] = [:]
                var last: Date?
                for r in records {
                    if let key = axisKey(r, axis: axis) { tally[key, default: 0] += 1 }
                    if last == nil || r.ts > last! { last = r.ts }
                }
                return LaunchStatsResult(
                    window: window,
                    axis: axis,
                    tally: tally,
                    count: records.count,
                    lastTs: last
                )
            }
        }
    }

    /// Rescan the whole jsonl and rewrite the aggregate from scratch (drift
    /// recovery — design §2.4 anticipates this since `.all` reads the aggregate,
    /// not the jsonl). Preserves the existing `recent`. Returns the rebuilt value.
    @discardableResult
    public func rebuildAggregate() -> AgentLaunchStatsAggregate {
        queue.sync {
            let existingRecent = loadAggregateLocked().recent
            let records = scanRecordsLocked()
            var agg = AgentLaunchStatsAggregate.empty
            agg.recent = existingRecent
            for r in records { bumpLocked(&agg, with: r) }
            try? writeAggregateLocked(agg)
            return agg
        }
    }

    /// Test/shutdown barrier: block until all queued work has drained and close
    /// the append handle.
    public func flush() {
        queue.sync {
            try? appendHandle?.close()
            appendHandle = nil
        }
    }

    // MARK: - Locked internals (queue-confined)

    private func cutoffDate(window: StatsWindow, now: Date) -> Date {
        switch window {
        case .today:
            return calendar.startOfDay(for: now)
        case .days(let n):
            return now.addingTimeInterval(-Double(max(0, n)) * 86_400)
        case .all:
            return .distantPast
        }
    }

    private func tally(from totals: AggregateTotals, axis: StatsAxis) -> [String: Int] {
        switch axis {
        case .model: return totals.byModel
        case .harness: return totals.byHarness
        case .provider: return totals.byProvider
        }
    }

    private func axisKey(_ r: LaunchRecord, axis: StatsAxis) -> String? {
        switch axis {
        case .model: return AgentLaunchStats.nilIfBlank(r.model)
        case .harness: return AgentLaunchStats.nilIfBlank(r.harness)
        case .provider: return AgentLaunchStats.nilIfBlank(r.provider)
        }
    }

    private func bumpLocked(_ agg: inout AgentLaunchStatsAggregate, with record: LaunchRecord) {
        if agg.since == nil { agg.since = record.ts }
        if let m = AgentLaunchStats.nilIfBlank(record.model) { agg.totals.byModel[m, default: 0] += 1 }
        if let h = AgentLaunchStats.nilIfBlank(record.harness) { agg.totals.byHarness[h, default: 0] += 1 }
        if let p = AgentLaunchStats.nilIfBlank(record.provider) { agg.totals.byProvider[p, default: 0] += 1 }
        agg.count += 1
        if agg.lastTs == nil || record.ts > agg.lastTs! { agg.lastTs = record.ts }
    }

    @discardableResult
    private func applyRecentLocked(_ agg: inout AgentLaunchStatsAggregate, incoming: RecentObservation) -> Bool {
        guard Self.shouldReplace(stored: agg.recent, incoming: incoming) else { return false }
        agg.recent = incoming
        return true
    }

    private func loadAggregateLocked() -> AgentLaunchStatsAggregate {
        guard let data = try? Data(contentsOf: aggregateURL), !data.isEmpty else {
            return .empty
        }
        guard let agg = try? AgentLaunchStatsDate.makeDecoder().decode(AgentLaunchStatsAggregate.self, from: data) else {
            // Corrupt aggregate: fall back to empty. The jsonl remains ground
            // truth; rebuildAggregate() can restore all-time counts.
            return .empty
        }
        return agg
    }

    private func writeAggregateLocked(_ agg: AgentLaunchStatsAggregate) throws {
        try ensureDirectoryLocked()
        let data: Data
        do {
            data = try AgentLaunchStatsDate.makeEncoder().encode(agg)
        } catch {
            throw LaunchStatsStoreError.encodeFailed("\(error)")
        }
        do {
            try data.write(to: aggregateURL, options: .atomic)
        } catch {
            throw LaunchStatsStoreError.writeFailed(aggregateURL.path)
        }
    }

    private func scanRecordsLocked() -> [LaunchRecord] {
        guard let data = try? Data(contentsOf: jsonlURL), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = AgentLaunchStatsDate.makeDecoder()
        var out: [LaunchRecord] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { return }
            // Tolerant: skip unparseable lines rather than throwing.
            if let record = try? decoder.decode(LaunchRecord.self, from: lineData) {
                out.append(record)
            }
        }
        return out
    }

    private func appendLineLocked(_ record: LaunchRecord) {
        guard let data = try? AgentLaunchStatsDate.makeEncoder().encode(record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        do {
            if appendHandle == nil {
                try ensureDirectoryLocked()
                if !FileManager.default.fileExists(atPath: jsonlURL.path) {
                    FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
                }
                let fh = try FileHandle(forWritingTo: jsonlURL)
                try fh.seekToEnd()
                appendHandle = fh
            }
            try appendHandle?.write(contentsOf: lineData)
        } catch {
            // Best-effort: drop the handle so the next call reopens from scratch.
            try? appendHandle?.close()
            appendHandle = nil
        }
    }

    private func ensureDirectoryLocked() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LaunchStatsStoreError.createDirectoryFailed(directory.path)
        }
    }
}
