import Foundation

/// Shared values for the frozen contract. Consumers never infer terminal death
/// from a missing transport, unavailable inventory, or native surface disposal.
struct HCPin: Equatable, Codable, Sendable {
    let version: String
    let archiveSHA256: String
    let executableSHA256: String
    let protocolGeneration: Int

    /// The pin of the core this app starts: the bundled helper's signed hash
    /// (C11H-66), else M1's external pin. See `HCCoreBinary`.
    static var current: HCPin { HCCoreBinary.current.pin }
}

/// hc 0.1.16's local terminal id: `t`, a digit 1–9, then the 30-symbol tail
/// (`0123456789bcdfghjkmnpqrstvwxyz`: no vowels, no `l`). The one rule for
/// attach/put/kill addresses, the diagnostics tokens and c11-core's
/// addresses. It lives here so the app and the c11-core CLI compile one copy.
enum HCLocalTerminalAddress {
    private static let symbols = Set("0123456789bcdfghjkmnpqrstvwxyz")

    static func isValid(_ raw: String) -> Bool {
        guard raw.count >= 2, raw.first == "t" else { return false }
        let rest = raw.dropFirst()
        guard let first = rest.first, first >= "1", first <= "9" else { return false }
        return rest.allSatisfy { symbols.contains($0) }
    }
}

enum HCLimits {
    static let helloBytes = 64 * 1024
    static let frameBytes = 16 * 1024 * 1024
    static let eventBufferBytes = 4 * 1024 * 1024
    static let transactionBytes = 1024 * 1024
    static let queuedInputBytes = 4 * 1024 * 1024
    /// RPC capacity for one `terminal.put` (ticket 12): hc's 8 MiB file limit
    /// as base64 (4/3) plus JSON and framing, under hc's 16 MiB wire payload.
    /// Every other RPC keeps `queuedInputBytes`.
    static let fileTransferRPCBytes = 12 * 1024 * 1024
    static let controlBytes = 256 * 1024
    static let initialCreditBytes = 256 * 1024
    static let outputChunkBytes = 64 * 1024
    static let pendingRPCs = 256
    static let connectSeconds: TimeInterval = 2
    /// Managed reads include hc's concurrent 3 s remote-list probes and a
    /// short reconnect. One absolute budget covers connection and response.
    static let managedReadSeconds: TimeInterval = 12
    static let runSeconds: TimeInterval = 20
    static let recoverySeconds: TimeInterval = 30
    static let creationResolutionSeconds: TimeInterval = 30
    static let screenSeconds: TimeInterval = 2
    static let spawnMilliseconds = 10_000
    static let minimumFileDescriptors: UInt64 = 8192
}

enum HCPersistence: String, Codable, Sendable { case persistent, nonpersistent }
enum HCPanelOrigin: String, Codable, Sendable { case fresh, restored }
enum HCTerminalState: String, Codable, Sendable { case starting, running, finished }
enum HCMachineAvailability: String, Codable, Sendable { case local, connected, disconnected, unknown }

enum HCUnavailableReason: String, Error, Codable, Sendable {
    case backendNotInstalled, coreUnreachable, inventoryPending, connectionLost
    case incompatibleProtocol, foreignBuild, foreignSession, pinMismatch, invalidLaunchTuple
    case fileDescriptorLimit, intentStoreFailure, creationPending, creationUncertain
    case recoveryRequired, inputFault, screenUnavailable, staleIdentity, ambiguousIdentity
    case deadlineExceeded, malformedResponse, bufferOverflow, cancelled
    /// C11H-415: an end waits because a c11 app carries the terminal's `HC_SCOPE` token.
    case appCarriesScope
}

enum HCLifecycle: Sendable {
    case new
    case live(HCTerminalRecord)
    case ended(HCEndEvidence)
    case unresolved(HCPanelIdentity, HCUnavailableReason)
}

enum HCReadiness: Equatable, Sendable {
    case pending(HCUnavailableReason)
    case ready(HCRevision)
}

