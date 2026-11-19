import Foundation
import OSLog

/// C11H-67 (SH2), contract Amendment 1. c11 spreads its terminals across a
/// pool of hc sessions, each its own core, holder and parse thread, so a
/// flood or a holder loss stays inside one shard. Placement is sticky by
/// workspace.
///
/// Shard 0 is the single session every build ran before shards (`c11`,
/// `c11-<tag>`). Its terminals stay where they are and resolve there; it
/// takes no new workspace and no new terminal, so it empties as they close.
/// C11H-91: the one switch for the shard pool. A c11-only setting, read once
/// at launch; off (the default) keeps 1.7.6-h3's single session: every new
/// workspace and terminal goes to S0 and no pool core is ever started. Turn it
/// on with `defaults write <c11 bundle id> c11.shards.enabled -bool true`
/// and relaunch.
enum HCShardSettings {
    static let enabledKey = "c11.shards.enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    /// The launcher a shard's session gets: S0 always starts its core; a pool
    /// shard starts one only while shards are on.
    static func launcher(forShard index: Int, enabled: Bool, base: any HCCoreLaunching) -> any HCCoreLaunching {
        index == 0 || enabled ? base : HCReadOnlyShardLauncher()
    }

    /// A pool shard is read-only while shards are off: it reads and ends what
    /// its core serves, never creates a terminal or restarts the core.
    static func isReadOnly(shard index: Int, enabled: Bool) -> Bool { index != 0 && !enabled }
}

/// C11H-91: a pool shard's launcher while shards are off. It never starts a
/// core, so no `S0-sN` socket is created by a creation, a resolve or a
/// recovery; a core that is already serving is still joined and read.
struct HCReadOnlyShardLauncher: HCCoreLaunching {
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        throw HCUnavailableReason.coreUnreachable
    }
}

/// What the pool needs of one shard's session. `HCManagedSession` in the app;
/// tests use fakes.
protocol HCShardSession: HCSession, HCInventorySource {
    /// Connects to a core already serving this shard's socket, never launching
    /// one and never recovering a foreign build. True once connected.
    func connectIfServing() async -> Bool
    /// C11H-267: stop this shard's own core as the app quits.
    func stopForQuit(deadlineUptimeNanoseconds: UInt64) async -> HCQuitStopOutcome
    /// C11H-313: record in this shard's store that a creation the pool
    /// stopped before any shard's `create` never ran.
    func recordNeverRun(_ request: HCCreateRequest) async
}

extension HCShardSession {
    func stopForQuit(deadlineUptimeNanoseconds: UInt64) async -> HCQuitStopOutcome { .notRunning }
    func recordNeverRun(_ request: HCCreateRequest) async {}
}

/// What stopping one shard's core at quit came to (C11H-267).
enum HCQuitStopOutcome: String, Sendable {
    case stopped
    case notRunning = "not_running"
    /// Another build serves this session: left running.
    case foreignBuild = "foreign_build"
    case failed
    case timedOut = "timed_out"
}

struct HCShard: Sendable {
    let index: Int
    let configuration: HCLaunchConfiguration
    let session: any HCShardSession
    /// The same store the session uses (one instance per directory: its lock
    /// is process-wide and nonblocking). Read here only to find a panel's shard.
    let intents: HCCreationIntentStore?

    var id: HCShardID { HCShardID(index: index) }
    var name: String { configuration.session }
}

/// Which shard each workspace and panel uses. Lock-protected so the main
/// thread reads it synchronously for snapshot capture and terminal env.
final class HCShardPlacement: @unchecked Sendable {
    static let shared = HCShardPlacement()

    private let lock = NSLock()
    /// Workspace -> its placement (1...size), sticky.
    private var workspaces: [UUID: Int] = [:]
    /// Panel -> the shard its terminal lives in (0...size).
    private var homes: [UUID: Int] = [:]
    /// Panel -> the shard a pending creation targets, until it is live or settled.
    private var targets: [UUID: Target] = [:]

    /// C11H-356: a pending target and the attempt it waits for. `creation` is the creation the
    /// pool sent there; `key` is the terminal it bound to (or the panel resolved live on), and
    /// `boundAt` the shard's revision when the pool learned that key. A target with neither
    /// was placed by `creationTarget` and waits for its create or resolve.
    struct Target: Equatable, Sendable {
        let shard: Int
        var creation: UUID?
        var key: HCTerminalKey?
        var boundAt: HCRevision?

        init(shard: Int, creation: UUID? = nil, key: HCTerminalKey? = nil, boundAt: HCRevision? = nil) {
            self.shard = shard
            self.creation = creation
            self.key = key
            self.boundAt = boundAt
        }
    }
    /// Workspaces whose placement came from a saved snapshot, and the panels
    /// whose target came from one (A1.L3: such a panel resolves in its placed
    /// shard; a panel with no saved placement, key or intent resolves in S0).
    private var savedWorkspaces: Set<UUID> = []
    private var savedTargets: Set<UUID> = []

    func seed(workspace: UUID, shard: Int?) {
        guard let shard, (1...HCShardPool.size).contains(shard) else { return }
        lock.lock(); workspaces[workspace] = shard; savedWorkspaces.insert(workspace); lock.unlock()
    }

    func targetIsSaved(panel: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return savedTargets.contains(panel)
    }

    /// A saved session that names no shard of this app (another tag's, a
    /// renamed base): the panel's shard is unknown, so it is never guessed.
    private var unknownShard: Set<UUID> = []

    func seedUnknownShard(panel: UUID) {
        lock.lock(); unknownShard.insert(panel); lock.unlock()
    }

    func shardIsUnknown(panel: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return unknownShard.contains(panel)
    }

    /// Every panel's home, copied (read before the pool takes its own lock).
    func allHomes() -> [UUID: Int] {
        lock.lock(); defer { lock.unlock() }; return homes
    }

    func seed(panel: UUID, home: Int?) {
        // C11H-391: a panel may live in the links session too.
        guard let home, (0...HCShardPool.size).contains(home) || home == HCShardID.links.index else { return }
        lock.lock(); homes[panel] = home; lock.unlock()
    }

    func shard(forWorkspace workspace: UUID) -> Int? {
        lock.lock(); defer { lock.unlock() }; return workspaces[workspace]
    }

    func home(forPanel panel: UUID) -> Int? {
        lock.lock(); defer { lock.unlock() }; return homes[panel]
    }

    func target(forPanel panel: UUID) -> Int? {
        lock.lock(); defer { lock.unlock() }; return targets[panel]?.shard
    }

    /// The panel's pending target with the attempt it waits for (C11H-356).
    func pendingTarget(forPanel panel: UUID) -> Target? {
        lock.lock(); defer { lock.unlock() }; return targets[panel]
    }

    func setHome(_ shard: Int?, panel: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let shard { homes[panel] = shard; unknownShard.remove(panel) } else { homes.removeValue(forKey: panel) }
    }

    /// `creation`: the creation the pool is sending there (C11H-356), so only that attempt's
    /// terminal or end settles it.
    func setTarget(_ shard: Int, panel: UUID, workspace: UUID? = nil, creation: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        targets[panel] = Target(shard: shard, creation: creation)
        if let workspace, savedWorkspaces.contains(workspace) { savedTargets.insert(panel) }
    }

    func clearTarget(panel: UUID) {
        lock.lock(); targets.removeValue(forKey: panel); lock.unlock()
    }

    /// Clears a panel's target only while `matches` holds for it as it is now (C11H-356): a
    /// settle or an end never clears a later attempt's target.
    func clearTarget(panel: UUID, where matches: (Target) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        if let target = targets[panel], matches(target) { targets.removeValue(forKey: panel) }
    }

    /// Clears exactly this target: unchanged since it was read.
    func clearTarget(panel: UUID, ifStill expected: Target) {
        clearTarget(panel: panel) { $0 == expected }
    }

    /// Names the terminal a panel's target waits for, while `matches` holds for the target as
    /// it is now (C11H-356). `revision`: the shard's, read once the key was known.
    func attributeTarget(panel: UUID, key: HCTerminalKey, at revision: HCRevision?, where matches: (Target) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var target = targets[panel], matches(target) else { return }
        target.key = key
        target.boundAt = revision
        targets[panel] = target
    }

    /// Every pending target's shard, copied (read before the pool takes its own lock).
    func allTargets() -> [UUID: Int] {
        lock.lock(); defer { lock.unlock() }; return targets.mapValues(\.shard)
    }

    /// The pending targets on one shard, copied (read before the pool takes its own lock).
    func pendingTargets(on shard: Int) -> [UUID: Target] {
        lock.lock(); defer { lock.unlock() }; return targets.filter { $0.value.shard == shard }
    }

    /// Explicit panel removal (closed for good), never surface disposal or a move.
    func removePanel(_ panel: UUID) {
        lock.lock()
        homes.removeValue(forKey: panel); targets.removeValue(forKey: panel); savedTargets.remove(panel)
        unknownShard.remove(panel)
        // A panel with no workspace was placed under its own id.
        workspaces.removeValue(forKey: panel); savedWorkspaces.remove(panel)
        lock.unlock()
    }

