import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// One shard's core as the pool sees it. "Started" means a core would have
/// been launched: any resolve or create (connectIfServing only when serving).
private actor HCFakeShard: HCShardSession, HCCreationSettling {
    let index: Int
    let coreID: String
    nonisolated let feed = HCSessionFeed()
    private(set) var records: [HCTerminalKey: HCTerminalRecord] = [:]
    private(set) var calls: [String] = []
    private(set) var started = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var nextAddress = 1
    private var bindings: [UUID: HCTerminalKey] = [:]
    /// C11H-391: the machine lines this shard's core reports.
    private var machines: [String: HCMachineAvailability] = [:]
    private var pendingReason: HCUnavailableReason?
    var serving = false
    /// A shard whose core cannot start.
    var failing = false
    /// The shard's real durable intent store: resolve then runs the real
    /// lifecycle resolver over it, and create claims there first.
    var store: HCCreationIntentStore?
    /// create claims, then loses its connection before the run is sent.
    var rejectAfterClaim = false
    /// refresh() returns the state of its start, after `releaseRefresh()`.
    private var heldRefresh: CheckedContinuation<Void, Never>?
    var holdRefresh = false
    var refreshHeld: Bool { heldRefresh != nil }
    /// C11H-356: create sends the run, and its terminal is in the inventory still starting, so
    /// the creation answers unresolved (creationPending), as a real session's may.
    var createsStarting = false

    init(index: Int) {
        self.index = index
        coreID = "core-\(index)"
    }

    private var current: HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: sequence)
        return HCInventorySnapshot(readiness: pendingReason.map { .pending($0) } ?? (started ? .ready(revision) : .pending(.backendNotInstalled)),
            revision: revision, records: records, buildIdentity: started ? identity : nil, panelBindings: bindings,
            machines: machines)
    }

    private var identity: HCBuildIdentity {
        HCBuildIdentity(pin: .current, executablePath: "/hc", fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1,
            modifiedSeconds: 1, modifiedNanoseconds: 0), process: HCProcessIdentity(pid: Int32(100 + index), startTimeMicroseconds: 1),
            coreID: coreID, protocolGeneration: 1)
    }

    private func start() {
        guard !started else { return }
        started = true
        generation = 1
        publish()
    }

    private func publish() {
        sequence += 1
        feed.publish(current)
    }

    func setServing(_ value: Bool) { serving = value }
    /// C11H-391: this shard's core links these machines.
    func setMachines(_ value: [String: HCMachineAvailability]) { start(); machines = value; publish() }
    /// A binding this shard's session learned (it keeps it after the terminal ends).
    func bind(_ panel: UUID, _ key: HCTerminalKey) { bindings[panel] = key; publish() }
    func setFailing(_ value: Bool) { failing = value }
    func use(store: HCCreationIntentStore, rejectAfterClaim: Bool = false) {
        self.store = store
        self.rejectAfterClaim = rejectAfterClaim
    }
    func setHoldRefresh(_ value: Bool) { holdRefresh = value }
    func releaseRefresh() { heldRefresh?.resume(); heldRefresh = nil }
    func setCreatesStarting(_ value: Bool) { createsStarting = value }

    /// A terminal that was already running in this shard's core; `creation` stamps
    /// `c11.creation` beside `c11.panel`, as a real session's creation does.
    @discardableResult
    func seedLive(panel: UUID?, state: HCTerminalState = .running, creation: UUID? = nil) -> HCTerminalKey {
        start()
        let key = HCTerminalKey(owningCoreID: coreID, localAddress: "t\(nextAddress)")
        nextAddress += 1
        var labels = panel.map { ["c11.panel": $0.uuidString] } ?? [:]
        if let creation { labels["c11.creation"] = creation.uuidString }
        records[key] = HCTerminalRecord(key: key, state: state, labels: labels, pid: state == .finished ? nil : 42)
        publish()
        return key
    }

    /// The terminal leaves the inventory (hc's `keep: false` after it ends).
    func remove(_ key: HCTerminalKey) { records.removeValue(forKey: key); publish() }

    /// A new revision of the same state.
    func republish() { publish() }

    func finish(_ key: HCTerminalKey, reason: String = "exit") {
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .finished, labels: record.labels, endReason: reason)
        publish()
    }

    func goPending(_ reason: HCUnavailableReason) {
        pendingReason = reason
        generation += 1
        publish()
    }

    func clearPending() { pendingReason = nil; publish() }

    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func snapshot() async -> HCInventorySnapshot { current }
    func refresh() async -> HCInventorySnapshot {
        let read = current
        if holdRefresh { await withCheckedContinuation { heldRefresh = $0 } }
        return read
    }

    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        calls.append("resolve")
        if failing { return .unresolved(identity, .coreUnreachable) }
        start()
        if let store {
            let intent: HCStoredCreation?
            do { intent = try await store.read(panelID: identity.panelID) }
            catch { return .unresolved(identity, .intentStoreFailure) }
            return HCLifecycleResolver.resolve(identity, snapshot: current, intent: intent)
        }
        if let key = identity.key {
            guard let record = records[key] else {
                return key.owningCoreID == coreID
                    ? .ended(HCEndEvidence(id: UUID(), key: key, revision: current.revision, kind: .observedRemoval))
                    : .unresolved(identity, .connectionLost)
            }
            return record.state == .finished
                ? .ended(HCEndEvidence(id: UUID(), key: key, revision: current.revision, kind: .finished))
                : .live(record)
        }
        if let record = records.values.first(where: { $0.labels["c11.panel"] == identity.panelID.uuidString && $0.state != .finished }) {
            return .live(record)
        }
        return .new
    }

    func create(_ request: HCCreateRequest) async -> HCCreateResult {
        calls.append("create")
        if failing { return .rejectedBeforeTransmission(.coreUnreachable) }
        start()
        if let store, rejectAfterClaim {
            _ = try? await store.claim(request, coreID: coreID, process: identity.process)
            let refused = HCEndEvidence(id: UUID(), creationID: request.creationID, revision: current.revision, kind: .createRejected)
            try? await store.recordEnd(panelID: request.identity.panelID, creationID: request.creationID, evidence: refused)
            return .rejectedBeforeTransmission(.connectionLost)
        }
        if let key = request.identity.key, key.owningCoreID != coreID {
            // A real session resolves before creating: another core's key is unresolved here.
            return .unresolved(request.identity, .creationPending)
        }
        if createsStarting {
            seedLive(panel: request.identity.panelID, state: .starting, creation: request.creationID)
            return .unresolved(request.identity, .creationPending)
        }
        let key = seedLive(panel: request.identity.panelID)
        return .bound(records[key]!)
    }

    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        calls.append("attach")
        throw HCUnavailableReason.backendNotInstalled
    }

    nonisolated func declineCreations(panelID: UUID, carrying creationID: UUID?) {}
    nonisolated func observeCreationSettlements(on queue: DispatchQueue,
                                                handler: @escaping @Sendable (UUID) -> Void) -> HCObservation { HCObservation() }
    func recordedNeverRun(_ identity: HCPanelIdentity) async -> HCEndEvidence? {
        guard let store, let intent = try? await store.read(panelID: identity.panelID) else { return nil }
        return HCLifecycleResolver.neverRan(identity, intent: intent)
    }

    func recordNeverRun(_ request: HCCreateRequest) async {
        calls.append("never-run")
        if let store { _ = try? await store.recordNeverRun(request, coreID: coreID, process: identity.process, revision: current.revision) }
    }

    func end(_ key: HCTerminalKey) async -> HCEndResult {
        calls.append("end")
        ended.append(key)
        finish(key)
        return .pending(key)
    }

    /// C11H-359 (L2): every key this shard was asked to end.
    private(set) var ended: [HCTerminalKey] = []

    /// A linked machine's terminal as this shard's inventory mirrors it, under
    /// whatever core id that machine reported.
    func seedMirrored(_ key: HCTerminalKey, machine: String) {
        start()
        records[key] = HCTerminalRecord(key: key, state: .running, labels: [:], machineName: machine,
                                        machineAvailability: .connected, pid: 7)
        publish()
    }

    func diagnostics() async -> HCDiagnostics { HCDiagnostics(inventory: current) }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }

    func connectIfServing() async -> Bool {
        guard serving else { return false }
        start()
        return true
    }
}

extension HCFakeShard: HCFileTransfer {
    func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String {
        calls.append("put \(key.localAddress) \(name) \(data.count)")
        return "/shard-\(index)/\(name)"
    }
}

extension HCFakeShard: HCTerminalLabeling {
    func setLabels(_ labels: [String: String], on key: HCTerminalKey) async -> Bool {
        calls.append("label \(key.localAddress) \(labels.keys.sorted().joined(separator: ","))")
        return true
    }
}

