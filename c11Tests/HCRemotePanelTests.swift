import XCTest
import Bonsplit
import Observation
import QuartzCore
import SwiftUI

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// Ticket 12 (C11H-14): terminals on another hc machine through HCManagedSession.

private final class RemoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [HCRPCRequest] = []
    private var notes: [String] = []
    func add(_ request: HCRPCRequest) { lock.lock(); calls.append(request); lock.unlock() }
    func note(_ value: String) { lock.lock(); notes.append(value); lock.unlock() }
    var requests: [HCRPCRequest] { lock.lock(); defer { lock.unlock() }; return calls }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return notes }
    func params(_ method: String) -> [[String: HCJSONValue]] {
        requests.filter { $0.method == method }.compactMap { $0.params.object }
    }
}

private struct RemoteVerifier: HCPeerVerifying {
    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer {
        HCVerifiedPeer(identity: HCBuildIdentity(pin: configuration.pin, executablePath: configuration.executableURL.path,
            fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: peer.pid, startTimeMicroseconds: UInt64(peer.pid) * 100),
            coreID: peer.coreID, protocolGeneration: 1), isPinnedBuild: true)
    }
    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {}
}

private struct RemoteLauncher: HCCoreLaunching {
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        XCTFail("A remote panel never starts a core")
        return HCLaunchLimitReport(beforeSoft: 256, afterSoft: 8192, hard: 8192, kernelCap: 8192)
    }
}

private actor RemoteProcesses: HCProcessObserving {
    var exited: Set<Int32> = []
    func markExited(_ pid: Int32) { exited.insert(pid) }
    func hasExited(_ process: HCProcessIdentity) async -> Bool { exited.contains(process.pid) }
}

private final class RemoteConnection: HCConnection, @unchecked Sendable {
    let generation: UInt64
    let peer: HCPeerEvidence
    let verification: HCVerifiedPeer
    let log: RemoteLog
    let handler: @Sendable (HCRPCRequest) async throws -> HCJSONValue
    init(generation: UInt64, peer: HCPeerEvidence, verification: HCVerifiedPeer, log: RemoteLog,
         handler: @escaping @Sendable (HCRPCRequest) async throws -> HCJSONValue) {
        self.generation = generation; self.peer = peer; self.verification = verification
        self.log = log; self.handler = handler
    }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue { log.add(request); return try await handler(request) }
    var channel: (@Sendable () -> any HCChannel)?
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        guard let make = self.channel else { throw HCUnavailableReason.backendNotInstalled }
        return make()
    }
    func close(reason: HCUnavailableReason) { log.note("close") }
}

private struct RemoteFactory: HCConnectionFactory {
    let pid: Int32
    let log: RemoteLog
    var channel: (@Sendable () -> any HCChannel)? = nil
    let handler: @Sendable (HCRPCRequest) async throws -> HCJSONValue
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        let peer = HCPeerEvidence(uid: 1, pid: pid, statusPID: pid, coreID: "local-core", version: request.configuration.pin.version,
                                  protocolGeneration: 1, methods: [], features: [])
        let connection = RemoteConnection(generation: request.generation, peer: peer, verification: try await verify(peer), log: log, handler: handler)
        connection.channel = channel
        return connection
    }
}

/// Inventory the way 2B's reducer presents it: remote keys carry the remote
/// core id, the hc machine alias and that machine's line state.
private actor RemoteInventory: HCInventorySource {
    var generation: UInt64 = 0
    var build: HCBuildIdentity?
    var records: [HCTerminalKey: HCTerminalRecord] = [:]
    var machines: [String: HCMachineAvailability] = ["studio": .connected]
    var sequence: UInt64 = 1
    func bind(generation: UInt64, build: HCBuildIdentity) { self.generation = generation; self.build = build }
    func insert(_ record: HCTerminalRecord) { records[record.key] = record; sequence += 1 }
    func remove(_ key: HCTerminalKey) { records.removeValue(forKey: key); sequence += 1 }
    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation { HCObservation() }
    func snapshot() async -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: sequence)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: records,
                                   buildIdentity: build, machines: machines)
    }
    func refresh() async -> HCInventorySnapshot { await snapshot() }
}

private func atlasRecord(panel: UUID, creation: UUID, address: String = "t3",
                         availability: HCMachineAvailability = .connected) -> HCTerminalRecord {
    HCTerminalRecord(key: HCTerminalKey(owningCoreID: "atlas-core", localAddress: address), state: .running,
        labels: ["c11.panel": panel.uuidString, "c11.creation": creation.uuidString],
        machineName: "studio", machineAvailability: availability, pid: 4242, cwd: "/Users/demo/proj",
        foreground: HCForeground(pid: 4243, name: "zsh", cwd: "/tmp/x"))
}

final class HCRemotePanelTests: XCTestCase {
    private func configuration() throws -> HCLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcr\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: [:])
        return HCLaunchConfiguration(executableURL: c.executableURL, session: c.session, socketURL: c.socketURL,
            stateDirectory: c.stateDirectory, intentDirectory: root.appendingPathComponent("intents"),
            environment: c.environment, pin: c.pin)
    }

    private func session(_ c: HCLaunchConfiguration, pid: Int32 = 1, log: RemoteLog, inventory: RemoteInventory,
                         store: HCCreationIntentStore, processes: RemoteProcesses = RemoteProcesses(),
                         handler: @escaping @Sendable (HCRPCRequest) async throws -> HCJSONValue) -> HCManagedSession {
        HCManagedSession(configuration: c, connections: RemoteFactory(pid: pid, log: log, handler: handler),
            verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: processes, intents: store,
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
    }

    /// C11H-124: production create/end -> live inventory refresh -> panel runtime
    /// and reconnect coordinator, while the real input coordinator holds a Return.
    /// Only the RPC peer, native renderer and terminal byte sink are substitutes.
    @MainActor
    func testPanelCreateAndCloseDuringRemoteDelayedReturnKeepTheLiveAttachment() async throws {
        let c = try configuration(), log = RemoteLog()
        let panel = UUID(), peer = ChurnPeer(), wire = ChurnWire(), rendering = ChurnRendering()
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let session = HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { ChurnChannel(wire) }) { try await peer.request($0) },
            verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in HCLiveInventorySource(connection: connection, buildIdentity: build) },
            makeAttachment: { key, generation, channel, sink, display in
                HCPanelAttachment(panelID: panel, key: key, generation: generation, channel: channel,
                    sink: sink, rendering: rendering, display: display, encoder: HCHeadlessInputEncoder(), report: { _ in })
            })
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key), session: session,
                                     registrar: { _, _ in })
        runtime.installReconnectPolicy()
        defer { runtime.detachSurface(); HCPanelRestoreState.shared.remove(panelID: panel) }
        let bridge = HCNativeBridge(panelID: panel, rendering: rendering, encoder: HCHeadlessInputEncoder(), report: { _ in })
        let attachment = try await runtime.attachSurface(
            launch: HCPanelLaunchSpec(argv: [], cwd: nil, environment: [:], initialInput: nil), bridge: bridge,
            display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                    grid: HCGridSize(columns: 80, rows: 24)))
        let epoch = runtime.inputEpoch
        let statusQueue = DispatchQueue(label: "test.churn.remote-status")
        let mailbox = ChurnMailboxOwner()
        let store = try JournalStore(layout: JournalStorageLayout(
            directory: c.intentDirectory.deletingLastPathComponent().appendingPathComponent("journal")))
        let journal = JournalCoordinator(store: store), workspace = UUID()
        journal.register(panelID: panel, workspaceID: workspace)
        let status = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal, queue: statusQueue) { mailbox.apply($0) }
        defer { withExtendedLifetime(status) {} }
        statusQueue.sync {}; statusQueue.sync {}
        XCTAssertTrue(mailbox.ownsTerminal)
        var expectedBytes = Data()
        for (close, resize) in [(false, false), (true, false), (false, true), (true, true)] {
            let checking = expectation(description: "body written; Return waits for screen")
            let screenGate = HCReconnectTestGate<Void>()
            rendering.holdNext(checking, gate: screenGate)
            let pending = expectation(description: "create/close published pending inventory")
            let refreshGate = HCReconnectTestGate<Void>()
            await peer.holdNextRefresh(refreshGate)
            let observation = session.observe(on: .main) { snapshot in
                if case .pending(.inventoryPending) = snapshot.readiness { pending.fulfill() }
            }
            let payload = Data((close ? "close-churn" : "create-churn").utf8)
            var composerReads: [HCDisplayRevision] = []
            let send = Task { await runtime.submitInput(HCInputRequest(operationID: UUID(), panelID: panel, key: key,
                attachmentGeneration: attachment.generation, source: .mailbox, payload: payload, submitReturn: true,
                returnGuard: { receipt in
                    composerReads.append(receipt.revision)
                    return mailbox.ownsTerminal
                })) }
            await fulfillment(of: [checking], timeout: 3)
            XCTAssertEqual(wire.bytes, expectedBytes + payload, "the body is already out, with no Return")
            let churn = Task {
                if close {
                    guard case .pending = await session.end(HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t4")) else {
                        XCTFail("close did not reach the real managed session"); return
                    }
                } else {
                    let request = HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                        creationID: UUID(), argv: [], machine: "studio")
                    guard case .bound = await session.create(request) else {
                        XCTFail("create did not reconcile through refreshed inventory"); return
                    }
                }
            }
            await fulfillment(of: [pending], timeout: 3)
            observation.cancel()
            // Re-publish the held pending snapshot synchronously through the
            // real session, then drain its coalesced status observation.
            let duringRefresh = await session.diagnostics()
            XCTAssertEqual(duringRefresh.inventory.readiness, .pending(.inventoryPending))
            statusQueue.sync {}; statusQueue.sync {}
            XCTAssertTrue(mailbox.ownsTerminal, "resnapshot must not revoke the doorbell owner")
            XCTAssertEqual(journal.snapshot(panelID: panel)?.connection, .live)
            XCTAssertEqual(try store.readPage(after: 0).count, 1, "no false connection_lost draft")
            // Drain the same main queue used by both runtime inventory observers.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertTrue(runtime.attachment === attachment)
            XCTAssertEqual(runtime.inputEpoch, epoch)
            XCTAssertNil(runtime.inputFault)
            let revision = HCDisplayRevision(attachmentGeneration: attachment.generation,
                                            displayGeneration: resize ? (close ? 3 : 2) : 1)
            if resize {
                _ = await attachment.updateDisplay(HCDisplayState(revision: revision, grid: HCGridSize(columns: 100, rows: 30)))
            }
            // Return must succeed INSIDE the pending window, including churn
            // elsewhere that leaves this panel's display revision unchanged.
            await screenGate.release(())
            let outcome = await send.value
            await refreshGate.release(())
            await churn.value
            guard case .written(let receipt) = outcome else { return XCTFail("churn faulted the delayed Return: \(outcome)") }
            XCTAssertTrue(receipt.returnWritten)
            XCTAssertEqual(receipt.bodyBytesWritten, payload.count)
            XCTAssertEqual(composerReads, [revision], "only the fresh screen reaches the composer guard")
            expectedBytes += payload + Data([13])
            XCTAssertEqual(wire.bytes, expectedBytes, "body and Return are each sent exactly once")
            XCTAssertTrue(runtime.attachment === attachment)
            XCTAssertNil(runtime.inputFault)
            XCTAssertEqual(runtime.disconnectedInput?.isFaulted, false)
        }
        XCTAssertEqual(log.params("terminal.run").count, 2)
        XCTAssertEqual(log.params("terminal.kill").count, 2)
        XCTAssertEqual(log.params("terminal.attach").count, 1, "inventory refresh must not reattach")
        XCTAssertEqual(log.params("events.subscribe").count, 5, "initial snapshot plus four churn refreshes")
    }

    /// `--on studio` reaches hc as `terminal.run` with `on`, the remote cwd
    /// verbatim, and binds the remote key the inventory reports.
    func testRemoteCreateSendsOnAndBindsTheRemoteKey() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID(), creation = UUID()
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { request in
            guard request.method == "terminal.run" else { throw HCUnavailableReason.malformedResponse }
            await inventory.insert(atlasRecord(panel: panel, creation: creation))
            return .object(["terminal": .string("studio/t3")])
        }
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation,
                                      argv: ["/bin/zsh", "-l"], cwd: "/srv/remote-only", machine: "studio")
        guard case .bound(let record) = await s.create(request) else { return XCTFail("Remote create must bind") }
        XCTAssertEqual(record.key, HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3"))
        XCTAssertEqual(record.machineName, "studio")
        let run = try XCTUnwrap(log.params("terminal.run").first)
        XCTAssertEqual(run["on"], .string("studio"))
        XCTAssertEqual(run["cwd"], .string("/srv/remote-only"))
        XCTAssertEqual(log.params("terminal.run").count, 1)
    }

    /// C11H-103: a created terminal carries c11.workspace beside its
    /// identity labels, which a caller's labels can never override.
    func testCreateStampsTheOwnersWorkspaceAndKeepsTheIdentityLabels() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID(), creation = UUID(), workspace = UUID()
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { request in
            guard request.method == "terminal.run" else { throw HCUnavailableReason.malformedResponse }
            await inventory.insert(atlasRecord(panel: panel, creation: creation))
            return .object(["terminal": .string("studio/t3")])
        }
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation,
            argv: [], machine: "studio",
            labels: [HCOwnerLabels.workspace: workspace.uuidString, "c11.panel": "someone-else"])
        _ = await s.create(request)
        let run = try XCTUnwrap(log.params("terminal.run").first)
        guard case .object(let labels)? = run["labels"] else { return XCTFail("no labels") }
        XCTAssertEqual(labels[HCOwnerLabels.workspace], .string(workspace.uuidString))
        XCTAssertEqual(labels["c11.panel"], .string(panel.uuidString), "the identity label always wins")
        XCTAssertEqual(labels["c11.creation"], .string(creation.uuidString))
        XCTAssertEqual(request.retargeted(identity: request.identity).labels, request.labels, "a shard retarget keeps them")
    }

    /// C11H-103: a title or workspace label goes to the terminal's own
    /// machine through `terminal.label` with its routed address; it never
    /// connects or starts a core on its own.
    func testLabelsAreSetOnTheTerminalsMachine() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        await inventory.insert(atlasRecord(panel: UUID(), creation: UUID()))
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { request in
            XCTAssertEqual(request.method, "terminal.label")
            return .object([:])
        }
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let beforeConnect = await s.setLabels([HCOwnerLabels.title: "T-8 Review"], on: key)
        XCTAssertFalse(beforeConnect, "no connection: nothing is sent and no core starts")
        XCTAssertTrue(log.params("terminal.label").isEmpty)
        _ = await s.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let sent = await s.setLabels([HCOwnerLabels.title: "T-8 Review", HCOwnerLabels.workspace: ""], on: key)
        XCTAssertTrue(sent)
        let params = try XCTUnwrap(log.params("terminal.label").first)
        XCTAssertEqual(params["terminal"], .string("studio/t3"))
        XCTAssertEqual(params["labels"], .object([HCOwnerLabels.title: .string("T-8 Review"), HCOwnerLabels.workspace: .string("")]))
    }

    /// A local create never names a machine.
    func testLocalCreateSendsNoMachine() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID(), creation = UUID()
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { _ in
            await inventory.insert(HCTerminalRecord(key: HCTerminalKey(owningCoreID: "local-core", localAddress: "t1"), state: .running,
                labels: ["c11.panel": panel.uuidString, "c11.creation": creation.uuidString], pid: 9))
            return .object(["terminal": .string("t1")])
        }
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])
        guard case .bound = await s.create(request) else { return XCTFail("Local create must bind") }
        XCTAssertNil(try XCTUnwrap(log.params("terminal.run").first)["on"])
    }

    /// The remote target survives in the durable intent, so a later app
    /// incarnation still knows the pending creation was not local.
    func testIntentRecordsTheTargetMachine() async throws {
        let c = try configuration()
        let store = HCCreationIntentStore(directory: c.intentDirectory)
        let panel = UUID()
        _ = try await store.claim(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
            creationID: UUID(), argv: ["sh"], machine: "studio"),
            coreID: "local-core", process: HCProcessIdentity(pid: 7, startTimeMicroseconds: 700))
        let reread = HCCreationIntentStore(directory: c.intentDirectory)
        let intent = try await reread.read(panelID: panel)
        XCTAssertEqual(intent?.machine, "studio")
    }

    /// The hazard this guards: the local core restarts while the Studio link is
    /// down. The pending Studio creation is absent from the new local inventory
    /// only because its machine is unreachable. Settling it as ended would let
    /// the panel create a second Studio terminal beside the surviving one.
    func testLocalAdoptionNeverSettlesAPendingRemoteCreation() async throws {
        for machine in ["studio", nil] as [String?] {
            let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory(), processes = RemoteProcesses()
            await inventory.setMachines(["studio": .disconnected])
            let store = HCCreationIntentStore(directory: c.intentDirectory)
            let panel = UUID(), creation = UUID()
            let identity = HCPanelIdentity(panelID: panel, creationID: creation, origin: .restored)
            _ = try await store.claim(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                creationID: creation, argv: ["sh"], machine: machine),
                coreID: "local-core", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 4200))
            try await store.markTransmitted(panelID: panel, creationID: creation)
            try await store.markUncertain(panelID: panel, creationID: creation)
            await processes.markExited(42)
            let s = session(c, pid: 1, log: log, inventory: inventory, store: store, processes: processes) { _ in .null }
            let result = await s.resolve(identity)
            if machine == nil {
                guard case .ended(let proof) = result, proof.kind == .postAdoptionAbsence else {
                    XCTFail("Control: a local pending creation absent after adoption settles as ended (\(result))"); continue
                }
            } else {
                guard case .unresolved(_, let reason) = result else {
                    XCTFail("A remote pending creation must stay unresolved after local adoption, got \(result)"); continue
                }
                XCTAssertTrue([.creationPending, .creationUncertain].contains(reason), "\(reason)")
            }
        }
    }

    /// A bound Studio key whose record is gone (link down, mirror dropped)
    /// stays Reconnecting with its identity; it never reads as ended or new.
    func testStoredAtlasKeyStaysUnresolvedWhileItsMirrorIsMissing() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        await inventory.setMachines(["studio": .disconnected])
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let identity = HCPanelIdentity(panelID: UUID(), key: key, origin: .restored)
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { _ in .null }
        guard case .unresolved(let kept, .connectionLost) = await s.resolve(identity) else {
            return XCTFail("Missing remote mirror must be connectionLost")
        }
        XCTAssertEqual(kept, identity)
        XCTAssertTrue(log.params("terminal.run").isEmpty)
    }

    /// The same Studio key comes back live after the link returns, and a
    /// disconnected record in between reads Reconnecting, not live.
    func testAtlasRecordFollowsTheLinkAndKeepsItsKey() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID(), creation = UUID()
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let identity = HCPanelIdentity(panelID: panel, key: key, origin: .restored)
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { _ in .null }
        await inventory.insert(atlasRecord(panel: panel, creation: creation, availability: .disconnected))
        guard case .unresolved(_, .connectionLost) = await s.resolve(identity) else { return XCTFail("Down link reads Reconnecting") }
        await inventory.insert(atlasRecord(panel: panel, creation: creation, availability: .connected))
        guard case .live(let record) = await s.resolve(identity) else { return XCTFail("Restored link reads live") }
        XCTAssertEqual(record.key, key)
    }

    /// A dropped file goes to the terminal's own machine: `terminal.put` with
    /// the routed address, the file's name and base64 bytes; hc's path comes back.
    func testPutSendsTheFileToTheTerminalsMachine() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        await inventory.insert(atlasRecord(panel: UUID(), creation: UUID()))
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { request in
            XCTAssertEqual(request.method, "terminal.put")
            return .object(["path": .string("/Users/demo/.local/state/herdr-core/c11/files/t3/shot.png"), "bytes": .integer(3)])
        }
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let path = try await s.put(key, name: "shot.png", data: Data([0xff, 0x00, 0x7f]))
        XCTAssertEqual(path, "/Users/demo/.local/state/herdr-core/c11/files/t3/shot.png")
        let params = try XCTUnwrap(log.params("terminal.put").first)
        XCTAssertEqual(params["terminal"], .string("studio/t3"))
        XCTAssertEqual(params["name"], .string("shot.png"))
        XCTAssertEqual(params["data"], .string("/wB/"))
        do {
            _ = try await s.put(key, name: "big.bin", data: Data(count: HCRemoteFileDrop.maximumBytes + 1))
            XCTFail("Over hc's put limit must be refused before any RPC")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .bufferOverflow) }
        XCTAssertEqual(log.params("terminal.put").count, 1)
    }

    /// Close of a Studio panel ends the remote terminal by its routed address.
    func testEndRoutesAnAtlasKeyThroughItsMachineAlias() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID()
        await inventory.insert(atlasRecord(panel: panel, creation: UUID()))
        let s = session(c, log: log, inventory: inventory, store: HCCreationIntentStore(directory: c.intentDirectory)) { request in
            XCTAssertEqual(request.method, "terminal.kill"); return .object([:])
        }
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        guard case .pending(let pending) = await s.end(key) else { return XCTFail("Accepted kill is pending until inventory confirms") }
        XCTAssertEqual(pending, key)
        XCTAssertEqual(log.params("terminal.kill").first?["terminal"], .string("studio/t3"))
    }
}

private extension RemoteInventory {
    func setMachines(_ value: [String: HCMachineAvailability]) { machines = value; sequence += 1 }
}

/// What 2B's live source does with a polled machine.list: routes and the
/// availability of every record they route.
extension RemoteInventory: HCMachineRouteSink {
    func applyMachines(_ value: HCJSONValue) async {
        var next: [String: HCMachineAvailability] = [:]
        for item in value["machines"].array ?? [] {
            if let name = item["name"].string { next[name] = item["state"].string == "connected" ? .connected : .disconnected }
        }
        machines = next
        for (key, record) in records {
            guard let name = record.machineName, let availability = next[name] else { continue }
            records[key] = record.with(availability: availability)
        }
    }
}

fileprivate extension HCTerminalRecord {
    func with(availability: HCMachineAvailability) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, labels: labels, machineName: machineName, machineAvailability: availability,
            pid: pid, cwd: cwd, foreground: foreground, title: title, status: status,
            statusTimestampMilliseconds: statusTimestampMilliseconds, turn: turn, grid: grid, screenExact: screenExact,
            exitCode: exitCode, exitSignal: exitSignal, endReason: endReason, tty: tty, localProcessIdentity: localProcessIdentity)
    }
}

private func machineList(_ state: String) -> HCJSONValue {
    .object(["machines": .array([.object(["name": .string("studio"), "id": .string("atlas-core"), "state": .string(state)])])])
}

