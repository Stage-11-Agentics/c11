import Darwin
import Foundation

/// C11H-332: c11's audit log. One JSON line for every cross-machine action
/// (link, update, unlink, a terminal started on another machine, a relayed
/// call, a file dropped onto a terminal there) and every check c11 makes on hc's trust (a verified or refused hc
/// binary or serving core, a folder made private or refused). It lives in
/// c11's own runtime, `~/Library/Application Support/c11/audit/` (folder
/// 0700, files 0600), and is read with `c11 machine audit`.
///
/// Two pairs of files, each rotating on its own at 2 MiB into its `.1`
/// file: relayed calls (`relay`) go to `relay.jsonl`, every other kind (the
/// trust records: link, update, unlink, remote_launch, file_transfer, hc_*, dir_*) to
/// `audit.jsonl`. Relay chatter can never rotate a trust record out. `read`
/// merges all four files in time order.
///
/// It records who, what, where and the outcome as codes and checked
/// identifiers: never a command line, a prompt, terminal text, a relayed
/// call's parameters, a rejected raw input or another program's output.
/// Every string is stripped of control characters and capped, and a record
/// never encodes past `maxRecordBytes`.
///
/// This class is the only writer. The app and the CLI (Add Machine runs in
/// either) append under one stable lock file, `.lock`, shared by both pairs
/// and held across open, check, rotate and append. The via script never
/// writes here: it names a refused dial in `link-ssh.log`, and
/// `ingestLinkLog` turns those lines into records. App paths write on a
/// background queue, never on main and never awaited; the CLI calls
/// `flush()` before it exits.
enum C11AuditKind: String, CaseIterable, Sendable {
    case link
    case update
    case unlink
    case remoteLaunch = "remote_launch"
    case relay
    case hcVerified = "hc_verified"
    case hcHashMismatch = "hc_hash_mismatch"
    case hcServingMismatch = "hc_serving_mismatch"
    case dirRepaired = "dir_repaired"
    case dirRefused = "dir_refused"
    /// C11H-392: a dial refused before it started a Linux core, for want of
    /// linger, a user manager, or a service NOFILE limit of 8192 (on a Mac,
    /// `hc_fd_limit` is the launcher's own raise failing).
    case hcNeedsLinger = "hc_needs_linger"
    case hcNeedsUserManager = "hc_needs_user_manager"
    case hcFdLimit = "hc_fd_limit"
    /// C11H-363: a file drop onto a terminal on another machine, sent,
    /// cancelled, refused or failed. One record per drop.
    case fileTransfer = "file_transfer"
}

struct C11AuditRecord: Codable, Equatable, Sendable {
    var time: String
    var kind: String
    /// Where the action came from: `settings`, `cli`, `socket`, `relay`, `app`, `link`, `pairing`.
    var via: String
    var outcome: String
    var machine: String?
    var host: String?
    var session: String?
    var panel: String?
    var workspace: String?
    var method: String?
    var program: String?
    var path: String?
    var code: String?
    var detail: String?
    /// Folded records: how many actions this line stands for (absent means
    /// one). A refused dial's record counts every such dial since the last
    /// record of its kind, machine, host and session.
    var count: Int?
    /// Folded records: up to five of their request ids.
    var ids: [String]?

    static let fieldLimit = 128
    static let pathLimit = 512
    static let detailLimit = 300

