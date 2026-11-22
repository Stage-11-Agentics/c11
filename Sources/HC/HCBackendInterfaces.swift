import Foundation

/// All these interfaces are off-main unless annotated. No implementation may
/// synchronously wait for an output/reader worker from the main thread.
protocol HCSession: Sendable {
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle
    func create(_ request: HCCreateRequest) async -> HCCreateResult
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment
    func end(_ key: HCTerminalKey) async -> HCEndResult
    func diagnostics() async -> HCDiagnostics
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult
}

protocol HCAttachment: AnyObject, Sendable {
    var key: HCTerminalKey { get }
    var generation: UInt64 { get }
    var input: any HCInputPort { get }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt?
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome
    /// Returns immediately. Retires sink/IO before native surface destruction.
    func detach()
}

protocol HCInputPort: Sendable {
    func submit(_ request: HCInputRequest) async -> HCInputOutcome
    /// Native callback lane: must enqueue or latch a visible fault, never wait.
    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64)
    func invalidate(generation: UInt64, reason: HCInputRefusal)
}

enum HCRawInputKind: Sendable { case key, paste, query }

protocol HCScreenProvider: Sendable {
    /// Must bound the wait to HCLimits.screenSeconds; no receipt from a timer.
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt?
}

protocol HCOutputSink: Sendable {
    /// Called in order on one channel's worker. Credit follows completion.
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption
    /// Schedules retirement, then calls completion after outstanding output.
    func retire(completion: @escaping @Sendable () -> Void)
}

struct HCOutputChunk: Sendable {
    let attachmentGeneration: UInt64
    let watermark: UInt64
    let bytes: Data
}
enum HCOutputConsumption: Sendable { case consumed, stale, failed(HCUnavailableReason) }

/// Why c11 refuses a machine hc lists (C11H-359). A refused machine gets no
/// route: its terminals never enter c11's key space, and the rest of the
/// list, and the shard, carry on.
enum HCMachineRefusal: String, Equatable, Sendable {
    /// No core id, or no state.
    case missingID = "missing_id"
    /// It claims the core id of one of this app's own cores.
    case localCoreID = "local_core_id"
    /// Its name, or its core id, is listed twice.
    case duplicate
}

protocol HCInventorySource: Sendable {
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation
    func snapshot() async -> HCInventorySnapshot
    /// One bounded resubscribe; an unavailable snapshot never proves absence.
    func refresh() async -> HCInventorySnapshot
    /// Bounded owning-core time enrichment; nil supplies no completion evidence.
    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord?
    /// C11H-332: the core's last `machine.list` answer this source fetched
    /// (each machine's via), so stored links are reviewed with no extra call.
    func lastMachineList() async -> HCJSONValue?
    /// C11H-359: machines the last list refused, and why.
    func refusedMachines() async -> [String: HCMachineRefusal]
}

extension HCInventorySource {
    func lastMachineList() async -> HCJSONValue? { nil }
    func refusedMachines() async -> [String: HCMachineRefusal] { [:] }

    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? { nil }
}

/// The callback is taken under the lock, invoked outside it, and invoked once.
/// This lock is not on a native output path and never protects client work.
final class HCObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancel: @escaping @Sendable () -> Void = {}) { cancellation = cancel }

    func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit { cancel() }
}

/// C11H-313: how an explicit close reaches a creation that runs shielded from
/// its caller (C11H-308), and how it hears that a creation settled with no run,
/// which produces no hc event and so no inventory revision.
protocol HCCreationSettling: Sendable {
    /// The panel is closing: every creation for it that is under way, and the
    /// creation it carries (which may not have started yet), declines to start
    /// if it has not claimed yet. Synchronous and nonblocking, so it lands
    /// before the close's own cancel. Only explicit ends call it; a reattach,
    /// move or Quit cancels a start without declining its creation.
    func declineCreations(panelID: UUID, carrying creationID: UUID?)
    /// `handler` runs on `queue` with the panel id each time one of that
    /// panel's creations is recorded as never run.
    func observeCreationSettlements(on queue: DispatchQueue,
                                    handler: @escaping @Sendable (UUID) -> Void) -> HCObservation
    /// The identity's own creation as recorded never run, from durable state
    /// alone: no core, connection or inventory is asked (`HCLifecycleResolver.neverRan`).
    func recordedNeverRun(_ identity: HCPanelIdentity) async -> HCEndEvidence?
}

/// C11H-417: a session let an end go ahead that a c11 app had held (the app
/// no longer carries the terminal's token). Reported before `terminal.kill`, so
/// a kill that then fails or confirms slowly is no longer blamed on the app.
protocol HCCarrierReleaseReporting: Sendable {
    func observeCarrierReleases(on queue: DispatchQueue,
                                handler: @escaping @Sendable (HCTerminalKey) -> Void) -> HCObservation
}

