import Foundation
import SQLite3

/// File-only analytics. This file belongs to c11-cli, never the app target.
enum ActivityAnalysisCommand {
    static let usage = """
    Usage: c11 usage [--since <ISO-8601|Nd|Nh|Nm>] [--by panel|workspace|model|harness] [--json]
           c11 report [--instance <id>] [--since <ISO-8601|Nd|Nh|Nm>] [--format md|json]

    Reads local transcripts and history without a socket. Unknown is never zero.
    File overrides: --state-root <directory>, --claude-root <directory>,
    --codex-root <directory>, --journal <lifecycle.sqlite3> (repeatable).
    Report defaults to the newest instance; --since without --instance reads all instances.
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
        var state: URL
        var claude: URL
        var codex: URL
        init(_ args: [String], json: Bool) throws {
            let home = FileManager.default.homeDirectoryForCurrentUser
            state = try EventLogLayout.defaultStateURL()
            claude = home.appendingPathComponent(".claude/projects")
            codex = home.appendingPathComponent(".codex/sessions")
            self.json = json
            var i = 0
            let names: Set<String> = ["--since", "--by", "--instance", "--format", "--state-root", "--claude-root", "--codex-root", "--journal"]
            while i < args.count {
                if args[i] == "--json" { self.json = true; i += 1; continue }
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
    /// Stream JSONL in bounded chunks; malformed or unreadable data is a visible coverage gap.
    private static func lines(_ url: URL, gaps: inout Set<String>, _ consume: (Object, Int) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { gaps.insert("unreadable_file"); return }
        defer { try? handle.close() }
        var pending = Data(), line = 0
        func decode(_ data: Data) {
            line += 1
            guard !data.isEmpty else { return }
            guard let row = (try? JSONSerialization.jsonObject(with: data)) as? Object else { gaps.insert("malformed_jsonl"); return }
            consume(row, line)
        }
        do {
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    decode(pending.subdata(in: pending.startIndex..<end)); pending.removeSubrange(...end)
                }
                // Refuse pathological single lines without unbounded memory growth.
                if pending.count > 16 * 1024 * 1024 { gaps.insert("oversize_jsonl_line"); return }
            }
            if !pending.isEmpty { decode(pending) }
        } catch { gaps.insert("unreadable_file") }
    }
    private static func files(_ root: URL, ext: String, gaps: inout Set<String>) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { gaps.insert("missing_\(ext)_root"); return [] }
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else {
            gaps.insert("unreadable_\(ext)_root"); return []
        }
        return iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }.sorted { $0.path < $1.path }
    }
    private struct Link: Hashable {
        let panel: String
        let workspace: String?
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
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT tab_id,session_id,agent_kind,workspace_id FROM journal_events WHERE tab_id IS NOT NULL AND session_id IS NOT NULL", -1, &stmt, nil) == SQLITE_OK else {
                gaps.insert("journal_schema_unavailable"); continue
            }
            defer { sqlite3_finalize(stmt) }
            func column(_ n: Int32) -> String? { sqlite3_column_text(stmt, n).map { String(cString: $0) } }
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                if let panel = column(0), let session = column(1), let kind = column(2) {
                    result[harness(kind) + ":" + session, default: []].insert(Link(panel: panel, workspace: column(3)))
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
    }
    private static func claudeRow(_ d: Object, file: URL, line: Int) -> (String, UsageRow)? {
        let m = object(d["message"])
        let u = object(m["usage"])
        guard d["type"] as? String == "assistant", !u.isEmpty, m["model"] as? String != "<synthetic>" else { return nil }
        let session = text(d["sessionId"]) ?? file.deletingPathExtension().lastPathComponent
        let id = text(m["id"]), request = text(d["requestId"])
        let key: String
        if let id { key = session + ":" + id + ":" + (request ?? "unknown") }
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
        var claude: [String: UsageRow] = [:]
        var missingIdentity = false
        for file in files(options.claude, ext: "jsonl", gaps: &gaps) {
            lines(file, gaps: &gaps) { d, line in
                if d["type"] as? String == "assistant", !object(object(d["message"])["usage"]).isEmpty, text(object(d["message"])["id"]) == nil { missingIdentity = true }
                guard let (key, row) = claudeRow(d, file: file, line: line) else { return }
                let tokens = row.tokens
                // Streaming snapshots repeat identity; retain the most complete usage snapshot.
                if let old = claude[key], number(old.tokens.json["total_tokens"]) > number(tokens.json["total_tokens"]) { return }
                claude[key] = row
            }
        }
        if missingIdentity { gaps.insert("claude_dedup_identity_missing") }
        var rows = Array(claude.values)
        var codex: [String: [(Date?, String, Object, Object)]] = [:]
        for file in files(options.codex, ext: "jsonl", gaps: &gaps) {
            var session = file.deletingPathExtension().lastPathComponent, model = "unknown"
            lines(file, gaps: &gaps) { d, _ in
                let p = object(d["payload"])
                if d["type"] as? String == "session_meta" { session = text(p["id"]) ?? session }
                if d["type"] as? String == "turn_context" { model = text(p["model"]) ?? model }
                if d["type"] as? String == "event_msg", p["type"] as? String == "token_count" {
                    let info = object(p["info"]), total = object(info["total_token_usage"])
                    if !total.isEmpty { codex[session, default: []].append((date(d["timestamp"]), model, total, object(info["last_token_usage"]))) }
                }
            }
        }
        for (session, samples) in codex {
            var previous: Object = [:], seen = Set<String>()
            for (timestamp, model, total, last) in samples.sorted(by: { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }) {
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
                                     tokens: Tokens(input: max(0, input - cached), output: delta["output_tokens"] ?? 0, read: cached, reasoning: delta["reasoning_output_tokens"] ?? 0, calls: 1)))
            }
        }
        var total = Tokens(), unattributed = Tokens(), groups: [String: Tokens] = [:]
        var estimates: [String: Double] = [:], unknownCost = Set<String>()
        let catalog = ModelCostCatalogStore(directory: options.state).catalog()
        let axis = options.value("--by") ?? "model"
        for row in rows {
            if row.timestamp == nil { gaps.insert("usage_timestamp_unknown_included") }
            if let since = options.since, let ts = row.timestamp, ts < since { continue }
            if let until, let ts = row.timestamp, ts > until { continue }
            let candidates = attribution[row.harness + ":" + row.session] ?? []
            let link = candidates.count == 1 ? candidates.first : nil
            if link == nil || (axis == "workspace" && link?.workspace == nil) { unattributed.add(row.tokens); if candidates.count > 1 { gaps.insert("ambiguous_session_attribution") } }
            let key: String
            switch axis { case "panel": key = link?.panel ?? "unattributed"; case "workspace": key = link?.workspace ?? "unattributed"; case "harness": key = row.harness; default: key = row.model }
            total.add(row.tokens); groups[key, default: Tokens()].add(row.tokens)
            if row.tokens.writeUnknown > 0 { gaps.insert("cache_write_ttl_unknown") }
            if let cost = estimate(row, catalog: catalog) { estimates[key, default: 0] += cost } else { unknownCost.insert(key) }
        }
        gaps.insert("transcript_retention_and_unrecorded_usage_unknown")
        let groupRows: [Object] = groups.keys.sorted().map { key in
            var result = groups[key]!.json; result["key"] = key
            result["estimated_api_usd"] = unknownCost.contains(key) ? null : (estimates[key] ?? 0) as Any
            return result
        }
        return ["schema_version": 1, "by": axis, "since": options.since.map(iso.string) as Any? ?? null,
                "totals": total.json, "unattributed": unattributed.json, "groups": groupRows,
                "coverage_gaps": gaps.sorted(), "pricing_basis": "Current catalog standard API list rates, not subscription spend or historical billing; missing rates or TTL make the estimate unknown."]
    }
    private static func estimate(_ row: UsageRow, catalog: [String: ModelCostEntry]) -> Double? {
        guard row.speed == "standard", let price = catalog[row.model], row.tokens.writeUnknown == 0 else { return nil }
        let t = row.tokens
        var cost = Double(t.input) * price.inUSD + Double(t.output) * price.outUSD
        if t.read > 0 { guard let p = price.cacheReadUSD else { return nil }; cost += Double(t.read) * p }
        if t.write5 > 0 { guard let p = price.cacheWriteUSD else { return nil }; cost += Double(t.write5) * p }
        if t.write1 > 0 { guard let p = price.cacheWrite1hUSD else { return nil }; cost += Double(t.write1) * p }
        // The shipped GPT-6 reference lists long-context premiums explicitly.
        // Agent-maintained custom catalogs may have their own pricing policies.
        if row.harness == "codex", row.model.hasPrefix("gpt-6"),
           price.source?.hasPrefix("https://developers.openai.com/") == true,
           t.input + t.read > 272_000 {
            let outputCost = Double(t.output) * price.outUSD
            cost = (cost - outputCost) * 2 + outputCost * 1.5
        }
        return cost / 1_000_000
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
        if instance == nil && options.since == nil {
            instance = (try? EventLogLayout.newestLogURL(state: options.state)).map {
                String($0.lastPathComponent.dropFirst("events-".count).dropLast(".ndjson".count))
            }
        }
        let selected = names.filter {
            let name = $0.lastPathComponent
            guard name.hasPrefix("events-"), name.contains(".ndjson") else { return false }
            if let instance { return name == "events-\(instance).ndjson" || name.hasPrefix("events-\(instance).ndjson.") }
            return true
        }
        var events: [String: [Int64: Event]] = [:]
        var malformedEnvelope = false
        for file in selected {
            lines(file, gaps: &gaps) { row, _ in
                guard let ts = date(row["ts"]), let id = text(row["instance"]), let seq = row["seq"] as? NSNumber,
                      let version = row["v"] as? Int, [1, 2].contains(version), text(row["type"]) != nil else { malformedEnvelope = true; return }
                events[id, default: [:]][seq.int64Value] = Event(raw: row, seq: seq.int64Value, ts: ts, instance: id)
            }
        }
        if malformedEnvelope { gaps.insert("invalid_event_envelope") }
        var replayIncomplete = malformedEnvelope
        var starts: [Date] = [], ends: [Date] = [], created = 0, peakOpen = 0, peakWorking = 0, agentSeconds = 0.0
        var foreground = 0.0, foregroundUnknown = 0.0, hangCount = 0
        var workspaces: [String: Object] = [:], daily: [String: Object] = [:], rhythm: [String: Int] = [:]
        var lifetime: [Double] = [], censored = 0, openAtEnd = 0
        var loadSeconds: [String: Double] = [:], loadHangs: [String: Int] = [:]
        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"; dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let hourFormatter = DateFormatter(); hourFormatter.dateFormat = "HH"; hourFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        func bucket(_ n: Int) -> String { n < 10 ? "0-9" : n < 25 ? "10-24" : n < 50 ? "25-49" : "50+" }
        for id in events.keys.sorted() {
            let ordered = events[id]!.values.sorted { $0.seq < $1.seq }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let start = max(options.since ?? first.ts, first.ts), end = max(start, last.ts)
            guard last.ts >= start else { continue }
            starts.append(start); ends.append(end)
            if first.seq != 1 { gaps.insert("event_history_truncated"); replayIncomplete = true }
            var open = Set<String>(), working = Set<String>(), births: [String: Date] = [:]
            var active: Bool?, locked: Bool?, asleep: Bool?
            var analyticsEnabled = true
            var previous = first.ts, previousSeq = first.seq - 1
            for event in ordered {
                let now = max(previous, event.ts) // seq is authoritative; clamp racing timestamp inversions.
                let duration = max(0, min(end, now).timeIntervalSince(max(start, previous)))
                let sequenceGap = event.seq != previousSeq + 1 || event.type == "log.dropped"
                if sequenceGap {
                    gaps.insert("event_sequence_gap"); replayIncomplete = true
                    active = nil; locked = nil; asleep = nil
                    open.removeAll(); working.removeAll(); censored += births.count; births.removeAll()
                }
                previousSeq = event.seq
                if !sequenceGap && analyticsEnabled {
                    agentSeconds += duration * Double(working.count)
                    loadSeconds[bucket(working.count), default: 0] += duration
                }
                if !analyticsEnabled { foregroundUnknown += duration }
                else if active == false || locked == true || asleep == true { /* known unavailable */ }
                else if active == true && locked == false && asleep == false { foreground += duration }
                else { foregroundUnknown += duration }
                previous = now
                let inRange = event.ts >= start
                let panel = event.panel, payload = event.payload
                if let w = event.workspace {
                    var ws = workspaces[w] ?? ["id": w, "name": null, "topics": [String](), "panels_created": 0]
                    if event.type.hasPrefix("workspace."), let title = text(payload["title"]) { ws["name"] = title }
                    if event.type == "metadata.changed", payload["key"] as? String == "title", let title = text(payload["value"]), ["explicit", "declare"].contains(payload["source"] as? String ?? "") {
                        var topics = ws["topics"] as? [String] ?? []; if !topics.contains(title), topics.count < 12 { topics.append(title) }; ws["topics"] = topics
                    }
                    if event.type == "panel.created", inRange { ws["panels_created"] = (ws["panels_created"] as? Int ?? 0) + 1 }
                    workspaces[w] = ws
                }
                switch event.type {
                case "panel.created":
                    if let panel { open.insert(panel); births[panel] = event.ts }
                    if inRange { created += 1 }
                case "panel.closed":
                    if let panel {
                        open.remove(panel); working.remove(panel)
                        if let born = births.removeValue(forKey: panel), born >= start, inRange { lifetime.append(max(0, event.ts.timeIntervalSince(born))) }
                        else if inRange { censored += 1 }
                    }
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
                    if inRange { hangCount += 1; loadHangs[bucket(working.count), default: 0] += 1 }
                case "log.policy":
                    analyticsEnabled = payload["enabled"] as? Bool != false && payload["analytics_enabled"] as? Bool != false
                    if !analyticsEnabled { active = nil; locked = nil; asleep = nil; gaps.insert("analytics_disabled_span") }
                    if payload["enabled"] as? Bool == false { replayIncomplete = true; open.removeAll(); working.removeAll(); censored += births.count; births.removeAll() }
                case "log.dropped": gaps.insert("event_log_dropped_events")
                default: break
                }
                if inRange {
                    peakOpen = max(peakOpen, open.count); peakWorking = max(peakWorking, working.count)
                    let day = dayFormatter.string(from: event.ts)
                    var d = daily[day] ?? ["date": day, "events": 0, "panels_created": 0, "peak_open": 0, "peak_working": 0]
                    d["events"] = (d["events"] as? Int ?? 0) + 1
                    if event.type == "panel.created" { d["panels_created"] = (d["panels_created"] as? Int ?? 0) + 1 }
                    d["peak_open"] = max(d["peak_open"] as? Int ?? 0, open.count)
                    d["peak_working"] = max(d["peak_working"] as? Int ?? 0, working.count)
                    daily[day] = d; rhythm[hourFormatter.string(from: event.ts), default: 0] += 1
                }
            }
            openAtEnd += open.count; censored += births.count
        }
        if starts.isEmpty { gaps.insert("event_history_unavailable") }
        if foregroundUnknown > 0 { gaps.insert("presence_state_unknown") }
        gaps.insert("restored_panel_births_and_liveness_before_retention_unknown")
        lifetime.sort()
        func percentile(_ p: Double) -> Any { lifetime.isEmpty ? null : lifetime[min(lifetime.count - 1, Int(Double(lifetime.count - 1) * p))] / 60 }
        let buckets: [Object] = ["0-9", "10-24", "25-49", "50+"].map { key in
            let hours = (loadSeconds[key] ?? 0) / 3600
            return ["working_panels": key, "observed_hours": hours, "hangs": loadHangs[key] ?? 0, "hangs_per_hour": hours > 0 ? Double(loadHangs[key] ?? 0) / hours as Any : null]
        }
        var usageOptions = options
        if let start = starts.min() { usageOptions.since = start }
        let tokens = try usageResult(usageOptions, gaps: &gaps, until: ends.max())
        return ["schema_version": 1, "instances": events.keys.sorted(), "start": starts.min().map(iso.string) as Any? ?? null,
                "end": ends.max().map(iso.string) as Any? ?? null, "span_hours": starts.min().flatMap { s in ends.max().map { $0.timeIntervalSince(s) / 3600 } } as Any? ?? null,
                "panels_created": starts.isEmpty ? null : created as Any,
                "observed_peak_open_per_instance": peakOpen, "observed_peak_working_per_instance": peakWorking,
                "peak_open_per_instance": starts.isEmpty || replayIncomplete ? null : peakOpen as Any,
                "peak_working_per_instance": starts.isEmpty || replayIncomplete ? null : peakWorking as Any, "open_at_observed_end": starts.isEmpty || replayIncomplete ? null : openAtEnd as Any,
                "observed_agent_hours": starts.isEmpty ? null : agentSeconds / 3600 as Any,
                "foreground_hours": foregroundUnknown > 0 || starts.isEmpty ? null : foreground / 3600 as Any,
                "observed_foreground_hours": foreground / 3600, "presence_unknown_hours": foregroundUnknown / 3600,
                "closed_lifetimes_minutes": ["count": lifetime.count, "p10": percentile(0.1), "median": percentile(0.5), "p90": percentile(0.9), "censored_panels": censored],
                "workspaces": workspaces.keys.sorted().compactMap { workspaces[$0] }, "daily_utc": daily.keys.sorted().compactMap { daily[$0] },
                "hour_of_day_utc_events": rhythm, "hang_precursors": hangCount, "hang_rate_by_working_load": buckets,
                "host_usage": tokens, "usage_scope": "Host transcripts during the observed span, across all instances; not exclusive instance usage. Unknown transcript timestamps are included separately in coverage.",
                "coverage_gaps": gaps.sorted()]
    }
    private static func usageMarkdown(_ result: Object) -> String {
        var output = "Token usage by \(result["by"] ?? "model")\n\nKey | Fresh input | Cache read | Cache write | Output | API estimate USD\n--- | ---: | ---: | ---: | ---: | ---:\n"
        for row in result["groups"] as? [Object] ?? [] {
            let write = number(row["cache_write_5m_tokens"]) + number(row["cache_write_1h_tokens"]) + number(row["cache_write_unknown_ttl_tokens"])
            output += "\(row["key"] ?? "unknown") | \(row["input_tokens"] ?? 0) | \(row["cache_read_tokens"] ?? 0) | \(write) | \(row["output_tokens"] ?? 0) | \(row["estimated_api_usd"] is NSNull ? "unknown" : String(describing: row["estimated_api_usd"] ?? "unknown"))\n"
        }
        output += "\nUnattributed tokens: \(object(result["unattributed"])["total_tokens"] ?? 0)\n\n\(result["pricing_basis"] ?? "")\nCoverage gaps: \((result["coverage_gaps"] as? [String] ?? []).joined(separator: ", "))"
        return output
    }
    private static func reportMarkdown(_ report: Object) -> String {
        func show(_ key: String) -> String { report[key] is NSNull ? "unknown" : String(describing: report[key] ?? "unknown") }
        var output = "# Local activity report\n\nObserved span: \(show("start")) to \(show("end")) (\(show("span_hours")) h).\n\n"
        for (label, key) in [("Panels created", "panels_created"), ("Peak open per instance", "peak_open_per_instance"), ("Peak working per instance", "peak_working_per_instance"), ("Observed agent hours", "observed_agent_hours"), ("Foreground hours", "foreground_hours"), ("Observed foreground hours", "observed_foreground_hours"), ("Presence unknown hours", "presence_unknown_hours"), ("Hang precursors", "hang_precursors")] { output += "- \(label): \(show(key))\n" }
        output += "\n## Daily activity (UTC)\n\nDate | Events | Created | Peak open | Peak working\n--- | ---: | ---: | ---: | ---:\n"
        for d in report["daily_utc"] as? [Object] ?? [] { output += "\(d["date"] ?? "") | \(d["events"] ?? 0) | \(d["panels_created"] ?? 0) | \(d["peak_open"] ?? 0) | \(d["peak_working"] ?? 0)\n" }
        output += "\n## Workspaces and observed topics\n\n"
        for w in report["workspaces"] as? [Object] ?? [] { output += "- \(w["name"] is NSNull ? "unknown" : String(describing: w["name"] ?? "unknown")) (\(w["id"] ?? "")): \((w["topics"] as? [String] ?? []).joined(separator: ", "))\n" }
        output += "\n## Lifetimes, rhythm and hang rates\n\n```json\n\((try? json(["closed_lifetimes_minutes": report["closed_lifetimes_minutes"] ?? null, "hour_of_day_utc_events": report["hour_of_day_utc_events"] ?? null, "hang_rate_by_working_load": report["hang_rate_by_working_load"] ?? null])) ?? "{}")\n```\n\n## Host token usage\n\n\(report["usage_scope"] ?? "")\n\n\(usageMarkdown(object(report["host_usage"])))\n\nCoverage gaps: \((report["coverage_gaps"] as? [String] ?? []).joined(separator: ", "))\n"
        return output
    }
}
