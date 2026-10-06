import Foundation
import SQLite3

// Live model detection for agent tabs.
//
// For each harness c11 already resumes through `Sources/Conversation/Strategies/`,
// read the model the session is *actually using* from the session or transcript
// file that harness writes, and publish it as the `model_detected` metadata key
// at the `.derived` precedence tier. Display precedence (`AgentModelPrecedence`):
// an agent's own `set-agent --model` (tier `declare` or above) > the detected
// model > a launch stamp (tier `heuristic`).
//
// Contract:
// - Read-only. Nothing is written to any harness's files or config.
// - Incremental. A transcript is opened once, its tail scanned for the latest
//   model, then only bytes appended since the last poll are read. Whole
//   transcripts are never re-read.
// - Off-main. Polls run on the AgentDetector's 10 s sweep via the detector's own
//   utility queue; only a changed value hops to main, for a UI refresh.
// - What is retained, exactly: the model id; event timestamps (last agent event,
//   turn start); a tool-call count and a token count for the current turn; the
//   last model request's time, cache tier and prompt size (for the prompt cache
//   estimate); and message ids, held only as dedupe keys. NO message
//   text, prompt, tool input or tool output is kept, logged or published: lines
//   are scanned in memory and dropped.
// - Honest about gaps. A harness whose session files carry no model (Kimi,
//   GitHub Copilot) reports `model_detection = unsupported:<reason>` instead of
//   guessing from config.
//
// Where the model lives, per harness:
//   claude-code  ~/.claude/projects/<slug>/<id>.jsonl   assistant line `message.model`
//   codex        ~/.codex/sessions/Y/M/D/rollout-*-<id>.jsonl   `turn_context.payload.model`
//   pi           ~/.pi/agent/sessions/<slug>/<ts>_<id>.jsonl    `model_change.modelId`
//   omp          ~/.omp/agent/sessions/<slug>/<ts>_<id>.jsonl   `model_change.model`
//   grok         <session dir>/summary.json                     `current_model_id`
//   opencode     ~/.local/share/opencode/opencode.db            `session.model` (JSON `{id}`)
//   kimi, github-copilot: no model in the files c11 can locate.

enum AgentModelDetection: Equatable, Sendable {
    /// The latest model id found in the harness's own files.
    case model(String)
    /// Nothing found yet (session file missing or no model line so far).
    case none
    /// This harness's session files carry no model. `reason` is short and stable.
    case unsupported(String)
}

/// What the agent did most recently, as read from the same tail as the model.
/// The tab sheet's `active`, `turn`, `tools` and `tokens` clocks are built from
/// this; only counts and timestamps are kept, never transcript text.
struct TranscriptSignals: Equatable, Sendable {
    /// Last assistant message or tool result: "an agent added to this tab".
    var lastEventAt: Date?
    /// When the current (or last) turn began: the last human prompt (Codex:
    /// `task_started`). nil when the scanned window never reached one.
    var turnStartedAt: Date?
    var turnToolCalls = 0
    /// Fresh input + output tokens spent in the current turn. Cache reads are
    /// excluded: they re-count the whole context on every call.
    var turnTokens = 0
    /// Claude Code splits one API message across several lines that repeat its
    /// usage; keyed by message id so a message counts once.
    var messageTokens: [String: Int] = [:]
    /// Whole-session token total where a harness records one (opencode).
    var sessionTokens: Int?
    /// The agent's prompt cache as of its last model request; nil when the
    /// transcript says nothing c11 can use (see `PromptCacheObservation`).
    var promptCache: PromptCacheObservation?
    /// Latest time of any line read, so a response can anchor on the line
    /// written just before its request went out.
    var lastLineAt: Date?
    /// The request behind `promptCache`; a response written over several lines
    /// keeps the anchor of its first line.
    var promptCacheRequestKey: String?
    /// Claude names its cache tier only on requests that write to the cache;
    /// a pure read keeps the tier of the request before it.
    var promptCacheBasis: PromptCacheObservation.Basis?

    mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .prompt(let at):
            turnStartedAt = at
            turnToolCalls = 0
            turnTokens = 0
            messageTokens = [:]
            noteLine(at)
        case .agent(let at, let tools, let tokens, let messageKey):
            if let at { lastEventAt = max(lastEventAt ?? at, at) }
            turnToolCalls += tools
            if let messageKey {
                messageTokens[messageKey] = tokens
                turnTokens = messageTokens.values.reduce(0, +)
            } else {
                turnTokens += tokens
            }
            noteLine(at)
        case .toolResult(let at):
            if let at { lastEventAt = max(lastEventAt ?? at, at) }
            noteLine(at)
        }
    }

    /// Record one request's cache use. Call before `apply` for the same line,
    /// so `lastLineAt` still holds the line before it.
    mutating func notePromptCache(_ usage: PromptCacheUsage) {
        guard let at = usage.at else { return }
        if let key = usage.requestKey, key == promptCacheRequestKey { return }
        let basis = usage.basis ?? promptCacheBasis ?? usage.fallbackBasis
        promptCacheBasis = basis
        promptCacheRequestKey = usage.requestKey
        let requestAt = usage.anchorsOnPriorLine ? min(at, lastLineAt ?? at) : at
        promptCache = PromptCacheObservation(requestAt: requestAt, basis: basis, promptTokens: usage.promptTokens)
        noteLine(at)
    }

    /// A prompt sends a request that reads the cache, even one interrupted
    /// before its response wrote a line, and writes a fresh one after a reset.
    /// Not for lines that send nothing (slash commands, `!` shell lines).
    mutating func notePromptSent(_ at: Date?) {
        guard let at, var cache = promptCache, at > cache.requestAt else { return }
        cache.requestAt = at
        cache.reset = nil
        cache.resetAt = nil
        promptCache = cache
    }

    /// Something replaced the cached prefix (a model switch, a compaction):
    /// cold from that moment, until the next request writes a new cache.
    mutating func resetPromptCache(_ line: PromptCacheResetLine) {
        guard let at = line.at else { return }
        let basis = promptCacheBasis ?? .ttl(PromptCachePolicy.anthropicDefaultTTL)
        promptCache = PromptCacheObservation(
            requestAt: promptCache?.requestAt ?? at,
            basis: basis,
            promptTokens: line.promptTokens ?? promptCache?.promptTokens,
            reset: line.reason,
            resetAt: at
        )
        promptCacheRequestKey = nil
        noteLine(at)
    }

    private mutating func noteLine(_ at: Date?) {
        if let at { lastLineAt = max(lastLineAt ?? at, at) }
    }
}

/// When an agent's prompt cache goes cold, from the last model request it made.
///
/// Anthropic publishes the lifetime (5 minutes by default, 1 hour on the
/// extended tier), counted from the start of each request that reads or writes
/// the cache, so a Claude Code expiry is computed. OpenAI and xAI publish no
/// fixed lifetime; c11 calls those caches cold after an idle span measured on
/// real sessions and labels the result an estimate.
struct PromptCacheObservation: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        /// The provider's published lifetime, in seconds.
        case ttl(TimeInterval)
        /// No published lifetime: treat as cold after this much idle time.
        case estimate(TimeInterval)
    }

    /// When the last request that read or wrote the cache was sent.
    var requestAt: Date
    var basis: Basis
    /// The prompt the next request re-caches once this goes cold; nil when the
    /// harness does not record it.
    var promptTokens: Int?
    /// Set when something replaced the cached prefix before its lifetime ran out.
    var reset: Reset? = nil
    var resetAt: Date? = nil

    enum Reset: Equatable, Sendable {
        case modelSwitch
        case compaction
    }

    var isEstimate: Bool {
        if case .estimate = basis { return true }
        return false
    }

    func coldAt(estimateOverride: TimeInterval? = PromptCachePolicy.estimateOverride) -> Date {
        if let resetAt { return resetAt }
        switch basis {
        case .ttl(let seconds):
            return requestAt.addingTimeInterval(seconds)
        case .estimate(let seconds):
            return requestAt.addingTimeInterval(estimateOverride ?? seconds)
        }
    }

    func isCold(at now: Date, estimateOverride: TimeInterval? = PromptCachePolicy.estimateOverride) -> Bool {
        now >= coldAt(estimateOverride: estimateOverride)
    }
}

