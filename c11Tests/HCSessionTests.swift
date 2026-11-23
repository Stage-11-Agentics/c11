import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class HCTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor HCTestReadClock {
    private(set) var start: UInt64 = 0
    func begin() { start = HCMonotonic.now }
}

private struct HCTestVerifier: HCPeerVerifying {
    let log: HCTestLog
    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer {
        log.add("verify:\(peer.pid)")
        guard peer.coreID == "core" else { throw HCUnavailableReason.foreignSession }
        return HCVerifiedPeer(identity: HCBuildIdentity(pin: configuration.pin, executablePath: configuration.executableURL.path,
            fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: peer.pid, startTimeMicroseconds: UInt64(peer.pid) * 100),
            coreID: peer.coreID, protocolGeneration: 1), isPinnedBuild: peer.version == configuration.pin.version)
    }
    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {
        guard coreID == "core" else { throw HCUnavailableReason.foreignSession }
        log.add("owned-state")
    }
}

private struct HCTestLauncher: HCCoreLaunching {
    let log: HCTestLog
    var expectedDeadline: UInt64? = nil
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        log.add("start")
        if let expectedDeadline { XCTAssertEqual(deadlineUptimeNanoseconds, expectedDeadline) }
        XCTAssertGreaterThan(deadlineUptimeNanoseconds, HCMonotonic.now)
        XCTAssertLessThanOrEqual(deadlineUptimeNanoseconds - HCMonotonic.now, UInt64(HCLimits.recoverySeconds * 1_000_000_000))
        return HCLaunchLimitReport(beforeSoft: 256, afterSoft: 8192, hard: 8192, kernelCap: 8192)
    }
}

private actor HCTestProcesses: HCProcessObserving {
    let log: HCTestLog
    var exited: Set<Int32> = []
    init(log: HCTestLog) { self.log = log }
    func markExited(_ pid: Int32) { exited.insert(pid) }
    func currentPID() -> Int32 {
        var pid: Int32 = 1
        while exited.contains(pid) { pid += 1 }
        return pid
    }
    func hasExited(_ process: HCProcessIdentity) async -> Bool {
        log.add("exit-proof:\(process.pid):\(exited.contains(process.pid))")
        return exited.contains(process.pid)
    }
}

private final class HCTestConnection: HCConnection, @unchecked Sendable {
    let generation: UInt64
    let peer: HCPeerEvidence
    let verification: HCVerifiedPeer
    let log: HCTestLog
    let handler: @Sendable (HCRPCRequest) async throws -> HCJSONValue
    init(generation: UInt64, peer: HCPeerEvidence, verification: HCVerifiedPeer, log: HCTestLog,
         handler: @escaping @Sendable (HCRPCRequest) async throws -> HCJSONValue) {
        self.generation = generation; self.peer = peer; self.verification = verification; self.log = log; self.handler = handler
    }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue { log.add(request.method); return try await handler(request) }
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        log.add("register")
        return HCTestChannel(channelID: channel, connectionGeneration: generation, attachmentGeneration: attachmentGeneration, sink: sink, log: log)
    }
    func close(reason: HCUnavailableReason) { log.add("close") }
}

/// A switch a test flips from outside the code it steers.
private final class HCTestSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ on: Bool = true) { lock.lock(); value = on; lock.unlock() }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct HCTestFactory: HCConnectionFactory {
    /// C11H-313: while on, no core answers (connect refuses).
    var refuse: HCTestSwitch? = nil
    var beforeConnect: (@Sendable (UInt64) async -> Void)? = nil
    var processes: HCTestProcesses? = nil
    var versions: [Int32: String] = [:]
    let pid: Int32
    let log: HCTestLog
    let handler: @Sendable (HCRPCRequest) async throws -> HCJSONValue
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        if refuse?.isOn == true { log.add("refused"); throw HCUnavailableReason.coreUnreachable }
        let pid = await processes?.currentPID() ?? self.pid
        log.add("connect:\(pid)")
        if let beforeConnect { await beforeConnect(request.generation) }
        let peer = HCPeerEvidence(uid: 1, pid: pid, statusPID: pid, coreID: "core", version: versions[pid] ?? request.configuration.pin.version,
                                  protocolGeneration: 1, methods: [], features: [])
        let verification = try await verify(peer)
        return HCTestConnection(generation: request.generation, peer: peer, verification: verification, log: log, handler: handler)
    }
}

private final class HCTestInventoryObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var handler: (@Sendable (HCInventorySnapshot) -> Void)?
    func set(queue: DispatchQueue?, handler: (@Sendable (HCInventorySnapshot) -> Void)?) {
        lock.lock(); self.queue = queue; self.handler = handler; lock.unlock()
    }
    func deliver(_ snapshot: HCInventorySnapshot) {
        lock.lock(); let queue = self.queue, handler = self.handler; lock.unlock()
        queue?.async { handler?(snapshot) }
    }
}

private actor HCTestInventory: HCInventorySource {
    /// C11H-332: the machine list install reviews, optionally held until released.
    var installMachineList: HCJSONValue?
    private var holdMachineList = false
    private var heldReaders: [CheckedContinuation<Void, Never>] = []
    var isHoldingMachineList: Bool { !heldReaders.isEmpty }
    func setInstallMachineList(_ value: HCJSONValue?, hold: Bool = false) { installMachineList = value; holdMachineList = hold }
    func releaseMachineList() { holdMachineList = false; let readers = heldReaders; heldReaders = []; readers.forEach { $0.resume() } }
    func lastMachineList() async -> HCJSONValue? {
        if holdMachineList { await withCheckedContinuation { heldReaders.append($0) } }
        return installMachineList
    }
    var generation: UInt64 = 0
    var build: HCBuildIdentity?
    var records: [HCTerminalKey: HCTerminalRecord] = [:]
    var sequence: UInt64 = 1
    var timestampRequests = 0
    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? {
        timestampRequests += 1
        return HCTerminalRecord(key: key, state: .running, machineName: "studio", machineAvailability: .connected,
            status: status, statusTimestampMilliseconds: 2_500, turn: turn)
    }
    func bind(generation: UInt64, build: HCBuildIdentity) { self.generation = generation; self.build = build; lost = false }
    private var catchingUp = false
    private var lost = false
    /// C11H-313: hc is resnapshotting. Every read is pending until `caughtUp()`; nothing is pushed.
    func catchUp() { catchingUp = true }
    func caughtUp() { catchingUp = false; sequence += 1; changed() }
    /// C11H-313: the connection drops, and hc's inventory says so (pushed, as its stream does).
    func loseConnection() { lost = true; changed() }
    /// C11H-313: hc drops a finished terminal's record.
    func remove(address: String) {
        records.removeValue(forKey: HCTerminalKey(owningCoreID: "core", localAddress: Self.local(address)))
        sequence += 1
        changed()
    }
    /// `machine`: the terminal was run `on` that machine, and hc lists it there
    /// (C11H-359: c11 finds a panel's terminal by its labels only on its own
    /// machine). Its key keeps this fake's one core id.
    func insert(panel: UUID, creation: UUID, address: String = "t1", machine: String? = nil) {
        let key = HCTerminalKey(owningCoreID: "core", localAddress: address)
        records[key] = HCTerminalRecord(key: key, state: .running,
            labels: ["c11.panel": panel.uuidString, "c11.creation": creation.uuidString],
            machineName: machine, machineAvailability: machine == nil ? .local : .connected, pid: 100)
        sequence += 1
        changed()
    }
    /// The terminal at `address` exits (killed, or its shell ended); its labels stay.
    func finish(address: String) {
        let key = HCTerminalKey(owningCoreID: "core", localAddress: Self.local(address))
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .finished, labels: record.labels, machineName: record.machineName,
                                        machineAvailability: record.machineAvailability, endReason: "killed")
        sequence += 1
        changed()
    }
    /// `studio/t3` addresses the terminal this fake keys as `t3`.
    private static func local(_ address: String) -> String { address.split(separator: "/").last.map(String.init) ?? address }
    /// The terminal at `address` was on another machine, has finished, and that machine is offline now.
    func finishOffline(address: String) {
        let key = HCTerminalKey(owningCoreID: "core", localAddress: address)
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .finished, labels: record.labels, machineName: "studio",
                                        machineAvailability: .disconnected, endReason: "exited")
        sequence += 1
        changed()
    }
    func insertFinished(panel: UUID, address: String, reason: String) {
        let key = HCTerminalKey(owningCoreID: "core", localAddress: address)
        records[key] = HCTerminalRecord(key: key, state: .finished, labels: ["c11.panel": panel.uuidString], endReason: reason)
        sequence += 1
    }
    private nonisolated let observer = HCTestInventoryObserver()
    private var pushes = false
    /// From now on every change is pushed to the observer, as hc's event stream does.
    func pushChanges() { pushes = true }
    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        observer.set(queue: queue, handler: handler)
        return HCObservation { [observer] in observer.set(queue: nil, handler: nil) }
    }
    private func current() -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: sequence)
        let readiness: HCReadiness = lost ? .pending(.connectionLost) : catchingUp ? .pending(.inventoryPending) : .ready(revision)
        return HCInventorySnapshot(readiness: readiness, revision: revision, records: records, buildIdentity: build)
    }
    private func changed() { if pushes { observer.deliver(current()) } }
    func snapshot() async -> HCInventorySnapshot { current() }
    func refresh() async -> HCInventorySnapshot { await snapshot() }
}

final class HCSessionTests: XCTestCase {
    /// C11H-274: a session review publishes its unusable links process-wide;
    /// every test starts from none.
    override func tearDown() async throws {
        await MainActor.run { HCMachineDirectory.shared.clearUnusable() }
        try await super.tearDown()
    }