private final class HCStartedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class HCCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HCInventorySnapshot] = []
    func add(_ value: HCInventorySnapshot) { lock.lock(); values.append(value); lock.unlock() }
    var all: [HCInventorySnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class HCShardPoolTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hc-shards-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    private func makePool(_ fakes: [HCFakeShard], placement: HCShardPlacement,
                          intents: [Int: HCCreationIntentStore] = [:], placementEnabled: Bool = true) throws -> HCShardPool {
        let shards = try fakes.map { fake -> HCShard in
            var configuration = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index, inherited: [:])
            if intents[fake.index] != nil {
                configuration = HCLaunchConfiguration(executableURL: configuration.executableURL, session: configuration.session,
                    socketURL: configuration.socketURL, stateDirectory: configuration.stateDirectory,
                    intentDirectory: temporary.appendingPathComponent(configuration.session),
                    environment: configuration.environment, pin: configuration.pin)
            }
            return HCShard(index: fake.index, configuration: configuration, session: fake, intents: intents[fake.index])
        }
        return HCShardPool(shards: shards, placement: placement, placementEnabled: placementEnabled)
    }

    private func fakes() -> [HCFakeShard] { (0...HCShardPool.size).map { HCFakeShard(index: $0) } }

    /// C11H-391: an app that adopted c11h's sessions: the pool in c11h's names
    /// (`c11h`, `c11h-s1`...) plus c11's own shard 0 as the links session.
    private func makeAdoptedPool(_ fakes: [HCFakeShard], placement: HCShardPlacement) throws -> HCShardPool {
        let record = C11AdoptionRecord(owner: "com.stage11.c11")
        let members = Dictionary(uniqueKeysWithValues: try HCBackendComposition.memberConfigurations(
            home: home, tag: nil, inherited: [:], namespace: record))
        let shards = try fakes.map { fake -> HCShard in
            HCShard(index: fake.index, configuration: try XCTUnwrap(members[fake.index]), session: fake, intents: nil)
        }
        return HCShardPool(shards: shards, placement: placement)
    }

    private func adoptedFakes() -> [HCFakeShard] { fakes() + [HCFakeShard(index: HCShardID.links.index)] }

    private func identity(_ lifecycle: HCLifecycle) -> HCTerminalKey? {
        if case .live(let record) = lifecycle { return record.key }
        return nil
    }

    private func boundKey(_ result: HCCreateResult) -> HCTerminalKey? {
        if case .bound(let record) = result { return record.key }
        return nil
    }

    /// The fresh-panel path of HCPanelSession: start (target), resolve, create.
    private func open(panel: UUID, workspace: UUID, machine: String? = nil, in pool: HCShardPool) async -> HCTerminalKey? {
        guard let target = pool.creationTarget(panelID: panel, workspaceID: workspace, machine: machine) else { return nil }
        let route = pool.route(panelID: panel)
        let fresh = HCPanelIdentity(panelID: panel, origin: .fresh)
        guard case .new = await route.resolve(fresh) else { return nil }
        let result = await route.create(HCCreateRequest(identity: fresh, creationID: UUID(), argv: ["/bin/zsh"],
                                                         machine: machine, shard: target.id))
        return boundKey(result)
    }

    // MARK: Files (C11H-105)

    /// A panel's session is a route; a file sent to its terminal reaches the
    /// shard that holds the terminal, through the same cast the app's remote
    /// launch prompt and file drop use.
    func testAFileSentThroughAPanelsRouteReachesTheShardThatHoldsItsTerminal() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let panel = UUID()
        let opened = await open(panel: panel, workspace: UUID(), in: pool)
        let key = try XCTUnwrap(opened)
        let session: any HCSession = pool.route(panelID: panel)
        let transfer = try XCTUnwrap(session as? any HCFileTransfer, "a route must carry files")
        let landed = try await transfer.put(key, name: "prompt.md", data: Data("go".utf8))
        let owner = try XCTUnwrap(shards.first { $0.coreID == key.owningCoreID })
        XCTAssertEqual(landed, "/shard-\(owner.index)/prompt.md")
        let ownerCalls = await owner.calls
        XCTAssertTrue(ownerCalls.contains("put \(key.localAddress) prompt.md 2"), "\(ownerCalls)")
        for other in shards where other.index != owner.index {
            let calls = await other.calls
            XCTAssertFalse(calls.contains { $0.hasPrefix("put") }, "shard \(other.index) got a file that was not its terminal's")
        }
    }

    /// C11H-103: a label write through a panel's route reaches the shard
    /// that holds its terminal, and no other.
    func testALabelWriteThroughAPanelsRouteReachesTheShardThatHoldsItsTerminal() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let panel = UUID()
        let opened = await open(panel: panel, workspace: UUID(), in: pool)
        let key = try XCTUnwrap(opened)
        let session: any HCSession = pool.route(panelID: panel)
        let labeling = try XCTUnwrap(session as? any HCTerminalLabeling)
        let sent = await labeling.setLabels([HCOwnerLabels.title: "T-8 Review"], on: key)
        XCTAssertTrue(sent)
        for shard in shards {
            let calls = await shard.calls
            XCTAssertEqual(calls.contains("label \(key.localAddress) \(HCOwnerLabels.title)"), shard.coreID == key.owningCoreID)
        }
    }

    // MARK: Links session (C11H-391)

    /// While adopted, a machine the links session links usably gets its new
    /// terminals there, whatever the workspace: usable wins over c11h's old
    /// link of the same name. A local terminal never lands there, and a
    /// machine only c11h links stays on shard 0 (where `--on` refuses it).
    func testALinksSessionTakesTheRemoteTerminalsItLinksUsablyAndNoWorkspace() async throws {
        let shards = adoptedFakes()
        let pool = try makeAdoptedPool(shards, placement: HCShardPlacement())
        let links = try XCTUnwrap(pool.links)
        XCTAssertEqual(links.name, "c11")
        XCTAssertEqual(pool.shard(0)?.name, "c11h")
        let unusable = HCUnusableBox(["c11h": ["far"]])
        pool.unusableLinks = { unusable.value }
        await shards[0].setMachines(["far": .connected, "cube": .connected])
        await shards[HCShardID.links.index].setMachines(["far": .connected])
        let merged = await pool.snapshot()
        XCTAssertEqual(merged.sessionMachines.map(\.session), ["c11h", "c11"], "each session's own lines, in shard order")
        let workspace = UUID()
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: workspace, machine: "far")?.index, links.index)
        let opened = await open(panel: UUID(), workspace: workspace, machine: "far", in: pool)
        XCTAssertEqual(opened?.owningCoreID, "core-\(links.index)", "the links session's core runs it")
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: workspace, machine: "cube")?.index, 0,
                       "a machine only c11h links stays where it was")
        // Usable wins the other way too: the links session's link unusable, c11h's usable.
        unusable.value = ["c11": ["far"]]
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: workspace, machine: "far")?.index, 0)
        XCTAssertFalse(pool.placementCandidates.contains(links.index))
        for _ in 0..<12 {
            XCTAssertNotEqual(pool.creationTarget(panelID: UUID(), workspaceID: UUID(), machine: nil)?.index, links.index,
                              "no workspace is placed in the links session")
        }
        let quit = await pool.stopAllForQuit(deadlineUptimeNanoseconds: HCMonotonic.deadline(after: 1))
        XCTAssertNotNil(quit[links.index], "quit stops the links session's core too when terminals don't outlive it")
    }

    // MARK: C11H-396: creation follows the routed usable link

    /// The preflight admits a name when its routed link is usable; the pool
    /// then sends the creation through a usable link, whatever the pairing
    /// file (C11H-78, SH4) chose. A workspace's paired shard that links the
    /// machine unusably gives way to shard 0's usable link; shard 0's
    /// unusable link gives way to a pool shard's usable one; a paired shard
    /// that links it usably keeps its pairing, and so does one not started yet.
    func testARemoteCreationGoesThroughAUsableLinkWhateverThePairingChose() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let names = try (0...3).map { try XCTUnwrap(pool.shard($0)).name }
        pool.pairedWith = { machine, session in machine == "studio" && [names[1], names[3]].contains(session) }
        let unusable = HCUnusableBox([names[1]: ["studio"]])
        pool.unusableLinks = { unusable.value }
        for index in 0...2 { await shards[index].setMachines(["studio": .connected]) }
        let merged = await pool.snapshot()
        func admitted() -> Bool { !HCMachineLinkView.of(merged, unusableBySession: unusable.value).unusable.contains("studio") }

        let paired = UUID()
        pool.placement.seed(workspace: paired, shard: 1)
        XCTAssertTrue(admitted(), "the preflight admits studio: shard 0's link is usable")
        let viaShard0 = await open(panel: UUID(), workspace: paired, machine: "studio", in: pool)
        XCTAssertEqual(viaShard0?.owningCoreID, "core-0", "never the paired shard's unusable link")

        unusable.value = [:]
        let viaPairing = await open(panel: UUID(), workspace: paired, machine: "studio", in: pool)
        XCTAssertEqual(viaPairing?.owningCoreID, "core-1", "a paired shard that links it usably keeps its pairing")

        unusable.value = [names[0]: ["studio"], names[1]: ["studio"]]
        XCTAssertTrue(admitted(), "the preflight admits studio: shard 2's link is usable")
        let unpaired = UUID()
        pool.placement.seed(workspace: unpaired, shard: 2)
        let viaShard2 = await open(panel: UUID(), workspace: unpaired, machine: "studio", in: pool)
        XCTAssertEqual(viaShard2?.owningCoreID, "core-2", "an unpaired workspace's terminal never takes shard 0's unusable link")

        let cold = UUID()
        pool.placement.seed(workspace: cold, shard: 3)
        let viaCold = await open(panel: UUID(), workspace: cold, machine: "studio", in: pool)
        XCTAssertEqual(viaCold?.owningCoreID, "core-3", "a paired shard not started yet keeps its pairing")
    }

    /// C11H-396 (Astra 1 on #390): with no pairing file, shard 0 is only the
    /// fallback, so while it hasn't started it never wins over the usable
    /// link the preflight admitted: only S2 started and links studio, and an
    /// unpaired workspace's terminal on studio is S2's.
    func testAColdShardZeroNobodyPairedGivesWayToTheKnownUsableLink() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        XCTAssertNil(pool.pairedWith, "no pairing file")
        pool.unusableLinks = { [:] }
        await shards[2].setMachines(["studio": .connected])
        let merged = await pool.snapshot()
        XCTAssertFalse(HCMachineLinkView.of(merged, unusableBySession: [:]).unusable.contains("studio"), "the preflight admits studio")
        XCTAssertEqual(pool.route(machine: "studio")?.shard.index, 2)
        let opened = await open(panel: UUID(), workspace: UUID(), machine: "studio", in: pool)
        XCTAssertEqual(opened?.owningCoreID, "core-2", "never shard 0, whose link is not known")
    }

    /// C11H-396 (Opus NB5 on #390): a paired shard whose link to the machine
    /// is down gives way to a routed usable link that is up, the one the
    /// preflight checked; the pairing still holds while that link is down too.
    func testAPairedShardWhoseLinkIsDownGivesWayToARoutedLinkThatIsUp() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let paired = try XCTUnwrap(pool.shard(1)).name
        pool.pairedWith = { machine, session in machine == "studio" && session == paired }
        pool.unusableLinks = { [:] }
        await shards[0].setMachines(["studio": .connected])
        await shards[1].setMachines(["studio": .disconnected])
        _ = await pool.snapshot()
        let workspace = UUID()
        pool.placement.seed(workspace: workspace, shard: 1)
        let opened = await open(panel: UUID(), workspace: workspace, machine: "studio", in: pool)
        XCTAssertEqual(opened?.owningCoreID, "core-0", "the routed link that is up")
    }

    func testAPairedShardWhoseLinkIsDownKeepsItsPairingWhileTheRoutedLinkIsDownToo() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let paired = try XCTUnwrap(pool.shard(1)).name
        pool.pairedWith = { machine, session in machine == "studio" && session == paired }
        pool.unusableLinks = { [:] }
        await shards[0].setMachines(["studio": .disconnected])
        await shards[1].setMachines(["studio": .disconnected])
        _ = await pool.snapshot()
        let workspace = UUID()
        pool.placement.seed(workspace: workspace, shard: 1)
        let opened = await open(panel: UUID(), workspace: workspace, machine: "studio", in: pool)
        XCTAssertEqual(opened?.owningCoreID, "core-1", "no link that is up to give way to")
    }

    /// While shards are off a pool shard is read-only: its usable link of a
    /// name is never the route, so the preflight refuses a name only it links
    /// usably rather than admit a creation shard 0 can't make.
    func testAReadOnlyShardsUsableLinkIsNeverTheRoute() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement(), placementEnabled: false)
        let names = try [0, 3].map { try XCTUnwrap(pool.shard($0)).name }
        let unusable = HCUnusableBox([names[0]: ["studio"]])
        pool.unusableLinks = { unusable.value }
        await shards[0].setMachines(["studio": .connected])
        await shards[3].setMachines(["studio": .connected])
        let merged = await pool.snapshot()
        XCTAssertEqual(merged.sessionMachines.first { $0.shard.index == 3 }?.takesCreations, false)
        XCTAssertTrue(HCMachineLinkView.of(merged, unusableBySession: unusable.value).unusable.contains("studio"),
                      "refused up front: no session that takes new terminals links studio usably")
        XCTAssertEqual(pool.route(machine: "studio")?.usable, false)
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: UUID(), machine: "studio")?.index, 0)
        unusable.value = [:]
        XCTAssertEqual(pool.route(machine: "studio")?.shard.index, 0, "shard 0's own usable link")
    }

    /// A panel saved in the links session (`hcSession: "c11"`) homes there
    /// while adopted, and in shard 0 once converged: the same name, now shard 0's.
    func testAPanelSavedInTheLinksSessionHomesThereWhileAdoptedAndInShardZeroOnceConverged() throws {
        let adopted = try makeAdoptedPool(adoptedFakes(), placement: HCShardPlacement())
        let panel = UUID()
        adopted.seedRestored(panel: panel, savedSession: "c11")
        XCTAssertEqual(adopted.placement.home(forPanel: panel), HCShardID.links.index)
        let converged = try makePool(fakes(), placement: HCShardPlacement())
        XCTAssertNil(converged.links, "no adoption record, no links session")
        let later = UUID()
        converged.seedRestored(panel: later, savedSession: "c11")
        XCTAssertEqual(converged.placement.home(forPanel: later), 0)
    }

    // MARK: Names

    func testShardSessionsSocketsAndIntentsAreDistinct() throws {
        let legacy = try HCLaunchPolicy.configuration(home: home, tag: nil, inherited: [:])
        XCTAssertEqual(legacy.session, "c11")
        XCTAssertEqual(legacy.socketURL.path, "/Users/tester/.local/share/c11/run/c11.sock")
        let third = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: 3, inherited: [:])
        XCTAssertEqual(third.session, "c11-s3")
        XCTAssertEqual(third.socketURL.path, "/Users/tester/.local/share/c11/run/c11-s3.sock")
        XCTAssertEqual(third.environment["HC_SESSION"], "c11-s3")
        XCTAssertEqual(third.environment["HC_SOCKET"], third.socketURL.path)
        XCTAssertEqual(third.stateDirectory.lastPathComponent, "c11-s3")
        XCTAssertEqual(third.intentDirectory.lastPathComponent, "c11-s3")
        let tagged = try HCLaunchPolicy.configuration(home: home, tag: "c11-sh2", shard: 8, inherited: [:])
        XCTAssertEqual(tagged.session, "c11-c11-sh2-s8")
        XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: home, tag: nil, shard: HCShardPool.size + 1, inherited: [:]))
        // A tag ending in a shard suffix would be another build's shard session.
        XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: home, tag: "foo-s1", inherited: [:]))
        XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: home, tag: "s2", inherited: [:]))
        XCTAssertNoThrow(try HCLaunchPolicy.configuration(home: home, tag: "sh2", inherited: [:]))
        XCTAssertEqual(HCShardPool.session(base: "c11", shard: HCShardID(index: 3)), "c11-s3")
        XCTAssertEqual(HCShardPool.session(base: "c11-a", shard: .legacy), "c11-a")
    }

    /// A1.L1: the 103-byte check is shard K's holder, for every shard. A tag
    /// that fit before shards (S0's holder) but not shard 8's is refused whole.
    func testTupleIsRefusedWhenShardKHolderDoesNotFit() throws {
        // "/Users/tester/.local/share/c11/run/" is 35 bytes; "c11-" 4; "-s8" 3; ".holder.00000000.sock" 21.
        let fits = String(repeating: "a", count: 103 - 35 - 4 - 3 - 21)
        let tooLong = fits + "a"
        XCTAssertNoThrow(try HCLaunchPolicy.configuration(home: home, tag: fits, shard: 8, inherited: [:]))
        XCTAssertLessThanOrEqual(35 + 4 + tooLong.count + 21, 103, "S0's own holder would still fit")
        XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: home, tag: tooLong, inherited: [:]))
        XCTAssertThrowsError(try HCLaunchPolicy.configuration(home: home, tag: tooLong, shard: 3, inherited: [:]))
    }

    // MARK: Placement

    /// C11H-78 (SH4): a remote terminal follows its workspace's shard only
    /// when the pairing file pairs that shard with the machine.
    func testARemoteTerminalUsesItsWorkspacesShardOnlyWhenThatShardIsPaired() throws {
        let pool = try makePool(fakes(), placement: HCShardPlacement())
        let (local, remote) = (UUID(), UUID())
        let workspace = UUID()
        // No pairing at all: remote terminals stay on shard 0 (the hand-made link).
        XCTAssertEqual(pool.creationTarget(panelID: remote, workspaceID: workspace, machine: "studio")?.index, 0)
        let session1 = try XCTUnwrap(pool.shard(1)).name
        pool.pairedWith = { machine, session in machine == "studio" && session == session1 }
        // The workspace takes shard 1 for a local terminal; its Studio terminal follows it there.
        XCTAssertEqual(pool.creationTarget(panelID: local, workspaceID: workspace, machine: nil)?.index, 1)
        XCTAssertEqual(pool.creationTarget(panelID: remote, workspaceID: workspace, machine: "studio")?.index, 1)
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: workspace, machine: "prime")?.index, 0,
                       "a machine the file does not pair stays on shard 0")
        // A second workspace lands on shard 2, which is not paired: its Studio terminal stays on shard 0.
        let other = UUID()
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: other, machine: nil)?.index, 2)
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: other, machine: "studio")?.index, 0)
    }

    /// Grok on #150 (blocking 2): the create, not only the picker. A Studio
    /// terminal in a paired workspace is made by that shard's core; in an
    /// unpaired workspace, or for a machine the file does not name, by shard 0's.
    func testARemoteCreateIsMadeByThePairedShardsCoreElseShard0s() async throws {
        let pool = try makePool(fakes(), placement: HCShardPlacement())
        let session1 = try XCTUnwrap(pool.shard(1)).name
        pool.pairedWith = { machine, session in machine == "studio" && session == session1 }
        let paired = UUID()
        let local = await open(panel: UUID(), workspace: paired, in: pool)
        XCTAssertEqual(local?.owningCoreID, "core-1")
        let studio = await open(panel: UUID(), workspace: paired, machine: "studio", in: pool)
        XCTAssertEqual(studio?.owningCoreID, "core-1", "the paired shard's core runs its Studio terminal")
        let prime = await open(panel: UUID(), workspace: paired, machine: "prime", in: pool)
        XCTAssertEqual(prime?.owningCoreID, "core-0", "a machine the file does not pair stays on shard 0")
        // A workspace already placed on shard 2, which the file does not pair.
        let unpaired = UUID()
        pool.placement.seed(workspace: unpaired, shard: 2)
        let unpairedLocal = await open(panel: UUID(), workspace: unpaired, in: pool)
        XCTAssertEqual(unpairedLocal?.owningCoreID, "core-2")
        let stays = await open(panel: UUID(), workspace: unpaired, machine: "studio", in: pool)
        XCTAssertEqual(stays?.owningCoreID, "core-0", "an unpaired workspace's Studio terminal stays on shard 0")
    }

    /// Grok on #150 (non-blocking 1): a workspace whose first terminal is
    /// remote is placed on a paired shard, never stuck on an unpaired one.
    func testARemoteFirstWorkspaceIsPlacedOnAPairedShard() async throws {
        let pool = try makePool(fakes(), placement: HCShardPlacement())
        let session3 = try XCTUnwrap(pool.shard(3)).name
        pool.pairedWith = { machine, session in machine == "studio" && session == session3 }
        let workspace = UUID()
        let studio = await open(panel: UUID(), workspace: workspace, machine: "studio", in: pool)
        XCTAssertEqual(studio?.owningCoreID, "core-3")
        XCTAssertEqual(pool.placement.shard(forWorkspace: workspace), 3)
        let local = await open(panel: UUID(), workspace: workspace, in: pool)
        XCTAssertEqual(local?.owningCoreID, "core-3", "the workspace's later local terminals follow it")
    }

    func testTwoWorkspacesLandOnTwoShardsAndOnlyThoseStart() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let (a, b) = (UUID(), UUID())
        // Both choose before either creates: the first one's pending panel counts.
        let first = pool.creationTarget(panelID: a, workspaceID: a, machine: nil)?.index
        let second = pool.creationTarget(panelID: b, workspaceID: b, machine: nil)?.index
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        let keyA = await open(panel: a, workspace: a, in: pool)
        let keyB = await open(panel: b, workspace: b, in: pool)
        XCTAssertEqual(keyA?.owningCoreID, "core-1")
        XCTAssertEqual(keyB?.owningCoreID, "core-2")
        XCTAssertEqual(pool.placement.home(forPanel: a), 1)
        XCTAssertEqual(pool.placement.home(forPanel: b), 2)
        for shard in shards where ![1, 2].contains(shard.index) {
            let started = await shard.started
            XCTAssertFalse(started, "shard \(shard.index) started without a workspace")
        }
    }

    func testEveryTerminalOfAWorkspaceLandsOnItsShard() async throws {
        let pool = try makePool(fakes(), placement: HCShardPlacement())
        let workspace = UUID()
        let other = UUID()
        _ = await open(panel: UUID(), workspace: workspace, in: pool)
        _ = await open(panel: UUID(), workspace: other, in: pool)
        // The workspace's shard now has the most terminals; it still takes them.
        var keys: [HCTerminalKey?] = []
        for _ in 0..<3 { keys.append(await open(panel: UUID(), workspace: workspace, in: pool)) }
        XCTAssertEqual(keys.map { $0?.owningCoreID }, ["core-1", "core-1", "core-1"])
    }

    func testNewWorkspaceTakesTheLeastLoadedShard() async throws {
        let shards = fakes()
        let loads = [1: 3, 2: 1, 3: 2, 4: 2, 5: 4, 6: 2, 7: 1, 8: 3]
        for (index, count) in loads { for _ in 0..<count { await shards[index].seedLive(panel: nil) } }
        // Finished terminals are not load: shard 4 has two live and five ended.
        for _ in 0..<5 { await shards[4].seedLive(panel: nil, state: .finished) }
        await shards[2].seedLive(panel: nil)   // shard 2 now 2, shard 7 is the least loaded
        let pool = try makePool(shards, placement: HCShardPlacement())
        _ = await pool.snapshot()
        XCTAssertEqual(pool.liveTerminals(in: 4), 2)
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: UUID(), machine: nil)?.index, 7)
        // Shard 7 now has a pending creation (load 2): ties go to the lowest index.
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: UUID(), machine: nil)?.index, 2)
    }

    func testWorkspacesShareShardsPastEightAndShardZeroIsNeverATarget() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        var placed: [Int] = []
        for _ in 0..<(HCShardPool.size + 1) {
            let workspace = UUID()
            let key = await open(panel: workspace, workspace: workspace, in: pool)
            placed.append(Int(key?.owningCoreID.dropFirst(5) ?? "") ?? -1)
            _ = await pool.snapshot()
        }
        XCTAssertEqual(placed, [1, 2, 3, 4, 5, 6, 7, 8, 1])
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [])
    }

    // MARK: Shard 0

    func testShardZeroKeepsItsTerminalsAndTakesNoNewOnes() async throws {
        let shards = fakes()
        let legacyPanel = UUID()
        let workspace = UUID()
        let legacyKey = await shards[0].seedLive(panel: legacyPanel)
        let pool = try makePool(shards, placement: HCShardPlacement())
        // A pre-shard snapshot: key, no shard. It resolves on shard 0, in place.
        let restored = HCPanelIdentity(panelID: legacyPanel, key: legacyKey, origin: .restored)
        XCTAssertEqual(pool.creationTarget(panelID: legacyPanel, workspaceID: workspace, machine: nil)?.index, 1)
        let lifecycle = await pool.route(panelID: legacyPanel).resolve(restored)
        XCTAssertEqual(identity(lifecycle), legacyKey)
        XCTAssertEqual(pool.placement.home(forPanel: legacyPanel), 0)
        XCTAssertNil(pool.placement.target(forPanel: legacyPanel), "a live panel is no longer pending")
        // A new split in that workspace goes to the workspace's pool shard.
        let split = await open(panel: UUID(), workspace: workspace, in: pool)
        XCTAssertEqual(split?.owningCoreID, "core-1")
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, ["resolve"])
        let legacyRecords = await shards[0].records
        XCTAssertEqual(legacyRecords[legacyKey]?.state, .running)
    }

    /// C11H-359 (L2): a terminal one of this app's own cores owns is ended on
    /// that core's shard, even when another shard's inventory lists its key (a
    /// linked machine that reported that core's id). Through the pool, and
    /// through a panel's route whose home is the other shard.
    func testAShardOwnedKeyIsEndedOnlyOnItsOwnShard() async throws {
        let shards = fakes()
        let panel = UUID()
        let local = await shards[2].seedLive(panel: panel)
        await shards[1].seedMirrored(local, machine: "studio")
        let placement = HCShardPlacement()
        let pool = try makePool(shards, placement: placement)
        _ = await pool.snapshot()
        XCTAssertEqual(pool.shardIndex(for: local), 1, "the precondition: the other shard's listing is found first")
        _ = await pool.end(local)
        placement.setHome(1, panel: panel)
        _ = await pool.route(panelID: panel).end(local)
        let ownEnds = await shards[2].ended
        let otherEnds = await shards[1].ended
        XCTAssertEqual(ownEnds, [local, local])
        XCTAssertEqual(otherEnds, [], "a kill never goes to the shard that only mirrors the key")
        // A linked machine's own key still ends where its record is.
        let far = HCTerminalKey(owningCoreID: "studio-core", localAddress: "t4")
        await shards[1].seedMirrored(far, machine: "studio")
        _ = await pool.snapshot()
        _ = await pool.end(far)
        let farEnds = await shards[1].ended
        XCTAssertEqual(farEnds, [far])
    }

    func testReplacementOnAnotherShardWaitsForTheOldEnd() async throws {
        let shards = fakes()
        let panel = UUID()
        let workspace = UUID()
        let oldKey = await shards[0].seedLive(panel: panel)
        let pool = try makePool(shards, placement: HCShardPlacement())
        let restored = HCPanelIdentity(panelID: panel, key: oldKey, origin: .restored)
        let target = pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil)
        let request = HCCreateRequest(identity: restored, creationID: UUID(), argv: [], shard: target?.id)
        // Still live on shard 0: nothing is created anywhere.
        let early = await pool.route(panelID: panel).create(request)
        XCTAssertEqual(boundKey(early), oldKey)
        let earlyCalls = await shards[1].calls
        XCTAssertFalse(earlyCalls.contains("create"))
        await shards[0].finish(oldKey)
        let replaced = await pool.route(panelID: panel).create(request)
        XCTAssertEqual(boundKey(replaced)?.owningCoreID, "core-1")
        XCTAssertEqual(pool.placement.home(forPanel: panel), 1)
    }

    // MARK: Persistence and restore

    func testQuitAndRelaunchKeepsBothWorkspacesOnTheirShards() async throws {
        let shards = fakes()   // the cores outlive the app
        let placement = HCShardPlacement()
        let pool = try makePool(shards, placement: placement)
        let (workspaceA, workspaceB, panelA, panelB) = (UUID(), UUID(), UUID(), UUID())
        let keyAOpened = await open(panel: panelA, workspace: workspaceA, in: pool)
        let keyA = try XCTUnwrap(keyAOpened)
        let keyBOpened = await open(panel: panelB, workspace: workspaceB, in: pool)
        let keyB = try XCTUnwrap(keyBOpened)

        // Quit: what autosave writes for each workspace.
        func saved(workspace: UUID, panel: UUID, key: HCTerminalKey) throws -> Data {
            let terminal = SessionTerminalPanelSnapshot.capture(workingDirectory: "/tmp",
                hcIdentity: HCPanelIdentity(panelID: panel, key: key, origin: .fresh),
                hcSession: placement.home(forPanel: panel).flatMap { pool.shard($0)?.name }) { nil }
            return try JSONEncoder().encode(Saved(workspaceShard: placement.shard(forWorkspace: workspace).map { HCShardID(index: $0) },
                                                  terminal: terminal))
        }
        let savedA = try saved(workspace: workspaceA, panel: panelA, key: keyA)
        let savedB = try saved(workspace: workspaceB, panel: panelB, key: keyB)

        // Relaunch: a new process, new placement, new pool over the same cores.
        let relaunched = HCShardPlacement()
        let next = try makePool(shards, placement: relaunched)
        for (data, workspace, panel, key) in [(savedA, workspaceA, panelA, keyA), (savedB, workspaceB, panelB, keyB)] {
            let decoded = try JSONDecoder().decode(Saved.self, from: data)
            let index = Int(key.owningCoreID.dropFirst(5))
            XCTAssertEqual(decoded.terminal.hcSession, "c11-s\(index ?? -1)", "the snapshot names the key's session")
            XCTAssertEqual(decoded.workspaceShard?.index, index)
            relaunched.seed(workspace: workspace, shard: decoded.workspaceShard?.index)
            relaunched.seed(panel: panel, home: decoded.terminal.hcSession.flatMap { next.index(ofSession: $0) })
            let restored = try XCTUnwrap(decoded.terminal.restoredHCIdentity(panelID: panel, backendActive: true))
            let lifecycle = await next.route(panelID: panel).resolve(restored)
            XCTAssertEqual(identity(lifecycle), key)
        }
        // A new terminal in workspace B still lands on B's shard.
        let more = await open(panel: UUID(), workspace: workspaceB, in: next)
        XCTAssertEqual(more?.owningCoreID, keyB.owningCoreID)
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [])
    }

    private struct Saved: Codable {
        let workspaceShard: HCShardID?
        let terminal: SessionTerminalPanelSnapshot
    }

    func testOlderSnapshotsDecodeWithoutAShard() throws {
        let terminal = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: Data(#"{"workingDirectory":"/tmp"}"#.utf8))
        XCTAssertNil(terminal.hcSession)
        let workspace = try JSONDecoder().decode(HCShardID?.self, from: Data("null".utf8))
        XCTAssertNil(workspace)
        let placement = HCShardPlacement()
        let panel = UUID()
        placement.seed(panel: panel, home: terminal.hcSession.map { _ in 1 })
        placement.seed(panel: UUID(), home: 42)   // out of range: ignored
        XCTAssertNil(placement.home(forPanel: panel))
        placement.seed(workspace: panel, shard: 0)   // shard 0 is never a workspace placement
        XCTAssertNil(placement.shard(forWorkspace: panel))
    }

    func testRestoreFindsAPendingCreationOnAnotherShard() async throws {
        let shards = fakes()
        let store = HCCreationIntentStore(directory: temporary.appendingPathComponent("c11-s3"))
        let panel = UUID()
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: UUID(), argv: [])
        _ = try await store.claim(request, coreID: "core-3", process: HCProcessIdentity(pid: 103, startTimeMicroseconds: 1))
        let placement = HCShardPlacement()
        // The snapshot was written before the creation moved this panel to shard 3.
        placement.seed(panel: panel, home: 1)
        let pool = try makePool(shards, placement: placement, intents: [3: store])
        let restored = HCPanelIdentity(panelID: panel, creationID: request.creationID, origin: .restored)
        let home = try await pool.homeIndex(for: restored)
        XCTAssertEqual(home, 3)
    }

    // MARK: Readiness per shard

    /// A panel hears only its own shard, never another shard's outage. Its
    /// observer starts from what its shard last told the fan-out: the shard's
    /// pre-start placeholder (pending, no build identity) when it registers
    /// before the fan-out has matched the shard's first ready snapshot. A
    /// loaded host does that after the panel opens; here a observes before
    /// shard 1 starts, so that order happens on every run.
    func testPanelsSeeOnlyTheirOwnShard() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let (a, b) = (UUID(), UUID())
        let seen = HCCollected()
        let queue = DispatchQueue(label: "test.route")
        let newest = expectation(description: "a hears shard 1's newest snapshot")
        newest.assertForOverFulfill = false
        let outage = expectation(description: "b hears shard 2's outage")
        outage.assertForOverFulfill = false
        let target = pool.creationTarget(panelID: a, workspaceID: a, machine: nil)
        XCTAssertEqual(target?.index, 1)
        let observation = pool.route(panelID: a).observe(on: queue) { snapshot in
            seen.add(snapshot)
            if snapshot.records.count == 2 { newest.fulfill() }   // a's terminal and the one seeded below
        }
        defer { observation.cancel() }
        _ = await open(panel: a, workspace: a, in: pool)
        _ = await pool.snapshot()   // shard 1's terminal counts now, so b's workspace takes shard 2
        _ = await open(panel: b, workspace: b, in: pool)
        XCTAssertEqual(pool.placement.home(forPanel: b), 2)
        let other = pool.route(panelID: b).observe(on: queue) { snapshot in
            if case .pending(.connectionLost) = snapshot.readiness { outage.fulfill() }
        }
        defer { other.cancel() }
        await shards[2].goPending(.connectionLost)
        await shards[1].seedLive(panel: nil)
        await fulfillment(of: [newest, outage], timeout: 5)
        pool.fanout.sync()
        let drained = expectation(description: "route queue drained")
        queue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        let all = seen.all
        XCTAssertTrue(all.allSatisfy { $0.source == HCShardID(index: 1) }, "\(all.map { $0.source?.index ?? -1 })")
        XCTAssertFalse(all.contains { if case .pending(.connectionLost) = $0.readiness { return true } else { return false } },
                       "shard 2's outage reached shard 1's panel")
        let last = try XCTUnwrap(all.last)
        guard case .ready = last.readiness else { return XCTFail("a ends on shard 1's ready snapshot") }
        XCTAssertEqual(last.buildIdentity?.coreID, "core-1")
    }

    func testMergedInventoryCountsOnlyShardsInUse() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let first = await pool.snapshot()
        guard case .pending = first.readiness else { return XCTFail("nothing connected yet") }
        let a = UUID()
        let keyOpened = await open(panel: a, workspace: a, in: pool)
        let key = try XCTUnwrap(keyOpened)
        let ready = await pool.snapshot()
        guard case .ready(let revision) = ready.readiness else { return XCTFail("shard 1 is ready") }
        XCTAssertEqual(revision, ready.revision)
        XCTAssertNotNil(ready.records[key])
        let b = UUID()
        let keyBOpened = await open(panel: b, workspace: b, in: pool)
        let keyB = try XCTUnwrap(keyBOpened)
        _ = await pool.snapshot()   // shard 2 is in use (seen ready) before it goes down
        await shards[2].goPending(.connectionLost)
        let pending = await pool.snapshot()
        guard case .pending(.connectionLost) = pending.readiness else { return XCTFail("a shard in use is down") }
        XCTAssertNotNil(pending.records[keyB], "an outage never drops a record")
        XCTAssertGreaterThan(pending.revision.connectionGeneration, ready.revision.connectionGeneration)
        let ended = await pool.end(key)
        guard case .pending(key) = ended else { return XCTFail("routed to the owning shard") }
        let calls = await shards[1].calls
        XCTAssertEqual(calls.last, "end")
    }

    func testServingShardsAreJoinedWithoutLaunchingOthers() async throws {
        let shards = fakes()
        await shards[0].setServing(true)
        await shards[5].setServing(true)
        let pool = try makePool(shards, placement: HCShardPlacement())
        pool.connectServingShards()
        for _ in 0..<200 {
            let joined = await (shards[0].started, shards[5].started)
            if joined.0 && joined.1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = await withTaskGroup(of: (Int, Bool).self) { group in
            for shard in shards { group.addTask { (shard.index, await shard.started) } }
            var result: [Int] = []
            for await (index, started) in group where started { result.append(index) }
            return result.sorted()
        }
        XCTAssertEqual(started, [0, 5])
    }

    func testAShardThatCannotStartFailsOnlyItsCreation() async throws {
        let shards = fakes()
        await shards[2].setFailing(true)
        let pool = try makePool(shards, placement: HCShardPlacement())
        let (a, c) = (UUID(), UUID())
        let keyA = await open(panel: a, workspace: a, in: pool)
        XCTAssertEqual(keyA?.owningCoreID, "core-1")
        _ = await pool.snapshot()
        let target = try XCTUnwrap(pool.creationTarget(panelID: c, workspaceID: c, machine: nil))
        XCTAssertEqual(target.index, 2)
        let fresh = HCPanelIdentity(panelID: c, origin: .fresh)
        let failed = await pool.route(panelID: c).create(HCCreateRequest(identity: fresh, creationID: UUID(), argv: [], shard: target.id))
        guard case .rejectedBeforeTransmission(.coreUnreachable) = failed else { return XCTFail("the creation fails as L3 says") }
        // Never retried on another shard; the workspace keeps its placement and
        // the panel stays with the shard it tried (not pending load).
        XCTAssertEqual(pool.placement.shard(forWorkspace: c), 2)
        XCTAssertEqual(pool.placement.home(forPanel: c), 2)
        XCTAssertNil(pool.placement.target(forPanel: c))
        for shard in shards where shard.index != 2 {
            let created = await shard.calls.filter { $0 == "create" }.count
            XCTAssertEqual(created, shard.index == 1 ? 1 : 0, "shard \(shard.index)")
        }
        // Shard 1 is untouched by shard 2's failure: A's workspace still opens terminals.
        let more = await open(panel: UUID(), workspace: a, in: pool)
        XCTAssertEqual(more?.owningCoreID, "core-1")
    }

    func testAPendingCreationInAnotherStoreIsNeverDuplicated() async throws {
        let shards = fakes()
        let panel = UUID()
        let workspace = UUID()
        // The creation reached shard 5 (its intent and its starting terminal), but the
        // snapshot was written before: it names the workspace's placement only.
        let store = HCCreationIntentStore(directory: temporary.appendingPathComponent("c11-s5"))
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: UUID(), argv: [])
        _ = try await store.claim(request, coreID: "core-5", process: HCProcessIdentity(pid: 105, startTimeMicroseconds: 1))
        let onFive = await shards[5].seedLive(panel: panel)
        let placement = HCShardPlacement()
        placement.seed(workspace: workspace, shard: 2)
        let pool = try makePool(shards, placement: placement, intents: [5: store])
        XCTAssertEqual(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil)?.index, 2)
        let restored = HCPanelIdentity(panelID: panel, origin: .restored)
        let lifecycle = await pool.route(panelID: panel).resolve(restored)
        XCTAssertEqual(identity(lifecycle), onFive, "resolved where the intent is, so no second terminal")
        let placedCalls = await shards[2].calls
        XCTAssertEqual(placedCalls, [])
    }

    func testAPreShardPanelWithoutKeyResolvesInShardZero() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let (restoredPanel, freshPanel, workspace) = (UUID(), UUID(), UUID())
        // A pre-shard workspace: no saved placement. Its terminal start still places it.
        XCTAssertEqual(pool.creationTarget(panelID: restoredPanel, workspaceID: workspace, machine: nil)?.index, 1)
        _ = await pool.route(panelID: restoredPanel).resolve(HCPanelIdentity(panelID: restoredPanel, origin: .restored))
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, ["resolve"])
        // A new panel of this process resolves where its creation goes.
        _ = pool.creationTarget(panelID: freshPanel, workspaceID: workspace, machine: nil)
        _ = await pool.route(panelID: freshPanel).resolve(HCPanelIdentity(panelID: freshPanel, origin: .fresh))
        let placedCalls = await shards[1].calls
        XCTAssertEqual(placedCalls, ["resolve"])
    }

    func testAChangedCoreIDResolvesByLabelsInTheSavedSession() async throws {
        let shards = fakes()
        let panel = UUID()
        let live = await shards[3].seedLive(panel: panel)
        let placement = HCShardPlacement()
        placement.seed(panel: panel, home: 3)
        let pool = try makePool(shards, placement: placement)
        _ = await pool.snapshot()
        // The saved key names shard 3's old core id (its state directory was deleted).
        let stale = HCTerminalKey(owningCoreID: "core-3-before", localAddress: live.localAddress)
        let lifecycle = await pool.route(panelID: panel).resolve(HCPanelIdentity(panelID: panel, key: stale, origin: .restored))
        XCTAssertEqual(identity(lifecycle), live)
    }

    func testEachShardIsAnnouncedOnceWhenItStarts() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let started = HCStartedLog()
        let announced = expectation(description: "shards 1 and 2 announced")
        announced.expectedFulfillmentCount = 2
        announced.assertForOverFulfill = true
        pool.onShardStarted = { started.add($0.name); announced.fulfill() }
        let a = UUID()
        _ = await open(panel: a, workspace: a, in: pool)
        _ = await open(panel: UUID(), workspace: a, in: pool)
        let b = UUID()
        _ = await open(panel: b, workspace: b, in: pool)
        _ = await pool.snapshot()
        _ = await pool.refresh()
        // The pool's observer queue may still be calling the hook it just claimed.
        await fulfillment(of: [announced], timeout: 10)
        // Once: a later refresh announces in line, so a shard announced again shows here.
        _ = await pool.refresh()
        // Diagnostics list a shard from its start, once; an unused shard is never listed.
        XCTAssertEqual(started.all.sorted(), ["c11-s1", "c11-s2"])
    }

    /// C11H-346: a created terminal counts toward its shard's load until the pool has absorbed
    /// the shard inventory that holds it. The observer queue is held here, as a loaded host
    /// delays it: the next workspace still sees shard 1 busy and takes shard 2, and once the
    /// inventory arrives the terminal counts as live and its target is gone. Before, the target
    /// was cleared when create returned, so the next workspace joined shard 1 (the order that
    /// left testEachShardIsAnnouncedOnceWhenItStarts with only c11-s1 started).
    func testACreatedTerminalCountsTowardItsShardUntilThePoolAbsorbsIt() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        pool.suspendObserverQueueForTesting()
        var held = true
        defer { if held { pool.resumeObserverQueueForTesting() } }
        let a = UUID()
        let key = await open(panel: a, workspace: a, in: pool)
        XCTAssertEqual(key?.owningCoreID, "core-1")
        XCTAssertEqual(pool.liveTerminals(in: 1), 0, "the pool has not absorbed shard 1's inventory yet")
        XCTAssertEqual(pool.placement.target(forPanel: a), 1, "so a's terminal is still shard 1's pending load")
        let b = UUID()
        XCTAssertEqual(pool.creationTarget(panelID: b, workspaceID: b, machine: nil)?.index, 2,
                       "the next workspace sees shard 1 busy")
        pool.resumeObserverQueueForTesting()
        held = false
        let deadline = Date().addingTimeInterval(5)
        while pool.placement.target(forPanel: a) != nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(pool.placement.target(forPanel: a), "absorbed: a's terminal counts as live instead")
        XCTAssertEqual(pool.liveTerminals(in: 1), 1)
    }

    /// C11H-356 (Astra's guard on #350): a restart in the same panel and shard. The panel's earlier
    /// terminal is still in shard 1's inventory, finished, by its binding or by its `c11.panel`
    /// label. Its replacement's target must wait for the replacement's own record: before, any
    /// record of the panel settled it, so the new terminal counted nowhere and the next workspace
    /// joined shard 1. Resolving the earlier terminal's end leaves the target pending too.
    func testAPanelsEarlierTerminalNeverSettlesItsReplacementsTarget() async throws {
        for byBinding in [true, false] {
            let variant = byBinding ? "binding" : "label"
            let shards = fakes()
            let pool = try makePool(shards, placement: HCShardPlacement())
            let (panel, workspace) = (UUID(), UUID())
            let old: HCTerminalKey
            if byBinding {
                old = await shards[1].seedLive(panel: nil)
                await shards[1].bind(panel, old)
            } else {
                old = await shards[1].seedLive(panel: panel, creation: UUID())
            }
            await shards[1].finish(old)
            _ = await pool.snapshot()
            XCTAssertEqual(pool.shardIndex(for: old), 1, variant)
            pool.suspendObserverQueueForTesting()
            var held = true
            defer { if held { pool.resumeObserverQueueForTesting() } }
            let target = try XCTUnwrap(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil))
            XCTAssertEqual(target.index, 1, variant)
            let route = pool.route(panelID: panel)
            let earlier = HCPanelIdentity(panelID: panel, key: old, origin: .restored)
            let replaced = await route.create(HCCreateRequest(identity: earlier, creationID: UUID(), argv: ["/bin/zsh"],
                                                              shard: target.id))
            let replacement = try XCTUnwrap(boundKey(replaced), variant)
            XCTAssertEqual(replacement.owningCoreID, "core-1", variant)
            XCTAssertEqual(pool.liveTerminals(in: 1), 0, "\(variant): the pool holds only the finished earlier terminal")
            XCTAssertEqual(pool.placement.target(forPanel: panel), 1, "\(variant): the replacement is still shard 1's pending load")
            guard case .ended = await route.resolve(earlier) else { return XCTFail("\(variant): the earlier terminal resolves ended") }
            XCTAssertEqual(pool.placement.target(forPanel: panel), 1, "\(variant): the earlier terminal's end is not the replacement's")
            let next = UUID()
            XCTAssertEqual(pool.creationTarget(panelID: next, workspaceID: next, machine: nil)?.index, 2,
                           "\(variant): the next workspace sees shard 1 busy")
            pool.resumeObserverQueueForTesting()
            held = false
            let deadline = Date().addingTimeInterval(5)
            while pool.placement.target(forPanel: panel) != nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertNil(pool.placement.target(forPanel: panel), "\(variant): settled once the replacement's record is absorbed")
            XCTAssertEqual(pool.liveTerminals(in: 1), 1, variant)
        }
    }

    /// C11H-356 (Opus nb2 on #350): a terminal that binds and leaves the inventory before the
    /// pool absorbs any shard inventory showing it. The observer is held behind an earlier
    /// delivery, so the only inventories it absorbs are before the bind or after the removal.
    /// The target settles on the newer one that no longer holds it, not when the panel closes.
    func testATargetSettlesWhenItsTerminalLeavesBeforeThePoolSeesIt() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        await shards[1].seedLive(panel: nil, state: .finished)   // shard 1 is serving
        _ = await pool.snapshot()
        pool.drainObserverQueueForTesting()
        pool.suspendObserverQueueForTesting()
        var held = true
        defer { if held { pool.resumeObserverQueueForTesting() } }
        await shards[1].republish()   // the delivery the observer takes next, from before the bind
        let panel = UUID()
        let created = await open(panel: panel, workspace: panel, in: pool)
        let key = try XCTUnwrap(created)
        XCTAssertEqual(key.owningCoreID, "core-1")
        await shards[1].remove(key)
        XCTAssertEqual(pool.placement.target(forPanel: panel), 1, "nothing absorbed yet")
        pool.resumeObserverQueueForTesting()
        held = false
        let deadline = Date().addingTimeInterval(5)
        while pool.placement.target(forPanel: panel) != nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(pool.placement.target(forPanel: panel), "a ready inventory after the bind no longer holds it")
        XCTAssertEqual(pool.liveTerminals(in: 1), 0)
    }

    /// C11H-356: a creation sent but not yet live answers unresolved and names no terminal. Its
    /// target settles when the absorbed inventory holds a record of that creation.
    func testAnUnresolvedCreationSettlesWhenItsCreationsRecordIsAbsorbed() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        await shards[1].setCreatesStarting(true)
        pool.suspendObserverQueueForTesting()
        var held = true
        defer { if held { pool.resumeObserverQueueForTesting() } }
        let panel = UUID()
        let target = try XCTUnwrap(pool.creationTarget(panelID: panel, workspaceID: panel, machine: nil))
        let fresh = HCPanelIdentity(panelID: panel, origin: .fresh)
        let result = await pool.route(panelID: panel).create(HCCreateRequest(identity: fresh, creationID: UUID(),
                                                                             argv: ["/bin/zsh"], shard: target.id))
        guard case .unresolved(_, .creationPending) = result else { return XCTFail("sent, still starting: \(result)") }
        XCTAssertEqual(pool.placement.target(forPanel: panel), 1)
        pool.resumeObserverQueueForTesting()
        held = false
        let deadline = Date().addingTimeInterval(5)
        while pool.placement.target(forPanel: panel) != nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(pool.placement.target(forPanel: panel), "its creation's record is in the absorbed inventory")
        XCTAssertEqual(pool.liveTerminals(in: 1), 1)
    }

    /// C11H-346 / Opus nb3 on #350: `creationTarget` reads the targets, then the live counts. A
    /// target that settled after the counts were read (its record absorbed just after them) is
    /// in neither the counts nor the targets `place` reads; the copy read first still counts it.
    func testATargetThatSettlesAfterTheCountsAreReadStillCounts() {
        let placement = HCShardPlacement()
        let (settled, next) = (UUID(), UUID())
        XCTAssertEqual(placement.place(workspace: next, candidates: [1, 2], liveTerminals: [:],
                                       targetsBeforeCounts: [settled: 1]), 2)
    }

    // MARK: C11H-94 placement hygiene (hc Lead items 5 and 6)

    /// Item 5, decided: a restored pre-shard workspace's placement is committed
    /// at its first terminal start, yet its reattached terminal stays in S0, its
    /// target leaves the pending load, and no pool core starts until a creation.
    func testARestoredWorkspaceCommitsItsPlacementButStartsNoPoolShard() async throws {
        let shards = fakes()
        let (panel, workspace) = (UUID(), UUID())
        let live = await shards[0].seedLive(panel: panel)
        let placement = HCShardPlacement()
        placement.seed(panel: panel, home: 0)
        let pool = try makePool(shards, placement: placement)
        XCTAssertEqual(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil)?.index, 1)
        let lifecycle = await pool.route(panelID: panel).resolve(HCPanelIdentity(panelID: panel, key: live, origin: .restored))
        XCTAssertEqual(identity(lifecycle), live, "the terminal stays where it lives")
        XCTAssertEqual(placement.shard(forWorkspace: workspace), 1, "committed at the first start")
        XCTAssertNil(placement.target(forPanel: panel), "a reattached panel is not pending load")
        let poolStarted = await shards[1].started
        XCTAssertFalse(poolStarted, "committing a placement starts no core")
        // The workspace's next new terminal goes to its committed shard, which starts only then.
        let next = await open(panel: UUID(), workspace: workspace, in: pool)
        XCTAssertEqual(next?.owningCoreID, "core-1")
    }

    /// Item 6: placement entries leave with what they place. A panel closed for
    /// good drops its home, its target and (with no workspace) its own
    /// placement. A workspace closed for good drops its placement. A move or a
    /// quit keeps both, for the snapshot.
    @MainActor
    func testClosingForGoodDropsPlacementAndQuittingKeepsIt() throws {
        let placement = HCShardPlacement()
        let lineage = PanelLineage()
        HCShardPlacement.installCloseObserver(lineage: lineage, placement: placement)
        let (panel, loose, moved, workspace, other) = (UUID(), UUID(), UUID(), UUID(), UUID())
        placement.seed(workspace: workspace, shard: 2)
        placement.seed(workspace: other, shard: 3)
        placement.seed(panel: panel, home: 2)
        placement.setTarget(2, panel: panel, workspace: workspace)
        placement.seed(panel: moved, home: 2)
        // A panel with no workspace is placed under its own id.
        XCTAssertEqual(placement.place(workspace: loose, candidates: [1, 2], liveTerminals: [:]), 1)
        placement.setTarget(1, panel: loose)
        lineage.panelsClosedForGood([moved], isDetaching: true)
        XCTAssertEqual(placement.home(forPanel: moved), 2, "a move is not a close")
        lineage.panelsClosedForGood([panel, loose])
        XCTAssertNil(placement.home(forPanel: panel))
        XCTAssertNil(placement.target(forPanel: panel))
        XCTAssertNil(placement.target(forPanel: loose))
        XCTAssertNil(placement.shard(forWorkspace: loose), "a workspace-less panel's own placement goes with it")
        XCTAssertEqual(placement.shard(forWorkspace: workspace), 2, "closing a panel keeps its workspace's shard")
        placement.workspacesClosedForGood([workspace], isTerminatingApp: true)
        XCTAssertEqual(placement.shard(forWorkspace: workspace), 2, "quitting keeps it for the snapshot")
        placement.workspacesClosedForGood([workspace], isTerminatingApp: false)
        XCTAssertNil(placement.shard(forWorkspace: workspace))
        XCTAssertEqual(placement.shard(forWorkspace: other), 3)
        let counts = placement.entryCounts
        XCTAssertEqual([counts.workspaces, counts.homes, counts.targets], [1, 1, 0], "only the open workspace and the moved panel remain")
    }

    // MARK: Review round 1 (sol on ecf4318f)

    /// B2: a first creation that shard 2 claimed and then refused before the
    /// run was sent. Its retry resolves in shard 2, where the settled end
    /// proof is (real store, real resolver), and autosave names shard 2.
    func testARefusedFirstCreationRetriesInItsOwnShard() async throws {
        let shards = fakes()
        let store = HCCreationIntentStore(directory: temporary.appendingPathComponent("c11-s2"))
        await shards[2].use(store: store, rejectAfterClaim: true)
        let pool = try makePool(shards, placement: HCShardPlacement(), intents: [2: store])
        let (a, c) = (UUID(), UUID())
        _ = await open(panel: a, workspace: a, in: pool)       // shard 1 is taken
        _ = await pool.snapshot()
        let target = try XCTUnwrap(pool.creationTarget(panelID: c, workspaceID: c, machine: nil))
        XCTAssertEqual(target.index, 2)
        let creation = UUID()
        let refused = await pool.route(panelID: c).create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: c, origin: .fresh), creationID: creation, argv: [], shard: target.id))
        guard case .rejectedBeforeTransmission = refused else { return XCTFail("refused before the run") }
        XCTAssertEqual(pool.placement.home(forPanel: c), 2, "autosave names the shard holding the settled intent")
        // HCPanelSession keeps the attempt's UUID and resolves again.
        let retry = await pool.route(panelID: c).resolve(HCPanelIdentity(panelID: c, creationID: creation, origin: .fresh))
        guard case .ended(let proof) = retry, proof.kind == .createRejected else {
            return XCTFail("resolves the settled refusal in shard 2, got \(retry)")
        }
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [], "never S0")
    }

    // MARK: C11H-313: a creation stopped before its claim is recorded where the panel resolves

    /// Shard 0 holds a panel's finished first terminal, its intent ended there.
    private func finishedFirstTerminal(_ shards: [HCFakeShard], panel: UUID, first: UUID) async throws
        -> (HCCreationIntentStore, HCTerminalKey) {
        let session = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: 0, inherited: [:]).session
        let store = HCCreationIntentStore(directory: temporary.appendingPathComponent(session))
        await shards[0].use(store: store)
        let oldKey = await shards[0].seedLive(panel: panel)
        _ = try await store.claim(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: first, argv: []),
                                  coreID: "core-0", process: HCProcessIdentity(pid: 100, startTimeMicroseconds: 1))
        try await store.bind(panelID: panel, creationID: first, key: oldKey)
        await shards[0].finish(oldKey)
        try await store.recordEnd(panelID: panel, creationID: first, evidence: HCEndEvidence(id: UUID(), key: oldKey,
            creationID: first, revision: HCRevision(connectionGeneration: 1, sequence: 3), kind: .finished))
        return (store, oldKey)
    }

    /// A replacement the target shard refuses before its run sends the panel
    /// back to the shard of its old terminal. That shard learns the replacement
    /// never ran, so a close following the replacement there settles instead
    /// of reading the old creation's end.
    func testAReplacementRefusedOnAnotherShardIsRecordedNeverRunWhereThePanelResolves() async throws {
        let shards = fakes()
        let (panel, first, replacement) = (UUID(), UUID(), UUID())
        let (store, oldKey) = try await finishedFirstTerminal(shards, panel: panel, first: first)
        await shards[1].setFailing(true)
        let pool = try makePool(shards, placement: HCShardPlacement(), intents: [0: store])
        let restored = HCPanelIdentity(panelID: panel, key: oldKey, creationID: first, origin: .restored)
        let refused = await pool.route(panelID: panel).create(HCCreateRequest(identity: restored, creationID: replacement,
                                                                               argv: [], shard: HCShardID(index: 1)))
        guard case .rejectedBeforeTransmission = refused else { return XCTFail("refused before the run, got \(refused)") }
        XCTAssertEqual(pool.placement.home(forPanel: panel), 0, "the replaced terminal is still where it was")
        let closing = HCPanelIdentity(panelID: panel, creationID: replacement, origin: .restored)
        let lifecycle = await pool.route(panelID: panel).resolve(closing)
        guard case .ended(let proof) = lifecycle, proof.creationID == replacement, proof.kind == .createRejected else {
            return XCTFail("the replacement must read as never run where the panel resolves, got \(lifecycle)")
        }
    }

    /// A replacement the pool stops before any shard's create (the old shard
    /// cannot prove its end yet) is recorded never run in the panel's shard,
    /// and answers so while that shard's inventory is still pending.
    func testAReplacementStoppedByThePoolIsRecordedNeverRunInThePanelsShard() async throws {
        let shards = fakes()
        let (panel, first, replacement) = (UUID(), UUID(), UUID())
        let (store, oldKey) = try await finishedFirstTerminal(shards, panel: panel, first: first)
        let pool = try makePool(shards, placement: HCShardPlacement(), intents: [0: store])
        await shards[0].goPending(.connectionLost)
        let restored = HCPanelIdentity(panelID: panel, key: oldKey, creationID: first, origin: .restored)
        let stopped = await pool.route(panelID: panel).create(HCCreateRequest(identity: restored, creationID: replacement,
                                                                               argv: [], shard: HCShardID(index: 1)))
        guard case .unresolved(_, .connectionLost) = stopped else { return XCTFail("the old end is unproven, got \(stopped)") }
        let created = await shards[1].calls
        XCTAssertFalse(created.contains("create"), "no shard was asked to create")
        let lifecycle = await pool.route(panelID: panel).resolve(HCPanelIdentity(panelID: panel, creationID: replacement, origin: .restored))
        guard case .ended(let proof) = lifecycle, proof.creationID == replacement, proof.kind == .createRejected else {
            return XCTFail("the replacement must read as never run, got \(lifecycle)")
        }
        // The app's close, carrying the old key, through the pool, while that shard is still pending.
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: pool, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: oldKey, creationID: replacement, origin: .restored)],
                               origin: .panelClose)
        let closed = await coordinator.outcomes(for: [panel], timeout: 1)[panel]
        XCTAssertEqual(closed, .ended, "the close settles from the record, with the old key's shard pending")
        XCTAssertTrue(pendingEnds.saved.isEmpty)
        let oldShardCalls = await shards[0].calls
        XCTAssertFalse(oldShardCalls.contains("end"), "the old key needed no lookup")
    }

    /// B2 across a relaunch whose snapshot predates the refusal (no saved
    /// shard): the store holding the panel's current creation names the shard.
    func testARestoredRefusedCreationIsFoundByItsCreationID() async throws {
        let shards = fakes()
        let store = HCCreationIntentStore(directory: temporary.appendingPathComponent("c11-s4"))
        await shards[4].use(store: store)
        let panel = UUID()
        let creation = UUID()
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: [])
        _ = try await store.claim(request, coreID: "core-4", process: HCProcessIdentity(pid: 104, startTimeMicroseconds: 1))
        try await store.recordEnd(panelID: panel, creationID: creation, evidence: HCEndEvidence(id: UUID(), creationID: creation,
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .createRejected))
        let pool = try makePool(shards, placement: HCShardPlacement(), intents: [4: store])
        let lifecycle = await pool.route(panelID: panel).resolve(HCPanelIdentity(panelID: panel, creationID: creation, origin: .restored))
        guard case .ended = lifecycle else { return XCTFail("resolved in shard 4, got \(lifecycle)") }
        XCTAssertEqual(pool.placement.home(forPanel: panel), 4)
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [])
    }

    /// B3: shard 5's store is locked by another app incarnation while a stale
    /// snapshot points at shard 2. Nothing is created; once readable, the
    /// panel binds to the terminal shard 5 already runs.
    func testALockedStoreIsNeverReadAsAbsence() async throws {
        let shards = fakes()
        let panel = UUID()
        let workspace = UUID()
        let directory = temporary.appendingPathComponent("c11-s5")
        let store = HCCreationIntentStore(directory: directory)
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: UUID(), argv: [])
        _ = try await store.claim(request, coreID: "core-5", process: HCProcessIdentity(pid: 105, startTimeMicroseconds: 1))
        let onFive = await shards[5].seedLive(panel: panel)
        let placement = HCShardPlacement()
        placement.seed(workspace: workspace, shard: 2)
        let pool = try makePool(shards, placement: placement, intents: [5: store])
        XCTAssertEqual(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil)?.index, 2)
        let lockFD = Darwin.open(directory.appendingPathComponent("creation-intents.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        let restored = HCPanelIdentity(panelID: panel, origin: .restored)
        let locked = await pool.route(panelID: panel).resolve(restored)
        guard case .unresolved(_, .intentStoreFailure) = locked else { return XCTFail("a failed read is not absence, got \(locked)") }
        let create = await pool.route(panelID: panel).create(HCCreateRequest(identity: restored, creationID: UUID(), argv: [],
            shard: HCShardID(index: 2)))
        guard case .unresolved = create else { return XCTFail("no creation while a store is unreadable, got \(create)") }
        let placedCalls = await shards[2].calls
        XCTAssertFalse(placedCalls.contains("create"))
        flock(lockFD, LOCK_UN); Darwin.close(lockFD)
        let bound = await pool.route(panelID: panel).resolve(restored)
        XCTAssertEqual(identity(bound), onFive)
    }

    /// B4: a refresh collected before shard 1 reconnected must not bring back
    /// its retired generation over the newer pending one.
    func testADelayedReadNeverRestoresARetiredGeneration() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let a = UUID()
        _ = await open(panel: a, workspace: a, in: pool)
        _ = await pool.snapshot()
        await shards[1].setHoldRefresh(true)
        let refreshing = Task { await pool.refresh() }
        for _ in 0..<400 { if await shards[1].refreshHeld { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        await shards[1].goPending(.connectionLost)
        let observed = await pool.snapshot()
        guard case .pending = observed.shardReadiness[HCShardID(index: 1)] else { return XCTFail("the loss is seen") }
        await shards[1].releaseRefresh()
        let collected = await refreshing.value
        guard case .pending = collected.shardReadiness[HCShardID(index: 1)] else {
            return XCTFail("the retired generation came back: \(String(describing: collected.shardReadiness))")
        }
        let after = await pool.snapshot()
        guard case .pending = after.shardReadiness[HCShardID(index: 1)] else { return XCTFail("stays revoked") }
    }

    /// B1: S0 and shard 1 ready, shard 2 down. Each consumer judges a record
    /// by its own shard through the pool's real merged snapshot.
    private func mixedPool() async throws -> (HCShardPool, HCInventorySnapshot, s0: HCTerminalKey, s1: HCTerminalKey,
                                               s2: HCTerminalKey, panel1: UUID, panel2: UUID) {
        let shards = fakes()
        let s0 = await shards[0].seedLive(panel: nil)
        let s1 = await shards[1].seedLive(panel: nil)
        let s2 = await shards[2].seedLive(panel: nil)
        let pool = try makePool(shards, placement: HCShardPlacement())
        _ = await pool.snapshot()
        await shards[2].goPending(.connectionLost)
        let merged = await pool.snapshot()
        return (pool, merged, s0, s1, s2, UUID(), UUID())
    }

    func testRecoveredTakesEveryReadyShardsOrphans() async throws {
        let mixed = try await mixedPool()
        let recovered = HCRecoveredTerminalPlanner.recoveries(from: mixed.1, identities: [], restoreComplete: true)
        XCTAssertEqual(Set(recovered.map(\.record.key)), [mixed.s0, mixed.s1], "shard 2 is down: only its own orphan waits")
    }

    func testAgentRecoveryKeepsHealthyShardsObservers() async throws {
        let mixed = try await mixedPool()
        var state = HCAgentRecoveryState(readProcess: { pid in
            HCAgentRecoveryProcessFacts(identity: HCProcessIdentity(pid: pid, startTimeMicroseconds: 1), controllingTTYDevice: 7)
        }, ttyName: { _ in "ttys007" })
        state.setClaims([mixed.panel1: mixed.s1, mixed.panel2: mixed.s2])
        XCTAssertTrue(state.accept(mixed.1))
        XCTAssertEqual(state.observations.map(\.key), [mixed.s1])
    }

    func testCaptureOfAHealthyShardIsNotHeldByAnotherShardsOutage() async throws {
        let mixed = try await mixedPool()
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: HCPanelIdentity(panelID: mixed.panel1, key: mixed.s1),
            panelID: mixed.panel1, inventory: mixed.1), .live)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: HCPanelIdentity(panelID: mixed.panel2, key: mixed.s2),
            panelID: mixed.panel2, inventory: mixed.1), .pending)
    }

    // MARK: C11H-91: shards off by default

    func testShardsAreOffUnlessTheSettingTurnsThemOn() throws {
        let suite = "c11.shards.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(HCShardSettings.isEnabled(defaults), "default off: 1.7.6-h3's single session")
        defaults.set(true, forKey: HCShardSettings.enabledKey)
        XCTAssertTrue(HCShardSettings.isEnabled(defaults))
        defaults.set(false, forKey: HCShardSettings.enabledKey)
        XCTAssertFalse(HCShardSettings.isEnabled(defaults))
        // Off: every pool shard is read-only, S0 never is; on: none is.
        XCTAssertTrue((1...HCShardPool.size).allSatisfy { HCShardSettings.isReadOnly(shard: $0, enabled: false) })
        XCTAssertFalse(HCShardSettings.isReadOnly(shard: 0, enabled: false))
        XCTAssertFalse((0...HCShardPool.size).contains { HCShardSettings.isReadOnly(shard: $0, enabled: true) })
    }

    func testShardsOffPutsEveryNewWorkspaceOnS0AndStartsNoPoolShard() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement(), placementEnabled: false)
        var keys: [HCTerminalKey?] = []
        for _ in 0..<3 {
            let workspace = UUID()
            keys.append(await open(panel: workspace, workspace: workspace, in: pool))
            keys.append(await open(panel: UUID(), workspace: workspace, in: pool))
        }
        XCTAssertEqual(keys.map { $0?.owningCoreID }, Array(repeating: "core-0", count: 6))
        XCTAssertEqual(pool.creationTarget(panelID: UUID(), workspaceID: UUID(), machine: nil)?.name, "c11")
        for shard in shards where shard.index > 0 {
            let started = await shard.started
            XCTAssertFalse(started, "shard \(shard.index) started with shards off")
        }
    }

    func testShardsOffStillReadsALivePoolShardAndSendsNewTerminalsToS0() async throws {
        let shards = fakes()
        let panel = UUID()
        let workspace = UUID()
        let onThree = await shards[3].seedLive(panel: panel)   // made while shards were on
        let placement = HCShardPlacement()
        placement.seed(workspace: workspace, shard: 3)
        placement.seed(panel: panel, home: 3)
        let pool = try makePool(shards, placement: placement, placementEnabled: false)
        let lifecycle = await pool.route(panelID: panel).resolve(HCPanelIdentity(panelID: panel, key: onThree, origin: .restored))
        XCTAssertEqual(identity(lifecycle), onThree, "nothing a shard build made is orphaned")
        let split = await open(panel: UUID(), workspace: workspace, in: pool)
        XCTAssertEqual(split?.owningCoreID, "core-0", "new terminals go to S0 even in a workspace placed on a shard")
        let created = await shards[3].calls.filter { $0 == "create" }
        XCTAssertEqual(created, [])
    }

    /// With shards off a pool shard's session never launches a core, through a
    /// real resolve and create; S0's still does, and shards on launch as before.
    func testOnlyS0LaunchesACoreWhileShardsAreOff() async throws {
        func launches(shard: Int, enabled: Bool) async throws -> [String] {
            let log = HCStartedLog()
            let configuration = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: shard, inherited: [:])
            let session = HCManagedSession(configuration: configuration, connections: HCNoCoreFactory(),
                verifier: HCShardTestVerifier(),
                launcher: HCShardSettings.launcher(forShard: shard, enabled: enabled, base: HCRecordingLauncher(log: log)),
                intents: HCCreationIntentStore(directory: temporary.appendingPathComponent("launch-\(shard)-\(enabled)")),
                prepareAttachment: { _, _, _, display in display })
            let fresh = HCPanelIdentity(panelID: UUID(), origin: .fresh)
            _ = await session.resolve(fresh)
            _ = await session.create(HCCreateRequest(identity: fresh, creationID: UUID(), argv: []))
            return log.all
        }
        let offPool = try await launches(shard: 4, enabled: false)
        XCTAssertEqual(offPool, [], "no c11-s4 core or socket while shards are off")
        let offLegacy = try await launches(shard: 0, enabled: false)
        XCTAssertFalse(offLegacy.isEmpty, "S0 starts its core as in 1.7.6-h3")
        XCTAssertTrue(offLegacy.allSatisfy { $0 == "c11" })
        let onPool = try await launches(shard: 4, enabled: true)
        XCTAssertFalse(onPool.isEmpty, "shards on: a pool shard starts on first use")
    }

    /// Sol B1/B2 on #127: a pool shard whose core is already serving (made
    /// while shards were on). With shards off its session reads but never
    /// creates or restarts: `hc run`, a direct create, `hc server restart`,
    /// a recovery and the automatic foreign-build recovery send nothing.
    private func servingSession(readOnly: Bool, pinned: Bool = true) throws -> (HCManagedSession, HCStartedLog, HCStartedLog) {
        let calls = HCStartedLog()
        let launches = HCStartedLog()
        let configuration = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: 3, inherited: [:])
        let session = HCManagedSession(configuration: configuration, connections: HCServingFactory(calls: calls, pinned: pinned),
            verifier: HCShardTestVerifier(), launcher: HCRecordingLauncher(log: launches),
            intents: HCCreationIntentStore(directory: temporary.appendingPathComponent("serving-\(readOnly)-\(pinned)")),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, identity in HCServingInventory(generation: connection.generation, identity: identity) },
            readOnly: readOnly)
        return (session, calls, launches)
    }

    func testAReadOnlyServingShardCreatesNothing() async throws {
        let (session, calls, launches) = try servingSession(readOnly: true)
        let fresh = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        guard case .new = await session.resolve(fresh) else { return XCTFail("it still reads its serving core") }
        let created = await session.create(HCCreateRequest(identity: fresh, creationID: UUID(), argv: ["/bin/zsh"]))
        guard case .rejectedBeforeTransmission = created else { return XCTFail("refused: \(created)") }
        let run = HCManagedCommand(session: "c11-s3", socket: "/Users/tester/.local/share/c11/run/c11-s3.sock",
                                   verb: .run, argv: ["/bin/zsh"])
        do { _ = try await session.managedCommand(run); XCTFail("hc run on a read-only shard") } catch {}
        let list = HCManagedCommand(session: "c11-s3", socket: "/Users/tester/.local/share/c11/run/c11-s3.sock", verb: .list)
        let inventory = try await session.managedCommand(list)
        XCTAssertEqual(inventory["terminals"], .array([]))
        XCTAssertEqual(inventory["partial"], .bool(false))
        XCTAssertFalse(calls.all.contains("terminal.run"), "no terminal.run reached the pool shard: \(calls.all)")
        XCTAssertTrue(calls.all.contains("terminal.list"), "reads still work")
        XCTAssertEqual(launches.all, [])
        // Shards on: the same serving shard takes the run.
        let (open, openCalls, _) = try servingSession(readOnly: false)
        _ = try await open.managedCommand(run)
        XCTAssertTrue(openCalls.all.contains("terminal.run"))
    }

    func testAReadOnlyServingShardIsNeverRestarted() async throws {
        let (session, calls, launches) = try servingSession(readOnly: true)
        let fresh = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        _ = await session.resolve(fresh)
        let restart = HCManagedCommand(session: "c11-s3", socket: "/Users/tester/.local/share/c11/run/c11-s3.sock", verb: .restart)
        do { _ = try await session.managedCommand(restart); XCTFail("hc server restart on a read-only shard") } catch {}
        guard case .refused = await session.recoverSession(reason: .foreignBuild) else { return XCTFail("refused before anything") }
        XCTAssertFalse(calls.all.contains("server.restart"), "\(calls.all)")
        XCTAssertEqual(launches.all, [])
        // Still usable afterwards: its inventory is ready and it resolves.
        let after = await session.snapshot()
        guard case .ready = after.readiness else { return XCTFail("the serving session stays usable") }
        guard case .new = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh)) else { return XCTFail("resolves") }
        // A foreign build found on connect is left running: no restart, no launch.
        let (foreign, foreignCalls, foreignLaunches) = try servingSession(readOnly: true, pinned: false)
        guard case .unresolved(_, .foreignBuild) = await foreign.resolve(fresh) else { return XCTFail("left alone") }
        XCTAssertFalse(foreignCalls.all.contains("server.restart"))
        XCTAssertEqual(foreignLaunches.all, [])
    }

    // MARK: C11H-92 (hc Lead's fix-forward 1-3)

    /// 1: a pre-shard panel whose S0 terminal ended and was recreated in shard 1.
    /// S0 keeps its binding to the dead terminal; the merged view gives the live one.
    func testAPanelsBindingIsItsHomeShards() async throws {
        let shards = fakes()
        let panel = UUID()
        let dead = await shards[0].seedLive(panel: panel)
        await shards[0].bind(panel, dead)
        await shards[0].finish(dead)
        let live = await shards[1].seedLive(panel: panel)
        await shards[1].bind(panel, live)
        let placement = HCShardPlacement()
        placement.seed(panel: panel, home: 1)
        let pool = try makePool(shards, placement: placement)
        let merged = await pool.snapshot()
        XCTAssertEqual(merged.panelBindings[panel], live)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: nil, panelID: panel, inventory: merged), .live,
                       "capture reads the live terminal, not S0's dead one")
    }

    /// 3: a saved session this app does not have is never guessed as S0; the
    /// panel stays unresolved until a shard reports its key's core.
    func testAnUnknownShardIsUnresolvedUntilAShardReportsIt() async throws {
        let shards = fakes()
        let panel = UUID()
        // Shard 3 has not reported yet: its core's first terminal will be this key.
        let key = HCTerminalKey(owningCoreID: "core-3", localAddress: "t1")
        let placement = HCShardPlacement()
        placement.seedUnknownShard(panel: panel)
        let pool = try makePool(shards, placement: placement)
        let restored = HCPanelIdentity(panelID: panel, key: key, origin: .restored)
        let first = await pool.route(panelID: panel).resolve(restored)
        guard case .unresolved(_, .inventoryPending) = first else { return XCTFail("never guessed: \(first)") }
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [], "S0 is not asked, so not started")
        let reported = await shards[3].seedLive(panel: panel)
        XCTAssertEqual(reported, key)
        _ = await pool.snapshot()   // shard 3 reports its core
        let second = await pool.route(panelID: panel).resolve(restored)
        XCTAssertEqual(identity(second), key)
        XCTAssertEqual(pool.placement.home(forPanel: panel), 3)
    }

    /// Grok on #141: restore's own decision, the production writer of the
    /// unknown flag. An unrecognized saved session is unresolved, S0 is not
    /// asked, and the panel's home is the shard that reports its key's core. A
    /// known session seeds its home; no session marks nothing (pre-shard: S0).
    func testRestoreMarksAnUnrecognizedSessionAsAnUnknownShard() async throws {
        let shards = fakes()
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core-3", localAddress: "t1")
        let placement = HCShardPlacement()
        let pool = try makePool(shards, placement: placement)
        pool.seedRestored(panel: panel, savedSession: "c11-renamed-s3")
        let restored = HCPanelIdentity(panelID: panel, key: key, origin: .restored)
        let first = await pool.route(panelID: panel).resolve(restored)
        guard case .unresolved(_, .inventoryPending) = first else { return XCTFail("never guessed: \(first)") }
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [], "S0 is not asked, so a label match there cannot bind another terminal")
        let reported = await shards[3].seedLive(panel: panel)
        XCTAssertEqual(reported, key)
        _ = await pool.snapshot()   // shard 3 reports its core
        let second = await pool.route(panelID: panel).resolve(restored)
        XCTAssertEqual(identity(second), key)
        XCTAssertEqual(placement.home(forPanel: panel), 3)
        let (known, older) = (UUID(), UUID())
        pool.seedRestored(panel: known, savedSession: "c11-s2")
        XCTAssertEqual(placement.home(forPanel: known), 2)
        XCTAssertFalse(placement.shardIsUnknown(panel: known))
        pool.seedRestored(panel: older, savedSession: nil)
        XCTAssertNil(placement.home(forPanel: older))
        XCTAssertFalse(placement.shardIsUnknown(panel: older), "a pre-shard snapshot still resolves in S0")
    }

    /// Grok on #141 (non-blocking 2): a home shard that has not published a
    /// binding yet clears S0's stale one rather than letting it stand.
    func testAHomeShardWithNoBindingYetClearsS0sStaleOne() async throws {
        let shards = fakes()
        let panel = UUID()
        let dead = await shards[0].seedLive(panel: panel)
        await shards[0].bind(panel, dead)
        await shards[0].finish(dead)
        let placement = HCShardPlacement()
        placement.seed(panel: panel, home: 2)
        let pool = try makePool(shards, placement: placement)
        let merged = await pool.snapshot()
        XCTAssertNil(merged.panelBindings[panel], "S0's dead terminal is not the panel's")
    }

    /// 2 (route side): what a panel's route forwards names its shard.
    func testARouteNamesTheShardOfEachSnapshot() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let a = UUID()
        _ = await open(panel: a, workspace: a, in: pool)
        let seen = HCCollected()
        let queue = DispatchQueue(label: "test.route.source")
        // Waits for the seeded terminal, not a fixed 0.2 s: the fan-out queue can lag
        // that long on a loaded host (C11H-346).
        let delivered = expectation(description: "a hears the seeded terminal")
        delivered.assertForOverFulfill = false
        let observation = pool.route(panelID: a).observe(on: queue) { snapshot in
            seen.add(snapshot)
            if snapshot.records.count == 2 { delivered.fulfill() }
        }
        defer { observation.cancel() }
        await shards[1].seedLive(panel: nil)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertFalse(seen.all.isEmpty)
        XCTAssertTrue(seen.all.allSatisfy { $0.source == HCShardID(index: 1) })
    }

    // MARK: C11H-93 (hc Lead's fix-forward 4)

    /// A corrupt intent store in shard 6 blocks only shard 6's panel; a panel
    /// on shard 1 resolves, and a busy store (another incarnation) still waits.
    func testAnUnreadableStoreBlocksOnlyItsOwnShard() async throws {
        let shards = fakes()
        let directory = temporary.appendingPathComponent("c11-s6")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try PrivateFileWriter.write(Data("not json".utf8), to: directory.appendingPathComponent("creation-intents.json"))
        let broken = HCCreationIntentStore(directory: directory)
        let (onOne, onSix) = (UUID(), UUID())
        let liveOne = await shards[1].seedLive(panel: onOne)
        let liveSix = await shards[6].seedLive(panel: onSix)
        let placement = HCShardPlacement()
        placement.seed(panel: onOne, home: 1)
        placement.seed(panel: onSix, home: 6)
        let pool = try makePool(shards, placement: placement, intents: [6: broken])
        let one = await pool.route(panelID: onOne).resolve(HCPanelIdentity(panelID: onOne, key: liveOne, origin: .restored))
        XCTAssertEqual(identity(one), liveOne, "another shard's bad store blocks nothing here")
        let six = await pool.route(panelID: onSix).resolve(HCPanelIdentity(panelID: onSix, key: liveSix, origin: .restored))
        guard case .unresolved(_, .intentStoreFailure) = six else { return XCTFail("its own shard's store is unreadable: \(six)") }
        let sixCalls = await shards[6].calls
        XCTAssertEqual(sixCalls, [], "nothing is asked of shard 6 while its store is unreadable")
    }

    /// C11H-78 on C11H-91: a read-only shard never pairs. Its core gets no
    /// `machine.add`; with shards on, the same serving shard takes it.
    func testAReadOnlyServingShardIsNeverPaired() async throws {
        let (session, calls, _) = try servingSession(readOnly: true)
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let add: [String: HCJSONValue] = ["name": .string("studio"), "via": .string("/x"), "session": .string("c11-s3")]
        do { _ = try await session.pairingRequest("machine.add", params: add); XCTFail("machine.add on a read-only shard") } catch {}
        XCTAssertFalse(calls.all.contains("machine.add"), "\(calls.all)")
        let (open, openCalls, _) = try servingSession(readOnly: false)
        _ = await open.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        _ = try await open.pairingRequest("machine.add", params: add)
        XCTAssertTrue(openCalls.all.contains("machine.add"))
    }

    // MARK: C11H-113 (the hc Lead's #141 follow-ups 4b and 5)

    /// 4b: an unknown shard nobody owns stays pending only while a shard has
    /// not answered (or a serving one is not ready yet), then needs the
    /// operator: recovery_required, never eternal pending. A keyless panel too.
    /// S0 is never asked.
    func testAnUnownedUnknownShardNeedsRecoveryOnceEveryShardHasAnswered() async throws {
        let shards = fakes()
        await shards[2].setServing(true)
        await shards[2].goPending(.inventoryPending)
        let (keyed, keyless) = (UUID(), UUID())
        let key = HCTerminalKey(owningCoreID: "core-elsewhere", localAddress: "t1")
        let pool = try makePool(shards, placement: HCShardPlacement())
        pool.seedRestored(panel: keyed, savedSession: "c11-renamed-s4")
        pool.seedRestored(panel: keyless, savedSession: "c11-renamed-s5")
        let keyedIdentity = HCPanelIdentity(panelID: keyed, key: key, origin: .restored)
        let keylessIdentity = HCPanelIdentity(panelID: keyless, origin: .restored)
        guard case .unresolved(_, .inventoryPending) = await pool.route(panelID: keyed).resolve(keyedIdentity)
        else { return XCTFail("pending before any shard answers") }
        await pool.probeServingShards()
        _ = await pool.snapshot()
        XCTAssertFalse(pool.shardsSettled(), "serving shard 2 has not reported a ready inventory")
        guard case .unresolved(_, .inventoryPending) = await pool.route(panelID: keyed).resolve(keyedIdentity)
        else { return XCTFail("pending while a serving shard is not ready") }
        await shards[2].clearPending()
        _ = await pool.snapshot()
        XCTAssertTrue(pool.shardsSettled())
        guard case .unresolved(_, .recoveryRequired) = await pool.route(panelID: keyed).resolve(keyedIdentity)
        else { return XCTFail("no shard owns it: the operator decides") }
        guard case .unresolved(_, .recoveryRequired) = await pool.route(panelID: keyless).resolve(keylessIdentity)
        else { return XCTFail("a keyless unknown panel is never owned") }
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [], "S0 is never asked")
    }

    /// 4b Retry: recovering an unknown-shard panel asks every shard again and
    /// restarts nothing. A shard that came up since then owns it.
    func testRetryAsksTheShardsAgainAndFindsALateOwner() async throws {
        let shards = fakes()
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core-6", localAddress: "t1")
        let placement = HCShardPlacement()
        let pool = try makePool(shards, placement: placement)
        pool.seedRestored(panel: panel, savedSession: "c11-renamed-s6")
        let identity6 = HCPanelIdentity(panelID: panel, key: key, origin: .restored)
        await pool.probeServingShards()
        guard case .unresolved(_, .recoveryRequired) = await pool.route(panelID: panel).resolve(identity6)
        else { return XCTFail("nobody owns it yet") }
        await shards[6].setServing(true)
        let late = await shards[6].seedLive(panel: panel)
        XCTAssertEqual(late, key)
        guard case .recovered = await pool.route(panelID: panel).recoverSession(reason: .foreignBuild)
        else { return XCTFail("Retry re-probes rather than recovering another panel's core") }
        _ = await pool.snapshot()
        let lifecycle = await pool.route(panelID: panel).resolve(identity6)
        XCTAssertEqual(identity(lifecycle), key)
        XCTAssertEqual(placement.home(forPanel: panel), 6)
    }

    /// 5: while a recreated panel's new terminal is in flight its home may
    /// still be S0, whose binding is the dead terminal; then the home moves
    /// before shard 1 has bound anything. Capture never reads it as live.
    /// (Admission reads records and pids, never panel bindings.)
    func testARecreationInFlightNeverReadsS0sDeadTerminalAsLive() async throws {
        let shards = fakes()
        let (panel, workspace) = (UUID(), UUID())
        let dead = await shards[0].seedLive(panel: panel)
        await shards[0].bind(panel, dead)
        await shards[0].finish(dead)
        let placement = HCShardPlacement()
        placement.seed(panel: panel, home: 0)
        let pool = try makePool(shards, placement: placement)
        XCTAssertEqual(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil)?.index, 1)
        XCTAssertEqual(placement.home(forPanel: panel), 0, "target set, home still S0")
        let placed = await pool.snapshot()
        XCTAssertNotEqual(HCProcessAdmission.captureLiveness(identity: nil, panelID: panel, inventory: placed), .live)
        // createRouted moves the home just before it sends the run.
        placement.setHome(1, panel: panel)
        let sending = await pool.snapshot()
        XCTAssertNil(sending.panelBindings[panel], "shard 1 has bound nothing yet, and S0's dead key is not used")
        XCTAssertNotEqual(HCProcessAdmission.captureLiveness(identity: nil, panelID: panel, inventory: sending), .live)
    }

    // MARK: hc shim

    func testManagedCommandReachesTheShardItsTerminalNames() async throws {
        let sessions = try [0, 3].map { index in
            HCManagedSession(configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: index, inherited: [:]),
                connections: HCUnavailableRuntime(), verifier: HCShardTestVerifier(), launcher: HCShardTestLauncher(),
                intents: HCCreationIntentStore(directory: temporary.appendingPathComponent("s\(index)")),
                prepareAttachment: { _, _, _, display in display })
        }
        await HCManagedCommandEndpoint.shared.install(sessions)
        let command = HCManagedCommand(session: "c11-s3", socket: "/Users/tester/.local/share/c11/run/c11-s3.sock", verb: .status)
        var failure: Error?
        do { _ = try await HCManagedCommandEndpoint.shared.perform(command) } catch { failure = error }
        await HCManagedCommandEndpoint.shared.uninstall()
        // Shard 3 owns it and tries its own socket (no core serves in a test);
        // any other session would refuse it as foreign.
        XCTAssertEqual(failure as? HCUnavailableReason, .backendNotInstalled)
    }

    // MARK: Holder loss (C11H-125)

    /// The shard half of "each conversation resumes once" after a holder loss:
    /// a pool-shard terminal that finished `holder_lost` resolves ended in its
    /// own shard, and the replacement created with that proof binds there.
    /// S0 is never asked, and the panel's home does not move.
    func testAHolderLostTerminalEndsAndIsReplacedInItsOwnShard() async throws {
        let shards = fakes()
        let pool = try makePool(shards, placement: HCShardPlacement())
        let (panel, workspace) = (UUID(), UUID())
        let target = try XCTUnwrap(pool.creationTarget(panelID: panel, workspaceID: workspace, machine: nil))
        XCTAssertEqual(target.index, 1)
        let route = pool.route(panelID: panel)
        let fresh = HCPanelIdentity(panelID: panel, origin: .fresh)
        let first = await route.create(
            HCCreateRequest(identity: fresh, creationID: UUID(), argv: ["/bin/zsh"], shard: target.id))
        let lost = try XCTUnwrap(boundKey(first))
        _ = await pool.snapshot()
        await shards[1].finish(lost, reason: "holder_lost")
        _ = await pool.refresh()
        let known = HCPanelIdentity(panelID: panel, key: lost, origin: .restored)
        let ended = await route.resolve(known)
        guard case .ended(let proof) = ended, proof.key == lost else { return XCTFail("ended in shard 1, got \(ended)") }
        XCTAssertEqual(pool.placement.home(forPanel: panel), 1)
        // The replacement (Workspace's conversation recovery) reuses the launch's shard.
        let replaced = await route.create(
            HCCreateRequest(identity: known, creationID: UUID(), argv: ["/bin/zsh"], shard: target.id))
        let replacement = try XCTUnwrap(boundKey(replaced))
        XCTAssertEqual(replacement.owningCoreID, "core-1", "the replacement runs in the shard that lost its holder")
        XCTAssertNotEqual(replacement, lost)
        XCTAssertEqual(pool.placement.home(forPanel: panel), 1)
        _ = await pool.refresh()
        let live = await route.resolve(HCPanelIdentity(panelID: panel, key: replacement, origin: .restored))
        XCTAssertEqual(identity(live), replacement)
        let legacyCalls = await shards[0].calls
        XCTAssertEqual(legacyCalls, [], "never S0")
    }
}

