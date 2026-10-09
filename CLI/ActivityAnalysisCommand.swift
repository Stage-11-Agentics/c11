import Foundation
import SQLite3
import Darwin
import CoreFoundation

/// File-only analytics. This file belongs to c11-cli, never the app target.
enum ActivityAnalysisCommand {
    static let usage = """
    Usage: c11 usage [--since <ISO-8601|Nd|Nh|Nm>] [--until <ISO-8601>] [--by panel|workspace|model|harness] [--json]
           c11 report [--instance <id>|--all-instances] [--since <ISO-8601|Nd|Nh|Nm>] [--until <ISO-8601>] [--utc] [--format md|json]

    Reads local transcripts and history without a socket. Unknown is never zero.
    File overrides: --state-root <directory>, --claude-root <directory>,
    --codex-root <directory>, --journal <lifecycle.sqlite3> (repeatable).
    Report defaults to production instances; use --instance or --all-instances for tagged builds.
    Calendar buckets use local time unless --utc is supplied.
    """
    private typealias Object = [String: Any]
    private static let null = NSNull()
    private static let iso = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return utcDate(s) ?? fractional.date(from: s) ?? iso.date(from: s)
    }
    /// Native logs use UTC ISO timestamps. Avoid ICU allocation for every sample;
    /// other ISO forms still use the existing Foundation parser.
    private static func utcDate(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 20, b.count <= 40, b[4] == 45, b[7] == 45,
              b[10] == 84, b[13] == 58, b[16] == 58, b.last == 90 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var result = 0
            for i in start..<(start + count) { guard b[i] >= 48, b[i] <= 57 else { return nil }; result = result * 10 + Int(b[i] - 48) }
            return result
        }
        guard var year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              year > 0, (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        var fraction = 0.0
        if b.count > 20 {
            guard b[19] == 46, b.count > 21 else { return nil }
            var scale = 0.1
            for i in 20..<(b.count - 1) { guard b[i] >= 48, b[i] <= 57 else { return nil }; fraction += Double(b[i] - 48) * scale; scale *= 0.1 }
        } else { guard b[19] == 90 else { return nil } }
        year -= month <= 2 ? 1 : 0
        let era = year / 400, y = year - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let epochDays = era * 146097 + y * 365 + y / 4 - y / 100 + doy - 719468
        return Date(timeIntervalSince1970: Double(epochDays * 86400 + hour * 3600 + minute * 60 + second) + fraction)
    }

    /// Inspect only a bounded prefix. Unknown ordering/escaping falls back to
    /// the full byte filter and JSON decoder, so this is never a schema guess.
    private static func prefixType(_ data: Data) -> String? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let bytes = raw.bindMemory(to: UInt8.self), end = min(bytes.count, 512)
            var i = 0, depth = 0
            while i < end {
                let c = bytes[i]
                if c == 123 || c == 91 { depth += 1; i += 1; continue }
                if c == 125 || c == 93 { depth -= 1; i += 1; continue }
                guard c == 34 else { i += 1; continue }
                let start = i + 1; i += 1
                var escaped = false
                while i < end, bytes[i] != 34 {
                    if bytes[i] == 92 { escaped = true; i += 1 }
                    i += 1
                }
                guard i < end else { return nil }
                let close = i; i += 1
                guard depth == 1, !escaped, close - start == 4,
                      bytes[start] == 116, bytes[start + 1] == 121, bytes[start + 2] == 112, bytes[start + 3] == 101 else { continue }
                while i < end, [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
                guard i < end, bytes[i] == 58 else { continue }
                i += 1
                while i < end, [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
                guard i < end, bytes[i] == 34 else { return nil }
                i += 1; let value = i
                while i < end, bytes[i] != 34 { if bytes[i] == 92 { return nil }; i += 1 }
                guard i < end else { return nil }
                return String(decoding: bytes[value..<i], as: UTF8.self)
            }
            return nil
        }
    }
    private static func contains(_ data: Data, needle: Data) -> Bool {
        data.withUnsafeBytes { haystack in needle.withUnsafeBytes { value in
            guard let h = haystack.baseAddress, let n = value.baseAddress else { return false }
            return memmem(h, haystack.count, n, value.count) != nil
        } }
    }
    private static func isGPT6(_ model: String) -> Bool { (model.lowercased().split(separator: "/").last.map(String.init) ?? model).hasPrefix("gpt-6") }
    private static func number(_ value: Any?) -> Int64 { max(0, (value as? NSNumber)?.int64Value ?? 0) }
    private static func object(_ value: Any?) -> Object { value as? Object ?? [:] }
    private static func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
    private struct Options {
        var values: [String: [String]] = [:]
        var json = false
        var since: Date?
        var until: Date?
        var utc = false
        var allInstances = false
        var state: URL
        var claude: URL
        var codex: URL
        init(_ args: [String], json: Bool) throws {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // Read-only resolution: do not trigger the app's state migration from an offline query.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library/Application Support")
            state = support.appendingPathComponent("c11")
            claude = home.appendingPathComponent(".claude/projects")
            codex = home.appendingPathComponent(".codex/sessions")
            self.json = json
            var i = 0
            let names: Set<String> = ["--since", "--until", "--by", "--instance", "--format", "--state-root", "--claude-root", "--codex-root", "--journal"]
            while i < args.count {
                if args[i] == "--json" { self.json = true; i += 1; continue }
                if args[i] == "--utc" { utc = true; i += 1; continue }
                if args[i] == "--all-instances" { allInstances = true; i += 1; continue }
                let parts = args[i].split(separator: "=", maxSplits: 1).map(String.init)
                guard names.contains(parts[0]) else { throw CLIError(message: "analytics: unknown option \(args[i])") }
                let value: String
                if parts.count == 2 { value = parts[1] } else {
                    i += 1
                    guard i < args.count, !args[i].hasPrefix("--") else { throw CLIError(message: "analytics: missing value for \(parts[0])") }
                    value = args[i]
                }
                guard !value.isEmpty else { throw CLIError(message: "analytics: empty \(parts[0])") }
                values[parts[0], default: []].append(value); i += 1
            }
            if let s = value("--since") {
                if let d = ActivityAnalysisCommand.date(s) { since = d }
                else if let suffix = s.last, let n = Double(s.dropLast()), n.isFinite, n > 0,
                        let unit = ["d": 86400.0, "h": 3600.0, "m": 60.0][String(suffix)] {
                    since = Date().addingTimeInterval(-n * unit)
                } else { throw CLIError(message: "analytics: --since must be ISO-8601 or a positive duration (Nd, Nh, Nm)") }
            }
            if let s = value("--until") {
                guard let d = ActivityAnalysisCommand.date(s) else { throw CLIError(message: "analytics: --until must be ISO-8601 with timezone") }
                until = d
            }
            if allInstances && value("--instance") != nil { throw CLIError(message: "report: --instance and --all-instances are mutually exclusive") }
            if let since, let until, until < since { throw CLIError(message: "analytics: --until precedes --since") }
            if let p = value("--state-root") { state = URL(fileURLWithPath: p) }
            if let p = value("--claude-root") { claude = URL(fileURLWithPath: p) }
            if let p = value("--codex-root") { codex = URL(fileURLWithPath: p) }
            guard ["panel", "workspace", "model", "harness"].contains(value("--by") ?? "model") else { throw CLIError(message: "usage: invalid --by") }
            guard ["md", "json"].contains(value("--format") ?? "md") else { throw CLIError(message: "report: invalid --format") }
        }
        func value(_ name: String) -> String? { values[name]?.last }
    }
    static func run(command: String, args: [String], json: Bool) throws {
        if args.contains("--help") || args.contains("-h") { print(usage); return }
        let options = try Options(args, json: json)
        var gaps = Set<String>()
        if command == "usage" {
            let tokens = try usageResult(options, gaps: &gaps)
            if options.json { print(try self.json(tokens)) }
            else { print(usageMarkdown(tokens)) }
        } else {
            let report = try reportResult(options, gaps: &gaps)
            if options.json || options.value("--format") == "json" { print(try self.json(report)) }
            else { print(reportMarkdown(report)) }
        }
    }
    /// Decode only relevant lines; drain Foundation temporaries for every bounded chunk.
    private static func lines(_ url: URL, gaps: inout Set<String>, counts: inout [String: Int],
                              matching needles: [Data] = [], _ consume: (Object, Int) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { gaps.insert("unreadable_file"); return }
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        var pending = Data(), line = 0, discarding = false
        func skipped(_ kind: String) { gaps.insert(kind); counts[kind, default: 0] += 1 }
        func decode(_ data: Data) {
            line += 1
            guard !data.isEmpty else { return }
            guard data.count <= limit else { skipped("oversize_jsonl_line"); return }
            if !needles.isEmpty, let kind = prefixType(data),
               !(needles.count == 1 ? kind == "assistant" : ["session_meta", "turn_context", "event_msg"].contains(kind)) {
                counts["filtered_lines", default: 0] += 1; return
            }
            if !needles.isEmpty && !needles.contains(where: { contains(data, needle: $0) }) {
                counts["filtered_lines", default: 0] += 1; return
            }
            guard let row = (try? JSONSerialization.jsonObject(with: data)) as? Object else { skipped("malformed_jsonl"); return }
            consume(row, line)
        }
        do {
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard var chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { return false }
                if discarding {
                    guard let end = chunk.firstIndex(of: 10) else { return true }
                    chunk.removeSubrange(...end); discarding = false
                }
                var cursor = chunk.startIndex
                while let end = chunk[cursor...].firstIndex(of: 10) {
                    pending.append(chunk[cursor..<end])
                    decode(pending); pending.removeAll(keepingCapacity: false)
                    cursor = chunk.index(after: end)
                }
                pending.append(chunk[cursor...])
                if pending.count > limit {
                    skipped("oversize_jsonl_line"); line += 1; pending.removeAll(keepingCapacity: false); discarding = true
                }
                return true
            }) {}
            if !pending.isEmpty { autoreleasepool { decode(pending) } }
        } catch { gaps.insert("unreadable_file") }
    }
    private static func files(_ root: URL, ext: String, gaps: inout Set<String>) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { gaps.insert("missing_\(ext)_root"); return [] }
        var failedSubtree = false
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
            failedSubtree = true
            return true // Keep other readable subtrees; expose the missing coverage below.
        }) else {
            gaps.insert("unreadable_\(ext)_root"); return []
        }
        let result = iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }.sorted { $0.path < $1.path }
        if failedSubtree { gaps.insert("unreadable_\(ext)_subtree") }
        return result
    }
    private struct Link: Hashable {
        let panel: String
        let workspace: String?
        let committedAt: Int64?
        let historyPruned: Bool
    }
    private static func harness(_ raw: String) -> String {
        switch raw.lowercased() { case "claude", "claude-code", "claude_code": return "claude"; case "codex", "openai-codex": return "codex"; default: return raw.lowercased() }
    }
    private static func links(_ options: Options, gaps: inout Set<String>) -> [String: Set<Link>] {
        let paths = options.values["--journal"]?.map { URL(fileURLWithPath: $0) }
            ?? files(options.state.appendingPathComponent("journal"), ext: "sqlite3", gaps: &gaps)
        var result: [String: Set<Link>] = [:]
        if paths.isEmpty { gaps.insert("journal_unavailable") }
        for path in paths {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; gaps.insert("journal_unavailable"); continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            var stmt: OpaquePointer?
            let columns = "tab_id,session_id,agent_kind,workspace_id"
            var timed = true
            if sqlite3_prepare_v2(db, "SELECT DISTINCT \(columns),committed_at_ms FROM journal_events WHERE tab_id IS NOT NULL AND session_id IS NOT NULL", -1, &stmt, nil) != SQLITE_OK {
                if let stmt { sqlite3_finalize(stmt) }; stmt = nil; timed = false
                guard sqlite3_prepare_v2(db, "SELECT DISTINCT \(columns),NULL FROM journal_events WHERE tab_id IS NOT NULL AND session_id IS NOT NULL", -1, &stmt, nil) == SQLITE_OK else {
                    gaps.insert("journal_schema_unavailable"); continue
                }
                gaps.insert("journal_attribution_time_unavailable")
            }
            var meta: OpaquePointer?
            var historyPruned = false
            if sqlite3_prepare_v2(db, "SELECT value FROM journal_meta WHERE key='coverage_low_water'", -1, &meta, nil) == SQLITE_OK,
               sqlite3_step(meta) == SQLITE_ROW, sqlite3_column_int64(meta, 0) > 1 { historyPruned = true; gaps.insert("journal_history_pruned") }
            if let meta { sqlite3_finalize(meta) }
            defer { sqlite3_finalize(stmt) }
            func column(_ n: Int32) -> String? { sqlite3_column_text(stmt, n).map { String(cString: $0) } }
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                if let panel = column(0), let session = column(1), let kind = column(2) {
                    result[harness(kind) + ":" + session, default: []].insert(Link(panel: panel, workspace: column(3), committedAt: timed ? sqlite3_column_int64(stmt, 4) : nil, historyPruned: historyPruned))
                }
                code = sqlite3_step(stmt)
            }
            if code != SQLITE_DONE { gaps.insert("journal_read_incomplete") }
        }
        return result
    }
    private struct Tokens: Equatable {
        var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, write5: Int64 = 0, write1: Int64 = 0, writeUnknown: Int64 = 0, reasoning: Int64 = 0, calls: Int64 = 0
        mutating func add(_ t: Tokens) {
            input += t.input; output += t.output; read += t.read; write5 += t.write5; write1 += t.write1; writeUnknown += t.writeUnknown; reasoning += t.reasoning; calls += t.calls
        }
        var totalTokens: Int64 { input + output + read + write5 + write1 + writeUnknown }
        var json: Object { ["input_tokens": input, "output_tokens": output, "cache_read_tokens": read, "cache_write_5m_tokens": write5, "cache_write_1h_tokens": write1, "cache_write_unknown_ttl_tokens": writeUnknown, "reasoning_output_tokens": reasoning, "calls": calls, "total_tokens": totalTokens] }
    }
    private struct UsageRow {
        let session: String, harness: String, model: String
        let timestamp: Date?
        let tokens: Tokens
        var speed: String = "standard"
        var sessions: Set<String> = []
        var origins: [String: Date] = [:]
        var originTimestamp: Date?
        var requestContextKnown = false
        var attributionUnknown = false
        var estimateUnknown = false
        var firstOutput: Int64 = 0
        var minimumOutput: Int64 = 0
    }
    private struct StringPool {
        private var strings: [String: String] = [:]
        mutating func intern(_ raw: String) -> String {
            if let stored = strings[raw] { return stored }
            // Own native UTF-8 storage instead of retaining Foundation bridges.
            let stored = String(decoding: raw.utf8, as: UTF8.self)
            strings[stored] = stored
            return stored
        }
    }
    /// Full native counter tuple, including total_tokens and field presence.
    /// Unexpected future fields/types retain only their canonical signature.
    private struct CounterSnapshot: Hashable {
        let input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64
        let presence: UInt16
        let extended: String?
        init(_ raw: Object) {
            let names = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
            var values = [Int64](repeating: 0, count: 5), mask: UInt16 = 0
            var unusual = raw.keys.contains { !names.contains($0) }
            for (i, name) in names.enumerated() {
                guard let value = raw[name] else { continue }
                if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.int64Value) {
                    values[i] = n.int64Value; mask |= 1 << (i * 2)
                } else if value is NSNull { mask |= 2 << (i * 2) }
                else { mask |= 3 << (i * 2); unusual = true }
            }
            input = values[0]; cached = values[1]; output = values[2]; reasoning = values[3]; total = values[4]
            presence = mask; extended = unusual ? try? ActivityAnalysisCommand.json(raw) : nil
        }
        func value(_ i: Int) -> Int64 {
            switch i { case 0: return max(0, input); case 1: return max(0, cached); case 2: return max(0, output); default: return max(0, reasoning) }
        }
    }
    private struct CodexIdentity: Hashable {
        let timestamp: String?
        let total: CounterSnapshot
        let last: CounterSnapshot
        let missingTimestampSource: Int
        let missingTimestampLine: Int
    }
    private struct CodexCandidate {
        var row: UsageRow
        let hasPredecessor: Bool
    }
    private static func mergeOrigins(_ old: UsageRow, into row: inout UsageRow) {
        let oldTime = old.originTimestamp ?? old.timestamp, rowTime = row.originTimestamp ?? row.timestamp
        row.attributionUnknown = row.attributionUnknown || old.attributionUnknown
        row.estimateUnknown = row.estimateUnknown || old.estimateUnknown
        if old.session == row.session, old.sessions.isEmpty, row.sessions.isEmpty {
            row.originTimestamp = [oldTime, rowTime].compactMap { $0 }.min()
            return
        }
        row.sessions.formUnion(old.sessions.isEmpty ? [old.session] : old.sessions)
        row.sessions.insert(row.session)
        var origins = old.origins
        if origins.isEmpty, let ts = oldTime { origins[old.session] = ts }
        if row.origins.isEmpty, let ts = rowTime { row.origins[row.session] = ts }
        row.origins.merge(origins, uniquingKeysWith: min)
    }
    private static func claudeRow(_ d: Object, file: URL, line: Int, pool: inout StringPool) -> (String, UsageRow)? {
        let m = object(d["message"])
        let u = object(m["usage"])
        guard d["type"] as? String == "assistant", !u.isEmpty, m["model"] as? String != "<synthetic>" else { return nil }
        let session = pool.intern(text(d["sessionId"]) ?? file.deletingPathExtension().lastPathComponent)
        let id = text(m["id"]), request = text(d["requestId"])
        let key: String
        if let id { key = id + ":" + (request ?? "unknown") }
        else { key = file.path + ":" + String(line) }
        let creation = object(u["cache_creation"])
        let w5 = number(creation["ephemeral_5m_input_tokens"])
        let w1 = number(creation["ephemeral_1h_input_tokens"])
        var tokens = Tokens()
        tokens.input = number(u["input_tokens"])
        tokens.output = number(u["output_tokens"])
        tokens.read = number(u["cache_read_input_tokens"])
        tokens.write5 = w5; tokens.write1 = w1
        tokens.writeUnknown = max(0, number(u["cache_creation_input_tokens"]) - w5 - w1)
        tokens.calls = 1
        var row = UsageRow(session: session, harness: "claude", model: pool.intern(text(m["model"]) ?? "unknown"), timestamp: date(d["timestamp"]), tokens: tokens, speed: pool.intern(text(u["speed"]) ?? "standard"))
        row.firstOutput = tokens.output; row.minimumOutput = tokens.output
        return (key, row)
    }
    private static func usageResult(_ options: Options, gaps: inout Set<String>, until: Date? = nil) throws -> Object {
        let attribution = links(options, gaps: &gaps)
        var counts: [String: Int] = [:]
        var analysis: [String: Int64] = ["codex_inherited_metadata_ignored": 0,
            "codex_duplicate_candidate_records_removed": 0, "codex_duplicate_candidate_input_tokens_removed": 0,
            "codex_duplicate_candidate_cache_read_tokens_removed": 0, "codex_duplicate_candidate_output_tokens_removed": 0,
            "codex_duplicate_delta_conflicts": 0, "codex_cumulative_samples": 0,
            "claude_output_upgrade_identities": 0, "claude_output_upgrade_tokens": 0,
            "claude_output_above_min_snapshot_tokens": 0,
            "codex_first_cumulative_without_matching_last_records": 0,
            "codex_first_cumulative_without_matching_last_tokens": 0]
        var pool = StringPool()
        let until = [until, options.until].compactMap { $0 }.min()
        var claude: [String: UsageRow] = [:]
        var missingIdentity = false
        for file in files(options.claude, ext: "jsonl", gaps: &gaps) {
            if let since = options.since,
               let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < since {
                counts["claude_files_before_since_skipped", default: 0] += 1
                gaps.insert("claude_file_mtime_filter_applied"); continue
            }
            lines(file, gaps: &gaps, counts: &counts, matching: [Data("\"usage\"".utf8)]) { d, line in
                if d["type"] as? String == "assistant", !object(object(d["message"])["usage"]).isEmpty, text(object(d["message"])["id"]) == nil { missingIdentity = true }
                guard let (key, parsed) = claudeRow(d, file: file, line: line, pool: &pool) else { return }
                var row = parsed
                let tokens = row.tokens
                // Streaming snapshots repeat identity; retain the most complete usage snapshot.
                if var old = claude[key] {
                    let firstOutput = old.firstOutput, minimumOutput = min(old.minimumOutput, row.minimumOutput)
                    if old.tokens.totalTokens > tokens.totalTokens {
                        mergeOrigins(row, into: &old); old.minimumOutput = minimumOutput; claude[key] = old; return
                    }
                    mergeOrigins(old, into: &row); row.firstOutput = firstOutput; row.minimumOutput = minimumOutput
                }
                claude[key] = row
            }
        }
        if missingIdentity { gaps.insert("claude_dedup_identity_missing") }
        // Counter continuity belongs to a native rollout file. Forks contain
        // inherited session_meta records; joining their counters by those IDs
        // invents resets and recounts entire cumulative histories.
        var codex: [CodexIdentity: CodexCandidate] = [:]
        var candidateVolume = Tokens()
        for (fileIndex, file) in files(options.codex, ext: "jsonl", gaps: &gaps).enumerated() {
            if let since = options.since,
               let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < since {
                counts["codex_files_before_since_skipped", default: 0] += 1
                gaps.insert("codex_file_mtime_filter_applied"); continue
            }
            var session = pool.intern(file.deletingPathExtension().lastPathComponent), model = pool.intern("unknown")
            var ownID: String?, firstMetadataInvalid = false, forkProvenance = false, attributionUnknown = false
            var previous: CounterSnapshot?, previousTimestamp: Date?
            var fileKeys: [CodexIdentity] = []
            var fileGaps = Set<String>()
            lines(file, gaps: &gaps, counts: &counts, matching: ["token_count", "session_meta", "turn_context"].map { Data($0.utf8) }) { d, line in
                let p = object(d["payload"])
                if d["type"] as? String == "session_meta" {
                    if let id = text(p["id"]) {
                        if ownID == nil {
                            session = pool.intern(id); ownID = session
                            forkProvenance = text(p["forked_from_id"]) != nil
                            attributionUnknown = attributionUnknown || firstMetadataInvalid
                        } else if id != ownID {
                            analysis["codex_inherited_metadata_ignored", default: 0] += 1
                            if !forkProvenance { attributionUnknown = true; fileGaps.insert("codex_session_metadata_conflict") }
                        }
                    } else if ownID == nil { firstMetadataInvalid = true; fileGaps.insert("codex_initial_session_metadata_missing") }
                    return
                }
                if d["type"] as? String == "turn_context" { model = pool.intern(text(p["model"]) ?? model); return }
                guard d["type"] as? String == "event_msg", p["type"] as? String == "token_count" else { return }
                let info = object(p["info"]), rawTotal = object(info["total_token_usage"]), rawLast = object(info["last_token_usage"])
                guard !rawTotal.isEmpty else { return }
                analysis["codex_cumulative_samples", default: 0] += 1
                let total = CounterSnapshot(rawTotal), last = CounterSnapshot(rawLast), timestamp = date(d["timestamp"])
                if let previous, (0..<4).allSatisfy({ total.value($0) == previous.value($0) }) { return }
                let hasPredecessor = previous != nil
                let reset = previous.map { before in (0..<4).contains { total.value($0) < before.value($0) } } ?? false
                let delta = (0..<4).map { reset ? last.value($0) : total.value($0) - (previous?.value($0) ?? 0) }
                if reset { fileGaps.insert(rawLast.isEmpty ? "codex_counter_reset_usage_unknown" : "codex_counter_reset_last_usage_only") }
                if let timestamp, let previousTimestamp, timestamp < previousTimestamp { fileGaps.insert("codex_source_timestamp_regression") }
                previous = total
                previousTimestamp = timestamp
                // Baselines are processed even outside the requested window;
                // only compact in-window usage identities survive this callback.
                if let timestamp, let since = options.since, timestamp < since { return }
                if let timestamp, let until, timestamp > until { return }
                if !hasPredecessor && total != last {
                    analysis["codex_first_cumulative_without_matching_last_records", default: 0] += 1
                    analysis["codex_first_cumulative_without_matching_last_tokens", default: 0] += total.value(0) + total.value(2)
                    fileGaps.insert("codex_first_cumulative_baseline_unproven")
                }
                let input = delta[0], cached = delta[1]
                if cached > input { fileGaps.insert("codex_cached_tokens_exceed_input") }
                var row = UsageRow(session: session, harness: "codex", model: model, timestamp: timestamp,
                    tokens: Tokens(input: max(0, input - cached), output: delta[2], read: cached, reasoning: delta[3], calls: 1),
                    requestContextKnown: !rawLast.isEmpty && (0..<4).allSatisfy { delta[$0] == last.value($0) })
                row.attributionUnknown = attributionUnknown || ownID == nil
                row.estimateUnknown = reset && rawLast.isEmpty
                if timestamp == nil { fileGaps.insert("codex_copy_identity_timestamp_missing") }
                let timestampIdentity = timestamp == nil ? nil : text(d["timestamp"]).map { String(decoding: $0.utf8, as: UTF8.self) }
                let key = CodexIdentity(timestamp: timestampIdentity, total: total, last: last,
                    missingTimestampSource: timestamp == nil ? fileIndex : 0,
                    missingTimestampLine: timestamp == nil ? line : 0)
                fileKeys.append(key); candidateVolume.add(row.tokens)
                if let old = codex[key] {
                    if old.row.tokens != row.tokens {
                        analysis["codex_duplicate_delta_conflicts", default: 0] += 1
                        if hasPredecessor != old.hasPredecessor {
                            // Same full native snapshot: one copy starts here,
                            // while the other retains its observed predecessor.
                            if !hasPredecessor { var chosen = old.row; mergeOrigins(row, into: &chosen); codex[key] = CodexCandidate(row: chosen, hasPredecessor: true); return }
                        } else {
                            // Conflicting retained predecessors do not establish
                            // a unique delta. Keep only the last known request.
                            fileGaps.insert("codex_duplicate_delta_ambiguous")
                            row = UsageRow(session: session, harness: "codex", model: model, timestamp: timestamp,
                                tokens: Tokens(input: max(0, last.value(0) - last.value(1)), output: last.value(2), read: last.value(1), reasoning: last.value(3), calls: 1))
                            row.estimateUnknown = true
                        }
                    } else if old.hasPredecessor && !hasPredecessor {
                        var chosen = old.row; mergeOrigins(row, into: &chosen); codex[key] = CodexCandidate(row: chosen, hasPredecessor: true); return
                    }
                    mergeOrigins(old.row, into: &row)
                }
                codex[key] = CodexCandidate(row: row, hasPredecessor: hasPredecessor)
            }
            if ownID == nil, !fileKeys.isEmpty { fileGaps.insert("codex_session_metadata_missing") }
            if attributionUnknown || ownID == nil {
                for key in fileKeys { codex[key]?.row.attributionUnknown = true }
            }
            gaps.formUnion(fileGaps)
        }
        var uniqueVolume = Tokens()
        for candidate in codex.values { uniqueVolume.add(candidate.row.tokens) }
        analysis["codex_duplicate_candidate_records_removed"] = candidateVolume.calls - uniqueVolume.calls
        analysis["codex_duplicate_candidate_input_tokens_removed"] = candidateVolume.input - uniqueVolume.input
        analysis["codex_duplicate_candidate_cache_read_tokens_removed"] = candidateVolume.read - uniqueVolume.read
        analysis["codex_duplicate_candidate_output_tokens_removed"] = candidateVolume.output - uniqueVolume.output
        var total = Tokens(), unattributed = Tokens(), groups: [String: Tokens] = [:]
        var estimates: [String: Double] = [:], unknownCost = Set<String>()
        var unknownCostTokens: [String: Int64] = [:], unknownCostCalls: [String: Int64] = [:]
        var lowerCosts: [String: Double] = [:], upperCosts: [String: Double] = [:], unboundedCost = Set<String>()
        let catalog = ModelCostCatalogStore(directory: options.state).resolvedCatalog()
        let axis = options.value("--by") ?? "model"
        func consume(_ row: UsageRow) {
            let usageTime = row.origins.values.min() ?? row.originTimestamp ?? row.timestamp
            if usageTime == nil { gaps.insert("usage_timestamp_unknown_included") }
            if let since = options.since, let ts = usageTime, ts < since { return }
            if let until, let ts = usageTime, ts > until { return }
            if row.harness == "claude" {
                let upgrade = max(0, row.tokens.output - row.firstOutput)
                analysis["claude_output_upgrade_identities", default: 0] += upgrade > 0 ? 1 : 0
                analysis["claude_output_upgrade_tokens", default: 0] += upgrade
                analysis["claude_output_above_min_snapshot_tokens", default: 0] += max(0, row.tokens.output - row.minimumOutput)
            }
            var sessionIDs = row.sessions.isEmpty ? Set([row.session]) : row.sessions
            // A copied history keeps token identity, but ownership follows its earliest
            // occurrence. Identical copied timestamps use the first journal registration;
            // tied/absent provenance stays ambiguous.
            if sessionIDs.count > 1, let earliest = row.origins.values.min(), row.origins.count == sessionIDs.count {
                sessionIDs = Set(row.origins.filter { $0.value == earliest }.keys)
                if sessionIDs.count > 1 && !sessionIDs.contains(where: { attribution[row.harness + ":" + $0]?.contains(where: \.historyPruned) == true }) {
                    let firstLinks = sessionIDs.compactMap { session -> (String, Int64)? in
                        attribution[row.harness + ":" + session]?.compactMap(\.committedAt).min().map { (session, $0) }
                    }
                    if firstLinks.count == sessionIDs.count, let first = firstLinks.map({ $0.1 }).min() {
                        sessionIDs = Set(firstLinks.filter { $0.1 == first }.map { $0.0 })
                    }
                }
            }
            var candidates = sessionIDs.reduce(into: Set<Link>()) { result, session in
                result.formUnion(attribution[row.harness + ":" + session] ?? [])
            }
            let sessionPanels = Set(candidates.map(\.panel))
            let sessionHistoryPruned = candidates.contains(where: \.historyPruned)
            let timestamp = row.origins.values.min() ?? row.originTimestamp ?? row.timestamp
            if sessionIDs.count == 1, let timestamp, !candidates.isEmpty, candidates.allSatisfy({ $0.committedAt != nil }) {
                let at = Int64(timestamp.timeIntervalSince1970 * 1000)
                let eligible = candidates.filter { $0.committedAt! <= at }
                if let latest = eligible.compactMap(\.committedAt).max() {
                    candidates = Set(eligible.filter { $0.committedAt == latest })
                } else { candidates.removeAll(); gaps.insert("usage_before_journal_attribution") }
            }
            let panels = Set(candidates.map(\.panel))
            let uniqueSessionPanel = sessionPanels.count == 1 && !(sessionHistoryPruned && candidates.isEmpty)
            let panel = row.attributionUnknown ? nil : uniqueSessionPanel ? sessionPanels.first : panels.count == 1 ? panels.first : nil
            let workspaceIDs = Set(candidates.compactMap(\.workspace))
            let workspace = panel != nil && workspaceIDs.count == 1 && candidates.allSatisfy({ $0.workspace != nil }) ? workspaceIDs.first : nil
            // On model/harness axes this aggregate still means no unique panel link.
            if panel == nil || (axis == "workspace" && workspace == nil) {
                unattributed.add(row.tokens)
                gaps.insert(panel != nil ? "workspace_attribution_unknown" : candidates.isEmpty ? "session_attribution_missing" : "ambiguous_session_attribution")
            }
            let key: String
            switch axis { case "panel": key = panel ?? "unattributed"; case "workspace": key = workspace ?? "unattributed"; case "harness": key = row.harness; default: key = row.model }
            total.add(row.tokens); groups[key, default: Tokens()].add(row.tokens)
            if row.tokens.writeUnknown > 0 { gaps.insert("cache_write_ttl_unknown") }
            if row.harness == "codex", isGPT6(row.model), row.tokens.input + row.tokens.read > 272_000, !row.requestContextKnown {
                gaps.insert("codex_per_request_context_unknown")
            }
            let price = ModelCostCatalogStore.entry(forModel: row.model, in: catalog)
            let baseCost = estimate(row, catalog: catalog)
            let unknownWrites = row.harness == "codex" && row.tokens.input > 0
            if unknownWrites { gaps.insert("codex_cache_write_tokens_unknown") }
            if let cost = baseCost {
                if unknownWrites {
                    // Uncached Codex input includes an unknown cache-write subset.
                    // Bound it between all fresh input and all cache writes; never
                    // label the baseline as an exact API estimate.
                    if let price, let write = price.cacheWriteUSD, write.isFinite, write >= 0 {
                        let contextMultiplier = isGPT6(row.model) && price.source?.hasPrefix("https://developers.openai.com/") == true && row.tokens.input + row.tokens.read > 272_000 ? 2.0 : 1.0
                        let allWrites = cost + Double(row.tokens.input) * (write - price.inUSD) * contextMultiplier / 1_000_000
                        lowerCosts[key, default: 0] += min(cost, allWrites)
                        upperCosts[key, default: 0] += max(cost, allWrites)
                    } else { unboundedCost.insert(key); gaps.insert("model_cache_rate_unavailable") }
                } else { estimates[key, default: 0] += cost; lowerCosts[key, default: 0] += cost; upperCosts[key, default: 0] += cost }
            } else { unboundedCost.insert(key) }
            if baseCost == nil || unknownWrites {
                unknownCost.insert(key); unknownCostTokens[key, default: 0] += row.tokens.totalTokens
                unknownCostCalls[key, default: 0] += row.tokens.calls
                if let price {
                    if (row.tokens.read > 0 && price.cacheReadUSD == nil) || (row.tokens.write5 > 0 && price.cacheWriteUSD == nil) || (row.tokens.write1 > 0 && price.cacheWrite1hUSD == nil) { gaps.insert("model_cache_rate_unavailable") }
                } else { gaps.insert("model_price_unavailable") }
                if row.speed != "standard" { gaps.insert("nonstandard_speed_price_unknown") }
            }
        }
        // Stream compact deduplicated rows into aggregates. No second combined
        // row array or retained historical Foundation objects is required.
        for row in claude.values { consume(row) }
        for candidate in codex.values { consume(candidate.row) }
        gaps.insert("transcript_retention_and_unrecorded_usage_unknown")
        let groupRows: [Object] = groups.keys.sorted().map { key in
            var result = groups[key]!.json; result["key"] = key
            result["estimated_api_usd"] = unknownCost.contains(key) ? null : (estimates[key] ?? 0) as Any
            result["known_api_usd_subtotal"] = estimates[key] ?? 0
            result["estimated_api_usd_lower_bound"] = lowerCosts[key] ?? 0
            result["estimated_api_usd_upper_bound"] = unboundedCost.contains(key) ? null : (upperCosts[key] ?? 0) as Any
            result["unknown_cost_tokens"] = unknownCostTokens[key] ?? 0
            result["unknown_cost_calls"] = unknownCostCalls[key] ?? 0
            return result
        }
        var totalJSON = total.json
        totalJSON["estimated_api_usd"] = unknownCost.isEmpty ? estimates.values.reduce(0, +) as Any : null
        totalJSON["known_api_usd_subtotal"] = estimates.values.reduce(0, +)
        totalJSON["estimated_api_usd_lower_bound"] = lowerCosts.values.reduce(0, +)
        totalJSON["estimated_api_usd_upper_bound"] = unboundedCost.isEmpty ? upperCosts.values.reduce(0, +) as Any : null
        totalJSON["unknown_cost_tokens"] = unknownCostTokens.values.reduce(0, +)
        totalJSON["unknown_cost_calls"] = unknownCostCalls.values.reduce(0, +)
        return ["schema_version": 1, "by": axis, "since": options.since.map(iso.string) as Any? ?? null,
                "totals": totalJSON, "unattributed": unattributed.json, "groups": groupRows,
                "until": until.map(iso.string) as Any? ?? null, "skipped_counts": counts, "analysis_counts": analysis,
                "snapshot_basis": "Claude upgrades compare the selected most-complete snapshot with first seen in sorted transcript path/append order, and with minimum observed output. This order may differ from another scanner. Codex deltas follow each rollout's append chain; copies use full timestamp/last/total tuples across source sessions.",
                "unattributed_basis": axis == "workspace" ? "No unique native panel link or no workspace mapping at usage time" : "No unique native session-to-panel link",
                "coverage_gaps": gaps.sorted(), "pricing_basis": "Current catalog standard API list rates, not subscription spend or historical billing. Unknown Codex cache writes have explicit lower/upper bounds; missing rates, TTL or request context can leave the upper bound unknown."]
    }
    private static func estimate(_ row: UsageRow, catalog: [String: ModelCostEntry]) -> Double? {
        guard !row.estimateUnknown, row.speed == "standard", let price = ModelCostCatalogStore.entry(forModel: row.model, in: catalog), row.tokens.writeUnknown == 0, price.inUSD.isFinite, price.inUSD >= 0, price.outUSD.isFinite, price.outUSD >= 0 else { return nil }
        let t = row.tokens
        var cost = Double(t.input) * price.inUSD + Double(t.output) * price.outUSD
        if t.read > 0 { guard let p = price.cacheReadUSD, p.isFinite, p >= 0 else { return nil }; cost += Double(t.read) * p }
        if t.write5 > 0 { guard let p = price.cacheWriteUSD, p.isFinite, p >= 0 else { return nil }; cost += Double(t.write5) * p }
        if t.write1 > 0 { guard let p = price.cacheWrite1hUSD, p.isFinite, p >= 0 else { return nil }; cost += Double(t.write1) * p }
        // A cumulative Codex delta may contain several small requests. Its token sum
        // cannot establish the per-request context used by the documented premium.
        if row.harness == "codex", isGPT6(row.model),
           price.source?.hasPrefix("https://developers.openai.com/") == true,
           t.input + t.read > 272_000 {
            guard row.requestContextKnown else { return nil }
            // The delta exactly equals last_token_usage: it describes one request.
            cost += Double(t.input) * price.inUSD + Double(t.output) * price.outUSD * 0.5
            if t.read > 0 { cost += Double(t.read) * (price.cacheReadUSD ?? 0) }
        }
        return cost.isFinite ? cost / 1_000_000 : nil
    }
    /// Compact native replay state. Never retain parsed payload dictionaries,
    /// input/mail bodies, or per-hang Foundation arrays across reader chunks.
    private struct Event {
        struct Hang {
            let cause: String
            let samples: Int
            let total: Double
            let maximum: Double
            let unknown: Bool
        }
        enum Detail {
            case none, title(String), explicitTitle(String), kind(String), state(String), sender(String)
            case hang(Hang), presence(Bool?, Bool?, Bool?), policy(Bool, Bool), retentionDegraded
        }
        let seq: Int64
        let ts: Date
        let type: String
        let panel: String?
        let workspace: String?
        let detail: Detail
        let transient: Bool
        init(raw: Object, seq: Int64, ts: Date, pool: inout StringPool) {
            self.seq = seq; self.ts = ts
            type = pool.intern(EventEnvelope.canonicalType(raw["type"] as? String ?? ""))
            panel = (text(raw["panel"]) ?? text(raw["surface"])).map { pool.intern($0) }
            workspace = text(raw["workspace"]).map { pool.intern($0) }
            let p = object(raw["payload"])
            transient = (p["transient"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            func owned(_ value: String) -> String { String(decoding: value.utf8, as: UTF8.self) }
            switch type {
            case "workspace.created", "workspace.renamed", "workspace.closed":
                detail = text(p["title"]).map { .title(owned($0)) } ?? .none
            case "metadata.changed":
                if p["key"] as? String == "title", ["explicit", "declare"].contains(p["source"] as? String ?? ""), let title = text(p["value"]) {
                    detail = .explicitTitle(owned(title))
                } else { detail = .none }
            case "panel.created": detail = .kind(pool.intern(text(p["kind"]) ?? "unknown"))
            case "liveness.derived": detail = .state(pool.intern(text(p["state"]) ?? "unknown"))
            case "mailbox.accepted": detail = .sender(pool.intern(text(p["from"]) ?? "unknown"))
            case "hang.precursor":
                let durations = (p["durations_ms"] as? [NSNumber] ?? []).map(\.doubleValue)
                let valid = durations.filter { $0.isFinite && $0 >= 0 }
                let reported = (p["count"] as? NSNumber)?.intValue ?? durations.count
                detail = .hang(Hang(cause: pool.intern(text(p["cause"]) ?? "unknown"), samples: valid.count,
                    total: valid.reduce(0, +), maximum: valid.max() ?? 0,
                    unknown: durations.isEmpty || valid.count != durations.count || reported > valid.count))
            case "log.opened": detail = .presence(p["app_active"] as? Bool, p["screen_locked"] as? Bool, p["system_asleep"] as? Bool)
            case "log.policy": detail = .policy(p["enabled"] as? Bool != false, p["analytics_enabled"] as? Bool != false)
            case "log.retention": detail = p["state"] as? String == "degraded" ? .retentionDegraded : .none
            default: detail = .none
            }
        }
        var title: String? { if case .title(let value) = detail { return value }; return nil }
        var explicitTitle: String? { if case .explicitTitle(let value) = detail { return value }; return nil }
        var kind: String? { if case .kind(let value) = detail { return value }; return nil }
    }
    private static func reportResult(_ options: Options, gaps: inout Set<String>) throws -> Object {
        let directory = EventLogLayout.eventsDirectoryURL(state: options.state)
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var instance = options.value("--instance")
        func production(_ name: String) -> Bool { name.hasPrefix("events-com.stage11.c11-") }
        if instance == nil && options.since == nil && !options.allInstances {
            instance = names.filter { production($0.lastPathComponent) && $0.lastPathComponent.hasSuffix(".ndjson") }
                .sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }.first.map { String($0.lastPathComponent.dropFirst("events-".count).dropLast(".ndjson".count)) }
        }
        let selected = names.filter {
            let name = $0.lastPathComponent
            guard name.hasPrefix("events-"), let marker = name.range(of: ".ndjson", options: .backwards),
                  marker.lowerBound > name.index(name.startIndex, offsetBy: "events-".count) else { return false }
            let suffix = String(name[marker.upperBound...])
            guard suffix.isEmpty || (suffix.hasPrefix(".") && (Int(suffix.dropFirst()) ?? 0) > 0) else { return false }
            if let instance { return name == "events-\(instance).ndjson" || name.hasPrefix("events-\(instance).ndjson.") }
            return options.allInstances || production(name)
        }
        var events: [String: [Int64: Event]] = [:]
        var eventPool = StringPool()
        var counts: [String: Int] = [:]
        var malformedEnvelope = false
        var invalidEnvelopes = 0
        for file in selected {
            lines(file, gaps: &gaps, counts: &counts) { row, _ in
                guard let ts = date(row["ts"]), let id = text(row["instance"]), let seq = row["seq"] as? NSNumber,
                      let version = row["v"] as? Int, [1, 2].contains(version), text(row["type"]) != nil else { malformedEnvelope = true; invalidEnvelopes += 1; return }
                events[eventPool.intern(id), default: [:]][seq.int64Value] = Event(raw: row, seq: seq.int64Value, ts: ts, pool: &eventPool)
            }
        }
        if malformedEnvelope { gaps.insert("invalid_event_envelope"); counts["invalid_event_envelope"] = invalidEnvelopes }
        var replayIncomplete = malformedEnvelope
        var bootstrapGraphs = 0, bootstrapEvents = 0, rawEvents = 0
        var bootstrapEventTypes: [String: Int] = [:]
        var starts: [Date] = [], ends: [Date] = [], created = 0, peakOpen = 0, peakWorking = 0, agentSeconds = 0.0
        var foreground = 0.0, foregroundUnknown = 0.0, hangCount = 0
        var kindsCreated: [String: Int] = [:], peakKinds: [String: Int] = [:], peakByKind: [String: Int] = [:]
        var selectionUnknown = 0.0, workspaceAgentUnknown = 0.0, waitsUnattributed = 0
        var mailboxAccepted = 0, mailboxDelivered = 0, mailFrom: [String: Int] = [:], flagCounts: [String: Int] = [:]
        var hangCauses: [String: Int] = [:], hangDurationTotal = 0.0, hangDurationMax = 0.0, hangDurationSamples = 0, hangDurationUnknown = 0
        var workspaces: [String: Object] = [:], daily: [String: Object] = [:], rhythm: [String: Int] = [:]
        var lifetime: [Double] = [], censored = 0, openAtEnd = 0
        var loadSeconds: [String: Double] = [:], loadHangs: [String: Int] = [:]
        var openLoadSeconds: [String: Double] = [:], openLoadHangs: [String: Int] = [:]
        var unknownLoadSeconds = 0.0, unknownLoadHangs = 0
        let zone = options.utc ? TimeZone(secondsFromGMT: 0)! : TimeZone.current
        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"; dayFormatter.timeZone = zone
        let hourFormatter = DateFormatter(); hourFormatter.dateFormat = "HH"; hourFormatter.timeZone = zone
        func bucket(_ n: Int) -> String { n < 10 ? "0-9" : n < 25 ? "10-24" : n < 50 ? "25-49" : "50+" }
        func openBucket(_ n: Int) -> String { n < 40 ? "under40" : n < 80 ? "40-79" : "80+" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        func workspaceRow(_ key: String) -> Object {
            workspaces[key] ?? ["id": key, "name": null, "topics": [String](), "panels_created": 0,
                                "selections": 0, "waiting_entered": 0, "selected_dwell_hours": 0.0,
                                "observed_agent_hours": 0.0]
        }
        func updatePeaks(_ open: Set<String>, _ working: Set<String>, _ kinds: [String: String]) {
            var composition: [String: Int] = [:]
            for panel in open { composition[kinds[panel] ?? "unknown", default: 0] += 1 }
            if open.count > peakOpen { peakOpen = open.count; peakKinds = composition }
            for (kind, count) in composition { peakByKind[kind] = max(peakByKind[kind] ?? 0, count) }
            peakWorking = max(peakWorking, working.count)
        }
        func dailyRow(_ key: String) -> Object {
            daily[key] ?? ["date": key, "events": 0, "panels_created": 0, "peak_open": 0, "peak_working": 0,
                           "observed_peak_open": 0, "observed_peak_working": 0, "load_unknown_hours": 0.0,
                           "observed_hours": 0.0, "observed_agent_hours": 0.0, "observed_foreground_hours": 0.0,
                           "presence_unknown_hours": 0.0]
        }
        func dailyPeaks(_ d: inout Object, open: Int, working: Int, loadKnown: Bool) {
            d["observed_peak_open"] = max(d["observed_peak_open"] as? Int ?? 0, open)
            d["observed_peak_working"] = max(d["observed_peak_working"] as? Int ?? 0, working)
            if loadKnown && !(d["peak_open"] is NSNull) {
                d["peak_open"] = max(d["peak_open"] as? Int ?? 0, open)
                d["peak_working"] = max(d["peak_working"] as? Int ?? 0, working)
            } else { d["peak_open"] = null; d["peak_working"] = null }
        }
        func integrateDaily(_ from: Date, _ to: Date, open: Int, working: Int, presence: Bool?, loadKnown: Bool, observedLoad: Bool) {
            var cursor = from
            while cursor < to {
                let midnight = calendar.startOfDay(for: cursor)
                let boundary = calendar.date(byAdding: .day, value: 1, to: midnight)!
                let end = min(boundary, to)
                let hours = end.timeIntervalSince(cursor) / 3600
                let key = dayFormatter.string(from: cursor)
                var d = dailyRow(key)
                d["observed_hours"] = (d["observed_hours"] as? Double ?? 0) + hours
                dailyPeaks(&d, open: observedLoad ? open : 0, working: observedLoad ? working : 0, loadKnown: loadKnown)
                if observedLoad {
                    d["observed_agent_hours"] = (d["observed_agent_hours"] as? Double ?? 0) + hours * Double(working)
                }
                if !loadKnown { d["load_unknown_hours"] = (d["load_unknown_hours"] as? Double ?? 0) + hours }
                if presence == true { d["observed_foreground_hours"] = (d["observed_foreground_hours"] as? Double ?? 0) + hours }
                if presence == nil { d["presence_unknown_hours"] = (d["presence_unknown_hours"] as? Double ?? 0) + hours }
                daily[key] = d; cursor = end
            }
        }
        let instances = events.keys.sorted()
        for id in instances {
            let ordered = events[id]!.values.sorted { $0.seq < $1.seq }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let start = max(options.since ?? first.ts, first.ts), end = min(options.until ?? last.ts, last.ts)
            guard end >= start else { continue }
            starts.append(start); ends.append(end)
            // Classify from the complete retained sequence before replay. A later
            // marker or rotated-away workspace.created must not create false load.
            var bootstrapWorkspaces = Set<String>(), bootstrapPanels = Set<String>()
            for event in ordered where event.transient {
                if let workspace = event.workspace { bootstrapWorkspaces.insert(workspace) }
            }
            for event in ordered where event.transient || event.workspace.map(bootstrapWorkspaces.contains) == true {
                if let panel = event.panel { bootstrapPanels.insert(panel) }
            }
            bootstrapGraphs += bootstrapWorkspaces.count
            if first.seq != 1 { gaps.insert("event_history_truncated"); replayIncomplete = true }
            if first.type != "log.opened" { gaps.insert("instance_start_missing"); replayIncomplete = true }
            var open = Set<String>(), working = Set<String>(), births: [String: Date] = [:]
            var panelKinds: [String: String] = [:], panelWorkspaces: [String: String] = [:]
            var selectedWorkspace: String?
            // Edges can rebuild a lower bound after a gap, but cannot establish a full
            // census. No event currently restores exact load knowledge in this format.
            var loadKnown = first.seq == 1 && first.type == "log.opened" && !malformedEnvelope
            var active: Bool?, locked: Bool?, asleep: Bool?
            var analyticsEnabled = true, historyEnabled = true
            var previous = first.ts, previousSeq = first.seq - 1
            for event in ordered {
                let now = max(previous, event.ts) // seq is authoritative; clamp racing timestamp inversions.
                let duration = max(0, min(end, now).timeIntervalSince(max(start, previous)))
                let sequenceGap = event.seq != previousSeq + 1 || event.type == "log.dropped"
                if sequenceGap {
                    gaps.insert("event_sequence_gap"); replayIncomplete = true; loadKnown = false
                    active = nil; locked = nil; asleep = nil; selectedWorkspace = nil
                    open.removeAll(); working.removeAll(); censored += births.count; births.removeAll()
                }
                previousSeq = event.seq
                if !sequenceGap && historyEnabled {
                    if duration > 0 { updatePeaks(open, working, panelKinds) }
                    agentSeconds += duration * Double(working.count)
                }
                if !sequenceGap && historyEnabled && loadKnown {
                    loadSeconds[bucket(working.count), default: 0] += duration
                    openLoadSeconds[openBucket(open.count), default: 0] += duration
                } else { unknownLoadSeconds += duration }
                if duration > 0 {
                    if !sequenceGap && historyEnabled, let selected = selectedWorkspace {
                        var ws = workspaceRow(selected)
                        ws["selected_dwell_hours"] = (ws["selected_dwell_hours"] as? Double ?? 0) + duration / 3600
                        workspaces[selected] = ws
                    } else { selectionUnknown += duration }
                    if !sequenceGap && historyEnabled {
                        for panel in working {
                            if let w = panelWorkspaces[panel] {
                                var ws = workspaceRow(w)
                                ws["observed_agent_hours"] = (ws["observed_agent_hours"] as? Double ?? 0) + duration / 3600
                                workspaces[w] = ws
                            } else { workspaceAgentUnknown += duration / 3600 }
                        }
                    }
                }
                let presence: Bool?
                if !analyticsEnabled { presence = nil }
                else if active == false || locked == true || asleep == true { presence = false }
                else if active == true && locked == false && asleep == false { presence = true }
                else { presence = nil }
                if presence == true { foreground += duration }
                if presence == nil { foregroundUnknown += duration }
                if duration > 0 {
                    integrateDaily(max(start, previous), min(end, now), open: open.count, working: working.count,
                                   presence: presence, loadKnown: !sequenceGap && historyEnabled && loadKnown,
                                   observedLoad: !sequenceGap && historyEnabled)
                }
                if now > end { break }
                previous = now
                let inRange = event.ts >= start && event.ts <= end
                if inRange { rawEvents += 1 }
                let isBootstrap = event.workspace.map(bootstrapWorkspaces.contains) == true
                    || event.panel.map(bootstrapPanels.contains) == true
                if isBootstrap {
                    if inRange { bootstrapEvents += 1; bootstrapEventTypes[event.type, default: 0] += 1 }
                    // Sequence, time and global presence integration already advanced.
                    // The raw stream and bounded host transcript usage remain intact.
                    continue
                }
                let panel = event.panel
                if let w = event.workspace {
                    if let panel { panelWorkspaces[panel] = w }
                    var ws = workspaceRow(w)
                    if let title = event.title { ws["name"] = title }
                    if let title = event.explicitTitle {
                        var topics = ws["topics"] as? [String] ?? []; if !topics.contains(title), topics.count < 12 { topics.append(title) }; ws["topics"] = topics
                    }
                    if event.type == "panel.created", inRange { ws["panels_created"] = (ws["panels_created"] as? Int ?? 0) + 1 }
                    workspaces[w] = ws
                }
                switch event.type {
                case "panel.created":
                    if let panel { open.insert(panel); births[panel] = event.ts; panelKinds[panel] = event.kind ?? "unknown" }
                    if inRange { created += 1; kindsCreated[event.kind ?? "unknown", default: 0] += 1 }
                case "panel.closed":
                    if let panel {
                        open.remove(panel); working.remove(panel)
                        if let born = births.removeValue(forKey: panel), born >= start, inRange { lifetime.append(max(0, event.ts.timeIntervalSince(born))) }
                        else if inRange { censored += 1 }
                    }
                case "workspace.selected":
                    selectedWorkspace = event.workspace
                    if inRange, let w = selectedWorkspace {
                        var ws = workspaceRow(w); ws["selections"] = (ws["selections"] as? Int ?? 0) + 1; workspaces[w] = ws
                    }
                case "workspace.closed":
                    if selectedWorkspace == event.workspace { selectedWorkspace = nil }
                case "waiting.entered":
                    if inRange {
                        if let w = event.workspace ?? panel.flatMap({ panelWorkspaces[$0] }) {
                            var ws = workspaceRow(w); ws["waiting_entered"] = (ws["waiting_entered"] as? Int ?? 0) + 1; workspaces[w] = ws
                        } else { waitsUnattributed += 1 }
                    }
                case "mailbox.accepted":
                    if inRange { mailboxAccepted += 1; if case .sender(let sender) = event.detail { mailFrom[sender, default: 0] += 1 } }
                case "mailbox.delivered": if inRange { mailboxDelivered += 1 }
                case "flag.raised", "flag.lowered", "flag.suppressed", "flag.unsuppressed":
                    if inRange { flagCounts[event.type, default: 0] += 1 }
                case "liveness.derived":
                    if let panel { if case .state("working") = event.detail { working.insert(panel) } else { working.remove(panel) } }
                case "app.activated": active = true
                case "app.deactivated": active = false
                case "screen.locked": locked = true
                case "screen.unlocked": locked = false
                case "system.sleep": asleep = true
                case "system.wake": asleep = false
                case "log.opened":
                    if case .presence(let a, let l, let s) = event.detail { active = a; locked = l; asleep = s }
                case "hang.precursor":
                    if inRange {
                        hangCount += 1
                        if loadKnown && historyEnabled {
                            loadHangs[bucket(working.count), default: 0] += 1
                            openLoadHangs[openBucket(open.count), default: 0] += 1
                        } else { unknownLoadHangs += 1 }
                        if case .hang(let hang) = event.detail {
                            hangCauses[hang.cause, default: 0] += 1
                            hangDurationSamples += hang.samples; hangDurationTotal += hang.total
                            hangDurationMax = max(hangDurationMax, hang.maximum)
                            if hang.unknown { hangDurationUnknown += 1; gaps.insert("hang_durations_unknown") }
                        }
                    }
                case "log.policy":
                    if case .policy(let enabled, let analytics) = event.detail { historyEnabled = enabled; analyticsEnabled = enabled && analytics }
                    if !analyticsEnabled { active = nil; locked = nil; asleep = nil; gaps.insert("analytics_disabled_span") }
                    if !historyEnabled { replayIncomplete = true; loadKnown = false; selectedWorkspace = nil; open.removeAll(); working.removeAll(); censored += births.count; births.removeAll() }
                case "log.retention":
                    if inRange, case .retentionDegraded = event.detail { gaps.insert("retention_reconciliation_degraded") }
                case "log.dropped": gaps.insert("event_log_dropped_events")
                default: break
                }
                if inRange {
                    updatePeaks(open, working, panelKinds)
                    let day = dayFormatter.string(from: event.ts)
                    var d = dailyRow(day)
                    d["events"] = (d["events"] as? Int ?? 0) + 1
                    if event.type == "panel.created" { d["panels_created"] = (d["panels_created"] as? Int ?? 0) + 1 }
                    dailyPeaks(&d, open: open.count, working: working.count, loadKnown: historyEnabled && loadKnown)
                    daily[day] = d; rhythm[hourFormatter.string(from: event.ts), default: 0] += 1
                }
            }
            openAtEnd += open.count; censored += births.count
        }
        // Replay is complete. Release input event state before scanning transcripts.
        events.removeAll(keepingCapacity: false); eventPool = StringPool()
        if starts.isEmpty { gaps.insert("event_history_unavailable") }
        if foregroundUnknown > 0 { gaps.insert("presence_state_unknown") }
        if unknownLoadSeconds > 0 || unknownLoadHangs > 0 { gaps.insert("load_state_unknown") }
        gaps.insert("restored_panel_births_and_liveness_before_retention_unknown")
        lifetime.sort()
        func percentile(_ p: Double) -> Any { lifetime.isEmpty ? null : lifetime[min(lifetime.count - 1, Int(Double(lifetime.count - 1) * p))] / 60 }
        var buckets: [Object] = ["0-9", "10-24", "25-49", "50+"].map { key in
            let hours = (loadSeconds[key] ?? 0) / 3600
            return ["working_panels": key, "observed_hours": hours, "hangs": loadHangs[key] ?? 0, "hangs_per_hour": hours > 0 ? Double(loadHangs[key] ?? 0) / hours as Any : null]
        }
        var openBuckets: [Object] = ["under40", "40-79", "80+"].map { key in
            let hours = (openLoadSeconds[key] ?? 0) / 3600
            return ["open_panels": key, "observed_hours": hours, "hangs": openLoadHangs[key] ?? 0,
                    "hangs_per_hour": hours > 0 ? Double(openLoadHangs[key] ?? 0) / hours as Any : null]
        }
        buckets.append(["working_panels": "unknown", "observed_hours": unknownLoadSeconds / 3600,
                        "hangs": unknownLoadHangs, "hangs_per_hour": null])
        openBuckets.append(["open_panels": "unknown", "observed_hours": unknownLoadSeconds / 3600,
                            "hangs": unknownLoadHangs, "hangs_per_hour": null])
        let tokens: Object?
        if let start = starts.min(), let end = ends.max() {
            var usageOptions = options; usageOptions.since = start
            tokens = try usageResult(usageOptions, gaps: &gaps, until: end)
        } else {
            gaps.insert("usage_span_unavailable")
            tokens = nil // No span means no transcript or journal scan, not host-wide usage.
        }
        return ["schema_version": 1, "instances": instances, "start": starts.min().map(iso.string) as Any? ?? null,
                "end": ends.max().map(iso.string) as Any? ?? null, "span_hours": starts.min().flatMap { s in ends.max().map { $0.timeIntervalSince(s) / 3600 } } as Any? ?? null,
                "panels_created": starts.isEmpty ? null : created as Any,
                "raw_events_observed": rawEvents, "bootstrap_graphs_excluded": bootstrapGraphs,
                "bootstrap_events_excluded": bootstrapEvents, "bootstrap_event_types_excluded": bootstrapEventTypes,
                "bootstrap_scope": "Pre-install bootstrap workspace graphs marked by strict payload transient=true in retained selected-instance history. Graph counts include replay baselines; event counts cover the observed span. Installed graph summaries exclude them; process evidence, raw history and host transcript tokens remain included.",
                "observed_peak_open_per_instance": peakOpen, "observed_peak_working_per_instance": peakWorking,
                "kinds_created": starts.isEmpty ? null : kindsCreated as Any, "observed_peak_open_kinds": peakKinds, "observed_peak_open_by_kind": peakByKind,
                "peak_open_kinds": starts.isEmpty || replayIncomplete ? null : peakKinds as Any,
                "peak_open_by_kind": starts.isEmpty || replayIncomplete ? null : peakByKind as Any,
                "peak_open_per_instance": starts.isEmpty || replayIncomplete ? null : peakOpen as Any,
                "peak_working_per_instance": starts.isEmpty || replayIncomplete ? null : peakWorking as Any, "open_at_observed_end": starts.isEmpty || replayIncomplete ? null : openAtEnd as Any,
                "observed_agent_hours": starts.isEmpty ? null : agentSeconds / 3600 as Any,
                "foreground_hours": foregroundUnknown > 0 || starts.isEmpty ? null : foreground / 3600 as Any,
                "observed_foreground_hours": foreground / 3600, "presence_unknown_hours": foregroundUnknown / 3600,
                "foreground_hours_range": ["minimum": starts.isEmpty ? null : foreground / 3600 as Any,
                                           "maximum": starts.isEmpty ? null : (foreground + foregroundUnknown) / 3600 as Any],
                "closed_lifetimes_minutes": ["count": lifetime.count, "p10": percentile(0.1), "median": percentile(0.5), "p90": percentile(0.9), "censored_panels": censored],
                "workspaces": workspaces.keys.sorted().compactMap { workspaces[$0] }, "daily": daily.keys.sorted().compactMap { daily[$0] },
                "timezone": zone.identifier, "instance_scope": options.value("--instance") != nil ? "explicit" : options.allInstances ? "all" : "production",
                "workspace_selection_unknown_hours": selectionUnknown / 3600, "workspace_agent_hours_unattributed": workspaceAgentUnknown,
                "waiting_entered_unattributed": waitsUnattributed,
                "mailbox_accepted": starts.isEmpty ? null : mailboxAccepted as Any,
                "mailbox_delivered": starts.isEmpty ? null : mailboxDelivered as Any,
                "mail_from": starts.isEmpty ? null : mailFrom as Any, "flag_events": starts.isEmpty ? null : flagCounts as Any,
                "load_unknown_hours": unknownLoadSeconds / 3600, "hangs_with_unknown_load": unknownLoadHangs,
                "hour_of_day_events": rhythm, "hang_precursors": hangCount, "hang_causes": starts.isEmpty ? null : hangCauses as Any,
                "hang_durations_ms": ["samples": hangDurationSamples, "unknown_precursors": hangDurationUnknown,
                                      "total": hangDurationUnknown > 0 || starts.isEmpty || replayIncomplete ? null : hangDurationTotal as Any,
                                      "max": hangDurationUnknown > 0 || starts.isEmpty || replayIncomplete ? null : hangDurationMax as Any,
                                      "observed_total": hangDurationTotal, "observed_max": hangDurationMax], "hang_rate_by_working_load": buckets, "hang_rate_by_open_load": openBuckets,
                "skipped_counts": counts.merging(tokens?["skipped_counts"] as? [String: Int] ?? [:], uniquingKeysWith: +),
                "host_usage": tokens.map { $0 as Any } ?? null,
                "usage_scope": tokens == nil ? "Unknown: no observed event span; host transcripts were not scanned." : "Host transcripts during the observed span, across all instances; not exclusive instance usage. Unknown transcript timestamps are included separately in coverage.",
                "coverage_gaps": gaps.sorted()]
    }
    private static func usageMarkdown(_ result: Object) -> String {
        var output = "Token usage by \(result["by"] ?? "model")\n\nKey | Fresh/uncached input | Cache read | Cache write | Output | API estimate USD\n--- | ---: | ---: | ---: | ---: | ---:\n"
        for row in result["groups"] as? [Object] ?? [] {
            let write = number(row["cache_write_5m_tokens"]) + number(row["cache_write_1h_tokens"]) + number(row["cache_write_unknown_ttl_tokens"])
            output += "\(row["key"] ?? "unknown") | \(row["input_tokens"] ?? 0) | \(row["cache_read_tokens"] ?? 0) | \(write) | \(row["output_tokens"] ?? 0) | \(row["estimated_api_usd"] is NSNull ? "unknown" : String(describing: row["estimated_api_usd"] ?? "unknown"))\n"
        }
        let totals = object(result["totals"])
        output += "\nTotal API estimate USD: \(totals["estimated_api_usd"] is NSNull ? "unknown" : String(describing: totals["estimated_api_usd"] ?? "unknown")); known subtotal: \(totals["known_api_usd_subtotal"] ?? 0); unknown-cost tokens: \(totals["unknown_cost_tokens"] ?? 0).\n"
        output += "API list-rate bounds USD: \(totals["estimated_api_usd_lower_bound"] ?? 0) to \(totals["estimated_api_usd_upper_bound"] is NSNull ? "unknown" : String(describing: totals["estimated_api_usd_upper_bound"] ?? "unknown")).\n"
        output += "\nUnattributed tokens: \(object(result["unattributed"])["total_tokens"] ?? 0)\n\n\(result["pricing_basis"] ?? "")\nCoverage gaps: \((result["coverage_gaps"] as? [String] ?? []).joined(separator: ", "))"
        return output
    }
    private static func reportMarkdown(_ report: Object) -> String {
        func show(_ key: String) -> String { report[key] is NSNull ? "unknown" : String(describing: report[key] ?? "unknown") }
        let tokenMarkdown = (report["host_usage"] as? Object).map(usageMarkdown)
            ?? "Unknown: no observed event span; host transcripts were not scanned."
        var output = "# Local activity report\n\nObserved span: \(show("start")) to \(show("end")) (\(show("span_hours")) h).\n\n"
        for (label, key) in [("Panels created", "panels_created"), ("Peak open per instance", "peak_open_per_instance"), ("Peak working per instance", "peak_working_per_instance"), ("Observed agent hours", "observed_agent_hours"), ("Foreground hours", "foreground_hours"), ("Observed foreground hours", "observed_foreground_hours"), ("Presence unknown hours", "presence_unknown_hours"), ("Hang precursors", "hang_precursors")] { output += "- \(label): \(show(key))\n" }
        output += "\nBootstrap workspace graphs excluded: \(show("bootstrap_graphs_excluded")); events excluded: \(show("bootstrap_events_excluded")) of \(show("raw_events_observed")) raw events.\n"
        let bounds = object(report["foreground_hours_range"])
        func bound(_ key: String) -> String { bounds[key] is NSNull ? "unknown" : String(describing: bounds[key] ?? "unknown") }
        output += "\nForeground hours range: \(bound("minimum")) to \(bound("maximum")).\n"
        output += "\n## Daily activity (\(show("timezone")))\n\nDate | Events | Created | Peak open | Peak working | Observed peak open | Observed peak working | Observed h | Observed agent h | Unknown load h\n--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---:\n"
        for d in report["daily"] as? [Object] ?? [] {
            func cell(_ key: String) -> String { d[key] is NSNull ? "unknown" : String(describing: d[key] ?? "unknown") }
            output += ["date", "events", "panels_created", "peak_open", "peak_working", "observed_peak_open", "observed_peak_working", "observed_hours", "observed_agent_hours", "load_unknown_hours"].map(cell).joined(separator: " | ") + "\n"
        }
        output += "\n## Workspaces and observed topics\n\n"
        for w in report["workspaces"] as? [Object] ?? [] { output += "- \(w["name"] is NSNull ? "unknown" : String(describing: w["name"] ?? "unknown")) (\(w["id"] ?? "")): \((w["topics"] as? [String] ?? []).joined(separator: ", "))\n" }
        let extraKeys = ["kinds_created", "peak_open_kinds", "peak_open_by_kind", "mailbox_accepted", "mailbox_delivered", "mail_from", "flag_events", "hang_causes", "hang_durations_ms", "workspace_selection_unknown_hours", "workspace_agent_hours_unattributed", "waiting_entered_unattributed"]
        var extra: Object = [:]; for key in extraKeys { extra[key] = report[key] ?? null }
        output += "\n## Workspace dwell, coordination and health summaries\n\n```json\n\((try? json(["workspaces": report["workspaces"] ?? null, "summaries": extra])) ?? "{}")\n```\n"
        output += "\n## Lifetimes, rhythm and hang rates\n\n```json\n\((try? json(["closed_lifetimes_minutes": report["closed_lifetimes_minutes"] ?? null, "hour_of_day_events": report["hour_of_day_events"] ?? null, "hang_rate_by_working_load": report["hang_rate_by_working_load"] ?? null, "hang_rate_by_open_load": report["hang_rate_by_open_load"] ?? null])) ?? "{}")\n```\n\n## Host token usage\n\n\(report["usage_scope"] ?? "")\n\n\(tokenMarkdown)\n\nCoverage gaps: \((report["coverage_gaps"] as? [String] ?? []).joined(separator: ", "))\n"
        return output
    }
}