    func removePanels(_ panels: Set<UUID>) {
        for panel in panels { removePanel(panel) }
    }

    func removeWorkspace(_ workspace: UUID) {
        lock.lock(); workspaces.removeValue(forKey: workspace); savedWorkspaces.remove(workspace); lock.unlock()
    }

    /// A workspace closed by the operator or an agent (C11H-94). Ignored while
    /// the app terminates: quitting keeps every placement for the snapshot.
    /// A moved or detached workspace is not closed and keeps its placement.
    func workspacesClosedForGood(_ ids: Set<UUID>, isTerminatingApp: Bool) {
        guard PanelCloseForGoodPolicy.shouldFire(isDetaching: false, isTerminatingApp: isTerminatingApp) else { return }
        for id in ids { removeWorkspace(id) }
    }

    /// Entries counted for tests and diagnostics: workspaces, homes, targets.
    var entryCounts: (workspaces: Int, homes: Int, targets: Int) {
        lock.lock(); defer { lock.unlock() }; return (workspaces.count, homes.count, targets.count)
    }

    /// The workspace's placement, choosing and recording the least-loaded
    /// candidate the first time. Load is the shard's live terminals plus the
    /// panels whose creation targets it and is not yet live, so two workspaces
    /// opening at once do not both see an empty shard. Ties go to the lowest index.
    ///
    /// Decision (C11H-94, hc Lead item 5): placement is "least live terminals
    /// plus pending targets", not live terminals alone. Pending targets are the
    /// only load a shard has between a creation's placement and its first
    /// inventory, so without them a burst of new workspaces all lands on one
    /// shard. A target leaves the count once its shard's inventory, as the pool
    /// has absorbed it, holds the terminal of the attempt that set it (C11H-356:
    /// never an earlier terminal of the same panel), when that attempt resolves
    /// ended, when its creation is refused before transmission, or when the panel
    /// closes for good. An unresolved panel keeps its target until then.
    /// `liveTerminals` is read before this lock is taken (the pool's lock is
    /// never taken inside the placement lock).
    ///
    /// C11H-346: `targetsBeforeCounts` are the targets read before those counts. A target is
    /// cleared only once its shard's absorbed inventory holds the terminal, so one cleared
    /// before that read is in the counts, and one cleared after it is still pending here: no
    /// placed terminal is missing from both (at worst one counts twice for this choice).
    func place(workspace: UUID, candidates: [Int], liveTerminals counts: [Int: Int],
               targetsBeforeCounts: [UUID: Int] = [:]) -> Int? {
        let liveTerminals: (Int) -> Int = { counts[$0, default: 0] }
        lock.lock(); defer { lock.unlock() }
        if let placed = workspaces[workspace], candidates.contains(placed) { return placed }
        var pending: [Int: Int] = [:]
        for shard in targets.mapValues(\.shard).merging(targetsBeforeCounts, uniquingKeysWith: { now, _ in now }).values {
            pending[shard, default: 0] += 1
        }
        guard let chosen = candidates.min(by: { lhs, rhs in
            let left = liveTerminals(lhs) + pending[lhs, default: 0]
            let right = liveTerminals(rhs) + pending[rhs, default: 0]
            return left == right ? lhs < rhs : left < right
        }) else { return nil }
        workspaces[workspace] = chosen
        return chosen
    }

    /// Panels closed for good drop their placement (C11H-94). Moves and app
    /// termination never fire this observer, so a moving or quitting panel
    /// keeps its shard.
    @MainActor
    static func installCloseObserver(lineage: PanelLineage = .shared, placement: HCShardPlacement = .shared) {
        lineage.addPanelClosedForGoodObserver { placement.removePanels($0) }
    }

#if DEBUG
    func resetForTesting() {
        lock.lock()
        workspaces.removeAll(); homes.removeAll(); targets.removeAll(); savedWorkspaces.removeAll(); savedTargets.removeAll()
        lock.unlock()
    }
#endif
}

/// The pool, and the app-wide view of it. Global consumers (End All,
/// Recovered, the machine directory, diagnostics, admission) read the merged
/// inventory; each panel talks to its own shard through `route(panelID:)`.
/// `shards` is the explicit list SH3, SH4 and SH5 iterate.
final class HCShardPool: HCSession, HCInventorySource, @unchecked Sendable {
    /// K, one constant: change it if real use asks (hc-shards-c11.md, settled 1).
    static let size = HCShardID.poolSize
    static func base(tag: String?) -> String { HCShardID.base(tag: tag) }
    static func session(base: String, shard: HCShardID) -> String { HCShardID.session(base: base, shard: shard) }

    let shards: [HCShard]