/// A session whose create is rejected before transmission, as when the core
/// is unreachable for a genuinely new panel.
private actor UnreachableCreateSession: HCSession {
    private(set) var creates: [HCCreateRequest] = []
    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation { HCObservation() }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { .new }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { creates.append(request); return .rejectedBeforeTransmission(.coreUnreachable) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        throw HCUnavailableReason.backendNotInstalled
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
}


// C11H-359: machines and labels hc reports are judged where the session uses them.
extension HCRemoteLinkTests {
    /// M6, L2: a machine listed with no core id, or with this core's own id,
    /// is refused alone. The shard stays ready, its terminals stay out of the
    /// inventory, nothing opens there, and Settings learns why.
    func testARefusedMachineLeavesTheShardReadyAndOpensNothing() async throws {
        let c = try configuration(), log = RemoteLog()
        let panel = UUID()
        func terminal(_ address: String, labels: [String: String] = [:]) -> HCJSONValue {
            .object(["address": .string(address), "state": .string("live"), "pid": .integer(4242),
                     "labels": .object(labels.mapValues(HCJSONValue.string)), "cols": .integer(80), "rows": .integer(24)])
        }
        let s = HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { ChurnChannel(ChurnWire()) }) { request in
                switch request.method {
                case "machine.list":
                    return .object(["machines": .array([
                        .object(["name": .string("studio"), "id": .string("atlas-core"), "state": .string("connected")]),
                        .object(["name": .string("rigel"), "id": .string(""), "state": .string("connected")]),
                        .object(["name": .string("mirror"), "id": .string("local-core"), "state": .string("connected")]),
                    ])])
                case "events.subscribe":
                    return .object(["channel": .integer(3), "seq": .integer(1), "terminals": .array([
                        terminal("t1", labels: ["c11.panel": panel.uuidString]), terminal("studio/t3"),
                        terminal("rigel/t2"), terminal("mirror/t1"),
                    ])])
                default: throw HCUnavailableReason.malformedResponse
                }
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in HCLiveInventorySource(connection: connection, buildIdentity: build) })
        defer { Task { @MainActor in HCMachineDirectory.shared.setRefused([:], session: c.session) } }
        let key = HCTerminalKey(owningCoreID: "local-core", localAddress: "t1")
        guard case .live(let own) = await s.resolve(HCPanelIdentity(panelID: panel, key: key, origin: .restored)) else {
            return XCTFail("this core's terminal is live: the shard installed")
        }
        XCTAssertEqual(own.key, key)
        let refused = await s.refusedMachines
        XCTAssertEqual(refused, ["rigel": .missingID, "mirror": .localCoreID])
        let snapshot = await s.snapshot()
        XCTAssertEqual(snapshot.machines, ["studio": .connected])
        XCTAssertEqual(Set(snapshot.records.keys), [key, HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")])
        let created = await s.create(HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                                                     creationID: UUID(), argv: [], machine: "rigel"))
        guard case .rejectedBeforeTransmission = created else { return XCTFail("nothing opens on a refused machine: \(created)") }
        XCTAssertFalse(log.requests.contains { $0.method == "terminal.run" })
        let shown = await MainActor.run { HCMachineDirectory.shared.refused }
        XCTAssertEqual(shown["rigel"], .missingID)
        XCTAssertEqual(shown["mirror"], .localCoreID)
    }

    /// A session over the live inventory whose machine list the test flips.
    private func flippableSession(_ c: HCLaunchConfiguration, log: RemoteLog, list: HCLinkState) -> HCManagedSession {
        HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { ChurnChannel(ChurnWire()) }) { request in
                switch request.method {
                case "machine.list":
                    let id = list.value
                    return .object(["machines": .array([.object(["name": .string("studio"), "id": .string(id),
                                                                 "state": .string("connected")])])])
                case "events.subscribe":
                    return .object(["channel": .integer(3), "seq": .integer(1), "terminals": .array([
                        .object(["address": .string("t1"), "state": .string("live"), "pid": .integer(4242),
                                 "labels": .object([:]), "cols": .integer(80), "rows": .integer(24)])])])
                case "terminal.run": return .object(["terminal": .string("studio/t5")])
                default: throw HCUnavailableReason.malformedResponse
                }
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in HCLiveInventorySource(connection: connection, buildIdentity: build) })
    }

    /// REPAIR-1 (B1): a machine refused by a resnapshot, not by the poll,
    /// opens nothing either: the creation gate reads the inventory's current
    /// judgement. (a) the refusal comes from a session refresh; (b) from the
    /// resnapshot one machine poll starts when a route disappears.
    func testAMachineRefusedSinceTheLastPollOpensNothing() async throws {
        for poll in [false, true] {
            let c = try configuration(), log = RemoteLog(), list = HCLinkState()
            list.value = "atlas-core"
            let s = flippableSession(c, log: log, list: list)
            defer { Task { @MainActor in HCMachineDirectory.shared.setRefused([:], session: c.session) } }
            _ = await s.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
            let routed = await s.snapshot()
            XCTAssertEqual(routed.machines, ["studio": .connected], "poll=\(poll): studio is routed first")
            list.value = ""
            if poll {
                _ = await s.pollMachines()
                func settled(_ snapshot: HCInventorySnapshot) -> Bool {
                    guard case .ready = snapshot.readiness else { return false }
                    return snapshot.machines.isEmpty
                }
                var current = await s.snapshot()
                for _ in 0..<200 where !settled(current) {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    current = await s.snapshot()
                }
                XCTAssertTrue(settled(current), "the poll's resnapshot refused studio")
            } else {
                _ = await s.refresh()
            }
            let created = await s.create(HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                                                         creationID: UUID(), argv: [], machine: "studio"))
            guard case .rejectedBeforeTransmission = created else { return XCTFail("poll=\(poll): opened on a refused machine: \(created)") }
            XCTAssertFalse(log.requests.contains { $0.method == "terminal.run" }, "poll=\(poll)")
        }
    }

    /// A one-shot gate the test opens: `wait()` holds until `open()`.
    private actor HeldStep {
        private var reached = false, opened = false
        private var holders: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            reached = true
            watchers.forEach { $0.resume() }; watchers = []
            if !opened { await withCheckedContinuation { holders.append($0) } }
        }
        func untilReached() async { if !reached { await withCheckedContinuation { watchers.append($0) } } }
        func open() { opened = true; holders.forEach { $0.resume() }; holders = [] }
    }

    /// REPAIR-2: a creation already in remote preparation when one poll finds
    /// its machine refused, while that poll's resnapshot is still held, opens
    /// nothing: the poll's judgement is kept while the inventory is pending.
    func testACreationInPreparationWhenAPollRefusesItsMachineOpensNothing() async throws {
        let c = try configuration(), log = RemoteLog(), list = HCLinkState()
        let preparing = HeldStep(), resnapshot = HeldStep()
        final class Count: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let subscribes = Count()
        list.value = "atlas-core"
        let s = HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { ChurnChannel(ChurnWire()) }) { request in
                switch request.method {
                case "machine.list":
                    if list.value == "atlas-core" {
                        return .object(["machines": .array([.object(["name": .string("studio"), "id": .string("atlas-core"),
                                                                     "state": .string("connected")])])])
                    }
                    // The same far core linked under a second name.
                    return .object(["machines": .array([
                        .object(["name": .string("studio"), "id": .string("far-core"), "state": .string("connected")]),
                        .object(["name": .string("rigel"), "id": .string("far-core"), "state": .string("connected")])])])
                case "events.subscribe":
                    if subscribes.next() > 1 { await resnapshot.wait() }
                    return .object(["channel": .integer(3), "seq": .integer(1), "terminals": .array([])])
                case "terminal.run": return .object(["terminal": .string("studio/t5")])
                default: throw HCUnavailableReason.malformedResponse
                }
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in HCLiveInventorySource(connection: connection, buildIdentity: build) },
            prepareRemote: { _, _ in await preparing.wait(); return [:] })
        defer {
            Task { await preparing.open(); await resnapshot.open() }
            Task { @MainActor in HCMachineDirectory.shared.setRefused([:], session: c.session) }
        }
        _ = await s.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let routed = await s.snapshot()
        XCTAssertEqual(routed.machines, ["studio": .connected])
        let creating = Task { await s.create(HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                                                             creationID: UUID(), argv: [], machine: "studio")) }
        await preparing.untilReached()
        list.value = "doubled"
        _ = await s.pollMachines()
        await resnapshot.untilReached()
        await preparing.open()
        let created = await creating.value
        guard case .rejectedBeforeTransmission = created else { return XCTFail("opened on a refused machine: \(created)") }
        XCTAssertFalse(log.requests.contains { $0.method == "terminal.run" })
        await resnapshot.open()
    }

    /// Opus nb5: a refusal seen again by later polls is audited once per
    /// machine and reason.
    func testARefusalIsAuditedOncePerMachineAndReason() async throws {
        let c = try configuration(), log = RemoteLog(), list = HCLinkState()
        let name = "audit-\(UUID().uuidString.prefix(8).lowercased())"
        list.value = ""
        let s = HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { ChurnChannel(ChurnWire()) }) { request in
                switch request.method {
                case "machine.list":
                    return .object(["machines": .array([.object(["name": .string(name), "id": .string(list.value),
                                                                 "state": .string("connected")])])])
                case "events.subscribe":
                    return .object(["channel": .integer(3), "seq": .integer(1), "terminals": .array([])])
                default: throw HCUnavailableReason.malformedResponse
                }
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in HCLiveInventorySource(connection: connection, buildIdentity: build) })
        defer { Task { @MainActor in HCMachineDirectory.shared.setRefused([:], session: c.session) } }
        _ = await s.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        _ = await s.pollMachines()
        _ = await s.pollMachines()
        C11AuditLog.shared.flush()
        let records = C11AuditLog.shared.read().filter { $0.machine == name && $0.outcome == "refused" }
        XCTAssertEqual(records.count, 1, "one record for the machine and its reason: \(records)")
        XCTAssertEqual(records.first?.code, HCMachineRefusal.missingID.rawValue)
    }

    /// M3: the session matches a panel's terminal by its labels only on the
    /// placement the panel was made for. A linked machine's terminal labelled
    /// with a local panel's UUID stays out; a remote panel finds its own.
    func testASessionMatchesLabelsOnlyOnThePanelsOwnPlacement() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let local = UUID(), remote = UUID()
        await inventory.insert(atlasRecord(panel: local, creation: UUID()))
        await inventory.insert(atlasRecord(panel: remote, creation: UUID(), address: "t5"))
        let s = HCManagedSession(configuration: c, connections: RemoteFactory(pid: 1, log: log) { _ in machineList("connected") },
            verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            placements: { $0 == remote ? .machine("studio") : nil })
        guard case .new = await s.resolve(HCPanelIdentity(panelID: local, origin: .restored)) else {
            return XCTFail("a local panel never resolves to a linked machine's terminal")
        }
        guard case .live(let record) = await s.resolve(HCPanelIdentity(panelID: remote, origin: .restored)) else {
            return XCTFail("a remote panel resolves its own terminal on its machine")
        }
        XCTAssertEqual(record.key.localAddress, "t5")
    }

    /// M3: a genuinely new panel has no terminal anywhere, so its creation
    /// matches nothing by label before it runs, not even a terminal of this
    /// Mac's own core that something labelled with its new UUID: it runs.
    func testAGenuinelyNewPanelsCreationLooksNothingUpBeforeItRuns() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID()
        let planted = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "local-core", localAddress: "t8"), state: .running,
                                       labels: ["c11.panel": panel.uuidString], pid: 5)
        await inventory.insert(planted)
        let s = HCManagedSession(configuration: c, connections: RemoteFactory(pid: 1, log: log) { request in
                switch request.method {
                case "terminal.run": return .object(["terminal": .string("t9")])
                default: return machineList("connected")
                }
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let created = await s.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                     creationID: UUID(), argv: []))
        XCTAssertEqual(log.requests.filter { $0.method == "terminal.run" }.count, 1, "sent: \(created)")
        if case .bound(let record) = created { XCTAssertNotEqual(record.key, planted.key, "never bound to the labelled terminal") }
    }
}

final class HCRemoteLinkTests: XCTestCase {
    private func configuration() throws -> HCLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcl\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, inherited: [:])
        return HCLaunchConfiguration(executableURL: c.executableURL, session: c.session, socketURL: c.socketURL,
            stateDirectory: c.stateDirectory, intentDirectory: root.appendingPathComponent("intents"),
            environment: c.environment, pin: c.pin)
    }

    /// hc sends no event when a line drops. The poll is what turns a live
    /// Studio terminal Reconnecting, and live again with the same key.
    func testMachinePollTurnsAtlasTerminalsReconnectingAndBack() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID()
        await inventory.insert(atlasRecord(panel: panel, creation: UUID()))
        let state = HCLinkState()
        let s = HCManagedSession(configuration: c, connections: RemoteFactory(pid: 1, log: log) { request in
                guard request.method == "machine.list" else { throw HCUnavailableReason.malformedResponse }
                return machineList(state.value)
            }, verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let identity = HCPanelIdentity(panelID: panel, key: key, origin: .restored)
        guard case .live = await s.resolve(identity) else { return XCTFail("Connected Studio terminal is live") }
        state.value = "unreachable"
        let polled = await s.pollMachines()
        XCTAssertEqual(polled, ["studio": .disconnected])
        guard case .unresolved(let kept, .connectionLost) = await s.resolve(identity) else {
            return XCTFail("A dropped line must read Reconnecting")
        }
        XCTAssertEqual(kept.key, key)
        state.value = "connected"
        _ = await s.pollMachines()
        guard case .live(let record) = await s.resolve(identity) else { return XCTFail("Restored line reads live") }
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(log.requests.filter { $0.method == "machine.list" }.count, 2)
    }

    /// The panel side of the same edge: a remote record whose machine is down
    /// is never published as live, and comes back live with the same key.
    @MainActor
    func testPanelSessionTreatsADownLineAsConnectionLossNotLive() {
        let panel = UUID()
        let record = atlasRecord(panel: panel, creation: UUID())
        let panelSession = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: record.key), session: HCUnavailableRuntime())
        panelSession.publish(.live(record))
        let revision = HCRevision(connectionGeneration: 1, sequence: 9)
        panelSession.receiveInventory(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [record.key: record.with(availability: .disconnected)], machines: ["studio": .disconnected]))
        guard case .unresolved(let kept, .connectionLost) = panelSession.lifecycle else {
            return XCTFail("Down line must read Reconnecting, got \(panelSession.lifecycle)")
        }
        XCTAssertEqual(kept.key, record.key)
        XCTAssertEqual(kept.persistence, .persistent)
        panelSession.receiveInventory(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [record.key: record], machines: ["studio": .connected]))
        guard case .live(let back) = panelSession.lifecycle else { return XCTFail("Restored line reads live") }
        XCTAssertEqual(back.key, record.key)
    }

    /// hc may drop the remote mirror while the line is down: still Reconnecting,
    /// never ended or left live.
    @MainActor
    func testMissingAtlasMirrorOnADownLineIsConnectionLoss() {
        let panel = UUID()
        let record = atlasRecord(panel: panel, creation: UUID())
        let panelSession = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: record.key), session: HCUnavailableRuntime())
        panelSession.publish(.live(record))
        let revision = HCRevision(connectionGeneration: 1, sequence: 10)
        panelSession.receiveInventory(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [:], machines: ["studio": .disconnected]))
        guard case .unresolved(let kept, .connectionLost) = panelSession.lifecycle else {
            return XCTFail("A dropped mirror on a down line must read Reconnecting, got \(panelSession.lifecycle)")
        }
        XCTAssertEqual(kept.key, record.key)
    }

    /// The line check asks the local core now, not the last poll: a line that
    /// dropped since then reads down, and the change reaches the inventory so
    /// the panel turns Reconnecting without waiting for the next poll.
    func testConfirmLineAsksTheCoreNowAndAppliesAChange() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID()
        let record = atlasRecord(panel: panel, creation: UUID())
        await inventory.insert(record)
        let state = HCLinkState()
        let s = HCManagedSession(configuration: c, connections: RemoteFactory(pid: 1, log: log) { _ in machineList(state.value) },
            verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        _ = await s.resolve(HCPanelIdentity(panelID: panel, key: record.key))
        let up = await s.confirmLine("studio")
        XCTAssertTrue(up)
        state.value = "unreachable"   // dropped; no poll has run
        let down = await s.confirmLine("studio")
        XCTAssertFalse(down)
        let applied = await inventory.machines["studio"]
        XCTAssertEqual(applied, .disconnected, "The change must reach the inventory now")
    }

    /// T12.7: keys typed into a Studio terminal whose line dropped before the
    /// next poll go through the real attach and input path and are refused
    /// visibly with zero bytes sent; the same keys write once the line is up.
    /// A local terminal's channel is never wrapped.
    func testKeysIntoADroppedLineAreRefusedBeforeAByteIsSent() async throws {
        let c = try configuration(), log = RemoteLog(), inventory = RemoteInventory()
        let panel = UUID()
        let record = atlasRecord(panel: panel, creation: UUID())
        let local = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "local-core", localAddress: "t9"), state: .running, pid: 9)
        await inventory.insert(record)
        await inventory.insert(local)
        let state = HCLinkState(), wire = LinkWire(), reports = LinkReports()
        let s = HCManagedSession(configuration: c,
            connections: RemoteFactory(pid: 1, log: log, channel: { LinkChannel(wire) }) { request in
                request.method == "terminal.attach" ? .object(["channel": .integer(3)]) : machineList(state.value)
            },
            verifier: RemoteVerifier(), launcher: RemoteLauncher(), processes: RemoteProcesses(),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            makeAttachment: { key, generation, channel, sink, display in
                let attachment = HCPanelAttachment(panelID: panel, key: key, generation: generation, channel: channel,
                    sink: sink, rendering: HCUnavailableRenderingAdapter(), display: display,
                    encoder: HCUnavailableInputEncoder(), report: { reports.add($0) })
                attachment.setAdmission(true)
                wire.channels.append(channel)
                return attachment
            })
        let sink = HCNativeBridge(panelID: panel, rendering: HCUnavailableRenderingAdapter(),
                                  encoder: HCUnavailableInputEncoder(), report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                     grid: HCGridSize(columns: 80, rows: 24))
        let attached = try await s.attach(record.key, sink: sink, display: display)
        let port = try XCTUnwrap((attached as? HCPanelAttachment)?.coordinator)
        XCTAssertTrue(wire.channels.first is HCRemoteLinkChannel)
        state.value = "unreachable"   // dropped before the next poll
        port.receiveRaw(Data("ls\r".utf8), kind: .key, generation: attached.generation)
        let refused = await reports.wait(count: 1)
        guard case .refused(.unavailable) = refused.first else { return XCTFail("Keys into a dropped line must be refused, got \(refused)") }
        XCTAssertEqual(wire.dataWrites, 0, "Not a byte may go into a dropped line")
        state.value = "connected"
        port.receiveRaw(Data("ls\r".utf8), kind: .key, generation: attached.generation)
        let written = await reports.wait(count: 2)
        guard written.count == 2, case .written = written[1] else { return XCTFail("Control: an up line writes, got \(written)") }
        XCTAssertEqual(wire.dataWrites, 1)
        _ = try await s.attach(local.key, sink: HCNativeBridge(panelID: UUID(), rendering: HCUnavailableRenderingAdapter(),
                                  encoder: HCUnavailableInputEncoder(), report: { _ in }), display: display)
        XCTAssertFalse(wire.channels.last is HCRemoteLinkChannel, "A local terminal's writes are never gated")
    }

    /// Review 1 (Grok, blocking 2): the production create stamps the owner's
    /// workspace. A panel's first creation through attachSurface carries
    /// c11.workspace (and no identity label of its own; create adds those).
    @MainActor
    func testAPanelsCreationStampsItsWorkspace() async {
        let session = UnreachableCreateSession()
        let panelSession = HCPanelSession(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), session: session)
        let bridge = HCNativeBridge(panelID: panelSession.identity.panelID, rendering: HCUnavailableRenderingAdapter(),
                                    encoder: HCUnavailableInputEncoder(), report: { _ in })
        let workspace = UUID()
        let launch = HCPanelLaunchSpec.placed(argv: ["/bin/zsh", "-l"], localCwd: "/Users/me", environment: [:],
            initialInput: nil, workspaceID: workspace, remote: HCRemoteTarget(machine: "studio", cwd: "/tmp"))
        _ = try? await panelSession.attachSurface(launch: launch, bridge: bridge,
            display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                    grid: HCGridSize(columns: 80, rows: 24)))
        let creates = await session.creates
        XCTAssertEqual(creates.first?.labels, [HCOwnerLabels.workspace: workspace.uuidString])
    }

    /// C11H-103 (case 5): a panel adopted into Recovered whose terminal is
    /// gone when its surface starts creates nothing. Before, resolve said .new
    /// and attachSurface started a fresh local shell under the closed id.
    @MainActor
    func testARecoveredPanelWhoseTerminalIsGoneStartsNoNewTerminal() async {
        defer { HCPanelSession.mayReplaceMissingTerminal = { _, _ in true } }
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t9")
        for allowed in [false, true] {
            HCPanelSession.mayReplaceMissingTerminal = { _, _ in allowed }
            let session = UnreachableCreateSession()
            let panelSession = HCPanelSession(identity: HCPanelIdentity(panelID: UUID(), key: key, origin: .restored),
                                              session: session)
            let bridge = HCNativeBridge(panelID: panelSession.identity.panelID, rendering: HCUnavailableRenderingAdapter(),
                                        encoder: HCUnavailableInputEncoder(), report: { _ in })
            let launch = HCPanelLaunchSpec.placed(argv: ["/bin/zsh", "-l"], localCwd: "/Users/me", environment: [:],
                initialInput: nil, remote: nil)
            var thrown: Error?
            do {
                _ = try await panelSession.attachSurface(launch: launch, bridge: bridge,
                    display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                            grid: HCGridSize(columns: 80, rows: 24)))
            } catch { thrown = error }
            let creates = await session.creates
            if allowed {
                XCTAssertEqual(creates.count, 1, "control: an ordinary restored panel may replace its terminal")
            } else {
                XCTAssertEqual(creates.count, 0, "a Recovered panel never starts a new terminal")
                XCTAssertEqual(thrown as? HCUnavailableReason, .staleIdentity)
            }
        }
    }

    /// A Studio panel never becomes a local plain shell because the core is
    /// unreachable; only a genuinely new local panel may.
    @MainActor
    func testRemotePanelNeverFallsBackToALocalShell() async {
        for machine in ["studio", nil] as [String?] {
            let session = UnreachableCreateSession()
            let panelSession = HCPanelSession(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), session: session)
            var fellBack = false
            panelSession.onFallback = { fellBack = true }
            let bridge = HCNativeBridge(panelID: panelSession.identity.panelID, rendering: HCUnavailableRenderingAdapter(),
                                        encoder: HCUnavailableInputEncoder(), report: { _ in })
            let launch = HCPanelLaunchSpec.placed(argv: ["/bin/zsh", "-l"], localCwd: "/Users/me", environment: [:],
                initialInput: nil, remote: machine.map { HCRemoteTarget(machine: $0, cwd: "/tmp") })
            _ = try? await panelSession.attachSurface(launch: launch, bridge: bridge,
                display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                        grid: HCGridSize(columns: 80, rows: 24)))
            let creates = await session.creates
            XCTAssertEqual(creates.count, 1)
            XCTAssertEqual(creates.first?.machine, machine)
            if machine == nil {
                XCTAssertTrue(fellBack, "Control: a new local panel may fall back")
                XCTAssertEqual(panelSession.identity.persistence, .nonpersistent)
            } else {
                XCTAssertFalse(fellBack, "A Studio panel must not fall back to a local shell")
                XCTAssertEqual(panelSession.identity.persistence, .persistent)
                XCTAssertEqual(creates.first?.argv,
                    ["/bin/sh", "-c", HCMachineTarget.remoteLaunchLine],
                    "Placement selects the far shell; HCManagedSession sanitizes the eventual run")
                guard case .unresolved(_, .coreUnreachable) = panelSession.lifecycle else {
                    return XCTFail("Unreachable remote creation stays visible as unresolved, got \(panelSession.lifecycle)")
                }
            }
        }
    }
}

private final class HCLinkState: @unchecked Sendable {
    private let lock = NSLock()
    private var state = "connected"
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return state }
        set { lock.lock(); state = newValue; lock.unlock() }
    }
}

