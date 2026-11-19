import Foundation
import Combine
import OSLog

/// Debug-only trace of attach, defer, retry and cancel steps. The app points
/// `sink` at `dlog` in Debug; Release compiles every call to nothing.
enum HCTrace {
    #if DEBUG
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    #endif
    @inline(__always) static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        sink?("hc.trace " + message())
        #endif
    }
}

struct HCCreationProvenance: Sendable {
    enum Outcome: Sendable { case attempted, bound, unresolved, rejected, reconciled }
    let creationID: UUID
    let replaces: HCEndEvidence?
    let outcome: Outcome
    let boundKey: HCTerminalKey?
}

/// Restore seeds this registry BEFORE constructing any native panel/surface.
/// Reading a seed is not consuming it: recreated views must retain identity.
final class HCPanelRestoreState: @unchecked Sendable {
    static let shared = HCPanelRestoreState()
    struct Entry: Sendable {
        let identity: HCPanelIdentity
        let lifecycle: HCLifecycle
        let creation: HCCreationProvenance?
        let migrationEnd: HCEndEvidence?

        init(identity: HCPanelIdentity, lifecycle: HCLifecycle, creation: HCCreationProvenance?,
             migrationEnd: HCEndEvidence? = nil) {
            self.identity = identity
            self.lifecycle = lifecycle
            self.creation = creation
            self.migrationEnd = migrationEnd
        }
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var owners: [UUID: UUID] = [:]

    func claim(panelID: UUID, owner: UUID) {
        lock.lock(); owners[panelID] = owner; lock.unlock()
    }
    func isOwner(panelID: UUID, owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return owners[panelID] == owner
    }
    func release(panelID: UUID, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owners[panelID] == owner { owners.removeValue(forKey: panelID) }
    }

    func seed(_ identity: HCPanelIdentity, migrationEnd: HCEndEvidence? = nil) {
        let restored = HCPanelIdentity(panelID: identity.panelID, key: identity.key,
            persistence: identity.persistence, creationID: identity.creationID, origin: .restored)
        // A replacement that was already created when c11 quit still answers
        // to this end. The current identity/intent resolves whether it lives;
        // retaining provenance never authorizes a second create or resume.
        let creation = migrationEnd.flatMap { proof in
            restored.creationID.map {
                HCCreationProvenance(creationID: $0, replaces: proof,
                    outcome: restored.key == nil ? .unresolved : .reconciled, boundKey: restored.key)
            }
        }
        lock.lock()
        owners.removeValue(forKey: identity.panelID)
        entries[identity.panelID] = Entry(identity: restored, lifecycle: .unresolved(restored, .inventoryPending),
                                          creation: creation, migrationEnd: migrationEnd)
        if self === Self.shared { HCLoadMeter.shared.setPanelCount(entries.count) }
        lock.unlock()
    }
    func entry(for panelID: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[panelID]
    }
    /// Every panel identity the app has published, readable off-main. The
    /// diagnostics recorder takes it as the panels' persistence and origin.
    func identities() -> [HCPanelIdentity] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.identity)
    }
    func publish(identity: HCPanelIdentity, lifecycle: HCLifecycle) {
        lock.lock(); defer { lock.unlock() }
        var creation = entries[identity.panelID]?.creation
        if case .live(let record) = lifecycle, let current = creation,
           record.labels["c11.creation"]?.lowercased() == current.creationID.uuidString.lowercased() {
            creation = HCCreationProvenance(creationID: current.creationID, replaces: current.replaces,
                outcome: current.outcome == .unresolved ? .reconciled : .bound, boundKey: record.key)
        }
        entries[identity.panelID] = Entry(identity: identity, lifecycle: lifecycle, creation: creation,
                                          migrationEnd: entries[identity.panelID]?.migrationEnd)
        if self === Self.shared { HCLoadMeter.shared.setPanelCount(entries.count) }
    }

    /// Observational provenance, not permission to create: HCSession still
    /// validates and consumes the authoritative end evidence durably.
    func recordCreation(panelID: UUID, creationID: UUID, replacing proof: HCEndEvidence?) {
        lock.lock(); defer { lock.unlock() }
        guard let current = entries[panelID] else { return }
        entries[panelID] = Entry(identity: current.identity, lifecycle: current.lifecycle,
            creation: HCCreationProvenance(creationID: creationID, replaces: proof,
                outcome: .attempted, boundKey: nil),
            migrationEnd: current.migrationEnd?.key == proof?.key ? current.migrationEnd : nil)
    }

    func recordCreationOutcome(panelID: UUID, creationID: UUID, result: HCCreateResult) {
        lock.lock(); defer { lock.unlock() }
        guard let current = entries[panelID], let creation = current.creation,
              creation.creationID == creationID else { return }
        let outcome: HCCreationProvenance.Outcome
        let key: HCTerminalKey?
        switch result {
        case .bound(let record): outcome = .bound; key = record.key
        case .unresolved: outcome = .unresolved; key = nil
        case .rejectedBeforeTransmission: outcome = .rejected; key = nil
        }
        entries[panelID] = Entry(identity: current.identity, lifecycle: current.lifecycle,
            creation: HCCreationProvenance(creationID: creationID, replaces: creation.replaces,
                outcome: outcome, boundKey: key), migrationEnd: current.migrationEnd)
    }
    /// Explicit panel removal only. Native surface disposal never erases it.
    func remove(panelID: UUID) {
        lock.lock()
        entries.removeValue(forKey: panelID)
        owners.removeValue(forKey: panelID)
        if self === Self.shared { HCLoadMeter.shared.setPanelCount(entries.count) }
        lock.unlock()
        HCShardPlacement.shared.removePanel(panelID)
    }

    /// Panels closed for good drop their entries (C11H-114), installed at
    /// launch so no close escapes it. A workspace or window close reaches this
    /// through the same seam. Moves and app termination never fire it, so a
    /// moving or quitting panel keeps its entry for the snapshot. The removal
    /// waits one main turn, after the close's own end request, which may still
    /// read the entry for a panel whose session never registered (C11H-103).
    @MainActor
    static func installCloseObserver(
        lineage: PanelLineage? = nil,
        state: HCPanelRestoreState = .shared,
        diagnostics: @escaping (HCDiagnosticEvent) -> Void = { HCCompositionDiagnostics.record($0) }
    ) {
        (lineage ?? .shared).addPanelClosedForGoodObserver { panelIDs in
            // C11H-205: the panel's diagnostics row goes too, and stays gone.
            for id in panelIDs { diagnostics(.panelClosed(panelID: id)) }
            DispatchQueue.main.async {
                for id in panelIDs { state.remove(panelID: id) }
            }
        }
    }
}

/// One decision for the native exec path: persistent panels await hc attachment.
enum HCPanelNativeLaunchPolicy {
    static func permitsExec(identity: HCPanelIdentity?) -> Bool {
        identity?.persistence != .persistent
    }
}

/// Single app-side composition point. 3A and reconnect use the same session
/// object as surface creation; neither duplicates create/attach decisions.
@MainActor
final class HCBackendComposition {
    static let shared: HCBackendComposition = {
        let composition = HCBackendComposition()
        HCSessionEnd.compose(into: composition)
        return composition
    }()
    private(set) var session: (any HCSession)?
    private(set) var inventory: (any HCInventorySource)?
    /// Shard 0's configuration: the single session before shards.
    private(set) var configuration: HCLaunchConfiguration?
    /// C11H-391: the session Add Machine, Update, `c11 machine link` and the
    /// machine lists link through: c11's own shard 0 session. While this app
    /// has adopted c11h's sessions that is the links session `L` (session
    /// `c11`, root `~/.local/share/c11`), never the adopted `c11h`, so a
    /// machine linked after the switch is already the converged link.
    var linkConfiguration: HCLaunchConfiguration? { linksSession?.configuration ?? configuration }
    /// C11H-391: the links session `L`, composed only while adopted.
    private(set) var linksSession: HCManagedSession?
    /// C11H-391: `L` already lists machines, so its core starts with restore
    /// (its links redial and `--on` sees them); otherwise it starts only when
    /// Add Machine asks, and is joined only if already serving.
    private var linksStartAtRestore = false
    /// C11H-67: the shard pool when the live backend is composed.
    private(set) var pool: HCShardPool?
    var makeRenderingAdapter: (TerminalSurface) -> any HCRenderingAdapter = { _ in HCUnavailableRenderingAdapter() }
    var makeInputEncoder: (TerminalSurface) -> any HCInputEncoder = { _ in HCUnavailableInputEncoder() }
    var onPanelSessionCreated: ((HCPanelSession) -> Void)?
    /// `shared` registers HCSessionEnd.install(session:) (3C); other
    /// compositions keep the no-op.
    var installSessionEnd: (any HCSession) -> Void = { _ in }
    var hasCreatedNativeSurface = false
    private var initialRestoreReady = false
    private var servingShardsJoined = false
    /// C11H-16: machine transitions feed the relay (spool drain, manifest, trust log).
    private var relayObservations: [HCObservation] = []
    private var deferredSurfaceStarts: [UUID: () -> Void] = [:]

    func deferSurfaceStartUntilRestore(panelID: UUID, start: @escaping () -> Void) -> Bool {
        guard !initialRestoreReady else { return false }
        deferredSurfaceStarts[panelID] = start
        return true
    }