enum HCEndKind: String, Codable, Sendable {
    case finished, observedRemoval, postAdoptionAbsence, createRejected
}

enum HCCreateResult: Sendable {
    case bound(HCTerminalRecord)
    case rejectedBeforeTransmission(HCUnavailableReason)
    case unresolved(HCPanelIdentity, HCUnavailableReason)
}

enum HCEndResult: Sendable {
    case confirmed(HCEndEvidence)
    case pending(HCTerminalKey)
    case unresolved(HCTerminalKey, HCUnavailableReason)
}

enum HCInputSource: String, Codable, Sendable {
    /// `filePaste` is the operator's clipboard paste (Cmd+V, the Paste menu items, middle-click); `drop` is text,
    /// URLs or paths the operator drags onto a terminal.
    case socket, textBox, filePaste, feed, mailbox, launchPrompt, resume, initial, drop

    /// C11H-362: the operator's paste or drop. Its text came from a clipboard or a drag (a web page, another
    /// program), so it always reaches the terminal as a paste: fenced when the program enabled bracketed paste,
    /// with control bytes replaced. It is never typed as keystrokes, whatever it contains.
    var isOperatorPaste: Bool { self == .filePaste || self == .drop }
}

enum HCInputRefusal: String, Error, Codable, Sendable {
    case unavailable, staleIdentity, guardRefused, screenUnavailable, tooLarge, queueFull, inputFault, cancelled
}

enum HCInputOutcome: Sendable {
    case refused(HCInputRefusal) // Zero bytes; safe to retry only after a new guard.
    case written(HCWriteReceipt) // Transport completion, never execution acknowledgment.
    case uncertain(HCWriteReceipt) // Never replay; cancel any unsent Return.
}

enum HCRecoveryReason: String, Sendable { case foreignBuild, creationUncertain, inputFault }
enum HCRecoveryResult: Sendable {
    case recovered(HCRevision)
    case refused(HCUnavailableReason)
    case recoveryRequired(HCUnavailableReason)
}

typealias HCInputGuard = @MainActor @Sendable (HCScreenReceipt) -> Bool

/// Contract Amendment 1 (C11H-65): one hc session of the pool. Index 0 is
/// the legacy session S0 (`c11[-<tag>]`); 1...HCShardPool.size are `S0-sN`.
struct HCShardID: Hashable, Codable, Comparable, Sendable {
    let index: Int
    static let legacy = HCShardID(index: 0)
    /// C11H-391: the links session `L` of an adopted app (one that runs
    /// c11h's sessions after the switch): c11's own converged shard 0 session
    /// (`c11`, `c11-<tag>`), composed beside the adopted pool. It holds only
    /// linked machines and their terminals; no workspace is ever placed there.
    /// Outside 0...poolSize, so no adopted shard can carry it.
    static let links = HCShardID(index: poolSize + 1)
    var isLinks: Bool { self == .links }
    static func < (lhs: HCShardID, rhs: HCShardID) -> Bool { lhs.index < rhs.index }
}

/// Shard names (Amendment 1 A1.L1). Pure, so every target that builds the
/// launch policy (the app, `c11-cli`'s `c11-core`) shares them; `HCShardPool`
/// exposes the same names.
extension HCShardID {
    /// K: pool shards are 1...poolSize.
    static let poolSize = 8

    /// L1's session: `c11` (release) or `c11-<tag>` (dev).
    static func base(tag: String?) -> String { tag.map { "c11-\($0)" } ?? "c11" }

    /// S0 is `base`; shard N is `base-sN`.
    static func session(base: String, shard: HCShardID) -> String {
        shard == .legacy ? base : "\(base)-s\(shard.index)"
    }

    /// `s` and digits: the suffix of a shard session.
    static func isShardSuffix(_ part: String) -> Bool {
        part.count >= 2 && part.first == "s" && part.dropFirst().allSatisfy { ("0"..."9").contains($0) }
    }
}

