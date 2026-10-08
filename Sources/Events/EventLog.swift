import Foundation
import Darwin

/// Append-only NDJSON writer for the c11 events stream (C11-163). Cloned from
/// `MailboxDispatchLog`: writes ride a dedicated serial `.utility` queue so the
/// emitting path fire-and-forgets; `flush()` blocks until the queue drains for
/// tests and shutdown. Two things this adds over the mailbox log:
///
/// - **Monotonic `seq`** assigned on the queue (the single ordering authority),
///   so file order and `seq` order always agree even under concurrent emits
///   (EVT-1).
/// - **Size-capped rotation** (EVT-4): at the cap the current file rolls to
///   `.1`, older generations are retained within age and total-byte bounds, and a `log.rotated` marker is written as
///   the first line of the fresh file so consumers detect the boundary.
///
/// Non-blocking under a slow/full disk (EVT-3): `append` never touches the disk
/// on the caller thread, and a bounded in-flight cap drops rather than growing
/// memory without bound — drops surface in-stream as a `log.dropped` marker.
final class EventLog {

    /// Posted on the log's utility queue after a line has been handed to the
    /// file handle. Consumers such as the messages page use it to debounce
    /// their own off-main rebuild without adding work to event emitters.
    static let eventWrittenNotification = Notification.Name("com.stage11.c11.event-log-line-written")

