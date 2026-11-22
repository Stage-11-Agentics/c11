import Foundation
import OSLog
import os

/// Part 2B provides the inventory factory; part 2C provides attachment/native
/// composition. Keeping both injected lets the lifecycle land independently.
actor HCManagedSession: HCShardSession, HCCreationSettling, HCCarrierReleaseReporting {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.lifecycle")
    typealias PrepareAttachment = @Sendable (HCTerminalKey, UInt64, any HCOutputSink, HCDisplayState) async throws -> HCDisplayState
    typealias InventoryFactory = @Sendable (any HCConnection, HCBuildIdentity) async throws -> any HCInventorySource
    typealias AttachmentFactory = @Sendable (HCTerminalKey, UInt64, any HCChannel, any HCOutputSink, HCDisplayState) async throws -> any HCAttachment

    typealias PrepareRemote = @Sendable (HCManagedSession, String) async throws -> [String: String]
    private let prepareRemote: PrepareRemote?
    /// C11H-176: the link secrets a remote terminal's relay credential comes
    /// from, and the ledger of pickups not yet seen claimed.
    private let relayKeyring: any C11RelayLinkSecrets
    private let relayLedger: C11RelayPickupLedger

    let configuration: HCLaunchConfiguration
    /// The hc session this core serves (a shard's own name).
    nonisolated let sessionName: String
    /// C11H-78: told each time a verified connection is installed, after its
    /// first snapshot. Runs off this actor; never blocks the install.
    private let onInstalled: (@Sendable (HCManagedSession) -> Void)?
    private let connections: any HCConnectionFactory
    private let verifier: any HCPeerVerifying
    private let launcher: any HCCoreLaunching
    private let processes: any HCProcessObserving
    private let intents: HCCreationIntentStore
    private let creationResolutionSeconds: TimeInterval
    private let managedReadSeconds: TimeInterval
    private let prepareAttachment: PrepareAttachment
    private let makeInventory: InventoryFactory
    private let makeAttachment: AttachmentFactory
    private let startLog: HCCoreStartLog
    /// C11H-91: a pool shard while shards are off. It reads, attaches,
    /// reconnects and ends what its core already serves, but never creates a
    /// terminal or restarts its core: those are refused before any RPC.
    let readOnly: Bool
    /// C11H-332: hc's folders for every core this session installs (a fresh
    /// connect or a restore's); the flag allows repair (false for a read-only
    /// shard, which only inspects). False refuses that core: its connection
    /// is closed, never signalled.
    private let checkFolders: @Sendable (HCLaunchConfiguration, Bool) -> Bool
    /// C11H-332: machines whose stored link doesn't check an hc pin and
    /// couldn't be migrated (`HCStoredLinks`): c11 opens nothing on them and
    /// relays nothing from them. Re-reviewed every time; never cached.
    private(set) var unusableMachines: Set<String> = []
    /// C11H-391 (NB6): counts changes to `unusableMachines`. Each publish
    /// carries it, so of two overlapping reviews only the newest one counts,
    /// whichever order their hops arrive in.
    private(set) var unusableGeneration: UInt64 = 0
    /// C11H-359 (M6, L2): machines this core's inventory refused. Nothing
    /// opens on one; Settings lists it with Remove; each reason is audited once.
    private(set) var refusedMachines: [String: HCMachineRefusal] = [:]
    private var refusedRecorded: Set<String> = []
    /// C11H-359 (M3): the machine each running creation targets.
    private var creatingPlacements: [UUID: HCPanelPlacement] = [:]
    /// C11H-359 (M3): a panel's placement as the app created or restored it.
    private let placements: @Sendable (UUID) -> HCPanelPlacement?
    /// C11H-415: c11 app processes that hc would end with a terminal (`HCScopeCarriers.live`).
    private let scopeCarriers: @Sendable () -> [HCScopeCarrier]
    /// C11H-415: ends held for a carrier, so each is logged once.
    private var heldForCarrier: Set<HCTerminalKey> = []
    /// C11H-417: told when a held end goes ahead (or its terminal finished by itself).
    private nonisolated let carrierReleases = HCCarrierReleases()

    nonisolated func observeCarrierReleases(on queue: DispatchQueue,
                                            handler: @escaping @Sendable (HCTerminalKey) -> Void) -> HCObservation {
        carrierReleases.observe(on: queue, handler: handler)
    }
    /// C11H-365 (N13): machines whose link was migrated while hc held a line
    /// to them, each with the hc core process that held it. That line was
    /// dialed through the old, pinless via, so c11 opens no terminal there
    /// (and runs nothing there for `c11 show`) until hc reports the line down
    /// or the machine gone, or a different core process serves this session:
    /// any later dial, and every dial a newer core makes, reads the migrated
    /// via, which checks the pin. Kept on disk in the session's own folder,
    /// so a c11 restart (which leaves hc's core and its lines up) still holds.
    private let redialHolds: C11RelayStateFile<[String: HCProcessIdentity]>
    var redialPendingMachines: Set<String> { redialHolds.read { Set($0.keys) } }
    static func redialHoldsFile(_ configuration: HCLaunchConfiguration) -> C11RelayStateFile<[String: HCProcessIdentity]> {
        C11RelayStateFile(url: configuration.intentDirectory.appendingPathComponent("redial-pending.json"), empty: [:])
    }
    /// Each usable machine's via as last reviewed ("target|size|mtime").
    private var storedLinkStamps: [String: String] = [:]
    /// "machine|code" already audited as unusable, and each machine's last failed migration.
    private var unusableRecorded: Set<String> = []
    /// An unusable link's via-and-folder stamp and time: reviewed again (and
    /// any migration run again) once either changed, else at most every 30 s,
    /// whatever the reason, so no review re-runs the link script every poll.
    private var lastMigrationTry: [String: (stamp: String, at: TimeInterval)] = [:]
    static let migrationRetrySeconds: TimeInterval = 30
    /// Where c11's via files live and the link script that migrates them;
    /// nil turns the review off (a session built without the live backend).
    private let storedLinks: HCStoredLinkReview?
    private nonisolated let feed = HCSessionFeed()
    /// C11H-313: creations a close declined, and no-run settlements announced to the close.
    private nonisolated let creationSettlements = HCCreationSettlements()
    private let observationQueue = DispatchQueue(label: "c11.hc.session-inventory")
    private var inventory: any HCInventorySource = HCUnavailableRuntime()
    private var inventoryObservation: HCObservation?
    private var runtime: HCConnectedRuntime?
    private var lastVerifiedRuntime: HCConnectedRuntime?
    private var requiresExplicitRecovery = false
    private var generation: UInt64 = 0
    private var nextConnectionGeneration: UInt64 = 0
    private var attachmentGeneration: UInt64 = 0
    private var preparingAttachments: [HCTerminalKey: UInt64] = [:]
    private var connecting: Task<HCConnectedRuntime, Error>?
    private var recovering = false
    /// C11H-267: set by `stopForQuit`. From then on this process never starts,
    /// joins or recovers this shard's core again.
    private var stoppedForQuit = false
    private var activeCreations: Set<UUID> = []
    /// C11H-313: each panel's latest creation task; the next one for the panel waits for it.
    private var panelCreations: [UUID: Task<HCCreateResult, Never>] = [:]
    /// C11H-206: how long create lets a catching-up inventory settle before it decides.
    static let preflightSettleSeconds: TimeInterval = 10
    private let preflightSettleNanoseconds: UInt64
    private var uncertainSince: [UUID: UInt64] = [:]
    private var initialInputs: [UUID: HCInitialInput] = [:]
    private var attachments: [HCTerminalKey: any HCAttachment] = [:]
    /// C11H-306, C11H-327: terminals whose last composer read's attach is still unanswered, by connection generation.
    private var unansweredComposerReads: [HCTerminalKey: (generation: UInt64, reply: HCLateReply)] = [:]
    private var resolutionTimers: [UUID: Task<Void, Never>] = [:]
    private var lastReason: HCUnavailableReason = .backendNotInstalled
    /// Which terminal each panel resolved to. The inventory knows terminals,
    /// not panels, so this session publishes the map in every snapshot: process
    /// admission, agent and conversation recovery and the diagnostics recorder
    /// read it. A finished terminal stays bound so its end is still attributed.
    private var panelBindings: [UUID: HCTerminalKey] = [:]
    private var lastSnapshot = HCInventorySnapshot(readiness: .pending(.backendNotInstalled),
                                                   revision: HCRevision(connectionGeneration: 0, sequence: 0))

    init(configuration: HCLaunchConfiguration, connections: any HCConnectionFactory,
         verifier: any HCPeerVerifying, launcher: any HCCoreLaunching,
         processes: any HCProcessObserving = HCKernelProcessObserver(), intents: HCCreationIntentStore,
         creationResolutionSeconds: TimeInterval = HCLimits.creationResolutionSeconds,
         managedReadSeconds: TimeInterval = HCLimits.managedReadSeconds,
         prepareAttachment: @escaping PrepareAttachment,
         makeInventory: @escaping InventoryFactory = { _, _ in HCUnavailableRuntime() },
         makeAttachment: @escaping AttachmentFactory = { _, _, _, _, _ in throw HCUnavailableReason.backendNotInstalled },
         startLog: HCCoreStartLog = .live, readOnly: Bool = false,
         onInstalled: (@Sendable (HCManagedSession) -> Void)? = nil,
         prepareRemote: PrepareRemote? = nil,
         relayKeyring: any C11RelayLinkSecrets = C11RelayKeyring.shared,
         relayLedger: C11RelayPickupLedger? = nil,
         preflightSettleSeconds: TimeInterval = HCManagedSession.preflightSettleSeconds,
         checkFolders: @escaping @Sendable (HCLaunchConfiguration, Bool) -> Bool = { HCLauncher.repairPrivateFolders($0, repair: $1) },
         storedLinks: HCStoredLinkReview? = nil,
         redialHolds: C11RelayStateFile<[String: HCProcessIdentity]>? = nil,
         placements: @escaping @Sendable (UUID) -> HCPanelPlacement? = { HCPanelPlacements.shared.placement(for: $0) },
         scopeCarriers: @escaping @Sendable () -> [HCScopeCarrier] = { HCScopeCarriers.live() }) {
        self.placements = placements
        self.scopeCarriers = scopeCarriers
        self.redialHolds = redialHolds ?? Self.redialHoldsFile(configuration)
        self.checkFolders = checkFolders
        self.storedLinks = storedLinks
        self.preflightSettleNanoseconds = UInt64(max(0, preflightSettleSeconds) * 1_000_000_000)
        self.prepareRemote = prepareRemote
        self.relayKeyring = relayKeyring
        self.relayLedger = relayLedger ?? C11RelayPickupLedger.shared(session: configuration.session)
        self.onInstalled = onInstalled
        self.startLog = startLog
        self.readOnly = readOnly
        self.configuration = configuration
        self.sessionName = configuration.session
        self.connections = connections
        self.verifier = verifier
        self.launcher = launcher
        self.processes = processes
        self.intents = intents
        self.creationResolutionSeconds = creationResolutionSeconds
        self.managedReadSeconds = managedReadSeconds
        self.prepareAttachment = prepareAttachment
        self.makeInventory = makeInventory
        self.makeAttachment = makeAttachment
    }

    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }

    /// Gate/Recovered callers read the current source directly. observe() is
    /// notification-only; its bounded UI delivery never authorizes a gate.
    func snapshot() async -> HCInventorySnapshot { await currentSnapshot() }

    func refresh() async -> HCInventorySnapshot {
        guard let runtime else { return lastSnapshot }
        let expected = runtime.connection.generation
        let source = inventory
        accept(await source.refresh(), generation: expected)
        return lastSnapshot
    }

    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? {
        guard runtime?.connection.generation == connectionGeneration, !recovering else { return nil }
        let result = await inventory.enrichStatusTimestamp(for: key, matchingStatus: status,
            turn: turn, connectionGeneration: connectionGeneration)
        guard runtime?.connection.generation == connectionGeneration, !recovering else { return nil }
        return result
    }

    /// Ticket 12: read every machine's line now (one bounded machine.list on
    /// the session's verified connection) and apply it to the inventory, so
    /// remote terminals turn Reconnecting or live without waiting for an event
    /// hc never sends. Nil when no connection is up; never starts a core.
    @discardableResult
    func pollMachines() async -> [String: HCMachineAvailability]? {
        guard let runtime, !recovering else { return nil }
        let expected = runtime.connection.generation
        guard let value = try? await runtime.connection.request(HCRPCRequest(method: "machine.list", params: .object([:]),
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds))),
              self.runtime?.connection.generation == expected else { return nil }
        await reviewStoredLinks(value, core: runtime.verified.identity.process)
        guard let sink = inventory as? HCMachineRouteSink else { return nil }
        await sink.applyMachines(value)
        await reviewRefusedMachines(inventory)
        accept(await inventory.snapshot(), generation: expected)
        return lastSnapshot.machines
    }

    /// C11H-359 (M6, L2): the machines the inventory refused (an empty or
    /// missing core id, one of this app's own core ids, a doubled name or id)
    /// are audited once per reason, kept from new terminals, and shown in
    /// Settings with Remove. Their terminals never entered the inventory.
    func reviewRefusedMachines(_ source: any HCInventorySource) async {
        let refused = await source.refusedMachines()
        for (name, reason) in refused.sorted(by: { $0.key < $1.key })
        where refusedRecorded.insert("\(name)|\(reason.rawValue)").inserted {
            Self.logger.error("hc_machine_refused session=\(self.sessionName, privacy: .public) machine=\(HCCoreUtility.isLinkMachineName(name) ? name : "invalid", privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            _ = C11AuditLog.shared.append(C11AuditRecord(kind: .link, via: "app", outcome: "refused",
                machine: HCCoreUtility.isLinkMachineName(name) ? name : "invalid", session: sessionName,
                code: reason.rawValue, detail: "c11 won't use this machine; Remove it in Settings"))
        }
        guard refused != refusedMachines else { return }
        refusedMachines = refused
        let session = sessionName
        await MainActor.run { HCMachineDirectory.shared.setRefused(refused, session: session) }
    }

    /// C11H-332: before c11 uses a stored link, a pinless one is migrated (its
    /// via re-rendered with this build's pin) or, where that can't happen,
    /// marked unusable: no creation on it and no relayed call from it, with
    /// the reason audited once. A usable via is re-read only when it changed;
    /// an unusable one is reviewed again every time.
    /// `core` is the hc core process whose machine list this is.
    func reviewStoredLinks(_ machineList: HCJSONValue, core: HCProcessIdentity) async {
        guard let storedLinks else { return }
        // C11H-365 (N13): a held line released once hc reports it down or the
        // machine gone, or once another core process serves the session (a
        // core that started after the migration dialed through the updated link).
        var lineState: [String: String] = [:]
        for entry in machineList["machines"].array ?? [] {
            if let name = entry["name"].string { lineState[name] = entry["state"].string ?? "" }
        }
        let released: [(name: String, detail: String)] = redialHolds.read { holds in
            holds.sorted { $0.key < $1.key }.compactMap { entry -> (name: String, detail: String)? in
                let name = entry.key, holder = entry.value
                if lineState[name] != "connected" {
                    return (name, "the line held through the old link dropped; the next dial uses the updated link")
                }
                return holder == core ? nil : (name, "hc's core restarted since the hold; its lines use the updated link")
            }
        }
        if !released.isEmpty {
            redialHolds.update { holds in for entry in released { holds.removeValue(forKey: entry.name) } }
        }
        for entry in released {
            _ = C11AuditLog.shared.append(C11AuditRecord(kind: .link, via: "app", outcome: "released",
                machine: HCCoreUtility.isLinkMachineName(entry.name) ? entry.name : "invalid", session: sessionName,
                code: "redial_pending", detail: entry.detail))
        }
        var unusable: Set<String> = []
        var stamps: [String: String] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        func stamp(_ target: String?) -> String {
            guard let path = target else { return "none" }
            var info = stat()
            return lstat(path, &info) == 0
                ? "\(path)|\(info.st_size)|\(info.st_mode)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : "\(path)|missing"
        }
        for entry in machineList["machines"].array ?? [] {
            guard let name = entry["name"].string else { continue }
            let target = entry["target"].string
            let before = stamp(target)
            if storedLinkStamps[name] == before { stamps[name] = before; continue }
            // The via and its folder, as they are now.
            func attemptStamp() -> String { stamp(target) + "|" + stamp(target.map { ($0 as NSString).deletingLastPathComponent }) }
            let attempt = attemptStamp()
            if let tried = lastMigrationTry[name], tried.stamp == attempt, now - tried.at < Self.migrationRetrySeconds,
               unusableMachines.contains(name) {
                unusable.insert(name)
                continue
            }
            let verdict = HCStoredLinks.review(machine: name, viaPath: target, home: storedLinks.home,
                                               pinSHA256: configuration.pin.executableSHA256, mayWrite: !readOnly,
                                               linkScript: storedLinks.linkScript, runner: storedLinks.runner)
            if case .migrated = verdict, lineState[name] == "connected",
               redialHolds.update({ holds in holds.updateValue(core, forKey: name) == nil }) {
                _ = C11AuditLog.shared.append(C11AuditRecord(kind: .link, via: "app", outcome: "held",
                    machine: HCCoreUtility.isLinkMachineName(name) ? name : "invalid", session: sessionName, path: target,
                    code: "redial_pending", detail: "c11 opens no terminal here until hc's line, dialed through the old link, redials"))
            }
            switch verdict {
            case .pinned, .migrated:
                stamps[name] = stamp(target)
                lastMigrationTry.removeValue(forKey: name)
                unusableRecorded = unusableRecorded.filter { !$0.hasPrefix(name + "|") }
            case .unusable(let code):
                unusable.insert(name)
                // Stamped after the review: a refused migration's own temporary
                // file changes the folder, and that is not an operator's change.
                lastMigrationTry[name] = (attemptStamp(), now)
                if unusableRecorded.insert("\(name)|\(code)").inserted {
                    // Written now, like a migration: it is recorded once.
                    _ = C11AuditLog.shared.append(C11AuditRecord(kind: .link, via: "app", outcome: "unusable",
                        machine: HCCoreUtility.isLinkMachineName(name) ? name : "invalid", session: sessionName,
                        path: target, code: code,
                        detail: "c11 won't use this link; hc may still redial it until you Update or Remove it"))
                }
            }
        }
        storedLinkStamps = stamps
        guard unusable != unusableMachines else { return }
        unusableMachines = unusable
        unusableGeneration += 1
        await publishUnusable(unusable, generation: unusableGeneration)
    }

    private func publishUnusable(_ unusable: Set<String>, generation: UInt64) async {
        await Self.publishUnusable(unusable, session: sessionName, generation: generation,
                                   relay: C11RelayService.service(for: sessionName))
    }

    /// One stored-link review's unusable set, to both consumers. The relay
    /// and the machine directory each keep only the newest generation: the
    /// session's actor suspends at both hops, so a review that started later
    /// can publish first (C11H-391, NB6). `directory` nil is the app's.
    static func publishUnusable(_ unusable: Set<String>, session: String, generation: UInt64,
                                relay: C11RelayService, directory: HCMachineDirectory? = nil) async {
        await relay.setUnusableMachines(unusable, generation: generation)
        // C11H-274: `--on`, the machine picker and the File menu refuse it up
        // front, so no blank panel is created for a terminal hc never starts.
        await MainActor.run {
            (directory ?? HCMachineDirectory.shared).setUnusable(unusable, session: session, generation: generation)
        }
    }

    /// C11H-391: start this session's core now, or join the one serving
    /// (Add Machine in the links session, or a links session that already
    /// lists machines). False when it can't be started.
    func startServing() async -> Bool {
        (try? await ensureRuntime()) != nil
    }

    /// Ticket 12 (T12.7): is `machine`'s line up right now? One bounded
    /// machine.list to the local core, which is what knows; a change is
    /// applied to the inventory so the panel turns Reconnecting at once.
    /// False when no connection is up or the answer does not come in time.
    func confirmLine(_ machine: String) async -> Bool {
        guard let runtime, !recovering else { return false }
        let expected = runtime.connection.generation
        guard let value = try? await runtime.connection.request(HCRPCRequest(method: "machine.list", params: .object([:]),
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCRemoteLinkChannel.confirmSeconds))),
              self.runtime?.connection.generation == expected, let list = value["machines"].array else { return false }
        let up = list.contains { $0["name"].string == machine && $0["state"].string == "connected" }
        if (lastSnapshot.machines[machine] == .connected) != up, let sink = inventory as? HCMachineRouteSink {
            await sink.applyMachines(value)
            accept(await inventory.snapshot(), generation: expected)
        }
        return up
    }

    /// Ticket 12 (row 23): write a local file's bytes beside a terminal on its
    /// own machine (hc `terminal.put`) and return where it landed there.
    /// Routed by the terminal's key like attach/end; a link that is down is
    /// connectionLost, and nothing is retried.
    func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String {
        guard data.count <= HCRemoteFileDrop.maximumBytes else { throw HCUnavailableReason.bufferOverflow }
        let connected = try await ensureRuntime()
        let snapshot = await currentSnapshot()
        guard case .ready = snapshot.readiness, let record = snapshot.records[key], record.state == .running else {
            throw HCUnavailableReason.inventoryPending
        }
        let address = try addressFor(key, record: record, ownCoreID: connected.verified.identity.coreID)
        let result = try await connected.connection.request(HCRPCRequest(method: "terminal.put",
            params: .object(["terminal": .string(address), "name": .string(name), "data": .string(data.base64EncodedString())]),
            deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCRemoteFileDrop.seconds)))
        guard let path = result["path"].string, !path.isEmpty else { throw HCUnavailableReason.malformedResponse }
        return path
    }

    /// C11H-103 (HCTerminalLabeling): set or remove (empty value) labels on a terminal, routed by its
    /// key like attach and put. Best effort: false when hc can't take them now.
    func setLabels(_ labels: [String: String], on key: HCTerminalKey) async -> Bool {
        guard !labels.isEmpty, let connected = runtime, !recovering else { return false }
        let snapshot = await currentSnapshot()
        guard case .ready = snapshot.readiness, let record = snapshot.records[key], record.state == .running,
              let address = try? addressFor(key, record: record, ownCoreID: connected.verified.identity.coreID) else { return false }
        do {
            _ = try await connected.connection.request(HCRPCRequest(method: "terminal.label",
                params: .object(["terminal": .string(address), "labels": .object(labels.mapValues(HCJSONValue.string))]),
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)))
            return true
        } catch {
            return false
        }
    }

    /// C11H-78: the pairing registrar's calls, on the verified connection.
    /// Only reading the machine list and adding the paired machine.
    static let pairingMethods: Set<String> = ["machine.list", "machine.add"]

    func pairingRequest(_ method: String, params: [String: HCJSONValue]) async throws -> HCJSONValue {
        guard Self.pairingMethods.contains(method) else { throw HCUnavailableReason.invalidLaunchTuple }
        // A read-only shard (C11H-91) never changes its core, so it never pairs.
        guard !readOnly else { throw HCUnavailableReason.foreignSession }
        guard let runtime, !recovering else { throw HCUnavailableReason.connectionLost }
        return try await runtime.connection.request(HCRPCRequest(method: method, params: .object(params),
            deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)))
    }

    /// C11H-16: the relay's hc calls, on the session's verified connection.
    /// Only these methods; never starts a core or reconnects. C11H-228:
    /// `machine.exec` reads a shown file on the caller's machine (a fixed
    /// read-only program, argv only) and `file.write` leaves a point-and-say
    /// screenshot there.
    static let relayMethods: Set<String> = ["doc.get", "doc.set", "file.read", "machine.list", "machine.exec", "file.write"]

    /// The relay methods that run a program or write a file on a machine.
    static func runsOnMachine(_ method: String) -> Bool { method == "machine.exec" || method == "file.write" }

    /// C11H-332, C11H-359 and C11H-365: a machine c11 opens nothing on and runs nothing on.
    func holdsCreations(on machine: String) -> Bool {
        unusableMachines.contains(machine) || refusedMachines[machine] != nil || redialPendingMachines.contains(machine)
    }

    /// C11H-176: c11's own record of a panel's current terminal: the
    /// creation it made for it and where, from the durable intent store (hc's
    /// labels can be set by any process of the user on that machine).
    func relayCurrentCreation(panelID: UUID) async -> C11RelayCreationAnswer {
        do {
            guard let intent = try await intents.read(panelID: panelID), intent.phase != .ended else { return .none }
            return .live(intent.creationID, machine: intent.machine)
        } catch {
            return .unknown
        }
    }

    func relayRequest(_ method: String, params: [String: HCJSONValue], seconds: TimeInterval) async throws -> HCJSONValue {
        guard Self.relayMethods.contains(method) else { throw HCUnavailableReason.invalidLaunchTuple }
        // C11H-228: exec and write carry only what `c11 show` builds.
        guard ShowExecGate.allows(method: method, params: params) else { throw HCUnavailableReason.invalidLaunchTuple }
        // C11H-365 (L10): nothing runs or is written on a machine c11 won't use.
        if Self.runsOnMachine(method), let machine = params["on"]?.string, holdsCreations(on: machine) {
            throw HCUnavailableReason.pinMismatch
        }
        guard let runtime, !recovering else { throw HCUnavailableReason.connectionLost }
        return try await runtime.connection.request(HCRPCRequest(method: method, params: .object(params),
            deadlineUptimeNanoseconds: HCMonotonic.deadline(after: seconds)))
    }

    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        do {
            // C11H-313: a creation recorded as never run is answered from the store alone, before
            // any connect, launch or recovery a resolve would otherwise wait for (a core lost before
            // the claim, a read-only shard whose core is gone).
            let connectedNow = runtime != nil && !recovering && !requiresExplicitRecovery && !stoppedForQuit
            if !connectedNow, identity.creationID != nil,
               let intent = try? await intents.read(panelID: identity.panelID),
               let proof = HCLifecycleResolver.neverRan(identity, intent: intent) { return .ended(proof) }
            _ = try await ensureRuntime()
            let intent = try await intents.read(panelID: identity.panelID)
            let snapshot = await currentSnapshot()
            var adoption: HCAdoptionProof?
            // Post-adoption absence proves only this core's terminals. A creation
            // aimed at another machine is absent while its link is down, too.
            if let intent, intent.machine == nil, let build = snapshot.buildIdentity, build.coreID == intent.coreID,
               build.process != intent.coreProcess, await processes.hasExited(intent.coreProcess),
               case .ready = snapshot.readiness {
                adoption = HCAdoptionProof(retiredProcess: intent.coreProcess, servingProcess: build.process,
                                           revision: snapshot.revision, coreID: build.coreID)
            }
            let result = HCLifecycleResolver.resolve(identity, snapshot: snapshot, intent: intent, adoption: adoption,
                                                     placement: placement(of: identity.panelID))
            switch result {
            case .live(let record):
                noteBinding(panelID: identity.panelID, key: record.key)
                if let intent {
                    try await intents.bind(panelID: identity.panelID, creationID: intent.creationID, key: record.key)
                    if intent.phase != .bound {
                        Self.logger.info("hc_creation_reconciled panel=\(identity.panelID.uuidString, privacy: .public) creation=\(intent.creationID.uuidString, privacy: .public) core=\(record.key.owningCoreID, privacy: .public) terminal=\(record.key.localAddress, privacy: .public)")
                    }
                }
                uncertainSince.removeValue(forKey: identity.panelID)
                resolutionTimers.removeValue(forKey: identity.panelID)?.cancel()
            case .ended(let evidence):
                if let key = evidence.key { noteBinding(panelID: identity.panelID, key: key) }
                if let intent {
                    try await intents.recordEnd(panelID: identity.panelID, creationID: intent.creationID, evidence: evidence)
                    initialInputs.removeValue(forKey: intent.creationID)
                }
                uncertainSince.removeValue(forKey: identity.panelID)
                resolutionTimers.removeValue(forKey: identity.panelID)?.cancel()
            case .unresolved(_, .creationPending) where intent != nil:
                startResolutionDeadline(identity.panelID)
                let since = uncertainSince[identity.panelID] ?? HCMonotonic.now
                if HCMonotonic.now - since >= UInt64(creationResolutionSeconds * 1_000_000_000) {
                    return .unresolved(identity, .creationUncertain)
                }
            default: break
            }
            return result
        } catch { return .unresolved(identity, Self.reason(error)) }
    }

    /// C11H-359 (M3): where this panel's terminal runs, from c11's own records:
    /// the creation running now, else the target the panel was created or
    /// restored with, else this Mac. Never from hc labels. (The resolver
    /// prefers a stored intent's machine over this.)
    private func placement(of panelID: UUID) -> HCPanelPlacement {
        creatingPlacements[panelID] ?? placements(panelID) ?? .local
    }

    /// C11H-359 (M3): `.new` once the inventory is authoritative, else why not.
    /// Nothing in it is matched to the identity.
    private func inventoryAnswer(for identity: HCPanelIdentity) async -> HCLifecycle {
        let snapshot = await currentSnapshot()
        if case .ready(let revision) = snapshot.readiness, revision == snapshot.revision { return .new }
        if case .pending(let reason) = snapshot.readiness { return .unresolved(identity, reason) }
        return .unresolved(identity, .inventoryPending)
    }

    /// C11H-308: a creation runs to its own answer (bound, rejected, or a real
    /// connection failure) even when its caller stops waiting, as when its panel
    /// closes mid-creation. Abandoning a run hc may already be executing left the
    /// creation uncertain and dropped the connection every terminal shares.
    ///
    /// The whole creation is shielded, not only the run. A creation stopped
    /// before the hand-off leaves a rejection no hc event announces, so a close
    /// already waiting on it never wakes, and one stopped in its catch-up leaves
    /// no record at all, which its close reads as a creation still pending
    /// (review of a060c025, items 2 and 3). Run to completion, its create and
    /// finish events wake the close, and the explicit end ends a terminal whose
    /// panel closed meanwhile.
    ///
    /// C11H-313: the shield hides the caller's cancel, not the panel's close.
    /// An explicit end declines the creation (`declineCreation`), and `create`
    /// looks for that wherever it can still decline to start, up to its claim.
    /// Every exit before the claim, declined or not, records the creation as
    /// never run and announces it, so a close waiting on it settles with no hc
    /// event. A creation that claimed runs to its own answer, as before.
    ///
    /// One creation per panel at a time: a second (a reveal's native start
    /// while the hidden start's creation is still preparing) waits for the
    /// first, then runs, binding to the first's terminal if it launched. It
    /// never speaks for the panel while the first can still run, and a close
    /// declines both.
    func create(_ request: HCCreateRequest) async -> HCCreateResult {
        let panel = request.identity.panelID
        creationSettlements.begin(request.creationID, panelID: panel)
        let ahead = panelCreations[panel]
        let task = Task { () -> HCCreateResult in
            if let ahead { _ = await ahead.value }
            return await self.createToCompletion(request)
        }
        panelCreations[panel] = task
        let result = await task.value
        if panelCreations[panel] == task { panelCreations.removeValue(forKey: panel) }
        return result
    }

    private func createToCompletion(_ request: HCCreateRequest) async -> HCCreateResult {
        defer { creationSettlements.end(request.creationID) }
        let (result, claimed) = await runCreation(request)
        // A preflight that found the panel's terminal live binds to it: that is not a creation that never ran.
        if !claimed, case .bound = result { return result }
        Self.auditRemoteLaunch(request, result: result, sent: claimed)
        if !claimed { await writeNeverRun(request) }
        return result
    }

    /// C11H-332: every terminal c11 starts (or fails to start) on another
    /// machine is a line in c11's audit log: the machine, panel, workspace and
    /// program name; never its arguments or environment.
    nonisolated static func auditRemoteLaunch(_ request: HCCreateRequest, result: HCCreateResult, sent: Bool,
                                              audit: C11AuditLog = .shared) {
        guard let machine = request.machine else { return }
        let outcome: String, code: String?
        switch result {
        case .bound: (outcome, code) = ("ok", nil)
        case .rejectedBeforeTransmission(let reason): (outcome, code) = ("refused", reason.rawValue)
        case .unresolved(_, let reason): (outcome, code) = (sent ? "unconfirmed" : "refused", reason.rawValue)
        }
        audit.record(C11AuditRecord(kind: .remoteLaunch, via: "app", outcome: outcome, machine: machine,
                                    panel: request.identity.panelID.uuidString,
                                    workspace: request.labels[HCOwnerLabels.workspace],
                                    program: request.argv.first.map { ($0 as NSString).lastPathComponent }, code: code))
    }

    private func declined(_ request: HCCreateRequest) -> Bool { creationSettlements.isDeclined(request.creationID) }

    private func runCreation(_ request: HCCreateRequest) async -> (HCCreateResult, claimed: Bool) {
        // C11H-313: a creation whose panel already closed never starts.
        if declined(request) { return (.rejectedBeforeTransmission(.cancelled), false) }
        // C11H-332: nothing opens on a machine whose stored link is unusable.
        // C11H-359: nor on one the inventory refused; C11H-365 (N13): nor on
        // one whose held line predates its migration.
        if let machine = request.machine, holdsCreations(on: machine) {
            return (.rejectedBeforeTransmission(.pinMismatch), false)
        }
        // Nothing is sent: new terminals go to S0 while shards are off.
        guard !readOnly else { return (.rejectedBeforeTransmission(.foreignSession), false) }
        guard activeCreations.insert(request.identity.panelID).inserted else {
            return (.unresolved(request.identity, .creationPending), false)
        }
        creatingPlacements[request.identity.panelID] = request.machine.map(HCPanelPlacement.machine) ?? .local
        defer {
            activeCreations.remove(request.identity.panelID)
            creatingPlacements.removeValue(forKey: request.identity.panelID)
        }
        var claimed = false
        var dispatched = false
        var genuinelyNew = false
        do {
            let prior = try await intents.read(panelID: request.identity.panelID)
            genuinelyNew = request.identity.origin == .fresh && request.identity.key == nil
                && request.identity.creationID == nil && prior == nil
            let connected = try await ensureRuntime()
            // C11H-206: an inventory still catching up is not an answer. Settle it (bounded) before deciding, so an
            // unresolved create always means hc was sent the request and its terminal is worth waiting for.
            // C11H-359 (M3): a genuinely new identity has no terminal to find: its catch-up is waited out, but
            // nothing is matched to it by label.
            func lookup() async -> HCLifecycle {
                genuinelyNew ? await inventoryAnswer(for: request.identity) : await resolve(request.identity)
            }
            var preflight = await lookup()
            let settleBy = DispatchTime.now().uptimeNanoseconds &+ preflightSettleNanoseconds
            // A close ends the wait: the creation then declines (C11H-313).
            while case .unresolved(_, let reason) = preflight,
                  reason == .inventoryPending || reason == .deadlineExceeded,
                  DispatchTime.now().uptimeNanoseconds < settleBy, !declined(request) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                preflight = await lookup()
            }
            switch preflight {
            case .live(let record): return (.bound(record), claimed)
            case .new, .ended: break
            case .unresolved(_, let reason):
                if declined(request) { return (.rejectedBeforeTransmission(.cancelled), claimed) }
                return (.unresolved(request.identity, reason), claimed)
            }
            if declined(request) { return (.rejectedBeforeTransmission(.cancelled), claimed) }
            guard runtime?.connection.generation == connected.connection.generation, !recovering else {
                return (.rejectedBeforeTransmission(.connectionLost), claimed)
            }
            // A cold shard must register its remote before terminal.run, and
            // fetch that shard's relay environment before freezing the run env.
            // This is before claim/transmission: failure sends no terminal.run.
            var environment = request.environment
            if let machine = request.machine, let prepareRemote {
                let relay = try await prepareRemote(self, machine)
                environment.merge(relay) { _, prepared in prepared }
            }
            // C11H-176: a relay kit that speaks protocol 2 gets this terminal's
            // credential through a one-time pickup. A failure only leaves the
            // terminal without one; it still opens.
            if let machine = request.machine, !readOnly,
               environment[C11RelayAuth.protocolVariable] == String(C11Relay.protocolVersion),
               let pickup = await C11RelayPickupDelivery.deliver(host: C11RelaySessionHost(session: self),
                                                                  keyring: relayKeyring, ledger: relayLedger,
                                                                  session: sessionName,
                                                                  machine: machine, panel: request.identity.panelID,
                                                                  creation: request.creationID) {
                environment[C11RelayAuth.pickupVariable] = pickup
            }
            guard runtime?.connection.generation == connected.connection.generation, !recovering else {
                return (.rejectedBeforeTransmission(.connectionLost), claimed)
            }
            // The last point it can decline: the panel closed during preparation (C11H-313).
            if declined(request) { return (.rejectedBeforeTransmission(.cancelled), claimed) }
            // C11H-332: checked again right before claim and transmit: the
            // install this creation waited on may have just found the link unusable.
            // C11H-359: the inventory's current judgement of its machines, which a
            // resnapshot since the last poll may have changed (also audited and shown).
            await reviewRefusedMachines(inventory)
            if let machine = request.machine, holdsCreations(on: machine) {
                return (.rejectedBeforeTransmission(.pinMismatch), claimed)
            }
            _ = try await intents.claim(request, coreID: connected.verified.identity.coreID,
                                         process: connected.verified.identity.process)
            claimed = true
            if let initial = request.initialInput { initialInputs[request.creationID] = initial }
            try await intents.markTransmitted(panelID: request.identity.panelID, creationID: request.creationID)
            guard runtime?.connection.generation == connected.connection.generation, !recovering else {
                throw HCRPCFailure(reason: .connectionLost, transmission: .none, remoteCode: nil)
            }
            var params = HCLaunchPolicy.terminalRunParameters(argv: request.argv, environment: environment)
            params.merge([
                "labels": .object(request.labels.mapValues(HCJSONValue.string).merging(
                    ["c11.panel": .string(request.identity.panelID.uuidString), "c11.creation": .string(request.creationID.uuidString),
                     HCOwnerLabels.app: .string(HCOwnerLabels.appInstallID)]
                ) { _, identity in identity }),
                "no_parent": .bool(true), "no_notify": .bool(true), "keep": .bool(false), "wait": .bool(false)
            ]) { _, value in value }
            if let cwd = request.cwd { params["cwd"] = .string(cwd) }
            if let machine = request.machine { params["on"] = .string(machine) }
            dispatched = true
            _ = try await connected.connection.request(HCRPCRequest(method: "terminal.run", params: .object(params),
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.runSeconds)))
            _ = await inventory.refresh()
            switch await resolve(request.identity) {
            case .live(let record): return (.bound(record), claimed)
            case .unresolved(_, let reason): return (.unresolved(request.identity, reason), claimed)
            case .ended, .new: return (.unresolved(request.identity, .creationPending), claimed)
            }
        } catch {
            return (await settleFailedCreation(request, error: error, claimed: claimed, dispatched: dispatched,
                                               genuinelyNew: genuinelyNew), claimed)
        }
    }

    /// C11H-313: the pool stopped this creation before any shard's `create`.
    /// It waits for the panel's creation under way here, if any, then is
    /// recorded like any creation that never reached its claim.
    func recordNeverRun(_ request: HCCreateRequest) async {
        if let ahead = panelCreations[request.identity.panelID] { _ = await ahead.value }
        await writeNeverRun(request)
    }

    /// C11H-313: a creation that left `create` before its claim never ran.
    /// Record it as never run for its creationID and announce that, since no
    /// hc event will. Never while another creation of the panel is under way
    /// here: that one may still run, and the record would speak for the panel.
    /// A store that cannot take it leaves the close pending.
    private func writeNeverRun(_ request: HCCreateRequest) async {
        let core = (runtime ?? lastVerifiedRuntime)?.verified.identity
        let panel = request.identity.panelID.uuidString, creation = request.creationID.uuidString
        guard !activeCreations.contains(request.identity.panelID) else {
            Self.logger.info("hc_creation_never_run_deferred panel=\(panel, privacy: .public) creation=\(creation, privacy: .public)")
            return
        }
        for attempt in 1...5 {
            do {
                // A creation that never reached a core is recorded against none (only adoption reads it,
                // never for an ended intent).
                if try await intents.recordNeverRun(request, coreID: core?.coreID ?? "",
                        process: core?.process ?? HCProcessIdentity(pid: 0, startTimeMicroseconds: 0),
                        revision: lastSnapshot.revision) {
                    initialInputs.removeValue(forKey: request.creationID)
                    Self.logger.info("hc_creation_never_run panel=\(panel, privacy: .public) creation=\(creation, privacy: .public)")
                    creationSettlements.publish(panelID: request.identity.panelID)
                }
                return
            } catch is HCIntentStoreBusy where attempt < 5 {
                // Another app incarnation's short transaction: retry, never absence.
                try? await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                Self.logger.error("hc_creation_no_record panel=\(panel, privacy: .public) creation=\(creation, privacy: .public) reason=\(Self.reason(error).rawValue, privacy: .public)")
                return
            }
        }
    }

    nonisolated func declineCreations(panelID: UUID, carrying creationID: UUID?) {
        creationSettlements.decline(panelID: panelID, carrying: creationID)
    }

    nonisolated func observeCreationSettlements(on queue: DispatchQueue,
                                                handler: @escaping @Sendable (UUID) -> Void) -> HCObservation {
        creationSettlements.observe(on: queue, handler: handler)
    }

    func recordedNeverRun(_ identity: HCPanelIdentity) async -> HCEndEvidence? {
        guard identity.creationID != nil, let intent = try? await intents.read(panelID: identity.panelID) else { return nil }
        return HCLifecycleResolver.neverRan(identity, intent: intent)
    }

    private func settleFailedCreation(_ request: HCCreateRequest, error: Error, claimed: Bool, dispatched: Bool,
                                      genuinelyNew: Bool) async -> HCCreateResult {
        // Once the run is handed to the connection, a failure is the transport's, never the intent store's.
        let reason = dispatched ? HCUnavailableReason.transportReason(error) : Self.reason(error)
        // A bare CancellationError is the transport refusing before anything was enqueued.
        let definite = (error as? HCRPCFailure).map { $0.transmission == .none } ?? (!dispatched || error is CancellationError)
        let rejectedByPeer = (error as? HCRPCFailure)?.transmission == .rejectedByPeer
        if claimed, definite || rejectedByPeer {
            initialInputs.removeValue(forKey: request.creationID)
            let evidence = HCEndEvidence(id: UUID(), creationID: request.creationID, revision: lastSnapshot.revision, kind: .createRejected)
            if (try? await intents.recordEnd(panelID: request.identity.panelID, creationID: request.creationID, evidence: evidence)) != nil {
                // No hc event announces a rejection (C11H-313).
                creationSettlements.publish(panelID: request.identity.panelID)
            }
        } else if claimed {
            try? await intents.markUncertain(panelID: request.identity.panelID, creationID: request.creationID)
            startResolutionDeadline(request.identity.panelID)
            Self.logger.error("hc_creation_unresolved panel=\(request.identity.panelID.uuidString, privacy: .public) creation=\(request.creationID.uuidString, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            // Only the connection's own failure drops the connection every terminal shares. A
            // cancellation is not one; a connection that did close reports it through its inventory.
            if reason != .cancelled { invalidate(reason) }
        }
        // A failed lookup of a restored or durable pending identity stays
        // unresolved; its zero transmitted bytes cannot imply fallback.
        if !genuinelyNew && !dispatched { return .unresolved(request.identity, reason) }
        return definite ? .rejectedBeforeTransmission(reason) : .unresolved(request.identity, reason)
    }

    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        let connected = try await ensureRuntime()
        let snapshot = await currentSnapshot()
        guard case .ready = snapshot.readiness, let record = snapshot.records[key], record.state == .running else {
            throw HCUnavailableReason.inventoryPending
        }
        let address = try addressFor(key, record: record, ownCoreID: connected.verified.identity.coreID)
        attachmentGeneration += 1
        let attachGeneration = attachmentGeneration
        preparingAttachments[key] = attachGeneration
        attachments.removeValue(forKey: key)?.detach()
        var completed = false
        var prepared: (any HCAttachment)?
        var registeredChannel: (any HCChannel)?
        defer {
            if preparingAttachments[key] == attachGeneration { preparingAttachments.removeValue(forKey: key) }
            if !completed { registeredChannel?.close(); prepared?.detach(); sink.retire {} }
        }
        let proposed = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: attachGeneration,
            displayGeneration: display.revision.displayGeneration), grid: display.grid, facts: display.facts, focused: display.focused)
        // Composition must bind native generation before displayStateForAttach,
        // and before the RPC can produce early paint on an unregistered channel.
        let attachedDisplay = try await prepareAttachment(key, attachGeneration, sink, proposed)
        guard attachedDisplay.revision.attachmentGeneration == attachGeneration,
              preparingAttachments[key] == attachGeneration,
              runtime?.connection.generation == connected.connection.generation, !recovering else {
            throw HCUnavailableReason.connectionLost
        }
        let params = Self.attachParameters(address: address, display: attachedDisplay)
        let result = try await connected.connection.request(HCRPCRequest(method: "terminal.attach", params: params,
            deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)))
        guard case .object(let fields) = result, case .integer(let channelID) = fields["channel"],
              let channel = UInt32(exactly: channelID) else { throw HCUnavailableReason.malformedResponse }
        let transport = try await connected.connection.registerChannel(channel, attachmentGeneration: attachGeneration, sink: sink)
        registeredChannel = transport
        guard runtime?.connection.generation == connected.connection.generation, !recovering,
              preparingAttachments[key] == attachGeneration else {
            transport.close()
            throw HCUnavailableReason.connectionLost
        }
        // Ticket 12: a terminal on another machine writes through a channel
        // that confirms that machine's line before each DATA write.
        let ownCoreID = connected.verified.identity.coreID
        let writer: any HCChannel
        if key.owningCoreID != ownCoreID, let machine = record.machineName {
            writer = HCRemoteLinkChannel(base: transport) { [weak self] in await self?.confirmLine(machine) ?? false }
        } else {
            writer = transport
        }
        let attachment: any HCAttachment
        do { attachment = try await makeAttachment(key, attachGeneration, writer, sink, attachedDisplay) }
        catch { transport.close(); throw error }
        prepared = attachment
        guard runtime?.connection.generation == connected.connection.generation, !recovering,
              preparingAttachments[key] == attachGeneration else { throw HCUnavailableReason.connectionLost }
        // Early paint may synchronously produce native query replies. The input
        // port must already be bound when this begins delivering output.
        try await transport.activate()
        // Binding is by active intent, never by an arbitrary shared panel label.
        if let panelText = record.labels["c11.panel"], let panel = UUID(uuidString: panelText),
           let intent = try await intents.read(panelID: panel), intent.key == key,
           record.labels["c11.creation"]?.lowercased() == intent.creationID.uuidString.lowercased() {
            if let initial = initialInputs.removeValue(forKey: intent.creationID),
               try await intents.claimInitialInput(panelID: panel, creationID: intent.creationID) {
                let input = HCInputRequest(operationID: initial.operationID, panelID: panel, key: key,
                    attachmentGeneration: attachGeneration, source: .initial, payload: initial.payload, submitReturn: initial.submitReturn)
                let outcome = await attachment.submit(input)
                try await intents.finishInitialInput(panelID: panel, creationID: intent.creationID, outcome: outcome)
            }
        }
        guard runtime?.connection.generation == connected.connection.generation, !recovering,
              preparingAttachments[key] == attachGeneration else { throw HCUnavailableReason.connectionLost }
        attachments[key] = attachment
        completed = true
        return attachment
    }

    /// C11H-306: observe-attach to the terminal, take its first paint, close (`HCComposerPaintRead`). Uses only
    /// the connection already verified: it never connects, launches or recovers a core, and it never touches the
    /// panel's own attachment, its input or its size.
    /// A read whose attach went unanswered (timed out or cancelled) leaves that attach in the engine's budget of
    /// unanswered channel calls until hc's late reply comes (C11H-327). No second read of the same terminal attaches
    /// behind it for as long as the engine counts it: until that late reply, or until the connection and its whole
    /// budget are gone. There is no time limit, so a core that never answers holds one unanswered attach per
    /// terminal, never one more each minute.
    func readComposerPaint(_ key: HCTerminalKey) async -> Result<HCComposerPaint, HCComposerReadFailure> {
        guard let connected = runtime, !recovering, !stoppedForQuit else { return .failure(.unreachable) }
        let generation = connected.connection.generation
        if let mark = unansweredComposerReads[key] {
            if mark.generation == generation, mark.reply.outstanding { return .failure(.attachUnanswered) }
            unansweredComposerReads.removeValue(forKey: key)
        }
        let snapshot = await currentSnapshot()
        guard case .ready = snapshot.readiness, let record = snapshot.records[key], record.state == .running,
              let address = try? addressFor(key, record: record, ownCoreID: connected.verified.identity.coreID) else {
            return .failure(.unavailable)
        }
        let reply = HCLateReply()
        let result = await HCComposerPaintRead.read(connection: connected.connection, address: address,
                                                    grid: record.grid ?? HCHeadless.grid, lateReply: reply)
        switch result {
        case .failure(.timedOut), .failure(.cancelled):
            // The engine may still count this attach. The next read asks the mark, so the hold never depends on
            // when the engine marked it relative to this read's return.
            unansweredComposerReads = unansweredComposerReads.filter { $0.value.generation == generation }
            unansweredComposerReads[key] = (generation, reply)
        default:
            break
        }
        return result
    }

    private static func attachParameters(address: String, display: HCDisplayState) -> HCJSONValue {
        var params: [String: HCJSONValue] = ["terminal": .string(address), "cols": .integer(Int64(display.grid.columns)),
            "rows": .integer(Int64(display.grid.rows)), "history": .integer(2000)]
        var facts: [String: HCJSONValue] = [:]
        for (name, color) in [("fg", display.facts.foreground), ("bg", display.facts.background), ("cursor", display.facts.cursor)] {
            if let color { facts[name] = .string(String(format: "#%02x%02x%02x", color.red, color.green, color.blue)) }
        }
        if let width = display.facts.cellWidth, let height = display.facts.cellHeight {
            facts["cell"] = .array([.integer(Int64(width)), .integer(Int64(height))])
        }
        if !facts.isEmpty { params["display"] = .object(facts) }
        return .object(params)
    }

    func end(_ key: HCTerminalKey) async -> HCEndResult {
        do {
            let connected = try await ensureRuntime()
            let snapshot = await currentSnapshot()
            guard case .ready = snapshot.readiness, let record = snapshot.records[key] else { return .unresolved(key, .inventoryPending) }
            if record.state == .finished {
                if heldForCarrier.remove(key) != nil { carrierReleases.publish(key) }
                // C11H-308: which creation ended, so a close can tell it from a replacement.
                let creation = record.labels["c11.creation"].flatMap(UUID.init(uuidString:))
                return .confirmed(HCEndEvidence(id: UUID(), key: key, creationID: creation, revision: snapshot.revision, kind: .finished,
                                               hcReason: record.endReason, exitCode: record.exitCode, exitSignal: record.exitSignal,
                                               endedAtMilliseconds: record.finishedMilliseconds))
            }
            let address = try addressFor(key, record: record, ownCoreID: connected.verified.identity.coreID)
            // C11H-415: hc ends everything carrying the terminal's `HC_SCOPE`
            // token, and a c11 app opened from that terminal carries it. Never
            // end c11 with a panel: the end waits, retried on each ready
            // revision and kept across restarts, until no c11 app carries it.
            if key.owningCoreID == connected.verified.identity.coreID, let carrier = carrierEnded(by: key) {
                if heldForCarrier.insert(key).inserted {
                    Self.logger.notice("hc.end.held reason=app_carries_scope terminal=\(key.localAddress, privacy: .public) session=\(self.sessionName, privacy: .public) app_pid=\(carrier.pid) bundle=\(carrier.bundleID, privacy: .public)")
                }
                return .unresolved(key, .appCarriesScope)
            }
            if heldForCarrier.remove(key) != nil {
                Self.logger.notice("hc.end.released terminal=\(key.localAddress, privacy: .public) session=\(self.sessionName, privacy: .public)")
                carrierReleases.publish(key)
            }
            _ = try await connected.connection.request(HCRPCRequest(method: "terminal.kill", params: .object(["terminal": .string(address)]),
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)))
            attachments.removeValue(forKey: key)?.detach()
            if let creationText = record.labels["c11.creation"], let creation = UUID(uuidString: creationText) {
                initialInputs.removeValue(forKey: creation)
            }
            // Acceptance is not death: the inventory must confirm the transition.
            _ = await inventory.refresh()
            return .pending(key)
        } catch { return .unresolved(key, Self.reason(error)) }
    }

    /// C11H-415: the c11 app process ending this local terminal would end,
    /// nil when none. The terminal's recorded token is read only when some c11
    /// app carries a token at all.
    private func carrierEnded(by key: HCTerminalKey) -> HCScopeCarrier? {
        let carriers = scopeCarriers()
        guard !carriers.isEmpty else { return nil }
        let scope = HCScopeCarriers.recordedScope(address: key.localAddress, stateDirectory: configuration.stateDirectory)
        return carriers.first { $0.isEnded(byTerminal: key.localAddress, socket: configuration.socketURL.path, scope: scope) }
    }

    func diagnostics() async -> HCDiagnostics {
        let stored = (try? await intents.all()) ?? []
        return HCDiagnostics(inventory: await currentSnapshot(), expectedPin: configuration.pin,
            servingBuild: runtime?.verified.identity, unavailableReason: runtime == nil ? lastReason : nil,
            pendingCreations: stored.filter { [.prepared, .transmitted, .uncertain].contains($0.phase) }.count)
    }

    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult {
        if stoppedForQuit { return .refused(.coreUnreachable) }
        // A restart would stop a core this app may not start again; an input
        // fault only reconnects to the serving core, so it stays allowed.
        if readOnly, reason != .inputFault { return .refused(.foreignSession) }
        guard !recovering else { return .recoveryRequired(.recoveryRequired) }
        recovering = true
        let recoveryDeadline = HCMonotonic.deadline(after: HCLimits.recoverySeconds)
        defer { recovering = false }
        do {
            let previous: HCConnectedRuntime
            if let runtime { previous = runtime }
            else {
                // No verified old connection: connect first, never launch or signal
                // an unknown endpoint as a side effect of the recovery button.
                do { previous = try await connectExisting(deadline: recoveryDeadline) }
                catch {
                    guard Self.reason(error) == .coreUnreachable, let known = lastVerifiedRuntime,
                          await processes.hasExited(known.verified.identity.process) else { throw error }
                    previous = known
                }
            }
            if reason == .inputFault {
                invalidate(.inputFault)
                let next = try await connectExisting(deadline: recoveryDeadline)
                guard next.verified.isPinnedBuild else { throw HCUnavailableReason.foreignBuild }
                try await install(next, deadline: recoveryDeadline)
                requiresExplicitRecovery = false
                guard case .ready(let revision) = lastSnapshot.readiness else { throw HCUnavailableReason.inventoryPending }
                return .recovered(revision)
            }
            invalidate(.connectionLost, closeConnection: false)
            _ = allocateConnectionGeneration()
            let coordinator = HCRecoveryCoordinator(configuration: configuration, factory: connections,
                verifier: verifier, launcher: launcher, processes: processes)
            let next = try await coordinator.recover(previous, generation: generation, deadlineUptimeNanoseconds: recoveryDeadline)
            try await install(next, deadline: recoveryDeadline)
            let snapshot = await currentSnapshot()
            guard case .ready(let revision) = snapshot.readiness else { throw HCUnavailableReason.recoveryRequired }
            requiresExplicitRecovery = false
            return .recovered(revision)
        } catch {
            requiresExplicitRecovery = true
            invalidate(.recoveryRequired)
            return .recoveryRequired(Self.reason(error))
        }
    }

    /// The shim's RPC adapter deliberately does not call ensureRuntime: no
    /// ordinary managed command may autostart when the serving core is missing.
    func managedCommand(_ command: HCManagedCommand) async throws -> HCJSONValue {
        if command.verb.isReadOnly {
            let deadline = HCMonotonic.deadline(after: managedReadSeconds)
            return try await HCBoundedOperation.run(deadline: deadline) {
                try await self.performManagedCommand(command, readDeadline: deadline)
            }
        }
        return try await performManagedCommand(command, readDeadline: nil)
    }

    private func performManagedCommand(_ command: HCManagedCommand, readDeadline: UInt64?) async throws -> HCJSONValue {
        guard command.session == configuration.session, command.socket == configuration.socketURL.path else {
            throw HCUnavailableReason.foreignSession
        }
        if readOnly, command.verb == .run || command.verb == .restart {
            // `hc run` and `hc server restart` from a terminal on a read-only shard.
            throw HCUnavailableReason.foreignSession
        }
        if command.verb == .restart {
            let result = await recoverSession(reason: .foreignBuild)
            guard case .recovered = result else { throw HCUnavailableReason.recoveryRequired }
            return .object(["restarted": .bool(true)])
        }
        guard !recovering, !requiresExplicitRecovery else { throw HCUnavailableReason.recoveryRequired }
        let connected: HCConnectedRuntime
        if let runtime { connected = runtime }
        else { connected = try await connectExisting(installable: false, deadline: readDeadline,
                                                     connectSeconds: readDeadline == nil ? HCLimits.connectSeconds : managedReadSeconds) }
        guard connected.verified.isPinnedBuild else { connected.connection.close(reason: .foreignBuild); throw HCUnavailableReason.foreignBuild }
        // A command-only connection is closed after use; it does not replace the
        // application's inventory/attachment connection or its generation.
        let temporary = runtime == nil
        defer { if temporary { connected.connection.close(reason: .connectionLost) } }
        let method: String
        var params: [String: HCJSONValue] = [:]
        switch command.verb {
        case .status: method = "server.status"
        case .list: method = "terminal.list"
        case .machineList: method = "machine.list"
        case .get:
            guard let terminal = command.terminal, !terminal.isEmpty else { throw HCUnavailableReason.staleIdentity }
            method = "terminal.get"; params["terminal"] = .string(terminal)
        case .run:
            guard !command.argv.isEmpty else { throw HCUnavailableReason.malformedResponse }
            method = "terminal.run"
            params = HCLaunchPolicy.terminalRunParameters(argv: command.argv, environment: command.environment)
            params.merge(["labels": .object(command.labels.mapValues(HCJSONValue.string)),
                          "no_parent": .bool(true), "no_notify": .bool(true), "keep": .bool(false), "wait": .bool(false)]) { _, value in value }
            if let cwd = command.cwd { params["cwd"] = .string(cwd) }
        case .restart: throw HCUnavailableReason.recoveryRequired
        }
        do {
            let value = try await connected.connection.request(HCRPCRequest(method: method, params: .object(params),
                deadlineUptimeNanoseconds: readDeadline ?? HCMonotonic.deadline(after: command.verb == .run ? HCLimits.runSeconds : HCLimits.connectSeconds)))
            return command.verb == .list ? try HCManagedListResult.annotate(value) : value
        } catch let failure as HCRPCFailure { throw failure }
        catch {
            // Once handed to the wire, an unclassified failure cannot claim
            // zero transmission. The CLI must not suggest a safe repeat run.
            throw HCRPCFailure(reason: HCUnavailableReason.transportReason(error),
                transmission: .possible, remoteCode: nil)
        }
    }

    /// C11H-67: after restore, join a core that is already serving this
    /// session so its terminals are in the inventory. Never launches a core,
    /// never recovers a foreign build, and publishes nothing when there is
    /// no core: an unused shard stays unused.
    func connectIfServing() async -> Bool {
        if stoppedForQuit { return false }
        if runtime != nil { return true }
        guard !recovering, !requiresExplicitRecovery, connecting == nil,
              FileManager.default.fileExists(atPath: configuration.socketURL.path) else { return false }
        do {
            let next = try await connectExisting()
            guard next.verified.isPinnedBuild, runtime == nil, connecting == nil, !recovering else {
                next.connection.close(reason: next.verified.isPinnedBuild ? .connectionLost : .foreignBuild)
                return runtime != nil
            }
            try await install(next)
            return true
        } catch { return runtime != nil }
    }

    /// C11H-267: Keep Terminals After Quit is off and the operator quit. Stops
    /// this shard's own core with `server.stop`, which ends every terminal it
    /// holds (hc reports `server_stop`, a host end: the next launch resumes
    /// each conversation once, as after a reboot). Never starts or recovers a
    /// core; a core of another build is left alone. Bounded by `deadline`.
    func stopForQuit(deadlineUptimeNanoseconds deadline: UInt64) async -> HCQuitStopOutcome {
        stoppedForQuit = true
        connecting?.cancel()
        let connected: HCConnectedRuntime
        if let runtime { connected = runtime }
        else {
            guard FileManager.default.fileExists(atPath: configuration.socketURL.path) else { return .notRunning }
            do { connected = try await connectExisting(installable: false, deadline: deadline) }
            catch { return .notRunning }
        }
        let temporary = runtime == nil
        guard connected.verified.isPinnedBuild else {
            if temporary { connected.connection.close(reason: .foreignBuild) }
            return .foreignBuild
        }
        let process = connected.verified.identity.process
        do {
            _ = try await connected.connection.request(HCRPCRequest(method: "server.stop", params: .object([:]),
                                                                    deadlineUptimeNanoseconds: deadline))
        } catch let failure as HCRPCFailure where failure.transmission == .none {
            if temporary { connected.connection.close(reason: .connectionLost) }
            return .failed
        } catch {
            // The reply may vanish as the core exits; the exit settles it.
        }
        if temporary { connected.connection.close(reason: .connectionLost) } else { invalidate(.coreUnreachable) }
        while !(await processes.hasExited(process)) {
            guard HCMonotonic.now < deadline else { return .timedOut }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return .stopped
    }

    private func ensureRuntime() async throws -> HCConnectedRuntime {
        guard !stoppedForQuit else { throw HCUnavailableReason.coreUnreachable }
        guard !recovering, !requiresExplicitRecovery else { throw HCUnavailableReason.recoveryRequired }
        if let runtime { return runtime }
        if let connecting { return try await connecting.value }
        _ = allocateConnectionGeneration()
        let expected = generation
        let task = Task { try await self.connectAndInstall(generation: expected) }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    private func connectAndInstall(generation expected: UInt64) async throws -> HCConnectedRuntime {
        do {
            let verify: HCServingBuildVerifier = { [verifier, configuration] peer in
                try await verifier.verify(peer, configuration: configuration)
            }
            let connection: any HCConnection
            do {
                connection = try await connections.connect(HCConnectionRequest(configuration: configuration, generation: expected,
                    deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)), verify: verify)
            } catch HCUnavailableReason.coreUnreachable {
                startLog.failed(.connect, HCUnavailableReason.coreUnreachable,
                                detail: "no core at \(configuration.socketURL.path); starting one")
                _ = try await launcher.start(configuration, deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.runSeconds))
                connection = try await connections.connect(HCConnectionRequest(configuration: configuration, generation: expected,
                    deadlineUptimeNanoseconds: HCMonotonic.deadline(after: HCLimits.connectSeconds)), verify: verify)
            }
            guard generation == expected, !recovering else { connection.close(reason: .connectionLost); throw HCUnavailableReason.connectionLost }
            var next = HCConnectedRuntime(connection: connection, verified: connection.verification)
            var installDeadline: UInt64?
            lastVerifiedRuntime = next
            if !next.verified.isPinnedBuild, readOnly {
                // A foreign build on a read-only shard is left running, untouched.
                connection.close(reason: .foreignBuild)
                throw HCUnavailableReason.foreignBuild
            }
            if !next.verified.isPinnedBuild {
                // C11H-332: no recovery RPC (`server.restart`) reaches a core
                // whose folders fail the policy; install checks again after.
                guard checkFolders(configuration, !readOnly) else {
                    startLog.failed(.launchDirectories, HCUnavailableReason.invalidLaunchTuple,
                                    detail: "an hc folder is a symlink, not private or not this user's; no recovery")
                    connection.close(reason: .invalidLaunchTuple)
                    throw HCUnavailableReason.invalidLaunchTuple
                }
                requiresExplicitRecovery = true
                recovering = true
                defer { recovering = false }
                invalidate(.foreignBuild, closeConnection: false, cancelConnecting: false)
                let coordinator = HCRecoveryCoordinator(configuration: configuration, factory: connections,
                    verifier: verifier, launcher: launcher, processes: processes)
                let deadline = HCMonotonic.deadline(after: HCLimits.recoverySeconds)
                installDeadline = deadline
                next = try await coordinator.recover(next, generation: generation, deadlineUptimeNanoseconds: deadline)
            }
            try await install(next, deadline: installDeadline)
            requiresExplicitRecovery = false
            return next
        } catch {
            lastReason = Self.reason(error)
            startLog.failed(.connect, error, detail: "session \(configuration.session): the terminal stays unavailable")
            if requiresExplicitRecovery { invalidate(.recoveryRequired) }
            else { publishPending(lastReason) }
            throw error
        }
    }

    private func connectExisting(installable: Bool = true, deadline: UInt64? = nil,
                                 connectSeconds: TimeInterval = HCLimits.connectSeconds) async throws -> HCConnectedRuntime {
        let connectionGeneration = allocateConnectionGeneration(installable: installable)
        let connection = try await connections.connect(HCConnectionRequest(configuration: configuration, generation: connectionGeneration,
            deadlineUptimeNanoseconds: min(deadline ?? UInt64.max, HCMonotonic.deadline(after: connectSeconds))), verify: { [verifier, configuration] peer in
                try await verifier.verify(peer, configuration: configuration)
            })
        return HCConnectedRuntime(connection: connection, verified: connection.verification)
    }

    private func allocateConnectionGeneration(installable: Bool = true) -> UInt64 {
        nextConnectionGeneration += 1
        if installable { generation = nextConnectionGeneration }
        return nextConnectionGeneration
    }

    private func install(_ next: HCConnectedRuntime, deadline: UInt64? = nil) async throws {
        var completed = false
        defer {
            if !completed {
                next.connection.close(reason: .inventoryPending)
                if runtime?.connection.generation == next.connection.generation { invalidate(.inventoryPending) }
            }
        }
        guard generation == next.connection.generation else { next.connection.close(reason: .connectionLost); throw HCUnavailableReason.connectionLost }
        // C11H-332: every core this session installs, whether it connected
        // fresh or a restore found it serving, passes the folder policy. A
        // read-only shard only inspects.
        guard checkFolders(configuration, !readOnly) else {
            startLog.failed(.launchDirectories, HCUnavailableReason.invalidLaunchTuple,
                            detail: "an hc folder is a symlink, not private or not this user's; core refused")
            throw HCUnavailableReason.invalidLaunchTuple
        }
        let source: any HCInventorySource
        if let deadline {
            source = try await HCBoundedOperation.run(deadline: deadline) { [makeInventory] in
                try await makeInventory(next.connection, next.verified.identity)
            }
        } else { source = try await makeInventory(next.connection, next.verified.identity) }
        guard generation == next.connection.generation else { next.connection.close(reason: .connectionLost); throw HCUnavailableReason.connectionLost }
        inventoryObservation?.cancel()
        let expected = next.connection.generation
        inventoryObservation = source.observe(on: observationQueue) { [weak self] snapshot in
            Task { await self?.accept(snapshot, generation: expected) }
        }
        if let deadline { _ = try await HCBoundedOperation.run(deadline: deadline) { await source.refresh() } }
        else { _ = await source.refresh() }
        // C11H-332: the stored links are reviewed, and their refusals handed to
        // the relay, before this core's runtime or its ready snapshot is
        // published, from the machine list the inventory just fetched (no
        // extra call). Nothing can use the core before then.
        if let machines = await source.lastMachineList() { await reviewStoredLinks(machines, core: next.verified.identity.process) }
        await reviewRefusedMachines(source)
        guard generation == next.connection.generation else { next.connection.close(reason: .connectionLost); throw HCUnavailableReason.connectionLost }
        runtime = next
        lastVerifiedRuntime = next
        inventory = source
        // The source's newest snapshot: it includes anything that changed during the review.
        accept(await source.snapshot(), generation: expected)
        completed = true
        if let onInstalled { Task.detached(priority: .utility) { onInstalled(self) } }
    }

    private func currentSnapshot() async -> HCInventorySnapshot {
        if let runtime { accept(await inventory.snapshot(), generation: runtime.connection.generation) }
        return lastSnapshot
    }

    private func accept(_ snapshot: HCInventorySnapshot, generation: UInt64) {
        guard let runtime, runtime.connection.generation == generation,
              snapshot.revision.connectionGeneration == generation else { return }
        if lastSnapshot.revision.connectionGeneration == generation,
           snapshot.revision.sequence < lastSnapshot.revision.sequence { return }
        if case .pending(let reason) = snapshot.readiness, [.connectionLost, .foreignBuild, .pinMismatch].contains(reason) {
            invalidate(reason)
            return
        }
        lastSnapshot = HCInventorySnapshot(readiness: snapshot.readiness, revision: snapshot.revision, records: snapshot.records,
            buildIdentity: runtime.verified.identity, panelBindings: snapshot.panelBindings.merging(panelBindings) { _, mine in mine },
            machines: snapshot.machines)
        feed.publish(lastSnapshot)
    }

    /// A new or changed binding is published at once; the next inventory event
    /// may be far off, and a consumer must not wait for it to learn a panel's key.
    private func noteBinding(panelID: UUID, key: HCTerminalKey) {
        guard panelBindings[panelID] != key else { return }
        panelBindings[panelID] = key
        lastSnapshot = HCInventorySnapshot(readiness: lastSnapshot.readiness, revision: lastSnapshot.revision,
            records: lastSnapshot.records, buildIdentity: lastSnapshot.buildIdentity,
            panelBindings: lastSnapshot.panelBindings.merging(panelBindings) { _, mine in mine },
            machines: lastSnapshot.machines)
        feed.publish(lastSnapshot)
    }

    private func invalidate(_ reason: HCUnavailableReason, closeConnection: Bool = true, cancelConnecting: Bool = true) {
        _ = allocateConnectionGeneration()
        if cancelConnecting { connecting?.cancel() }
        if closeConnection { runtime?.connection.close(reason: reason) }
        runtime = nil
        inventoryObservation?.cancel()
        inventoryObservation = nil
        inventory = HCUnavailableRuntime()
        for attachment in attachments.values {
            attachment.input.invalidate(generation: attachment.generation, reason: .unavailable)
            attachment.detach()
        }
        attachments.removeAll()
        preparingAttachments.removeAll()
        lastReason = reason
        publishPending(reason)
    }

    private func publishPending(_ reason: HCUnavailableReason) {
        lastSnapshot = HCInventorySnapshot(readiness: .pending(reason),
            revision: HCRevision(connectionGeneration: generation, sequence: 0), records: lastSnapshot.records,
            buildIdentity: lastSnapshot.buildIdentity, panelBindings: lastSnapshot.panelBindings.merging(panelBindings) { _, mine in mine },
            machines: lastSnapshot.machines)
        feed.publish(lastSnapshot)
    }

    private func startResolutionDeadline(_ panelID: UUID) {
        guard uncertainSince[panelID] == nil else { return }
        uncertainSince[panelID] = HCMonotonic.now
        let delay = UInt64(creationResolutionSeconds * 1_000_000_000)
        resolutionTimers[panelID] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            await self?.notifyResolutionDeadline(panelID)
        }
    }

    private func notifyResolutionDeadline(_ panelID: UUID) {
        guard uncertainSince[panelID] != nil else { return }
        // Re-evaluate pending panel resolutions without fabricating a core seq
        // or revoking the readiness of the session's other live terminals.
        feed.publish(lastSnapshot)
    }

    private func addressFor(_ key: HCTerminalKey, record: HCTerminalRecord, ownCoreID: String) throws -> String {
        try Self.terminalAddress(key, record: record, ownCoreID: ownCoreID)
    }

    /// The wire address of a terminal for attach, put and kill: its local
    /// address on this core, or `<machine>/<address>` on another machine.
    /// A local address is hc's own form (`HCLocalTerminalAddress`): hc numbers
    /// terminals t1…t19, then t1b…t1z, then t20…, so letters are ordinary.
    /// Anything else (a separator, uppercase, a vowel, non-ASCII) is not an hc
    /// address and could break the `<machine>/<address>` form.
    static func terminalAddress(_ key: HCTerminalKey, record: HCTerminalRecord, ownCoreID: String) throws -> String {
        let address = key.localAddress
        guard HCLocalTerminalAddress.isValid(address) else { throw HCUnavailableReason.staleIdentity }
        if key.owningCoreID == ownCoreID { return address }
        guard record.machineAvailability == .connected, let alias = record.machineName, !alias.isEmpty,
              !alias.contains("/") else { throw HCUnavailableReason.connectionLost }
        return "\(alias)/\(address)"
    }

    private static func reason(_ error: Error) -> HCUnavailableReason {
        if let reason = error as? HCUnavailableReason { return reason }
        if let failure = error as? HCRPCFailure { return failure.reason }
        if error is CancellationError { return .cancelled }
        return .intentStoreFailure
    }
}