    func cancelDeferredSurfaceStart(panelID: UUID) { deferredSurfaceStarts.removeValue(forKey: panelID) }

    /// C11H-359 (M4): every shard's active creation records (a store read
    /// starts no core). Nil when any store cannot be read now: the caller
    /// reads again rather than judging from part of them.
    func activeCreations() async -> [HCStoredCreation]? {
        let stores = pool?.shards.compactMap(\.intents) ?? []
        var records: [HCStoredCreation] = []
        for store in stores {
            guard let all = try? await store.all() else { return nil }
            records.append(contentsOf: all.filter { $0.phase != .ended })
        }
        return records
    }
    /// Whether the session restore has finished (the gate is open). Read by tests that restore the gate.
    var isInitialRestoreReady: Bool { initialRestoreReady }

    func setInitialRestoreReady(_ ready: Bool) {
        initialRestoreReady = ready
        guard ready else { return }
        if !servingShardsJoined, let pool {
            servingShardsJoined = true
            pool.connectServingShards()
            if linksStartAtRestore, let links = linksSession {
                Task.detached(priority: .utility) {
                    // C11H-396: a links session that won't start lists nothing that is coming.
                    let started = await links.startServing()
                    if !started { HCLinkedMachines.shared.setStartingLinks([]) }
                }
            }
        }
        let starts = Array(deferredSurfaceStarts.values)
        deferredSurfaceStarts.removeAll()
        for start in starts { start() }
    }

    // 2B invokes this on its bounded diagnostics worker, outside transport IO.
    private nonisolated static let transportDiagnostics: HCTransportReport = { event, generation, elapsed in
        HCDiagnosticRecorder.shared.recordTransport(event: event,
            connectionGeneration: generation, elapsedNanoseconds: elapsed)
    }

    /// Admission is installed before activation becomes visible to any panel.
    /// Ticket 7 passes HCProcessAdmission.shared.install(inventory:) here.
    func activate(session: any HCSession, inventory: any HCInventorySource, linkSession: HCManagedSession? = nil,
                  installAdmission: (any HCInventorySource) -> Void) {
        installAdmission(inventory)
        installSessionEnd(session)
        self.inventory = inventory
        self.session = session
        // Ticket 12: machine lines are polled; hc sends no event for them.
        let previous = linkMonitor
        linkMonitor = (linkSession ?? (session as? HCManagedSession))?.makeLinkMonitor()
        let next = linkMonitor
        Task { await previous?.stop(); await next?.start() }
        HCMachineDirectory.shared.follow(session)
    }

    /// Compose all services synchronously before a WorkspaceManager can create
    /// panels. Core/filesystem work remains lazy on the session and launcher.
    func activateLiveBackend(home: URL, tag: String?, inherited: [String: String],
                             shardsEnabled: Bool = HCShardSettings.isEnabled(),
                             namespace: C11AdoptionRecord? = HCLaunchPolicy.processNamespace) throws {
        guard session == nil else { return }
        let shardConfigurations = try Self.memberConfigurations(home: home, tag: tag, inherited: inherited, namespace: namespace)
        let configuration = shardConfigurations[0].1
        let linksConfiguration = shardConfigurations.first { $0.0 == HCShardID.links.index }?.1
        let verifier = HCBuildVerifier()
        #if DEBUG
        let connections = try HCLiveConnectionFactory(environment: inherited, diagnostics: Self.transportDiagnostics)
        #else
        let connections = HCLiveConnectionFactory(diagnostics: Self.transportDiagnostics)
        #endif
        let launcher = HCDiagnosticLauncher(base: HCLauncher(verifier: verifier))
        var sessions: [HCManagedSession] = []
        // C11H-78 (SH4): each shard has its own relay service (its own core's
        // slots and records), and each connect of a shard's core pairs it with
        // the same session on the machine the operator's pairing file names.
        // C11H-397: a paired Linux machine's via checks this build's Linux hc
        // pin (read only when a via is checked), a Mac's this Mac's.
        let macPin = shardConfigurations.first?.1.pin.executableSHA256
        let pairing = HCAtlasPairingRegistrar.live(home: home) {
            HCAtlasPairing.Pins(mac: macPin, linux: HCRemoteArtifactManifest.bundledLinuxHCPin)
        }
        let onPairedConnect = Self.pairingHook(registrar: pairing)
        let preparePairedRemote = Self.remotePreparation(pairing: pairing)
        // C11H-359 (L2): every shard's own core id is reserved before any
        // shard lists a linked machine, so none can claim one.
        let localCoreIDs = HCLocalCoreIDs.shared
        for (_, shardConfiguration) in shardConfigurations {
            if let id = HCLocalCoreIDs.read(stateDirectory: shardConfiguration.stateDirectory) { localCoreIDs.insert(id) }
        }
        let shards = shardConfigurations.map { index, shardConfiguration -> HCShard in
            let intents = HCCreationIntentStore(directory: shardConfiguration.intentDirectory)
            let relaySignals = Self.relaySignalRouter(to: C11RelayService.service(for: shardConfiguration.session))
            // C11H-391: `L` is never read-only and its core may start (it is
            // c11's own); it pairs nothing: its links come from Add Machine.
            let isLinks = index == HCShardID.links.index
            let readOnly = !isLinks && HCShardSettings.isReadOnly(shard: index, enabled: shardsEnabled)
            let session = HCManagedSession(configuration: shardConfiguration,
                connections: connections, verifier: verifier,
                launcher: isLinks ? launcher : HCShardSettings.launcher(forShard: index, enabled: shardsEnabled, base: launcher),
                intents: intents,
                prepareAttachment: Self.prepareAttachment,
                makeInventory: { connection, identity in
                    localCoreIDs.insert(connection.peer.coreID)
                    return HCLiveInventorySource(connection: connection, buildIdentity: identity, diagnostics: Self.transportDiagnostics,
                                          docSignals: relaySignals, reservedCoreIDs: { localCoreIDs.snapshot() })
                }, makeAttachment: Self.makeAttachment,
                readOnly: readOnly, onInstalled: readOnly || isLinks ? nil : onPairedConnect,
                prepareRemote: readOnly || isLinks ? nil : preparePairedRemote,
                // C11H-332: every live shard reviews its stored links before use.
                storedLinks: HCStoredLinkReview(home: home,
                                                linkScript: HCMachineSetupResources.inBundle(Bundle.main.bundleURL).linkScript))
            sessions.append(session)
            return HCShard(index: index, configuration: shardConfiguration, session: session, intents: intents)
        }
        let pool = HCShardPool(shards: shards, placementEnabled: shardsEnabled)
        pool.pairedWith = { machine, session in
            guard let pairing = HCAtlasPairingRegistrar.pairing(home: home) else { return false }
            return pairing.machine == machine && pairing.registration(for: session) != nil
        }
        let legacy = sessions[0]
        self.configuration = configuration
        self.pool = pool
        linksSession = pool.links?.session as? HCManagedSession
        linksStartAtRestore = linksConfiguration.map { Self.listsMachines(stateDirectory: $0.stateDirectory) } ?? false
        // C11H-396: until `L` reports, `--on` answers its names "not ready".
        HCLinkedMachines.shared.setStartingLinks(
            linksConfiguration.map { Self.listedMachineNames(stateDirectory: $0.stateDirectory) } ?? [])
        // SH5's recorder lists a shard from the moment it starts (lazily, on
        // its first live snapshot), with each panel attributed to its own shard.
        pool.onShardStarted = { shard in
            HCCompositionDiagnostics.install(shard.session, shard: shard.diagnosticsIdentity,
                shardOf: { identity in
                    HCShardPlacement.shared.home(forPanel: identity.panelID)
                        .flatMap { pool.shard($0) }.map(\.diagnosticsIdentity)
                })
        }
        installLiveSurfaceFactories()
        activate(session: pool, inventory: pool, linkSession: legacy) { HCProcessAdmission.shared.install(inventory: $0) }
        let commandSessions = sessions
        Task { await HCManagedCommandEndpoint.shared.install(commandSessions) }
        // C11H-78: every shard serves its own machines' relay; shard 0 keeps
        // the hand-made link, pool shards the ones the pairing file adds.
        for session in sessions { installRelay(session) }
        // Ticket 12's line poll, per shard: a shard's own link state drives its
        // own remote panels (shard 0's monitor is the one activate() made).
        // C11H-391: `L`'s too; an unstarted core's poll does nothing.
        shardLinkMonitors = sessions.dropFirst().map { $0.makeLinkMonitor() }
        let monitors = shardLinkMonitors
        Task { for monitor in monitors { await monitor.start() } }
    }

    /// C11H-78: each pool shard's machine-line poll. It never starts a core:
    /// an unstarted shard's poll finds no connection and does nothing.
    private var shardLinkMonitors: [HCMachineLinkMonitor] = []

