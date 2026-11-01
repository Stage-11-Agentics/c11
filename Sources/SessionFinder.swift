import Foundation

/// On-demand search of Claude Code and Codex transcripts for `c11 conversation find` (C11-518).
///
/// The scan stays in this process. It reads fixture or tenant files and returns rows.
/// It does not open the c11 socket, and it does not log titles, prompts, or the query.
/// Callers that focus or resume send only ids, cwd, and the resume command.
enum SessionFinder {
    static let headByteCap = 64 * 1024
    static let deepReadCap = 1024 * 1024
    static let hugeFileBytes = 8 * 1024 * 1024
    static let titleDisplayCap = 120
    static let matchTextCap = 8192
    static let cwdCap = 4096
    static let historyLineCap = 1024 * 1024
    static let defaultLimit = 30
    static let maxLimit = 200

    struct Query: Equatable {
        var text: String
        var deep: Bool
        var limit: Int
        var sessionID: String?

        init(text: String, deep: Bool, limit: Int = SessionFinder.defaultLimit, sessionID: String? = nil) {
            self.text = text
            self.deep = deep
            self.limit = limit
            self.sessionID = sessionID
        }
    }

    struct Roots: Equatable {
        var claudeProjects: URL
        var claudeHistory: URL
        var codexSessions: URL
        var codexHistory: URL
    }

    struct LiveHit: Equatable {
        var kind: String
        var sessionID: String
        var conversationState: String
        var placeholder: Bool
        var panelID: String
        var panelRef: String
        var workspaceID: String
        var workspaceRef: String
        var cwd: String?
        var capturedAt: Date?
        var panelExists: Bool = true
    }

    enum Harness: String, Equatable {
        case claude
        case codex
    }

    enum State: String, Equatable {
        case live
        case idle
        case gone
    }

    struct Row: Equatable {
        var harness: Harness
        var kind: String
        var sessionID: String
        var state: State
        var panelID: String?
        var panelRef: String?
        var workspaceID: String?
        var workspaceRef: String?
        var cwd: String?
        var lastActive: Date
        var title: String
    }

    struct Skipped: Equatable {
        var corruptLines: Int
        var hugeFiles: Int
        var unreadableFiles: Int

        static let zero = Skipped(corruptLines: 0, hugeFiles: 0, unreadableFiles: 0)
    }

    struct Result: Equatable {
        var query: String
        var deep: Bool
        var truncated: Bool
        var skipped: Skipped
        var rows: [Row]
        var matchCount: Int
    }

    enum Action: Equatable {
        case focus(panelID: String, workspaceID: String)
        case resume(command: String, cwd: String?)
        case refuse
    }

    struct SocketCall: Equatable {
        var method: String
        var params: [String: String]
    }

    enum OpenChoice: Equatable {
        case focus(panelID: String, workspaceID: String)
        case resume(command: String, cwd: String?)
        case none
        case ambiguous(Int)
        case gone(sessionID: String)
        case refuse
    }

    struct Invocation: Equatable {
        var query: Query
        var open: Bool
        var json: Bool
        var callerWorkspace: String?
    }

    enum ParseError: Error, Equatable {
        case extraWord(String)
        case badLimit
        case badSession
        case unknownFlag(String)
    }