/// Error receipts for the existing-only CLI adapter retain the wire's certainty.
struct HCManagedCallFailure: Error, Sendable {
    let reason: HCUnavailableReason
    let retrySafe: Bool

    init(_ error: Error, mayMutate: Bool) {
        if let failure = error as? HCRPCFailure {
            reason = failure.reason
            retrySafe = failure.transmission != .possible || !mayMutate
        } else if let unavailable = error as? HCUnavailableReason {
            // ManagedSession emits bare reasons only before handing off a call.
            reason = unavailable
            retrySafe = true
        } else {
            reason = HCUnavailableReason.transportReason(error)
            retrySafe = !mayMutate
        }
    }
}

extension HCManagedSession: HCTerminalLabeling {}

/// hc 0.1.16's list returns local rows even when its concurrent, 3 s remote
/// probes fail. Its machines describe link state, not probe completion: a
/// connected machine with no rows may be empty OR may have timed out. Expose
/// that uncertainty instead of letting a monitor infer that sessions ended.
enum HCManagedListResult {
    static func annotate(_ value: HCJSONValue) throws -> HCJSONValue {
        guard var result = value.object, let terminals = result["terminals"]?.array else {
            throw HCUnavailableReason.malformedResponse
        }
        let machines: [HCJSONValue]
        if let raw = result["machines"] {
            guard let rows = raw.array else { throw HCUnavailableReason.malformedResponse }
            machines = rows
        } else { machines = [] }
        var availability: [String: String] = [:]
        var partial = false
        result["machines"] = .array(try machines.map { value in
            guard var row = value.object, let name = row["name"]?.string,
                  let state = row["state"]?.string else { throw HCUnavailableReason.malformedResponse }
            let hasRows = terminals.contains { $0["address"].string?.hasPrefix(name + "/") == true }
            let status = state != "connected" ? "unavailable" : (hasRows ? "available" : "unconfirmed")
            availability[name] = status
            if status != "available" { partial = true }
            row["inventory_status"] = .string(status)
            return .object(row)
        })
        result["terminals"] = .array(try terminals.map { value in
            guard var row = value.object, let address = row["address"]?.string else {
                throw HCUnavailableReason.malformedResponse
            }
            if let slash = address.firstIndex(of: "/") {
                let status = availability[String(address[..<slash])] ?? "unconfirmed"
                row["availability"] = .string(status)
                if status != "available" { partial = true }
            } else { row["availability"] = .string("local") }
            return .object(row)
        })
        result["partial"] = .bool(partial)
        if partial { result["retry_safe"] = .bool(true) }
        return .object(result)
    }
}


