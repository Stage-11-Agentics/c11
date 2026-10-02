import Foundation

/// Keeps the local messages page current without making the event-emitting or
/// UI paths wait on page rendering. All source reads, JSON encoding, and file
/// replacement happen on this utility queue.
final class MessagesPageWriter {
    static let shared = MessagesPageWriter()
    static let pageDidWriteNotification = Notification.Name("com.stage11.c11.messages-page-did-write")

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let fixedStateURL: URL?
    private let debounceInterval: TimeInterval
    private let observeEvents: Bool
    private var stateURL: URL?
    private var eventObserver: NSObjectProtocol?
    private var started = false
    private var generation: UInt64 = 0
    /// Queue-confined cache of parsed event-log files. Startup fills it from
    /// the full current + rolled log set; debounced live writes only reread
    /// files whose size or modification date changed.
    private var eventLogCache = MessagesPageEventLogCache()
    /// Queue-confined durable mailbox snapshot. Plain `c11 send` events do
    /// not touch envelope files, and mailbox event payloads carry the body
    /// needed by the live page, so both channels can reuse this snapshot.
    /// Startup/relaunch still performs the full scan so older bodies survive
    /// event-log rotation via `_read/`, inbox, and `_rejected/`.
    private var mailboxArtifactsCache: [MessagesPageMailboxArtifact]?
    private var mailboxRefreshRequested = true

    init(
        stateURL: URL? = nil,
        debounceInterval: TimeInterval = 1.0,
        observeEvents: Bool = true,
        label: String = "com.stage11.c11.messages-page-writer"
    ) {
        self.fixedStateURL = stateURL
        self.debounceInterval = max(0, debounceInterval)
        self.observeEvents = observeEvents
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        if let eventObserver {
            NotificationCenter.default.removeObserver(eventObserver)
        }
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        guard let resolvedStateURL = fixedStateURL ?? (try? EventLogLayout.defaultStateURL()) else {
            lock.unlock()
            return
        }
        stateURL = resolvedStateURL
        started = true
        mailboxRefreshRequested = true
        if observeEvents {
            eventObserver = NotificationCenter.default.addObserver(
                forName: EventLog.eventWrittenNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let type = notification.object as? String,
                      MessagesPageWriter.isMessageEvent(type) else { return }
                self?.scheduleRebuild(refreshMailbox: false)
            }
        }
        lock.unlock()

        // Rebuild immediately on app start so the page is useful before the
        // first new event arrives in this process.
        queue.async { [weak self] in
            self?.rebuildQuietly()
        }
    }

    /// Test-only lifecycle seam. Production callers use `start()` and never
    /// need to stop the process-wide writer.
    func stopForTesting() {
        lock.lock()
        let observer = eventObserver
        eventObserver = nil
        started = false
        generation &+= 1
        lock.unlock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Synchronously rebuild a page in the resolved state directory. Callers
    /// use this only when they need the file to exist before opening it; the
    /// event-driven path remains asynchronous and debounced.
    func rebuildNow() throws {
        lock.lock()
        let resolvedStateURL = stateURL ?? fixedStateURL
        lock.unlock()
        guard let resolvedStateURL else {
            throw EventLogLayout.Error.stateDirectoryUnavailable
        }
        try queue.sync {
            try rebuild(stateURL: resolvedStateURL, forceMailboxRefresh: true)
        }
    }

    /// Test-only spelling retained so logic tests make the filesystem seam
    /// explicit at the call site.
    func rebuildNowForTesting() throws {
        try rebuildNow()
    }

    private func scheduleRebuild(refreshMailbox: Bool) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        if refreshMailbox {
            mailboxRefreshRequested = true
        }
        generation &+= 1
        let scheduledGeneration = generation
        lock.unlock()

        queue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldRun = self.started && self.generation == scheduledGeneration
            self.lock.unlock()
            guard shouldRun else { return }
            self.rebuildQuietly()
        }
    }

    private func rebuildQuietly() {
        lock.lock()
        let resolvedStateURL = stateURL
        let isStarted = started
        lock.unlock()
        guard isStarted, let resolvedStateURL else { return }
        try? rebuild(stateURL: resolvedStateURL, forceMailboxRefresh: false)
    }

    private func rebuild(stateURL: URL, forceMailboxRefresh: Bool) throws {
        lock.lock()
        let refreshMailbox = forceMailboxRefresh || mailboxRefreshRequested || mailboxArtifactsCache == nil
        mailboxRefreshRequested = false
        lock.unlock()

        let source = MessagesPageSource.load(
            stateURL: stateURL,
            eventLogCache: &eventLogCache,
            mailboxArtifacts: refreshMailbox ? nil : mailboxArtifactsCache
        )
        mailboxArtifactsCache = source.mailboxArtifacts
        let snapshot = MessagesPageBuilder.build(
            events: source.events,
            mailboxArtifacts: source.mailboxArtifacts
        )
        let html = MessagesPageRenderer.render(snapshot: snapshot)
        try writeAtomically(html: html, stateURL: stateURL)
    }

    private func writeAtomically(html: String, stateURL: URL) throws {
        let fileManager = FileManager.default
        let directory = MessagesPageLayout.directoryURL(state: stateURL)
        let pageURL = MessagesPageLayout.pageURL(state: stateURL)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let temporaryURL = directory.appendingPathComponent(
            ".messages-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try Data(html.utf8).write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: pageURL.path) {
            _ = try fileManager.replaceItemAt(
                pageURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: pageURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: pageURL.path
        )
        NotificationCenter.default.post(
            name: Self.pageDidWriteNotification,
            object: pageURL
        )
    }

    private static func isMessageEvent(_ type: String) -> Bool {
        type == "tab.input_sent" || type.hasPrefix("mailbox.")
    }
}
