import Foundation

// Prompt cache reports: cache observations that reach c11 over its socket
// (`agent.prompt_cache.report`) instead of from a file c11 reads.
//
// - c11's own runtime plugins report each model request: OpenCode
//   (`skills/opencode-plugins/c11-notify.js`), Pi (`Resources/bin/pi-lifecycle.ts`)
//   and omp (`Resources/bin/omp-prompt-cache.ts`). A custom kind's own wrapper or
//   plugin can report the same way.
// - The operator's own Claude Code statusline can report Claude's exact
//   `prompt_cache` object. c11 documents that snippet and never writes it.
// - A reporter can say something replaced the cached prefix (`reset`: a
//   compaction or model switch), or that it cannot tell (`unknown`), and c11
//   shows that rather than a wrong state.
//
// Reports are parsed and validated on the socket worker and land in a
// lock-guarded store, one slot per panel. The 10 s liveness sweep reads the
// slot, so any number of reports between sweeps costs the main thread nothing.
// Only counts, times, provider and model ids are kept; no prompt text reaches c11.

/// One validated report.
enum PromptCacheReport: Equatable, Sendable {
    /// A model request the reporter saw go out, with its usage when known.
    case request(Request)
    /// The harness's own view of its cache (Claude Code's statusline `prompt_cache`).
    case state(ExactState)
    /// Something replaced the cached prefix: cold from `at` until the next request.
    case reset(PromptCacheObservation.Reset, at: Date)
    /// The reporter cannot tell; show no cache state for the panel.
    case unknown

    struct Request: Equatable, Sendable {
        /// When the request was sent.
        var at: Date
        var provider: String?
        var model: String?
        /// Uncached input; with the reads and writes, the prompt's size.
        var inputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        /// The cache lifetime the harness asked for (Anthropic's 5m or 1h).
        var ttl: TimeInterval?

        /// A report without usage says only that a request went out.
        var hasUsage: Bool { inputTokens != nil || cacheReadTokens != nil || cacheWriteTokens != nil }
    }

    struct ExactState: Equatable, Sendable {
        var warm: Bool
        var expiresAt: Date?
        var ttl: TimeInterval
        var misses: Int?
        var recacheTokens: Int?
    }
}

/// Validates the `agent.prompt_cache.report` params. Pure: no clocks or stores.
enum PromptCacheReportParser {
    struct Failure: Error, Equatable {
        let message: String
    }

    static let requestKeys: Set<String> = [
        "at_ms", "provider", "model", "input_tokens", "cache_read_tokens", "cache_write_tokens", "ttl_seconds",
    ]
    /// A request may be stamped a little after c11 receives it (clock jitter
    /// between processes); further ahead is a caller error.
    static let futureTolerance: TimeInterval = 60
    static let maxTokens = 100_000_000
    static let maxIdentifierLength = 128

    /// Every accepted spelling of the panel, canonical first, then of the
    /// caller's panel the CLI attributes from its environment.
    static let panelKeys = spellings(of: "surface_id")
    static let callerPanelKeys = spellings(of: "caller_surface_id")

    static let payloadKeys = ["request", "prompt_cache", "reset", "unknown"]
    /// Top-level keys: the panel (any accepted spelling) and exactly one payload.
    static let allowedKeys = Set(panelKeys + callerPanelKeys + payloadKeys)
    /// Epoch milliseconds before 2001: a caller sent seconds.
    static let minimumEpochMilliseconds: Double = 1_000_000_000_000

    private static func spellings(of canonical: String) -> [String] {
        [canonical] + (LegacyWireAliases.paramSources.first { $0.target == canonical }?.sources ?? [])
    }

