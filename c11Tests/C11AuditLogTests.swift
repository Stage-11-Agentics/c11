import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-332: c11's audit log, written and read back from a scratch folder.
final class C11AuditLogTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    func testARecordIsOnePrivateJSONLineReadBackInOrder() throws {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        log.record(C11AuditRecord(kind: .link, via: "settings", outcome: "ok", machine: "studio", host: "me@studio.local"))
        log.record(C11AuditRecord(kind: .relay, via: "relay", outcome: "refused", machine: "studio",
                                  panel: UUID().uuidString, method: "set_status", code: "relay_auth_refused"))
        log.flush()
        XCTAssertEqual(mode(log.directory), 0o700)
        XCTAssertEqual(mode(log.fileURL), 0o600)
        XCTAssertEqual(mode(log.relayFileURL), 0o600)
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "the trust file holds the link record only")
        XCTAssertEqual(try String(contentsOf: log.relayFileURL, encoding: .utf8).split(separator: "\n").count, 1,
                       "the relayed call has its own file")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["kind"] as? String, "link")
        XCTAssertEqual(first["machine"] as? String, "studio")
        XCTAssertNil(first["panel"], "absent fields are left out, not null")
        let time = try XCTUnwrap(first["time"] as? String)
        XCTAssertNotNil(time.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$"#, options: .regularExpression),
                        "local time with its offset: \(time)")
        XCTAssertEqual(log.read().map(\.kind), ["link", "relay"])
        XCTAssertEqual(log.read(.init(kind: "relay")).map(\.code), ["relay_auth_refused"])
        XCTAssertEqual(log.read(.init(machine: "elsewhere")).count, 0)
        XCTAssertEqual(log.read(.init(limit: 1)).map(\.kind), ["relay"], "the limit keeps the newest")
    }

    /// C11H-402: the audit folder is made private by its own mode, never by
    /// borrowing the process umask, which every other thread's new files share.
    /// Fails with `umask(0o077)` put back around the folder's creation.
    func testMakingTheAuditFolderNeverChangesTheProcessUmask() {
        let probe = UmaskLeakProbe(folder: tmp)
        probe.start()
        var folders: [URL] = []
        for index in 0..<200 {
            let log = C11AuditLog(directory: tmp.appendingPathComponent("logs/\(index)/audit", isDirectory: true))
            XCTAssertTrue(log.append(C11AuditRecord(kind: .link, via: "test", outcome: "ok")))
            folders.append(log.directory)
        }
        let seen = probe.stop()
        XCTAssertGreaterThan(seen.probes, 0, "the probe made folders while the logs were made")
        XCTAssertEqual(seen.lost.map { String($0, radix: 8) }, [], "another thread's 0755 folder lost bits")
        XCTAssertEqual(folders.filter { mode($0) != 0o700 }, [], "every audit folder is private")
    }

    func testTheLogRotatesOnceAndKeepsTheNewest() {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true), maxBytes: 600)
        for index in 0..<12 {
            XCTAssertTrue(log.append(C11AuditRecord(kind: .remoteLaunch, via: "app", outcome: "ok", machine: "m\(index)")))
        }
        let current = (try? Data(contentsOf: log.fileURL))?.count ?? 0
        let rotated = (try? Data(contentsOf: log.rotatedURL))?.count ?? 0
        XCTAssertGreaterThan(rotated, 0, "the full file moved aside")
        XCTAssertLessThanOrEqual(current, 600)
        XCTAssertLessThanOrEqual(rotated, 600)
        let machines = log.read().compactMap(\.machine)
        XCTAssertEqual(machines.last, "m11", "the newest record survives rotation")
        XCTAssertEqual(machines, machines.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! }, "oldest first across both files")
        XCTAssertLessThan(machines.count, 12, "only one rotated file is kept")
    }

    func testASymlinkedAuditFolderIsNeverWrittenThrough() throws {
        let elsewhere = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("audit")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let log = C11AuditLog(directory: link)
        XCTAssertFalse(log.append(C11AuditRecord(kind: .unlink, via: "cli", outcome: "ok", machine: "studio")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testALooseAuditFolderIsMadePrivate() throws {
        let folder = tmp.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        let log = C11AuditLog(directory: folder)
        XCTAssertTrue(log.append(C11AuditRecord(kind: .update, via: "settings", outcome: "ok", machine: "studio")))
        XCTAssertEqual(mode(folder), 0o700)
    }

    /// A terminal c11 starts on another machine is audited with its program
    /// name only; a local one is not a cross-machine action.
    func testARemoteLaunchIsAuditedWithItsProgramNameOnly() {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        let panel = UUID(), workspace = UUID()
        let remote = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: UUID(),
                                     argv: ["/opt/bin/claude", "--resume", "SECRET-PROMPT"], environment: ["TOKEN": "SECRET"],
                                     machine: "studio", labels: [HCOwnerLabels.workspace: workspace.uuidString])
        HCManagedSession.auditRemoteLaunch(remote, result: .rejectedBeforeTransmission(.connectionLost), sent: false, audit: log)
        HCManagedSession.auditRemoteLaunch(remote, result: .unresolved(remote.identity, .deadlineExceeded), sent: true, audit: log)
        let local = HCCreateRequest(identity: HCPanelIdentity(panelID: UUID(), origin: .fresh), creationID: UUID(), argv: ["/bin/zsh"])
        HCManagedSession.auditRemoteLaunch(local, result: .rejectedBeforeTransmission(.connectionLost), sent: false, audit: log)
        log.flush()
        let records = log.read()
        XCTAssertEqual(records.map(\.kind), ["remote_launch", "remote_launch"], "a local terminal is not audited")
        XCTAssertEqual(records.map(\.outcome), ["refused", "unconfirmed"])
        XCTAssertEqual(records.first?.machine, "studio")
        XCTAssertEqual(records.first?.panel, panel.uuidString)
        XCTAssertEqual(records.first?.workspace, workspace.uuidString)
        XCTAssertEqual(records.first?.program, "claude")
        XCTAssertEqual(records.first?.code, "connectionLost")
        XCTAssertFalse(((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").contains("SECRET"),
                       "arguments and environment never reach the log")
    }

    func testATestProcessNeverWritesTheRealLog() {
        XCTAssertNotEqual(C11AuditLog.shared.directory, C11AuditLog.defaultDirectory())
        XCTAssertEqual(C11AuditLog.sharedDirectory(environment: [:], underTest: false), C11AuditLog.defaultDirectory())
    }

    // MARK: Relay records in their own file

    private func relay(_ index: Int) -> C11AuditRecord {
        C11AuditRecord(kind: .relay, via: "relay", outcome: "ok", machine: "studio", method: "set_status", code: "r\(index)")
    }

    /// Relayed calls rotate their own pair, so a burst of them never pushes
    /// a trust record (here a link) out of the log.
    func testRelayChatterNeverRotatesATrustRecordOut() throws {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true), maxBytes: 600)
        XCTAssertTrue(log.append(C11AuditRecord(kind: .link, via: "settings", outcome: "ok", machine: "studio",
                                                host: "me@studio.local")))
        let relayLine = try XCTUnwrap(C11AuditLog.encode(relay(0))).count + 1
        let perFile = 600 / relayLine
        XCTAssertGreaterThan(perFile, 0)
        let total = perFile * 3 + 1 // the relay file fills and rotates at least twice
        for index in 0..<total {
            XCTAssertTrue(log.append(relay(index)))
        }
        let trust = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(trust.split(separator: "\n").count, 1, "the trust file holds only the link")
        XCTAssertFalse(trust.contains(#""kind":"relay""#), "no relayed call reaches the trust file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.rotatedURL.path), "the trust pair never rotated")
        XCTAssertEqual(mode(log.relayFileURL), 0o600)
        XCTAssertEqual(mode(log.relayRotatedURL), 0o600)
        XCTAssertLessThanOrEqual((try? Data(contentsOf: log.relayFileURL))?.count ?? 0, 600)
        XCTAssertLessThanOrEqual((try? Data(contentsOf: log.relayRotatedURL))?.count ?? 0, 600)

        let links = log.read(.init(kind: "link"))
        XCTAssertEqual(links.map(\.machine), ["studio"], "the link survives every relay rotation")
        let relays = log.read(.init(kind: "relay"))
        XCTAssertLessThan(relays.count, total, "old relayed calls rotated out")
        XCTAssertEqual(relays.last?.code, "r\(total - 1)", "the newest relayed call is kept")
        XCTAssertEqual(log.read().count, relays.count + 1, "read merges both pairs")
    }

    // MARK: Two writers at the rotation boundary

    /// Two writers at the rotation boundary, as when the app and the CLI each
    /// own a `C11AuditLog` on the same folder. Writer A opens the full trust
    /// file and pauses there (the test seam), holding the lock; writer B
    /// appends meanwhile. With the stable `.lock`, B waits for A: A rotates
    /// the history aside and writes, then B appends after it. If `withLock`
    /// did not `flock`, B would rotate the history first and write a fresh
    /// file; A, still holding the old full file's descriptor, would then see
    /// it full and rotate B's fresh file over `audit.1.jsonl`, destroying the
    /// history. That was the original bug: an app write and a CLI write at
    /// the boundary destroyed the rotated history. This test fails without
    /// the lock.
    func testTwoWritersAtTheRotationBoundaryNeverDestroyTheRotatedHistory() throws {
        let folder = tmp.appendingPathComponent("audit", isDirectory: true)
        let maxBytes = 1000
        let filler = C11AuditLog(directory: folder, maxBytes: maxBytes)
        var size = 0
        var history: [String] = []
        while true {
            let record = C11AuditRecord(kind: .link, via: "cli", outcome: "ok", machine: "h\(history.count)")
            let line = try XCTUnwrap(C11AuditLog.encode(record)).count + 1
            guard size + line <= maxBytes else { break }
            XCTAssertTrue(filler.append(record))
            size += line
            history.append("h\(history.count)")
        }
        XCTAssertGreaterThan(history.count, 3)
        XCTAssertEqual((try? Data(contentsOf: filler.fileURL))?.count, size, "the trust file sits just under the cap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filler.rotatedURL.path))

        let recordA = C11AuditRecord(kind: .link, via: "settings", outcome: "ok", machine: "writer-a")
        let recordB = C11AuditRecord(kind: .link, via: "cli", outcome: "ok", machine: "writer-b")
        let lineA = try XCTUnwrap(C11AuditLog.encode(recordA)).count + 1
        let lineB = try XCTUnwrap(C11AuditLog.encode(recordB)).count + 1
        XCTAssertGreaterThan(size + lineA, maxBytes, "A's line rotates")
        XCTAssertGreaterThan(size + lineB, maxBytes, "B's line would rotate the full file too")
        XCTAssertLessThanOrEqual(lineA + lineB, maxBytes, "after A rotates, B fits beside it")

        let writerA = C11AuditLog(directory: folder, maxBytes: maxBytes)
        let writerB = C11AuditLog(directory: folder, maxBytes: maxBytes)
        let paused = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let flags = Flags()
        // Every wait is bounded, so a broken lock fails the asserts below
        // rather than hanging the run.
        writerA.afterOpenForTesting = {
            guard flags.claim("paused") else { return }
            paused.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            flags.set("a", writerA.append(recordA))
            done.leave()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success, "A opened the full file and paused holding the lock")
        done.enter()
        DispatchQueue.global().async {
            flags.set("b", writerB.append(recordB))
            done.leave()
        }
        // B now waits on the lock; without it, B would rotate in this time.
        Thread.sleep(forTimeInterval: 0.3)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "both writers finished")
        XCTAssertEqual(flags.get("a"), true)
        XCTAssertEqual(flags.get("b"), true)
        XCTAssertEqual(try machines(in: filler.rotatedURL), history, "the rotated file still holds the whole history")
        XCTAssertEqual(try machines(in: filler.fileURL), ["writer-a", "writer-b"], "B waited for A, then appended after it")
    }

    private func machines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["machine"] as? String ?? ""
        }
    }

    // MARK: The via's refused dials

    private static let t0 = Date(timeIntervalSince1970: 1_794_800_000)

    /// One `link-ssh.log` line, `offset` seconds after `t0`, in the via's form.
    private func linkLine(_ offset: TimeInterval, reason: String, status: Int = 8, machine: String = "localhost",
                          host: String = "far@localhost", session: String = "c11-c11-orch4") -> String {
        let time = C11AuditLog.timestamp(Self.t0.addingTimeInterval(offset))
        return "time=\(time) status=\(status) signal=- up_s=0 reason=\(reason) machine=\(machine) host=\(host) session=\(session)"
    }

    private func writeLinkLog(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The via's refused dials become trust records: one per kind, machine,
    /// host and session every ten minutes, each line taken once, and a dial
    /// inside the window is carried into the key's next record.
    func testRefusedDialsInTheLinkLogBecomeOneRecordPerKeyEveryTenMinutes() throws {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        XCTAssertEqual(log.linkLogURL.path, tmp.appendingPathComponent("link-ssh.log").path)
        let t0 = Self.t0
        var fixture = [
            linkLine(0, reason: "hc_serving_mismatch"),
            linkLine(5, reason: "-", status: 0),
            linkLine(10, reason: "hc_fd_limit"),
            linkLine(20, reason: "hc_hash_mismatch"),
            linkLine(30, reason: "hc_dir_refused", session: "c11-other"),
            linkLine(40, reason: "hc_serving_mismatch"),
            linkLine(50, reason: "hc_hash_mismatch", machine: "evil;$(rm)\u{1B}[31m", host: "-oProxyCommand=x"),
        ]
        try writeLinkLog(fixture, to: log.linkLogURL)

        XCTAssertEqual(log.ingestLinkLog(now: t0.addingTimeInterval(60)), 5)
        let records = log.read()
        XCTAssertEqual(records.map(\.kind), ["hc_serving_mismatch", "hc_fd_limit", "hc_hash_mismatch", "dir_refused", "hc_hash_mismatch"],
                       "a reason=- dial is not a record; C11H-392: a dial refused for its open-file limit is")
        XCTAssertEqual(records.map(\.code), ["hc_serving_mismatch", "hc_fd_limit", "hc_hash_mismatch", "hc_dir_refused", "hc_hash_mismatch"])
        XCTAssertEqual(Set(records.map(\.via)), ["link"])
        XCTAssertEqual(Set(records.map(\.outcome)), ["refused"])
        XCTAssertEqual(records[0].machine, "localhost")
        XCTAssertEqual(records[0].host, "far@localhost")
        XCTAssertEqual(records[0].session, "c11-c11-orch4")
        XCTAssertEqual(records[0].time, C11AuditLog.timestamp(t0), "a record keeps the dial's own time")
        XCTAssertEqual(records.map(\.count), [2, nil, nil, nil, nil], "a repeat in the same pass folds into its record")
        XCTAssertEqual(records[3].session, "c11-other")
        XCTAssertEqual(records[4].machine, "invalid", "a machine outside the token pattern is never recorded as written")
        XCTAssertEqual(records[4].host, "invalid")
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("evil") || text.contains("ProxyCommand"))
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B }, "no control characters")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.relayFileURL.path), "refused dials are trust records")

        let written = try Data(contentsOf: log.fileURL)
        XCTAssertEqual(log.ingestLinkLog(now: t0.addingTimeInterval(90)), 0, "the cursor remembers the last line taken")
        XCTAssertEqual(try Data(contentsOf: log.fileURL), written)

        // Two more refusals inside the ten minutes after t0: carried, not written.
        fixture += [linkLine(120, reason: "hc_serving_mismatch"), linkLine(180, reason: "hc_serving_mismatch")]
        try writeLinkLog(fixture, to: log.linkLogURL)
        XCTAssertEqual(log.ingestLinkLog(now: t0.addingTimeInterval(200)), 0)
        XCTAssertEqual(try Data(contentsOf: log.fileURL), written)

        // After the window the next record counts the two carried dials, its
        // own and a repeat folded into it in the same pass.
        fixture += [linkLine(700, reason: "hc_serving_mismatch"), linkLine(710, reason: "hc_serving_mismatch")]
        try writeLinkLog(fixture, to: log.linkLogURL)
        XCTAssertEqual(log.ingestLinkLog(now: t0.addingTimeInterval(720)), 1)
        let serving = log.read(.init(kind: "hc_serving_mismatch"))
        XCTAssertEqual(serving.map(\.time), [C11AuditLog.timestamp(t0), C11AuditLog.timestamp(t0.addingTimeInterval(700))])
        XCTAssertEqual(serving.map(\.count), [2, 4], "no refused dial is lost")
        XCTAssertEqual(serving.last?.detail?.hasPrefix("the far end refused a serving hc that isn't this build's"), true)

        // The carried count was spent: a lone dial after the next window is one.
        fixture.append(linkLine(1400, reason: "hc_serving_mismatch"))
        try writeLinkLog(fixture, to: log.linkLogURL)
        XCTAssertEqual(log.ingestLinkLog(now: t0.addingTimeInterval(1410)), 1)
        XCTAssertEqual(log.read(.init(kind: "hc_serving_mismatch")).map(\.count), [2, 4, nil])

        let local = log.read(.init(machine: "localhost"))
        XCTAssertEqual(local.map(\.kind), ["hc_serving_mismatch", "hc_fd_limit", "hc_hash_mismatch", "dir_refused", "hc_serving_mismatch",
                                           "hc_serving_mismatch"],
                       "the record with a refused machine name is not this machine's")
    }

    /// C11H-392: a Linux machine's dial refused before it starts a core is a
    /// record of its own kind, named for its fix.
    func testLinuxRefusedDialsBecomeRecordsNamedForTheirCause() throws {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        try writeLinkLog([linkLine(0, reason: "hc_needs_linger", status: 9),
                          linkLine(10, reason: "hc_needs_user_manager", status: 10),
                          linkLine(20, reason: "hc_fd_limit", status: 4)], to: log.linkLogURL)
        XCTAssertEqual(log.ingestLinkLog(now: Self.t0.addingTimeInterval(30)), 3)
        let records = log.read()
        XCTAssertEqual(records.map(\.kind), ["hc_needs_linger", "hc_needs_user_manager", "hc_fd_limit"])
        XCTAssertEqual(Set(records.map(\.outcome)), ["refused"])
        XCTAssertEqual(records.first?.detail?.contains("linger is off"), true)
        XCTAssertEqual(records[1].detail?.contains("no systemd user manager"), true)
    }

    /// A cursor written before carried counts existed still resumes after
    /// its last line.
    func testAnIngestCursorFromAnOlderBuildStillResumes() throws {
        let log = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))
        let first = linkLine(0, reason: "hc_serving_mismatch")
        try writeLinkLog([first, linkLine(700, reason: "hc_hash_mismatch")], to: log.linkLogURL)
        try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = "hc_serving_mismatch|localhost|far@localhost|c11-c11-orch4"
        let cursor: [String: Any] = [
            "last": first, "lastTime": C11AuditLog.timestamp(Self.t0), "recent": [key: Self.t0.timeIntervalSince1970],
        ]
        let old = try JSONSerialization.data(withJSONObject: cursor)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.directory.appendingPathComponent(C11AuditLog.cursorName).path,
                                                     contents: old, attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(log.ingestLinkLog(now: Self.t0.addingTimeInterval(710)), 1)
        XCTAssertEqual(log.read().map(\.kind), ["hc_hash_mismatch"])
    }
}

