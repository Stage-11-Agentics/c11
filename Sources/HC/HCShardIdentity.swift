import Darwin
import Foundation

/// Which hc session (shard) a diagnostic belongs to. A shard is one hc session
/// with its own core, holder and socket. The pool is `c11-s1` ... `c11-s8`
/// (dev builds `c11-<tag>-s<N>`), plus the legacy `c11` session as shard 0
/// (`docs`: hc-shards-c11.md). Pure: no socket, no kernel.
struct HCShardIdentity: Hashable, Sendable {
    /// The hc session name, as `HCLaunchConfiguration.session` carries it.
    let session: String
    /// 0 is the legacy shard (the session without a pool suffix); 1...8 are pool shards.
    let index: Int

    static let poolSize = 8
    /// The release session before any pool exists: the single session of today's build.
    static let legacyDefault = HCShardIdentity(session: "c11", index: 0)

    /// A trailing `-s<N>` with N in 1...poolSize is a pool shard; any other
    /// session name (`c11`, `c11-<tag>`) is shard 0. A dev tag that itself
    /// ends in `-s3` reads as shard 3: tags that end that way are reserved.
    static func parse(session: String) -> HCShardIdentity {
        if let range = session.range(of: #"-s([1-9][0-9]*)$"#, options: .regularExpression) {
            let digits = session[range].dropFirst(2)
            if let index = Int(digits), (1...poolSize).contains(index) {
                return HCShardIdentity(session: session, index: index)
            }
        }
        return HCShardIdentity(session: session, index: 0)
    }

    var isLegacy: Bool { index == 0 }

    /// C11H-391: the links session of an adopted app (`HCShardID.links`). Its
    /// name parses as shard 0 (it is the converged shard 0), so the pool
    /// passes this identity rather than `parse`.
    static func links(session: String) -> HCShardIdentity {
        HCShardIdentity(session: session, index: HCShardID.links.index)
    }

    var isLinks: Bool { index == HCShardID.links.index }

    /// `shard 0 (legacy)`, `shard 3`, `links (c11)`.
    var label: String { isLinks ? "links (c11)" : isLegacy ? "shard 0 (legacy)" : "shard \(index)" }
}

extension HCShard {
    /// The diagnostics identity of this pool member (C11H-391: the links session is its own).
    var diagnosticsIdentity: HCShardIdentity {
        id.isLinks ? .links(session: name) : HCShardIdentity.parse(session: name)
    }
}

/// The holder of a shard is the process that parents every local terminal's
/// root process. The inventory carries no holder field, so the recorder asks
/// the kernel about one live terminal's root pid, once, and remembers the
/// answer: after a holder kill the terminals are gone and so is the answer.
enum HCShardHolder {
    /// `parentOf` returns the parent pid of a process, or nil when it is gone.
    static func holderPID(
        terminalPIDs: [Int32],
        parentOf: (Int32) -> Int32?
    ) -> Int32? {
        var holder: Int32?
        for pid in terminalPIDs where pid > 0 {
            guard let parent = parentOf(pid), parent > 1 else { return nil }
            if let holder, holder != parent { return nil }
            holder = parent
        }
        return holder
    }

    /// The kernel's answer for `parentOf`. Read-only, no signal.
    /// C11H-205: `proc_pidinfo` refuses a process under another effective uid,
    /// which a terminal opened before C11H-232 roots at (setuid-root `/usr/bin/login`), so the
    /// `sysctl(KERN_PROC_PID)` read answers when it does not.
    static func kernelParent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 0 {
            return Int32(info.pbi_ppid)
        }
        guard let parent = HCLocalProcess.readKernelProcess(pid)?.parentPID, parent > 0 else { return nil }
        return parent
    }
}
