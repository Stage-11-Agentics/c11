import Foundation

/// Append-only NDJSON writer for the c11 events stream (C11-163). Cloned from
/// `MailboxDispatchLog`: writes ride a dedicated serial `.utility` queue so the
/// emitting path fire-and-forgets; `flush()` blocks until the queue drains for
/// tests and shutdown. Two things this adds over the mailbox log:
///
/// - **Monotonic `seq`** assigned on the queue (the single ordering authority),
///   so file order and `seq` order always agree even under concurrent emits
///   (EVT-1).
/// - **Size-capped rotation** (EVT-4): at the cap the current file rolls to
///   `.1`, one generation is retained, and a `log.rotated` marker is written as
///   the first line of the fresh file so consumers detect the boundary.
///
/// Non-blocking under a slow/full disk (EVT-3): `append` never touches the disk
/// on the caller thread, and a bounded in-flight cap drops rather than growing
/// memory without bound — drops surface in-stream as a `log.dropped` marker.
final class EventLog {

    let url: URL
    private let instance: String
    private let sizeCap: Int
    private let maxPending: Int
    private let now: () -> Date

    private let queue: DispatchQueue
    private var fileHandle: FileHandle?

    /// Test seam: invoked on the writer queue immediately before each line is
    /// written. Tests install a semaphore wait here to pin the queue and prove
    /// `append` stays non-blocking + drops rather than growing (EVT-3). nil in
    /// production.
    var onQueueBeforeWrite: (() -> Void)?

    /// Assigned and read only on `queue`.
    private var nextSeq: UInt64 = 0

    /// Guards the caller-visible backpressure counters.
    private let counterLock = NSLock()
    private var pendingCount = 0
    private var droppedSinceReport = 0

    /// - Parameters:
    ///   - url: the per-instance current log path.
    ///   - instance: the per-process id embedded in every envelope + markers.
    ///   - sizeCap: bytes; the file rolls once it grows past this. Default 8 MiB.
    ///   - maxPending: max in-flight appends before drop-newest kicks in.
    init(
        url: URL,
        instance: String,
        sizeCap: Int = 8 * 1024 * 1024,
        maxPending: Int = 4096,
        now: @escaping () -> Date = { Date() },
        label: String = "com.stage11.c11.events.log"
    ) {
        self.url = url
        self.instance = instance
        self.sizeCap = sizeCap
        self.maxPending = maxPending
        self.now = now
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        try? fileHandle?.close()
    }

    // MARK: - Public API

    /// Enqueues an append; returns immediately. Drops (counted) when the
    /// in-flight queue is saturated so a stalled disk never blocks the caller.
    func append(_ envelope: EventEnvelope) {
        counterLock.lock()
        if pendingCount >= maxPending {
            droppedSinceReport += 1
            counterLock.unlock()
            return
        }
        pendingCount += 1
        counterLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.reportDropsIfNeeded()
            self.writeAssigningSeq(envelope)
            self.counterLock.lock()
            self.pendingCount -= 1
            self.counterLock.unlock()
        }
    }

    /// Writes the per-instance `log.opened` marker. Call once, eagerly, at
    /// startup so consumers see the instance boundary + seq reset.
    func open() {
        let env = EventEnvelope(
            type: .logOpened,
            instance: instance,
            ts: now(),
            payload: ["pid": ProcessInfo.processInfo.processIdentifier]
        )
        queue.async { [weak self] in
            self?.writeAssigningSeq(env)
        }
    }

    /// Blocks until all previously-enqueued appends have completed. For tests
    /// and shutdown. Never call from within `queue`.
    func flush() {
        queue.sync {}
    }

    // MARK: - Queue-confined writing

    private func writeAssigningSeq(_ envelope: EventEnvelope) {
        nextSeq &+= 1
        let line = envelope.serialize(seq: nextSeq)
        writeLine(line)
        rotateIfNeeded()
    }

    /// Emits a `log.dropped` marker when the backpressure guard has shed events
    /// since the last report. Runs on `queue` ahead of the next real append.
    private func reportDropsIfNeeded() {
        counterLock.lock()
        let dropped = droppedSinceReport
        droppedSinceReport = 0
        counterLock.unlock()
        guard dropped > 0 else { return }
        let env = EventEnvelope(
            type: .logDropped,
            instance: instance,
            ts: now(),
            payload: ["count": dropped]
        )
        nextSeq &+= 1
        writeLine(env.serialize(seq: nextSeq))
    }

    private func writeLine(_ line: String) {
        onQueueBeforeWrite?()
        do {
            try ensureHandle()
            if let data = line.data(using: .utf8) {
                try fileHandle?.write(contentsOf: data)
            }
        } catch {
            // Best-effort: drop the handle so the next call reopens from scratch.
            // Log write failures are intentionally silent — observability must
            // never block or crash the emitting path.
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func ensureHandle() throws {
        if fileHandle != nil { return }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        fileHandle = fh
    }

    // MARK: - Rotation (EVT-4)

    private func rotateIfNeeded() {
        guard let fh = fileHandle else { return }
        let size = (try? fh.offset()) ?? 0
        guard size >= UInt64(sizeCap) else { return }
        rotate()
    }

    private func rotate() {
        let fm = FileManager.default
        let rolled = EventLogLayout.rolledURL(for: url)
        do {
            try fileHandle?.close()
        } catch {
            // fall through; we still attempt the rename + reopen
        }
        fileHandle = nil
        // Retain exactly one rolled generation: replace any prior `.1`.
        try? fm.removeItem(at: rolled)
        do {
            try fm.moveItem(at: url, to: rolled)
        } catch {
            // If the roll failed, keep appending to the current file rather than
            // losing events; reopen and carry on (cap will retrigger).
            return
        }
        // Fresh current file starts with a rotation marker so a consumer that
        // re-reads from the top after detecting the shrink lands on the boundary.
        let marker = EventEnvelope(
            type: .logRotated,
            instance: instance,
            ts: now(),
            payload: ["rolled_to": rolled.lastPathComponent]
        )
        nextSeq &+= 1
        writeLine(marker.serialize(seq: nextSeq))
    }
}
