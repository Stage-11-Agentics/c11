import Darwin
import Foundation
import OSLog

struct HCLaunchLimitReport: Sendable {
    let beforeSoft: UInt64
    let afterSoft: UInt64
    let hard: UInt64
    let kernelCap: UInt64
}

protocol HCCoreLaunching: Sendable {
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport
}

/// A dedicated worker handles blocking filesystem/process APIs. It launches only
/// the pinned core's `serve`, as this process's own child (A1); it never launches
/// an app or signals a core or holder.
final class HCLauncher: HCCoreLaunching, Sendable {
    private let queue = DispatchQueue(label: "c11.hc.launch", qos: .utility)
    private let verifier: HCBuildVerifier
    private let startLog: HCCoreStartLog
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.launch")

    init(verifier: HCBuildVerifier, startLog: HCCoreStartLog = .live) {
        self.verifier = verifier
        self.startLog = startLog
    }

    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        let log = startLog
        do { _ = try await verifier.verifyPin(configuration) }
        catch { log.failed(.launchPin, error, detail: configuration.executableURL.path); throw error }
        log.passed(.launchPin, detail: configuration.executableURL.path)
        guard HCMonotonic.now < deadlineUptimeNanoseconds else {
            log.failed(.launchPin, HCUnavailableReason.deadlineExceeded, detail: "deadline before launch")
            throw HCUnavailableReason.deadlineExceeded
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    do { try HCBuildVerifier.verifyStateEndpoint(configuration) }
                    catch { log.failed(.launchState, error, detail: configuration.stateDirectory.path); throw error }
                    log.passed(.launchState)
                    for directory in Self.privateFolders(configuration) {
                        do { try Self.preparePrivateDirectory(directory) }
                        catch { log.failed(.launchDirectories, error, detail: Self.describe(directory)); throw error }
                    }
                    log.passed(.launchDirectories)
                    if let configDirectory = configuration.configDirectory {
                        do { try HCCoreConfigFile.ensure(in: configDirectory) }
                        catch { log.failed(.launchConfig, error, detail: Self.describe(configDirectory)); throw error }
                        log.passed(.launchConfig)
                    }
                    let report: HCLaunchLimitReport
                    do { report = try Self.raiseFileLimit() }
                    catch { log.failed(.launchFileLimit, error, detail: "need hard limit >= \(HCLimits.minimumFileDescriptors)"); throw error }
                    Self.logger.info("hc_fd_limit session=\(configuration.session, privacy: .public) before_soft=\(report.beforeSoft) after_soft=\(report.afterSoft) hard=\(report.hard) kernel_cap=\(report.kernelCap)")
                    guard HCMonotonic.now < deadlineUptimeNanoseconds else { throw HCUnavailableReason.deadlineExceeded }
                    // A1 (C11H-66): this process spawns `serve` itself, so the core is
                    // its direct child and HC_LAUNCHD_DIRECT names its real parent.
                    // `server start` would fork `serve` from a helper that then exits.
                    let pid: pid_t
                    do { pid = try HCCoreSpawn.spawnServe(configuration) }
                    catch { log.failed(.launchSpawn, error, detail: "\(configuration.executableURL.path): \(error.localizedDescription)"); throw error }
                    log.passed(.launchSpawn, detail: "serve pid \(pid) parent \(getpid())")
                    let exit = HCCoreSpawn.reap(pid)
                    do {
                        try HCCoreSpawn.waitUntilAnswering(configuration.socketURL, exit: exit,
                                                           deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
                    } catch {
                        // Nothing is signalled: a slow core may be adopting holders.
                        let status = exit.status.map { "exit status \($0)" } ?? "still running"
                        log.failed(.launchExit, error, detail: "serve pid \(pid) \(status), socket not answering")
                        throw error
                    }
                    log.passed(.launchExit, detail: "serve pid \(pid) answering")
                    continuation.resume(returning: report)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// The directory itself must be a real directory, owned by the user and
    /// private. Ancestors may be symlinks (a home under /var, /tmp or a
    /// relocated volume is ordinary): the leaf is checked with lstat, which does
    /// not follow a final symlink, and a missing leaf is created 0700 first.
    /// Paths are compared as strings without a trailing slash: URL equality is
    /// not stable for a not-yet-existing directory under a symlinked parent.
    ///
    /// C11H-332: hc trusts its socket folder's mode alone (it has no
    /// per-client check), so the leaf is opened relative to its parent's
    /// descriptor without following a symlink (and created there with
    /// `mkdirat` when missing): a real directory this user owns with group or
    /// other bits is `fchmod`ed to 0700 and audited (`dir_repaired`). A
    /// symlink, another owner or a non-directory is refused (`dir_refused`,
    /// once per path per process) and nothing under it is touched.
    /// With `repair: false` (a read-only shard) nothing is created or changed:
    /// a missing folder is skipped by the caller and a loose one is refused.
    static func preparePrivateDirectory(_ directory: URL, repair: Bool = true, audit: C11AuditLog = .shared) throws {
        let path = normalizedPath(directory)
        let parentPath = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != ".." else { throw HCUnavailableReason.invalidLaunchTuple }
        var info = stat()
        if lstat(parentPath, &info) != 0 {
            guard errno == ENOENT, repair else { throw HCUnavailableReason.invalidLaunchTuple }
            // Ancestors may be symlinks (a home under /var or a moved volume).
            try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw HCUnavailableReason.invalidLaunchTuple }
        defer { close(parent) }
        var fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, repair {
            // 0700 under any umask (it can only clear bits). The process umask
            // stays as it is: changing it races every other thread's new files
            // (C11H-402).
            let made = mkdirat(parent, leaf, 0o700)
            let failure = errno
            guard made == 0 || failure == EEXIST else { throw HCUnavailableReason.invalidLaunchTuple }
            fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { auditRefusal(path: path, info: info, audit: audit) }
            throw HCUnavailableReason.invalidLaunchTuple
        }
        defer { close(fd) }
        guard fstat(fd, &info) == 0 else { throw HCUnavailableReason.invalidLaunchTuple }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            auditRefusal(path: path, info: info, audit: audit)
            throw HCUnavailableReason.invalidLaunchTuple
        }
        guard info.st_mode & 0o077 != 0 else { return }
        guard repair else {
            auditRefusal(path: path, info: info, audit: audit, reason: "not_private")
            throw HCUnavailableReason.invalidLaunchTuple
        }
        let previous = info.st_mode & 0o777
        guard fchmod(fd, 0o700) == 0, fstat(fd, &info) == 0, info.st_mode & 0o077 == 0 else {
            throw HCUnavailableReason.invalidLaunchTuple
        }
        audit.record(C11AuditRecord(kind: .dirRepaired, via: "app", outcome: "ok", machine: "local", path: path,
                                    detail: "mode \(String(previous, radix: 8)) to 700"))
    }

    /// hc's folders on this Mac, parents before children: the socket folder,
    /// hc's state root (only when it is hc's own `herdr-core` folder) and the
    /// session's state folder.
    static func privateFolders(_ configuration: HCLaunchConfiguration) -> [URL] {
        let stateRoot = configuration.stateDirectory.deletingLastPathComponent()
        return [configuration.socketURL.deletingLastPathComponent()]
            + (stateRoot.lastPathComponent == "herdr-core" ? [stateRoot] : [])
            + [configuration.stateDirectory]
    }

    /// C11H-332: the same check for a core c11 found already running (it did
    /// not start it, so its launch never checked). Existing folders only;
    /// nothing is created. False at the first refused folder: the walk stops
    /// there, so nothing under it is touched, and the caller refuses the core.
    /// With `repair: false` (a read-only shard) it only inspects: a loose
    /// folder refuses the core rather than being changed.
    @discardableResult
    static func repairPrivateFolders(_ configuration: HCLaunchConfiguration, repair: Bool = true,
                                     audit: C11AuditLog = .shared) -> Bool {
        for directory in privateFolders(configuration) {
            var info = stat()
            guard lstat(normalizedPath(directory), &info) == 0 else { continue }
            do { try preparePrivateDirectory(directory, repair: repair, audit: audit) } catch { return false }
        }
        return true
    }

    private static let refusedLock = NSLock()
    nonisolated(unsafe) private static var refusedPaths: Set<String> = []

    private static func auditRefusal(path: String, info: stat, audit: C11AuditLog, reason given: String? = nil) {
        let reason = given ?? (info.st_mode & S_IFMT == S_IFLNK ? "symlink"
            : (info.st_mode & S_IFMT != S_IFDIR ? "not_a_directory" : "owner_\(info.st_uid)"))
        refusedLock.lock()
        let first = refusedPaths.insert(path).inserted
        refusedLock.unlock()
        guard first else { return }
        audit.record(C11AuditRecord(kind: .dirRefused, via: "app", outcome: "refused", machine: "local", path: path, code: reason))
    }

    /// Standardized path with no trailing slash.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// For the log when a directory is refused: what was asked and where it
    /// resolves, so a symlinked leaf or a foreign owner is visible.
    static func describe(_ directory: URL) -> String {
        let path = normalizedPath(directory)
        let resolved = normalizedPath(directory.resolvingSymlinksInPath())
        var info = stat()
        guard lstat(path, &info) == 0 else { return "\(path) (missing)" }
        let kind = info.st_mode & S_IFMT == S_IFLNK ? "symlink" : (info.st_mode & S_IFMT == S_IFDIR ? "dir" : "other")
        return "\(path) kind=\(kind) uid=\(info.st_uid) mode=\(String(info.st_mode & 0o777, radix: 8)) resolves-to=\(resolved)"
    }

    static func raiseFileLimit() throws -> HCLaunchLimitReport {
        var before = rlimit()
        var cap: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard getrlimit(RLIMIT_NOFILE, &before) == 0,
              sysctlbyname("kern.maxfilesperproc", &cap, &size, nil, 0) == 0, cap > 0 else {
            throw HCUnavailableReason.fileDescriptorLimit
        }
        let plan = try HCFileLimitPlan(soft: UInt64(before.rlim_cur), hard: UInt64(before.rlim_max),
                                      kernelCap: UInt64(cap), infinity: UInt64(Int64.max) /* Darwin RLIM_INFINITY: (1ULL << 63) - 1 */)
        if plan.targetSoft != before.rlim_cur {
            var desired = before
            desired.rlim_cur = rlim_t(plan.targetSoft)
            guard setrlimit(RLIMIT_NOFILE, &desired) == 0 else { throw HCUnavailableReason.fileDescriptorLimit }
        }
        var after = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &after) == 0,
              plan.verified(soft: UInt64(after.rlim_cur), hard: UInt64(after.rlim_max)) else {
            throw HCUnavailableReason.fileDescriptorLimit
        }
        return HCLaunchLimitReport(beforeSoft: plan.soft, afterSoft: UInt64(after.rlim_cur),
                                   hard: UInt64(after.rlim_max), kernelCap: UInt64(cap))
    }
}