/// T12.2 wiring: a Studio panel's chip comes from ticket 15's remote status
/// binding, which this panel binds from its own hc lifecycle.
@MainActor
final class HCRemoteChipTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")

    private func snapshot(_ sequence: UInt64, _ availability: HCMachineAvailability) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        let record = HCTerminalRecord(key: key, state: .running, machineName: "studio",
                                      machineAvailability: availability, pid: 4242)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: record],
                                   machines: ["studio": availability])
    }

    private func placement(_ workspace: Workspace, _ panel: UUID, becomes expected: SessionPlacement?) async -> Bool {
        for _ in 0..<200 {
            if workspace.sessionPlacements[panel] == expected { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// A restored Studio panel whose line is down binds on its known key and
    /// reads "Studio, Reconnecting"; when the line returns it reads "Studio".
    func testRestoredAtlasPanelChipReadsReconnectingThenAtlas() async throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let session = ChipSession()
        session.feed.publish(snapshot(1, .disconnected))
        let identity = HCPanelIdentity(panelID: panel, key: key)
        let runtime = HCPanelSession(identity: identity, session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.unresolved(identity, .connectionLost))
        let down = await placement(workspace, panel, becomes: SessionPlacement(machineName: "Studio", mark: .reconnecting, machineKey: "studio"))
        XCTAssertTrue(down, "A down Studio line reads Reconnecting, never not kept; got \(String(describing: workspace.sessionPlacements[panel]))")
        session.feed.publish(snapshot(2, .connected))
        let up = await placement(workspace, panel, becomes: SessionPlacement(machineName: "Studio", mark: .none, machineKey: "studio"))
        XCTAssertTrue(up, "got \(String(describing: workspace.sessionPlacements[panel]))")
    }

    /// The binding needs an exact key: a creation still pending binds nothing,
    /// and a live record binds on the record's key.
    func testStatusBindingNeedsAnExactKey() {
        let target = HCRemoteTarget(machine: "studio")
        XCTAssertNil(HCMachineTarget.statusBinding(.unresolved(HCPanelIdentity(panelID: UUID(), origin: .fresh), .creationPending),
                                                   target: target))
        XCTAssertNil(HCMachineTarget.statusBinding(.new, target: target))
        let live = HCMachineTarget.statusBinding(.live(HCTerminalRecord(key: key, state: .running, machineName: "studio", pid: 1)),
                                                 target: target)
        XCTAssertEqual(live?.0, key)
        XCTAssertEqual(live?.1, "studio")
    }
}

// C11H-87: the stdin doorbell for an agent in a terminal on another machine.
@MainActor
final class HCRemoteDoorbellTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t13")
    private let claude = HCForeground(pid: 78, name: "claude", argv: ["claude"], cwd: "/Users/demo")
    private let zsh = HCForeground(pid: 77, name: "zsh", argv: ["-zsh"], cwd: "/Users/demo")

    private func record(_ foreground: HCForeground?, status: String? = nil, state: HCTerminalState = .running,
                        availability: HCMachineAvailability = .connected) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, machineName: "studio", machineAvailability: availability,
                         pid: 4242, foreground: foreground, status: status)
    }

    private func snapshot(_ sequence: UInt64, _ record: HCTerminalRecord,
                          machine: HCMachineAvailability = .connected) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: record],
                                   machines: ["studio": machine])
    }

    private func remotePanel(_ first: HCTerminalRecord) throws -> (Workspace, UUID, ChipSession) {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let session = ChipSession()
        session.feed.publish(snapshot(1, first))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key), session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(first))
        return (workspace, panel, session)
    }

    private func gate(_ workspace: Workspace, _ panel: UUID,
                      becomes expected: (Bool, MailboxStdinBuffer.PromptGate)) async -> Bool {
        for _ in 0..<200 {
            if let state = workspace.mailboxDoorbellGateState(surfaceId: panel),
               state.ownsTerminal == expected.0, state.promptGate == expected.1 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testOwnershipComesFromThatMachinesForegroundNeverLocalState() {
        XCTAssertTrue(HCRemoteMailboxForeground.agentOwnsTerminal(record(claude, status: "idle")))
        XCTAssertTrue(HCRemoteMailboxForeground.agentOwnsTerminal(record(.init(name: "codex", argv: ["codex"]))))
        XCTAssertFalse(HCRemoteMailboxForeground.agentOwnsTerminal(record(zsh)), "a plain shell at its prompt owns nothing")
        XCTAssertFalse(HCRemoteMailboxForeground.agentOwnsTerminal(record(nil)))
        XCTAssertFalse(HCRemoteMailboxForeground.agentOwnsTerminal(record(claude, state: .finished)))
        XCTAssertFalse(HCRemoteMailboxForeground.agentOwnsTerminal(nil), "no reachable record owns nothing")
    }

    func testStatusChangesAreTurnEdges() {
        XCTAssertEqual(HCRemoteMailboxForeground.turnEdge(previous: nil, current: "idle"), true)
        XCTAssertEqual(HCRemoteMailboxForeground.turnEdge(previous: "working", current: "done"), true)
        XCTAssertEqual(HCRemoteMailboxForeground.turnEdge(previous: "idle", current: "working"), false)
        XCTAssertEqual(HCRemoteMailboxForeground.turnEdge(previous: "idle", current: "blocked"), false,
                       "a blocked agent shows a question; the doorbell never types into it")
        XCTAssertNil(HCRemoteMailboxForeground.turnEdge(previous: "idle", current: "idle"))
        XCTAssertNil(HCRemoteMailboxForeground.turnEdge(previous: "working", current: "error"))
        XCTAssertNil(HCRemoteMailboxForeground.turnEdge(previous: "idle", current: nil))
    }

    /// C11H-328: no local TTY registers a remote agent, so hc's
    /// classification is what brings it into the fleet sweep.
    func testARemoteAgentJoinsTheFleetSweep() async throws {
        let (workspace, panel, _) = try remotePanel(record(claude, status: "idle"))
        var kind: String?
        for _ in 0..<200 where kind == nil {
            kind = AgentDetector.shared.remoteKindForTesting(workspaceId: workspace.id, panelId: panel)
            if kind == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(kind, "claude-code")
        AgentDetector.shared.unregister(workspaceId: workspace.id, panelId: panel)
    }

    func testClaudeAtItsPromptOnAtlasOpensTheDoorbell() async throws {
        let (workspace, panel, _) = try remotePanel(record(claude, status: "idle"))
        let open = await gate(workspace, panel, becomes: (true, .open))
        XCTAssertTrue(open, "got \(String(describing: workspace.mailboxDoorbellGateState(surfaceId: panel)))")
        XCTAssertTrue(workspace.hasLiveAttributedAgentWriter(surfaceId: panel))
    }

    func testAPlainShellOnAtlasNeverOwnsTheTerminal() async throws {
        let (workspace, panel, session) = try remotePanel(record(zsh))
        session.feed.publish(snapshot(2, record(zsh)))
        // Wait until hc's report has reached the workspace, so the check below
        // reads the remote decision and not the state before any report.
        var applied = false
        for _ in 0..<200 where !applied {
            applied = workspace.hcRemoteForeground[panel]?.name == "zsh" && workspace.hcRemoteAgentOwnsTerminal[panel] != nil
            if !applied { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(applied, "hc's zsh report never reached the workspace")
        XCTAssertEqual(workspace.hcRemoteAgentOwnsTerminal[panel], false)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        XCTAssertFalse(workspace.hasLiveAttributedAgentWriter(surfaceId: panel))
    }

    func testMailQueuedMidTurnRingsWhenTheRemoteAgentGoesIdle() async throws {
        let (workspace, panel, session) = try remotePanel(record(claude, status: "working"))
        let working = await gate(workspace, panel, becomes: (true, .closed))
        XCTAssertTrue(working, "a working remote agent holds the gate; got \(String(describing: workspace.mailboxDoorbellGateState(surfaceId: panel)))")
        session.feed.publish(snapshot(2, record(claude, status: "idle")))
        let idle = await gate(workspace, panel, becomes: (true, .open))
        XCTAssertTrue(idle, "hc's idle edge opens it; got \(String(describing: workspace.mailboxDoorbellGateState(surfaceId: panel)))")
    }

    func testALostLinkOwnsNothing() async throws {
        let (workspace, panel, session) = try remotePanel(record(claude, status: "idle"))
        let open = await gate(workspace, panel, becomes: (true, .open))
        XCTAssertTrue(open)
        session.feed.publish(snapshot(2, record(claude, status: "idle", availability: .disconnected), machine: .disconnected))
        let lost = await gate(workspace, panel, becomes: (false, .closed))
        XCTAssertTrue(lost, "got \(String(describing: workspace.mailboxDoorbellGateState(surfaceId: panel)))")
    }

    /// The delivery decision itself: with the remote owner, an empty composer
    /// rings; a plain shell stays buffered as agent_not_foreground. The
    /// composer, draft and trust-dialog guards still apply after this gate.
    func testDeliveryRingsForRemoteClaudeAndBuffersForAShell() {
        for (foreground, expectRing) in [(claude, true), (zsh, false)] {
            let state = MailboxStdinBufferStore()
            let surface = UUID()
            let owns = HCRemoteMailboxForeground.agentOwnsTerminal(record(foreground, status: "idle"))
            if owns { state.buffer.noteAgentTurn(surfaceId: surface, atPrompt: true, at: Date()) }
            var skipped: String?
            let result = MailboxStdinDelivery.deliver(
                state: state, surfaceId: surface,
                entry: .init(id: "01JMAIL", recipientName: "Glass Pathfinder", block: "<c11-msg/>", bufferedAt: Date()),
                gate: .init(isAgentKind: owns, ownsTerminal: owns),
                logEvicted: { _ in },
                ringInput: { _ in MailboxDoorbell.Input(prompt: .empty) },
                noteRing: { decision, _ in if case .skip(let reason) = decision { skipped = reason } })
            if expectRing {
                XCTAssertEqual(result, .doorbell(bytes: 10, effect: .ring))
            } else {
                XCTAssertEqual(result, .buffered(bytes: 10))
                XCTAssertEqual(skipped, "not_agent")
            }
        }
    }
}

// C11H-117: an agent seat idle through a relaunch. The restored local panel has
// no SessionStart and no turn edge, so the doorbell knew neither its agent nor
// its tty and held mail as agent_not_foreground forever. hc's report for the
// terminal relearns the agent (kernel-checked) and seeds the turn.
@MainActor
final class HCLocalDoorbellSeedTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "local-core", localAddress: "t13")
    private let agentPID: pid_t = 4711
    private let device: dev_t = 0x1234
    private let born: UInt64 = 1_700_000_000_000_000

    private func record(status: String?, foreground: String = "claude", hcStamp: Date? = nil,
                        turn: Int64? = nil, tty: String? = "/dev/ttys042") -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: .running, machineAvailability: .local, pid: 4242,
                         foreground: HCForeground(pid: agentPID, name: foreground, argv: [foreground]),
                         status: status,
                         statusTimestampMilliseconds: hcStamp.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                         turn: turn, tty: tty)
    }

    private func gate(_ workspace: Workspace, _ panel: UUID) -> MailboxStdinBuffer.PromptGate? {
        workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate
    }

    private func mail(_ workspace: Workspace, _ panel: UUID, _ id: String) {
        _ = workspace.deliverOrBufferMailboxStdin(surfaceId: panel, envelopeId: id,
                                                  recipientName: "glass-captain", block: "<c11-msg/>")
    }

    /// The kernel as it reads for a live agent in front of ttys042. A host
    /// test never owns a real terminal, so these facts are fixed.
    private func kernel(foregroundGroup: pid_t? = nil) -> MailboxAgentForeground.Kernel {
        let pid = agentPID, device = device, born = born
        return MailboxAgentForeground.Kernel(
            processInfo: { $0 == pid ? .init(processGroup: pid, terminalForegroundGroup: foregroundGroup ?? pid,
                                             terminalDevice: device, isZombie: false, startTime: born) : nil },
            ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
            isCanonical: { _ in false })
    }

    /// A restored local seat with one envelope already buffered: no agent
    /// learned, so the doorbell held it as agent_not_foreground.
    private func restoredSeat(screen: PromptInputState = .empty,
                              foregroundGroup: pid_t? = nil) throws -> (Workspace, UUID, () -> Int) {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panel,
            partial: ["mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "claude", argv: ["claude"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        workspace.mailboxKernel = kernel(foregroundGroup: foregroundGroup)
        workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        workspace.mailboxDoorbellScreenForTesting = { _ in screen }
        var rings = 0
        workspace.onMailboxDoorbellRingForTesting = { if $0 == panel { rings += 1 } }
        _ = workspace.deliverOrBufferMailboxStdin(surfaceId: panel, envelopeId: "01M6DHPY2Q3ZNEDDRTETSGKX8P",
                                                  recipientName: "glass-captain", block: "<c11-msg/>")
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false,
                       "before hc's report the restored seat has no agent: agent_not_foreground")
        XCTAssertEqual(rings, 0)
        return (workspace, panel, { rings })
    }

    /// The Glass case: hc reports the idle agent in front, and the buffered
    /// envelope rings exactly once.
    func testARestoredIdleSeatIsRungOnceWhenHCReportsItsAgent() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(workspace.mailboxAgentPID(surfaceId: panel) ?? 0, 0,
                       "the PID check reads the live kernel, which never knows this fake")
        XCTAssertEqual(workspace.panelTTYNames[panel], "/dev/ttys042", "hc's tty for the terminal")
        let state = workspace.mailboxDoorbellGateState(surfaceId: panel)
        XCTAssertEqual(state?.ownsTerminal, true, "relearned from hc's record, kernel-checked")
        XCTAssertEqual(state?.promptGate, .open, "hc's idle status seeds the turn at its prompt")
        XCTAssertEqual(rings(), 1)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(rings(), 1, "the same report again rings nothing more")
    }

    /// C11H-184: hc's inventory names no tty. The seat waits for the tty
    /// agent recovery reads from the terminal's root process, then rings.
    func testARecordWithoutATTYRelearnsFromTheRecoveredTTY() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", tty: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false,
                       "no tty yet: nothing to check the agent against")
        XCTAssertEqual(rings(), 0)
        workspace.panelTTYNames[panel] = "/dev/ttys042"  // HCAgentRecoveryController.apply
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", tty: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true,
                       "relearned against the recovered tty, kernel-checked")
        XCTAssertEqual(rings(), 1)
    }

    /// A surviving bridge's hold applies only while that bridge is the panel's
    /// listener and the hold lasts.
    func testACarriedHoldEndsWithItsBridgeOrItsTime() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let reg = MailboxNativeDoorbell.Registration(id: UUID(), panelID: panel, agentPID: agentPID, processStart: born,
            sessionID: UUID().uuidString, route: .claudeInbox, canQueue: false, supportsInlineMail: true)
        MailboxNativeDoorbell.shared.register(reg, write: { _ in true }, close: {})
        defer { MailboxNativeDoorbell.shared.disconnect(reg) }
        let ids = ["01M6HZ7FRRAB13BQZTPFRJXV76"]
        workspace.noteCarriedInlineHold(registration: reg, ids: ids)
        XCTAssertEqual(workspace.mailboxCarriedHeldIds(surfaceId: panel), Set(ids))
        XCTAssertEqual(workspace.mailboxCarriedHeldIds(surfaceId: panel,
            now: Date().addingTimeInterval(Workspace.MailboxCarriedHold.lifetime + 1)), [],
            "past its lifetime the mail is offered again")
        workspace.noteCarriedInlineHold(registration: reg, ids: ids)
        let next = MailboxNativeDoorbell.Registration(id: UUID(), panelID: panel, agentPID: agentPID, processStart: born,
            sessionID: UUID().uuidString, route: .claudeInbox, canQueue: false, supportsInlineMail: true)
        MailboxNativeDoorbell.shared.register(next, write: { _ in true }, close: {})
        defer { MailboxNativeDoorbell.shared.disconnect(next) }
        XCTAssertEqual(workspace.mailboxCarriedHeldIds(surfaceId: panel), [], "a replaced bridge's hold ends")
    }

    /// C11H-184: a carried acceptance that arrives before the relearn waits,
    /// and runs once ownership is confirmed, with no mail buffered at all.
    func testACarriedClaimBeforeTheRelearnRunsOnceOwnershipIsConfirmed() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "claude", argv: ["claude"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        workspace.mailboxKernel = kernel()
        workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        let reg = MailboxNativeDoorbell.Registration(id: UUID(), panelID: panel, agentPID: agentPID, processStart: born,
            sessionID: UUID().uuidString, route: .claudeInbox, canQueue: false, supportsInlineMail: true)
        MailboxNativeDoorbell.shared.register(reg, write: { _ in true }, close: {})
        defer { MailboxNativeDoorbell.shared.disconnect(reg) }
        workspace.claimCarriedInlineMailbox(registration: reg, ids: ["01M6HZ7FRRAB13BQZTPFRJXV76"])
        XCTAssertTrue(workspace.hasPendingCarriedMailboxClaim(surfaceId: panel),
                      "the bridge's word is not ownership: the claim waits for the kernel")
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "working"))
        XCTAssertFalse(workspace.hasPendingCarriedMailboxClaim(surfaceId: panel),
                       "the relearn confirmed ownership and the claim ran, though nothing was buffered")
    }

    /// Review 2 (C11H-238): ownership confirmed later without a relearn. The
    /// agent is learned while its tty is canonical (recovery), so the carried
    /// claim waits; the tty then leaves canonical mode with no hc, hook or tty
    /// event. The tracker's own retry confirms ownership and runs the claim.
    func testACarriedClaimRunsWhenOwnershipIsConfirmedLaterWithoutARelearn() throws {
        final class Flag: @unchecked Sendable { var canonical = true }
        let flag = Flag()
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "claude", argv: ["claude"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        let pid = agentPID, device = device, born = born
        workspace.mailboxKernel = MailboxAgentForeground.Kernel(
            processInfo: { $0 == pid ? .init(processGroup: pid, terminalForegroundGroup: pid, terminalDevice: device,
                                             isZombie: false, startTime: born) : nil },
            ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
            isCanonical: { _ in flag.canonical })
        workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        let reg = MailboxNativeDoorbell.Registration(id: UUID(), panelID: panel, agentPID: agentPID, processStart: born,
            sessionID: UUID().uuidString, route: .claudeInbox, canQueue: false, supportsInlineMail: true)
        MailboxNativeDoorbell.shared.register(reg, write: { _ in true }, close: {})
        defer { MailboxNativeDoorbell.shared.disconnect(reg) }
        workspace.claimCarriedInlineMailbox(registration: reg, ids: ["01M6HZ7FRRAB13BQZTPFRJXV76"])
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertTrue(workspace.hasPendingCarriedMailboxClaim(surfaceId: panel), "canonical tty: not owned yet")
        flag.canonical = false
        let retried = expectation(description: "the tracker's first retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + HCLocalOwnershipTracker.retryDelays[0] + 0.5) { retried.fulfill() }
        wait(for: [retried], timeout: 5)
        XCTAssertFalse(workspace.hasPendingCarriedMailboxClaim(surfaceId: panel),
                       "confirmed ownership runs the waiting claim with no other event")
    }

    /// The recovered tty is still checked: an agent on another terminal is not relearned.
    func testARecoveredTTYTheAgentIsNotOnIsNotRelearned() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.panelTTYNames[panel] = "/dev/ttys099"
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", tty: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false)
        XCTAssertEqual(rings(), 0)
    }

    /// A blocked agent shows a question: owned, but never typed into.
    func testABlockedRestoredSeatIsNeverRung() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "blocked"))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        XCTAssertEqual(rings(), 0)
    }

    /// No status from hc: the turn is unknown, and an empty composer rings.
    func testAnUnknownTurnAtAnEmptyComposerRings() throws {
        let (workspace, panel, rings) = try restoredSeat(screen: .empty)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .unknown)
        XCTAssertEqual(rings(), 1)
    }

    /// No status from hc and text in the composer: the draft holds the ring.
    func testAnUnknownTurnWithADraftHolds() throws {
        let (workspace, panel, rings) = try restoredSeat(screen: .draft)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true)
        XCTAssertEqual(rings(), 0)
    }

    /// hc alone never authorizes typing: when the kernel says another group
    /// holds the terminal, nothing is learned and the mail stays buffered.
    func testHCAloneNeverOwnsALocalTerminal() throws {
        let (workspace, panel, rings) = try restoredSeat(foregroundGroup: 99)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false)
        XCTAssertEqual(rings(), 0)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", foreground: "zsh"))
        XCTAssertEqual(rings(), 0, "a shell in front is never an agent")
    }

    /// hc clears the status time when the word changes, so these reports
    /// carry none. Working, then idle: the idle change rings the held mail.
    func testWorkingThenIdleWithoutTimestampsRingsOnTheIdleChange() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "working"))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true)
        XCTAssertEqual(gate(workspace, panel), .closed)
        XCTAssertEqual(rings(), 0)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(gate(workspace, panel), .open)
        XCTAssertEqual(rings(), 1)
    }

    /// Idle, then working or blocked, without timestamps: each holds new mail,
    /// and the next idle rings it.
    func testIdleThenWorkingOrBlockedWithoutTimestampsHoldsTheMail() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(rings(), 1)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "working"))
        XCTAssertEqual(gate(workspace, panel), .closed, "working holds")
        mail(workspace, panel, "01M6DHPY2Q3ZNEDDRTETSGKX8Q")
        XCTAssertEqual(rings(), 1)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "blocked"))
        XCTAssertEqual(gate(workspace, panel), .closed, "blocked holds")
        mail(workspace, panel, "01M6DHPY2Q3ZNEDDRTETSGKX8R")
        XCTAssertEqual(rings(), 1, "never typed into a question")
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(gate(workspace, panel), .open)
        XCTAssertEqual(rings(), 2)
    }

    /// A status older than a newer submit is rejected, and the same word is
    /// considered again when hc supplies a time after it.
    func testAStaleStatusIsReconsideredWhenItsTimeArrives() throws {
        let (workspace, panel, rings) = try restoredSeat()
        let now = Date()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "working"))
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working,
                                            at: now.addingTimeInterval(100))
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", hcStamp: now.addingTimeInterval(50)))
        XCTAssertEqual(gate(workspace, panel), .closed, "an idle from before the submit is stale")
        XCTAssertEqual(rings(), 0)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", hcStamp: now.addingTimeInterval(200)))
        XCTAssertEqual(gate(workspace, panel), .open, "the same word with a newer time is new evidence")
        XCTAssertEqual(rings(), 1)
    }

    /// The same word repeated with no new time never reopens a turn a submit
    /// moved since.
    func testARepeatedStatusNeverReopensATurnASubmitMoved() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(rings(), 1)
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working,
                                            at: Date().addingTimeInterval(1))
        XCTAssertEqual(gate(workspace, panel), .closed)
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle"))
        XCTAssertEqual(gate(workspace, panel), .closed, "a repeated idle is not a new idle")
        XCTAssertEqual(rings(), 1)
    }

    /// Every ownership fact agrees (live process, foreground group, tty, raw
    /// mode, empty composer) but hc reports a shell in front: nothing is
    /// learned and nothing is typed.
    func testAShellInFrontIsNeverLearnedEvenWhenTheKernelAgrees() throws {
        let (workspace, panel, rings) = try restoredSeat()
        workspace.noteHCLocalMailbox(panelId: panel, record: record(status: "idle", foreground: "zsh"))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, false)
        XCTAssertNil(workspace.panelTTYNames[panel], "no tty learned from a shell")
        XCTAssertNil(workspace.hcLocalMailboxStatus[panel])
        XCTAssertEqual(rings(), 0)
    }

    func testStatusEvidenceIsNewOnlyForANewWordTurnOrTime() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(5)
        let first = Workspace.HCLocalStatusEvidence.next(nil, status: "idle", turn: 3, hcStamp: nil, now: t0)
        XCTAssertEqual(first?.stamp, t0, "no hc time: stamped when first seen")
        XCTAssertNil(Workspace.HCLocalStatusEvidence.next(first, status: "idle", turn: 3, hcStamp: nil, now: t1),
                     "the same word again is nothing new")
        let timed = Workspace.HCLocalStatusEvidence.next(first, status: "idle", turn: 3, hcStamp: t0.addingTimeInterval(-2), now: t1)
        XCTAssertEqual(timed?.stamp, t0.addingTimeInterval(-2), "hc's own time replaces first-seen")
        XCTAssertEqual(timed?.firstSeen, t0)
        XCTAssertNil(Workspace.HCLocalStatusEvidence.next(timed, status: "idle", turn: 3,
                                                          hcStamp: t0.addingTimeInterval(-2), now: t1))
        XCTAssertEqual(Workspace.HCLocalStatusEvidence.next(first, status: "idle", turn: 4, hcStamp: nil, now: t1)?.stamp, t1,
                       "a new hc turn under the same word is new")
        XCTAssertEqual(Workspace.HCLocalStatusEvidence.next(first, status: "working", turn: 3, hcStamp: nil, now: t1)?.stamp, t1)
    }

    func testTheKernelCheckForAnHCReportedAgent() {
        let live = MailboxAgentForeground.ProcessTerminalInfo(processGroup: 7, terminalForegroundGroup: 7,
            terminalDevice: device, isZombie: false, startTime: born)
        XCTAssertEqual(Workspace.hcLocalAgentProcess(pid: 7, info: live, ttyDevice: device),
                       .init(pid: 7, startTime: born))
        var background = live; background = .init(processGroup: 7, terminalForegroundGroup: 8,
            terminalDevice: device, isZombie: false, startTime: born)
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: background, ttyDevice: device), "not the foreground group")
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: live, ttyDevice: device + 1), "another terminal")
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: live, ttyDevice: nil))
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: nil, ttyDevice: device), "no such process")
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: .init(processGroup: 7, terminalForegroundGroup: 7,
            terminalDevice: device, isZombie: true, startTime: born), ttyDevice: device))
        XCTAssertNil(Workspace.hcLocalAgentProcess(pid: 7, info: .init(processGroup: 7, terminalForegroundGroup: 7,
            terminalDevice: device, isZombie: false, startTime: 0), ttyDevice: device))
    }

    /// hc's status seeds an empty clock and never overrides a newer edge.
    func testHCStatusSeedsTheTurnAndNeverOverridesANewerEdge() {
        var buffer = MailboxStdinBuffer()
        let panel = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(buffer.noteHCStatusEdge(surfaceId: panel, atPrompt: true, at: t0), "first observation seeds")
        XCTAssertEqual(buffer.promptGate(surfaceId: panel, isAgentKind: true, agentOwnsTerminal: true,
                                         journalTurnOpen: false, now: t0), .open)
        buffer.noteAgentTurn(surfaceId: panel, atPrompt: false, at: t0.addingTimeInterval(10))   // a hook: working
        XCTAssertFalse(buffer.noteHCStatusEdge(surfaceId: panel, atPrompt: true, at: t0.addingTimeInterval(5)),
                       "an idle status older than the hook's working edge is stale")
        XCTAssertEqual(buffer.agentTurn(surfaceId: panel)?.atPrompt, false)
        buffer.noteSubmit(surfaceId: panel, at: t0.addingTimeInterval(30))
        XCTAssertFalse(buffer.noteHCStatusEdge(surfaceId: panel, atPrompt: true, at: t0.addingTimeInterval(20)),
                       "an idle status older than the latest submit is stale")
        XCTAssertTrue(buffer.noteHCStatusEdge(surfaceId: panel, atPrompt: true, at: t0.addingTimeInterval(40)))

        var restored = MailboxStdinBuffer()
        restored.noteAgentAttached(surfaceId: panel, at: t0.addingTimeInterval(100))
        XCTAssertFalse(restored.noteHCStatusEdge(surfaceId: panel, atPrompt: true, at: t0.addingTimeInterval(50)),
                       "a status from before the agent attached describes an earlier process")
        XCTAssertNil(restored.agentTurn(surfaceId: panel))
    }
}

private final class ChipSession: HCSession, @unchecked Sendable {
    let feed = HCSessionFeed()
    private let unavailable = HCUnavailableRuntime()
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { await unavailable.resolve(identity) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { await unavailable.create(request) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        try await unavailable.attach(key, sink: sink, display: display)
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { await unavailable.end(key) }
    func diagnostics() async -> HCDiagnostics { await unavailable.diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await unavailable.recoverSession(reason: reason) }
}

/// What reached the wire through a terminal channel.
private final class LinkWire: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var made: [any HCChannel] = []
    var dataWrites: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func wrote() { lock.lock(); writes += 1; lock.unlock() }
    var channels: [any HCChannel] {
        get { lock.lock(); defer { lock.unlock() }; return made }
        set { lock.lock(); made = newValue; lock.unlock() }
    }
}

private final class LinkChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 3
    let connectionGeneration: UInt64 = 1
    private let wire: LinkWire
    init(_ wire: LinkWire) { self.wire = wire }
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        .reserved(HCWriteReservation(id: UUID(), operationID: operationID, attachmentGeneration: attachmentGeneration,
                                     connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        wire.wrote()
        let bytes = batch.frames.reduce(0) { total, frame in
            if case .data(let data) = frame { return total + data.count }
            return total
        }
        return .written(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                       bodyBytesWritten: bytes, returnWritten: false))
    }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

private final class LinkReports: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [HCInputOutcome] = []
    func add(_ outcome: HCInputOutcome) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    var all: [HCInputOutcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
    func wait(count: Int) async -> [HCInputOutcome] {
        for _ in 0..<200 where all.count < count { try? await Task.sleep(nanoseconds: 10_000_000) }
        return all
    }
}

/// T12.6 through the entries that do not go through `newTerminalSplit`: the
/// panel-bar split buttons (bonsplit's non-programmatic split) and the
/// demoted `panel.split` panel.
// C11H-123: a Codex idle at its prompt with a background terminal running.
// Codex itself keeps reporting OSC 7501 `working` (hc stores it verbatim), so
// hc read `working` for hours and the doorbell never rang. Codex's own turn
// signal (notify turn-complete, rollout transcript) now decides its turn;
// hc's word is a hint dated by hc's time.
@MainActor
final class CodexTurnSignalTests: XCTestCase {
    private let remoteKey = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t36")
    private let localKey = HCTerminalKey(owningCoreID: "local-core", localAddress: "t36")
    private let instance = UUID()
    private let agentPID: pid_t = 4711
    private let device: dev_t = 0x1234
    private let born: UInt64 = 1_700_000_000_000_000

    // MARK: - The rule

    func testHCWorkingIsStaleOnlyWhenCodexsOwnSignalEndedATurnAfterIt() {
        XCTAssertFalse(CodexTurnAuthority.hcWordIsStale("working", hcStampMs: nil, turnEndMs: nil),
                       "no Codex turn signal: hc's word stands, as before")
        XCTAssertTrue(CodexTurnAuthority.hcWordIsStale("working", hcStampMs: nil, turnEndMs: 5_000),
                      "no hc time after a turn end: a hint only")
        XCTAssertTrue(CodexTurnAuthority.hcWordIsStale("working", hcStampMs: 4_000, turnEndMs: 5_000))
        XCTAssertTrue(CodexTurnAuthority.hcWordIsStale("working", hcStampMs: 5_000, turnEndMs: 5_000))
        XCTAssertFalse(CodexTurnAuthority.hcWordIsStale("working", hcStampMs: 5_001, turnEndMs: 5_000),
                       "a working hc dates after the turn end is a new turn")
        XCTAssertTrue(CodexTurnAuthority.hcWordIsStale("blocked", hcStampMs: 4_000, turnEndMs: 5_000))
        XCTAssertFalse(CodexTurnAuthority.hcWordIsStale("idle", hcStampMs: nil, turnEndMs: 5_000), "hc's idle still applies")
        XCTAssertFalse(CodexTurnAuthority.hcWordIsStale("done", hcStampMs: 1, turnEndMs: 5_000))
    }

    // MARK: - The journal (remote panels, and the sidebar's phase)

    private func journalOwner(_ kind: String = "codex", panel: UUID) -> JournalOwner {
        HCRemoteStatus.owner(panelID: panel, key: remoteKey, agentKind: kind)
    }

    private func hcRecord(_ status: String, at ms: Int64?, foreground: String = "codex") -> HCTerminalRecord {
        HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio", machineAvailability: .connected,
                         pid: 4242, foreground: HCForeground(pid: 78, name: foreground, argv: [foreground]),
                         status: status, statusTimestampMilliseconds: ms, turn: 3)
    }

    private func fold(_ prior: JournalSnapshot?, _ draft: JournalDraft, _ seq: Int64,
                      hc: Bool = false, transcript: Bool = false, committedAtMs: Int64? = nil) -> JournalFoldResult {
        JournalReducer.fold(previous: prior, draft: draft, sequence: seq, committedAtMs: committedAtMs ?? 100_000 + seq,
                            tick: UInt64(seq), instanceID: instance,
                            context: JournalContext(eligible: true, hcStatusEvidence: hc, verifiedNativeClock: transcript))
    }

    private func hcDraft(_ status: String, at ms: Int64?, owner: JournalOwner, workspace: UUID) throws -> JournalDraft {
        try XCTUnwrap(HCRemoteStatus.draft(record: hcRecord(status, at: ms, foreground: owner.agentKind == "codex" ? "codex" : "claude"),
                                           owner: owner, workspaceID: workspace, observedAtMs: 99_000))
    }

    private func turnEnd(_ adapter: JournalAdapter, at ms: Int64, owner: JournalOwner, workspace: UUID,
                         kind: JournalKind = .turnCompleted) -> JournalDraft {
        let transcript = adapter == .codexTranscript
        return JournalDraft(kind: kind, emittedAtMs: ms, occurredAtMs: transcript ? ms : nil,
                            timeQuality: transcript ? .nativeLocal : .missing,
                            panelID: owner.panelID, workspaceID: workspace, sessionID: owner.sessionID,
                            agentKind: owner.agentKind, source: adapter.source, adapter: adapter,
                            adapterVersion: transcript ? JournalNativeClockEvidence.codexTranscriptVersion : "1",
                            nativeEvent: transcript ? (kind == .turnInterrupted ? "turn.interrupted" : "turn.completed")
                                                    : "agent-turn-complete")
    }

    /// The Astra case on studio/t36: hc stuck on `working` from the turn's
    /// start, the turn ends by Codex's own notify, and every later report of
    /// that same `working` (a reconnect, a timeless re-observation) is stale.
    func testACodexTurnEndBeatsHCsStaleWorking() throws {
        let panel = UUID(), workspace = UUID(), owner = journalOwner(panel: panel)
        var s = try XCTUnwrap(fold(nil, try hcDraft("working", at: 1_000, owner: owner, workspace: workspace), 1, hc: true).snapshot)
        XCTAssertEqual(s.phase, .working)
        let end = fold(s, turnEnd(.codexNotify, at: 5_000, owner: owner, workspace: workspace), 2)
        s = try XCTUnwrap(end.snapshot)
        XCTAssertEqual(s.phase, .idle, "Codex's own turn end, with its background terminal still running")
        XCTAssertEqual(CodexTurnAuthority.turnEndMs(s), 5_000)
        for (seq, ms) in [(3, Optional<Int64>(1_000)), (4, nil), (5, 5_000)] as [(Int64, Int64?)] {
            let again = fold(s, try hcDraft("working", at: ms, owner: owner, workspace: workspace), seq, hc: true)
            XCTAssertEqual(again.effect, .stale, "hc working at \(String(describing: ms)) after the turn end")
            XCTAssertEqual(again.reason, "hc_status_older_than_turn_end")
            XCTAssertEqual(again.snapshot?.phase, .idle)
        }
        let blocked = fold(s, try hcDraft("blocked", at: 2_000, owner: owner, workspace: workspace), 6, hc: true)
        XCTAssertEqual(blocked.snapshot?.phase, .idle, "an older blocked is stale too")
        let next = fold(s, try hcDraft("working", at: 6_000, owner: owner, workspace: workspace), 7, hc: true)
        XCTAssertEqual(next.effect, .applied, "hc's working dated after the turn end is the next turn")
        XCTAssertEqual(next.snapshot?.phase, .working)
        let idle = fold(s, try hcDraft("idle", at: nil, owner: owner, workspace: workspace), 8, hc: true)
        XCTAssertEqual(idle.snapshot?.phase, .idle, "hc's idle still applies")
        XCTAssertEqual(idle.effect, .applied)
    }

    /// The transcript's turn end and turn abort count as Codex's own signal.
    func testATranscriptTurnEndOrInterruptAlsoMarksTheTurnEnd() throws {
        for kind in [JournalKind.turnCompleted, .turnInterrupted] {
            let panel = UUID(), workspace = UUID(), owner = journalOwner(panel: panel)
            let started = JournalDraft(kind: .turnStarted, emittedAtMs: 900, occurredAtMs: 900, timeQuality: .nativeLocal,
                panelID: panel, workspaceID: workspace, sessionID: owner.sessionID, agentKind: "codex",
                source: .transcript, adapter: .codexTranscript,
                adapterVersion: JournalNativeClockEvidence.codexTranscriptVersion, nativeEvent: "turn.started")
            var s = try XCTUnwrap(fold(nil, started, 1, transcript: true).snapshot)
            s = try XCTUnwrap(fold(s, turnEnd(.codexTranscript, at: 4_000, owner: owner, workspace: workspace, kind: kind),
                                   2, transcript: true).snapshot)
            XCTAssertEqual(s.phase, .idle, "\(kind)")
            XCTAssertEqual(CodexTurnAuthority.turnEndMs(s), 4_000, "\(kind)")
            let stale = fold(s, try hcDraft("working", at: 3_000, owner: owner, workspace: workspace), 3, hc: true)
            XCTAssertEqual(stale.snapshot?.phase, .idle, "\(kind)")
        }
    }