/// A line that replaced the cached prefix without a request of its own.
struct PromptCacheResetLine: Equatable, Sendable {
    var reason: PromptCacheObservation.Reset
    var at: Date?
    /// The prompt the next request re-caches (compaction's post-compact size).
    var promptTokens: Int?
}

/// One model request's cache use, as a transcript line records it.
struct PromptCacheUsage: Equatable, Sendable {
    var at: Date?
    /// Identifies the request, so a response written across several lines counts once.
    var requestKey: String?
    /// nil: the same tier as the previous request.
    var basis: PromptCacheObservation.Basis?
    /// The tier to assume when neither this request nor an earlier one named one.
    var fallbackBasis: PromptCacheObservation.Basis
    var promptTokens: Int?
    /// The line is written when the response finishes; the request went out
    /// at the line before it.
    var anchorsOnPriorLine: Bool
}

enum PromptCachePolicy {
    /// Anthropic's two published lifetimes.
    static let anthropicDefaultTTL: TimeInterval = 5 * 60
    static let anthropicExtendedTTL: TimeInterval = 60 * 60
    /// Codex: OpenAI documents a sliding 30-minute minimum and no guarantee.
    /// Over 115k measured response pairs, reuse held to about an hour and a
    /// miss first became likelier than a hit at about two hours.
    static let codexColdAfter: TimeInterval = 2 * 60 * 60
    /// Grok Build: xAI documents automatic caching and no lifetime. Implicit
    /// caches measured here keep little past an hour.
    static let grokColdAfter: TimeInterval = 60 * 60

    /// Replaces every estimated span (not a published TTL), so a validation
    /// run can watch an estimate go cold without waiting hours.
    static let estimateOverrideEnvironmentKey = "C11_PROMPT_CACHE_ESTIMATE_SECONDS"
    static let estimateOverride: TimeInterval? = parseEstimateOverride(
        environment: ProcessInfo.processInfo.environment
    )

    static func parseEstimateOverride(environment: [String: String]) -> TimeInterval? {
        guard let raw = environment[estimateOverrideEnvironmentKey],
              let value = TimeInterval(raw), value.isFinite else { return nil }
        return min(max(value, 60), 24 * 60 * 60)
    }
}

enum TranscriptEvent: Equatable, Sendable {
    case prompt(at: Date?)
    case agent(at: Date?, tools: Int, tokens: Int, messageKey: String?)
    case toolResult(at: Date?)
}

struct ParsedTranscriptLine: Equatable, Sendable {
    var model: String? = nil
    var event: TranscriptEvent? = nil
    var lifecycle: ParsedTranscriptLifecycle? = nil
    var sessionID: String? = nil
    var sessionMetaIdentity = false
    var promptCache: PromptCacheUsage? = nil
    var promptCacheReset: PromptCacheResetLine? = nil
    /// A user line the harness echoes for a local command or `!` shell line:
    /// no model request went out.
    var sendsNoRequest = false
}

/// A structural lifecycle record found in a harness transcript. This type is
/// deliberately not a journal draft: the producer below is the only place
/// that supplies c11 ownership and provenance fields.
enum ParsedTranscriptLifecycle: Equatable, Sendable {
    case codex(kind: JournalKind, at: Date?, turnID: String?, rootTurnID: String?)
    case grokStart(at: Date?, turnID: String?, sessionID: String?, primary: Bool)
    case grokEnd(at: Date?, outcome: String?)
    case grokMalformed
}

struct TranscriptLifecycleObservation: Equatable, Sendable {
    let kind: JournalKind
    let occurredAt: Date?
    let nativeEvent: String
    let turnID: String?
    let isChild: Bool
}

enum TranscriptCoverage: Equatable, Sendable {
    case none
    /// Bytes before the retained window, including a leading partial line that
    /// was discarded rather than parsed.
    case gap(skippedBytes: UInt64)
}

struct AgentModelDetectionResult: Equatable, Sendable {
    let detection: AgentModelDetection
    let lifecycle: [TranscriptLifecycleObservation]
    let coverage: TranscriptCoverage
}

struct GrokPendingTurn: Equatable {
    let turnID: String
    let occurredAt: Date?
}

/// Incremental tail position for one surface's transcript.
struct ModelTailState: Equatable {
    var signals = TranscriptSignals()
    var path: String?
    var inode: UInt64 = 0
    /// Byte offset just past the last fully-consumed line.
    var offset: UInt64 = 0
    var model: String?
    /// The conversation id this state belongs to; a new id starts fresh.
    var conversationId: String?
    /// After a failed locate, do not search the disk again before this time.
    var nextLocateAt: Date?
    /// A skipped span permanently lowers transcript coverage for this session.
    var coverageDegraded = false
    /// Codex child/root classification is bounded to the current tail.
    var codexRootTurnID: String?
    var codexChildTurnIDs: [String] = []
    /// Grok's end record has no identity; pair it only with this verified start.
    var grokPendingStart: GrokPendingTurn?
    /// A rollout whose session_meta disagrees with the exact ref is unusable.
    var transcriptIdentityInvalid = false
    /// Codex lifecycle edges require an exact session_meta match before they
    /// can be trusted. Model/clock parsing remains useful before that proof.
    var transcriptIdentityVerified = false
}

struct AgentModelProbe: Sendable {
    let home: URL
    /// First-read window (bytes) and its ceiling when no model is found in it.
    static let initialWindow = 256 * 1024
    static let maxInitialWindow = 4 * 1024 * 1024
    /// Largest slice one poll will read; a bigger backlog is skipped to its end.
    static let maxPollBytes = 4 * 1024 * 1024
    /// Codex session identity lives at the rollout header, outside a bounded
    /// tail window on old or resumed sessions.
    static let maxIdentityHeaderBytes = 64 * 1024
    static let locateRetry: TimeInterval = 30
    /// How far back the substring-only `turn_context` search may look.
    static let maxBackwardSearch: UInt64 = 64 * 1024 * 1024

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    static func supportsModelDetection(kind: String) -> Bool {
        unsupportedReason(kind: kind) == nil
    }

    static func unsupportedReason(kind: String) -> String? {
        switch kind {
        case "kimi": return "kimi session files carry no model"
        case "github-copilot": return "copilot session files carry no model c11 can read"
        default: return nil
        }
    }

    // MARK: - Entry point

    func detect(
        kind: String,
        ref: ConversationRef?,
        state: inout ModelTailState,
        now: Date = Date()
    ) -> AgentModelDetection {
        detectWithObservations(kind: kind, ref: ref, state: &state, now: now).detection
    }

