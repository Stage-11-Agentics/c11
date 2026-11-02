import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-568: the relaunch record, the quit-time process count, the one mailbox
/// notice per resumed agent, and the `app.relaunched` payload.
final class RelaunchNoticeTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: - Record

    private func record(runLaunchedAt: Double, reason: RelaunchRecord.Reason, counts: [String: Int]? = nil) -> RelaunchRecord {
        var record = RelaunchRecord(
            runLaunchedAt: runLaunchedAt,
            writtenAt: runLaunchedAt + 60,
            reason: reason,
            refs: ["panel": [.init(ref: "panel:3", id: UUID().uuidString)]]
        )
        record.backgroundProcesses = counts
        return record
    }

    func testConsumeReadsOnceThenDeletes() throws {
        let url = try XCTUnwrap(RelaunchRecordStore.url(bundleId: "com.stage11.c11.test", directory: tempRoot))
        let panel = UUID()
        let written = record(runLaunchedAt: 1_000, reason: .quit, counts: [panel.uuidString: 2])
        XCTAssertTrue(RelaunchRecordStore.write(written, to: url))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let read = RelaunchRecordStore.consume(url: url, priorShutdown: .clean(at: Date(timeIntervalSince1970: 1_060)))
        XCTAssertEqual(read, written)
        XCTAssertEqual(read?.backgroundProcessCount(panelId: panel), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "consumed record must be deleted")
        XCTAssertNil(RelaunchRecordStore.consume(url: url, priorShutdown: .clean(at: Date())))
    }

    /// kill -9: the crashed run's own autosave record matches its dirty stamp
    /// and carries refs but no count.
    func testCrashRecordMatchesDirtyStampAndHasNoCount() throws {
        let url = try XCTUnwrap(RelaunchRecordStore.url(bundleId: "b", directory: tempRoot))
        XCTAssertTrue(RelaunchRecordStore.write(record(runLaunchedAt: 2_000.25, reason: .autosave), to: url))
        let read = try XCTUnwrap(RelaunchRecordStore.consume(
            url: url, priorShutdown: .dirty(launchedAt: Date(timeIntervalSince1970: 2_000.25))
        ))
        XCTAssertEqual(read.refs["panel"]?.first?.ref, "panel:3")
        XCTAssertNil(read.backgroundProcessCount(panelId: UUID()))
    }

    /// A record from an older quit (its delete failed) never lends its count
    /// to the crash that followed.
    func testOlderQuitRecordRefusedAfterCrash() throws {
        let url = try XCTUnwrap(RelaunchRecordStore.url(bundleId: "b", directory: tempRoot))
        let panel = UUID()
        XCTAssertTrue(RelaunchRecordStore.write(
            record(runLaunchedAt: 1_000, reason: .quit, counts: [panel.uuidString: 4]), to: url
        ))
        XCTAssertNil(RelaunchRecordStore.consume(
            url: url, priorShutdown: .dirty(launchedAt: Date(timeIntervalSince1970: 3_000))
        ))
        XCTAssertNil(RelaunchRecordStore.consume(url: url, priorShutdown: .dirty(launchedAt: nil)))
    }

    /// After a clean shutdown the record must have been written moments
    /// before the clean marker; a stale one, or one with no prior marker, is
    /// refused.
    func testCleanShutdownAcceptsOnlyARecordWrittenAtThatQuit() {
        let fresh = record(runLaunchedAt: 1_000, reason: .quit) // written at 1_060
        XCTAssertTrue(RelaunchRecordStore.accepts(fresh, priorShutdown: .clean(at: Date(timeIntervalSince1970: 1_061))))
        XCTAssertFalse(RelaunchRecordStore.accepts(fresh, priorShutdown: .clean(at: Date(timeIntervalSince1970: 9_000))))
        XCTAssertFalse(RelaunchRecordStore.accepts(fresh, priorShutdown: .missing))
    }

    func testAutosaveRecordNeverStatesCount() {
        let panel = UUID()
        let autosave = record(runLaunchedAt: 1, reason: .autosave, counts: [panel.uuidString: 3])
        XCTAssertNil(autosave.backgroundProcessCount(panelId: panel))
    }

    func testUnknownSchemaRefused() {
        var future = record(runLaunchedAt: 1, reason: .quit)
        future.schema = RelaunchRecord.schemaVersion + 1
        XCTAssertFalse(RelaunchRecordStore.accepts(future, priorShutdown: .clean(at: Date())))
    }

    // MARK: - Process count

    private func entry(_ pid: pid_t, parent: pid_t, group: pid_t, _ command: String = "zsh",
                       start: UInt64 = 1, zombie: Bool = false) -> RelaunchProcessCount.ProcessEntry {
        .init(pid: pid, parentPid: parent, processGroup: group, startTime: start, command: command, isZombie: zombie)
    }

    /// Two background sleeps (each a shell plus sleep in its own group), an MCP
    /// server and caffeinate in the agent's group, c11's mailbox bridge, a
    /// zombie and an unrelated process: two groups ended.
    func testCountsBackgroundGroupsNotHelpers() throws {
        let panel = UUID()
        let processes = [
            entry(100, parent: 1, group: 100, "claude", start: 77),
            entry(200, parent: 100, group: 200), entry(201, parent: 200, group: 200, "sleep"),
            entry(300, parent: 100, group: 300), entry(301, parent: 300, group: 300, "sleep"),
            entry(400, parent: 100, group: 100, "node"), entry(401, parent: 400, group: 100, "node"),
            entry(402, parent: 100, group: 100, "caffeinate"),
            entry(500, parent: 100, group: 500, "c11"),
            entry(600, parent: 100, group: 600, zombie: true),
            entry(700, parent: 1, group: 700, "sleep"),
        ]
        let count = try XCTUnwrap(RelaunchProcessCount.count(
            agent: .init(panelId: panel, pid: 100, startTime: 77), in: processes
        ))
        XCTAssertEqual(count.backgroundGroups, 2)
        XCTAssertEqual(count.descendants, 8)
    }

    func testCountFailsClosedOnPidReuseOrUnknownStart() {
        let processes = [entry(100, parent: 1, group: 100, "vim", start: 5)]
        XCTAssertNil(RelaunchProcessCount.count(agent: .init(panelId: UUID(), pid: 100, startTime: 4), in: processes))
        XCTAssertNil(RelaunchProcessCount.count(agent: .init(panelId: UUID(), pid: 100, startTime: nil), in: processes))
        XCTAssertNil(RelaunchProcessCount.count(agent: .init(panelId: UUID(), pid: 999, startTime: 5), in: processes))
    }

    /// The real kernel read: two children of this test process in their own
    /// process groups are two background groups.
    func testLiveProcessTableCountsSpawnedGroups() throws {
        var spawned: [pid_t] = []
        defer {
            for pid in spawned { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        }
        for _ in 0..<2 {
            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)
            var pid: pid_t = 0
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
            let result = posix_spawn(&pid, "/bin/sleep", nil, &attr, args, environ)
            args.forEach { free($0) }
            posix_spawnattr_destroy(&attr)
            XCTAssertEqual(result, 0)
            spawned.append(pid)
        }
        let me = getpid()
        let processes = try XCTUnwrap(RelaunchProcessCount.liveProcesses())
        let start = try XCTUnwrap(processes.first { $0.pid == me }?.startTime)
        let counts = try XCTUnwrap(RelaunchProcessCount.measure(
            agents: [.init(panelId: UUID(), pid: me, startTime: start)], timeout: 2
        ))
        let count = try XCTUnwrap(counts.values.first)
        XCTAssertGreaterThanOrEqual(count.backgroundGroups, 2)
    }

    // MARK: - Notice

    func testNoticeBodyStatesCountOnlyWhenMeasured() {
        let at = Date(timeIntervalSince1970: 1_793_577_900) // 2026-11-01 16:05 PST
        let pst = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(
            RelaunchNotice.body(restartedAt: at, backgroundProcesses: 2, timeZone: pst),
            "c11 restarted at 16:05 PST; 2 background jobs ended; your background shells, watchers and monitors did not survive; re-arm what you depend on. Short refs renumbered; use UUIDs."
        )
        XCTAssertEqual(
            RelaunchNotice.body(restartedAt: at, backgroundProcesses: nil, timeZone: pst),
            "c11 restarted at 16:05 PST; your background shells, watchers and monitors did not survive; re-arm what you depend on. Short refs renumbered; use UUIDs."
        )
        XCTAssertTrue(RelaunchNotice.body(restartedAt: at, backgroundProcesses: 1, timeZone: pst)
            .contains("; 1 background job ended; "))
    }

    func testDeliverWritesOneValidEnvelopeToThePanel() throws {
        let workspace = UUID(), panel = UUID()
        let id = try RelaunchNotice.deliver(
            workspaceId: workspace, panelId: panel, restartedAt: Date(),
            backgroundProcesses: 2, stateURL: tempRoot
        )
        let outbox = MailboxLayout.outboxURL(state: tempRoot, workspaceId: workspace)
        let data = try Data(contentsOf: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
        let envelope = try MailboxEnvelope.validate(data: data)
        XCTAssertEqual(envelope.to, "id:\(panel.uuidString)")
        XCTAssertEqual(envelope.from, "c11")
        XCTAssertEqual(envelope.topic, RelaunchNotice.topic)
        XCTAssertTrue(envelope.body.contains("2 background jobs ended"))
    }

    /// Two quick relaunches: the first notice, still unread, is replaced, so
    /// the agent finds one. Read mail and other mail stay.
    func testDeliverSupersedesUnreadEarlierNoticeOnly() throws {
        let workspace = UUID(), panel = UUID()
        let inbox = MailboxLayout.inboxURL(state: tempRoot, workspaceId: workspace, panelId: panel)
        try FileManager.default.createDirectory(at: MailboxLayout.readURL(inbox: inbox), withIntermediateDirectories: true)
        func put(_ envelope: MailboxEnvelope, in dir: URL) throws {
            try envelope.encode().write(to: dir.appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        }
        let oldNotice = try MailboxEnvelope.build(from: "c11", to: "id:\(panel)", topic: RelaunchNotice.topic, body: "old")
        let readNotice = try MailboxEnvelope.build(from: "c11", to: "id:\(panel)", topic: RelaunchNotice.topic, body: "read")
        let peerMail = try MailboxEnvelope.build(from: "c11-lead", to: "id:\(panel)", topic: RelaunchNotice.topic, body: "peer")
        let other = try MailboxEnvelope.build(from: "c11", to: "id:\(panel)", body: "other")
        try put(oldNotice, in: inbox)
        try put(peerMail, in: inbox)
        try put(other, in: inbox)
        try put(readNotice, in: MailboxLayout.readURL(inbox: inbox))

        _ = try RelaunchNotice.deliver(
            workspaceId: workspace, panelId: panel, restartedAt: Date(),
            backgroundProcesses: nil, stateURL: tempRoot
        )
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: inbox.path))
        XCTAssertFalse(remaining.contains(MailboxLayout.envelopeFilename(id: oldNotice.id)))
        XCTAssertTrue(remaining.contains(MailboxLayout.envelopeFilename(id: peerMail.id)))
        XCTAssertTrue(remaining.contains(MailboxLayout.envelopeFilename(id: other.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MailboxLayout.readURL(inbox: inbox)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: readNotice.id)).path))
    }

    /// Quit A ended 5 jobs; B resumed and quit before the agent read its
    /// notice, measuring 1. The replacement states 6, not 1.
    func testReplacementAddsJobsFromUnreadNotice() throws {
        let workspace = UUID(), panel = UUID()
        let first = try RelaunchNotice.deliver(
            workspaceId: workspace, panelId: panel, restartedAt: Date(),
            backgroundProcesses: 5, stateURL: tempRoot
        )
        // The dispatcher moves it from the outbox into the unread inbox.
        let outbox = MailboxLayout.outboxURL(state: tempRoot, workspaceId: workspace)
        let inbox = MailboxLayout.inboxURL(state: tempRoot, workspaceId: workspace, panelId: panel)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let name = MailboxLayout.envelopeFilename(id: first)
        try FileManager.default.moveItem(at: outbox.appendingPathComponent(name), to: inbox.appendingPathComponent(name))

        let second = try RelaunchNotice.deliver(
            workspaceId: workspace, panelId: panel, restartedAt: Date(),
            backgroundProcesses: 1, stateURL: tempRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(name).path))
        let data = try Data(contentsOf: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: second)))
        XCTAssertTrue(try MailboxEnvelope.validate(data: data).body.contains("6 background jobs ended"))
        XCTAssertNil(RelaunchNotice.statedJobs(measured: nil, superseded: 5))
    }

    func testLedgerNoticesEachPanelOncePerLaunch() {
        var ledger = RelaunchNotice.Ledger()
        let a = UUID(), b = UUID()
        XCTAssertTrue(ledger.claim(a))
        XCTAssertFalse(ledger.claim(a))
        XCTAssertTrue(ledger.claim(b))
    }

    // MARK: - Event

    func testRelaunchedPayloadCarriesOldRefPairs() throws {
        let window = UUID().uuidString, panel = UUID().uuidString
        let record = RelaunchRecord(
            runLaunchedAt: 1_000, writtenAt: 1_060, reason: .quit,
            refs: ["window": [.init(ref: "window:1", id: window)], "panel": [.init(ref: "panel:12", id: panel)]]
        )
        let payload = EventEmitter.relaunchedPayload(
            priorShutdown: .clean(at: Date(timeIntervalSince1970: 1_061)),
            restartedAt: Date(timeIntervalSince1970: 1_100), record: record
        )
        XCTAssertEqual(payload["prior_shutdown"] as? String, "clean")
        XCTAssertEqual(payload["record"] as? String, "quit")
        let refs = try XCTUnwrap(payload["refs"] as? [String: Any])
        XCTAssertEqual(Set(refs.keys), ["window", "workspace", "area", "panel"])
        let panels = try XCTUnwrap(refs["panel"] as? [[String: String]])
        XCTAssertEqual(panels, [["old_ref": "panel:12", "id": panel]])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))

        let crash = EventEmitter.relaunchedPayload(
            priorShutdown: .dirty(launchedAt: nil), restartedAt: Date(), record: nil
        )
        XCTAssertEqual(crash["prior_shutdown"] as? String, "dirty")
        XCTAssertTrue(crash["record"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(crash))
    }
}