    // MARK: C11H-134: a remote Claude's hooks and hc

    /// A relayed Claude hook as c11 journals it: mapped by the real mapping,
    /// stamped on the agent machine's clock, attributed to the hc owner.
    private func relayedClaudeHook(_ subcommand: String, _ object: [String: Any] = [:], at ms: Int64,
                                   owner: JournalOwner, workspace: UUID) throws -> JournalDraft {
        var input = object
        input["session_id"] = "claude-session-1"
        var draft = try XCTUnwrap(ClaudeHookMapping.map(subcommand: subcommand, object: input))
        draft.emittedAtMs = ms
        draft.panelID = owner.panelID
        draft.workspaceID = workspace
        draft.sessionID = owner.sessionID
        return draft
    }

    /// Escape ends a remote Claude's turn with no hook. hc's idle, dated after
    /// the last hook edge on that machine's clock, ends it and opens the mail
    /// gate; an hc idle from before the submit does not.
    func testARemoteClaudeTurnInterruptedWithoutAStopEndsOnANewerHCIdle() throws {
        let panel = UUID(), workspace = UUID()
        let owner = journalOwner("claude-code", panel: panel)
        var s = try XCTUnwrap(fold(nil, try hcDraft("idle", at: 1_000, owner: owner, workspace: workspace), 1, hc: true).snapshot)
        s = try XCTUnwrap(fold(s, try relayedClaudeHook("prompt-submit", at: 2_000, owner: owner, workspace: workspace), 2).snapshot)
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(RemoteClaudeTurnAuthority.hookEdgeMs(s), 2_000)
        XCTAssertTrue(MailboxStdinDelivery.journalTurnOpen(s), "the hook's turn holds mail")

        let stale = fold(s, try hcDraft("idle", at: 1_500, owner: owner, workspace: workspace), 3, hc: true)
        XCTAssertEqual(stale.reason, "lower_confidence", "an hc idle from before the submit is not this turn's end")
        XCTAssertEqual(stale.snapshot?.phase, .working)
        let sameTime = fold(s, try hcDraft("idle", at: 2_000, owner: owner, workspace: workspace), 3, hc: true)
        XCTAssertEqual(sameTime.snapshot?.phase, .working, "not after the hook edge")
        let timeless = fold(s, try hcDraft("idle", at: nil, owner: owner, workspace: workspace), 3, hc: true)
        XCTAssertEqual(timeless.snapshot?.phase, .working, "hc's word without hc's time")
        let working = fold(s, try hcDraft("working", at: 2_500, owner: owner, workspace: workspace), 3, hc: true)
        XCTAssertEqual(working.reason, "lower_confidence", "hc's working never displaces a hook edge")

        let ended = try XCTUnwrap(fold(s, try hcDraft("idle", at: 2_500, owner: owner, workspace: workspace), 3, hc: true).snapshot)
        XCTAssertEqual(ended.phase, .idle)
        XCTAssertFalse(MailboxStdinDelivery.journalTurnOpen(ended), "mail may ring again")
        let next = try XCTUnwrap(fold(ended, try relayedClaudeHook("prompt-submit", at: 3_000, owner: owner,
                                                                   workspace: workspace), 4).snapshot)
        XCTAssertEqual(next.phase, .working, "the next submit starts a turn as before")
    }

    /// A remote Claude waiting on its own question stays blocked whatever hc
    /// says: the answer, not hc, ends the ask.
    func testARemoteClaudeAskStaysBlockedOverANewerHCIdle() throws {
        let panel = UUID(), workspace = UUID()
        let owner = journalOwner("claude-code", panel: panel)
        var s = try XCTUnwrap(fold(nil, try relayedClaudeHook("prompt-submit", at: 2_000, owner: owner, workspace: workspace), 1).snapshot)
        s = try XCTUnwrap(fold(s, try relayedClaudeHook("pre-tool-use", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_1"],
                                                       at: 2_200, owner: owner, workspace: workspace), 2).snapshot)
        XCTAssertEqual(s.phase, .blocked)
        let idle = fold(s, try hcDraft("idle", at: 9_000, owner: owner, workspace: workspace), 3, hc: true)
        XCTAssertEqual(idle.snapshot?.phase, .blocked)
        XCTAssertTrue(MailboxStdinDelivery.journalTurnOpen(idle.snapshot), "mail is never typed into a question")
    }

    /// A local Claude (its owner is its own session) keeps its hooks over hc.
    func testALocalClaudeTurnIgnoresHCIdle() throws {
        let panel = UUID(), workspace = UUID()
        let owner = JournalOwner(panelID: panel, agentKind: "claude-code", sessionID: "claude-session-1")
        let s = try XCTUnwrap(fold(nil, try relayedClaudeHook("prompt-submit", at: 2_000, owner: owner, workspace: workspace), 1).snapshot)
        XCTAssertNil(RemoteClaudeTurnAuthority.hookEdgeMs(s))
        let idle = fold(s, try hcDraft("idle", at: 9_000, owner: owner, workspace: workspace), 2, hc: true)
        XCTAssertEqual(idle.reason, "lower_confidence")
        XCTAssertEqual(idle.snapshot?.phase, .working)
    }

    /// Without a Codex turn signal nothing changes: a Claude panel's hooks
    /// keep their rank over hc, and a Codex panel with only hc follows hc.
    func testWithoutACodexTurnSignalHCIsTreatedAsBefore() throws {
        let panel = UUID(), workspace = UUID()
        let claude = journalOwner("claude-code", panel: panel)
        let stop = JournalDraft(kind: .turnCompleted, emittedAtMs: 5_000, panelID: panel, workspaceID: workspace,
                                sessionID: claude.sessionID, agentKind: "claude-code", source: .hook,
                                adapter: .claudeHook, nativeEvent: "Stop")
        var s = try XCTUnwrap(fold(nil, try hcDraft("working", at: 1_000, owner: claude, workspace: workspace), 1, hc: true).snapshot)
        s = try XCTUnwrap(fold(s, stop, 2).snapshot)
        XCTAssertNil(CodexTurnAuthority.turnEndMs(s), "a Claude Stop is not a Codex turn end")
        let newer = fold(s, try hcDraft("working", at: 6_000, owner: claude, workspace: workspace), 3, hc: true)
        XCTAssertEqual(newer.effect, .advisory, "Claude's hook still outranks hc")
        XCTAssertEqual(newer.reason, "lower_confidence")
        XCTAssertEqual(newer.snapshot?.phase, .idle)

        let codex = journalOwner(panel: UUID())
        var c = try XCTUnwrap(fold(nil, try hcDraft("idle", at: 1_000, owner: codex, workspace: workspace), 1, hc: true).snapshot)
        c = try XCTUnwrap(fold(c, try hcDraft("working", at: nil, owner: codex, workspace: workspace), 2, hc: true).snapshot)
        XCTAssertEqual(c.phase, .working, "hc only: its working stands, as before")
    }

    // MARK: - A local Codex panel (the C11H-117 seed)

    private func localRecord(_ status: String, at ms: Int64?) -> HCTerminalRecord {
        HCTerminalRecord(key: localKey, state: .running, machineAvailability: .local, pid: 4242,
                         foreground: HCForeground(pid: agentPID, name: "codex", argv: ["codex"]),
                         status: status, statusTimestampMilliseconds: ms, turn: 3, tty: "/dev/ttys042")
    }

    private func seat(remote: Bool, journal: @escaping () -> JournalSnapshot?) throws
        -> (Workspace, UUID, () -> Int) {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panel,
            partial: ["mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "codex", argv: ["codex"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        if !remote {
            let pid = agentPID, device = device, born = born
            workspace.mailboxKernel = MailboxAgentForeground.Kernel(
                processInfo: { $0 == pid ? .init(processGroup: pid, terminalForegroundGroup: pid, terminalDevice: device,
                                                 isZombie: false, startTime: born) : nil },
                ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
                isCanonical: { _ in false })
            // C11H-238: the ownership probe runs off main in the app; inline here.
            workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        }
        workspace.mailboxDoorbellScreenForTesting = { _ in .empty }
        workspace.mailboxJournalSnapshotForTesting = { $0 == panel ? journal() : nil }
        var rings = 0
        workspace.onMailboxDoorbellRingForTesting = { if $0 == panel { rings += 1 } }
        return (workspace, panel, { rings })
    }

    private func mail(_ workspace: Workspace, _ panel: UUID, _ id: String) {
        _ = workspace.deliverOrBufferMailboxStdin(surfaceId: panel, envelopeId: id,
                                                  recipientName: "astra-reviewer", block: "<c11-msg/>")
    }

    private func idleCodex(panel: UUID, turnEndMs: Int64, owner: JournalOwner? = nil) -> JournalSnapshot {
        var s = JournalSnapshot(owner: owner ?? JournalOwner(panelID: panel, agentKind: "codex", sessionID: "codex-thread"),
                                workspaceID: nil, appInstanceID: instance)
        s.phase = .idle
        s.adapter = .codexNotify
        s.source = .hook
        s.rank = JournalSource.hook.rank
        s.confirmation = .confirmed
        s.connection = .live
        s.nativeWatermarks[CodexTurnAuthority.turnEndKey] = turnEndMs
        return s
    }

    /// A local Codex whose own notify ended its turn, while hc still reports
    /// the `working` Codex sent at the turn's start (first seen after a
    /// relaunch, so with no hc time or an older one): hc never closes the
    /// gate, and the buffered mail rings once. A working hc dates after the
    /// turn end is a new turn and holds the next mail.
    func testALocalCodexIdleWithABackgroundJobRingsFromItsOwnTurnEnd() throws {
        let endMs = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        var journal: JournalSnapshot?
        let (workspace, panel, rings) = try seat(remote: false, journal: { journal })
        journal = idleCodex(panel: panel, turnEndMs: endMs)
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG4")
        XCTAssertEqual(rings(), 0, "no agent learned yet")
        workspace.noteHCLocalMailbox(panelId: panel, record: localRecord("working", at: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true)
        XCTAssertNotEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed,
                          "hc's working with no time is a hint after Codex's own turn end")
        XCTAssertEqual(rings(), 1)
        workspace.noteHCLocalMailbox(panelId: panel, record: localRecord("working", at: endMs - 600_000))
        XCTAssertNotEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed,
                          "hc's time for that working is the turn's start, before the turn end")
        workspace.noteHCLocalMailbox(panelId: panel, record: localRecord("working", at: endMs + 1_000))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed,
                       "a working dated after the turn end is the next turn")
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG5")
        XCTAssertEqual(rings(), 1, "mail during the next turn waits")
    }

    /// Without a Codex journal the C11H-117 seed is unchanged: hc's working
    /// holds the mail.
    func testALocalCodexWithoutItsOwnSignalFollowsHCAsBefore() throws {
        let (workspace, panel, rings) = try seat(remote: false, journal: { nil })
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG6")
        workspace.noteHCLocalMailbox(panelId: panel, record: localRecord("working", at: nil))
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        XCTAssertEqual(rings(), 0)
    }

    // MARK: - A remote Codex panel (studio/t36)

    private func snapshot(_ sequence: UInt64, _ record: HCTerminalRecord,
                          machine: HCMachineAvailability = .connected) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [remoteKey: record],
                                   machines: ["studio": machine])
    }

    private func settle(_ until: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if until() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// hc stuck on Codex's `working` holds the mail; Codex's turn end,
    /// relayed from studio and accepted by the journal, rings it once. A
    /// reconnect that re-reports the same old `working` does not close it.
    func testARemoteCodexStuckOnWorkingRingsOnItsRelayedTurnEnd() async throws {
        var journal: JournalSnapshot?
        let (workspace, panel, rings) = try seat(remote: true, journal: { journal })
        let stuck = hcRecord("working", at: 1_000)
        let session = ChipSession()
        session.feed.publish(snapshot(1, stuck))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: remoteKey), session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(stuck))
        let held = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel).map { $0 == (true, .closed) } ?? false }
        XCTAssertTrue(held, "got \(String(describing: workspace.mailboxDoorbellGateState(surfaceId: panel)))")
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG7")
        XCTAssertEqual(rings(), 0, "working: held")

        // The relayed notify folds to idle; the journal publishes its boundary.
        journal = idleCodex(panel: panel, turnEndMs: 5_000)
        workspace.noteMailboxBoundary(JournalMailboxBoundary(working: false, pid: nil, at: Date(), headless: true),
                                      panelID: panel)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .open)
        XCTAssertEqual(rings(), 1, "Codex's own turn end rings the held mail once")

        // C11H-162: a dropped line reaches a record through its own shard's
        // route (C11H-78), so the record and the machine map read disconnected
        // together, as the inventory reducer reports them.
        session.feed.publish(snapshot(2, hcRecord("working", at: 1_000, foreground: "codex").with(availability: .disconnected),
                                      machine: .disconnected))
        let lost = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal == false }
        XCTAssertTrue(lost)
        session.feed.publish(snapshot(3, stuck))
        let back = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal == true }
        XCTAssertTrue(back)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .open,
                       "the same old working after a reconnect is stale")
        session.feed.publish(snapshot(4, hcRecord("idle", at: 7_000)))
        session.feed.publish(snapshot(5, hcRecord("working", at: 8_000)))
        let next = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate == .closed }
        XCTAssertTrue(next, "a working dated after the turn end is the next turn")
    }

    // MARK: - A remote Codex's next turn (sol/Grok FAIL on 27967393)

    /// While a background terminal keeps OSC 7501 on `working`, hc never
    /// dates the next turn later. A Return starts it in the journal; a
    /// second delivery of the turn end Codex already reported cannot idle
    /// it; the next turn end does. Only Codex's own times are compared: the
    /// Return is stamped on this Mac's clock, far from the remote one here.
    func testAReturnStartsARemoteCodexsNextTurnAndALateTurnEndCannotIdleIt() throws {
        let panel = UUID(), workspace = UUID(), owner = journalOwner(panel: panel)
        var s = try XCTUnwrap(fold(nil, try hcDraft("working", at: 1_000, owner: owner, workspace: workspace), 1, hc: true).snapshot)
        let early = CodexTurnAuthority.submitStart(owner: owner, workspaceID: workspace, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(fold(s, early, 2).reason, "unsupported_turn",
                       "before Codex's own signal ended a turn, a Return starts nothing")
        s = try XCTUnwrap(fold(s, turnEnd(.codexNotify, at: 5_000, owner: owner, workspace: workspace), 2).snapshot)
        XCTAssertEqual(s.phase, .idle)
        let submit = CodexTurnAuthority.submitStart(owner: owner, workspaceID: workspace,
                                                    at: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(submit.adapter, .keypress)
        XCTAssertNoThrow(try submit.validate())
        let started = fold(s, submit, 3)
        XCTAssertEqual(started.effect, .applied)
        s = try XCTUnwrap(started.snapshot)
        XCTAssertEqual(s.phase, .working, "the Return started Codex's next turn")
        XCTAssertTrue(MailboxStdinDelivery.journalTurnOpen(s), "the doorbell holds for the whole turn")
        let stale = fold(s, try hcDraft("working", at: 1_000, owner: owner, workspace: workspace), 4, hc: true)
        XCTAssertEqual(stale.snapshot?.phase, .working, "hc's old working changes nothing")
        for ms in [Int64(5_000), 4_000] {
            let late = fold(s, turnEnd(.codexNotify, at: ms, owner: owner, workspace: workspace), 5)
            XCTAssertEqual(late.effect, .stale, "a turn end at \(ms)")
            XCTAssertEqual(late.reason, "turn_end_not_after_last")
            XCTAssertEqual(late.snapshot?.phase, .working)
        }
        let ended = fold(s, turnEnd(.codexNotify, at: 5_001, owner: owner, workspace: workspace), 6)
        XCTAssertEqual(ended.snapshot?.phase, .idle, "Codex's next turn end, though this Mac's clock reads far later")
        XCTAssertEqual(CodexTurnAuthority.turnEndMs(ended.snapshot), 5_001)
        var keypressEnd = submit
        keypressEnd.kind = .turnCompleted
        XCTAssertEqual(fold(s, keypressEnd, 7).reason, "unsupported_turn", "a Return never ends a turn")

        // The composer shows the Return submitted nothing: only that turn goes back to idle.
        let retract = CodexTurnAuthority.retractReturnStart(owner: owner, workspaceID: workspace, at: Date(timeIntervalSince1970: 3_001))
        XCTAssertNoThrow(try retract.validate())
        XCTAssertTrue(CodexTurnAuthority.isReturnStartedTurn(s))
        let taken = fold(s, retract, 8)
        XCTAssertEqual(taken.reason, "return_started_nothing")
        XCTAssertEqual(taken.snapshot?.phase, .idle)
        XCTAssertEqual(CodexTurnAuthority.turnEndMs(taken.snapshot), 5_000, "Codex's last turn end stands")
        let dated = try XCTUnwrap(fold(s, try hcDraft("working", at: 6_000, owner: owner, workspace: workspace), 9, hc: true).snapshot)
        XCTAssertEqual(dated.phase, .working)
        XCTAssertFalse(CodexTurnAuthority.isReturnStartedTurn(dated))
        let refused = fold(dated, retract, 10)
        XCTAssertEqual(refused.reason, "unsupported_turn", "hc dated this turn itself: the composer cannot take it back")
        XCTAssertEqual(refused.snapshot?.phase, .working)

        // Any other agent: a Return is not a turn start, even after its own turn end.
        let claude = journalOwner("claude-code", panel: UUID())
        let stop = JournalDraft(kind: .turnCompleted, emittedAtMs: 5_000, panelID: claude.panelID, workspaceID: workspace,
                                sessionID: claude.sessionID, agentKind: "claude-code", source: .hook,
                                adapter: .claudeHook, nativeEvent: "Stop")
        var c = try XCTUnwrap(fold(nil, try hcDraft("working", at: 1_000, owner: claude, workspace: workspace), 1, hc: true).snapshot)
        c = try XCTUnwrap(fold(c, stop, 2).snapshot)
        XCTAssertEqual(c.phase, .idle)
        let claudeReturn = fold(c, CodexTurnAuthority.submitStart(owner: claude, workspaceID: workspace,
                                                                  at: Date(timeIntervalSince1970: 3_000)), 3)
        XCTAssertEqual(claudeReturn.reason, "unsupported_turn")
        XCTAssertEqual(claudeReturn.snapshot?.phase, .idle)
    }

    /// Astra Review 2: a Return that submits nothing must not leave a remote
    /// Codex working. The composer is read before the Return (an operator's
    /// key or a socket Return) and again after it; when nothing changed, the
    /// turn that Return started goes back to idle and held mail rings at
    /// once, not after the working decay. A Return that submitted text keeps
    /// its turn and holds the mail. Each append is published as the journal
    /// coordinator does: its commit time is now, its boundary comes from
    /// `JournalMailboxBoundary.make`, and the projection reaches the mailbox
    /// through the deriver's own routing, so the synthetic start reports
    /// working after the Return.
    func testAReturnThatSubmitsNothingDoesNotStartARemoteCodexsTurn() async throws {
        var journal: JournalSnapshot?
        var appended: [JournalDraft] = []
        var seq: Int64 = 10
        let (workspace, panel, rings) = try seat(remote: true, journal: { journal })
        workspace.journalAppendForTesting = { [unowned self, unowned workspace] draft in
            appended.append(draft)
            seq += 1
            let committed = Int64(Date().timeIntervalSince1970 * 1000) + 1
            let folded = self.fold(journal, draft, seq, committedAtMs: committed)
            guard folded.effect == .applied else { return }
            journal = folded.snapshot
            let result = JournalAppendResult(receipt: JournalReceipt(eventID: draft.eventID, sequence: seq,
                committedAtMs: committed, replayed: false, projectionEffect: folded.effect), changedSnapshot: folded.snapshot)
            let boundary = JournalMailboxBoundary.make(draft: draft, result: result, historical: false, pid: nil)
            workspace.noteJournalProjectionForMailbox(folded.snapshot, boundary: boundary, panelID: panel)
        }
        var composer: (region: PromptRegionSnapshot, state: PromptInputState) = (composerRegion("› "), .empty)
        workspace.mailboxComposerReadForTesting = { $0 == panel ? composer : nil }
        var checks: [MailboxNoOpReturn.Probe] = []
        workspace.mailboxNoOpReturnCheckForTesting = { if $0 == panel { checks.append($1) } }
        let hcOwner = HCRemoteStatus.owner(panelID: panel, key: remoteKey, agentKind: "codex")
        let stuck = hcRecord("working", at: 1_000)
        let session = ChipSession()
        session.feed.publish(snapshot(1, stuck))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: remoteKey), session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(stuck))
        let owned = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal == true }
        XCTAssertTrue(owned)

        // The relayed turn end; then an operator's Return on the empty composer, and mail.
        journal = idleCodex(panel: panel, turnEndMs: 5_000, owner: hcOwner)
        workspace.noteMailboxBoundary(JournalMailboxBoundary(working: false, pid: nil, at: Date(), headless: true),
                                      panelID: panel)
        let ringsBefore = rings()
        let keyAt = Date()
        workspace.noteRemoteCodexReturnKey(surfaceId: panel, at: keyAt)
        XCTAssertEqual(checks.count, 1, "the composer was read before the Return")
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working, at: keyAt)
        XCTAssertEqual(journal?.phase, .working)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG9")
        XCTAssertEqual(rings(), ringsBefore, "held behind the Return")
        workspace.finishMailboxNoOpReturn(surfaceId: panel, probe: try XCTUnwrap(checks.last))
        XCTAssertEqual(appended.last?.kind, .idleObserved)
        XCTAssertEqual(journal?.phase, .idle, "the empty Return started nothing")
        XCTAssertEqual(rings(), ringsBefore + 1, "the held mail rings now, not after the working decay")
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .open)

        // An unchanged empty socket Return: the same, through the socket's own probe.
        let socketProbe = try XCTUnwrap(workspace.mailboxNoOpReturnProbe(surfaceId: panel))
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working)
        XCTAssertEqual(journal?.phase, .working)
        workspace.finishMailboxNoOpReturn(surfaceId: panel, probe: socketProbe)
        XCTAssertEqual(journal?.phase, .idle)

        // A Return that submitted text: no probe, and the composer changing keeps the turn.
        composer = (composerRegion("› fix the flaky test"), .draft)
        workspace.noteRemoteCodexReturnKey(surfaceId: panel, at: Date())
        XCTAssertEqual(checks.count, 1, "a draft is a real submit: nothing to take back")
        composer = (composerRegion("› "), .empty)
        let emptyProbe = try XCTUnwrap(workspace.mailboxNoOpReturnProbe(surfaceId: panel))
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working)
        composer = (composerRegion("› ", cursorX: 4), .empty)
        workspace.finishMailboxNoOpReturn(surfaceId: panel, probe: emptyProbe)
        XCTAssertEqual(journal?.phase, .working, "the screen changed after the Return: the turn stands")
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        let ringsInTurn = rings()
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHGA")
        XCTAssertEqual(rings(), ringsInTurn, "mail during that turn waits")
    }

    private func composerRegion(_ text: String, cursorX: Int = 2) -> PromptRegionSnapshot {
        var cells: [PromptRegionCell] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let length = String(scalar).utf8.count
            cells.append(PromptRegionCell(textOffset: offset, textLength: length, faint: false, italic: false))
            offset += length
        }
        return PromptRegionSnapshot(
            cursorX: cursorX, cursorY: 0, cursorPendingWrap: false, complete: true,
            rows: [PromptRegionRow(screenY: 0, cellRange: 0..<cells.count, softWrap: false, wrapContinuation: false)],
            cells: cells, text: Data(text.utf8))
    }

    /// A timeless hc report of the phase already shown keeps its time.
    func testATimelessHCIdleKeepsTheIdleTime() throws {
        let panel = UUID(), workspace = UUID(), owner = journalOwner(panel: panel)
        var s = try XCTUnwrap(fold(nil, try hcDraft("working", at: 1_000, owner: owner, workspace: workspace), 1, hc: true).snapshot)
        s = try XCTUnwrap(fold(s, turnEnd(.codexNotify, at: 5_000, owner: owner, workspace: workspace), 2).snapshot)
        let since = s.sinceMs
        XCTAssertGreaterThan(since, 0)
        let idle = try XCTUnwrap(fold(s, try hcDraft("idle", at: nil, owner: owner, workspace: workspace), 3, hc: true).snapshot)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertEqual(idle.sinceMs, since)
    }

    /// The workspace side: a Return into a remote Codex after its own turn
    /// end, while hc still says `working`, appends exactly that turn start
    /// under the panel's hc owner, and the folded journal holds new mail. No
    /// turn start when hc's word is idle, the journal is not idle, or the
    /// panel is local.
    func testAReturnIntoARemoteCodexAfterItsTurnEndStartsItsNextTurn() async throws {
        var journal: JournalSnapshot?
        var appended: [JournalDraft] = []
        let (workspace, panel, rings) = try seat(remote: true, journal: { journal })
        workspace.journalAppendForTesting = { appended.append($0) }
        let hcOwner = HCRemoteStatus.owner(panelID: panel, key: remoteKey, agentKind: "codex")
        let stuck = hcRecord("working", at: 1_000)
        let session = ChipSession()
        session.feed.publish(snapshot(1, stuck))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: remoteKey), session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(stuck))
        let owned = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal == true }
        XCTAssertTrue(owned)
        journal = idleCodex(panel: panel, turnEndMs: 5_000, owner: hcOwner)

        let submitAt = Date()
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working, at: submitAt)
        XCTAssertEqual(appended.count, 1)
        let start = try XCTUnwrap(appended.first)
        XCTAssertEqual(start.kind, .turnStarted)
        XCTAssertEqual(start.adapter, .keypress)
        XCTAssertEqual(start.owner, hcOwner)
        XCTAssertEqual(start.emittedAtMs, Int64((submitAt.timeIntervalSince1970 * 1000).rounded()))

        journal = fold(journal, start, 10).snapshot
        XCTAssertEqual(journal?.phase, .working)
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working)
        XCTAssertEqual(appended.count, 1, "a turn already running gets no second start")
        mail(workspace, panel, "01M6DVS5WJGKSG34YSX181PHG8")
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate, .closed)
        XCTAssertEqual(rings(), 0, "mail during the next turn waits for its turn end")

        journal = idleCodex(panel: panel, turnEndMs: 6_000, owner: hcOwner)
        session.feed.publish(snapshot(2, hcRecord("idle", at: 7_000)))
        let idleWord = await settle { workspace.mailboxDoorbellGateState(surfaceId: panel)?.promptGate == .open }
        XCTAssertTrue(idleWord)
        workspace.noteMailboxAgentLifecycle(surfaceId: panel, source: .submit, activity: .working)
        XCTAssertEqual(appended.count, 1, "with hc at idle, Codex's next working dates the turn itself")

        let (local, localPanel, _) = try seat(remote: false, journal: { nil })
        var localAppended = 0
        local.journalAppendForTesting = { _ in localAppended += 1 }
        let localJournal = idleCodex(panel: localPanel, turnEndMs: 5_000, owner: hcOwner)
        local.mailboxJournalSnapshotForTesting = { _ in localJournal }
        local.noteMailboxAgentLifecycle(surfaceId: localPanel, source: .submit, activity: .working)
        XCTAssertEqual(localAppended, 0, "a local Codex has its transcript's turn start")
    }

    // MARK: - The relay's codex shim reaches the journal

    /// The exact event `bin/codex` sends (scripts/c11-atlas-relay.sh) is a
    /// valid Codex turn end; the relay names the panel's hc owner for it,
    /// and for nothing else.
    func testTheRelayedTurnEndIsAttributedToThePanelsHCOwnerOnly() throws {
        let panel = UUID(), workspace = UUID(), hcOwner = journalOwner(panel: panel)
        let shim = #"{"schema_version":1,"event_id":"\#(UUID().uuidString)","kind":"agent.turn.completed","emitted_at_ms":5000,"panel_id":"\#(panel.uuidString)","workspace_id":"\#(workspace.uuidString)","agent_kind":"codex","source":"hook","adapter":"codex_notify","native_event":"agent-turn-complete"}"#
        let draft = try JournalDraft.decode(Data(shim.utf8))
        XCTAssertEqual(draft.kind, .turnCompleted)
        XCTAssertEqual(draft.adapter, .codexNotify)
        XCTAssertNil(draft.owner, "the remote shim cannot know c11's owner")
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: try draft.canonicalData()) as? [String: Any])
        func admitted(_ event: [String: Any]) throws -> C11RelayPolicy.Admitted {
            let request: [String: Any] = ["id": "r1", "method": "agent.event.append", "params": ["event": event]]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            return .v2(method: "agent.event.append", id: "r1", params: ["event": event], line: line)
        }
        func session(_ result: C11RelayPolicy.Admitted) -> String? {
            guard case .v2(_, _, let params, let line) = result,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let lineEvent = (object["params"] as? [String: Any])?["event"] as? [String: Any] else { return "malformed" }
            let fromParams = (params["event"] as? [String: Any])?["session_id"] as? String
            XCTAssertEqual(fromParams, lineEvent["session_id"] as? String, "the line the processor runs agrees")
            return fromParams
        }
        let attributed = C11RelayPolicy.attributingJournalEvent(try admitted(event), hcOwner: hcOwner)
        XCTAssertEqual(session(attributed), hcOwner.sessionID)
        guard case .v2(_, _, let params, _) = attributed,
              let rewritten = params["event"] as? [String: Any] else { return XCTFail("not v2") }
        let folded = try JournalDraft.decode(JSONSerialization.data(withJSONObject: rewritten))
        XCTAssertEqual(folded.owner, hcOwner)

        XCTAssertNil(session(C11RelayPolicy.attributingJournalEvent(try admitted(event), hcOwner: nil)))
        XCTAssertNil(session(C11RelayPolicy.attributingJournalEvent(try admitted(event),
            hcOwner: journalOwner("claude-code", panel: panel))), "another agent kind")
        XCTAssertNil(session(C11RelayPolicy.attributingJournalEvent(try admitted(event),
            hcOwner: journalOwner(panel: UUID()))), "another panel")
        XCTAssertNil(session(C11RelayPolicy.attributingJournalEvent(try admitted(event),
            hcOwner: JournalOwner(panelID: panel, agentKind: "codex", sessionID: "codex-thread"))),
            "a local owner is never handed to the relay")
        var named = event; named["session_id"] = "their-own"
        XCTAssertEqual(session(C11RelayPolicy.attributingJournalEvent(try admitted(named), hcOwner: hcOwner)), "their-own",
                       "an event that names its session keeps it; the journal's owner check decides")
    }
}