    static func parse(_ params: [String: Any], now: Date) -> Result<(panelId: UUID, report: PromptCacheReport), Failure> {
        if let unexpected = params.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
            return .failure(Failure(message: "unknown parameter '\(unexpected)'"))
        }
        // An explicit panel wins over the caller the CLI attributes from its env.
        let rawPanel = panelKeys.lazy.compactMap { params[$0] }.first
            ?? callerPanelKeys.lazy.compactMap { params[$0] }.first
        guard let rawPanel else {
            return .failure(Failure(message: "panel_id is required outside a c11 panel"))
        }
        guard let panelString = rawPanel as? String,
              let panelId = UUID(uuidString: panelString.trimmingCharacters(in: .whitespaces)) else {
            return .failure(Failure(message: "panel_id must be a panel UUID"))
        }
        let payloads = payloadKeys.filter { params[$0] != nil }
        guard payloads.count == 1 else {
            return .failure(Failure(message: "exactly one of request, prompt_cache, reset or unknown is required"))
        }
        let report: Result<PromptCacheReport, Failure>
        switch payloads[0] {
        case "request": report = parseRequest(params["request"], now: now)
        case "prompt_cache": report = parseExactState(params["prompt_cache"], now: now)
        case "reset": report = parseReset(params["reset"], now: now)
        default: report = parseUnknown(params["unknown"])
        }
        return report.map { (panelId: panelId, report: $0) }
    }

    private static func parseRequest(_ raw: Any?, now: Date) -> Result<PromptCacheReport, Failure> {
        guard let object = raw as? [String: Any] else {
            return .failure(Failure(message: "request must be an object"))
        }
        if let unexpected = object.keys.filter({ !requestKeys.contains($0) }).sorted().first {
            return .failure(Failure(message: "unknown request field '\(unexpected)'"))
        }
        var request = PromptCacheReport.Request(at: now)
        switch time(object["at_ms"], field: "request.at_ms", now: now) {
        case .failure(let failure): return .failure(failure)
        case .success(let at): request.at = at
        }
        let identifierFields: [(String, WritableKeyPath<PromptCacheReport.Request, String?>)] = [
            ("provider", \.provider), ("model", \.model),
        ]
        for (key, path) in identifierFields {
            guard let value = object[key] else { continue }
            guard let string = value as? String, string.count <= maxIdentifierLength else {
                return .failure(Failure(message: "request.\(key) must be a string of at most \(maxIdentifierLength) characters"))
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            request[keyPath: path] = trimmed.isEmpty ? nil : trimmed
        }
        let tokenFields: [(String, WritableKeyPath<PromptCacheReport.Request, Int?>)] = [
            ("input_tokens", \.inputTokens), ("cache_read_tokens", \.cacheReadTokens), ("cache_write_tokens", \.cacheWriteTokens),
        ]
        for (key, path) in tokenFields {
            guard let value = object[key] else { continue }
            guard let count = tokenCount(value) else {
                return .failure(Failure(message: "request.\(key) must be a non-negative integer"))
            }
            request[keyPath: path] = count
        }
        if let rawTTL = object["ttl_seconds"] {
            guard let ttl = number(rawTTL), PromptCachePolicy.reportedTTLRange.contains(ttl) else {
                return .failure(Failure(message: "request.ttl_seconds must be between 60 and 86400"))
            }
            request.ttl = ttl
        }
        return .success(.request(request))
    }

    /// Claude Code's statusline `prompt_cache` object, passed through as is.
    /// Fields c11 does not use (`hit_ratio`, and any added later) are ignored.
    private static func parseExactState(_ raw: Any?, now: Date) -> Result<PromptCacheReport, Failure> {
        guard let object = raw as? [String: Any] else {
            return .failure(Failure(message: "prompt_cache must be an object"))
        }
        guard let warm = object["warm"] as? Bool, isBool(object["warm"]) else {
            return .failure(Failure(message: "prompt_cache.warm must be a boolean"))
        }
        var ttl = PromptCachePolicy.anthropicDefaultTTL
        if let rawTTL = object["ttl"], !(rawTTL is NSNull) {
            guard let parsed = ttlSeconds(rawTTL), PromptCachePolicy.reportedTTLRange.contains(parsed) else {
                return .failure(Failure(message: "prompt_cache.ttl must be a lifetime such as \"5m\" or \"1h\""))
            }
            ttl = parsed
        }
        var expiresAt: Date?
        if let rawExpiry = object["expires_at"], !(rawExpiry is NSNull) {
            guard let seconds = number(rawExpiry), seconds > 0 else {
                return .failure(Failure(message: "prompt_cache.expires_at must be epoch seconds"))
            }
            let expiry = Date(timeIntervalSince1970: seconds)
            guard expiry <= now.addingTimeInterval(ttl + futureTolerance) else {
                return .failure(Failure(message: "prompt_cache.expires_at is further ahead than its ttl"))
            }
            expiresAt = expiry
        }
        var state = PromptCacheReport.ExactState(warm: warm, expiresAt: expiresAt, ttl: ttl)
        let countFields: [(String, WritableKeyPath<PromptCacheReport.ExactState, Int?>)] = [
            ("misses", \.misses), ("recache_tokens_if_cold", \.recacheTokens),
        ]
        for (key, path) in countFields {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard let count = tokenCount(value) else {
                return .failure(Failure(message: "prompt_cache.\(key) must be a non-negative integer"))
            }
            state[keyPath: path] = count
        }
        return .success(.state(state))
    }

    private static func parseReset(_ raw: Any?, now: Date) -> Result<PromptCacheReport, Failure> {
        guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: ["reason", "at_ms"]) else {
            return .failure(Failure(message: "reset must be {\"reason\": …, \"at_ms\": …}"))
        }
        let reason: PromptCacheObservation.Reset
        switch object["reason"] as? String {
        case "compaction": reason = .compaction
        case "model_switch": reason = .modelSwitch
        case "effort_change": reason = .effortChange
        default:
            return .failure(Failure(message: "reset.reason must be compaction, model_switch or effort_change"))
        }
        return time(object["at_ms"], field: "reset.at_ms", now: now).map { .reset(reason, at: $0) }
    }

    /// An optional epoch-milliseconds field; absent means now.
    private static func time(_ raw: Any?, field: String, now: Date) -> Result<Date, Failure> {
        guard let raw else { return .success(now) }
        guard let ms = number(raw), ms >= minimumEpochMilliseconds else {
            return .failure(Failure(message: "\(field) must be epoch milliseconds"))
        }
        let at = Date(timeIntervalSince1970: ms / 1000)
        guard at <= now.addingTimeInterval(futureTolerance) else {
            return .failure(Failure(message: "\(field) is in the future"))
        }
        return .success(at)
    }

    private static func parseUnknown(_ raw: Any?) -> Result<PromptCacheReport, Failure> {
        if isBool(raw), (raw as? Bool) == true { return .success(.unknown) }
        guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: ["reason"]) else {
            return .failure(Failure(message: "unknown must be true or {\"reason\": …}"))
        }
        if let reason = object["reason"] {
            guard let text = reason as? String, text.count <= 64 else {
                return .failure(Failure(message: "unknown.reason must be a string of at most 64 characters"))
            }
        }
        return .success(.unknown)
    }

    /// `"5m"`, `"1h"`, `"90s"`, or a number of seconds.
    static func ttlSeconds(_ raw: Any) -> TimeInterval? {
        if let seconds = number(raw) { return seconds }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
              let unit = text.last, let value = Double(text.dropLast()), value.isFinite, value > 0 else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        default: return nil
        }
    }

    private static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A finite JSON number (never a boolean).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func tokenCount(_ value: Any) -> Int? {
        guard let double = number(value), double >= 0, double <= Double(maxTokens),
              double == double.rounded() else { return nil }
        return Int(double)
    }
}