    /// The pool's members by index. C11H-67: shard 0 is today's session and
    /// 1...size the pool, in the adopted names while adopted (the tuple check
    /// covers shard K's paths, so each holds). C11H-391: while adopted, c11's
    /// own converged shard 0 is added at `HCShardID.links`: no namespace, so
    /// session `c11[-<tag>]`, root `~/.local/share/c11`, this build's hc and its
    /// own retained helpers, never c11h's. A links tuple that can't be built
    /// (a path too long) leaves the adopted app without `L`, as before.
    nonisolated static func memberConfigurations(home: URL, tag: String?, inherited: [String: String],
                                                 binary: HCCoreBinary? = nil,
                                                 namespace: C11AdoptionRecord?) throws -> [(Int, HCLaunchConfiguration)] {
        var members = try (0...HCShardPool.size).map { index in
            (index, try HCLaunchPolicy.configuration(home: home, tag: tag, shard: index, inherited: inherited,
                                                     binary: binary, namespace: namespace))
        }
        do {
            guard let links = try HCLaunchPolicy.linksConfiguration(home: home, tag: tag, inherited: inherited,
                                                                    binary: binary, namespace: namespace) else { return members }
            // Opus on #382 (NB6): never a second managed session on an adopted member's socket.
            guard !members.contains(where: { $0.1.session == links.session || $0.1.socketURL == links.socketURL }) else {
                HCCoreStartLog.live.failed(.activation, HCUnavailableReason.invalidLaunchTuple,
                                           detail: "links session: its session is an adopted member's")
                return members
            }
            members.append((HCShardID.links.index, links))
        } catch {
            HCCoreStartLog.live.failed(.activation, error, detail: "links session: no Add Machine while adopted")
        }
        return members
    }

    /// Tests: shard 0's configuration and the links session, as an adopted
    /// activation composes them, without composing a pool.
    func composeLinksForTesting(configuration: HCLaunchConfiguration, links: HCManagedSession?) {
        self.configuration = configuration
        linksSession = links
    }

    /// C11H-391: whether a session's own `machines.json` lists a machine (a
    /// read; nothing is started). Unreadable or malformed counts as listing,
    /// so a link is never left undialed by a read error.
    nonisolated static func listsMachines(stateDirectory: URL) -> Bool {
        let file = stateDirectory.appendingPathComponent("machines.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file),
              let machines = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return true }
        return !machines.isEmpty
    }

    /// C11H-396: the machine names a session's own `machines.json` lists (a
    /// read; nothing is started). Missing, unreadable or malformed lists none.
    nonisolated static func listedMachineNames(stateDirectory: URL) -> Set<String> {
        let file = stateDirectory.appendingPathComponent("machines.json")
        guard let data = try? Data(contentsOf: file),
              let machines = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return Set(machines.compactMap { ($0 as? [String: Any])?["name"] as? String }.filter { !$0.isEmpty })
    }

    /// C11H-391: Add Machine, Update and `c11 machine link` in the links
    /// session start its core first (the flow then proves it is c11's own).
    /// Nil when not adopted: shard 0's core is already this app's.
    func startLinkSession() async -> Bool {
        guard let linksSession else { return true }
        return await linksSession.startServing()
    }

    /// C11H-78 (SH4): each connect of a shard's core pairs it with the same
    /// session on the machine the operator's pairing file names. No file, no
    /// machine added; the legacy session is never paired this way.
    nonisolated static func pairingHook(registrar: HCAtlasPairingRegistrar) -> @Sendable (HCManagedSession) -> Void {
        return { connected in
            Task { _ = await registrar.connected(session: connected.sessionName) { method, params in
                try await connected.pairingRequest(method, params: params)
            } }
        }
    }

    nonisolated static func remotePreparation(pairing: HCAtlasPairingRegistrar) -> HCManagedSession.PrepareRemote {
        return { connected, machine in
            guard try await pairing.prepare(session: connected.sessionName, machine: machine, request: { method, params in
                try await connected.pairingRequest(method, params: params)
            }) else { return [:] }
            let host = C11RelaySessionHost(session: connected)
            var lastError: Error = HCUnavailableReason.invalidLaunchTuple
            for path in C11Relay.Manifest.relativePaths(session: connected.sessionName) {
                do {
                    let text = try await host.relayFileRead(machine: machine, path: path)
                    if let manifest = C11Relay.Manifest(data: Data(text.utf8), session: connected.sessionName) {
                        return manifest.terminalEnvironment
                    }
                    lastError = HCUnavailableReason.invalidLaunchTuple
                } catch { lastError = error }
            }
            throw lastError
        }
    }

    /// C11H-16: serve c11 calls relayed from c11 terminals on other machines.
    /// C11H-78: one service per shard, on that shard's own session.
    private func installRelay(_ session: HCManagedSession) {
        let service = C11RelayService.service(for: session.sessionName)
        let host = C11RelaySessionHost(session: session)
        let executor = C11RelaySocketExecutor(controller: TerminalController.shared)
        Task { await service.install(host: host, executor: executor) }
        relayObservations.append(session.observe(on: DispatchQueue(label: "c11h.relay.machines")) { snapshot in
            guard case .ready = snapshot.readiness else { return }
            service.machinesChanged(snapshot.machines)
        })
    }

    /// Routes the inventory's doc signals to a relay service. A renewed
    /// subscription or a `missed` snapshot rescans the spools and the slots
    /// (C11H-89: an inventory refresh can lose a slot's event).
    nonisolated static func relaySignalRouter(to service: C11RelayService) -> @Sendable (HCDocSignal) -> Void {
        { signal in
            switch signal {
            case .doc(let machine, let name, let version):
                service.docEvent(machine: machine, name: name, version: version)
            case .resubscribed, .missed:
                service.resubscribed()
            }
        }
    }

    /// The live backend's per-surface factories: Ghostty's native encoder and
    /// ticket 5's rendering adapter (paint-proved `screenCurrent`, resize,
    /// theme facts, focus, size gate, latency probe). Without the rendering
    /// adapter no screen is ever current and every guarded send is refused.
    func installLiveSurfaceFactories() {
        makeInputEncoder = { $0.makeHCNativeEncoder() }
        makeRenderingAdapter = { surface in
            MainActor.assumeIsolated { HCPanelRendering(host: surface, pinVersion: HCPin.current.version) }
        }
    }

    private var linkMonitor: HCMachineLinkMonitor?
    /// App start: activate the live backend, or retain persistent identity as
    /// unavailable and say why. An invalid owned launch configuration is not
    /// permission for an exec fallback.
    func activateOrUnavailable(home: URL, tag: String?, inherited: [String: String],
                               startLog: HCCoreStartLog = .live,
                               installAdmission: (any HCInventorySource) -> Void = { HCProcessAdmission.shared.install(inventory: $0) }) {
        do {
            try activateLiveBackend(home: home, tag: tag, inherited: inherited)
            startLog.passed(.activation, detail: "session \(configuration?.session ?? "-"), shards \(pool?.placementEnabled == true ? "on" : "off")")
        } catch {
            startLog.failed(.activation, error, detail: "tag \(tag ?? "-"), home \(home.path): no core will be started")
            activate(session: HCUnavailableRuntime(), inventory: HCUnavailableRuntime(), installAdmission: installAdmission)
        }
    }

    func makePanelSession(panelID: UUID) -> HCPanelSession? {
        let restored = HCPanelRestoreState.shared.entry(for: panelID)
        guard let session else {
            // A restored persistent identity never becomes an exec shell just
            // because composition or the core is temporarily unavailable.
            guard let restored, restored.identity.persistence == .persistent else { return nil }
            return prepare(HCPanelSession(identity: restored.identity, session: HCUnavailableRuntime()))
        }
        if let restored, restored.identity.persistence == .nonpersistent { return nil }
        let routed: any HCSession = pool?.route(panelID: panelID) ?? session
        return prepare(HCPanelSession(identity: restored?.identity ?? HCPanelIdentity(
            panelID: panelID, origin: .fresh), session: routed))
    }

    private func prepare(_ runtime: HCPanelSession) -> HCPanelSession {
        runtime.installReconnectPolicy()
        onPanelSessionCreated?(runtime)
        // Hidden restored panels resolve liveness without native construction.
        // This never creates a terminal or sends initial/resume input.
        runtime.beginHiddenResolution()
        return runtime
    }

    nonisolated static func prepareAttachment(key: HCTerminalKey, generation: UInt64,
        sink: any HCOutputSink, proposedDisplay: HCDisplayState) async throws -> HCDisplayState {
        guard let bridge = sink as? HCNativeBridge else { throw HCUnavailableReason.backendNotInstalled }
        let display = await bridge.rendering.displayStateForAttach(
            attachmentGeneration: generation, focused: proposedDisplay.focused)
            ?? HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation,
                displayGeneration: proposedDisplay.revision.displayGeneration), grid: proposedDisplay.grid,
                facts: proposedDisplay.facts, focused: proposedDisplay.focused)
        guard display.grid.columns > 0, display.grid.rows > 0,
              bridge.prepare(generation: generation) else { throw HCUnavailableReason.cancelled }
        return display
    }

    nonisolated static func makeAttachment(key: HCTerminalKey, generation: UInt64,
        channel: any HCChannel, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        guard let bridge = sink as? HCNativeBridge else { throw HCUnavailableReason.backendNotInstalled }
        let attachment = HCPanelAttachment(panelID: bridge.panelID, key: key, generation: generation,
            channel: channel, sink: bridge, rendering: bridge.rendering, display: display,
            encoder: bridge.encoder, report: bridge.report, displayChanged: bridge.displayChanged)
        guard bridge.bind(generation: generation, input: attachment.input) else {
            throw HCUnavailableReason.cancelled
        }
        try await attachment.initializeFocus()
        await bridge.rendering.attached(attachment)
        // HCManagedSession activates the dormant channel only after return.
        return attachment
    }

}

