import Foundation

/// Evidence from the recovery coordinator, not a timer or an empty RPC reply.
struct HCAdoptionProof: Sendable {
    let retiredProcess: HCProcessIdentity
    let servingProcess: HCProcessIdentity
    let revision: HCRevision
    let coreID: String
}

/// C11H-359 (M3): where a panel's terminal runs, from c11's own records (the
/// creation intent, else the panel's saved target), never from hc's labels.
enum HCPanelPlacement: Equatable, Sendable {
    case local
    case machine(String)

    /// A creation's own record: its machine, or this Mac.
    init(intent: HCStoredCreation) { self = intent.machine.map(HCPanelPlacement.machine) ?? .local }

    /// Whether a terminal found by its labels is on this placement. Labels can be
    /// set by any process of the user on any linked machine, so a label match
    /// counts only here: on this Mac, a local record one of this app's own cores
    /// owns; on a machine, a record on that machine.
    func holds(_ record: HCTerminalRecord, in snapshot: HCInventorySnapshot) -> Bool {
        switch self {
        case .local: return record.machineAvailability == .local && record.machineName == nil && snapshot.ownsLocal(record.key)
        case .machine(let name): return record.machineName == name
        }
    }
}

/// C11H-359 (M3): each panel's placement as the app created or restored it
/// (its saved `HCRemoteTarget`, else this Mac), for resolves that have no
/// creation record to read it from. Read from any queue. An entry lasts for
/// the app run, so a closing panel's end still resolves on its own
/// placement after its surface is gone; each surface construction for that
/// panel replaces it.
final class HCPanelPlacements: @unchecked Sendable {
    static let shared = HCPanelPlacements()

    private let lock = NSLock()
    private var placements: [UUID: HCPanelPlacement] = [:]

    func set(_ placement: HCPanelPlacement, for panelID: UUID) {
        lock.lock(); placements[panelID] = placement; lock.unlock()
    }

    func placement(for panelID: UUID) -> HCPanelPlacement? {
        lock.lock(); defer { lock.unlock() }
        return placements[panelID]
    }
}

enum HCLifecycleResolver {
    /// Label matches count only on the panel's placement (C11H-359, M3): its
    /// creation record's machine when there is one, else `placement`, the
    /// caller's own record of where the panel was made. An exact key match
    /// names its own core and is unchanged.
    static func resolve(_ identity: HCPanelIdentity, snapshot: HCInventorySnapshot,
                        intent: HCStoredCreation?, adoption: HCAdoptionProof? = nil,
                        placement: HCPanelPlacement = .local) -> HCLifecycle {
        let placement = intent.map(HCPanelPlacement.init(intent:)) ?? placement
        if let intent, intent.panelID != identity.panelID { return .unresolved(identity, .staleIdentity) }
        if let proof = neverRan(identity, intent: intent) { return .ended(proof) }
        guard case .ready(let revision) = snapshot.readiness, revision == snapshot.revision else {
            if case .pending(let reason) = snapshot.readiness { return .unresolved(identity, reason) }
            return .unresolved(identity, .inventoryPending)
        }
        if let intent, intent.phase == .ended, let proof = intent.endEvidence { return .ended(proof) }

        let activeCreationID = intent?.creationID ?? identity.creationID
        let key = intent != nil ? intent?.key : identity.key
        let candidates = snapshot.records.values.filter { record in
            if let activeCreationID {
                return record.labels["c11.panel"]?.lowercased() == identity.panelID.uuidString.lowercased()
                    && record.labels["c11.creation"]?.lowercased() == activeCreationID.uuidString.lowercased()
                    && placement.holds(record, in: snapshot)
            }
            if let key { return record.key == key }
            return record.labels["c11.panel"]?.lowercased() == identity.panelID.uuidString.lowercased()
                && placement.holds(record, in: snapshot)
        }
        guard candidates.count <= 1 else { return .unresolved(identity, .ambiguousIdentity) }
        if let record = candidates.first {
            guard key == nil || key == record.key else { return .unresolved(identity, .ambiguousIdentity) }
            if record.machineAvailability == .disconnected || record.machineAvailability == .unknown {
                return .unresolved(identity, .connectionLost)
            }
            switch record.state {
            case .running:
                guard record.pid != nil else { return .unresolved(identity, .creationPending) }
                return .live(record)
            case .starting: return .unresolved(identity, .creationPending)
            case .finished:
                return .ended(HCEndEvidence(id: UUID(), key: record.key, creationID: activeCreationID,
                    revision: revision, kind: .finished, hcReason: record.endReason,
                    exitCode: record.exitCode, exitSignal: record.exitSignal,
                    endedAtMilliseconds: record.finishedMilliseconds))
            }
        }

        // A bound local record was observed inserted. Its authoritative removal
        // settles even if its late spawn reply is lost (hc kills that spawn).
        if let key, snapshot.buildIdentity?.coreID == key.owningCoreID {
            return .ended(HCEndEvidence(id: UUID(), key: key, creationID: activeCreationID,
                                       revision: revision, kind: .observedRemoval))
        }
        if let intent, let adoption,
           adoption.retiredProcess == intent.coreProcess,
           adoption.servingProcess != intent.coreProcess,
           adoption.coreID == intent.coreID,
           adoption.revision.connectionGeneration == revision.connectionGeneration,
           adoption.revision.sequence <= revision.sequence,
           snapshot.buildIdentity?.process == adoption.servingProcess,
           snapshot.buildIdentity?.coreID == adoption.coreID {
            return .ended(HCEndEvidence(id: UUID(), creationID: intent.creationID,
                                       revision: revision, kind: .postAdoptionAbsence))
        }
        if intent != nil || activeCreationID != nil { return .unresolved(identity, .creationPending) }
        // Stored/remote keys never become new because a mirror is missing.
        if key != nil { return .unresolved(identity, .connectionLost) }
        return .new
    }

    /// C11H-313: the identity's own creation is recorded as never run (rejected
    /// before hc was sent it). That is the whole answer: no inventory, ready or
    /// not, can hold a terminal of a creation hc never received. An identity
    /// that still carries an earlier terminal's key (a replacement) is answered
    /// only when the record also names that key as its ended predecessor: a
    /// creation's rejection says nothing about another terminal.
    static func neverRan(_ identity: HCPanelIdentity, intent: HCStoredCreation?) -> HCEndEvidence? {
        guard let intent, let asked = identity.creationID, intent.creationID == asked, intent.phase == .ended,
              let proof = intent.endEvidence, proof.kind == .createRejected else { return nil }
        if let key = identity.key, intent.predecessorKey != key { return nil }
        return proof
    }
}
