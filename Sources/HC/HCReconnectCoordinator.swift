import Foundation

enum HCReconnectStatus: Equatable, Sendable {
    case waiting(HCUnavailableReason)
    case attaching
    case attached(UInt64)
    case ended
    case recovering
    case recoveryRequired(HCUnavailableReason)
    case stopped
}

/// Client attachment recovery only. HCSession owns core launch, connection
/// retries and authoritative lifecycle resolution; hc owns its holders.
/// Main-actor work is limited to panel state. Session/attachment work is async.
@MainActor
final class HCReconnectCoordinator {
    typealias Attach = @MainActor (HCTerminalRecord) async throws -> any HCAttachment
    typealias Detach = @MainActor (any HCAttachment) -> Void
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private(set) var identity: HCPanelIdentity
    private(set) var status: HCReconnectStatus = .waiting(.inventoryPending)
    private(set) var lifecycle: HCLifecycle
    private(set) var attachment: (any HCAttachment)?
    private(set) var attempts = 0

    private let session: any HCSession
    private let attach: Attach
    private let detachAttachment: Detach
    private let sleep: Sleep
    private let retryDelay: TimeInterval
    private let changed: @MainActor (HCReconnectCoordinator) -> Void
    private let attachmentChanged: @MainActor ((any HCAttachment)?) -> Void
    private var observation: HCObservation?
    private var task: Task<Void, Never>?
    #if DEBUG
    /// Lets composition tests await an obsolete attempt after releasing its resolver.
    var pendingAttemptForTesting: Task<Void, Never>? { task }
    #endif
    private var operation: UInt64 = 0
    private var running = false
    private var inventoryRevision: HCRevision?
    /// The shard the ratchet is for. A panel whose terminal moves to another
    /// shard starts a new ratchet: revisions never compare across shards (A1.L4).
    private var inventorySource: HCShardID?
    private var readiness: HCReadiness?

    init(
        identity: HCPanelIdentity,
        session: any HCSession,
        retryDelay: TimeInterval = 1,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        attach: @escaping Attach,
        detach: @escaping Detach = { $0.detach() },
        attachmentChanged: @escaping @MainActor ((any HCAttachment)?) -> Void = { _ in },
        changed: @escaping @MainActor (HCReconnectCoordinator) -> Void = { _ in }
    ) {
        self.identity = identity
        self.lifecycle = .unresolved(identity, .inventoryPending)
        self.session = session
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.attach = attach
        self.detachAttachment = detach
        self.attachmentChanged = attachmentChanged
        self.changed = changed
    }

    func start() {
        guard !running, identity.persistence == .persistent else { return }
        running = true
        observeInventory()
        wait(.inventoryPending)
        schedule(after: 0)
    }

    /// Every runtime bind transfers attachment ownership here before input opens.
    /// A native surface can finish starting while our retry is suspended; its
    /// verified binding supersedes that attempt, including a late resolve result.
    @discardableResult
    func start(attached: any HCAttachment, record: HCTerminalRecord) -> Bool {
        guard identity.persistence == .persistent, identity.key == nil || identity.key == record.key,
              attached.key == record.key, record.state == .running, record.pid != nil,
              record.machineAvailability == .local || record.machineAvailability == .connected else { return false }
        if running, attachment === attached { return true }
        // A bind inside attach(record) cancels that very attempt's task. Its
        // post-bind return path must preserve the adopted port, even though
        // the task is cancelled; do not add a cancellation throw after binding.
        cancelAttempt()
        detach()
        let needsObservation = !running
        running = true
        identity = HCPanelIdentity(panelID: identity.panelID, key: record.key,
            persistence: identity.persistence, creationID: identity.creationID, origin: identity.origin)
        attachment = attached
        lifecycle = .live(record)
        status = .attached(attached.generation)
        if needsObservation { observeInventory() }
        attachmentChanged(attached)
        changed(self)
        return true
    }

    private func observeInventory() {
        observation = session.observe(on: .main) { [weak self] snapshot in
            // HCSession delivers on the nominated serial queue. Consume inline
            // so pending/ready transitions cannot reorder in separate Tasks.
            MainActor.assumeIsolated { self?.receive(snapshot) }
        }
    }