    func detectWithObservations(
        kind: String,
        ref: ConversationRef?,
        state: inout ModelTailState,
        now: Date = Date()
    ) -> AgentModelDetectionResult {
        if let reason = Self.unsupportedReason(kind: kind) {
            return AgentModelDetectionResult(detection: .unsupported(reason), lifecycle: [], coverage: .none)
        }
        guard let ref, !ref.placeholder else {
            // No real session (yet): drop what the previous session left behind.
            state = ModelTailState()
            return AgentModelDetectionResult(detection: .none, lifecycle: [], coverage: .none)
        }
        if state.conversationId != ref.id {
            state = ModelTailState(conversationId: ref.id)
        }

        var lifecycle: [TranscriptLifecycleObservation] = []
        var coverage = TranscriptCoverage.none
        switch kind {
        case "opencode":
            if let row = readOpencodeRow(sessionId: ref.id) {
                if let model = row.model { state.model = model }
                state.signals.lastEventAt = row.updatedAt
                state.signals.sessionTokens = row.tokens
            }
        case "grok":
            let summary: (model: String?, lastActiveAt: Date?)?
            if case .string(let dir)? = ref.payload?[GrokStrategy.sessionDirectoryPayloadKey] {
                summary = readGrokSummary(sessionDirectory: dir)
            } else {
                summary = nil
            }
            tail(kind: kind, ref: ref, state: &state, now: now,
                 lifecycle: &lifecycle, coverage: &coverage)
            if let summary {
                if let model = summary.model { state.model = model }
                if let lastActiveAt = summary.lastActiveAt {
                    state.signals.lastEventAt = max(state.signals.lastEventAt ?? lastActiveAt, lastActiveAt)
                }
            }
        case "claude-code", "codex", "pi", "omp":
            tail(kind: kind, ref: ref, state: &state, now: now,
                 lifecycle: &lifecycle, coverage: &coverage)
        default:
            return AgentModelDetectionResult(
                detection: .unsupported("no model detection for \(kind)"), lifecycle: [], coverage: .none
            )
        }
        return AgentModelDetectionResult(
            detection: state.model.map(AgentModelDetection.model) ?? .none,
            lifecycle: lifecycle,
            coverage: coverage
        )
    }

    // MARK: - JSONL harnesses

    private func tail(
        kind: String,
        ref: ConversationRef,
        state: inout ModelTailState,
        now: Date,
        lifecycle: inout [TranscriptLifecycleObservation],
        coverage: inout TranscriptCoverage
    ) {
        if state.path == nil || !FileManager.default.fileExists(atPath: state.path!) {
            state.path = nil
            if let retry = state.nextLocateAt, now < retry { return }
            guard let located = locateTranscript(kind: kind, ref: ref) else {
                state.nextLocateAt = now.addingTimeInterval(Self.locateRetry)
                return
            }
            state.path = located
            state.nextLocateAt = nil
            state.offset = 0
            state.inode = 0
        }
        guard let path = state.path,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        // Rotated, replaced or truncated: start over.
        if state.inode != 0, (state.inode != inode || size < state.offset) {
            state.offset = 0
            state.model = nil
            Self.resetLifecycleState(&state)
            state.transcriptIdentityInvalid = false
            state.transcriptIdentityVerified = false
        }
        state.inode = inode

        if state.offset == 0 {
            if kind == "codex" {
                state.transcriptIdentityInvalid = false
                state.transcriptIdentityVerified = false
                switch verifyCodexSessionIdentity(handle: handle, size: size, expectedSessionID: ref.id) {
                case .verified:
                    state.transcriptIdentityVerified = true
                case .mismatch:
                    state.transcriptIdentityInvalid = true
                case .unavailable:
                    break
                }
            }
            initialScan(kind: kind, expectedSessionID: ref.id, handle: handle, size: size,
                        state: &state, lifecycle: &lifecycle, coverage: &coverage)
        } else if size > state.offset {
            incrementalScan(kind: kind, expectedSessionID: ref.id, handle: handle, size: size,
                            state: &state, lifecycle: &lifecycle, coverage: &coverage)
        }
    }

    /// First contact: read a window ending at EOF, processing every line forward
    /// so the newest model wins and the current turn's counters are exact. The
    /// window grows (to `maxInitialWindow`) until it holds a model and, unless it
    /// already reaches the file start, the start of the current turn. The offset
    /// is left at the end of the last complete line.
    private func initialScan(
        kind: String,
        expectedSessionID: String,
        handle: FileHandle,
        size: UInt64,
        state: inout ModelTailState,
        lifecycle: inout [TranscriptLifecycleObservation],
        coverage: inout TranscriptCoverage
    ) {
        var window = UInt64(Self.initialWindow)
        while true {
            let start = size > window ? size - window : 0
            guard let data = readRange(handle, from: start, to: size) else { return }
            let (lines, consumed, leadingSkipped) = Self.completeLines(in: data, droppingLeadingPartial: start > 0)
            state.model = nil
            state.signals = TranscriptSignals()
            Self.resetLifecycleState(&state, preserveCoverage: true)
            var candidateLifecycle: [TranscriptLifecycleObservation] = []
            var candidateCoverage: TranscriptCoverage = .none
            for line in lines {
                Self.fold(kind: kind, expectedSessionID: expectedSessionID, line: line,
                          into: &state, lifecycle: &candidateLifecycle, coverage: &candidateCoverage)
            }
            state.offset = start + UInt64(consumed)
            let complete = state.model != nil && (state.signals.turnStartedAt != nil || start == 0)
            if complete || start == 0 || window >= UInt64(Self.maxInitialWindow) {
                if start > 0 {
                    // The omitted prefix invalidates pairings from before the
                    // retained window, but a qualified Grok start inside that
                    // window is continuous evidence for a later appended end.
                    state.model = nil
                    state.signals = TranscriptSignals()
                    state.coverageDegraded = false
                    Self.resetLifecycleState(&state, preserveCoverage: true)
                    candidateLifecycle.removeAll(keepingCapacity: true)
                    candidateCoverage = .none
                    Self.markCoverageGap(
                        skippedBytes: start + UInt64(leadingSkipped),
                        state: &state,
                        coverage: &candidateCoverage
                    )
                    for line in lines {
                        Self.fold(kind: kind, expectedSessionID: expectedSessionID, line: line,
                                  into: &state, lifecycle: &candidateLifecycle, coverage: &candidateCoverage)
                    }
                }
                // One very long turn can push the last `turn_context` out of the
                // window; look further back for just that line.
                if state.model == nil, start > 0, kind == "codex" {
                    state.model = findEarlierTurnContextModel(handle: handle, before: start)
                }
                lifecycle.append(contentsOf: candidateLifecycle)
                if case .gap = candidateCoverage { coverage = candidateCoverage }
                return
            }
            window *= 4
        }
    }

    /// Substring-only backward search (up to `maxBackwardSearch`) for the last
    /// `"type":"turn_context"` line before `offset`; only that line is parsed.
    private func findEarlierTurnContextModel(handle: FileHandle, before offset: UInt64) -> String? {
        let needle = Data("\"type\":\"turn_context\"".utf8)
        let chunk = UInt64(Self.maxInitialWindow)
        let overlap: UInt64 = 64 * 1024
        var end = offset
        var searched: UInt64 = 0
        while end > 0, searched < Self.maxBackwardSearch {
            let start = end > chunk ? end - chunk : 0
            guard let data = readRange(handle, from: start, to: end + overlap) else { return nil }
            if let hit = data.range(of: needle, options: .backwards) {
                let lineStart = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
                if let lineEnd = data[hit.upperBound...].firstIndex(of: 0x0A) {
                    let line = data.subdata(in: lineStart..<lineEnd)
                    if let model = Self.parseLine(kind: "codex", line: line).model { return model }
                }
            }
            searched += end - start
            end = start
        }
        return nil
    }