/// C11H-332: what a live session needs to review its stored links: the home
/// c11's via files live under and the link script that migrates them.
struct HCStoredLinkReview: Sendable {
    let home: URL
    let linkScript: URL?
    var runner: any HCMachineSetupRunner = HCMachineSetupProcessRunner()
}

/// C11H-415: a c11 app process that hc would end with a terminal. hc ends what
/// a terminal started by its `HC_SCOPE` token: every process whose exec-time
/// environment (`HCExecEnvironment`) carries the token, and everything beneath
/// one that does, short of hc's own processes (hc `sweep.rs`, `members`). An
/// app opened from a c11 terminal (`open -a`, or its binary run there) carries
/// that terminal's token unless its launch blanked it, which no build before
/// C11H-415 does.
struct HCScopeCarrier: Equatable, Sendable {
    /// One `HC_SCOPE` token in the recorded environment of the app or of one of
    /// its ancestors, with hc's terminal labels recorded beside it.
    struct Mark: Equatable, Sendable {
        let scope: String
        let terminalID: String?
        let terminalSocket: String?
        /// The process whose recorded environment holds it: the app or an ancestor.
        let holderPID: Int32
    }

    let pid: Int32
    let bundleID: String
    let marks: [Mark]

    /// Ending terminal `address` of the core on `socket` would end this app.
    /// hc sweeps by the token, so with the terminal's recorded token (`scope`)
    /// only a mark holding that token counts; hc's labels for that terminal on
    /// that core stand in only when no token is recorded. A reused address
    /// with a new token holds nothing.
    func isEnded(byTerminal address: String, socket: String, scope: String?) -> Bool {
        marks.contains { mark in
            if let scope { return mark.scope == scope }
            return mark.terminalID == address && mark.terminalSocket == socket
        }
    }
}