@MainActor
final class HCRemoteSplitTests: XCTestCase {
    func testPanelBarSplitOfAnAtlasPanelRunsOnAtlasInItsFolder() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let studio = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true,
            machine: .restored(HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))))
        XCTAssertEqual(studio.hcRemoteTarget, HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))
        let before = Set(workspace.panels.keys)
        XCTAssertNotNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal))
        let created = workspace.panels.keys.filter { !before.contains($0) }
        XCTAssertEqual(created.count, 1)
        let split = try XCTUnwrap(created.first.flatMap { workspace.terminalPanel(for: $0) })
        XCTAssertEqual(split.hcRemoteTarget, HCRemoteTarget(machine: "studio", cwd: "/tmp/x"),
                       "A panel-bar split of a Studio terminal runs on Studio, in its folder")
        XCTAssertNil(split.requestedWorkingDirectory, "Its folder is a path on Studio, never resolved here")
    }

    func testPanelBarSplitOfALocalPanelStaysLocal() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let before = Set(workspace.panels.keys)
        XCTAssertNotNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal))
        let created = workspace.panels.keys.filter { !before.contains($0) }
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created.first.flatMap { workspace.terminalPanel(for: $0) }?.hcRemoteTarget)
    }

    // MARK: C11H-391 (Astra 2 on #382): the panel bar's split and the refill

    /// A terminal on `far` alone in its own area, beside this Mac's.
    private func farArea(_ workspace: Workspace) throws -> (pane: PaneID, far: TerminalPanel) {
        let local = try XCTUnwrap(workspace.focusedPanelId)
        let far = try XCTUnwrap(workspace.newTerminalSplit(from: local, orientation: .horizontal, focus: true,
                                                           machine: .restored(HCRemoteTarget(machine: "far"))))
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: far.id))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: pane).count, 1)
        return (pane, far)
    }

    /// The routed view while adopted: c11h links `far` unusably; with
    /// `linksUsably`, c11's links session links it too, and usable wins.
    private func routed(linksUsably: Bool) -> HCMachineDirectory {
        let directory = HCMachineDirectory()
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        var sessions = [HCSessionMachines(shard: .legacy, session: "c11h", machines: ["far": .connected])]
        if linksUsably { sessions.append(HCSessionMachines(shard: .links, session: "c11", machines: ["far": .connected])) }
        directory.apply(HCInventorySnapshot(readiness: .ready(revision), revision: revision, machines: ["far": .connected],
                                            sessionMachines: sessions))
        directory.setUnusable(["far"], session: "c11h")
        return directory
    }

    private func counts(_ workspace: Workspace) -> (panels: Set<UUID>, areas: Int) {
        (Set(workspace.panels.keys), workspace.bonsplitController.allPaneIds.count)
    }

    /// The panel bar's split of a terminal whose machine's only link is
    /// unusable is refused before bonsplit makes the area: no area, no panel,
    /// and the reason. With c11's own usable link of the name it opens there.
    func testPanelBarSplitOfATerminalWhoseOnlyLinkIsUnusableMakesNoAreaAndNoPanel() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let workspace = Workspace()
        let (pane, _) = try farArea(workspace)
        let before = counts(workspace)
        XCTAssertNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal), "bonsplit makes no area")
        XCTAssertEqual(counts(workspace).panels, before.panels, "no blank panel")
        XCTAssertEqual(counts(workspace).areas, before.areas)
        XCTAssertEqual(workspace.lastHCRemoteRefusal, .linkUnusable("far"))

        let usable = routed(linksUsably: true)
        MachinePicker.unusableOverride = { usable.unusable }
        XCTAssertNotNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal))
        let created = workspace.panels.keys.filter { !before.panels.contains($0) }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first.flatMap { workspace.terminalPanel(for: $0) }?.hcRemoteTarget?.machine, "far",
                       "opens on far, through the links session's usable link (HCShardPool.creationTarget)")
        XCTAssertNil(workspace.lastHCRemoteRefusal)
    }

    /// Moving an area's only panel, on a machine whose only link is unusable,
    /// to its own edge would leave its emptied side for c11 to refill on that
    /// machine: refused up front, by bonsplit's own drag and by c11's move,
    /// and nothing moves. With a usable link of the name the refill opens there.
    func testMovingTheOnlyPanelToItsOwnEdgeIsRefusedWhenItsRefillCantOpen() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let workspace = Workspace()
        let (pane, far) = try farArea(workspace)
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(far.id))
        let before = counts(workspace)
        XCTAssertNil(workspace.bonsplitController.splitPane(pane, orientation: .vertical, movingTab: tab, insertFirst: false),
                     "bonsplit's own drag")
        XCTAssertNil(workspace.movePanelToSplitPreservingFocus(far.id, orientation: .vertical, insertFirst: false), "c11's move")
        XCTAssertEqual(counts(workspace).panels, before.panels)
        XCTAssertEqual(counts(workspace).areas, before.areas)
        XCTAssertEqual(workspace.paneId(forPanelId: far.id), pane, "the panel stays where it was")
        XCTAssertEqual(workspace.lastHCRemoteRefusal, .linkUnusable("far"))

        let usable = routed(linksUsably: true)
        MachinePicker.unusableOverride = { usable.unusable }
        XCTAssertNotNil(workspace.movePanelToSplitPreservingFocus(far.id, orientation: .vertical, insertFirst: false))
        let refill = workspace.panels.keys.filter { !before.panels.contains($0) }
        XCTAssertEqual(refill.count, 1, "the emptied side is refilled")
        XCTAssertEqual(refill.first.flatMap { workspace.terminalPanel(for: $0) }?.hcRemoteTarget?.machine, "far")
    }

    /// A move c11 makes beside such a terminal creates nothing, so it is
    /// never refused: the moved panel lands in its new area.
    func testC11sMoveOfAnotherPanelBesideSuchATerminalIsNotRefused() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let workspace = Workspace()
        let (pane, _) = try farArea(workspace)
        let localPane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first { $0 != pane })
        let local = try XCTUnwrap(workspace.newTerminalSurface(inPane: localPane, focus: false))
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(local.id))
        let panels = counts(workspace).panels
        let moved = workspace.movingTabIntoSplit(pane, orientation: .vertical, tab: tab, insertFirst: false)
        XCTAssertNotNil(moved, "a move beside far's terminal creates nothing there")
        XCTAssertEqual(counts(workspace).panels, panels, "nothing was created")
        XCTAssertEqual(moved.flatMap { workspace.bonsplitController.tabs(inPane: $0).first?.id }, tab)
        XCTAssertNil(workspace.lastHCRemoteRefusal)
    }

    // MARK: C11H-396: bonsplit's own drag beside such a terminal, and the reason on screen

    /// Bonsplit's drag of a panel from another area to the edge of an area
    /// whose selected terminal's only link is unusable creates nothing, so it
    /// moves the panel (`BonsplitController.splitMovingTab`), as the drop
    /// handler (`PaneContainerView`) drives it.
    func testBonsplitsDragOfAnotherAreasPanelBesideSuchATerminalMovesIt() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let workspace = Workspace()
        var shown: [HCMachineTargetError] = []
        workspace.hcRefusalPresenterOverride = { refusal, _ in shown.append(refusal) }
        let (pane, far) = try farArea(workspace)
        workspace.bonsplitController.selectTab(try XCTUnwrap(workspace.bonsplitTabIdFromTabId(far.id)))
        let localPane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first { $0 != pane })
        let local = try XCTUnwrap(workspace.newTerminalSurface(inPane: localPane, focus: false))
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(local.id))
        let before = counts(workspace)
        let moved = workspace.bonsplitController.splitPane(pane, orientation: .vertical, movingTab: tab, insertFirst: false)
        XCTAssertNotNil(moved, "the drag moves the panel beside far's terminal")
        XCTAssertEqual(counts(workspace).panels, before.panels, "and creates nothing")
        XCTAssertEqual(moved.flatMap { workspace.bonsplitController.tabs(inPane: $0).map(\.id) }, [tab])
        XCTAssertNil(workspace.lastHCRemoteRefusal)
        XCTAssertEqual(shown, [], "nothing to explain")
        // Opus NB1 on #390: the move ends when the delegate has answered, so
        // the area's next panel-bar split is a new terminal on far again.
        XCTAssertNil(workspace.bonsplitController.splitMovingTab)
        XCTAssertNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal),
                     "the panel bar's split of far's area after the drag is refused")
        XCTAssertEqual(counts(workspace).panels, before.panels, "no blank panel")
        XCTAssertEqual(shown, [.linkUnusable("far")])
    }

    /// The same drag of another panel of that area to its own edge leaves
    /// far's terminal where it was and creates nothing: it moves too.
    func testBonsplitsDragOfAnotherTabOfSuchAnAreaToItsEdgeMovesIt() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let workspace = Workspace()
        let (pane, far) = try farArea(workspace)
        let local = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        workspace.bonsplitController.selectTab(try XCTUnwrap(workspace.bonsplitTabIdFromTabId(far.id)))
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(local.id))
        let before = counts(workspace)
        let moved = workspace.bonsplitController.splitPane(pane, orientation: .horizontal, movingTab: tab, insertFirst: true)
        XCTAssertNotNil(moved)
        XCTAssertEqual(counts(workspace).panels, before.panels)
        XCTAssertEqual(counts(workspace).areas, before.areas + 1)
        XCTAssertEqual(workspace.paneId(forPanelId: far.id), pane, "far's terminal stays in its area")
        XCTAssertNil(workspace.lastHCRemoteRefusal)
    }

    /// A workspace in a manager, with far's terminal in its own area, and
    /// every refusal the operator would be shown.
    private func operatorsFarArea() throws -> (WorkspaceManager, Workspace, PaneID, TerminalPanel,
                                                () -> [(HCMachineTargetError, UUID?)]) {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        final class Shown { var all: [(HCMachineTargetError, UUID?)] = [] }
        let shown = Shown()
        workspace.hcRefusalPresenterOverride = { shown.all.append(($0, $1)) }
        let (pane, far) = try farArea(workspace)
        return (manager, workspace, pane, far, { shown.all })
    }

    /// The operator sees why bonsplit's split was refused: the panel bar's
    /// split and a drag that would refill on far say it over far's terminal.
    func testAPanelBarSplitOrDragRefusedForFarsLinkSaysWhyOverFarsTerminal() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let (_, workspace, pane, far, shown) = try operatorsFarArea()
        let farTab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(far.id))
        XCTAssertNil(workspace.bonsplitController.splitPane(pane, orientation: .horizontal), "the panel bar's split")
        XCTAssertNil(workspace.bonsplitController.splitPane(pane, orientation: .vertical, movingTab: farTab, insertFirst: false),
                     "a drag of the area's only panel to its own edge")
        XCTAssertNil(workspace.bonsplitController.splitMovingTab, "a refused move is over too")
        XCTAssertEqual(shown().map { $0.0 }, [.linkUnusable("far"), .linkUnusable("far")])
        XCTAssertEqual(shown().map { $0.1 }, [far.id, far.id], "over far's terminal")
    }

    /// Cmd+D (`WorkspaceManager.createSplit`, which the menus and terminal
    /// keybinds take too) refused for far's link says why over far's terminal.
    func testCmdDRefusedForFarsLinkSaysWhyOverFarsTerminal() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let (manager, workspace, _, far, shown) = try operatorsFarArea()
        let before = counts(workspace)
        XCTAssertNil(manager.createSplit(workspaceId: workspace.id, surfaceId: far.id, direction: .right))
        XCTAssertEqual(counts(workspace).panels, before.panels)
        XCTAssertEqual(shown().map { $0.0 }, [.linkUnusable("far")])
        XCTAssertEqual(shown().map { $0.1 }, [far.id])
    }

    /// A socket move refused for the same reason (`panel.drag_to_split`) is
    /// the agent's error to read: nothing shows, and no beep, on the
    /// operator's Mac. The same move by the operator says why.
    func testASocketMoveRefusedForFarsLinkShowsNothingOnTheMac() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        let (_, workspace, _, far, shown) = try operatorsFarArea()
        let socket = SocketCommandContext(method: "panel.drag_to_split", allowsFocus: false)
        let refused = SocketCommandContext.withContext(socket) {
            workspace.movePanelToSplitPreservingFocus(far.id, orientation: .vertical, insertFirst: false)
        }
        XCTAssertNil(refused)
        XCTAssertEqual(workspace.lastHCRemoteRefusal, .linkUnusable("far"), "the agent still reads the reason")
        XCTAssertTrue(shown().isEmpty, "nothing on the operator's Mac for an agent's move")
        XCTAssertNil(workspace.movePanelToSplitPreservingFocus(far.id, orientation: .vertical, insertFirst: false))
        XCTAssertEqual(shown().map { $0.0 }, [.linkUnusable("far")], "the operator's own move says why")
    }

    /// Opus on #382 (Blocking 1): `panel.split` (`c11 new-split`) of a terminal
    /// whose machine's only link is unusable answers `machine_link_unusable`,
    /// with the action to take, and makes no panel.
    func testPanelSplitOverTheSocketAnswersMachineLinkUnusable() throws {
        defer { MachinePicker.unusableOverride = nil; HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let unusable = routed(linksUsably: false)
        MachinePicker.unusableOverride = { unusable.unusable }
        _ = NSApplication.shared
        let previousDelegate = AppDelegate.shared
        let app = AppDelegate()
        app.resignSnapshotWriterOverrideForTesting = {}
        defer { AppDelegate.shared = previousDelegate }
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let windowId = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("c11.main.\(windowId.uuidString)")
        defer { app.debugUnregisterMainWindow(window); window.close() }
        app.registerMainWindow(window, windowId: windowId, workspaceManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
        let (_, far) = try farArea(workspace)
        let before = Set(workspace.panels.keys)
        let reply = TerminalController.makeForTesting().v2DispatchSurface("panel.split", id: 1, params: [
            "workspace_id": workspace.id.uuidString, "surface_id": far.id.uuidString, "direction": "right", "force": true])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], reply)
        XCTAssertEqual(object["ok"] as? Bool, false, reply)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "machine_link_unusable", reply)
        XCTAssertEqual(Set(workspace.panels.keys), before, "no panel")
    }

    /// `hcSplitTarget` is what the demoted `panel.split` arm and the drag
    /// placeholder use: the source terminal's machine, or this Mac.
    func testSplitTargetFollowsTheSourceTerminal() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let local = try XCTUnwrap(workspace.focusedPanelId)
        let studio = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false,
            machine: .restored(HCRemoteTarget(machine: "studio", cwd: "/srv/a"))))
        XCTAssertEqual(workspace.hcSplitTarget(from: studio.id), HCRemoteTarget(machine: "studio", cwd: "/srv/a"))
        XCTAssertEqual(workspace.hcSplitTarget(from: studio.id, explicitCwd: "/srv/b"), HCRemoteTarget(machine: "studio", cwd: "/srv/b"))
        XCTAssertNil(workspace.hcSplitTarget(from: local))
        XCTAssertNil(workspace.hcSplitTarget(from: nil))
    }
}