struct HCPanelLaunchSpec: Sendable {
    let argv: [String]
    let cwd: String?
    let environment: [String: String]
    let initialInput: HCInitialInput?
    var workspaceID: UUID? = nil
    /// hc machine to run on (ticket 12); nil runs on this core. A remote
    /// spec never falls back to a local plain shell.
    var machine: String? = nil
    /// C11H-67: the pool shard a creation targets; nil for a single session.
    var shard: HCShardID? = nil

    /// A local ended panel keeps its selected terminal environment and shard,
    /// but starts a fresh shell without replaying the original launch input.
    /// Wire normalization belongs to HCManagedSession, not this replacement.
    func replacingEndedWithShell(argv: [String]) -> HCPanelLaunchSpec {
        HCPanelLaunchSpec(argv: argv, cwd: cwd, environment: environment,
                          initialInput: nil, workspaceID: workspaceID, shard: shard)
    }
}

/// Consumer-facing runtime hooks. Only this object owns a panel's attachment;
/// view disposal detaches, while an explicit close calls endSession().
@MainActor
final class HCPanelSession: ObservableObject {
    /// C11H-103: may this panel replace a terminal it knew (a key) that is
    /// now gone? False for a panel in Recovered: it exists only to show an
    /// orphan, so a missing orphan leaves it empty rather than starting a new
    /// shell under a closed panel's id. A brand-new keyless tab is unaffected.
    static var mayReplaceMissingTerminal: @MainActor (_ panelID: UUID, _ workspaceID: UUID?) -> Bool = { _, _ in true }

    /// C11H-206: a creation this runtime sent to hc that hc's inventory has not listed yet.
    private var unlistedCreationID: UUID?

