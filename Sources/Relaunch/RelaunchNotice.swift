import Darwin
import Foundation

// C11-568: a relaunch ends every agent terminal's process tree. Resumed agents
// get one c11 mailbox notice saying so, with the number of background process
// groups each one lost when the previous run measured it at quit, and the
// event stream gets one `app.relaunched` event carrying the previous run's
// short refs so external watchers can remap them to UUIDs.
//
// Everything here writes inside c11's own runtime: `~/.c11/runtime/` for the
// record and the workspace mailbox outbox for the notice. Nothing touches
// tenant configuration.

/// What the previous run left for this launch: its short refs and, when it
/// quit cleanly enough to measure them, each agent panel's background process
/// groups. Consumed (read, then deleted) once at launch.
struct RelaunchRecord: Codable, Equatable {
    static let schemaVersion = 1

    enum Reason: String, Codable {
        /// Written as the app quit; carries process counts.
        case quit
        /// Written by session autosave; refs only. A run that crashed leaves
        /// only this kind.
        case autosave
    }

    struct RefEntry: Codable, Equatable {
        let ref: String
        let id: String
    }

    /// Ref kinds in the record and the event, in display order.
    static let refKinds = ["window", "workspace", "area", "panel"]

    var schema: Int = RelaunchRecord.schemaVersion
    /// The writing run's dirty-sentinel launch stamp (seconds since 1970).
    var runLaunchedAt: Double
    var writtenAt: Double
    var reason: Reason
    /// Ref kind (`window`, `workspace`, `area`, `panel`) to that kind's refs.
    var refs: [String: [RefEntry]]
    /// Panel UUID to background process groups ended at quit. Quit only.
    var backgroundProcesses: [String: Int]?
    /// Panel UUID to every live descendant at quit, for diagnosis only.
    var descendantProcesses: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case schema
        case runLaunchedAt = "run_launched_at"
        case writtenAt = "written_at"
        case reason
        case refs
        case backgroundProcesses = "background_processes"
        case descendantProcesses = "descendant_processes"
    }

    /// The count the notice may state for `panelId`: only a quit record
    /// measured it. An autosave record (a crash) never carries one.
    func backgroundProcessCount(panelId: UUID) -> Int? {
        guard reason == .quit else { return nil }
        return backgroundProcesses?[panelId.uuidString]
    }
}

enum RelaunchRecordStore {
    /// `~/.c11/runtime/relaunch.<bundle>.json`, beside the shutdown sentinel.
    static func url(bundleId: String, directory: URL? = nil) -> URL? {
        guard let dir = directory ?? ShutdownSentinel.defaultDirectory() else { return nil }
        let safe = ShutdownSentinel.sanitisedBundleId(bundleId)
        return dir.appendingPathComponent("relaunch.\(safe).json", isDirectory: false)
    }

    /// Owner-only atomic write. Best effort: a failure costs only the notice
    /// count and the event's ref pairs.
    @discardableResult
    static func write(_ record: RelaunchRecord, to url: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Read the previous run's record, then delete it so no later launch can
    /// read it again. Deleting first-thing at launch means any record present
    /// at the next launch was written by this run.
    static func consume(
        url: URL,
        priorShutdown: ShutdownSentinel.PriorShutdown,
        fileManager: FileManager = .default
    ) -> RelaunchRecord? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try? Data(contentsOf: url)
        try? fileManager.removeItem(at: url)
        guard let data,
              let record = try? JSONDecoder().decode(RelaunchRecord.self, from: data) else {
            return nil
        }
        return accepts(record, priorShutdown: priorShutdown) ? record : nil
    }

    /// How long before the clean marker the previous run's last record may
    /// have been written: the quit record lands just before it, an autosave
    /// copy (when the quit write failed) within one autosave interval.
    static let cleanMarkerWindow: TimeInterval = 120

    /// A crashed run left its dirty marker with its launch stamp; only that
    /// run's record belongs to this relaunch. A clean run's record was written
    /// moments before its clean marker. An older record that survived a failed
    /// delete, or an older build that wrote none, fails both checks.
    static func accepts(_ record: RelaunchRecord, priorShutdown: ShutdownSentinel.PriorShutdown) -> Bool {
        guard record.schema == RelaunchRecord.schemaVersion else { return false }
        switch priorShutdown {
        case .dirty(let launchedAt):
            guard let launchedAt else { return false }
            return abs(launchedAt.timeIntervalSince1970 - record.runLaunchedAt) < 0.001
        case .clean(let at):
            let gap = at.timeIntervalSince1970 - record.writtenAt
            return gap >= -1 && gap <= cleanMarkerWindow
        case .missing, .unreadable, .invalid:
            return false
        }
    }
}