// C11H-98: a terminal hc kept live with an agent in its foreground is never a
// resume candidate. The panel here is a terminal on another machine, so the
// agent comes from that machine's report (C11H-87), never local state.
@MainActor
final class HCLiveAgentResumeTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7")
    private let codex = HCForeground(pid: 81, name: "codex", argv: ["codex"], cwd: "/Users/demo")
    private let zsh = HCForeground(pid: 77, name: "zsh", argv: ["-zsh"], cwd: "/Users/demo")
    private let codexID = "0ba1b200-1111-4111-8111-111111111111"
    private var eventsDir: URL!

    override func setUpWithError() throws {
        eventsDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-98-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        EventEmitter.shared.startForTesting(log: EventLog(url: eventsURL, instance: "c11-98"), instance: "c11-98")
    }

    override func tearDownWithError() throws {
        EventEmitter.shared.resetForTesting()
        if let eventsDir { try? FileManager.default.removeItem(at: eventsDir) }
    }

    private var eventsURL: URL { eventsDir.appendingPathComponent("events.ndjson") }

    private func events(_ type: String) -> [[String: Any]] {
        EventEmitter.shared.flush()
        let text = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["type"] as? String == type }
    }

    private func record(_ foreground: HCForeground?, state: HCTerminalState = .running) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, machineName: "studio", machineAvailability: .connected,
                         pid: 4242, foreground: foreground, status: "idle")
    }

    /// A workspace whose one terminal runs on Studio with `foreground` in front,
    /// once hc's report has reached the workspace.
    private func livePanel(running foreground: HCForeground) async throws -> (Workspace, UUID) {
        let (workspace, panel, _) = try await livePanelAndSession(running: foreground)
        return (workspace, panel)
    }

    private func livePanelAndSession(running foreground: HCForeground) async throws -> (Workspace, UUID, ChipSession) {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let session = ChipSession()
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                                                 records: [key: record(foreground)], machines: ["studio": .connected]))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key), session: session)
        workspace.followHCRemoteStatus(panelID: panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(record(foreground)))
        for _ in 0..<200 where workspace.hcRemoteForeground[panel]?.name != foreground.name
            || workspace.hcRemoteAgentOwnsTerminal[panel] == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(workspace.hcRemoteForeground[panel]?.name, foreground.name, "hc's report never arrived")
        return (workspace, panel, session)
    }

    private func snapshot(_ panel: UUID) -> SessionWorkspaceSnapshot {
        let terminal = SessionPanelSnapshot(
            id: panel, type: .terminal, title: "t7", customTitle: nil, directory: nil, isPinned: false,
            isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
            browser: nil, markdown: nil, metadata: nil, metadataSources: nil)
        return SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Test", customTitle: nil, stableDefaultTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: nil,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [panel], selectedPanelId: panel)),
            panels: [terminal], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil, metadata: nil)
    }

    private func conversations(_ panel: UUID) -> [String: PanelConversations] {
        [panel.uuidString: PanelConversations(active: ConversationRef(
            kind: "codex", id: codexID, capturedVia: .runtimeEnv, state: .suspended), history: [])]
    }

    func testHCLiveAgentIsTheAgentInFrontOfARunningTerminal() {
        XCTAssertEqual(HCLiveAgent.kind(record(codex)), "codex")
        XCTAssertNil(HCLiveAgent.kind(record(zsh)), "a plain shell is not a live agent")
        XCTAssertNil(HCLiveAgent.kind(record(codex, state: .finished)), "a finished terminal has no live agent")
        XCTAssertNil(HCLiveAgent.kind(record(nil)))
        XCTAssertNil(HCLiveAgent.kind(nil))
    }

    /// The laptop's case: the Codex tester never stopped. Nothing is planned,
    /// the panel is kept, and the refusal is logged as its own event.
    func testALiveCodexIsKeptAndNeverPlanned() async throws {
        let (workspace, panel) = try await livePanel(running: codex)
        XCTAssertEqual(workspace.launchResumeCandidacy(panel), .liveAgent("codex"))
        let plan = workspace.restartPlan(from: snapshot(panel), registry: .v1, mode: .clean,
                                         conversations: conversations(panel))
        XCTAssertTrue(plan.commands.isEmpty, "a resume was planned for a live agent: \(plan.commands)")
        XCTAssertEqual(workspace.launchResumeOutcomes[panel], .kept(agentKind: "codex"))
        XCTAssertTrue(events("conversation.resume.decision").isEmpty, "no decision is made for a live agent")
        let refused = events("conversation.resume.refused")
        XCTAssertEqual(refused.count, 1)
        XCTAssertEqual(refused.first?["panel"] as? String, panel.uuidString)
        let payload = refused.first?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["reason_code"] as? String, "live-agent")
        XCTAssertEqual(payload?["agent_kind"] as? String, "codex")
        XCTAssertEqual(payload?["kind"] as? String, "codex")
        XCTAssertEqual(payload?["conversation_id"] as? String, codexID)
        XCTAssertEqual(payload?["stage"] as? String, "plan")
        XCTAssertEqual(workspace.resumeSubmissionRefusal(panel),
                       "codex is still running in this terminal, so it was not resumed.",
                       "a manual resume is refused the same way")
    }

    /// A persistent hc terminal hc kept live with only its shell in front (the
    /// agent exited before the quit): never decided from the snapshot. A
    /// survivor's shell is not a fresh shell; only an ended terminal resumes,
    /// through its own recovery.
    func testALiveShellSurvivorIsLeftToItsHCRecovery() async throws {
        let (workspace, panel) = try await livePanel(running: zsh)
        XCTAssertNil(workspace.hcLiveAgentKind(panelId: panel))
        XCTAssertEqual(workspace.launchResumeCandidacy(panel), .hcRecovery)
        let plan = workspace.restartPlan(from: snapshot(panel), registry: .v1, mode: .clean,
                                         conversations: conversations(panel))
        XCTAssertTrue(plan.commands.isEmpty)
        XCTAssertNil(workspace.launchResumeOutcomes[panel], "not kept and not skipped")
        XCTAssertTrue(events("conversation.resume.refused").isEmpty)
    }

    /// A restored terminal with no hc terminal behind it (no live agent, not
    /// persistent) still resumes its conversation, once.
    func testAnOrdinaryRestoredTerminalStillResumesOnce() async throws {
        let workspace = Workspace()
        let panel = UUID()
        XCTAssertEqual(workspace.launchResumeCandidacy(panel), .candidate)
        let plan = workspace.restartPlan(from: snapshot(panel), registry: .v1, mode: .clean,
                                         conversations: conversations(panel))
        XCTAssertEqual(plan.commands.count, 1)
        guard case .typeCommand(let text, _) = plan.commands.first?.action else {
            return XCTFail("an ended agent's conversation must resume")
        }
        XCTAssertEqual(text, "codex resume --yolo '\(codexID)'")
        XCTAssertNotEqual(workspace.launchResumeOutcomes[panel], .kept(agentKind: "codex"))
        XCTAssertTrue(events("conversation.resume.refused").isEmpty)
    }

    /// A persistent hc terminal is decided by its own recovery once hc says it
    /// ended, never from the snapshot before its lifecycle is known.
    func testAPersistentTerminalIsLeftToItsOwnRecovery() async throws {
        let workspace = Workspace()
        let panel = UUID()
        let plan = workspace.restartPlan(from: snapshot(panel), registry: .v1, mode: .clean,
                                         conversations: conversations(panel), candidacy: { _ in .hcRecovery })
        XCTAssertTrue(plan.commands.isEmpty)
        XCTAssertNil(workspace.launchResumeOutcomes[panel], "not kept, not skipped: nothing to report yet")
        XCTAssertTrue(events("conversation.resume.decision").isEmpty)
        XCTAssertTrue(events("conversation.resume.refused").isEmpty)
    }

    /// A panel whose decision waited on a startup scrape: an agent hc reports
    /// by the time the scrape lands is kept, and nothing is dispatched.
    func testAnAgentRunningWhenItsScrapeLandsIsKept() async throws {
        let (workspace, panel, session) = try await livePanelAndSession(running: zsh)
        // The snapshot pass held it for its scrape (a candidate then: no agent in front).
        let plan = workspace.restartPlan(from: snapshot(panel), registry: .v1, mode: .clean,
                                         conversations: conversations(panel), awaitingScrape: [panel.uuidString],
                                         candidacy: { _ in .candidate })
        XCTAssertEqual(plan.awaitingScrape, [panel])
        XCTAssertEqual(workspace.launchResumeOutcomes[panel], .awaitingScrape)
        let revision = HCRevision(connectionGeneration: 1, sequence: 2)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                                                 records: [key: record(codex)], machines: ["studio": .connected]))
        for _ in 0..<200 where workspace.hcLiveAgentKind(panelId: panel) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(workspace.hcLiveAgentKind(panelId: panel), "codex", "hc's codex report never arrived")
        workspace.resumeAfterStartupScrape(panelIds: [panel], snapshot: snapshot(panel), registry: .v1, mode: .clean,
                                           conversations: conversations(panel), scrape: .applied,
                                           firstAt: .now() + 3600)
        XCTAssertEqual(workspace.launchResumeOutcomes[panel], .kept(agentKind: "codex"))
        XCTAssertTrue(events("conversation.resume.decision").isEmpty)
        let stages = events("conversation.resume.refused").compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }
        XCTAssertEqual(stages, ["scrape"])
    }

    private func cliTarget(_ workspace: Workspace, _ panel: UUID, ref: ConversationRef?, dryRun: Bool,
                           scheduled: inout [Workspace.RestartCommand]) -> [String: Any] {
        var plans: [Workspace.RestartCommand] = []
        let row = workspace.conversationResumeTarget(
            panelId: panel, conversation: ref, registry: .v1, mode: .clean, transcriptEvidence: nil, dryRun: dryRun,
            conversationsBySurface: ref.map { [panel.uuidString: PanelConversations(active: $0, history: [])] } ?? [:],
            liveWriters: { _ in [] }, schedule: { plans.append($0) })
        scheduled += plans
        return row
    }

    /// `c11 conversation resume` keeps a live agent before any decision,
    /// whatever its stored ref says: a valid ref and a missing one each give
    /// `kept`, schedule nothing, record the keep and one `cli` refusal.
    func testTheCLIKeepsALiveAgentBeforeAnyDecision() async throws {
        let valid = conversations(UUID()).values.first?.active
        let cases: [(String, ConversationRef?)] = [("valid ref", valid), ("missing ref", nil)]
        for (label, ref) in cases {
            let (workspace, panel) = try await livePanel(running: codex)
            var scheduled: [Workspace.RestartCommand] = []
            let row = cliTarget(workspace, panel, ref: ref, dryRun: false, scheduled: &scheduled)
            XCTAssertEqual(row["outcome"] as? String, "kept", label)
            XCTAssertEqual(row["agent_kind"] as? String, "codex", label)
            XCTAssertNil(row["command"], "\(label): no command is offered for a live agent")
            XCTAssertTrue(scheduled.isEmpty, "\(label): nothing may be typed")
            XCTAssertEqual(workspace.launchResumeOutcomes[panel], .kept(agentKind: "codex"), label)
            // A second attempt is deduplicated.
            _ = cliTarget(workspace, panel, ref: ref, dryRun: false, scheduled: &scheduled)
            let mine = events("conversation.resume.refused").filter { $0["panel"] as? String == panel.uuidString }
            XCTAssertEqual(mine.compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }, ["cli"], label)
            XCTAssertTrue(events("conversation.resume.decision").filter { $0["panel"] as? String == panel.uuidString }.isEmpty,
                          "\(label): no decision for a live agent")
        }
    }

    /// A dry run reports the keep and changes nothing; a terminal without a
    /// live agent still reaches the shared decision.
    func testTheCLIDryRunOnlyReportsAndOrdinaryTargetsStillDecide() async throws {
        let (workspace, panel) = try await livePanel(running: codex)
        var scheduled: [Workspace.RestartCommand] = []
        let row = cliTarget(workspace, panel, ref: nil, dryRun: true, scheduled: &scheduled)
        XCTAssertEqual(row["outcome"] as? String, "kept")
        XCTAssertNil(workspace.launchResumeOutcomes[panel], "a preview records nothing")
        XCTAssertTrue(events("conversation.resume.refused").isEmpty, "a preview logs nothing")

        let ordinary = UUID()
        let skipped = cliTarget(workspace, ordinary, ref: nil, dryRun: false, scheduled: &scheduled)
        XCTAssertEqual(skipped["outcome"] as? String, "skipped")
        XCTAssertEqual(skipped["skip_code"] as? String, "conversation-unavailable")
        XCTAssertTrue(scheduled.isEmpty)
    }

    /// The last check, at the moment of typing: an agent that started after
    /// the plan was made is never typed into.
    func testTheSubmissionNeverTypesIntoALiveAgent() async throws {
        let (workspace, panel) = try await livePanel(running: codex)
        let pushed = await ConversationStore.shared.push(
            surfaceId: panel.uuidString, kind: "codex", id: codexID, source: .manual, state: .suspended)
        let ref = try XCTUnwrap(pushed)
        defer { Task { await ConversationStore.shared.clear(surfaceId: panel.uuidString) } }
        await workspace.submitResume((panelId: panel, action: .typeCommand(text: "codex resume --yolo '\(codexID)'",
                                                                           submitWithReturn: true), conversation: ref),
                                     idleShellRequired: false, launchScoped: false, gate: LaunchResumeGate())
        XCTAssertEqual(workspace.launchResumeOutcomes[panel], .kept(agentKind: "codex"),
                       "the submission must keep the agent, never type or record a skip")
        let stages = events("conversation.resume.refused").compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }
        XCTAssertEqual(stages, ["submit"])
    }

    // MARK: C11H-272: the agent died, its shell lives

    /// The 2026-11-13 incident: a stray pkill ended three Codex seats on this
    /// Mac and their zsh lived on, in the same persistent terminal. hc names
    /// zsh in front and the shell is back at an empty prompt.
    private func agentEndedShell(reportPrompt: Bool = true) throws -> (Workspace, UUID, TerminalPanel) {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let terminal = try XCTUnwrap(workspace.panels[panel] as? TerminalPanel)
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key), session: ChipSession())
        runtime.publish(.live(record(zsh)))
        terminal.surface.installHCSessionForTesting(runtime)
        XCTAssertEqual(terminal.hcIdentity?.persistence, .persistent)
        XCTAssertFalse(terminal.permitsConversationResume, "a survivor is not a replacement terminal")
        // The agent ran as the shell's command, then the prompt came back.
        if reportPrompt {
            workspace.updatePanelShellActivityState(panelId: panel, state: .commandRunning)
            workspace.updatePanelShellActivityState(panelId: panel, state: .promptIdle)
        }
        return (workspace, panel, terminal)
    }

    private var codexRef: ConversationRef {
        ConversationRef(kind: "codex", id: codexID, capturedVia: .runtimeEnv, state: .suspended)
    }

    private var promptNotEmpty: String {
        "The terminal may have something typed at its prompt. Press Return on an empty prompt (or run a command), then resume."
    }

    /// Before: `c11 conversation resume --panel` refused with panel-in-use,
    /// "The ended session does not have a fresh shell ready for resume."
    func testTheCLIResumesTheLiveShellAnAgentLeft() throws {
        let (workspace, panel, _) = try agentEndedShell()
        XCTAssertEqual(workspace.hcForegroundKind(panelId: panel), "shell")
        XCTAssertNil(workspace.hcLiveAgentKind(panelId: panel))
        var scheduled: [Workspace.RestartCommand] = []
        let preview = cliTarget(workspace, panel, ref: codexRef, dryRun: true, scheduled: &scheduled)
        XCTAssertEqual(preview["outcome"] as? String, "would_resume", "\(preview)")
        XCTAssertEqual(preview["command"] as? String, "codex resume --yolo '\(codexID)'")
        let row = cliTarget(workspace, panel, ref: codexRef, dryRun: false, scheduled: &scheduled)
        XCTAssertEqual(row["outcome"] as? String, "scheduled", "\(row)")
        XCTAssertEqual(scheduled.map { $0.panelId }, [panel])
        // A launch-time resume still never types into a survivor.
        XCTAssertEqual(workspace.resumeSubmissionRefusal(panel),
                       "The ended session does not have a fresh shell ready for resume.")
    }

    /// C11H-196's rule on this route: a key since the last empty prompt may
    /// be a half-typed command. An empty Return (a new idle report) clears it;
    /// a running command or another program in front refuses.
    func testALiveShellTakesTheResumeOnlyAtAnEmptyPrompt() throws {
        let (workspace, panel, terminal) = try agentEndedShell()
        var scheduled: [Workspace.RestartCommand] = []
        terminal.surface.lastOperatorKeyAt = Date().addingTimeInterval(1)
        let typed = cliTarget(workspace, panel, ref: codexRef, dryRun: true, scheduled: &scheduled)
        XCTAssertEqual(typed["outcome"] as? String, "refused")
        XCTAssertEqual(typed["skip_code"] as? String, "panel-in-use")
        XCTAssertEqual(typed["reason"] as? String, promptNotEmpty)
        terminal.surface.lastOperatorKeyAt = Date().addingTimeInterval(-1)
        workspace.updatePanelShellActivityState(panelId: panel, state: .promptIdle)
        XCTAssertEqual(cliTarget(workspace, panel, ref: codexRef, dryRun: true, scheduled: &scheduled)["outcome"] as? String,
                       "would_resume")
        workspace.updatePanelShellActivityState(panelId: panel, state: .commandRunning)
        XCTAssertEqual(cliTarget(workspace, panel, ref: codexRef, dryRun: true, scheduled: &scheduled)["reason"] as? String,
                       promptNotEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    /// The route's decision: hc must name the shell itself, and each empty
    /// prompt takes one resume.
    func testLiveShellReadinessNeedsTheShellInFrontAndTakesOneResumePerPrompt() {
        let prompt = Date(timeIntervalSince1970: 1_000)
        func readiness(_ kind: String?, _ state: Workspace.PanelShellActivityState? = .promptIdle, key: Date? = nil,
                       empty: Date? = prompt, typed: Date? = nil) -> Workspace.LiveShellResumeReadiness {
            Workspace.liveShellResumeReadiness(foregroundKind: kind, shellState: state, lastOperatorKeyAt: key,
                                               lastEmptyPrompt: empty, resumedPrompt: typed)
        }
        XCTAssertEqual(readiness("shell"), .ready(epoch: prompt))
        XCTAssertEqual(readiness("shell", key: prompt.addingTimeInterval(-5)), .ready(epoch: prompt))
        for kind in ["codex", "unknown", nil] as [String?] {
            XCTAssertEqual(readiness(kind), .notApplicable, "\(kind ?? "nil") in front")
        }
        XCTAssertEqual(readiness("shell", .unknown), .promptNotEmpty, "no prompt report since the agent ended")
        XCTAssertEqual(readiness("shell", empty: nil), .promptNotEmpty)
        XCTAssertEqual(readiness("shell", key: prompt.addingTimeInterval(1)), .promptNotEmpty)
        XCTAssertEqual(readiness("shell", typed: prompt), .promptNotEmpty, "one per prompt: the epoch it consumed")
        XCTAssertEqual(readiness("shell", typed: prompt.addingTimeInterval(-1)), .ready(epoch: prompt),
                       "a resume typed at an earlier prompt does not hold a newer one")
    }

    /// Astra B1 on #360: an empty Return must reach the live-shell route
    /// through the socket, not only through the workspace setter. The shells
    /// report every prompt; the socket's dedupe passes a repeated prompt. A
    /// key at the prompt refuses until that empty Return; a repeated
    /// `running` changes nothing.
    func testAnEmptyReturnThroughTheSocketMakesTheLiveShellResumeEligible() async throws {
        let (workspace, panel, terminal) = try agentEndedShell(reportPrompt: false)
        TerminalController.shellReportWorkspaceForTesting = { $0 == panel ? workspace : nil }
        defer { TerminalController.shellReportWorkspaceForTesting = nil }
        let controller = TerminalController.makeForTesting()
        func report(_ state: String) async {
            // The shells' own line: `--tab` carries the panel id too (C11-171).
            let line = "report_shell_state \(state) --tab=\(panel.uuidString) --panel=\(panel.uuidString)"
                + (state == "prompt" ? " --agent-kick=1" : "")
            XCTAssertEqual(controller.processCommandUsingSocketExecutionPolicy(line), "OK")
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
        func outcome() -> [String: Any] {
            var scheduled: [Workspace.RestartCommand] = []
            return cliTarget(workspace, panel, ref: codexRef, dryRun: true, scheduled: &scheduled)
        }
        await report("running")
        await report("prompt")
        XCTAssertEqual(outcome()["outcome"] as? String, "would_resume")
        // A draft typed and erased at the prompt: the key refuses the resume.
        terminal.surface.lastOperatorKeyAt = Date()
        XCTAssertEqual(outcome()["reason"] as? String, promptNotEmpty)
        // The operator presses Return on the empty prompt: the same state again.
        await report("prompt")
        XCTAssertEqual(outcome()["outcome"] as? String, "would_resume", "\(outcome())")
        // A command starts; its repeated `running` changes nothing.
        await report("running")
        await report("running")
        XCTAssertEqual(outcome()["reason"] as? String, promptNotEmpty)
    }

    /// Opus nb2 on #360: the launch call site, not only the default argument.
    /// A launch-time resume never takes the live shell an agent left.
    func testALaunchTimeResumeNeverTakesTheLiveShell() async throws {
        let (workspace, panel, _) = try agentEndedShell()
        let pushed = await ConversationStore.shared.push(
            surfaceId: panel.uuidString, kind: "codex", id: codexID, source: .manual, state: .suspended)
        let ref = try XCTUnwrap(pushed)
        defer { Task { await ConversationStore.shared.clear(surfaceId: panel.uuidString) } }
        await workspace.submitResume((panelId: panel, action: .typeCommand(text: "codex resume --yolo '\(codexID)'",
                                                                           submitWithReturn: true), conversation: ref),
                                     idleShellRequired: true, launchScoped: true, gate: LaunchResumeGate())
        XCTAssertEqual(workspace.launchResumeOutcomes[panel], .skipped(
            code: .panelInUse, reason: "The ended session does not have a fresh shell ready for resume."))
    }
}

// Deterministic wire substitutes for the assembled C11H-124 churn regression.
private actor ChurnPeer {
    private var sibling: HCJSONValue?
    private var sequence: Int64 = 1
    private var heldRefresh: HCReconnectTestGate<Void>?
    func holdNextRefresh(_ gate: HCReconnectTestGate<Void>) { heldRefresh = gate }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue {
        switch request.method {
        case "machine.list": return machineList("connected")
        case "terminal.attach": return .object(["channel": .integer(3)])
        case "terminal.run":
            sibling = record("studio/t4", labels: request.params["labels"])
            sequence += 1
            return .object(["terminal": .string("studio/t4")])
        case "terminal.kill":
            sibling = record("studio/t4", finished: true)
            sequence += 1
            return .object([:])
        case "events.subscribe":
            if let gate = heldRefresh { heldRefresh = nil; await gate.wait() }
            return .object(["channel": .integer(7), "seq": .integer(sequence),
                            "terminals": .array([record("studio/t3")] + (sibling.map { [$0] } ?? []))])
        default: throw HCUnavailableReason.malformedResponse
        }
    }
    private func record(_ address: String, labels: HCJSONValue = .object([:]), finished: Bool = false) -> HCJSONValue {
        .object(["address": .string(address), "state": .string(finished ? "finished" : "live"), "pid": .integer(4242),
                 "foreground": .object(["pid": .integer(4243), "name": .string("claude"), "argv": .array([.string("claude")])]),
                 "status": .object(["state": .string("idle")]), "status_ms": .integer(1000), "turn": .integer(0),
                 "labels": labels, "cols": .integer(80), "rows": .integer(24)])
    }
}

private final class ChurnMailboxOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var owns = false
    func apply(_ value: HCRemoteStatusObservation.Presentation) {
        lock.lock(); owns = value.mailboxOwnsTerminal; lock.unlock()
    }
    var ownsTerminal: Bool { lock.lock(); defer { lock.unlock() }; return owns }
}

private final class ChurnRendering: HCRenderingAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var hold: (XCTestExpectation, HCReconnectTestGate<Void>)?
    func holdNext(_ entered: XCTestExpectation, gate: HCReconnectTestGate<Void>) {
        lock.lock(); hold = (entered, gate); lock.unlock()
    }
    private func takeHold() -> (XCTestExpectation, HCReconnectTestGate<Void>)? {
        lock.lock(); defer { lock.unlock() }; let next = hold; hold = nil; return next
    }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        if let (entered, gate) = takeHold() { entered.fulfill(); await gate.wait() }
        return HCScreenReceipt(revision: revision, parsedOutputWatermark: 1, columns: 80, rows: 24)
    }
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
    func noteOutput(_ chunk: HCOutputChunk) {}
    func didParse(_ chunk: HCOutputChunk) {}
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
}

private final class ChurnWire: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ bytes: Data) { lock.lock(); data += bytes; lock.unlock() }
}

private final class ChurnChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 3
    let connectionGeneration: UInt64 = 1
    private let wire: ChurnWire
    private let lock = NSLock()
    private var cancelled: Set<UUID> = []
    init(_ wire: ChurnWire) { self.wire = wire }
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        .reserved(HCWriteReservation(id: UUID(), operationID: operationID, attachmentGeneration: attachmentGeneration,
                                    connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    private func isCancelled(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(id) }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        var count = 0
        var returned = false
        for frame in batch.frames {
            switch frame {
            case .data(let bytes): wire.append(bytes); count += bytes.count
            case .submitReturn(let bytes), .submitReturnAfter(let bytes, _):
                let allowed = await batch.beforeReturn?() ?? true
                guard allowed, !isCancelled(reservation.id) else {
                    return .uncertain(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                                     bodyBytesWritten: count, returnWritten: false))
                }
                wire.append(bytes); returned = true
            default: break
            }
        }
        return .written(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                       bodyBytesWritten: count, returnWritten: returned))
    }
    func cancel(_ reservation: HCWriteReservation) { lock.lock(); cancelled.insert(reservation.id); lock.unlock() }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

// C11H-237: a Claude turn that ends in an API error (StopFailure) is a turn
// end for the doorbell. Before, the error phase read as a turn still running
// and nothing looked again, so a seat idle after an error sat on its mail.
// Each case replays the hook sequence through the real reducer and the
// journal's own boundary, as the coordinator publishes it.
@MainActor
final class StopFailureDoorbellTests: XCTestCase {
    private let remoteKey = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t52")
    private let localKey = HCTerminalKey(owningCoreID: "local-core", localAddress: "t52")
    private let instance = UUID()
    private let agentPID: pid_t = 4711
    private let device: dev_t = 0x1234
    private let born: UInt64 = 1_700_000_000_000_000

    /// One Claude seat with the journal fed through `publish`.
    private final class Seat {
        let workspace: Workspace
        let panel: UUID
        var journal: JournalSnapshot?
        var seq: Int64 = 0
        var rings = 0
        var rechecks: [String] = []
        var screen: PromptInputState = .empty
        init(workspace: Workspace, panel: UUID) { self.workspace = workspace; self.panel = panel }
    }

    private func seat(remote: Bool) throws -> Seat {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let seat = Seat(workspace: workspace, panel: panel)
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panel,
            partial: ["mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "claude", argv: ["claude"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        if !remote {
            let pid = agentPID, device = device, born = born
            workspace.mailboxKernel = MailboxAgentForeground.Kernel(
                processInfo: { $0 == pid ? .init(processGroup: pid, terminalForegroundGroup: pid, terminalDevice: device,
                                                 isZombie: false, startTime: born) : nil },
                ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
                isCanonical: { _ in false })
            // C11H-238: the ownership probe runs off main in the app; inline here.
            workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        }
        // C11H-346: weak, never unowned. A look the workspace runs after the test has let go of its seat must not
        // abort the runner.
        workspace.mailboxDoorbellScreenForTesting = { [weak seat] _ in seat?.screen ?? .empty }
        workspace.mailboxJournalSnapshotForTesting = { [weak seat] in $0 == panel ? seat?.journal : nil }
        workspace.onMailboxDoorbellRingForTesting = { [weak seat] in if $0 == panel { seat?.rings += 1 } }
        workspace.onMailboxRecheckForTesting = { [weak seat] in if $0 == panel { seat?.rechecks.append($1) } }
        return seat
    }

    /// A local seat whose agent hc reports working in front of ttys042: the
    /// doorbell learns the agent under the kernel's checks.
    private func localSeat() throws -> Seat {
        let seat = try seat(remote: false)
        let record = HCTerminalRecord(key: localKey, state: .running, machineAvailability: .local, pid: 4242,
                                      foreground: HCForeground(pid: agentPID, name: "claude", argv: ["claude"]),
                                      status: "working", statusTimestampMilliseconds: nil, turn: 1, tty: "/dev/ttys042")
        seat.workspace.noteHCLocalMailbox(panelId: seat.panel, record: record)
        XCTAssertEqual(seat.workspace.mailboxDoorbellGateState(surfaceId: seat.panel)?.ownsTerminal, true)
        return seat
    }

    /// One Claude hook as the CLI journals it: the mapping, the reducer, and
    /// the boundary the coordinator publishes with the hook's PID (none
    /// through the relay), then the projection's own route to the mailbox.
    private func hook(_ seat: Seat, _ subcommand: String, prompt: String? = nil, remote: Bool = false,
                      emittedAt: Date = Date()) throws {
        var object: [String: Any] = remote ? [:] : ["session_id": "claude-session"]
        if let prompt { object["prompt_id"] = prompt }
        var draft = try XCTUnwrap(ClaudeHookMapping.map(subcommand: subcommand, object: object))
        draft.emittedAtMs = Int64(emittedAt.timeIntervalSince1970 * 1000)
        draft.panelID = seat.panel
        draft.workspaceID = seat.workspace.id
        if remote {
            let owner = HCRemoteStatus.owner(panelID: seat.panel, key: remoteKey, agentKind: "claude-code")
            draft.sessionID = owner.sessionID
        }
        seat.seq += 1
        let committed = Int64(Date().timeIntervalSince1970 * 1000) + 1
        let folded = JournalReducer.fold(previous: seat.journal, draft: draft, sequence: seat.seq, committedAtMs: committed,
                                         tick: UInt64(seat.seq), instanceID: instance,
                                         context: JournalContext(eligible: true))
        guard folded.effect == .applied else { return }
        seat.journal = folded.snapshot
        let result = JournalAppendResult(receipt: JournalReceipt(eventID: draft.eventID, sequence: seat.seq,
            committedAtMs: committed, replayed: false, projectionEffect: folded.effect), changedSnapshot: folded.snapshot)
        let boundary = JournalMailboxBoundary.make(draft: draft, result: result, historical: false,
                                                   pid: remote ? nil : agentPID)
        seat.workspace.noteJournalProjectionForMailbox(folded.snapshot, boundary: boundary, panelID: seat.panel)
    }

    private func mail(_ seat: Seat, _ id: String) {
        _ = seat.workspace.deliverOrBufferMailboxStdin(surfaceId: seat.panel, envelopeId: id,
                                                       recipientName: "wave-coordinator", block: "<c11-msg/>")
    }

    private func gate(_ seat: Seat) -> MailboxStdinBuffer.PromptGate? {
        seat.workspace.mailboxDoorbellGateState(surfaceId: seat.panel)?.promptGate
    }

    // MARK: - Local

    /// prompt-submit, prompt-submit, stop-failure: one ring at the
    /// StopFailure; the next prompt-submit closes the gate again.
    func testALocalClaudeTurnThatEndsInStopFailureRingsOnceAtTheFailure() throws {
        let seat = try localSeat()
        try hook(seat, "prompt-submit", prompt: "p1")
        XCTAssertEqual(seat.journal?.phase, .working)
        mail(seat, "01M6W0A0000000000000000001")
        try hook(seat, "prompt-submit", prompt: "p2")
        mail(seat, "01M6W0A0000000000000000002")
        XCTAssertEqual(seat.rings, 0, "mid-turn: held")
        XCTAssertEqual(gate(seat), .closed)

        try hook(seat, "stop-failure", prompt: "p2")
        XCTAssertEqual(seat.journal?.phase, .error)
        XCTAssertEqual(gate(seat), .open, "an error-ended turn is back at its prompt")
        XCTAssertEqual(seat.rings, 1, "the waiting mail rings once, at the StopFailure")
        XCTAssertEqual(seat.rechecks, [], "the StopFailure edge itself looked; no extra look")
        seat.workspace.noteJournalProjectionForMailbox(seat.journal, boundary: nil, panelID: seat.panel)
        XCTAssertEqual(gate(seat), .open, "a later projection of the error phase is not a working turn")

        try hook(seat, "prompt-submit", prompt: "p3")
        XCTAssertEqual(gate(seat), .closed, "a prompt-submit after the StopFailure is the next turn")
        mail(seat, "01M6W0A0000000000000000003")
        XCTAssertEqual(seat.rings, 1, "no ring into the new turn")
    }

    /// A StopFailure stamped before the latest submit belongs to the turn
    /// before it: it cannot reopen the prompt into the turn now running.
    func testAStopFailureStampedBeforeTheLatestSubmitIsStale() throws {
        let seat = try localSeat()
        let failedAt = Date().addingTimeInterval(-5)
        try hook(seat, "prompt-submit", prompt: "p1", emittedAt: failedAt.addingTimeInterval(-10))
        seat.workspace.noteMailboxAgentLifecycle(surfaceId: seat.panel, source: .submit, activity: .working)
        mail(seat, "01M6W0A0000000000000000004")
        try hook(seat, "stop-failure", prompt: "p1", emittedAt: failedAt)
        XCTAssertEqual(gate(seat), .closed, "the Return after it started the next turn")
        XCTAssertEqual(seat.rings, 0)
    }

    /// A draft in the composer still holds the ring the StopFailure opens.
    func testADraftStillHoldsTheRingAfterAStopFailure() throws {
        let seat = try localSeat()
        try hook(seat, "prompt-submit", prompt: "p1")
        mail(seat, "01M6W0A0000000000000000005")
        seat.screen = .draft
        try hook(seat, "stop-failure", prompt: "p1")
        XCTAssertEqual(gate(seat), .open)
        XCTAssertEqual(seat.rings, 0, "the operator's draft holds it")
        seat.screen = .empty
        seat.workspace.recheckMailboxDoorbellAfterFlagLower(surfaceId: seat.panel)
        let rang = expectation(description: "the cleared composer rings")
        DispatchQueue.main.async { rang.fulfill() }
        wait(for: [rang], timeout: 10)
        XCTAssertEqual(seat.rings, 1)
    }

    // MARK: - Remote (a terminal on another machine)