/// Per-shard diagnostics row (Amendment 1; filled by SH5).
struct HCShardStatus: Sendable {
    let shard: HCShardID
    let session: String
    let coreID: String?
    let holderPID: Int32?
    let readiness: HCReadiness
    let liveTerminals: Int
    /// nil when the shard has no remote pair.
    let link: HCMachineAvailability?
}

struct HCTerminalKey: Hashable, Codable, Sendable {
    let owningCoreID: String
    let localAddress: String

    init(
        owningCoreID: String,
        localAddress: String
    ) {
        self.owningCoreID = owningCoreID
        self.localAddress = localAddress
    }
}

struct HCRevision: Equatable, Codable, Sendable {
    let connectionGeneration: UInt64
    let sequence: UInt64

    init(
        connectionGeneration: UInt64,
        sequence: UInt64
    ) {
        self.connectionGeneration = connectionGeneration
        self.sequence = sequence
    }
}

struct HCProcessIdentity: Equatable, Codable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64

    init(
        pid: Int32,
        startTimeMicroseconds: UInt64
    ) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

struct HCFileIdentity: Equatable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

struct HCBuildIdentity: Equatable, Codable, Sendable {
    let pin: HCPin
    let executablePath: String
    let fileIdentity: HCFileIdentity
    let process: HCProcessIdentity
    let coreID: String
    let protocolGeneration: Int

    init(
        pin: HCPin,
        executablePath: String,
        fileIdentity: HCFileIdentity,
        process: HCProcessIdentity,
        coreID: String,
        protocolGeneration: Int
    ) {
        self.pin = pin
        self.executablePath = executablePath
        self.fileIdentity = fileIdentity
        self.process = process
        self.coreID = coreID
        self.protocolGeneration = protocolGeneration
    }
}

struct HCPanelIdentity: Equatable, Codable, Sendable {
    let panelID: UUID
    let key: HCTerminalKey?
    let persistence: HCPersistence
    let creationID: UUID?
    let origin: HCPanelOrigin

    init(
        panelID: UUID,
        key: HCTerminalKey? = nil,
        persistence: HCPersistence = .persistent,
        creationID: UUID? = nil,
        origin: HCPanelOrigin = .restored
    ) {
        self.panelID = panelID
        self.key = key
        self.persistence = persistence
        self.creationID = creationID
        self.origin = origin
    }
}

struct HCForeground: Equatable, Codable, Sendable {
    let pid: Int32?
    let name: String?
    let argv: [String]?
    let cwd: String?

    init(
        pid: Int32? = nil,
        name: String? = nil,
        argv: [String]? = nil,
        cwd: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.argv = argv
        self.cwd = cwd
    }
}

struct HCGridSize: Equatable, Codable, Sendable {
    let columns: UInt16
    let rows: UInt16

    init(
        columns: UInt16,
        rows: UInt16
    ) {
        self.columns = columns
        self.rows = rows
    }
}

struct HCTerminalRecord: Equatable, Codable, Sendable {
    let key: HCTerminalKey
    let state: HCTerminalState
    let labels: [String: String]
    let machineName: String?
    let machineAvailability: HCMachineAvailability
    let pid: Int32?
    let cwd: String?
    let foreground: HCForeground?
    let title: String?
    let status: String?
    let statusTimestampMilliseconds: Int64?
    let turn: Int64?
    let grid: HCGridSize?
    let screenExact: Bool?
    let exitCode: Int32?
    let exitSignal: Int32?
    let endReason: String?
    let tty: String?
    let localProcessIdentity: HCProcessIdentity?
    /// C11H-205: when hc says the terminal finished (`finished_ms`, Unix
    /// milliseconds). An end's banner and restore record name this time, not
    /// the moment c11 first read it.
    let finishedMilliseconds: Int64?