private struct HCShardTestVerifier: HCPeerVerifying {
    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer {
        throw HCUnavailableReason.foreignSession
    }
    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {}
}

/// A core already serving the shard's socket: records every RPC method.
private struct HCServingFactory: HCConnectionFactory {
    let calls: HCStartedLog
    let pinned: Bool
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        HCServingConnection(generation: request.generation, calls: calls, pinned: pinned, pin: request.configuration.pin)
    }
}

private final class HCServingConnection: HCConnection, @unchecked Sendable {
    let generation: UInt64
    let calls: HCStartedLog
    let peer: HCPeerEvidence
    let verification: HCVerifiedPeer
    init(generation: UInt64, calls: HCStartedLog, pinned: Bool, pin: HCPin) {
        self.generation = generation
        self.calls = calls
        peer = HCPeerEvidence(uid: getuid(), pid: 303, statusPID: 303, coreID: "core-3", version: pin.version,
                              protocolGeneration: 1, methods: [], features: [])
        verification = HCVerifiedPeer(identity: HCBuildIdentity(pin: pin, executablePath: "/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: 303, startTimeMicroseconds: 1), coreID: "core-3", protocolGeneration: 1),
            isPinnedBuild: pinned)
    }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue {
        calls.add(request.method)
        if request.method == "terminal.list" { return .object(["terminals": .array([])]) }
        return .object([:])
    }
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        throw HCUnavailableReason.backendNotInstalled
    }
    func close(reason: HCUnavailableReason) {}
}