    func testRemoteTimestampEnrichmentUsesInstalledInventoryAndNeverAutostarts() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let factory = HCTestFactory(pid: 1, log: log) { _ in throw HCUnavailableReason.malformedResponse }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7")
        let unavailable = await session.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 4, connectionGeneration: 1)
        XCTAssertNil(unavailable)
        XCTAssertTrue(log.read().isEmpty, "status enrichment must not connect or launch a core")
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let current = await session.snapshot()
        let result = await session.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 4,
            connectionGeneration: current.revision.connectionGeneration)
        XCTAssertEqual(result?.key, key)
        XCTAssertEqual(result?.status, "done")
        XCTAssertEqual(result?.turn, 4)
        XCTAssertEqual(result?.statusTimestampMilliseconds, 2_500)
        let stale = await session.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 4,
            connectionGeneration: current.revision.connectionGeneration + 1)
        XCTAssertNil(stale)
        let requests = await inventory.timestampRequests
        XCTAssertEqual(requests, 1)
    }

    /// C11H-332: every core a session installs passes the folder policy:
    /// a fresh connect, a restore's `connectIfServing`, and a read-only shard
    /// (which only inspects: repair is off). An unsafe answer refuses that
    /// core and closes its connection. Fails with the check removed from
    /// `install`.
    func testEveryInstalledCorePassesTheFolderPolicy() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
            var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
        }
        func session(_ c: HCLaunchConfiguration, log: HCTestLog, readOnly: Bool, safe: Bool, seen: Seen) -> HCManagedSession {
            let inventory = HCTestInventory()
            return HCManagedSession(configuration: c, connections: HCTestFactory(pid: 1, log: log) { _ in throw HCUnavailableReason.malformedResponse },
                verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
                intents: HCCreationIntentStore(directory: c.intentDirectory),
                prepareAttachment: { _, _, _, display in display },
                makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
                readOnly: readOnly,
                checkFolders: { _, repair in seen.add(repair); return safe })
        }
        // A fresh connect, writable and read-only.
        for (readOnly, safe) in [(false, false), (false, true), (true, false), (true, true)] {
            let c = try configuration(), log = HCTestLog(), seen = Seen()
            _ = await session(c, log: log, readOnly: readOnly, safe: safe, seen: seen).resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
            XCTAssertEqual(seen.all.first, !readOnly, "repair is allowed only on a writable shard (readOnly=\(readOnly))")
            XCTAssertEqual(log.read().contains("close"), !safe, "only an unsafe core's connection is closed: \(log.read())")
        }
        // A restore's adoption of a core already serving.
        let base = try configuration()
        let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent("hcsock\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: socketDir) }
        let socket = socketDir.appendingPathComponent("c.sock")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let c = HCLaunchConfiguration(executableURL: base.executableURL, session: base.session, socketURL: socket,
                                      stateDirectory: base.stateDirectory, intentDirectory: base.intentDirectory,
                                      environment: base.environment, pin: base.pin)
        for safe in [false, true] {
            let log = HCTestLog(), seen = Seen()
            let adopted = await session(c, log: log, readOnly: false, safe: safe, seen: seen).connectIfServing()
            XCTAssertEqual(seen.all, [true], "restore checks the folders of the core it adopts")
            XCTAssertEqual(adopted, safe, "an unsafe restored core is not adopted")
            XCTAssertEqual(log.read().contains("close"), !safe, "and its connection is closed: \(log.read())")
        }
    }

    private func unusableLinkList() throws -> (HCJSONValue, URL) {
        // A via outside c11's folders: never migrated, so the link is unusable.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hclinks\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let via = home.appendingPathComponent("handmade-via.sh")
        try "#!/bin/sh\nexec /usr/bin/ssh -T -- me@studio 'herdr-core connect'\n".write(to: via, atomically: true, encoding: .utf8)
        let list: HCJSONValue = .object(["machines": .array([.object(["name": .string("studio"), "state": .string("connected"),
                                                                         "target": .string(via.path)])])])
        return (list, home)
    }

    private func linkSession(_ c: HCLaunchConfiguration, log: HCTestLog, inventory: HCTestInventory, home: URL) -> HCManagedSession {
        HCManagedSession(configuration: c, connections: HCTestFactory(pid: 1, log: log) { _ in throw HCUnavailableReason.malformedResponse },
            verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            checkFolders: { _, _ in true }, storedLinks: HCStoredLinkReview(home: home, linkScript: nil))
    }

    private func remoteCreate() -> HCCreateRequest {
        HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), creationID: UUID(), argv: ["/bin/zsh"], machine: "studio")
    }

    /// C11H-332: the first creation after a restart, which itself brings the
    /// core up, is refused on an unusable stored link: install reviews the
    /// core's machine list before the runtime is published, and the creation
    /// checks again right before claim. Fails with either the install-time
    /// review or the pre-claim check removed.
    func testTheFirstColdCreationOnAnUnusableLinkIsRefused() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let (list, home) = try unusableLinkList()
        await inventory.setInstallMachineList(list)
        let session = linkSession(c, log: log, inventory: inventory, home: home)
        guard case .rejectedBeforeTransmission(.pinMismatch) = await session.create(remoteCreate()) else {
            return XCTFail("a terminal was opened on an unusable link: \(log.read())")
        }
        let unusable = await session.unusableMachines
        XCTAssertEqual(unusable, ["studio"])
        XCTAssertTrue(HCLinkedMachines.shared.unusable().contains("studio"),
                      "C11H-274: the review reaches the set --on, the picker and the File menu read")
        XCTAssertFalse(log.read().contains("terminal.run"), "nothing was sent: \(log.read())")
    }

    /// C11H-332: while install holds the machine list it reviews, the core is
    /// not published (no ready snapshot) and a creation that arrives waits;
    /// once the review lands, that creation is refused. Fails if install
    /// publishes the runtime before the review.
    func testAHeldInstallTimeMachineListKeepsTheCoreUnpublished() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let (list, home) = try unusableLinkList()
        await inventory.setInstallMachineList(list, hold: true)
        let session = linkSession(c, log: log, inventory: inventory, home: home)
        let created = Task { await session.create(self.remoteCreate()) }
        var held = false
        for _ in 0..<200 where !held { held = await inventory.isHoldingMachineList; if !held { try await Task.sleep(nanoseconds: 10_000_000) } }
        XCTAssertTrue(held, "install reached the review")
        let whileHeld = await session.snapshot()
        if case .ready = whileHeld.readiness { XCTFail("the core was published before its stored links were reviewed") }
        await inventory.releaseMachineList()
        guard case .rejectedBeforeTransmission(.pinMismatch) = await created.value else {
            return XCTFail("the waiting creation was not refused: \(log.read())")
        }
        let after = await session.snapshot()
        guard case .ready = after.readiness else { return XCTFail("published after the review: \(after.readiness)") }
    }

    /// C11H-332: an unusable link whose migration ran the link script (here
    /// `pairing_unowned`, exit 5) is not migrated again at the next poll, even
    /// though the script's own temporary file changed the folder: it runs
    /// again only after a later change to the via or its folder, or 30 s.
    func testAnUnusableLinkIsNotMigratedAgainEveryPoll() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hcpoll\(UUID().uuidString.prefix(6))", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let via = vias.appendingPathComponent("atlas-via-c11-s1.sh")
        try "#!/bin/sh\nexec /usr/bin/ssh -T -- me@studio 'herdr-core connect'\n".write(to: via, atomically: true, encoding: .utf8)
        let script = vias.appendingPathComponent("link.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        // Like the real script, each run creates and removes a temporary file
        // beside the via, which changes the folder's modification time.
        let runner = CountingRunner(status: 5, touching: vias)
        let session = HCManagedSession(configuration: c, connections: HCTestFactory(pid: 1, log: log) { _ in throw HCUnavailableReason.malformedResponse },
            verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            checkFolders: { _, _ in true }, storedLinks: HCStoredLinkReview(home: home, linkScript: script, runner: runner))
        let list: HCJSONValue = .object(["machines": .array([.object(["name": .string("studio"), "target": .string(via.path)])])])
        await session.reviewStoredLinks(list, core: core(1))
        await session.reviewStoredLinks(list, core: core(1))
        let unusable = await session.unusableMachines
        XCTAssertEqual(unusable, ["studio"])
        XCTAssertEqual(runner.calls, 1, "the second poll did not run the link script again")
        try "#!/bin/sh\nexec /usr/bin/ssh -T -- me@studio 'herdr-core connect' # edited\n".write(to: via, atomically: false, encoding: .utf8)
        await session.reviewStoredLinks(list, core: core(1))
        XCTAssertEqual(runner.calls, 2, "a changed via is tried again at once")
    }

    /// C11H-365 (L10, N13): `c11 show`'s program and screenshot calls are
    /// refused by c11 itself, before hc is asked, on a machine c11 won't use.
    private func assertShowRunsNothing(on machine: String, session: HCManagedSession,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        let calls: [(String, [String: HCJSONValue])] = [
            // Exactly what `c11 show` sends (ShowExecGate admits both).
            ("machine.exec", ["argv": .array(["stat", "-L", "-f", "%HT|%z|%Fm", "--", "/tmp/x"].map { .string($0) }),
                              "on": .string(machine), "timeout": .number(5)]),
            ("file.write", ["path": .string(ShowShots.hostRelativePath("00000000-0000-4000-8000-000000000000.png")),
                            "on": .string(machine), "data": .string("AA==")]),
        ]
        for (method, params) in calls {
            do {
                _ = try await session.relayRequest(method, params: params, seconds: 5)
                XCTFail("\(method) ran on \(machine)", file: file, line: line)
            } catch let reason as HCUnavailableReason {
                XCTAssertEqual(reason, .pinMismatch, "\(method) must be refused by c11, not tried", file: file, line: line)
            } catch {
                XCTFail("\(method) reached hc: \(error)", file: file, line: line)
            }
        }
    }

    /// C11H-365 (L10): on an unusable link, `c11 show`'s viewer runs nothing
    /// and writes nothing there.
    func testShowRunsNothingOnAnUnusableMachine() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let (list, home) = try unusableLinkList()
        await inventory.setInstallMachineList(list)
        let session = linkSession(c, log: log, inventory: inventory, home: home)
        _ = await session.create(remoteCreate())   // brings the core up and reviews the list
        let unusable = await session.unusableMachines
        XCTAssertEqual(unusable, ["studio"])
        await assertShowRunsNothing(on: "studio", session: session)
        XCTAssertFalse(log.read().contains("machine.exec"), "\(log.read())")
    }

    /// C11H-365 (N13): a pinless via in c11's folder, a link script, and a
    /// runner that migrates it the way the real script does (the via is
    /// rewritten pinned and forwarding nothing, stdout `migrated`).
    private func migratingLink(state: String) throws -> (list: HCJSONValue, home: URL, script: URL, runner: MigratingRunner, via: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hcmig\(UUID().uuidString.prefix(6))", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let via = vias.appendingPathComponent("atlas-via.sh")
        try "#!/bin/sh\nexec /usr/bin/ssh -T -- me@studio 'herdr-core connect'\n".write(to: via, atomically: true, encoding: .utf8)
        let script = vias.appendingPathComponent("link.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        let pinned = "#!/bin/sh\nexec /usr/bin/ssh -T " + HCMachineSetup.sshForwardingOff.joined(separator: " ")
            + " -- me@studio 'sha256=" + String(repeating: "a", count: 64) + " /Users/me/.local/share/c11/hc/x/herdr-core connect'\n"
        let list: HCJSONValue = .object(["machines": .array([.object(["name": .string("studio"), "state": .string(state),
                                                                         "target": .string(via.path)])])])
        return (list, home, script, MigratingRunner(via: via, pinned: pinned), via)
    }

    /// The identity `HCTestVerifier` gives the core `HCTestFactory(pid:)` serves.
    private func core(_ pid: Int32) -> HCProcessIdentity {
        HCProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(pid) * 100)
    }

    /// C11H-365 (N13): the held and released records `c`'s sessions wrote, in order.
    private func redialRecords(_ c: HCLaunchConfiguration) -> [C11AuditRecord] {
        C11AuditLog.shared.flush()
        return C11AuditLog.shared.read().filter { $0.kind == "link" && $0.code == "redial_pending" && $0.session == c.session }
    }

    private func migratingSession(_ c: HCLaunchConfiguration, pid: Int32 = 1, log: HCTestLog, inventory: HCTestInventory,
                                  home: URL, script: URL, runner: MigratingRunner) -> HCManagedSession {
        HCManagedSession(configuration: c, connections: HCTestFactory(pid: pid, log: log) { _ in throw HCUnavailableReason.malformedResponse },
            verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            checkFolders: { _, _ in true }, storedLinks: HCStoredLinkReview(home: home, linkScript: script, runner: runner))
    }

    /// C11H-365 (N13): migrating a link rewrites its via, but hc keeps the
    /// line it already dialed through the old, pinless via. While that line
    /// is up, no terminal opens on the machine and `c11 show` runs nothing
    /// there; once hc reports the line down, any later dial reads the pinned
    /// via, and the machine is usable again. Fails with the hold removed.
    func testALinkMigratedWhileItsLineIsUpOpensNothingUntilTheLineRedials() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let link = try migratingLink(state: "connected")
        await inventory.setInstallMachineList(link.list)
        let session = migratingSession(c, log: log, inventory: inventory, home: link.home, script: link.script, runner: link.runner)
        guard case .rejectedBeforeTransmission(.pinMismatch) = await session.create(remoteCreate()) else {
            return XCTFail("a terminal was opened over a line dialed before the migration: \(log.read())")
        }
        XCTAssertEqual(link.runner.calls, 1, "the via was migrated")
        let held = await session.redialPendingMachines, unusable = await session.unusableMachines
        XCTAssertEqual(held, ["studio"])
        XCTAssertEqual(unusable, [], "a migrated link is not unusable, only held")
        XCTAssertFalse(log.read().contains("terminal.run"), "nothing was sent: \(log.read())")
        await assertShowRunsNothing(on: "studio", session: session)

        // The line drops: the next dial reads the migrated via.
        let down: HCJSONValue = .object(["machines": .array([.object(["name": .string("studio"), "state": .string("disconnected"),
                                                                         "target": .string(link.via.path)])])])
        await session.reviewStoredLinks(down, core: core(1))
        await session.reviewStoredLinks(link.list, core: core(1))
        let released = await session.redialPendingMachines
        XCTAssertEqual(released, [], "a redialed line is a pinned one")
        let usable = await session.holdsCreations(on: "studio")
        XCTAssertFalse(usable)
    }

    /// C11H-365 (N13): the hold outlives a c11 restart. A quit leaves hc's
    /// core and its lines up, so a new session over the same folder, whose
    /// review now finds the via already pinned, still opens nothing and runs
    /// nothing on the machine while that core reports the old line up. It
    /// releases the hold once the line drops. Each step is audited once.
    /// Fails with the hold kept in memory only, or either record removed.
    func testAHeldLinkStaysHeldAcrossACRestartUntilItsLineDrops() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let link = try migratingLink(state: "connected")
        await inventory.setInstallMachineList(link.list)
        let seen = redialRecords(c).count
        let first = migratingSession(c, log: log, inventory: inventory, home: link.home, script: link.script, runner: link.runner)
        guard case .rejectedBeforeTransmission(.pinMismatch) = await first.create(remoteCreate()) else {
            return XCTFail("a terminal was opened over a line dialed before the migration: \(log.read())")
        }
        let held = Array(redialRecords(c).dropFirst(seen))
        XCTAssertEqual(held.map(\.outcome), ["held"], "one held record: \(held)")
        XCTAssertEqual(held.first?.machine, "studio")

        // c11 restarts. hc's core (pid 1) still serves the session and still
        // reports the line it dialed before the migration; the via is pinned now.
        let secondLog = HCTestLog(), secondInventory = HCTestInventory()
        await secondInventory.setInstallMachineList(link.list)
        let second = migratingSession(c, log: secondLog, inventory: secondInventory,
                                      home: link.home, script: link.script, runner: link.runner)
        guard case .rejectedBeforeTransmission(.pinMismatch) = await second.create(remoteCreate()) else {
            return XCTFail("a restart released the hold while the old line is up: \(secondLog.read())")
        }
        XCTAssertEqual(link.runner.calls, 1, "the pinned via was not migrated again")
        XCTAssertFalse(secondLog.read().contains("terminal.run"), "nothing was sent: \(secondLog.read())")
        await assertShowRunsNothing(on: "studio", session: second)
        XCTAssertEqual(redialRecords(c).count - seen, 1, "a restart that keeps the hold writes nothing")

        // The line drops: the hold is released, once, and audited.
        let down: HCJSONValue = .object(["machines": .array([.object(["name": .string("studio"), "state": .string("disconnected"),
                                                                         "target": .string(link.via.path)])])])
        await second.reviewStoredLinks(down, core: core(1))
        await second.reviewStoredLinks(down, core: core(1))
        let records = Array(redialRecords(c).dropFirst(seen))
        XCTAssertEqual(records.map(\.outcome), ["held", "released"], "\(records)")
        XCTAssertEqual(records.last?.machine, "studio")
        let holds = await second.holdsCreations(on: "studio")
        XCTAssertFalse(holds, "a redialed line reads the pinned via")
    }

    /// C11H-365 (N13): a held machine is released when a different hc core
    /// process serves the session (after a Mac restart or a core recovery),
    /// even with its line up: that core dialed every line it holds through
    /// the pinned via. The release is audited. Fails with the core-process
    /// release removed.
    func testAHeldLinkIsReleasedWhenAnotherCoreProcessServes() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let link = try migratingLink(state: "connected")
        await inventory.setInstallMachineList(link.list)
        let seen = redialRecords(c).count
        let first = migratingSession(c, log: log, inventory: inventory, home: link.home, script: link.script, runner: link.runner)
        guard case .rejectedBeforeTransmission(.pinMismatch) = await first.create(remoteCreate()) else {
            return XCTFail("the migrated link was not held: \(log.read())")
        }

        // c11 restarts on a new core process (pid 2) whose line to studio is up.
        let nextLog = HCTestLog(), nextInventory = HCTestInventory()
        await nextInventory.setInstallMachineList(link.list)
        let next = migratingSession(c, pid: 2, log: nextLog, inventory: nextInventory,
                                    home: link.home, script: link.script, runner: link.runner)
        _ = await next.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))   // brings core 2 up and reviews the list
        XCTAssertTrue(nextLog.read().contains("connect:2"), "the new core was installed: \(nextLog.read())")
        let holds = await next.holdsCreations(on: "studio")
        XCTAssertFalse(holds, "a newer core's lines read the pinned via")
        let records = Array(redialRecords(c).dropFirst(seen))
        XCTAssertEqual(records.map(\.outcome), ["held", "released"], "\(records)")
        XCTAssertEqual(records.last?.machine, "studio")
    }

    /// C11H-365 (N13): a link migrated while hc holds no line to it is used at
    /// once: its first dial reads the migrated via.
    func testALinkMigratedWhileItsLineIsDownIsNotHeld() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let link = try migratingLink(state: "disconnected")
        let session = migratingSession(c, log: log, inventory: inventory, home: link.home, script: link.script, runner: link.runner)
        await session.reviewStoredLinks(link.list, core: core(1))
        XCTAssertEqual(link.runner.calls, 1, "the via was migrated")
        let held = await session.redialPendingMachines
        XCTAssertEqual(held, [])
    }

    /// C11H-332: a non-current serving core whose folders fail the policy
    /// gets no recovery RPC: no `server.restart`, its connection closed.
    func testNoRecoveryReachesACoreWhoseFoldersFailThePolicy() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let factory = HCTestFactory(versions: [1: "foreign"], pid: 1, log: log) { request in
            XCTFail("no RPC may reach it: \(request.method)")
            return .object([:])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            checkFolders: { _, _ in false })
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        XCTAssertFalse(log.read().contains("server.restart"), "\(log.read())")
        XCTAssertTrue(log.read().contains("close"), "its connection is closed: \(log.read())")
    }

    /// C11H-306 repair 1b: a composer read never connects or launches a core; and once a read's attach got no reply,
    /// the same terminal is not attached again on that connection (a silent core cannot fill its budget of
    /// unanswered attaches).
    func testAComposerReadNeverConnectsAndAnUnansweredAttachIsNotRepeated() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let attaches = HCAttachCounter(), late = HCLateReplies()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            if request.method == "terminal.attach" {
                attaches.add()
                late.add(request.lateReply)
                throw HCRPCFailure(reason: .deadlineExceeded, transmission: .possible, remoteCode: nil)
            }
            throw HCUnavailableReason.malformedResponse
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        guard case .failure(.unreachable) = await session.readComposerPaint(key) else { return XCTFail("read with no core") }
        XCTAssertTrue(log.read().isEmpty, "a composer read must not connect or launch a core")
        let panel = UUID()
        await inventory.insert(panel: panel, creation: UUID())
        _ = await session.resolve(HCPanelIdentity(panelID: panel, origin: .fresh))
        guard case .failure(.timedOut) = await session.readComposerPaint(key) else { return XCTFail("the attach timed out") }
        XCTAssertEqual(attaches.count, 1)
        late.last?.expire()     // the engine counts the attach; its mark may land after the read returned
        guard case .failure(.attachUnanswered) = await session.readComposerPaint(key) else {
            return XCTFail("a second read behind an unanswered attach")
        }
        XCTAssertEqual(attaches.count, 1, "no second attach")
    }

    /// C11H-327: the read's unanswered attach is held for as long as the engine counts it, with no time limit.
    /// Past the minute #321 waited, a read still sends no second attach; hc's late reply ends the hold; and so does
    /// a new connection, which takes the old one's whole budget with it. The engine's mark lands after each read
    /// returns here, so the hold does not depend on that order (the real engine marks first: HCTransportTests).
    func testAnUnansweredComposerAttachIsHeldUntilItsLateReplyOrANewConnectionNotForAMinute() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let attaches = HCAttachCounter(), late = HCLateReplies()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            guard request.method == "terminal.attach" else { throw HCUnavailableReason.malformedResponse }
            attaches.add()
            late.add(request.lateReply)
            throw HCRPCFailure(reason: .deadlineExceeded, transmission: .possible, remoteCode: nil)
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let panel = UUID()
        await inventory.insert(panel: panel, creation: UUID())
        _ = await session.resolve(HCPanelIdentity(panelID: panel, origin: .fresh))
        guard case .failure(.timedOut) = await session.readComposerPaint(key) else { return XCTFail("the attach timed out") }
        XCTAssertEqual(attaches.count, 1)
        late.last?.expire()     // the engine counts the attach

        let pastAMinute: Result<HCComposerPaint, HCComposerReadFailure>
        do {
            HCMonotonic.advancedForTesting = 61_000_000_000
            defer { HCMonotonic.advancedForTesting = 0 }
            pastAMinute = await session.readComposerPaint(key)
        }
        guard case .failure(.attachUnanswered) = pastAMinute else {
            return XCTFail("a minute on, the first attach is still unanswered: \(pastAMinute)")
        }
        XCTAssertEqual(attaches.count, 1, "no second attach while the engine still counts the first")

        late.last?.settle()     // hc's late reply: the engine takes the attach out of its budget
        guard case .failure(.timedOut) = await session.readComposerPaint(key) else { return XCTFail("the read attaches again") }
        XCTAssertEqual(attaches.count, 2, "after the late reply, one new attach")
        late.last?.expire()
        guard case .failure(.attachUnanswered) = await session.readComposerPaint(key) else {
            return XCTFail("and that one is held in turn")
        }

        await inventory.loseConnection()
        _ = await session.snapshot()        // the session sees the loss and retires the connection
        _ = await session.resolve(HCPanelIdentity(panelID: panel, origin: .fresh))
        guard case .failure(.timedOut) = await session.readComposerPaint(key) else { return XCTFail("a new connection reads") }
        XCTAssertEqual(attaches.count, 3, "a new connection's budget is empty: the old mark counts nothing")
    }

    private func configuration(shard: Int = 0) throws -> HCLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hc\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        // Home must be short enough for the production socket path; intent IO is
        // redirected to this per-test directory without changing the launch policy.
        let c = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil, shard: shard, inherited: [:])
        return HCLaunchConfiguration(executableURL: c.executableURL, session: c.session, socketURL: c.socketURL,
                                     stateDirectory: c.stateDirectory, intentDirectory: root.appendingPathComponent("intents"), environment: c.environment, pin: c.pin)
    }

    private func pairingRegistrar(session: String) throws -> HCAtlasPairingRegistrar {
        let home = URL(fileURLWithPath: "/Users/test")
        let data = try JSONSerialization.data(withJSONObject: ["pairing": 1, "machine": "studio", "acknowledged": 1,
            "vias": [session: HCAtlasPairing.viaPath(home: home, session: session)]])
        let pairing = try XCTUnwrap(HCAtlasPairing(data: data, home: home))
        return HCAtlasPairingRegistrar(load: { pairing }, checkVia: { _ in .safe }, maxAttempts: 1)
    }

    func testColdRemoteCreateJoinsRegistrationAndLoadsItsOwnRelayBeforeRun() async throws {
        let c = try configuration(shard: 1), log = HCTestLog(), inventory = HCTestInventory()
        let registrar = try pairingRegistrar(session: c.session), gate = HCTestConnectGate()
        let adding = expectation(description: "registration in progress")
        let preparing = expectation(description: "creation joins registration")
        let panel = UUID(), creation = UUID()
        let root = "/Users/far/.local/share/c11/relay/\(c.session)"
        let manifest = try JSONSerialization.data(withJSONObject: ["relay_protocol": 1, "session": c.session,
            "home": "/Users/far", "bin": root + "/bin", "zdotdir": root + "/zdotdir",
            "sentinel": root + "/no-socket", "cli_sha256": String(repeating: "a", count: 64)])
        let factory = HCTestFactory(pid: 1, log: log) { request in
            switch request.method {
            case "machine.list":
                let machines: [HCJSONValue] = log.read().contains("registered")
                    ? [.object(["name": .string("studio"), "session": .string(c.session)])] : []
                return .object(["machines": .array(machines)])
            case "machine.add":
                XCTAssertEqual(request.params["session"], .string(c.session))
                adding.fulfill()
                await gate.pause()
                log.add("registered")
                return .object([:])
            case "file.read":
                XCTAssertTrue(log.read().contains("registered"))
                XCTAssertEqual(request.params["on"], .string("studio"))
                XCTAssertEqual(request.params["path"], .string(C11Relay.Manifest.relativePath(session: c.session)))
                return .object(["text": .string(String(decoding: manifest, as: UTF8.self))])
            case "terminal.run":
                XCTAssertTrue(log.read().contains("registered"))
                XCTAssertTrue(log.read().contains("file.read"))
                XCTAssertEqual(request.params["on"], .string("studio"))
                XCTAssertEqual(request.params["env"]["ZDOTDIR"], .string(root + "/zdotdir"))
                XCTAssertEqual(request.params["env"]["C11_SOCKET_PATH"], .string(root + "/no-socket"))
                XCTAssertEqual(request.params["env"]["KEEP_ME"], .string("yes"))
                await inventory.insert(panel: panel, creation: creation, machine: request.params["on"].string)
                return .object([:])
            default: throw HCUnavailableReason.malformedResponse
            }
        }
        let prepare = HCBackendComposition.remotePreparation(pairing: registrar)
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            onInstalled: HCBackendComposition.pairingHook(registrar: registrar), prepareRemote: { connected, machine in
                preparing.fulfill()
                return try await prepare(connected, machine)
            })
        let creationTask = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
            creationID: creation, argv: [], environment: ["ZDOTDIR": "/stale/shard", "KEEP_ME": "yes"], machine: "studio")) }
        await fulfillment(of: [adding, preparing], timeout: 1)
        XCTAssertFalse(log.read().contains("terminal.run"), "run must not overtake the add handshake")
        await gate.release()
        guard case .bound = await creationTask.value else { return XCTFail("first remote creation must bind") }
        XCTAssertEqual(log.read().filter { $0 == "machine.add" }.count, 1)
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
    }

    func testInvalidPairedRelayRejectsBeforeClaimOrRun() async throws {
        let c = try configuration(shard: 1), log = HCTestLog(), inventory = HCTestInventory()
        let registrar = try pairingRegistrar(session: c.session)
        let factory = HCTestFactory(pid: 1, log: log) { request in
            switch request.method {
            case "machine.list": return .object(["machines": .array([.object(["name": .string("studio"), "session": .string(c.session)])])])
            case "file.read": return .object(["text": .string("{}")])
            default: XCTFail("invalid relay must not send \(request.method)"); throw HCUnavailableReason.malformedResponse
            }
        }
        let store = HCCreationIntentStore(directory: c.intentDirectory)
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: store,
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            prepareRemote: HCBackendComposition.remotePreparation(pairing: registrar))
        let panel = UUID()
        let result = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
            creationID: UUID(), argv: [], machine: "studio"))
        guard case .rejectedBeforeTransmission(.invalidLaunchTuple) = result else { return XCTFail("invalid relay must refuse") }
        let intent = try await store.read(panelID: panel)
        // Preparation must finish before claiming the creation: nothing was claimed, and
        // C11H-313 records that the creation never ran.
        XCTAssertEqual(intent?.phase, .ended, "preparation must finish before claiming the creation")
        XCTAssertEqual(intent?.endEvidence?.kind, .createRejected)
        XCTAssertFalse(log.read().contains("terminal.run"))
    }

    /// C11H-176: a protocol 2 relay kit gets the terminal's credential as a
    /// one-time pickup, written on the machine before `terminal.run`. The
    /// launch env carries only the pad; the pad and the document together
    /// give exactly the credential c11 derives for that panel and creation.
    /// A pickup that cannot be written still opens the terminal, without one.
    func testARemoteRunHandsItsTerminalACredentialPickupAndAFailedPickupStillRuns() async throws {
        for failWrite in [false, true] {
            let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
            let keyring = C11RelayMemoryKeyring()
            let panel = UUID(), creation = UUID()
            let documents = HCTestDocuments()
            let factory = HCTestFactory(pid: 1, log: log) { request in
                switch request.method {
                case "doc.get":
                    XCTAssertEqual(request.params["on"], .string("studio"))
                    return .object(["value": .null, "version": .integer(0)])
                case "doc.set":
                    if failWrite { throw HCRPCFailure(reason: .connectionLost, transmission: .none, remoteCode: nil) }
                    await documents.put(request.params["name"].string ?? "", request.params["value"])
                    return .object(["version": .integer(1)])
                case "terminal.run":
                    await documents.put("run.env", request.params["env"])
                    await inventory.insert(panel: panel, creation: creation, machine: request.params["on"].string)
                    return .object([:])
                default: throw HCUnavailableReason.malformedResponse
                }
            }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
                intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
                makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
                prepareRemote: { _, _ in ["C11_RELAY_BIN": "/far/bin", C11RelayAuth.protocolVariable: "2"] },
                relayKeyring: keyring, relayLedger: C11RelayPickupLedger(url: nil))
            let result = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                creationID: creation, argv: [], environment: [:], machine: "studio"))
            guard case .bound = result else { return XCTFail("the terminal opens either way (failWrite=\(failWrite))") }
            let env = await documents.get("run.env")
            XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
            if failWrite {
                XCTAssertEqual(env["C11_RELAY_PICKUP"], .null, "no pickup without its document")
                continue
            }
            let pickup = try XCTUnwrap(C11RelayAuth.Pickup(env["C11_RELAY_PICKUP"].string))
            XCTAssertEqual(pickup.creation, creation)
            XCTAssertEqual(env["C11_RELAY_AUTH"], .null, "the credential itself never goes into the launch env")
            let document = await documents.get(C11RelayAuth.pickupName(creation: creation))
            XCTAssertNotEqual(document, .null)
            let order = log.read()
            XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "doc.set")), try XCTUnwrap(order.firstIndex(of: "terminal.run")),
                              "the pickup is written before terminal.run")
            let credential = try XCTUnwrap(C11RelayAuth.credential(document: document.foundation, pickup: pickup))
            let link = try XCTUnwrap(keyring.secret(session: c.session, machine: "studio"))
            XCTAssertEqual(credential.linkID, link.id)
            XCTAssertEqual(credential.key, C11RelayAuth.terminalKey(link: link, session: c.session, machine: "studio",
                                                                     panel: panel, creation: creation))
            XCTAssertNotEqual(document["m"].string, C11RelayAuth.hex(credential.key), "the document alone is masked")
        }
    }

    func testLostRunReplyReconcilesSameProcessAndNeverSendsSecondRun() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let panel = UUID(), creation = UUID()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            guard request.method == "terminal.run" else { throw HCUnavailableReason.malformedResponse }
            await inventory.insert(panel: panel, creation: creation)
            throw HCRPCFailure(reason: .connectionLost, transmission: .possible, remoteCode: nil)
        }
        let store = HCCreationIntentStore(directory: c.intentDirectory)
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: store, prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let identity = HCPanelIdentity(panelID: panel, origin: .fresh)
        let request = HCCreateRequest(identity: identity, creationID: creation, argv: ["sh"])
        guard case .unresolved = await session.create(request) else { return XCTFail("Lost reply must be uncertain") }
        guard case .live(let record) = await session.resolve(identity) else { return XCTFail("Label reconciliation must bind") }
        XCTAssertEqual(record.pid, 100)
        guard case .bound = await session.create(request) else { return XCTFail("Retry must return existing terminal") }
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
        XCTAssertFalse(log.read().contains("start"))
    }

    func testLostRunEscalatesThenRecoversToExactlyOneReplacement() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory(), processes = HCTestProcesses(log: log)
        let panel = UUID(), creation = UUID(), replacement = UUID()
        let factory = HCTestFactory(processes: processes, pid: 1, log: log) { request in
            switch request.method {
            case "terminal.run":
                if log.read().filter({ $0 == "terminal.run" }).count == 1 {
                    // No record was ever observed, so an empty snapshot cannot
                    // settle this possibly transmitted request in the same core.
                    throw HCRPCFailure(reason: .connectionLost, transmission: .possible, remoteCode: nil)
                }
                guard case .object(let params) = request.params, case .object(let labels) = params["labels"] else {
                    throw HCUnavailableReason.malformedResponse
                }
                XCTAssertEqual(labels["c11.creation"], .string(replacement.uuidString))
                await inventory.insert(panel: panel, creation: replacement)
                return .object(["terminal": .string("t1")])
            case "server.restart":
                await processes.markExited(1)
                return .object([:])
            default: throw HCUnavailableReason.malformedResponse
            }
        }
        let store = HCCreationIntentStore(directory: c.intentDirectory)
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: processes, intents: store, creationResolutionSeconds: 0.05,
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let identity = HCPanelIdentity(panelID: panel, origin: .fresh)
        let request = HCCreateRequest(identity: identity, creationID: creation, argv: ["sh"])
        guard case .unresolved = await session.create(request) else { return XCTFail("Lost run reply must remain unresolved") }
        let limit = HCMonotonic.deadline(after: 2)
        var unresolved = await session.resolve(identity)
        while case .unresolved(_, .creationPending) = unresolved, HCMonotonic.now < limit {
            try await Task.sleep(nanoseconds: 10_000_000)
            unresolved = await session.resolve(identity)
        }
        guard case .unresolved(_, .creationUncertain) = unresolved else {
            return XCTFail("Lost run without a record did not escalate at the creation resolution deadline")
        }
        let replacementRequest = HCCreateRequest(identity: identity, creationID: replacement, argv: ["sh"])
        guard case .unresolved(_, .creationUncertain) = await session.create(replacementRequest) else {
            return XCTFail("Elapsed time alone must not authorize a replacement")
        }
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
        XCTAssertFalse(log.read().contains("server.restart"))
        guard case .recovered = await session.recoverSession(reason: .creationUncertain) else {
            return XCTFail("Explicit safe retry must recover the owned session")
        }
        guard case .ended(let end) = await session.resolve(identity) else {
            return XCTFail("Post-adoption absence must settle the unobserved creation")
        }
        XCTAssertEqual(end.kind, .postAdoptionAbsence)
        XCTAssertEqual(end.creationID, creation)
        let adopted = await session.snapshot()
        XCTAssertEqual(adopted.buildIdentity?.process.pid, 2)
        guard case .bound(let record) = await session.create(replacementRequest) else {
            return XCTFail("Settled absence must authorize the one replacement")
        }
        guard case .bound(let repeated) = await session.create(replacementRequest) else {
            return XCTFail("Retry must retain the replacement already bound")
        }
        XCTAssertEqual(repeated.key, record.key)
        XCTAssertEqual(record.labels["c11.creation"], replacement.uuidString)
        let final = await session.snapshot()
        XCTAssertEqual(final.records.count, 1)
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 2)
        XCTAssertEqual(log.read().filter { $0 == "server.restart" }.count, 1)
    }

    func testForeignBuildRecoveryAtConnectSucceedsOrLatchesUntilExplicitRetry() async throws {
        for replacementIsPinned in [true, false] {
            let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory(), processes = HCTestProcesses(log: log)
            let factory = HCTestFactory(processes: processes,
                versions: [1: "foreign", 2: replacementIsPinned ? c.pin.version : "foreign"], pid: 1, log: log) { request in
                    XCTAssertEqual(request.method, "server.restart")
                    let pid = await processes.currentPID()
                    await processes.markExited(pid)
                    return .object([:])
                }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), processes: processes, intents: HCCreationIntentStore(directory: c.intentDirectory),
                prepareAttachment: { _, _, _, display in display },
                makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
            let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
            let first = await session.resolve(identity)
            XCTAssertEqual(log.read().filter { $0 == "server.restart" }.count, 1)
            if replacementIsPinned {
                guard case .new = first else { XCTFail("Foreign core must hand over to the pinned replacement"); continue }
                let diagnostics = await session.diagnostics()
                XCTAssertEqual(diagnostics.servingBuild?.process.pid, 2)
            } else {
                guard case .unresolved(_, .recoveryRequired) = first else { XCTFail("Failed handover must require explicit recovery"); continue }
            }
            for _ in 0..<2 {
                let later = await session.resolve(identity)
                if replacementIsPinned {
                    guard case .new = later else { XCTFail("Pinned session must stay installed"); continue }
                } else {
                    guard case .unresolved(_, .recoveryRequired) = later else {
                        XCTFail("Failed automatic handover must stay latched until explicit recovery")
                        continue
                    }
                }
            }
            XCTAssertEqual(log.read().filter { $0 == "server.restart" }.count, 1,
                           "Later resolves must not repeat the automatic restart")
            if !replacementIsPinned {
                guard case .recovered = await session.recoverSession(reason: .foreignBuild) else {
                    XCTFail("Explicit Retry recovery must be allowed after the latch"); continue
                }
                guard case .new = await session.resolve(identity) else { XCTFail("Explicit recovery must install the pinned core"); continue }
                let diagnostics = await session.diagnostics()
                XCTAssertEqual(diagnostics.servingBuild?.process.pid, 3)
                XCTAssertEqual(log.read().filter { $0 == "server.restart" }.count, 2)
            }
            XCTAssertFalse(log.read().contains("terminal.run"))
        }
    }

    func testSlowValidRunKeepsItsTwentySecondBudget() async throws {
        // Pathfinder observed valid runs taking up to 16 seconds through hc.
        // Read the budget the session hands terminal.run instead of waiting it out.
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let panel = UUID(), creation = UUID()
        let pathfinderWorstRun: UInt64 = 16_000_000_000
        let factory = HCTestFactory(pid: 1, log: log) { request in
            guard request.method == "terminal.run" else { throw HCUnavailableReason.malformedResponse }
            let now = HCMonotonic.now
            guard request.deadlineUptimeNanoseconds > now, request.deadlineUptimeNanoseconds - now > pathfinderWorstRun else {
                throw HCRPCFailure(reason: .deadlineExceeded, transmission: .possible, remoteCode: nil)
            }
            await inventory.insert(panel: panel, creation: creation)
            return .object(["terminal": .string("t1")])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])
        guard case .bound = await session.create(request) else { return XCTFail("Valid 15-second run exceeded an incorrectly short budget") }
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
        XCTAssertFalse(log.read().contains("close"))
    }

    func testUnreachableCreatePreservesRestoredAndDurablyPendingIdentities() async throws {
        for kind in ["fresh", "restored", "pending"] {
            let c = try configuration(), log = HCTestLog()
            let store = HCCreationIntentStore(directory: c.intentDirectory)
            let identity = HCPanelIdentity(panelID: UUID(), origin: kind == "restored" ? .restored : .fresh)
            if kind == "pending" {
                _ = try await store.claim(HCCreateRequest(identity: identity, creationID: UUID(), argv: ["sh"]),
                    coreID: "core", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 10))
            }
            let session = HCManagedSession(configuration: c, connections: HCTestUnavailableFactory(), verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: store, prepareAttachment: { _, _, _, display in display })
            let outcome = await session.create(HCCreateRequest(identity: identity, creationID: UUID(), argv: ["sh"]))
            if kind == "fresh" {
                guard case .rejectedBeforeTransmission(.coreUnreachable) = outcome else { XCTFail("Genuinely new unreachable birth may fall back"); continue }
            } else {
                guard case .unresolved(let saved, .coreUnreachable) = outcome else { XCTFail("Restored/pending identity must remain unresolved on failed lookup"); continue }
                XCTAssertEqual(saved, identity)
            }
        }
    }

    func testIntentWriteFailurePreventsAnyRunRPC() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let factory = HCTestFactory(pid: 1, log: log) { _ in XCTFail("No RPC after failed intent write"); return .null }
        let store = HCCreationIntentStore(directory: c.intentDirectory, persist: { data, file in
            // The rename can be visible even though the subsequent durability
            // barrier fails. A swallowed fsync error must not authorize run.
            try PrivateFileWriter.write(data, to: file)
            throw POSIXError(.ENOSPC)
        })
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: store, prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let request = HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), creationID: UUID(), argv: ["sh"])
        guard case .rejectedBeforeTransmission(.intentStoreFailure) = await session.create(request) else { return XCTFail("Expected durable barrier refusal") }
        XCTAssertFalse(log.read().contains("terminal.run"))
    }

    func testAttachmentBindsGenerationAndDisplayBeforeEarlyOutput() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        await inventory.insert(panel: UUID(), creation: UUID())
        let sink = HCTestSink(log: log)
        let factory = HCTestFactory(pid: 1, log: log) { request in
            XCTAssertEqual(request.method, "terminal.attach")
            XCTAssertTrue(log.read().contains("prepare"))
            guard case .object(let params) = request.params else { throw HCUnavailableReason.malformedResponse }
            XCTAssertEqual(params["cols"], .integer(91))
            XCTAssertEqual(params["rows"], .integer(37))
            XCTAssertEqual(params["display"], .object(["fg": .string("#010203"), "cell": .array([.integer(9), .integer(17)])]))
            return .object(["channel": .integer(7)])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, generation, _, display in
                await sink.bind(generation)
                log.add("prepare")
                return HCDisplayState(revision: display.revision, grid: HCGridSize(columns: 91, rows: 37),
                    facts: HCDisplayFacts(foreground: HCRGBColor(red: 1, green: 2, blue: 3), cellWidth: 9, cellHeight: 17))
            },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            makeAttachment: { key, generation, _, _, display in
                log.add("makeAttachment")
                await sink.bindInput()
                XCTAssertEqual(display.revision.attachmentGeneration, generation)
                XCTAssertEqual(display.grid, HCGridSize(columns: 91, rows: 37))
                return HCTestAttachment(key: key, generation: generation)
            })
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let attachment = try await session.attach(key, sink: sink,
            display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1), grid: HCGridSize(columns: 80, rows: 24)))
        XCTAssertEqual(attachment.generation, 1)
        let events = log.read().filter { ["prepare", "terminal.attach", "register", "makeAttachment", "output"].contains($0) }
        XCTAssertEqual(events, ["prepare", "terminal.attach", "register", "makeAttachment", "output"])
    }

    func testCanonicalInventoryReadsCurrentSourceWithoutObserverDrain() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let session = HCManagedSession(configuration: c, connections: HCTestFactory(pid: 1, log: log, handler: { _ in .null }),
            verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let canonical: any HCInventorySource = session
        guard case .pending = await canonical.snapshot().readiness else { return XCTFail("Before install must be pending") }
        guard case .new = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh)) else { return XCTFail("Fixture installs authoritative empty inventory") }
        let panel = UUID()
        // This fake never emits observe callbacks; only a direct source read
        // can see the insertion, independent of a UI queue's delivery timing.
        await inventory.insert(panel: panel, creation: UUID())
        let current = await canonical.snapshot()
        XCTAssertEqual(current.records.values.first?.labels["c11.panel"], panel.uuidString)
        let refreshed = await canonical.refresh()
        XCTAssertEqual(refreshed.revision, current.revision)
    }

    func testManagedRunFailureRetainsTransmissionCertainty() {
        let lost = HCRPCFailure(reason: .connectionLost, transmission: .possible, remoteCode: nil)
        XCTAssertFalse(HCManagedCallFailure(lost, mayMutate: true).retrySafe)
        XCTAssertTrue(HCManagedCallFailure(lost, mayMutate: false).retrySafe)
        let none = HCRPCFailure(reason: .bufferOverflow, transmission: .none, remoteCode: nil)
        XCTAssertTrue(HCManagedCallFailure(none, mayMutate: true).retrySafe)
        let rejected = HCRPCFailure(reason: .malformedResponse, transmission: .rejectedByPeer, remoteCode: "invalid_params")
        XCTAssertTrue(HCManagedCallFailure(rejected, mayMutate: true).retrySafe)
        XCTAssertTrue(HCManagedCallFailure(HCUnavailableReason.foreignSession, mayMutate: true).retrySafe)
        XCTAssertFalse(HCManagedCallFailure(POSIXError(.EIO), mayMutate: true).retrySafe)
    }

    func testManagedStatusCannotInvalidateAnInFlightSessionConnection() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory(), gate = HCTestConnectGate()
        let factory = HCTestFactory(beforeConnect: { generation in
            if generation == 1 { await gate.pause() }
        }, pid: 1, log: log, handler: { _ in .object(["ok": .bool(true)]) })
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let resolving = Task { await session.resolve(identity) }
        await gate.waitUntilPaused()
        let command = try HCManagedCommandParser.parse(["server", "status"], environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], cwd: "/")
        let reply = try await session.managedCommand(command)
        XCTAssertEqual(reply, .object(["ok": .bool(true)]))
        await gate.release()
        guard case .new = await resolving.value else { return XCTFail("Command-only connect invalidated the session connect") }
        guard case .ready = await session.diagnostics().inventory.readiness else { return XCTFail("Session inventory must stay ready") }
    }

    func testManagedStatusNeverAutostartsAnUnreachableCore() async throws {
        let c = try configuration(), log = HCTestLog()
        let session = HCManagedSession(configuration: c, connections: HCTestUnavailableFactory(), verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display })
        let command = try HCManagedCommandParser.parse(["server", "status"], environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], cwd: "/")
        do { _ = try await session.managedCommand(command); XCTFail("Unreachable must refuse") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .coreUnreachable) }
        XCTAssertFalse(log.read().contains("start"))
    }

    func testRecoveryDeadlineReturnsWhileInventoryIgnoresCancellation() async throws {
        let gate = HCTestConnectGate()
        let task = Task {
            try await HCBoundedOperation.run(deadline: HCMonotonic.deadline(after: 1)) {
                await gate.pause()
                return 7
            }
        }
        // A fixture escape also makes the removed-deadline mutation fail in
        // seconds, instead of hanging the XCTest worker for its whole allowance.
        let escape = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await gate.release() }
        do { _ = try await task.value; XCTFail("Blocked inventory outlived absolute recovery deadline") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .deadlineExceeded) }
        // Completion after the timeout must be harmless, with no second resume.
        escape.cancel()
        await gate.release()
        let value = try await HCBoundedOperation.run(deadline: HCMonotonic.deadline(after: 2)) { 9 }
        XCTAssertEqual(value, 9)
    }

    func testRecoveryWaitsForExitBeforePinnedStartAndRetainsCoreIdentity() async throws {
        let c = try configuration(), log = HCTestLog(), processes = HCTestProcesses(log: log)
        let verifier = HCTestVerifier(log: log)
        let peer = HCPeerEvidence(uid: 1, pid: 1, statusPID: 1, coreID: "core", version: "foreign", protocolGeneration: 1, methods: [], features: [])
        let verification = try await verifier.verify(peer, configuration: c)
        let previous = HCTestConnection(generation: 1, peer: peer, verification: verification, log: log) { request in
            XCTAssertEqual(request.method, "server.restart")
            await processes.markExited(1)
            throw HCRPCFailure(reason: .connectionLost, transmission: .possible, remoteCode: nil)
        }
        let factory = HCTestFactory(pid: 2, log: log) { _ in .null }
        let deadline = HCMonotonic.deadline(after: 10)
        let coordinator = HCRecoveryCoordinator(configuration: c, factory: factory, verifier: verifier,
                                                 launcher: HCTestLauncher(log: log, expectedDeadline: deadline), processes: processes)
        let next = try await coordinator.recover(HCConnectedRuntime(connection: previous, verified: verification), generation: 2, deadlineUptimeNanoseconds: deadline)
        XCTAssertEqual(next.verified.identity.coreID, "core")
        XCTAssertEqual(next.verified.identity.process.pid, 2)
        let events = log.read()
        let proof = try XCTUnwrap(events.firstIndex(of: "exit-proof:1:true"))
        let start = try XCTUnwrap(events.firstIndex(of: "start"))
        XCTAssertLessThan(proof, start)
        XCTAssertEqual(events.filter { $0 == "server.restart" }.count, 1)
    }

    func testRecoveryAfterAlreadyExitedCoreValidatesOwnedStateWithoutSecondRestart() async throws {
        let c = try configuration(), log = HCTestLog(), processes = HCTestProcesses(log: log)
        let verifier = HCTestVerifier(log: log)
        let peer = HCPeerEvidence(uid: 1, pid: 1, statusPID: 1, coreID: "core", version: "foreign", protocolGeneration: 1, methods: [], features: [])
        let verification = try await verifier.verify(peer, configuration: c)
        let previous = HCTestConnection(generation: 1, peer: peer, verification: verification, log: log) { _ in XCTFail("Dead peer must not receive restart"); return .null }
        await processes.markExited(1)
        let coordinator = HCRecoveryCoordinator(configuration: c,
            factory: HCTestFactory(pid: 2, log: log, handler: { _ in .null }), verifier: verifier,
            launcher: HCTestLauncher(log: log), processes: processes)
        _ = try await coordinator.recover(HCConnectedRuntime(connection: previous, verified: verification), generation: 2)
        XCTAssertTrue(log.read().contains("owned-state"))
        XCTAssertFalse(log.read().contains("server.restart"))
    }

    // MARK: panel bindings

    private func bindingSession(_ c: HCLaunchConfiguration, _ log: HCTestLog, _ inventory: HCTestInventory) -> HCManagedSession {
        HCManagedSession(configuration: c, connections: HCTestFactory(pid: 1, log: log) { _ in throw HCUnavailableReason.malformedResponse },
            verifier: HCTestVerifier(log: log), launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
    }

    /// The reducer knows terminals, not panels, so nothing filled
    /// `panelBindings` on the live path. Process admission, agent and
    /// conversation recovery and the diagnostics recorder all read it.
    func testResolvingAPanelPublishesItsTerminalBindingInEverySnapshot() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let panel = UUID()
        await inventory.insert(panel: panel, creation: UUID())
        let session = bindingSession(c, log, inventory)
        let published = expectation(description: "a published snapshot binds the panel")
        published.assertForOverFulfill = false
        let observation = session.observe(on: DispatchQueue(label: "hc.test.bindings")) { snapshot in
            if snapshot.panelBindings[panel] != nil { published.fulfill() }
        }
        defer { observation.cancel() }
        let before = await session.diagnostics().inventory.panelBindings
        XCTAssertTrue(before.isEmpty, "control: nothing is bound before the panel resolves")

        guard case .live(let record) = await session.resolve(HCPanelIdentity(panelID: panel, origin: .fresh)) else {
            return XCTFail("the labelled running terminal must resolve live")
        }

        await fulfillment(of: [published], timeout: 2)
        // A later snapshot, built from the inventory alone, keeps the binding.
        let later = await session.diagnostics().inventory
        XCTAssertEqual(later.panelBindings[panel], record.key)
    }

    func testTheRecorderListsBoundPanelsAndCountsAHolderLossFromTheLiveSnapshot() async throws {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let alive = UUID(), lost = UUID()
        await inventory.insert(panel: alive, creation: UUID())
        await inventory.insertFinished(panel: lost, address: "t2", reason: "holder_lost")
        let session = bindingSession(c, log, inventory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hc-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let recorder = HCDiagnosticRecorder(logFile: directory.appendingPathComponent("hc-diagnostics.log"),
                                            counterFile: directory.appendingPathComponent("holder-lost.json"))

        guard case .live = await session.resolve(HCPanelIdentity(panelID: alive, origin: .fresh)) else { return XCTFail("live") }
        guard case .ended = await session.resolve(HCPanelIdentity(panelID: lost, origin: .fresh)) else { return XCTFail("ended") }
        recorder.ingest(await session.diagnostics())

        let rows = recorder.jsonObject()["panels"] as? [[String: Any]] ?? []
        func row(_ id: UUID) -> [String: Any]? { rows.first { $0["panel_id"] as? String == id.uuidString } }
        XCTAssertEqual(rows.count, 2, "both bound panels are listed")
        XCTAssertEqual(row(alive)?["lifecycle"] as? String, "live")
        XCTAssertEqual(row(alive)?["terminal"] as? String, "t1")
        XCTAssertEqual(row(lost)?["lifecycle"] as? String, "ended")
        XCTAssertEqual(row(lost)?["reason"] as? String, "holder_lost")
        XCTAssertEqual(recorder.jsonObject()["holder_lost_count"] as? Int, 1, "the holder death is counted from the live snapshot")
    }

    // MARK: hc.call

    /// `hc ls` from a c11 terminal: the CLI's `hc.call` request, through the
    /// controller's socket-worker dispatch, into the composed session and out to
    /// the core's `terminal.list`. The core is a fake; nothing is launched.
    func testHCListReachesTheManagedSessionThroughTheSocketDispatcher() async throws {
        let c = try configuration(), log = HCTestLog()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            guard request.method == "terminal.list" else { throw HCUnavailableReason.malformedResponse }
            return .object(["terminals": .array([.object(["address": .string("t1b")])])])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display })
        let command = try HCManagedCommandParser.parse(["ls"], environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], cwd: "/")
        let params = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])

        await HCManagedCommandEndpoint.shared.install(session)
        let response = try await HCCallRoutingTests.workerResponse("hc.call", params: params)
        await HCManagedCommandEndpoint.shared.uninstall()

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let terminals = (response["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
        XCTAssertEqual(terminals?.first?["address"] as? String, "t1b")
        XCTAssertEqual(log.read().filter { $0 == "terminal.list" }.count, 1)
        XCTAssertFalse(log.read().contains("start"), "a command never starts a core")
    }

    private func machineSession(version: String?, log: HCTestLog) throws -> (HCManagedSession, HCLaunchConfiguration) {
        let c = try configuration()
        let factory = HCTestFactory(versions: version.map { [1: $0] } ?? [:], pid: 1, log: log) { request in
            guard request.method == "machine.list" else { throw HCUnavailableReason.malformedResponse }
            return .object(["machines": .array([.object(["name": .string("studio"), "state": .string("connected"), "version": .string("0.1.16")])])])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display })
        return (session, c)
    }

    /// C11H-42: `hc machine ls` inside a c11 panel is the core's machine.list,
    /// link state and all, through the same managed route as `hc ls`.
    func testHCMachineLsReachesTheCoresMachineListThroughTheManagedRoute() async throws {
        let log = HCTestLog()
        let (session, c) = try machineSession(version: nil, log: log)
        let command = try HCManagedCommandParser.parse(["machine", "ls"], environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], cwd: "/")
        let params = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])

        await HCManagedCommandEndpoint.shared.install(session)
        let response = try await HCCallRoutingTests.workerResponse("hc.call", params: params)
        await HCManagedCommandEndpoint.shared.uninstall()

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let machine = ((response["result"] as? [String: Any])?["machines"] as? [[String: Any]])?.first
        XCTAssertEqual(machine?["name"] as? String, "studio")
        XCTAssertEqual(machine?["state"] as? String, "connected", "the link state comes back untouched")
        XCTAssertEqual(log.read().filter { $0 == "machine.list" }.count, 1)
        XCTAssertFalse(log.read().contains("start"), "a command never starts a core")
    }

    func testHCMachineLsIsRefusedBeforeTheCoreAnswersWhenTheServingCoreIsNotThePinnedBuild() async throws {
        let log = HCTestLog()
        let (session, c) = try machineSession(version: "0.0.1-foreign", log: log)
        let command = try HCManagedCommandParser.parse(["machine", "ls"], environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path], cwd: "/")
        do {
            _ = try await session.managedCommand(command)
            XCTFail("a foreign build must not answer a managed command")
        } catch {
            XCTAssertEqual(error as? HCUnavailableReason, .foreignBuild)
        }
        XCTAssertFalse(log.read().contains("machine.list"), "the pin check comes before the request")
    }
}

