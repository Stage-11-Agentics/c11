import Foundation

/// The existing Claude Stop summary, with transcript work bounded independently
/// of the duration of the session. Runs in the short-lived CLI hook process.
public enum ClaudeStopTranscript {
    public static let defaultMaxTailBytes = 256 * 1024

    public struct ReadResult {
        public let lastAssistantMessage: String?
        public let bytesRead: Int
        /// C11H-320: the same message at the fleet report's length.
        public var lastAssistantReport: String? = nil
    }

    public static func read(
        path: String,
        maxTailBytes: Int = defaultMaxTailBytes
    ) -> ReadResult? {
        guard maxTailBytes > 0 else { return nil }
        let path = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            return read(fileSize: size, maxTailBytes: maxTailBytes) { offset, length in
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: length) ?? Data()
            }
        } catch {
            return nil
        }
    }

    /// The production file wrapper uses this same seam. The reader receives
    /// exactly one request, bounded by the cap and the observed file size.
    public static func read(
        fileSize: UInt64,
        maxTailBytes: Int = defaultMaxTailBytes,
        read: (UInt64, Int) throws -> Data
    ) -> ReadResult? {
        guard maxTailBytes > 0 else { return nil }
        let length = Int(min(fileSize, UInt64(maxTailBytes)))
        let offset = fileSize - UInt64(length)
        guard let data = try? read(offset, length) else { return nil }
        let bytesRead = data.count
        var completeRecords = data[...]
        if offset > 0 {
            // Discard the partial JSONL record before decoding: the cutoff can
            // be inside a UTF-8 scalar. An oversized final record falls back.
            guard let newline = completeRecords.firstIndex(of: 0x0A) else {
                return ReadResult(lastAssistantMessage: nil, bytesRead: bytesRead)
            }
            completeRecords = completeRecords.suffix(from: completeRecords.index(after: newline))
        }
        guard let content = String(data: completeRecords, encoding: .utf8) else { return nil }
        var lastAssistantMessage: String?
        var lastAssistantReport: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let text = messageText(message), !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
            lastAssistantReport = ClaudeAgentReport.lastMessage(text)
        }
        return ReadResult(lastAssistantMessage: lastAssistantMessage, bytesRead: bytesRead,
                          lastAssistantReport: lastAssistantReport)
    }

    /// C11H-320: the Stop hook's two uses of the turn's final message, the
    /// completion notification's line and the fleet report, from one source:
    /// Claude's own `last_assistant_message` when it sends one, else a
    /// single bounded transcript read. `transcriptReads` is 0 or 1.
    public struct StopText {
        public let notification: String?
        public let report: String?
        public let transcriptReads: Int

        public static func read(hookMessage: String?, transcriptPath: String?,
                                readTranscript: (String) -> ReadResult? = { ClaudeStopTranscript.read(path: $0) }) -> StopText {
            if let hook = ClaudeAgentReport.lastMessage(hookMessage) {
                return StopText(notification: truncate(normalizedSingleLine(hook), maxLength: 120), report: hook,
                                transcriptReads: 0)
            }
            guard let path = transcriptPath, let result = readTranscript(path) else {
                return StopText(notification: nil, report: nil, transcriptReads: transcriptPath == nil ? 0 : 1)
            }
            return StopText(notification: result.lastAssistantMessage, report: result.lastAssistantReport,
                            transcriptReads: 1)
        }
    }

    public static func summary(
        cwd: String?,
        lastAssistantMessage: String?,
        fallbackBody: String?,
        fallbackSubtitle: String?
    ) -> (subtitle: String, body: String)? {
        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()
        if let lastAssistantMessage {
            let subtitle = projectName.map { "Completed in \($0)" } ?? "Completed"
            return (subtitle, truncate(lastAssistantMessage, maxLength: 200))
        }
        let lastMessage = fallbackBody ?? fallbackSubtitle
        guard cwd != nil || lastMessage != nil else { return nil }
        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty { body += " in \(projectName)" }
        if let lastMessage, !lastMessage.isEmpty { body += ". Last: \(lastMessage)" }
        return ("Completed", body)
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func normalizedSingleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }
}

/// C11H-320: what a Claude hook tells c11 about its agent for `c11 fleet`.
/// Pure and shared by the hook (c11-cli) and the app, so both sides apply the
/// same bounds. Nothing here reads a file, a login, or a credential.
public enum ClaudeAgentReport {
    public static let lastMessageMaxLength = 300
    public static let accountMaxLength = 64

    /// The agent's final message as the fleet shows it: one line, whitespace
    /// collapsed, at most 300 characters. Nil for empty text.
    public static func lastMessage(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard line.count > lastMessageMaxLength else { return line }
        return String(line.prefix(lastMessageMaxLength - 1)) + "\u{2026}"
    }