/// c11's own `herdr-core/config.toml` under the core's `XDG_CONFIG_HOME`
/// (A1). Only c11 writes it; hc's shared `~/.config/herdr-core` is never read.
enum HCCoreConfigFile {
    /// C13's start size, written explicitly so hc's shared config cannot move
    /// it. Ticket 5 (P5) changes this one constant.
    static let contents = "headless = \"200x120\"\n"

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("herdr-core", isDirectory: true).appendingPathComponent("config.toml")
    }

    /// Writes the file atomically, and only when its contents differ. A core
    /// that is already running keeps what it read at start. Returns whether it wrote.
    @discardableResult
    static func ensure(in directory: URL, contents: String = contents) throws -> Bool {
        try HCLauncher.preparePrivateDirectory(directory)
        let folder = directory.appendingPathComponent("herdr-core", isDirectory: true)
        try HCLauncher.preparePrivateDirectory(folder)
        let file = fileURL(in: directory), wanted = Data(contents.utf8)
        if let existing = try? PrivateFileWriter.readPrivateFile(at: file, maxBytes: 64 * 1024), existing == wanted {
            return false
        }
        try PrivateFileWriter.write(wanted, to: file)
        return true
    }
}

/// The exit status of a core this process spawned, recorded by its reaper.
final class HCServeExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    /// nil while the process runs; the raw `waitpid` status after it exits.
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ status: Int32) { lock.lock(); value = status; lock.unlock() }
}