    init(kind: C11AuditKind, via: String, outcome: String, machine: String? = nil, host: String? = nil,
         session: String? = nil, panel: String? = nil, workspace: String? = nil, method: String? = nil,
         program: String? = nil, path: String? = nil, code: String? = nil, detail: String? = nil,
         count: Int? = nil, ids: [String]? = nil, date: Date = Date()) {
        let field = { (value: String?) in Self.clean(value, limit: Self.fieldLimit) }
        self.time = C11AuditLog.timestamp(date)
        self.kind = kind.rawValue
        self.via = field(via) ?? "app"
        self.outcome = field(outcome) ?? "unknown"
        self.machine = field(machine)
        self.host = field(host)
        self.session = field(session)
        self.panel = field(panel)
        self.workspace = field(workspace)
        self.method = field(method)
        self.program = field(program)
        self.path = Self.clean(path, limit: Self.pathLimit)
        self.code = field(code)
        self.detail = Self.clean(detail, limit: Self.detailLimit)
        self.count = count.map { max(1, $0) }
        self.ids = ids.map { Array($0.prefix(5).compactMap { Self.clean($0, limit: 64) }) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Control characters (C0, C1, DEL) removed, then capped. Nil and empty stay nil.
    static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value))
        }))
        let capped = String(kept.prefix(limit))
        return capped.isEmpty ? nil : capped
    }

    /// An identifier read from another machine or from input c11 refused:
    /// kept only when it matches `pattern`, else the word `invalid`.
    static func checked(_ value: String?, _ pattern: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.range(of: pattern, options: .regularExpression) != nil ? value : "invalid"
    }

    static let pathPattern = #"^/[A-Za-z0-9._/ +@-]{0,510}$"#
    static let tokenPattern = #"^[A-Za-z0-9._-]{1,64}$"#
    static let hostPattern = #"^[A-Za-z0-9][A-Za-z0-9._@-]{0,254}$"#
}

final class C11AuditLog: @unchecked Sendable {
    static let fileName = "audit.jsonl"
    static let rotatedName = "audit.1.jsonl"
    static let relayFileName = "relay.jsonl"
    static let relayRotatedName = "relay.1.jsonl"
    static let lockName = ".lock"
    static let cursorName = ".link-ingest"
    static let defaultMaxBytes = 2 * 1024 * 1024
    static let maxRecordBytes = 2048