    private func incrementalScan(
        kind: String,
        expectedSessionID: String,
        handle: FileHandle,
        size: UInt64,
        state: inout ModelTailState,
        lifecycle: inout [TranscriptLifecycleObservation],
        coverage: inout TranscriptCoverage
    ) {
        var start = state.offset
        var dropLeading = false
        if size - start > UInt64(Self.maxPollBytes) {
            start = size - UInt64(Self.maxPollBytes)
            dropLeading = true
        }
        guard let data = readRange(handle, from: start, to: size) else { return }
        let (lines, consumed, leadingSkipped) = Self.completeLines(in: data, droppingLeadingPartial: dropLeading)
        if dropLeading {
            Self.markCoverageGap(
                skippedBytes: (start - state.offset) + UInt64(leadingSkipped),
                state: &state,
                coverage: &coverage
            )
        }
        for line in lines {
            Self.fold(kind: kind, expectedSessionID: expectedSessionID, line: line,
                      into: &state, lifecycle: &lifecycle, coverage: &coverage)
        }
        state.offset = start + UInt64(consumed)
    }

    private enum CodexIdentityRead {
        case verified
        case mismatch
        case unavailable
    }

    /// Reads only the bounded file prefix. This identity check is independent
    /// of the retained tail window and is repeated on every initial scan.
    private func verifyCodexSessionIdentity(
        handle: FileHandle,
        size: UInt64,
        expectedSessionID: String
    ) -> CodexIdentityRead {
        guard size > 0 else { return .unavailable }
        let end = min(size, UInt64(Self.maxIdentityHeaderBytes))
        guard let data = readRange(handle, from: 0, to: end) else { return .unavailable }
        let (lines, _, _) = Self.completeLines(in: data, droppingLeadingPartial: false)
        for line in lines where Self.hasType(line, "session_meta") {
            guard line.count <= Self.maxParseBytes,
                  let parsedID = Self.parseLine(kind: "codex", line: line).sessionID else {
                return .unavailable
            }
            return parsedID == expectedSessionID ? .verified : .mismatch
        }
        return .unavailable
    }

    private static func fold(
        kind: String,
        expectedSessionID: String,
        line: Data,
        into state: inout ModelTailState,
        lifecycle: inout [TranscriptLifecycleObservation],
        coverage: inout TranscriptCoverage
    ) {
        let parsed = parseLine(kind: kind, line: line)
        if case .grokMalformed? = parsed.lifecycle {
            markCoverageGap(skippedBytes: UInt64(max(1, line.count)), state: &state, coverage: &coverage)
            return
        }
        if let sessionID = parsed.sessionID {
            guard sessionID == expectedSessionID else {
                state.transcriptIdentityInvalid = true
                state.transcriptIdentityVerified = false
                resetLifecycleState(&state)
                state.model = nil
                state.signals = TranscriptSignals()
                return
            }
        }
        guard !state.transcriptIdentityInvalid else { return }

        let acceptedLifecycle = processLifecycle(
            lifecycle: parsed.lifecycle,
            expectedSessionID: expectedSessionID,
            state: &state,
            observations: &lifecycle
        )
        // Child Codex records are deliberately invisible to the model clocks as
        // well as to the journal. A response/tool line alone is not a turn edge.
        if acceptedLifecycle || parsed.lifecycle == nil {
            if let model = parsed.model { state.model = model }
            if let reset = parsed.promptCacheReset { state.signals.resetPromptCache(reset) }
            if let usage = parsed.promptCache { state.signals.notePromptCache(usage) }
            if let event = parsed.event {
                state.signals.apply(event)
                if case .prompt(let at) = event, !parsed.sendsNoRequest { state.signals.notePromptSent(at) }
            }
        }
    }

    private static func processLifecycle(
        lifecycle: ParsedTranscriptLifecycle?,
        expectedSessionID: String,
        state: inout ModelTailState,
        observations: inout [TranscriptLifecycleObservation]
    ) -> Bool {
        guard let lifecycle else { return false }
        switch lifecycle {
        case .codex(let kind, let at, let turnID, let rootTurnID):
            guard state.transcriptIdentityVerified else { return false }
            guard let turnID, !turnID.isEmpty else { return false }
            let isChild = rootTurnID.map { $0 != turnID } ?? false
            if isChild {
                rememberCodexChild(turnID, state: &state)
                return false
            }
            if state.codexChildTurnIDs.contains(turnID) { return false }
            switch kind {
            case .turnStarted:
                state.codexRootTurnID = turnID
                observations.append(.init(kind: .turnStarted, occurredAt: at,
                                           nativeEvent: "turn.started", turnID: turnID, isChild: false))
                return true
            case .turnCompleted, .turnInterrupted:
                guard state.codexRootTurnID == turnID || rootTurnID == turnID else { return false }
                observations.append(.init(
                    kind: kind, occurredAt: at,
                    nativeEvent: kind == .turnCompleted ? "turn.completed" : "turn.interrupted",
                    turnID: turnID, isChild: false
                ))
                state.codexRootTurnID = nil
                return kind == .turnCompleted
            default:
                return false
            }
        case .grokStart(let at, let turnID, let sessionID, let primary):
            state.grokPendingStart = nil
            guard primary, sessionID == expectedSessionID, let turnID, let at else { return false }
            state.grokPendingStart = GrokPendingTurn(turnID: turnID, occurredAt: at)
            // The turn's first model call reads the cache; its end records the
            // last. A subagent's start clears the pending turn, so a long turn
            // that ran a subagent counts from its start and can read cold early.
            state.signals.notePromptCache(Self.grokPromptCache(at: at, key: "start:\(turnID)"))
            observations.append(.init(kind: .turnStarted, occurredAt: at,
                                       nativeEvent: "turn.started", turnID: turnID, isChild: false))
            return false
        case .grokEnd(let at, let outcome):
            // Any end of a verified primary turn follows its last model call.
            if let pending = state.grokPendingStart, let at,
               pending.occurredAt.map({ at >= $0 }) ?? true {
                state.signals.notePromptCache(Self.grokPromptCache(at: at, key: "end:\(pending.turnID)"))
            }
            guard outcome == "completed", let pending = state.grokPendingStart,
                  let at else {
                state.grokPendingStart = nil
                return false
            }
            if let startedAt = pending.occurredAt, at < startedAt {
                state.grokPendingStart = nil
                return false
            }
            observations.append(.init(kind: .turnCompleted, occurredAt: at,
                                       nativeEvent: "turn.completed", turnID: pending.turnID, isChild: false))
            state.grokPendingStart = nil
            return false
        case .grokMalformed:
            state.grokPendingStart = nil
            return false
        }
    }

    /// xAI caches automatically and publishes no lifetime: an estimate.
    private static func grokPromptCache(at: Date, key: String) -> PromptCacheUsage {
        PromptCacheUsage(
            at: at, requestKey: key,
            basis: .estimate(PromptCachePolicy.grokColdAfter),
            fallbackBasis: .estimate(PromptCachePolicy.grokColdAfter),
            promptTokens: nil, anchorsOnPriorLine: false
        )
    }

    private static func rememberCodexChild(_ turnID: String, state: inout ModelTailState) {
        state.codexChildTurnIDs.removeAll { $0 == turnID }
        state.codexChildTurnIDs.append(turnID)
        if state.codexChildTurnIDs.count > 32 { state.codexChildTurnIDs.removeFirst() }
    }

    private static func resetLifecycleState(_ state: inout ModelTailState, preserveCoverage: Bool = false) {
        state.codexRootTurnID = nil
        state.codexChildTurnIDs.removeAll(keepingCapacity: true)
        state.grokPendingStart = nil
        if !preserveCoverage { state.coverageDegraded = false }
    }