/// C11H-176: documents and the run env a test core received.
private actor HCTestDocuments {
    private var values: [String: HCJSONValue] = [:]
    func put(_ name: String, _ value: HCJSONValue) { values[name] = value }
    func get(_ name: String) -> HCJSONValue { values[name] ?? .null }
}

private actor HCTestConnectGate {
    private var started = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var notified: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        started = true
        for continuation in notified { continuation.resume() }
        notified.removeAll()
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func waitUntilPaused() async {
        if !started { await withCheckedContinuation { notified.append($0) } }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

/// C11H-329: a close's holder lookup. The first answers at once; every later
/// one waits until `release()`, then answers that nothing else holds the key.
private actor HCLaterLookupHold {
    private(set) var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func answer() async -> HCHolderAnswer {
        count += 1
        if count > 1, !released { await withCheckedContinuation { waiting.append($0) } }
        return .none
    }
    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

private struct HCTestUnavailableFactory: HCConnectionFactory {
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        throw HCUnavailableReason.coreUnreachable
    }
}

private struct HCTestChannel: HCChannel {
    let channelID: UInt32
    let connectionGeneration: UInt64
    let attachmentGeneration: UInt64
    let sink: any HCOutputSink
    let log: HCTestLog
    func activate() async throws {
        let result = await sink.consume(HCOutputChunk(attachmentGeneration: attachmentGeneration, watermark: 1, bytes: Data("early paint".utf8)))
        guard case .consumed = result else { throw HCUnavailableReason.staleIdentity }
    }
    func close() { log.add("channel-close") }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome { .refused(.unavailable) }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome { .refused(.unavailable) }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
}

private actor HCTestSink: HCOutputSink {
    let log: HCTestLog
    var generation: UInt64?
    var inputBound = false
    init(log: HCTestLog) { self.log = log }
    func bind(_ generation: UInt64) { self.generation = generation }
    func bindInput() { inputBound = true }
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        log.add("output")
        XCTAssertEqual(chunk.attachmentGeneration, generation)
        XCTAssertTrue(inputBound, "Early output generated a reply before the input port was bound")
        return chunk.attachmentGeneration == generation && inputBound ? .consumed : .stale
    }
    nonisolated func retire(completion: @escaping @Sendable () -> Void) { log.add("retire"); completion() }
}

private final class HCTestAttachment: HCAttachment, Sendable {
    let key: HCTerminalKey
    let generation: UInt64
    let input: any HCInputPort = HCUnavailableRuntime()
    init(key: HCTerminalKey, generation: UInt64) { self.key = key; self.generation = generation }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
    func detach() {}
}

/// hc numbers terminals t1…t19, then t1b…t1z, then t20… (pinned hc 0.1.16).
/// A digits-only check refused every lettered address as stale identity, so
/// every hc panel created after the 19th in a core's life never attached and
/// every send to it was refused (Validator T2.3, T2.6, V2.sends: 43 of 43
/// attach failures were on t1b…t1z).
final class HCTerminalAddressTests: XCTestCase {
    private let own = "core-own"

    private func address(_ local: String, core: String? = nil, machine: String? = nil,
                         availability: HCMachineAvailability = .local) throws -> String {
        let key = HCTerminalKey(owningCoreID: core ?? own, localAddress: local)
        let record = HCTerminalRecord(key: key, state: .running, machineName: machine, machineAvailability: availability)
        return try HCManagedSession.terminalAddress(key, record: record, ownCoreID: own)
    }

    func testEveryAddressHcIssuesIsAccepted() throws {
        for local in ["t1", "t9", "t19", "t1b", "t1c", "t1z", "t20", "t28", "t2b", "t100"] {
            XCTAssertEqual(try address(local), local, "hc issued \(local)")
        }
        XCTAssertEqual(try address("t1c", core: "core-other", machine: "studio", availability: .connected), "studio/t1c")
    }

    func testAnythingThatIsNotAnHcAddressIsRefused() {
        // Also outside hc's 30-symbol alphabet: a leading zero, a vowel, `l`.
        for local in ["", "t", "x1", "1", "t1/t2", "t1C", "T1", "t-1", "t 1", "t1é", "t١",
                      "t0", "t01", "t1a", "t1e", "t1i", "t1l", "t1o", "t1u", "tb", "t2au"] {
            XCTAssertThrowsError(try address(local), "\(local) is not an hc address") { error in
                XCTAssertEqual(error as? HCUnavailableReason, .staleIdentity)
            }
        }
    }
}


/// C11H-66: the app starts a core only when none answers. A serving core is
/// reattached; a missing core or a stale socket (both `coreUnreachable`) gets
/// exactly one start, then a connect.
private struct HCUnreachableFirstFactory: HCConnectionFactory {
    let base: HCTestFactory
    let unreachableConnects: Int
    let attempts: HCTestLog
    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        attempts.add("attempt")
        if attempts.read().count <= unreachableConnects {
            base.log.add("unreachable")
            throw HCUnavailableReason.coreUnreachable
        }
        return try await base.connect(request, verify: verify)
    }
}