    /// C11H-267: Keep Terminals After Quit is off. Stops every shard's own
    /// core at once, each within the deadline.
    func stopAllForQuit(deadlineUptimeNanoseconds deadline: UInt64) async -> [Int: HCQuitStopOutcome] {
        await withTaskGroup(of: (Int, HCQuitStopOutcome).self) { group in
            for shard in shards {
                group.addTask { (shard.index, await shard.session.stopForQuit(deadlineUptimeNanoseconds: deadline)) }
            }
            var outcomes: [Int: HCQuitStopOutcome] = [:]
            for await (index, outcome) in group { outcomes[index] = outcome }
            return outcomes
        }
    }
    let placement: HCShardPlacement
    private let byIndex: [Int: HCShard]
    private let feed = HCSessionFeed()
    private let queue = DispatchQueue(label: "c11.hc.shard-pool")
    private let lock = NSLock()
    private var cached: [Int: HCInventorySnapshot] = [:]
    /// Shards that reached a ready inventory in this process. Only these
    /// decide the merged readiness, so an unused shard never holds it pending.
    private var connected: Set<Int> = []
    /// C11H-113: each shard's answer to the latest restore probe (serving or
    /// not), for that round only. Empty until a probe runs.
    private var probeRound: UInt64 = 0
    private var probed: [Int: Bool] = [:]
    private var lastGenerations: [Int: UInt64] = [:]
    private var mergedGeneration: UInt64 = 0
    private var mergedSequence: UInt64 = 0
    private var reconciling: [UUID: Task<Result<IntentScan, HCUnavailableReason>, Never>] = [:]
    private var reconciled: Set<UUID> = []
    private var announced: Set<Int> = []
    /// Called once per shard, off-main, the first time it publishes a live
    /// snapshot in this process (lazy start or joining a serving core). SH5
    /// lists the shard in diagnostics from here; SH4 may hook its link here.
    var onShardStarted: (@Sendable (HCShard) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return startedHook }
        set { lock.lock(); startedHook = newValue; lock.unlock() }
    }
    private var startedHook: (@Sendable (HCShard) -> Void)?
    private var observations: [HCObservation] = []

    /// False while shards are off (C11H-91): no workspace is placed on a pool shard.
    let placementEnabled: Bool

    init(shards: [HCShard], placement: HCShardPlacement = .shared, placementEnabled: Bool = true) {
        self.placementEnabled = placementEnabled
        self.shards = shards.sorted { $0.index < $1.index }
        self.placement = placement
        byIndex = Dictionary(shards.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = shards.sorted { $0.index < $1.index }
        let fallback = sorted.contains { $0.index == 0 } ? 0 : sorted.first?.index
        fanout = HCHomeFanout(home: { [placement] panel in
            placement.home(forPanel: panel) ?? placement.target(forPanel: panel) ?? fallback
        })
        observations = self.shards.map { shard in
            shard.session.observe(on: queue) { [weak self] snapshot in self?.accept(shard.index, snapshot) }
        }
        fanout.attach(self.shards.map { ($0.index, $0.id, $0.session) })
    }

    /// C11H-238: the panels' inventory observers (`observeHome`).
    let fanout: HCHomeFanout

    #if DEBUG
    /// C11H-346 test seam: holds the observer queue, so no shard snapshot is absorbed until resumed.
    func suspendObserverQueueForTesting() { queue.suspend() }
    func resumeObserverQueueForTesting() { queue.resume() }
    /// C11H-356 test seam: returns once every delivery offered so far has been absorbed (a
    /// delivery the first pass queues runs before the second).
    func drainObserverQueueForTesting() { queue.sync {}; queue.sync {} }
    #endif

    func shard(_ index: Int) -> HCShard? { byIndex[index] }

    /// The shard of this app named by a saved session (the snapshot keeps the
    /// session a panel's key belongs to). nil for any other session.
    func index(ofSession session: String) -> Int? { shards.first { $0.name == session }?.index }

    /// Restore's one decision for a terminal's saved session (C11H-92). A
    /// session of this app seeds the panel's home there. A session it does
    /// not have (another tag's, a renamed base) marks the shard unknown:
    /// unresolved until a shard reports the key's core, never S0. No saved
    /// session (a pre-shard snapshot) marks nothing, so the panel resolves in S0.
    func seedRestored(panel: UUID, savedSession: String?) {
        guard let savedSession else { return }
        if let home = index(ofSession: savedSession) {
            placement.seed(panel: panel, home: home)
        } else {
            placement.seedUnknownShard(panel: panel)
        }
    }

    /// Shards a new workspace may take: every pool shard, never shard 0 and
    /// never the links session (C11H-391).
    var placementCandidates: [Int] { placementEnabled ? shards.map(\.index).filter { (1...Self.size).contains($0) } : [] }

    /// C11H-391: the links session `L` of an adopted app, when composed. It
    /// holds linked machines only: no workspace is placed there, and it takes
    /// only the remote terminals routing gives it.
    var links: HCShard? { byIndex[HCShardID.links.index] }

    /// C11H-391: each session's unusable machine names (the stored-link
    /// reviews'), read when a remote creation is routed. The composition
    /// passes the app-wide copy; tests pass their own.
    var unusableLinks: @Sendable () -> [String: Set<String>] {
        get { lock.lock(); defer { lock.unlock() }; return unusableHook }
        set { lock.lock(); unusableHook = newValue; lock.unlock() }
    }
    private var unusableHook: @Sendable () -> [String: Set<String>] = { HCLinkedMachines.shared.unusableSessions() }

    /// C11H-391: each started shard's machine lines, in shard order.
    func sessionMachines() -> [HCSessionMachines] {
        lock.lock(); defer { lock.unlock() }
        return sessionMachinesLocked()
    }

    private func sessionMachinesLocked() -> [HCSessionMachines] {
        shards.compactMap { shard in
            cached[shard.index].map {
                HCSessionMachines(shard: shard.id, session: shard.name, machines: $0.machines,
                                  takesCreations: shard.id.isLinks
                                      || !HCShardSettings.isReadOnly(shard: shard.index, enabled: placementEnabled))
            }
        }
    }

    /// C11H-391: the link a new terminal on `machine` uses (usable wins).
    func route(machine: String) -> HCMachineRouting.Link? {
        HCMachineRouting.route(machine, sessions: sessionMachines(), unusable: unusableLinks())
    }

    // MARK: Placement

    /// Decided on main when a terminal starts, before its environment is
    /// built: the shard a creation for this panel would use. Commits the
    /// workspace's placement the first time and counts the panel as pending
    /// there until it is live. A remote terminal stays on shard 0, whose core
    /// holds the hand-made link, unless its workspace's shard is paired (SH4).
    ///
    /// Decision (C11H-94, hc Lead item 5): a restored pre-shard workspace has
    /// its placement committed at its first terminal start, even when every
    /// terminal there only reattaches in S0. Committing places nothing and
    /// starts no core: a pool core starts only when a creation goes to it (lazy
    /// start), and a reattached panel's target is cleared when it resolves.
    /// Committing early keeps one answer per workspace from the first start, so
    /// its terminals' environments, its next creation and its snapshot agree.
    /// The cost is that the shard is chosen by restore order, not by the load at
    /// the workspace's first creation.
    func creationTarget(panelID: UUID, workspaceID: UUID?, machine: String?) -> HCShard? {
        let routed = machine.flatMap { route(machine: $0) }
        // C11H-391: a machine the links session links usably is opened there,
        // whatever the workspace (a split of a c11h-era panel, a saved agent
        // config): usable wins over c11h's old link of the same name.
        if let links, routed?.shard == links.id {
            placement.setTarget(links.index, panel: panelID)
            fanout.placementChanged(panelID: panelID)
            return links
        }
        let chosen = pairedCreationTarget(panelID: panelID, workspaceID: workspaceID, machine: machine)
        // C11H-396: the preflight (`--on`, the picker, the menus) admits a
        // name when its routed link is usable. A started shard chosen above
        // that doesn't link the machine usably (its pairing's link is older,
        // or it links none) gives way to that routed link, so a creation the
        // preflight admitted never goes to an unusable one. A paired shard
        // not started yet keeps its pairing: its link is not known until it starts.
        if let machine, let routed, routed.usable, routed.shard != chosen?.id,
           let shard = byIndex[routed.shard.index], let chosen, !keeps(machine, in: chosen, over: routed) {
            placement.setTarget(shard.index, panel: panelID)
            fanout.placementChanged(panelID: panelID)
            return shard
        }
        return chosen
    }

    /// C11H-396: whether `shard`, the shard placement chose, keeps a new
    /// terminal on `machine` rather than give way to the routed usable link.
    /// A started shard keeps it when it links the machine usably and its link
    /// is up, or the routed one is down too. A shard not started yet keeps it
    /// only when the pairing file pairs it with the machine (its link is
    /// unknown until it starts); shard 0 chosen as the fallback of no pairing
    /// gives way to the link that is known.
    private func keeps(_ machine: String, in shard: HCShard, over routed: HCMachineRouting.Link) -> Bool {
        lock.lock()
        let machines = cached[shard.index]?.machines
        lock.unlock()
        guard let machines else { return isPaired(machine, shard.name) }
        guard let availability = machines[machine],
              !(unusableLinks()[shard.name]?.contains(machine) ?? false) else { return false }
        return availability == .connected || routed.availability != .connected
    }

    /// The shard placement and the pairing file (C11H-78, SH4) choose.
    private func pairedCreationTarget(panelID: UUID, workspaceID: UUID?, machine: String?) -> HCShard? {
        let legacy = byIndex[0] ?? shards.first
        guard !placementCandidates.isEmpty else { return legacy }
        // C11H-78 (SH4): a remote terminal follows its workspace's shard only
        // when the operator's pairing file pairs that shard with the machine;
        // otherwise it stays on shard 0, whose core holds the hand-made link.
        if let machine, !anyShardPaired(machine) { return legacy }
        // A workspace whose first terminal is remote is placed among the shards
        // paired with that machine, so it never sticks to an unpaired one.
        let workspace = workspaceID ?? panelID
        var candidates = placementCandidates
        if let machine, placement.shard(forWorkspace: workspace) == nil {
            candidates = candidates.filter { byIndex[$0].map { isPaired(machine, $0.name) } ?? false }
        }
        let targetsBeforeCounts = placement.allTargets()
        guard let index = placement.place(workspace: workspace, candidates: candidates,
                                          liveTerminals: liveTerminalCounts(), targetsBeforeCounts: targetsBeforeCounts),
              let shard = byIndex[index] else { return legacy }
        if let machine, !isPaired(machine, shard.name) { return legacy }
        placement.setTarget(index, panel: panelID, workspace: workspace)
        fanout.placementChanged(panelID: panelID)
        return shard
    }

    /// C11H-78: whether the operator's pairing file pairs a shard session with
    /// a machine. Set by the composition; nil (tests, no file) pairs nothing.
    var pairedWith: (@Sendable (_ machine: String, _ session: String) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return pairingHook }
        set { lock.lock(); pairingHook = newValue; lock.unlock() }
    }
    private var pairingHook: (@Sendable (_ machine: String, _ session: String) -> Bool)?

    private func isPaired(_ machine: String, _ session: String) -> Bool { pairedWith?(machine, session) ?? false }

    private func anyShardPaired(_ machine: String) -> Bool {
        shards.contains { (1...Self.size).contains($0.index) && isPaired(machine, $0.name) }
    }

    private func liveTerminalCounts() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: placementCandidates.map { ($0, liveTerminals(in: $0)) })
    }

    /// Live (not finished) terminals in a shard's last inventory.
    func liveTerminals(in index: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return cached[index]?.records.values.filter { $0.state != .finished }.count ?? 0
    }

    /// The shard a panel resolves in (A1.L3): the shard its pending intent or
    /// saved session names, else its saved workspace placement, else S0 (a
    /// snapshot from before shards). The first lookup in this process
    /// reconciles against durable intents in every shard's store, so a crash
    /// between creation and autosave cannot leave the snapshot's shard stale.
    /// A panel minted in this process with no creation resolves where its
    /// creation will go.
    func homeIndex(for identity: HCPanelIdentity) async throws -> Int? {
        let panel = identity.panelID
        // A panel minted in this process with no creation has no intent in any store.
        if !(identity.origin == .fresh && identity.key == nil && identity.creationID == nil) {
            try await reconcile(identity)
        }
        if let home = placement.home(forPanel: panel) { return home }
        // A saved session this app does not have names an unknown shard:
        // unresolved, and read again on the next lookup (A1 detail: never guessed).
        if placement.shardIsUnknown(panel: panel) {
            // Once a shard reports the key's core, that shard is the panel's.
            if let key = identity.key, let index = shardIndex(for: key) {
                placement.setHome(index, panel: panel)
                return index
            }
            // C11H-113: once every shard has answered and none owns it (or it
            // has no key to own), the operator decides (Retry), never eternal
            // pending. A retired shard name, should the pool shrink, lands here too.
            if shardsSettled() { throw HCUnavailableReason.recoveryRequired }
            throw HCUnavailableReason.inventoryPending
        }
        let legacy = byIndex[0] != nil ? 0 : nil
        if let key = identity.key {
            // A shard that reports the key's core owns it. With no saved session
            // the snapshot predates shards and the panel resolves in S0 (A1.L3).
            guard let index = shardIndex(for: key) ?? legacy else { return nil }
            placement.setHome(index, panel: panel)
            return index
        }
        if identity.creationID != nil, let legacy {
            placement.setHome(legacy, panel: panel)
            return legacy
        }
        if identity.origin == .fresh || placement.targetIsSaved(panel: panel) {
            return placement.target(forPanel: panel)
        }
        return legacy
    }

    /// Reads this panel's intent in every shard's store (a read starts no core)
    /// and applies it once per process: a single unsettled intent names the
    /// panel's shard; with none, the shard holding the panel's current creation
    /// (settled, say after a refused first run) does. Concurrent lookups share
    /// one read. A store that cannot be read, or unsettled intents in two
    /// shards, is never absence: the lookup fails (unresolved) and the next one
    /// reads again (A1.L3: `new` needs no pending intent in any store).
    private struct IntentScan: Sendable {
        var found: [Int: HCStoredCreation] = [:]
        /// Shards whose store cannot be read at all (corrupt, unreadable): not busy.
        var broken: Set<Int> = []
    }
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.shards")

    private func reconcile(_ identity: HCPanelIdentity) async throws {
        let panel = identity.panelID
        let task: Task<Result<IntentScan, HCUnavailableReason>, Never>
        lock.lock()
        if reconciled.contains(panel) { lock.unlock(); return }
        if let running = reconciling[panel] { task = running } else {
            task = Task { [shards] in
                var scan = IntentScan()
                for shard in shards {
                    guard let intents = shard.intents,
                          FileManager.default.fileExists(atPath: shard.configuration.intentDirectory
                            .appendingPathComponent("creation-intents.json").path) else { continue }
                    do {
                        if let intent = try await intents.read(panelID: panel) { scan.found[shard.index] = intent }
                    } catch is HCIntentStoreBusy {
                        return .failure(.intentStoreFailure)
                    } catch {
                        scan.broken.insert(shard.index)
                    }
                }
                return .success(scan)
            }
            reconciling[panel] = task
        }
        lock.unlock()
        let result = await task.value
        lock.lock()
        if reconciling[panel] == task { reconciling.removeValue(forKey: panel) }
        let first = !reconciled.contains(panel)
        lock.unlock()
        let found: [Int: HCStoredCreation]
        let broken: Set<Int>
        switch result {
        case .failure(let reason): throw reason
        case .success(let value): found = value.found; broken = value.broken
        }
        // C11H-93: a store that cannot be read blocks only its own shard's
        // panels (the one this panel lives in, or would be created in); the
        // others proceed, and the scan repeats until the store reads again.
        if !broken.isEmpty {
            let own = placement.home(forPanel: panel) ?? placement.target(forPanel: panel) ?? (byIndex[0] != nil ? 0 : nil)
            if let own, broken.contains(own) { throw HCUnavailableReason.intentStoreFailure }
            noteBroken(broken)
        }
        let active = found.filter { $0.value.phase != .ended }.keys.sorted()
        guard active.count <= 1 else { throw HCUnavailableReason.ambiguousIdentity }
        guard first else { return }
        let home = placement.home(forPanel: panel)
        if let only = active.first {
            if home != only { placement.setHome(only, panel: panel) }
        } else if home == nil, let creation = identity.creationID,
                  let owner = found.first(where: { $0.value.creationID == creation })?.key {
            placement.setHome(owner, panel: panel)
        }
        if broken.isEmpty { lock.lock(); reconciled.insert(panel); lock.unlock() }
    }

    private var reportedBroken: Set<Int> = []

    /// Logged once per shard per process.
    private func noteBroken(_ broken: Set<Int>) {
        lock.lock()
        let fresh = broken.subtracting(reportedBroken)
        reportedBroken.formUnion(fresh)
        lock.unlock()
        for index in fresh.sorted() {
            Self.logger.error("hc_intent_store_unreadable shard=\(index) session=\(self.byIndex[index]?.name ?? "-", privacy: .public): its own panels stay unresolved; other shards proceed")
        }
    }

    /// The shard is ready under a core id other than the key's, and holds no
    /// remote machine whose terminals could carry a foreign core id.
    private func coreChanged(_ index: Int, key: HCTerminalKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = cached[index], case .ready = snapshot.readiness,
              let core = snapshot.buildIdentity?.coreID else { return false }
        return core != key.owningCoreID && snapshot.machines.isEmpty && snapshot.records[key] == nil
    }

    /// The shard whose inventory holds this key, else whose core owns it.
    func shardIndex(for key: HCTerminalKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        for shard in shards where cached[shard.index]?.records[key] != nil { return shard.index }
        for shard in shards where cached[shard.index]?.buildIdentity?.coreID == key.owningCoreID { return shard.index }
        return nil
    }

    // MARK: Per-panel routing

    func route(panelID: UUID) -> HCShardRoute { HCShardRoute(pool: self, panelID: panelID) }

    func resolveRouted(_ identity: HCPanelIdentity) async -> HCLifecycle {
        let panel = identity.panelID
        let home: Int?
        do { home = try await homeIndex(for: identity) }
        catch { return .unresolved(identity, (error as? HCUnavailableReason) ?? .intentStoreFailure) }
        guard let index = home, let shard = byIndex[index] else {
            // A panel minted in this process with no creation yet has no
            // terminal anywhere: no shard holds an intent for it.
            if identity.origin == .fresh, identity.key == nil, identity.creationID == nil { return .new }
            return .unresolved(identity, .inventoryPending)
        }
        var result = await shard.session.resolve(identity)
        if case .unresolved(_, .connectionLost) = result, let key = identity.key, coreChanged(index, key: key) {
            // The saved session's core has a new id (its state was deleted):
            // resolve by labels there, never by address alone (A1 detail).
            result = await shard.session.resolve(HCPanelIdentity(panelID: panel, persistence: identity.persistence,
                creationID: identity.creationID, origin: identity.origin))
        }
        switch result {
        case .live(let record):
            placement.setHome(index, panel: panel)
            if let target = placement.pendingTarget(forPanel: panel) {
                if target.shard != index {
                    // Live elsewhere: exactly the target read here leaves the count.
                    placement.clearTarget(panel: panel, ifStill: target)
                } else {
                    // C11H-356: the target waits for this terminal, unless a creation it
                    // carries is another terminal's (that creation's own result names it).
                    let made = record.labels["c11.creation"].flatMap(UUID.init(uuidString:))
                    if target.key == nil, target.creation == nil || target.creation == made {
                        let boundAt = await shard.session.snapshot().revision
                        placement.attributeTarget(panel: panel, key: record.key, at: boundAt) { $0 == target }
                    }
                    settleTargets(on: index, only: panel)
                }
            }
        case .ended(let evidence):
            // C11H-356: an earlier terminal's end leaves its replacement's target pending.
            placement.clearTarget(panel: panel) { !Self.endsAnotherAttempt(evidence, than: $0) }
        case .new, .unresolved: break
        }
        fanout.placementChanged(panelID: panel)
        return result
    }

    func createRouted(_ request: HCCreateRequest) async -> HCCreateResult {
        let panel = request.identity.panelID
        let home: Int?
        do { home = try await homeIndex(for: request.identity) }
        catch { return await neverRan(request, .unresolved(request.identity, (error as? HCUnavailableReason) ?? .intentStoreFailure)) }
        // Where the panel's terminal lived before this attempt (nil: nowhere yet).
        let previousHome = placement.home(forPanel: panel)
        // C11H-78: a remote creation goes where creationTarget placed it (a
        // paired shard); with no target it stays on S0, the hand-made link.
        let requested = request.machine == nil ? (request.shard?.index ?? placement.target(forPanel: panel) ?? home)
            : (request.shard?.index ?? placement.target(forPanel: panel) ?? (byIndex[0] != nil ? 0 : home))
        guard let index = requested, let shard = byIndex[index] else {
            return await neverRan(request, .rejectedBeforeTransmission(.backendNotInstalled))
        }
        var forwarded = request
        if let home, home != index {
            // The terminal it replaces lives on another shard: that shard must
            // prove the end first; the target then resolves before creating.
            guard let old = byIndex[home] else { return await neverRan(request, .unresolved(request.identity, .inventoryPending)) }
            switch await old.session.resolve(request.identity) {
            case .ended, .new: break
            case .live(let record): return .bound(record)
            case .unresolved(_, let reason): return await neverRan(request, .unresolved(request.identity, reason))
            }
            forwarded = request.retargeted(identity: HCPanelIdentity(panelID: panel,
                persistence: request.identity.persistence, origin: request.identity.origin))
        }
        placement.setHome(index, panel: panel)
        placement.setTarget(index, panel: panel, creation: request.creationID)
        fanout.placementChanged(panelID: panel)
        let result = await shard.session.create(forwarded)
        switch result {
        case .bound(let record):
            // C11H-356: the target now waits for this terminal (finished or not) in the absorbed
            // inventory, or a ready one at or after this read that no longer holds it (it ended
            // before the pool absorbed any inventory showing it). Set before returning.
            let boundAt = await shard.session.snapshot().revision
            placement.attributeTarget(panel: panel, key: record.key, at: boundAt) {
                $0.shard == index && $0.creation == request.creationID
            }
            settleTargets(on: index, only: panel)
        case .rejectedBeforeTransmission:
            // Nothing was sent. A replaced terminal is still where it was; a
            // first creation stays with the shard that holds its settled intent,
            // so a retry resolves there (sticky, A1.L3). Not pending load.
            placement.clearTarget(panel: panel) { $0.creation == request.creationID }
            placement.setHome(previousHome ?? index, panel: panel)
            // C11H-313: the panel resolves where its old terminal lives again;
            // that store must also know this creation never ran, or a close
            // following it there reads the old creation's end and waits.
            if let previousHome, previousHome != index, let old = byIndex[previousHome] {
                await old.session.recordNeverRun(request)
            }
        case .unresolved: break
        }
        fanout.placementChanged(panelID: panel)
        return result
    }

    /// C11H-313: a creation stopped here, before any shard's `create`, never
    /// ran. The shard the panel resolves in records that, so a close of the
    /// panel (whose identity already carries the creation) can settle.
    private func neverRan(_ request: HCCreateRequest, _ result: HCCreateResult) async -> HCCreateResult {
        let panel = request.identity.panelID
        let index = placement.home(forPanel: panel) ?? request.identity.key.flatMap { shardIndex(for: $0) }
            ?? (byIndex[0] != nil ? 0 : shards.first?.index)
        if let index, let shard = byIndex[index] { await shard.session.recordNeverRun(request) }
        return result
    }

    /// Forwards only the snapshots of the panel's current shard, so one
    /// shard's outage never revokes another shard's panels. C11H-238: one
    /// fan-out per pool matches each snapshot off main and delivers only to
    /// observers whose own view changed (`HCHomeFanout`).
    func observeHome(panelID: UUID, on queue: DispatchQueue, interest: HCHomeInterest? = nil,
                     handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        fanout.register(panelID: panelID, on: queue, interest: interest, handler: handler)
    }

    /// After restore: connect to every shard whose core is already serving,
    /// launching none, so the merged inventory and Recovered see every shard.
    func connectServingShards() {
        Task.detached(priority: .utility) { [self] in await self.probeServingShards() }
    }

    /// Asks every shard once whether its core is serving (joining it if so,
    /// launching none) and records each answer for this round (C11H-113).
    func probeServingShards() async {
        lock.lock(); probeRound += 1; let round = probeRound; probed.removeAll(); lock.unlock()
        await withTaskGroup(of: (Int, Bool).self) { group in
            for shard in shards { group.addTask { (shard.index, await shard.session.connectIfServing()) } }
            for await (index, serving) in group {
                lock.lock()
                if round == probeRound { probed[index] = serving }
                lock.unlock()
            }
        }
    }

    /// Every shard answered the latest probe, and every serving one has a
    /// ready inventory: a key's core no shard reports is on no shard this app
    /// reaches. False before any probe, so an unprobed pool never decides.
    func shardsSettled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard probed.count == shards.count else { return false }
        return probed.allSatisfy { index, serving in !serving || connected.contains(index) }
    }

    // MARK: Merged inventory (app-wide consumers)

    private func accept(_ index: Int, _ snapshot: HCInventorySnapshot) {
        let merged = absorb(index, snapshot)
        settleTargets(on: index)
        guard let merged else { return }
        announceStarted()
        feed.publish(merged)
    }

    /// C11H-346: a placed terminal is its shard's pending load (its panel's target) until the
    /// shard's inventory, as this pool has absorbed it, holds the terminal; from then its record
    /// counts. Clearing the target when `create` returned left the terminal in neither count
    /// until the observer absorbed the shard's next snapshot, so a workspace placed in that
    /// window joined the busy shard. Runs after each absorb and after a bound creation or a
    /// live resolve, so whichever comes second clears it. The inventory is copied under the
    /// lock and scanned after it; each clear applies only to the target as it was scanned.
    private func settleTargets(on index: Int, only panel: UUID? = nil) {
        let pending = placement.pendingTargets(on: index).filter { panel == nil || $0.key == panel }
        guard !pending.isEmpty else { return }
        lock.lock(); let snapshot = cached[index]; lock.unlock()
        guard let snapshot else { return }
        for (panel, target) in pending where Self.settles(target, in: snapshot) {
            placement.clearTarget(panel: panel, ifStill: target)
        }
    }

    /// C11H-356: whether a shard's absorbed inventory settles a target. It does when it holds the
    /// attempt's own terminal, finished or not (by its bound key, else by its `c11.creation`
    /// label), or, once the key is known, when a ready inventory at or after `boundAt` no longer
    /// holds it (the terminal ended before the pool absorbed any inventory showing it). Another
    /// terminal of the same panel, earlier or finished, never settles it; nor does any record
    /// settle a target with no creation or key yet.
    private static func settles(_ target: HCShardPlacement.Target, in snapshot: HCInventorySnapshot) -> Bool {
        if let key = target.key {
            if snapshot.records[key] != nil { return true }
            guard let boundAt = target.boundAt, case .ready = snapshot.readiness else { return false }
            let at = snapshot.revision
            return at.connectionGeneration > boundAt.connectionGeneration
                || (at.connectionGeneration == boundAt.connectionGeneration && at.sequence >= boundAt.sequence)
        }
        guard let creation = target.creation?.uuidString.lowercased() else { return false }
        return snapshot.records.values.contains { $0.labels["c11.creation"]?.lowercased() == creation }
    }

    /// C11H-356: an end that names another terminal or creation than the target's own attempt
    /// (the panel's earlier terminal, resolved while its replacement is pending). An end that
    /// names nothing comparable is the target's.
    private static func endsAnotherAttempt(_ evidence: HCEndEvidence, than target: HCShardPlacement.Target) -> Bool {
        if let key = target.key, let ended = evidence.key { return ended != key }
        if let creation = target.creation, let ended = evidence.creationID { return ended != creation }
        return false
    }

    private func announceStarted() {
        lock.lock()
        let fresh = cached.keys.filter { !announced.contains($0) }.sorted()
        announced.formUnion(fresh)
        let hook = startedHook
        lock.unlock()
        guard let hook else { return }
        for index in fresh { if let shard = byIndex[index] { hook(shard) } }
    }

    /// Records a shard's snapshot. An unused shard's initial placeholder
    /// (connection generation 0) is not a shard in use.
    private func absorb(_ index: Int, _ snapshot: HCInventorySnapshot) -> HCInventorySnapshot? {
        let homes = placement.allHomes()
        lock.lock(); defer { lock.unlock() }
        guard snapshot.revision.connectionGeneration > 0 || connected.contains(index) else { return nil }
        // A shard's connection generations only grow: a delayed read of a
        // retired connection never replaces a newer one (L4 ordering).
        if let previous = cached[index], snapshot.revision.connectionGeneration < previous.revision.connectionGeneration {
            return nil
        }
        if let previous = cached[index], previous.revision.connectionGeneration == snapshot.revision.connectionGeneration {
            if snapshot.revision.sequence < previous.revision.sequence { return nil }
            // A re-read of the same state changes nothing for the merged view.
            if snapshot.revision == previous.revision, snapshot.readiness == previous.readiness,
               snapshot.panelBindings == previous.panelBindings, snapshot.buildIdentity == previous.buildIdentity,
               snapshot.machines == previous.machines { return nil }
        }
        if case .ready = snapshot.readiness { connected.insert(index) }
        cached[index] = snapshot
        if lastGenerations[index] != snapshot.revision.connectionGeneration {
            lastGenerations[index] = snapshot.revision.connectionGeneration
            mergedGeneration += 1
        }
        mergedSequence += 1
        return mergedLocked(homes: homes)
    }

    private func mergedLocked(homes: [UUID: Int]) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: mergedGeneration, sequence: mergedSequence)
        var readiness = HCReadiness.ready(revision)
        if connected.isEmpty {
            readiness = .pending(cached.values.compactMap { snapshot -> HCUnavailableReason? in
                if case .pending(let reason) = snapshot.readiness { return reason }
                return nil
            }.first ?? .backendNotInstalled)
        } else {
            for index in connected.sorted() {
                if case .pending(let reason) = cached[index]?.readiness { readiness = .pending(reason); break }
            }
        }
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        var bindings: [UUID: HCTerminalKey] = [:]
        var machines: [String: HCMachineAvailability] = [:]
        var shardReadiness: [HCShardID: HCReadiness] = [:]
        var shardRevisions: [HCShardID: HCRevision] = [:]
        var shardCoreIDs: [HCShardID: String] = [:]
        var recordShards: [HCTerminalKey: HCShardID] = [:]
        for shard in shards.reversed() {
            guard let snapshot = cached[shard.index] else { continue }
            records.merge(snapshot.records) { _, lower in lower }
            bindings.merge(snapshot.panelBindings) { _, lower in lower }
            machines.merge(snapshot.machines) { _, lower in lower }
            shardReadiness[shard.id] = snapshot.readiness
            shardRevisions[shard.id] = snapshot.revision
            if let coreID = snapshot.buildIdentity?.coreID { shardCoreIDs[shard.id] = coreID }
            for key in snapshot.records.keys { recordShards[key] = shard.id }
        }
        // A panel's binding is its home shard's: a shard it left (S0 after a
        // recreation in the pool) keeps a binding to the dead terminal (C11H-92).
        for (panel, home) in homes where bindings[panel] != nil || cached[home]?.panelBindings[panel] != nil {
            bindings[panel] = cached[home]?.panelBindings[panel]
        }
        // Consumers that need one build identity still get the first shard's;
        // admission (SH3) decides per shard from the maps below.
        let identity = shards.lazy.compactMap { self.cached[$0.index]?.buildIdentity }.first
        return HCInventorySnapshot(readiness: readiness, revision: revision, records: records,
            buildIdentity: identity, panelBindings: bindings, machines: machines,
            shardReadiness: shardReadiness, shardRevisions: shardRevisions, shardCoreIDs: shardCoreIDs,
            recordShards: recordShards, sessionMachines: sessionMachinesLocked())
    }

    private func merged(after snapshots: [(Int, HCInventorySnapshot)]) -> HCInventorySnapshot {
        var latest: HCInventorySnapshot?
        for (index, snapshot) in snapshots {
            if let next = absorb(index, snapshot) { latest = next }
            settleTargets(on: index)
        }
        // Idempotent: a shard already absorbed by the observer is announced here too.
        announceStarted()
        if let latest { feed.publish(latest); return latest }
        let homes = placement.allHomes()
        lock.lock(); defer { lock.unlock() }
        return mergedLocked(homes: homes)
    }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }

    func snapshot() async -> HCInventorySnapshot {
        merged(after: await collect { await $0.snapshot() })
    }

    func refresh() async -> HCInventorySnapshot {
        let snapshots = await collect { await $0.refresh() }
        // A refresh is a new authoritative read even if no shard moved.
        advanceSequence()
        return merged(after: snapshots)
    }

    private func advanceSequence() {
        lock.lock(); mergedSequence += 1; lock.unlock()
    }

    /// The shard's own connection generation, when the caller's merged
    /// generation is still current.
    private func shardGeneration(_ index: Int, ifMerged generation: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard generation == mergedGeneration else { return nil }
        return cached[index]?.revision.connectionGeneration
    }

    private func collect(_ body: @escaping @Sendable (any HCShardSession) async -> HCInventorySnapshot) async -> [(Int, HCInventorySnapshot)] {
        await withTaskGroup(of: (Int, HCInventorySnapshot).self) { group in
            for shard in shards { group.addTask { (shard.index, await body(shard.session)) } }
            var result: [(Int, HCInventorySnapshot)] = []
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }
        }
    }

    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? {
        guard let index = shardIndex(for: key), let shard = byIndex[index],
              let generation = shardGeneration(index, ifMerged: connectionGeneration) else { return nil }
        return await shard.session.enrichStatusTimestamp(for: key, matchingStatus: status, turn: turn,
                                                         connectionGeneration: generation)
    }

    // MARK: HCSession (app-wide)

    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { await resolveRouted(identity) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { await createRouted(request) }

    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        guard let index = shardIndex(for: key), let shard = byIndex[index] else { throw HCUnavailableReason.inventoryPending }
        return try await shard.session.attach(key, sink: sink, display: display)
    }

    func readComposerPaint(_ key: HCTerminalKey) async -> Result<HCComposerPaint, HCComposerReadFailure> {
        guard let index = shardIndex(for: key), let shard = byIndex[index] else { return .failure(.unavailable) }
        return await (shard.session as? any HCComposerPaintReading)?.readComposerPaint(key) ?? .failure(.unavailable)
    }

    func end(_ key: HCTerminalKey) async -> HCEndResult {
        guard let index = endShardIndex(for: key, routed: shardIndex(for: key)), let shard = byIndex[index] else {
            return .unresolved(key, .inventoryPending)
        }
        return await shard.session.end(key)
    }

    /// C11H-359 (L2): the shard whose own verified core owns this key, if one does.
    func localOwnerShard(of key: HCTerminalKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return shards.first { cached[$0.index]?.buildIdentity?.coreID == key.owningCoreID }?.index
    }

    /// C11H-359 (L2): a terminal one of this app's own cores owns is ended on
    /// that core's shard and never on another, whatever another shard's
    /// inventory lists under its key. Other keys go where they were routed.
    func endShardIndex(for key: HCTerminalKey, routed: Int?) -> Int? {
        guard let owner = localOwnerShard(of: key) else { return routed }
        if let routed, routed != owner {
            Self.logger.error("hc_end_rerouted core=\(key.owningCoreID, privacy: .public) terminal=\(key.localAddress, privacy: .public) from=\(routed) to=\(owner)")
        }
        return owner
    }

    func diagnostics() async -> HCDiagnostics {
        var pending = 0
        var queued = 0
        var serving: HCBuildIdentity?
        var reason: HCUnavailableReason?
        for shard in shards {
            let diagnostics = await shard.session.diagnostics()
            pending += diagnostics.pendingCreations
            queued += diagnostics.queuedInputBytes
            serving = serving ?? diagnostics.servingBuild
            if shard.index == 0 { reason = diagnostics.unavailableReason }
        }
        return HCDiagnostics(inventory: await snapshot(), expectedPin: shards.first?.configuration.pin ?? .current,
            servingBuild: serving, unavailableReason: serving == nil ? reason : nil,
            pendingCreations: pending, queuedInputBytes: queued)
    }

    /// A1.L2: recovery is per shard, through the panel's route. The pool has
    /// no app-wide recovery, so this refuses and touches no shard.
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.ambiguousIdentity) }
}

