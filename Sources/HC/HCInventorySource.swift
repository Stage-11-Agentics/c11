import Foundation

/// One subscription/reducer for a connection. Snapshot installation happens
/// before channel activation releases early events. UI delivery is coalesced;
/// admission reads the reducer immediately on its independent serial queue.
final class HCLiveInventorySource: HCInventorySource, HCMachineRouteSink, @unchecked Sendable {
    /// C11H-332: the last `machine.list` answer (touched only on `queue`).
    private var machineList: HCJSONValue?

    func lastMachineList() async -> HCJSONValue? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.machineList) } }
    }

    func refusedMachines() async -> [String: HCMachineRefusal] {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.reducer.refusedMachines) } }
    }

    private let queue = DispatchQueue(label: "c11.hc.inventory", qos: .userInitiated)
    private let connection: any HCConnection
    private var reducer: HCInventoryReducer
    private var lines = HCEventLines()
    private let inboundBudget: HCInboundBudget
    private var retainedEventBytes = 0
    private var channel: (any HCChannel)?
    private var subscription: UInt64 = 0
    private var refreshing = false
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5
    private var refreshWaiters: [CheckedContinuation<HCInventorySnapshot, Never>] = []
    private var observers: [UUID: HCInventoryDelivery] = [:]
    private var publishScheduled = false
    private var invalidated = false
    private var statusEnrichments: [HCTerminalKey: StatusEnrichment] = [:]
    private let report: @Sendable (HCUnavailableReason) -> Void
    private let diagnostics: HCTransportReporter
    /// C11H-16: hc doc events from another machine, and a renewed subscription
    /// (events may have been missed). The reducer ignores docs; the relay reads them.
    private let docSignals: (@Sendable (HCDocSignal) -> Void)?
    /// How long one refresh may take before the snapshot reports pending.
    /// Production keeps HCLimits.connectSeconds; tests scale it down.
    private let refreshTimeout: TimeInterval

    init(connection: any HCConnection, buildIdentity: HCBuildIdentity? = nil,
         report: @escaping @Sendable (HCUnavailableReason) -> Void = { _ in },
         diagnostics: @escaping HCTransportReport = { _, _, _ in },
         refreshTimeout: TimeInterval = HCLimits.connectSeconds,
         docSignals: (@Sendable (HCDocSignal) -> Void)? = nil,
         reservedCoreIDs: @escaping @Sendable () -> Set<String> = { [] }) {
        self.connection = connection; self.report = report; self.refreshTimeout = refreshTimeout
        self.docSignals = docSignals
        self.diagnostics = HCTransportReporter(diagnostics)
        inboundBudget = (connection as? HCUnixConnection)?.engine.inboundBudget ?? HCInboundBudget()
        reducer = HCInventoryReducer(generation: connection.generation, coreID: connection.peer.coreID,
                                     buildIdentity: buildIdentity ?? connection.verification.identity,
                                     reservedCoreIDs: reservedCoreIDs)
    }

    private var currentSnapshot: HCInventorySnapshot {
        let value = reducer.snapshot
        guard refreshing else { return value }
        return HCInventorySnapshot(readiness: .pending(.inventoryPending), revision: value.revision,
            records: value.records, buildIdentity: value.buildIdentity, panelBindings: value.panelBindings, machines: value.machines)
    }

    func observe(on target: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        let id = UUID(); let delivery = HCInventoryDelivery(target: target, handler: handler)
        queue.async {
            self.observers[id] = delivery
            delivery.offer(self.currentSnapshot)
        }
        return HCObservation { [weak self] in
            delivery.cancel()
            self?.queue.async { [weak self] in self?.observers.removeValue(forKey: id) }
        }
    }

    func snapshot() async -> HCInventorySnapshot {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.currentSnapshot) } }
    }

    func refresh() async -> HCInventorySnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                // Bound caller waiters independently of stream and RPC buffers.
                guard self.refreshWaiters.count < HCLimits.pendingRPCs, !self.invalidated else {
                    continuation.resume(returning: self.currentSnapshot); return
                }
                self.refreshWaiters.append(continuation)
                self.startRefresh()
            }
        }
    }

    private struct StatusEnrichment {
        let id: UUID
        let target: HCInventoryReducer.StatusTarget
        let subscription: UInt64
        var waiters: [CheckedContinuation<HCTerminalRecord?, Never>]
    }

    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? {
        // The deadline starts at entry, including admission onto the queue.
        let deadline = HCMonotonic.deadline(after: 2)
        return await withCheckedContinuation { continuation in
            queue.async {
                guard HCMonotonic.now < deadline, !self.invalidated, !self.refreshing,
                      connectionGeneration == self.connection.generation,
                      let target = self.reducer.statusTarget(for: key, status: status, turn: turn) else {
                    continuation.resume(returning: nil); return
                }
                if var pending = self.statusEnrichments[key] {
                    // Coalesce callers without retaining an unbounded waiter list.
                    guard pending.target == target, pending.subscription == self.subscription,
                          pending.waiters.count < 16 else { continuation.resume(returning: nil); return }
                    pending.waiters.append(continuation)
                    self.statusEnrichments[key] = pending
                    self.diagnostics.emit("hc_status_enrichment_coalesced", generation: connectionGeneration)
                    return
                }
                guard self.statusEnrichments.count < 16 else { continuation.resume(returning: nil); return }
                let id = UUID()
                self.statusEnrichments[key] = StatusEnrichment(id: id, target: target,
                    subscription: self.subscription, waiters: [continuation])
                self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
                    self.finishStatusEnrichment(key: key, id: id, reply: nil)
                }
                Task {
                    let reply = try? await self.connection.request(HCRPCRequest(method: "terminal.get",
                        params: .object(["terminal": .string("\(key.owningCoreID)/\(key.localAddress)")]),
                        deadlineUptimeNanoseconds: deadline))
                    self.queue.async {
                        self.finishStatusEnrichment(key: key, id: id,
                            reply: HCMonotonic.now < deadline ? reply : nil)
                    }
                }
            }
        }
    }

    private func finishStatusEnrichment(key: HCTerminalKey, id: UUID, reply: HCJSONValue?) {
        guard let pending = statusEnrichments[key], pending.id == id else { return }
        statusEnrichments.removeValue(forKey: key)
        var enriched: HCTerminalRecord?
        if !invalidated, !refreshing, pending.subscription == subscription, let reply {
            enriched = reducer.installStatusTimestamp(reply, matching: pending.target)
        }
        if enriched != nil { publish(immediate: true) }
        for waiter in pending.waiters { waiter.resume(returning: enriched) }
    }

    private func cancelStatusEnrichments() {
        let pending = statusEnrichments.values
        statusEnrichments.removeAll()
        for value in pending { for waiter in value.waiters { waiter.resume(returning: nil) } }
    }

    private func startRefresh() {
        guard !refreshing, !invalidated else { return }
        retryWork?.cancel(); retryWork = nil
        cancelStatusEnrichments()
        refreshing = true; subscription += 1
        let token = subscription
        diagnostics.emit("hc_inventory_resnapshot_start", generation: connection.generation)
        channel?.close(); channel = nil; lines = HCEventLines()
        inboundBudget.release(retainedEventBytes); retainedEventBytes = 0
        reducer.invalidate(.inventoryPending); publish(immediate: true)
        queue.asyncAfter(deadline: .now() + refreshTimeout) {
            guard self.refreshing, self.subscription == token else { return }
            self.subscription += 1; self.refreshing = false
            self.reducer.invalidate(.deadlineExceeded); self.publish(immediate: true); self.completeWaiters()
            self.diagnostics.emit("hc_inventory_timeout", generation: self.connection.generation)
            self.report(.deadlineExceeded)
            self.scheduleRetry(after: .deadlineExceeded)
        }
        Task {
            do {
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(refreshTimeout * 1e9)
                let machines = try await connection.request(HCRPCRequest(method: "machine.list", params: .object([:]), deadlineUptimeNanoseconds: deadline))
                let initial = try await connection.request(HCRPCRequest(method: "events.subscribe", params: .object([:]), deadlineUptimeNanoseconds: deadline))
                guard let channelID = initial["channel"].integer.flatMap(UInt32.init(exactly:)), channelID > 0 else {
                    throw HCUnavailableReason.malformedResponse
                }
                let sink = HCInventorySink(source: self, token: token)
                let opened = try await connection.registerChannel(channelID, attachmentGeneration: connection.generation, sink: sink)
                do {
                    try await install(initial, machines: machines, token: token)
                    try await opened.activate()
                } catch { opened.close(); throw error }
                queue.async {
                    guard token == self.subscription, !self.invalidated else { opened.close(); return }
                    self.channel = opened; self.refreshing = false
                    self.diagnostics.emit("hc_inventory_resnapshot_complete", generation: self.connection.generation)
                    self.docSignals?(.resubscribed)
                    // Early event consume callbacks finish during activate
                    // before this completion. Their gap/failure wins over readiness.
                    self.publish(immediate: true)
                    self.completeWaiters()
                    if self.reducer.needsRefresh { self.startRefresh() }
                    else { self.retryDelay = 0.5 }
                }
            } catch {
                queue.async {
                    guard token == self.subscription else { return }
                    self.refreshing = false
                    self.reducer.invalidate(HCUnavailableReason.transportReason(error))
                    self.publish(immediate: true); self.completeWaiters()
                    self.report(HCUnavailableReason.transportReason(error))
                    self.scheduleRetry(after: HCUnavailableReason.transportReason(error))
                }
            }
        }
    }

    /// A refresh can lose its event channel while the core is only slow. Re-arm
    /// without an external caller, but keep one attempt/timer and a bounded rate.
    /// Connection replacement remains the session owner's responsibility.
    private func scheduleRetry(after reason: HCUnavailableReason) {
        guard !invalidated, !refreshing, retryWork == nil else { return }
        switch reason {
        case .connectionLost, .cancelled, .foreignBuild, .foreignSession, .pinMismatch,
             .incompatibleProtocol, .invalidLaunchTuple, .staleIdentity: return
        default: break
        }
        let token = subscription
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.invalidated, !self.refreshing, self.subscription == token else { return }
            self.retryWork = nil
            self.startRefresh()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 2)
    }

    private func install(_ initial: HCJSONValue, machines: HCJSONValue, token: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard token == self.subscription, !self.invalidated else { continuation.resume(throwing: HCUnavailableReason.staleIdentity); return }
                do {
                    try self.reducer.setMachines(machines); try self.reducer.install(initial)
                    self.machineList = machines
                    // C11H-359: a refused machine or a doubled address is
                    // skipped, never a refused shard; each is logged.
                    if !self.reducer.refusedMachines.isEmpty {
                        self.diagnostics.emit("hc_inventory_machine_refused", generation: self.connection.generation)
                    }
                    self.noteDroppedDuplicates()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    fileprivate func consume(_ chunk: HCOutputChunk, token: UInt64) async -> HCOutputConsumption {
        await withCheckedContinuation { continuation in
            queue.async {
                guard token == self.subscription, !self.invalidated, chunk.attachmentGeneration == self.connection.generation else {
                    continuation.resume(returning: .stale); return
                }
                do {
                    try self.lines.feed(chunk.bytes) { message in
                        try self.reducer.apply(message, generation: self.connection.generation)
                        if let signal = HCDocSignal(message) { self.docSignals?(signal) }
                        if message["method"].string == "missed" {
                            self.diagnostics.emit("hc_inventory_missed", generation: self.connection.generation)
                            self.noteDroppedDuplicates()
                        }
                    }
                    let difference = self.lines.pending.count - self.retainedEventBytes
                    if difference > 0 {
                        guard self.inboundBudget.reserve(difference) else { throw HCUnavailableReason.bufferOverflow }
                    } else { self.inboundBudget.release(-difference) }
                    self.retainedEventBytes = self.lines.pending.count
                    self.publish(immediate: self.reducer.needsRefresh)
                    let refresh = self.reducer.needsRefresh
                    // Consumption, including event parsing, precedes credit.
                    continuation.resume(returning: .consumed)
                    if refresh {
                        self.diagnostics.emit("hc_inventory_gap", generation: self.connection.generation)
                        self.startRefresh()
                    }
                } catch {
                    self.diagnostics.emit("hc_inventory_malformed", generation: self.connection.generation)
                    self.lines = HCEventLines()
                    self.inboundBudget.release(self.retainedEventBytes); self.retainedEventBytes = 0
                    self.reducer.invalidate((error as? HCUnavailableReason) ?? .malformedResponse)
                    self.report((error as? HCUnavailableReason) ?? .malformedResponse)
                    self.publish(immediate: true)
                    continuation.resume(returning: .consumed)
                    self.startRefresh()
                }
            }
        }
    }

    /// C11H-359: an install (a subscribe's snapshot or a `missed` frame) that
    /// dropped a doubled address is logged once. Called on `queue`.
    private func noteDroppedDuplicates() {
        if reducer.takeDroppedDuplicateAddresses() > 0 {
            diagnostics.emit("hc_inventory_duplicate_address", generation: connection.generation)
        }
    }

    fileprivate func retired(token: UInt64) {
        queue.async {
            guard token == self.subscription, !self.invalidated else { return }
            self.reducer.invalidate(.connectionLost); self.publish(immediate: true)
            self.report(.connectionLost)
            if !self.refreshing { self.startRefresh() }
        }
    }

    func invalidate(_ reason: HCUnavailableReason) {
        queue.async {
            self.cancelStatusEnrichments()
            self.invalidated = true; self.refreshing = false; self.subscription += 1
            self.retryWork?.cancel(); self.retryWork = nil
            self.channel?.close(); self.channel = nil
            self.reducer.invalidate(reason); self.publish(immediate: true); self.completeWaiters()
        }
    }

    private func completeWaiters() {
        let waiters = refreshWaiters; refreshWaiters = []
        let snapshot = currentSnapshot
        for waiter in waiters { waiter.resume(returning: snapshot) }
    }

    /// Ticket 12: hc carries no line state on the event stream. A machine.list
    /// poll lands here; an availability change republishes at once. A changed
    /// machine set (one added or removed) needs a fresh snapshot, because the
    /// remote records it routes are decoded against these routes.
    func applyMachines(_ value: HCJSONValue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                guard !self.invalidated, !self.refreshing, case .ready = self.reducer.readiness else { return }
                let before = self.reducer.snapshot.machines
                var next = self.reducer
                guard (try? next.setMachines(value)) != nil else { return }
                let after = next.snapshot.machines
                // C11H-359: a machine newly refused (or no longer) is kept even
                // when the routes are unchanged, so the session and Settings see it.
                guard after != before || next.refusedMachines != self.reducer.refusedMachines else { return }
                if Set(after.keys) != Set(before.keys) {
                    // REPAIR-2: keep the judgement this poll made, so a creation
                    // that reads the refusals while the resnapshot is pending
                    // sees it. startRefresh makes the inventory pending at once.
                    self.reducer = next
                    self.startRefresh()
                } else {
                    self.reducer = next
                    self.publish(immediate: true)
                }
            }
        }
    }

    private func publish(immediate: Bool = false) {
        if immediate {
            let snapshot = currentSnapshot
            for observer in observers.values { observer.offer(snapshot) }
        } else if !publishScheduled {
            publishScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self.publishScheduled = false
                let snapshot = self.currentSnapshot
                for observer in self.observers.values { observer.offer(snapshot) }
            }
        }
    }

    deinit { retryWork?.cancel(); inboundBudget.release(retainedEventBytes); channel?.close() }
}