extension HCSessionTests {
    func testManagedCancellationPreservesReasonAndPossibleTransmission() async throws {
        // The read deadline wrapper can deliver cancellation before an RPC
        // receipt exists. The CLI must preserve that reason too.
        for mayMutate in [false, true] {
            let failure = HCManagedCallFailure(CancellationError(), mayMutate: mayMutate)
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertEqual(failure.retrySafe, !mayMutate)
        }
        for verb in [HCManagedVerb.list, .run] {
            let c = try configuration(), log = HCTestLog()
            let factory = HCTestFactory(pid: 1, log: log) { _ in throw CancellationError() }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
                prepareAttachment: { _, _, _, display in display })
            do {
                _ = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path,
                    verb: verb, argv: verb == .run ? ["sh"] : []))
                XCTFail("A cancelled transport must fail")
            } catch let failure as HCRPCFailure {
                XCTAssertEqual(failure.reason, .cancelled)
                XCTAssertEqual(failure.transmission, .possible)
                XCTAssertEqual(HCManagedCallFailure(failure, mayMutate: verb == .run).retrySafe, verb != .run)
            } catch { XCTFail("Lost transmission evidence: \(error)") }
            XCTAssertEqual(log.read().filter { $0 == (verb == .run ? "terminal.run" : "terminal.list") }.count, 1)
        }
    }

    func testSocketWaitExpiryIsRetrySafeOnlyForReads() async throws {
        for verb in [HCManagedVerb.status, .run] {
            let c = try configuration(), log = HCTestLog(), gate = HCTestConnectGate()
            let factory = HCTestFactory(beforeConnect: { _ in await gate.pause() }, pid: 1, log: log) { _ in
                .object(["ok": .bool(true)])
            }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
                prepareAttachment: { _, _, _, display in display })
            await HCManagedCommandEndpoint.shared.install(session)
            let command = HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: verb, argv: ["sh"])
            let params = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
            let reply: (String, Bool?) = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    switch TerminalController.shared.v2HCCall(params: params, waitSeconds: 0) {
                    case .err(let code, _, let data):
                        continuation.resume(returning: (code, (data as? [String: Any])?["retry_safe"] as? Bool))
                    case .ok: continuation.resume(returning: ("unexpected_success", nil))
                    }
                }
            }
            await HCManagedCommandEndpoint.shared.uninstall()
            await gate.release()
            XCTAssertEqual(reply.0, verb == .status ? "hc_deadlineExceeded" : "hc_outcome_uncertain")
            XCTAssertEqual(reply.1, verb == .status)
        }
    }

    func testManagedListReportsAvailabilityWithoutInventingTerminalEndings() async throws {
        let c = try configuration(), log = HCTestLog()
        let factory = HCTestFactory(pid: 1, log: log) { _ in
            .object(["terminals": .array([
                .object(["address": .string("t1"), "state": .string("live")]),
                .object(["address": .string("studio/t2"), "state": .string("live")])]),
                "machines": .array([
                    .object(["name": .string("studio"), "state": .string("unreachable")]),
                    .object(["name": .string("slow"), "state": .string("connected")])])])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display })
        let value = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .list))
        XCTAssertEqual(value["terminals"].array?.map { $0["state"] }, [.string("live"), .string("live")])
        XCTAssertEqual(value["terminals"].array?.map { $0["availability"] }, [.string("local"), .string("unavailable")])
        XCTAssertEqual(value["machines"].array?.map { $0["inventory_status"] }, [.string("unavailable"), .string("unconfirmed")])
        XCTAssertEqual(value["partial"], .bool(true))
        XCTAssertEqual(value["retry_safe"], .bool(true))
    }

    func testManagedListCanConfirmAnEmptyLocalInventory() async throws {
        let c = try configuration(), log = HCTestLog()
        let factory = HCTestFactory(pid: 1, log: log) { _ in .object(["terminals": .array([])]) }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display })
        let value = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .list))
        XCTAssertEqual(value["terminals"], .array([]))
        XCTAssertEqual(value["partial"], .bool(false))
    }

    private func bundledSession(unreachableConnects: Int) throws -> (HCManagedSession, HCTestLog) {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        let factory = HCUnreachableFirstFactory(base: HCTestFactory(pid: 1, log: log) { _ in .object([:]) },
                                                unreachableConnects: unreachableConnects, attempts: HCTestLog())
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory), prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory })
        return (session, log)
    }

    func testAServingCoreIsReattachedAndNeverStartedAgain() async throws {
        let (session, log) = try bundledSession(unreachableConnects: 0)
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        XCTAssertEqual(log.read().filter { $0.hasPrefix("connect:") }.count, 1)
        XCTAssertFalse(log.read().contains("start"), "a core that answers is never started a second time")
    }

    func testAMissingCoreOrStaleSocketGetsExactlyOneStartThenAConnect() async throws {
        let (session, log) = try bundledSession(unreachableConnects: 1)
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let events = log.read().filter { $0 == "unreachable" || $0 == "start" || $0.hasPrefix("connect:") }
        XCTAssertEqual(events, ["unreachable", "start", "connect:1"])
    }
}