/// Counts what a relaunch ends under each agent: the process groups among its
/// descendants other than the agent's own. Agent harnesses run each shell
/// command in its own process group (a background `sleep` is one group, its
/// shell and the command together), while MCP servers and helpers stay in the
/// agent's group, so groups count the work an agent started.
enum RelaunchProcessCount {
    struct ProcessEntry: Equatable {
        let pid: pid_t
        let parentPid: pid_t
        let processGroup: pid_t
        /// Microseconds since 1970.
        let startTime: UInt64
        /// Kernel short command name (`p_comm`).
        let command: String
        let isZombie: Bool
    }

    struct Agent: Equatable {
        let panelId: UUID
        let pid: pid_t
        /// Pinned at registration; nil means unverifiable and gets no count.
        let startTime: UInt64?
    }

    struct Count: Equatable {
        let backgroundGroups: Int
        let descendants: Int
    }

    /// c11's own CLI (the Claude mailbox bridge, an in-flight `c11` command)
    /// is not the agent's work.
    static let sidecarCommands: Set<String> = ["c11", "cmux"]

    /// Upper bound on the quit-time measurement; past it the record carries
    /// no counts.
    static let quitTimeout: TimeInterval = 0.2

    /// The process table indexed once for every agent's walk.
    struct Table {
        let byPid: [pid_t: ProcessEntry]
        let children: [pid_t: [ProcessEntry]]

        init(_ processes: [ProcessEntry]) {
            var byPid: [pid_t: ProcessEntry] = [:]
            var children: [pid_t: [ProcessEntry]] = [:]
            for entry in processes {
                byPid[entry.pid] = entry
                if entry.pid != entry.parentPid {
                    children[entry.parentPid, default: []].append(entry)
                }
            }
            self.byPid = byPid
            self.children = children
        }
    }

    static func count(agent: Agent, in processes: [ProcessEntry]) -> Count? {
        count(agent: agent, in: Table(processes))
    }

    static func count(agent: Agent, in table: Table) -> Count? {
        guard let expectedStart = agent.startTime,
              let root = table.byPid[agent.pid],
              !root.isZombie,
              root.startTime == expectedStart else { return nil }
        let children = table.children
        var groups = Set<pid_t>()
        var descendants = 0
        var visited: Set<pid_t> = [root.pid]
        var queue = children[root.pid] ?? []
        while let entry = queue.popLast() {
            guard visited.insert(entry.pid).inserted else { continue }
            queue.append(contentsOf: children[entry.pid] ?? [])
            guard !entry.isZombie else { continue }
            descendants += 1
            if entry.processGroup != root.processGroup,
               !sidecarCommands.contains(entry.command) {
                groups.insert(entry.processGroup)
            }
        }
        return Count(backgroundGroups: groups.count, descendants: descendants)
    }

    static func counts(agents: [Agent], in processes: [ProcessEntry]) -> [UUID: Count] {
        let table = Table(processes)
        var out: [UUID: Count] = [:]
        for agent in agents {
            if let count = count(agent: agent, in: table) { out[agent.panelId] = count }
        }
        return out
    }

