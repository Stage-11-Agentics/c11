// Linux only (tools/linux-cli): compiled into the Linux c11 beside the CLI's own files, never into the macOS app or CLI.
// Fills the few Foundation surfaces Apple platforms have and swift-corelibs/swift-foundation on Linux do not.
#if os(Linux)
import Foundation

extension String {
    /// The CLI's localized strings: Linux carries no string catalogs, so every one reads its English default.
    init(localized key: StaticString, defaultValue: String, table: String? = nil, bundle: Bundle? = nil,
         locale: Locale = .current, comment: StaticString? = nil) {
        self = defaultValue
    }
}

/// No Objective-C runtime on Linux, so nothing to drain: run the body.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// macOS's names for stat's time fields, read from Linux's.
extension stat {
    var st_mtimespec: timespec { st_mtim }
    var st_ctimespec: timespec { st_ctim }
}

let MAXPATHLEN = Int32(PATH_MAX)

/// macOS's `_NSGetExecutablePath`, from /proc/self/exe: with a nil or short buffer it sets the size needed and fails.
func _NSGetExecutablePath(_ buffer: UnsafeMutablePointer<CChar>?, _ size: UnsafeMutablePointer<UInt32>) -> Int32 {
    guard let path = LinuxProc.executablePath(getpid()) else { return -1 }
    let needed = UInt32(path.utf8.count + 1)
    guard let buffer, size.pointee >= needed else { size.pointee = needed; return -1 }
    _ = path.withCString { strcpy(buffer, $0) }
    return 0
}

extension NSString {
    /// Foundation on Linux lacks it: the home folder becomes `~`.
    var abbreviatingWithTildeInPath: String {
        let path = self as String, home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What the CLI reads about a process on macOS through sysctl and proc_pidinfo, read from /proc.
enum LinuxProc {
    struct Stat { let state: Character; let parentPID: Int32; let startTicks: UInt64 }

    static func stat(_ pid: Int32) -> Stat? {
        guard pid > 0, let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        // After "pid (comm)": state is field 3, ppid 4, starttime 22.
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let state = fields[0].first, let ppid = Int32(fields[1]),
              let start = UInt64(fields[19]) else { return nil }
        return Stat(state: state, parentPID: ppid, startTicks: start)
    }

    /// The kernel's boot time (/proc/stat btime).
    static var bootTime: Date? {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let seconds = TimeInterval(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A start time in microseconds since boot: stable for one process, different for a recycled pid.
    static func startMicroseconds(_ stat: Stat) -> UInt64 {
        let ticks = UInt64(max(sysconf(Int32(_SC_CLK_TCK)), 1))
        return stat.startTicks * 1_000_000 / ticks
    }

    /// A start time in microseconds since the epoch, the unit macOS's proc_bsdinfo gives, so values from the two
    /// platforms (a registry's recorded pid_start, a build identity) compare. 0 when the boot time is unreadable.
    static func epochMicroseconds(_ stat: Stat) -> UInt64 {
        guard let boot = bootTime else { return 0 }
        return UInt64(boot.timeIntervalSince1970) * 1_000_000 + startMicroseconds(stat)
    }

    static func startDate(_ pid: Int32) -> Date? {
        guard let stat = stat(pid), let boot = bootTime else { return nil }
        return boot.addingTimeInterval(TimeInterval(startMicroseconds(stat)) / 1_000_000)
    }

    /// The real uid from /proc/<pid>/status.
    static func uid(_ pid: Int32) -> uid_t? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }) else { return nil }
        return line.split(whereSeparator: { $0 == "\t" || $0 == " " }).dropFirst().first.flatMap { uid_t($0) }
    }

    static func executablePath(_ pid: Int32) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }

    /// The peer of a connected Unix socket (SO_PEERCRED).
    static func peerCredentials(_ fd: Int32) -> (pid: Int32, uid: uid_t)? {
        var cred = ucred()
        var size = socklen_t(MemoryLayout<ucred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &size) == 0 else { return nil }
        return (cred.pid, cred.uid)
    }

    static var hostName: String {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return "this machine" }
        return String(cString: name)
    }
}
#endif