    private func remoteSeat(turnStartedAt: Date? = nil) async throws -> (Seat, ChipSession, HCPanelSession) {
        let seat = try seat(remote: true)
        if let turnStartedAt {
            // The parent turn began long ago: its working edge dates from then.
            seat.workspace.noteMailboxAgentLifecycle(surfaceId: seat.panel, source: .reported, activity: .working,
                                                     at: turnStartedAt)
        }
        let session = ChipSession()
        let working = remoteRecord("working", seq: 1)
        session.feed.publish(snapshot(1, working))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: seat.panel, key: remoteKey), session: session)
        seat.workspace.followHCRemoteStatus(panelID: seat.panel, target: HCRemoteTarget(machine: "studio"), runtime: runtime)
        runtime.publish(.live(working))
        // A turn older than the 2-minute window reads unknown, not closed.
        let owned = await settle { (turnStartedAt != nil || self.gate(seat) == .closed)
            && seat.workspace.mailboxDoorbellGateState(surfaceId: seat.panel)?.ownsTerminal == true }
        XCTAssertTrue(owned, "hc's working Claude owns the remote terminal")
        return (seat, session, runtime)
    }

    /// Each record's foreground carries its `seq` as the cwd, a field the doorbell never reads, so a test can see
    /// which of hc's reports the workspace has applied (`hcWordLanded`).
    private func remoteRecord(_ status: String, seq: Int64) -> HCTerminalRecord {
        HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio", machineAvailability: .connected,
                         pid: 4242, foreground: HCForeground(pid: 78, name: "claude", argv: ["claude"], cwd: "/work/\(seq)"),
                         status: status, statusTimestampMilliseconds: 1_000 * seq, turn: seq)
    }

    private func snapshot(_ sequence: UInt64, _ record: HCTerminalRecord) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [remoteKey: record],
                                   machines: ["studio": .connected])
    }

    /// C11H-402: a deadline, not a count of polls. On a loaded host hc's word crosses a utility queue and a main
    /// hop late, and each poll's sleep runs long; the wait still returns as soon as the condition holds.
    private func settle(_ until: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if until() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return until()
    }

    /// The workspace has applied hc's report `seq` (its status word and owner are set in the same main-actor turn
    /// as the foreground).
    private func hcWordLanded(_ seat: Seat, seq: Int64) async -> Bool {
        await settle { seat.workspace.hcRemoteForeground[seat.panel]?.cwd == "/work/\(seq)" }
    }

    /// The incident's order: hc's word changes with the failure, then the
    /// relayed StopFailure closes the journal turn. Both agree the turn is
    /// over, so the held mail rings once, at the StopFailure.
    func testARemoteClaudeRingsOnceWhenItsRelayedStopFailureClosesTheTurn() async throws {
        let (seat, session, _) = try await remoteSeat()
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000006")
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000007")
        XCTAssertEqual(seat.rings, 0)

        session.feed.publish(snapshot(2, remoteRecord("error", seq: 2)))
        // C11H-402: wait for hc's error itself to reach the workspace. Ownership was already true from the working
        // report, so the old check passed at once, and under load the StopFailure below arrived before hc's error.
        let seen = await hcWordLanded(seat, seq: 2)
        XCTAssertTrue(seen, "hc's error reached the workspace")
        XCTAssertEqual(seat.workspace.hcRemoteAgentOwnsTerminal[seat.panel], true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seat.rings, 0, "hc's error alone is not a turn end while the journal shows the turn")

        try hook(seat, "stop-failure", remote: true)
        XCTAssertEqual(seat.journal?.phase, .error)
        XCTAssertEqual(seat.rings, 1, "the relayed StopFailure and hc agree: one ring")

        try hook(seat, "prompt-submit", prompt: "p9", remote: true)
        XCTAssertEqual(gate(seat), .closed, "the relayed prompt-submit closes the gate again")
        mail(seat, "01M6W0A0000000000000000008")
        XCTAssertEqual(seat.rings, 1)
    }

    /// The other order: the StopFailure closes the journal turn while hc still
    /// reads working. The doorbell looks once (`journal_turn_closed`) and then
    /// rings when hc's word follows.
    func testARemoteStopFailureBeforeHCsWordLooksOnceThenRingsOnHCsError() async throws {
        let (seat, session, _) = try await remoteSeat()
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000009")
        try hook(seat, "stop-failure", remote: true)
        XCTAssertEqual(seat.rechecks.filter { $0 == "journal_turn_closed" }.count, 1,
                       "the journal turn's close looks once")
        XCTAssertEqual(seat.rings, 0, "hc still reads working: the look holds")

        session.feed.publish(snapshot(2, remoteRecord("error", seq: 2)))
        let rang = await settle { seat.rings == 1 }
        XCTAssertTrue(rang, "hc's error agrees with the journal: one ring")
        XCTAssertEqual(seat.rechecks.filter { $0 == "journal_turn_closed" }.count, 1, "no recheck storm")
    }

    /// Repair 1 (review): a parent turn older than the 2-minute window, an
    /// empty composer, hc still `working`, and a headless `claude -p` run in
    /// that turn whose relayed Stop closes the journal. The close looks
    /// later, never at once, so nothing types into the running parent; hc's
    /// idle when the parent really ends rings once.
    func testARelayedNestedStopInALongRemoteTurnDoesNotRingUntilHCAgrees() async throws {
        let (seat, session, _) = try await remoteSeat(turnStartedAt: Date().addingTimeInterval(-300))
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000011")
        try hook(seat, "stop", remote: true)
        XCTAssertEqual(seat.journal?.phase, .idle, "the nested run's Stop closed the journal turn")
        XCTAssertEqual(seat.rechecks.filter { $0 == "journal_turn_closed" }.count, 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seat.rings, 0, "hc still reads working: no ring into the parent's turn")

        session.feed.publish(snapshot(2, remoteRecord("idle", seq: 2)))
        let rang = await settle { seat.rings == 1 }
        XCTAssertTrue(rang, "hc's idle when the parent ends rings once")
    }

    /// Repair 2 (design): a real scheduled look, through the timer path,
    /// while hc still says working after a nested relayed Stop on a long
    /// parent turn. The gate stays closed (not unknown), nothing rings, and
    /// the hold names the core's word; hc's idle then rings once.
    func testAScheduledLookWithHCStillWorkingNeverRingsARemotePanel() async throws {
        let (seat, session, _) = try await remoteSeat(turnStartedAt: Date().addingTimeInterval(-300))
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000012")
        try hook(seat, "stop", remote: true)
        XCTAssertEqual(seat.journal?.phase, .idle)
        seat.workspace.recheckMailboxDoorbellAfterOpenCodeRouteBound(surfaceId: seat.panel)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(gate(seat), .closed, "hc still says working: closed, not unknown")
        XCTAssertEqual(seat.rings, 0, "the scheduled look types nothing into the parent")
        XCTAssertEqual(seat.workspace.mailboxWaitByPanel[seat.panel]?.code, "core_working")

        session.feed.publish(snapshot(2, remoteRecord("idle", seq: 2)))
        let rang = await settle { seat.rings == 1 }
        XCTAssertTrue(rang, "hc's idle rings once")
    }

    /// Main's exposure: mail that arrives after a nested relayed Stop on a
    /// long parent turn is held while hc says working; hc's error, with the
    /// journal already idle, rings it once.
    func testMailArrivingAfterANestedStopInALongRemoteTurnIsHeldWhileHCWorks() async throws {
        let (seat, session, _) = try await remoteSeat(turnStartedAt: Date().addingTimeInterval(-300))
        try hook(seat, "prompt-submit", remote: true)
        try hook(seat, "stop", remote: true)
        mail(seat, "01M6W0A0000000000000000013")
        XCTAssertEqual(gate(seat), .closed)
        XCTAssertEqual(seat.rings, 0)
        XCTAssertEqual(seat.workspace.mailboxWaitByPanel[seat.panel]?.code, "core_working")

        session.feed.publish(snapshot(2, remoteRecord("error", seq: 2)))
        let rang = await settle { seat.rings == 1 }
        XCTAssertTrue(rang, "hc's error and the idle journal agree: one ring")
    }

    // MARK: - A journal turn that stays open

    /// Projections while the journal turn stays open look at nothing; its
    /// close looks once, with one `doorbell_recheck`.
    func testAnOpenJournalTurnHoldsWithoutRechecksAndItsCloseLooksOnce() async throws {
        let (seat, _, _) = try await remoteSeat()
        try hook(seat, "prompt-submit", remote: true)
        mail(seat, "01M6W0A0000000000000000010")
        for prompt in 0..<5 {
            try hook(seat, "notification", remote: true)
            try hook(seat, "prompt-submit", prompt: "q\(prompt)", remote: true)
        }
        XCTAssertEqual(seat.rechecks, [], "a turn that stays open never looks again")
        try hook(seat, "stop", remote: true)
        XCTAssertEqual(seat.journal?.phase, .idle)
        XCTAssertEqual(seat.rechecks.filter { $0 == "journal_turn_closed" }.count, 1)
    }
}

/// C11H-238: a working fleet projects a new journal snapshot per structural
/// event (about 1.4 a second live). Only a change a view can show republishes
/// the workspace; the stored snapshot is always the newest.
@MainActor
final class WorkspaceJournalPublishTests: XCTestCase {
    func testOnlyAPresentationChangeRepublishesTheWorkspace() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        var sends = 0
        let watch = workspace.objectWillChange.sink { sends += 1 }
        defer { watch.cancel() }

        var snapshot = JournalSnapshot(owner: JournalOwner(panelID: panel, agentKind: "claude-code", sessionID: "s"),
                                       workspaceID: workspace.id, appInstanceID: UUID())
        snapshot.phase = .working
        snapshot.sinceMs = 1_000
        snapshot.observedAtMs = 1_000
        workspace.setJournalSnapshot(snapshot, forPanel: panel)
        XCTAssertEqual(sends, 1, "the first snapshot is news")

        for tick in 1...20 {
            snapshot.observedAtMs = 1_000 + Int64(tick) * 700
            snapshot.lastSequence = Int64(tick)
            snapshot.observedTickNs = UInt64(tick)
            workspace.setJournalSnapshot(snapshot, forPanel: panel)
        }
        XCTAssertEqual(sends, 1, "observation-only updates must not re-render the workspace")
        XCTAssertEqual(workspace.journalByPanel[panel]?.lastSequence, 20, "the newest snapshot is stored")

        snapshot.phase = .blocked
        snapshot.reason = .question
        workspace.setJournalSnapshot(snapshot, forPanel: panel)
        XCTAssertEqual(sends, 2, "a phase change republishes at once")

        workspace.setJournalSnapshot(nil, forPanel: panel)
        XCTAssertEqual(sends, 3, "clearing the snapshot republishes")
    }
}

/// C11H-238: the activity-mark clock stops while no window is visible and
/// catches every mark up once when one shows.
@MainActor
final class WindowVisibilityGateTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAHiddenWindowStopsTheMarkClockAndShowingItCatchesUpOnce() {
        let clock = BonsplitActivityAnimationClock.shared
        let gate = WindowVisibilityGate.shared
        var ticks = 0
        let token = clock.subscribe { _ in ticks += 1 }
        defer {
            clock.unsubscribe(token)
            gate.apply(anyVisible: true)
        }
        gate.apply(anyVisible: true)
        XCTAssertTrue(clock.isTicking)
        spin(0.5)
        XCTAssertGreaterThanOrEqual(ticks, 2, "a visible window ticks at 5 Hz")

        gate.apply(anyVisible: false)
        XCTAssertFalse(clock.isTicking, "no window visible: no timer")
        let atHide = ticks
        spin(0.7)
        XCTAssertEqual(ticks, atHide, "a hidden window costs no ticks")

        gate.apply(anyVisible: true)
        XCTAssertEqual(ticks, atHide + 1, "showing a window publishes the current phase at once")
        XCTAssertTrue(clock.isTicking)
        spin(0.5)
        XCTAssertGreaterThan(ticks, atHide + 1, "and the clock runs again")
    }

    func testAnotherAppActiveStopsTheMarkClockAndActivatingCatchesUpOnce() {
        let clock = BonsplitActivityAnimationClock.shared
        let gate = WindowVisibilityGate.shared
        var ticks = 0
        let token = clock.subscribe { _ in ticks += 1 }
        defer {
            clock.unsubscribe(token)
            gate.apply(anyVisible: true)
        }
        gate.apply(anyVisible: true, appActive: false)
        XCTAssertFalse(clock.isTicking, "another app active: the marks hold still")
        let atResign = ticks
        spin(0.5)
        XCTAssertEqual(ticks, atResign)
        gate.apply(anyVisible: true, appActive: true)
        XCTAssertEqual(ticks, atResign + 1, "activating publishes the current phase at once")
        XCTAssertTrue(clock.isTicking)
    }

    /// C11H-278: the coarse decay clock (description ages, decay pills) runs
    /// nothing while no window is visible and catches up once on show.
    func testAHiddenWindowStopsTheDecayClockAndShowingItPublishesOnce() throws {
        try XCTSkipIf(true, "Flaky on the loaded CI runner; quarantined until made deterministic (C11H-431)")
        let decay = SidebarDecayClock(interval: 0.1)
        let gate = WindowVisibilityGate.shared
        var publishes = 0
        let subscription = decay.$now.dropFirst().sink { _ in publishes += 1 }
        defer {
            subscription.cancel()
            gate.apply(anyVisible: true)
        }
        gate.apply(anyVisible: true, decayClock: decay)
        XCTAssertTrue(decay.isTicking)
        spin(0.35)
        XCTAssertGreaterThanOrEqual(publishes, 2, "a visible window ticks")

        gate.apply(anyVisible: false, decayClock: decay)
        XCTAssertFalse(decay.isTicking, "no window visible: no timer")
        let atHide = publishes
        spin(0.35)
        XCTAssertEqual(publishes, atHide, "a hidden window costs no ticks")

        gate.apply(anyVisible: true, decayClock: decay)
        XCTAssertEqual(publishes, atHide + 1, "showing a window publishes the current time at once")
        XCTAssertTrue(decay.isTicking)
    }

    /// A visible c11 behind another app is still read: its ages keep moving.
    func testAnotherAppActiveKeepsTheDecayClockRunning() {
        let decay = SidebarDecayClock(interval: 0.1)
        defer { WindowVisibilityGate.shared.apply(anyVisible: true) }
        WindowVisibilityGate.shared.apply(anyVisible: true, appActive: false, decayClock: decay)
        XCTAssertTrue(decay.isTicking)
    }

    func testAClockWithNoMarksStaysStoppedWhenAWindowShows() {
        let clock = BonsplitActivityAnimationClock.shared
        WindowVisibilityGate.shared.apply(anyVisible: false)
        WindowVisibilityGate.shared.apply(anyVisible: true)
        XCTAssertFalse(clock.isTicking)
    }
}

/// C11H-238: the root view asks for the focused panel on every evaluation.
/// That read must depend on the pane's selection only, never on its tabs'
/// titles or activity marks, or every mark change re-renders the window.
@MainActor
final class FocusedPanelObservationTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func tracking(_ workspace: Workspace, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = workspace.focusedPanelId
        } onChange: {
            flag.fired = true
        }
        change()
        return flag.fired
    }

    func testATabChangeDoesNotInvalidateTheFocusedPanelButASelectionDoes() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let controller = workspace.bonsplitController
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(panel))
        let pane = try XCTUnwrap(controller.focusedPaneId)

        XCTAssertFalse(tracking(workspace) {
            controller.updateTab(tab, title: "renamed", activityState: .some(.running))
        }, "a title or activity change in the pane is not a focus change")

        let other = try XCTUnwrap(controller.createTab(title: "other", inPane: pane))
        // Creating a tab may select it; switch to whichever one is not selected.
        let target = controller.selectedTabId(inPane: pane) == other ? tab : other
        XCTAssertTrue(tracking(workspace) { controller.selectTab(target) },
                      "selecting another tab changes the focused panel")
        XCTAssertEqual(controller.selectedTabId(inPane: pane), target)
        XCTAssertEqual(workspace.focusedPanelId, workspace.tabIdFromBonsplitTabId(target))
    }
}

/// C11H-238: the app body evaluates the Area menu's enable check on every
/// pass. It must not read the tabs' contents, or every activity mark change
/// re-renders the app body and each window under it.
@MainActor
final class CloseOtherPanelsEnableObservationTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var fired = false }

    func testTheEnableCheckIgnoresTabContentsButFollowsMembership() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let controller = workspace.bonsplitController
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let first = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(manager.canCloseOtherPanelsInFocusedPane(), "one panel: nothing else to close")

        func tracking(_ change: () -> Void) -> Bool {
            let flag = Flag()
            withObservationTracking { _ = manager.canCloseOtherPanelsInFocusedPane() } onChange: { flag.fired = true }
            change()
            return flag.fired
        }

        XCTAssertTrue(tracking { _ = workspace.newTerminalSurface(inPane: pane, focus: false) },
                      "a new panel in the area changes the answer")
        XCTAssertTrue(manager.canCloseOtherPanelsInFocusedPane())

        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(first))
        XCTAssertFalse(tracking { controller.updateTab(tab, title: "renamed", activityState: .some(.running)) },
                       "a title or activity change is not a membership change")
        XCTAssertTrue(manager.canCloseOtherPanelsInFocusedPane())
    }

    /// Area order A,B with B selected: pinning or unpinning A keeps the order,
    /// yet flips whether there is anything else to close.
    func testAPinOrUnpinThatKeepsTheOrderUpdatesTheEnableCheck() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let controller = workspace.bonsplitController
        let pane = try XCTUnwrap(controller.focusedPaneId)
        let a = try XCTUnwrap(workspace.focusedPanelId)
        let b = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false)).id
        controller.selectTab(try XCTUnwrap(workspace.bonsplitTabIdFromTabId(b)))
        let order = controller.tabIds(inPane: pane)
        XCTAssertEqual(order.first, workspace.bonsplitTabIdFromTabId(a))
        XCTAssertTrue(manager.canCloseOtherPanelsInFocusedPane())

        func tracking(_ change: () -> Void) -> Bool {
            let flag = Flag()
            withObservationTracking { _ = manager.canCloseOtherPanelsInFocusedPane() } onChange: { flag.fired = true }
            change()
            return flag.fired
        }

        XCTAssertTrue(tracking { workspace.setPanelPinned(panelId: a, pinned: true) }, "pinning A is observed")
        XCTAssertEqual(controller.tabIds(inPane: pane), order, "the order is unchanged")
        XCTAssertFalse(manager.canCloseOtherPanelsInFocusedPane(), "the only other panel is pinned")

        XCTAssertTrue(tracking { workspace.setPanelPinned(panelId: a, pinned: false) }, "unpinning A is observed")
        XCTAssertEqual(controller.tabIds(inPane: pane), order)
        XCTAssertTrue(manager.canCloseOtherPanelsInFocusedPane())
    }
}

private final class HeartbeatSeen {
    var sends = 0
    var sendsAtOnce = -1
    var listedAtOnce: SidebarStatusEntry?
}

/// C11H-238: a working agent re-reports the same status on every tool call.
/// The reported time is kept at once (order, socket reads) and reaches the
/// views in one coalesced publish; the last heartbeat is never dropped.
@MainActor
final class StatusHeartbeatPublishTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// C11H-346: setStatus answers at once and applies its report in a main-queue block. This
    /// waits until every main-queue block enqueued before it has run (a fixed spin let a loaded
    /// host read first), then runs `body` in that same turn.
    private func drainMain(_ body: @escaping () -> Void = {}) {
        let drained = expectation(description: "the main queue reached this point")
        DispatchQueue.main.async { body(); drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    func testIdenticalHeartbeatsKeepTheirTimeAndPublishOnceCoalesced() throws {
        let saved = (TerminalController.shared.workspaceManager, Workspace.statusHeartbeatFlushDelay)
        defer { (TerminalController.shared.workspaceManager, Workspace.statusHeartbeatFlushDelay) = saved }
        Workspace.statusHeartbeatFlushDelay = 0.3
        let manager = WorkspaceManager()
        TerminalController.shared.workspaceManager = manager
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let command = "claude_code Running --tab=\(workspace.id) --panel=\(panel)"

        XCTAssertEqual(TerminalController.shared.setStatus(command), "OK")
        drainMain()
        let first = try XCTUnwrap(workspace.statusEntries["claude_code"])
        let seen = HeartbeatSeen()
        let watch = workspace.objectWillChange.sink { seen.sends += 1 }
        defer { watch.cancel() }

        spin(0.02)   // the heartbeats' clock is later than the report's
        for _ in 0..<5 { XCTAssertEqual(TerminalController.shared.setStatus(command), "OK") }
        // Read in the turn the heartbeats landed in: their coalesced flush, due 0.3 s after the
        // first, is queued behind it however late that turn runs.
        drainMain {
            seen.sendsAtOnce = seen.sends
            seen.listedAtOnce = workspace.sidebarStatusEntriesInDisplayOrder().first
        }
        XCTAssertEqual(seen.sendsAtOnce, 0, "heartbeats do not republish at once")
        let listed = try XCTUnwrap(seen.listedAtOnce)
        XCTAssertGreaterThan(listed.timestamp, first.timestamp, "reads see the last-reported time at once")

        let deadline = Date().addingTimeInterval(10)
        while seen.sends == 0, Date() < deadline { spin(0.01) }
        drainMain()
        XCTAssertEqual(seen.sends, 1, "one coalesced publish")
        let stored = try XCTUnwrap(workspace.statusEntries["claude_code"]?.timestamp)
        XCTAssertEqual(stored, listed.timestamp, "the last heartbeat is written, not dropped")
    }

    func testAHeartbeatOrdersAndDecaysByItsOwnTime() throws {
        let workspace = Workspace()
        let now = Date()
        workspace.statusEntries["a"] = SidebarStatusEntry(key: "a", value: "A", timestamp: now.addingTimeInterval(-20))
        workspace.statusEntries["b"] = SidebarStatusEntry(key: "b", value: "B", timestamp: now.addingTimeInterval(-10))
        XCTAssertEqual(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key), ["b", "a"])
        workspace.noteStatusHeartbeat(key: "a", at: now)
        XCTAssertEqual(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key), ["a", "b"],
                       "equal priority: the fresher report lists first, at once")

        // Report at t-20, heartbeat at t, then silence: decay counts from t.
        workspace.flushStatusHeartbeats()
        let reported = try XCTUnwrap(workspace.statusEntries["a"]?.timestamp)
        XCTAssertEqual(reported, now)
        let stale = SidebarStalenessSettings.defaultStaleSeconds
        let expiry = SidebarStalenessSettings.defaultExpirySeconds
        func stage(at seconds: Double) -> SidebarDecayStage {
            SidebarStalenessSettings.stage(ageSeconds: now.addingTimeInterval(seconds).timeIntervalSince(reported),
                                           staleSeconds: stale, expirySeconds: expiry)
        }
        XCTAssertEqual(stage(at: stale - 10), .fresh, "280 s after the last report is still fresh")
        XCTAssertNotEqual(stage(at: stale + 10), .fresh)
        XCTAssertNotEqual(stage(at: expiry - 10), stage(at: expiry + 10), "expiry is counted from the last report")
    }
}

/// C11H-238: writes that repeat the current value must not republish the
/// workspace (a `@Published` dictionary publishes on any mutation).
@MainActor
final class RepeatedWorkspaceWritePublishTests: XCTestCase {
    func testARepeatedPortScanAndAnAbsentAttentionRemovalPublishNothing() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        var sends = 0
        let watch = workspace.objectWillChange.sink { sends += 1 }
        defer { watch.cancel() }

        workspace.applyScannedListeningPorts([3000], forPanel: panel)
        XCTAssertEqual(workspace.panelListeningPorts[panel], [3000])
        let afterFirst = sends
        XCTAssertGreaterThan(afterFirst, 0, "a new port is news")
        workspace.applyScannedListeningPorts([3000], forPanel: panel)
        workspace.applyScannedListeningPorts([3000], forPanel: panel)
        XCTAssertEqual(sends, afterFirst, "the same ports again change nothing")
        workspace.applyScannedListeningPorts([], forPanel: panel)
        XCTAssertNil(workspace.panelListeningPorts[panel])
        XCTAssertGreaterThan(sends, afterFirst, "losing the port is news")

        let beforeAttention = sends
        workspace.setAttentionSnapshot(nil, forSurface: panel)
        workspace.setAttentionSnapshot(nil, forSurface: panel)
        XCTAssertEqual(sends, beforeAttention, "clearing attention a panel does not have changes nothing")
    }

    func testTheSameFlagAgainPublishesNothing() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let flag = PanelAttentionSnapshot(workspaceId: workspace.id, surfaceId: panel, flagReason: "needs review",
                                          flagRaisedAt: Date(timeIntervalSince1970: 1_800_000_000), delegated: false)
        workspace.setAttentionSnapshot(flag, forSurface: panel)
        XCTAssertEqual(workspace.attentionByPanel[panel], flag)
        var sends = 0
        let watch = workspace.objectWillChange.sink { sends += 1 }
        defer { watch.cancel() }
        workspace.setAttentionSnapshot(flag, forSurface: panel)
        workspace.setAttentionSnapshot(flag, forSurface: panel)
        XCTAssertEqual(sends, 0, "an identical flag snapshot changes nothing")
    }
}

/// C11H-238: activity marks move in Core Animation. The layer keyframes must
/// keep the clock's look, timing and per-panel phase, follow the host's pause
/// and the view's attachment, sit where SwiftUI centered them, and install
/// nothing without motion. No mark keeps a clock subscription.
@MainActor
final class ActivityMarkLayerMotionTests: XCTestCase {
    private let id = UUID(uuidString: "6B1E2C1A-3D4F-4A5B-9C6D-7E8F90A1B2C3")!
    private typealias Overlay = BonsplitActivityMarkMotionOverlay

    override func setUp() {
        super.setUp()
        BonsplitActivityAnimationClock.shared.isPaused = false
    }

    /// The discrete keyframe value at a unit time.
    private func discreteValue(_ animation: CAKeyframeAnimation, unit: Double) -> Double {
        let times = (animation.keyTimes ?? []).map(\.doubleValue)
        let values = (animation.values as? [NSNumber] ?? []).map(\.doubleValue)
        var index = 0
        for (i, t) in times.enumerated() where i < values.count && unit >= t { index = i }
        return values[index]
    }

    /// The animation's value at media time `now`, from its beginTime.
    private func unit(of animation: CAAnimation, at now: CFTimeInterval) -> Double {
        (now - animation.beginTime).truncatingRemainder(dividingBy: animation.duration) / animation.duration
    }

    private func attachedView(_ part: Overlay.Part, motion: BonsplitActivityMarkMotion?,
                              alternate: NSColor? = nil) -> Overlay.MotionView {
        let view = Overlay.MotionView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        view.attachedForTesting = true
        view.configure(.init(part: part, color: .systemBlue, alternateColor: alternate, motion: motion, phaseId: id))
        return view
    }

    private func running(_ view: Overlay.MotionView) -> Int {
        view.installedAnimationsForTesting.compactMap { $0 }.count
    }

    // MARK: Timing and phase

    func testWorkingDotsAppearOnTheClocksBeats() {
        let cycle = BonsplitActivityMarkAnimation.workingCycle
        let offset = BonsplitActivityMarkAnimation.stableUnitPhase(for: id) * cycle
        for rank in 0..<9 {
            let animation = BonsplitActivityMarkKeyframes.workingDot(rank: rank, phaseId: id)
            XCTAssertEqual(animation.duration, cycle)
            XCTAssertEqual(animation.calculationMode, .discrete)
            for step in 0..<400 {
                // Between beats: exactly on one, rounding picks either side.
                let seconds = Double(step) * 0.01 + 0.005
                let elapsed = seconds - offset + 1000 * cycle
                let shown = BonsplitActivityMarkAnimation.visibleWorkingDots(at: elapsed, id: id) > rank
                XCTAssertEqual(discreteValue(animation, unit: seconds / cycle), shown ? 1 : 0,
                               "dot \(rank) at \(seconds) s")
            }
        }
    }

    func testTheWaitingCoreFollowsTheEasedDip() {
        let animation = BonsplitActivityMarkKeyframes.waitingCore(phaseId: id)
        let cycle = BonsplitActivityMarkAnimation.waitingCycle
        XCTAssertEqual(animation.duration, cycle)
        let values = (animation.values as? [NSNumber] ?? []).map(\.doubleValue)
        let times = (animation.keyTimes ?? []).map(\.doubleValue)
        let offset = BonsplitActivityMarkAnimation.stableUnitPhase(for: id) * cycle
        for (unit, value) in zip(times, values) {
            let elapsed = unit * cycle - offset + 1000 * cycle
            XCTAssertEqual(value, BonsplitActivityMarkAnimation.waitingCoreOpacity(at: elapsed, id: id), accuracy: 1e-6)
        }
        XCTAssertEqual(values.min() ?? 1, 0.15, accuracy: 0.01, "dips to 0.15")
    }

    /// The flash keeps base's formula: a 0.4 s cycle of two 0.2 s halves.
    func testTheFlaggedFlashAlternatesEveryTwoTenthsOfASecond() {
        let animation = BonsplitActivityMarkKeyframes.flashAlternate(phaseId: id)
        let cycle = BonsplitActivityMarkAnimation.binaryFlashCycle
        XCTAssertEqual(cycle, 0.4)
        XCTAssertEqual(animation.duration, cycle)
        let offset = BonsplitActivityMarkAnimation.stableUnitPhase(for: id) * cycle
        for step in 0..<40 {
            let seconds = Double(step) * 0.01 + 0.005
            let elapsed = seconds - offset + 1000 * cycle
            let shows = BonsplitActivityMarkAnimation.binaryFlashShowsAlternate(at: elapsed, id: id)
            XCTAssertEqual(discreteValue(animation, unit: seconds / cycle), shows ? 1 : 0, "at \(seconds) s")
            XCTAssertEqual(shows, seconds >= 0.2, "halves of 0.2 s")
        }
    }

    func testTheBreatheFollowsTheClocksCurve() {
        let animation = BonsplitActivityMarkKeyframes.breathe(phaseId: id)
        let cycle = BonsplitActivityMarkAnimation.breatheCycle
        XCTAssertEqual(animation.duration, cycle)
        let offset = BonsplitActivityMarkAnimation.stableUnitPhase(for: id) * cycle
        for (unit, value) in zip((animation.keyTimes ?? []).map(\.doubleValue),
                                 (animation.values as? [NSNumber] ?? []).map(\.doubleValue)) {
            let elapsed = unit * cycle - offset + 1000 * cycle
            XCTAssertEqual(value, BonsplitActivityMarkAnimation.breatheOpacity(at: elapsed, id: id), accuracy: 1e-6)
        }
    }

    func testTheBeginTimeKeepsThePanelsPhase() {
        let cycle = BonsplitActivityMarkAnimation.waitingCycle
        let animation = BonsplitActivityMarkKeyframes.waitingCore(phaseId: id)
        let now = CACurrentMediaTime()
        XCTAssertEqual(unit(of: animation, at: now) * cycle,
                       BonsplitActivityMarkAnimation.phase(at: now, id: id, cycle: cycle) * cycle, accuracy: 0.01)
    }

    // MARK: Lifecycle

    func testPauseRemovesAndResumeRestartsAtTheFormulasPhase() {
        let clock = BonsplitActivityAnimationClock.shared
        let view = attachedView(.waitingCore(height: 4), motion: .easedDip)
        XCTAssertEqual(running(view), 1)
        clock.isPaused = true
        XCTAssertEqual(running(view), 0, "paused: no animation")
        clock.isPaused = false
        let resumed = try? XCTUnwrap(view.installedAnimationsForTesting.first ?? nil)
        XCTAssertNotNil(resumed)
        if let resumed {
            let now = CACurrentMediaTime()
            XCTAssertEqual(unit(of: resumed, at: now),
                           BonsplitActivityMarkAnimation.phase(at: now, id: id, cycle: BonsplitActivityMarkAnimation.waitingCycle),
                           accuracy: 0.01, "the first frame after resume is at the formula's phase")
        }
    }

    func testAnIdenticalConfigureInstallsNothing() {
        let view = attachedView(.workingDots(rows: 3), motion: .steppedFill)
        let installs = view.installCountForTesting
        view.configure(.init(part: .workingDots(rows: 3), color: .systemBlue, alternateColor: nil,
                             motion: .steppedFill, phaseId: id))
        XCTAssertEqual(view.installCountForTesting, installs, "an unchanged mark reinstalls nothing")
        XCTAssertEqual(running(view), 9)
    }