    /// One `sysctl(KERN_PROC_ALL)` read of every process. Nil on failure.
    static func liveProcesses() -> [ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            // Room for processes started between the two calls.
            size += 64 * MemoryLayout<kinfo_proc>.stride
            var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = infos.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            let count = size / MemoryLayout<kinfo_proc>.stride
            return infos.prefix(count).map { info in
                var comm = info.kp_proc.p_comm
                let command = withUnsafeBytes(of: &comm) { raw -> String in
                    let bytes = raw.prefix { $0 != 0 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                return ProcessEntry(
                    pid: info.kp_proc.p_pid,
                    parentPid: info.kp_eproc.e_ppid,
                    processGroup: info.kp_eproc.e_pgid,
                    startTime: UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
                        + UInt64(info.kp_proc.p_starttime.tv_usec),
                    command: command,
                    isZombie: Int32(info.kp_proc.p_stat) == SZOMB
                )
            }
        }
        return nil
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UUID: Count]?
        var value: [UUID: Count]? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Measure off the calling thread, waiting at most `timeout`. Nil when
    /// the process table could not be read in time.
    static func measure(agents: [Agent], timeout: TimeInterval = quitTimeout) -> [UUID: Count]? {
        guard !agents.isEmpty else { return [:] }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let processes = liveProcesses() {
                box.value = counts(agents: agents, in: processes)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}

/// The one mailbox notice each resumed agent panel gets after a relaunch.
enum RelaunchNotice {
    static let topic = "c11.relaunch"
    static let sender = "c11"
    /// Upper bound on inbox files examined when superseding an older notice.
    static let supersedeScanLimit = 512

    /// Agent-facing protocol text, like the doorbell line; not localized.
    static func body(
        restartedAt: Date,
        backgroundProcesses: Int?,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm zzz"
        var text = "c11 restarted at \(formatter.string(from: restartedAt)); "
        if let count = backgroundProcesses {
            text += count == 1
                ? "1 background job ended; "
                : "\(count) background jobs ended; "
        }
        text += "your background shells, watchers and monitors did not survive; "
            + "re-arm what you depend on. Short refs renumbered; use UUIDs."
        return text
    }

    /// Remove unread notices from an earlier relaunch still sitting in the
    /// inbox, so two quick relaunches leave one notice, never a stack. Mail
    /// already read (moved out of the inbox root) and other mail are kept.
    /// `ext` key carrying the notice's job count, so a replacement can add
    /// in jobs from a notice the agent never read.
    static let jobsExtKey = "c11_relaunch_jobs"

    struct Superseded: Equatable {
        var removed = 0
        /// Jobs stated by the removed notices; nil when none stated a count.
        var jobs: Int?
    }

    @discardableResult
    static func supersedeUnread(inbox: URL, fileManager: FileManager = .default) -> Superseded {
        var result = Superseded()
        guard let names = try? fileManager.contentsOfDirectory(atPath: inbox.path) else { return result }
        for name in names.prefix(supersedeScanLimit)
        where name.hasSuffix(".\(MailboxLayout.envelopeExtension)") && !name.hasPrefix(".") {
            let url = inbox.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? MailboxEnvelope.validate(data: data),
                  envelope.topic == topic, envelope.from == sender else { continue }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            result.removed += 1
            if let jobs = (envelope.ext?[jobsExtKey] as? NSNumber)?.intValue {
                result.jobs = (result.jobs ?? 0) + jobs
            }
        }
        return result
    }

    /// Jobs the new notice states: this relaunch's measured count plus any an
    /// unread earlier notice stated. Unmeasured (a crash) stays unstated.
    static func statedJobs(measured: Int?, superseded: Int?) -> Int? {
        guard let measured else { return nil }
        return measured + (superseded ?? 0)
    }

    /// Supersede any older unread notice, then hand one envelope to the
    /// workspace's dispatcher. Delivery is ordinary mail: the doorbell rings
    /// only at an idle prompt and the envelope is claimed once. Off main.
    @discardableResult
    static func deliver(
        workspaceId: UUID,
        panelId: UUID,
        restartedAt: Date,
        backgroundProcesses: Int?,
        stateURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let superseded = supersedeUnread(
            inbox: MailboxLayout.inboxURL(state: stateURL, workspaceId: workspaceId, panelId: panelId),
            fileManager: fileManager
        )
        let jobs = statedJobs(measured: backgroundProcesses, superseded: superseded.jobs)
        let envelope = try MailboxEnvelope.build(
            from: sender,
            to: MailboxAddress.idPrefix + panelId.uuidString,
            topic: topic,
            body: body(restartedAt: restartedAt, backgroundProcesses: jobs),
            ext: jobs.map { [jobsExtKey: $0] }
        )
        let outbox = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        try fileManager.createDirectory(
            at: outbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try MailboxIO.atomicWrite(
            data: try envelope.encode(),
            to: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        )
        return envelope.id
    }

    /// One notice per panel per launch, however many resume paths reach it.
    struct Ledger {
        private(set) var noticed = Set<UUID>()
        mutating func claim(_ panelId: UUID) -> Bool { noticed.insert(panelId).inserted }
    }
}
