import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-352: abandoned hc sessions, against hc state written to a temporary
/// folder and a fake process table. Nothing here reads the real state root,
/// connects to a real socket or signals a real process.
final class HCAbandonedSessionsTests: XCTestCase {
    private var root: URL!
    private var context: HCAbandonedSessions.Context!
    private var host: FakeHost!

    private let uid: uid_t = 501
    private let started1: UInt64 = 1_700_000_000_000   // ms, terminal t1
    private let started2: UInt64 = 1_700_000_001_000   // ms, terminal t2

    final class FakeHost: HCAbandonedHost {
        var uid: uid_t = 501
        var selfPID: Int32 = 9000
        var table: [Int32: HCAbandonedProcess] = [:]
        var environments: [Int32: [String: String]] = [:]
        var accepting = Set<String>()
        var bound: Set<String>? = []
        var tableReadable = true
        var signals: [(pid: Int32, signal: Int32)] = []
        /// Runs during the grace, so a test can change the table then.
        var duringGrace: (() -> Void)?
        /// SIGKILL takes effect only at the next wait, as a kernel reaps later.
        var deferKills = false
        private var pendingKills: [Int32] = []
        /// Every socket path the scan tried to connect to.
        var probes: [String] = []
        /// Runs after each signal is recorded, so a test can change the table then.
        var onSignal: ((Int32, Int32) -> Void)?
        /// Runs when a process's environment is read, before the value returns.
        var onEnvironmentRead: ((Int32) -> Void)?

        func process(_ pid: Int32) -> HCAbandonedProcess? { table[pid] }
        func processes() -> [HCAbandonedProcess]? { tableReadable ? table.values.sorted { $0.identity.pid < $1.identity.pid } : nil }
        func environmentValue(_ name: String, pid: Int32) -> String? {
            onEnvironmentRead?(pid)
            return environments[pid]?[name]
        }
        func socketAccepts(_ path: String) -> Bool {
            probes.append(path)
            return accepting.contains(path)
        }
        func boundUnixSocketPaths() -> Set<String>? { bound }
        func signal(_ pid: Int32, _ signal: Int32) {
            signals.append((pid, signal))
            if signal == SIGKILL {
                if deferKills { pendingKills.append(pid) } else { table[pid] = nil }
            }
            onSignal?(pid, signal)
        }
        func wait(_ seconds: TimeInterval) {
            let work = duringGrace
            duringGrace = nil
            work?()
            for pid in pendingKills { table[pid] = nil }
            pendingKills = []
        }

        func add(_ pid: Int32, startMicroseconds: UInt64, parent: Int32 = 1, session: Int32, uid: uid_t = 501,
                 scope: String? = nil) {
            table[pid] = HCAbandonedProcess(identity: HCProcessIdentity(pid: pid, startTimeMicroseconds: startMicroseconds),
                                            parentPID: parent, session: session, realUID: uid)
            if let scope { environments[pid] = ["HC_SCOPE": scope] }
        }

        func signalled(_ pid: Int32) -> [Int32] { signals.filter { $0.pid == pid }.map(\.signal) }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hc-abandoned-\(UUID().uuidString)", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        context = HCAbandonedSessions.Context(stateRoot: stateRoot, runDirectories: [run], protectedFamilies: ["c11-orch4"])
        host = FakeHost()
        host.uid = uid
        // The caller: a shell in a live c11 terminal of its own.
        host.add(9000, startMicroseconds: 1, parent: 8999, session: 8999)
        host.add(8999, startMicroseconds: 1, parent: 1, session: 8999)
        // Someone else's process, in a session of its own.
        host.add(5000, startMicroseconds: 1, session: 5000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    private var run: URL { context.runDirectories[0] }

    /// hc's record: t1 (pid 4001) and t2 (pid 4002) live, t3 finished.
    private func writeSession(_ name: String = "c11h-old", terminals: [[String: Any]]? = nil, coreLock: String? = nil) throws {
        let folder = context.stateRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let items = terminals ?? [
            ["address": "t1", "state": "live", "pid": 4001, "program_started_ms": started1, "scope": "1-aaa"],
            ["address": "t2", "state": "live", "pid": 4002, "program_started_ms": started2, "scope": "2-bbb"],
            ["address": "t3", "state": "finished", "pid": 4003, "program_started_ms": started2, "scope": "3-ccc"],
        ]
        var map: [String: Any] = [:]
        for (index, item) in items.enumerated() { map["\(index + 1)"] = item }
        let data = try JSONSerialization.data(withJSONObject: ["next_id": items.count + 1, "holder": NSNull(), "terminals": map])
        try data.write(to: folder.appendingPathComponent("terminals.json"))
        if let coreLock { try Data(coreLock.utf8).write(to: folder.appendingPathComponent("core.lock")) }
    }

    /// t1's root alive and orphaned with a `nohup` job; t2's root gone, one job
    /// carrying its scope and one that does not.
    private func orphans() {
        host.add(4001, startMicroseconds: started1 * 1000 + 4_000, session: 4001)
        host.add(4101, startMicroseconds: started1 * 1000 + 900_000, session: 4001)
        host.add(4201, startMicroseconds: started2 * 1000 + 500_000, session: 4002, scope: "2-bbb")
        host.add(4202, startMicroseconds: started2 * 1000 + 600_000, session: 4002, scope: "9-zzz")
    }

    private func session(_ verdict: HCAbandonedVerdict, file: StaticString = #filePath, line: UInt = #line) -> HCAbandonedSession? {
        guard case .abandoned(let found) = verdict else {
            XCTFail("expected abandoned, got \(verdict.code)", file: file, line: line)
            return nil
        }
        return found
    }

    // MARK: report

    func testListsWhatAnAbandonedSessionLeftRunning() throws {
        try writeSession()
        orphans()
        let scan = HCAbandonedSessions.scan(context, host: host)
        XCTAssertEqual(scan.sessions.count, 1)
        let found = try XCTUnwrap(scan.sessions.first)
        XCTAssertEqual(found.session, "c11h-old")
        XCTAssertEqual(found.terminalsRecorded, 2, "finished terminals are not counted")
        XCTAssertEqual(found.terminalsLeft, 2)
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4001, 4101, 4201])
        XCTAssertEqual(found.leftovers.map(\.basis), [.root, .session, .scope])
        XCTAssertEqual(found.unverified, 1, "a job without t2's scope is never counted as t2's")
        XCTAssertEqual(scan.processCount, 3)
        XCTAssertEqual(HCAbandonedSessions.line(found),
                       "abandoned session=c11h-old terminals=2 terminals_left=2 processes=3 unverified=1")
        XCTAssertTrue(host.signals.isEmpty, "a scan signals nothing")
    }