    /// QA overrides apply only in a tagged or QA launch, matching `claudeProjectsRoot`.
    static func roots(home: URL, environment: [String: String]) -> Roots {
        let tagged = ["C11_TAG", "CMUX_TAG", "C11_QA_LAUNCH"].contains { key in
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !value.isEmpty
        }
        func override(_ key: String) -> URL? {
            guard tagged else { return nil }
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        let claudeProjects = override("C11_QA_CLAUDE_PROJECTS_ROOT")
            ?? home.appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        let codexSessions = override("C11_QA_CODEX_SESSIONS_ROOT")
            ?? home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        return Roots(
            claudeProjects: claudeProjects,
            claudeHistory: claudeProjects.deletingLastPathComponent().appendingPathComponent("history.jsonl"),
            codexSessions: codexSessions,
            codexHistory: codexSessions.deletingLastPathComponent().appendingPathComponent("history.jsonl")
        )
    }

    static func parseArguments(_ args: [String]) -> Swift.Result<Invocation, ParseError> {
        var text: String?
        var deep = false
        var open = false
        var json = false
        var limit = defaultLimit
        var sessionID: String?
        var callerWorkspace: String?
        var index = 0
        var endOfOptions = false
        func takeValue(_ name: String) -> Swift.Result<String, ParseError> {
            guard index + 1 < args.count else { return .failure(name == "--limit" ? .badLimit : .badSession) }
            index += 1
            return .success(args[index])
        }
        while index < args.count {
            let arg = args[index]
            if !endOfOptions, arg == "--" {
                endOfOptions = true
                index += 1
                continue
            }
            if !endOfOptions, arg == "--json" {
                json = true
                index += 1
                continue
            }
            if !endOfOptions, arg == "-a" {
                deep = true
                index += 1
                continue
            }
            if !endOfOptions, arg == "--open" {
                open = true
                index += 1
                continue
            }
            if !endOfOptions, arg == "--limit" || arg.hasPrefix("--limit=") {
                let raw: String
                if arg.hasPrefix("--limit=") {
                    raw = String(arg.dropFirst("--limit=".count))
                } else {
                    switch takeValue("--limit") {
                    case .success(let value): raw = value
                    case .failure(let error): return .failure(error)
                    }
                }
                guard let parsed = Int(raw), parsed >= 1, parsed <= maxLimit else { return .failure(.badLimit) }
                limit = parsed
                index += 1
                continue
            }
            if !endOfOptions, arg == "--session" || arg.hasPrefix("--session=") {
                let raw: String
                if arg.hasPrefix("--session=") {
                    raw = String(arg.dropFirst("--session=".count))
                } else {
                    switch takeValue("--session") {
                    case .success(let value): raw = value
                    case .failure(let error): return .failure(error == .badLimit ? .badSession : error)
                    }
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isSessionUUID(trimmed) else { return .failure(.badSession) }
                sessionID = trimmed
                index += 1
                continue
            }
            if !endOfOptions, arg == "--workspace" || arg.hasPrefix("--workspace=") {
                let raw: String
                if arg.hasPrefix("--workspace=") {
                    raw = String(arg.dropFirst("--workspace=".count))
                } else {
                    guard index + 1 < args.count else { return .failure(.unknownFlag(arg)) }
                    index += 1
                    raw = args[index]
                }
                callerWorkspace = raw
                index += 1
                continue
            }
            if !endOfOptions, arg.hasPrefix("-") {
                return .failure(.unknownFlag(arg))
            }
            if text != nil {
                return .failure(.extraWord(arg))
            }
            text = arg
            index += 1
        }
        return .success(Invocation(
            query: Query(text: text ?? "", deep: deep, limit: limit, sessionID: sessionID),
            open: open,
            json: json,
            callerWorkspace: callerWorkspace
        ))
    }

    static func search(
        query: Query,
        roots: Roots,
        liveHits: [LiveHit] = [],
        now: Date = Date()
    ) -> Result {
        var skipped = Skipped.zero
        let files = indexFiles(roots: roots, skipped: &skipped)
        let history = scanHistories(
            files: files,
            roots: roots,
            query: query.text,
            skipped: &skipped
        )
        var drafts: [Draft] = []
        for file in files.values {
            var draft = history.files[file.key] ?? Draft(sessionID: file.sessionID, kind: file.kind)
            draft.sessionID = file.sessionID
            draft.kind = file.kind
            draft.hasFile = true
            draft.mtime = file.mtime
            readFile(file, query: query, draft: &draft, skipped: &skipped)
            drafts.append(draft)
        }
        for (key, draft) in history.gone where files[key] == nil {
            drafts.append(draft)
        }

        let live = indexLive(liveHits)
        var rows: [Row] = []
        var seen = Set<String>()
        for draft in drafts {
            let key = liveKey(kind: draft.kind, sessionID: draft.sessionID)
            guard seen.insert(key).inserted else { continue }
            guard include(draft, query: query.text) else { continue }
            if let wanted = query.sessionID, wanted.lowercased() != draft.sessionID.lowercased() {
                continue
            }
            rows.append(makeRow(draft, live: live[key], now: now))
        }
        for hit in live.values {
            let key = liveKey(kind: hit.kind, sessionID: hit.sessionID)
            guard !seen.contains(key) else { continue }
            guard let wanted = query.sessionID, wanted.lowercased() == hit.sessionID.lowercased() else { continue }
            if !query.text.isEmpty {
                let cwdMatch = hit.cwd?.range(of: query.text, options: .caseInsensitive) != nil
                let idMatch = hit.sessionID.range(of: query.text, options: .caseInsensitive) != nil
                guard cwdMatch || idMatch else { continue }
            }
            seen.insert(key)
            let harness: Harness = hit.kind == "codex" ? .codex : .claude
            rows.append(Row(
                harness: harness,
                kind: hit.kind,
                sessionID: hit.sessionID,
                state: .live,
                panelID: hit.panelID,
                panelRef: hit.panelRef.isEmpty ? hit.panelID : hit.panelRef,
                workspaceID: hit.workspaceID,
                workspaceRef: hit.workspaceRef.isEmpty ? hit.workspaceID : hit.workspaceRef,
                cwd: usableCwd(hit.cwd),
                lastActive: hit.capturedAt ?? now,
                title: ""
            ))
        }

        rows.sort { lhs, rhs in
            if lhs.lastActive != rhs.lastActive { return lhs.lastActive > rhs.lastActive }
            return lhs.sessionID.lowercased() < rhs.sessionID.lowercased()
        }
        let matchCount = rows.count
        let limit = min(max(query.limit, 0), maxLimit)
        return Result(
            query: query.text,
            deep: query.deep,
            truncated: matchCount > limit,
            skipped: skipped,
            rows: Array(rows.prefix(limit)),
            matchCount: matchCount
        )
    }

    /// GUARD live-never-resumes: a live row focuses its panel. Do not build a resume command for it.
    static func action(for row: Row) -> Action {
        switch row.state {
        case .live:
            guard let panelID = row.panelID, !panelID.isEmpty,
                  let workspaceID = row.workspaceID, !workspaceID.isEmpty else {
                return .refuse
            }
            return .focus(panelID: panelID, workspaceID: workspaceID)
        case .idle:
            guard let command = resumeCommand(kind: row.kind, sessionID: row.sessionID, cwd: row.cwd) else {
                return .refuse
            }
            return .resume(command: command, cwd: row.cwd)
        case .gone:
            return .refuse
        }
    }

    /// `--open` decides from the full match count, not the displayed page.
    static func openChoice(_ result: Result) -> OpenChoice {
        if result.matchCount == 0 { return .none }
        if result.matchCount != 1 { return .ambiguous(result.matchCount) }
        guard let row = result.rows.first else { return .ambiguous(result.matchCount) }
        switch action(for: row) {
        case .focus(let panelID, let workspaceID):
            return .focus(panelID: panelID, workspaceID: workspaceID)
        case .resume(let command, let cwd):
            return .resume(command: command, cwd: cwd)
        case .refuse:
            return row.state == .gone ? .gone(sessionID: row.sessionID) : .refuse
        }
    }

    static func resumeCommand(kind: String, sessionID: String, cwd: String?) -> String? {
        guard isSessionUUID(sessionID) else { return nil }
        let quotedID = shellQuote(sessionID)
        let base: String
        switch kind {
        case "claude-code":
            base = "claude --dangerously-skip-permissions --resume \(quotedID)"
        case "codex":
            base = "codex resume --yolo \(quotedID)"
        default:
            return nil
        }
        if let cwd = usableCwd(cwd) {
            return "cd \(shellQuote(cwd)) && \(base)"
        }
        return base
    }

    /// GUARD no-prompt-on-socket: focus params are the panel and its workspace. No title and no query.
    static func focusCall(panelID: String, workspaceID: String) -> SocketCall {
        SocketCall(
            method: "panel.focus",
            params: [
                "panel_id": panelID,
                "workspace_id": workspaceID
            ]
        )
    }

    /// Resume creates a terminal. The caller workspace is where the new panel lands.
    /// `panel.create` is not a workspace selection.
    static func resumeCall(command: String, cwd: String?, callerWorkspaceID: String?) -> SocketCall {
        var params: [String: String] = [
            "type": "terminal",
            "initial_input": command
        ]
        if let cwd = usableCwd(cwd) {
            params["cwd"] = cwd
        }
        if let callerWorkspaceID, !callerWorkspaceID.isEmpty {
            params["workspace_id"] = callerWorkspaceID
        }
        return SocketCall(method: "panel.create", params: params)
    }

    static func paramsContain(_ params: [String: String], needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return params.values.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }

    static func liveKey(kind: String, sessionID: String) -> String {
        "\(kind)|\(sessionID.lowercased())"
    }

    static func isSessionUUID(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == lengths.count else { return false }
        for (part, length) in zip(parts, lengths) {
            guard part.count == length, part.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    static func formatLocalTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }

    static func formatISOTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    static func jsonObject(_ result: Result, timeZone: TimeZone) -> [String: Any] {
        [
            "query": result.query,
            "deep": result.deep,
            "truncated": result.truncated,
            "skipped": [
                "corrupt_lines": result.skipped.corruptLines,
                "huge_files": result.skipped.hugeFiles,
                "unreadable_files": result.skipped.unreadableFiles
            ],
            "results": result.rows.map { jsonRow($0, timeZone: timeZone) }
        ]
    }

    static func jsonRow(_ row: Row, timeZone: TimeZone) -> [String: Any] {
        var item: [String: Any] = [
            "harness": row.harness.rawValue,
            "kind": row.kind,
            "session_id": row.sessionID,
            "state": row.state.rawValue,
            "last_active": formatISOTimestamp(row.lastActive, timeZone: timeZone),
            "title": row.title
        ]
        if row.state == .live {
            if let panelID = row.panelID { item["panel_id"] = panelID }
            if let panelRef = row.panelRef { item["panel_ref"] = panelRef }
            if let workspaceID = row.workspaceID { item["workspace_id"] = workspaceID }
            if let workspaceRef = row.workspaceRef { item["workspace_ref"] = workspaceRef }
        }
        if let cwd = row.cwd { item["cwd"] = cwd }
        return item
    }

    // MARK: - Scan

    private struct FileRec {
        var key: String
        var sessionID: String
        var kind: String
        var url: URL
        var bytes: Int
        var mtime: Date
    }

    private struct Draft {
        var sessionID: String
        var kind: String = "claude-code"
        var hasFile = false
        var matched = false
        var cwd: String?
        var aiTitle: String?
        var userTitle: String?
        var historyTitle: String?
        var mtime: Date?
        var historyDate: Date?
        var transcriptDate: Date?
    }

    private struct HistoryScan {
        var files: [String: Draft]
        var gone: [String: Draft]
    }

    private static func indexFiles(roots: Roots, skipped: inout Skipped) -> [String: FileRec] {
        var files: [String: FileRec] = [:]
        indexClaude(roots.claudeProjects, into: &files, skipped: &skipped)
        indexCodex(roots.codexSessions, into: &files, skipped: &skipped)
        return files
    }

    private static func indexClaude(_ root: URL, into files: inout [String: FileRec], skipped: inout Skipped) {
        let manager = FileManager.default
        guard directoryExists(root) else { return }
        let projects: [URL]
        do {
            projects = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            skipped.unreadableFiles += 1
            return
        }
        for project in projects {
            guard isDirectory(project) else { continue }
            let entries: [URL]
            do {
                entries = try manager.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                skipped.unreadableFiles += 1
                continue
            }
            for url in entries where url.pathExtension == "jsonl" {
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard isSessionUUID(sessionID) else { continue }
                consider(url, sessionID: sessionID, kind: "claude-code", into: &files)
            }
        }
    }

    private static func indexCodex(_ root: URL, into files: inout [String: FileRec], skipped: inout Skipped) {
        guard directoryExists(root) else { return }
        walk(root, depth: 0, skipped: &skipped) { url in
            guard url.pathExtension == "jsonl" else { return }
            guard let sessionID = codexSessionID(fileName: url.lastPathComponent) else { return }
            consider(url, sessionID: sessionID, kind: "codex", into: &files)
        }
    }

    private static func walk(_ url: URL, depth: Int, skipped: inout Skipped, visit: (URL) -> Void) {
        if depth > 8 { return }
        let manager = FileManager.default
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            skipped.unreadableFiles += 1
            return
        }
        for entry in entries {
            if isDirectory(entry) {
                walk(entry, depth: depth + 1, skipped: &skipped, visit: visit)
            } else {
                visit(entry)
            }
        }
    }

    private static func consider(_ url: URL, sessionID: String, kind: String, into files: inout [String: FileRec]) {
        let key = liveKey(kind: kind, sessionID: sessionID)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { return }
        let rec = FileRec(
            key: key,
            sessionID: sessionID,
            kind: kind,
            url: url,
            bytes: values?.fileSize ?? 0,
            mtime: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        )
        if let existing = files[key], existing.mtime > rec.mtime { return }
        files[key] = rec
    }

    private static func scanHistories(
        files: [String: FileRec],
        roots: Roots,
        query: String,
        skipped: inout Skipped
    ) -> HistoryScan {
        var scan = HistoryScan(files: [:], gone: [:])
        scanHistory(
            url: roots.claudeHistory,
            kind: "claude-code",
            files: files,
            query: query,
            skipped: &skipped,
            idKey: "sessionId",
            textKey: "display",
            cwdKey: "project",
            timeKey: "timestamp",
            into: &scan
        )
        scanHistory(
            url: roots.codexHistory,
            kind: "codex",
            files: files,
            query: query,
            skipped: &skipped,
            idKey: "session_id",
            textKey: "text",
            cwdKey: nil,
            timeKey: "ts",
            into: &scan
        )
        return scan
    }

    private static func scanHistory(
        url: URL,
        kind: String,
        files: [String: FileRec],
        query: String,
        skipped: inout Skipped,
        idKey: String,
        textKey: String,
        cwdKey: String?,
        timeKey: String,
        into scan: inout HistoryScan
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let outcome = forEachLine(url: url, maxLineBytes: historyLineCap) { line in
            guard let object = jsonObject(line) else {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped.corruptLines += 1
                }
                return
            }
            guard let sessionID = object[idKey] as? String, isSessionUUID(sessionID) else { return }
            let key = liveKey(kind: kind, sessionID: sessionID)
            let text = object[textKey] as? String
            let project = cwdKey.flatMap { object[$0] as? String }
            var matched = false
            if !query.isEmpty {
                if let text, text.range(of: query, options: .caseInsensitive) != nil { matched = true }
                if let project, project.range(of: query, options: .caseInsensitive) != nil { matched = true }
            }
            let isFile = files[key] != nil
            if !isFile && (query.isEmpty || !matched) { return }
            var draft = (isFile ? scan.files[key] : scan.gone[key]) ?? Draft(sessionID: sessionID, kind: kind)
            draft.kind = kind
            draft.sessionID = sessionID
            draft.matched = draft.matched || matched
            if draft.historyTitle == nil, let text, !text.isEmpty {
                draft.historyTitle = String(text.prefix(matchTextCap))
            }
            if draft.cwd == nil, let project {
                draft.cwd = usableCwd(project)
            }
            if let date = jsonDate(object[timeKey]) {
                draft.historyDate = max(draft.historyDate ?? date, date)
            }
            if isFile {
                scan.files[key] = draft
            } else {
                draft.hasFile = false
                scan.gone[key] = draft
            }
        }
        if outcome.unreadable { skipped.unreadableFiles += 1 }
        skipped.corruptLines += outcome.corruptLines
    }

    private static func readFile(_ file: FileRec, query: Query, draft: inout Draft, skipped: inout Skipped) {
        let huge = file.bytes > hugeFileBytes
        if query.deep && huge {
            skipped.hugeFiles += 1
        }
        // GUARD deep-read-cap: a deep scan never reads past deepReadCap, and never reads the body of a huge file.
        let wantBody = query.deep && !huge && !query.text.isEmpty && !draft.matched
        let cap = wantBody ? deepReadCap : headByteCap
        // GUARD read-only: FileHandle(forReadingFrom:) only. This function does not create or write.
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            skipped.unreadableFiles += 1
            return
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap) else {
            skipped.unreadableFiles += 1
            return
        }
        guard let text = decodeUTF8(data) else {
            skipped.unreadableFiles += 1
            return
        }
        let headData = data.prefix(headByteCap)
        let headText = decodeUTF8(Data(headData)) ?? ""
        let headWasCut = file.bytes > headData.count
        skipped.corruptLines += applyHead(
            headText,
            kind: file.kind,
            query: query.text,
            dropPartial: headWasCut,
            draft: &draft
        )
        if wantBody, text.range(of: query.text, options: .caseInsensitive) != nil {
            draft.matched = true
        }
        if wantBody, data.count > headByteCap {
            let body = text.dropFirst(headText.count)
            let bodyCut = file.bytes > data.count
            skipped.corruptLines += countCorruptLines(String(body), dropPartial: bodyCut)
        }
    }

