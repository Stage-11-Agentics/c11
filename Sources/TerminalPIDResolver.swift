import Darwin
import Foundation

/// C11-25 fix DoD #5 closure: resolves a terminal's controlling-TTY
/// name (e.g. `ttys012` or `/dev/ttys012`) to the PID of the foreground
/// process running on it. Used by `SurfaceMetricsSampler` to give
/// terminal surfaces (not just browsers) live CPU/RSS in the sidebar.
///
/// Implementation: stat the tty path to read `st_rdev`, then enumerate
/// processes via `proc_listpids` + `proc_pidinfo(PROC_PIDTBSDINFO)` and
/// match `pbi_tdev`. When multiple processes share the controlling tty
/// (shell + foreground child), the highest PID is selected — the
/// most-recently spawned process, which is typically the active
/// foreground command (`make`, `top`, etc.). When the surface is idle
/// at the shell prompt, the shell itself is the only match and is
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

    /// Walk every running process; return the highest PID whose
    /// controlling tty matches `dev`. O(n) over running processes — the
    /// sampler amortizes this by only re-resolving every couple of
    /// seconds rather than every tick.
    static func foregroundPID(forDevice dev: dev_t) -> pid_t? {
        let byteSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteSize > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        let capacity = Int(byteSize) / stride
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(buf.count * stride))
        }
        guard written > 0 else { return nil }
        let count = min(capacity, Int(written) / stride)

        // e_tdev is uint32_t (controlling tty dev on proc_bsdinfo); dev_t on
        // Darwin is int32_t. Compare as bit-equal raw pattern via
        // `truncatingIfNeeded` so a sign extension can't mismatch and a
        // future Swift bridging change wouldn't trap on negative-looking
        // values.
        let target = UInt32(truncatingIfNeeded: dev)
        var bestPID: pid_t = 0
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
            guard rc == infoSize else { continue }
            if info.e_tdev == target && pid > bestPID {
                bestPID = pid
            }
        }
        return bestPID > 0 ? bestPID : nil
    }
}