/// The latest reported prompt cache per panel. Thread-safe; every method is a
/// short critical section.
final class PromptCacheReportStore: @unchecked Sendable {
    static let shared = PromptCacheReportStore()

    /// More slots than this means callers are reporting for panels that do not
    /// exist; the oldest are dropped. The sweep prunes closed panels long before.
    static let capacity = 512

    struct Slot: Equatable, Sendable {
        /// What the reports establish; nil until a request shows cache use,
        /// and after an `unknown` report.
        var observation: PromptCacheObservation?
        /// The reporter said it cannot tell (a cache warmer is running).
        var unknown = false
        /// When c11 accepted the last report.
        var receivedAt: Date
        /// An implicit cache (no published lifetime) has shown a read, so the
        /// provider caches and its later requests count as cache evidence.
        var implicitCacheSeen = false
    }

    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]

    @discardableResult
    func record(_ report: PromptCacheReport, panelId: UUID, receivedAt: Date = Date()) -> Slot {
        lock.lock()
        defer { lock.unlock() }
        let slot = Self.fold(slots[panelId], report, receivedAt: receivedAt)
        slots[panelId] = slot
        if slots.count > Self.capacity,
           let oldest = slots.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            slots.removeValue(forKey: oldest)
        }
        return slot
    }

    func slot(forPanel panelId: UUID) -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        return slots[panelId]
    }

    /// Forget panels the sweep no longer sees.
    func retain(livePanels: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        slots = slots.filter { livePanels.contains($0.key) }
    }

    /// A panel whose agent left the foreground: its reports described that agent.
    func remove(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        slots.removeValue(forKey: panelId)
    }

    /// Apply one report to a panel's slot. Pure, so the rules are testable.
    static func fold(_ prior: Slot?, _ report: PromptCacheReport, receivedAt: Date) -> Slot {
        var slot = prior ?? Slot(receivedAt: receivedAt)
        slot.receivedAt = receivedAt
        switch report {
        case .unknown:
            slot.observation = nil
            slot.unknown = true
        case .state(let state):
            // `expires_at` already counts any keepalive touch. Without one, a
            // repeated report keeps the expiry it already established: a warm
            // one does not extend it, a cold one does not move it to now.
            let previousExpiry = slot.observation?.coldAt()
            let expiry: Date
            if state.warm {
                expiry = state.expiresAt
                    ?? previousExpiry.flatMap { $0 > receivedAt ? $0 : nil }
                    ?? receivedAt.addingTimeInterval(state.ttl)
            } else {
                expiry = min(state.expiresAt ?? previousExpiry.flatMap { $0 <= receivedAt ? $0 : nil } ?? receivedAt,
                             receivedAt)
            }
            slot.observation = PromptCacheObservation(
                requestAt: expiry.addingTimeInterval(-state.ttl),
                basis: .ttl(state.ttl),
                promptTokens: state.recacheTokens.flatMap { $0 > 0 ? $0 : nil },
                source: .statusline,
                misses: state.misses
            )
            slot.unknown = false
        case .reset(let reason, let at):
            // Before any request there is no cache to reset; an older reset
            // than the last request was already superseded by it.
            guard var current = slot.observation, at >= current.requestAt else { break }
            current.reset = reason
            current.resetAt = at
            slot.observation = current
            slot.unknown = false
        case .request(let request):
            slot.unknown = false
            // Reports can arrive out of order; one older than the last request
            // or reset changes nothing.
            if let current = slot.observation,
               request.at < current.requestAt || current.resetAt.map({ request.at <= $0 }) == true { break }
            guard request.hasUsage else {
                // A request went out and its usage is not in yet: it reads the
                // cache, so an established cache counts from it.
                if var current = slot.observation {
                    current.requestAt = request.at
                    current.reset = nil
                    current.resetAt = nil
                    slot.observation = current
                }
                break
            }
            let read = request.cacheReadTokens ?? 0
            let write = request.cacheWriteTokens ?? 0
            let basis = PromptCachePolicy.reportedBasis(provider: request.provider, model: request.model, ttl: request.ttl)
            let isCacheUse: Bool
            switch basis {
            case .ttl:
                // An explicit cache marks what it caches; a request that
                // touched none leaves the cache as it was.
                isCacheUse = read + write > 0
            case .estimate:
                // An implicit cache proves itself with its first read; its
                // first request, which writes it, reads nothing.
                if read > 0 { slot.implicitCacheSeen = true }
                isCacheUse = slot.implicitCacheSeen
            }
            guard isCacheUse else { break }
            let prompt = (request.inputTokens ?? 0) + read + write
            slot.observation = PromptCacheObservation(
                requestAt: request.at,
                basis: basis,
                promptTokens: prompt > 0 ? prompt : slot.observation?.promptTokens,
                source: .report
            )
        }
        return slot
    }

    /// The word the socket returns for a slot.
    static func stateWord(_ slot: Slot, now: Date) -> String {
        if slot.unknown { return "unknown" }
        guard let observation = slot.observation else { return "no_evidence" }
        return observation.isCold(at: now) ? "cold" : "warm"
    }
}