/// Spawns `herdr-core serve` the way hc's `server start` does
/// (`client::spawn_detached`: own session, stdin and stdout on /dev/null, stderr
/// appended to `core.log`, `HC_RUNTIME=1`, no `HC_SCOPE`), but as this process's
/// own child, so A1's `HC_LAUNCHD_DIRECT` names the real parent (C7). A core
/// that loses `core.lock` to one already serving exits 0 and the serving one
/// answers; `serve` removes a stale socket file before it binds.
enum HCCoreSpawn {
    enum Failure: Error, Equatable { case exited(Int32) }

    static func serveEnvironment(_ configuration: HCLaunchConfiguration) -> [String: String] {
        var environment = configuration.environment
        environment.removeValue(forKey: "HC_SCOPE")
        environment["HC_RUNTIME"] = "1"
        return environment
    }

    static func spawnServe(_ configuration: HCLaunchConfiguration) throws -> pid_t {
        try spawn(executable: configuration.executableURL.path, arguments: ["serve"],
                  environment: serveEnvironment(configuration),
                  stderrPath: configuration.stateDirectory.appendingPathComponent("core.log").path)
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String],
                      stderrPath: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        for signal in 1..<NSIG where signal != SIGKILL && signal != SIGSTOP { sigaddset(&defaults, signal) }
        sigemptyset(&mask)
        // Its own session (no SIGHUP from c11's group), default dispositions and
        // an empty mask as a fresh Rust child gets, and none of c11's descriptors.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, 2, stderrPath,
                                                   O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600))
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&pid, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argvBuffer.baseAddress!),
                            UnsafeMutablePointer(mutating: envpBuffer.baseAddress!))
            }
        }
        try check(rc)
        return pid
    }

    /// One thread per spawned core waits for it, so an exit never leaves a
    /// zombie while c11 runs (hc's own launcher does the same).
    static func reap(_ pid: pid_t) -> HCServeExit {
        let exit = HCServeExit()
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                guard errno == EINTR else { status = -1; break }
            }
            exit.record(status)
        }
        thread.name = "c11.hc.reaper"
        thread.stackSize = 64 * 1024
        thread.start()
        return exit
    }

    /// Ready when the socket accepts a connection (hc's `wait_for_socket`). A
    /// nonzero exit first fails at once; a zero exit means another core holds
    /// `core.lock`, so its socket is awaited. Signals nothing at the deadline.
    #if DEBUG
    /// C11H-346 test seam: runs on the launch thread after each poll that found the socket
    /// silent and the core not failed, with the exit status that poll saw (nil while it runs).
    nonisolated(unsafe) static var waitPollForTesting: ((_ socket: URL, _ status: Int32?) -> Void)?
    #endif

    static func waitUntilAnswering(_ socket: URL, exit: HCServeExit, deadlineUptimeNanoseconds: UInt64,
                                   pollMicroseconds: useconds_t = 10_000) throws {
        while true {
            if answers(socket) { return }
            let status = exit.status
            if let status, status != 0 { throw HCUnavailableReason.coreUnreachable }
            #if DEBUG
            waitPollForTesting?(socket, status)
            #endif
            guard HCMonotonic.now < deadlineUptimeNanoseconds else { throw HCUnavailableReason.deadlineExceeded }
            usleep(pollMicroseconds)
        }
    }

    static func answers(_ socket: URL) -> Bool {
        let path = socket.path
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func check(_ rc: Int32) throws {
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
    }
}