private final class HCInventorySink: HCOutputSink, @unchecked Sendable {
    weak var source: HCLiveInventorySource?
    let token: UInt64
    init(source: HCLiveInventorySource, token: UInt64) { self.source = source; self.token = token }
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        guard let source else { return .stale }; return await source.consume(chunk, token: token)
    }
    func retire(completion: @escaping @Sendable () -> Void) { source?.retired(token: token); completion() }
}

/// At most one queued callback plus one latest snapshot per observer, even if
/// its target queue is suspended. Initial delivery is never replaced.
private final class HCInventoryDelivery: @unchecked Sendable {
    let lock = NSLock()
    let target: DispatchQueue
    let handler: @Sendable (HCInventorySnapshot) -> Void
    var first: HCInventorySnapshot?
    var latest: HCInventorySnapshot?
    var scheduled = false
    var active = true
    var initialDelivered = false
    init(target: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) {
        self.target = DispatchQueue(label: "c11.hc.inventory.observer", target: target); self.handler = handler
    }
    func offer(_ snapshot: HCInventorySnapshot) {
        lock.lock()
        guard active else { lock.unlock(); return }
        if !initialDelivered && first == nil { first = snapshot } else { latest = snapshot }
        guard !scheduled else { lock.unlock(); return }
        scheduled = true; lock.unlock()
        target.async { self.drain() }
    }
    private func drain() {
        lock.lock()
        guard active else { scheduled = false; lock.unlock(); return }
        let next = first ?? latest
        if first != nil { first = nil; initialDelivered = true } else { latest = nil }
        lock.unlock()
        if let next { handler(next) }
        lock.lock()
        if active && (first != nil || latest != nil) { lock.unlock(); target.async { self.drain() } }
        else { scheduled = false; lock.unlock() }
    }
    func cancel() { lock.lock(); active = false; first = nil; latest = nil; lock.unlock() }
}