    private static func applyHead(
        _ text: String,
        kind: String,
        query: String,
        dropPartial: Bool,
        draft: inout Draft
    ) -> Int {
        let lines = linesFrom(text, dropPartial: dropPartial)
        var corrupt = 0
        var sawUser = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if kind == "codex", line.contains("\"instructions\"") {
                if draft.cwd == nil {
                    draft.cwd = usableCwd(parseCwd(line))
                }
                continue
            }
            guard let object = jsonObject(line) else {
                corrupt += 1
                continue
            }
            if let date = jsonDate(object["timestamp"]) {
                draft.transcriptDate = max(draft.transcriptDate ?? date, date)
            }
            let type = object["type"] as? String
            if type == "ai-title", let title = object["aiTitle"] as? String, !title.isEmpty {
                if draft.aiTitle == nil { draft.aiTitle = String(title.prefix(matchTextCap)) }
                noteMatch(title, query: query, draft: &draft)
            }
            if let cwd = object["cwd"] as? String, draft.cwd == nil {
                draft.cwd = usableCwd(cwd)
                noteMatch(cwd, query: query, draft: &draft)
            }
            if kind == "codex", draft.cwd == nil, let payload = object["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String {
                draft.cwd = usableCwd(cwd)
                noteMatch(cwd, query: query, draft: &draft)
            }
            if let user = userText(object, kind: kind) {
                noteMatch(user, query: query, draft: &draft)
                if !sawUser {
                    sawUser = true
                    if draft.userTitle == nil { draft.userTitle = String(user.prefix(matchTextCap)) }
                }
            }
        }
        return corrupt
    }

    private static func userText(_ object: [String: Any], kind: String) -> String? {
        let type = object["type"] as? String
        if kind == "codex" {
            if type == "response_item", let payload = object["payload"] as? [String: Any] {
                let role = payload["role"] as? String
                guard role == nil || role == "user" else { return nil }
                return joinedText(payload["content"])
            }
            if type == "user" || object["role"] as? String == "user" {
                return joinedText(object["content"]) ?? joinedText(object["message"])
            }
            return nil
        }
        guard type == "user" || object["role"] as? String == "user" else { return nil }
        if let direct = joinedText(object["content"]) { return direct }
        if let message = object["message"] as? [String: Any] {
            return joinedText(message["content"])
        }
        return joinedText(object["message"])
    }

    private static func noteMatch(_ text: String, query: String, draft: inout Draft) {
        guard !query.isEmpty else { return }
        if text.range(of: query, options: .caseInsensitive) != nil {
            draft.matched = true
        }
    }

    private static func include(_ draft: Draft, query: String) -> Bool {
        if draft.hasFile {
            return query.isEmpty || draft.matched
        }
        return !query.isEmpty && draft.matched
    }

    private static func makeRow(_ draft: Draft, live: LiveHit?, now: Date) -> Row {
        let harness: Harness = draft.kind == "codex" ? .codex : .claude
        var dates: [Date] = []
        if let mtime = draft.mtime { dates.append(mtime) }
        if let historyDate = draft.historyDate { dates.append(historyDate) }
        if let transcriptDate = draft.transcriptDate { dates.append(transcriptDate) }
        if let captured = live?.capturedAt { dates.append(captured) }
        let lastActive = dates.max() ?? now
        let rawTitle = draft.kind == "codex"
            ? firstNonempty(draft.historyTitle, draft.userTitle)
            : firstNonempty(draft.aiTitle, draft.historyTitle, draft.userTitle)
        let state: State
        if live != nil {
            state = .live
        } else if draft.hasFile {
            state = .idle
        } else {
            state = .gone
        }
        return Row(
            harness: harness,
            kind: draft.kind,
            sessionID: draft.sessionID,
            state: state,
            panelID: live?.panelID,
            panelRef: live.map { $0.panelRef.isEmpty ? $0.panelID : $0.panelRef },
            workspaceID: live?.workspaceID,
            workspaceRef: live.map { $0.workspaceRef.isEmpty ? $0.workspaceID : $0.workspaceRef },
            cwd: usableCwd(draft.cwd ?? live?.cwd),
            lastActive: lastActive,
            title: displayTitle(rawTitle)
        )
    }

    private static func firstNonempty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return ""
    }

    private static func indexLive(_ hits: [LiveHit]) -> [String: LiveHit] {
        var grouped: [String: [LiveHit]] = [:]
        for hit in hits {
            guard hit.panelExists, !hit.placeholder, hit.conversationState != "tombstoned" else { continue }
            guard hit.kind == "claude-code" || hit.kind == "codex" else { continue }
            guard isSessionUUID(hit.sessionID), !hit.panelID.isEmpty, !hit.workspaceID.isEmpty else { continue }
            let key = liveKey(kind: hit.kind, sessionID: hit.sessionID)
            grouped[key, default: []].append(hit)
        }
        var out: [String: LiveHit] = [:]
        for (key, group) in grouped {
            let alive = group.filter { $0.conversationState == "alive" }
            let pool = alive.isEmpty ? group : alive
            out[key] = pool.min { $0.panelID < $1.panelID }
        }
        return out
    }

    private static func displayTitle(_ raw: String) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= titleDisplayCap { return flat }
        return String(flat.prefix(titleDisplayCap))
    }

    private static func usableCwd(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= cwdCap else { return nil }
        return trimmed
    }

    // MARK: - Bytes

    private struct LineOutcome {
        var corruptLines: Int
        var unreadable: Bool
    }

    private static func forEachLine(url: URL, maxLineBytes: Int, _ body: (String) -> Void) -> LineOutcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return LineOutcome(corruptLines: 0, unreadable: true)
        }
        defer { try? handle.close() }
        var pending = Data()
        var corrupt = 0
        var skipping = false
        func emit(_ data: Data) {
            if data.isEmpty { return }
            var line = data
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                corrupt += 1
                return
            }
            body(text)
        }
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 256 * 1024) else { break }
                chunk = read
            } catch {
                return LineOutcome(corruptLines: corrupt, unreadable: true)
            }
            if chunk.isEmpty { break }
            for byte in chunk {
                if skipping {
                    if byte == 0x0A { skipping = false }
                    continue
                }
                if byte == 0x0A {
                    emit(pending)
                    pending.removeAll(keepingCapacity: true)
                    continue
                }
                pending.append(byte)
                if pending.count > maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    skipping = true
                    corrupt += 1
                }
            }
        }
        if !skipping { emit(pending) }
        return LineOutcome(corruptLines: corrupt, unreadable: false)
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func countCorruptLines(_ text: String, dropPartial: Bool) -> Int {
        var corrupt = 0
        for line in linesFrom(text, dropPartial: dropPartial) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if jsonObject(line) == nil { corrupt += 1 }
        }
        return corrupt
    }

    private static func linesFrom(_ text: String, dropPartial: Bool) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if dropPartial, !text.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func decodeUTF8(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var end = data.count
        let floor = max(0, data.count - 3)
        while end > floor {
            end -= 1
            if let text = String(data: data.prefix(end), encoding: .utf8) { return text }
        }
        return nil
    }

    /// Bounded scan for the first `"cwd"` string. Does not retain other header fields.
    static func parseCwd(_ head: String) -> String? {
        let scalars = Array(head.unicodeScalars)
        let key = Array("\"cwd\"".unicodeScalars)
        let count = scalars.count
        var index = 0
        func matches(at pos: Int) -> Bool {
            guard pos + key.count <= count else { return false }
            for offset in 0..<key.count where scalars[pos + offset] != key[offset] { return false }
            return true
        }
        while index < count {
            if scalars[index] == "\"", matches(at: index) {
                var cursor = index + key.count
                while cursor < count, scalars[cursor] == " " || scalars[cursor] == "\t" { cursor += 1 }
                guard cursor < count, scalars[cursor] == ":" else { index += 1; continue }
                cursor += 1
                while cursor < count, scalars[cursor] == " " || scalars[cursor] == "\t" { cursor += 1 }
                guard cursor < count, scalars[cursor] == "\"" else { return nil }
                cursor += 1
                var out = String.UnicodeScalarView()
                while cursor < count {
                    let scalar = scalars[cursor]
                    if scalar == "\\" {
                        guard cursor + 1 < count else { return nil }
                        let escaped = scalars[cursor + 1]
                        switch escaped {
                        case "\"": out.append("\"")
                        case "\\": out.append("\\")
                        case "/": out.append("/")
                        default: out.append(escaped)
                        }
                        cursor += 2
                        continue
                    }
                    if scalar == "\"" {
                        let value = String(out)
                        return value.isEmpty ? nil : value
                    }
                    out.append(scalar)
                    cursor += 1
                }
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func jsonDate(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            if let parsed = parseISO(text) { return parsed }
            if let seconds = Double(text) { return dateFromNumeric(seconds) }
            return nil
        }
        if let number = value as? NSNumber {
            return dateFromNumeric(number.doubleValue)
        }
        return nil
    }

    private static func dateFromNumeric(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private static let isoLock = NSLock()
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return formatter
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter
    }()

    private static func parseISO(_ text: String) -> Date? {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
    }

    private static func joinedText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        if let parts = value as? [Any] {
            var collected: [String] = []
            for part in parts {
                if let text = part as? String {
                    collected.append(text)
                } else if let object = part as? [String: Any], let text = object["text"] as? String {
                    collected.append(text)
                }
            }
            let joined = collected.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        if let object = value as? [String: Any] {
            return joinedText(object["content"]) ?? (object["text"] as? String)
        }
        return nil
    }

    private static func codexSessionID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else { return nil }
        let stem = String(fileName.dropLast(".jsonl".count))
        guard stem.count >= 36 else { return nil }
        let suffix = String(stem.suffix(36))
        guard isSessionUUID(suffix) else { return nil }
        if stem.count > 36 {
            let marker = stem[stem.index(stem.endIndex, offsetBy: -37)]
            guard marker == "-" else { return nil }
        }
        return suffix
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }
}
