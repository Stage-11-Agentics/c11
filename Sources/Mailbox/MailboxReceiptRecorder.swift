import Foundation

/// Records drain deliveries (C11-257): turns each `MailboxDeliveryReceipt` a
/// CLI drain leaves in `<mailboxes>/_receipts/` into one `mailbox.delivered`
/// event per envelope with `via: "drain"`, then deletes the receipt.
///
/// One recorder serves every workspace, on one serial `.utility` queue, so a
/// receipt is never processed twice concurrently and one set of recorded ids
/// covers them all.
///
/// - **Live spools:** each workspace's dispatcher registers its spool; a
///   `MailboxOutboxWatcher` (FSEvents + periodic sweep) triggers a sweep of it.
/// - **Every spool, once per launch:** the first registration also sweeps the
///   spool of every workspace directory on disk, so receipts left by a run
///   that quit or crashed are recorded even when their workspace is never
///   restored under the same id.
/// - **Exactly once:** within a run, the in-memory set skips an id already
///   recorded (a duplicate receipt). A receipt older than this run may have
///   been recorded by the previous one right before it died (emit happened,
///   delete did not), so its ids are first looked up in the event logs
///   written since the receipt and skipped when found.
/// - **Bad entries:** a receipt's invalid deliveries are dropped (listed in
///   `_rejected/<receipt>.dropped`) and its valid ones recorded.
/// - **Never lost:** nothing is deleted unless the event log is recording and
///   has been flushed; otherwise the receipt stays and is retried. Spools of
///   workspaces that are not open are swept again every
///   `everyWorkspaceSweepInterval`.
/// - **One app at a time per receipt:** several c11 builds can share the state
///   directory (a tagged dev build beside the installed app). A receipt is
///   claimed by renaming it to `.<name>.<pid>.claim` before it is read, so only
///   one process records it; a claim whose process died is put back.
final class MailboxReceiptRecorder {

    typealias Emit = (_ workspace: UUID, _ id: String, _ recipient: String, _ surface: UUID?) -> Void

    static let shared = MailboxReceiptRecorder()

    /// Temp files a writer abandoned (crash between write and rename).
    static let staleTempAge: TimeInterval = 300
    static let retryDelay: TimeInterval = 2
    /// Re-sweep of every workspace's spool, for receipts left where no open
    /// workspace watches (~40 ms for 11k workspace dirs, warm).
    static let everyWorkspaceSweepInterval: TimeInterval = 600
    static let claimSuffix = "claim"

    let queue: DispatchQueue
    private let startedAt: Date
    private let emit: Emit
    private let flush: () -> Void
    private let isRecording: () -> Bool
    private let eventsDirectory: () -> URL?
    private let fileManager: FileManager