    init(
        key: HCTerminalKey,
        state: HCTerminalState,
        labels: [String: String] = [:],
        machineName: String? = nil,
        machineAvailability: HCMachineAvailability = .local,
        pid: Int32? = nil,
        cwd: String? = nil,
        foreground: HCForeground? = nil,
        title: String? = nil,
        status: String? = nil,
        statusTimestampMilliseconds: Int64? = nil,
        turn: Int64? = nil,
        grid: HCGridSize? = nil,
        screenExact: Bool? = nil,
        exitCode: Int32? = nil,
        exitSignal: Int32? = nil,
        endReason: String? = nil,
        tty: String? = nil,
        localProcessIdentity: HCProcessIdentity? = nil,
        finishedMilliseconds: Int64? = nil
    ) {
        self.key = key
        self.state = state
        self.labels = labels
        self.machineName = machineName
        self.machineAvailability = machineAvailability
        self.pid = pid
        self.cwd = cwd
        self.foreground = foreground
        self.title = title
        self.status = status
        self.statusTimestampMilliseconds = statusTimestampMilliseconds
        self.turn = turn
        self.grid = grid
        self.screenExact = screenExact
        self.exitCode = exitCode
        self.exitSignal = exitSignal
        self.endReason = endReason
        self.tty = tty
        self.localProcessIdentity = localProcessIdentity
        self.finishedMilliseconds = finishedMilliseconds
    }
}

struct HCEndEvidence: Equatable, Codable, Sendable {
    let id: UUID
    let key: HCTerminalKey?
    let creationID: UUID?
    let revision: HCRevision
    let kind: HCEndKind
    let hcReason: String?
    let exitCode: Int32?
    let exitSignal: Int32?
    /// C11H-205: hc's own end time for a finished record (`finished_ms`),
    /// nil for an end hc did not time (an observed removal, a rejection).
    let endedAtMilliseconds: Int64?

    init(
        id: UUID,
        key: HCTerminalKey? = nil,
        creationID: UUID? = nil,
        revision: HCRevision,
        kind: HCEndKind,
        hcReason: String? = nil,
        exitCode: Int32? = nil,
        exitSignal: Int32? = nil,
        endedAtMilliseconds: Int64? = nil
    ) {
        self.id = id
        self.key = key
        self.creationID = creationID
        self.revision = revision
        self.kind = kind
        self.hcReason = hcReason
        self.exitCode = exitCode
        self.exitSignal = exitSignal
        self.endedAtMilliseconds = endedAtMilliseconds
    }

    /// hc's end time, when it gave one.
    var endedAt: Date? {
        endedAtMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}

struct HCInventorySnapshot: Sendable {
    let readiness: HCReadiness
    let revision: HCRevision
    let records: [HCTerminalKey: HCTerminalRecord]
    let buildIdentity: HCBuildIdentity?
    let panelBindings: [UUID: HCTerminalKey]
    let machines: [String: HCMachineAvailability]
    /// Amendment 1: the shard pool's merged view carries each started shard's
    /// own readiness and revision. Empty on one shard's own snapshot. On the
    /// merged view `revision` is only a change counter: never compare it with
    /// a shard's revision.
    let shardReadiness: [HCShardID: HCReadiness]
    let shardRevisions: [HCShardID: HCRevision]
    /// SH3 (C11H-77): each started shard's own verified core id, so admission
    /// knows which local records are this app's own in which shard.
    let shardCoreIDs: [HCShardID: String]
    /// The shard whose inventory holds each record (merged view only).
    let recordShards: [HCTerminalKey: HCShardID]
    /// The shard this snapshot came from, set when a panel's route forwards it
    /// (C11H-92). A revision is ordered only within one source (A1.L4).
    let source: HCShardID?
    /// C11H-391: each started shard's own machine lines, by session, in
    /// shard order (merged view only). `machines` above is the routed view;
    /// this keeps the per-session facts routing needs (`HCMachineRouting`).
    let sessionMachines: [HCSessionMachines]

