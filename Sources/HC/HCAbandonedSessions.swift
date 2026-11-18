import Darwin
import Foundation

/// C11H-352: hc sessions whose core will never run again, and what their
/// terminals left running.
///
/// hc ends a lost holder's terminals itself, in the running core and in the
/// next core that starts for that session (C11H-348). A session whose core
/// never runs again (an old dev tag, the c11h to c11 rename, an uninstalled
/// build) keeps whatever its terminals left behind forever. This finds them and,
/// only when an operator or agent asks for one session, ends them.
///
/// Identity comes from hc's own record, `terminals.json` in the session's state
/// folder: each terminal's root pid, `program_started_ms` and `scope` (the
/// `HC_SCOPE` token in its environment), written by every hc build c11 ships, so
/// a session older than any c11 ledger is covered. A process counts only when
///  - it is a recorded root: that pid, our real uid, a kernel start time within
///    `startTolerance` of the recorded one, parented by launchd, and leader of its
///    own session; or
///  - it is in such a root's session; or
///  - the root is gone, no process holds its pid, and the process is in the
///    session that pid named, started after the root, and carries the root's
///    exact `HC_SCOPE` token. One that fails this is `unverified`, never signalled.
///
/// A session is abandoned only when nothing accepts on its core socket, no
/// process of ours holds a socket under its core or holder name, and no
/// recorded root has a parent other than launchd. A process with a child in
/// another session (it launched an app or a core) is never a leftover. This build's sessions and the caller's are never
/// candidates. No process is ever chosen by name or argv; folder names only
/// say where to look. Nothing here starts a core.
enum HCAbandonedSessions {
    static let schema = "c11.core.abandoned/1"
    /// hc stamps `program_started_ms` at spawn, the kernel at fork.
    static let startTolerance: UInt64 = 2_000_000
    /// HUP, then KILL after this.
    static let grace: TimeInterval = 3
    static let maxRecordBytes = 64 << 20
    static let maxSessions = 512

