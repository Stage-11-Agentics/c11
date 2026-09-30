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
//   turn start); a tool-call count and a token count for the current turn; and
//   message ids, held only as dedupe keys for that turn's token count. NO message
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

enum AgentModelDetection: Equatable {
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

    mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .prompt(let at):
            turnStartedAt = at
            turnToolCalls = 0
            turnTokens = 0
            messageTokens = [:]
        case .agent(let at, let tools, let tokens, let messageKey):
            if let at { lastEventAt = max(lastEventAt ?? at, at) }
            turnToolCalls += tools
            if let messageKey {
                messageTokens[messageKey] = tokens
                turnTokens = messageTokens.values.reduce(0, +)
            } else {
                turnTokens += tokens
            }
        case .toolResult(let at):
            if let at { lastEventAt = max(lastEventAt ?? at, at) }
        }
    }
}

enum TranscriptEvent: Equatable, Sendable {
    case prompt(at: Date?)
    case agent(at: Date?, tools: Int, tokens: Int, messageKey: String?)
    case toolResult(at: Date?)
}

struct ParsedTranscriptLine: Equatable, Sendable {
    var model: String?
    var event: TranscriptEvent?
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
}

struct AgentModelProbe: Sendable {
    let home: URL
    /// First-read window (bytes) and its ceiling when no model is found in it.
    static let initialWindow = 256 * 1024
    static let maxInitialWindow = 4 * 1024 * 1024
    /// Largest slice one poll will read; a bigger backlog is skipped to its end.
    static let maxPollBytes = 4 * 1024 * 1024
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
        if let reason = Self.unsupportedReason(kind: kind) {
            return .unsupported(reason)
        }
        guard let ref, !ref.placeholder else {
            // No real session (yet): drop what the previous session left behind.
            state = ModelTailState()
            return .none
        }
        if state.conversationId != ref.id {
            state = ModelTailState(conversationId: ref.id)
        }