    static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/c11/audit", isDirectory: true)
    }

    static let shared = C11AuditLog(directory: sharedDirectory())

    /// A test process never writes the real log: under XCTest the shared log
    /// lives in a scratch folder of its own.
    static func sharedDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                underTest: Bool = NSClassFromString("XCTestCase") != nil) -> URL {
        if underTest || environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("c11-audit-test-\(getpid())", isDirectory: true)
        }
        return defaultDirectory()
    }

    let directory: URL
    let maxBytes: Int
    private let queue = DispatchQueue(label: "com.stage11.c11.audit", qos: .utility)

    init(directory: URL, maxBytes: Int = C11AuditLog.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// Tests only: called inside every append right after the current file
    /// is opened, before its size is checked, with the lock held.
    var afterOpenForTesting: (@Sendable () -> Void)?

    /// The trust records: every kind but `relay`.
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var rotatedURL: URL { directory.appendingPathComponent(Self.rotatedName) }
    /// Relayed calls only.
    var relayFileURL: URL { directory.appendingPathComponent(Self.relayFileName) }
    var relayRotatedURL: URL { directory.appendingPathComponent(Self.relayRotatedName) }
    var lockURL: URL { directory.appendingPathComponent(Self.lockName) }

    /// `link-ssh.log`, which the via script writes beside this folder.
    var linkLogURL: URL { directory.deletingLastPathComponent().appendingPathComponent("link-ssh.log") }

    /// Local time with its offset, the same form the via script writes.
    static func timestamp(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ text: String) -> Date? { formatter.date(from: text) }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    /// Fire and forget: the line is written on the audit queue.
    func record(_ record: C11AuditRecord) {
        queue.async { [self] in _ = append(record) }
    }

    /// Fire and forget, for the app's link monitor: the via's refused dials,
    /// read only when `link-ssh.log`'s size or modification time changed.
    func ingestLinkLogSoon() {
        queue.async { [self] in
            var info = stat()
            guard lstat(linkLogURL.path, &info) == 0 else { return }
            let stamp = "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
            guard stamp != lastLinkLogStamp else { return }
            lastLinkLogStamp = stamp
            _ = ingestLinkLog()
        }
    }

    /// Touched only on `queue`.
    private var lastLinkLogStamp: String?

    /// Waits for every line recorded so far to reach the file.
    func flush() {
        queue.sync {}
    }

    /// Writes one line now, on the caller's thread. Returns false when the
    /// folder or file is not c11's own private one, or the write failed.
    @discardableResult
    func append(_ record: C11AuditRecord) -> Bool {
        withLock(LOCK_EX) { appendLocked([record]) } ?? false
    }

    /// Runs `body` holding the stable lock file. Nil when the folder or the
    /// lock is not c11's own.
    private func withLock<T>(_ operation: Int32, _ body: () -> T) -> T? {
        guard ensureDirectory() else { return nil }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(fd, operation) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// Appends under the lock the caller holds: relayed calls to the relay
    /// pair, everything else to the trust pair.
    private func appendLocked(_ records: [C11AuditRecord]) -> Bool {
        var trust = Data()
        var relay = Data()
        for record in records {
            guard let line = Self.encode(record) else { continue }
            if record.kind == C11AuditKind.relay.rawValue {
                relay.append(line)
                relay.append(0x0A)
            } else {
                trust.append(line)
                trust.append(0x0A)
            }
        }
        var ok = true
        if !trust.isEmpty { ok = appendLocked(trust, current: fileURL, rotated: rotatedURL) && ok }
        if !relay.isEmpty { ok = appendLocked(relay, current: relayFileURL, rotated: relayRotatedURL) && ok }
        return ok
    }

    /// Appends `payload` to one pair under the lock the caller holds; rotates
    /// `current` into `rotated` first when the lines would pass `maxBytes`.
    /// Every writer holds the same lock, so no writer ever rotates a file
    /// another has just opened.
    private func appendLocked(_ payload: Data, current: URL, rotated: URL) -> Bool {
        func openCurrent() -> Int32 {
            let fd = open(current.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return -1 }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                close(fd)
                return -1
            }
            if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
            return fd
        }
        var fd = openCurrent()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        afterOpenForTesting?()
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        if Int(info.st_size) + payload.count > maxBytes, info.st_size > 0 {
            guard rename(current.path, rotated.path) == 0 else { return false }
            close(fd)
            fd = openCurrent()
            guard fd >= 0 else { return false }
        }
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == payload.count
    }

    /// One record's line, never longer than `maxRecordBytes`: the free text
    /// goes first, then the path, then the ids.
    static func encode(_ record: C11AuditRecord) -> Data? {
        var record = record
        for step in 0..<4 {
            if let data = try? encoder.encode(record), data.count <= maxRecordBytes { return data }
            switch step {
            case 0: record.detail = nil
            case 1: record.path = nil
            case 2: record.ids = nil
            default: return nil
            }
        }
        return nil
    }

    private func ensureDirectory() -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { return false }
            // The 0700 attribute covers the intermediate folders too, and a
            // umask can only clear bits; never change the process umask here,
            // which every other thread's new files would take (C11H-402).
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700]) }
            catch { return false }
            guard lstat(directory.path, &info) == 0 else { return false }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 {
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return fchmod(fd, 0o700) == 0
        }
        return true
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: The via's refused dials

    /// What a `link-ssh.log` reason becomes in the audit.
    static func kind(forLinkReason reason: String) -> C11AuditKind? {
        switch reason {
        case "hc_hash_mismatch": return .hcHashMismatch
        case "hc_serving_mismatch": return .hcServingMismatch
        case "hc_dir_refused": return .dirRefused
        case "hc_needs_linger": return .hcNeedsLinger
        case "hc_needs_user_manager": return .hcNeedsUserManager
        case "hc_fd_limit": return .hcFdLimit
        default: return nil
        }
    }

    static let linkRepeatWindow: TimeInterval = 600

    /// Turns the via script's refused-dial lines in `link-ssh.log` into audit
    /// records, once each: at most one record per kind, machine, host and
    /// session every ten minutes. A dial inside that window is never lost:
    /// one read in the same pass folds into that pass's record, and one read
    /// in a later pass is carried in the cursor until the key's next record,
    /// so a record's `count` is every refused dial since the key's previous
    /// record. The last line taken and the carried counts are kept in
    /// `.link-ingest` under the lock. Returns how many records it wrote.
    @discardableResult
    func ingestLinkLog(_ url: URL? = nil, now: Date = Date()) -> Int {
        let source = url ?? linkLogURL
        return withLock(LOCK_EX) { ingestLocked(source, now: now) } ?? 0
    }

    private struct Cursor: Codable {
        var last: String?
        var lastTime: String?
        /// "kind|machine|host|session" → when its last record was written (epoch seconds).
        var recent: [String: Double] = [:]
        /// "kind|machine|host|session" → refused dials inside the window of
        /// its last record that no record counts yet; the next one does.
        var suppressed: [String: Int] = [:]

        init() {}

        /// A cursor from an older build has no `suppressed`. Counts are kept
        /// positive and bounded, so adding to one never overflows.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            last = try container.decodeIfPresent(String.self, forKey: .last)
            lastTime = try container.decodeIfPresent(String.self, forKey: .lastTime)
            recent = try container.decodeIfPresent([String: Double].self, forKey: .recent) ?? [:]
            suppressed = (try container.decodeIfPresent([String: Int].self, forKey: .suppressed) ?? [:])
                .compactMapValues { $0 > 0 ? min($0, 1 << 40) : nil }
        }
    }

    /// One record of a pass, before it is written.
    private struct LinkDraft {
        var kind: C11AuditKind
        var reason: String
        var machine: String?
        var host: String?
        var session: String?
        var when: Date
        var count: Int
    }

    private func ingestLocked(_ source: URL, now: Date) -> Int {
        let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return 0 }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data.suffix(256 * 1024), encoding: .utf8) else { return 0 }
        let cursorURL = directory.appendingPathComponent(Self.cursorName)
        var cursor = Self.readPrivate(cursorURL).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } ?? Cursor()
        let lines = text.split(separator: "\n").map(String.init)
        let fresh: [String]
        if let last = cursor.last, let index = lines.lastIndex(of: last) {
            fresh = Array(lines[(index + 1)...])
        } else if let lastTime = cursor.lastTime.flatMap(Self.date) {
            fresh = lines.filter { Self.fields($0)["time"].flatMap(Self.date).map { $0 > lastTime } ?? false }
        } else {
            fresh = lines
        }
        guard !fresh.isEmpty else { return 0 }
        var drafts: [LinkDraft] = []
        // key → index in `drafts` of this pass's newest record for the key.
        var openDraft: [String: Int] = [:]
        for line in fresh {
            let values = Self.fields(line)
            guard let reason = values["reason"], let kind = Self.kind(forLinkReason: reason) else { continue }
            let when = values["time"].flatMap(Self.date) ?? now
            let machine = C11AuditRecord.checked(values["machine"], C11AuditRecord.tokenPattern)
            let host = C11AuditRecord.checked(values["host"], C11AuditRecord.hostPattern)
            let session = C11AuditRecord.checked(values["session"], C11AuditRecord.tokenPattern)
            let key = [kind.rawValue, machine ?? "", host ?? "", session ?? ""].joined(separator: "|")
            if let previous = cursor.recent[key], when.timeIntervalSince1970 - previous < Self.linkRepeatWindow {
                // Inside the window of the key's last record: this pass's
                // record counts it, else the cursor carries it to the next.
                if let index = openDraft[key] {
                    drafts[index].count += 1
                } else {
                    cursor.suppressed[key, default: 0] += 1
                }
                continue
            }
            let carried = cursor.suppressed.removeValue(forKey: key) ?? 0
            openDraft[key] = drafts.count
            drafts.append(LinkDraft(kind: kind, reason: reason, machine: machine, host: host, session: session,
                                    when: when, count: 1 + carried))
            cursor.recent[key] = when.timeIntervalSince1970
        }
        let records = drafts.map { draft -> C11AuditRecord in
            var detail: String
            switch draft.kind {
            case .hcHashMismatch: detail = "the far end refused to start an hc that isn't this build's"
            case .hcServingMismatch: detail = "the far end refused a serving hc that isn't this build's"
            case .hcNeedsLinger: detail = "the far end refused to start hc: linger is off for this user, so hc would stop at the last logout"
            case .hcNeedsUserManager: detail = "the far end refused to start hc: no systemd user manager runs for this user"
            case .hcFdLimit: detail = "the far end refused to start hc: its open-file limit is under 8192"
            default: detail = "the far end refused an hc folder that isn't private"
            }
            if draft.count > 1 { detail += "; count is every such refused dial since the last record of this kind for this machine and session" }
            return C11AuditRecord(kind: draft.kind, via: "link", outcome: "refused", machine: draft.machine,
                                  host: draft.host, session: draft.session, code: draft.reason, detail: detail,
                                  count: draft.count > 1 ? draft.count : nil, date: draft.when)
        }
        if !records.isEmpty { _ = appendLocked(records) }
        cursor.last = fresh.last
        cursor.lastTime = fresh.last.flatMap { Self.fields($0)["time"] }
        cursor.recent = cursor.recent.filter { now.timeIntervalSince1970 - $0.value < Self.linkRepeatWindow * 2 }
        if let encoded = try? JSONEncoder().encode(cursor) {
            let tmp = directory.appendingPathComponent(Self.cursorName + ".\(getpid())")
            if FileManager.default.createFile(atPath: tmp.path, contents: encoded, attributes: [.posixPermissions: 0o600]) {
                _ = rename(tmp.path, cursorURL.path)
            }
        }
        return records.count
    }

    private static func readPrivate(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd()
    }

    /// `key=value` words of one `link-ssh.log` line.
    static func fields(_ line: String) -> [String: String] {
        var values: [String: String] = [:]
        for word in line.split(separator: " ") {
            guard let eq = word.firstIndex(of: "=") else { continue }
            values[String(word[..<eq])] = String(word[word.index(after: eq)...])
        }
        return values
    }

    // MARK: Reading

    struct Filter: Equatable, Sendable {
        var machine: String?
        var kind: String?
        var limit: Int?
    }

    /// The newest `limit` records (oldest first), from both pairs of files
    /// read under the shared lock and merged by `time`; records of the same
    /// second keep file order (rotated before current, trust before relay,
    /// then line order). A line that isn't a record is skipped; one whose
    /// time doesn't parse sorts with the record before it in its file.
    /// `machine` also matches a host's part after `@`.
    func read(_ filter: Filter = Filter()) -> [C11AuditRecord] {
        let files = withLock(LOCK_SH) {
            [rotatedURL, relayRotatedURL, fileURL, relayFileURL].map { Self.readPrivate($0) }
        } ?? []
        var stamped: [(date: Date, order: Int, record: C11AuditRecord)] = []
        var dates: [String: Date] = [:]
        var order = 0
        let decoder = JSONDecoder()
        for data in files.compactMap({ $0 }) {
            var previous = Date.distantPast
            for line in data.split(separator: 0x0A) {
                guard let record = try? decoder.decode(C11AuditRecord.self, from: Data(line)) else { continue }
                let date: Date
                if let known = dates[record.time] {
                    date = known
                } else if let parsed = Self.date(record.time) {
                    dates[record.time] = parsed
                    date = parsed
                } else {
                    date = previous
                }
                previous = date
                order += 1
                if let machine = filter.machine, record.machine != machine, record.host != machine,
                   record.host?.split(separator: "@").last.map(String.init) != machine { continue }
                if let kind = filter.kind, record.kind != kind { continue }
                stamped.append((date: date, order: order, record: record))
            }
        }
        stamped.sort { $0.date != $1.date ? $0.date < $1.date : $0.order < $1.order }
        var records = stamped.map { $0.record }
        if let limit = filter.limit, limit >= 0, records.count > limit {
            records.removeFirst(records.count - limit)
        }
        return records
    }

    /// One line per record for a terminal: the local time, kind, where,
    /// outcome and the rest, with control characters removed again.
    static func text(_ record: C11AuditRecord) -> String {
        let clock = record.time.count >= 19
            ? String(record.time[record.time.index(record.time.startIndex, offsetBy: 5)..<record.time.index(record.time.startIndex, offsetBy: 19)])
                .replacingOccurrences(of: "T", with: " ")
            : record.time
        var parts = [clock, record.kind, record.machine ?? record.host ?? "local", record.outcome]
        var extra: [String] = []
        extra.append("via=\(record.via)")
        if let method = record.method { extra.append("method=\(method)") }
        if let panel = record.panel { extra.append("panel=\(panel)") }
        if let program = record.program { extra.append("program=\(program)") }
        if let code = record.code { extra.append("code=\(code)") }
        if let count = record.count { extra.append("count=\(count)") }
        if let path = record.path { extra.append("path=\(path)") }
        if let detail = record.detail { extra.append(detail) }
        parts.append(extra.joined(separator: " "))
        return C11AuditRecord.clean(parts.joined(separator: "  "), limit: 4096) ?? ""
    }
}
