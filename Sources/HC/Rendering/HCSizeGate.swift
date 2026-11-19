import Foundation

/// Workaround for hc starting every PTY at its headless size (SPIKE-0B
/// defect 6; matrix T5.8). hc 0.1.16's `terminal.run` takes no size and opens
/// the PTY at the shared config's `headless` (200x120 by default), which c11
/// reads but never edits. zsh then draws its first PROMPT_SP filler for 200
/// columns before the attach RESIZE lands, leaving a long blank `%` line.
///
/// The gate is a few lines of `/bin/sh` placed in front of a **new local**
/// terminal's argv (2C calls `wrapNewTerminalArgv` for those only; never for
/// a reattach, a resume or a remote machine). It waits until the PTY has the
/// panel's size, for at most `boundSeconds`, then `exec`s the original argv
/// unchanged: same pid, same argv, same environment. Input that arrives
/// meanwhile stays in the tty and is read by the program after exec.
///
/// Order matters: the WINCH trap is installed before the size is checked, so
/// a RESIZE landing between the two still wakes the gate.
enum HCSizeGate {
    static let boundSeconds = 1
    static let argv0 = "c11-size-gate"
    static let headlessDefault = HCGridSize(columns: 200, rows: 120)

    /// `$1` = wanted `rows cols` (may be empty), `$2` = headless `rows cols`,
    /// `$3` = bound in seconds, then the program's argv. It waits only while
    /// the PTY still has the headless size and the panel wants another one;
    /// no tty, a size already moved, or a panel that is itself headless-sized
    /// execs at once. The bound's `sleep` is killed before exec, so no stray
    /// process outlives the gate.
    static let script = """
    want=$1; headless=$2; bound=$3; shift 3
    trap 'trap - WINCH; [ -n "$t" ] && kill "$t" 2>/dev/null; exec "$@"' WINCH
    size=$(stty size 2>/dev/null)
    if [ -z "$size" ] || [ "$size" = "$want" ] || [ "$size" != "$headless" ]; then trap - WINCH; exec "$@"; fi
    sleep "$bound" & t=$!
    wait "$t"
    trap - WINCH
    exec "$@"
    """

    /// - Parameters:
    ///   - argv: the program c11 already chose (shell or command), unchanged.
    ///   - panelGrid: the panel's grid when known; without it the gate waits
    ///     for the size to leave the headless size.
    static func wrap(
        _ argv: [String],
        panelGrid: HCGridSize?,
        headless: HCGridSize = HCSizeGate.headlessDefault,
        boundSeconds: Int = HCSizeGate.boundSeconds
    ) -> [String] {
        guard !argv.isEmpty, argv.first?.isEmpty == false else { return argv }
        // Already gated (a retry with the same request): never nest.
        if argv.count > 2, argv[0] == "/bin/sh", argv[1] == "-c", argv[2] == script { return argv }
        let want = panelGrid.map { "\($0.rows) \($0.columns)" } ?? ""
        return ["/bin/sh", "-c", script, argv0, want, "\(headless.rows) \(headless.columns)", String(boundSeconds)] + argv
    }
}