extension HCSessionTests {
    /// Fake the real hc list's slow remote probe: it still returns local rows
    /// after its 3 s per-machine cap. The old 2 s adapter deadline loses them.
    func testManagedReadWaitsPastConnectBudgetAndPreservesPartialLocalList() async throws {
        let c = try configuration(), log = HCTestLog()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            XCTAssertEqual(request.method, "terminal.list")
            return try await HCBoundedOperation.run(deadline: request.deadlineUptimeNanoseconds) {
                try await Task.sleep(nanoseconds: 2_100_000_000)
                return .object([
                    "terminals": .array([.object(["address": .string("t1"), "state": .string("live")])]),
                    "machines": .array([
                        .object(["name": .string("studio"), "state": .string("unreachable"), "why": .string("link down")]),
                        .object(["name": .string("slow"), "state": .string("connected")])]),
                    "hidden_finished": .integer(2)
                ])
            }
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display })
        let value = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .list))
        XCTAssertEqual(value["terminals"].array?.count, 1)
        XCTAssertEqual(value["terminals"].array?.first?["address"], .string("t1"))
        XCTAssertEqual(value["terminals"].array?.first?["availability"], .string("local"))
        XCTAssertEqual(value["machines"].array?.first?["inventory_status"], .string("unavailable"))
        XCTAssertEqual(value["machines"].array?.last?["inventory_status"], .string("unconfirmed"))
        XCTAssertEqual(value["machines"].array?.first?["why"], .string("link down"))
        XCTAssertEqual(value["hidden_finished"], .integer(2))
        XCTAssertEqual(value["partial"], .bool(true))
        XCTAssertEqual(value["retry_safe"], .bool(true))
        XCTAssertEqual(log.read().filter { $0 == "terminal.list" }.count, 1)
    }

    func testManagedReadBudgetIsSharedByConnectAndRequest() async throws {
        for verb in [HCManagedVerb.get, .status, .machineList] {
            let c = try configuration(), log = HCTestLog()
            let clock = HCTestReadClock()
            let factory = HCTestFactory(beforeConnect: { _ in
                await clock.begin()
                try? await Task.sleep(nanoseconds: 30_000_000)
            },
                pid: 1, log: log) { request in
                // Connection starts after the command established its budget.
                // A fresh RPC deadline after connecting would exceed this cap.
                let connectionStart = await clock.start
                XCTAssertGreaterThan(connectionStart, 0)
                XCTAssertLessThanOrEqual(request.deadlineUptimeNanoseconds, connectionStart + 60_000_000)
                // The response would arrive within a fresh 60 ms RPC budget,
                // but not within the original budget after connection time.
                try await Task.sleep(nanoseconds: 40_000_000)
                return .object(["ok": .bool(true)])
            }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
                managedReadSeconds: 0.06, prepareAttachment: { _, _, _, display in display })
            do {
                _ = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path,
                                                                      verb: verb, terminal: "studio/t1"))
                XCTFail("A read must not reset its budget after connecting")
            } catch { XCTAssertEqual(HCManagedCallFailure(error, mayMutate: false).reason, .deadlineExceeded) }
            XCTAssertEqual(log.read().filter { ["terminal.get", "server.status", "machine.list"].contains($0) }.count, 1)
        }
    }

    /// The transport ignores cancellation and answers only when the gate opens,
    /// 10 s in. The read must give up at its 0.05 s budget, before that answer,
    /// however slow the runner is; it never waits on wall-clock time.
    func testManagedReadReturnsAtDeadlineEvenWhenTransportIgnoresCancellation() async throws {
        let c = try configuration(), log = HCTestLog(), answered = HCTestLog(), gate = HCTestConnectGate()
        let factory = HCTestFactory(pid: 1, log: log) { _ in
            await gate.pause()
            answered.add("answered")
            return .object(["late": .bool(true)])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            managedReadSeconds: 0.05, prepareAttachment: { _, _, _, display in display })
        let escape = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); await gate.release() }
        do {
            _ = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .status))
            XCTFail("Uncooperative transport must not escape the read budget")
        } catch { XCTAssertEqual(HCManagedCallFailure(error, mayMutate: false).reason, .deadlineExceeded) }
        XCTAssertEqual(answered.read(), [], "the read returned only after the transport answered")
        escape.cancel()
        await gate.release()
    }

    func testManagedRunNeverRetriesLostReply() async throws {
        let c = try configuration(), log = HCTestLog()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            XCTAssertEqual(request.method, "terminal.run")
            // A run carries the 20 s run budget, not the 12 s read budget; 4 s
            // of slack either side so a loaded runner cannot reach it.
            XCTAssertGreaterThan(Double(request.deadlineUptimeNanoseconds - HCMonotonic.now) / 1e9, 16)
            throw HCRPCFailure(reason: .connectionLost, transmission: .possible, remoteCode: nil)
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: { _, _, _, display in display })
        do {
            _ = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path,
                                                                  verb: .run, argv: ["sh"]))
            XCTFail("Lost run reply must fail")
        } catch { XCTAssertFalse(HCManagedCallFailure(error, mayMutate: true).retrySafe) }
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
    }

    func testManagedListDoesNotTurnMalformedOrUnconfirmedInventoryIntoEmptySuccess() async throws {
        for response in [HCJSONValue.object([:]), .object(["terminals": .null])] {
            let c = try configuration(), log = HCTestLog()
            let factory = HCTestFactory(pid: 1, log: log) { _ in response }
            let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
                launcher: HCTestLauncher(log: log), intents: HCCreationIntentStore(directory: c.intentDirectory),
                prepareAttachment: { _, _, _, display in display })
            do {
                _ = try await session.managedCommand(HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .list))
                XCTFail("Malformed list must be an explicit failure")
            } catch { XCTAssertEqual(HCManagedCallFailure(error, mayMutate: false).reason, .malformedResponse) }
        }
    }
}

/// C11H-308: every terminal shares one connection to the hc core. A creation
/// whose caller stops waiting (its panel closed, or detached for a reattach)
/// must settle on its own and never drop that connection: the lane's c11Tests
/// run logged 103 such creations as intent-store failures, each of which sent
/// every terminal in the app to Reconnecting.
private final class HCTrackedAttachment: HCAttachment, @unchecked Sendable {
    let key: HCTerminalKey
    let generation: UInt64
    let input: any HCInputPort = HCUnavailableRuntime()
    private let log: HCTestLog
    init(key: HCTerminalKey, generation: UInt64, log: HCTestLog) { self.key = key; self.generation = generation; self.log = log }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
    func detach() { log.add("detach:\(key.localAddress)") }
}

private struct HCAcceptingSink: HCOutputSink {
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption { .consumed }
    func retire(completion: @escaping @Sendable () -> Void) { completion() }
}

/// A run hc holds until released.
private actor HCTestRunHold {
    private var held = false
    private(set) var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func markHeld() { held = true; for continuation in waiting { continuation.resume() }; waiting.removeAll() }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { waiting.append($0) } } }
    func release() { released = true }
}