    init(
        readiness: HCReadiness,
        revision: HCRevision,
        records: [HCTerminalKey: HCTerminalRecord] = [:],
        buildIdentity: HCBuildIdentity? = nil,
        panelBindings: [UUID: HCTerminalKey] = [:],
        machines: [String: HCMachineAvailability] = [:],
        shardReadiness: [HCShardID: HCReadiness] = [:],
        shardRevisions: [HCShardID: HCRevision] = [:],
        shardCoreIDs: [HCShardID: String] = [:],
        recordShards: [HCTerminalKey: HCShardID] = [:],
        source: HCShardID? = nil,
        sessionMachines: [HCSessionMachines] = []
    ) {
        self.readiness = readiness
        self.revision = revision
        self.records = records
        self.buildIdentity = buildIdentity
        self.panelBindings = panelBindings
        self.machines = machines
        self.shardReadiness = shardReadiness
        self.shardRevisions = shardRevisions
        self.shardCoreIDs = shardCoreIDs
        self.recordShards = recordShards
        self.source = source
        self.sessionMachines = sessionMachines
    }

    /// This snapshot, marked as coming from `shard`.
    func from(_ shard: HCShardID) -> HCInventorySnapshot {
        HCInventorySnapshot(readiness: readiness, revision: revision, records: records, buildIdentity: buildIdentity,
            panelBindings: panelBindings, machines: machines, shardReadiness: shardReadiness,
            shardRevisions: shardRevisions, shardCoreIDs: shardCoreIDs, recordShards: recordShards, source: shard,
            sessionMachines: sessionMachines)
    }
}

/// C11H-391: one session's machine lines, as its shard's inventory reports them.
struct HCSessionMachines: Equatable, Sendable {
    let shard: HCShardID
    let session: String
    let machines: [String: HCMachineAvailability]
    /// C11H-396: whether this session takes new terminals. A pool shard is
    /// read-only while shards are off (`HCShardSettings.isReadOnly`): its
    /// links are listed, and a new terminal is never routed through them.
    var takesCreations: Bool = true
}

/// Amendment 1 A1.L4 for consumers: readiness is the readiness of the shard
/// that holds the record in question, and a local record is the app's own when
/// its core is any started shard's. On one session's own snapshot (no shard
/// maps) each answer is that session's, exactly as before shards.
extension HCInventorySnapshot {
    var isMerged: Bool { !shardReadiness.isEmpty }

    /// The shard that holds this key: the record's shard, else the shard whose core owns it.
    func shard(for key: HCTerminalKey) -> HCShardID? {
        recordShards[key] ?? shardCoreIDs.first { $0.value == key.owningCoreID }?.key
    }

    /// Authoritative for this key: its own shard is ready at its current revision.
    func isReady(for key: HCTerminalKey) -> Bool {
        guard isMerged else {
            if case .ready(let current) = readiness { return current == revision }
            return false
        }
        guard let shard = shard(for: key), case .ready(let current) = shardReadiness[shard] else { return false }
        return current == shardRevisions[shard]
    }

    /// Any part of this inventory is authoritative (one ready shard on the merged view).
    var hasReadyPart: Bool {
        guard isMerged else {
            if case .ready(let current) = readiness { return current == revision }
            return false
        }
        return shardReadiness.contains { shard, readiness in
            if case .ready(let current) = readiness { return current == shardRevisions[shard] }
            return false
        }
    }

    /// The core id this app's own local terminal under this key would carry.
    func ownsLocal(_ key: HCTerminalKey) -> Bool {
        isMerged ? shardCoreIDs.values.contains(key.owningCoreID) : key.owningCoreID == buildIdentity?.coreID
    }

    /// The connection generation that holds this key (its shard's on the merged view).
    func connectionGeneration(for key: HCTerminalKey) -> UInt64 {
        shard(for: key).flatMap { shardRevisions[$0]?.connectionGeneration } ?? revision.connectionGeneration
    }
}

struct HCInitialInput: Sendable {
    let operationID: UUID
    let payload: Data
    let submitReturn: Bool

