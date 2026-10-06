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
        ).writeAll(mailboxesRoot: mailboxesRoot(ws ?? workspace)).first
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
        XCTAssertEqual(decoded.receipt.tabId, tab)
        XCTAssertEqual(decoded.receipt.via, "drain")
        XCTAssertEqual(decoded.receipt.deliveries.map(\.id), [idA, idB])
        XCTAssertTrue(decoded.dropped.isEmpty)
    }

    func testAFileThatIsNotAReceiptIsRejectedWhole() {
        func decode(_ json: String) -> MailboxDeliveryReceipt.Decoded? { MailboxDeliveryReceipt.decode(Data(json.utf8)) }
        let ok = #"{"version":1,"via":"drain","ts":"2026-10-01T12:00:00Z","deliveries":[{"id":"01K0000000000000000000000A","recipient":"w"}]}"#
        XCTAssertNotNil(decode(ok))
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)))
        XCTAssertNil(decode(ok.replacingOccurrences(of: #""drain""#, with: #""push""#)))
        XCTAssertNil(decode(#"{"version":1,"via":"drain","ts":"t"}"#))
        XCTAssertNil(MailboxDeliveryReceipt.decode(Data(repeating: 0x20, count: MailboxDeliveryReceipt.maxBytes + 1)))
    }

    func testInvalidDeliveriesAreDroppedAndTheValidOnesKept() throws {
        let json = #"""
        {"version":1,"via":"drain","ts":"t","tab_id":"not-a-uuid","extra":true,"deliveries":[
          {"id":"01K0000000000000000000000A","recipient":"w"},
          {"id":"0note","recipient":"w"},
          {"id":"","recipient":"w"},
          {"id":"bad\u0007id","recipient":"w"},
          {"id":"a/b","recipient":"w"},
          {"id":"01K0000000000000000000000B","recipient":""},
          {"id":"01K0000000000000000000000C","recipient":"\#(String(repeating: "r", count: 257))"},
          "not an object",
          {"id":"01K0000000000000000000000D","recipient":"w","extra":1}
        ]}
        """#
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.receipt.deliveries.map(\.id), [idA, "01K0000000000000000000000D"])
        XCTAssertNil(decoded.receipt.tabId)
        XCTAssertEqual(decoded.dropped.count, 8)   // the tab_id, six bad entries (0note is not a ULID), the non-object
    }

    func testSixHundredDeliveriesSplitIntoReceiptsThatFit() throws {
        let ids = (0..<600).map { String(format: "01K%023d", $0) }
        let urls = MailboxDeliveryReceipt(
            tabId: tab,
            deliveries: ids.map { .init(id: $0, recipient: "watcher") }
        ).writeAll(mailboxesRoot: mailboxesRoot(workspace))
        XCTAssertEqual(urls.count, 2)
        var seen: [String] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, MailboxDeliveryReceipt.maxBytes)
            let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(data))
            XCTAssertLessThanOrEqual(decoded.receipt.deliveries.count, MailboxDeliveryReceipt.maxDeliveries)
            XCTAssertTrue(decoded.dropped.isEmpty)
            seen += decoded.receipt.deliveries.map(\.id)
        }
        XCTAssertEqual(seen, ids)
    }

    func testLongRecipientsSplitByBytesAndAreClamped() throws {
        let long = String(repeating: "é", count: 200)   // 400 bytes, clamped to 256
        let ids = (0..<400).map { String(format: "01K%023d", $0) }
        let urls = MailboxDeliveryReceipt(
            tabId: tab,
            deliveries: ids.map { .init(id: $0, recipient: long) }
        ).writeAll(mailboxesRoot: mailboxesRoot(workspace))
        XCTAssertGreaterThan(urls.count, 1, "400 entries of ~300 bytes cannot fit one 64 KB receipt")
        var seen: [String] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, MailboxDeliveryReceipt.maxBytes)
            let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(data))
            XCTAssertTrue(decoded.dropped.isEmpty)
            XCTAssertTrue(decoded.receipt.deliveries.allSatisfy { $0.recipient.utf8.count <= 256 && $0.recipient.hasPrefix("é") })
            seen += decoded.receipt.deliveries.map(\.id)
        }
        XCTAssertEqual(seen, ids)
    }

    func testAReceiptWithBadEntriesRecordsTheGoodOnesAndListsTheRest() throws {
        try FileManager.default.createDirectory(at: spool(workspace), withIntermediateDirectories: true)
        let name = "\(idC).receipt"
        let json = #"{"version":1,"via":"drain","ts":"t","tab_id":"\#(tab.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"},{"id":"","recipient":"w"},{"id":"0note","recipient":"w"}]}"#
        try Data(json.utf8).write(to: spool(workspace).appendingPathComponent(name))
        let sink = Sink()
        let recorder = makeRecorder(sink)
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idA])
        XCTAssertEqual(names(spool(workspace)), [])
        let sidecar = spool(workspace).appendingPathComponent("_rejected/\(name).dropped")
        let logged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual((logged["dropped"] as? [Any])?.count, 2)
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

// MARK: - C11-337: receipts carry panel_id beside tab_id

extension MailboxReceiptRecorderTests {
    func testNewReceiptWritesPanelIdAndTabId() throws {
        let url = try XCTUnwrap(writeReceipt([idA]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["panel_id"] as? String, tab.uuidString)
        XCTAssertEqual(object["tab_id"] as? String, tab.uuidString, "tab_id is still written for one release")
    }

    func testReceiptWithOnlyLegacyTabIdIsRecordedWithItsPanel() throws {
        try FileManager.default.createDirectory(at: spool(workspace), withIntermediateDirectories: true)
        let json = #"{"version":1,"via":"drain","ts":"t","tab_id":"\#(tab.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.receipt.tabId, tab)
        XCTAssertTrue(decoded.dropped.isEmpty)

        try Data(json.utf8).write(to: spool(workspace).appendingPathComponent("\(idB).receipt"))
        let sink = Sink()
        sweep(makeRecorder(sink))
        XCTAssertEqual(sink.snapshot, [Emitted(workspace: workspace, id: idA, recipient: "w", surface: tab)])
        XCTAssertEqual(names(spool(workspace)), [])
    }

    func testReceiptWithOnlyPanelIdIsRecordedWithItsPanel() throws {
        try FileManager.default.createDirectory(at: spool(workspace), withIntermediateDirectories: true)
        let json = #"{"version":1,"via":"drain","ts":"t","panel_id":"\#(tab.uuidString)","deliveries":[{"id":"\#(idA)","recipient":"w"}]}"#
        let decoded = try XCTUnwrap(MailboxDeliveryReceipt.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.receipt.tabId, tab)

        try Data(json.utf8).write(to: spool(workspace).appendingPathComponent("\(idB).receipt"))
        let sink = Sink()
        sweep(makeRecorder(sink))
        XCTAssertEqual(sink.snapshot, [Emitted(workspace: workspace, id: idA, recipient: "w", surface: tab)])
    }

    func testLeftoverReceiptAlreadyInAV2EventLogIsNotRecordedAgain() throws {
        writeReceipt([idA, idB])
        let line = #"{"instance":"old","panel":"\#(tab.uuidString)","payload":{"id":"\#(idA)","recipient":"watcher","via":"drain"},"seq":9,"ts":"2026-10-06T12:00:00Z","type":"mailbox.delivered","v":2,"workspace":"\#(workspace.uuidString)"}"#
        try Data((line + "\n").utf8).write(to: eventsDir.appendingPathComponent("events-old.ndjson"))
        let sink = Sink()
        let recorder = makeRecorder(sink, startedAt: Date().addingTimeInterval(60))
        sweep(recorder)
        XCTAssertEqual(sink.snapshot.map(\.id), [idB])
    }
}