    func testARunningCoreMeansNotAbandoned() throws {
        try writeSession()
        orphans()
        host.accepting = [run.appendingPathComponent("c11h-old.sock").path]
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .coreRunning)
        XCTAssertTrue(HCAbandonedSessions.scan(context, host: host).sessions.isEmpty)
    }

    func testTheSocketCoreLockNamesIsChecked() throws {
        let elsewhere = root.appendingPathComponent("elsewhere/c11h-old.sock").path
        try writeSession(coreLock: elsewhere + "\n")
        orphans()
        host.accepting = [elsewhere]
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .coreRunning)
    }

    func testARootAHolderStillParentsMeansTheSessionIsHeld() throws {
        try writeSession()
        orphans()
        host.add(4001, startMicroseconds: started1 * 1000 + 4_000, parent: 3000, session: 4001)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .holderAlive)
    }

    func testAListeningHolderSocketMeansTheSessionIsHeld() throws {
        try writeSession()
        orphans()
        let holder = run.appendingPathComponent("c11h-old.holder.ab12cd34.sock")
        try Data().write(to: holder)
        host.bound = [holder.path]
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .holderAlive)
        host.bound = nil
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unreadable("socket table"),
                       "an unreadable socket table never reads as no holder")
        host.bound = ["/elsewhere/other.sock"]
        XCTAssertNotNil(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)),
                        "a stale holder socket file nobody holds is not a holder")
        try FileManager.default.removeItem(at: holder)
        host.bound = ["/elsewhere/run/c11h-old.holder.99.sock"]
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .holderAlive,
                       "a holder whose socket file is gone, or bound elsewhere, still holds the session")
    }

    func testACoreSocketHeldUnderTheSessionNameMeansACore() throws {
        try writeSession()
        orphans()
        // Its file was unlinked, so connect cannot reach it; the core still holds it.
        host.bound = ["/elsewhere/run/c11h-old.sock"]
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .coreRunning)
    }

    func testThisBuildsSessionsAndTheCallersAreNeverCandidates() throws {
        try writeSession("c11-orch4-s2")
        orphans()
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11-orch4-s2", context, host: host), .current)
        XCTAssertTrue(HCAbandonedSessions.scan(context, host: host).sessions.isEmpty)

        let caller = HCAbandonedSessions.Context.local(home: root, ownSessions: ["c11-orch4", nil],
                                                       environment: ["HC_SESSION": "c11h-s3"])
        XCTAssertTrue(caller.isProtected("c11h"), "the caller's whole build: base and shards")
        XCTAssertTrue(caller.isProtected("c11h-s7"))
        XCTAssertTrue(caller.isProtected("c11-orch4-s1"))
        XCTAssertFalse(caller.isProtected("c11h-old"))
    }

    func testOnlyC11SessionFoldersAreCandidates() throws {
        try writeSession("default")
        try writeSession("herdr-dev")
        try writeSession("c11h-c11h-b")
        orphans()
        try FileManager.default.createSymbolicLink(at: context.stateRoot.appendingPathComponent("c11h-link"),
                                                   withDestinationURL: context.stateRoot.appendingPathComponent("c11h-c11h-b"))
        XCTAssertEqual(HCAbandonedSessions.candidates(context), ["c11h-c11h-b"], "never a symlinked folder")
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-link", context, host: host), .notFound, "nor by its name")
        XCTAssertEqual(HCAbandonedSessions.end("c11h-link", context, host: host).failureVerdict, .notFound)
        XCTAssertTrue(host.signals.isEmpty)
        XCTAssertTrue(HCAbandonedSessions.isC11SessionName("c11"))
        XCTAssertTrue(HCAbandonedSessions.isC11SessionName("c11-staging-stg-261"))
        XCTAssertFalse(HCAbandonedSessions.isC11SessionName("c11x"))
        XCTAssertFalse(HCAbandonedSessions.isC11SessionName("../c11"))
        XCTAssertEqual(HCAbandonedSessions.family("c11-orch4-s12"), "c11-orch4")
        XCTAssertEqual(HCAbandonedSessions.family("c11-s1x"), "c11-s1x")
    }

    func testAReusedRootPidIsNotTheTerminal() throws {
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": started1, "scope": "1-aaa"]])
        // pid 4001 now runs something that started an hour later, leading its own session.
        host.add(4001, startMicroseconds: (started1 + 3_600_000) * 1000, session: 4001)
        host.add(4101, startMicroseconds: (started1 + 3_600_100) * 1000, session: 4001, scope: "1-aaa")
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .clean)
    }

    func testAStartAtTheToleranceEdge() throws {
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": started1, "scope": "1-aaa"]])
        host.add(4001, startMicroseconds: started1 * 1000 - HCAbandonedSessions.startTolerance, session: 4001)
        XCTAssertEqual(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host))?.leftovers.count, 1)
        host.add(4001, startMicroseconds: started1 * 1000 + HCAbandonedSessions.startTolerance + 1, session: 4001)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .clean)
    }

    func testAnotherUsersProcessAtTheRootPidIsNotTheTerminal() throws {
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": started1, "scope": "1-aaa"]])
        host.add(4001, startMicroseconds: started1 * 1000, session: 4001, uid: 0)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .clean)
    }

    func testARootThatLeadsNoSessionIsUnverified() throws {
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": started1, "scope": "1-aaa"]])
        host.add(4001, startMicroseconds: started1 * 1000, session: 3999)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unverifiedOnly(1))
    }

    func testARecordWithoutAStartIsUnverified() throws {
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "scope": "1-aaa"]])
        host.add(4001, startMicroseconds: started1 * 1000, session: 4001)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unverifiedOnly(1))
    }

    func testAJobOlderThanItsDeadRootIsNeverItsLeftover() throws {
        try writeSession(terminals: [["address": "t2", "state": "live", "pid": 4002, "program_started_ms": started2, "scope": "2-bbb"]])
        host.add(4201, startMicroseconds: started2 * 1000 - HCAbandonedSessions.startTolerance - 1, session: 4002, scope: "2-bbb")
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unverifiedOnly(1))
    }

    func testADeadRootWithoutARecordedScopeEndsNothing() throws {
        try writeSession(terminals: [["address": "t2", "state": "live", "pid": 4002, "program_started_ms": started2]])
        host.add(4201, startMicroseconds: started2 * 1000 + 500_000, session: 4002)
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .clean,
                       "no HC_SCOPE on either side is not a match, and a process without one is not counted")
        host.add(4202, startMicroseconds: started2 * 1000 + 600_000, session: 4002, scope: "2-bbb")
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unverifiedOnly(1))
    }

    func testOtherUsersProcessesInTheSessionAreNeverLeftovers() throws {
        try writeSession()
        orphans()
        host.add(4102, startMicroseconds: started1 * 1000 + 900_000, session: 4001, uid: 0)
        host.add(4203, startMicroseconds: started2 * 1000 + 700_000, session: 4002, uid: 0, scope: "2-bbb")
        let found = try XCTUnwrap(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)))
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4001, 4101, 4201])
        XCTAssertEqual(found.unverified, 1)
    }

    func testAProcessThatLaunchedSomethingIsNeverALeftover() throws {
        try writeSession()
        orphans()
        // 4101 started an app whose core runs in a session of its own.
        host.add(4401, startMicroseconds: started1 * 1000 + 950_000, parent: 4101, session: 4401)
        host.add(4211, startMicroseconds: started2 * 1000 + 800_000, session: 4002, scope: "2-bbb")
        host.add(4402, startMicroseconds: started2 * 1000 + 850_000, parent: 4211, session: 4402)
        let found = try XCTUnwrap(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)))
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4001, 4201])
        XCTAssertEqual(found.unverified, 3, "4101, 4211 and 4202")
    }

    func testTheCallersAncestorsAreNeverLeftovers() throws {
        try writeSession()
        orphans()
        // The caller leads its own session; its parent and grandparent sit in t1's.
        host.add(8997, startMicroseconds: started1 * 1000 + 2_000_000, parent: 1, session: 4001)
        host.add(8999, startMicroseconds: started1 * 1000 + 3_000_000, parent: 8997, session: 4001)
        host.add(9000, startMicroseconds: started1 * 1000 + 4_000_000, parent: 8999, session: 9000)
        let found = try XCTUnwrap(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)))
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4001, 4101, 4201])
    }

    func testTheCallerAndItsSessionAreNeverLeftovers() throws {
        try writeSession()
        orphans()
        // The caller runs inside t1's session (its shell outlived the build).
        host.add(9000, startMicroseconds: started1 * 1000 + 5_000_000, parent: 4001, session: 4001)
        let found = try XCTUnwrap(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)))
        XCTAssertFalse(found.leftovers.contains { [4001, 4101, 9000].contains($0.identity.pid) })
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4201])
    }

    func testAnUnreadableProcessTableActsOnNothing() throws {
        try writeSession()
        orphans()
        host.tableReadable = false
        XCTAssertEqual(HCAbandonedSessions.evaluate("c11h-old", context, host: host), .unreadable("process table"))
        XCTAssertEqual(try? HCAbandonedSessions.end("c11h-old", context, host: host).get(), nil)
        XCTAssertTrue(host.signals.isEmpty)
    }

    func testAnUnsafeCoreLockLeavesTheSessionUnreadable() throws {
        try writeSession()
        orphans()
        let folder = context.stateRoot.appendingPathComponent("c11h-old")
        let lock = folder.appendingPathComponent("core.lock")
        let good = run.appendingPathComponent("c11h-old.sock").path

        // A symlink, even to a file naming the right socket.
        let target = root.appendingPathComponent("lock-target")
        try Data(good.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        assertUnreadable("c11h-old", prefix: "core.lock")
        try FileManager.default.removeItem(at: lock)

        // Writable by group or others.
        try Data(good.utf8).write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: lock.path)
        assertUnreadable("c11h-old", prefix: "core.lock")
        try FileManager.default.removeItem(at: lock)

        // A holder socket, or anything that is not this session's core socket: never probed.
        for named in [run.appendingPathComponent("c11h-old.holder.ab12cd34.sock").path, "relative/c11h-old.sock",
                      run.appendingPathComponent("c11h-other.sock").path, "garbage"] {
            try Data(named.utf8).write(to: lock)
            assertUnreadable("c11h-old", prefix: "core.lock names no core socket")
        }
        try FileManager.default.removeItem(at: lock)
        XCTAssertNotNil(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)), "absent is fine")
    }

    func testAnUnreachableCoreLockLeavesTheSessionUnreadable() throws {
        try writeSession()
        orphans()
        let folder = context.stateRoot.appendingPathComponent("c11h-old")
        // The folder can be listed but not searched: core.lock cannot be looked at.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        assertUnreadable("c11h-old", prefix: "core.lock")
    }

    func testACorruptStartLeavesTheRecordUnreadable() throws {
        // Fits Int64 as milliseconds, overflows UInt64 as microseconds.
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": 18_446_744_073_709_552 as Int64]])
        host.add(4001, startMicroseconds: 1, session: 4001)
        assertUnreadable("c11h-old", prefix: "terminals.json")
        try writeSession(terminals: [["address": "t1", "state": "live", "pid": 4001, "program_started_ms": 1.5]])
        assertUnreadable("c11h-old", prefix: "terminals.json")
        let scan = HCAbandonedSessions.scan(context, host: host)
        XCTAssertEqual(scan.unreadableCount, 1)
        let fields = HCAbandonedSessions.diagnostics(scan)
        XCTAssertEqual(fields["abandoned_unreadable"] as? Int, 1)
        XCTAssertTrue(HCDiagnosticsText.lines(fields).contains("abandoned_unreadable=1"))
    }

    private func assertUnreadable(_ name: String, prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        host.probes = []
        let verdict = HCAbandonedSessions.evaluate(name, context, host: host)
        guard case .unreadable(let why) = verdict else {
            return XCTFail("expected unreadable, got \(verdict.code)", file: file, line: line)
        }
        XCTAssertTrue(why.hasPrefix(prefix), "\(why)", file: file, line: line)
        XCTAssertEqual(HCAbandonedSessions.end(name, context, host: host).failureVerdict?.code, "unreadable", file: file, line: line)
        XCTAssertTrue(host.probes.isEmpty, "probed \(host.probes)", file: file, line: line)
        XCTAssertTrue(host.signals.isEmpty, file: file, line: line)
    }

    func testAProcessReplacedWhileItsScopeIsReadIsNotALeftover() throws {
        try writeSession()
        orphans()
        host.onEnvironmentRead = { [unowned host = self.host!] pid in
            guard pid == 4201 else { return }
            // 4201 exits and the pid goes to a new process of the same session and scope.
            host.add(4201, startMicroseconds: self.started2 * 1000 + 70_000_000, session: 4002, scope: "2-bbb")
        }
        let found = try XCTUnwrap(session(HCAbandonedSessions.evaluate("c11h-old", context, host: host)))
        XCTAssertEqual(found.leftovers.map(\.identity.pid), [4001, 4101])
        XCTAssertEqual(found.unverified, 2)
    }

    func testHcRecordShapes() throws {
        let list = try JSONSerialization.data(withJSONObject: ["terminals": [
            ["address": "t1", "state": "live", "pid": 4001, "program_started_ms": 5, "scope": "s"],
            ["address": "t2", "state": "starting", "pid": 1, "program_started_ms": 5],
            ["address": "t3", "state": "finished", "pid": 4003, "program_started_ms": 5],
        ]])
        XCTAssertEqual(HCAbandonedSessions.parseTerminals(list),
                       [HCRecordedTerminal(address: "t1", pid: 4001, startMicroseconds: 5000, scope: "s")])
        XCTAssertEqual(HCAbandonedSessions.parseTerminals(Data(#"{"next_id": 1, "holder": null, "terminals": {}}"#.utf8)), [])
        XCTAssertNil(HCAbandonedSessions.parseTerminals(Data(#"{"terminals": 4}"#.utf8)))
        XCTAssertNil(HCAbandonedSessions.parseTerminals(Data("not json".utf8)))
    }

    func testDiagnosticsFieldsAndText() throws {
        try writeSession()
        orphans()
        let fields = HCAbandonedSessions.diagnostics(HCAbandonedSessions.scan(context, host: host))
        XCTAssertEqual(fields["abandoned_processes"] as? Int, 3)
        let lines = HCDiagnosticsText.lines(fields)
        XCTAssertTrue(lines.contains("abandoned_processes=3"))
        XCTAssertTrue(lines.contains("abandoned session=c11h-old terminals=2 terminals_left=2 processes=3 unverified=1"), "\(lines)")
    }

    // MARK: end

    func testEndHangsUpThenKillsOnlyWhatIsStillTheSameProcess() throws {
        try writeSession()
        orphans()
        host.duringGrace = { [unowned host = self.host!] in
            // 4101 ends on the hangup and its pid goes to a new, unrelated process.
            host.add(4101, startMicroseconds: self.started1 * 1000 + 99_000_000, parent: 1, session: 4101)
            // 4201 ends on the hangup.
            host.table[4201] = nil
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4001), [SIGHUP, SIGCONT, SIGKILL])
        XCTAssertEqual(host.signalled(4101), [SIGHUP, SIGCONT], "a reused pid is never killed")
        XCTAssertEqual(host.signalled(4201), [SIGHUP, SIGCONT])
        XCTAssertEqual(host.signalled(4202), [], "unverified: never signalled")
        XCTAssertEqual(host.signalled(5000), [])
        XCTAssertEqual(host.signalled(9000), [])
        XCTAssertEqual(result.hungUp, 3)
        XCTAssertEqual(result.killed, 1)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(result.unverified, 1)
    }

    func testEndKillsWhatTheSessionForkedDuringTheGrace() throws {
        try writeSession()
        orphans()
        host.duringGrace = { [unowned host = self.host!] in
            host.add(4301, startMicroseconds: self.started1 * 1000 + 10_000_000, parent: 4001, session: 4001, scope: "1-aaa")
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4301), [SIGKILL])
        XCTAssertEqual(result.killed, 4)
        XCTAssertEqual(result.remaining, 0)
    }

    func testAKillNotYetReapedIsNeitherRepeatedNorCountedTwice() throws {
        try writeSession()
        orphans()
        host.deferKills = true
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        for pid: Int32 in [4001, 4101, 4201] {
            XCTAssertEqual(host.signalled(pid), [SIGHUP, SIGCONT, SIGKILL], "pid \(pid)")
        }
        XCTAssertEqual(result.killed, 3)
        XCTAssertEqual(result.remaining, 0)
    }

    func testAPidReusedBeforeItsHangupGetsNoSignal() throws {
        try writeSession()
        orphans()
        host.onSignal = { [unowned host = self.host!] pid, signal in
            guard pid == 4001, signal == SIGHUP else { return }
            host.add(4101, startMicroseconds: self.started1 * 1000 + 50_000_000, session: 4101)
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4101), [], "4101 is another process by the time its turn comes")
        XCTAssertEqual(result.hungUp, 2)
    }

    func testAPidReusedAfterItsHangupGetsNoContinue() throws {
        try writeSession()
        orphans()
        host.onSignal = { [unowned host = self.host!] pid, signal in
            guard pid == 4101, signal == SIGHUP else { return }
            // It ended on the hangup and its pid went to a new process.
            host.add(4101, startMicroseconds: self.started1 * 1000 + 50_000_000, session: 4101)
        }
        _ = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4101), [SIGHUP])
    }

    func testAPidReusedBeforeItsKillGetsNoKill() throws {
        try writeSession()
        orphans()
        host.onSignal = { [unowned host = self.host!] pid, signal in
            guard pid == 4001, signal == SIGKILL else { return }
            host.add(4101, startMicroseconds: self.started1 * 1000 + 50_000_000, session: 4101)
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4101), [SIGHUP, SIGCONT])
        XCTAssertEqual(result.killed, 2)
    }

    func testAProcessThatLeftTheSessionDuringTheGraceGetsNoKill() throws {
        try writeSession()
        orphans()
        host.duringGrace = { [unowned host = self.host!] in
            // Same pid and start: it called setsid() and is no longer in t1's session.
            host.add(4101, startMicroseconds: self.started1 * 1000 + 900_000, session: 4101)
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(host.signalled(4101), [SIGHUP, SIGCONT])
        XCTAssertEqual(host.signalled(4001), [SIGHUP, SIGCONT, SIGKILL])
        XCTAssertEqual(result.killed, 2)
    }

    func testACoreOrHolderThatAppearsDuringTheGraceStopsTheKill() throws {
        let cases: [(String, (FakeHost, URL) -> Void)] = [
            ("core_running", { host, run in host.accepting = [run.appendingPathComponent("c11h-old.sock").path] }),
            ("holder_alive", { host, _ in host.bound = ["/elsewhere/c11h-old.holder.77.sock"] }),
        ]
        for (expected, change) in cases {
            try writeSession()
            host.signals = []
            host.accepting = []
            host.bound = []
            orphans()
            let runFolder = run
            host.duringGrace = { [unowned host = self.host!] in change(host, runFolder) }
            let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
            XCTAssertFalse(host.signals.contains { $0.signal == SIGKILL }, expected)
            XCTAssertEqual(result.escalationRefused, expected)
            XCTAssertNil(result.remaining, "never reported as ended")
            XCTAssertFalse(result.succeeded)
        }
    }

    func testAClosingReadThatCannotConfirmReportsRemainingUnknown() throws {
        try writeSession()
        orphans()
        host.onSignal = { [unowned host = self.host!] _, signal in
            if signal == SIGKILL { host.tableReadable = false }
        }
        let result = try HCAbandonedSessions.end("c11h-old", context, host: host, grace: 3).get()
        XCTAssertEqual(result.killed, 3)
        XCTAssertNil(result.remaining)
        XCTAssertEqual(result.unconfirmed, "unreadable")
        XCTAssertFalse(result.succeeded)
    }

    func testEndRefusesWhatIsNotAbandoned() throws {
        try writeSession()
        try writeSession("c11-orch4")
        orphans()
        XCTAssertEqual(HCAbandonedSessions.end("c11-orch4", context, host: host).failureVerdict, .current)
        XCTAssertEqual(HCAbandonedSessions.end("c11h-gone", context, host: host).failureVerdict, .notFound)
        host.accepting = [run.appendingPathComponent("c11h-old.sock").path]
        XCTAssertEqual(HCAbandonedSessions.end("c11h-old", context, host: host).failureVerdict, .coreRunning)
        host.accepting = []
        host.add(4001, startMicroseconds: started1 * 1000 + 4_000, parent: 3000, session: 4001)
        XCTAssertEqual(HCAbandonedSessions.end("c11h-old", context, host: host).failureVerdict, .holderAlive)
        XCTAssertTrue(host.signals.isEmpty)
    }
}