/// C11H-238: which terminal a panel's inventory observer cares about. The
/// runtime sets it whenever its identity's key changes; the fan-out reads it
/// off main. Nil: every snapshot of the panel's home shard matters (a keyless
/// panel looking for its terminal, or an observer with no key).
final class HCHomeInterest: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HCTerminalKey?
    private var changed: (@Sendable () -> Void)?

    init(key: HCTerminalKey? = nil) { current = key }

    var key: HCTerminalKey? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            lock.lock()
            guard current != newValue else { lock.unlock(); return }
            current = newValue
            let notify = changed
            lock.unlock()
            notify?()
        }
    }

    fileprivate func onChange(_ body: (@Sendable () -> Void)?) {
        lock.lock(); changed = body; lock.unlock()
    }

    private var reconciler: (@Sendable () -> Void)?

    /// The observer's state came from somewhere other than the inventory (a
    /// reattach published the record it resolved earlier): hand it its home's
    /// newest snapshot again, even unchanged, so the inventory has the last word.
    func reconcile() {
        lock.lock(); let body = reconciler; lock.unlock()
        body?()
    }

    fileprivate func onReconcile(_ body: (@Sendable () -> Void)?) {
        lock.lock(); reconciler = body; lock.unlock()
    }
}

/// C11H-238: hc load the hang monitor reports with a stall (`main.stall`):
/// inventory snapshots per second over the last ten seconds and the number
/// of panels the app holds. Lock-protected, allocation-free reads, any thread.
final class HCLoadMeter: @unchecked Sendable {
    static let shared = HCLoadMeter()
    private let lock = NSLock()
    private var buckets = [UInt32](repeating: 0, count: 10)
    private var bucketSecond = [Int64](repeating: -1, count: 10)
    private var panels = 0

