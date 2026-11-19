import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCAtlasViaTests: XCTestCase {
    private let remoteHome = URL(fileURLWithPath: "/tmp/c11-atlas-home", isDirectory: true)
    private let localHome = URL(fileURLWithPath: "/tmp/c11-local-home", isDirectory: true)

    func testReleaseSessionAndLiteralDebugTag() {
        XCTAssertEqual(HCAtlasLink.sessionName(debugTag: nil), HCAtlasLink.releaseSession)
        XCTAssertEqual(HCAtlasLink.sessionName(debugTag: ""), HCAtlasLink.releaseSession)
        XCTAssertEqual(HCAtlasLink.sessionName(debugTag: "c11-b"), "c11-c11-b")
        XCTAssertNotEqual(HCAtlasLink.sessionName(debugTag: "c11-b"), HCAtlasLink.releaseSession)
        XCTAssertNotEqual(HCAtlasLink.sessionName(debugTag: "c11-b"), "default")
        XCTAssertNil(HCAtlasLink.sessionName(debugTag: "../bin"))
    }

    func testLaunchTupleUsesCurrentPinAndSanitizedEnv() throws {
        let link = try XCTUnwrap(sshLink(debugTag: "c11-b"))
        XCTAssertEqual(link.configuration.pin, HCPin.current)
        XCTAssertEqual(link.session, "c11-c11-b")
        XCTAssertEqual(link.sshTarget, "studio")
        XCTAssertTrue(link.configuration.executableURL.path.hasSuffix(
            "/.local/share/c11/hc/\(HCPin.current.version)-\(HCPin.current.executableSHA256.prefix(12))/herdr-core"
        ))
        XCTAssertFalse(link.configuration.executableURL.path.contains("/.local/bin/"))
        XCTAssertEqual(link.remoteArgv, [
            link.configuration.executableURL.path, "connect", "--session", link.session,
        ])
        XCTAssertEqual(link.configuration.environment["HC_SESSION"], link.session)
        XCTAssertEqual(link.configuration.environment["HC_SOCKET"], link.configuration.socketURL.path)
        XCTAssertEqual(link.configuration.environment["HC_SPAWN_MS"], String(HCLimits.spawnMilliseconds))
        XCTAssertEqual(link.configuration.environment["PATH"], HCAtlasLink.remotePath)
        XCTAssertNil(link.configuration.environment["SSH_AUTH_SOCK"])
        XCTAssertEqual(link.configuration.environment["XDG_CONFIG_HOME"], remoteHome.path + "/.local/share/c11/config")
        XCTAssertEqual(Set(link.configuration.environment.keys.filter { $0.hasPrefix("XDG_") }), ["XDG_CONFIG_HOME"])
        XCTAssertNil(link.configuration.environment["HC_LAUNCHD_DIRECT"])
        XCTAssertNil(link.configuration.environment["SSH_CONNECTION"])
        XCTAssertNil(link.bridgeCommand)
        XCTAssertEqual(
            link.configuration.stateDirectory.path,
            "/tmp/c11-atlas-home/.local/state/herdr-core/c11-c11-b"
        )
    }

    func testCoreEnvironmentRejectsForeignConfigAndExtraVariables() throws {
        let link = try sshLink(debugTag: nil)
        let valid = link.configuration.environment
        XCTAssertTrue(HCAtlasLink.sanitized(valid, session: link.session, socket: link.configuration.socketURL.path))
        for (key, value) in [("XDG_CONFIG_HOME", "/foreign/config"), ("XDG_CACHE_HOME", "/tmp/cache"),
                             ("SSH_AUTH_SOCK", "/tmp/agent"), ("HC_LAUNCHD_DIRECT", "12"),
                             ("SSH_CONNECTION", "local 0 remote 0")] {
            var invalid = valid
            invalid[key] = value
            XCTAssertFalse(HCAtlasLink.sanitized(invalid, session: link.session, socket: link.configuration.socketURL.path), key)
        }
        var missing = valid
        missing.removeValue(forKey: "XDG_CONFIG_HOME")
        XCTAssertFalse(HCAtlasLink.sanitized(missing, session: link.session, socket: link.configuration.socketURL.path))
    }

    func testBridgeDoesNotDialPathHerdr() throws {
        let link = try XCTUnwrap(result(HCAtlasLink.make(
            mode: .bridge,
            sshTarget: "studio",
            remoteHome: remoteHome,
            localHome: localHome,
            user: "demo",
            debugTag: nil,
            bridgeSocket: "/tmp/c11-bridge.sock"
        )))
        XCTAssertEqual(link.session, HCAtlasLink.releaseSession)
        XCTAssertEqual(link.bridgeCommand, "exec /usr/bin/nc -U /tmp/c11-bridge.sock")
        XCTAssertFalse(link.bridgeCommand?.contains("command -v") ?? true)
        XCTAssertFalse(link.bridgeCommand?.contains(".local/bin") ?? true)
        XCTAssertEqual(link.remoteArgv.first, link.configuration.executableURL.path)
    }

    func testOverlongSocketIsInvalid() {
        let home = URL(fileURLWithPath: "/" + String(repeating: "h", count: 80), isDirectory: true)
        let result = HCAtlasLink.make(
            mode: .ssh,
            sshTarget: "studio",
            remoteHome: home,
            localHome: localHome,
            user: "demo",
            debugTag: nil
        )
        guard case .failure(let reason) = result else {
            return XCTFail("overlong socket was accepted")
        }
        XCTAssertEqual(reason, .invalidLaunchTuple)
    }

    func testDisconnectedStaysUnresolvedAndPersistent() {
        let identity = sampleIdentity()
        for state in ["connecting", "unreachable", "needs_login", "needs_update", "other"] {
            let availability = HCAtlasLink.availability(machineState: state)
            XCTAssertEqual(availability, .disconnected, state)
            assertConnectionLost(HCAtlasLink.resolve(
                identity: identity,
                availability: availability,
                snapshot: readySnapshot([])
            ), identity: identity)
        }
        XCTAssertTrue(HCAtlasLink.tellsOrchestrator(machineState: "needs_login"))
        XCTAssertFalse(HCAtlasLink.tellsOrchestrator(machineState: "unreachable"))
    }

    func testUnknownIsConnectionLostAndLocalStaysLocal() {
        let identity = sampleIdentity()
        XCTAssertEqual(HCAtlasLink.availability(machineState: nil), .unknown)
        assertConnectionLost(HCAtlasLink.resolve(
            identity: identity,
            availability: .unknown,
            snapshot: readySnapshot([])
        ), identity: identity)
        XCTAssertEqual(HCAtlasLink.availability(machineState: "connected", localCore: true), .local)
        switch HCAtlasLink.resolve(identity: identity, availability: .local, snapshot: pendingSnapshot()) {
        case .unresolved(let resolved, let reason):
            XCTAssertEqual(resolved, identity)
            XCTAssertEqual(reason, .inventoryPending)
        default:
            XCTFail("local absence looked like a down Studio link or a death")
        }
    }

    func testConnectedReturnsTheSameKey() {
        let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")
        let identity = sampleIdentity(key: key)
        let record = HCTerminalRecord(
            key: key,
            state: .running,
            machineName: "studio",
            machineAvailability: .connected,
            pid: 18744
        )
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .connected,
            snapshot: readySnapshot([record])
        ) {
        case .live(let live):
            XCTAssertEqual(live.key, key)
            XCTAssertEqual(live.pid, 18744)
            XCTAssertEqual(live.machineAvailability, .connected)
        default:
            XCTFail("connected link did not stay live on the same key")
        }
    }

    func testFinishedRecordKeepsTheEndReason() {
        let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")
        let identity = sampleIdentity(key: key)
        let connected = readySnapshot([
            sampleRecord(key: key, state: .finished, endReason: "exited", exitCode: 0),
        ])
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .connected,
            snapshot: connected
        ) {
        case .ended(let evidence):
            XCTAssertEqual(evidence.kind, .finished)
            XCTAssertEqual(evidence.hcReason, "exited")
            XCTAssertEqual(evidence.exitCode, 0)
            XCTAssertNil(evidence.exitSignal)
            XCTAssertEqual(evidence.key, key)
            XCTAssertEqual(evidence.revision, connected.revision)
        default:
            XCTFail("a finished Studio terminal stayed live while the link was up")
        }
        let local = readySnapshot([
            sampleRecord(key: key, state: .finished, availability: .local, endReason: "exited", exitCode: 0),
        ])
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .local,
            snapshot: local
        ) {
        case .ended(let evidence):
            XCTAssertEqual(evidence.kind, .finished)
            XCTAssertEqual(evidence.hcReason, "exited")
            XCTAssertEqual(evidence.key, key)
            XCTAssertEqual(evidence.revision, local.revision)
        default:
            XCTFail("a finished local terminal stayed live")
        }
    }

    func testStartingAndMissingPidStayPending() {
        let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")
        let identity = sampleIdentity(key: key)
        let pending = [
            sampleRecord(key: key, state: .starting),
            sampleRecord(key: key, state: .running),
        ]
        for record in pending {
            switch HCAtlasLink.resolve(identity: identity, availability: .connected, snapshot: readySnapshot([record])) {
            case .unresolved(let resolved, let reason):
                XCTAssertEqual(resolved, identity)
                XCTAssertEqual(reason, .creationPending)
            default:
                XCTFail("\(record.state) without a pid became live")
            }
        }
    }

    func testForeignCoreAndAddressStayAmbiguous() {
        let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")
        let identity = sampleIdentity(key: key)
        let foreign = [
            HCTerminalKey(owningCoreID: "core-2", localAddress: "t3"),
            HCTerminalKey(owningCoreID: "core-1", localAddress: "t9"),
        ]
        for other in foreign {
            switch HCAtlasLink.resolve(
                identity: identity,
                availability: .connected,
                snapshot: readySnapshot([
                    sampleRecord(
                        key: other,
                        state: .running,
                        pid: 18744,
                        labels: ["c11.panel": identity.panelID.uuidString]
                    ),
                ])
            ) {
            case .unresolved(let resolved, let reason):
                XCTAssertEqual(resolved.panelID, identity.panelID)
                XCTAssertEqual(resolved.key, key)
                XCTAssertEqual(resolved.persistence, identity.persistence)
                XCTAssertEqual(reason, .ambiguousIdentity)
            default:
                XCTFail("foreign key \(other.owningCoreID)/\(other.localAddress) was adopted")
            }
        }
    }

    func testLinkDownKeepsNonpersistentIdentity() {
        let identity = HCPanelIdentity(
            panelID: UUID(uuidString: "EA1AD561-2F7C-4959-9C55-63063535491D")!,
            key: HCTerminalKey(owningCoreID: "core-1", localAddress: "t3"),
            persistence: .nonpersistent,
            origin: .fresh
        )
        assertConnectionLost(
            HCAtlasLink.resolve(identity: identity, availability: .disconnected, snapshot: readySnapshot([])),
            identity: identity
        )
        assertConnectionLost(
            HCAtlasLink.resolve(identity: identity, availability: .unknown, snapshot: readySnapshot([])),
            identity: identity
        )
    }

    func testConnectedAbsenceFollowsTheSharedResolver() {
        let identity = sampleIdentity()
        assertConnectionLost(
            HCAtlasLink.resolve(identity: identity, availability: .connected, snapshot: readySnapshot([])),
            identity: identity
        )
        let unbound = sampleIdentity(key: nil)
        switch HCAtlasLink.resolve(
            identity: unbound,
            availability: .connected,
            snapshot: readySnapshot([])
        ) {
        case .new:
            break
        default:
            XCTFail("a ready empty inventory with no intent was not new")
        }
        assertConnectionLost(
            HCAtlasLink.resolve(
                identity: unbound,
                availability: .disconnected,
                snapshot: readySnapshot([])
            ),
            identity: unbound
        )
    }

    func testPendingInventoryAndIntentDoNotAuthorizeNew() {
        let identity = sampleIdentity(key: nil)
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .connected,
            snapshot: pendingSnapshot()
        ) {
        case .unresolved(let resolved, let reason):
            XCTAssertEqual(resolved, identity)
            XCTAssertEqual(reason, .inventoryPending)
        case .new, .live, .ended:
            XCTFail("pending inventory authorized a creation")
        }
        let intent = HCStoredCreation(
            panelID: identity.panelID,
            creationID: UUID(uuidString: "6C3E0B2A-7A11-4E5D-9C11-0A11A5C13013")!,
            coreID: "core-1",
            coreProcess: HCProcessIdentity(pid: 18744, startTimeMicroseconds: 1),
            phase: .transmitted,
            key: nil,
            endEvidence: nil,
            initialInput: .none
        )
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .connected,
            snapshot: readySnapshot([]),
            intent: intent
        ) {
        case .unresolved(let resolved, let reason):
            XCTAssertEqual(resolved.panelID, identity.panelID)
            XCTAssertNil(resolved.key)
            XCTAssertEqual(resolved.persistence, identity.persistence)
            XCTAssertEqual(reason, .creationPending)
        case .new, .live, .ended:
            XCTFail("a transmitted intent authorized a second creation")
        }
    }

    func testNilKeyRunningRecordStaysLive() {
        let identity = sampleIdentity(key: nil)
        let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")
        // C11H-359 (M3): a keyless panel matches by label on its own machine.
        switch HCAtlasLink.resolve(
            identity: identity,
            availability: .connected,
            snapshot: readySnapshot([
                sampleRecord(
                    key: key,
                    state: .running,
                    pid: 18744,
                    labels: ["c11.panel": identity.panelID.uuidString]
                ),
            ]),
            placement: .machine("studio")
        ) {
        case .live(let live):
            XCTAssertEqual(live.key, key)
            XCTAssertEqual(live.pid, 18744)
        default:
            XCTFail("a running record for this panel was not live")
        }
    }

    func testHolderBoundaryAccepts103AndRejects104() {
        let fitting = URL(fileURLWithPath: "/" + String(repeating: "h", count: 56), isDirectory: true)
        let over = URL(fileURLWithPath: "/" + String(repeating: "h", count: 57), isDirectory: true)
        let fitPaths = remoteRunPaths(fitting)
        let overPaths = remoteRunPaths(over)
        XCTAssertEqual(fitPaths.holder.utf8.count, HCAtlasLink.maximumSocketPathBytes)
        XCTAssertLessThanOrEqual(fitPaths.socket.utf8.count, HCAtlasLink.maximumSocketPathBytes)
        XCTAssertEqual(overPaths.holder.utf8.count, HCAtlasLink.maximumSocketPathBytes + 1)
        XCTAssertLessThanOrEqual(overPaths.socket.utf8.count, HCAtlasLink.maximumSocketPathBytes)
        XCTAssertNotNil(result(HCAtlasLink.make(
            mode: .ssh,
            sshTarget: "studio",
            remoteHome: fitting,
            localHome: localHome,
            user: "demo",
            debugTag: nil
        )))
        guard case .failure(let reason) = HCAtlasLink.make(
            mode: .ssh,
            sshTarget: "studio",
            remoteHome: over,
            localHome: localHome,
            user: "demo",
            debugTag: nil
        ) else {
            return XCTFail("holder one byte over 103 was accepted")
        }
        XCTAssertEqual(reason, .invalidLaunchTuple)
    }

    func testFileLimitKeepsHighSoftAndRefusesLowHard() {
        let cap: UInt64 = 245760
        let floor = HCLimits.minimumFileDescriptors
        let raised = HCAtlasLink.fileLimit(
            beforeSoft: floor,
            beforeHard: 0,
            hardInfinite: true,
            softInfinite: false,
            kernelCap: cap
        )
        XCTAssertEqual(raised?.afterSoft, cap)
        XCTAssertEqual(raised?.afterHard, 0)
        let high = cap + 100
        let kept = HCAtlasLink.fileLimit(
            beforeSoft: high,
            beforeHard: 0,
            hardInfinite: true,
            softInfinite: false,
            kernelCap: cap
        )
        XCTAssertEqual(kept?.afterSoft, high)
        XCTAssertNil(HCAtlasLink.fileLimit(
            beforeSoft: 1024,
            beforeHard: 1024,
            hardInfinite: false,
            softInfinite: false,
            kernelCap: cap
        ))
    }

    func testPinInstallFollowsCurrentExecutable() {
        XCTAssertEqual(
            HCAtlasLink.pinInstall(remoteExecutableSHA256: HCPin.current.executableSHA256, ourSessionServing: true),
            .leave
        )
        XCTAssertEqual(
            HCAtlasLink.pinInstall(remoteExecutableSHA256: nil, ourSessionServing: false),
            .write
        )
        XCTAssertEqual(
            HCAtlasLink.pinInstall(remoteExecutableSHA256: "deadbeef", ourSessionServing: true),
            .stopBecauseServing
        )
        XCTAssertEqual(
            HCAtlasLink.pinInstall(remoteExecutableSHA256: "deadbeef", ourSessionServing: false),
            .write
        )
    }

    private func sshLink(debugTag: String?) throws -> HCAtlasLink {
        try XCTUnwrap(result(HCAtlasLink.make(
            mode: .ssh,
            sshTarget: "studio",
            remoteHome: remoteHome,
            localHome: localHome,
            user: "demo",
            debugTag: debugTag
        )))
    }

    private func result<T>(_ value: Result<T, HCUnavailableReason>) -> T? {
        try? value.get()
    }

    private let authority = HCRevision(connectionGeneration: 7, sequence: 11)

    private func readySnapshot(_ records: [HCTerminalRecord]) -> HCInventorySnapshot {
        HCInventorySnapshot(
            readiness: .ready(authority),
            revision: authority,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        )
    }

    private func pendingSnapshot() -> HCInventorySnapshot {
        HCInventorySnapshot(
            readiness: .pending(.inventoryPending),
            revision: HCRevision(connectionGeneration: 7, sequence: 0)
        )
    }

    private func sampleRecord(
        key: HCTerminalKey,
        state: HCTerminalState,
        availability: HCMachineAvailability = .connected,
        pid: Int32? = nil,
        endReason: String? = nil,
        exitCode: Int32? = nil,
        labels: [String: String] = [:]
    ) -> HCTerminalRecord {
        HCTerminalRecord(
            key: key,
            state: state,
            labels: labels,
            machineName: "studio",
            machineAvailability: availability,
            pid: pid,
            exitCode: exitCode,
            endReason: endReason
        )
    }

    private func remoteRunPaths(_ home: URL) -> (socket: String, holder: String) {
        let root = home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        return (
            root.appendingPathComponent("c11.sock").path,
            root.appendingPathComponent("c11.holder.ffffffff.sock").path
        )
    }

    private func sampleIdentity(key: HCTerminalKey? = HCTerminalKey(owningCoreID: "core-1", localAddress: "t3")) -> HCPanelIdentity {
        HCPanelIdentity(
            panelID: UUID(uuidString: "EA1AD561-2F7C-4959-9C55-63063535491D")!,
            key: key,
            persistence: .persistent,
            origin: .restored
        )
    }

    private func assertConnectionLost(_ lifecycle: HCLifecycle, identity: HCPanelIdentity) {
        switch lifecycle {
        case .unresolved(let resolved, let reason):
            XCTAssertEqual(resolved.panelID, identity.panelID)
            XCTAssertEqual(resolved.key, identity.key)
            XCTAssertEqual(resolved.persistence, identity.persistence)
            XCTAssertEqual(reason, .connectionLost)
            XCTAssertNotEqual(reason, .coreUnreachable)
        case .ended, .live, .new:
            XCTFail("link down changed lifecycle to \(lifecycle)")
        }
    }
}