/// The real kernel reader, against this test process and sockets it binds
/// itself. Reads only; starts, connects to and signals nothing else.
final class HCKernelAbandonedHostTests: XCTestCase {
    private let host = HCKernelAbandonedHost()
    private var folder: String!
    private var descriptors: [Int32] = []

    override func setUpWithError() throws {
        // Short: a unix socket path must fit in 104 bytes.
        folder = "/tmp/hcab-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for fd in descriptors { close(fd) }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func bind(_ name: String, listening: Bool) throws -> String {
        let path = folder + "/" + name
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        descriptors.append(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0, "bind \(path): errno \(errno)")
        if listening { XCTAssertEqual(listen(fd, 4), 0) }
        return path
    }

    /// The uid-wide reads walk every process of ours and give up (nil) when
    /// one changes under them: a descriptor listed as a socket is closed and
    /// its number reused before it is read, a process refuses mid-exec, the
    /// table outgrows its slack. Parallel test workers and a build beside
    /// them make that churn real, so read again until a read completes; the
    /// assertions are on a completed read, never on a missing one. Remove this
    /// retry when C11H-404 makes the scan tolerate a descriptor's reuse.
    private func completedRead<T>(_ read: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if let value = read() { return value }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func testReadsThisProcess() throws {
        let me = try XCTUnwrap(host.process(getpid()))
        XCTAssertEqual(me.identity.pid, getpid())
        XCTAssertEqual(me.session, getsid(0))
        XCTAssertEqual(me.realUID, getuid())
        XCTAssertGreaterThan(me.identity.startTimeMicroseconds, 0)
        XCTAssertEqual(host.process(getpid())?.identity, me.identity, "a second read is the same identity")
        XCTAssertTrue(try XCTUnwrap(completedRead { host.processes() }).contains { $0.identity == me.identity })
        XCTAssertFalse((host.environmentValue("PATH", pid: getpid()) ?? "").isEmpty, "the environment is reached past argv")
        XCTAssertNil(host.environmentValue("C11H352_NO_SUCH_VARIABLE", pid: getpid()))
        XCTAssertNil(host.process(1), "launchd is never a candidate")
    }

    func testTellsAServingSocketFromADeadOne() throws {
        let serving = try bind("l.sock", listening: true)
        let dead = try bind("n.sock", listening: false)
        XCTAssertTrue(host.socketAccepts(serving))
        XCTAssertFalse(host.socketAccepts(dead), "bound but not listening: refused")
        XCTAssertFalse(host.socketAccepts(folder + "/missing.sock"))
        XCTAssertTrue(host.socketAccepts("/tmp/" + String(repeating: "x", count: 120)), "a path too long to check reads as serving")
        let held = try XCTUnwrap(completedRead { host.boundUnixSocketPaths() }, "our own processes' sockets are readable")
        XCTAssertTrue(held.contains(serving))
        XCTAssertTrue(held.contains(dead))
    }
}

private extension Result where Success == HCAbandonedSessions.EndResult, Failure == HCAbandonedVerdict {
    var failureVerdict: HCAbandonedVerdict? {
        if case .failure(let verdict) = self { return verdict }
        return nil
    }
}

/// C11H-415: which c11 app processes hc would end with a terminal, by hc's own
/// rule: the token in a process's recorded environment, or in an ancestor's,
/// short of hc's own processes.
final class HCScopeCarriersTests: XCTestCase {
    private typealias Env = [(name: String, value: String)]

