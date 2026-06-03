import Foundation
#if DEBUG
import Bonsplit
#endif

/// Periodically probes whether c11 has Full Disk Access while the TCC primer
/// is up. Runs the probe off-main on a private utility queue. When the probe
/// observes a successful grant, the probe self-cancels and invokes
/// `onGranted` once on the main queue.
///
/// The probe never touches AppKit focus state; the auto-advance close path
/// in `AppDelegate` is responsible for transitioning the primer sheet and
/// closing the window without reactivating the app.
final class FullDiskAccessProbe {

    typealias Probe = () -> Bool
    typealias Granted = () -> Void
    typealias DelayObserver = (TimeInterval) -> Void

    /// Default backoff schedule, in seconds. The final value repeats
    /// indefinitely until the probe is cancelled or grants. Combined with
    /// the `didBecomeActive` kick from AppDelegate, the 10s ceiling is
    /// effectively a soft cap: most users see <1s detection latency.
    static let defaultSchedule: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0, 10.0]

    private let probe: Probe
    private let scheduleDelays: [TimeInterval]
    private let queue: DispatchQueue
    private let onScheduled: DelayObserver?
    private let onGranted: Granted

    private var timer: DispatchSourceTimer?
    private var attemptIndex: Int = 0
    private var started: Bool = false
    private var stopped: Bool = false

    init(
        probe: @escaping Probe = FullDiskAccessProbe.readsTCCDb,
        schedule: [TimeInterval] = FullDiskAccessProbe.defaultSchedule,
        queue: DispatchQueue = DispatchQueue(
            label: "com.stage11.c11.fda-probe",
            qos: .utility
        ),
        onScheduled: DelayObserver? = nil,
        onGranted: @escaping Granted
    ) {
        precondition(!schedule.isEmpty, "FullDiskAccessProbe schedule must not be empty")
        self.probe = probe
        self.scheduleDelays = schedule
        self.queue = queue
        self.onScheduled = onScheduled
        self.onGranted = onGranted
    }

    /// Begin probing. Idempotent — repeated calls before `stop()` are no-ops.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.scheduleNextTick()
        }
    }

    /// Cancel any pending tick and prevent future ticks. Idempotent.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Fire one extra probe attempt soon, without resetting `attemptIndex`
    /// or cancelling the running backoff timer. Used to re-arm after the
    /// app reactivates from System Settings so we get a fast detection
    /// rather than waiting up to the schedule's ceiling.
    func kick() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.runProbe(viaKick: true)
        }
    }

    private func tick() {
        guard !stopped else { return }
        runProbe(viaKick: false)
    }

    private func runProbe(viaKick: Bool) {
        guard !stopped else { return }
        let result = probe()
        #if DEBUG
        dlog("fda.probe.tick attempt=\(attemptIndex) kick=\(viaKick ? 1 : 0) result=\(result ? 1 : 0)")
        #endif
        if result {
            stopped = true
            timer?.cancel()
            timer = nil
            DispatchQueue.main.async { [onGranted] in
                onGranted()
            }
            return
        }
        guard !viaKick else { return }
        attemptIndex += 1
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        guard !stopped else { return }
        let delay = Self.nextDelay(forAttempt: attemptIndex, schedule: scheduleDelays)
        onScheduled?(delay)
        let nextTimer = DispatchSource.makeTimerSource(queue: queue)
        nextTimer.schedule(deadline: .now() + delay)
        nextTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer?.cancel()
        timer = nextTimer
        nextTimer.resume()
    }

    /// Pure backoff calculation. Clamps to the last schedule entry once
    /// `index` runs past the array end so the ceiling repeats indefinitely.
    static func nextDelay(forAttempt index: Int, schedule: [TimeInterval]) -> TimeInterval {
        let clamped = max(0, min(index, schedule.count - 1))
        return schedule[clamped]
    }

    /// Probe path: open the TCC database for reading and read one byte.
    /// Without FDA, `FileHandle(forReadingFrom:)` throws EPERM. With FDA,
    /// init succeeds and the read returns one byte. There is no documented
    /// in-between case where FDA is denied but the read succeeds, so this
    /// is unambiguous as a grant signal.
    static func readsTCCDb() -> Bool {
        let raw = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: raw)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 1)
            return (head?.count ?? 0) > 0
        } catch {
            return false
        }
    }
}