    /// C11H-206: while this runtime's own creation is unlisted, look it up again (bounded). Resolve finds a
    /// creation by its creation id first and answers pending until hc lists it, so this never creates twice.
    private func awaitOwnCreationListing(_ resolved: HCLifecycle, epoch: UInt64) async throws -> HCLifecycle {
        guard case .unresolved(_, let reason) = resolved, Self.awaitsListing(reason),
              let pending = unlistedCreationID, identity.creationID == pending else {
            if case .unresolved = resolved {} else { unlistedCreationID = nil }
            return resolved
        }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ Self.creationListingWaitNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: Self.creationListingPollNanoseconds)
            guard ownsLifecycle, epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
            let listed = await session.resolve(identity)
            guard epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
            if case .unresolved(_, let still) = listed, Self.awaitsListing(still) { continue }
            HCTrace.log("attachSurface.listed panel=\(identity.panelID.uuidString.prefix(8)) resolved=\(listed)")
            unlistedCreationID = nil
            publish(listed)
            return listed
        }
        return resolved
    }

    /// C11H-206: how long a creation hc made may take to appear in its inventory before the start gives up, and
    /// how often it is looked up meanwhile. Test seams.
    static var creationListingWaitNanoseconds: UInt64 = 30_000_000_000
    static var creationListingPollNanoseconds: UInt64 = 250_000_000
    static func awaitsListing(_ reason: HCUnavailableReason) -> Bool {
        reason == .inventoryPending || reason == .creationPending || reason == .deadlineExceeded
    }

    private static let inputLogger = Logger(subsystem: "com.stage11.c11", category: "hc.input")
    @Published private(set) var identity: HCPanelIdentity {
        didSet { homeInterest.key = identity.key }
    }
    /// C11H-238: the terminal this panel's inventory observer cares about,
    /// read off main by the shard pool's fan-out.
    let homeInterest: HCHomeInterest
    @Published private(set) var lifecycle: HCLifecycle
    @Published private(set) var inputFault: HCInputRefusal?
    @Published private(set) var disconnectedInput: HCDisconnectedInput?
    /// C11H-238: the generation of the attachment last bound. A pending
    /// resume waits for a bound port, and binding does not change the
    /// lifecycle, so observers that wait for the port watch this.
    @Published private(set) var boundGeneration: UInt64?
    private var reconnectCoordinator: HCReconnectCoordinator?
    private(set) var attachment: (any HCAttachment)?
    private var lastDisplayRevision = HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0)
    var currentDisplayState: HCDisplayState? { (attachment as? HCPanelAttachment)?.currentDisplayState }
    var currentDisplayRevision: HCDisplayRevision { currentDisplayState?.revision ?? lastDisplayRevision }
    private(set) var inputEpoch: UInt64 = 0
    /// True from creation until the first attachment is bound, while the
    /// creation can still succeed. Launch input may wait for it; after the
    /// first bind a missing port means a reconnect, which never queues input.
    var isAwaitingFirstAttachment: Bool {
        if case .ended = lifecycle { return false }
        return !everBound && !disposed && identity.persistence == .persistent
    }
    let session: any HCSession

    /// Ticket 6 installs these callbacks; delivery always occurs on main.
    var onConnectionLoss: ((HCUnavailableReason) -> Void)?
    var onInputFault: ((HCInputRefusal) -> Void)?
    var onAttachmentBound: ((any HCAttachment, HCDisplayState) -> Void)?
    var onAttachmentDetached: ((UInt64) -> Void)?
    var onSurfaceDisposed: (() -> Void)?
    var onInitialAttachUnresolved: ((HCUnavailableReason) -> Void)?
    var onAttachmentLoss: ((UInt64, HCUnavailableReason) -> Void)?
    var onDisplayChanged: ((HCDisplayState) -> Void)?
    var reconnectAttachment: ((HCTerminalRecord) async throws -> any HCAttachment)?
    var requestInputFaultReattach: (() -> Void)?
    var onEnded: ((HCEndEvidence) -> Void)?
    /// C11H-232: the last live record published, so a child end can tell
    /// whether an agent was in front of the terminal when its root died.
    private(set) var lastLiveRecord: HCTerminalRecord?
    var onFallback: (() -> Void)?
    var onInputOutcome: ((HCInputOutcome) -> Void)?
    var onWillCreate: ((UUID, HCEndEvidence?) -> Void)?
    var onCreationOutcome: ((UUID, HCCreateResult) -> Void)?
    /// C11H-313: (attempt, adopted): the attempt bound to the terminal another
    /// creation of this panel made, which becomes the panel's creation.
    var onCreationAdopted: ((UUID, UUID) -> Void)?
    var onLifecycleChanged: ((HCPanelRestoreState.Entry) -> Void)?
    /// Where this panel's diagnostic events go (`hc-diagnostics`). The default
    /// hands them to the recorder on its own queue and returns; tests replace it.
    var diagnosticSink: (HCDiagnosticEvent) -> Void = { HCCompositionDiagnostics.record($0) }
    /// The last outage or end already reported, so a state that every inventory
    /// snapshot re-publishes is sent once. An attach clears it.
    private var lastDiagnosed: String?
    /// Busy shards can republish many revisions with the same answer. Keep
    /// the first wait and every outcome transition without rotating away history.
    private var lastDiagnosedResolutionOutcome: String?
    private var observation: HCObservation?
    private var startTask: Task<any HCAttachment, Error>?
    /// An attach (a native or headless start) is in flight. C11H-160: a replacement lets it settle first.
    var isStartingAttachment: Bool { startTask != nil }
    /// Waits until no start is in flight: the start's own caller clears it after its await, which can come after
    /// a joiner resumes, so this waits for the clear too (bounded).
    func settleStart() async {
        for _ in 0..<200 {
            guard let task = startTask else { return }
            _ = try? await task.value
            await Task.yield()
        }
    }
    private var surfaceEpoch: UInt64 = 0
    private var handledEnd: HCTerminalKey?
    private var interruptedGeneration: UInt64?
    private var everBound = false
    private var pendingInitialFault: HCInputOutcome?
    private let runtimeOwner = UUID()
    private var lifecycleEpoch: UInt64 = 0
    private var hiddenResolution: Task<Void, Never>?
    private var hiddenResolutionRequested = false
    private var hiddenResolutionRevision: HCRevision?
    private var hiddenResolutionSource: HCShardID?
    private var disposed = false
    /// The identity last handed to process admission, so repeated inventory
    /// publishes of the same terminal do not re-register it.
    private var registeredIdentity: HCPanelIdentity?
    /// Where registrations go: process admission, which forwards to agent
    /// recovery. Tests observe the calls themselves.
    typealias IdentityRegistrar = @MainActor (HCPanelIdentity?, UUID) -> Void
    private let registrar: IdentityRegistrar
    private var ownsLifecycle: Bool {
        !disposed && HCPanelRestoreState.shared.isOwner(panelID: identity.panelID, owner: runtimeOwner)
    }

    init(identity: HCPanelIdentity, session: any HCSession,
         registrar: @escaping IdentityRegistrar = { HCProcessAdmission.shared.setPanelIdentity($0, panelID: $1) }) {
        self.identity = identity
        homeInterest = HCHomeInterest(key: identity.key)
        self.session = session
        self.registrar = registrar
        lifecycle = .unresolved(identity, .inventoryPending)
        HCPanelRestoreState.shared.claim(panelID: identity.panelID, owner: runtimeOwner)
        registerIdentity()
    }

    /// Plan 8: agent recovery re-learns a surviving terminal's tty and root
    /// pid only for a panel whose identity process admission holds. Registered
    /// at creation (a restored key claims before resolution) and on every
    /// lifecycle publish; a fallback to exec registers the nonpersistent
    /// identity, which drops the claim.
    private func registerIdentity() {
        guard registeredIdentity != identity else { return }
        registeredIdentity = identity
        registrar(identity, identity.panelID)
    }

    func beginHiddenResolution() {
        guard ownsLifecycle else { return }
        hiddenResolutionRequested = true
        guard hiddenResolution == nil else { return }
        hiddenResolution = Task { [weak self] in
            // Coalesce ready inventories, including one delivered while the
            // previous lookup is suspended. Never cancel a lookup at birth.
            while let self, self.hiddenResolutionRequested, self.ownsLifecycle, !Task.isCancelled {
                self.hiddenResolutionRequested = false
                _ = await self.resolveIdentity()
            }
            self?.hiddenResolution = nil
        }
    }

    /// Install once before the runtime is exposed to a panel. Reconnect adopts
    /// every binding before input opens, superseding any older retry.
    func installReconnectPolicy() {
        guard disconnectedInput == nil else { return }
        let policy = HCDisconnectedInput(panelID: identity.panelID, setAdmission: { attachment, open in
            (attachment as? HCPanelAttachment)?.setAdmission(open)
        }, clearFault: { [weak self] attachment, receipt in
            guard let self else { return HCRetryRefusal(.connectionChanged, "runtime.gone") }
            guard self.attachment === attachment else {
                return HCRetryRefusal(.connectionChanged, "runtime.attachmentChanged",
                    "port=\(self.attachment.map { String($0.generation) } ?? "nil") expected=\(attachment.generation)")
            }
            return await self.clearInputFault(using: receipt)
        }, currentDisplay: { [weak self] in self?.currentDisplayState },
           reattach: { [weak self] in self?.requestInputFaultReattach?() })
        disconnectedInput = policy
        onAttachmentBound = { [weak self, weak policy] attachment, display in
            guard let self else { return }
            // An inventory wait can have made lifecycle unresolved while the
            // verified attach was in flight. Keep its last live identity when
            // transferring the new port, rather than leaving a retry in charge.
            // Attach paths publish their live record first; bind rejects a
            // same-key end that arrives before the attachment finishes.
            if let record = self.lastLiveRecord {
                if let previous = self.reconnectCoordinator,
                   let ownerKey = previous.identity.key, ownerKey != record.key {
                    // Ordinary startup can replace an ended terminal without
                    // prepareEndedReplacement. Retire that terminal's owner.
                    self.reconnectCoordinator = nil
                    previous.stop()
                }
                let existing = self.reconnectCoordinator
                let coordinator = existing ?? self.makeReconnectCoordinator()
                if !coordinator.start(attached: attachment, record: record), existing == nil {
                    self.reconnectCoordinator = nil
                }
            }
            policy?.bind(attachment, display: display)
        }
        onAttachmentDetached = { [weak policy] _ in policy?.disconnect() }
        onSurfaceDisposed = { [weak self] in
            let coordinator = self?.reconnectCoordinator
            self?.reconnectCoordinator = nil
            coordinator?.stop()
        }
        onInitialAttachUnresolved = { [weak self] _ in
            guard let self, self.reconnectCoordinator == nil else { return }
            self.makeReconnectCoordinator().start()
        }
        onAttachmentLoss = { [weak self] generation, reason in
            self?.reconnectCoordinator?.disconnected(generation: generation, reason: reason)
        }
        onDisplayChanged = { [weak policy] display in policy?.updateDisplay(display) }
        onInputOutcome = { [weak policy] outcome in policy?.record(outcome) }
        onInputFault = { [weak policy] _ in policy?.record(.refused(.inputFault)) }
        requestInputFaultReattach = { [weak self] in
            guard let self, let attachment = self.attachment else { return }
            // A reconnect owner holding another port ignores the request, and the
            // pause would wait for a generation that never comes: say so.
            guard let coordinator = self.reconnectCoordinator, coordinator.attachment === attachment else {
                let owner = self.reconnectCoordinator?.attachment.map { String($0.generation) } ?? "nil"
                let line = "input reattach not requested panel=\(self.identity.panelID.uuidString) " +
                    "port=\(attachment.generation) owner=\(owner)"
                Self.inputLogger.notice("\(line, privacy: .public)")
                return
            }
            coordinator.disconnected(generation: attachment.generation, reason: .connectionLost)
        }
    }

    private func makeReconnectCoordinator() -> HCReconnectCoordinator {
        let coordinator = HCReconnectCoordinator(identity: identity, session: session,
            attach: { [weak self] record in
                guard let self, let attach = self.reconnectAttachment else { throw HCUnavailableReason.cancelled }
                // The surface owner creates one replacement renderer/bridge and
                // binds its result back here; the coordinator never creates hc terminals.
                return try await attach(record)
            }, detach: { [weak self] candidate in
                guard let self, self.attachment === candidate else { candidate.detach(); return }
                self.detachSurface(forReattach: true)
            }, changed: { [weak self] coordinator in
                guard let self, self.reconnectCoordinator === coordinator else { return }
                self.publish(coordinator.lifecycle)
            })
        reconnectCoordinator = coordinator
        return coordinator
    }

    @discardableResult
    func resolveIdentity() async -> HCLifecycle {
        let started = DispatchTime.now().uptimeNanoseconds
        let expected = identity
        let epoch = lifecycleEpoch
        let resolved = await session.resolve(expected)
        guard ownsLifecycle, !Task.isCancelled, lifecycleEpoch == epoch, identity == expected else { return lifecycle }
        publish(resolved)
        let outcome: String
        switch resolved {
        case .new: outcome = "new"
        case .live: outcome = "live"
        case .ended: outcome = "ended"
        case .unresolved(_, let reason): outcome = HCDiagnosticTokens.unavailable(reason)
        }
        if lastDiagnosedResolutionOutcome != outcome {
            lastDiagnosedResolutionOutcome = outcome
            recordAttachmentProgress(phase: "resolve", outcome: outcome, started: started)
        }
        observeInventory()
        return lifecycle
    }

    func recordAttachmentProgress(phase: String, outcome: String, started: UInt64) {
        diagnosticSink(.attachmentProgress(panel: identity, phase: phase, outcome: outcome,
            waitNanoseconds: DispatchTime.now().uptimeNanoseconds &- started))
    }

    /// One composition path for fresh and restored surfaces. HCSession owns
    /// intent durability and resolve-before-create; callers never send RPCs.
    func attachSurface(launch: HCPanelLaunchSpec, bridge: HCNativeBridge, display: HCDisplayState,
                       replaceEnded: Bool = false) async throws -> any HCAttachment {
        guard ownsLifecycle else { throw HCUnavailableReason.cancelled }
        if let attachment { return attachment }
        if let startTask { return try await startTask.value }
        surfaceEpoch &+= 1
        let epoch = surfaceEpoch
        let task = Task<any HCAttachment, Error> { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var outcome = "cancelled"
            recordAttachmentProgress(phase: "attach", outcome: "started", started: started)
            defer { recordAttachmentProgress(phase: "attach", outcome: outcome, started: started) }
            defer { observeInventory() }
            do {
                var resolved = await session.resolve(identity)
                HCTrace.log("attachSurface.resolved panel=\(identity.panelID.uuidString.prefix(8)) resolved=\(resolved) epoch=\(epoch == surfaceEpoch)")
                guard epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
                publish(resolved)
                // C11H-206: a start that took over (a reveal) while this runtime's own creation was still unlisted
                // waits for it too, instead of failing with nothing left to adopt it.
                resolved = try await awaitOwnCreationListing(resolved, epoch: epoch)
                let isNew: Bool
                if case .new = resolved { isNew = true } else { isNew = false }
                let ended: HCEndEvidence?
                if case .ended(let proof) = resolved { ended = proof }
                else if isNew { ended = migrationEndForFreshIdentity }
                else { ended = nil }
                if (isNew || ended != nil), identity.key != nil,
                   !Self.mayReplaceMissingTerminal(identity.panelID, launch.workspaceID) {
                    HCTrace.log("attachSurface.noReplace panel=\(identity.panelID.uuidString.prefix(8)) resolved=\(resolved)")
                    throw HCUnavailableReason.staleIdentity
                }
                if isNew || (replaceEnded && ended != nil)
                    || (identity.origin == .fresh && identity.key == nil && identity.creationID == nil) {
                    let original = identity
                    let creationID = UUID()
                    // The size gate is a local /bin/sh wrapper; never for another machine.
                    let argv = launch.machine == nil ? bridge.rendering.wrapNewTerminalArgv(launch.argv) : launch.argv
                    var environment = launch.environment
                    // Only an actual new creation allocates. Reattach never
                    // changes panel numbers, ports, or their durable record.
                    if let workspaceID = launch.workspaceID {
                        let allocation = PanelAllocationRegistry.shared.allocationForLaunch(
                            panelId: identity.panelID, workspaceId: workspaceID, outlivesApp: true)
                        guard await PanelAllocationRegistry.shared.waitUntilDurable(allocation) else {
                            throw HCUnavailableReason.intentStoreFailure
                        }
                        guard epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
                        for key in ["C11_PANEL_NUM", "C11_TAB_NUM", "C11_SURFACE_NUM"] {
                            environment[key] = String(allocation.panelNumber)
                        }
                        // Ports are reserved on this Mac only; a remote
                        // terminal keeps its panel number but no port range.
                        for prefix in ["C11_", "CMUX_"] where launch.machine == nil {
                            environment[prefix + "PORT"] = allocation.ports.map { String($0.start) }
                            environment[prefix + "PORT_END"] = allocation.ports.map { String($0.end) }
                            environment[prefix + "PORT_RANGE"] = allocation.ports.map { String($0.size) }
                        }
                    }
                    let request = HCCreateRequest(identity: original, creationID: creationID, argv: argv,
                        cwd: launch.cwd, environment: environment, initialInput: launch.initialInput,
                        machine: launch.machine, shard: launch.shard,
                        labels: launch.workspaceID.map { [HCOwnerLabels.workspace: $0.uuidString] } ?? [:])
                    identity = HCPanelIdentity(panelID: original.panelID, key: original.key,
                        persistence: original.persistence, creationID: creationID, origin: original.origin)
                    publish(.unresolved(identity, .creationPending))
                    diagnosticSink(.panelNew(panel: identity))
                    HCPanelRestoreState.shared.recordCreation(panelID: identity.panelID,
                        creationID: creationID, replacing: ended)
                    onWillCreate?(creationID, ended)
                    let result = await session.create(request)
                    HCTrace.log("attachSurface.created panel=\(identity.panelID.uuidString.prefix(8)) result=\(result)")
                    guard ownsLifecycle, epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
                    // C11H-313: a creation queued behind another of this panel's (a reveal while the
                    // hidden start's creation was still preparing) binds to the terminal that one made.
                    // That creation becomes the panel's, here, in restore state and in the restore
                    // projection, so a later close follows the creation that really ran.
                    var outcomeCreationID = creationID
                    if case .bound(let record) = result,
                       let made = record.labels["c11.creation"].flatMap(UUID.init(uuidString:)), made != creationID {
                        outcomeCreationID = made
                        identity = HCPanelIdentity(panelID: identity.panelID, key: identity.key,
                            persistence: identity.persistence, creationID: made, origin: identity.origin)
                        HCPanelRestoreState.shared.recordCreation(panelID: identity.panelID, creationID: made, replacing: ended)
                        onCreationAdopted?(creationID, made)
                    }
                    HCPanelRestoreState.shared.recordCreationOutcome(panelID: identity.panelID,
                        creationID: outcomeCreationID, result: result)
                    onCreationOutcome?(outcomeCreationID, result)
                    guard epoch == surfaceEpoch, !Task.isCancelled else { throw HCUnavailableReason.cancelled }
                    switch result {
                    case .bound(let record): resolved = .live(record)
                    case .unresolved(_, let reason): resolved = .unresolved(identity, reason)
                    case .rejectedBeforeTransmission(let reason):
                        if reason == .coreUnreachable, launch.machine == nil, original.origin == .fresh,
                           original.key == nil, original.creationID == nil {
                            identity = HCPanelIdentity(panelID: original.panelID, persistence: .nonpersistent, origin: .fresh)
                            // The one place a panel becomes a plain shell, so the one
                            // place the diagnostics are told it did.
                            diagnosticSink(.fallback(panel: identity, configuredBuild: Self.servingBuildForDiagnostics))
                            publish(.new)
                            onFallback?()
                            throw HCUnavailableReason.backendNotInstalled
                        }
                        resolved = .unresolved(identity, reason)
                    }
                    publish(resolved)
                    // C11H-206: hc was sent the creation (an unresolved create always was), but its inventory has
                    // not listed it yet (a loaded Mac). Wait for it rather than give up with nothing retrying.
                    if case .unresolved(_, let reason) = result, Self.awaitsListing(reason) { unlistedCreationID = creationID }
                    resolved = try await awaitOwnCreationListing(resolved, epoch: epoch)
                }
                guard case .live(let record) = resolved else {
                    if case .unresolved(_, let reason) = resolved { throw reason }
                    throw HCUnavailableReason.inventoryPending
                }
                let attached: any HCAttachment
                do {
                    attached = try await session.attach(record.key, sink: bridge, display: display)
                } catch {
                    HCTrace.log("attachSurface.attachFailed panel=\(identity.panelID.uuidString.prefix(8)) error=\(error)")
                    let reason = (error as? HCUnavailableReason) ?? .connectionLost
                    if reason != .cancelled, !Task.isCancelled {
                        diagnosticSink(.attachFailed(panelID: identity.panelID, terminal: record.key.localAddress,
                            servingBuild: Self.servingBuildForDiagnostics,
                            reason: HCDiagnosticTokens.unavailable(reason)))
                    }
                    throw error
                }
                guard epoch == surfaceEpoch, !Task.isCancelled else {
                    attached.detach(); throw HCUnavailableReason.cancelled
                }
                let revision = (attached as? HCPanelAttachment)?.currentDisplayState.revision
                    ?? HCDisplayRevision(attachmentGeneration: attached.generation,
                        displayGeneration: display.revision.displayGeneration)
                guard bind(attached, display: revision) else {
                    HCTrace.log("attachSurface.bindRefused panel=\(identity.panelID.uuidString.prefix(8)) " +
                        "idKey=\(identity.key?.localAddress ?? "nil") attKey=\(attached.key.localAddress) " +
                        "gen=\(attached.generation) displayGen=\(revision.attachmentGeneration)")
                    attached.detach(); throw HCUnavailableReason.staleIdentity
                }
                HCTrace.log("attachSurface.bound panel=\(identity.panelID.uuidString.prefix(8)) gen=\(attached.generation)")
                outcome = "bound"
                return attached
            } catch {
                let reason = (error as? HCUnavailableReason) ?? .connectionLost
                outcome = HCDiagnosticTokens.unavailable(reason)
                if epoch == surfaceEpoch, identity.persistence == .persistent {
                    if reason == .connectionLost || reason == .coreUnreachable { connectionLost(reason) }
                    else if reason != .cancelled {
                        if case .ended = lifecycle {} else { publish(.unresolved(identity, reason)) }
                    }
                }
                throw error
            }
        }
        startTask = task
        defer { if surfaceEpoch == epoch { startTask = nil } }
        do { return try await task.value }
        catch {
            if surfaceEpoch == epoch, !everBound, identity.persistence == .persistent,
               let reason = error as? HCUnavailableReason, reason != .cancelled {
                startTask = nil
                HCTrace.log("attachSurface.initialUnresolved panel=\(identity.panelID.uuidString.prefix(8)) reason=\(reason) " +
                    "coordinator=\(reconnectCoordinator != nil)")
                onInitialAttachUnresolved?(reason)
            }
            throw error
        }
    }

    private func observeInventory() {
        guard ownsLifecycle, observation == nil else { return }
        let deliver: @Sendable (HCInventorySnapshot) -> Void = { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.receiveInventory(snapshot)
            }
        }
        // C11H-238: a pool route delivers only this terminal's changes.
        if let route = session as? any HCInterestObserving {
            observation = route.observe(on: .main, interest: homeInterest, handler: deliver)
        } else {
            observation = session.observe(on: .main, handler: deliver)
        }
    }

    /// Same delivery path for native and hidden panels. Holder loss is an
    /// ended lifecycle for restore/resume UI, never a normal child exit.
    func receiveInventory(_ snapshot: HCInventorySnapshot) {
        guard ownsLifecycle else { return }
        receivingInventory = true
        defer { receivingInventory = false }
        guard case .ready = snapshot.readiness else {
            if case .pending(let reason) = snapshot.readiness {
                // An open but slow core is not a disconnected transport. Keep
                // the current port while inventory is catching up.
                if reason == .connectionLost || reason == .coreUnreachable {
                    connectionLost(reason)
                } else if attachment == nil {
                    publish(.unresolved(identity, reason))
                }
            }
            return
        }
        guard let key = identity.key else {
            // A saved creation can have no terminal key yet. Only the session
            // may reconcile its durable intent/labels; a pending first lookup
            // must not make us ignore the inventory that finally contains it.
            // resolve() republishes its current snapshot. Only new inventory
            // evidence may request another lookup, or a keyless placeholder
            // feeds its own unchanged answer back forever.
            guard hiddenResolutionRevision != snapshot.revision || hiddenResolutionSource != snapshot.source else { return }
            hiddenResolutionRevision = snapshot.revision
            hiddenResolutionSource = snapshot.source
            beginHiddenResolution()
            return
        }
        guard let record = snapshot.records[key] else {
            // Ticket 12: hc may drop a remote mirror while its line is down.
            // Absence is never an end; a live terminal on a machine that is no
            // longer connected is a connection loss, so input stops at once.
            if case .live(let last) = lifecycle, let machine = last.machineName,
               snapshot.machines[machine] != .connected {
                if attachment != nil { connectionLost(.connectionLost) }
                else { publish(.unresolved(identity, .connectionLost)) }
            }
            return
        }
        // During replacement, identity deliberately retains the old key until
        // the new creation is reconciled. Its old finished record must not
        // turn the pending replacement into an ordinary child-exit close.
        if let creationID = identity.creationID,
           let creation = HCPanelRestoreState.shared.entry(for: identity.panelID)?.creation,
           creation.creationID == creationID,
           creation.outcome == .attempted || creation.outcome == .unresolved,
           record.labels["c11.creation"]?.lowercased() != creationID.uuidString.lowercased() {
            return
        }
        // Ticket 12: a terminal on another machine whose line is down. hc keeps
        // the local stream open and drops what is typed into it (audit C6), so
        // the input port is retired now; the reconnect coordinator attaches a
        // fresh, repainted generation when the line is back. Never an end.
        if record.state != .finished, record.machineAvailability == .disconnected || record.machineAvailability == .unknown {
            if attachment != nil { connectionLost(.connectionLost) }
            else if case .unresolved(_, .connectionLost) = lifecycle {}
            else { publish(.unresolved(identity, .connectionLost)) }
            return
        }
        if record.state == .finished {
            // C11H-196: an end is published once. Every inventory revision used
            // to republish it with a fresh evidence id, re-running every observer
            // of every ended panel (38 after the 2026-11-04 reboot) per revision.
            if case .ended(let current) = lifecycle, current.key == key, current.kind == .finished,
               current.hcReason == record.endReason, handledEnd == key { return }
            let evidence = HCEndEvidence(id: UUID(), key: key, revision: snapshot.revision,
                kind: .finished, hcReason: record.endReason, exitCode: record.exitCode, exitSignal: record.exitSignal,
                endedAtMilliseconds: record.finishedMilliseconds)
            publish(.ended(evidence))
            if handledEnd != key {
                handledEnd = key
                // A host-caused end keeps the panel for recovery (T4.3, T4.4).
                // Every other end reaches the child-exit path, which closes the
                // panel unless an outside signal ended an agent (C11H-232).
                if !HCRestoreLifecycleProjection.isHostEnd(record.endReason) { onEnded?(evidence) }
            }
        } else {
            // C11H-238: a shard's revision moves when any of its terminals
            // changes, and every revision used to republish every live panel,
            // re-running each observer (mailbox ownership probes included) for
            // a record nothing touched. Only the current lifecycle counts: an
            // equal record still publishes out of Reconnecting, unresolved or
            // a pending creation, and any field an observer reads is part of
            // the record's equality.
            if case .live(let current) = lifecycle, current == record { return }
            publish(.live(record))
        }
    }

    /// Convergence's end is recovery evidence, not a dead key handed to the
    /// new core. Only a keyless, unattempted creation can project `.new` to
    /// `.ended`; uncertainty, a survivor and a replacement keep HC's answer.
    private var migrationEndForFreshIdentity: HCEndEvidence? {
        guard identity.origin == .restored, identity.persistence == .persistent,
              identity.key == nil, identity.creationID == nil else { return nil }
        return HCPanelRestoreState.shared.entry(for: identity.panelID)?.migrationEnd
    }

    func publish(_ observed: HCLifecycle) {
        guard ownsLifecycle else { return }
        let resolved: HCLifecycle = {
            if case .new = observed, let proof = migrationEndForFreshIdentity { return .ended(proof) }
            return observed
        }()
        lifecycleEpoch &+= 1
        if case .live(let record) = resolved {
            lastLiveRecord = record
            identity = HCPanelIdentity(panelID: identity.panelID, key: record.key,
                persistence: identity.persistence, creationID: identity.creationID, origin: identity.origin)
        }
        lifecycle = resolved
        diagnose(resolved)
        registerIdentity()
        HCPanelRestoreState.shared.publish(identity: identity, lifecycle: resolved)
        if let entry = HCPanelRestoreState.shared.entry(for: identity.panelID) { onLifecycleChanged?(entry) }
        // C11H-238: a live record published from outside the inventory (a
        // resolve, a creation, a reattach that resolved before awaiting its
        // attachment) can be older than what the inventory delivered since.
        // The inventory no longer republishes every revision, so ask for its
        // newest snapshot again; an equal record publishes nothing.
        if case .live = resolved, !receivingInventory { homeInterest.reconcile() }
    }

    /// True while `receiveInventory` runs (its own publishes need no reconcile).
    private var receivingInventory = false

    /// Panel events for `hc-diagnostics`. The recorder also reads the session's
    /// published panel bindings; these events add what a snapshot cannot say:
    /// attaches, failures, creations and outages. An unreachable core is reported
    /// as unresolved, never as a fallback (only the fallback branch of
    /// `attachSurface` knows a panel became a plain shell). An outage or ended
    /// terminal is reported once per occurrence, not once per snapshot.
    private func diagnose(_ lifecycle: HCLifecycle) {
        let state: String
        let event: HCDiagnosticEvent
        switch lifecycle {
        case .unresolved(_, .coreUnreachable):
            state = "unreachable"
            event = .coreUnresolved(panel: identity, configuredBuild: Self.servingBuildForDiagnostics)
        case .ended(let evidence):
            // The evidence id is new on every snapshot; the terminal is the occurrence.
            state = "ended:" + (evidence.key.map { "\($0.owningCoreID)/\($0.localAddress)" } ?? "-")
            event = .panelEnded(panelID: identity.panelID, reason: evidence.hcReason)
        case .live:
            lastDiagnosed = nil
            return
        default:
            return
        }
        guard lastDiagnosed != state else { return }
        lastDiagnosed = state
        diagnosticSink(event)
    }

    /// A bound attachment exists only on a connection `HCManagedSession`
    /// verified against the configured pin, so that pin is the serving build.
    private static var servingBuildForDiagnostics: String { HCPin.current.version }

    private func diagnoseAttach(_ attachment: any HCAttachment, reattach: Bool) {
        lastDiagnosed = nil
        var tty: String?
        if case .live(let record) = lifecycle { tty = record.tty }
        let panelID = identity.panelID, terminal = attachment.key.localAddress
        let build = Self.servingBuildForDiagnostics
        diagnosticSink(reattach
            ? .reattach(panelID: panelID, terminal: terminal, servingBuild: build, tty: tty)
            : .attach(panelID: panelID, terminal: terminal, servingBuild: build, tty: tty))
    }

    func bind(_ attachment: any HCAttachment, display: HCDisplayRevision) -> Bool {
        guard identity.key == attachment.key, display.attachmentGeneration == attachment.generation else { return false }
        // A late attachment cannot revive the last live record over a known end.
        if case .ended(let evidence) = lifecycle, evidence.key == attachment.key { return false }
        self.attachment?.detach()
        inputEpoch &+= 1
        self.attachment = attachment
        boundGeneration = attachment.generation
        diagnoseAttach(attachment, reattach: everBound)
        everBound = true
        lastDisplayRevision = display
        if inputFault != nil {
            attachment.input.invalidate(generation: attachment.generation, reason: .inputFault)
        }
        if let currentDisplayState { onAttachmentBound?(attachment, currentDisplayState) }
        HCTrace.log("bind panel=\(identity.panelID.uuidString.prefix(8)) gen=\(attachment.generation) " +
            "policyBound=\(disconnectedInput?.isBound(to: attachment) == true)")
        if let pending = pendingInitialFault {
            pendingInitialFault = nil
            Task { @MainActor [weak self] in self?.recordInputOutcome(pending) }
        }
        return true
    }

    func updateDisplayState(_ display: HCDisplayState) {
        guard display.revision.attachmentGeneration == attachment?.generation else { return }
        lastDisplayRevision = display.revision
        onDisplayChanged?(display)
    }

    func updateDisplayRevision(_ revision: HCDisplayRevision) {
        guard revision.attachmentGeneration == attachment?.generation else { return }
        lastDisplayRevision = revision
    }

    /// Ticket 12: this panel's live record once its terminal exists, waiting
    /// up to `seconds` (a remote launch sends its prompt there first). Nil
    /// when it ends or does not bind in time.
    func liveRecord(within seconds: TimeInterval) async -> HCTerminalRecord? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            switch lifecycle {
            case .live(let record): return record
            case .ended: return nil
            default: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return nil
    }

    func connectionLost(_ reason: HCUnavailableReason) {
        inputEpoch &+= 1
        if let attachment { attachment.input.invalidate(generation: attachment.generation, reason: .unavailable) }
        // The port is gone: the policy stops treating it as bound, so a send now
        // waits for the replacement instead of reaching a closed port (C11H-82).
        disconnectedInput?.disconnect()
        publish(.unresolved(identity, reason))
        if let attachment { onAttachmentLoss?(attachment.generation, reason) }
        onConnectionLoss?(reason)
    }

    func recordInputOutcome(_ outcome: HCInputOutcome) {
        let isFault: Bool
        // The port an interruption belongs to. An uncertain write names its own,
        // which a reattach may already have replaced (C11H-124). A paused port
        // refusing a key is the pause itself, not a new interruption.
        var interrupted: UInt64?
        var isNewFault = false
        switch outcome {
        case .uncertain(let receipt):
            isFault = true; isNewFault = true; interrupted = receipt.attachmentGeneration
        case .refused(.inputFault):
            isFault = true; isNewFault = inputFault == nil; interrupted = attachment?.generation
        default: isFault = false
        }
        // The backend may finish initial input before attach returns to this
        // runtime. Retain only its outcome metadata until the port is adopted.
        if isFault, !everBound, attachment == nil {
            pendingInitialFault = outcome
            return
        }
        if isNewFault {
            inputEpoch &+= 1
            noteInterruption(at: interrupted)
            inputFault = .inputFault
            if let attachment { attachment.input.invalidate(generation: attachment.generation, reason: .inputFault) }
        }
        onInputOutcome?(outcome)
        if isFault { onInputFault?(.inputFault) }
    }

    /// Programmatic input (socket, text box, paste, feed, mailbox, launch, resume).
    /// HCDisconnectedInput stages replacements while old submits are pending and
    /// records each outcome once, so the attachment does not also report these
    /// (only backend-owned initial input reports through `recordInputOutcome`).
    /// This adds the runtime's own fault latch, keyed to the submitted generation
    /// because a policy-requested reattach can drop the attachment first.
    func submitInput(_ request: HCInputRequest) async -> HCInputOutcome {
        guard let policy = disconnectedInput else { return .refused(.unavailable) }
        let generation = request.attachmentGeneration
        let outcome = await policy.submit(request)
        switch outcome {
        case .uncertain(let receipt):
            latchInputFault(generation: receipt.attachmentGeneration)
        case .refused(.inputFault) where inputFault == nil:
            latchInputFault(generation: generation)
        default:
            break
        }
        return outcome
    }

    private func latchInputFault(generation: UInt64?) {
        inputEpoch &+= 1
        noteInterruption(at: generation)
        inputFault = .inputFault
    }

    /// Records the port an interruption belongs to (call before setting
    /// `inputFault`). A newer port's interruption raises it, never lowers it:
    /// Retry input then needs a port newer than every interrupted one.
    private func noteInterruption(at generation: UInt64?) {
        // A fault reported after a detach has no port left to name; the last bound
        // one is where it happened (lastDisplayRevision follows every bind).
        guard let generation = generation ?? attachment?.generation
                ?? (everBound ? lastDisplayRevision.attachmentGeneration : nil) else { return }
        if inputFault == nil || interruptedGeneration == nil {
            interruptedGeneration = generation
        } else if let current = interruptedGeneration {
            interruptedGeneration = max(current, generation)
        }
    }

    func inputInterrupted(_ reason: HCInputRefusal = .inputFault) {
        inputEpoch &+= 1
        noteInterruption(at: attachment?.generation)
        inputFault = reason
        if let attachment { attachment.input.invalidate(generation: attachment.generation, reason: reason) }
        onInputFault?(reason)
    }

    /// Explicit Retry input. A stale caller-supplied receipt is insufficient:
    /// ask the currently bound parser again and require the same screen. The
    /// port's fault token is read here, not when the port was bound: a pause
    /// can land after the bind, and a key typed while paused must not strand it.
    /// Returns the refusing guard, or nil once the port is open to new input.
    func clearInputFault(using receipt: HCScreenReceipt) async -> HCRetryRefusal? {
        let faultEpoch = inputEpoch
        guard inputFault != nil else { return HCRetryRefusal(.stateMismatch, "runtime.notFaulted") }
        guard let attachment else { return HCRetryRefusal(.reconnecting, "runtime.noAttachment") }
        guard let native = attachment as? HCPanelAttachment else {
            return HCRetryRefusal(.stateMismatch, "runtime.portKind", "port=\(attachment.generation)")
        }
        guard let interruptedGeneration else { return HCRetryRefusal(.stateMismatch, "runtime.noInterruptedGeneration") }
        guard receipt.revision.attachmentGeneration == attachment.generation else {
            return HCRetryRefusal(.connectionChanged, "runtime.receiptGeneration",
                                  "receipt=\(receipt.revision.logText) port=\(attachment.generation)")
        }
        guard receipt.revision == currentDisplayRevision else {
            return HCRetryRefusal(.screenNotSettled, "runtime.receiptRevision",
                                  "receipt=\(receipt.revision.logText) display=\(currentDisplayRevision.logText)")
        }
        guard let fresh = await attachment.screenCurrent(after: currentDisplayRevision) else {
            return HCRetryRefusal(.screenNotSettled, "runtime.screenUnavailable", "display=\(currentDisplayRevision.logText)")
        }
        // Same revision and grid. Output parsed in between moves only the
        // watermark, and a busy terminal is still a healthy one.
        guard fresh.revision == receipt.revision, fresh.columns == receipt.columns, fresh.rows == receipt.rows else {
            return HCRetryRefusal(.screenNotSettled, "runtime.freshReceipt",
                "fresh=\(fresh.revision.logText) \(fresh.columns)x\(fresh.rows) " +
                "receipt=\(receipt.revision.logText) \(receipt.columns)x\(receipt.rows)")
        }
        guard self.attachment === attachment else {
            return HCRetryRefusal(.connectionChanged, "runtime.attachmentChanged",
                "port=\(self.attachment.map { String($0.generation) } ?? "nil") expected=\(attachment.generation)")
        }
        guard inputEpoch == faultEpoch else {
            return HCRetryRefusal(.newInterruption, "runtime.inputEpoch", "epoch=\(inputEpoch) expected=\(faultEpoch)")
        }
        guard currentDisplayRevision == receipt.revision else {
            return HCRetryRefusal(.screenNotSettled, "runtime.displayMoved",
                                  "display=\(currentDisplayRevision.logText) receipt=\(receipt.revision.logText)")
        }
        guard !Task.isCancelled else { return HCRetryRefusal(.reconnecting, "runtime.cancelled") }
        guard let faultToken = native.coordinator.gate.faultToken else {
            return HCRetryRefusal(.stateMismatch, "runtime.portNotFaulted", "port=\(attachment.generation)")
        }
        if let refusal = native.coordinator.clearInputFault(receipt: receipt,
                                                            interruptedGeneration: interruptedGeneration,
                                                            faultToken: faultToken) {
            return refusal
        }
        inputFault = nil
        self.interruptedGeneration = nil
        inputEpoch &+= 1
        return nil
    }

    /// A reattach replaces the native surface, so the attachment bound to the old
    /// one is dead (its bridge is retired). Release it first: `attachSurface`
    /// returns the bound attachment when there is one, and after a core restart the
    /// surface's own start can bind an attachment just before the reconnect owner
    /// retires that surface, which handed the dead attachment straight back and
    /// left the panel refusing every key as `staleIdentity` (C11H-82, F13).
    func prepareReattach() {
        detachSurface(forReattach: true)
    }

    func detachSurface(forReattach: Bool = false) {
        surfaceEpoch &+= 1
        startTask?.cancel()
        startTask = nil
        inputEpoch &+= 1
        attachment?.input.invalidate(generation: attachment?.generation ?? 0, reason: .staleIdentity)
        let detachedGeneration = attachment?.generation
        attachment?.detach()
        attachment = nil
        if let detachedGeneration { onAttachmentDetached?(detachedGeneration) }
        if !forReattach {
            // Only the panel's current runtime clears its registration; a
            // replacement runtime has already registered its own identity.
            if ownsLifecycle {
                registeredIdentity = nil
                registrar(nil, identity.panelID)
            }
            disposed = true
            hiddenResolution?.cancel()
            hiddenResolution = nil
            observation?.cancel()
            observation = nil
            HCPanelRestoreState.shared.release(panelID: identity.panelID, owner: runtimeOwner)
            onSurfaceDisposed?()
        }
    }

    /// The terminal the reconnect owner is bound to; nil when it has none.
    var reconnectOwnerKey: HCTerminalKey? { reconnectCoordinator?.identity.key }
    #if DEBUG
    var reconnectAttemptForTesting: Task<Void, Never>? { reconnectCoordinator?.pendingAttemptForTesting }
    #endif

    /// First step of replacing an `.ended` terminal in the same panel. The
    /// reconnect owner is bound to the dead terminal's key and attachment: it
    /// would publish `staleIdentity` into the replacement and never reattach
    /// it. Retire it here so the replacement's bind installs a fresh owner for
    /// the new key. Plain reattach of the same terminal keeps its owner and
    /// uses `detachSurface(forReattach:)` directly. Refuses unless ended.
    @discardableResult
    func prepareEndedReplacement() -> Bool {
        guard ownsLifecycle, case .ended = lifecycle else { return false }
        let owner = reconnectCoordinator
        reconnectCoordinator = nil
        owner?.stop()
        detachSurface(forReattach: true)
        return true
    }

    func endSession() async -> HCEndResult? {
        guard let key = identity.key else { return nil }
        let result = await session.end(key)
        if case .confirmed(let evidence) = result { publish(.ended(evidence)) }
        return result
    }
}