    func testAnAppIsEndedByItsOwnTokenOrAnAncestorsButNeverThroughAnHcProcess() {
        let parents: [Int32: Int32] = [100: 1, 200: 150, 150: 120, 120: 1, 300: 250, 250: 240, 240: 1]
        let environments: [Int32: Env] = [
            // c11 opened with `open -a` from terminal t1: launchd's child, carrying the token.
            100: [("HOME", "/Users/a"), ("HC_SCOPE", "1-aaa"), ("HC_TERMINAL_ID", "t1"), ("HC_TERMINAL_SOCKET", "/run/c11-s1.sock")],
            // c11 run directly by an agent in t2: its own block is clean, its parent's is not.
            200: [("HOME", "/Users/a")],
            150: [("HC_SCOPE", "2-bbb"), ("HC_TERMINAL_ID", "t2"), ("HC_TERMINAL_SOCKET", "/run/c11-s1.sock")],
            // 120 is Apple's shell: its environment is hidden from hc and from us.
            // c11 under an hc core: nothing above the core ends it.
            300: [("HOME", "/Users/a")],
            250: [("HC_RUNTIME", "1"), ("HC_SCOPE", "3-ccc")],
            240: [("HC_SCOPE", "4-ddd")],
        ]
        func marks(_ pid: Int32) -> [HCScopeCarrier.Mark] {
            HCScopeCarriers.marks(of: pid, parent: { parents[$0] }, environment: { environments[$0] })
        }
        XCTAssertEqual(marks(100), [.init(scope: "1-aaa", terminalID: "t1", terminalSocket: "/run/c11-s1.sock", holderPID: 100)])
        XCTAssertEqual(marks(200), [.init(scope: "2-bbb", terminalID: "t2", terminalSocket: "/run/c11-s1.sock", holderPID: 150)])
        XCTAssertEqual(marks(300), [])
    }