    /// The session names c11 has used: `c11`, `c11-<rest>`, and c11h 1.x's.
    static func isC11SessionName(_ name: String) -> Bool {
        name.range(of: #"^c11h?(-[A-Za-z0-9._-]{1,80})?$"#, options: .regularExpression) != nil
    }

    /// `c11-orch4-s3` -> `c11-orch4`: a build's shards share its base.
    static func family(_ session: String) -> String {
        guard let range = session.range(of: #"-s[1-9][0-9]*$"#, options: .regularExpression) else { return session }
        return String(session[..<range.lowerBound])
    }
}

// MARK: - Kernel seam

struct HCAbandonedProcess: Equatable, Sendable {
    let identity: HCProcessIdentity
    let parentPID: Int32
    /// `getsid`: the pid of the process's session leader.
    let session: Int32
    let realUID: uid_t
}

/// Production reads sysctl, libproc and connect(2), and sends kill(2); tests
/// pass a fake, so no host process is ever signalled.
protocol HCAbandonedHost {
    var uid: uid_t { get }
    /// The pid of the process running the scan or the end.
    var selfPID: Int32 { get }
    func process(_ pid: Int32) -> HCAbandonedProcess?
    /// Every live process of ours, by real uid. Nil when unreadable.
    func processes() -> [HCAbandonedProcess]?
    /// The value of `name` in the process's environment, or nil when absent or unreadable.
    func environmentValue(_ name: String, pid: Int32) -> String?
    /// True when something accepts on the unix socket at `path`, or when that
    /// cannot be told (a path too long for `sun_path`).
    func socketAccepts(_ path: String) -> Bool
    /// The paths of every unix socket a process of ours holds. Nil when unreadable.
    func boundUnixSocketPaths() -> Set<String>?
    func signal(_ pid: Int32, _ signal: Int32)
    func wait(_ seconds: TimeInterval)
}

// MARK: - hc's record of a session

struct HCRecordedTerminal: Equatable, Sendable {
    let address: String
    let pid: Int32
    /// hc's `program_started_ms`, as microseconds.
    let startMicroseconds: UInt64?
    let scope: String?
}

struct HCSessionRecord: Equatable, Sendable {
    let session: String
    /// Sockets a core of this session would accept on.
    let coreSockets: [String]
    /// Terminals hc did not record as finished.
    let terminals: [HCRecordedTerminal]
}

extension HCAbandonedSessions {
    struct Context {
        /// hc's state root, `~/.local/state/herdr-core`.
        let stateRoot: URL
        /// c11's socket folders (`~/.local/share/c11/run`, and c11h's).
        let runDirectories: [URL]
        /// Session families never touched: this build's, and the caller's.
        let protectedFamilies: Set<String>

        /// `ownSessions`: this build's session (and its base, when they differ).
        static func local(home: URL, ownSessions: [String?], environment: [String: String]) -> Context {
            var families = Set<String>()
            for session in ownSessions + [environment["HC_SESSION"], environment["C11_HC_SESSION"]] {
                if let session, !session.isEmpty { families.insert(family(session)) }
            }
            return Context(
                stateRoot: home.appendingPathComponent(".local/state/herdr-core", isDirectory: true),
                runDirectories: [
                    home.appendingPathComponent(".local/share/c11/run", isDirectory: true),
                    home.appendingPathComponent(".local/share/c11h/run", isDirectory: true), // c11-2.0:legacy
                ],
                protectedFamilies: families)
        }

        func isProtected(_ session: String) -> Bool {
            protectedFamilies.contains(session) || protectedFamilies.contains(HCAbandonedSessions.family(session))
        }
    }

    /// The c11 session folders under the state root, sorted.
    static func candidates(_ context: Context) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: context.stateRoot.path)) ?? []
        return names.filter { name in
            guard isC11SessionName(name) else { return false }
            var info = stat()
            let path = context.stateRoot.appendingPathComponent(name).path
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
        }.sorted().prefix(maxSessions).map { $0 }
    }

    enum RecordError: Error, Equatable {
        case notFound
        case unreadable(String)
    }

    /// Reads one session's record. Never follows a symlink, never reads a file
    /// another user owns or can write.
    static func record(_ session: String, _ context: Context) -> Result<HCSessionRecord, RecordError> {
        guard isC11SessionName(session) else { return .failure(.notFound) }
        let directory = context.stateRoot.appendingPathComponent(session, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .failure(.notFound) }
        guard info.st_uid == getuid() else { return .failure(.unreadable("state folder not ours")) }

        var coreSockets: [String] = []
        // Absent is fine. Present, it must read safely (ours, no group or other
        // write, no ACL, no symlink) and name this session's core socket;
        // anything else leaves the session unreadable, never assumed coreless.
        let lock = directory.appendingPathComponent("core.lock")
        if lstat(lock.path, &info) == 0 {
            let data: Data
            do { data = try PrivateFileWriter.readPrivateFile(at: lock, maxBytes: 4096) } catch {
                return .failure(.unreadable("core.lock: \(error)"))
            }
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isCoreEndpoint(text, session: session) else {
                return .failure(.unreadable("core.lock names no core socket of \(session)"))
            }
            coreSockets.append(text)
        } else if errno != ENOENT {
            return .failure(.unreadable("core.lock: \(String(cString: strerror(errno)))"))
        }
        for folder in context.runDirectories.map(\.path) {
            coreSockets.append((folder as NSString).appendingPathComponent("\(session).sock"))
        }

        let file = directory.appendingPathComponent("terminals.json")
        guard lstat(file.path, &info) == 0 else {
            guard errno == ENOENT else { return .failure(.unreadable("terminals.json: \(String(cString: strerror(errno)))")) }
            return .success(HCSessionRecord(session: session, coreSockets: unique(coreSockets), terminals: []))
        }
        let data: Data
        do { data = try PrivateFileWriter.readPrivateFile(at: file, maxBytes: maxRecordBytes) } catch {
            return .failure(.unreadable("terminals.json: \(error)"))
        }
        guard let terminals = parseTerminals(data) else { return .failure(.unreadable("terminals.json is not hc's shape")) }
        return .success(HCSessionRecord(session: session, coreSockets: unique(coreSockets), terminals: terminals))
    }

    /// A core socket of this session: an absolute path whose last part is
    /// `<session>.sock`. Never a holder socket, never anything else.
    static func isCoreEndpoint(_ path: String, session: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n") && !path.contains("\0")
            && (path as NSString).lastPathComponent == "\(session).sock"
    }

    /// A JSON number written with a fraction or exponent.
    static func isFloat(_ number: NSNumber) -> Bool {
        #if os(macOS)
        return CFNumberIsFloatType(number as CFNumber)
        #else
        let type = String(cString: number.objCType)
        return type == "f" || type == "d"
        #endif
    }

    /// hc's `terminals.json`: `{"terminals": {id: item} | [item]}`. Only items
    /// hc did not record as finished, with a usable pid. A start that is not a
    /// whole number of milliseconds or does not fit in microseconds makes the
    /// whole record unreadable (nil): a corrupt record is never acted on.
    static func parseTerminals(_ data: Data) -> [HCRecordedTerminal]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items: [[String: Any]]
        switch object["terminals"] {
        case let map as [String: Any]: items = map.values.compactMap { $0 as? [String: Any] }
        case let list as [Any]: items = list.compactMap { $0 as? [String: Any] }
        case nil, is NSNull: items = []
        default: return nil
        }
        var out: [HCRecordedTerminal] = []
        for item in items {
            guard (item["state"] as? String) != "finished",
                  let pidNumber = item["pid"] as? NSNumber, pidNumber.int64Value > 1, pidNumber.int64Value <= Int64(Int32.max) else { continue }
            var started: UInt64?
            if let raw = item["program_started_ms"], !(raw is NSNull) {
                guard let number = raw as? NSNumber, !Self.isFloat(number) else { return nil }
                if number.int64Value > 0 {
                    let product = UInt64(number.int64Value).multipliedReportingOverflow(by: 1000)
                    guard !product.overflow else { return nil }
                    started = product.partialValue
                }
            }
            let scope = (item["scope"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(HCRecordedTerminal(address: item["address"] as? String ?? "?", pid: Int32(pidNumber.int64Value),
                                          startMicroseconds: started, scope: scope))
        }
        return out.sorted { $0.pid < $1.pid }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

// MARK: - Verdict

struct HCAbandonedLeftover: Equatable, Sendable {
    enum Basis: String, Sendable {
        /// The recorded root itself.
        case root
        /// In the recorded root's session, while that root lives.
        case session
        /// Root gone; in its session and carrying its `HC_SCOPE` token.
        case scope
    }
    let terminal: String
    let identity: HCProcessIdentity
    let basis: Basis
}

struct HCAbandonedSession: Equatable, Sendable {
    let session: String
    /// Terminals hc did not record as finished.
    let terminalsRecorded: Int
    /// Those with at least one process left.
    let terminalsLeft: Int
    let leftovers: [HCAbandonedLeftover]
    /// Processes in a recorded session that failed the identity checks: listed, never signalled.
    let unverified: Int
}

enum HCAbandonedVerdict: Error, Equatable, Sendable {
    case abandoned(HCAbandonedSession)
    /// This build's session or one of its shards, or the caller's.
    case current
    case coreRunning
    case holderAlive
    /// Nothing of its terminals is left.
    case clean
    /// Processes in its terminals' sessions that no check proves are theirs.
    case unverifiedOnly(Int)
    case notFound
    case unreadable(String)

    var code: String {
        switch self {
        case .abandoned: return "abandoned"
        case .current: return "current"
        case .coreRunning: return "core_running"
        case .holderAlive: return "holder_alive"
        case .clean: return "clean"
        case .unverifiedOnly: return "unverified_only"
        case .notFound: return "not_found"
        case .unreadable: return "unreadable"
        }
    }
}

extension HCAbandonedSessions {
    struct Scan: Equatable {
        let sessions: [HCAbandonedSession]
        /// Candidates passed over, with why (never `clean` ones).
        let skipped: [(session: String, verdict: HCAbandonedVerdict)]

        var processCount: Int { sessions.reduce(0) { $0 + $1.leftovers.count } }
        /// Candidates that could not be read: a zero elsewhere is then not a proven zero.
        var unreadableCount: Int { skipped.filter { if case .unreadable = $0.verdict { return true } else { return false } }.count }

        static func == (lhs: Scan, rhs: Scan) -> Bool {
            lhs.sessions == rhs.sessions && lhs.skipped.map(\.session) == rhs.skipped.map(\.session)
                && lhs.skipped.map(\.verdict) == rhs.skipped.map(\.verdict)
        }
    }

    /// Our processes' open unix sockets, read at most once per scan: the read
    /// walks every descriptor of every process of ours.
    final class Sockets {
        private let host: HCAbandonedHost
        private var read = false
        private var paths: Set<String>?
        init(_ host: HCAbandonedHost) { self.host = host }
        var bound: Set<String>? {
            if !read { paths = host.boundUnixSocketPaths(); read = true }
            return paths
        }
    }

    static func scan(_ context: Context, host: HCAbandonedHost) -> Scan {
        let table = host.processes()
        let sockets = Sockets(host)
        var sessions: [HCAbandonedSession] = []
        var skipped: [(session: String, verdict: HCAbandonedVerdict)] = []
        for name in candidates(context) {
            let verdict = evaluate(name, context, host: host, table: table, sockets: sockets)
            switch verdict {
            case .abandoned(let session): sessions.append(session)
            case .clean, .notFound: break
            default: skipped.append((session: name, verdict: verdict))
            }
        }
        return Scan(sessions: sessions, skipped: skipped)
    }

    /// One session's verdict, read fresh.
    static func evaluate(_ session: String, _ context: Context, host: HCAbandonedHost) -> HCAbandonedVerdict {
        evaluate(session, context, host: host, table: host.processes(), sockets: Sockets(host))
    }

    static func evaluate(_ session: String, _ context: Context, host: HCAbandonedHost,
                         table: [HCAbandonedProcess]?, sockets: Sockets) -> HCAbandonedVerdict {
        if context.isProtected(session) { return .current }
        let record: HCSessionRecord
        switch self.record(session, context) {
        case .success(let value): record = value
        case .failure(.notFound): return .notFound
        case .failure(.unreadable(let why)): return .unreadable(why)
        }
        return verdict(record, host: host, table: table, sockets: sockets)
    }

    /// The pure part: a read record against the kernel.
    static func verdict(_ record: HCSessionRecord, host: HCAbandonedHost, table: [HCAbandonedProcess]?,
                        sockets: Sockets) -> HCAbandonedVerdict {
        if record.coreSockets.filter({ isCoreEndpoint($0, session: record.session) }).contains(where: host.socketAccepts) {
            return .coreRunning
        }
        guard !record.terminals.isEmpty else { return .clean }
        guard let table else { return .unreadable("process table") }

        // A socket a process of ours holds under this session's core or holder
        // name, wherever it is bound and whether or not its file still exists.
        guard let bound = sockets.bound else { return .unreadable("socket table") }
        let names = bound.map { ($0 as NSString).lastPathComponent }
        if names.contains("\(record.session).sock") { return .coreRunning }
        if names.contains(where: { $0.hasPrefix("\(record.session).holder.") && $0.hasSuffix(".sock") }) { return .holderAlive }

        let protected = protectedProcesses(host)
        // A process with a child in another session launched something that
        // lives on its own (an app, a core): never counted as a leftover.
        let sessionOf = Dictionary(table.map { ($0.identity.pid, $0.session) }, uniquingKeysWith: { first, _ in first })
        var launchers = Set<Int32>()
        for process in table where process.parentPID > 1 {
            if let parentSession = sessionOf[process.parentPID], parentSession != process.session {
                launchers.insert(process.parentPID)
            }
        }
        var leftovers: [HCAbandonedLeftover] = []
        var unverified = 0
        var terminalsLeft = 0
        var seen = Set<Int32>()

        // First pass: a root a holder still parents means the session is held.
        for terminal in record.terminals {
            guard let root = host.process(terminal.pid), matches(root, terminal, uid: host.uid) else { continue }
            if root.parentPID != 1 { return .holderAlive }
        }

        for terminal in record.terminals {
            var found: [HCAbandonedLeftover] = []
            if let root = host.process(terminal.pid) {
                guard terminal.startMicroseconds != nil else {
                    // hc recorded no start, so this pid cannot be told apart from a reused one.
                    unverified += 1
                    continue
                }
                // The pid names another process now: that pid's session is not this one.
                guard matches(root, terminal, uid: host.uid) else { continue }
                guard root.session == root.identity.pid else {
                    // Not the shape of a held terminal's root. Never signalled.
                    unverified += 1
                    continue
                }
                for member in table where member.session == root.identity.pid && member.realUID == host.uid {
                    guard !protected.pids.contains(member.identity.pid), member.session != protected.session else { continue }
                    guard !launchers.contains(member.identity.pid) else {
                        unverified += 1
                        continue
                    }
                    let basis: HCAbandonedLeftover.Basis = member.identity.pid == root.identity.pid ? .root : .session
                    found.append(HCAbandonedLeftover(terminal: terminal.address, identity: member.identity, basis: basis))
                }
                if !found.contains(where: { $0.basis == .root }), !protected.pids.contains(root.identity.pid),
                   root.session != protected.session, !launchers.contains(root.identity.pid) {
                    // The table was read before the root: keep the root itself.
                    found.append(HCAbandonedLeftover(terminal: terminal.address, identity: root.identity, basis: .root))
                }
            } else {
                // The root has ended and no process holds its pid, so the
                // session that pid named can only be this terminal's or one a
                // later process of that pid created. The scope token tells them apart.
                for member in table where member.session == terminal.pid && member.realUID == host.uid {
                    guard !protected.pids.contains(member.identity.pid), member.session != protected.session else { continue }
                    // No HC_SCOPE at all: not an hc terminal's process. Not counted.
                    guard let carried = host.environmentValue("HC_SCOPE", pid: member.identity.pid) else { continue }
                    if let start = terminal.startMicroseconds, let scope = terminal.scope, carried == scope,
                       member.identity.startTimeMicroseconds + startTolerance >= start,
                       !launchers.contains(member.identity.pid),
                       host.process(member.identity.pid)?.identity == member.identity {
                        found.append(HCAbandonedLeftover(terminal: terminal.address, identity: member.identity, basis: .scope))
                    } else {
                        unverified += 1
                    }
                }
            }
            found = found.filter { seen.insert($0.identity.pid).inserted }
            if !found.isEmpty { terminalsLeft += 1 }
            leftovers += found
        }
        guard !leftovers.isEmpty else { return unverified > 0 ? .unverifiedOnly(unverified) : .clean }
        return .abandoned(HCAbandonedSession(
            session: record.session, terminalsRecorded: record.terminals.count, terminalsLeft: terminalsLeft,
            leftovers: leftovers.sorted { $0.identity.pid < $1.identity.pid }, unverified: unverified))
    }

    /// The recorded root itself: same pid, ours, started when hc says it did.
    static func matches(_ process: HCAbandonedProcess, _ terminal: HCRecordedTerminal, uid: uid_t) -> Bool {
        guard let start = terminal.startMicroseconds, process.identity.pid == terminal.pid, process.realUID == uid else { return false }
        let kernel = process.identity.startTimeMicroseconds
        let gap = kernel > start ? kernel - start : start - kernel
        return gap <= startTolerance
    }

    /// The caller, its ancestors and its own session: never signalled.
    static func protectedProcesses(_ host: HCAbandonedHost) -> (pids: Set<Int32>, session: Int32) {
        var pids = Set<Int32>()
        var pid = host.selfPID
        let session = host.process(pid)?.session ?? -1
        while pid > 1, pids.insert(pid).inserted {
            guard let process = host.process(pid) else { break }
            pid = process.parentPID
        }
        return (pids, session)
    }
}

// MARK: - End

extension HCAbandonedSessions {
    struct EndResult: Equatable, Sendable {
        let session: String
        /// Processes sent SIGHUP.
        let hungUp: Int
        /// Processes sent SIGKILL: still eligible after the grace, or forked meanwhile.
        let killed: Int
        /// Still listed after the end; nil when the closing read could not confirm it.
        let remaining: Int?
        let unverified: Int
        let terminals: Int
        /// Set when the session stopped being abandoned during the grace (a
        /// core or holder appeared, or it could not be read): then no SIGKILL.
        let escalationRefused: String?
        /// Set when the closing read could not confirm the result.
        let unconfirmed: String?

        var succeeded: Bool { remaining == 0 && escalationRefused == nil }
    }

    /// Ends one abandoned session's leftovers. Reads the session fresh and
    /// refuses anything not abandoned; sends SIGHUP, then SIGCONT, each only to
    /// a process that is still the same pid and start; after `grace` reads the
    /// session again and sends SIGKILL only to what that read lists (so a
    /// process that left the session, or a session that gained a core or
    /// holder, gets none), each checked again right before. Never starts a core.
    static func end(_ session: String, _ context: Context, host: HCAbandonedHost,
                    grace: TimeInterval = HCAbandonedSessions.grace) -> Result<EndResult, HCAbandonedVerdict> {
        let first: HCAbandonedSession
        switch evaluate(session, context, host: host) {
        case .abandoned(let found): first = found
        case let other: return .failure(other)
        }
        var hungUp = 0
        for leftover in first.leftovers {
            let pid = leftover.identity.pid
            guard host.process(pid)?.identity == leftover.identity else { continue }
            host.signal(pid, SIGHUP)
            hungUp += 1
            // One that ended on the hangup may already have given its pid away.
            guard host.process(pid)?.identity == leftover.identity else { continue }
            host.signal(pid, SIGCONT)
        }
        if hungUp > 0 { host.wait(grace) }

        // Eligibility after the grace is read again, not carried over: this
        // read also finds what the session forked meanwhile.
        var killed = 0
        var refused: String?
        switch evaluate(session, context, host: host) {
        case .abandoned(let now):
            for leftover in now.leftovers {
                let pid = leftover.identity.pid
                guard host.process(pid)?.identity == leftover.identity else { continue }
                host.signal(pid, SIGKILL)
                killed += 1
            }
        case .clean, .unverifiedOnly:
            break
        case let other:
            refused = other.code
        }
        // SIGKILL lands at once, but the kernel takes a moment to reap.
        if killed > 0 { host.wait(0.5) }
        var remaining: Int?
        var unverified = first.unverified
        var unconfirmed: String?
        switch evaluate(session, context, host: host) {
        case .abandoned(let after):
            remaining = after.leftovers.count
            unverified = after.unverified
        case .clean:
            remaining = 0
            unverified = 0
        case .unverifiedOnly(let count):
            remaining = 0
            unverified = count
        case let other:
            unconfirmed = other.code
        }
        return .success(EndResult(session: session, hungUp: hungUp, killed: killed, remaining: remaining,
                                  unverified: unverified, terminals: first.terminalsLeft,
                                  escalationRefused: refused, unconfirmed: unconfirmed))
    }
}

// MARK: - Output

extension HCAbandonedSessions {
    static func rfc3339(microseconds: UInt64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000))
    }

    /// One structured line per session.
    static func line(_ session: HCAbandonedSession) -> String {
        "abandoned session=\(session.session) terminals=\(session.terminalsRecorded) terminals_left=\(session.terminalsLeft) processes=\(session.leftovers.count) unverified=\(session.unverified)"
    }

    static func sessionJSON(_ session: HCAbandonedSession, items: Bool) -> [String: Any] {
        var processes: [String: Any] = ["count": session.leftovers.count, "unverified": session.unverified]
        if items {
            processes["items"] = session.leftovers.map { leftover -> [String: Any] in
                ["pid": Int(leftover.identity.pid), "started_at": rfc3339(microseconds: leftover.identity.startTimeMicroseconds),
                 "terminal": leftover.terminal, "basis": leftover.basis.rawValue]
            }
        }
        return ["session": session.session,
                "terminals": ["recorded": session.terminalsRecorded, "left": session.terminalsLeft],
                "processes": processes]
    }

    static func counts(_ scan: Scan) -> [String: Any] {
        ["sessions": scan.sessions.count,
         "terminals": scan.sessions.reduce(0) { $0 + $1.terminalsLeft },
         "processes": scan.processCount,
         "unverified": scan.sessions.reduce(0) { $0 + $1.unverified },
         "unreadable": scan.unreadableCount]
    }

    static func json(_ scan: Scan, context: Context, now: Date = Date()) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return ["schema": schema,
                "generated_at": formatter.string(from: now),
                "state_root": context.stateRoot.path,
                "protected": context.protectedFamilies.sorted(),
                "count": counts(scan),
                "sessions": scan.sessions.map { sessionJSON($0, items: true) },
                "skipped": scan.skipped.map { ["session": $0.session, "why": $0.verdict.code] }]
    }

    /// The `hc.diagnostics` fields: counts and one item per session, no pids.
    static func diagnostics(_ scan: Scan) -> [String: Any] {
        ["abandoned_processes": scan.processCount,
         "abandoned_unreadable": scan.unreadableCount,
         "abandoned_sessions": scan.sessions.map { session -> [String: Any] in
             ["session": session.session, "terminals": session.terminalsRecorded, "terminals_left": session.terminalsLeft,
              "processes": session.leftovers.count, "unverified": session.unverified]
         }]
    }
}