/// Inject this bundle into 2A's session composition; only 2C activates panels.
struct HCLiveSessionFactory: Sendable {
    let connectionFactory: HCLiveConnectionFactory
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> (any HCConnection, HCLiveInventorySource) {
        let connection = try await connectionFactory.connect(request, verify: verify)
        let inventory = HCLiveInventorySource(connection: connection)
        _ = await inventory.refresh()
        return (connection, inventory)
    }
}


/// A document change on another machine, as hc's event stream reports it
/// (`{"method":"event","params":{"type":"doc","machine":m,"data":{"name","version"}}}`).
/// This core's own documents carry no `machine` and are not relay traffic.
enum HCDocSignal: Equatable, Sendable {
    case doc(machine: String, name: String, version: UInt64)
    case resubscribed
    /// hc replaced a burst of events with a snapshot; doc events in it are lost.
    case missed

    init?(_ message: HCJSONValue) {
        if message["method"].string == "missed" { self = .missed; return }
        guard message["method"].string == "event", message["params"]["type"].string == "doc",
              let machine = message["params"]["machine"].string, !machine.isEmpty,
              let name = message["params"]["data"]["name"].string,
              let version = message["params"]["data"]["version"].uint else { return nil }
        self = .doc(machine: machine, name: name, version: version)
    }
}