    func testAnEndMatchesTheRecordedTokenOrHcsLabelsForThatTerminalOnThatCore() {
        let carrier = HCScopeCarrier(pid: 100, bundleID: "com.stage11.c11", marks: [
            .init(scope: "1-aaa", terminalID: "t1", terminalSocket: "/run/c11-s1.sock", holderPID: 100)])
        XCTAssertTrue(carrier.isEnded(byTerminal: "t9", socket: "/run/c11-s2.sock", scope: "1-aaa"), "the token itself")
        XCTAssertTrue(carrier.isEnded(byTerminal: "t1", socket: "/run/c11-s1.sock", scope: nil), "hc's labels, token unknown")
        XCTAssertFalse(carrier.isEnded(byTerminal: "t1", socket: "/run/c11-s2.sock", scope: nil), "t1 of another core")
        XCTAssertFalse(carrier.isEnded(byTerminal: "t2", socket: "/run/c11-s1.sock", scope: "2-bbb"))
        XCTAssertFalse(carrier.isEnded(byTerminal: "t1", socket: "/run/c11-s1.sock", scope: "9-new"),
                       "t1 reissued on that core with a new token: hc would never sweep the app for it")
    }

    func testOnlyC11AppExecutablesAreCandidates() {
        for id in ["com.stage11.c11", "com.stage11.c11h", "com.stage11.c11.debug.c11-orch2", "com.stage11.c11h.debug"] {
            XCTAssertTrue(HCScopeCarriers.isC11App(bundleID: id), id)
        }
        for id in ["com.stage11.c11hx", "com.stage11.lattice", "com.example.c11", "com.mitchellh.ghostty"] {
            XCTAssertFalse(HCScopeCarriers.isC11App(bundleID: id), id)
        }
        XCTAssertEqual(HCScopeCarriers.appBundle(ofExecutable: "/Applications/c11.app/Contents/MacOS/c11"), "/Applications/c11.app")
        XCTAssertNil(HCScopeCarriers.appBundle(ofExecutable: "/Applications/c11.app/Contents/Helpers/herdr-core"))
        XCTAssertNil(HCScopeCarriers.appBundle(ofExecutable: "/Applications/c11.app/Contents/MacOS/bin/tool"))
    }

