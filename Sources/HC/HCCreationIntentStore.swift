import Darwin
import Foundation

enum HCCreationPhase: String, Codable, Sendable { case prepared, transmitted, uncertain, bound, ended }
enum HCInitialInputPhase: String, Codable, Sendable { case none, pending, attempted, written, uncertain }

struct HCStoredCreation: Equatable, Codable, Sendable {
    let panelID: UUID
    let creationID: UUID
    let coreID: String
    let coreProcess: HCProcessIdentity
    var phase: HCCreationPhase
    var key: HCTerminalKey?
    var endEvidence: HCEndEvidence?
    var initialInput: HCInitialInputPhase
    /// Target hc machine for a remote creation; absent (nil) on older records
    /// and local creations. A local core's adoption never settles a remote one.
    var machine: String? = nil
    /// C11H-313: the key of the panel's earlier terminal, already recorded
    /// ended, that this creation replaced (carried through creations that
    /// never ran). A replacement's close keeps that key, so its end is proven
    /// from here when the creation never runs. Nil on older records.
    var predecessorKey: HCTerminalKey? = nil
}

/// The store's lock is held by another app incarnation for its short
/// transaction: retry, never absence. Callers that map errors to a reason see
/// `intentStoreFailure`, as before.
struct HCIntentStoreBusy: Error, Sendable {}

/// One durable commit barrier, separate from debounced workspace autosave.
/// The serial worker never performs IO on main. The nonblocking process lock
/// also prevents two overlapping app incarnations from losing each other's claims.
final class HCCreationIntentStore: Sendable {
    private struct Document: Codable {
        var version = 1
        var active: [String: HCStoredCreation] = [:]
        var usedCreationIDs: Set<UUID> = []

        private enum CodingKeys: String, CodingKey { case version, active, usedCreationIDs }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            active = try container.decode([String: HCStoredCreation].self, forKey: .active)
            usedCreationIDs = try container.decode(Set<UUID>.self, forKey: .usedCreationIDs)
        }

        /// Canonical: one document always encodes to the same bytes (sorted
        /// keys from the encoder, used ids in order), so an unchanged
        /// transaction can be recognized by its bytes.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(active, forKey: .active)
            try container.encode(usedCreationIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .usedCreationIDs)
        }
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "c11.hc.creation-intents", qos: .utility)
    private let persist: @Sendable (Data, URL) throws -> Void
#if DEBUG
    /// C11H-329 test seam: runs on the store's worker right after a
    /// transaction's caller has been resumed.
    private let afterDelivery: (@Sendable () -> Void)?
#endif

    init(directory: URL, persist: @escaping @Sendable (Data, URL) throws -> Void = { try HCCreationIntentStore.persistDurably($0, $1) }) {
        self.directory = directory
        self.persist = persist
#if DEBUG
        afterDelivery = nil
#endif
    }

#if DEBUG
    init(directory: URL, afterDelivery: @escaping @Sendable () -> Void) {
        self.directory = directory
        persist = { try HCCreationIntentStore.persistDurably($0, $1) }
        self.afterDelivery = afterDelivery
    }
