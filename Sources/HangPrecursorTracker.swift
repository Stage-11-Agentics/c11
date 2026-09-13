import Foundation

/// Cross-episode memory for the main-thread watchdog.
///
/// `MainThreadHangMonitor` judges each stall in isolation: it classifies the
/// episode, writes it to the local log, and — if the episode is long enough —
/// sends one Sentry event. Nothing looks across episodes. So a wedge that
/// announces itself first, as a run of short stalls with one identical cause,
/// reaches nobody until the long one lands.
///
/// That is not hypothetical. Before the 25-minute stall behind C11-209 the hang
/// log held seven episodes of 2.4s to 10.7s sharing a fingerprint. Every one was
/// recorded; not one was reported, because each was individually below the
/// threshold. The prediction was already in the data.
///
/// This tracker is that missing memory: a bounded, time-windowed ring of
/// completed episodes that fires a `Precursor` when the same fingerprint repeats
/// often enough to be a pattern rather than a coincidence.
///
/// Pure value type with an injected clock (callers pass `systemUptime`), so the
/// policy is testable without threads or a wall clock. Constant work per
/// episode: the ring is capped at `maxEntries`, so pruning and counting are
/// bounded regardless of how long the process has been running.
///
/// Called only from the watchdog thread, which handles episodes serially.
struct HangPrecursorTracker {

    /// One completed hang episode, keyed by the signature that classified it.
    private struct Entry {
        let key: String
        let durationMs: Double
        /// `systemUptime` at which the episode ended. Monotonic, so the window
        /// can be pruned from the front.
        let endUptime: Double
    }

    /// A run of same-fingerprint episodes worth warning about.
    struct Precursor: Equatable {
        /// The shared signature fingerprint, verbatim from
        /// `MainThreadHangDescriptor.fingerprint` — so a precursor and the wedge
        /// it predicts group together downstream.
        let fingerprint: [String]
        let cause: String
        /// Deepest own-binary frame from the most recent episode in the run.
        /// Best-effort; nil whenever no capture reached our code.
        let culprit: String?
        /// How many episodes in the run (always ≥ `threshold`).
        let count: Int
        /// The tracker's window, so a consumer reading only the payload knows
        /// what "within the window" meant.
        let windowMs: Int
        /// Durations of the counted episodes, oldest first.
        let durationsMs: [Int]
        /// Wall span from the first counted episode's end to the last's.
        let spanMs: Int
    }

    /// How many same-fingerprint episodes inside the window make a pattern.
    ///
    /// Three, not two: two short stalls with one cause is an ordinary bad minute
    /// (a slow first paint, a cold cache), and firing on it would spend Sentry
    /// hang budget on noise. Three inside ten minutes is a repeat.
    let threshold: Int
    /// How far back the run may reach. Ten minutes is long enough to hold the
    /// C11-209 precursor run and short enough that a warning still describes
    /// what the machine is doing now rather than an hour ago.
    let windowSeconds: Double
    /// Hard cap on retained episodes. A pathological beachball storm cannot grow
    /// this ring, so the per-episode cost stays constant.
    let maxEntries: Int

    private var entries: [Entry] = []
    /// Per-fingerprint uptime of the last precursor fired, so a single run
    /// produces a single warning instead of one per subsequent episode.
    private var lastFired: [String: Double] = [:]

    init(threshold: Int = 3, windowSeconds: Double = 600, maxEntries: Int = 64) {
        self.threshold = max(1, threshold)
        self.windowSeconds = max(0, windowSeconds)
        self.maxEntries = max(1, maxEntries)
        entries.reserveCapacity(self.maxEntries)
    }

    /// Record one completed episode and report whether it completes a run.
    ///
    /// - Parameters:
    ///   - fingerprint: the episode's `MainThreadHangDescriptor.fingerprint`.
    ///   - cause: the descriptor's cause. Causes
    ///     `MainThreadHangMonitor.isWorthReporting` rejects (today: only
    ///     `runloop-idle`) are dropped outright — not counted, not stored. An
    ///     idle main thread repeating is exactly what an idle main thread does;
    ///     a run of them predicts nothing.
    ///   - culprit: the descriptor's culprit, carried through to the payload.
    ///   - durationMs: how long the episode lasted.
    ///   - nowUptime: `ProcessInfo.processInfo.systemUptime` at recovery.
    /// - Returns: a `Precursor` on the episode that completes a run, `nil`
    ///   otherwise. At most one per fingerprint per window.
    mutating func record(
        fingerprint: [String],
        cause: String,
        culprit: String?,
        durationMs: Double,
        nowUptime: Double
    ) -> Precursor? {
        guard MainThreadHangMonitor.isWorthReporting(cause: cause) else { return nil }
        guard !fingerprint.isEmpty else { return nil }

        let key = fingerprint.joined(separator: "\u{1F}")
        prune(nowUptime: nowUptime)
        entries.append(Entry(key: key, durationMs: durationMs, endUptime: nowUptime))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }

        // Already warned about this fingerprint and the window has not yet slid
        // past that warning: one run, one signal.
        if let firedAt = lastFired[key], nowUptime - firedAt < windowSeconds { return nil }

        let run = entries.filter { $0.key == key }
        guard run.count >= threshold else { return nil }

        lastFired[key] = nowUptime
        pruneFiredMarks(nowUptime: nowUptime)

        let first = run.first?.endUptime ?? nowUptime
        return Precursor(
            fingerprint: fingerprint,
            cause: cause,
            culprit: culprit,
            count: run.count,
            windowMs: Int((windowSeconds * 1000.0).rounded()),
            durationsMs: run.map { Int($0.durationMs.rounded()) },
            spanMs: Int(((nowUptime - first) * 1000.0).rounded())
        )
    }

    /// Drop episodes that have fallen out of the window. Entries are appended in
    /// uptime order, so the expired ones are always a prefix.
    private mutating func prune(nowUptime: Double) {
        let cutoff = nowUptime - windowSeconds
        guard let firstLive = entries.firstIndex(where: { $0.endUptime > cutoff }) else {
            entries.removeAll(keepingCapacity: true)
            return
        }
        if firstLive > 0 { entries.removeFirst(firstLive) }
    }

    /// Forget fire marks that can no longer suppress anything, so the dictionary
    /// cannot grow without bound across a long-lived process.
    private mutating func pruneFiredMarks(nowUptime: Double) {
        guard lastFired.count > maxEntries else { return }
        let cutoff = nowUptime - windowSeconds
        lastFired = lastFired.filter { $0.value > cutoff }
    }

    /// Test-only introspection: episodes currently retained.
    var retainedCount: Int { entries.count }
}