enum HCScopeCarriers {
    /// c11's app bundles: c11 and c11h, and their debug and tagged builds.
    static func isC11App(bundleID: String) -> Bool {
        bundleID == "com.stage11.c11" || bundleID == "com.stage11.c11h" // c11-2.0:keep
            || bundleID.hasPrefix("com.stage11.c11.") || bundleID.hasPrefix("com.stage11.c11h.") // c11-2.0:keep
    }

    /// `/x/Name.app` for an app's own executable, `/x/Name.app/Contents/MacOS/<exe>`; nil otherwise.
    static func appBundle(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        let executable = path[range.upperBound...]
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The marks hc would end `pid` by: its own recorded tokens and every
    /// ancestor's, walking parents up to launchd. A process hc marks as its own
    /// (`HC_RUNTIME=1`) is never ended, nor anything beneath it, so the walk
    /// stops there. An environment the kernel hides (Apple's binaries) is hidden
    /// from hc too: it adds nothing and the walk goes on.
    static func marks(of pid: Int32, parent: (Int32) -> Int32?,
                      environment: (Int32) -> [(name: String, value: String)]?) -> [HCScopeCarrier.Mark] {
        var marks: [HCScopeCarrier.Mark] = []
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted, seen.count <= 64 {
            if let entries = environment(current) {
                if entries.contains(where: { $0.name == "HC_RUNTIME" && $0.value == "1" }) { break }
                let terminalID = entries.first { $0.name == "HC_TERMINAL_ID" }?.value
                let socket = entries.first { $0.name == "HC_TERMINAL_SOCKET" }?.value
                for entry in entries where entry.name == "HC_SCOPE" && !entry.value.isEmpty {
                    marks.append(HCScopeCarrier.Mark(scope: entry.value, terminalID: terminalID,
                                                     terminalSocket: socket, holderPID: current))
                }
            }
            guard let next = parent(current) else { break }
            current = next
        }
        return marks
    }

    /// Every live c11 app process of ours that carries a mark, this one
    /// included. A test process reads no real process table (as
    /// `HCAbandonedDiagnostics`): tests pass their carriers.
    static func live() -> [HCScopeCarrier] {
        guard !QALaunchPolicy.currentProcessIsHostedTest,
              let table = HCKernelAbandonedHost().processes() else { return [] }
        let parents = Dictionary(table.map { ($0.identity.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        var carriers: [HCScopeCarrier] = []
        for process in table {
            let pid = process.identity.pid
            guard let path = executablePath(pid), let bundle = appBundle(ofExecutable: path),
                  let bundleID = bundleIdentifier(bundle), isC11App(bundleID: bundleID) else { continue }
            let marks = marks(of: pid, parent: { parents[$0] },
                              environment: { HCExecEnvironment.read(pid: $0).map(HCExecEnvironment.entries) })
            if !marks.isEmpty { carriers.append(HCScopeCarrier(pid: pid, bundleID: bundleID, marks: marks)) }
        }
        return carriers
    }

    /// The `HC_SCOPE` token hc recorded for terminal `address` in its session's
    /// `terminals.json`; nil when the record is missing, unreadable or lists no token.
    static func recordedScope(address: String, stateDirectory: URL) -> String? {
        let file = stateDirectory.appendingPathComponent("terminals.json")
        guard let data = try? PrivateFileWriter.readPrivateFile(at: file, maxBytes: HCAbandonedSessions.maxRecordBytes),
              let terminals = HCAbandonedSessions.parseTerminals(data) else { return nil }
        return terminals.first { $0.address == address }?.scope
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let bundleIDs = OSAllocatedUnfairLock(initialState: [String: String]())

    /// The bundle's `CFBundleIdentifier`, read once per path.
    private static func bundleIdentifier(_ bundle: String) -> String? {
        if let known = bundleIDs.withLock({ $0[bundle] }) { return known }
        guard let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
              let identifier = plist["CFBundleIdentifier"] as? String else { return nil }
        bundleIDs.withLock { $0[bundle] = identifier }
        return identifier
    }
}
