import Foundation

/// Per-workspace mailbox dispatcher. Watches `_outbox/`, atomically moves new
/// `*.msg` files into `_processing/`, validates, resolves recipients, copies
/// envelopes into each recipient's inbox, invokes handlers, appends NDJSON
/// events to `_dispatch.log`, then cleans up.
///
/// All phases run on a dedicated `.utility` queue per CLAUDE.md's socket
/// command threading policy. Handlers may hop to other executors internally
/// (the `stdin` handler bounds a `@MainActor` hop with a 500 ms timeout).
///
/// Stage 2 scope: `to` resolution only. Topic fan-out via `mailbox.subscribe`
/// globs is Stage 3 per `.lattice/notes/task_01KPYFX4PV4QQQYHCPE0R02GEZ.md`.
/// Envelopes declaring only `topic` are accepted but resolve to an empty
/// recipient set — the `resolved` log entry reflects that.
final class MailboxDispatcher {

    typealias HandlerFunction = (
        _ envelope: MailboxEnvelope,
        _ recipientId: UUID,
        _ recipientName: String
    ) async -> HandlerInvocationResult

    struct HandlerInvocationResult {
        let outcome: MailboxDispatchLog.HandlerOutcome
        let bytes: Int?
        let elapsedMs: Int?

        init(
            outcome: MailboxDispatchLog.HandlerOutcome,
            bytes: Int? = nil,
            elapsedMs: Int? = nil
        ) {
            self.outcome = outcome
            self.bytes = bytes
            self.elapsedMs = elapsedMs
        }
    }

    // MARK: - Collaborators

    let workspaceId: UUID
    let stateURL: URL
    let resolver: MailboxSurfaceResolver
    let log: MailboxDispatchLog
    let queue: DispatchQueue

    private var watcher: MailboxOutboxWatcher?
    private var gcTimer: DispatchSourceTimer?
    private var handlers: [String: HandlerFunction] = [:]
    private var recentlySeen: [String] = []
    private let recentlySeenCap = 1024
    private let lock = NSLock()

    /// How often the stale-tmp sweep fires. Plan § Step 13: every 60 s.
    static let gcSweepInterval: TimeInterval = 60
    /// How old a `.tmp` file must be before the sweep deletes it. Plan: 5 min.
    static let gcStaleThreshold: TimeInterval = 300