/// C11H-417: the subscribers to one session's carrier releases.
final class HCCarrierReleases: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: (queue: DispatchQueue, handler: @Sendable (HCTerminalKey) -> Void)] = [:]

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCTerminalKey) -> Void) -> HCObservation {
        let id = UUID()
        lock.lock(); subscribers[id] = (queue, handler); lock.unlock()
        return HCObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.subscribers.removeValue(forKey: id); self.lock.unlock()
        }
    }

    func publish(_ key: HCTerminalKey) {
        lock.lock(); let targets = Array(subscribers.values); lock.unlock()
        for target in targets { target.queue.async { target.handler(key) } }
    }
}

/// C11H-313: one session's creations under way, the ones a close declined,
/// and its no-run settlements. A decline of a creation under way is kept until
/// that creation ends; only a decline of a creation not yet started (a close
/// names its panel's creation whether or not one is coming) is bounded.
final class HCCreationSettlements: @unchecked Sendable {
    static let declineMemory = 512
    private let lock = NSLock()
    private var underWay: [UUID: UUID] = [:]
    private var declinedUnderWay: Set<UUID> = []
    private var declinedAhead: Set<UUID> = []
    private var aheadOrder: [UUID] = []
    private var subscribers: [UUID: (queue: DispatchQueue, handler: @Sendable (UUID) -> Void)] = [:]

    /// A creation for `panelID` is under way, from its `create` call to its answer.
    func begin(_ creationID: UUID, panelID: UUID) {
        lock.lock(); defer { lock.unlock() }
        underWay[creationID] = panelID
        if declinedAhead.remove(creationID) != nil {
            aheadOrder.removeAll { $0 == creationID }
            declinedUnderWay.insert(creationID)
        }
    }

    func end(_ creationID: UUID) {
        lock.lock(); defer { lock.unlock() }
        underWay.removeValue(forKey: creationID)
        declinedUnderWay.remove(creationID)
    }

    func decline(panelID: UUID, carrying creationID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        for (creation, panel) in underWay where panel == panelID { declinedUnderWay.insert(creation) }
        guard let creationID, underWay[creationID] == nil, declinedAhead.insert(creationID).inserted else { return }
        aheadOrder.append(creationID)
        if aheadOrder.count > Self.declineMemory { declinedAhead.remove(aheadOrder.removeFirst()) }
    }

    func isDeclined(_ creationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return declinedUnderWay.contains(creationID) || declinedAhead.contains(creationID)
    }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (UUID) -> Void) -> HCObservation {
        let id = UUID()
        lock.lock(); subscribers[id] = (queue, handler); lock.unlock()
        return HCObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.subscribers.removeValue(forKey: id); self.lock.unlock()
        }
    }

    func publish(panelID: UUID) {
        lock.lock(); let targets = Array(subscribers.values); lock.unlock()
        for target in targets { target.queue.async { target.handler(panelID) } }
    }
}

struct HCLaunchConfiguration: Equatable, Sendable {
    let executableURL: URL
    let session: String
    let socketURL: URL
    let stateDirectory: URL
    let intentDirectory: URL
    let environment: [String: String]
    let pin: HCPin
    /// Binaries accepted as already serving (L2). Empty means the launch
    /// binary alone; the bundled tuple adds M1's external pin for the transition.
    var acceptedServing: [HCServingBinary] = []
    /// The core's own `XDG_CONFIG_HOME` (A1), where c11 writes
    /// `herdr-core/config.toml` before a start. nil for a remote tuple.
    var configDirectory: URL? = nil

    var servingBinaries: [HCServingBinary] {
        acceptedServing.isEmpty ? [HCServingBinary(executableURL: executableURL, pin: pin)] : acceptedServing
    }
}

/// Deadline is monotonic and shared across connect, hello, status and identity.
/// A run's separate deadline is at least HCLimits.runSeconds after dispatch.
struct HCConnectionRequest: Sendable {
    let configuration: HCLaunchConfiguration
    let generation: UInt64
    let deadlineUptimeNanoseconds: UInt64
    /// Minimum time a transmitted terminal.run waits for its reply. Production
    /// keeps the default; tests scale it down instead of waiting it out.
    var runBudgetNanoseconds: UInt64 = UInt64(HCLimits.runSeconds * 1e9)
}

struct HCPeerEvidence: Sendable {
    let uid: UInt32
    let pid: Int32
    let statusPID: Int32
    let coreID: String
    let version: String
    let protocolGeneration: Int
    let methods: Set<String>
    let features: Set<String>
}

/// Verification attests the peer and owned session even when its binary is
/// foreign. Only 2A's planned-recovery path may use a same-session foreign build;
/// no terminal operation is admitted until isPinnedBuild is true.
struct HCVerifiedPeer: Sendable {
    let identity: HCBuildIdentity
    let isPinnedBuild: Bool
}

typealias HCServingBuildVerifier = @Sendable (HCPeerEvidence) async throws -> HCVerifiedPeer