/// C11H-415: the c11 apps a test says carry a token.
private final class HCTestCarriers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HCScopeCarrier] = []
    var value: [HCScopeCarrier] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension HCSessionTests {
    /// A session whose connection already serves another panel's terminal
    /// (t2), attached; `run` answers terminal.run, and terminal.kill finishes
    /// the named terminal. `persist` replaces the intent store's durable write.
    private func sharedConnection(
        prepareRemote: HCManagedSession.PrepareRemote? = nil,
        persist: (@Sendable (Data, URL) throws -> Void)? = nil,
        readOnly: Bool = false,
        settleSeconds: TimeInterval = HCManagedSession.preflightSettleSeconds,
        refuse: HCTestSwitch? = nil,
        scopeCarriers: @escaping @Sendable () -> [HCScopeCarrier] = { [] },
        kill: (@Sendable (HCRPCRequest, HCTestInventory) async throws -> HCJSONValue)? = nil,
        run: @escaping @Sendable (HCRPCRequest, HCTestInventory) async throws -> HCJSONValue
    ) async throws -> (HCManagedSession, HCTestLog, HCCreationIntentStore, HCTestInventory) {
        let c = try configuration(), log = HCTestLog(), inventory = HCTestInventory()
        await inventory.insert(panel: UUID(), creation: UUID(), address: "t2")
        let factory = HCTestFactory(refuse: refuse, pid: 1, log: log) { request in
            switch request.method {
            case "terminal.attach": return .object(["channel": .integer(9)])
            case "terminal.kill":
                if let kill { return try await kill(request, inventory) }
                await inventory.finish(address: request.params["terminal"].string ?? "")
                return .object([:])
            case "terminal.run": return try await run(request, inventory)
            default: throw HCUnavailableReason.malformedResponse
            }
        }
        let store = persist.map { HCCreationIntentStore(directory: c.intentDirectory, persist: $0) }
            ?? HCCreationIntentStore(directory: c.intentDirectory)
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log), intents: store,
            // A panel runtime's surface (a headless bridge) is prepared and bound as composition does.
            prepareAttachment: { key, generation, sink, display in
                guard sink is HCNativeBridge else { return display }
                return try await HCBackendComposition.prepareAttachment(key: key, generation: generation, sink: sink,
                                                                         proposedDisplay: display)
            },
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            makeAttachment: { key, generation, _, sink, _ in
                let attachment = HCTrackedAttachment(key: key, generation: generation, log: log)
                if let bridge = sink as? HCNativeBridge { _ = bridge.bind(generation: generation, input: attachment.input) }
                return attachment
            },
            readOnly: readOnly, prepareRemote: prepareRemote, preflightSettleSeconds: settleSeconds,
            scopeCarriers: scopeCarriers)
        _ = try await session.attach(HCTerminalKey(owningCoreID: "core", localAddress: "t2"), sink: HCAcceptingSink(),
            display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                    grid: HCGridSize(columns: 80, rows: 24)))
        await inventory.pushChanges()
        return (session, log, store, inventory)
    }

    private func assertSharedConnectionKept(_ session: HCManagedSession, _ log: HCTestLog, _ context: String,
                                            file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertFalse(log.read().contains("close"), "\(context): the shared connection was closed", file: file, line: line)
        XCTAssertFalse(log.read().contains("detach:t2"), "\(context): another panel's terminal lost its attachment", file: file, line: line)
        XCTAssertEqual(log.read().filter { $0.hasPrefix("connect:") }.count, 1, "\(context): the session reconnected", file: file, line: line)
        guard case .ready = await session.snapshot().readiness else {
            return XCTFail("\(context): the inventory every panel reads left ready", file: file, line: line)
        }
    }

    /// The real close: the explicit end's coordinator, woken only by the
    /// inventory's own pushes (no injected revision), until it settles.
    private func closeOutcome(_ coordinator: HCExplicitEndCoordinator, panel: UUID, session: HCManagedSession,
                              within seconds: TimeInterval = 5) async -> HCPanelEndOutcome? {
        await coordinator.outcomes(for: [panel], timeout: seconds)[panel]
    }

    /// A store write hook that holds the first write after `arm()`: the claim.
    private final class HCClaimHold: @unchecked Sendable {
        private let marks = HCTestLog()
        private let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        func arm() { marks.add("armed") }
        var held: Bool { marks.read() == ["armed", "claim"] }
        var persist: @Sendable (Data, URL) throws -> Void {
            { [self] data, file in
                if marks.read() == ["armed"] {
                    marks.add("claim")
                    entered.signal()
                    _ = released.wait(timeout: .now() + 5)
                }
                try HCCreationIntentStore.persistDurably(data, file)
            }
        }
        func waitUntilHeld() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { [entered] in _ = entered.wait(timeout: .now() + 5); done.resume() }
            }
        }
        func release() { released.signal() }
    }

    private func liveTerminals(of panel: UUID, _ session: HCManagedSession) async -> [HCTerminalRecord] {
        await session.snapshot().records.values.filter { $0.state == .running && $0.labels["c11.panel"] == panel.uuidString }
    }

    /// A run that inserts its terminal, labelled from the request, at `address`.
    private static func listedRun(_ request: HCRPCRequest, _ inventory: HCTestInventory, address: String) async throws -> HCJSONValue {
        guard let panel = UUID(uuidString: request.params["labels"]["c11.panel"].string ?? ""),
              let creation = UUID(uuidString: request.params["labels"]["c11.creation"].string ?? "") else {
            throw HCUnavailableReason.malformedResponse
        }
        let machine = request.params["on"].string
        await inventory.insert(panel: panel, creation: creation, address: address, machine: machine)
        return .object(["terminal": .string(machine.map { "\($0)/\(address)" } ?? address)])
    }

    /// The 103: a panel closed before its creation sent anything. Before
    /// C11H-308 the bare CancellationError from HCUnixConnection.rpc's first step
    /// was read as an intent-store failure and invalidated the connection every
    /// terminal shares. The creation now runs to its own answer.
    func testACreationWhoseCallerIsCancelledBeforeItStartsStillSettlesAndKeepsTheConnection() async throws {
        let panel = UUID(), creation = UUID()
        let (session, log, store, _) = try await sharedConnection { request, inventory in
            try Task.checkCancellation()
            return try await Self.listedRun(request, inventory, address: "t1")
        }
        let gate = HCTestConnectGate()
        let creating = Task { () -> HCCreateResult in
            await gate.pause()
            return await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                        creationID: creation, argv: ["sh"]))
        }
        await gate.waitUntilPaused()
        creating.cancel()
        await gate.release()
        let outcome = await creating.value
        await assertSharedConnectionKept(session, log, "caller cancelled before the creation began")
        guard case .bound(let record) = outcome else { return XCTFail("a creation runs to its own answer; got \(outcome)") }
        XCTAssertEqual(record.labels["c11.creation"], creation.uuidString)
        let intent = try await store.read(panelID: panel)
        XCTAssertEqual(intent?.phase, .bound, "the creation settled; nothing is left pending")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
    }

    /// The close in its real order: the explicit end is requested while the
    /// creation's claim is still being made durable, then the start task is
    /// cancelled. The creation runs to its own answer, its create and finish
    /// events wake the pending end, and the end kills the terminal and clears.
    func testAPanelClosedWhileItsClaimIsHeldLaunchesAndItsCloseEndsIt() async throws {
        let panel = UUID(), creation = UUID(), claim = HCClaimHold()
        let (session, log, _, _) = try await sharedConnection(persist: claim.persist) { request, inventory in
            // HCUnixConnection.rpc's first step refuses a cancelled caller.
            try Task.checkCancellation()
            return try await Self.listedRun(request, inventory, address: "t1")
        }
        claim.arm()
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"])) }
        await claim.waitUntilHeld()
        XCTAssertTrue(claim.held, "the claim must be held when the panel closes")
        // Workspace's close: the explicit end, then the start task's cancel, in one turn.
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        XCTAssertTrue(coordinator.isEndPending(panelID: panel))
        claim.release()
        let outcome = await creating.value
        guard case .bound = outcome else { return XCTFail("the creation runs to its own answer; got \(outcome)") }
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second, woken by the creation's own events")
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "a closed panel's terminal survived: \(survivors.map(\.key.localAddress))")
        XCTAssertFalse(coordinator.isEndPending(panelID: panel))
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
        await assertSharedConnectionKept(session, log, "closed during the claim")
    }

    /// C11H-415: hc ends everything that carries a terminal's `HC_SCOPE` token,
    /// and c11 opened from that terminal with `open -a` carries it. Closing the
    /// panel must never end c11: the end waits, with no `terminal.kill`, and
    /// ends the terminal once no c11 app carries the token, with nothing else
    /// changing in hc (the app quitting is no hc event).
    func testClosingThePanelThatOpenedC11WaitsUntilNoC11AppCarriesItsTerminal() async throws {
        let panel = UUID(), creation = UUID(), carriers = HCTestCarriers()
        let socket = try configuration().socketURL.path
        let (session, log, _, inventory) = try await sharedConnection(scopeCarriers: { carriers.value }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound(let record) = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11", marks: [
            .init(scope: "1234-abcd", terminalID: "t1", terminalSocket: socket, holderPID: 4242)])]
        guard case .unresolved(_, .appCarriesScope) = await session.end(record.key) else {
            return XCTFail("an end that would end c11 must wait")
        }
        XCTAssertFalse(log.read().contains("terminal.kill"), "c11 is never ended with a panel")

        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), carrierRecheckSeconds: 0.05)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let held = await closeOutcome(coordinator, panel: panel, session: session, within: 0.5)
        XCTAssertEqual(held, .pending(.appCarriesScope))
        XCTAssertEqual(HCCloseCopy.endOutcomeMessage(.pending(.appCarriesScope)).hasPrefix("End held"), true)
        XCTAssertFalse(log.read().contains("terminal.kill"), "rechecked while held, never killed")

        // That c11 quit, and nothing in hc changed: the end's own recheck ends the terminal.
        carriers.value = []
        let revision = await inventory.snapshot().revision
        let ended = await closeOutcome(coordinator, panel: panel, session: session, within: 2)
        XCTAssertEqual(ended, .ended)
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
        let terminals = await inventory.records.count, after = await inventory.snapshot().revision
        XCTAssertEqual(terminals, 2, "no other terminal was added to wake it")
        XCTAssertEqual(after.sequence, revision.sequence + 1, "only the kill moved hc")
    }

    /// C11H-415: a held end is kept for the next launch, and the restored end
    /// is rechecked the same way: it ends once the carrier quits, with no hc
    /// change and one `terminal.kill` in all.
    func testAHeldEndRestoredAtLaunchEndsOnceTheCarrierQuits() async throws {
        let panel = UUID(), creation = UUID(), carriers = HCTestCarriers()
        let socket = try configuration().socketURL.path
        let (session, log, _, inventory) = try await sharedConnection(scopeCarriers: { carriers.value }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11h", marks: [
            .init(scope: "1234-abcd", terminalID: "t1", terminalSocket: socket, holderPID: 4242)])]
        let store = HCEndMemoryStore()
        var first: HCExplicitEndCoordinator? = HCExplicitEndCoordinator(session: session, store: store,
                                                                        carrierRecheckSeconds: 0.05)
        first?.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let held = await first?.outcomes(for: [panel], timeout: 0.3)[panel]
        XCTAssertEqual(held, .pending(.appCarriesScope))
        XCTAssertEqual(store.saved.map(\.identity.panelID), [panel], "the held end is kept for the next launch")
        first = nil

        let holds = HCTestLog()
        let next = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(store.saved), carrierRecheckSeconds: 0.05,
                                            onCarrierHold: { holds.add("\($0)") })
        let restored = await next.outcomes(for: [panel], timeout: 0.3)[panel]
        XCTAssertEqual(restored, .pending(.appCarriesScope), "restored while the app still carries the token")
        XCTAssertEqual(holds.read(), ["held(\(panel))"], "C11H-417: a restored hold is reported, so it gets its notice")
        XCTAssertFalse(log.read().contains("terminal.kill"))
        carriers.value = []
        let revision = await inventory.snapshot().revision
        let ended = await next.outcomes(for: [panel], timeout: 2)[panel]
        XCTAssertEqual(ended, .ended)
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
        let after = await inventory.snapshot().revision
        XCTAssertEqual(after.sequence, revision.sequence + 1, "only the kill moved hc")
        XCTAssertEqual(holds.read(), ["held(\(panel))", "released(\(panel))"])
    }

    /// C11H-417: a hold found after the close's own report window (hc was
    /// catching up when the panel closed) is still reported, once, and its
    /// release too. Nothing reports the end as ended while it is held.
    func testAHoldFoundAfterTheCloseReportWindowIsStillReportedOnce() async throws {
        let panel = UUID(), creation = UUID(), carriers = HCTestCarriers(), holds = HCTestLog()
        let socket = try configuration().socketURL.path
        let (session, log, _, inventory) = try await sharedConnection(scopeCarriers: { carriers.value }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11h", marks: [
            .init(scope: "1234-abcd", terminalID: "t1", terminalSocket: socket, holderPID: 4242)])]
        await inventory.catchUp()
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), carrierRecheckSeconds: 0.05,
                                                   onCarrierHold: { holds.add("\($0)") })
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let early = await coordinator.outcomes(for: [panel], timeout: 0.3)
        XCTAssertEqual(early[panel], .pending(.inventoryPending))
        XCTAssertEqual(HCCloseOutcomeReport.report(early, live: [panel]), .init(),
                       "the close's own window saw neither an end nor a hold: no tip")
        XCTAssertTrue(holds.read().isEmpty)

        await inventory.caughtUp()
        let held = await coordinator.outcomes(for: [panel], timeout: 0.5)[panel]
        XCTAssertEqual(held, .pending(.appCarriesScope))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(holds.read(), ["held(\(panel))"], "reported once, however often it is rechecked")
        XCTAssertFalse(log.read().contains("terminal.kill"))

        carriers.value = []
        let ended = await coordinator.outcomes(for: [panel], timeout: 2)[panel]
        XCTAssertEqual(ended, .ended)
        XCTAssertEqual(holds.read(), ["held(\(panel))", "released(\(panel))"])
    }

    /// C11H-417: the hold ends when the end goes ahead, not when it settles. The
    /// carrier quits and the kill is sent, but hc confirms nothing: the end is
    /// still pending and the app is no longer named as its reason.
    func testAHeldEndIsReleasedWhenItGoesAheadEvenIfTheKillIsNeverConfirmed() async throws {
        let panel = UUID(), creation = UUID(), carriers = HCTestCarriers(), holds = HCTestLog()
        let socket = try configuration().socketURL.path
        let (session, log, _, _) = try await sharedConnection(scopeCarriers: { carriers.value },
                                                              kill: { _, _ in .object([:]) }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11h", marks: [
            .init(scope: "1234-abcd", terminalID: "t1", terminalSocket: socket, holderPID: 4242)])]
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), carrierRecheckSeconds: 0.05,
                                                   onCarrierHold: { holds.add("\($0)") })
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let held = await coordinator.outcomes(for: [panel], timeout: 0.3)[panel]
        XCTAssertEqual(held, .pending(.appCarriesScope))
        carriers.value = []
        let after = await coordinator.outcomes(for: [panel], timeout: 0.5)[panel]
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1, "the end went ahead")
        XCTAssertNotEqual(after, .ended, "hc confirmed nothing")
        XCTAssertNotEqual(after, .pending(.appCarriesScope), "the app is no longer the reason")
        XCTAssertEqual(holds.read(), ["held(\(panel))", "released(\(panel))"],
                       "released when it went ahead, before any settle")
    }

    /// C11H-417: after the first stretch of a hold its recheck slows, driven
    /// through the coordinator (0.05 s, slowing to 1 s after 0.1 s).
    func testAHeldEndsRecheckSlowsAfterItsFirstStretch() async throws {
        let panel = UUID(), creation = UUID(), carriers = HCTestCarriers(), scans = HCTestLog()
        let socket = try configuration().socketURL.path
        let (session, _, _, _) = try await sharedConnection(scopeCarriers: { scans.add("scan"); return carriers.value }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11h", marks: [
            .init(scope: "1234-abcd", terminalID: "t1", terminalSocket: socket, holderPID: 4242)])]
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), carrierRecheckSeconds: 0.05,
                                                   carrierBackoffAfterSeconds: 0.1, carrierBackedOffSeconds: 1)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        try await Task.sleep(nanoseconds: 800_000_000)
        let count = scans.read().count
        XCTAssertGreaterThanOrEqual(count, 2, "rechecked during its first stretch")
        XCTAssertLessThanOrEqual(count, 5, "kept at 0.05 s it would have scanned about 16 times; it scanned \(count)")
        _ = coordinator
    }

    /// C11H-415: a c11 app that carries another terminal's token, or this
    /// terminal's id on another core, does not hold this end.
    func testAC11AppCarryingAnotherTerminalsTokenDoesNotHoldTheEnd() async throws {
        let panel = UUID(), carriers = HCTestCarriers()
        let socket = try configuration().socketURL.path
        carriers.value = [HCScopeCarrier(pid: 4242, bundleID: "com.stage11.c11h", marks: [
            .init(scope: "9-other", terminalID: "t7", terminalSocket: socket, holderPID: 4242),
            .init(scope: "8-other", terminalID: "t1", terminalSocket: "/other/c11-s3.sock", holderPID: 4241)])]
        let (session, log, _, _) = try await sharedConnection(scopeCarriers: { carriers.value }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound(let record) = await session.create(HCCreateRequest(
            identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: UUID(), argv: ["sh"])) else {
            return XCTFail("the terminal was not created")
        }
        guard case .pending = await session.end(record.key) else { return XCTFail("the end goes ahead") }
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
    }

    /// The same order on a replacement claimed but not yet sent: the panel
    /// keeps the old, finished key under the new creation. The close ends the
    /// old key, waits on the replacement, and kills it once its run lands.
    func testAReplacementClosedWhileItsClaimIsHeldLaunchesAndItsCloseEndsIt() async throws {
        try XCTSkipIf(true, "Flaky on the loaded CI runner; quarantined until made deterministic (C11H-431)")
        let panel = UUID(), first = UUID(), replacement = UUID(), claim = HCClaimHold()
        let (session, log, _, inventory) = try await sharedConnection(persist: claim.persist) { request, inventory in
            try Task.checkCancellation()
            let address = request.params["labels"]["c11.creation"].string == replacement.uuidString ? "t3" : "t1"
            return try await Self.listedRun(request, inventory, address: address)
        }
        guard case .bound(let old) = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                          creationID: first, argv: ["sh"])) else {
            return XCTFail("the first terminal must bind")
        }
        await inventory.finish(address: old.key.localAddress)
        let ended = HCPanelIdentity(panelID: panel, key: old.key, creationID: first, origin: .fresh)
        guard case .ended = await session.resolve(ended) else { return XCTFail("the first terminal must read as ended") }
        claim.arm()
        let replacing = Task { await session.create(HCCreateRequest(identity: ended, creationID: replacement, argv: ["sh"])) }
        await claim.waitUntilHeld()
        XCTAssertTrue(claim.held, "the replacement's claim must be held when the panel closes")
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        replacing.cancel()
        claim.release()
        let outcome = await replacing.value
        guard case .bound = outcome else { return XCTFail("the replacement runs to its own answer; got \(outcome)") }
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second")
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "the replacement survived its panel's close: \(survivors.map(\.key.localAddress))")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 2)
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1, "only the replacement was live to end")
        await assertSharedConnectionKept(session, log, "replacement closed during its claim")
    }

    /// A replacement closed while its remote shard is still being prepared,
    /// before its claim: the only intent is the previous creation's, already
    /// ended. That evidence is not about the replacement, so the close waits.
    /// C11H-313: preparation then finishes, the replacement finds its panel
    /// closed and declines before its claim, records that it never ran, and
    /// that wakes the close with no hc event: nothing launches, nothing is killed.
    func testAReplacementClosedDuringItsRemotePreparationLaunchesNothingAndItsCloseSettles() async throws {
        let panel = UUID(), first = UUID(), replacement = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let replacing = Task { await session.create(HCCreateRequest(identity: old.identity, creationID: replacement, argv: ["sh"],
                                                                    machine: "studio")) }
        await preparing.waitUntilPaused()
        // Workspace's close: the explicit end (old key, replacement creation), then the cancel.
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        replacing.cancel()
        // The coordinator looks while preparation holds: it must wait, not settle on the old creation's end.
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, .pending(.creationPending), "the close settled on an earlier creation's end")
        await preparing.release()
        let outcome = await replacing.value
        guard case .rejectedBeforeTransmission(.cancelled) = outcome else {
            return XCTFail("a closed panel's replacement declines before its claim; got \(outcome)")
        }
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second, with no hc event to wake it")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(replacement, panel: panel, store: store)
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1, "only the first terminal ran")
        XCTAssertFalse(log.read().contains("terminal.kill"), "nothing was live to end")
        await assertSharedConnectionKept(session, log, "replacement closed during preparation")
    }

    /// A remote panel whose terminal already finished, closed while that
    /// machine is offline: the key just ended is the panel's own creation, so
    /// the close settles at once rather than waiting for the link.
    func testAFinishedRemotePanelClosedWhileItsMachineIsOfflineSettlesAtOnce() async throws {
        let panel = UUID(), creation = UUID()
        let (session, log, _, inventory) = try await sharedConnection { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        guard case .bound(let record) = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                             creationID: creation, argv: ["sh"])) else {
            return XCTFail("the terminal must bind")
        }
        await inventory.finishOffline(address: record.key.localAddress)
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: record.key, creationID: creation, origin: .fresh)],
                               origin: .panelClose)
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "an ended panel's close must not wait for its machine")
        XCTAssertTrue(pendingEnds.saved.isEmpty)
        XCTAssertFalse(log.read().contains("terminal.kill"))
    }

    // MARK: C11H-313: every close settles, even when a creation never reached its claim

    /// The panel's first terminal, created, then finished (its shell exited): the identity a replacement carries.
    private func finishedFirstTerminal(_ session: HCManagedSession, _ inventory: HCTestInventory, panel: UUID,
                                       first: UUID) async throws -> (identity: HCPanelIdentity, key: HCTerminalKey) {
        guard case .bound(let old) = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                          creationID: first, argv: ["sh"])) else {
            throw HCUnavailableReason.creationPending
        }
        await inventory.finish(address: old.key.localAddress)
        let ended = HCPanelIdentity(panelID: panel, key: old.key, creationID: first, origin: .fresh)
        guard case .ended = await session.resolve(ended) else { throw HCUnavailableReason.creationPending }
        return (ended, old.key)
    }

    /// The coordinator's first look at the close has come back (a new end reads `.pending(nil)` until then).
    private func firstLook(_ coordinator: HCExplicitEndCoordinator, panel: UUID) async -> HCPanelEndOutcome? {
        var during = await coordinator.outcomes(for: [panel], timeout: 0.05)[panel]
        let limit = HCMonotonic.deadline(after: 2)
        while during == .pending(nil), HCMonotonic.now < limit {
            during = await coordinator.outcomes(for: [panel], timeout: 0.05)[panel]
        }
        return during
    }

    /// The panel's intent is this creation, ended by a rejection: it never ran.
    private func assertNeverRan(_ creation: UUID, panel: UUID, store: HCCreationIntentStore,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let intent = try? await store.read(panelID: panel)
        XCTAssertEqual(intent?.creationID, creation, "the creation must be recorded", file: file, line: line)
        XCTAssertEqual(intent?.phase, .ended, file: file, line: line)
        XCTAssertEqual(intent?.endEvidence?.kind, .createRejected, file: file, line: line)
        XCTAssertEqual(intent?.endEvidence?.creationID, creation, file: file, line: line)
    }

    /// A run that must never happen.
    private static func noRun(_ request: HCRPCRequest, _ inventory: HCTestInventory) async throws -> HCJSONValue {
        XCTFail("a creation that never reached its claim ran")
        throw HCUnavailableReason.malformedResponse
    }

    /// A fresh panel closed while its creation waits out an inventory catch-up
    /// (hc resnapshotting). The close declines the creation, which leaves the
    /// wait at once, records that it never ran, and that wakes the close while
    /// the inventory is still catching up: nothing runs, and nothing waits on hc.
    func testAPanelClosedDuringItsCreationsCatchUpLaunchesNothingAndItsCloseSettles() async throws {
        let panel = UUID(), creation = UUID(), sawCatchUp = HCTestSwitch()
        let (session, log, store, inventory) = try await sharedConnection(run: { try await Self.noRun($0, $1) })
        let watching = session.observe(on: .global()) { snapshot in
            if case .pending(.inventoryPending) = snapshot.readiness { sawCatchUp.set() }
        }
        defer { watching.cancel() }
        await inventory.catchUp()
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"])) }
        let limit = HCMonotonic.deadline(after: 2)
        while !sawCatchUp.isOn, HCMonotonic.now < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(sawCatchUp.isOn, "the creation must be waiting out the catch-up when the panel closes")
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1.5)
        XCTAssertEqual(closed, .alreadyEnded, "the close must settle within about a second, while hc is still catching up")
        guard case .pending(.inventoryPending) = await session.snapshot().readiness else {
            return XCTFail("no ready revision may have woken the close")
        }
        let outcome = await creating.value
        guard case .rejectedBeforeTransmission(.cancelled) = outcome else { return XCTFail("declined; got \(outcome)") }
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(creation, panel: panel, store: store)
        XCTAssertFalse(log.read().contains("terminal.run"))
        await inventory.caughtUp()
        await assertSharedConnectionKept(session, log, "closed during the catch-up")
    }

    /// The catch-up outlasts the creation's budget with nobody closing: create
    /// leaves before its claim, as before, but now records that the creation
    /// never ran. The panel, which already carries that creation, is closed
    /// later, while hc is still catching up, and the close settles.
    func testACreationWhoseCatchUpExpiresRecordsThatItNeverRanAndItsLaterCloseSettles() async throws {
        let panel = UUID(), creation = UUID()
        let (session, log, store, inventory) = try await sharedConnection(settleSeconds: 0.3, run: { try await Self.noRun($0, $1) })
        await inventory.catchUp()
        let outcome = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                           creationID: creation, argv: ["sh"]))
        guard case .unresolved(_, .inventoryPending) = outcome else { return XCTFail("the catch-up expired; got \(outcome)") }
        await assertNeverRan(creation, panel: panel, store: store)
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .alreadyEnded, "a creation that never ran is nothing to wait for")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertFalse(log.read().contains("terminal.run"))
        await inventory.caughtUp()
        await assertSharedConnectionKept(session, log, "catch-up expired")
    }

    /// A fresh panel closed while its remote shard is being prepared; the
    /// preparation then fails. The close was waiting on a creation no hc event
    /// will ever mention: the no-run record wakes it.
    func testAPanelClosedWhileItsRemotePreparationFailsSettlesWithNothingRun() async throws {
        let panel = UUID(), creation = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, _) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            throw POSIXError(.EHOSTUNREACH)
        }, run: { try await Self.noRun($0, $1) })
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"], machine: "studio")) }
        await preparing.waitUntilPaused()
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, .pending(.creationPending))
        await preparing.release()
        _ = await creating.value
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .alreadyEnded, "the close must settle within a second, with no hc event to wake it")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(creation, panel: panel, store: store)
        XCTAssertFalse(log.read().contains("terminal.run"))
        await assertSharedConnectionKept(session, log, "preparation failed")
    }

    /// A fresh panel closed during remote preparation that succeeds: the
    /// creation declines at its last point before the claim. Nothing runs, the
    /// close settles, and the connection every terminal shares is untouched.
    func testAPanelClosedDuringItsRemotePreparationDeclinesBeforeItsClaimAndKeepsTheConnection() async throws {
        let panel = UUID(), creation = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, _) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }, run: { try await Self.noRun($0, $1) })
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"], machine: "studio")) }
        await preparing.waitUntilPaused()
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, .pending(.creationPending))
        await preparing.release()
        let outcome = await creating.value
        guard case .rejectedBeforeTransmission(.cancelled) = outcome else { return XCTFail("declined; got \(outcome)") }
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .alreadyEnded)
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(creation, panel: panel, store: store)
        XCTAssertFalse(log.read().contains("terminal.run"))
        await assertSharedConnectionKept(session, log, "declined during preparation")
    }

    /// The connection is lost during remote preparation, before the claim,
    /// and no core answers again. The close settles from the store alone.
    func testAPanelClosedWhenItsConnectionIsLostBeforeTheClaimSettlesWithNoCore() async throws {
        let panel = UUID(), creation = UUID(), preparing = HCTestConnectGate(), refuse = HCTestSwitch()
        let (session, log, store, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }, refuse: refuse, run: { try await Self.noRun($0, $1) })
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"], machine: "studio")) }
        await preparing.waitUntilPaused()
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, .pending(.creationPending))
        refuse.set()
        await inventory.loseConnection()
        guard case .pending(.connectionLost) = await session.snapshot().readiness else {
            return XCTFail("the session must see its connection lost")
        }
        await preparing.release()
        let outcome = await creating.value
        guard case .rejectedBeforeTransmission(.connectionLost) = outcome else { return XCTFail("lost before the claim; got \(outcome)") }
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .alreadyEnded, "a creation that never ran needs no core to settle its close")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(creation, panel: panel, store: store)
        XCTAssertFalse(log.read().contains("terminal.run"))
        XCTAssertFalse(log.read().contains("refused") || log.read().contains("start"),
                       "a creation that never ran is answered from the store, with no core asked or started")
    }

    /// A read-only shard refuses every creation before its claim; the panel,
    /// which carries that creation, is then closed.
    func testAReadOnlyShardsRefusalRecordsThatTheCreationNeverRanAndItsCloseSettles() async throws {
        let panel = UUID(), creation = UUID()
        let (session, log, store, _) = try await sharedConnection(readOnly: true, run: { try await Self.noRun($0, $1) })
        let outcome = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                           creationID: creation, argv: ["sh"]))
        guard case .rejectedBeforeTransmission(.foreignSession) = outcome else { return XCTFail("refused; got \(outcome)") }
        await assertNeverRan(creation, panel: panel, store: store)
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .alreadyEnded)
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertFalse(log.read().contains("terminal.run"))
        await assertSharedConnectionKept(session, log, "read-only refusal")
    }

    /// A replacement closed during its remote preparation, which then fails:
    /// the old key is confirmed ended, the replacement is recorded never run,
    /// and the close settles with nothing run and nothing killed.
    func testAReplacementClosedWhileItsRemotePreparationFailsSettlesWithNothingRun() async throws {
        let panel = UUID(), first = UUID(), replacement = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            throw POSIXError(.EHOSTUNREACH)
        }) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let replacing = Task { await session.create(HCCreateRequest(identity: old.identity, creationID: replacement, argv: ["sh"],
                                                                    machine: "studio")) }
        await preparing.waitUntilPaused()
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        replacing.cancel()
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, .pending(.creationPending), "the close settled on an earlier creation's end")
        await preparing.release()
        _ = await replacing.value
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second, with no hc event to wake it")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        await assertNeverRan(replacement, panel: panel, store: store)
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1, "only the first terminal ran")
        XCTAssertFalse(log.read().contains("terminal.kill"), "nothing was live to end")
        await assertSharedConnectionKept(session, log, "replacement's preparation failed")
    }

    // MARK: C11H-313 repair 1: a replacement's close needs no fresh lookup of its old key

    /// What a replacement's close came to (see `closeReplacementBeforeItsClaim`).
    private struct ReplacementClose {
        let closed: HCPanelEndOutcome?
        let session: HCManagedSession
        let log: HCTestLog
        let inventory: HCTestInventory
        let pendingEnds: HCEndMemoryStore
        let store: HCCreationIntentStore
        let panel: UUID
        let replacement: UUID
    }

    /// A replacement held in remote preparation, its panel closed in the app's
    /// order (the old key and the replacement creation, then the cancel).
    /// `beforeClose` runs before the close, `afterFirstLook` after the close's
    /// first look; preparation is then released, the replacement declines and
    /// records that it never ran, and that settlement must settle the close.
    private func closeReplacementBeforeItsClaim(
        refuse: HCTestSwitch? = nil, firstLook expected: HCPanelEndOutcome,
        heldElsewhere: @escaping @Sendable (HCTerminalKey) async -> HCHolderAnswer = { _ in .none },
        beforeClose: @escaping @Sendable (HCTestInventory, HCTerminalKey) async -> Void = { _, _ in },
        afterFirstLook: @escaping @Sendable (HCManagedSession, HCTestInventory) async -> Void = { _, _ in }
    ) async throws -> ReplacementClose {
        let panel = UUID(), first = UUID(), replacement = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }, refuse: refuse) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let replacing = Task { await session.create(HCCreateRequest(identity: old.identity, creationID: replacement, argv: ["sh"],
                                                                    machine: "studio")) }
        await preparing.waitUntilPaused()
        await beforeClose(inventory, old.key)
        let pendingEnds = HCEndMemoryStore()
        // C11H-329: the coordinator's queue starts only once the close is requested, as on a
        // loaded host, where the coordinator's setup has not run yet when the close comes.
        let queue = DispatchQueue(label: "c11.hc.explicit-end.test", qos: .userInitiated)
        queue.suspend()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds, heldElsewhere: heldElsewhere,
                                                   queue: queue)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        queue.resume()
        replacing.cancel()
        let during = await firstLook(coordinator, panel: panel)
        XCTAssertEqual(during, expected, "the close's first look")
        await afterFirstLook(session, inventory)
        await preparing.release()
        _ = await replacing.value
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        return ReplacementClose(closed: closed, session: session, log: log, inventory: inventory, pendingEnds: pendingEnds,
                                store: store, panel: panel, replacement: replacement)
    }

    private func assertSettled(_ run: ReplacementClose, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(run.closed, .ended, "\(context): the close must settle within a second", file: file, line: line)
        XCTAssertTrue(run.pendingEnds.saved.isEmpty, "\(context): the persisted pending end must clear", file: file, line: line)
        await assertNeverRan(run.replacement, panel: run.panel, store: run.store, file: file, line: line)
        XCTAssertEqual(run.log.read().filter { $0 == "terminal.run" }.count, 1, "\(context): only the first terminal ran",
                       file: file, line: line)
        XCTAssertFalse(run.log.read().contains("terminal.kill"), "\(context): nothing was live to end", file: file, line: line)
    }

    /// hc starts catching up after the close's first look: the old key cannot
    /// be looked up when the replacement records that it never ran, and the
    /// close settles from that record while hc is still catching up.
    func testAReplacementClosedBeforeItsClaimSettlesWhileHCIsCatchingUp() async throws {
        let run = try await closeReplacementBeforeItsClaim(firstLook: .pending(.creationPending),
                                                           afterFirstLook: { _, inventory in await inventory.catchUp() })
        await assertSettled(run, "catching up")
        guard case .pending(.inventoryPending) = await run.session.snapshot().readiness else {
            return XCTFail("no ready revision may have woken the close")
        }
        await run.inventory.caughtUp()
        await assertSharedConnectionKept(run.session, run.log, "replacement closed during a catch-up")
    }

    /// The core is lost before the claim and none answers again: the close
    /// settles from durable state, with no core asked or started.
    ///
    /// C11H-329: the close makes one attempt before the loss. Any later attempt
    /// that reached the session before the never-run record would ask for a
    /// core; every holder lookup after the first is held until the core is
    /// lost, so such an attempt fails this test every time, not only under load.
    /// A coordinator whose setup had not run when the close came once had its
    /// feed's first delivery queued behind the close (the setup subscribed for
    /// it); that delivery then started a redundant second attempt.
    func testAReplacementClosedWhenItsCoreIsLostBeforeTheClaimSettlesWithNoCore() async throws {
        let refuse = HCTestSwitch(), lookups = HCLaterLookupHold()
        let run = try await closeReplacementBeforeItsClaim(refuse: refuse, firstLook: .pending(.creationPending),
                                                           heldElsewhere: { _ in await lookups.answer() },
                                                           afterFirstLook: { session, inventory in
            refuse.set()
            await inventory.loseConnection()
            _ = await session.snapshot()
            await lookups.release()
        })
        await assertSettled(run, "core lost")
        XCTAssertFalse(run.log.read().contains("refused") || run.log.read().contains("start"),
                       "the close asked no core and started none")
        let asked = await lookups.count
        XCTAssertEqual(asked, 1, "only the close's first attempt reached the holder lookup")
    }

    /// hc has already dropped the old terminal's record when the panel closes:
    /// the old key can never be looked up again, and the close still settles.
    func testAReplacementClosedAfterHCDroppedItsOldRecordSettles() async throws {
        let run = try await closeReplacementBeforeItsClaim(firstLook: .pending(.inventoryPending),
                                                           beforeClose: { inventory, old in
            await inventory.remove(address: old.localAddress)
        })
        await assertSettled(run, "old record dropped")
        await assertSharedConnectionKept(run.session, run.log, "old record dropped")
    }

    /// A replacement that claimed, then lost its connection before its run was
    /// sent, is rejected; its claim carried the old key's recorded end, so a
    /// later close with no core settles from durable state too.
    func testAReplacementRejectedAfterItsClaimIsClosedWithNoCoreAndSettles() async throws {
        let panel = UUID(), first = UUID(), replacement = UUID(), claim = HCClaimHold(), refuse = HCTestSwitch()
        let (session, log, store, inventory) = try await sharedConnection(persist: claim.persist, refuse: refuse) { request, inventory in
            try await Self.listedRun(request, inventory, address: "t1")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        claim.arm()
        let replacing = Task { await session.create(HCCreateRequest(identity: old.identity, creationID: replacement, argv: ["sh"])) }
        await claim.waitUntilHeld()
        XCTAssertTrue(claim.held, "the replacement's claim must be held when its connection drops")
        refuse.set()
        await inventory.loseConnection()
        _ = await session.snapshot()
        claim.release()
        _ = await replacing.value
        await assertNeverRan(replacement, panel: panel, store: store)
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second, with no core")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1, "only the first terminal ran")
    }

    // MARK: C11H-313 repair 1: a reveal's creation queued behind a hidden one's

    /// A hidden panel's replacement A waits in remote preparation; the operator
    /// reveals the panel (GhosttyTerminalView's takeover: `prepareReattach`,
    /// then a start on the native surface), whose start mints creation B,
    /// queued behind A. Returns the panel's runtime and both creations.
    @MainActor
    private func revealDuringReplacement(_ session: HCManagedSession, identity: HCPanelIdentity,
                                         preparing: HCTestConnectGate,
                                         observe: (HCPanelSession) -> Void = { _ in }) async throws
        -> (runtime: HCPanelSession, a: UUID, b: UUID, starts: [Task<Void, Never>], bridges: [HCNativeBridge]) {
        let runtime = HCPanelSession(identity: identity, session: session, registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        observe(runtime)
        let spec = HCPanelLaunchSpec(argv: ["sh"], cwd: nil, environment: [:], initialInput: nil, machine: "studio")
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let hidden = HCNativeBridge.headless(panelID: identity.panelID, report: { _ in })
        let hiddenStart = Task { @MainActor in
            _ = try? await runtime.attachSurface(launch: spec, bridge: hidden, display: display, replaceEnded: true)
        }
        await preparing.waitUntilPaused()
        let a = try XCTUnwrap(runtime.identity.creationID)
        runtime.prepareReattach()
        let native = HCNativeBridge.headless(panelID: identity.panelID, report: { _ in })
        let nativeStart = Task { @MainActor in
            _ = try? await runtime.attachSurface(launch: spec, bridge: native, display: display, replaceEnded: true)
        }
        let limit = HCMonotonic.deadline(after: 2)
        while runtime.identity.creationID == a, HCMonotonic.now < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        let b = try XCTUnwrap(runtime.identity.creationID)
        XCTAssertNotEqual(a, b, "the reveal's start must mint its own creation")
        return (runtime, a, b, [hiddenStart, nativeStart], [hidden, native])
    }

    /// Repair 1 (Astra 2): the reveal's creation B queues behind A instead of
    /// recording itself never run while A can still run. The close declines
    /// both (B is the one it carries; A is under way), each records that it
    /// never ran, A first, and the close settles on B's record: nothing
    /// launches after the panel is gone.
    @MainActor
    func testARevealDuringAReplacementsPreparationThenACloseLaunchesNothing() async throws {
        let panel = UUID(), first = UUID(), preparing = HCTestConnectGate()
        let (session, log, store, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }) { request, inventory in
            try await Self.listedRun(request, inventory, address: request.params["labels"]["c11.creation"].string == first.uuidString ? "t1" : "t3")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let reveal = try await revealDuringReplacement(session, identity: old.identity, preparing: preparing)
        // Workspace's close: the explicit end of what the panel carries now, then the teardown.
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([reveal.runtime.identity], origin: .panelClose)
        reveal.runtime.detachSurface()
        await preparing.release()
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second")
        for start in reveal.starts { await start.value }
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "a terminal outlived its panel's close: \(survivors.map(\.key.localAddress))")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1, "neither A nor B may launch after the close")
        await assertNeverRan(reveal.b, panel: panel, store: store)
        for bridge in reveal.bridges { bridge.retire {} }
    }

    /// Repair 2 (Astra v322): the reveal succeeds with no close. B, queued
    /// behind A, binds to the terminal A launched, and the panel takes A as its
    /// creation: in its runtime identity, its restore state and its restore
    /// projection. A's command later exits on its own and the panel is closed;
    /// the close follows A and settles.
    @MainActor
    func testARevealedPanelBoundToItsHiddenStartsTerminalClosesAfterThatTerminalExits() async throws {
        let panel = UUID(), first = UUID(), preparing = HCTestConnectGate(), restore = HCRestoreLifecycleStore()
        let (session, log, _, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }) { request, inventory in
            try await Self.listedRun(request, inventory, address: request.params["labels"]["c11.creation"].string == first.uuidString ? "t1" : "t3")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let reveal = try await revealDuringReplacement(session, identity: old.identity, preparing: preparing,
                                                       observe: { restore.observe($0) })
        defer { restore.forget(reveal.runtime); for bridge in reveal.bridges { bridge.retire {} } }
        await preparing.release()
        let limit = HCMonotonic.deadline(after: 5)
        while reveal.runtime.attachment == nil, HCMonotonic.now < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        guard reveal.runtime.attachment != nil else {
            return XCTFail("the revealed panel must attach; identity \(reveal.runtime.identity), lifecycle \(reveal.runtime.lifecycle)")
        }
        for start in reveal.starts { await start.value }
        XCTAssertEqual(reveal.runtime.identity.key?.localAddress, "t3")
        XCTAssertEqual(reveal.runtime.identity.creationID, reveal.a, "the panel takes the creation that ran")
        XCTAssertEqual(HCPanelRestoreState.shared.entry(for: panel)?.creation?.creationID, reveal.a,
                       "restore state names the creation that ran")
        XCTAssertTrue(restore.permitsResume(reveal.runtime), "the restore projection binds the creation that ran")
        // A's command exits on its own; later the operator closes the panel, in the app's order.
        await inventory.finish(address: "t3")
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([reveal.runtime.identity], origin: .panelClose)
        reveal.runtime.detachSurface()
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must settle within a second")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 2, "only A launched, never B")
        XCTAssertFalse(log.read().contains("terminal.kill"), "A had already exited")
    }

    /// The same reveal, but A has claimed and is running when the panel closes,
    /// which still carries the old key and B. A launched past every point it
    /// could decline, so the close follows the panel's live terminal, A's, and
    /// ends it; B, queued behind it, binds nothing and records nothing.
    @MainActor
    func testARevealedPanelWhoseHiddenStartLaunchedEndsThatTerminalWhenItCloses() async throws {
        let panel = UUID(), first = UUID(), preparing = HCTestConnectGate(), hold = HCTestRunHold()
        let (session, log, _, inventory) = try await sharedConnection(prepareRemote: { _, _ in
            await preparing.pause()
            return [:]
        }) { request, inventory in
            guard request.params["labels"]["c11.creation"].string != first.uuidString else {
                return try await Self.listedRun(request, inventory, address: "t1")
            }
            await hold.markHeld()
            while !(await hold.released) { try await Task.sleep(nanoseconds: 2_000_000) }
            return try await Self.listedRun(request, inventory, address: "t3")
        }
        let old = try await finishedFirstTerminal(session, inventory, panel: panel, first: first)
        let reveal = try await revealDuringReplacement(session, identity: old.identity, preparing: preparing)
        await preparing.release()
        await hold.waitUntilHeld()
        XCTAssertEqual(reveal.runtime.identity.key, old.key, "the panel still carries the old key when it closes")
        let pendingEnds = HCEndMemoryStore()
        let coordinator = HCExplicitEndCoordinator(session: session, store: pendingEnds)
        coordinator.requestEnd([reveal.runtime.identity], origin: .panelClose)
        reveal.runtime.detachSurface()
        await hold.release()
        let closed = await closeOutcome(coordinator, panel: panel, session: session, within: 1)
        XCTAssertEqual(closed, .ended, "the close must end the terminal A launched")
        for start in reveal.starts { await start.value }
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "A's terminal outlived its panel's close: \(survivors.map(\.key.localAddress))")
        XCTAssertTrue(pendingEnds.saved.isEmpty, "the persisted pending end must clear")
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 2, "only A launched, never B")
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
        for bridge in reveal.bridges { bridge.retire {} }
    }

    /// The other 2: a panel closed while hc was running its terminal. The run
    /// settles on its own (the engine answers a cancelled pending call at once,
    /// as possibly sent, so it may not be abandoned), and the close's explicit
    /// end then ends the terminal it made. Nothing else is touched.
    func testAPanelClosedWhileItsTerminalIsCreatingKeepsTheOthersAndLeavesNoOrphan() async throws {
        let panel = UUID(), creation = UUID(), hold = HCTestRunHold()
        let (session, log, store, _) = try await sharedConnection { request, inventory in
            await hold.markHeld()
            while !(await hold.released) {
                do { try await Task.sleep(nanoseconds: 2_000_000) }
                catch { throw HCRPCFailure(reason: .cancelled, transmission: .possible, remoteCode: nil) }
            }
            return try await Self.listedRun(request, inventory, address: "t1")
        }
        let creating = Task { await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                   creationID: creation, argv: ["sh"])) }
        await hold.waitUntilHeld()
        // The close: the explicit end, then HCPanelRuntime.detachSurface cancels the panel's start task.
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)], origin: .panelClose)
        creating.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        await hold.release()
        let outcome = await creating.value
        await assertSharedConnectionKept(session, log, "caller cancelled during the run")
        guard case .bound = outcome else {
            return XCTFail("the run hc was already running must settle, not be abandoned as uncertain; got \(outcome)")
        }
        let closed = await closeOutcome(coordinator, panel: panel, session: session)
        XCTAssertEqual(closed, .ended)
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "a closed panel's terminal survived: \(survivors.map(\.key.localAddress))")
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1)
        XCTAssertEqual(log.read().filter { $0 == "terminal.run" }.count, 1)
        let intent = try await store.read(panelID: panel)
        XCTAssertEqual(intent?.phase, .ended)
        await assertSharedConnectionKept(session, log, "after the end")
    }

    /// A panel replacing a terminal that already finished keeps the old key
    /// while the replacement is created. Closed then, its explicit end found
    /// the old terminal finished and settled, and the replacement it was
    /// already running launched with no panel. The close ends the replacement.
    func testClosingAPanelWhileItsReplacementIsCreatingEndsTheReplacement() async throws {
        let panel = UUID(), first = UUID(), replacement = UUID(), hold = HCTestRunHold(), held = HCTestLog()
        let (session, log, _, inventory) = try await sharedConnection { request, inventory in
            guard request.params["labels"]["c11.creation"].string == replacement.uuidString else {
                return try await Self.listedRun(request, inventory, address: "t1")
            }
            held.add("held")
            await hold.markHeld()
            while !(await hold.released) {
                do { try await Task.sleep(nanoseconds: 2_000_000) }
                catch { throw HCRPCFailure(reason: .cancelled, transmission: .possible, remoteCode: nil) }
            }
            return try await Self.listedRun(request, inventory, address: "t3")
        }
        // The panel's first terminal, created and then finished (its shell exited).
        guard case .bound(let old) = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                          creationID: first, argv: ["sh"])) else {
            return XCTFail("the first terminal must bind")
        }
        await inventory.finish(address: old.key.localAddress)
        let ended = HCPanelIdentity(panelID: panel, key: old.key, creationID: first, origin: .fresh)
        guard case .ended = await session.resolve(ended) else { return XCTFail("the first terminal must read as ended") }
        // HCPanelRuntime.attachSurface: the replacement's request carries the ended identity, and the
        // panel keeps the old key under the new creation while it runs.
        let replacing = Task { await session.create(HCCreateRequest(identity: ended, creationID: replacement, argv: ["sh"])) }
        await hold.waitUntilHeld()
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: old.key, creationID: replacement, origin: .fresh)],
                               origin: .panelClose)
        replacing.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        await hold.release()
        _ = await replacing.value
        let closed = await closeOutcome(coordinator, panel: panel, session: session)
        let survivors = await liveTerminals(of: panel, session)
        XCTAssertTrue(survivors.isEmpty, "the replacement survived its panel's close: \(survivors.map(\.key.localAddress))")
        XCTAssertEqual(closed, .ended)
        XCTAssertEqual(held.read(), ["held"])
        XCTAssertEqual(log.read().filter { $0 == "terminal.kill" }.count, 1, "only the replacement was live to end")
        await assertSharedConnectionKept(session, log, "replacement closed")
    }

    /// The brief's reproduction: the connection itself reports a cancelled run.
    /// It is unresolved as cancelled (never an intent-store failure) and the
    /// connection stays; a connection that did close says so through its inventory.
    func testACancelledRunIsNeverAStoreFailureAndNeverDropsTheSharedConnection() async throws {
        let failures: [any Error] = [CancellationError(), HCRPCFailure(reason: .cancelled, transmission: .possible, remoteCode: nil)]
        for failure in failures {
            let panel = UUID()
            let (session, log, store, _) = try await sharedConnection { _, _ in throw failure }
            let outcome = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                               creationID: UUID(), argv: ["sh"]))
            await assertSharedConnectionKept(session, log, "\(failure)")
            let intent = try await store.read(panelID: panel)
            if failure is CancellationError {
                // HCUnixConnection.rpc's first step: nothing was enqueued, so the creation is definitely rejected.
                guard case .rejectedBeforeTransmission(.cancelled) = outcome else { XCTFail("\(failure): got \(outcome)"); continue }
                XCTAssertEqual(intent?.endEvidence?.kind, .createRejected, "\(failure)")
            } else {
                // Possibly sent: the record waits for the inventory to settle it, as any uncertain run does.
                guard case .unresolved(_, .cancelled) = outcome else { XCTFail("\(failure): got \(outcome)"); continue }
                XCTAssertEqual(intent?.phase, .uncertain, "\(failure)")
            }
        }
    }

    /// Acceptance 3: a real failure of the connection still drops it.
    func testARealConnectionFailureDuringARunStillDropsTheConnection() async throws {
        for reason in [HCUnavailableReason.connectionLost, .deadlineExceeded] {
            let (session, log, _, _) = try await sharedConnection { _, _ in
                throw HCRPCFailure(reason: reason, transmission: .possible, remoteCode: nil)
            }
            let outcome = await session.create(HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                                                               creationID: UUID(), argv: ["sh"]))
            guard case .unresolved(_, let got) = outcome, got == reason else { XCTFail("\(reason): got \(outcome)"); continue }
            XCTAssertTrue(log.read().contains("close"), "\(reason): a failed connection must be closed")
            XCTAssertTrue(log.read().contains("detach:t2"), "\(reason): attachments on a failed connection must be released")
            guard case .pending(let pending) = await session.snapshot().readiness, pending == reason else {
                XCTFail("\(reason): the inventory must report the loss"); continue
            }
        }
    }

    /// The catch's audit: only the intent store's own failure is named one.
    func testACreationNamesTheTransportOrTheCancellationNeverAStoreFailure() async throws {
        // A transport error hc was sent: it is the transport's, and the connection is dropped as before.
        let (sent, sentLog, _, _) = try await sharedConnection { _, _ in throw POSIXError(.EIO) }
        let sentOutcome = await sent.create(HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh),
                                                            creationID: UUID(), argv: ["sh"]))
        guard case .unresolved(_, let sentReason) = sentOutcome else { return XCTFail("got \(sentOutcome)") }
        XCTAssertNotEqual(sentReason, .intentStoreFailure)
        XCTAssertTrue(sentLog.read().contains("close"))
        // A cancellation before anything was claimed or sent (a remote shard's preparation): nothing to settle.
        let panel = UUID()
        let (remote, remoteLog, store, _) = try await sharedConnection(prepareRemote: { _, _ in throw CancellationError() }) { _, _ in
            XCTFail("nothing may run after a cancelled preparation"); return .null
        }
        let remoteOutcome = await remote.create(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                                                creationID: UUID(), argv: ["sh"], machine: "studio"))
        guard case .rejectedBeforeTransmission(.cancelled) = remoteOutcome else { return XCTFail("got \(remoteOutcome)") }
        let intent = try await store.read(panelID: panel)
        // Nothing was claimed; C11H-313 records the creation as never run.
        XCTAssertEqual(intent?.phase, .ended)
        XCTAssertEqual(intent?.endEvidence?.kind, .createRejected)
        await assertSharedConnectionKept(remote, remoteLog, "cancelled preparation")
    }
}