    init(
        workspaceId: UUID,
        stateURL: URL,
        resolver: MailboxSurfaceResolver,
        queue: DispatchQueue = DispatchQueue(
            label: "com.stage11.c11.mailbox.dispatcher",
            qos: .utility
        ),
        log: MailboxDispatchLog? = nil
    ) {
        self.workspaceId = workspaceId
        self.stateURL = stateURL
        self.resolver = resolver
        self.queue = queue
        self.log = log ?? MailboxDispatchLog(
            url: MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)
        )
    }

    deinit {
        watcher?.stop()
    }

    // MARK: - Lifecycle

    /// Registers a handler under a name referenced in `mailbox.delivery`.
    /// Re-registration replaces the prior entry.
    func registerHandler(name: String, _ handler: @escaping HandlerFunction) {
        lock.withLock { handlers[name] = handler }
    }

    /// Creates the mailbox tree (if absent) and begins watching `_outbox/`.
    /// Idempotent: calling again after `start` is a no-op. Returns whether the
    /// dispatcher took ownership (false if the state directory couldn't be
    /// created).
    ///
    /// **At-least-once is steady-state only in Stage 2.** Pre-existing
    /// envelopes in `_outbox/` are picked up by the watcher's initial
    /// scan below. Envelopes stranded in `_processing/` after a prior
    /// dispatcher was killed mid-flight are NOT swept back to `_outbox/`
    /// here — that recovery pass is Stage 3 scope.
    /// TODO(stage-3): move surviving `_processing/*.msg` back to
    /// `_outbox/` (or re-dispatch directly) on start so at-least-once
    /// holds across dispatcher-crash-while-processing.
    @discardableResult
    func start() -> Bool {
        if watcher != nil { return true }
        do {
            try createMailboxTree()
        } catch {
            return false
        }

        let outbox = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        let watcher = MailboxOutboxWatcher(
            directoryURL: outbox,
            queue: queue
        ) { [weak self] urls in
            self?.handleOutboxChanges(urls: urls)
        }
        watcher.start()
        // Dispatch any `.msg` files that were sitting in `_outbox/` before
        // c11 started — either written while c11 was down, or stranded by a
        // previous run. The periodic sweep would pick them up within 5 s
        // anyway; this keeps the at-least-once claim prompt, not eventual.
        // Note: crash-recovery of `_processing/` envelopes is Stage 3
        // (see MailboxDispatcher at-least-once docs and skill).
        watcher.triggerImmediateScan()
        self.watcher = watcher

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.gcSweepInterval,
            repeating: Self.gcSweepInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sweepStaleTempFiles()
        }
        gcTimer = timer
        timer.resume()
        return true
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        gcTimer?.cancel()
        gcTimer = nil
    }

    // MARK: - Stale-tmp GC

    /// Deletes dot-prefixed `.tmp` files in `_outbox/` older than
    /// `gcStaleThreshold`. Writer crashes (or slow writes) can leave tmp
    /// siblings around; the dispatcher cleans them up so they don't linger.
    /// Exposed internal for test determinism via `runGCSweep(now:)`.
    @discardableResult
    func runGCSweep(now: Date = Date()) -> Int {
        let outbox = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: outbox,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch {
            return 0
        }
        var removed = 0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".\(MailboxLayout.tempExtension)") else { continue }
            // Only GC dot-prefixed tmp siblings written by MailboxIO.atomicWrite
            // (or the raw-bash example). Anything else is out of our domain.
            guard name.hasPrefix(".") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) >= Self.gcStaleThreshold {
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 {
            log.append(.gc(tempFilesRemoved: removed))
        }
        return removed
    }

    private func sweepStaleTempFiles() {
        _ = runGCSweep()
    }

    // MARK: - Directory setup

    private func createMailboxTree() throws {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(
            at: MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId),
            withIntermediateDirectories: true,
            attributes: attrs
        )
        try fm.createDirectory(
            at: MailboxLayout.processingURL(state: stateURL, workspaceId: workspaceId),
            withIntermediateDirectories: true,
            attributes: attrs
        )
        try fm.createDirectory(
            at: MailboxLayout.rejectedURL(state: stateURL, workspaceId: workspaceId),
            withIntermediateDirectories: true,
            attributes: attrs
        )
    }

    // MARK: - Watcher callback

    private func handleOutboxChanges(urls: [URL]) {
        for url in urls {
            dispatchOne(url: url)
        }
    }

    /// Serialized by the dispatcher queue (the watcher callback is delivered
    /// on it). Exposed internal for deterministic testing.
    func dispatchOne(url: URL) {
        let id = url.deletingPathExtension().lastPathComponent

        if recentlySeenContains(id) { return }

        // Step 1: atomic-move outbox → processing. ENOENT means another
        // fsevent replay already handled it — skip silently.
        let processingDir = MailboxLayout.processingURL(state: stateURL, workspaceId: workspaceId)
        let processingURL = processingDir.appendingPathComponent(
            MailboxLayout.envelopeFilename(id: id)
        )
        do {
            try FileManager.default.moveItem(at: url, to: processingURL)
        } catch {
            return
        }

        recordRecentlySeen(id)

        // Step 2: validate.
        let envelope: MailboxEnvelope
        do {
            let data = try Data(contentsOf: processingURL)
            envelope = try MailboxEnvelope.validate(data: data)
        } catch {
            quarantine(
                id: id,
                processingURL: processingURL,
                reason: "\(error)"
            )
            return
        }

        log.append(
            .received(
                id: envelope.id,
                from: envelope.from,
                to: envelope.to,
                topic: envelope.topic
            )
        )

        // Step 3: resolve recipients. Stage 2 = `to` only.
        let recipients = resolveRecipients(envelope: envelope)
        log.append(.resolved(id: envelope.id, recipients: recipients.map(\.name)))

        // Step 4: copy into each recipient inbox.
        let envelopeBytes = (try? envelope.encode()) ?? Data()
        for recipient in recipients {
            copyToInbox(
                envelope: envelope,
                recipient: recipient,
                envelopeBytes: envelopeBytes
            )
        }

        // Step 5: invoke handlers.
        runHandlers(envelope: envelope, recipients: recipients)

        // Step 6: cleanup.
        try? FileManager.default.removeItem(at: processingURL)
        log.append(.cleaned(id: envelope.id))
    }

    // MARK: - Recipient resolution

    private func resolveRecipients(
        envelope: MailboxEnvelope
    ) -> [MailboxSurfaceResolver.SurfaceMetadata] {
        guard let to = envelope.to else { return [] }
        let all = resolver.surfacesWithMailboxMetadata()
        return all.filter { $0.name == to }
    }

    // MARK: - Inbox copy

    private func copyToInbox(
        envelope: MailboxEnvelope,
        recipient: MailboxSurfaceResolver.SurfaceMetadata,
        envelopeBytes: Data
    ) {
        do {
            let inbox = try MailboxLayout.inboxURL(
                state: stateURL,
                workspaceId: workspaceId,
                surfaceName: recipient.name
            )
            try FileManager.default.createDirectory(
                at: inbox,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let target = inbox.appendingPathComponent(
                MailboxLayout.envelopeFilename(id: envelope.id)
            )
            try MailboxIO.atomicWrite(data: envelopeBytes, to: target)
            log.append(.copied(id: envelope.id, recipient: recipient.name))
        } catch {
            // The `resolved` event already lists the recipient; failure to
            // copy is logged as a handler-style failure so the operator can
            // see it in `c11 mailbox trace`.
            log.append(
                .handler(
                    id: envelope.id,
                    recipient: recipient.name,
                    handler: "_copy",
                    outcome: .eio,
                    bytes: nil,
                    elapsedMs: nil
                )
            )
        }
    }

    // MARK: - Handler invocation

    private func runHandlers(
        envelope: MailboxEnvelope,
        recipients: [MailboxSurfaceResolver.SurfaceMetadata]
    ) {
        for recipient in recipients {
            for handlerName in recipient.delivery {
                let handler = lock.withLock { handlers[handlerName] }
                guard let handler else {
                    // Unknown handler — log and continue. Not a fatal error.
                    log.append(
                        .handler(
                            id: envelope.id,
                            recipient: recipient.name,
                            handler: handlerName,
                            outcome: .eio,
                            bytes: nil,
                            elapsedMs: nil
                        )
                    )
                    continue
                }
                invokeHandlerSynchronously(
                    handler: handler,
                    name: handlerName,
                    envelope: envelope,
                    recipient: recipient
                )
            }
        }
    }

    /// Bridges the async handler into the serial dispatcher queue. The outer
    /// 2 s ceiling is a reporting bound: if the handler Task has not
    /// signalled within 2 s, this method logs `timeout` and returns so the
    /// dispatcher's serial queue can move on. The underlying handler Task
    /// is not cancellable in the runtime sense — it keeps running on
    /// whatever actor it took — so "main thread freed after 2 s" is a
    /// property of the handler closure, not of this wait. See
    /// `StdinMailboxHandler` for the per-handler story.
    private func invokeHandlerSynchronously(
        handler: @escaping HandlerFunction,
        name: String,
        envelope: MailboxEnvelope,
        recipient: MailboxSurfaceResolver.SurfaceMetadata
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        var result = HandlerInvocationResult(outcome: .timeout)
        let start = Date()

        Task {
            let outcome = await handler(envelope, recipient.surfaceId, recipient.name)
            result = outcome
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            result = HandlerInvocationResult(outcome: .timeout)
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        log.append(
            .handler(
                id: envelope.id,
                recipient: recipient.name,
                handler: name,
                outcome: result.outcome,
                bytes: result.bytes,
                elapsedMs: result.elapsedMs ?? elapsedMs
            )
        )
    }

    // MARK: - Quarantine

    private func quarantine(id: String, processingURL: URL, reason: String) {
        let rejectedDir = MailboxLayout.rejectedURL(state: stateURL, workspaceId: workspaceId)
        let rejectedMsg = rejectedDir.appendingPathComponent(
            MailboxLayout.envelopeFilename(id: id)
        )
        let rejectedErr = rejectedDir.appendingPathComponent(
            MailboxLayout.rejectedErrorFilename(id: id)
        )
        try? FileManager.default.createDirectory(
            at: rejectedDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.moveItem(at: processingURL, to: rejectedMsg)
        try? Data(reason.utf8).write(to: rejectedErr)
        log.append(.rejected(id: id, reason: reason))
    }

    // MARK: - Dedupe

    private func recentlySeenContains(_ id: String) -> Bool {
        lock.withLock { recentlySeen.contains(id) }
    }

    private func recordRecentlySeen(_ id: String) {
        lock.withLock {
            recentlySeen.append(id)
            if recentlySeen.count > recentlySeenCap {
                recentlySeen.removeFirst(recentlySeen.count - recentlySeenCap)
            }
        }
    }
}

// MARK: - Minor helpers

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