    func recordSnapshot(nowUptime: Double = ProcessInfo.processInfo.systemUptime) {
        let second = Int64(nowUptime)
        let slot = Int(second % 10)
        lock.lock()
        if bucketSecond[slot] != second { bucketSecond[slot] = second; buckets[slot] = 0 }
        buckets[slot] &+= 1
        lock.unlock()
    }

    /// Snapshots in the ten whole seconds up to `nowUptime`.
    func snapshotsLast10s(nowUptime: Double = ProcessInfo.processInfo.systemUptime) -> Int {
        let now = Int64(nowUptime)
        lock.lock(); defer { lock.unlock() }
        var total = 0
        for slot in 0..<10 where bucketSecond[slot] > now - 10 && bucketSecond[slot] <= now { total += Int(buckets[slot]) }
        return total
    }

    func setPanelCount(_ count: Int) { lock.lock(); panels = count; lock.unlock() }
    var panelCount: Int { lock.lock(); defer { lock.unlock() }; return panels }
}

/// C11H-238: one delivery path from the shards to the panels' inventory
/// observers. Every panel used to subscribe to every shard on main and drop
/// the snapshots of shards it does not live in there: one main hop per panel
/// per snapshot (nine shards times seventy panels). Here each shard has one
/// subscription on a private serial queue, where each snapshot is matched to
/// the observers homed on that shard and diffed against what each was last
/// given. Only an observer whose own view changed gets it, all of them in one
/// hop per target queue. Its view is the shard, its connection generation,
/// readiness, machine lines, its panel binding and its own terminal's record
/// (with an interest key), or the revision itself (keyless, or no interest).
///
/// A change to its record's title alone is coalesced to one delivery per
/// `titleInterval`; the newest title always lands, and any other change
/// delivers at once with the newest snapshot. A late observer gets its home's
/// current snapshot. Its home is read when each snapshot is matched and again
/// at delivery, so a moved panel gets its new home's snapshots only.
final class HCHomeFanout: @unchecked Sendable {
    typealias Handler = @Sendable (HCInventorySnapshot) -> Void
    /// The shard a panel's snapshots come from now (nil: none).
    typealias Home = @Sendable (UUID) -> Int?