private struct HCServingInventory: HCInventorySource {
    let generation: UInt64
    let identity: HCBuildIdentity
    private var current: HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: 1)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, buildIdentity: identity)
    }
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        let snapshot = current
        queue.async { handler(snapshot) }
        return HCObservation()
    }
    func snapshot() async -> HCInventorySnapshot { current }
    func refresh() async -> HCInventorySnapshot { current }
}

/// No core is serving: every connect finds no socket.
private struct HCNoCoreFactory: HCConnectionFactory {
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        throw HCUnavailableReason.coreUnreachable
    }
}

private struct HCRecordingLauncher: HCCoreLaunching {
    let log: HCStartedLog
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        log.add(configuration.session)
        throw HCUnavailableReason.coreUnreachable
    }
}

private struct HCShardTestLauncher: HCCoreLaunching {
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        throw HCUnavailableReason.coreUnreachable
    }
}

/// C11H-238 (F2, F4): the pool's one fan-out from shard snapshots to panel
/// observers. Driven directly: snapshots go in through `receive`, a test clock
/// and scheduler stand in for time, and deliveries land on a test queue.
final class HCHomeFanoutTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var homes: [UUID: Int] = [:]
        var now: Double = 100
        var scheduled: [(Double, @Sendable () -> Void)] = []
        var seen: [UUID: [HCInventorySnapshot]] = [:]
        /// While set, each clock read waits (briefly) for a handler to run:
        /// it lets a target drain start between two observers' matching.
        var gate: DispatchSemaphore?
        func home(_ panel: UUID) -> Int? { lock.lock(); defer { lock.unlock() }; return homes[panel] }
        func setHome(_ panel: UUID, _ shard: Int) { lock.lock(); homes[panel] = shard; lock.unlock() }
        func add(_ panel: UUID, _ snapshot: HCInventorySnapshot) {
            lock.lock(); seen[panel, default: []].append(snapshot); lock.unlock()
        }
        func got(_ panel: UUID) -> [HCInventorySnapshot] { lock.lock(); defer { lock.unlock() }; return seen[panel] ?? [] }
    }

    private let box = Box()
    private let target = DispatchQueue(label: "test.fanout.target")
    private var fanout: HCHomeFanout!
    private var observations: [HCObservation] = []
    private var sequence: [Int: UInt64] = [:]

    override func setUp() {
        let box = self.box
        fanout = HCHomeFanout(home: { box.home($0) }, clock: {
            box.lock.lock(); let gate = box.gate; let now = box.now; box.lock.unlock()
            _ = gate?.wait(timeout: .now() + 0.05)
            return now
        }, meter: nil)
        fanout.scheduleForTesting = { due, body in box.lock.lock(); box.scheduled.append((due, body)); box.lock.unlock() }
    }

    override func tearDown() { observations.forEach { $0.cancel() }; observations = [] }

    private func key(_ n: Int) -> HCTerminalKey { HCTerminalKey(owningCoreID: "core", localAddress: "t\(n)") }

    private func record(_ n: Int, title: String = "idle", status: String? = "idle") -> HCTerminalRecord {
        HCTerminalRecord(key: key(n), state: .running, pid: Int32(n), title: title, status: status)
    }

    private func snapshot(_ shard: Int, _ records: [HCTerminalRecord], generation: UInt64 = 1,
                          pending: HCUnavailableReason? = nil, sequence explicit: UInt64? = nil) -> HCInventorySnapshot {
        let next = explicit ?? (sequence[shard, default: 0] + 1)
        sequence[shard] = next
        let revision = HCRevision(connectionGeneration: generation, sequence: next)
        return HCInventorySnapshot(readiness: pending.map { .pending($0) } ?? .ready(revision), revision: revision,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }), source: HCShardID(index: shard))
    }

    @discardableResult
    private func observe(_ panel: UUID, home: Int, key: HCTerminalKey?) -> HCHomeInterest {
        box.setHome(panel, home)
        let interest = HCHomeInterest(key: key)
        let box = self.box
        observations.append(fanout.register(panelID: panel, on: target, interest: interest) { box.add(panel, $0) })
        return interest
    }

    private func settle() { fanout.sync(); target.sync {}; fanout.sync(); target.sync {} }

    private func feed(_ shard: Int, _ snapshot: HCInventorySnapshot) { fanout.receive(shard, snapshot); settle() }

    func testOnlyThePanelWhoseRecordChangedIsCalledInOneHop() {
        let panels = (0..<10).map { _ in UUID() }
        for (n, panel) in panels.enumerated() { observe(panel, home: 1, key: key(n)) }
        let records = (0..<10).map { record($0) }
        feed(1, snapshot(1, records))
        XCTAssertTrue(panels.allSatisfy { box.got($0).count == 1 }, "every panel gets its first snapshot")
        let hops = fanout.hopCount
        var changed = records
        changed[3] = record(3, status: "working")
        feed(1, snapshot(1, changed))
        XCTAssertEqual(box.got(panels[3]).count, 2)
        XCTAssertEqual(panels.enumerated().filter { $0.offset != 3 }.map { box.got($0.element).count }, Array(repeating: 1, count: 9))
        XCTAssertEqual(fanout.hopCount, hops + 1, "one main hop for the snapshot")
        // A snapshot that changes nothing any panel watches reaches nobody.
        feed(1, snapshot(1, changed + [record(42)]))
        XCTAssertEqual(fanout.hopCount, hops + 1)
    }

    func testAMovedPanelGetsItsNewHomeOnlyAndAnotherShardsOutageNeverReachesIt() {
        let panel = UUID(), neighbour = UUID()
        observe(panel, home: 1, key: key(1))
        observe(neighbour, home: 2, key: key(2))
        feed(1, snapshot(1, [record(1)]))
        feed(2, snapshot(2, [record(2)]))
        box.setHome(panel, 2)
        fanout.placementChanged(panelID: panel)
        settle()
        XCTAssertEqual(box.got(panel).last?.source, HCShardID(index: 2), "the new home's current snapshot at once")
        let count = box.got(panel).count
        feed(1, snapshot(1, [record(1, status: "working")], pending: nil))
        feed(1, snapshot(1, [], pending: .connectionLost))
        XCTAssertEqual(box.got(panel).count, count, "the old home's snapshots and outage stop at the move")
        XCTAssertEqual(box.got(neighbour).count, 1, "shard 1's outage never reaches shard 2's panels")
    }

    func testAnOutageReachesEveryPanelHomedThereThoughNoRecordChanged() {
        let a = UUID(), b = UUID(), keyless = UUID()
        observe(a, home: 3, key: key(1))
        observe(b, home: 3, key: key(2))
        observe(keyless, home: 3, key: nil)
        feed(3, snapshot(3, [record(1), record(2)]))
        feed(3, snapshot(3, [record(1), record(2)], pending: .connectionLost))
        for panel in [a, b, keyless] {
            guard case .pending(.connectionLost)? = box.got(panel).last?.readiness else { return XCTFail("no outage for \(panel)") }
        }
        // Reconnect: a fresh generation with the same records reaches them all again.
        feed(3, snapshot(3, [record(1), record(2)], generation: 2))
        for panel in [a, b, keyless] {
            XCTAssertEqual(box.got(panel).last?.revision.connectionGeneration, 2)
            guard case .ready? = box.got(panel).last?.readiness else { return XCTFail("not ready again") }
        }
    }

    func testAnOlderSnapshotIsNeverDeliveredAfterANewerOne() {
        let panel = UUID()
        observe(panel, home: 1, key: key(1))
        feed(1, snapshot(1, [record(1, status: "working")], sequence: 9))
        feed(1, snapshot(1, [record(1, status: "idle")], sequence: 4))
        feed(1, snapshot(1, [record(1, status: "done")], generation: 0, sequence: 20))
        XCTAssertEqual(box.got(panel).map(\.revision.sequence), [9])
    }

    func testALateObserverGetsItsHomesCurrentSnapshot() {
        feed(5, snapshot(5, [record(1)]))
        feed(6, snapshot(6, [record(1, status: "elsewhere")]))
        let panel = UUID()
        observe(panel, home: 5, key: key(1))
        settle()
        XCTAssertEqual(box.got(panel).count, 1)
        XCTAssertEqual(box.got(panel).first?.source, HCShardID(index: 5))
    }

    func testAChangedInterestKeyIsMatchedAgainstTheCurrentSnapshot() {
        let panel = UUID()
        let interest = observe(panel, home: 1, key: nil)
        feed(1, snapshot(1, [record(1)]))
        feed(1, snapshot(1, [record(1), record(2)]))
        XCTAssertEqual(box.got(panel).count, 2, "keyless: every revision")
        interest.key = key(2)
        settle()
        XCTAssertEqual(box.got(panel).count, 3, "a new key is matched now")
        feed(1, snapshot(1, [record(1, status: "working"), record(2)]))
        XCTAssertEqual(box.got(panel).count, 3, "another terminal's change is not this panel's")
    }

    func testTitleOnlyChangesAreCoalescedAndTheLastTitleLands() {
        let panel = UUID()
        observe(panel, home: 1, key: key(1))
        feed(1, snapshot(1, [record(1, title: "⠋ working")]))
        XCTAssertEqual(box.got(panel).count, 1)
        for (offset, frame) in ["⠙", "⠹", "⠸", "⠼"].enumerated() {
            box.lock.lock(); box.now = 100 + 0.05 * Double(offset + 1); box.lock.unlock()
            feed(1, snapshot(1, [record(1, title: "\(frame) working")]))
        }
        XCTAssertEqual(box.got(panel).count, 1, "title frames inside the window wait")
        box.lock.lock(); let pending = box.scheduled; box.scheduled = []; box.now = 100.25; box.lock.unlock()
        XCTAssertEqual(pending.count, 1, "one trailing delivery")
        XCTAssertEqual(pending.first?.0 ?? 0, 100.25, accuracy: 0.0001)
        pending.forEach { $0.1() }
        settle()
        XCTAssertEqual(box.got(panel).count, 2)
        XCTAssertEqual(box.got(panel).last?.records[key(1)]?.title, "⠼ working", "the newest title lands")
        // A spinner that stops: its final title lands too.
        box.lock.lock(); box.now = 100.30; box.lock.unlock()
        feed(1, snapshot(1, [record(1, title: "done")]))
        box.lock.lock(); let last = box.scheduled; box.scheduled = []; box.now = 100.5; box.lock.unlock()
        last.forEach { $0.1() }
        settle()
        XCTAssertEqual(box.got(panel).last?.records[key(1)]?.title, "done")
    }

    func testATitleThatArrivesWithAStatusOrTurnChangeIsNotDelayed() {
        let panel = UUID()
        observe(panel, home: 1, key: key(1))
        feed(1, snapshot(1, [record(1, title: "⠋ working", status: "working")]))
        box.lock.lock(); box.now = 100.05; box.lock.unlock()
        feed(1, snapshot(1, [record(1, title: "⠙ working", status: "idle")]))
        XCTAssertEqual(box.got(panel).count, 2, "a status edge is never delayed")
        box.lock.lock(); box.now = 100.08; box.lock.unlock()
        let turned = HCTerminalRecord(key: key(1), state: .running, pid: 1, title: "⠹ working", status: "idle", turn: 5)
        feed(1, snapshot(1, [turned]))
        XCTAssertEqual(box.got(panel).count, 3, "a turn edge is never delayed")
        box.lock.lock(); let scheduled = box.scheduled; box.lock.unlock()
        XCTAssertTrue(scheduled.isEmpty)
    }

    // MARK: Review 1 repairs

    /// An outage and its recovery both reach an observer whose queue was
    /// stalled through both, and so does a remote line that dropped and came
    /// back inside one local connection generation. Same-continuity changes
    /// still fold to the newest.
    func testAStalledQueueStillReceivesAnOutageAndItsRecoveryInOrder() {
        let local = UUID(), remote = UUID()
        let remoteKey = HCTerminalKey(owningCoreID: "studio", localAddress: "t9")
        func remoteRecord(_ availability: HCMachineAvailability, status: String = "idle") -> HCTerminalRecord {
            HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio", machineAvailability: availability,
                             pid: 9, status: status)
        }
        observe(local, home: 1, key: key(1))
        observe(remote, home: 1, key: remoteKey)
        feed(1, snapshot(1, [record(1), remoteRecord(.connected)]))
        target.suspend()
        fanout.receive(1, snapshot(1, [], pending: .connectionLost)); fanout.sync()
        fanout.receive(1, snapshot(1, [record(1), remoteRecord(.connected)], generation: 2)); fanout.sync()
        fanout.receive(1, snapshot(1, [record(1), remoteRecord(.disconnected)], generation: 2)); fanout.sync()
        fanout.receive(1, snapshot(1, [record(1, status: "working"), remoteRecord(.connected)], generation: 2)); fanout.sync()
        fanout.receive(1, snapshot(1, [record(1, status: "idle"), remoteRecord(.connected, status: "working")], generation: 2))
        fanout.sync()
        target.resume()
        settle()
        let localSeen = box.got(local).dropFirst().map { snapshot -> String in
            if case .pending = snapshot.readiness { return "pending" }
            return "ready\(snapshot.revision.connectionGeneration):\(snapshot.records[key(1)]?.status ?? "-")"
        }
        XCTAssertEqual(localSeen, ["pending", "ready2:idle"],
                       "the outage survives the stall; the same-continuity changes after it fold to the newest")
        let remoteSeen = box.got(remote).dropFirst().map { snapshot -> String in
            if case .pending = snapshot.readiness { return "pending" }
            return snapshot.records[remoteKey].map { $0.machineAvailability.rawValue } ?? "absent"
        }
        XCTAssertEqual(remoteSeen, ["pending", "connected", "disconnected", "connected"],
                       "a line that dropped and came back while the queue was stalled still retires the old stream")
    }

    /// A snapshot that changes many observers wakes each target queue once,
    /// even when a drain starts while the snapshot is still being matched.
    func testOneSnapshotIsOneHopPerTargetHoweverManyPanelsItChanges() {
        let panels = (0..<8).map { _ in UUID() }
        let box = self.box
        for (n, panel) in panels.enumerated() {
            box.setHome(panel, 1)
            observations.append(fanout.register(panelID: panel, on: target, interest: HCHomeInterest(key: key(n))) {
                box.add(panel, $0)
                box.lock.lock(); let gate = box.gate; box.lock.unlock()
                gate?.signal()
            })
        }
        feed(1, snapshot(1, (0..<8).map { record($0) }))
        let before = fanout.hopCount
        box.lock.lock(); box.gate = DispatchSemaphore(value: 0); box.lock.unlock()
        feed(1, snapshot(1, (0..<8).map { record($0, status: "working") }))
        box.lock.lock(); box.gate = nil; box.lock.unlock()
        XCTAssertEqual(fanout.hopCount - before, 1, "one hop for the snapshot")
        XCTAssertTrue(panels.enumerated().allSatisfy { box.got($0.element).last?.records[key($0.offset)]?.status == "working" })
    }
}