    func testTheRecordedTokenComesFromHcsOwnRecordOfThatTerminal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(HCScopeCarriers.recordedScope(address: "t1", stateDirectory: folder), "no record yet")
        let terminals: [String: Any] = [
            "1": ["address": "t1", "state": "live", "pid": 4001, "program_started_ms": 1_000, "scope": "1-aaa"],
            "2": ["address": "t2", "state": "live", "pid": 4002, "program_started_ms": 1_000],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["next_id": 3, "terminals": terminals])
        try data.write(to: folder.appendingPathComponent("terminals.json"))
        XCTAssertEqual(HCScopeCarriers.recordedScope(address: "t1", stateDirectory: folder), "1-aaa")
        XCTAssertNil(HCScopeCarriers.recordedScope(address: "t2", stateDirectory: folder), "hc recorded no token")
        XCTAssertNil(HCScopeCarriers.recordedScope(address: "t3", stateDirectory: folder))
    }
}

/// C11H-415: a close reports what its ends did, not what it asked for. The End
/// Session tip ("That ended the terminal and everything it started") needs a
/// confirmed `.ended`; an end a c11 app holds gets the lasting notice instead.
final class HCCloseOutcomeReportTests: XCTestCase {
    func testTheEndedTipWaitsForAnEndAndAHeldEndGetsTheNotice() {
        let ended = UUID(), held = UUID(), pending = UUID(), kept = UUID(), already = UUID()
        let outcomes: [UUID: HCPanelEndOutcome] = [
            ended: .ended, held: .pending(.appCarriesScope), pending: .pending(.inventoryPending),
            kept: .kept(nil), already: .alreadyEnded,
        ]
        let live: Set<UUID> = [ended, held, pending, kept]
        XCTAssertEqual(HCCloseOutcomeReport.report(outcomes, live: live), .init(endedLive: 1, heldByApp: 1))
        XCTAssertEqual(HCCloseOutcomeReport.report([held: .pending(.appCarriesScope)], live: [held]),
                       .init(endedLive: 0, heldByApp: 1), "a held end never earns the ended tip")
        XCTAssertEqual(HCCloseOutcomeReport.report([:], live: [ended]), .init(), "nothing settled in time: no claim")
    }

    func testTheHeldNoticeNamesTheHoldAndCountsIt() {
        let one = HCCloseOutcomeReport.heldNotice(count: 1)
        XCTAssertEqual(one.title, "End held")
        XCTAssertTrue(one.body.hasPrefix("One session is held") && one.body.contains("c11 app"), one.body)
        let three = HCCloseOutcomeReport.heldNotice(count: 3)
        XCTAssertTrue(three.body.hasPrefix("3 sessions keep running"), three.body)
        XCTAssertFalse(one.body.contains("ended the terminal"))
    }
}