    struct View: Equatable {
        enum Readiness: Equatable { case ready, pending(HCUnavailableReason) }
        let shard: Int
        let generation: UInt64
        let readiness: Readiness
        let machines: [String: HCMachineAvailability]
        let binding: HCTerminalKey?
        let key: HCTerminalKey?
        let record: HCTerminalRecord?
        /// Set only when every revision matters (keyless or no interest).
        let revision: HCRevision?

        /// True when `other` differs from this view only in its record's title.
        func differsOnlyInTitle(from other: View) -> Bool {
            guard shard == other.shard, generation == other.generation, readiness == other.readiness,
                  machines == other.machines, binding == other.binding, key == other.key,
                  revision == other.revision, let mine = record, let theirs = other.record,
                  mine.title != theirs.title else { return false }
            return mine.withTitle(nil) == theirs.withTitle(nil)
        }
    }

    static let titleInterval: TimeInterval = 0.25

    fileprivate final class Registration: @unchecked Sendable {
        let id = UUID()
        let panelID: UUID
        let handler: Handler
        let interest: HCHomeInterest?
        let watchesKey: Bool
        private let stateLock = NSLock()
        private var active = true
        // Fan-out queue only:
        var target: Target?
        var lastView: View?
        var lastDeliveredUptime: Double = -.infinity
        var trailingScheduled = false
        init(panelID: UUID, interest: HCHomeInterest?, handler: @escaping Handler) {
            self.panelID = panelID; self.interest = interest
            self.watchesKey = interest != nil; self.handler = handler
        }
        var isActive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return active }
        func cancel() { stateLock.lock(); active = false; stateLock.unlock() }
    }

    /// One target queue's waiting deliveries, per observer in order. A newer
    /// delivery replaces the last waiting one only when their continuity
    /// agrees (`View.Continuity`); otherwise both wait. One `async` per burst.
    fileprivate final class Target: @unchecked Sendable {
        let queue: DispatchQueue
        private let lock = NSLock()
        private var pending: [UUID: [Item]] = [:]
        private var order: [UUID] = []
        private var scheduled = false
        /// Waiting deliveries kept per observer at most; past it the oldest
        /// continuity changes are folded (first and newest always stay).
        static let maximumWaiting = 32

        init(queue: DispatchQueue) { self.queue = queue }

        /// Adds a share; true when the queue must be woken.
        func enqueue(_ items: [Item]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            for item in items {
                let id = item.registration.id
                var waiting = pending[id] ?? []
                if waiting.isEmpty { order.append(id) }
                if let last = waiting.last, last.continuity == item.continuity {
                    waiting[waiting.count - 1] = item
                } else {
                    waiting.append(item)
                    if waiting.count > Self.maximumWaiting { waiting.remove(at: 1) }
                }
                pending[id] = waiting
            }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }

        func cancel(_ id: UUID) {
            lock.lock()
            if pending.removeValue(forKey: id) != nil { order.removeAll { $0 == id } }
            lock.unlock()
        }

        func drain(home: Home) {
            lock.lock()
            let batch = order.flatMap { pending[$0] ?? [] }
            pending.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            scheduled = false
            lock.unlock()
            for item in batch {
                // Moved since it was matched: its new home's snapshot follows.
                guard item.registration.isActive, home(item.registration.panelID) == item.shard else { continue }
                item.registration.handler(item.snapshot)
            }
        }
    }

    private let queue = DispatchQueue(label: "c11.hc.home-fanout", qos: .userInitiated)
    private let home: Home
    private let clock: @Sendable () -> Double
    private let meter: HCLoadMeter?
    /// Test seam: when set, trailing title deliveries are handed here instead
    /// of `asyncAfter`, with their due uptime.
    var scheduleForTesting: (@Sendable (_ due: Double, _ body: @escaping @Sendable () -> Void) -> Void)?
    // Fan-out queue only:
    private var registrations: [UUID: Registration] = [:]
    private var latest: [Int: HCInventorySnapshot] = [:]
    private var targets: [ObjectIdentifier: Target] = [:]
    private var subscriptions: [HCObservation] = []
    /// Test-visible: hops scheduled onto target queues.
    private let hopLock = NSLock()
    private var hops = 0

    init(home: @escaping Home, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         meter: HCLoadMeter? = .shared) {
        self.home = home
        self.clock = clock
        self.meter = meter
    }

    /// Subscribe once per shard. Snapshots carry their shard as `source`.
    func attach(_ shards: [(index: Int, id: HCShardID, session: any HCShardSession)]) {
        let subs = shards.map { shard in
            shard.session.observe(on: queue) { [weak self] snapshot in
                self?.receive(shard.index, snapshot.from(shard.id))
            }
        }
        queue.async { self.subscriptions.append(contentsOf: subs) }
    }

    var hopCount: Int { hopLock.lock(); defer { hopLock.unlock() }; return hops }

    /// Feed one shard snapshot (the shard subscriptions call this; tests may too).
    func receive(_ shard: Int, _ snapshot: HCInventorySnapshot) {
        queue.async { self.absorb(shard, snapshot) }
    }

    /// Waits until everything queued so far has been matched (tests).
    func sync() { queue.sync {} }

    /// Never blocks the caller: the registration is matched on the fan-out queue.
    func register(panelID: UUID, on target: DispatchQueue, interest: HCHomeInterest?,
                  handler: @escaping Handler) -> HCObservation {
        let registration = Registration(panelID: panelID, interest: interest, handler: handler)
        let id = registration.id
        queue.async {
            guard registration.isActive else { return }
            let box = self.targets[ObjectIdentifier(target)] ?? Target(queue: target)
            self.targets[ObjectIdentifier(target)] = box
            registration.target = box
            self.registrations[id] = registration
            // A late observer starts from its home's current snapshot.
            self.reevaluate(registration, force: true)
        }
        interest?.onChange { [weak self] in
            self?.queue.async {
                guard let self, let current = self.registrations[id] else { return }
                self.reevaluate(current, force: false)
            }
        }
        interest?.onReconcile { [weak self] in
            self?.queue.async {
                // Only a ready inventory has a record to reconcile with; a
                // pending one was already delivered and says nothing new.
                guard let self, let current = self.registrations[id], let shard = self.home(current.panelID),
                      case .ready = self.latest[shard]?.readiness else { return }
                self.reevaluate(current, force: true)
            }
        }
        return HCObservation { [weak self] in
            interest?.onChange(nil)
            registration.cancel()
            interest?.onReconcile(nil)
            self?.queue.async {
                guard let self, let gone = self.registrations.removeValue(forKey: id), let target = gone.target else { return }
                target.cancel(id)
                // A queue no observer uses any more is let go (each remote
                // status binding brings its own).
                if !self.registrations.values.contains(where: { $0.target === target }) {
                    self.targets.removeValue(forKey: ObjectIdentifier(target.queue))
                }
            }
        }
    }

    /// A panel's placement changed: match it against its new home now.
    func placementChanged(panelID: UUID) {
        queue.async {
            self.flush(self.registrations.values.filter { $0.panelID == panelID }.compactMap {
                self.evaluate($0, force: false)
            })
        }
    }

    private func absorb(_ shard: Int, _ snapshot: HCInventorySnapshot) {
        // A shard's generations and sequences only grow: a late read of an
        // older state is never matched (L4).
        if let previous = latest[shard] {
            let old = previous.revision, new = snapshot.revision
            if new.connectionGeneration < old.connectionGeneration { return }
            if new.connectionGeneration == old.connectionGeneration, new.sequence < old.sequence { return }
        }
        latest[shard] = snapshot
        meter?.recordSnapshot(nowUptime: clock())
        // The whole snapshot is matched before any target is woken, so one
        // snapshot is one hop per target queue however many panels it changes.
        let items = registrations.values.filter { home($0.panelID) == shard }.compactMap { evaluate($0, force: false) }
        flush(items)
    }

    private func view(_ registration: Registration, shard: Int, _ snapshot: HCInventorySnapshot) -> View {
        let readiness: View.Readiness
        switch snapshot.readiness {
        case .ready: readiness = .ready
        case .pending(let reason): readiness = .pending(reason)
        }
        let key = registration.interest?.key
        return View(shard: shard, generation: snapshot.revision.connectionGeneration, readiness: readiness,
                    machines: snapshot.machines, binding: snapshot.panelBindings[registration.panelID], key: key,
                    record: key.flatMap { snapshot.records[$0] },
                    revision: registration.watchesKey && key != nil ? nil : snapshot.revision)
    }

    /// One matched delivery, waiting for its target queue.
    fileprivate struct Item {
        let registration: Registration
        let shard: Int
        let snapshot: HCInventorySnapshot
        let continuity: View.Continuity
    }

    /// Fan-out queue: matches one observer against its home's newest snapshot
    /// and records what it will be given. `force` delivers an unchanged view
    /// too (a new observer, or one asked to reconcile).
    private func evaluate(_ registration: Registration, force: Bool) -> Item? {
        guard registration.isActive, registrations[registration.id] != nil, let shard = home(registration.panelID),
              let snapshot = latest[shard] else { return nil }
        let next = view(registration, shard: shard, snapshot)
        if !force, let last = registration.lastView, last == next { return nil }
        let now = clock()
        if !force, let last = registration.lastView, next.differsOnlyInTitle(from: last) {
            let due = registration.lastDeliveredUptime + Self.titleInterval
            if now < due {
                guard !registration.trailingScheduled else { return nil }
                registration.trailingScheduled = true
                let fire: @Sendable () -> Void = { [weak self, weak registration] in
                    self?.queue.async {
                        guard let self, let registration else { return }
                        registration.trailingScheduled = false
                        self.flush([self.evaluate(registration, force: false)].compactMap { $0 })
                    }
                }
                if let schedule = scheduleForTesting { schedule(due, fire) }
                else { queue.asyncAfter(deadline: .now() + max(0, due - now), execute: fire) }
                return nil
            }
        }
        guard registration.target != nil else { return nil }
        registration.lastView = next
        registration.lastDeliveredUptime = now
        return Item(registration: registration, shard: shard, snapshot: snapshot, continuity: next.continuity)
    }

    private func reevaluate(_ registration: Registration, force: Bool) {
        flush([evaluate(registration, force: force)].compactMap { $0 })
    }

    /// Hands matched deliveries to their target queues: each target takes its
    /// whole share under one lock, and is woken once if it was idle.
    private func flush(_ items: [Item]) {
        guard !items.isEmpty else { return }
        var byTarget: [ObjectIdentifier: (Target, [Item])] = [:]
        for item in items {
            guard let target = item.registration.target else { continue }
            byTarget[ObjectIdentifier(target), default: (target, [])].1.append(item)
        }
        for (_, (target, share)) in byTarget {
            guard target.enqueue(share) else { continue }
            hopLock.lock(); hops += 1; hopLock.unlock()
            let home = home
            target.queue.async { target.drain(home: home) }
        }
    }
}

