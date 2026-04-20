import Foundation

public final class ThemeDirectoryWatcher {
    public typealias ChangeHandler = @Sendable () -> Void

    private let url: URL
    private let debounceInterval: TimeInterval
    private let pollingInterval: TimeInterval
    private let queue: DispatchQueue
    private let handler: ChangeHandler

    private var stream: FSEventStreamRef?
    private var pollingTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSnapshot: [String: Date] = [:]
    private let lock = NSLock()

    public init(
        url: URL,
        debounceInterval: TimeInterval = 0.25,
        pollingInterval: TimeInterval = 2.0,
        queue: DispatchQueue = DispatchQueue(label: "c11.theme-watcher", qos: .utility),
        handler: @escaping ChangeHandler
    ) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.pollingInterval = pollingInterval
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        stop()

        lastSnapshot = currentSnapshot()

        startFSEventsStream()
        startPollingTimer()
    }

    public func stop() {
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

    // Callers can force a scan (e.g. "Reload" button). Bypasses debounce.
    public func triggerImmediateScan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastSnapshot = self.currentSnapshot()
            self.handler()
        }
    }

    private func startFSEventsStream() {
        let path = url.path
        let paths = [path] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ThemeDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleDebouncedScan()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.25,
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
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.detectChangesAndScan()
        }
        pollingTimer = timer
        timer.resume()
    }

    private func scheduleDebouncedScan() {
        lock.lock()
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.detectChangesAndScan()
        }
        debounceWorkItem = workItem
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func detectChangesAndScan() {
        let current = currentSnapshot()
        if current == lastSnapshot {
            return
        }
        lastSnapshot = current
        handler()
    }

    private func currentSnapshot() -> [String: Date] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [String: Date] = [:]
        for fileURL in contents where fileURL.pathExtension.lowercased() == "toml" {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            snapshot[fileURL.lastPathComponent] = values?.contentModificationDate ?? .distantPast
        }
        return snapshot
    }
}
