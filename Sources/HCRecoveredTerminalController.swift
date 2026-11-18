import Foundation

/// One observer for the entire app, not one per workspace/window. Restoring
/// windows register their claims before finishRestoring exposes any orphans.
@MainActor
final class HCRecoveredTerminalController {
    /// Explicit-end composition installs durable reads before startup recovery.
    /// Empty defaults let restore land before the explicit-end implementation.
    static var pendingEndPanelIDs: () -> Set<UUID> = { [] }
    static var pendingEndKeys: () -> Set<HCTerminalKey> = { [] }
    private let identities: () -> [HCPanelIdentity]
    private let unresolvedPanelIDs: () -> Set<UUID>
    private let closingPanelIDs: @MainActor () -> Set<UUID>
    private let closingKeys: @MainActor () -> Set<HCTerminalKey>
    private let claims: @MainActor () -> HCPanelClaims
    private let adopt: (HCRecoveredTerminalPlanner.Recovery) -> Void
    /// C11H-359 (M4): this Mac's active creation records, from every shard's
    /// store, read off main. Nil reads nothing, and no linked machine's
    /// terminal is adopted.
    private let readCreations: (@Sendable () async -> [HCStoredCreation]?)?
    private var creations: [UUID: HCStoredCreation]?
    /// The linked terminals `creations` was read for; any other set reads again.
    private var creationsReadFor: Set<HCRecoveredTerminalPlanner.LinkedTerminal>?
    private var creationsRead: Task<Void, Never>?
    private var observation: HCObservation?
    private var latest: HCInventorySnapshot?
    private var restoreComplete = false

    init(identities: @escaping () -> [HCPanelIdentity],
         unresolvedPanelIDs: @escaping () -> Set<UUID> = { [] },
         closingPanelIDs: @escaping @MainActor () -> Set<UUID> = { HCRecoveredTerminalController.pendingEndPanelIDs() },
         closingKeys: @escaping @MainActor () -> Set<HCTerminalKey> = { HCRecoveredTerminalController.pendingEndKeys() },
         claims: @escaping @MainActor () -> HCPanelClaims = { HCPanelClaims() },
         readCreations: (@Sendable () async -> [HCStoredCreation]?)? = nil,
         adopt: @escaping (HCRecoveredTerminalPlanner.Recovery) -> Void) {
        self.readCreations = readCreations
        self.identities = identities
        self.unresolvedPanelIDs = unresolvedPanelIDs
        self.closingPanelIDs = closingPanelIDs
        self.closingKeys = closingKeys
        self.claims = claims
        self.adopt = adopt
    }

    func start(inventory: any HCInventorySource) {
        guard observation == nil else { return }
        observation = inventory.observe(on: .main) { [weak self] snapshot in
            // The contract guarantees delivery on the nominated queue.
            MainActor.assumeIsolated { self?.receive(snapshot) }
        }
    }

    func finishRestoring() {
        restoreComplete = true
        reconcile()
    }

    func beginRestoring() {
        restoreComplete = false
    }

    func stop() {
        observation?.cancel()
        observation = nil
        latest = nil
        creationsRead?.cancel()
        creationsRead = nil
    }

    func receive(_ snapshot: HCInventorySnapshot) {
        latest = snapshot
        reconcile()
    }

    func panelClaimsChanged() { reconcile() }

    private func reconcile() {
        guard let latest else { return }
        let proposals = HCRecoveredTerminalPlanner.recoveries(from: latest,
            identities: identities(), restoreComplete: restoreComplete,
            unresolvedPanelIDs: unresolvedPanelIDs(),
            closingPanelIDs: closingPanelIDs(), closingKeys: closingKeys(), claims: claims(),
            appInstallID: HCOwnerLabels.appInstallID, creations: creationsFor(latest))
        for proposal in proposals { adopt(proposal) }
    }

    /// The creation records that vouch for this snapshot's linked-machine
    /// terminals: nil until read for its current set of labels. A changed set
    /// starts one read; its answer reconciles again.
    private func creationsFor(_ snapshot: HCInventorySnapshot) -> [UUID: HCStoredCreation]? {
        let wanted = HCRecoveredTerminalPlanner.linkedTerminals(in: snapshot)
        if wanted.isEmpty {
            // REPAIR-1 (B2): with no linked terminal left, nothing read so far
            // speaks for the next one, even with the same labels.
            creationsRead?.cancel()
            creationsRead = nil
            creations = nil
            creationsReadFor = nil
            return nil
        }
        guard restoreComplete, let readCreations else { return nil }
        if creationsReadFor == wanted { return creations }
        guard creationsRead == nil else { return nil }
        creationsRead = Task { [weak self] in
            let records = await readCreations()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // A read cancelled meanwhile (its terminals all left) never lands.
                guard let self, !Task.isCancelled else { return }
                self.creationsRead = nil
                // An unreadable store is read again on the next reconcile.
                guard let records else { return }
                self.creations = Dictionary(records.map { ($0.panelID, $0) }, uniquingKeysWith: { first, _ in first })
                self.creationsReadFor = wanted
                self.reconcile()
            }
        }
        return nil
    }
}