    /// The attachment owner reports loss with its generation. An old reader's
    /// late completion must never detach the replacement attachment.
    func disconnected(generation: UInt64, reason: HCUnavailableReason = .connectionLost) {
        guard running, attachment?.generation == generation else { return }
        cancelAttempt()
        detach()
        wait(reason)
        schedule(after: 0)
    }

    /// Disposing a view detaches; ending the terminal remains the panel owner's
    /// separate action. Neither stop nor any retry creates/ends a terminal.
    func stop() {
        running = false
        observation?.cancel()
        observation = nil
        cancelAttempt()
        detach()
        status = .stopped
        changed(self)
    }

    /// Explicit operator recovery, never an automatic restart loop. The
    /// session supplies the frozen 30-second identity-verified recovery gate.
    func retryRecovery(reason: HCRecoveryReason) async {
        guard running, status != .recovering else { return }
        cancelAttempt()
        detach()
        let current = operation
        lifecycle = .unresolved(identity, .recoveryRequired)
        status = .recovering
        changed(self)
        let result = await session.recoverSession(reason: reason)
        guard running, current == operation else { return }
        switch result {
        case .recovered:
            wait(.inventoryPending)
            schedule(after: 0)
        case .refused(let reason), .recoveryRequired(let reason):
            requireRecovery(reason)
        }
    }

    private func receive(_ snapshot: HCInventorySnapshot) {
        guard running else { return }
        let sourceChanged = snapshot.source != inventorySource
        if sourceChanged {
            inventorySource = snapshot.source
            inventoryRevision = nil
        }
        if let previous = inventoryRevision {
            guard snapshot.revision.connectionGeneration > previous.connectionGeneration ||
                    (snapshot.revision.connectionGeneration == previous.connectionGeneration &&
                     snapshot.revision.sequence >= previous.sequence) else { return }
        }
        let generationChanged = sourceChanged && readiness != nil || inventoryRevision.map {
            $0.connectionGeneration != snapshot.revision.connectionGeneration
        } ?? false
        let readinessChanged = readiness != snapshot.readiness
        let wasReady: Bool
        if case .ready? = readiness { wasReady = true } else { wasReady = false }
        inventoryRevision = snapshot.revision
        readiness = snapshot.readiness
        // Do not restart an in-flight resolution on every ordinary event.
        guard generationChanged || readinessChanged else { return }
        if case .recoveryRequired = status {
            // Another panel (or the session's automatic recovery) may have
            // completed recovery while our resolve reported it in progress.
            // Fresh readiness permits resolve/attach, never another restart.
            guard case .ready = snapshot.readiness, generationChanged || !wasReady else { return }
            wait(.inventoryPending)
            schedule(after: 0)
            return
        }
        if status == .recovering { return }
        switch snapshot.readiness {
        case .pending(let reason):
            // A read-only inventory deadline is not a DATA transport failure.
            // hc can remain open while its core/holder backlog takes seconds
            // to drain. Only a changed generation or actual loss retires it.
            if !generationChanged, attachment != nil,
               reason == .inventoryPending || reason == .deadlineExceeded { return }
            cancelAttempt()
            detach()
            wait(reason)
            schedule(after: retryDelay)
        case .ready:
            if generationChanged {
                cancelAttempt()
                detach()
            }
            if attachment == nil, task == nil { schedule(after: 0) }
        }
    }

    private func schedule(after delay: TimeInterval) {
        guard running, task == nil else { return }
        let current = operation
        let sleep = sleep
        task = Task { [weak self] in
            do {
                if delay > 0 { try await sleep(delay) }
                try Task.checkCancellation()
            } catch { return }
            await self?.attempt(current)
        }
    }