/// Which source describes a panel's prompt cache: c11's own transcript read or
/// a report. The one with the later evidence wins, and a report wins a tie, so
/// an exact statusline report beats the transcript estimate for as long as the
/// statusline keeps reporting.
enum PromptCacheSources {
    /// A report sent as the agent came to rest may still be in flight; until
    /// this much time has passed, the freshness guard fails warm.
    static let reportGrace: TimeInterval = 5

    static func resolve(
        transcript: PromptCacheReading?,
        report: PromptCacheReportStore.Slot?,
        now: Date
    ) -> PromptCacheReading? {
        guard let report, report.unknown || report.observation != nil else { return transcript }
        let reported = PromptCacheReading(
            observation: report.unknown ? nil : report.observation,
            scannedAt: now.addingTimeInterval(-reportGrace)
        )
        guard let read = transcript?.observation else { return reported }
        // Claude's statusline object does not see a `/model`, `/effort` or
        // compaction reset; one after the statusline's last request belongs
        // to the transcript until the next request.
        if let resetAt = read.resetAt, let tap = report.observation, tap.source == .statusline, tap.requestAt < resetAt {
            return transcript
        }
        return evidenceAt(report) >= evidenceAt(read) ? reported : transcript
    }

    /// A request report describes the cache as of its request; a statusline or
    /// `unknown` report, as of the moment it arrived.
    static func evidenceAt(_ slot: PromptCacheReportStore.Slot) -> Date {
        guard !slot.unknown, let observation = slot.observation, observation.source == .report else {
            return slot.receivedAt
        }
        return observation.requestAt
    }