    init(
        operationID: UUID,
        payload: Data,
        submitReturn: Bool
    ) {
        self.operationID = operationID
        self.payload = payload
        self.submitReturn = submitReturn
    }
}

struct HCCreateRequest: Sendable {
    let identity: HCPanelIdentity
    let creationID: UUID
    let argv: [String]
    let cwd: String?
    let environment: [String: String]
    let initialInput: HCInitialInput?
    /// The hc machine name to run on (`terminal.run`'s `on`); nil is this core.
    /// `cwd` is then a path on that machine and is never resolved locally.
    let machine: String?
    /// The pool shard this creation targets (Amendment 1 A1.L3); nil keeps
    /// the session's own meaning. Only `HCShardPool` reads it.
    let shard: HCShardID?
    /// C11H-103: labels stamped on the new terminal beside `c11.panel` and
    /// `c11.creation` (which always win): `c11.workspace`, so a terminal
    /// whose panel is missing from the saved layout goes home, not to Recovered.
    let labels: [String: String]

    init(
        identity: HCPanelIdentity,
        creationID: UUID,
        argv: [String],
        cwd: String? = nil,
        environment: [String: String] = [:],
        initialInput: HCInitialInput? = nil,
        machine: String? = nil,
        shard: HCShardID? = nil,
        labels: [String: String] = [:]
    ) {
        self.identity = identity
        self.creationID = creationID
        self.argv = argv
        self.cwd = cwd
        self.environment = environment
        self.initialInput = initialInput
        self.machine = machine
        self.shard = shard
        self.labels = labels
    }
}

/// C11H-103: labels c11 keeps on each terminal it creates, so a terminal
/// whose panel is missing from the saved layout returns to its own workspace
/// with its title instead of Recovered. `c11.panel` stays the owner's id.
enum HCOwnerLabels {
    static let workspace = "c11.workspace"
    static let title = "c11.title"
    /// C11H-196: which c11 install created the terminal. A machine's core is
    /// shared by every c11 linked to it (other Macs, tagged builds), so the
    /// Recovered workspace adopts a remote terminal only when it carries this
    /// install's value.
    static let app = "c11h.app"

    /// This install's value for `app`: one UUID per bundle (a tagged build has
    /// its own), kept in that bundle's defaults.
    static let appInstallID: String = {
        let key = "c11.appInstallID"
        if let existing = UserDefaults.standard.string(forKey: key), UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    /// C11H-205: whether a terminal no panel claims may be treated as this
    /// install's own (adopted into Recovered, ended by End All). Each build
    /// runs its own local session (C11H-216), but two copies of one build
    /// share it, and older builds of another channel left terminals in
    /// release's: one labelled by another install never is. An unlabelled local terminal
    /// predates the label and still is. A remote terminal must carry this
    /// install's label (C11H-196). Nil `appInstallID` (tests that predate the
    /// label) accepts every reachable record.
    static func isThisInstalls(_ record: HCTerminalRecord, appInstallID: String?) -> Bool {
        guard let appInstallID else { return true }
        let label = record.labels[app]
        switch record.machineAvailability {
        case .local: return label == nil || label == appInstallID
        case .connected, .disconnected, .unknown: return label == appInstallID
        }
    }

    /// hc saves its state on every label write: titles are clipped and
    /// written at most once per debounce window.
    static let maximumTitleCharacters = 120

    /// The label value for a custom title; "" removes the label.
    static func titleValue(_ title: String?) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumTitleCharacters))
    }
}

/// C11H-103: set or remove (an empty value) labels on a live terminal.
/// Best effort: false when hc can't take them now. Kept out of `HCSession`
/// so every fake session is unchanged.
protocol HCTerminalLabeling: Sendable {
    func setLabels(_ labels: [String: String], on key: HCTerminalKey) async -> Bool
}

struct HCDisplayRevision: Equatable, Codable, Sendable {
    let attachmentGeneration: UInt64
    let displayGeneration: UInt64

    init(
        attachmentGeneration: UInt64,
        displayGeneration: UInt64
    ) {
        self.attachmentGeneration = attachmentGeneration
        self.displayGeneration = displayGeneration
    }
}

struct HCRGBColor: Equatable, Codable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

struct HCDisplayFacts: Equatable, Codable, Sendable {
    let foreground: HCRGBColor?
    let background: HCRGBColor?
    let cursor: HCRGBColor?
    let cellWidth: UInt16?
    let cellHeight: UInt16?

