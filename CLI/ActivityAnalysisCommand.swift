import Foundation
import SQLite3

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
        return fractional.date(from: s) ?? iso.date(from: s)
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
            if !needles.isEmpty && !needles.contains(where: { data.range(of: $0) != nil }) {
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
            if sqlite3_prepare_v2(db, "SELECT value FROM journal_meta WHERE key='coverage_low_water'", -1, &meta, nil) == SQLITE_OK,
               sqlite3_step(meta) == SQLITE_ROW, sqlite3_column_int64(meta, 0) > 1 { gaps.insert("journal_history_pruned") }
            if let meta { sqlite3_finalize(meta) }
            defer { sqlite3_finalize(stmt) }
            func column(_ n: Int32) -> String? { sqlite3_column_text(stmt, n).map { String(cString: $0) } }
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                if let panel = column(0), let session = column(1), let kind = column(2) {
                    result[harness(kind) + ":" + session, default: []].insert(Link(panel: panel, workspace: column(3), committedAt: timed ? sqlite3_column_int64(stmt, 4) : nil))
                }
                code = sqlite3_step(stmt)
            }
            if code != SQLITE_DONE { gaps.insert("journal_read_incomplete") }
        }
        return result
    }
    private struct Tokens {
        var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, write5: Int64 = 0, write1: Int64 = 0, writeUnknown: Int64 = 0, reasoning: Int64 = 0, calls: Int64 = 0
        mutating func add(_ t: Tokens) {
            input += t.input; output += t.output; read += t.read; write5 += t.write5; write1 += t.write1; writeUnknown += t.writeUnknown; reasoning += t.reasoning; calls += t.calls
        }
        var json: Object { ["input_tokens": input, "output_tokens": output, "cache_read_tokens": read, "cache_write_5m_tokens": write5, "cache_write_1h_tokens": write1, "cache_write_unknown_ttl_tokens": writeUnknown, "reasoning_output_tokens": reasoning, "calls": calls, "total_tokens": input + output + read + write5 + write1 + writeUnknown] }
    }
    private struct UsageRow {
        let session: String, harness: String, model: String
        let timestamp: Date?
        let tokens: Tokens
        var speed: String = "standard"
        var sessions: Set<String> = []
        var origins: [String: Date] = [:]
        var requestContextKnown = false
    }
    private static func claudeRow(_ d: Object, file: URL, line: Int) -> (String, UsageRow)? {
        let m = object(d["message"])
        let u = object(m["usage"])
        guard d["type"] as? String == "assistant", !u.isEmpty, m["model"] as? String != "<synthetic>" else { return nil }
        let session = text(d["sessionId"]) ?? file.deletingPathExtension().lastPathComponent
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
        let row = UsageRow(session: session, harness: "claude", model: text(m["model"]) ?? "unknown", timestamp: date(d["timestamp"]), tokens: tokens, speed: text(u["speed"]) ?? "standard")
        return (key, row)
    }
    private static func usageResult(_ options: Options, gaps: inout Set<String>, until: Date? = nil) throws -> Object {
        let attribution = links(options, gaps: &gaps)
        var counts: [String: Int] = [:]
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
                guard let (key, parsed) = claudeRow(d, file: file, line: line) else { return }
                var row = parsed
                row.sessions = [row.session]
                if let timestamp = row.timestamp { row.origins[row.session] = timestamp }
                let tokens = row.tokens
                // Streaming snapshots repeat identity; retain the most complete usage snapshot.
                if var old = claude[key] {
                    let sessions = old.sessions.union(row.sessions)
                    let origins = old.origins.merging(row.origins, uniquingKeysWith: min)
                    if number(old.tokens.json["total_tokens"]) > number(tokens.json["total_tokens"]) {
                        old.sessions = sessions; old.origins = origins; claude[key] = old; return
                    }
                    row.sessions = sessions; row.origins = origins
                }
                claude[key] = row
            }
        }
        if missingIdentity { gaps.insert("claude_dedup_identity_missing") }
        var rows = Array(claude.values)
        var codex: [String: [(Date?, String, Object, Object, String, Int)]] = [:]
        for file in files(options.codex, ext: "jsonl", gaps: &gaps) {
            var session = file.deletingPathExtension().lastPathComponent, model = "unknown"
            lines(file, gaps: &gaps, counts: &counts, matching: ["token_count", "session_meta", "turn_context"].map { Data($0.utf8) }) { d, line in
                let p = object(d["payload"])
                if d["type"] as? String == "session_meta" { session = text(p["id"]) ?? session }
                if d["type"] as? String == "turn_context" { model = text(p["model"]) ?? model }
                if d["type"] as? String == "event_msg", p["type"] as? String == "token_count" {
                    let info = object(p["info"]), total = object(info["total_token_usage"])
                    if !total.isEmpty { codex[session, default: []].append((date(d["timestamp"]), model, total, object(info["last_token_usage"]), file.path, line)) }
                }
            }
        }
        for (session, samples) in codex {
            var previous: Object = [:], seen = Set<String>()
            for (timestamp, model, total, last, _, _) in samples.sorted(by: {
                if $0.0 != $1.0 { return ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }
                return $0.4 == $1.4 ? $0.5 < $1.5 : $0.4 < $1.4
            }) {
                let signature = (timestamp.map(iso.string) ?? "unknown") + ((try? json(total)) ?? "")
                if !seen.insert(signature).inserted { continue }
                let keys = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]
                if !previous.isEmpty && keys.allSatisfy({ number(total[$0]) == number(previous[$0]) }) { continue }
                let reset = keys.contains { number(total[$0]) < number(previous[$0]) }
                var delta: [String: Int64] = [:]
                for key in keys { delta[key] = reset ? number(last[key]) : number(total[key]) - number(previous[key]) }
                if reset { gaps.insert(last.isEmpty ? "codex_counter_reset_usage_unknown" : "codex_counter_reset_last_usage_only") }
                previous = total
                let input = delta["input_tokens"] ?? 0, cached = delta["cached_input_tokens"] ?? 0
                if cached > input { gaps.insert("codex_cached_tokens_exceed_input") }
                rows.append(UsageRow(session: session, harness: "codex", model: model, timestamp: timestamp,
                                     tokens: Tokens(input: max(0, input - cached), output: delta["output_tokens"] ?? 0, read: cached, reasoning: delta["reasoning_output_tokens"] ?? 0, calls: 1),
                                     requestContextKnown: !last.isEmpty && keys.allSatisfy { delta[$0] == number(last[$0]) }))
            }
        }
        var total = Tokens(), unattributed = Tokens(), groups: [String: Tokens] = [:]
        var estimates: [String: Double] = [:], unknownCost = Set<String>()
        var unknownCostTokens: [String: Int64] = [:], unknownCostCalls: [String: Int64] = [:]
        var lowerCosts: [String: Double] = [:], upperCosts: [String: Double] = [:], unboundedCost = Set<String>()
        let catalog = ModelCostCatalogStore(directory: options.state).resolvedCatalog()
        let axis = options.value("--by") ?? "model"
        for row in rows {
            let usageTime = row.origins.values.min() ?? row.timestamp
            if usageTime == nil { gaps.insert("usage_timestamp_unknown_included") }
            if let since = options.since, let ts = usageTime, ts < since { continue }
            if let until, let ts = usageTime, ts > until { continue }
            var sessionIDs = row.sessions.isEmpty ? Set([row.session]) : row.sessions
            // A copied history keeps token identity, but ownership follows its earliest
            // occurrence. Identical copied timestamps use the first journal registration;
            // tied/absent provenance stays ambiguous.
            if sessionIDs.count > 1, let earliest = row.origins.values.min(), row.origins.count == sessionIDs.count {
                sessionIDs = Set(row.origins.filter { $0.value == earliest }.keys)
                if sessionIDs.count > 1 && !gaps.contains("journal_history_pruned") {
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
            let timestamp = row.origins.values.min() ?? row.timestamp
            if sessionIDs.count == 1, let timestamp, !candidates.isEmpty, candidates.allSatisfy({ $0.committedAt != nil }) {
                let at = Int64(timestamp.timeIntervalSince1970 * 1000)
                let eligible = candidates.filter { $0.committedAt! <= at }
                if let latest = eligible.compactMap(\.committedAt).max() {
                    candidates = Set(eligible.filter { $0.committedAt == latest })
                } else { candidates.removeAll(); gaps.insert("usage_before_journal_attribution") }
            }
            let panels = Set(candidates.map(\.panel))
            let uniqueSessionPanel = sessionPanels.count == 1 && !(gaps.contains("journal_history_pruned") && candidates.isEmpty)
            let panel = uniqueSessionPanel ? sessionPanels.first : panels.count == 1 ? panels.first : nil
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
                unknownCost.insert(key); unknownCostTokens[key, default: 0] += number(row.tokens.json["total_tokens"])
                unknownCostCalls[key, default: 0] += row.tokens.calls
                if let price {
                    if (row.tokens.read > 0 && price.cacheReadUSD == nil) || (row.tokens.write5 > 0 && price.cacheWriteUSD == nil) || (row.tokens.write1 > 0 && price.cacheWrite1hUSD == nil) { gaps.insert("model_cache_rate_unavailable") }
                } else { gaps.insert("model_price_unavailable") }
                if row.speed != "standard" { gaps.insert("nonstandard_speed_price_unknown") }
            }
        }
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
                "until": until.map(iso.string) as Any? ?? null, "skipped_counts": counts,
                "unattributed_basis": axis == "workspace" ? "No unique native panel link or no workspace mapping at usage time" : "No unique native session-to-panel link",
                "coverage_gaps": gaps.sorted(), "pricing_basis": "Current catalog standard API list rates, not subscription spend or historical billing. Unknown Codex cache writes have explicit lower/upper bounds; missing rates, TTL or request context can leave the upper bound unknown."]
    }
    private static func estimate(_ row: UsageRow, catalog: [String: ModelCostEntry]) -> Double? {
        guard row.speed == "standard", let price = ModelCostCatalogStore.entry(forModel: row.model, in: catalog), row.tokens.writeUnknown == 0, price.inUSD.isFinite, price.inUSD >= 0, price.outUSD.isFinite, price.outUSD >= 0 else { return nil }
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
    private struct Event {
        let raw: Object
        let seq: Int64
        let ts: Date
        let instance: String
        var type: String { EventEnvelope.canonicalType(raw["type"] as? String ?? "") }
        var panel: String? { text(raw["panel"]) ?? text(raw["surface"]) }
        var workspace: String? { text(raw["workspace"]) }
        var payload: Object { object(raw["payload"]) }
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
        var counts: [String: Int] = [:]
        var malformedEnvelope = false
        var invalidEnvelopes = 0
        for file in selected {
            lines(file, gaps: &gaps, counts: &counts) { row, _ in
                guard let ts = date(row["ts"]), let id = text(row["instance"]), let seq = row["seq"] as? NSNumber,
                      let version = row["v"] as? Int, [1, 2].contains(version), text(row["type"]) != nil else { malformedEnvelope = true; invalidEnvelopes += 1; return }
                events[id, default: [:]][seq.int64Value] = Event(raw: row, seq: seq.int64Value, ts: ts, instance: id)
            }
        }
        if malformedEnvelope { gaps.insert("invalid_event_envelope"); counts["invalid_event_envelope"] = invalidEnvelopes }
        var replayIncomplete = malformedEnvelope
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
        for id in events.keys.sorted() {
            let ordered = events[id]!.values.sorted { $0.seq < $1.seq }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let start = max(options.since ?? first.ts, first.ts), end = min(options.until ?? last.ts, last.ts)
            guard end >= start else { continue }
            starts.append(start); ends.append(end)
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
                let panel = event.panel, payload = event.payload
                if let w = event.workspace {
                    if let panel { panelWorkspaces[panel] = w }
                    var ws = workspaceRow(w)
                    if event.type.hasPrefix("workspace."), let title = text(payload["title"]) { ws["name"] = title }
                    if event.type == "metadata.changed", payload["key"] as? String == "title", let title = text(payload["value"]), ["explicit", "declare"].contains(payload["source"] as? String ?? "") {
                        var topics = ws["topics"] as? [String] ?? []; if !topics.contains(title), topics.count < 12 { topics.append(title) }; ws["topics"] = topics
                    }
                    if event.type == "panel.created", inRange { ws["panels_created"] = (ws["panels_created"] as? Int ?? 0) + 1 }
                    workspaces[w] = ws
                }
                switch event.type {
                case "panel.created":
                    if let panel { open.insert(panel); births[panel] = event.ts; panelKinds[panel] = text(payload["kind"]) ?? "unknown" }
                    if inRange { created += 1; kindsCreated[text(payload["kind"]) ?? "unknown", default: 0] += 1 }
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
                    if inRange { mailboxAccepted += 1; mailFrom[text(payload["from"]) ?? "unknown", default: 0] += 1 }
                case "mailbox.delivered": if inRange { mailboxDelivered += 1 }
                case "flag.raised", "flag.lowered", "flag.suppressed", "flag.unsuppressed":
                    if inRange { flagCounts[event.type, default: 0] += 1 }
                case "liveness.derived":
                    if let panel { if payload["state"] as? String == "working" { working.insert(panel) } else { working.remove(panel) } }
                case "app.activated": active = true
                case "app.deactivated": active = false
                case "screen.locked": locked = true
                case "screen.unlocked": locked = false
                case "system.sleep": asleep = true
                case "system.wake": asleep = false
                case "log.opened":
                    active = payload["app_active"] as? Bool; locked = payload["screen_locked"] as? Bool; asleep = payload["system_asleep"] as? Bool
                case "hang.precursor":
                    if inRange {
                        hangCount += 1
                        if loadKnown && historyEnabled {
                            loadHangs[bucket(working.count), default: 0] += 1
                            openLoadHangs[openBucket(open.count), default: 0] += 1
                        } else { unknownLoadHangs += 1 }
                        hangCauses[text(payload["cause"]) ?? "unknown", default: 0] += 1
                        let durations = (payload["durations_ms"] as? [NSNumber] ?? []).map(\.doubleValue)
                        let valid = durations.filter { $0.isFinite && $0 >= 0 }
                        hangDurationSamples += valid.count; hangDurationTotal += valid.reduce(0, +)
                        hangDurationMax = max(hangDurationMax, valid.max() ?? 0)
                        let reportedCount = (payload["count"] as? NSNumber)?.intValue ?? durations.count
                        if durations.isEmpty || valid.count != durations.count || reportedCount > valid.count {
                            hangDurationUnknown += 1; gaps.insert("hang_durations_unknown")
                        }
                    }
                case "log.policy":
                    historyEnabled = payload["enabled"] as? Bool != false
                    analyticsEnabled = historyEnabled && payload["analytics_enabled"] as? Bool != false
                    if !analyticsEnabled { active = nil; locked = nil; asleep = nil; gaps.insert("analytics_disabled_span") }
                    if payload["enabled"] as? Bool == false { replayIncomplete = true; loadKnown = false; selectedWorkspace = nil; open.removeAll(); working.removeAll(); censored += births.count; births.removeAll() }
                case "log.retention":
                    if inRange && payload["state"] as? String == "degraded" { gaps.insert("retention_reconciliation_degraded") }
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
        return ["schema_version": 1, "instances": events.keys.sorted(), "start": starts.min().map(iso.string) as Any? ?? null,
                "end": ends.max().map(iso.string) as Any? ?? null, "span_hours": starts.min().flatMap { s in ends.max().map { $0.timeIntervalSince(s) / 3600 } } as Any? ?? null,
                "panels_created": starts.isEmpty ? null : created as Any,
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