/// C11H-78 (SH4, option B): the operator's pairing file and the registrar
/// that adds the paired machine to a shard's core. Fakes only: no hc, no ssh.
final class HCAtlasPairingTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/op", isDirectory: true)

    /// C11H-365: `pair` writes `"acknowledged": 1` after the operator's answer.
    private func file(_ vias: [String: String], machine: String = "studio", version: Int = 1, acknowledged: Bool = true) -> Data {
        var object: [String: Any] = ["pairing": version, "machine": machine, "vias": vias]
        if acknowledged { object["acknowledged"] = 1 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func via(_ session: String) -> String { HCAtlasPairing.viaPath(home: home, session: session) }

    func testAPairingFileNamesShardsAndOnlyTheirOwnViaPaths() throws {
        let pairing = try XCTUnwrap(HCAtlasPairing(data: file(["c11-s1": via("c11-s1"), "c11-s2": via("c11-s2")]), home: home))
        XCTAssertEqual(pairing.machine, "studio")
        XCTAssertTrue(pairing.acknowledged)
        let unanswered = try XCTUnwrap(HCAtlasPairing(data: file(["c11-s1": via("c11-s1")], acknowledged: false), home: home),
                                       "a manifest from before C11H-365 still reads")
        XCTAssertFalse(unanswered.acknowledged, "no acknowledged field: the operator never answered")
        XCTAssertEqual(via("c11-s2"), "/Users/op/.local/share/c11/atlas-via-c11-s2.sh")
        let registration = try XCTUnwrap(pairing.registration(for: "c11-s2"))
        XCTAssertEqual(registration.params, ["name": .string("studio"), "via": .string(via("c11-s2")), "session": .string("c11-s2")],
                       "the remote session is always the shard's own")
        XCTAssertNil(pairing.registration(for: "c11-s3"), "a shard the file does not name is not paired")

        XCTAssertNil(HCAtlasPairing(data: file(["c11-s1": "/tmp/evil.sh"]), home: home), "a via outside its own path")
        XCTAssertNil(HCAtlasPairing(data: file(["c11-s1": via("c11-s2")]), home: home), "shard 1 pointing at shard 2's via")
        XCTAssertNil(HCAtlasPairing(data: file(["c11-s1": via("c11-s1"), "c11": via("c11")]), home: home),
                     "the legacy c11 session is never paired here, and one bad entry voids the file")
        for bad in ["default", "c11-s9", "c11-s0", "c11-b-s1x"] {
            XCTAssertNil(HCAtlasPairing(data: file([bad: via(bad)]), home: home), bad)
        }
        for reserved in ["default", "local"] {
            XCTAssertNil(HCAtlasPairing(data: file(["c11-s1": via("c11-s1")], machine: reserved), home: home), reserved)
        }
        XCTAssertNil(HCAtlasPairing(data: file(["c11-s1": via("c11-s1")], version: 2), home: home))
        XCTAssertNil(HCAtlasPairing(data: file([:]), home: home))
        XCTAssertNotNil(HCAtlasPairing(data: file(["c11-b-s3": via("c11-b-s3")]), home: home), "dev shards pair too")
    }

    func testTheMachineListDecidesBetweenAddPairedAndLeavingAnotherSessionAlone() {
        let registration = HCAtlasPairing.Registration(machine: "studio", via: via("c11-s2"), session: "c11-s2")
        func list(_ entries: [[String: String]]) -> HCJSONValue {
            .object(["machines": .array(entries.map { .object($0.mapValues { .string($0) }) })])
        }
        XCTAssertEqual(HCAtlasPairing.decide(registration, machineList: list([])), .add)
        XCTAssertEqual(HCAtlasPairing.decide(registration, machineList: list([["name": "prime", "session": "c11-s2"]])), .add)
        XCTAssertEqual(HCAtlasPairing.decide(registration, machineList: list([["name": "studio", "session": "c11-s2"]])), .paired)
        XCTAssertEqual(HCAtlasPairing.decide(registration, machineList: list([["name": "studio", "session": "c11"]])), .mismatch("c11"))
        XCTAssertNil(HCAtlasPairing.decide(registration, machineList: .object([:])))
    }

    private actor Calls {
        var log: [(String, [String: HCJSONValue])] = []
        var machines: [[String: String]] = []
        var addFailures = 0
        func setMachines(_ value: [[String: String]]) { machines = value }
        func setAddFailures(_ value: Int) { addFailures = value }
        func handle(_ method: String, _ params: [String: HCJSONValue]) throws -> HCJSONValue {
            log.append((method, params))
            if method == "machine.add" {
                if addFailures > 0 { addFailures -= 1; throw HCUnavailableReason.connectionLost }
                machines.append(["name": params["name"]?.string ?? "", "session": params["session"]?.string ?? ""])
                return .object(["name": params["name"] ?? .null])
            }
            return .object(["machines": .array(machines.map { .object($0.mapValues { .string($0) }) })])
        }
        var methods: [String] { log.map(\.0) }
        var adds: [[String: HCJSONValue]] { log.filter { $0.0 == "machine.add" }.map(\.1) }
    }

    private func registrar(_ pairing: HCAtlasPairing?, safe: Bool = true, audit: C11AuditLog = .shared) -> HCAtlasPairingRegistrar {
        HCAtlasPairingRegistrar(load: { pairing }, checkVia: { _ in safe ? .safe : .unsafeFile }, sleep: { _ in }, maxAttempts: 5, audit: audit)
    }

    /// C11H-332: every pairing link outcome is audited through the registrar:
    /// added, a failed add, and a refused via. Fails with any of the three
    /// audit calls removed.
    func testEveryPairingOutcomeIsAudited() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pair-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audit = C11AuditLog(directory: folder)
        let added = Calls()
        _ = await registrar(pairing, audit: audit).connected(session: "c11-s1") { try await added.handle($0, $1) }
        let stuck = Calls()
        await stuck.setAddFailures(99)
        _ = await registrar(pairing, audit: audit).connected(session: "c11-s1") { try await stuck.handle($0, $1) }
        _ = await registrar(pairing, safe: false, audit: audit).connected(session: "c11-s1") { try await Calls().handle($0, $1) }
        audit.flush()
        let records = audit.read(.init(kind: "link"))
        XCTAssertTrue(records.allSatisfy { $0.via == "pairing" && $0.session == "c11-s1" }, "\(records)")
        XCTAssertEqual(records.first?.outcome, "ok")
        XCTAssertEqual(records.filter { $0.outcome == "failed" }.map(\.code), Array(repeating: "add_failed", count: 5),
                       "each failed add is a line, with a code and no error text")
        XCTAssertEqual(records.last?.outcome, "refused")
        XCTAssertNotNil(records.last?.code)
    }

    private var pairing: HCAtlasPairing {
        HCAtlasPairing(data: file(["c11-s1": via("c11-s1"), "c11-s2": via("c11-s2")]), home: home)!
    }

    func testWithNoPairingFileTheAppAddsNoMachine() async {
        let calls = Calls()
        let outcome = await registrar(nil).connected(session: "c11-s2") { try await calls.handle($0, $1) }
        XCTAssertEqual(outcome, .unpaired)
        let methods = await calls.methods
        XCTAssertEqual(methods, [], "no file: not even a machine.list")
    }

    func testAPairedShardAddsItsMachineOnceWithItsOwnSessionAndUnpairedShardsNone() async {
        let calls = Calls()
        let r = registrar(pairing)
        let first = await r.connected(session: "c11-s2") { try await calls.handle($0, $1) }
        XCTAssertEqual(first, .added)
        let again = await r.connected(session: "c11-s2") { try await calls.handle($0, $1) }
        XCTAssertEqual(again, .paired, "a reconnect finds it registered and adds nothing")
        let legacy = await r.connected(session: "c11") { try await calls.handle($0, $1) }
        XCTAssertEqual(legacy, .unpaired)
        let unnamed = await r.connected(session: "c11-s3") { try await calls.handle($0, $1) }
        XCTAssertEqual(unnamed, .unpaired)
        let adds = await calls.adds
        XCTAssertEqual(adds, [["name": .string("studio"), "via": .string(via("c11-s2")), "session": .string("c11-s2")]])
    }

    func testAMachineLinkedToAnotherSessionIsLeftAlone() async {
        let calls = Calls()
        await calls.setMachines([["name": "studio", "session": "c11"]])
        let outcome = await registrar(pairing).connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(outcome, .mismatch("c11"))
        let adds = await calls.adds
        XCTAssertTrue(adds.isEmpty)
    }

    func testAnAddThatFailsWhileTheFarEndIsDownIsRetriedUntilItLands() async {
        let calls = Calls()
        await calls.setAddFailures(2)
        let outcome = await registrar(pairing).connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(outcome, .added)
        let methods = await calls.methods
        XCTAssertEqual(methods, ["machine.list", "machine.add", "machine.list", "machine.add", "machine.list", "machine.add"])

        let stuck = Calls()
        await stuck.setAddFailures(99)
        let gaveUp = await registrar(pairing).connected(session: "c11-s1") { try await stuck.handle($0, $1) }
        XCTAssertEqual(gaveUp, .gaveUp)
        let tries = await stuck.adds.count
        XCTAssertEqual(tries, 5, "bounded by maxAttempts")
    }

    /// C11H-365: a manifest the operator never acknowledged adds no machine,
    /// on a connect or a creation, and does not retry; the audit records it
    /// once for the manifest, not once per connect. The same manifest with the
    /// operator's answer adds. Fails with the registrar's guard or its
    /// once-per-manifest check removed.
    func testAnUnacknowledgedManifestAddsNoMachineAndIsAuditedOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pair-ack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audit = C11AuditLog(directory: folder)
        let unanswered = try XCTUnwrap(HCAtlasPairing(data: file(["c11-s1": via("c11-s1"), "c11-s2": via("c11-s2")], acknowledged: false),
                                                      home: home))
        let calls = Calls()
        let r = registrar(unanswered, audit: audit)
        let first = await r.connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(first, .unacknowledged)
        let second = await r.connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(second, .unacknowledged)
        do {
            _ = try await r.prepare(session: "c11-s2", machine: "studio") { try await calls.handle($0, $1) }
            XCTFail("a remote creation went ahead on an unacknowledged pairing")
        } catch let reason as HCUnavailableReason {
            XCTAssertEqual(reason, .invalidLaunchTuple)
        }
        let adds = await calls.adds
        XCTAssertTrue(adds.isEmpty, "no machine.add for an unacknowledged manifest: \(adds)")
        let methods = await calls.methods
        XCTAssertEqual(methods, ["machine.list", "machine.list", "machine.list"], "one look per attempt, no retries")
        audit.flush()
        let refused = audit.read(.init(kind: "link"))
        XCTAssertEqual(refused.map(\.code), ["pairing_unacknowledged"], "one record per manifest: \(refused)")
        XCTAssertEqual(refused.first?.outcome, "refused")
        XCTAssertEqual(refused.first?.via, "pairing")
        XCTAssertEqual(refused.first?.machine, "studio")

        let answered = Calls()
        let added = await registrar(pairing, audit: audit).connected(session: "c11-s1") { try await answered.handle($0, $1) }
        XCTAssertEqual(added, .added)
        let answeredAdds = await answered.adds
        XCTAssertEqual(answeredAdds, [["name": .string("studio"), "via": .string(via("c11-s1")), "session": .string("c11-s1")]])
    }

    /// C11H-365: the registrar only ever adds, so a machine a shard already
    /// lists stays paired under a manifest written before acknowledgements.
    func testAnUnacknowledgedManifestKeepsAMachineAlreadyListed() async throws {
        let calls = Calls()
        await calls.setMachines([["name": "studio", "session": "c11-s1"]])
        let unanswered = try XCTUnwrap(HCAtlasPairing(data: file(["c11-s1": via("c11-s1")], acknowledged: false), home: home))
        let r = registrar(unanswered)
        let outcome = await r.connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(outcome, .paired)
        let ready = try await r.prepare(session: "c11-s1", machine: "studio") { try await calls.handle($0, $1) }
        XCTAssertTrue(ready, "a remote creation on an existing pairing goes ahead")
        let adds = await calls.adds
        XCTAssertTrue(adds.isEmpty)
    }

    func testAnUnsafeViaIsNeverAdded() async {
        let calls = Calls()
        let outcome = await registrar(pairing, safe: false).connected(session: "c11-s1") { try await calls.handle($0, $1) }
        XCTAssertEqual(outcome, .unsafeVia)
        let methods = await calls.methods
        XCTAssertEqual(methods, [])
    }

    func testViaSafetyNeedsAnOwnedExecutableRegularFileNoOneElseCanWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c11-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.sh").path
        FileManager.default.createFile(atPath: good, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(HCAtlasPairing.viaIsSafe(good))
        let shared = dir.appendingPathComponent("shared.sh").path
        FileManager.default.createFile(atPath: shared, contents: Data(), attributes: [.posixPermissions: 0o720])
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(shared), "group-writable")
        let plain = dir.appendingPathComponent("plain.sh").path
        FileManager.default.createFile(atPath: plain, contents: Data(), attributes: [.posixPermissions: 0o600])
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(plain), "not executable")
        let link = dir.appendingPathComponent("link.sh").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: good)
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(link), "a symlink")
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(dir.appendingPathComponent("missing.sh").path))
        // C11H-332: with the pin, only a via that checks it at every dial is safe.
        let pin = String(repeating: "c", count: 64)
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(good, pinSHA256: pin), "a via without the pin")
        let pinned = dir.appendingPathComponent("pinned.sh").path
        FileManager.default.createFile(atPath: pinned, contents: Data("#!/bin/sh\nexec x sha256=\(pin) /h/herdr-core connect\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(HCAtlasPairing.viaIsSafe(pinned, pinSHA256: pin))
        XCTAssertFalse(HCAtlasPairing.viaIsSafe(pinned, pinSHA256: String(repeating: "d", count: 64)), "another build's pin")
    }

    /// C11H-397: a paired via is added only when it checks this build's pin
    /// for the platform the link script rendered it for, as Add Machine
    /// renders it: a Linux via (bash) the Linux hc's pin, a Mac via this Mac's.
    /// One that checks the other platform's pin, whose every dial would refuse
    /// the hc it finds there, is refused by that name and audited; nothing is
    /// added. Vias come from the bundled link script's own `render`.
    func testAPairedViaMustCheckThisBuildsPinForItsOwnPlatform() async throws {
        let script = try Self.bundledLinkScript()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pair-platform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = String(repeating: "a", count: 64), linux = String(repeating: "b", count: 64)
        func render(_ name: String, platform: String, sha: String) -> String {
            let out = dir.appendingPathComponent("\(name).sh").path
            let rendered = HCMachineSetupProcessRunner().run(
                ["/bin/sh", script.path, "render", "--mode", "ssh", "--session", "c11-s1",
                 "--socket", "/home/far/.local/share/c11/run/c11-s1.sock", "--hc", "/home/far/.local/share/c11/hc/0.1.16/herdr-core",
                 "--sha", sha, "--machine", "studio", "--target", "studio", "--home", "/home/far", "--user", "far",
                 "--platform", platform, "--out", out],
                stdin: nil, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": dir.path], timeout: 30)
            XCTAssertEqual(rendered.status, 0, rendered.stderr)
            return out
        }
        let pins = HCAtlasPairing.Pins(mac: mac, linux: linux)
        let linuxVia = render("linux", platform: "linux", sha: linux)
        let crossed = render("linux-mac-pin", platform: "linux", sha: mac)
        XCTAssertEqual(HCAtlasPairing.checkVia(render("mac", platform: "mac", sha: mac), pins: pins), .safe)
        XCTAssertEqual(HCAtlasPairing.checkVia(linuxVia, pins: pins), .safe, "a Linux machine's via with the Linux pin")
        XCTAssertEqual(HCAtlasPairing.checkVia(crossed, pins: pins), .otherPlatformPin, "a Linux via that checks this Mac's pin")
        XCTAssertEqual(HCAtlasPairing.checkVia(render("mac-linux-pin", platform: "mac", sha: linux), pins: pins), .otherPlatformPin,
                       "a Mac via that checks the Linux pin")
        XCTAssertEqual(HCAtlasPairing.checkVia(render("other", platform: "linux", sha: String(repeating: "c", count: 64)), pins: pins),
                       .noPin, "another build's pin")
        XCTAssertEqual(HCAtlasPairing.checkVia(linuxVia, pins: .init(mac: mac, linux: nil)), .noPin,
                       "a build that names no Linux hc adds no Linux machine")
        XCTAssertEqual(chmod(linuxVia, 0o720), 0)
        XCTAssertEqual(HCAtlasPairing.checkVia(linuxVia, pins: pins), .unsafeFile)
        XCTAssertEqual(chmod(linuxVia, 0o700), 0)

        // Through the registrar: the Linux via is added; the crossed one is refused and audited by name.
        let audit = C11AuditLog(directory: dir.appendingPathComponent("audit", isDirectory: true))
        func pairedRegistrar(_ path: String) -> HCAtlasPairingRegistrar {
            HCAtlasPairingRegistrar(load: { self.pairing }, checkVia: { _ in HCAtlasPairing.checkVia(path, pins: pins) },
                                    sleep: { _ in }, maxAttempts: 1, audit: audit)
        }
        let good = Calls()
        let added = await pairedRegistrar(linuxVia).connected(session: "c11-s1") { try await good.handle($0, $1) }
        XCTAssertEqual(added, .added)
        let refused = Calls()
        let outcome = await pairedRegistrar(crossed).connected(session: "c11-s1") { try await refused.handle($0, $1) }
        XCTAssertEqual(outcome, .unsafeVia)
        let methods = await refused.methods
        XCTAssertEqual(methods, [], "a via that checks the other platform's pin reached the core")
        audit.flush()
        XCTAssertEqual(audit.read(.init(kind: "link")).map(\.code), [nil, "via_other_platform"])
    }

    /// The link script in the built app beside these tests.
    private static func bundledLinkScript() throws -> URL {
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            for appName in ["c11 DEV.app", "c11.app"] {
                let script = products.appendingPathComponent(appName + "/Contents/Resources/bin/c11-atlas-link.sh")
                if FileManager.default.isReadableFile(atPath: script.path) { return script }
            }
            products.deleteLastPathComponent()
        }
        throw XCTSkip("no built c11 app beside the tests")
    }
}