    init(
        foreground: HCRGBColor? = nil,
        background: HCRGBColor? = nil,
        cursor: HCRGBColor? = nil,
        cellWidth: UInt16? = nil,
        cellHeight: UInt16? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }
}

struct HCDisplayState: Equatable, Codable, Sendable {
    let revision: HCDisplayRevision
    let grid: HCGridSize
    let facts: HCDisplayFacts
    let focused: Bool

    init(
        revision: HCDisplayRevision,
        grid: HCGridSize,
        facts: HCDisplayFacts = HCDisplayFacts(),
        focused: Bool = false
    ) {
        self.revision = revision
        self.grid = grid
        self.facts = facts
        self.focused = focused
    }
}

struct HCScreenReceipt: Equatable, Sendable {
    let revision: HCDisplayRevision
    let parsedOutputWatermark: UInt64
    let columns: UInt16
    let rows: UInt16

    init(
        revision: HCDisplayRevision,
        parsedOutputWatermark: UInt64,
        columns: UInt16,
        rows: UInt16
    ) {
        self.revision = revision
        self.parsedOutputWatermark = parsedOutputWatermark
        self.columns = columns
        self.rows = rows
    }
}

struct HCInputRequest: Sendable {
    let operationID: UUID
    let panelID: UUID
    let key: HCTerminalKey
    let attachmentGeneration: UInt64
    let source: HCInputSource
    let payload: Data
    let submitReturn: Bool
    let screenGuard: HCInputGuard?
    let returnGuard: HCInputGuard?
    /// C11H-167: a screen-independent check for a terminal with no screen (a headless resume). Asked after the
    /// body is encoded and before it is written (no: zero bytes), and again before the Return when there is no
    /// screen-based return guard (no: the body is out, so the write is cut and paused, never replayed).
    let eligibility: (@Sendable () async -> Bool)?

    init(
        operationID: UUID,
        panelID: UUID,
        key: HCTerminalKey,
        attachmentGeneration: UInt64,
        source: HCInputSource,
        payload: Data,
        submitReturn: Bool,
        screenGuard: HCInputGuard? = nil,
        returnGuard: HCInputGuard? = nil,
        eligibility: (@Sendable () async -> Bool)? = nil
    ) {
        self.operationID = operationID
        self.panelID = panelID
        self.key = key
        self.attachmentGeneration = attachmentGeneration
        self.source = source
        self.payload = payload
        self.submitReturn = submitReturn
        self.screenGuard = screenGuard
        self.returnGuard = returnGuard
        self.eligibility = eligibility
    }
}

struct HCWriteReceipt: Equatable, Codable, Sendable {
    let operationID: UUID
    let attachmentGeneration: UInt64
    let bodyBytesWritten: Int
    let returnWritten: Bool

    init(
        operationID: UUID,
        attachmentGeneration: UInt64,
        bodyBytesWritten: Int,
        returnWritten: Bool
    ) {
        self.operationID = operationID
        self.attachmentGeneration = attachmentGeneration
        self.bodyBytesWritten = bodyBytesWritten
        self.returnWritten = returnWritten
    }
}

struct HCDiagnostics: Sendable {
    let inventory: HCInventorySnapshot
    let expectedPin: HCPin
    let servingBuild: HCBuildIdentity?
    let unavailableReason: HCUnavailableReason?
    let pendingCreations: Int
    let queuedInputBytes: Int

    init(
        inventory: HCInventorySnapshot,
        expectedPin: HCPin = .current,
        servingBuild: HCBuildIdentity? = nil,
        unavailableReason: HCUnavailableReason? = nil,
        pendingCreations: Int = 0,
        queuedInputBytes: Int = 0
    ) {
        self.inventory = inventory
        self.expectedPin = expectedPin
        self.servingBuild = servingBuild
        self.unavailableReason = unavailableReason
        self.pendingCreations = pendingCreations
        self.queuedInputBytes = queuedInputBytes
    }
}