/// Thread-safe flags for the two-writer test.
private final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func set(_ key: String, _ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func get(_ key: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    /// True only the first time `key` is claimed.
    func claim(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard values[key] == nil else { return false }
        values[key] = true
        return true
    }
}

/// C11H-402: watches for a borrowed process umask. A background thread makes,
/// reads and removes a 0755 folder in a loop; any folder that comes out with
/// fewer bits than the starting umask allows means some other thread changed
/// the process-wide umask while it ran. A umask is shared by every thread, so
/// a private-folder seam that sets it, even briefly, makes other threads'
/// files lose bits. Run the seam many times between `start` and `stop`.
final class UmaskLeakProbe: @unchecked Sendable {
    private let folder: URL
    private let expected: mode_t
    private let lock = NSLock()
    private var stopping = false
    private var probes = 0
    private var lost: [mode_t] = []
    private let finished = DispatchSemaphore(value: 0)

    init(folder: URL) {
        self.folder = folder
        // umask has no read-only call, and setting it is what this probe looks for: read it as the bits a 0777
        // folder keeps.
        let reader = folder.appendingPathComponent("umask-read").path
        var info = stat()
        let kept: mode_t = (mkdir(reader, 0o777) == 0 && lstat(reader, &info) == 0) ? info.st_mode & 0o777 : 0o755
        rmdir(reader)
        expected = mode_t(0o755) & kept
    }

    func start() {
        let path = folder.appendingPathComponent("probe").path
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            while true {
                lock.lock(); let done = stopping; lock.unlock()
                if done { return }
                guard mkdir(path, 0o755) == 0 else { continue }
                var info = stat()
                let read = lstat(path, &info) == 0
                rmdir(path)
                lock.lock()
                probes += 1
                if read, info.st_mode & 0o777 != expected { lost.append(info.st_mode & 0o777) }
                lock.unlock()
            }
        }
    }

    /// Stops the probe thread and returns how many folders it made and the modes that lost bits.
    func stop() -> (probes: Int, lost: [mode_t]) {
        lock.lock(); stopping = true; lock.unlock()
        finished.wait()
        lock.lock(); defer { lock.unlock() }
        return (probes, lost)
    }
}
