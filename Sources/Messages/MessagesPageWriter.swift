import Foundation
import OSLog

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
    private let maxWaitInterval: TimeInterval
    private let observeEvents: Bool
    private let allowStartUnderXCTest: Bool
    private var stateURL: URL?
    private var eventObserver: NSObjectProtocol?
    private var started = false
    private var generation: UInt64 = 0
    private var pendingSince: DispatchTime?
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
        maxWaitInterval: TimeInterval = 5.0,
        observeEvents: Bool = true,
        allowStartUnderXCTest: Bool = false,
        label: String = "com.stage11.c11.messages-page-writer"
    ) {
        self.fixedStateURL = stateURL
        self.debounceInterval = max(0, debounceInterval)
        self.maxWaitInterval = max(self.debounceInterval, maxWaitInterval)
        self.observeEvents = observeEvents
        self.allowStartUnderXCTest = allowStartUnderXCTest
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        if let eventObserver {
            NotificationCenter.default.removeObserver(eventObserver)
        }
    }

    func start() {
        guard allowStartUnderXCTest || !Self.isRunningUnderXCTest() else { return }
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
        pendingSince = nil
        eventLogCache = MessagesPageEventLogCache()
        mailboxArtifactsCache = nil
        lock.unlock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Synchronously rebuild a page in the resolved state directory. Callers
    /// use this only from tests or a non-UI maintenance path. UI callers must
    /// use `ensurePage(onReady:)` so a missing page never blocks the main
    /// thread behind the writer queue.
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

    /// Test-only trigger for exercising debounce/max-wait behavior without
    /// manufacturing an EventLog notification or touching process-wide state.
    func scheduleRebuildForTesting(refreshMailbox: Bool = false) {
        scheduleRebuild(refreshMailbox: refreshMailbox)
    }

    /// Resolve a page for a view request without waiting on the writer from the
    /// caller's thread. If the page is missing, the rebuild and callback stay
    /// on the utility queue; callers can hop to the main actor only when the
    /// file is ready to be opened.
    func ensurePage(onReady: @escaping (Result<URL, Swift.Error>) -> Void) {
        lock.lock()
        let resolvedStateURL = stateURL ?? fixedStateURL
        let isStarted = started
        lock.unlock()

        guard isStarted, let resolvedStateURL else {
            onReady(.failure(EventLogLayout.Error.stateDirectoryUnavailable))
            return
        }
        let pageURL = MessagesPageLayout.pageURL(state: resolvedStateURL)
        if FileManager.default.fileExists(atPath: pageURL.path) {
            onReady(.success(pageURL))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                if !FileManager.default.fileExists(atPath: pageURL.path) {
                    try self.rebuild(
                        stateURL: resolvedStateURL,
                        forceMailboxRefresh: true
                    )
                }
                onReady(.success(pageURL))
            } catch {
                Self.logRebuildFailure(error: error, stateURL: resolvedStateURL, phase: "ensure")
                onReady(.failure(error))
            }
        }
    }

    private func scheduleRebuild(refreshMailbox: Bool) {
        let now = DispatchTime.now()
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        if refreshMailbox {
            mailboxRefreshRequested = true
        }
        let shouldScheduleMaxWait = pendingSince == nil
        if pendingSince == nil {
            pendingSince = now
        }
        generation &+= 1
        let scheduledGeneration = generation
        let debounceDeadline = now.uptimeNanoseconds
            + UInt64(debounceInterval * 1_000_000_000)
        let maxDeadline = pendingSince!.uptimeNanoseconds
            + UInt64(maxWaitInterval * 1_000_000_000)
        let deadline = DispatchTime(uptimeNanoseconds: min(debounceDeadline, maxDeadline))
        lock.unlock()

        if shouldScheduleMaxWait {
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: maxDeadline)) { [weak self] in
                self?.runMaxWaitIfDue()
            }
        }

        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldRun = self.started && self.generation == scheduledGeneration
            if shouldRun {
                self.pendingSince = nil
            }
            self.lock.unlock()
            guard shouldRun else { return }
            self.rebuildQuietly()
        }
    }

    /// The max-wait item is deliberately independent of `generation`. New
    /// events cancel trailing debounce generations, but they must not postpone
    /// the first rebuild past the pending batch's deadline.
    private func runMaxWaitIfDue() {
        lock.lock()
        guard started, let pendingSince else {
            lock.unlock()
            return
        }
        let deadline = pendingSince.uptimeNanoseconds
            + UInt64(maxWaitInterval * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline {
            lock.unlock()
            return
        }
        generation &+= 1
        self.pendingSince = nil
        lock.unlock()
        rebuildQuietly()
    }

    private func rebuildQuietly() {
        lock.lock()
        let resolvedStateURL = stateURL
        let isStarted = started
        lock.unlock()
        guard isStarted, let resolvedStateURL else { return }
        do {
            try rebuild(stateURL: resolvedStateURL, forceMailboxRefresh: false)
        } catch {
            Self.logRebuildFailure(error: error, stateURL: resolvedStateURL, phase: "debounced")
        }
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

    private static let logger = Logger(
        subsystem: "com.stage11.c11",
        category: "messages-page"
    )

    private static func logRebuildFailure(error: Swift.Error, stateURL: URL, phase: String) {
        logger.error(
            "messages_page_rebuild_failed phase=\(phase, privacy: .public) state=\(stateURL.path, privacy: .private(mask: .hash)) error=\(String(describing: error), privacy: .public)"
        )
    }

    static func isRunningUnderXCTest(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCInjectBundle"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true
    }

    private static func isMessageEvent(_ type: String) -> Bool {
        EventEnvelope.canonicalType(type) == EventEnvelope.EventType.panelInputSent.rawValue
            || type.hasPrefix("mailbox.")
    }
}