/// C11H-417: the "End held" notice follows the holds themselves, not a close's
/// report window. Every new hold reaches the operator once, unread; a notice
/// read or cleared stays so until a new hold; it moves only when its workspace
/// or window is gone; its system copies never outlive its text.
@MainActor
final class HCHeldEndNoticeTests: XCTestCase {
    private final class Sink: HCHeldEndNoticeSink {
        var open: [UUID] = []
        var record: HCHeldEndNoticeRecord?
        var posts = 0, places = 0, updates = 0, removes = 0
        var isQuitting = false
        func current() -> HCHeldEndNoticeRecord? { record }
        func isOpen(_ workspaceID: UUID) -> Bool { open.contains(workspaceID) }
        func anyOpenWorkspace() -> UUID? { open.first }
        func post(workspaceID: UUID, title: String, body: String) {
            posts += 1
            record = HCHeldEndNoticeRecord(id: UUID(), workspaceID: workspaceID, body: body, isRead: false)
        }
        func place(workspaceID: UUID, title: String, body: String, isRead: Bool) {
            places += 1
            record = HCHeldEndNoticeRecord(id: UUID(), workspaceID: workspaceID, body: body, isRead: isRead)
        }
        func update(id: UUID, title: String, body: String) {
            updates += 1
            if let old = record { record = HCHeldEndNoticeRecord(id: old.id, workspaceID: old.workspaceID, body: body, isRead: old.isRead) }
        }
        func remove(id: UUID) { removes += 1; record = nil }
        func read() { if let old = record { record = HCHeldEndNoticeRecord(id: old.id, workspaceID: old.workspaceID, body: old.body, isRead: true) } }
        /// A workspace or window close: its notices are cleared.
        func clear(_ workspaceID: UUID) { if record?.workspaceID == workspaceID { record = nil } }
    }

    private var one: String { HCCloseOutcomeReport.heldNotice(count: 1).body }
    private var two: String { HCCloseOutcomeReport.heldNotice(count: 2).body }