/// Diagnostic persistence never runs on the main actor. Installation and launch
/// facts are rare lifecycle events; transport owns its separate bounded worker.
enum HCCompositionDiagnostics {
    static let queue = DispatchQueue(label: "c11.composition.diagnostics", qos: .utility)
    /// The recorder watches the session's snapshots and is told which panels the
    /// app knows (their persistence, creation and origin) for each one. The
    /// recorder is a parameter so a test can prove that hookup against a temp one.
    /// `shard` names the hc session this is (the pool calls this once per shard).
    static func install(_ session: any HCSession,
                        shard: HCShardIdentity = .legacyDefault,
                        shardOf: (@Sendable (HCPanelIdentity) -> HCShardIdentity?)? = nil,
                        recorder: HCDiagnosticRecorder = .shared) {
        queue.async {
            recorder.install(session, shard: shard, panels: { HCPanelRestoreState.shared.identities() }, shardOf: shardOf)
        }
    }
    static func record(_ event: HCDiagnosticEvent) {
        queue.async { HCDiagnosticRecorder.shared.record(event) }
    }
}

private struct HCDiagnosticLauncher: HCCoreLaunching {
    let base: any HCCoreLaunching
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        let limits = try await base.start(configuration, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
        HCCompositionDiagnostics.record(.fileLimit(soft: limits.afterSoft, hard: limits.hard,
            kernelCap: limits.kernelCap, beforeSoft: limits.beforeSoft))
        return limits
    }
}