        switch kind {
        case "opencode":
            if let row = readOpencodeRow(sessionId: ref.id) {
                if let model = row.model { state.model = model }
                state.signals.lastEventAt = row.updatedAt
                state.signals.sessionTokens = row.tokens
            }
        case "grok":
            if case .string(let dir)? = ref.payload?[GrokStrategy.sessionDirectoryPayloadKey],
               let summary = readGrokSummary(sessionDirectory: dir) {
                if let model = summary.model { state.model = model }
                state.signals.lastEventAt = summary.lastActiveAt
            }
        case "claude-code", "codex", "pi", "omp":
            tail(kind: kind, ref: ref, state: &state, now: now)
        default:
            return .unsupported("no model detection for \(kind)")
        }
        return state.model.map(AgentModelDetection.model) ?? .none
    }

    // MARK: - JSONL harnesses

    private func tail(kind: String, ref: ConversationRef, state: inout ModelTailState, now: Date) {
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
        }
        state.inode = inode

        if state.offset == 0 {
            initialScan(kind: kind, handle: handle, size: size, state: &state)
        } else if size > state.offset {
            incrementalScan(kind: kind, handle: handle, size: size, state: &state)
        }
    }

    /// First contact: read a window ending at EOF, processing every line forward
    /// so the newest model wins and the current turn's counters are exact. The
    /// window grows (to `maxInitialWindow`) until it holds a model and, unless it
    /// already reaches the file start, the start of the current turn. The offset
    /// is left at the end of the last complete line.
    private func initialScan(kind: String, handle: FileHandle, size: UInt64, state: inout ModelTailState) {
        var window = UInt64(Self.initialWindow)
        while true {
            let start = size > window ? size - window : 0
            guard let data = readRange(handle, from: start, to: size) else { return }
            let (lines, consumed) = Self.completeLines(in: data, droppingLeadingPartial: start > 0)
            state.model = nil
            state.signals = TranscriptSignals()
            for line in lines { Self.fold(kind: kind, line: line, into: &state) }
            state.offset = start + UInt64(consumed)
            let complete = state.model != nil && (state.signals.turnStartedAt != nil || start == 0)
            if complete || start == 0 || window >= UInt64(Self.maxInitialWindow) {
                // One very long turn can push the last `turn_context` out of the
                // window; look further back for just that line.
                if state.model == nil, start > 0, kind == "codex" {
                    state.model = findEarlierTurnContextModel(handle: handle, before: start)
                }
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

    private func incrementalScan(kind: String, handle: FileHandle, size: UInt64, state: inout ModelTailState) {
        var start = state.offset
        var dropLeading = false
        if size - start > UInt64(Self.maxPollBytes) {
            start = size - UInt64(Self.maxPollBytes)
            dropLeading = true
        }
        guard let data = readRange(handle, from: start, to: size) else { return }
        let (lines, consumed) = Self.completeLines(in: data, droppingLeadingPartial: dropLeading)
        for line in lines { Self.fold(kind: kind, line: line, into: &state) }
        state.offset = start + UInt64(consumed)
    }

    private static func fold(kind: String, line: Data, into state: inout ModelTailState) {
        let parsed = parseLine(kind: kind, line: line)
        if let model = parsed.model { state.model = model }
        if let event = parsed.event { state.signals.apply(event) }
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
    static func completeLines(in data: Data, droppingLeadingPartial: Bool) -> (lines: [Data], consumed: Int) {
        var lines: [Data] = []
        var lineStart = data.startIndex
        var consumed = 0
        var skipFirst = droppingLeadingPartial
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                if skipFirst {
                    skipFirst = false
                } else if index > lineStart {
                    lines.append(data.subdata(in: lineStart..<index))
                }
                lineStart = data.index(after: index)
                consumed = data.distance(from: data.startIndex, to: lineStart)
            }
            index = data.index(after: index)
        }
        return (lines, consumed)
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
        case "pi", "omp": return parsePiOmp(kind: kind, line: line)
        default: return ParsedTranscriptLine()
        }
    }

    /// Largest line worth a JSON parse; bigger ones are classified by substring.
    private static let maxParseBytes = 1_048_576

    private static func parseClaude(_ line: Data) -> ParsedTranscriptLine {
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
            if let usage = message["usage"] as? [String: Any] {
                tokens = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["output_tokens"])
            }
            return ParsedTranscriptLine(
                model: normalized(message["model"] as? String),
                event: .agent(at: at, tools: tools, tokens: tokens, messageKey: message["id"] as? String)
            )
        default:
            return ParsedTranscriptLine()
        }
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
            return ParsedTranscriptLine(model: normalized(payload["model"] as? String))
        }
        // Codex writes `timestamp` as the first key of every line, so the first
        // occurrence is the line's own.
        let at = timestamp(in: line, last: false)
        if hasType(line, "task_started") { return ParsedTranscriptLine(event: .prompt(at: at)) }
        if hasType(line, "task_complete") { return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: 0, messageKey: nil)) }
        if hasType(line, "token_count") {
            var tokens = 0
            var key: String?
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
            }
            return ParsedTranscriptLine(event: .agent(at: at, tools: 0, tokens: tokens, messageKey: key))
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

    /// The latest agent signals for a surface (from the last sweep), or nil.
    /// Cheap and safe from any thread; the sheet reads it when it opens.
    func signals(forSurface surfaceId: UUID) -> TranscriptSignals? {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedSignals[surfaceId]
    }

    private func setSignals(_ signals: TranscriptSignals?, forSurface surfaceId: UUID) {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        publishedSignals[surfaceId] = signals
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
                    publishedLock.unlock()
                    for target in agents {
                        let ref = refs[target.surfaceId.uuidString]?.active
                        var state = states[target.surfaceId] ?? ModelTailState()
                        let hadModel = state.model != nil
                        let result = probe.detect(kind: target.kind, ref: ref, state: &state)
                        states[target.surfaceId] = state
                        setSignals(state.signals, forSurface: target.surfaceId)
                        publish(result, target: target)
                        if result == .none, hadModel {
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
        let store = SurfaceMetadataStore.shared
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
        let store = SurfaceMetadataStore.shared
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
                guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                      let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return }
                workspace.syncSurfaceTabDetailForPanel(surfaceId)
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
