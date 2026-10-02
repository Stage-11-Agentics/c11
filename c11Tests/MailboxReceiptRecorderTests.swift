import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-257 Lane C: drain delivery receipts (`_receipts/` spool) and the app
/// recorder that turns them into `mailbox.delivered via:"drain"`.
final class MailboxReceiptRecorderTests: XCTestCase {

    private var root: URL!
    private var workspacesRoot: URL!
    private var eventsDir: URL!
    private let workspace = UUID(uuidString: "56CB5ABD-E57D-4800-9EFD-C4267A0FE6A7")!
    private let tab = UUID(uuidString: "B3A3DFEF-0A83-4887-BBE9-FDE27516A3B5")!
    private let idA = "01K0000000000000000000000A"
    private let idB = "01K0000000000000000000000B"
    private let idC = "01K0000000000000000000000C"

    private struct Emitted: Equatable {
        let workspace: UUID
        let id: String
        let recipient: String
        let surface: UUID?
    }

    private final class Sink {
        let lock = NSLock()
        var events: [Emitted] = []
        var flushes = 0
        var recording = true
        func append(_ event: Emitted) { lock.lock(); events.append(event); lock.unlock() }
        var snapshot: [Emitted] { lock.lock(); defer { lock.unlock() }; return events }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c11-receipts-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        eventsDir = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mailboxesRoot(_ ws: UUID) -> URL {
        workspacesRoot.appendingPathComponent(ws.uuidString, isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
    }

    private func spool(_ ws: UUID) -> URL {
        MailboxDeliveryReceipt.spoolURL(mailboxesRoot: mailboxesRoot(ws))
    }

    private func names(_ dir: URL, ext: String = "receipt") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".\(ext)") }.sorted()
    }

    private func makeRecorder(_ sink: Sink, startedAt: Date = Date().addingTimeInterval(-3600)) -> MailboxReceiptRecorder {
        MailboxReceiptRecorder(
            startedAt: startedAt,
            emit: { sink.append(Emitted(workspace: $0, id: $1, recipient: $2, surface: $3)) },
            flush: { sink.lock.lock(); sink.flushes += 1; sink.lock.unlock() },
            isRecording: { sink.recording },
            eventsDirectory: { [eventsDir] in eventsDir }
        )
    }

    @discardableResult
    private func writeReceipt(_ ids: [String], ws: UUID? = nil, tabId: UUID? = nil) -> URL? {
        MailboxDeliveryReceipt(
            tabId: tabId ?? tab,
            deliveries: ids.map { .init(id: $0, recipient: "watcher") }
        ).write(mailboxesRoot: mailboxesRoot(ws ?? workspace))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func sweep(_ recorder: MailboxReceiptRecorder, _ ws: UUID? = nil) {
        recorder.sync { recorder.sweep(spool: spool(ws ?? workspace), workspaceId: ws ?? workspace) }
    }

    // MARK: - Receipt format

    func testReceiptRoundTripsAndIsWrittenAtomically() throws {
        let url = try XCTUnwrap(writeReceipt([idA, idB]))
        XCTAssertEqual(url.pathExtension, "receipt")
        XCTAssertEqual(names(spool(workspace), ext: "tmp"), [])
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(contentsOf: url)))
        XCTAssertEqual(decoded.tabId, tab)
        XCTAssertEqual(decoded.via, "drain")
        XCTAssertEqual(decoded.deliveries.map(\.id), [idA, idB])
    }

    func testReceiptValidationRejectsMalformedContent() {
        func decode(_ json: String) -> MailboxDeliveryReceipt? { MailboxDeliveryReceipt.decode(Data(json.utf8)) }
        let ok = #"{"version":1,"via":"drain","ts":"2026-10-01T12:00:00Z","deliveries":[{"id":"01K0000000000000000000000A","recipient":"w"}]}"#
        XCTAssertNotNil(decode(ok))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""drain""#, with: #""push""#)))
        XCTAssertNil(decode(ok.replacingOccurrences(of: "01K0000000000000000000000A", with: "not-a-ulid")))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""recipient":"w""#, with: #""recipient":"""#)))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""via""#, with: #""tab_id":"nope","via""#)))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""via""#, with: #""extra":1,"via""#)))
        XCTAssertNil(decode(#"{"version":1,"via":"drain","ts":"t","deliveries":[]}"#))
        let many = (0..<513).map { _ in #"{"id":"01K0000000000000000000000A","recipient":"w"}"# }.joined(separator: ",")
        XCTAssertNil(decode(#"{"version":1,"via":"drain","ts":"t","deliveries":[\#(many)]}"#))
        XCTAssertNil(MailboxDeliveryReceipt.decode(Data(repeating: 0x20, count: MailboxDeliveryReceipt.maxBytes + 1)))
    }

    // MARK: - Recording

    func testRecordsEachDeliveryOnceThenDeletesTheReceipt() throws {
        let sink = Sink()
        let recorder = makeRecorder(sink)
        writeReceipt([idA, idB])
        sweep(recorder)
        XCTAssertEqual(sink.snapshot, [
            Emitted(workspace: workspace, id: idA, recipient: "watcher", surface: tab),
            Emitted(workspace: workspace, id: idB, recipient: "watcher", surface: tab)
        ])
        XCTAssertGreaterThanOrEqual(sink.flushes, 1)
        XCTAssertEqual(names(spool(workspace)), [])
    }

    func testDuplicateReceiptIsRecordedOnce() {
        let sink = Sink()
        let recorder = makeRecorder(sink)
        writeReceipt([idA])
        writeReceipt([idA, idB])
        sweep(recorder)
        writeReceipt([idB])
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idA, idB])
        XCTAssertEqual(names(spool(workspace)), [])
    }

    func testLeftoverReceiptAlreadyInTheEventLogIsNotRecordedAgain() throws {
        // A previous run emitted A, flushed, and died before deleting the receipt.
        writeReceipt([idA, idB])
        let line = #"{"instance":"old","payload":{"id":"\#(idA)","recipient":"watcher","via":"drain"},"seq":9,"surface":"\#(tab.uuidString)","ts":"2026-10-01T12:00:00Z","type":"mailbox.delivered","v":1,"workspace":"\#(workspace.uuidString)"}"#
        try Data((line + "\n").utf8).write(to: eventsDir.appendingPathComponent("events-old.ndjson"))
        let sink = Sink()
        let recorder = makeRecorder(sink, startedAt: Date().addingTimeInterval(60))  // this run started after the receipt
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idB])
        XCTAssertEqual(names(spool(workspace)), [])
    }

    func testANewReceiptIsNeverCheckedAgainstOldLogs() throws {
        // Same id already in a log, but the receipt is from this run: a new
        // delivery of a re-sent id is still recorded.
        let line = #"{"payload":{"id":"\#(idA)","recipient":"w","via":"drain"},"type":"mailbox.delivered"}"#
        try Data((line + "\n").utf8).write(to: eventsDir.appendingPathComponent("events-old.ndjson"))
        let sink = Sink()
        let recorder = makeRecorder(sink, startedAt: Date().addingTimeInterval(-60))
        writeReceipt([idA])
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idA])
    }

    func testNothingIsDeletedUntilTheEventLogRecords() throws {
        let sink = Sink()
        sink.recording = false
        let recorder = makeRecorder(sink)
        writeReceipt([idA])
        sweep(recorder)
        XCTAssertEqual(sink.snapshot, [])
        XCTAssertEqual(names(spool(workspace)).count, 1)

        sink.recording = true
        XCTAssertTrue(waitUntil(timeout: 8) { !sink.snapshot.isEmpty }, "the retry records the receipt")
        XCTAssertEqual(sink.snapshot.map(\.id), [idA])
        recorder.sync()
        XCTAssertEqual(names(spool(workspace)), [])
    }

    func testMalformedReceiptIsMovedAsideAndNothingRecorded() throws {
        try FileManager.default.createDirectory(at: spool(workspace), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: spool(workspace).appendingPathComponent("\(idC).receipt"))
        let sink = Sink()
        let recorder = makeRecorder(sink)
        sweep(recorder)
        XCTAssertEqual(sink.snapshot, [])
        XCTAssertEqual(names(spool(workspace)), [])
        XCTAssertEqual(names(spool(workspace).appendingPathComponent("_rejected")), ["\(idC).receipt"])
    }

    /// A pid that is certainly not running: spawn `true`, reap it.
    private func deadPid() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    func testAbandonedClaimOfADeadProcessIsRecoveredAndRecordedOnce() throws {
        // A previous c11 claimed the receipt, recorded A, and died before
        // deleting it.
        let url = try XCTUnwrap(writeReceipt([idA, idB]))
        let claim = spool(workspace).appendingPathComponent(".\(url.lastPathComponent).\(try deadPid()).claim")
        XCTAssertEqual(rename(url.path, claim.path), 0)
        let line = #"{"payload":{"id":"\#(idA)","recipient":"watcher","via":"drain"},"type":"mailbox.delivered"}"#
        try Data((line + "\n").utf8).write(to: eventsDir.appendingPathComponent("events-dead.ndjson"))
        let sink = Sink()
        let recorder = makeRecorder(sink, startedAt: Date().addingTimeInterval(60))
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idB])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool(workspace).path), [])
    }

    func testAReceiptClaimedByAnotherLiveProcessIsLeftToIt() throws {
        let url = try XCTUnwrap(writeReceipt([idA]))
        let claim = spool(workspace).appendingPathComponent(".\(url.lastPathComponent).\(getppid()).claim")
        XCTAssertEqual(rename(url.path, claim.path), 0)
        let sink = Sink()
        let recorder = makeRecorder(sink)
        sweep(recorder)
        XCTAssertEqual(sink.snapshot, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: claim.path))
    }

    func testSweepOfEveryWorkspaceRecordsReceiptsOfWorkspacesThatAreGone() {
        let other = UUID()
        writeReceipt([idA], ws: workspace)
        writeReceipt([idB], ws: other)
        let sink = Sink()
        let recorder = makeRecorder(sink)
        recorder.sync { recorder.sweepEveryWorkspace(workspacesRoot: workspacesRoot) }
        XCTAssertEqual(Set(sink.snapshot.map { "\($0.workspace.uuidString):\($0.id)" }),
                       ["\(workspace.uuidString):\(idA)", "\(other.uuidString):\(idB)"])
        XCTAssertEqual(names(spool(workspace)) + names(spool(other)), [])
    }

    func testWatchedSpoolRecordsANewReceiptWithoutAnExplicitSweep() {
        let sink = Sink()
        let recorder = makeRecorder(sink)
        recorder.watch(workspaceId: workspace, mailboxesRoot: mailboxesRoot(workspace), workspacesRoot: workspacesRoot)
        recorder.sync()
        writeReceipt([idA])
        XCTAssertTrue(waitUntil(timeout: 10) { !sink.snapshot.isEmpty }, "the watcher records the receipt")
        XCTAssertEqual(sink.snapshot.map(\.id), [idA])
        recorder.unwatch(workspaceId: workspace)
        recorder.sync()
    }

    func testUnwatchSweepsOnceMore() {
        let sink = Sink()
        let recorder = makeRecorder(sink)
        recorder.watch(workspaceId: workspace, mailboxesRoot: mailboxesRoot(workspace), workspacesRoot: workspacesRoot)
        recorder.sync()
        writeReceipt([idB])
        recorder.unwatch(workspaceId: workspace)
        recorder.sync()
        XCTAssertEqual(sink.snapshot.map(\.id), [idB])
    }
}