    private static func markCoverageGap(
        skippedBytes: UInt64,
        state: inout ModelTailState,
        coverage: inout TranscriptCoverage
    ) {
        resetLifecycleState(&state, preserveCoverage: true)
        // The line before a response may sit in the skipped span.
        state.signals.lastLineAt = nil
        guard !state.coverageDegraded else { return }
        state.coverageDegraded = true
        coverage = .gap(skippedBytes: max(1, skippedBytes))
    }

    private func readRange(_ handle: FileHandle, from: UInt64, to: UInt64) -> Data? {
        guard to > from else { return Data() }
        do {
            try handle.seek(toOffset: from)
            return try handle.read(upToCount: Int(to - from))
        } catch {
            return nil
        }
    }

    /// Complete (newline-terminated) lines in `data`, and the byte count through
    /// the last newline. A trailing partial line is left unconsumed so the next
    /// poll re-reads it once complete.
    static func completeLines(in data: Data, droppingLeadingPartial: Bool) -> (lines: [Data], consumed: Int, leadingSkipped: Int) {
        var lines: [Data] = []
        var lineStart = data.startIndex
        var consumed = 0
        var leadingSkipped = 0
        var skipFirst = droppingLeadingPartial
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                let next = data.index(after: index)
                if skipFirst {
                    leadingSkipped = data.distance(from: data.startIndex, to: next)
                    skipFirst = false
                } else if index > lineStart {
                    lines.append(data.subdata(in: lineStart..<index))
                }
                lineStart = next
                consumed = data.distance(from: data.startIndex, to: lineStart)
            }
            index = data.index(after: index)
        }
        return (lines, consumed, leadingSkipped)
    }

    // MARK: - Line parsing

    /// What one transcript line asserts: a model, and/or an agent/operator
    /// event. Parses JSON only for lines that can carry either, and never keeps
    /// text. Timestamps and classification use substring checks so a multi-MB
    /// tool result costs a memory scan, not a parse.
    static func parseLine(kind: String, line: Data) -> ParsedTranscriptLine {
        switch kind {
        case "claude-code": return parseClaude(line)
        case "codex": return parseCodex(line)
        case "grok": return parseGrok(line)
        case "pi", "omp": return parsePiOmp(kind: kind, line: line)
        default: return ParsedTranscriptLine()
        }
    }

    /// Largest line worth a JSON parse; bigger ones are classified by substring.
    private static let maxParseBytes = 1_048_576

    private static func parseClaude(_ line: Data) -> ParsedTranscriptLine {
        if hasType(line, "system"), contains(line, "\"compact_boundary\""), !contains(line, "\"isSidechain\":true") {
            let object = line.count <= maxParseBytes ? parseObject(line) : nil
            let at = (object?["timestamp"] as? String).flatMap(parseISO) ?? timestamp(in: line, last: true)
            let post = int((object?["compactMetadata"] as? [String: Any])?["postTokens"])
            return ParsedTranscriptLine(promptCacheReset: PromptCacheResetLine(
                reason: .compaction, at: at, promptTokens: post > 0 ? post : nil
            ))
        }
        guard hasType(line, "assistant") || hasType(line, "user") else { return ParsedTranscriptLine() }
        guard line.count <= maxParseBytes, let object = parseObject(line) else { return parseClaudeOversize(line) }
        if (object["isSidechain"] as? Bool) == true { return ParsedTranscriptLine() }
        let at = (object["timestamp"] as? String).flatMap(parseISO)
        let message = object["message"] as? [String: Any]
        switch object["type"] as? String {
        case "user":
            if (object["isMeta"] as? Bool) == true { return ParsedTranscriptLine() }
            let blocks = message?["content"] as? [[String: Any]]
            if blocks?.contains(where: { ($0["type"] as? String) == "tool_result" }) == true {
                return ParsedTranscriptLine(event: .toolResult(at: at))
            }
            let text = (message?["content"] as? String)
                ?? blocks?.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            if let text, localCommandEchoPrefixes.contains(where: { text.hasPrefix($0) }) {
                // `/model` swaps the model the cache belongs to.
                let reset = text.hasPrefix("<local-command-stdout>Set model to ")
                    ? PromptCacheResetLine(reason: .modelSwitch, at: at)
                    : nil
                return ParsedTranscriptLine(event: .prompt(at: at), promptCacheReset: reset, sendsNoRequest: true)
            }
            return ParsedTranscriptLine(event: .prompt(at: at))
        case "assistant":
            guard let message else { return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil)) }
            // Claude's placeholder assistant lines ("No response requested") are not the agent adding anything.
            if (message["model"] as? String) == "<synthetic>" { return ParsedTranscriptLine() }
            var tools = 0
            if let content = message["content"] as? [[String: Any]] {
                tools = content.filter { ($0["type"] as? String) == "tool_use" }.count
            }
            var tokens = 0
            var cache: PromptCacheUsage?
            if let usage = message["usage"] as? [String: Any] {
                tokens = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["output_tokens"])
                cache = claudePromptCache(usage: usage, at: at, requestKey: message["id"] as? String)
            }
            return ParsedTranscriptLine(
                model: normalized(message["model"] as? String),
                event: .agent(at: at, tools: tools, tokens: tokens, messageKey: message["id"] as? String),
                promptCache: cache
            )
        default:
            return ParsedTranscriptLine()
        }
    }

    /// How Claude Code records a slash command, its output, and `!` shell lines.
    /// A skill command (`<command-message>` first) does send a prompt; its
    /// response records the request, so only an interrupted one is missed.
    private static let localCommandEchoPrefixes = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
        "<bash-input>", "<bash-stdout>", "<bash-stderr>",
    ]

    /// A request that read or wrote the cache. `cache_creation` names the tier
    /// of what it wrote; a pure read names none and keeps the earlier tier.
    /// A request that touched no cache at all (caching off) says nothing.
    private static func claudePromptCache(usage: [String: Any], at: Date?, requestKey: String?) -> PromptCacheUsage? {
        let read = int(usage["cache_read_input_tokens"])
        let written = int(usage["cache_creation_input_tokens"])
        guard read + written > 0 else { return nil }
        let tiers = usage["cache_creation"] as? [String: Any]
        let basis: PromptCacheObservation.Basis?
        // Longer TTLs must precede shorter ones in a prompt, so when a request
        // writes both, the 5-minute part is the conversation's tail.
        if int(tiers?["ephemeral_5m_input_tokens"]) > 0 {
            basis = .ttl(PromptCachePolicy.anthropicDefaultTTL)
        } else if int(tiers?["ephemeral_1h_input_tokens"]) > 0 {
            basis = .ttl(PromptCachePolicy.anthropicExtendedTTL)
        } else {
            basis = nil
        }
        return PromptCacheUsage(
            at: at, requestKey: requestKey, basis: basis,
            fallbackBasis: .ttl(PromptCachePolicy.anthropicDefaultTTL),
            promptTokens: int(usage["input_tokens"]) + written + read,
            anchorsOnPriorLine: true
        )
    }

    /// A line too large to parse: classify by substring. The timestamp is the
    /// LAST `"timestamp"` key, which for Claude is the line's own (nested tool
    /// results come earlier).
    private static func parseClaudeOversize(_ line: Data) -> ParsedTranscriptLine {
        if contains(line, "\"isSidechain\":true") { return ParsedTranscriptLine() }
        let at = timestamp(in: line, last: true)
        if hasType(line, "user") {
            if contains(line, "\"tool_result\"") { return ParsedTranscriptLine(event: .toolResult(at: at)) }
            if contains(line, "\"isMeta\":true") { return ParsedTranscriptLine() }
            return ParsedTranscriptLine(event: .prompt(at: at))
        }
        return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil))
    }

    private static func parseCodex(_ line: Data) -> ParsedTranscriptLine {
        if hasType(line, "turn_context") || hasType(line, "session_meta") {
            guard line.count <= maxParseBytes, let object = parseObject(line),
                  let payload = object["payload"] as? [String: Any] else { return ParsedTranscriptLine() }
            return ParsedTranscriptLine(
                model: normalized(payload["model"] as? String),
                sessionID: validOpaque(payload["id"] as? String),
                sessionMetaIdentity: hasType(line, "session_meta")
            )
        }
        // Codex writes `timestamp` as the first key of every line, so the first
        // occurrence is the line's own.
        let at = timestamp(in: line, last: false)
        if line.count <= maxParseBytes, let object = parseObject(line),
           let payload = object["payload"] as? [String: Any],
           let type = payload["type"] as? String {
            switch type {
            case "task_started":
                return ParsedTranscriptLine(
                    event: .prompt(at: at),
                    lifecycle: .codex(kind: .turnStarted, at: at,
                                      turnID: validOpaque(payload["turn_id"] as? String),
                                      rootTurnID: validOpaque(payload["root_turn_id"] as? String))
                )
            case "task_complete":
                return ParsedTranscriptLine(
                    event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil),
                    lifecycle: .codex(kind: .turnCompleted, at: at,
                                      turnID: validOpaque(payload["turn_id"] as? String),
                                      rootTurnID: validOpaque(payload["root_turn_id"] as? String))
                )
            case "turn_aborted":
                return ParsedTranscriptLine(
                    lifecycle: .codex(kind: .turnInterrupted, at: at,
                                      turnID: validOpaque(payload["turn_id"] as? String),
                                      rootTurnID: validOpaque(payload["root_turn_id"] as? String))
                )
            default:
                break
            }
        }
        if hasType(line, "task_started") { return ParsedTranscriptLine(event: .prompt(at: at)) }
        if hasType(line, "task_complete") { return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil)) }
        if hasType(line, "turn_aborted") { return ParsedTranscriptLine() }
        if hasType(line, "token_count") {
            var tokens = 0
            var key: String?
            var cache: PromptCacheUsage?
            if line.count <= maxParseBytes, let object = parseObject(line),
               let info = (object["payload"] as? [String: Any])?["info"] as? [String: Any] {
                if let last = info["last_token_usage"] as? [String: Any] {
                    tokens = max(0, int(last["input_tokens"]) - int(last["cached_input_tokens"])) + int(last["output_tokens"])
                }
                // Rollouts repeat identical token_count lines. The session total only
                // ever grows, so it identifies one API call: repeats collapse to one.
                if let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber {
                    key = "total:\(total.intValue)"
                }
                // OpenAI caches automatically and publishes no fixed lifetime. A
                // line without usage (rate limits only) is not a request.
                if let last = info["last_token_usage"] as? [String: Any] {
                    let input = int(last["input_tokens"])
                    cache = PromptCacheUsage(
                        at: at, requestKey: key,
                        basis: .estimate(PromptCachePolicy.codexColdAfter),
                        fallbackBasis: .estimate(PromptCachePolicy.codexColdAfter),
                        promptTokens: input > 0 ? input : nil,
                        anchorsOnPriorLine: false
                    )
                }
            }
            return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: tokens, messageKey: key), promptCache: cache)
        }
        guard hasType(line, "response_item") else { return ParsedTranscriptLine() }
        if hasType(line, "custom_tool_call") || hasType(line, "function_call") || hasType(line, "local_shell_call") {
            return ParsedTranscriptLine(event: .agent(at: at, tools: 1, tokens: 0, messageKey: nil))
        }
        if hasType(line, "custom_tool_call_output") || hasType(line, "function_call_output") {
            return ParsedTranscriptLine(event: .toolResult(at: at))
        }
        if contains(line, "\"role\":\"user\"") || contains(line, "\"role\":\"developer\"") || contains(line, "\"role\":\"system\"") {
            return ParsedTranscriptLine()
        }
        return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil))
    }

    private static func parseGrok(_ line: Data) -> ParsedTranscriptLine {
        guard hasType(line, "turn_started") || hasType(line, "turn_ended") else {
            return ParsedTranscriptLine()
        }
        guard line.count <= maxParseBytes, let object = parseObject(line),
              let type = object["type"] as? String else {
            return ParsedTranscriptLine(lifecycle: .grokMalformed)
        }
        let at = (object["ts"] as? String).flatMap(parseISO)
        switch type {
        case "turn_started":
            return ParsedTranscriptLine(lifecycle: .grokStart(
                at: at,
                turnID: decimalTurnID(object["turn_number"]),
                sessionID: validOpaque(object["session_id"] as? String),
                primary: (object["session_relationship"] as? String) == "primary"
            ))
        case "turn_ended":
            return ParsedTranscriptLine(lifecycle: .grokEnd(
                at: at, outcome: object["outcome"] as? String
            ))
        default:
            return ParsedTranscriptLine()
        }
    }

    private static func parsePiOmp(kind: String, line: Data) -> ParsedTranscriptLine {
        let isModelChange = hasType(line, "model_change")
        guard isModelChange || hasType(line, "message") else { return ParsedTranscriptLine() }
        guard line.count <= maxParseBytes, let object = parseObject(line) else {
            return parsePiOmpOversize(line)
        }
        if isModelChange {
            let raw = kind == "omp"
                ? ((object["model"] as? String) ?? (object["modelId"] as? String))
                : (object["modelId"] as? String)
            return ParsedTranscriptLine(model: normalized(raw))
        }
        guard (object["type"] as? String) == "message", let message = object["message"] as? [String: Any] else {
            return ParsedTranscriptLine()
        }
        let at = (object["timestamp"] as? String).flatMap(parseISO)
        switch message["role"] as? String {
        case "toolResult": return ParsedTranscriptLine(event: .toolResult(at: at))
        case "user": return ParsedTranscriptLine(event: .prompt(at: at))
        case "assistant":
            var tools = 0
            if let content = message["content"] as? [[String: Any]] {
                tools = content.filter { ($0["type"] as? String) == "toolCall" }.count
            }
            var tokens = 0
            if let usage = message["usage"] as? [String: Any] {
                tokens = int(usage["input"]) + int(usage["output"]) + int(usage["cacheWrite"])
            }
            return ParsedTranscriptLine(event: .agent(at: at, tools: tools, tokens: tokens, messageKey: object["id"] as? String))
        default:
            return ParsedTranscriptLine()
        }
    }

    /// Too large to parse: role by substring, timestamp from the end of the line.
    private static func parsePiOmpOversize(_ line: Data) -> ParsedTranscriptLine {
        guard hasType(line, "message") else { return ParsedTranscriptLine() }
        let at = timestamp(in: line, last: true)
        if contains(line, "\"role\":\"toolResult\"") { return ParsedTranscriptLine(event: .toolResult(at: at)) }
        if contains(line, "\"role\":\"user\"") { return ParsedTranscriptLine(event: .prompt(at: at)) }
        if contains(line, "\"role\":\"assistant\"") { return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil)) }
        return ParsedTranscriptLine()
    }

    // MARK: - Line helpers

    private static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    /// `"type":"<value>"`, tolerating a space after the colon.
    private static func hasType(_ data: Data, _ value: String) -> Bool {
        contains(data, "\"type\":\"\(value)\"") || contains(data, "\"type\": \"\(value)\"")
    }

    private static func parseObject(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// Journal identifiers are opaque but must stay printable and bounded.
    /// Rejecting rather than truncating keeps a malformed transcript from being
    /// correlated with a different turn.
    private static func validOpaque(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 128,
              raw.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 47 && $0 != 92 }) else {
            return nil
        }
        return raw
    }

    private static func decimalTurnID(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double.rounded() == double else { return nil }
            return String(number.int64Value)
        }
        guard let raw = value as? String,
              !raw.isEmpty, raw.allSatisfy(\.isNumber), raw.utf8.count <= 128 else { return nil }
        return raw
    }

    /// A line's `"timestamp":"<ISO 8601>"` read without parsing JSON: the first
    /// occurrence, or the last (`last: true`) when nested objects may carry their
    /// own earlier timestamp. Only for lines too large to parse; parsed lines use
    /// `object["timestamp"]`.
    static func timestamp(in line: Data, last: Bool = false) -> Date? {
        let needle = Data("\"timestamp\"".utf8)
        var found: Range<Data.Index>?
        var searchStart = line.startIndex
        while let range = line.range(of: needle, in: searchStart..<line.endIndex) {
            found = range
            if !last { break }
            searchStart = range.upperBound
        }
        guard let key = found else { return nil }
        var i = key.upperBound
        while i < line.endIndex, line[i] == 0x3A || line[i] == 0x20 { i = line.index(after: i) }
        guard i < line.endIndex, line[i] == 0x22 else { return nil }
        let start = line.index(after: i)
        guard let end = line[start...].firstIndex(of: 0x22), end > start, line.distance(from: start, to: end) < 40 else { return nil }
        return parseISO(String(decoding: line[start..<end], as: UTF8.self))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// ISO 8601 with any number of fractional digits (Grok writes six).
    static func parseISO(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) ?? isoPlain.date(from: raw) { return d }
        guard let dot = raw.firstIndex(of: "."), let z = raw.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot else { return nil }
        let digits = raw[raw.index(after: dot)..<z]
        let trimmed = String(raw[..<dot]) + "." + String(digits.prefix(3)) + String(raw[z...])
        return isoFractional.date(from: trimmed)
    }

    /// Model ids worth showing: non-empty, not a harness placeholder.
    static func normalized(_ raw: String?) -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        if id.hasPrefix("<") && id.hasSuffix(">") { return nil }   // Claude's `<synthetic>`
        return String(id.prefix(128))
    }

    // MARK: - Locating transcripts

    func locateTranscript(kind: String, ref: ConversationRef) -> String? {
        let fm = FileManager.default
        let cwd = ref.cwd ?? ""
        switch kind {
        case "claude-code":
            let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
            if !cwd.isEmpty {
                let direct = projects
                    .appendingPathComponent(ClaudeCodeStrategy.projectSlug(forCwd: cwd), isDirectory: true)
                    .appendingPathComponent("\(ref.id).jsonl").path
                if fm.fileExists(atPath: direct) { return direct }
            }
            // The session may have started in another directory than the ref's cwd.
            for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
                let candidate = projects.appendingPathComponent(dir).appendingPathComponent("\(ref.id).jsonl").path
                if fm.fileExists(atPath: candidate) { return candidate }
            }
            return nil
        case "codex":
            return locateCodexRollout(id: ref.id)
        case "pi":
            guard !cwd.isEmpty else { return nil }
            let dir = home.appendingPathComponent(".pi/agent/sessions/\(PiScraper.sessionSlug(forCwd: cwd))", isDirectory: true)
            return fileWithSuffix("_\(ref.id).jsonl", in: dir)
        case "omp":
            if case .string(let path)? = ref.payload?[OmpStrategy.sessionFilePayloadKey], fm.fileExists(atPath: path) {
                return path
            }
            guard !cwd.isEmpty else { return nil }
            let slug = OmpScraper.sessionSlug(forCwd: cwd, homeDirectory: home)
            let dir = home.appendingPathComponent(".omp/agent/sessions/\(slug)", isDirectory: true)
            return fileWithSuffix("_\(ref.id).jsonl", in: dir)
        case "grok":
            guard case .string(let directory)? = ref.payload?[GrokStrategy.sessionDirectoryPayloadKey],
                  !directory.isEmpty else { return nil }
            let events = URL(fileURLWithPath: directory).appendingPathComponent("events.jsonl").path
            return fm.fileExists(atPath: events) ? events : nil
        default:
            return nil
        }
    }

    private func fileWithSuffix(_ suffix: String, in dir: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasSuffix(suffix) }.map { dir.appendingPathComponent($0).path }
    }

    /// Codex rollouts live in `sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
    /// Session ids are UUIDv7, whose leading 48 bits are the creation time, so
    /// the day directory (give or take a timezone day) is computable. If the id
    /// is not v7, fall back to the newest few day directories.
    private func locateCodexRollout(id: String) -> String? {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let suffix = "-\(id).jsonl"
        var days: [URL] = []
        if let date = Self.uuidV7Date(id) {
            var calendar = Calendar(identifier: .gregorian)
            for zone in [TimeZone.current, TimeZone(identifier: "UTC")!] {
                calendar.timeZone = zone
                for delta in [0, -1, 1] {
                    guard let day = calendar.date(byAdding: .day, value: delta, to: date) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day], from: day)
                    days.append(root.appendingPathComponent(
                        String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), isDirectory: true))
                }
            }
        } else {
            days = Self.newestDayDirectories(root: root, limit: 3)
        }
        for day in days {
            if let hit = fileWithSuffix(suffix, in: day) { return hit }
        }
        return nil
    }

    static func uuidV7Date(_ id: String) -> Date? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        let chars = Array(hex)
        guard chars[12] == "7", let ms = UInt64(String(chars[0..<12]), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func newestDayDirectories(root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        func sorted(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { Int($0) != nil }.sorted(by: >)
        }
        var out: [URL] = []
        for y in sorted(root) {
            for m in sorted(root.appendingPathComponent(y)) {
                for d in sorted(root.appendingPathComponent("\(y)/\(m)")) {
                    out.append(root.appendingPathComponent("\(y)/\(m)/\(d)", isDirectory: true))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    // MARK: - Non-transcript harnesses

    func readGrokModel(sessionDirectory: String) -> String? {
        readGrokSummary(sessionDirectory: sessionDirectory)?.model
    }

    /// `summary.json`: `current_model_id` and `last_active_at`.
    func readGrokSummary(sessionDirectory: String) -> (model: String?, lastActiveAt: Date?)? {
        let url = URL(fileURLWithPath: sessionDirectory).appendingPathComponent("summary.json")
        // Plain read, not mapped: Grok rewrites this file in place, and a truncated
        // mapping faults (SIGBUS) instead of failing.
        guard let data = try? Data(contentsOf: url),
              data.count < 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let last = ((object["last_active_at"] as? String) ?? (object["updated_at"] as? String)).flatMap(Self.parseISO)
        return (Self.normalized(object["current_model_id"] as? String), last)
    }

    func readOpencodeModel(sessionId: String) -> String? {
        readOpencodeRow(sessionId: sessionId)?.model
    }

    /// One row of the opencode `session` table: `model` is a JSON blob
    /// (`{"id":"k3","providerID":"kimi",...}`), `time_updated` is epoch
    /// milliseconds, and the token columns are whole-session totals.
    func readOpencodeRow(sessionId: String) -> (model: String?, updatedAt: Date?, tokens: Int?)? {
        guard isValidOpencodeSessionId(sessionId) else { return nil }
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        var statement: OpaquePointer?
        // Older opencode versions lack the time/token columns: fall back to `model` alone.
        let full = "SELECT model, time_updated, tokens_input + tokens_output + tokens_reasoning FROM session WHERE id = ? LIMIT 1"
        let minimal = "SELECT model, NULL, NULL FROM session WHERE id = ? LIMIT 1"
        if sqlite3_prepare_v2(handle, full, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            guard sqlite3_prepare_v2(handle, minimal, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
        }
        guard let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let bound = sessionId.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }

        var model: String?
        if let text = sqlite3_column_text(statement, 0) {
            let raw = String(cString: text)
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                model = Self.normalized(object["id"] as? String)
            } else {
                model = Self.normalized(raw)   // older opencode stored the bare id
            }
        }
        let updated: Date? = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)) / 1000)
        let tokens: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 2))
        return (model, updated, tokens)
    }
}

