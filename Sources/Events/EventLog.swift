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
    private let retentionNamespace: String
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
    private var writerLockError: Int32?
    private var retentionFailure: String?
    private var reportedRetentionDegraded = false
    private var sampleTimer: DispatchSourceTimer?
    private var nextSampleAt = Date.distantFuture
    private var nextPruneAt: Date
    private var sampleProvider: (() -> EventEnvelope?)?
    private var samplingStopped = false
    private var samplingAsleep = false
    private var recordingEnabled = true
    private var analyticsEnabled = true
    private let now: () -> Date
    private let healthMetrics: () -> [String: Any]
    private let acquireWriterLock: (Int32) -> Int32

    private let queue: DispatchQueue
    private var fileHandle: FileHandle?

    /// Test seam: invoked on the writer queue immediately before each line is
    /// written. Tests install a semaphore wait here to pin the queue and prove
    /// `append` stays non-blocking + drops rather than growing (EVT-3). nil in
    /// production.
    var onQueueBeforeWrite: (() -> Void)?
    /// Observes actual directory reconciliations for runtime cost tests.
    var onHistoryReconcile: (() -> Void)?
    /// Observes the actual timer lifecycle and selected deadline/leeway.
    var onTimerCreated: (() -> Void)?
    var onTimerScheduled: ((TimeInterval, Int) -> Void)?

    /// Assigned and read only on `queue`.
    private var nextSeq: UInt64 = 0
    private var confirmedDrainIDs = Set<String>()
    private var confirmedDrainOrder: [String] = []

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
        policy: ActivityHistoryPolicy? = nil,
        acquireWriterLock: @escaping (Int32) -> Int32 = { fd in
            flock(fd, LOCK_SH | LOCK_NB) == 0 ? 0 : errno
        },
        label: String = "com.stage11.c11.events.log"
    ) {
        self.url = url
        self.instance = instance
        self.sizeCap = max(1, min(sizeCap, totalSizeCap / 2))
        self.maxPending = maxPending
        self.totalSizeCap = max(1, totalSizeCap)
        self.retentionNamespace = Self.buildLabel(for: url.lastPathComponent) ?? instance
        self.retentionDays = policy?.retentionDays ?? retentionDays
        self.recordingEnabled = policy?.enabled ?? true
        self.analyticsEnabled = policy?.analyticsEnabled ?? true
        self.titleWindow = titleWindow
        self.maxTitlePanels = max(1, maxTitlePanels)
        self.now = now
        self.healthMetrics = healthMetrics
        self.acquireWriterLock = acquireWriterLock
        self.nextPruneAt = now().addingTimeInterval(86_400)
        self.queue = DispatchQueue(label: label, qos: .utility, autoreleaseFrequency: .workItem)
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
            guard let self else { return }
            if self.recordingEnabled { self.writeAssigningSeq(env) }
            else { self.pruneHistory() }
        }
    }

    /// Drain previously-enqueued writes for readers such as mailbox receipts.
    /// A read barrier must not end a live title window. Close, expiry and
    /// finishSampling() are the explicit tail-flush boundaries.
    /// Never call from within `queue`.
    func flush() {
        waitForQueue {}
    }

    /// Settings changes are rare and become one ordered queue mutation.
    func updatePolicy(_ policy: ActivityHistoryPolicy) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.recordingEnabled { self.flushTitles() }
            let resumeHealth = policy.enabled && policy.analyticsEnabled
                && (!self.recordingEnabled || !self.analyticsEnabled)
            self.recordingEnabled = policy.enabled
            self.analyticsEnabled = policy.analyticsEnabled
            self.retentionDays = policy.retentionDays
            self.pruneHistory()
            if !policy.enabled || !policy.analyticsEnabled { self.nextSampleAt = .distantFuture }
            else if resumeHealth { self.nextSampleAt = self.now().addingTimeInterval(600) }
            self.scheduleSampling()
        }
    }

    /// One rearmed timer serves title, health and daily retention deadlines.
    /// Title deadlines allow two seconds of wakeup coalescing; other work 60s.
    func startSampling(_ provider: @escaping () -> EventEnvelope?) {
        queue.async { [weak self] in
            self?.samplingStopped = false
            self?.sampleProvider = provider
            self?.nextSampleAt = self?.now().addingTimeInterval(600) ?? .distantFuture
            self?.scheduleSampling()
        }
    }

    private func scheduleSampling() {
        guard !samplingStopped, !samplingAsleep, recordingEnabled else {
            sampleTimer?.cancel()
            sampleTimer = nil
            return
        }
        let sampleDeadline = analyticsEnabled && sampleProvider != nil ? nextSampleAt : .distantFuture
        let deadline = min(nextTitleExpiry, min(sampleDeadline, nextPruneAt))
        let leeway = nextTitleExpiry <= min(sampleDeadline, nextPruneAt) ? 2 : 60
        let delay = max(0, deadline.timeIntervalSince(now()))
        if sampleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.deadlineFired() }
            sampleTimer = timer
            timer.schedule(deadline: .now() + delay, leeway: .seconds(leeway))
            timer.resume()
            onTimerCreated?()
        } else {
            sampleTimer?.schedule(deadline: .now() + delay, leeway: .seconds(leeway))
        }
        onTimerScheduled?(delay, leeway)
    }

    func setSamplingAsleep(_ asleep: Bool) {
        queue.async { [weak self] in
            guard let self, self.samplingAsleep != asleep else { return }
            self.samplingAsleep = asleep
            if asleep { self.sampleTimer?.cancel(); self.sampleTimer = nil }
            else {
                self.nextSampleAt = self.now().addingTimeInterval(600)
                self.scheduleSampling()
            }
        }
    }

    func stopSampling() {
        waitForQueue {
            self.samplingStopped = true
            self.sampleTimer?.cancel()
            self.sampleTimer = nil
            self.sampleProvider = nil
        }
    }

    func finishSampling(_ provider: @escaping () -> EventEnvelope?) {
        waitForQueue {
            self.samplingStopped = true
            self.sampleTimer?.cancel()
            self.sampleTimer = nil
            self.sampleProvider = nil
            self.flushTitles()
            if self.recordingEnabled, self.analyticsEnabled, let event = provider() { self.writeAssigningSeq(event) }
            self.pruneHistory()
        }
    }

    /// Deterministic behavioral seam: uses the exact timer path, without sleeps.
    func sampleForTesting() { waitForQueue { self.sampleNow() } }

    /// Execute the actual combined timer callback against an injected clock.
    func fireDeadlineForTesting() { waitForQueue { self.deadlineFired() } }

    /// Only successful drain-delivery writes enter this bounded acknowledgment
    /// set. A timed-out barrier confirms nothing, so the receipt stays durable.
    func confirmedDrainDeliveryIDs(_ ids: Set<String>) -> Set<String> {
        var result = Set<String>()
        let completed = waitForQueue { result = self.confirmedDrainIDs.intersection(ids) }
        return completed ? result : []
    }

    /// DispatchQueue.sync may execute its body on the calling main thread.
    /// Enqueue then wait only at explicit drain/shutdown seams, so metrics,
    /// title-tail serialization and disk I/O always execute off-main.
    @discardableResult
    private func waitForQueue(_ body: @escaping () -> Void) -> Bool {
        let completion = DispatchSemaphore(value: 0)
        queue.async {
            body()
            completion.signal()
        }
        return completion.wait(timeout: .now() + 2) == .success
    }

    private func deadlineFired() {
        guard recordingEnabled, !samplingAsleep else { return }
        flushTitles(expiredOnly: true)
        if analyticsEnabled, sampleProvider != nil, now() >= nextSampleAt {
            sampleNow()
        } else {
            if now() >= nextPruneAt { pruneHistory() }
            scheduleSampling()
        }
    }

    private func sampleNow() {
        guard recordingEnabled, !samplingAsleep else { return }
        flushTitles(expiredOnly: true)
        reportDropsIfNeeded()
        if recordingEnabled, analyticsEnabled, let event = sampleProvider?() { writeAssigningSeq(event) }
        pruneHistory()
        nextSampleAt = now().addingTimeInterval(600)
        scheduleSampling()
    }

    // MARK: - Queue-confined writing

    private func process(_ envelope: EventEnvelope) {
        guard recordingEnabled else { return }
        if now() >= nextTitleExpiry { flushTitles(expiredOnly: true) }
        let oscTitle = envelope.type == EventEnvelope.EventType.metadataChanged.rawValue
            && envelope.payload["key"] as? String == "title"
            && envelope.payload["source"] as? String == "osc"
        if envelope.type == EventEnvelope.EventType.logPolicy.rawValue
            || envelope.type == EventEnvelope.EventType.workspaceClosed.rawValue {
            flushTitles()
        } else if !oscTitle, envelope.surface != nil {
            flushTitles(panel: envelope.surface)
        }
        if oscTitle,
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
                nextTitleExpiry = titles.values.map { $0.started.addingTimeInterval(titleWindow) }.min() ?? .distantFuture
            }
            let started = now()
            titles[key] = TitleWindow(started: started, latest: envelope, count: 1)
            nextTitleExpiry = min(nextTitleExpiry, started.addingTimeInterval(titleWindow))
            scheduleSampling()
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
        guard !keys.isEmpty else { return }
        for key in keys { flushTitle(key) }
        nextTitleExpiry = titles.values.map { $0.started.addingTimeInterval(titleWindow) }.min() ?? .distantFuture
        scheduleSampling()
    }

    private static let asciiSpinnerValues: Set<UInt32> = [0x2F, 0x2D, 0x5C, 0x7C]

    private static func titleWithoutStatusGlyphs(_ title: String) -> String {
        var scalars = title.unicodeScalars[...]
        while let first = scalars.first {
            let category = first.properties.generalCategory
            let asciiSpinner = asciiSpinnerValues.contains(first.value)
                && (scalars.dropFirst().first.map {
                    CharacterSet.whitespaces.contains($0) || asciiSpinnerValues.contains($0.value)
                        || $0.properties.generalCategory == .otherSymbol || (0x2800...0x28FF).contains($0.value)
                        || $0.value == 0xFE0F || $0.value == 0x200D
                } ?? true)
            let glyph = category == .otherSymbol || asciiSpinner
                || first.value == 0xFE0F || first.value == 0x200D
                || (0x2800...0x28FF).contains(first.value)
            if glyph || CharacterSet.whitespaces.contains(first) { scalars = scalars.dropFirst() }
            else { break }
        }
        return String(String.UnicodeScalarView(scalars))
    }


    @discardableResult
    private func writeAssigningSeq(_ envelope: EventEnvelope, countDrop: Bool = true, rotate: Bool = true) -> Bool {
        do { try ensureHandle() } catch {
            if countDrop { recordDrop() }
            return false
        }
        let sequence = nextSeq &+ 1
        let line = envelope.serialize(seq: sequence)
        guard writeLine(line) else {
            if countDrop { recordDrop() }
            return false
        }
        nextSeq = sequence
        if envelope.type == EventEnvelope.EventType.mailboxDelivered.rawValue,
           envelope.payload["via"] as? String == "drain", let id = envelope.payload["id"] as? String,
           confirmedDrainIDs.insert(id).inserted {
            confirmedDrainOrder.append(id)
            if confirmedDrainOrder.count > 32_768 {
                confirmedDrainIDs.remove(confirmedDrainOrder.removeFirst())
            }
        }
        NotificationCenter.default.post(
            name: Self.eventWrittenNotification,
            object: envelope.type,
            userInfo: ["seq": nextSeq]
        )
        if !historyInitialized { pruneHistory() }
        else { publishRetentionState() }
        if rotate { rotateIfNeeded() }
        return true
    }

    private func recordDrop(_ count: Int = 1) {
        counterLock.lock()
        droppedSinceReport += count
        counterLock.unlock()
    }

    /// Emits a `log.dropped` marker when the backpressure guard has shed events
    /// since the last report. Runs on `queue` ahead of the next real append.
    private func reportDropsIfNeeded() {
        guard recordingEnabled else { return }
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
        if !writeAssigningSeq(env, countDrop: false) { recordDrop(dropped) }
    }

    private func writeLine(_ line: String) -> Bool {
        onQueueBeforeWrite?()
        do {
            try ensureHandle()
            if let data = line.data(using: .utf8) {
                // A single record larger than the whole configured budget
                // cannot be retained while honoring that budget.
                guard data.count <= totalSizeCap, let fileHandle else { return false }
                try fileHandle.write(contentsOf: data)
                knownHistoryBytes += data.count
                return true
            }
        } catch {
            // Best-effort: drop the handle so the next call reopens from scratch.
            // Log write failures are intentionally silent — observability must
            // never block or crash the emitting path.
            try? fileHandle?.close()
            fileHandle = nil
        }
        return false
    }

    private func ensureHandle() throws {
        if fileHandle != nil { return }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // O_CLOEXEC is atomic with open: a concurrent PTY fork must never
        // inherit this descriptor and keep a dead writer's SH lock alive.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let lockError = acquireWriterLock(fd)
        writerLockError = lockError == 0 ? nil : lockError
        // Lock failures affect retention coordination, never event delivery.
        // Busy is transient; unavailable locking gets an explicit boundary.
        do { try fh.seekToEnd() }
        catch { try? fh.close(); throw error }
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
        // Keep the old file's shared liveness lock until the rename completes.
        let previousHandle = fileHandle
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
            fileHandle = previousHandle
            return
        }
        try? previousHandle?.close()
        // Fresh current file starts with a rotation marker so a consumer that
        // re-reads from the top after detecting the shrink lands on the boundary.
        let marker = EventEnvelope(
            type: .logRotated,
            instance: instance,
            ts: now(),
            payload: ["rolled_to": rolled.lastPathComponent]
        )
        writeAssigningSeq(marker, rotate: false)
        pruneHistory()
    }

    private func historyFiles() -> [URL] {
        // Foundation refuses contentsOfDirectory on an explicit symlink with
        // ENOTDIR, although opening child files through it works. Resolve the
        // directory itself before discovering retained generations.
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
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

    /// Only open, rotation, health sample and policy changes reconcile files.
    /// Normal appends update cached bytes without directory scans or flock.
    private func acquireHistoryLock() -> String? {
        if historyLockFD < 0 {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            historyLockFD = Darwin.open(directory.appendingPathComponent(".activity-history.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard historyLockFD >= 0 else { return "lock_unavailable" }
        if flock(historyLockFD, LOCK_EX | LOCK_NB) == 0 { return nil }
        return errno == EWOULDBLOCK || errno == EAGAIN ? "lock_busy" : "lock_unavailable"
    }

    private func pruneHistory() {
        onHistoryReconcile?()
        if writerLockError != nil, let fileHandle {
            let result = acquireWriterLock(fileHandle.fileDescriptor)
            writerLockError = result == 0 ? nil : result
        }
        let failure = acquireHistoryLock()
        // Contention degrades the shared target to a bounded own-instance
        // namespace. It must never stall or shed activity records.
        pruneHistoryFiles(ownInstanceOnly: failure != nil)
        if failure == nil { flock(historyLockFD, LOCK_UN) }
        historyInitialized = true
        nextPruneAt = now().addingTimeInterval(86_400)
        if let writerLockError, writerLockError != EWOULDBLOCK && writerLockError != EAGAIN {
            retentionFailure = "liveness_lock_unavailable"
        } else { retentionFailure = failure }
        publishRetentionState()
    }

    private func publishRetentionState() {
        // A retention boundary must never precede the instance's first record
        // (log.opened in production), including first enable after off startup.
        guard recordingEnabled, nextSeq > 0 else { return }
        if let failure = retentionFailure, !reportedRetentionDegraded {
            reportedRetentionDegraded = true
            writeAssigningSeq(EventEnvelope(type: .logRetention, instance: instance, ts: now(),
                payload: ["state": "degraded", "reason": failure]), rotate: false)
        } else if retentionFailure == nil, reportedRetentionDegraded {
            reportedRetentionDegraded = false
            writeAssigningSeq(EventEnvelope(type: .logRetention, instance: instance, ts: now(),
                payload: ["state": "recovered"]), rotate: false)
        }
    }

    /// Build label excludes the per-process pid and numbered generation.
    private static func buildLabel(for name: String) -> String? {
        guard EventLogLayout.isLogFileName(name), let suffix = name.range(of: ".ndjson", options: .backwards) else { return nil }
        let instance = String(name[name.index(name.startIndex, offsetBy: EventLogLayout.logFilePrefix.count)..<suffix.lowerBound])
        guard let dash = instance.lastIndex(of: "-"), Int32(instance[instance.index(after: dash)...]) != nil else { return instance }
        return String(instance[..<dash])
    }

    private func isOwnInstanceFile(_ name: String) -> Bool {
        if name == url.lastPathComponent { return true }
        let prefix = url.lastPathComponent + "."
        guard name.hasPrefix(prefix), let generation = Int(name.dropFirst(prefix.count)) else { return false }
        return generation > 0
    }

    private func pruneHistoryFiles(ownInstanceOnly: Bool) {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        let developmentCutoff = now().addingTimeInterval(-14 * 86_400)
        let allEntries = historyFiles().compactMap { item -> (url: URL, date: Date, bytes: Int, label: String?)? in
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (item, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0,
                    isOwnInstanceFile(item.lastPathComponent) ? retentionNamespace : Self.buildLabel(for: item.lastPathComponent))
        }.sorted { $0.date < $1.date }
        func removeIfInactive(_ item: URL) -> Bool {
            if item.lastPathComponent == url.lastPathComponent, fileHandle != nil { return false }
            // If this volume cannot establish writer liveness, no current
            // file is safe to prune even if an EX probe appears to succeed.
            if let error = writerLockError, error != EWOULDBLOCK && error != EAGAIN,
               item.lastPathComponent.hasSuffix(".ndjson") { return false }
            // The kernel releases a live writer's SH lock on process death;
            // pid reuse cannot make an abandoned file immortal. Hold EX until
            // unlink completes so another writer cannot acquire SH meanwhile.
            let fd = Darwin.open(item.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
            do { try fm.removeItem(at: item); return true } catch { return false }
        }
        if !ownInstanceOnly {
            // A fixed development TTL may clean dead foreign tagged builds.
            // Production and nightly labels are never governed by our policy.
            for entry in allEntries where entry.label != retentionNamespace
                && entry.label != nil
                && entry.label != "com.stage11.c11"
                && entry.label != "com.stage11.c11.nightly"
                && entry.date < developmentCutoff {
                _ = removeIfInactive(entry.url)
            }
        }
        var entries = allEntries.filter {
            ownInstanceOnly ? isOwnInstanceFile($0.url.lastPathComponent) : $0.label == retentionNamespace
        }
        var removed = Set<String>()
        for entry in entries where entry.date < cutoff {
            if removeIfInactive(entry.url) { removed.insert(entry.url.lastPathComponent) }
        }
        entries.removeAll { removed.contains($0.url.lastPathComponent) }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries where total > totalSizeCap {
            if removeIfInactive(entry.url) { total -= entry.bytes }
        }
        knownHistoryBytes = total
        historyInitialized = true
    }
}
