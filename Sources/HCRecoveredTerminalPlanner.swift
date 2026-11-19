import Foundation

/// What the app's panels already hold, read from every panel in every window,
/// registered or not (C11H-46). A panel counts here even before its hc
/// session has published a persistent identity, so a reconcile that runs
/// while panels are still registering never hands their terminals to a
/// second panel.
struct HCPanelClaims: Equatable, Sendable {
    /// Every panel UUID in the app, of any kind and persistence.
    var panelIDs: Set<UUID> = []
    /// Every terminal key a panel is bound to: its identity, its live record,
    /// or the identity restore seeded for it.
    var keys: Set<HCTerminalKey> = []
    /// Terminal panels with no key known yet. A terminal labelled with one of
    /// these is that panel's to resolve, never an orphan.
    var keylessPanelIDs: Set<UUID> = []
}

/// Produces UI adoption proposals from the one owned session inventory. There
/// are no end/create side effects here. The caller installs proposals only
/// after every window's saved identities have been registered.
enum HCRecoveredTerminalPlanner {
    struct Recovery: Equatable, Sendable {
        let identity: HCPanelIdentity
        let record: HCTerminalRecord
        /// C11H-103 (L4 amendment, condition 3): it kept its own label UUID
        /// and no other candidate carries that label. A superseded creation,
        /// or an orphan whose label another live claim shares, never goes home.
        var homeEligible = false
        /// C11H-363: a terminal on a linked machine comes back as one, on the
        /// machine this Mac's creation record vouched for. Nil for this Mac.
        var remoteTarget: HCRemoteTarget? = nil

        /// The placement every recovered panel is created with.
        var machineRequest: HCMachineRequest { remoteTarget.map { .restored($0) } ?? .local }
    }

    static func recoveries(
        from snapshot: HCInventorySnapshot,
        identities: [HCPanelIdentity],
        restoreComplete: Bool,
        unresolvedPanelIDs: Set<UUID> = [],
        closingPanelIDs: Set<UUID> = [],
        closingKeys: Set<HCTerminalKey> = [],
        claims: HCPanelClaims = HCPanelClaims(),
        appInstallID: String? = nil,
        creations: [UUID: HCStoredCreation]? = nil
    ) -> [Recovery] {
        // Amendment 1: on the shard pool's merged view each record is judged by
        // its own shard (ready, and owned by that shard's core), so every
        // shard's orphans enter Recovered and one shard's outage hides only its own.
        guard restoreComplete, snapshot.hasReadyPart,
              snapshot.isMerged || snapshot.buildIdentity != nil else { return [] }

        // C11H-46: a UUID any panel already has is never given to a second one.
        var occupiedPanelIDs = Set(identities.map(\.panelID)).union(closingPanelIDs).union(claims.panelIDs)
        // Inventory bindings can outlive the UI (that is precisely an orphan).
        // Only a panel present in the restored graph can claim one here.
        let presentBindings = snapshot.panelBindings.filter { occupiedPanelIDs.contains($0.key) }
        let claimed = Set(identities.compactMap(\.key))
            .union(presentBindings.values).union(closingKeys).union(claims.keys)
        let candidates = snapshot.records.values.filter { record in
            guard !claimed.contains(record.key), record.state == .running, record.pid != nil,
                  snapshot.isReady(for: record.key) else { return false }
            if let panelID = record.labels["c11.panel"].flatMap(UUID.init(uuidString:)),
               closingPanelIDs.contains(panelID) { return false }
            // C11H-196, C11H-205: a core also holds terminals other c11
            // installs created (another Mac, a staging build on this one).
            // Only one this install made is an orphan of ours.
            switch record.machineAvailability {
            case .local:
                return snapshot.ownsLocal(record.key) && HCOwnerLabels.isThisInstalls(record, appInstallID: appInstallID)
            case .connected:
                // C11H-359 (M4): hc labels on a linked machine's terminal can be
                // written by any process of the user there, so they are never
                // provenance. Only this Mac's own creation record vouches for one.
                return HCOwnerLabels.isThisInstalls(record, appInstallID: appInstallID)
                    && vouched(record, by: creations, in: snapshot, occupied: occupiedPanelIDs)
            case .disconnected, .unknown: return false
            }
        }.sorted {
            ($0.key.owningCoreID, $0.key.localAddress) < ($1.key.owningCoreID, $1.key.localAddress)
        }
        let byLabel = Dictionary(grouping: candidates) {
            $0.labels["c11.panel"].flatMap(UUID.init(uuidString:))
        }
        return candidates.compactMap { record in
            let label = record.labels["c11.panel"].flatMap(UUID.init(uuidString:))
            let attempt = record.labels["c11.creation"].flatMap(UUID.init(uuidString:))
            // Autosave can hold the former key while the durable journal knows
            // a newer replacement. Let resolve reconcile that panel first;
            // adopting its labeled terminal now would duplicate the binding.
            if let label, unresolvedPanelIDs.contains(label) { return nil }
            // A panel that exists but has not learned its key yet owns the
            // terminal labelled with its UUID; adopting it would bind it twice.
            if let label, claims.keylessPanelIDs.contains(label) { return nil }
            // A currently resolving keyless panel owns its active attempt.
            // With no attempt, reserve its unique label until resolve returns;
            // a duplicate/superseded label never steals that saved panel UUID.
            if let label, identities.contains(where: { identity in
                guard identity.panelID == label, identity.key == nil else { return false }
                if let active = identity.creationID { return active == attempt }
                return byLabel[label]?.count == 1
            }) { return nil }

            let panelID: UUID
            if let label, !occupiedPanelIDs.contains(label) { panelID = label }
            else { panelID = UUID() }
            occupiedPanelIDs.insert(panelID)
            // Exact key is the recovered binding. A conflicting creation label
            // belongs to its original intent, not to this new UI identity.
            let identity = HCPanelIdentity(panelID: panelID, key: record.key, origin: .restored)
            let unique = label.map { (byLabel[$0]?.count ?? 0) == 1 } ?? false
            // Only a vouched linked record gets here as `.connected`: its
            // machine is the one the creation record names.
            let remote = record.machineAvailability == .connected
                ? label.flatMap { creations?[$0]?.machine }.map { HCRemoteTarget(machine: $0) } : nil
            return Recovery(identity: identity, record: record, homeEligible: label == panelID && unique,
                            remoteTarget: remote)
        }
    }
}