// MARK: - The kernel

#if os(macOS)
struct HCKernelAbandonedHost: HCAbandonedHost {
    var uid: uid_t { getuid() }
    var selfPID: Int32 { getpid() }

    func process(_ pid: Int32) -> HCAbandonedProcess? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return Self.entry(info)
    }

    func processes() -> [HCAbandonedProcess]? {
        // Ours by real uid: a setuid-root `login` root has our real uid.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_RUID, Int32(bitPattern: getuid())]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += 64 * MemoryLayout<kinfo_proc>.stride
            var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = infos.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return infos.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap(Self.entry)
        }
        return nil
    }

    func environmentValue(_ name: String, pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 4 << 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        // The executable path, then its NUL padding.
        while cursor < size, bytes[cursor] != 0 { cursor += 1 }
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        // argv.
        var skipped: Int32 = 0
        while cursor < size, skipped < argc {
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            cursor += 1
            skipped += 1
        }
        // The environment, up to the first empty string.
        let prefix = Array((name + "=").utf8)
        while cursor < size, bytes[cursor] != 0 {
            let start = cursor
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            let entry = bytes[start..<cursor]
            if entry.starts(with: prefix) {
                return String(bytes: entry.dropFirst(prefix.count), encoding: .utf8)
            }
            cursor += 1
        }
        return nil
    }

    func socketAccepts(_ path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // A path that does not fit cannot be told apart: treat it as serving.
        guard bytes.count < capacity else { return true }
        var info = stat()
        // Only a missing file proves nothing is bound there.
        guard lstat(path, &info) == 0 else { return errno != ENOENT }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        // Only a refusal or a missing listener proves nothing serves.
        return !(errno == ECONNREFUSED || errno == ENOENT)
    }

    func boundUnixSocketPaths() -> Set<String>? {
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return nil }
        var paths = Set<String>()
        // A process that cannot be read could be a holder: the table is then
        // unreadable, unless the process has just exited.
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 1 {
            errno = 0
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else {
                // No descriptors (errno unset), or it just exited.
                if errno == 0 || errno == ESRCH { continue }
                return nil
            }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
            errno = 0
            let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else {
                if errno == 0 || errno == ESRCH { continue }
                return nil
            }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                // The kernel fills C's sizeof, which is Swift's stride (tail
                // padding included), and refuses a smaller buffer.
                let size = Int32(MemoryLayout<socket_fdinfo>.stride)
                var failed = false
                let path: String? = withUnsafeTemporaryAllocation(of: socket_fdinfo.self, capacity: 1) { buffer in
                    guard let base = buffer.baseAddress else { failed = true; return nil }
                    errno = 0
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, base, size) == size else {
                        // Closed since the listing, or the process exited.
                        failed = !(errno == EBADF || errno == ESRCH)
                        return nil
                    }
                    let info = base.pointee
                    guard info.psi.soi_family == AF_UNIX, Int(info.psi.soi_kind) == Int(SOCKINFO_UN) else { return nil }
                    return withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                    }
                }
                if failed { return nil }
                if let path, !path.isEmpty { paths.insert(path) }
            }
        }
        return paths
    }

    func signal(_ pid: Int32, _ signal: Int32) {
        guard pid > 1 else { return }
        _ = kill(pid, signal)
    }

    func wait(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func entry(_ info: kinfo_proc) -> HCAbandonedProcess? {
        let pid = info.kp_proc.p_pid
        guard pid > 1, info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let session = getsid(pid)
        guard session > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return HCAbandonedProcess(
            identity: HCProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)),
            parentPID: info.kp_eproc.e_ppid,
            session: session,
            realUID: info.kp_eproc.e_pcred.p_ruid)
    }
}
#else
/// C11H-392: the Linux c11 CLI is a relay; it never looks for this Mac's
/// abandoned hc sessions. On Linux this host reads nothing and signals
/// nothing, so no session there is ever found abandoned or ended.
struct HCKernelAbandonedHost: HCAbandonedHost {
    var uid: uid_t { getuid() }
    var selfPID: Int32 { getpid() }
    func process(_ pid: Int32) -> HCAbandonedProcess? { nil }
    func processes() -> [HCAbandonedProcess]? { nil }
    func environmentValue(_ name: String, pid: Int32) -> String? { nil }
    func socketAccepts(_ path: String) -> Bool { true }
    func boundUnixSocketPaths() -> Set<String>? { nil }
    func signal(_ pid: Int32, _ signal: Int32) {}
    func wait(_ seconds: TimeInterval) {}
}
#endif