extension HCHomeFanout.View {
    /// What may never be coalesced away while a delivery waits: its shard and
    /// connection generation, readiness, the machine lines, and its record's
    /// presence, state and machine availability. Two waiting deliveries that
    /// agree on these keep only the newer; any difference keeps both, in
    /// order, so an outage and its recovery both reach the observer even when
    /// its queue was stalled through both.
    struct Continuity: Equatable {
        let shard: Int
        let generation: UInt64
        let readiness: Readiness
        let machines: [String: HCMachineAvailability]
        let present: Bool
        let state: HCTerminalState?
        let availability: HCMachineAvailability?
    }

    var continuity: Continuity {
        Continuity(shard: shard, generation: generation, readiness: readiness, machines: machines,
                   present: record != nil, state: record?.state, availability: record?.machineAvailability)
    }
}

extension HCTerminalRecord {
    /// The same record with another title (the fan-out's title-only test).
    func withTitle(_ title: String?) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, labels: labels, machineName: machineName,
            machineAvailability: machineAvailability, pid: pid, cwd: cwd, foreground: foreground, title: title,
            status: status, statusTimestampMilliseconds: statusTimestampMilliseconds, turn: turn, grid: grid,
            screenExact: screenExact, exitCode: exitCode, exitSignal: exitSignal, endReason: endReason, tty: tty,
            localProcessIdentity: localProcessIdentity, finishedMilliseconds: finishedMilliseconds)
    }
}

