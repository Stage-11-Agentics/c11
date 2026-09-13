import Darwin
import Foundation

/// C11-25 fix DoD #5 closure: resolves a terminal's controlling-TTY
/// name (e.g. `ttys012` or `/dev/ttys012`) to the PID of the foreground
/// process running on it. Used by `SurfaceMetricsSampler` to give
/// terminal surfaces (not just browsers) live CPU/RSS in the sidebar.
///
/// Implementation: stat the tty path to read `st_rdev`, then ask the
/// kernel for just the pids whose controlling tty is that device via
/// `proc_listpids(PROC_TTY_ONLY, dev)`. When multiple processes share
/// the controlling tty (shell + foreground child), the highest PID is
/// selected — the most-recently spawned process, which is typically the
/// active foreground command (`make`, `top`, etc.). When the surface is
/// idle at the shell prompt, the shell itself is the only match and is
/// returned.
///
/// Thread-safety: pure C-API; touches no AppKit / main-actor state.
/// Safe to invoke off-main from the sampler's utility queue.
enum TerminalPIDResolver {
    /// Look up the foreground PID for `ttyName`. Returns `nil` when the
    /// tty path can't be stat'd (e.g. the surface has not yet reported
    /// its tty via `report_tty`) or when no process currently has the
    /// tty as its controlling terminal.
    static func foregroundPID(forTTYName ttyName: String) -> pid_t? {
        guard let dev = ttyDevice(for: ttyName) else { return nil }
        return foregroundPID(forDevice: dev)
    }

    /// Resolve `ttyName` to its `st_rdev`. Exposed so callers (and
    /// tests) can hold the device number across calls and skip the
    /// per-tick `stat` syscall.
    static func ttyDevice(for ttyName: String) -> dev_t? {
        let path = ttyName.hasPrefix("/") ? ttyName : "/dev/\(ttyName)"
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_rdev
    }

    /// Return the highest PID whose controlling tty is `dev`, or `nil`
    /// when no process has that tty.
    ///
    /// C11-224: this used to be `proc_listpids(PROC_ALL_PIDS)` followed by
    /// `proc_pidinfo(PROC_PIDTBSDINFO)` on every pid on the machine to
    /// compare `e_tdev` ourselves — O(processes) syscalls per terminal per
    /// refresh, which with 38 terminals and ~1160 processes pinned an
    /// E-core at 99% in `__proc_info` and contended the kernel proc-list
    /// lock with every fork/exec on the box. `PROC_TTY_ONLY` takes the tty
    /// `dev_t` as `typeinfo` and does the filtering in one syscall, so the
    /// cost is O(pids on this tty), typically one or two.
    static func foregroundPID(forDevice dev: dev_t) -> pid_t? {
        let type = UInt32(PROC_TTY_ONLY)
        // `typeinfo` is uint32_t; dev_t is int32_t on Darwin. Pass the raw
        // bit pattern rather than a value conversion so a high-bit device
        // number can't trap.
        let typeinfo = UInt32(truncatingIfNeeded: dev)
        let byteSize = proc_listpids(type, typeinfo, nil, 0)
        guard byteSize > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        // The size probe reports the whole pid table, not the filtered
        // count; the buffer is sized from it so the filtered write can
        // never truncate, but the filtered result is far shorter.
        let capacity = Int(byteSize) / stride
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(type, typeinfo, buf.baseAddress, Int32(buf.count * stride))
        }
        guard written > 0 else { return nil }
        let count = min(capacity, Int(written) / stride)

        var bestPID: pid_t = 0
        for i in 0..<count where pids[i] > bestPID {
            bestPID = pids[i]
        }
        return bestPID > 0 ? bestPID : nil
    }
}