// MARK: - Live detector

/// One sweep's view of an agent's prompt cache.
struct PromptCacheReading: Equatable, Sendable {
    /// nil: the transcript says nothing usable about the cache.
    let observation: PromptCacheObservation?
    /// When that sweep began reading the harness's files.
    let scannedAt: Date
}

/// Runs `AgentModelProbe` for agent surfaces from the AgentDetector sweep and
/// publishes changes to the surface metadata store.
final class AgentModelDetector: @unchecked Sendable {
    static let shared = AgentModelDetector()

    enum MetadataKeys {
        static let detected = "model_detected"
        static let detection = "model_detection"
    }

    struct Target: Hashable, Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
        let kind: String
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.agent-model", qos: .utility)
    private var states: [UUID: ModelTailState] = [:]
    private var inFlight = false
    private let publishedLock = NSLock()
    private var publishedSignals: [UUID: TranscriptSignals] = [:]
    private var publishedScanStartedAt: [UUID: Date] = [:]

    /// The latest agent signals for a surface (from the last sweep), or nil.
    /// Cheap and safe from any thread; the sheet reads it when it opens.
    func signals(forSurface surfaceId: UUID) -> TranscriptSignals? {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedSignals[surfaceId]
    }

    /// The prompt cache from the last sweep, with the moment that sweep began
    /// reading. Anything the harness wrote before `scannedAt` is reflected.
    func promptCacheReading(forSurface surfaceId: UUID) -> PromptCacheReading? {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        guard let scannedAt = publishedScanStartedAt[surfaceId] else { return nil }
        return PromptCacheReading(observation: publishedSignals[surfaceId]?.promptCache, scannedAt: scannedAt)
    }

