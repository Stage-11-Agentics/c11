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