/// C11H-238: a session that can deliver only the snapshots one terminal's
/// observer needs (`HCHomeFanout`).
protocol HCInterestObserving {
    func observe(on queue: DispatchQueue, interest: HCHomeInterest,
                 handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation
}

/// C11H-313: a close declines its panel's creations in every shard (only the
/// shard making one holds it), and hears every shard's no-run settlements.
extension HCShardPool: HCCreationSettling {
    func declineCreations(panelID: UUID, carrying creationID: UUID?) {
        for shard in shards {
            (shard.session as? any HCCreationSettling)?.declineCreations(panelID: panelID, carrying: creationID)
        }
    }

    func observeCreationSettlements(on queue: DispatchQueue,
                                    handler: @escaping @Sendable (UUID) -> Void) -> HCObservation {
        let observations = shards.compactMap {
            ($0.session as? any HCCreationSettling)?.observeCreationSettlements(on: queue, handler: handler)
        }
        return HCObservation { for observation in observations { observation.cancel() } }
    }

    /// Asked of the shard the panel resolves in; finding it reads stores only.
    func recordedNeverRun(_ identity: HCPanelIdentity) async -> HCEndEvidence? {
        guard let index = try? await homeIndex(for: identity),
              let settling = byIndex[index]?.session as? any HCCreationSettling else { return nil }
        return await settling.recordedNeverRun(identity)
    }
}

/// A panel's view of the pool: every call goes to the shard its terminal lives
/// in (or, before its first creation, the shard its workspace placed it on).
struct HCShardRoute: HCSession, HCInterestObserving {
    let pool: HCShardPool
    let panelID: UUID

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        pool.observeHome(panelID: panelID, on: queue, handler: handler)
    }

    func observe(on queue: DispatchQueue, interest: HCHomeInterest,
                 handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        pool.observeHome(panelID: panelID, on: queue, interest: interest, handler: handler)
    }

    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { await pool.resolveRouted(identity) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { await pool.createRouted(request) }

    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        guard let shard = await shardFor(key) else { throw HCUnavailableReason.inventoryPending }
        return try await shard.session.attach(key, sink: sink, display: display)
    }

    func readComposerPaint(_ key: HCTerminalKey) async -> Result<HCComposerPaint, HCComposerReadFailure> {
        guard let shard = await shardFor(key) else { return .failure(.unavailable) }
        return await (shard.session as? any HCComposerPaintReading)?.readComposerPaint(key) ?? .failure(.unavailable)
    }

    func end(_ key: HCTerminalKey) async -> HCEndResult {
        let routed = await shardFor(key)
        guard let index = pool.endShardIndex(for: key, routed: routed?.index), let shard = pool.shard(index) else {
            return .unresolved(key, .inventoryPending)
        }
        return await shard.session.end(key)
    }

    func diagnostics() async -> HCDiagnostics {
        guard let shard = await home() else { return await HCUnavailableRuntime().diagnostics() }
        return await shard.session.diagnostics()
    }

    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult {
        // C11H-113: a panel whose shard is unknown has no core of its own to
        // recover (its target's core is another panel's): Retry asks every
        // shard again, and the next resolve finds its owner or needs Retry again.
        if pool.placement.shardIsUnknown(panel: panelID) {
            await pool.probeServingShards()
            return .recovered(HCRevision(connectionGeneration: 0, sequence: 0))
        }
        guard let shard = await home() else { return .refused(.backendNotInstalled) }
        return await shard.session.recoverSession(reason: reason)
    }

    private func home() async -> HCShard? {
        let index = pool.placement.home(forPanel: panelID) ?? pool.placement.target(forPanel: panelID)
        return index.flatMap { pool.shard($0) }
    }

    private func shardFor(_ key: HCTerminalKey) async -> HCShard? {
        if let home = await home() { return home }
        return pool.shardIndex(for: key).flatMap { pool.shard($0) }
    }
}

/// C11H-105: a file sent to a panel's terminal (a remote launch prompt, a file
/// dropped on a remote panel) goes to the shard that holds that terminal.
/// Every hc panel's session is a route since the pool landed (C11H-67), so
/// without this the callers' `as? any HCFileTransfer` found nothing.
extension HCShardRoute: HCFileTransfer {
    func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String {
        guard let shard = await shardFor(key) else { throw HCUnavailableReason.inventoryPending }
        guard let transfer = shard.session as? any HCFileTransfer else { throw HCUnavailableReason.backendNotInstalled }
        return try await transfer.put(key, name: name, data: data)
    }
}

extension HCCreateRequest {
    func retargeted(identity: HCPanelIdentity) -> HCCreateRequest {
        HCCreateRequest(identity: identity, creationID: creationID, argv: argv, cwd: cwd, environment: environment,
                        initialInput: initialInput, machine: machine, shard: shard, labels: labels)
    }
}

/// C11H-103: label calls go to the shard that holds the terminal.
extension HCShardRoute: HCTerminalLabeling {
    func setLabels(_ labels: [String: String], on key: HCTerminalKey) async -> Bool {
        guard let shard = await shardFor(key), let labeling = shard.session as? any HCTerminalLabeling else { return false }
        return await labeling.setLabels(labels, on: key)
    }
}