/// Review 1 (finding 2): a live record published from outside the inventory
/// (a reattach publishing the record it resolved before awaiting its
/// attachment) never hides a newer inventory record for good.
final class HCInventoryReconcileTests: XCTestCase {
    private struct FanoutSession: HCSession, HCInterestObserving {
        let fanout: HCHomeFanout
        let panel: UUID
        let base = HCUnavailableRuntime()
        func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
            fanout.register(panelID: panel, on: queue, interest: nil, handler: handler)
        }
        func observe(on queue: DispatchQueue, interest: HCHomeInterest,
                     handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
            fanout.register(panelID: panel, on: queue, interest: interest, handler: handler)
        }
        func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { await base.resolve(identity) }
        func create(_ request: HCCreateRequest) async -> HCCreateResult { await base.create(request) }
        func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
            try await base.attach(key, sink: sink, display: display)
        }
        func end(_ key: HCTerminalKey) async -> HCEndResult { await base.end(key) }
        func diagnostics() async -> HCDiagnostics { await base.diagnostics() }
        func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await base.recoverSession(reason: reason) }
    }

    @MainActor
    private func pump(_ fanout: HCHomeFanout) async {
        for _ in 0..<4 { fanout.sync(); try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @MainActor
    func testAnOlderRecordPublishedByAReattachIsReconciledToTheInventorysNewest() async {
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t3")
        let fanout = HCHomeFanout(home: { _ in 1 }, meter: nil)
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key),
                                     session: FanoutSession(fanout: fanout, panel: panel), registrar: { _, _ in })
        _ = await runtime.resolveIdentity()  // subscribes to the inventory
        var sequence: UInt64 = 0
        func feed(_ records: [HCTerminalRecord]) async {
            sequence += 1
            let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
            fanout.receive(1, HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }), source: HCShardID(index: 1)))
            await pump(fanout)
        }
        let a = HCTerminalRecord(key: key, state: .running, pid: 7, title: "⠋ working", status: "working", turn: 4)
        let b = HCTerminalRecord(key: key, state: .running, pid: 7, title: "done", status: "idle", turn: 4)
        let other = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "core", localAddress: "t4"), state: .running)
        await feed([a, other])
        await feed([b, other])
        guard case .live(let first) = runtime.lifecycle else { return XCTFail("not live") }
        XCTAssertEqual(first, b)
        // The reconnect coordinator's attachment completes and publishes the
        // record it resolved before it awaited the attachment.
        runtime.publish(.live(a))
        await pump(fanout)
        await feed([b, other.withTitle("busy elsewhere")])
        guard case .live(let current) = runtime.lifecycle else { return XCTFail("not live") }
        XCTAssertEqual(current, b, "the inventory's newest record wins after a reattach published an older one")
    }
}


/// C11H-391: the pool's view of each session's unusable links, set by a test.
private final class HCUnusableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Set<String>]
    init(_ value: [String: Set<String>]) { stored = value }
    var value: [String: Set<String>] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