    private func attempt(_ current: UInt64) async {
        guard running, current == operation else { return }
        attempts += 1
        let result = await session.resolve(identity)
        HCTrace.log("reconnect.attempt panel=\(identity.panelID.uuidString.prefix(8)) n=\(attempts) resolved=\(result) " +
            "current=\(running && current == operation)")
        guard running, current == operation else { return }
        switch result {
        case .new:
            // Reconnect never creates, even if a resolver returns new for a
            // keyless restored panel. Its creation owner reconciles the intent.
            retry(.inventoryPending)
        case .unresolved(_, let reason):
            if requiresRecovery(reason) { requireRecovery(reason) }
            else { retry(reason) }
        case .ended(let proof):
            lifecycle = .ended(proof)
            status = .ended
            task = nil
            observation?.cancel()
            observation = nil
            running = false
            changed(self)
        case .live(let record):
            guard identity.key == nil || identity.key == record.key else {
                requireRecovery(.staleIdentity)
                return
            }
            guard record.state == .running, record.pid != nil,
                  record.machineAvailability == .local || record.machineAvailability == .connected else {
                retry(.inventoryPending)
                return
            }
            status = .attaching
            changed(self)
            guard running, current == operation else { return }
            do {
                let candidate = try await attach(record)
                guard running, current == operation else {
                    // The runtime binds inside attach(record), so it may have
                    // adopted this very candidate and superseded our operation.
                    // Only an unowned late result belongs to this cleanup path.
                    guard attachment !== candidate else { return }
                    candidate.input.invalidate(generation: candidate.generation, reason: .cancelled)
                    detachAttachment(candidate)
                    return
                }
                guard candidate.key == record.key else {
                    candidate.input.invalidate(generation: candidate.generation, reason: .staleIdentity)
                    detachAttachment(candidate)
                    requireRecovery(.staleIdentity)
                    return
                }
                identity = HCPanelIdentity(panelID: identity.panelID, key: record.key,
                                           persistence: identity.persistence, creationID: identity.creationID,
                                           origin: identity.origin)
                attachment = candidate
                lifecycle = .live(record)
                status = .attached(candidate.generation)
                task = nil
                attachmentChanged(candidate)
                changed(self)
            } catch {
                HCTrace.log("reconnect.attachFailed panel=\(identity.panelID.uuidString.prefix(8)) error=\(error)")
                guard running, current == operation else { return }
                let reason = (error as? HCUnavailableReason) ?? .connectionLost
                if requiresRecovery(reason) { requireRecovery(reason) }
                else { retry(reason) }
            }
        }
    }

    private func retry(_ reason: HCUnavailableReason) {
        HCTrace.log("reconnect.retry panel=\(identity.panelID.uuidString.prefix(8)) reason=\(reason) after=\(retryDelay)s")
        task = nil
        wait(reason)
        // No elapsed-outage or attempt-count cutoff. Individual operations
        // have HCSession's bounds, and stop cancels the scheduled wait.
        schedule(after: retryDelay)
    }

    private func wait(_ reason: HCUnavailableReason) {
        lifecycle = .unresolved(identity, reason)
        status = .waiting(reason)
        changed(self)
    }

    private func requireRecovery(_ reason: HCUnavailableReason) {
        HCTrace.log("reconnect.parked panel=\(identity.panelID.uuidString.prefix(8)) reason=\(reason) (no automatic retry)")
        task = nil
        lifecycle = .unresolved(identity, reason)
        status = .recoveryRequired(reason)
        changed(self)
    }

    private func requiresRecovery(_ reason: HCUnavailableReason) -> Bool {
        switch reason {
        case .recoveryRequired, .foreignBuild, .foreignSession, .pinMismatch,
             .invalidLaunchTuple, .incompatibleProtocol, .creationUncertain,
             .staleIdentity, .ambiguousIdentity:
            return true
        default:
            return false
        }
    }

    private func cancelAttempt() {
        operation &+= 1
        task?.cancel()
        task = nil
    }

    private func detach() {
        guard let previous = attachment else { return }
        attachment = nil
        previous.input.invalidate(generation: previous.generation, reason: .unavailable)
        attachmentChanged(nil)
        // HCPanelSession's composition hook owns native retirement. It also
        // receives obsolete candidates, which must not retire a newer binding.
        detachAttachment(previous)
    }

    deinit {
        task?.cancel()
        observation?.cancel()
        if let attachment {
            let detachAttachment = detachAttachment
            Task { @MainActor in detachAttachment(attachment) }
        }
    }
}
