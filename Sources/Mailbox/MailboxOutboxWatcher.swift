import Foundation

/// Watches a mailbox `_outbox/` directory for new `*.msg` files. Modeled on
/// `Sources/Theme/ThemeDirectoryWatcher` (same FSEventStream + periodic-sweep
/// shape), with two specializations for the mailbox:
///
///  * File-extension filter: only `.msg` files trigger the handler. The `.tmp`
///    siblings that senders write first are ignored.
///  * 5-second periodic sweep (vs the theme watcher's 2 s): design doc §1 and
///    review item #4 name 5 s as the belt-and-suspenders interval to catch
///    missed fsevents after wake-from-sleep.
///
/// Handler receives the URLs of `.msg` files discovered since the previous
/// scan (either by fsevent + debounce, or by the periodic sweep). Duplicates
/// are filtered at the directory-snapshot layer so the dispatcher doesn't
/// re-dispatch between sweeps.
final class MailboxOutboxWatcher {

    typealias ChangeHandler = @Sendable ([URL]) -> Void

    let directoryURL: URL
    let debounceInterval: TimeInterval
    let pollingInterval: TimeInterval
    let queue: DispatchQueue
    private let handler: ChangeHandler

    private var stream: FSEventStreamRef?
    private var pollingTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var knownFiles: Set<String> = []
    private let lock = NSLock()

    init(
        directoryURL: URL,
        debounceInterval: TimeInterval = 0.05,
        pollingInterval: TimeInterval = 5.0,
        queue: DispatchQueue = DispatchQueue(
            label: "com.stage11.c11.mailbox.outbox-watcher",
            qos: .utility
        ),
        handler: @escaping ChangeHandler
    ) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        self.pollingInterval = pollingInterval
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Start with an empty known-set so any pre-existing `.msg` files
        // surface to the dispatcher on next scan. Idempotency is provided
        // downstream by the atomic move into `_processing/` — snapshotting
        // existing files as "already handled" here would strand envelopes
        // that arrived while c11 was not running.
        knownFiles = []
        startFSEventsStream()
        startPollingTimer()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pollingTimer?.cancel()
        pollingTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// Force an immediate scan, bypassing debounce. Used on dispatcher startup
    /// and by tests that want deterministic timing.
    func triggerImmediateScan() {
        queue.async { [weak self] in
            self?.detectChangesAndReport()
        }
    }

    // MARK: - FSEvents

    private func startFSEventsStream() {
        let paths = [directoryURL.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<MailboxOutboxWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
            watcher.scheduleDebouncedScan()
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            UInt64(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + pollingInterval,
            repeating: pollingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.detectChangesAndReport()
        }
        pollingTimer = timer
        timer.resume()
    }

    private func scheduleDebouncedScan() {
        lock.lock()
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.detectChangesAndReport()
        }
        debounceWorkItem = workItem
        lock.unlock()
        queue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: workItem
        )
    }

    // MARK: - Snapshot

    private func detectChangesAndReport() {
        let current = currentSnapshot()
        let new = current.subtracting(knownFiles)
        // Also track files that disappeared so we don't re-fire on re-creation
        // within the same polling window; knownFiles is a full reset to the
        // current snapshot per sweep.
        knownFiles = current
        if new.isEmpty { return }
        let urls = new.map { directoryURL.appendingPathComponent($0) }
        handler(urls)
    }

    /// Reads the directory, returning the `.msg` filenames. Dot-prefixed
    /// temp files and files of any other extension are filtered out here so
    /// dispatcher logic sees only fully-written envelopes.
    private func currentSnapshot() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var snapshot: Set<String> = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".\(MailboxLayout.envelopeExtension)") else { continue }
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            snapshot.insert(name)
        }
        return snapshot
    }
}