protocol HCConnectionFactory: Sendable {
    /// Does not autostart a core. Part 2A alone owns launch/recovery decisions.
    /// Required verifier runs before returning a connection, inside request's
    /// same absolute deadline. Reject and close on failure/expiry; no default.
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection
}

protocol HCConnection: AnyObject, Sendable {
    var generation: UInt64 { get }
    var peer: HCPeerEvidence { get }
    var verification: HCVerifiedPeer { get }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue
    /// Register immediately after the reply. Early frames are bounded by 2B.
    /// Registers a dormant bounded channel. No output reaches sink until activate.
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel
    /// Never blocks a caller waiting for reader/writer retirement.
    func close(reason: HCUnavailableReason)
}

struct HCRPCRequest: Sendable {
    let method: String
    let params: HCJSONValue
    /// Bounds the whole call; with `responseNanosecondsAfterTransmission`, only the wait to be sent.
    let deadlineUptimeNanoseconds: UInt64
    /// C11H-306: the reply's own bound, counted from when the request reached the socket (as `terminal.run`'s is),
    /// so a request queued behind other writes on the shared connection is delayed, not failed.
    var responseNanosecondsAfterTransmission: UInt64? = nil
    /// C11H-327: told when this channel call's caller stopped waiting while the engine still counts it among its
    /// unanswered channel calls, and again when hc's late reply takes it out.
    var lateReply: HCLateReply? = nil
}

/// C11H-327: a channel call (`terminal.attach`, `events.subscribe`) whose caller stopped waiting, timed out or
/// cancelled, stays in the engine's budget of unanswered channel calls until hc's late reply comes; a connection
/// that closes takes the whole budget with it. A caller that must not attach again behind its own unanswered call
/// asks `outstanding`. The engine marks the call expired before its caller resumes, so the caller sees it at once.
final class HCLateReply: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var answered = false

    /// The engine still counts the call: its caller stopped waiting and no reply has come.
    var outstanding: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired && !answered
    }

    /// The engine expired the call and keeps it among its unanswered channel calls.
    func expire() { lock.lock(); expired = true; lock.unlock() }

    /// The engine no longer counts the call: hc's late reply came, or the connection closed.
    func settle() { lock.lock(); answered = true; lock.unlock() }
}

enum HCRPCTransmission: Sendable { case none, possible, rejectedByPeer }
struct HCRPCFailure: Error, Sendable {
    let reason: HCUnavailableReason
    let transmission: HCRPCTransmission
    let remoteCode: String?
}

protocol HCChannel: HCFrameWriter {
    var channelID: UInt32 { get }
    var connectionGeneration: UInt64 { get }
    /// After native input/lease binding, begin draining buffered early output.
    func activate() async throws
    func close()
}

/// One reservation budget for C's native input and B's wire queue; no second
/// uncharged queue. A reservation is single-use and scoped to the connection.
struct HCWriteReservation: Hashable, Sendable {
    let id: UUID
    let operationID: UUID
    let attachmentGeneration: UInt64
    let connectionGeneration: UInt64
    let encodedByteCount: Int
}
enum HCReservationOutcome: Sendable {
    case reserved(HCWriteReservation)
    case refused(HCInputRefusal)
}

enum HCOutboundFrame: Sendable {
    case data(Data)
    case submitReturn(Data)
    /// Ordered paste-settle barrier; control drains while other DATA waits.
    case submitReturnAfter(Data, delayNanoseconds: UInt64)
    case resize(HCGridSize)
    case focus(Bool)
    case facts(HCDisplayFacts)
}
struct HCWriteBatch: Sendable {
    let operationID: UUID
    let attachmentGeneration: UInt64
    let frames: [HCOutboundFrame]
    let beforeReturn: (@Sendable () async -> Bool)?

    init(operationID: UUID, attachmentGeneration: UInt64, frames: [HCOutboundFrame],
         beforeReturn: (@Sendable () async -> Bool)? = nil) {
        self.operationID = operationID
        self.attachmentGeneration = attachmentGeneration
        self.frames = frames
        self.beforeReturn = beforeReturn
    }
}
enum HCControl: Sendable {
    case credit(UInt32)
    case close
    case resize(HCGridSize)
    case focus(Bool)
    case facts(HCDisplayFacts)
}
enum HCControlOutcome: Sendable { case written, coalesced, unavailable(HCUnavailableReason) }

protocol HCFrameWriter: Sendable {
    /// Short nonblocking admission before native encoding; never sends bytes.
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome
    /// Revokes remaining frames/Return, including a write already in flight.
    /// Completion retains the actual byte receipt; a partial frame closes the connection.
    func cancel(_ reservation: HCWriteReservation)
    /// Reserved control capacity; coalesce only across no DATA order barrier.
    func control(_ control: HCControl) async -> HCControlOutcome
}

/// Only the transport boundary deals in JSON. Public lifecycle consumers use
/// HCContract values; integers retain their value instead of round-tripping Double.
indirect enum HCJSONValue: Equatable, Codable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([HCJSONValue]), object([String: HCJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([HCJSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: HCJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