extension HCRecoveredTerminalPlanner {
    /// C11H-359 (M4): a linked machine's terminal is this install's orphan only
    /// when this Mac's creation store has an active creation for the panel its
    /// label names, made for this terminal (same creation id, same machine,
    /// and once bound the same key), and no panel or other terminal holds that
    /// panel's UUID. Nil `creations` (not read yet) vouches for nothing.
    static func vouched(_ record: HCTerminalRecord, by creations: [UUID: HCStoredCreation]?,
                        in snapshot: HCInventorySnapshot, occupied: Set<UUID>) -> Bool {
        guard let machine = record.machineName,
              let panel = record.labels["c11.panel"].flatMap(UUID.init(uuidString:)),
              let attempt = record.labels["c11.creation"].flatMap(UUID.init(uuidString:)),
              let creation = creations?[panel], creation.panelID == panel, creation.phase != .ended,
              creation.creationID == attempt, creation.machine == machine,
              creation.key == nil || creation.key == record.key,
              !occupied.contains(panel) else { return false }
        let holders = snapshot.records.values.filter { $0.labels["c11.panel"].flatMap(UUID.init(uuidString:)) == panel }
        return holders.count == 1
    }

    /// One running linked-machine terminal as a reconcile judges it: its key
    /// (which names its machine's core) and the panel and creation its labels
    /// name. A read of the creation records holds only for the terminals it
    /// was made for (REPAIR-1, B2).
    struct LinkedTerminal: Hashable, Sendable {
        let key: HCTerminalKey
        let panel: UUID
        let creation: UUID?
    }

    /// The linked terminals whose creation records a reconcile needs read
    /// before it can adopt any of them.
    static func linkedTerminals(in snapshot: HCInventorySnapshot) -> Set<LinkedTerminal> {
        Set(snapshot.records.values.compactMap { record in
            guard record.machineAvailability == .connected, record.state == .running,
                  let panel = record.labels["c11.panel"].flatMap(UUID.init(uuidString:)) else { return nil }
            return LinkedTerminal(key: record.key, panel: panel,
                                  creation: record.labels["c11.creation"].flatMap(UUID.init(uuidString:)))
        })
    }
}

/// C11H-46: the one-time launch cleanup of panels that hold the same terminal
/// or share a UUID (a saved session can carry such twins from an earlier
/// adoption). Pure: it names the panels to drop. The app drops each one by
/// closing it with ends suppressed, so its terminal is detached, never ended.
enum HCDuplicateBindingCleanup {
    struct Panel: Equatable {
        /// The caller's handle for this panel.
        let token: Int
        let panelID: UUID
        let keys: Set<HCTerminalKey>
        let inRecovered: Bool
    }

    /// Panels that share a key or a UUID, directly or through another panel,
    /// form a group. Each group keeps one panel: one outside Recovered before
    /// one inside it, then the first in the given order. The rest are dropped.
    static func drops(_ panels: [Panel]) -> [Panel] {
        var parent = Array(panels.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func join(_ a: Int, _ b: Int) {
            let (x, y) = (root(a), root(b))
            if x != y { parent[max(x, y)] = min(x, y) }
        }
        var byKey: [HCTerminalKey: Int] = [:]
        var byID: [UUID: Int] = [:]
        for (index, panel) in panels.enumerated() {
            if let other = byID[panel.panelID] { join(other, index) } else { byID[panel.panelID] = index }
            for key in panel.keys {
                if let other = byKey[key] { join(other, index) } else { byKey[key] = index }
            }
        }
        let groups = Dictionary(grouping: panels.indices, by: root)
        var dropped: [Int] = []
        for members in groups.values where members.count > 1 {
            let keep = members.min { a, b in
                if panels[a].inRecovered != panels[b].inRecovered { return !panels[a].inRecovered }
                return a < b
            }
            dropped.append(contentsOf: members.filter { $0 != keep })
        }
        return dropped.sorted().map { panels[$0] }
    }
}