    func testOneReusedViewCarriesExactlyTheCurrentStatesAnimation() {
        let view = attachedView(.workingDots(rows: 3), motion: .steppedFill)
        XCTAssertEqual(running(view), 9, "working: nine dots")
        view.configure(.init(part: .waitingCore(height: 4), color: .systemOrange, alternateColor: nil,
                             motion: .easedDip, phaseId: id))
        XCTAssertEqual(view.installedAnimationsForTesting.count, 1, "the dots are gone")
        XCTAssertEqual(running(view), 1, "waiting: the core dips")
        view.configure(.init(part: .waitingCore(height: 4), color: .systemOrange, alternateColor: .white,
                             motion: .binaryFlash, phaseId: id))
        let layers = view.installedAnimationsForTesting
        XCTAssertEqual(layers.count, 2)
        XCTAssertNil(layers[0] ?? nil, "flagged: the core holds still")
        XCTAssertNotNil(layers[1] ?? nil, "and only the alternate flashes")
    }

    func testADetachedMarkAnimatesNothingUntilAttachedAgain() {
        let clock = BonsplitActivityAnimationClock.shared
        let view = attachedView(.workingDots(rows: 3), motion: .steppedFill)
        XCTAssertEqual(running(view), 9)
        view.attachedForTesting = false
        XCTAssertEqual(running(view), 0, "detached: nothing runs")
        clock.isPaused = true
        clock.isPaused = false
        XCTAssertEqual(running(view), 0, "a resume does not reinstall a detached mark")
        view.attachedForTesting = true
        XCTAssertEqual(running(view), 9, "attached again: running")
    }

    func testNoMotionInstallsNothing() {
        let view = attachedView(.workingDots(rows: 3), motion: nil)
        XCTAssertEqual(running(view), 0, "Reduce Motion or Static marks: the static mark")
    }

    func testABreathingMarkFadesOnALayerAndFollowsThePause() {
        let clock = BonsplitActivityAnimationClock.shared
        let view = BonsplitActivityMarkBreathe<Color>.BreatheView(rootView: Color.purple, phaseId: id)
        view.frame = NSRect(x: 0, y: 0, width: 9, height: 9)
        XCTAssertNil(view.breatheAnimationForTesting, "detached: no breathe")
        view.attachedForTesting = true
        XCTAssertEqual(view.breatheAnimationForTesting?.duration, BonsplitActivityMarkAnimation.breatheCycle)
        clock.isPaused = true
        XCTAssertNil(view.breatheAnimationForTesting)
        clock.isPaused = false
        XCTAssertNotNil(view.breatheAnimationForTesting)
        XCTAssertFalse(clock.isTicking, "no mark needs a clock timer, breathing ones included")
    }

    // MARK: Geometry

    /// SwiftUI centered an 8 pt grid in a 9 pt cell at (0.5, 0.5) and a 4 pt
    /// core at (2.5, 2.5); at 2x those are whole pixels and must stay.
    func testCenteredPartsKeepTheirHalfPointOriginsAt2x() {
        let dots = attachedView(.workingDots(rows: 3), motion: .steppedFill).partFramesForTesting
        XCTAssertEqual(dots.first?.origin, CGPoint(x: 0.5, y: 6.5), "rank 0 is bottom-left")
        XCTAssertEqual(dots.map(\.minX).min(), 0.5)
        XCTAssertEqual(dots.map(\.minY).min(), 0.5)
        XCTAssertEqual(dots.map(\.maxX).max(), 8.5)
        let core = attachedView(.waitingCore(height: 4), motion: .easedDip).partFramesForTesting
        XCTAssertEqual(core.first, CGRect(x: 2.5, y: 2.5, width: 4, height: 4))
    }

    func testADelegatesShortenedMarkCentersItsDotsAsSwiftUIDid() {
        for depth in 1...2 {
            let height = BonsplitActivityMarkLineage.markHeight(depth: depth)
            let rows = BonsplitActivityMarkLineage.workingDotRows(depth: depth)
            let view = Overlay.MotionView(frame: NSRect(x: 0, y: 0, width: 9, height: height))
            view.attachedForTesting = true
            view.configure(.init(part: .workingDots(rows: rows), color: .systemBlue, alternateColor: nil,
                                 motion: .steppedFill, phaseId: id))
            let frames = view.partFramesForTesting
            let gridHeight = CGFloat(rows) * 2 + CGFloat(rows - 1)
            let expectedTop = ((height - gridHeight) / 2 * 2).rounded() / 2
            XCTAssertEqual(frames.map(\.minY).min() ?? -1, expectedTop, accuracy: 0.001, "depth \(depth)")
            XCTAssertEqual(frames.map(\.minX).min(), 0.5, "depth \(depth)")
        }
    }

    // MARK: Settings

    /// Reduce Motion stops every mark, flags included, through the same
    /// functions the sidebar and the tab strip use; Static marks keeps flags.
    func testReduceMotionStopsEveryMarkAndStaticMarksKeepsFlags() {
        for state in WorkspacePulseState.allCases {
            for flagged in [false, true] {
                XCTAssertNil(ActivityMarkSettings.sidebarMotion(
                    state: state, flagged: flagged, suppressed: false, animationEligible: true, sceneActive: true,
                    reduceMotion: true, staticMarks: false), "sidebar \(state) flagged=\(flagged)")
            }
        }
        XCTAssertEqual(ActivityMarkSettings.sidebarMotion(state: .waiting, flagged: true, suppressed: false,
                                                          animationEligible: true, sceneActive: true,
                                                          reduceMotion: false, staticMarks: true), .binaryFlash)
        XCTAssertNil(ActivityMarkSettings.sidebarMotion(state: .working, flagged: false, suppressed: false,
                                                        animationEligible: true, sceneActive: true,
                                                        reduceMotion: false, staticMarks: true))

        let reduced = ActivityMarkSettings.motionPermissions(inputActive: true, sceneActive: true,
                                                             reduceMotion: true, staticMarks: false)
        let flag = BonsplitTabActivityPresentation(motion: .binaryFlash)
        for state in [BonsplitTabActivityState.running, .waiting, .idle] {
            XCTAssertNil(TabActivityMarkMotionPolicy.resolvedMotion(
                for: state, defaultMotionEnabled: reduced.defaultMotion, explicitMotionEnabled: reduced.explicitMotion,
                presentation: flag), "tab \(state) flagged")
            XCTAssertNil(TabActivityMarkMotionPolicy.resolvedMotion(
                for: state, defaultMotionEnabled: reduced.defaultMotion, explicitMotionEnabled: reduced.explicitMotion,
                presentation: nil), "tab \(state)")
        }
        let stat = ActivityMarkSettings.motionPermissions(inputActive: true, sceneActive: true,
                                                          reduceMotion: false, staticMarks: true)
        XCTAssertEqual(TabActivityMarkMotionPolicy.resolvedMotion(
            for: .waiting, defaultMotionEnabled: stat.defaultMotion, explicitMotionEnabled: stat.explicitMotion,
            presentation: flag), .binaryFlash, "Static marks keeps a flag's motion")
    }
}

// C11H-304, C11H-306: mail to an agent in a panel with no screen (a hidden workspace's panel restored headless after
// a relaunch). hc's status says whether it is at its prompt; at its prompt its composer is read from hc's paint, here
// the paints recorded from hc 0.1.16 (`Fixtures/hc-paint`), and classified as the screen path classifies its own.
@MainActor
final class HCHeadlessDoorbellTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "local-core", localAddress: "t21")
    private let agentPID: pid_t = 4711
    private let device: dev_t = 0x1234
    private let born: UInt64 = 1_700_000_000_000_000

    private final class Seat {
        let workspace: Workspace
        let panel: UUID
        var record: HCTerminalRecord?
        var headless = true
        var screen: PromptInputState = .empty
        var paint: Result<HCComposerPaint, HCComposerReadFailure> = .failure(.unavailable)
        var reads = 0
        var rings = 0
        init(workspace: Workspace, panel: UUID) { self.workspace = workspace; self.panel = panel }
        @MainActor var wait: String? { workspace.mailboxWaitByPanel[panel]?.code }
    }

    private struct Recorded: Decodable {
        let file: String
        let harness: String
        let cols: Int
        let rows: Int
        let expect: String
    }

    /// A recorded hc paint of `harness`'s composer in `state`.
    private func recorded(_ harness: String, _ state: String) throws -> HCComposerPaint {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hc-paint")
        struct Manifest: Decodable { let paints: [Recorded] }
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: folder.appendingPathComponent("manifest.json"))).paints
        let entry = try XCTUnwrap(manifest.first { $0.harness == harness && $0.expect == state && $0.cols == 80 },
                                  "a recorded \(harness) \(state) paint")
        return HCComposerPaint(bytes: try Data(contentsOf: folder.appendingPathComponent(entry.file)),
                               grid: HCGridSize(columns: UInt16(entry.cols), rows: UInt16(entry.rows)))
    }

    /// The harnesses the typed doorbell rings, by hc's foreground name and c11's terminal type.
    private let harnesses: [(agent: String, type: String)] = [
        ("claude", "claude-code"), ("codex", "codex"), ("grok", "grok"), ("opencode", "opencode"), ("pi", "pi"),
    ]

    private func record(_ status: String?, agent: String, turn: Int64 = 1) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: .running, machineAvailability: .local, pid: 4242,
                         foreground: HCForeground(pid: agentPID, name: agent, argv: [agent]),
                         status: status, statusTimestampMilliseconds: nil, turn: turn, tty: "/dev/ttys042")
    }

    /// A panel with no screen whose agent hc reports in front of ttys042, as after a relaunch.
    private func seat(agent: String = "codex", status: String? = "idle") throws -> Seat {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let seat = Seat(workspace: workspace, panel: panel)
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panel,
            partial: ["mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: agent, argv: [agent])))
        workspace.setDetectedTerminalType(kind, forSurface: panel)
        let pid = agentPID, device = device, born = born
        workspace.mailboxKernel = MailboxAgentForeground.Kernel(
            processInfo: { $0 == pid ? .init(processGroup: pid, terminalForegroundGroup: pid, terminalDevice: device,
                                             isZombie: false, startTime: born) : nil },
            ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
            isCanonical: { _ in false })
        workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        workspace.mailboxJournalSnapshotForTesting = { _ in nil }
        seat.record = record(status, agent: agent)
        // C11H-346: weak, never unowned, and the seat is held until the arrival's composer read lands. That read is
        // an unstructured Task holding the workspace across its off-main classify; its late look must neither run
        // inside the next test nor call a freed seat (the runner aborts, "exited with code 5").
        workspace.mailboxHeadlessRecordForTesting = { [weak seat] _ in seat?.record }
        workspace.mailboxIsHeadlessForTesting = { [weak seat] _ in seat?.headless ?? true }
        workspace.mailboxDoorbellScreenForTesting = { [weak seat] _ in seat?.screen ?? .empty }
        workspace.mailboxHeadlessPaintForTesting = { [weak seat] _ in
            guard let seat else { return .failure(.unavailable) }
            seat.reads += 1; return seat.paint
        }
        workspace.onMailboxDoorbellRingForTesting = { [weak seat] in if $0 == panel { seat?.rings += 1 } }
        // Held in a box and let go inside the block, on main (`HCTeardownHold`).
        let hold = HCTeardownHold(seat)
        addTeardownBlock { @MainActor [hold] in
            let deadline = Date().addingTimeInterval(5)
            while hold.value?.workspace.mailboxHeadlessComposerReadInFlightForTesting == true, Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotEqual(hold.value?.workspace.mailboxHeadlessComposerReadInFlightForTesting, true,
                              "the arrival's composer read landed")
            hold.release()
        }
        workspace.noteHCLocalMailbox(panelId: panel, record: seat.record)
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel)?.ownsTerminal, true)
        return seat
    }

    private func mail(_ seat: Seat, _ id: String) {
        _ = seat.workspace.deliverOrBufferMailboxStdin(surfaceId: seat.panel, envelopeId: id,
                                                       recipientName: "c11-captain", block: "<c11-msg/>")
    }

    private func until(_ what: String, _ done: @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(done(), what, file: file, line: line)
    }

    /// A hold the buffered look decides is logged through the dispatcher a test workspace lacks; the next arrival
    /// decides on the same (fresh) read and records it.
    private func heldAs(_ seat: Seat, _ code: String, _ id: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
        mail(seat, id + "1")
        await until("read once", { seat.reads >= 1 }, file: file, line: line)
        try? await Task.sleep(nanoseconds: 50_000_000)
        mail(seat, id + "2")
        await until("held as \(code)", { seat.wait == code }, file: file, line: line)
    }

    /// Acceptance 1: every typed-doorbell harness, idle since c11 started, its dim suggestion or placeholder
    /// showing: the composer is read and the doorbell rings.
    func testAnIdleAgentWithNoScreenIsReadAndRungForEveryHarness() async throws {
        for (agent, type) in harnesses {
            let seat = try seat(agent: agent)
            seat.paint = .success(try recorded(type, "suggestion"))
            mail(seat, "01M7HEADLESSRING000000000\(agent.count)")
            await until("\(agent): read and rung") { seat.rings == 1 }
        }
    }

    /// Acceptance 2: text in the composer is a draft for every harness; never rung.
    func testADraftHoldsForEveryHarness() async throws {
        for (agent, type) in harnesses {
            let seat = try seat(agent: agent)
            seat.paint = .success(try recorded(type, "draft"))
            await heldAs(seat, "draft", "01M7HEADLESSDRAFT0000000\(agent.count)")
            XCTAssertEqual(seat.rings, 0, agent)
        }
    }

    func testAChooserOnScreenHoldsAsADialog() async throws {
        let seat = try seat(agent: "claude")
        seat.paint = .success(try recorded("claude-code", "dialog"))
        await heldAs(seat, "dialog", "01M7HEADLESSDIALOG000000")
        XCTAssertEqual(seat.rings, 0)
    }

    /// A busy agent is held by its turn; when hc reports it idle, its composer is read and the mail rings.
    func testABusyAgentIsHeldThroughItsTurnThenReadAndRung() async throws {
        let seat = try seat(status: "working")
        seat.paint = .success(try recorded("codex", "suggestion"))
        mail(seat, "01M7HEADLESSBUSY0000000001")
        XCTAssertEqual(seat.rings, 0)
        seat.record = record("idle", agent: "codex", turn: 2)
        seat.workspace.noteHCLocalMailbox(panelId: seat.panel, record: seat.record)
        await until("read and rung once idle") { seat.rings == 1 }
    }

    /// No status from hc: held as `headless_status`, and nothing is read.
    func testAnAgentWithNoStatusIsHeldUnderItsOwnName() throws {
        let seat = try seat(status: nil)
        mail(seat, "01M7HEADLESSNOSTATUS000001")
        XCTAssertEqual(seat.rings, 0)
        XCTAssertEqual(seat.wait, "headless_status")
    }

    /// A read that fails holds as `composer_unread`, never typed.
    func testAFailedReadHoldsAsComposerUnread() async throws {
        let seat = try seat()
        seat.paint = .failure(.timedOut)
        await heldAs(seat, "composer_unread", "01M7HEADLESSUNREAD0000000")
        XCTAssertEqual(seat.rings, 0)
    }

    /// The same panel, once shown, is read on screen and rung.
    func testAPanelThatIsShownRingsOnTheNextLook() async throws {
        let seat = try seat()
        seat.paint = .success(try recorded("codex", "draft"))
        await heldAs(seat, "draft", "01M7HEADLESSSHOWN00000000")
        seat.headless = false
        mail(seat, "01M7HEADLESSSHOWN000000003")
        XCTAssertEqual(seat.rings, 1, "a screen that reads empty: the doorbell rings")
    }
}

// C11H-363: file drops onto a terminal on another machine, the titlebar
// folder for a directory one reported, and Kitty media on hc surfaces.
@MainActor
final class HCRemoteFileDropTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7")
    private let panel = UUID()
    private let workspaceID = UUID()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func file(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data("canary".utf8).write(to: url)
        return url
    }

    private var target: HCRemoteFileDropFlow.Target {
        HCRemoteFileDropFlow.Target(key: key, machine: "studio", panelID: panel, workspaceID: workspaceID)
    }

    @MainActor private final class Effects {
        var asked: [([URL], String)] = []
        var answers: [@MainActor (Bool) -> Void] = []
        var sent: [[URL]] = []
        var pasted: [String] = []
        var unsent: [HCRemoteFileDropFlow.Outcome] = []
        var records: [C11AuditRecord] = []
        var showable = true
        var bound = true
    }

    private func flow(_ e: Effects,
                      result: Result<String, HCRemoteFileDrop.Failure> = .success("/remote/files/t7/a.txt"),
                      audit: ((C11AuditRecord) -> Void)? = nil) -> HCRemoteFileDropFlow {
        let key = key
        return HCRemoteFileDropFlow(
            ask: { urls, machine, answer in
                e.asked.append((urls, machine))
                guard e.showable else { return false }
                e.answers.append(answer)
                return true
            },
            send: { urls, _ in
                await MainActor.run { e.sent.append(urls) }
                return result
            },
            stillBound: { candidate in e.bound && candidate == key },
            paste: { e.pasted.append($0) },
            unsent: { e.unsent.append($0) },
            audit: { record in e.records.append(record); audit?(record) })
    }

    private func settle(_ e: Effects, records count: Int) async -> Bool {
        for _ in 0..<200 {
            if e.records.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testAFileDraggedFromInsideC11OntoARemoteTerminalIsRefusedBeforeAnyRead() throws {
        let canary = try file("id_ed25519")
        XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [canary], targetIsRemote: true, startedInsideC11: true), .refuse)
        XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [canary, URL(string: "https://example.com")!],
                                                     targetIsRemote: true, startedInsideC11: true), .refuse,
                       "a file among other URLs is still refused")
        XCTAssertTrue(TerminalFileDropPolicy.refusesDrag(hasFileURL: true, targetIsRemote: true, startedInsideC11: true),
                      "the cursor shows the refusal before the drop")

        let e = Effects()
        flow(e).refuseInApp([canary], target: target)
        XCTAssertTrue(e.asked.isEmpty, "nothing is asked")
        XCTAssertTrue(e.sent.isEmpty, "nothing is read or sent")
        XCTAssertTrue(e.pasted.isEmpty)
        XCTAssertEqual(e.unsent, [.refused("in_app_source")])
        XCTAssertEqual(e.records.count, 1)
        let record = try XCTUnwrap(e.records.first)
        XCTAssertEqual(record.kind, "file_transfer")
        XCTAssertEqual(record.outcome, "refused")
        XCTAssertEqual(record.code, "in_app_source")
        XCTAssertEqual(record.machine, "studio")
        XCTAssertEqual(record.panel, panel.uuidString)
        XCTAssertEqual(record.path, canary.path)
    }

    func testDropsOnALocalTerminalAreUnchanged() throws {
        let local = try file("notes.txt")
        for inside in [true, false] {
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [local], targetIsRemote: false, startedInsideC11: inside), .paste)
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [], targetIsRemote: false, startedInsideC11: inside), .paste)
            XCTAssertFalse(TerminalFileDropPolicy.refusesDrag(hasFileURL: true, targetIsRemote: false, startedInsideC11: inside))
        }
        // Text and web links onto a remote terminal still paste, from anywhere.
        let link = URL(string: "https://example.com/page")!
        for inside in [true, false] {
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [], targetIsRemote: true, startedInsideC11: inside), .paste)
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [link], targetIsRemote: true, startedInsideC11: inside), .paste)
        }
        XCTAssertFalse(TerminalFileDropPolicy.refusesDrag(hasFileURL: false, targetIsRemote: true, startedInsideC11: true))
    }

    func testAFinderDropOnALinkedTerminalWaitsForSendThenSendsAndAuditsOnce() async throws {
        let a = try file("a.txt")
        XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [a], targetIsRemote: true, startedInsideC11: false), .ask([a]))
        XCTAssertFalse(TerminalFileDropPolicy.refusesDrag(hasFileURL: true, targetIsRemote: true, startedInsideC11: false))

        let e = Effects()
        flow(e).start([a], target: target)
        XCTAssertEqual(e.asked.count, 1)
        XCTAssertEqual(e.asked.first?.1, "studio")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(e.sent.isEmpty, "nothing is read or sent before the answer")
        XCTAssertTrue(e.records.isEmpty, "the record waits for the outcome")
        XCTAssertTrue(e.pasted.isEmpty)

        try XCTUnwrap(e.answers.first)(true)
        let settled = await settle(e, records: 1)
        XCTAssertTrue(settled)
        XCTAssertEqual(e.sent, [[a]])
        XCTAssertEqual(e.pasted, ["/remote/files/t7/a.txt"])
        XCTAssertEqual(e.records.count, 1)
        XCTAssertEqual(e.records.first?.outcome, "ok")
        XCTAssertNil(e.records.first?.code)
        XCTAssertEqual(e.records.first?.detail, "files=1: a.txt")
        XCTAssertTrue(e.unsent.isEmpty)
    }

    func testCancelSendsNothingAndWritesOneCancelledRecord() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let e = Effects()
        flow(e).start([a, b], target: target)
        try XCTUnwrap(e.answers.first)(false)
        let settled = await settle(e, records: 1)
        XCTAssertTrue(settled)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(e.sent.isEmpty)
        XCTAssertTrue(e.pasted.isEmpty)
        XCTAssertEqual(e.records.map(\.outcome), ["cancelled"])
        XCTAssertEqual(e.records.first?.code, "declined")
        XCTAssertEqual(e.records.first?.detail, "files=2: a.txt, b.txt")
        XCTAssertEqual(e.unsent, [.cancelled])
    }

    func testNoWindowAChangedTerminalOrAFailedSendSendsNothingAndAuditsOnce() async throws {
        let a = try file("a.txt")

        let hidden = Effects()
        hidden.showable = false
        flow(hidden).start([a], target: target)
        XCTAssertEqual(hidden.records.map(\.code), ["no_window"])
        XCTAssertTrue(hidden.sent.isEmpty)

        let moved = Effects()
        flow(moved).start([a], target: target)
        moved.bound = false
        try XCTUnwrap(moved.answers.first)(true)
        let movedSettled = await settle(moved, records: 1)
        XCTAssertTrue(movedSettled)
        XCTAssertEqual(moved.records.map(\.code), ["target_changed"])
        XCTAssertTrue(moved.sent.isEmpty, "a panel that changed terminal while asking sends nothing")

        let failing = Effects()
        flow(failing, result: .failure(.tooLarge("a.txt"))).start([a], target: target)
        try XCTUnwrap(failing.answers.first)(true)
        let failedSettled = await settle(failing, records: 1)
        XCTAssertTrue(failedSettled)
        XCTAssertEqual(failing.records.map(\.outcome), ["failed"])
        XCTAssertEqual(failing.records.first?.code, "too_large")
        XCTAssertTrue(failing.pasted.isEmpty)

        let keyless = Effects()
        flow(keyless).start([a], target: HCRemoteFileDropFlow.Target(key: nil, machine: "studio",
                                                                      panelID: panel, workspaceID: nil))
        XCTAssertTrue(keyless.asked.isEmpty)
        XCTAssertEqual(keyless.records.map(\.code), ["hc_unavailable"])
    }

    func testTheTransferRecordIsWrittenToTheAuditLog() async throws {
        let a = try file("a.txt")
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        XCTAssertTrue(C11AuditKind.allCases.map(\.rawValue).contains("file_transfer"))
        let e = Effects()
        flow(e, audit: { _ = log.append($0) }).start([a], target: target)
        try XCTUnwrap(e.answers.first)(true)
        let settled = await settle(e, records: 1)
        XCTAssertTrue(settled)
        let read = log.read(.init(kind: "file_transfer"))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.via, "drop")
        XCTAssertEqual(read.first?.machine, "studio")
        XCTAssertEqual(read.first?.workspace, workspaceID.uuidString)
    }

    func testARemoteTerminalsDirectoryIsNeverOfferedAsALocalFolder() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let local = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelDirectory(panelId: local, directory: "/Users/demo/project")
        XCTAssertEqual(workspace.localFolderDirectory(), "/Users/demo/project", "a local terminal's folder is offered")

        let remote = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true, machine: .on("studio")))
        XCTAssertEqual(workspace.focusedPanelId, remote.id)
        XCTAssertTrue(workspace.isRemoteTerminalPanel(remote.id))
        workspace.updatePanelDirectory(panelId: remote.id, directory: "/Users/demo/.ssh/id_ed25519")
        XCTAssertNil(workspace.localFolderDirectory(), "a directory another machine reported is never a local folder")
    }

    func testAWorkspaceDirectoryLastTakenFromARemoteTerminalStaysUnoffered() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let local = try XCTUnwrap(workspace.focusedPanelId)
        let remote = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true, machine: .on("studio")))
        workspace.updatePanelDirectory(panelId: remote.id, directory: "/Users/demo/.ssh/id_ed25519")
        XCTAssertEqual(workspace.currentDirectory, "/Users/demo/.ssh/id_ed25519")

        // A local panel with no directory of its own falls back to the
        // workspace's, which still holds the remote report.
        workspace.focusPanel(local)
        XCTAssertEqual(workspace.focusedPanelId, local)
        XCTAssertNil(workspace.localFolderDirectory())

        workspace.updatePanelDirectory(panelId: local, directory: "/Users/demo/project")
        XCTAssertEqual(workspace.localFolderDirectory(), "/Users/demo/project", "its own report replaces it")
    }

    /// C11H-363: the workspace directory's provenance is saved with it. The
    /// terminal that reported it may be closed, so after a relaunch nothing
    /// else could say where the path came from.
    func testARemoteReportStaysUnofferedAfterASaveAndRestore() throws {
        let note = tmp.appendingPathComponent("note.md")
        try "# note\n".write(to: note, atomically: true, encoding: .utf8)
        func roundTrip(_ workspace: Workspace) throws -> Workspace {
            let data = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
            let restored = Workspace()
            restored.restoreSessionSnapshot(try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data))
            return restored
        }

        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let markdown = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: note.path, focus: false))
        let remote = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true, machine: .on("studio")))
        workspace.updatePanelDirectory(panelId: remote.id, directory: "/Users/demo/.ssh/id_ed25519")
        XCTAssertTrue(workspace.closePanel(remote.id, force: true))
        workspace.focusPanel(markdown.id)
        XCTAssertNil(workspace.localFolderDirectory(), "precondition: the remote report is not offered")

        let restored = try roundTrip(workspace)
        XCTAssertEqual(restored.currentDirectory, "/Users/demo/.ssh/id_ed25519")
        XCTAssertNil(restored.localFolderDirectory(), "after a relaunch the remote report is still not offered")

        // Control: a local terminal's report survives the round trip and is offered.
        let localWorkspace = Workspace()
        let localPane = try XCTUnwrap(localWorkspace.bonsplitController.allPaneIds.first)
        let terminal = try XCTUnwrap(localWorkspace.focusedPanelId)
        let localNote = try XCTUnwrap(localWorkspace.newMarkdownPanel(inPane: localPane, filePath: note.path, focus: false))
        localWorkspace.updatePanelDirectory(panelId: terminal, directory: "/Users/demo/project")
        localWorkspace.focusPanel(localNote.id)
        XCTAssertEqual(localWorkspace.localFolderDirectory(), "/Users/demo/project")
        XCTAssertEqual(try roundTrip(localWorkspace).localFolderDirectory(), "/Users/demo/project")
    }

    func testAnHCSurfaceTakesOnlyDirectKittyImagesAndAnExecSurfaceResetsIt() {
        var config = ghostty_surface_config_s()
        HCSurfaceNativeIO.apply(to: &config, hcInput: UnsafeMutableRawPointer(bitPattern: 0x1))
        XCTAssertEqual(config.io_mode, GHOSTTY_SURFACE_IO_MANUAL)
        XCTAssertNotNil(config.io_write_cb)
        XCTAssertTrue(config.kitty_graphics_direct_only, "an hc surface refuses Kitty path media")

        // A split inherits its source's native config; an exec surface resets it.
        var split = config
        HCSurfaceNativeIO.apply(to: &split, hcInput: nil)
        XCTAssertEqual(split.io_mode, GHOSTTY_SURFACE_IO_EXEC)
        XCTAssertNil(split.io_write_cb)
        XCTAssertNil(split.io_write_userdata)
        XCTAssertFalse(split.kitty_graphics_direct_only, "a local exec surface keeps Ghostty's own behaviour")
    }
}