    /// The login a Claude session runs under, from its own environment:
    /// `C11_AGENT_ACCOUNT` when a launcher named it, else the last path
    /// component of `CLAUDE_CONFIG_DIR` (Claude keeps one login per config
    /// directory) without a leading dot. Nil in the default home, whose
    /// account c11 cannot know without reading a login file.
    public static func account(environment: [String: String]) -> (name: String, source: String)? {
        if let named = accountName(environment["C11_AGENT_ACCOUNT"]) {
            return (named, "env")
        }
        guard let dir = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        // `$HOME/.claude` named explicitly is still the default home.
        let home = environment["HOME"] ?? NSHomeDirectory()
        let resolved = ((dir as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
        let defaultHome = ((home as NSString).appendingPathComponent(".claude") as NSString).resolvingSymlinksInPath
        guard resolved != defaultHome else { return nil }
        var base = (dir as NSString).standardizingPath
        base = (base as NSString).lastPathComponent
        while base.hasPrefix(".") { base.removeFirst() }
        return accountName(base).map { ($0, "claude_config_dir") }
    }

    /// The StopFailure facts c11 keeps: Claude's closed `error` code, which
    /// limit a `rate_limit` hit and when it resets (parsed here, as a number),
    /// and the provider's sentence, bounded like a final message.
    public static func stopFailureFields(_ object: [String: Any], now: Date) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let code = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           code.range(of: #"^[a-z][a-z0-9_]{0,39}$"#, options: .regularExpression) != nil {
            fields["failure_code"] = code
        }
        let text = object["last_assistant_message"] as? String
        if let limit = usageLimitKind(text) {
            fields["limit"] = limit
        }
        if let resets = resetsAt(text, now: now) {
            fields["resets_at_ms"] = Int64((resets.timeIntervalSince1970 * 1000).rounded())
        }
        if let line = lastMessage(text) {
            fields["failure_text"] = line
        }
        return fields
    }

    /// C11H-328: the `agent.report` params one Claude hook sends, the same on
    /// this Mac and through the relay from a linked machine. `stopText` is a
    /// Stop's final message, read once by the caller. Nil when the hook
    /// reports nothing: a mid-turn `compact` SessionStart, or another event.
    public static func hookParams(subcommand: String, panelId: String, object: [String: Any],
                                  stopText: String?, environment: [String: String], now: Date) -> [String: Any]? {
        var params: [String: Any]
        switch subcommand {
        case "session-start", "active":
            guard (object["source"] as? String) != "compact" else { return nil }
            params = ["event": "session_start"]
        case "prompt-submit":
            params = ["event": "turn_start"]
        case "stop", "idle":
            params = ["event": "stop", "last_message": stopText as Any? ?? NSNull()]
            let tasks = object["background_tasks"] as? [Any]
            if let tasks { params["background_tasks"] = tasks.count }
            // C11H-320 PR 3: a code, never the text, so a silence after
            // announced work reads as a stall.
            if let announced = announcedWork(message: object["last_assistant_message"] as? String,
                                             backgroundTasks: tasks?.count ?? 0,
                                             sessionCrons: (object["session_crons"] as? [Any])?.count ?? 0) {
                params["announces_work"] = announced
            }
        case "stop-failure":
            params = stopFailureFields(object, now: now)
            params["event"] = "stop_failure"
        default:
            return nil
        }
        params["panel_id"] = panelId
        if let account = account(environment: environment) {
            params["account"] = account.name
            params["account_source"] = account.source
        }
        return params
    }

    /// C11H-320 PR 3: whether a turn ended announcing work of its own, so a
    /// silence after it is a stall. `background_tasks` when the Stop left
    /// background tasks running; `next_step` when the final message's last
    /// line is the agent's own next step (`Let me run the tests.`, `I'll
    /// rebuild now.`, `Now checking:`). Nil when the turn reported (a
    /// `Needs you:` line), asked a question, waits on someone (`I'll wait for
    /// your review.`, `Let me know…`), or scheduled its own wake
    /// (`session_crons`). Only the code leaves the hook, never the text.
    public static func announcedWork(message: String?, backgroundTasks: Int, sessionCrons: Int) -> String? {
        guard sessionCrons == 0 else { return nil }
        let lines = (message ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.contains(where: { reportLine($0) }) { return nil }
        // A turn that hands the next move to someone is not announced work,
        // whatever is still running in the background.
        if let last = lines.last, handsOff(last) { return nil }
        if backgroundTasks > 0 { return "background_tasks" }
        guard let last = lines.last else { return nil }
        return isNextStep(last) ? "next_step" : nil
    }

    /// A last line that hands the next move to someone else: a question, or
    /// a lead followed by a waiting word (`I'll wait for your review.`, `Let
    /// me know…`), or `Waiting for your …`.
    static func handsOff(_ line: String) -> Bool {
        let text = normalized(line)
        guard !text.isEmpty else { return false }
        if text.hasSuffix("?") { return true }
        if ["waiting for you", "waiting on you", "standing by"].contains(where: { text.hasPrefix($0) }) { return true }
        for lead in nextStepLeads where text.hasPrefix(lead) {
            let rest = text.dropFirst(lead.count)
            return waitingWords.contains { rest.hasPrefix($0) }
        }
        return false
    }

    /// `Needs you: …`, the line c11 reads as the turn's report.
    static func reportLine(_ line: String) -> Bool {
        plain(line).lowercased().hasPrefix("needs you:")
    }

    /// The agent's own next step, as a last line: a lead-in from the list
    /// below or a line ending in a colon, not a question and not waiting on
    /// someone else.
    static func isNextStep(_ line: String) -> Bool {
        let text = normalized(line)
        guard !text.isEmpty, !handsOff(line) else { return false }
        if text.hasSuffix(":") { return true }
        return nextStepLeads.contains { text.hasPrefix($0) }
    }

    static let nextStepLeads = [
        "now let me ", "next, let me ", "next let me ", "first, let me ", "let me ",
        "now i'll ", "next, i'll ", "next i'll ", "i'll now ", "i'll ",
        "now i will ", "next, i will ", "i will now ", "i will ",
        "now i'm going to ", "i'm now going to ", "i'm going to ", "i am going to ",
        "next, i'm going to ", "going to ", "moving on to ", "continuing with ", "proceeding to ",
        "now running ", "now checking ", "now building ", "starting on ",
    ]

    /// After a lead, words that hand the next move to someone else.
    static let waitingWords = ["know", "wait", "await", "hold", "pause", "stop", "stand by", "leave", "be "]

    private static func normalized(_ line: String) -> String {
        plain(line).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The line without list, quote or emphasis marks around it.
    private static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "-*>#•".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Printable, no slash or backslash, at most 64 characters.
    public static func accountName(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.count <= accountMaxLength,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0 != "/" && $0 != "\\" })
        else { return nil }
        return value
    }

    /// Which limit a failed turn hit, from Claude's own limit sentence
    /// (2.1.325: `You've hit your 5-hour limit · resets 12:20pm (…)`):
    /// `five_hour`, `weekly`, `monthly_spend`, or `other` for a limit sentence
    /// this build does not name. Nil when the text is not a limit sentence.
    public static func usageLimitKind(_ text: String?) -> String? {
        guard let text else { return nil }
        let lower = text.lowercased()
        guard lower.hasPrefix("you've hit your") || lower.hasPrefix("you\u{2019}ve hit your")
                || lower.hasPrefix("you've reached your") || lower.hasPrefix("you\u{2019}ve reached your")
                || lower.hasPrefix("usage limit reached") else { return nil }
        if lower.contains("spend limit") || lower.contains("shared budget") { return "monthly_spend" }
        if lower.contains("5-hour") || lower.contains("five-hour") || lower.contains("session limit") { return "five_hour" }
        if lower.contains("weekly") || lower.contains("7-day") { return "weekly" }
        return "other"
    }

    /// The reset time in Claude's limit sentence, as an instant: `resets
    /// 12:20pm (America/Los_Angeles)`, `resets 3pm (…)`, `resets Nov 18,
    /// 3pm (…)` or `resets Nov 18 at 3:30pm (…)`; with `defaultZone`, also the
    /// auto-continue banner's zoneless `resets 8:10am` / `automatically at 8:10am`. A time alone is its next
    /// occurrence in that zone (a minute's grace for a just-passed reset); a
    /// date without a year is the nearest one. Nil when absent or unparsable;
    /// an unknown zone is never guessed.
    public static func resetsAt(_ text: String?, now: Date, defaultZone: TimeZone? = nil) -> Date? {
        guard let text else { return nil }
        let zone: TimeZone
        var when: String
        if let match = text.range(of: #"resets\s+([^\n(]+?)\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)*)\)"#,
                                  options: .regularExpression) {
            let clause = String(text[match])
            guard let open = clause.lastIndex(of: "("), let close = clause.lastIndex(of: ")"),
                  let named = TimeZone(identifier: String(clause[clause.index(after: open)..<close])) else { return nil }
            zone = named
            when = String(clause[..<open]).trimmingCharacters(in: .whitespaces)
            when = String(when.dropFirst("resets".count)).trimmingCharacters(in: .whitespaces)
        } else if let defaultZone,
                  let match = text.range(of: #"(?:resets|automatically at)\s+\d{1,2}(?::\d{2})?[ap]m\b"#,
                                         options: [.regularExpression, .caseInsensitive]) {
            // Claude's auto-continue banner prints the time without a zone, in
            // the zone of the machine it runs on.
            zone = defaultZone
            when = String(text[match].split(separator: " ").last ?? "")
        } else {
            return nil
        }
        when = when
            .replacingOccurrences(of: " at ", with: " ")
            .replacingOccurrences(of: ",", with: "")
            // en_US_POSIX parses `PM`, the case Claude does not print.
            .replacingOccurrences(of: "am", with: "AM")
            .replacingOccurrences(of: "pm", with: "PM")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.defaultDate = nil
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: when) {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                return calendar.nextDate(after: now.addingTimeInterval(-60), matching: parts,
                                         matchingPolicy: .nextTime, direction: .forward)
            }
        }
        for format in ["MMM d h:mma", "MMM d ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: when) else { continue }
            let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            let year = calendar.component(.year, from: now)
            let candidates = [year - 1, year, year + 1].compactMap { candidate -> Date? in
                var full = parts
                full.year = candidate
                return calendar.date(from: full)
            }
            return candidates.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) })
        }
        return nil
    }
}