    static func evidenceAt(_ observation: PromptCacheObservation) -> Date {
        max(observation.requestAt, observation.resetAt ?? observation.requestAt)
    }

    /// The panel's prompt cache for the liveness sweep. Safe from any thread.
    static func reading(forPanel panelId: UUID, now: Date = Date()) -> PromptCacheReading? {
        resolve(
            transcript: AgentModelDetector.shared.promptCacheReading(forSurface: panelId),
            report: PromptCacheReportStore.shared.slot(forPanel: panelId),
            now: now
        )
    }

    /// The panel's prompt cache for tooltips, the tab sheet and tab JSON.
    static func observation(forPanel panelId: UUID, now: Date = Date()) -> PromptCacheObservation? {
        reading(forPanel: panelId, now: now)?.observation
    }

    /// Whether a reporter's `unknown` is what describes the panel now.
    static func reportsUnknown(forPanel panelId: UUID) -> Bool {
        guard let slot = PromptCacheReportStore.shared.slot(forPanel: panelId), slot.unknown else { return false }
        guard let read = AgentModelDetector.shared.promptCacheReading(forSurface: panelId)?.observation else { return true }
        return evidenceAt(slot) >= evidenceAt(read)
    }
}

// MARK: - Socket

extension TerminalController {
    /// `agent.prompt_cache.report`: validate off-main, fold into the panel's
    /// slot, and return what the slot now says. No main-thread work: the
    /// liveness sweep picks the slot up within 10 s.
    nonisolated func v2PromptCacheReport(params: [String: Any]) -> V2CallResult {
        Self.promptCacheReportResult(params: params, store: .shared, now: Date())
    }

    nonisolated static func promptCacheReportResult(
        params: [String: Any],
        store: PromptCacheReportStore,
        now: Date
    ) -> V2CallResult {
        switch PromptCacheReportParser.parse(params, now: now) {
        case .failure(let failure):
            return .err(code: "invalid_params", message: failure.message, data: nil)
        case .success(let parsed):
            let slot = store.record(parsed.report, panelId: parsed.panelId, receivedAt: now)
            var result: [String: Any] = [
                "panel_id": parsed.panelId.uuidString,
                "state": PromptCacheReportStore.stateWord(slot, now: now),
            ]
            if let observation = slot.observation {
                result["source"] = observation.source.rawValue
            }
            return .ok(result)
        }
    }
}