private actor HCEnvironmentRuns {
    var requests: [HCJSONValue] = []
    func append(_ request: HCJSONValue) -> Int {
        requests.append(request)
        return requests.count
    }
    func last() throws -> HCJSONValue { try XCTUnwrap(requests.last) }
}

/// C11H-273: exercise both production terminal.run producers, then execute
/// their emitted argv with a synthetic core environment. No core, app, user
/// configuration, credentials, or live terminal participates in these tests.
final class HCTerminalEnvironmentTests: XCTestCase {
    private func fixture(rejectFirst: Bool = false) throws
        -> (HCManagedSession, HCLaunchConfiguration, HCTestInventory, HCEnvironmentRuns) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hc-env-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let core = try HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/test"), tag: nil,
            inherited: ["XDG_CONFIG_HOME": "/user/config", "PATH": "/usr/bin:/bin"])
        let c = HCLaunchConfiguration(executableURL: core.executableURL, session: core.session,
            socketURL: core.socketURL, stateDirectory: root, intentDirectory: root.appendingPathComponent("intents"),
            environment: core.environment, pin: core.pin, configDirectory: core.configDirectory)
        let log = HCTestLog(), inventory = HCTestInventory(), runs = HCEnvironmentRuns()
        let factory = HCTestFactory(pid: 1, log: log) { request in
            if request.method == "terminal.attach" { return .object(["channel": .integer(7)]) }
            guard request.method == "terminal.run" else { throw HCUnavailableReason.malformedResponse }
            let count = await runs.append(request.params)
            if rejectFirst && count == 1 {
                throw HCRPCFailure(reason: .invalidLaunchTuple, transmission: .rejectedByPeer, remoteCode: nil)
            }
            if let panel = request.params["labels"]["c11.panel"].string.flatMap(UUID.init(uuidString:)),
               let creation = request.params["labels"]["c11.creation"].string.flatMap(UUID.init(uuidString:)) {
                await inventory.insert(panel: panel, creation: creation)
            }
            return .object(["terminal": .string("t1")])
        }
        let session = HCManagedSession(configuration: c, connections: factory, verifier: HCTestVerifier(log: log),
            launcher: HCTestLauncher(log: log), processes: HCTestProcesses(log: log),
            intents: HCCreationIntentStore(directory: c.intentDirectory),
            prepareAttachment: HCBackendComposition.prepareAttachment,
            makeInventory: { connection, build in await inventory.bind(generation: connection.generation, build: build); return inventory },
            makeAttachment: { key, generation, _, sink, _ in
                let attachment = HCTestAttachment(key: key, generation: generation)
                guard let bridge = sink as? HCNativeBridge,
                      bridge.bind(generation: generation, input: attachment.input) else { throw HCUnavailableReason.cancelled }
                return attachment
            })
        return (session, c, inventory, runs)
    }

    /// Both normal and headless startup use this snapshot -> shell integration
    /// -> placement chain before HCPanelSession forwards it to create.
    private func startup(_ c: HCLaunchConfiguration, app: [String: String] = [:],
                         global: [String: String] = [:], panel: [String: String] = [:],
                         remote: HCRemoteTarget? = nil) throws -> HCPanelLaunchSpec {
        let snapshot = HCNativeLaunchSnapshot(command: .direct(["/usr/bin/env"]),
            environment: HCLaunchPolicy.inheritedAppEnvironment(app), overrides: global, workingDirectory: "/")
        let tuple = HCShellIntegration.launchTuple(command: snapshot.effectiveCommand(override: nil),
            base: snapshot.environment, globalOverrides: snapshot.overrides, panel: panel,
            mode: "none", configuration: c)
        return HCPanelLaunchSpec.placed(argv: try XCTUnwrap(snapshot.argv(command: tuple.command)), localCwd: "/",
            environment: tuple.environment, initialInput: nil, remote: remote, panelEnvironment: panel)
    }

    private func create(_ spec: HCPanelLaunchSpec, session: HCManagedSession,
                        identity: HCPanelIdentity = HCPanelIdentity(panelID: UUID(), origin: .fresh)) async -> HCCreateResult {
        await session.create(HCCreateRequest(identity: identity, creationID: UUID(), argv: spec.argv,
            cwd: spec.cwd, environment: spec.environment, initialInput: spec.initialInput, machine: spec.machine))
    }

    /// Use the real emitted wrapper, not an assertion that a helper returned
    /// the expected flags. env exits itself and prints only synthetic values.
    private func childEnvironment(_ request: HCJSONValue, core: [String: String],
                                  file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let argv = try XCTUnwrap(request["argv"].array, file: file, line: line).compactMap(\.string)
        let overlay = try XCTUnwrap(request["env"].object, file: file, line: line).compactMapValues(\.string)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(argv.first))
        process.arguments = Array(argv.dropFirst())
        process.environment = core.merging(overlay) { _, terminal in terminal }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, file: file, line: line)
        var result: [String: String] = [:]
        for entry in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    private func assertIsolated(_ request: HCJSONValue, configuration: HCLaunchConfiguration,
                                xdg: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        // Model hc's injected terminal identity independently of launch knobs.
        var core = configuration.environment
        core["HC_TERMINAL_ID"] = "t1"
        core["HC_TERMINAL_SOCKET"] = "/synthetic/terminal.sock"
        core["HC_SCOPE"] = "synthetic-scope"
        core.removeValue(forKey: "SSH_CONNECTION") // pinned hc program_env strips SSH login markers
        let child = try childEnvironment(request, core: core, file: file, line: line)
        XCTAssertEqual(child["XDG_CONFIG_HOME"], xdg, file: file, line: line)
        XCTAssertNil(child["HC_SPAWN_MS"], file: file, line: line)
        XCTAssertNil(child["HC_LAUNCHD_DIRECT"], file: file, line: line)
        for key in ["HC_SESSION", "HC_SOCKET", "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE"] {
            XCTAssertEqual(child[key], core[key], key, file: file, line: line)
        }
        XCTAssertEqual(configuration.environment["XDG_CONFIG_HOME"], configuration.configDirectory?.path,
                       "terminal normalization must not change the core's config", file: file, line: line)
        XCTAssertEqual(configuration.environment["HC_SPAWN_MS"], "10000", file: file, line: line)
        XCTAssertNotNil(configuration.environment["HC_LAUNCHD_DIRECT"], file: file, line: line)
    }

    func testNormalStartupKeepsUserXDGByProvenance() async throws {
        let (session, c, _, runs) = try fixture()
        // Equality with the private directory is still an intentional user value.
        for value in [nil, "/user/config", "", c.configDirectory!.path] as [String?] {
            let app = value.map { ["XDG_CONFIG_HOME": $0] } ?? [:]
            let spec = try startup(c, app: app)
            guard case .bound = await create(spec, session: session) else { return XCTFail("new creation did not bind") }
            try assertIsolated(try await runs.last(), configuration: c, xdg: value)
        }
        let spec = try startup(c, app: ["XDG_CONFIG_HOME": "/user/config"],
            global: ["XDG_CONFIG_HOME": "/global/config"], panel: ["XDG_CONFIG_HOME": "/panel/config"])
        guard case .bound = await create(spec, session: session) else { return XCTFail("panel creation did not bind") }
        try assertIsolated(try await runs.last(), configuration: c, xdg: "/panel/config")
    }

    @MainActor
    private func attachHeadless(_ spec: HCPanelLaunchSpec, session: HCManagedSession, identity: HCPanelIdentity,
                                replaceEnded: Bool = false) async throws {
        let runtime = HCPanelSession(identity: identity, session: session, registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        let bridge = HCNativeBridge.headless(panelID: identity.panelID, report: { _ in })
        defer { runtime.detachSurface(); bridge.retire {} }
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        _ = try await runtime.attachSurface(launch: spec, bridge: bridge, display: display, replaceEnded: replaceEnded)
    }

    @MainActor
    func testHeadlessStartupNormalizesThroughTheRealPanelRuntime() async throws {
        for value in [nil, "/headless/config", ""] as [String?] {
            let (session, c, _, runs) = try fixture()
            let spec = try startup(c, app: value.map { ["XDG_CONFIG_HOME": $0] } ?? [:])
            try await attachHeadless(spec, session: session, identity: HCPanelIdentity(panelID: UUID(), origin: .fresh))
            try assertIsolated(try await runs.last(), configuration: c, xdg: value)
        }
    }

    @MainActor
    func testHostEndAndOutsideSignalReplacementKeepEnvironmentWithoutStartupWrapper() async throws {
        for reason in ["server_stop", "signal"] {
            for value in [nil, "/user/config", ""] as [String?] {
                let (session, c, inventory, runs) = try fixture()
                let panel = UUID()
                await inventory.insertFinished(panel: panel, address: "t-old", reason: reason)
                let identity = HCPanelIdentity(panelID: panel,
                    key: HCTerminalKey(owningCoreID: "core", localAddress: "t-old"), origin: .restored)
                let previous = try startup(c, app: value.map { ["XDG_CONFIG_HOME": $0] } ?? [:])
                let snapshot = HCNativeLaunchSnapshot(command: .direct(["/usr/bin/env"]), environment: [:],
                    overrides: [:], workingDirectory: nil)
                let replacement = previous.replacingEndedWithShell(argv: try XCTUnwrap(snapshot.argv(override: nil)))
                XCTAssertNil(replacement.initialInput)
                try await attachHeadless(replacement, session: session, identity: identity, replaceEnded: true)
                try assertIsolated(try await runs.last(), configuration: c, xdg: value)
            }
        }
    }

    func testRejectedStartRetryNormalizesTheNewRunAgain() async throws {
        let (session, c, _, runs) = try fixture(rejectFirst: true)
        let spec = try startup(c), identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        _ = await create(spec, session: session, identity: identity)
        try assertIsolated(try await runs.last(), configuration: c, xdg: nil)
        guard case .bound = await create(spec, session: session, identity: identity) else { return XCTFail("retry did not bind") }
        let count = await runs.requests.count
        XCTAssertEqual(count, 2)
        try assertIsolated(try await runs.last(), configuration: c, xdg: nil)
    }

    func testRemotePlacementAndDefaultShellNormalizeAtTheWire() async throws {
        // Synthetic far shell prints env without reading any startup files.
        let (session, c, _, runs) = try fixture()
        let shell = c.intentDirectory.deletingLastPathComponent().appendingPathComponent("far shell")
        try Data("#!/bin/sh\nexec /usr/bin/env\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var farCore = c.environment
        farCore["SHELL"] = shell.path
        for value in [nil, "/far/config", ""] as [String?] {
            let spec = try startup(c, app: ["XDG_CONFIG_HOME": "/local/config"],
                panel: value.map { ["XDG_CONFIG_HOME": $0] } ?? [:], remote: HCRemoteTarget(machine: "test-no-relay"))
            _ = await create(spec, session: session)
            let request = try await runs.last()
            XCTAssertEqual(request["on"].string, "test-no-relay")
            let child = try childEnvironment(request, core: farCore)
            XCTAssertEqual(child["XDG_CONFIG_HOME"], value)
            XCTAssertNil(child["HC_SPAWN_MS"])
            XCTAssertNil(child["HC_LAUNCHD_DIRECT"])
        }
        // No argv must still get the guard before the owning machine's default shell.
        _ = await create(HCPanelLaunchSpec(argv: [], cwd: "/", environment: [:], initialInput: nil), session: session)
        let child = try childEnvironment(try await runs.last(), core: farCore)
        XCTAssertNil(child["XDG_CONFIG_HOME"])
        XCTAssertNil(child["HC_SPAWN_MS"])
        XCTAssertNil(child["HC_LAUNCHD_DIRECT"])
    }

    func testManagedHCRunUsesTheSameGuardAndKeepsCallerAndExplicitXDG() async throws {
        let (session, c, _, runs) = try fixture()
        for value in [nil, "/caller/config", "", c.configDirectory!.path] as [String?] {
            var caller = ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path]
            caller["XDG_CONFIG_HOME"] = value
            let command = try HCManagedCommandParser.parse(["run", "--", "/usr/bin/env"], environment: caller, cwd: "/")
            _ = try await session.managedCommand(command)
            try assertIsolated(try await runs.last(), configuration: c, xdg: value)
        }
        let command = try HCManagedCommandParser.parse(["run", "--env", "XDG_CONFIG_HOME=/explicit", "--", "/usr/bin/env"],
            environment: ["HC_SESSION": c.session, "HC_SOCKET": c.socketURL.path, "XDG_CONFIG_HOME": "/caller"], cwd: "/")
        _ = try await session.managedCommand(command)
        try assertIsolated(try await runs.last(), configuration: c, xdg: "/explicit")
        // The RPC boundary also refuses identity/launch overrides from a
        // caller that did not pass through the CLI parser.
        let forged = HCManagedCommand(session: c.session, socket: c.socketURL.path, verb: .run,
            argv: ["/usr/bin/env"], environment: ["HC_SESSION": "foreign", "HC_SCOPE": "foreign",
                                                "HC_SPAWN_MS": "1", "HC_LAUNCHD_DIRECT": "1"])
        _ = try await session.managedCommand(forged)
        try assertIsolated(try await runs.last(), configuration: c, xdg: nil)
    }
}