    private func setSignals(_ signals: TranscriptSignals?, scannedAt: Date? = nil, forSurface surfaceId: UUID) {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        publishedSignals[surfaceId] = signals
        publishedScanStartedAt[surfaceId] = signals == nil ? nil : scannedAt
    }

    /// Called from the 10 s sweep. `agents` are surfaces running a recognized
    /// harness; `plain` are surfaces with no agent in the foreground, whose
    /// derived model (from a session that ended) is cleared.
    func sweep(agents: [Target], plain: [(workspaceId: UUID, surfaceId: UUID)]) {
        guard !ConversationStorePolicy.isDisabled else { return }
        queue.async { [self] in
            guard !inFlight else { return }
            inFlight = true
            Task.detached(priority: .utility) { [self] in
                let refs = await ConversationStore.shared.snapshot()
                queue.async { [self] in
                    defer { inFlight = false }
                    let probe = AgentModelProbe()
                    let live = Set(agents.map(\.surfaceId))
                    states = states.filter { live.contains($0.key) }
                    publishedLock.lock()
                    publishedSignals = publishedSignals.filter { live.contains($0.key) }
                    publishedScanStartedAt = publishedScanStartedAt.filter { live.contains($0.key) }
                    publishedLock.unlock()
                    for target in agents {
                        let ref = refs[target.surfaceId.uuidString]?.active
                        var state = states[target.surfaceId] ?? ModelTailState()
                        let hadModel = state.model != nil
                        let scanStartedAt = Date()
                        let detection = probe.detectWithObservations(kind: target.kind, ref: ref, state: &state)
                        states[target.surfaceId] = state
                        setSignals(state.signals, scannedAt: scanStartedAt, forSurface: target.surfaceId)
                        if let ref {
                            JournalTranscriptProducer.shared.submit(
                                target: target, ref: ref, lifecycle: detection.lifecycle,
                                coverage: detection.coverage
                            )
                        }
                        publish(detection.detection, target: target)
                        if detection.detection == .none, hadModel {
                            // The session this model came from is gone.
                            clearDerived(workspaceId: target.workspaceId, surfaceId: target.surfaceId)
                        }
                    }
                    for surface in plain {
                        setSignals(nil, forSurface: surface.surfaceId)
                        clearDerived(workspaceId: surface.workspaceId, surfaceId: surface.surfaceId)
                    }
                }
            }
        }
    }

