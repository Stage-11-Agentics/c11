import Foundation

/// Implements `screenCurrent(after:)` for one attachment (contract L5; the
/// typed hook ticket 2 declares and ticket 5 proves).
///
/// A receipt is issued only when all of these hold at once:
/// - the request names this attachment's generation;
/// - the display state sent to hc has reached the requested display
///   generation;
/// - the paint scanner has parsed a complete paint (`HCPaintBoundaryScanner`);
/// - the grid last sent to hc equals the grid the surface reported.
///
/// Otherwise the call waits, bounded by `HCLimits.screenSeconds`, and then
/// returns nil (the consumer reports `screenUnavailable`). Nothing here is
/// timer-, attach-reply- or `terminal.read`-based readiness: time can only
/// turn a pending wait into nil.
///
/// Thread-safe. `didParse` runs on the panel's output lane; display and grid
/// notes come from main; waiters may be anywhere. No caller waits on a lock
/// held across native work, and nothing here enters main.
final class HCScreenTracker: HCScreenProvider, @unchecked Sendable {
    typealias Scheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    let attachmentGeneration: UInt64

    private let lock = NSLock()
    private var scanner: HCPaintBoundaryScanner
    private var sentDisplay: HCDisplayRevision?
    private var sentGrid: HCGridSize?
    private var surfaceGrid: HCGridSize?
    private var invalidated = false
    private var waiters: [UUID: Waiter] = [:]
    private let timeout: TimeInterval
    private let schedule: Scheduler
    private let onPainted: (@Sendable (UInt64) -> Void)?

    private struct Waiter {
        let revision: HCDisplayRevision
        let continuation: CheckedContinuation<HCScreenReceipt?, Never>
    }

    /// - Parameters:
    ///   - onPainted: called (off-main, outside the lock) each time a paint
    ///     completes, with the count of completed paints. Ticket 5 hangs the
    ///     reattach repaint nudge on it.
    init(
        attachmentGeneration: UInt64,
        pinVersion: String,
        timeout: TimeInterval = HCLimits.screenSeconds,
        schedule: @escaping Scheduler = { delay, work in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
        },
        onPainted: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.attachmentGeneration = attachmentGeneration
        scanner = HCPaintBoundaryScanner(pinVersion: pinVersion)
        self.timeout = timeout
        self.schedule = schedule
        self.onPainted = onPainted
    }

    // MARK: Inputs

    /// Output lane, after `ghostty_surface_process_output` returned for these
    /// bytes. Bytes from another attachment generation are ignored.
    func didParse(_ chunk: HCOutputChunk) {
        guard chunk.attachmentGeneration == attachmentGeneration else { return }
        lock.lock()
        let before = scanner.completedPaints
        scanner.scan(chunk.bytes)
        let after = scanner.completedPaints
        let ready = collectReadyLocked()
        lock.unlock()
        resume(ready)
        if after != before { onPainted?(after) }
    }

    /// Main, after the display state for `revision` was handed to hc
    /// (`attach` or `updateDisplay`).
    func noteDisplaySent(_ revision: HCDisplayRevision, grid: HCGridSize) {
        guard revision.attachmentGeneration == attachmentGeneration else { return }
        lock.lock()
        if sentDisplay.map({ revision.displayGeneration >= $0.displayGeneration }) ?? true {
            sentDisplay = revision
            sentGrid = grid
        }
        let ready = collectReadyLocked()
        lock.unlock()
        resume(ready)
    }

    /// Main, whenever Ghostty's grid for the surface settles.
    func noteSurfaceGrid(_ grid: HCGridSize) {
        lock.lock()
        surfaceGrid = grid
        let ready = collectReadyLocked()
        lock.unlock()
        resume(ready)
    }

    /// The attachment was replaced or detached: every pending and future
    /// request gets nil.
    func invalidate() {
        lock.lock()
        invalidated = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values { waiter.continuation.resume(returning: nil) }
    }

    // MARK: HCScreenProvider

    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if invalidated || revision.attachmentGeneration != attachmentGeneration {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            if let receipt = receiptLocked(for: revision) {
                lock.unlock()
                continuation.resume(returning: receipt)
                return
            }
            waiters[id] = Waiter(revision: revision, continuation: continuation)
            lock.unlock()
            schedule(timeout) { [weak self] in self?.expire(id) }
        }
    }

    /// For diagnostics and tests.
    var phase: HCPaintBoundaryScanner.Phase {
        lock.lock()
        defer { lock.unlock() }
        return scanner.phase
    }

    // MARK: Private

    private func expire(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }

    private func receiptLocked(for revision: HCDisplayRevision) -> HCScreenReceipt? {
        guard !invalidated,
              revision.attachmentGeneration == attachmentGeneration,
              case .painted = scanner.phase,
              let sent = sentDisplay, sent.displayGeneration >= revision.displayGeneration,
              let grid = sentGrid, let surface = surfaceGrid, grid == surface else { return nil }
        return HCScreenReceipt(
            revision: sent,
            parsedOutputWatermark: scanner.scannedBytes,
            columns: grid.columns,
            rows: grid.rows
        )
    }

    private func collectReadyLocked() -> [(CheckedContinuation<HCScreenReceipt?, Never>, HCScreenReceipt)] {
        guard !waiters.isEmpty else { return [] }
        var ready: [(CheckedContinuation<HCScreenReceipt?, Never>, HCScreenReceipt)] = []
        for (id, waiter) in waiters {
            if let receipt = receiptLocked(for: waiter.revision) {
                ready.append((waiter.continuation, receipt))
                waiters.removeValue(forKey: id)
            }
        }
        return ready
    }

    private func resume(_ ready: [(CheckedContinuation<HCScreenReceipt?, Never>, HCScreenReceipt)]) {
        for (continuation, receipt) in ready { continuation.resume(returning: receipt) }
    }
}