/// C11H-327: the late-reply marks the session handed out with its attaches, in order.
private final class HCLateReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [HCLateReply] = []
    func add(_ mark: HCLateReply?) { guard let mark else { return }; lock.lock(); marks.append(mark); lock.unlock() }
    var last: HCLateReply? { lock.lock(); defer { lock.unlock() }; return marks.last }
}

private final class HCAttachCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Counts link-script runs and answers with one status.
/// C11H-365 (N13): migrates a via the way `c11-atlas-link.sh migrate` does.
private final class MigratingRunner: HCMachineSetupRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let via: URL
    let pinned: String
    init(via: URL, pinned: String) { self.via = via; self.pinned = pinned }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        lock.lock(); count += 1; lock.unlock()
        try? pinned.write(to: via, atomically: true, encoding: .utf8)
        return HCMachineSetupOutput(status: 0, stdout: "migrated\n", stderr: "")
    }
}

private final class CountingRunner: HCMachineSetupRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let status: Int32
    let touching: URL?
    init(status: Int32, touching: URL? = nil) { self.status = status; self.touching = touching }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        lock.lock(); count += 1; let n = count; lock.unlock()
        if let touching {
            let temporary = touching.appendingPathComponent("via.migrate.\(n)")
            FileManager.default.createFile(atPath: temporary.path, contents: Data("x".utf8))
            try? FileManager.default.removeItem(at: temporary)
        }
        return HCMachineSetupOutput(status: status, stdout: "", stderr: "")
    }
}