    let url: URL
    private let instance: String
    private let sizeCap: Int
    private let maxPending: Int
    private let totalSizeCap: Int
    private var retentionDays = 14
    private let titleWindow: TimeInterval
    private let maxTitlePanels: Int
    private struct TitleWindow {
        let started: Date
        var latest: EventEnvelope
        var count: Int
    }
    private var titles: [String: TitleWindow] = [:]
    private var nextTitleExpiry = Date.distantFuture
    private var knownHistoryBytes = 0
    private var historyInitialized = false
    private var historyLockFD: Int32 = -1
    private var sampleTimer: DispatchSourceTimer?
    private var sampleProvider: (() -> EventEnvelope?)?
    private var samplingAsleep = false
    private var recordingEnabled = true
    private var analyticsEnabled = true
    private let now: () -> Date
    private let healthMetrics: () -> [String: Any]

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
        totalSizeCap: Int = 64 * 1024 * 1024,
        retentionDays: Int = 14,
        titleWindow: TimeInterval = 60,
        maxTitlePanels: Int = 4096,
        now: @escaping () -> Date = { Date() },
        healthMetrics: @escaping () -> [String: Any] = ActivityHistoryMetrics.sample,
        label: String = "com.stage11.c11.events.log"
    ) {
        self.url = url
        self.instance = instance
        self.sizeCap = max(1, min(sizeCap, totalSizeCap / 2))
        self.maxPending = maxPending
        self.totalSizeCap = max(1, totalSizeCap)
        self.retentionDays = retentionDays
        self.titleWindow = titleWindow
        self.maxTitlePanels = max(1, maxTitlePanels)
        self.now = now
        self.healthMetrics = healthMetrics
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        sampleTimer?.cancel()
        if historyLockFD >= 0 { Darwin.close(historyLockFD) }
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
            self.process(envelope)
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
            self?.pruneHistory()
            self?.writeAssigningSeq(env)
        }
    }

    /// Blocks until all previously-enqueued appends have completed. For tests
    /// and shutdown. Never call from within `queue`.
    func flush() {
        waitForQueue { self.flushTitles() }
    }

    /// Settings changes are rare and become one ordered queue mutation.
    func updatePolicy(_ policy: ActivityHistoryPolicy) {
        queue.async { [weak self] in
            guard let self else { return }
            self.recordingEnabled = policy.enabled
            self.analyticsEnabled = policy.analyticsEnabled
            self.retentionDays = policy.retentionDays
            if !policy.enabled { self.titles.removeAll(); self.nextTitleExpiry = .distantFuture }
            if policy.enabled { self.pruneHistory() }
            if !policy.enabled || !policy.analyticsEnabled {
                self.sampleTimer?.cancel()
                self.sampleTimer = nil
            } else { self.scheduleSampling() }
        }
    }

    /// The sole new timer. It runs on the existing writer queue and has one
    /// minute of leeway. Sleep cancels the source and wake schedules a fresh
    /// ten-minute interval, so no catch-up samples run after a long sleep.
    func startSampling(_ provider: @escaping () -> EventEnvelope?) {
        queue.async { [weak self] in
            self?.sampleProvider = provider
            self?.scheduleSampling()
        }
    }

    private func scheduleSampling() {
        guard sampleTimer == nil, !samplingAsleep, recordingEnabled, analyticsEnabled, sampleProvider != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 600, repeating: 600, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.sampleNow() }
        sampleTimer = timer
        timer.resume()
    }

    func setSamplingAsleep(_ asleep: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.samplingAsleep = asleep
            if asleep { self.sampleTimer?.cancel(); self.sampleTimer = nil }
            else { self.scheduleSampling() }
        }
    }

    func stopSampling() {
        waitForQueue {
            self.sampleTimer?.cancel()
            self.sampleTimer = nil
            self.sampleProvider = nil
        }
    }

    func finishSampling(_ provider: @escaping () -> EventEnvelope?) {
        waitForQueue {
            self.sampleTimer?.cancel()
            self.sampleTimer = nil
            self.sampleProvider = nil
            self.flushTitles()
            if self.recordingEnabled, self.analyticsEnabled, let event = provider() { self.writeAssigningSeq(event) }
            if self.recordingEnabled { self.pruneHistory() }
        }
    }

    /// Deterministic behavioral seam: uses the exact timer path, without sleeps.
    func sampleForTesting() { waitForQueue { self.sampleNow() } }

    /// DispatchQueue.sync may execute its body on the calling main thread.
    /// Enqueue then wait only at explicit drain/shutdown seams, so metrics,
    /// title-tail serialization and disk I/O always execute off-main.
    private func waitForQueue(_ body: @escaping () -> Void) {
        let completion = DispatchSemaphore(value: 0)
        queue.async {
            body()
            completion.signal()
        }
        completion.wait()
    }

    private func sampleNow() {
        guard !samplingAsleep else { return }
        flushTitles(expiredOnly: true)
        if recordingEnabled, analyticsEnabled, let event = sampleProvider?() { writeAssigningSeq(event) }
        pruneHistory()
    }

    // MARK: - Queue-confined writing

    private func process(_ envelope: EventEnvelope) {
        guard recordingEnabled else { return }
        if now() >= nextTitleExpiry { flushTitles(expiredOnly: true) }
        if envelope.type == EventEnvelope.EventType.surfaceClosed.rawValue {
            flushTitles(panel: envelope.surface)
        }
        if envelope.type == EventEnvelope.EventType.metadataChanged.rawValue,
           envelope.payload["key"] as? String == "title",
           envelope.payload["source"] as? String == "osc",
           let panel = envelope.surface, let title = envelope.payload["value"] as? String {
            let key = panel + ":" + (envelope.payload["scope"] as? String ?? "panel")
            let canonical = Self.titleWithoutStatusGlyphs(title)
            if let prior = envelope.payload["prior"] as? String,
               Self.titleWithoutStatusGlyphs(prior) == canonical { return }
            if var pending = titles[key] {
                // Spinner-only title changes never become log records.
                guard Self.titleWithoutStatusGlyphs(pending.latest.payload["value"] as? String ?? "") != canonical else { return }
                pending.latest = envelope
                pending.count += 1
                titles[key] = pending
                return
            }
            if titles.count >= maxTitlePanels, let oldest = titles.min(by: { $0.value.started < $1.value.started })?.key {
                flushTitle(oldest)
            }
            let started = now()
            titles[key] = TitleWindow(started: started, latest: envelope, count: 1)
            nextTitleExpiry = min(nextTitleExpiry, started.addingTimeInterval(titleWindow))
        }
        if envelope.type == EventEnvelope.EventType.hangPrecursor.rawValue {
            var payload = envelope.payload
            if analyticsEnabled, payload["app_active"] != nil {
                payload["rss_mb"] = healthMetrics()["rss_mb"] ?? NSNull()
            } else {
                payload.removeValue(forKey: "app_active")
                payload.removeValue(forKey: "screen_locked")
                payload.removeValue(forKey: "rss_mb")
            }
            writeAssigningSeq(EventEnvelope(type: envelope.type, instance: envelope.instance, ts: envelope.ts,
                                           workspace: envelope.workspace, surface: envelope.surface, pane: envelope.pane, payload: payload))
        } else { writeAssigningSeq(envelope) }
    }

    private func flushTitle(_ key: String) {
        guard let state = titles.removeValue(forKey: key), state.count > 1 else { return }
        let event = state.latest
        var payload = event.payload
        payload["title_change_count"] = state.count
        writeAssigningSeq(EventEnvelope(type: event.type, instance: event.instance, ts: event.ts,
                                       workspace: event.workspace, surface: event.surface, pane: event.pane, payload: payload))
    }

    private func flushTitles(expiredOnly: Bool = false, panel: String? = nil) {
        let date = now()
        let keys = titles.filter { _, state in
            if let panel { return state.latest.surface == panel }
            return !expiredOnly || date.timeIntervalSince(state.started) >= titleWindow
        }.sorted { $0.value.started < $1.value.started }.map(\.key)
        for key in keys { flushTitle(key) }
        nextTitleExpiry = titles.values.map { $0.started.addingTimeInterval(titleWindow) }.min() ?? .distantFuture
    }

    private static func titleWithoutStatusGlyphs(_ title: String) -> String {
        var scalars = title.unicodeScalars[...]
        while let first = scalars.first {
            let category = first.properties.generalCategory
            let glyph = category == .otherSymbol || category == .mathSymbol || category == .modifierSymbol
                || first.value == 0xFE0F || first.value == 0x200D
                || (0x2800...0x28FF).contains(first.value)
            if glyph || CharacterSet.whitespaces.contains(first) { scalars = scalars.dropFirst() }
            else { break }
        }
        return String(String.UnicodeScalarView(scalars))
    }


    private func writeAssigningSeq(_ envelope: EventEnvelope) {
        nextSeq &+= 1
        let line = envelope.serialize(seq: nextSeq)
        writeLine(line)
        NotificationCenter.default.post(
            name: Self.eventWrittenNotification,
            object: envelope.type,
            userInfo: ["seq": nextSeq]
        )
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
                // A single record larger than the whole configured budget
                // cannot be retained while honoring that budget.
                guard data.count <= totalSizeCap else { return }
                try withHistoryLock {
                    // Writers in separate c11 processes share this directory.
                    // Reconcile the budget under the same advisory lock as the
                    // append, so two fresh cached totals cannot both spend it.
                    pruneHistoryLocked(reserving: data.count)
                    guard knownHistoryBytes + data.count <= totalSizeCap else { return }
                    try fileHandle?.write(contentsOf: data)
                    knownHistoryBytes += data.count
                }
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
        if !historyInitialized { pruneHistory() }
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
        // Plain renames only. Numbered generations preserve the `.1` tail
        // compatibility contract; newest is always `.1`.
        // historyFiles enumerates exactly this directory. Match filenames,
        // because Foundation can return /private/var aliases for a /var URL.
        let generationPrefix = url.lastPathComponent + "."
        let generations = historyFiles().filter { $0.lastPathComponent.hasPrefix(generationPrefix) }
        let numbered = generations.compactMap { item -> (URL, Int)? in
            guard let number = Int(item.lastPathComponent.dropFirst(generationPrefix.count)) else { return nil }
            return (item, number)
        }.sorted { $0.1 > $1.1 }
        for (item, number) in numbered {
            try? fm.moveItem(at: item, to: URL(fileURLWithPath: url.path + "." + String(number + 1)))
        }
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
        pruneHistory()
    }

    private func historyFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])) ?? []
        return files.filter { item in
            let name = item.lastPathComponent
            // Only event files in this dedicated directory. Custom test paths
            // are supported without granting deletion of unrelated artifacts.
            if EventLogLayout.isLogFileName(name) { return true }
            if name == url.lastPathComponent { return true }
            let ownPrefix = url.lastPathComponent + "."
            guard name.hasPrefix(ownPrefix), let generation = Int(name.dropFirst(ownPrefix.count)) else { return false }
            return generation > 0
        }
    }

    /// Shared-directory coordination is confined to the writer queue and only
    /// surviving records take the lock. Suppressed spinner frames do no I/O.
    /// No ledger, polling, or new timer is needed for the cross-process budget.
    private func withHistoryLock(_ body: () throws -> Void) rethrows {
        if historyLockFD < 0 {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            historyLockFD = Darwin.open(directory.appendingPathComponent(".activity-history.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard historyLockFD >= 0, flock(historyLockFD, LOCK_EX) == 0 else { return }
        defer { flock(historyLockFD, LOCK_UN) }
        try body()
    }

    private func pruneHistory(reserving bytes: Int = 0) {
        withHistoryLock { pruneHistoryLocked(reserving: bytes) }
    }

    private func pruneHistoryLocked(reserving bytes: Int = 0) {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var entries = historyFiles().compactMap { item -> (URL, Date, Int)? in
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (item, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        func isProtected(_ item: URL) -> Bool {
            // Every item comes from this writer's directory; filename is its
            // identity even when directory symlink spellings differ.
            if item.lastPathComponent == url.lastPathComponent { return true }
            // Never unlink another live instance's current file. Its writer
            // enforces the same shared budget as it next rotates/samples.
            guard item.pathExtension == "ndjson",
                  let pidText = item.deletingPathExtension().lastPathComponent.split(separator: "-").last,
                  let pid = Int32(pidText) else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
        for entry in entries where entry.1 < cutoff && !isProtected(entry.0) {
            try? fm.removeItem(at: entry.0)
        }
        entries.removeAll { !fm.fileExists(atPath: $0.0.path) }
        var total = entries.reduce(0) { $0 + $1.2 }
        for entry in entries where total + bytes > totalSizeCap && !isProtected(entry.0) {
            do { try fm.removeItem(at: entry.0); total -= entry.2 } catch { }
        }
        knownHistoryBytes = total
        historyInitialized = true
    }
}