    func testAHoldWithNoWindowWaitsAndAppearsOnceAWindowRegisters() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), workspace = UUID()
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.posts, 0, "the last window closed: nothing can show it yet")
        sink.open = [workspace]
        notices.reassert()
        XCTAssertEqual(sink.posts, 1)
        XCTAssertEqual(sink.record?.workspaceID, workspace)
        XCTAssertEqual(sink.record?.body, one)
        XCTAssertEqual(sink.record?.isRead, false)
        notices.reassert()
        XCTAssertEqual(sink.posts, 1, "a window registering again never alerts twice")
    }

    func testEveryNewHoldIsPostedUnreadEvenAfterTheFirstWasRead() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), a = UUID(), b = UUID()
        sink.open = [UUID()]
        notices.apply(.held(a))
        sink.read()
        notices.apply(.held(b))
        XCTAssertEqual(sink.posts, 2, "the second hold reaches the operator too")
        XCTAssertEqual(sink.record?.isRead, false)
        XCTAssertEqual(sink.record?.body, two)
        XCTAssertEqual(sink.removes, 0, "the held slot replaces it in place: never two, and no waiting blink")
        notices.apply(.held(a))
        XCTAssertEqual(sink.posts, 2, "a hold reported again is not new")
        sink.read()
        notices.apply(.released(a))
        XCTAssertEqual(sink.record?.body, one)
        XCTAssertEqual(sink.record?.isRead, true, "a release rewords it quietly and leaves it read")
        XCTAssertEqual(sink.posts, 2)
        notices.apply(.released(b))
        XCTAssertNil(sink.record, "no hold left: no notice saying one runs")
    }

    func testANoticeTheOperatorClearedStaysClearedUntilANewHold() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), workspace = UUID(), other = UUID()
        sink.open = [workspace, other]
        notices.apply(.held(UUID()))
        sink.record = nil  // the operator clears it
        // An unrelated workspace closes, then a window registers.
        notices.capture()
        sink.open = [workspace]
        notices.reassert()
        notices.reassert()
        XCTAssertEqual(sink.posts + sink.places, 1, "a cleared notice never comes back on its own")
        XCTAssertNil(sink.record)
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.posts, 2, "a new hold is told")
    }

    /// Production order of a window close: the window leaves the registry,
    /// then `capture`, then the clear, then `reassert`. A notice the operator
    /// cleared before that stays cleared, and a new hold is still told.
    func testAClearedNoticeStaysClearedWhenItsOwnWindowCloses() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), own = UUID(), other = UUID()
        sink.open = [own, other]
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.record?.workspaceID, own)
        sink.record = nil  // the operator clears it
        sink.open = [other]
        notices.capture()
        sink.clear(own)
        notices.reassert()
        XCTAssertNil(sink.record, "a cleared notice came back when its window closed")
        notices.reassert()  // a window registers
        XCTAssertEqual(sink.posts + sink.places, 1)
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.posts, 2, "a new hold after a clear is told")
        XCTAssertEqual(sink.record?.isRead, false)
    }

    func testAClearedNoticeStaysClearedThroughTheLastWindowClosingAndANewOne() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), own = UUID()
        sink.open = [own]
        notices.apply(.held(UUID()))
        sink.record = nil
        sink.open = []
        notices.capture()
        sink.clear(own)
        notices.reassert()
        sink.open = [UUID()]
        notices.reassert()
        XCTAssertNil(sink.record, "a cleared notice came back with the next window")
        XCTAssertEqual(sink.posts + sink.places, 1)
    }

    /// Production order of a last shell exiting: `capture`, the workspace's
    /// clear, the window closing (its own `capture` finds nothing), then a new
    /// window. The notice moves read or unread as it was.
    func testALastShellExitMovesTheNoticeWithItsReadState() {
        for wasRead in [true, false] {
            let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), own = UUID()
            sink.open = [own]
            notices.apply(.held(UUID()))
            if wasRead { sink.read() }
            notices.capture()
            sink.clear(own)
            sink.open = []
            notices.capture()
            notices.reassert()
            XCTAssertNil(sink.record, "no window: it waits")
            sink.open = [UUID()]
            notices.reassert()
            XCTAssertEqual(sink.record?.isRead, wasRead, "the move keeps its read state (was read: \(wasRead))")
            XCTAssertEqual(sink.places, 1)
            XCTAssertEqual(sink.posts, 1)
        }
    }

    /// End All over several held terminals: one post, counting them all.
    func testHoldsThatArriveTogetherPostOnce() {
        let sink = Sink()
        var later: [() -> Void] = []
        let notices = HCHeldEndNotices(sink: sink, schedule: { later.append($0) })
        sink.open = [UUID()]
        for _ in 0..<3 { notices.apply(.held(UUID())) }
        XCTAssertEqual(later.count, 1, "one turn for the three")
        later.forEach { $0() }
        XCTAssertEqual(sink.posts, 1)
        XCTAssertEqual(sink.record?.body, HCCloseOutcomeReport.heldNotice(count: 3).body)
    }

    func testANoticeMovesOnlyWhenItsWorkspaceIsGoneQuietlyAndAsReadAsItWas() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), gone = UUID(), remaining = UUID()
        sink.open = [gone, remaining]
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.record?.workspaceID, gone)
        sink.read()
        notices.capture()
        sink.clear(gone)
        sink.open = [remaining]
        notices.reassert()
        XCTAssertEqual(sink.record?.workspaceID, remaining)
        XCTAssertEqual(sink.record?.isRead, true)
        XCTAssertEqual(sink.posts, 1, "moved, not posted again")
        XCTAssertEqual(sink.places, 1)
    }

    func testAMovedRecordReplacesTheOneLeftInAClosedWorkspace() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() }), gone = UUID(), remaining = UUID()
        sink.open = [gone, remaining]
        notices.apply(.held(UUID()))
        sink.open = [remaining]  // its workspace closed without clearing it
        notices.reassert()
        XCTAssertEqual(sink.removes, 1)
        XCTAssertEqual(sink.record?.workspaceID, remaining)
    }

    func testNothingIsPostedOrMovedWhileTheAppQuits() {
        let sink = Sink(), notices = HCHeldEndNotices(sink: sink, schedule: { $0() })
        sink.open = [UUID()]
        sink.isQuitting = true
        notices.apply(.held(UUID()))
        XCTAssertEqual(sink.posts + sink.places, 0)
    }

    /// The store keeps the held notice in a workspace slot of its own: it
    /// neither replaces nor is replaced by another workspace-level notice.
    func testTheHeldNoticeKeepsItsOwnWorkspaceSlotInTheStore() {
        // The bare logic runner has no NSApp to ask (as FlagNotificationTests).
        AppFocusState.overrideIsFocused = false
        defer { AppFocusState.overrideIsFocused = nil }
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        let settings = UserDefaults(suiteName: "c11h-417-\(UUID().uuidString)")!
        store.configureNotificationSettingsDefaultsForTesting(settings)
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        let workspace = UUID()
        store.addNotification(workspaceId: workspace, surfaceId: nil, title: "Panel numbers", subtitle: "", body: "x")
        store.addNotification(workspaceId: workspace, surfaceId: nil, title: "End held", subtitle: "", body: "one",
                              origin: .heldEnd)
        store.addNotification(workspaceId: workspace, surfaceId: nil, title: "Notice", subtitle: "", body: "y")
        XCTAssertEqual(Set(store.notifications.map(\.title)), ["End held", "Notice"],
                       "another workspace notice still replaces its own kind, never the held one")
    }

    /// Notification Center never keeps an obsolete copy: a change or removal
    /// retires the delivered and pending copy, and a delivery that was still
    /// waiting on authorization when the text changed is never posted.
    func testNotificationCenterNeverKeepsAStaleHeldCopy() {
        AppFocusState.overrideIsFocused = false
        defer { AppFocusState.overrideIsFocused = nil }
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        let settings = UserDefaults(suiteName: "c11h-417-\(UUID().uuidString)")!
        settings.set(NotificationLevel.normal.rawValue, forKey: NotificationLevel.key)
        store.configureNotificationSettingsDefaultsForTesting(settings)
        store.resetNotificationDeliveryHandlerForTesting()
        var waiting: [(Bool) -> Void] = [], posted: [(id: String, body: String)] = [], retired: [String] = []
        store.configureRoutineNotificationDeliveryHooksForTesting(
            authorization: { waiting.append($0) },
            add: { request, completion in posted.append((request.identifier, request.content.body)); completion(nil) })
        store.configureSystemCopyRetirementForTesting { retired += $0 }
        let workspace = UUID()

        // Its count changes while the delivery waits: the old text is never posted.
        store.addNotification(workspaceId: workspace, surfaceId: nil, title: "End held", subtitle: "", body: "one",
                              origin: .heldEnd)
        let first = store.notifications.first { $0.origin == .heldEnd }!.id.uuidString
        store.updateText(id: UUID(uuidString: first)!, title: "End held", body: "two")
        XCTAssertTrue(retired.contains(first))
        let ready = waiting; waiting.removeAll(); ready.forEach { $0(true) }
        drainMain()
        XCTAssertTrue(posted.isEmpty, "a stale copy was posted: \(posted)")

        // Delivered, then the count changes and one releases: each change retires the posted copy.
        store.addNotification(workspaceId: workspace, surfaceId: nil, title: "End held", subtitle: "", body: "one",
                              origin: .heldEnd)
        let second = store.notifications.first { $0.origin == .heldEnd }!.id
        let readyAgain = waiting; waiting.removeAll(); readyAgain.forEach { $0(true) }
        drainMain()
        XCTAssertEqual(posted.map(\.body), ["one"])
        retired.removeAll()
        store.updateText(id: second, title: "End held", body: "two")
        XCTAssertEqual(retired, [second.uuidString], "the posted \"one\" copy is retired")
        store.remove(id: second)
        XCTAssertEqual(retired, [second.uuidString, second.uuidString])
    }

    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
    }

    func testTheRecheckSlowsAfterTheFirstMinuteOfAHold() {
        XCTAssertEqual(HCExplicitEndCoordinator.carrierRecheckDelay(heldFor: 0), 3)
        XCTAssertEqual(HCExplicitEndCoordinator.carrierRecheckDelay(heldFor: 59), 3)
        XCTAssertEqual(HCExplicitEndCoordinator.carrierRecheckDelay(heldFor: 60), 30)
        XCTAssertEqual(HCExplicitEndCoordinator.carrierRecheckDelay(heldFor: 86_400), 30)
    }
}