    private func publish(_ result: AgentModelDetection, target: Target) {
        let store = TabMetadataStore.shared
        var changed = false
        switch result {
        case .model(let id):
            changed = store.setInternal(workspaceId: target.workspaceId, surfaceId: target.surfaceId,
                                        key: MetadataKeys.detected, value: id, source: .derived)
            _ = try? store.clearMetadata(workspaceId: target.workspaceId, surfaceId: target.surfaceId,
                                         keys: [MetadataKeys.detection], source: .derived)
        case .unsupported(let reason):
            changed = store.setInternal(workspaceId: target.workspaceId, surfaceId: target.surfaceId,
                                        key: MetadataKeys.detection, value: "unsupported: \(reason)", source: .derived)
        case .none:
            break
        }
        if changed { refreshUI(target.workspaceId, target.surfaceId) }
    }

    private func clearDerived(workspaceId: UUID, surfaceId: UUID) {
        let store = TabMetadataStore.shared
        let snapshot = store.getMetadata(workspaceId: workspaceId, surfaceId: surfaceId,
                                         keys: [MetadataKeys.detected, MetadataKeys.detection])
        guard !snapshot.metadata.isEmpty else { return }
        if let result = try? store.clearMetadata(workspaceId: workspaceId, surfaceId: surfaceId,
                                                 keys: [MetadataKeys.detected, MetadataKeys.detection],
                                                 source: .derived),
           !result.removedKeys.isEmpty {
            refreshUI(workspaceId, surfaceId)
        }
    }

    private func refreshUI(_ workspaceId: UUID, _ surfaceId: UUID) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let manager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                      let workspace = manager.workspaces.first(where: { $0.id == workspaceId }) else { return }
                workspace.syncSurfaceTabDetailForTab(surfaceId)
            }
        }
    }
}

// MARK: - Display precedence

/// Which model a tab shows when several sources disagree:
/// an agent's own declaration (`c11 set-agent --model`, tier `declare` or above)
/// > the model detected from the harness's session files
/// > a launch stamp (tier `heuristic`, written by launch-agent, the A button and
/// blueprints, which record what c11 *asked* for, not what is running).
enum AgentModelPrecedence {
    static func isAgentDeclared(_ source: MetadataSource?) -> Bool {
        guard let source else { return true }   // unknown provenance (legacy): treat as declared
        return source.precedence >= MetadataSource.declare.precedence
    }

    static func effective(
        model: String?, modelSource: MetadataSource?,
        modelLabel: String?, labelSource: MetadataSource?,
        detected: String?
    ) -> (model: String?, label: String?) {
        let declaredModel = model != nil && isAgentDeclared(modelSource) ? model : nil
        let declaredLabel = modelLabel != nil && isAgentDeclared(labelSource) ? modelLabel : nil
        if declaredModel != nil || declaredLabel != nil { return (declaredModel, declaredLabel) }
        if let detected, !detected.isEmpty { return (detected, nil) }
        return (model, modelLabel)
    }
}
