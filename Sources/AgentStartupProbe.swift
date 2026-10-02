import Darwin
import Foundation

/// Process observation only: `started` proves neither TUI readiness nor prompt ingestion.
/// Invoke off-main. Native inspection has no subprocess, AppKit, or screen parsing.
enum AgentStartupProbe {
    enum Status: String, Equatable {
        case started, pending, failed
    }

    struct Evidence: Equatable {
        let pid: Int32
        /// Basename only; arguments (including prompts) never leave the probe.
        let executable: String
    }

    struct Result: Equatable {
        let status: Status
        let process: Evidence?
    }

    struct ProcessSnapshot: Equatable {
        let pid: Int32
        let processGroup: Int32
        let executablePath: String
        /// Only interpreter invocation tokens, kept internal and never returned.
        let arguments: [String]
    }

    struct Snapshot: Equatable {
        let foregroundGroup: Int32
        let processes: [ProcessSnapshot]
    }

    static func observe(ttyName: String?, expectedKind: String, deadline: Date) -> Result {
        observe(ttyName: { ttyName }, expectedKind: expectedKind, deadline: deadline)
    }

    /// The resolver can supply a newly reported TTY on a later poll. It must itself
    /// be bounded by the caller's remaining deadline if it hops to the main queue.
    static func observe(
        ttyName: () -> String?,
        expectedKind: String,
        deadline: Date,
        snapshot: (String) -> Snapshot? = nativeSnapshot,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> Result {
        let observationDeadline = min(deadline, now().addingTimeInterval(5))
        guard nativeNames[expectedKind] != nil else {
            return Result(status: .pending, process: nil)
        }
        while now() < observationDeadline {
            if let tty = ttyName(), now() < observationDeadline,
               let state = snapshot(tty), now() < observationDeadline,
               let process = identifiedProcess(in: state, expectedKind: expectedKind) {
                return Result(status: .started, process: process)
            }
            let remaining = observationDeadline.timeIntervalSince(now())
            guard remaining > 0 else { break }
            sleep(min(0.2, remaining))
        }
        // Silence, continuation prompts, missing executables and vanished TTYs
        // cannot establish an attributable process failure; all stay pending.
        return Result(status: .pending, process: nil)
    }

    static func identifiedProcess(in snapshot: Snapshot, expectedKind: String) -> Evidence? {
        guard snapshot.foregroundGroup > 0 else { return nil }
        let matches = snapshot.processes.filter {
            $0.pid > 0 && $0.processGroup == snapshot.foregroundGroup
                && matchesIdentity($0, kind: expectedKind)
        }
        // Ambiguity is not evidence. Do not choose the highest PID on the TTY.
        guard matches.count == 1, let process = matches.first else { return nil }
        return Evidence(pid: process.pid, executable: basename(process.executablePath))
    }

    private static let nativeNames: [String: Set<String>] = [
        "claude-code": ["claude", "claude-code"],
        "codex": ["codex", "codex-cli"],
        "grok": ["grok", "grok-cli"],
        "kimi": ["kimi", "kimi-cli"],
        "opencode": ["opencode", "opencode-cli"],
        "github-copilot": ["copilot"],
        "pi": ["pi"],
        "omp": ["omp"],
    ]

    private static func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private static func matchesIdentity(_ process: ProcessSnapshot, kind: String) -> Bool {
        guard let names = nativeNames[kind] else { return false }
        let executable = basename(process.executablePath)
        if names.contains(executable) { return true }
        let isPython = executable == "python" || executable == "python3"
            || executable.hasPrefix("python3.")
        let isJavaScript = ["node", "bun", "deno"].contains(executable)
        guard isPython || isJavaScript, process.arguments.count > 1 else { return false }
        // Inspect only the actual interpreter entrypoint, never later prompt
        // tokens that happen to mention an agent or a package path.
        let entry = process.arguments[1]
        if isPython, kind == "kimi" {
            if entry == "-m" { return process.arguments.dropFirst(2).first == "kimi_cli" }
            return ["kimi", "kimi-cli"].contains(basename(entry))
                || entry.hasSuffix("/kimi_cli/__main__.py")
        }
        guard isJavaScript, !entry.hasPrefix("-") else { return false }
        switch kind {
        case "claude-code":
            return entry.hasSuffix("/@anthropic-ai/claude-code/cli.js")
        case "github-copilot":
            return entry.hasSuffix("/@github/copilot/index.js")
        case "pi":
            return entry.hasSuffix("/@earendil-works/pi/dist/cli.js")
        case "omp":
            return entry.hasSuffix("/@oh-my-pi/pi-coding-agent/dist/cli.js")
        default:
            // Codex's JS entrypoint is a launcher; wait for its native child.
            // Unknown interpreter forms conservatively remain pending.
            return false
        }
    }

    /// Actual kernel foreground group, restricted to processes with this
    /// controlling TTY. Recheck it after enumeration to fail closed on churn.
    static func nativeSnapshot(ttyName: String) -> Snapshot? {
        let path = ttyName.hasPrefix("/") ? ttyName : "/dev/\(ttyName)"
        let descriptor = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var ttyStat = stat()
        guard fstat(descriptor, &ttyStat) == 0 else { return nil }
        let group = tcgetpgrp(descriptor)
        guard group > 0 else { return nil }
        let type = UInt32(PROC_TTY_ONLY)
        let device = UInt32(truncatingIfNeeded: ttyStat.st_rdev)
        let byteCount = proc_listpids(type, device, nil, 0)
        guard byteCount > 0, byteCount <= 4 * 1024 * 1024 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride)
        let written = pids.withUnsafeMutableBufferPointer {
            proc_listpids(type, device, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
        }
        guard written > 0 else { return nil }
        var processes: [ProcessSnapshot] = []
        let scanDeadline = ProcessInfo.processInfo.systemUptime + 0.1
        for pid in pids.prefix(min(pids.count, Int(written) / MemoryLayout<pid_t>.stride)) where pid > 0 {
            guard ProcessInfo.processInfo.systemUptime < scanDeadline else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pgid == UInt32(group), info.e_tdev == device,
                  info.pbi_status != UInt32(SZOMB) else { continue }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let executablePath = String(cString: pathBuffer)
            let name = basename(executablePath)
            let interpreter = ["node", "bun", "deno", "python", "python3"].contains(name)
                || name.hasPrefix("python3.")
            processes.append(ProcessSnapshot(
                pid: pid, processGroup: group, executablePath: executablePath,
                arguments: interpreter ? invocationTokens(pid: pid) : []
            ))
        }
        guard tcgetpgrp(descriptor) == group else { return nil }
        return Snapshot(foregroundGroup: group, processes: processes)
    }

    /// Bounded kernel read; retain only argv[0...2] for interpreter identity.
    /// No `ps args` output, logging, or returned argument evidence.
    private static func invocationTokens(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size, size <= 256 * 1024 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard success == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        // First NUL-terminated field is executable path; padding follows.
        while cursor < size, bytes[cursor] != 0 { cursor += 1 }
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        var tokens: [String] = []
        for _ in 0..<min(Int(argc), 3) {
            let start = cursor
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < size, let token = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return [] }
            tokens.append(token)
            cursor += 1
        }
        return tokens
    }
}