#endif

    func read(panelID: UUID) async throws -> HCStoredCreation? {
        try await transaction(write: false) { $0.active[panelID.uuidString] }
    }

    func all() async throws -> [HCStoredCreation] {
        try await transaction(write: false) { Array($0.active.values) }
    }

    /// A replacement may claim only a settled prior attempt. UUID reuse is
    /// rejected even after that attempt ends, so a retried old call stays old.
    func claim(_ request: HCCreateRequest, coreID: String, process: HCProcessIdentity) async throws -> HCStoredCreation {
        try await transaction { document in
            guard !document.usedCreationIDs.contains(request.creationID) else { throw HCUnavailableReason.creationPending }
            if let prior = document.active[request.identity.panelID.uuidString] {
                guard prior.phase == .ended, prior.endEvidence != nil else { throw HCUnavailableReason.creationPending }
            }
            let prior = document.active[request.identity.panelID.uuidString]
            let intent = HCStoredCreation(panelID: request.identity.panelID, creationID: request.creationID,
                coreID: coreID, coreProcess: process, phase: .prepared, key: nil, endEvidence: nil,
                initialInput: request.initialInput == nil ? .none : .pending,
                machine: request.machine, predecessorKey: prior.flatMap { $0.key ?? $0.predecessorKey })
            document.active[request.identity.panelID.uuidString] = intent
            document.usedCreationIDs.insert(request.creationID)
            return intent
        }
    }

    /// C11H-313: a creation that left `create` before its claim never ran and
    /// never will. Record that for its creationID, so a close of the panel that
    /// already carries it settles instead of reading a creation still pending.
    /// Written as the panel's intent, ended with a `createRejected` proof naming
    /// the creation, which is the shape a claimed creation rejected before its
    /// run already has. Nothing is written while another creation of the panel
    /// is unsettled: the resolver follows that one, and a close ends it. A claim
    /// that reported failure but landed (still `prepared`) is ended the same way.
    /// The ended predecessor's key is kept on the record (`predecessorKey`).
    /// True when the record is written.
    @discardableResult
    func recordNeverRun(_ request: HCCreateRequest, coreID: String, process: HCProcessIdentity,
                        revision: HCRevision) async throws -> Bool {
        try await transaction { document in
            let panel = request.identity.panelID
            let evidence = HCEndEvidence(id: UUID(), creationID: request.creationID, revision: revision, kind: .createRejected)
            if var prior = document.active[panel.uuidString] {
                if prior.creationID == request.creationID {
                    guard prior.phase == .prepared else { return false }
                    prior.phase = .ended
                    prior.endEvidence = evidence
                    document.active[panel.uuidString] = prior
                    return true
                }
                guard prior.phase == .ended else { return false }
            }
            guard !document.usedCreationIDs.contains(request.creationID) else { return false }
            let prior = document.active[panel.uuidString]
            document.active[panel.uuidString] = HCStoredCreation(panelID: panel, creationID: request.creationID,
                coreID: coreID, coreProcess: process, phase: .ended, key: nil, endEvidence: evidence,
                initialInput: .none, machine: request.machine, predecessorKey: prior.flatMap { $0.key ?? $0.predecessorKey })
            document.usedCreationIDs.insert(request.creationID)
            return true
        }
    }

    func markTransmitted(panelID: UUID, creationID: UUID) async throws {
        try await update(panelID: panelID, creationID: creationID) { intent in
            guard intent.phase == .prepared else { throw HCUnavailableReason.creationPending }
            intent.phase = .transmitted
        }
    }

    func markUncertain(panelID: UUID, creationID: UUID) async throws {
        try await update(panelID: panelID, creationID: creationID) { intent in
            guard intent.phase == .transmitted || intent.phase == .uncertain else { return }
            intent.phase = .uncertain
        }
    }

    func bind(panelID: UUID, creationID: UUID, key: HCTerminalKey) async throws {
        try await update(panelID: panelID, creationID: creationID) { intent in
            guard intent.phase != .ended else { throw HCUnavailableReason.staleIdentity }
            guard intent.key == nil || intent.key == key else { throw HCUnavailableReason.ambiguousIdentity }
            intent.phase = .bound
            intent.key = key
        }
    }

    func recordEnd(panelID: UUID, creationID: UUID, evidence: HCEndEvidence) async throws {
        try await update(panelID: panelID, creationID: creationID) { intent in
            guard intent.phase != .ended else { return }
            guard evidence.creationID == creationID || (intent.key != nil && evidence.key == intent.key) else {
                throw HCUnavailableReason.staleIdentity
            }
            intent.phase = .ended
            intent.endEvidence = evidence
        }
    }

    /// Persist the attempt BEFORE handing initial input to the native lane.
    /// An app crash after this point must not replay, even with no write receipt.
    func claimInitialInput(panelID: UUID, creationID: UUID) async throws -> Bool {
        try await transaction { document in
            guard var intent = document.active[panelID.uuidString], intent.creationID == creationID,
                  intent.phase == .bound, intent.initialInput == .pending else { return false }
            intent.initialInput = .attempted
            document.active[panelID.uuidString] = intent
            return true
        }
    }

    func finishInitialInput(panelID: UUID, creationID: UUID, outcome: HCInputOutcome) async throws {
        try await update(panelID: panelID, creationID: creationID) { intent in
            guard intent.initialInput == .attempted else { return }
            // Even a definite refusal is not retried by a reattach. An operator
            // can choose a new explicit operation; this creation's intent is spent.
            switch outcome {
            case .written: intent.initialInput = .written
            case .refused, .uncertain: intent.initialInput = .uncertain
            }
        }
    }

    private func update(panelID: UUID, creationID: UUID, body: @escaping @Sendable (inout HCStoredCreation) throws -> Void) async throws {
        try await transaction { document in
            guard var intent = document.active[panelID.uuidString], intent.creationID == creationID else {
                throw HCUnavailableReason.staleIdentity
            }
            try body(&intent)
            document.active[panelID.uuidString] = intent
        }
    }

    private func transaction<T: Sendable>(write: Bool = true, _ body: @escaping @Sendable (inout Document) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                // C11H-329: the caller resumes only after the lock is released and
                // its descriptor closed. Resuming inside the locked scope let the
                // caller's next transaction, on another store over this directory,
                // find the lock still held and fail as busy.
                continuation.resume(with: Result { try Self.locked(directory: directory, persist: persist, write: write, body) })
#if DEBUG
                afterDelivery?()
#endif
            }
        }
    }

    private static func locked<T>(directory: URL, persist: @Sendable (Data, URL) throws -> Void, write: Bool,
                                  _ body: (inout Document) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw HCUnavailableReason.intentStoreFailure }
        let lockFD = open(directory.appendingPathComponent("creation-intents.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw HCUnavailableReason.intentStoreFailure }
        defer { Darwin.close(lockFD) }
        // Busy (another app incarnation holds it) is transient, unlike a
        // store that cannot be read at all (C11H-93).
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw HCIntentStoreBusy() }
        defer { flock(lockFD, LOCK_UN) }
        let file = directory.appendingPathComponent("creation-intents.json")
        var document: Document
        var stored: Data?
        do {
            let data = try PrivateFileWriter.readPrivateFile(at: file, maxBytes: 16 * 1024 * 1024)
            stored = data
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as POSIXError where error.code == .ENOENT {
            document = Document()
        }
        guard document.version == 1 else { throw HCUnavailableReason.intentStoreFailure }
        let result = try body(&document)
        // C11H-238: a write transaction that changed nothing used to
        // rewrite and fsync the whole file (8.5 GB in 13 h). Compare
        // with the bytes persisted now, read under this lock, not
        // with any earlier request: A, B, then A again still lands.
        if write {
            let encoded = try Self.canonicalEncoder().encode(document)
            if encoded != stored { try persist(encoded, file) }
        }
        return result
    }

    static func persistDurably(_ data: Data, _ file: URL) throws {
        try PrivateFileWriter.write(data, to: file)
        let fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw HCUnavailableReason.intentStoreFailure }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw HCUnavailableReason.intentStoreFailure }
    }
}