    // Queue-confined state.
    private var watchers: [UUID: MailboxOutboxWatcher] = [:]
    private var spools: [UUID: URL] = [:]
    private var recorded: Set<String> = []
    private var recordedOrder: [String] = []
    private let recordedCap = 32_768
    private var sweptEveryWorkspace = false
    private var everyWorkspaceTimer: DispatchSourceTimer?
    private var retrySpools: [UUID: URL] = [:]

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.stage11.c11.mailbox.receipts", qos: .utility),
        startedAt: Date = Date(),
        emit: @escaping Emit = { workspace, id, recipient, surface in
            EventEmitter.shared.emitMailboxDelivered(
                workspace: workspace,
                id: id,
                recipient: recipient,
                surface: surface,
                via: "drain"
            )
        },
        flush: @escaping () -> Void = { EventEmitter.shared.flush() },
        isRecording: @escaping () -> Bool = { EventEmitter.shared.isRecording },
        eventsDirectory: @escaping () -> URL? = {
            (try? EventLogLayout.defaultStateURL()).map { EventLogLayout.eventsDirectoryURL(state: $0) }
        },
        fileManager: FileManager = .default
    ) {
        self.queue = queue
        self.startedAt = startedAt
        self.emit = emit
        self.flush = flush
        self.isRecording = isRecording
        self.eventsDirectory = eventsDirectory
        self.fileManager = fileManager
    }

    // MARK: - Lifecycle

    /// Starts recording one workspace's spool. The first call per recorder
    /// also sweeps every workspace's spool under `workspacesRoot`.
    func watch(workspaceId: UUID, mailboxesRoot: URL, workspacesRoot: URL) {
        let spool = MailboxDeliveryReceipt.spoolURL(mailboxesRoot: mailboxesRoot)
        queue.async { [self] in
            if !sweptEveryWorkspace {
                sweptEveryWorkspace = true
                sweepEveryWorkspace(workspacesRoot: workspacesRoot)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(
                    deadline: .now() + Self.everyWorkspaceSweepInterval,
                    repeating: Self.everyWorkspaceSweepInterval
                )
                timer.setEventHandler { [weak self] in
                    self?.sweepEveryWorkspace(workspacesRoot: workspacesRoot)
                }
                timer.resume()
                everyWorkspaceTimer = timer
            }
            guard watchers[workspaceId] == nil else { return }
            let watcher = MailboxOutboxWatcher(
                directoryURL: spool,
                fileExtension: MailboxDeliveryReceipt.fileExtension,
                queue: queue
            ) { [weak self] _ in
                // The watcher reports only names it has not seen; always sweep
                // the whole spool so a receipt left behind by a failed pass is
                // retried.
                self?.sweep(spool: spool, workspaceId: workspaceId)
            }
            watcher.start()
            watchers[workspaceId] = watcher
            spools[workspaceId] = spool
            sweep(spool: spool, workspaceId: workspaceId)
        }
    }

    /// Stops watching a workspace's spool after one last sweep of it, so a
    /// receipt written just before the workspace closed is still recorded.
    func unwatch(workspaceId: UUID) {
        queue.async { [self] in
            watchers.removeValue(forKey: workspaceId)?.stop()
            if let spool = spools.removeValue(forKey: workspaceId) {
                sweep(spool: spool, workspaceId: workspaceId)
            }
        }
    }

    /// Test seam: run `block` after everything queued so far.
    func sync(_ block: () -> Void = {}) {
        queue.sync(execute: block)
    }

    // MARK: - Sweeps (queue only)

    func sweepEveryWorkspace(workspacesRoot: URL) {
        dispatchPrecondition(condition: .onQueue(queue))
        let names = (try? fileManager.contentsOfDirectory(atPath: workspacesRoot.path)) ?? []
        for name in names {
            guard let workspaceId = UUID(uuidString: name) else { continue }
            let spool = MailboxDeliveryReceipt.spoolURL(
                mailboxesRoot: workspacesRoot
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
            )
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: spool.path, isDirectory: &isDir), isDir.boolValue else { continue }
            sweep(spool: spool, workspaceId: workspaceId)
        }
    }

    func sweep(spool: URL, workspaceId: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        let entries = (try? fileManager.contentsOfDirectory(
            at: spool,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        )) ?? []
        removeStaleTempFiles(in: entries)
        let recovered = recoverAbandonedClaims(in: entries, spool: spool)
        let receipts = (entries + recovered)
            .filter { $0.pathExtension == MailboxDeliveryReceipt.fileExtension && !$0.lastPathComponent.hasPrefix(".") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !receipts.isEmpty else { return }
        guard isRecording() else {
            scheduleRetry(spool: spool, workspaceId: workspaceId)
            return
        }
        var logged: Set<String>?
        var loggedSince: Date?
        for url in receipts {
            process(url, spool: spool, workspaceId: workspaceId, logged: &logged, loggedSince: &loggedSince)
        }
    }

    // MARK: - One receipt

    private func process(
        _ url: URL,
        spool: URL,
        workspaceId: UUID,
        logged: inout Set<String>?,
        loggedSince: inout Date?
    ) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return }
        // Claim it: another c11 process sharing this state directory may be
        // sweeping the same spool. The rename keeps the mtime.
        let claimed = spool.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).\(Self.claimSuffix)"
        )
        guard rename(url.path, claimed.path) == 0 else { return }
        guard (values?.fileSize ?? 0) <= MailboxDeliveryReceipt.maxBytes,
              let data = try? Data(contentsOf: claimed),
              let decoded = MailboxDeliveryReceipt.decode(data) else {
            reject(claimed, as: url.lastPathComponent, spool: spool)
            return
        }
        let receipt = decoded.receipt
        if !decoded.dropped.isEmpty {
            logDropped(decoded.dropped, from: url.lastPathComponent, spool: spool)
        }
        var pending = receipt.deliveries.filter { !recorded.contains($0.id) }
        let modified = values?.contentModificationDate ?? .distantPast
        if !pending.isEmpty, modified < startedAt {
            // Possibly recorded by the run that wrote it, just before it died.
            if logged == nil || (loggedSince ?? .distantFuture) > modified {
                logged = loggedDrainDeliveryIds(since: modified)
                loggedSince = modified
            }
            let alreadyLogged = logged ?? []
            for delivery in pending where alreadyLogged.contains(delivery.id) {
                remember(delivery.id)
            }
            pending.removeAll { alreadyLogged.contains($0.id) }
        }
        for delivery in pending {
            emit(workspaceId, delivery.id, delivery.recipient, receipt.panelId)
            remember(delivery.id)
        }
        // The events are on disk before the receipt that proves them is gone.
        flush()
        try? fileManager.removeItem(at: claimed)
    }

    private func remember(_ id: String) {
        guard recorded.insert(id).inserted else { return }
        recordedOrder.append(id)
        if recordedOrder.count > recordedCap {
            let overflow = recordedOrder.count - recordedCap
            recordedOrder.prefix(overflow).forEach { recorded.remove($0) }
            recordedOrder.removeFirst(overflow)
        }
    }

    /// Invalid entries of an otherwise valid receipt: the valid ones are
    /// recorded, these are kept for inspection beside the rejected receipts.
    private func logDropped(_ dropped: [Any], from name: String, spool: URL) {
        let rejected = spool.appendingPathComponent(MailboxDeliveryReceipt.rejectedDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: rejected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = rejected.appendingPathComponent("\(name).\(MailboxDeliveryReceipt.droppedExtension)")
        let record: [String: Any] = ["receipt": name, "dropped": dropped]
        if JSONSerialization.isValidJSONObject(record),
           let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: target, options: .atomic)
        }
    }

    private func reject(_ url: URL, as name: String, spool: URL) {
        let rejected = spool.appendingPathComponent(MailboxDeliveryReceipt.rejectedDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: rejected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = rejected.appendingPathComponent(name)
        if rename(url.path, target.path) != 0 {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Puts back `.<name>.<pid>.claim` files whose claiming process is gone
    /// (it died between claim and delete), so they are processed again;
    /// the log check then skips what that process already recorded.
    private func recoverAbandonedClaims(in entries: [URL], spool: URL) -> [URL] {
        var recovered: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), url.pathExtension == Self.claimSuffix else { continue }
            let parts = name.dropFirst().split(separator: ".")
            // <ulid>.receipt.<pid>.claim
            guard parts.count == 4, let pid = pid_t(parts[2]) else { continue }
            if pid == getpid() { continue }
            if kill(pid, 0) == 0 || errno != ESRCH { continue }
            let original = spool.appendingPathComponent("\(parts[0]).\(parts[1])")
            if rename(url.path, original.path) == 0 {
                recovered.append(original)
            }
        }
        return recovered
    }

    private func removeStaleTempFiles(in entries: [URL]) {
        let now = Date()
        for url in entries where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "tmp" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.staleTempAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Spools that held receipts while the event log was not recording yet;
    /// retried together until it is.
    private func scheduleRetry(spool: URL, workspaceId: UUID) {
        let first = retrySpools.isEmpty
        retrySpools[workspaceId] = spool
        guard first else { return }
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self else { return }
            let pending = self.retrySpools
            self.retrySpools = [:]
            for (workspaceId, spool) in pending {
                self.sweep(spool: spool, workspaceId: workspaceId)
            }
        }
    }

    /// Ids already recorded as `mailbox.delivered` via drain in any event log
    /// written to at or after `since` (rolled generations included). Reads v1
    /// and v2 lines alike: `mailbox.delivered` kept its type and payload keys
    /// in v2 (C11-337); only the envelope's subject key changed.
    private func loggedDrainDeliveryIds(since: Date) -> Set<String> {
        guard let directory = eventsDirectory() else { return [] }
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var ids: Set<String> = []
        for file in files where file.lastPathComponent.hasPrefix(EventLogLayout.logFilePrefix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified >= since.addingTimeInterval(-2),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"drain\"") && line.contains("mailbox.delivered") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      object["type"] as? String == "mailbox.delivered",
                      let payload = object["payload"] as? [String: Any],
                      payload["via"] as? String == "drain",
                      let id = payload["id"] as? String else { continue }
                ids.insert(id)
            }
        }
        return ids
    }
}
