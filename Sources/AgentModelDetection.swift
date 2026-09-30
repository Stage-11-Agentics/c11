import Foundation
import SQLite3

// Live model detection for agent tabs.
//
// For each harness c11 already resumes through `Sources/Conversation/Strategies/`,
// read the model the session is *actually using* from the session or transcript
// file that harness writes, and publish it as the `model_detected` metadata key
// at the `.derived` precedence tier. An explicit or launch-stamped `model` /
// `model_label` (`declare`/`explicit`) still wins in the UI; detection wins over
// nothing.
//
// Contract:
// - Read-only. Nothing is written to any harness's files or config.
// - Incremental. A transcript is opened once, its tail scanned for the latest
//   model, then only bytes appended since the last poll are read. Whole
//   transcripts are never re-read.
// - Off-main. Polls run on the AgentDetector's 10 s sweep via the detector's own
//   utility queue; only a changed value hops to main, for a UI refresh.
// - Only the model id is retained. Transcript content is scanned in memory and
//   dropped; nothing else is stored, logged or published.
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

/// Incremental tail position for one surface's transcript.
struct ModelTailState: Equatable {
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
        guard let ref, !ref.placeholder else { return .none }
        if state.conversationId != ref.id {
            state = ModelTailState(conversationId: ref.id)
        }

        switch kind {
        case "opencode":
            if let model = readOpencodeModel(sessionId: ref.id) { state.model = model }
        case "grok":
            if case .string(let dir)? = ref.payload?[GrokStrategy.sessionDirectoryPayloadKey],
               let model = readGrokModel(sessionDirectory: dir) {
                state.model = model
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

    /// First contact: scan backwards from the end so the newest model wins, and
    /// leave the offset at the end of the last complete line.
    private func initialScan(kind: String, handle: FileHandle, size: UInt64, state: inout ModelTailState) {
        var window = UInt64(Self.initialWindow)
        while true {
            let start = size > window ? size - window : 0
            guard let data = readRange(handle, from: start, to: size) else { return }
            let (lines, consumed) = Self.completeLines(in: data, droppingLeadingPartial: start > 0)
            if let found = lines.reversed().lazy.compactMap({ Self.lineModel(kind: kind, line: $0) }).first {
                state.model = found
                state.offset = start + UInt64(consumed)
                return
            }
            if start == 0 || window >= UInt64(Self.maxInitialWindow) {
                // Nothing yet in the window we are willing to read; continue
                // from the end so future appends are picked up.
                state.offset = start + UInt64(consumed)
                return
            }
            window *= 4
        }
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
        for line in lines {
            if let found = Self.lineModel(kind: kind, line: line) { state.model = found }
        }
        state.offset = start + UInt64(consumed)
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

    /// The model a single transcript line asserts, or nil. Parses JSON only for
    /// lines that could carry a model, and only keeps the id.
    static func lineModel(kind: String, line: Data) -> String? {
        switch kind {
        case "claude-code":
            guard contains(line, "\"assistant\"") else { return nil }
            guard let object = parseObject(line) else { return nil }
            if (object["isSidechain"] as? Bool) == true { return nil }
            guard (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String else { return nil }
            return normalized(model)
        case "codex":
            guard contains(line, "turn_context") || contains(line, "session_meta") else { return nil }
            guard let object = parseObject(line),
                  let payload = object["payload"] as? [String: Any] else { return nil }
            switch object["type"] as? String {
            case "turn_context", "session_meta":
                return normalized(payload["model"] as? String)
            default:
                return nil
            }
        case "pi":
            guard contains(line, "model_change") else { return nil }
            guard let object = parseObject(line), (object["type"] as? String) == "model_change" else { return nil }
            return normalized(object["modelId"] as? String)
        case "omp":
            guard contains(line, "model_change") else { return nil }
            guard let object = parseObject(line), (object["type"] as? String) == "model_change" else { return nil }
            return normalized((object["model"] as? String) ?? (object["modelId"] as? String))
        default:
            return nil
        }
    }

    private static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    private static func parseObject(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
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
        let url = URL(fileURLWithPath: sessionDirectory).appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count < 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.normalized(object["current_model_id"] as? String)
    }

    /// `session.model` is a JSON blob: `{"id":"k3","providerID":"kimi",...}`.
    func readOpencodeModel(sessionId: String) -> String? {
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
        guard sqlite3_prepare_v2(handle, "SELECT model FROM session WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let bound = sessionId.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let raw = String(cString: text)
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return Self.normalized(object["id"] as? String)
        }
        return Self.normalized(raw)   // older opencode stored the bare id
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
                    for target in agents {
                        let ref = refs[target.surfaceId.uuidString]?.active
                        var state = states[target.surfaceId] ?? ModelTailState()
                        let result = probe.detect(kind: target.kind, ref: ref, state: &state)
                        states[target.surfaceId] = state
                        publish(result, target: target)
                    }
                    for surface in plain {
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
